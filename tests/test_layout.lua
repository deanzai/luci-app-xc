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
  t.contains(read_file("Makefile"), "PKG_RELEASE:=19")
end)

t.test("runtime XC directory is not declared as an opkg conffile", function()
  local makefile = read_file("Makefile")
  t.eq(makefile:find("\n/etc/xc/\n", 1, true), nil,
    "opkg conffiles must contain files, not the runtime directory")
end)

t.test("package and translation versions stay aligned", function()
  t.contains(read_file("Makefile"), "PKG_PO_VERSION:=$(PKG_VERSION)-r$(PKG_RELEASE)")
end)

t.test("package pulls the GeoIP and GeoSite asset packages", function()
  local makefile = read_file("Makefile")
  t.contains(makefile, "+v2ray-geoip")
  t.contains(makefile, "+v2ray-geosite")
end)

t.test("repository attributes force package text to LF", function()
  t.contains(read_file(".gitattributes"), "* text=auto eol=lf")
end)

t.test("Linux package and gettext source files contain no carriage returns", function()
  local manifest = "tests/tmp/lf-files"
  local command = table.concat({
    "mkdir -p tests/tmp && find root scripts tests po luasrc",
    "-path 'tests/tmp' -prune -o -type f \\\(",
    "-path 'root/usr/bin/*' -o -path 'root/etc/init.d/*'",
    "-o -path 'root/etc/hotplug.d/*' -o -path 'root/etc/uci-defaults/*'",
    "-o -name '*.sh' -o -name '*.lua' -o -name '*.htm'",
    "-o -name '*.po' -o -name '*.pot' \\\) -print | sort > " .. manifest
  }, " ")
  assert(os.execute(command) == 0)

  local paths = { "Makefile" }
  local handle = assert(io.open(manifest, "r"))
  for path in handle:lines() do paths[#paths + 1] = path end
  handle:close()
  os.remove(manifest)

  for _, path in ipairs(paths) do
    t.eq(read_file(path):find("\r", 1, true), nil, path .. " must use LF line endings")
  end
end)

t.test("CI installs required runtimes and runs the complete host verification", function()
  local workflow = read_file(".github/workflows/build.yml")
  local aggregate = read_file("tests/run-host.sh")
  t.contains(workflow, "apt-get install -y lua5.1")
  t.contains(workflow, "lua5.1 -v")
  t.contains(workflow, "node --version")
  t.contains(workflow, "sh tests/run-host.sh")
  t.contains(workflow, "FEED_DIR: ${{ github.workspace }}/..")
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

t.test("init selects the installed Xray asset directory", function()
  local source = read_file("root/etc/init.d/xc")
  t.contains(source, "for asset_dir in /usr/share/xray /usr/share/v2ray")
  t.contains(source, '[ -f "$asset_dir/geosite.dat" ]')
  t.contains(source, '[ -f "$asset_dir/geoip.dat" ]')
  t.contains(source, "XRAY_LOCATION_ASSET=\"$asset_dir\"")
end)
