local job = require("plenary.job")
local runner = require("mesone.testcases.init")

local runner_name = "catch2"

local catch2_runner = runner:new()

local function _parse_testcases(path, result)
  if result.code ~= 0 then
    -- If there is an error is not catch2
    return nil
  end
  local success, tests = pcall(vim.json.decode, result.stdout, { luanil = { object = true, array = true } })

  if not success or not tests or not tests.listings or not tests.listings.tests then
    return nil
  end

  local test_list = {}
  for _, testcase in ipairs(tests.listings.tests) do
    -- Catch2 v2 uses "source-location", Catch2 v3 uses "sourceLocation"
    local loc = testcase["source-location"] or testcase["sourceLocation"] or {}
    local filename_rel = loc.filename or ""
    local filename = vim.fs.normalize(path .. "/" .. filename_rel)

    table.insert(test_list, {
      name = testcase.name,
      filename = filename,
      line = loc.line or 0,
      status = "unk",
      type = runner_name,
    })
  end

  return test_list
end

function catch2_runner:get_testcases(path, cmd, _, callback)
  local command = { cmd, "--list-tests", "--reporter", "json" }
  -- stderr stays closed: helpers of the program (e.g. the wineserver of a
  -- cross build run through wine) inherit it and keep it open for seconds
  -- after the program exits, and on_exit only fires once every pipe is closed.
  vim.system(
    command,
    { text = true, stderr = false },
    vim.schedule_wrap(function(result)
      callback(_parse_testcases(path, result))
    end)
  )
end

local function _catch2_status(totals)
  if totals.failed ~= 0 then
    return "fail"
  end
  if totals.skipped ~= 0 then
    return "skipped"
  end
  if totals.passed ~= 0 then
    return "run"
  end
  return "unk"
end

function catch2_runner:run(testsuite, callback, run_sync)
  run_sync = run_sync or false
  for _, testcase in ipairs(testsuite.test_list) do
    local my_job = job
      ---@diagnostic disable-next-line: missing-fields
      :new({
        command = table.concat(testsuite.cmd, ""),
        args = { "--reporter=json", testcase.name },
        on_exit = function(j, _)
          local stdout = table.concat(j:result(), "\n")
          local ok, test_result = pcall(vim.json.decode, stdout, { luanil = { object = true, array = true } })
          if not ok or not test_result then
            return
          end

          local totals = test_result["test-run"].totals["test-cases"]
          local status = _catch2_status(totals)

          local output = test_result["test-run"]["test-cases"][1].runs[1]["captured-stdout"] or ""
          local errors = test_result["test-run"]["test-cases"][1].runs[1]["captured-stderr"] or ""

          local assertions_failed = ""
          if status == "fail" then
            for _, run_path in ipairs(test_result["test-run"]["test-cases"][1].runs[1].path or {}) do
              for _, path in ipairs(run_path.path or {}) do
                if not path.status and path.kind == "assertion" then
                  local loc = path["source-location"] or path["sourceLocation"] or {}
                  assertions_failed = assertions_failed .. "assertion failed at line " .. (loc.line or 0) .. "\n"
                end
              end
            end
          end

          local test_list = {
            {
              name = testcase.name,
              status = status,
              output = output .. "\n" .. errors .. "\n" .. assertions_failed,
            },
          }

          callback({ name = testsuite.name, test_list = test_list })
        end,
      })
    if run_sync then
      my_job:sync()
    else
      my_job:start()
    end
  end
end

function catch2_runner:debug_arguments(testcase)
  return { testcase.test_list[1].name }
end

return { runner_name, catch2_runner }
