local t = require "testlib"

local function source(path)
  local handle = assert(io.open(path, "rb"))
  local value = assert(handle:read("*a")); handle:close(); return value
end

t.test("probe controller replaces the 501 stub with safe typed outcomes", function()
  local value = source("luasrc/controller/xc.lua")
  t.contains(value, 'require "xc.probe"')
  t.contains(value, 'disabled_node')
  t.contains(value, 'unsupported_node')
  t.contains(value, 'probe_instance:run(')
  t.eq(value:find('failure("not_implemented")', 1, true), nil)
end)

t.test("node list installs safe probe and local import templates", function()
  local nodes = source("luasrc/model/cbi/xc/nodes.lua")
  for _, path in ipairs({ "luasrc/view/xc/node_table.htm", "luasrc/view/xc/ping_latency.htm", "luasrc/view/xc/import.htm" }) do
    t.truthy(io.open(path, "rb"), "missing " .. path)
  end
  t.contains(nodes, 'nodes.template = "xc/node_table"')
  t.eq(nodes:find(', "_probe"', 1, true), nil)
  t.eq(nodes:find('template = "xc/ping"', 1, true), nil)
  t.contains(nodes, 'template = "xc/import"')
  t.eq(nodes:find("password", 1, true), nil); t.eq(nodes:find("raw_outbound", 1, true), nil)
end)

t.test("cached latency is a valid CBI value cell with constrained socket state", function()
  local value = source("luasrc/view/xc/ping_latency.htm")
  t.contains(value, "<%+cbi/valueheader%>")
  t.contains(value, "<%+cbi/valuefooter%>")
  t.contains(value, "data-xc-socket")
  t.contains(value, 'socket == "ok"')
  t.contains(value, 'socket == "fail"')
end)

t.test("node probe UI has a shared bounded queue and stale-run invalidation", function()
  local value = source("luasrc/view/xc/node_table.htm")
  t.contains(value, "probe_concurrency")
  t.contains(value, "runId")
  t.contains(value, "queue")
  t.contains(value, "Math.min(5")
  t.contains(value, "Math.max(1")
  t.contains(value, "textContent")
  t.eq(value:find("innerHTML", 1, true), nil)
  t.eq(value:find("192.168.6.1", 1, true), nil)
end)

t.test("local import requires explicit preview and confirm without subscription support", function()
  local value = source("luasrc/view/xc/import.htm")
  t.contains(value, "FileReader")
  t.contains(value, 'dispatcher.build_url("admin", "services", "xc", "import-preview")')
  t.contains(value, 'dispatcher.build_url("admin", "services", "xc", "import-commit")')
  t.contains(value, "confirm")
  t.contains(value, "textContent")
  t.eq(value:find("innerHTML", 1, true), nil)
  t.eq(value:find("subscription", 1, true), nil)
end)

t.test("Task 9 templates use LuCI's CSRF token and never substitute the auth session id", function()
  for _, path in ipairs({ "luasrc/view/xc/node_table.htm", "luasrc/view/xc/import.htm" }) do
    local value = source(path)
    t.contains(value, "<%=token%>")
    t.eq(value:find("authsession", 1, true), nil)
  end
end)

return true
