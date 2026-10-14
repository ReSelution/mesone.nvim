local scandir = require("plenary.scandir")
local dap = require("dap")

local window = require("mesone.ui.window")
local project = require("mesone.project")
local tests = require("mesone.tests")
local settings = require("mesone.settings")
local clangd = require("mesone.lib.clangd")
local machine_files = require("mesone.lib.machine_files")
local command = require("mesone.lib.command")
local notification = require("mesone.lib.notification")
local storage = require("mesone.lib.storage")
local utils = require("mesone.lib.utils")

local M = {}
local instance = nil

M.get = function()
  if not instance then
    instance = M:new(settings:new())
  end
  return instance
end

function M:new(opts)
  local log_filename = os.tmpname()
  local cwd = vim.uv.cwd()
  local o = {
    opts = opts,
    cwd = cwd,
    log_filename = log_filename,
    project = nil,
    tests = nil,
    full_build_folder = vim.fs.normalize(cwd .. "/" .. opts:get().build_folder),
  }
  setmetatable(o, self)
  self.__index = self
  return o
end

-- Called whenever the build folder may have changed or got new compile
-- commands: tells listeners and, if enabled, clangd.
function M:_on_build_folder_changed()
  self.full_build_folder = vim.fs.normalize(vim.uv.cwd() .. "/" .. self.opts:get().build_folder)
  if self.opts:get().lsp_compile_commands then
    clangd.use_build_folder(self.full_build_folder)
  end
  if self.announced_build_folder ~= self.full_build_folder then
    self.announced_build_folder = self.full_build_folder
    vim.api.nvim_exec_autocmds("User", {
      pattern = "MesoneBuildFolderChanged",
      data = { build_folder = self.full_build_folder },
    })
  end
end

function M:_on_command_exit(status)
  self.running = false
  if status == 0 then
    self:_update_project()
    -- A setup may have created the build folder or its compile commands.
    self:_on_build_folder_changed()
  elseif status ~= 0 and not self.opts:get().show_command_logs then
    self:_show_log()
  end
end

function M:_update_project()
  self.project = project:new({ folder = self.opts:get().build_folder })
  self.project:load()
  self.opts:update({ build_type = self.project.options.build_type })
  if self.tests ~= nil then
    self.tests:update_project(self.project)
  end
end

-- Takes the machine files of the build folder into the settings, so that a
-- later setup keeps them.
function M:_adopt_machine_files()
  local adopted = machine_files.settings_from_build_folder(vim.uv.cwd(), self.full_build_folder)
  if adopted ~= nil then
    self.opts:update(adopted)
  end
end

function M:_on_init_completed()
  self.full_build_folder = vim.fs.normalize(vim.uv.cwd() .. "/" .. self.opts:get().build_folder)
  -- Only if none are configured, so that configured ones win.
  local opts = self.opts:get()
  if #machine_files.to_list(opts.cross_file) == 0 and #machine_files.to_list(opts.native_file) == 0 then
    self:_adopt_machine_files()
  end
  self:_update_project()
  self:_on_build_folder_changed()
  notification.notify("Mesone initialized", vim.log.levels.INFO)
end

function M:init()
  self.project = nil
  local pwd = vim.uv.cwd() .. "/"
  if utils.file_exists(pwd .. "meson.build") then
    -- The configured (or saved) folder wins if it is set up already, so that
    -- choosing one of several build folders sticks across restarts.
    if vim.uv.fs_stat(pwd .. self.opts:get().build_folder .. "/meson-info") ~= nil then
      vim.schedule(function()
        self:_on_init_completed()
      end)
      return
    end

    local metainfo_dir = nil
    scandir.scan_dir_async(pwd, {
      hidden = true,
      respect_gitignore = false,
      silent = true,
      depth = self.opts:get().info_depth,
      only_dirs = true,
      add_dirs = true,
      search_pattern = { ".*meson.info" },
      on_insert = function(filename)
        filename = vim.fs.normalize(filename)
        if metainfo_dir == nil and vim.fs.basename(filename) == "meson-info" then
          metainfo_dir = vim.fs.dirname(filename)
        end
      end,
      on_exit = function(_)
        if metainfo_dir ~= nil then
          self.opts:update({
            build_folder = utils.remove_prefix(metainfo_dir, pwd),
          })
          vim.schedule(function()
            self:_on_init_completed()
          end)
        end
      end,
    })
  end
end

