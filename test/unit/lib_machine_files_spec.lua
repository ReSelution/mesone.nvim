---@diagnostic disable: undefined-field
local machine_files = require("mesone.lib.machine_files")

local function make_build_folder(cmd_line)
  local folder = vim.fs.normalize(vim.fn.tempname())
  vim.fn.mkdir(folder .. "/meson-private", "p")
  vim.fn.writefile(vim.split(cmd_line, "\n"), folder .. "/meson-private/cmd_line.txt")
  return folder
end

describe("machine_files", function()
  it("should split comma-separated settings and lists", function()
    assert.are.same({ "a.ini", "b.ini" }, machine_files.to_list(" a.ini , b.ini,"))
    assert.are.same({ "a.ini" }, machine_files.to_list({ "a.ini", "" }))
    assert.are.same({}, machine_files.to_list(""))
    assert.are.same({}, machine_files.to_list(nil))
    assert.are.equal("a.ini,b.ini", machine_files.to_setting({ "a.ini", "b.ini" }))
  end)

  it("should build setup arguments", function()
    local args = machine_files.setup_args({ cross_file = "x.ini", native_file = { "n1.ini", "n2.ini" } })
    assert.are.same({ "--cross-file", "x.ini", "--native-file", "n1.ini", "--native-file", "n2.ini" }, args)
    assert.are.same({}, machine_files.setup_args({ cross_file = "", native_file = "" }))
  end)

  it("should read the machine files of a build folder", function()
    local folder = make_build_folder(
      "[options]\nbuildtype = release\n\n[properties]\nnative_file = ['/p/cross/a.ini', '/p/cross/b.ini']\n"
    )
    local got = machine_files.read_build_folder(folder)
    assert.are.same({ cross_file = {}, native_file = { "/p/cross/a.ini", "/p/cross/b.ini" } }, got)
    assert.are.same(
      { cross_file = "", native_file = "cross/a.ini,cross/b.ini" },
      machine_files.settings_from_build_folder("/p", folder)
    )
    assert.is_nil(machine_files.read_build_folder(folder .. "/missing"))
  end)

  it("should detect changed machine files", function()
    local folder = make_build_folder("[options]\n\n[properties]\ncross_file = ['/p/cross/win.ini']\n")
    assert.is_false(machine_files.differ({ cross_file = "cross/win.ini", native_file = "" }, "/p", folder))
    assert.is_false(machine_files.differ({ cross_file = "/p/cross/win.ini", native_file = "" }, "/p", folder))
    assert.is_true(machine_files.differ({ cross_file = "", native_file = "" }, "/p", folder))
    assert.is_true(machine_files.differ({ cross_file = "", native_file = "cross/win.ini" }, "/p", folder))
    assert.is_false(machine_files.differ({ cross_file = "x.ini" }, "/p", folder .. "/missing"))
  end)

  it("should forget the machine files of a build folder but keep its options", function()
    local folder = make_build_folder(
      "[options]\nbuildtype = release\n\n[properties]\nnative_file = ['/p/a.ini']\ncross_file = ['/p/b.ini']\n"
    )
    machine_files.forget_in_build_folder(folder)
    assert.are.same({ cross_file = {}, native_file = {} }, machine_files.read_build_folder(folder))
    local content = table.concat(vim.fn.readfile(folder .. "/meson-private/cmd_line.txt"), "\n")
    assert.is_truthy(content:find("buildtype = release", 1, true))
  end)

  it("should find the .ini files of a project outside of build folders", function()
    local root = vim.fs.normalize(vim.fn.tempname())
    for _, folder in ipairs({ "cross", "build/meson-info", ".git", "subprojects/dep" }) do
      vim.fn.mkdir(root .. "/" .. folder, "p")
    end
    for _, file in ipairs({ "cross/a.ini", "cross/b.ini", "build/c.ini", ".git/d.ini", "subprojects/dep/e.ini", "f.txt" }) do
      vim.fn.writefile({}, root .. "/" .. file)
    end
    local got = vim.tbl_filter(function(path)
      return not vim.startswith(path, "/")
    end, machine_files.candidates(root, "cross_file", 3))
    assert.are.same({ "cross/a.ini", "cross/b.ini" }, got)
  end)
end)
