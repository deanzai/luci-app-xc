local t = require "testlib"

local function read_file(path)
  local handle = assert(io.open(path, "rb"))
  local value = assert(handle:read("*a"))
  handle:close()
  return value
end

t.test("access endpoints are explicit and apply is POST-only", function()
  local source = read_file("luasrc/controller/xc.lua")
  t.contains(source, 'entry({ "admin", "services", "xc", "access" }, form("xc/access"), _("Access control"), 27)')
  t.contains(source, 'entry({ "admin", "services", "xc", "access-status" }, action_target("action_access_status"))')
  t.contains(source, 'post_entry({ "admin", "services", "xc", "access-apply" }, "action_access_apply")')
  t.contains(source, "runtime_instance.apply_access")
  t.contains(source, "request_body(true)")
end)

t.test("access failure response does not commit UCI directly", function()
  local source = read_file("luasrc/controller/xc.lua")
  local start = assert(source:find("function action_access_apply", 1, true))
  local tail = source:find("function ", start + 10, true)
  local body = source:sub(start, (tail or #source + 1) - 1)
  t.eq(body:find("adapters.uci.commit", 1, true), nil)
  t.contains(body, "access_validation_failed")
end)

return true