function M:_meson_setup()
  if self.running then
    notification.notify("Meson already running", "warn")
    return
  end
  local cmd = command:new({
    build_folder = self.full_build_folder,
    log_filename = self.log_filename,
    show_command_logs = self.opts:get().show_command_logs,
  })
  -- Meson keeps the machine files across a reconfigure, so other ones need
  -- a wipe of the build folder.
  local reconfigure = "--reconfigure"
  if machine_files.differ(self.opts:get(), vim.uv.cwd(), self.full_build_folder) then
    reconfigure = "--wipe"
  end
  local args = {
    "setup",
    reconfigure,
    "--buildtype",
    self.opts:get().build_type,
  }
  vim.list_extend(args, machine_files.setup_args(self.opts:get()))
  table.insert(args, self.opts:get().build_folder)
  self.running = true
  cmd:execute(args, "Setup", function(status)
    self:_on_command_exit(status)
  end)
end

function M:_meson_compile(on_done)
  if self.running then
    notification.notify("Meson already running", "warn")
    return
  end
  local cmd = command:new({
    build_folder = self.full_build_folder,
    log_filename = self.log_filename,
    show_command_logs = self.opts:get().show_command_logs,
  })
  local args = { "compile", "-C", self.opts:get().build_folder }
  self.running = true
  cmd:execute(args, "Compile", function(status)
    self:_on_command_exit(status)
    if on_done then
      on_done(status)
    end
  end)
end

function M:setup(opts)
  local saved_opts = storage.load(vim.uv.cwd(), {})
  self.opts:update(vim.tbl_extend("force", opts, saved_opts))
  -- Lists become the comma-separated form the settings form can edit.
  for _, kind in ipairs(machine_files.kinds) do
    self.opts:update({ [kind] = machine_files.to_setting(self.opts:get()[kind]) })
  end
  self.full_build_folder = vim.fs.normalize(vim.uv.cwd() .. "/" .. self.opts:get().build_folder)
  -- Before any clangd has started, so that the first one already gets the
  -- right compile commands.
  if self.opts:get().lsp_compile_commands then
    clangd.use_build_folder(self.full_build_folder)
  end
end

function M:_clean()
  if self.running then
    notification.notify("Meson already running", "warn")
    return
  end
  local cmd = command:new({
    build_folder = self.full_build_folder,
    log_filename = self.log_filename,
    show_command_logs = self.opts:get().show_command_logs,
  })
  local args = { "compile", "--clean", "-C", self.opts:get().build_folder }
  self.running = true
  cmd:execute(args, "clean", function(status)
    self:_on_command_exit(status)
  end)
end

function M:_show_log()
  local buf, _ = window.centered_window()

  -- press 'q' or 'esc' to close window
  for _, key in ipairs({ "q", "<esc>" }) do
    vim.api.nvim_buf_set_keymap(buf, "n", key, "<cmd>close<cr>", {
      nowait = true,
      noremap = true,
      silent = true,
    })
  end

  vim.api.nvim_set_option_value("readonly", false, { buf = buf })
  vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
  local first = true

  utils.read_file(self.log_filename, function(line)
    local content_type = "out"
    if utils.is_failure_message(line) then
      content_type = "err"
    end
    utils.buf_append_colorized(buf, line, content_type, first)
    first = false
  end)

  vim.api.nvim_set_option_value("readonly", true, { buf = buf })
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
end

function M:_tests()
  if self.tests == nil then
    self.tests = tests:new(self.opts, self.project)
    self.tests:show()
  else
    self.tests:update_project(self.project)
    self.tests:refresh()
  end
end

function M:_run_target()
  local executables = self.project:get_executable()
  utils.select_from_list("Select target to run", vim.tbl_keys(executables), function(name)
    local function run_target()
      vim.cmd("botright split term://" .. executables[name].target)

      if self.opts:get().auto_close_terminal then
        local buf = vim.api.nvim_get_current_buf()
        vim.api.nvim_create_autocmd("TermClose", {
          buffer = buf,
          once = true,
          callback = function()
            if vim.v.event.status == 0 then
              vim.schedule(function()
                if vim.api.nvim_buf_is_valid(buf) then
                  vim.api.nvim_buf_delete(buf, { force = true })
                  notification.notify("Mesone: terminal closed", vim.log.levels.INFO)
                end
              end)
            else
              notification.notify("Mesone: terminal kept open due to errors", vim.log.levels.WARN)
            end
          end,
        })
      end
    end
    if self.opts:get().compile_before_run then
      self:_meson_compile(function(status)
        if status == 0 then
          run_target()
        else
          notification.notify("Execution skipped: compile errors", vim.log.levels.WARN)
        end
      end)
    else
      run_target()
    end
  end)
