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

t.test("package release is bumped for the replacement IPK", function()
  t.contains(read_file("Makefile"), "PKG_RELEASE:=2")
end)

t.test("CI installs required runtimes and runs the complete host verification", function()
  local workflow = read_file(".github/workflows/build.yml")
  local aggregate = read_file("tests/run-host.sh")
  t.contains(workflow, "apt-get install -y lua5.1")
  t.contains(workflow, "lua5.1 -v")
  t.contains(workflow, "node --version")
  t.contains(workflow, "sh tests/run-host.sh")
  t.eq(workflow:find("if command -v lua5.1", 1, true), nil)
  t.contains(aggregate, '"$lua51" tests/run.lua')
  t.contains(aggregate, "node tests/test_task9_ui.js")
  t.contains(aggregate, "node tests/test_log_ui.js")
  t.contains(aggregate, "node tests/test_status.js")
  t.contains(aggregate, "sh tests/test_check_package.sh")
  t.contains(aggregate, "sh scripts/check-package.sh")
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
