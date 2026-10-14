local form = require("mesone.ui.form")

local default_settings = {
  build_folder = "build",
  build_type = "debug",
  cross_file = "",
  native_file = "",
  info_depth = 3,
  show_command_logs = false,
  auto_compile = true,
  dap_adapter = "gdb",
  auto_close_terminal = false,
  compile_before_run = false,
  lsp_compile_commands = false,
}

local M = {}

function M:new(opts)
  local o = { inner = opts or vim.deepcopy(default_settings), myform = nil }
  setmetatable(o, self)
  self.__index = self
  return o
end

function M:update(opts)
  self.inner = vim.tbl_deep_extend("force", self.inner, opts or {})
end

function M:get()
  return self.inner
end

function M:ui(on_changed)
  if self.myform == nil then
    self.myform = form:new({
      fields = {
        build_folder = {},
        build_type = {
          "plain",
          "debug",
          "debugoptimized",
          "release",
          "minsize",
          "custom",
        },
        cross_file = {},
        native_file = {},
        info_depth = {},
        show_command_logs = { true, false },
        auto_compile = { true, false },
        dap_adapter = {},
        auto_close_terminal = { true, false },
        compile_before_run = { true, false },
        lsp_compile_commands = { true, false },
      },
    })
  end
  self.myform:show("Mesone project settings", self.inner, function(conf)
    if conf ~= nil then
      self.inner = vim.deepcopy(conf)
      on_changed(conf)
    end
  end)
end

return M
