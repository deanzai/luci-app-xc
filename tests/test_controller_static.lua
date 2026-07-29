local t = require "testlib"

local function read_file(path)
  local handle = assert(io.open(path, "r"))
  local value = assert(handle:read("*a"))
  handle:close()
  return value
end

local source = read_file("luasrc/controller/xc.lua")

local function route(path)
  return table.concat(path, '\", \"')
end

t.test("controller root opens settings while status remains a JSON API", function()
  t.contains(source, 'alias("admin", "services", "xc", "settings")')
  t.eq(source:find('alias("admin", "services", "xc", "status")', 1, true), nil)
  t.contains(source, 'entry({ "admin", "services", "xc", "status" }, call("action_status"))')
end)

t.test("controller registers the authenticated XC page and action routes", function()
  for _, path in ipairs({
    { "admin", "services", "xc" },
    { "admin", "services", "xc", "settings" },
    { "admin", "services", "xc", "nodes" },
    { "admin", "services", "xc", "node" },
    { "admin", "services", "xc", "log" },
    { "admin", "services", "xc", "status" },
    { "admin", "services", "xc", "probe" },
    { "admin", "services", "xc", "test-current" },
    { "admin", "services", "xc", "switch" },
    { "admin", "services", "xc", "rollback" },
    { "admin", "services", "xc", "import-preview" },
    { "admin", "services", "xc", "import-commit" },
    { "admin", "services", "xc", "get-log" },
    { "admin", "services", "xc", "clear-log" }
  }) do
    t.contains(source, route(path), "missing authenticated route " .. table.concat(path, "/"))
  end
end)

t.test("controller marks every mutating or body-consuming action POST only", function()
  for _, action in ipairs({ "probe", "test-current", "switch", "rollback", "import-preview", "import-commit", "clear-log" }) do
    local declaration = 'post_entry({ "admin", "services", "xc", "' .. action .. '" }'
    t.contains(source, declaration, action .. " must use the POST-only route helper")
  end
  t.contains(source, 'target.post = true')
  t.contains(source, 'http.getenv("REQUEST_METHOD")')
  t.contains(source, 'method_not_allowed')
end)

t.test("controller validates UCI section IDs and bounds request bodies before parsing", function()
  t.contains(source, 'schema.safe_section_id')
  t.contains(source, 'pcall(adapters.uci.get_node, section_id)')
  t.contains(source, 'REQUEST_BODY_MAX = 512 * 1024')
  t.contains(source, 'http.getenv("CONTENT_LENGTH")')
  t.contains(source, 'if length_text == nil then failure("validation_failed")')
  t.contains(source, 'http.content()')
  t.contains(source, 'request_too_large')
end)

t.test("controller calls Lua runtime and importer APIs without shell interpolation", function()
  t.contains(source, 'require "xc.platform"')
  t.contains(source, 'require "xc.runtime"')
  t.contains(source, 'require "xc.importer"')
  t.contains(source, 'importer.parse(')
  t.contains(source, 'runtime_instance:switch(')
  t.contains(source, 'runtime_instance:rollback()')
  t.eq(source:find("os.execute", 1, true), nil)
  t.eq(source:find("io.popen", 1, true), nil)
  t.eq(source:find("luci.sys", 1, true), nil)
  t.contains(source, 'http.formvalue("level")')
end)

t.test("controller commits imported nodes atomically and emits whitelisted status", function()
  t.contains(source, 'importer.deduplicate(')
  t.contains(source, 'schema.validate(node)')
  t.contains(source, 'adapters.uci.stage_nodes(nodes)')
  t.contains(source, 'adapters.uci.revert()')
  t.contains(source, 'adapters.uci.commit()')
  t.contains(source, 'warnings = append_warnings(parsed.warnings, warnings)')
  t.contains(source, 'active_section = status.active_node')
  t.contains(source, 'active_name = status.node and status.node.name')
  t.contains(source, 'active_protocol = status.node and status.node.protocol')
  t.contains(source, 'listen_ip = status.listen and status.listen.address')
  t.contains(source, 'lock_state = status.lock')
  t.eq(source:find('raw_outbound', 1, true), nil)
end)
