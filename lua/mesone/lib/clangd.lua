-- Points clangd at the compile_commands.json of the current build folder.
--
-- The folder is passed as the init option `compilationDatabasePath`, which
-- clangd only reads on startup. A running clangd with another folder is
-- therefore stopped and started again by `vim.lsp.enable`, which resolves the
-- updated `vim.lsp.config`; `:lsp restart` would reuse the old config. Needs
-- clangd to be set up with `vim.lsp.enable`, as nvim-lspconfig and LazyVim do.

local M = { server = "clangd", stop_timeout_ms = 2000 }

local function _has_compile_commands(folder)
  return vim.uv.fs_stat(folder .. "/compile_commands.json") ~= nil
end

local function _database_path(client)
  local init_options = client.config.init_options or {}
  return init_options.compilationDatabasePath
end

-- Starts clangd again for the buffers it was attached to, once all of the
-- given clients have exited. Force-stops them if they take too long.
local function _start_when_stopped(clients, buffers)
  local waited = 0
  local timer = vim.uv.new_timer()
  timer:start(
    50,
    50,
    vim.schedule_wrap(function()
      waited = waited + 50
      local running = vim.tbl_filter(function(client)
        return not client:is_stopped()
      end, clients)

      if #running > 0 and waited < M.stop_timeout_ms then
        return
      end
      for _, client in ipairs(running) do
        client:stop(true)
      end

      timer:stop()
      timer:close()
      -- The FileType autocmd of vim.lsp.enable starts the server for a buffer
      -- with the config as it is now.
      for _, bufnr in ipairs(buffers) do
        if vim.api.nvim_buf_is_valid(bufnr) then
          pcall(vim.api.nvim_exec_autocmds, "FileType", { group = "nvim.lsp.enable", buffer = bufnr })
        end
      end
    end)
  )
end

-- Makes clangd use the compile commands of `folder` (an absolute path).
-- Does nothing if the folder has no compile_commands.json yet.
function M.use_build_folder(folder)
  -- vim.lsp.config and vim.lsp.enable need Neovim 0.11.
  if vim.lsp.config == nil or vim.lsp.enable == nil or not _has_compile_commands(folder) then
    return false
  end

  vim.lsp.config(M.server, { init_options = { compilationDatabasePath = folder } })

  local outdated = vim.tbl_filter(function(client)
    return _database_path(client) ~= folder
  end, vim.lsp.get_clients({ name = M.server }))

  if #outdated > 0 then
    local buffers = {}
    for _, client in ipairs(outdated) do
      vim.list_extend(buffers, vim.tbl_keys(client.attached_buffers))
      client:stop()
    end
    _start_when_stopped(outdated, buffers)
  end
  return true
end

return M
