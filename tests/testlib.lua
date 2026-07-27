local tests = {}
local failures = {}

local function fail(message)
  error(message, 2)
end

local function stringify(value)
  return tostring(value)
end

local M = {}

function M.test(name, fn)
  tests[#tests + 1] = { name = name, fn = fn }
end

function M.eq(actual, expected, message)
  if actual ~= expected then
    fail(message or ("expected " .. stringify(expected) .. ", got " .. stringify(actual)))
  end
end

function M.truthy(value, message)
  if not value then
    fail(message or "expected truthy value")
  end
  return value
end

function M.contains(haystack, needle, message)
  if type(haystack) ~= "string" or not haystack:find(needle, 1, true) then
    fail(message or ("expected " .. stringify(haystack) .. " to contain " .. stringify(needle)))
  end
end

function M.finish()
  for _, test in ipairs(tests) do
    local ok, err = pcall(test.fn)
    if ok then
      io.stdout:write("PASS " .. test.name .. "\n")
    else
      failures[#failures + 1] = { name = test.name, error = err }
      io.stderr:write("FAIL " .. test.name .. ": " .. err .. "\n")
    end
  end

  if #failures > 0 then
    io.stderr:write(#failures .. " test failure(s)\n")
    return false
  end

  io.stdout:write(#tests .. " test(s) passed\n")
  return true
end

return M