end

function M:_debug_target()
  local executables = self.project:get_executable()
  utils.select_from_list("Select target to run", vim.tbl_keys(executables), function(name)
    local dap_config = {
      args = {},
      cwd = vim.uv.cwd(),
      program = executables[name].target,
      request = "launch",
      name = "Debug " .. name,
      type = self.opts:get().dap_adapter,
    }

    dap.run(dap_config)
  end)
end

function M:parse_command(opts)
  local action = opts.fargs[1]
  if action == "init" then
    self:init()
  elseif action == "setup" then
    self:_meson_setup()
  elseif action == "compile" then
    self:_meson_compile()
  elseif action == "test" then
    self:_tests()
  elseif action == "log" then
    self:_show_log()
  elseif action == "run" then
    self:_run_target()
  elseif action == "debug" then
    self:_debug_target()
  elseif action == "cross" then
    self:_select_machine_file("cross_file")
  elseif action == "native" then
    self:_select_machine_file("native_file")
  elseif action == "setting" then
    self:_show_settings()
  elseif action == "log" then
    self:_show_log()
  elseif action == "clean" then
    self:_clean()
  else
    notification.notify("Mesone: invalid arguments: " .. opts.args, vim.log.levels.ERROR)
  end
end

function M:check_auto_build(opts)
  if not self.opts:get().auto_compile or self.project == nil then
    return
  end
  local found = false
  for _, filename in ipairs(self.project.sources) do
    if opts.match == filename then
      found = true
      break
    end
  end
  if found then
    self:_meson_compile()
  end
end

function M:check_focused_buffer(bufnr, filename)
  if self.tests ~= nil then
    self.tests:update_buffer_signs(bufnr, filename)
  end
end

function M:on_buffer_focused(ev)
  if self.project == nil or ev.file == "" then
    return
  end
  local buffer_filename = ev.file

  if not utils.file_exists(buffer_filename) then
    return
  end
  local found = false
  for _, filename in ipairs(self.project.sources) do
    if buffer_filename == filename then
      found = true
      break
    end
  end
  if found then
    local buffer_number = vim.fn.bufnr(buffer_filename)
    if vim.fn.buflisted(buffer_number) ~= 0 and vim.api.nvim_buf_is_valid(buffer_number) then
      self:check_focused_buffer(buffer_number, buffer_filename)
    end
  end
end

local no_machine_file = "(none)"

-- Picks the machine file of a kind from the files found in the project. It is
-- used by the next setup.
function M:_select_machine_file(kind)
  local current = machine_files.to_list(self.opts:get()[kind])
  local entries = { no_machine_file }
  local paths = { [no_machine_file] = "" }
  for _, path in ipairs(machine_files.candidates(vim.uv.cwd(), kind, self.opts:get().info_depth)) do
    local entry = path
    if vim.list_contains(current, path) then
      entry = path .. " (current)"
    end
    table.insert(entries, entry)
    paths[entry] = path
  end
  if #current == 0 then
    entries[1] = no_machine_file .. " (current)"
    paths[entries[1]] = ""
  end
  local title = kind == "cross_file" and "Select cross file" or "Select native file"
  utils.select_from_list(title, entries, function(entry)
    self.opts:update({ [kind] = paths[entry] })
    storage.save(vim.uv.cwd(), self.opts:get())
    local name = paths[entry] ~= "" and paths[entry] or "none"
    notification.notify("Mesone: " .. kind:gsub("_", " ") .. ": " .. name .. ", used by the next setup", vim.log.levels.INFO)
  end)
end

function M:_show_settings()
  local before = vim.deepcopy(self.opts:get())
  self.opts:ui(function(opts)
    -- Switching to another build folder brings its machine files along,
    -- unless they were changed in the form as well.
    if opts.build_folder ~= before.build_folder then
      local unchanged = true
      for _, kind in ipairs(machine_files.kinds) do
        if machine_files.to_setting(opts[kind]) ~= machine_files.to_setting(before[kind]) then
          unchanged = false
        end
      end
      if unchanged then
        self.full_build_folder = vim.fs.normalize(vim.uv.cwd() .. "/" .. opts.build_folder)
        self:_adopt_machine_files()
        opts = self.opts:get()
      end
    end
    storage.save(vim.uv.cwd(), opts)
    notification.notify("Project setting saved", vim.log.levels.INFO)
    self:_update_project()
    self:_on_build_folder_changed()
  end)
end

return M
