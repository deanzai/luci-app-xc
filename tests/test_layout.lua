local t = require "testlib"

local function read_file(path)
  local handle = assert(io.open(path, "rb"))
  local value = assert(handle:read("*a"))
  handle:close()
  return value
end

t.test("Makefile exists", function()
  t.truthy(io.open("Makefile", "r"), "Makefile is missing")
end)

for _, path in ipairs({
  "root/etc/config/xc", "root/etc/init.d/xc",
  "root/usr/bin/xc", "luasrc/controller/xc.lua"
}) do
  t.test(path .. " exists", function()
    t.truthy(io.open(path, "r"), path .. " is missing")
  end)
end

t.test("init lifecycle records only fixed start and stop events best-effort", function()
  local source = read_file("root/etc/init.d/xc")
  local started = "/usr/bin/xc log-event service_started >/dev/null 2>&1 || true"
  local stopped = "/usr/bin/xc log-event service_stopped >/dev/null 2>&1 || true"
  t.contains(source, started)
  t.contains(source, stopped)
  t.truthy(source:find("procd_close_instance", 1, true) < source:find(started, 1, true))
  local stop_body = assert(source:match("stop_service%(%) {%s*(.-)%s*}"))
  t.contains(stop_body, stopped)
  t.eq(source:find('log%-event "%$', 1), nil)
end)
