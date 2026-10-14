-- Cross and native files (meson machine files) of a project.
--
-- In the settings a kind ("cross_file" or "native_file") holds a string with
-- one or more comma-separated paths, or a list of paths. Relative paths are
-- relative to the project root.

local utils = require("mesone.lib.utils")

local M = {}

M.kinds = { "cross_file", "native_file" }

-- Turns a setting value into a list of paths.
function M.to_list(value)
  local list = {}
  if type(value) == "table" then
    for _, path in ipairs(value) do
      path = vim.trim(tostring(path))
      if path ~= "" then
        table.insert(list, path)
      end
    end
  elseif type(value) == "string" then
    for path in value:gmatch("[^,]+") do
      path = vim.trim(path)
      if path ~= "" then
        table.insert(list, path)
      end
    end
  end
  return list
end

-- Turns a setting value into the string shown in the settings form.
function M.to_setting(value)
  return table.concat(M.to_list(value), ",")
end

local function _absolute(root, path)
  if vim.startswith(path, "/") or path:match("^%a:[/\\]") then
    return vim.fs.normalize(path)
  end
  return vim.fs.normalize(root .. "/" .. path)
end

-- The setup arguments for the machine files in the settings.
function M.setup_args(opts)
  local args = {}
  for _, kind in ipairs(M.kinds) do
    for _, path in ipairs(M.to_list(opts[kind])) do
      vim.list_extend(args, { "--" .. kind:gsub("_", "-"), path })
    end
  end
  return args
end

-- The machine files a build folder was set up with, as absolute paths, read
-- from meson-private/cmd_line.txt. Nil if the folder is not set up.
function M.read_build_folder(build_folder)
  local filename = build_folder .. "/meson-private/cmd_line.txt"
  if not utils.file_exists(filename) then
    return nil
  end
  local result = { cross_file = {}, native_file = {} }
  local in_properties = false
  for _, line in ipairs(vim.fn.readfile(filename)) do
    local section = line:match("^%s*%[(.+)%]%s*$")
    if section ~= nil then
      in_properties = section == "properties"
    elseif in_properties then
      local key, value = line:match("^%s*([%w_]+)%s*=%s*(.*)$")
      if result[key] ~= nil then
        for path in value:gmatch("'([^']*)'") do
          table.insert(result[key], vim.fs.normalize(path))
        end
      end
    end
  end
  return result
end

-- Whether the machine files in the settings differ from the ones the build
-- folder was set up with. Meson keeps them across a reconfigure, so a change
-- needs a wipe.
function M.differ(opts, root, build_folder)
  local current = M.read_build_folder(build_folder)
  if current == nil then
    return false
  end
  for _, kind in ipairs(M.kinds) do
    local wanted = vim.tbl_map(function(path)
      return _absolute(root, path)
    end, M.to_list(opts[kind]))
    if not vim.deep_equal(wanted, current[kind]) then
      return true
    end
  end
  return false
end

-- The settings for the machine files of a build folder, with paths inside
-- the project root made relative to it. Nil if the folder is not set up.
function M.settings_from_build_folder(root, build_folder)
  local current = M.read_build_folder(build_folder)
  if current == nil then
    return nil
  end
  local prefix = vim.fs.normalize(root) .. "/"
  local result = {}
  for _, kind in ipairs(M.kinds) do
    local paths = vim.tbl_map(function(path)
      return utils.remove_prefix(path, prefix)
    end, current[kind])
    result[kind] = table.concat(paths, ",")
  end
  return result
end

return M
