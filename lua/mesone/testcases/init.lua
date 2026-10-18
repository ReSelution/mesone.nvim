local runner = {}

function runner:new()
  local o = {}
  setmetatable(o, self)
  self.__index = self
  return o
end

function runner:name() end

-- Calls callback with the list of testcases, or with nil if the runner does
-- not know the program.
function runner:get_testcases(path, command, target_provider, callback) end

function runner:run(testsuite, callback) end

function runner:debug_arguments(testcase) end

return runner
