local M = {}

function M.call(name, ...)
  local target = { type = "call", ["function"] = name }
  for index, value in ipairs({ ... }) do target[index] = value end
  return target
end

return M
