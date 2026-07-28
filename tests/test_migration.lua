local t = require "testlib"
local schema = require "xc.schema"

local function read_file(path)
  local handle = assert(io.open(path, "rb"))
  local value = assert(handle:read("*a"))
  handle:close()
  return value
end

local function load_cli()
  package.loaded["xc.cli"] = nil
  return require "xc.cli"
end

local function legacy_nodes()
  local nodes = {}
  for index = 1, 9 do
    nodes[tostring(index)] = {
      name = "Reality " .. index, protocol = "vless", address = "node" .. index .. ".invalid",
      port = 443, uuid = string.format("11111111-1111-1111-1111-%012d", index),
      security = "reality", serverName = "cover.invalid", publicKey = "public-key-" .. index,
      shortId = string.format("%08x", index), fingerprint = "chrome", flow = "xtls-rprx-vision", network = "tcp"
    }
  end
  nodes["10"] = { name = "SOCKS 10", protocol = "socks5", address = "127.0.0.1", port = 1010, username = "user10", password = "password10" }
  nodes["11"] = { name = "SOCKS 11", protocol = "naiveproxy", address = "127.0.0.1", port = 1011, username = "user11", password = "password11" }
  return { reality_uk_id = "9", nodes = nodes }
end

local function json_stringify(value)
  if type(value) == "string" then return '"' .. value:gsub('\\', '\\\\'):gsub('"', '\\"') .. '"' end
  if type(value) == "boolean" then return value and "true" or "false" end
  if type(value) == "number" then return tostring(value) end
  if type(value) ~= "table" then return "null" end
  local keys, output = {}, {}
  for key in pairs(value) do keys[#keys + 1] = key end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  for _, key in ipairs(keys) do output[#output + 1] = json_stringify(tostring(key)) .. ":" .. json_stringify(value[key]) end
  return "{" .. table.concat(output, ",") .. "}"
end

local function fixture(options)
  options = options or {}
  local legacy = legacy_nodes()
  local state = { globals = {}, nodes = {}, commits = 0, reverts = 0, events = {}, output = {} }
  local staged
  local uci = {
    get_global = function() return staged and staged.global or state.globals[1] end,
    get_node = function(id) return (staged and staged.by_id or state.nodes)[id] end,
    list_nodes = function()
      local values = {}
      for _, node in pairs(staged and staged.by_id or state.nodes) do values[#values + 1] = node end
      return values
    end,
    stage_replace = function(global, nodes)
      state.events[#state.events + 1] = "stage_replace"
      if options.stage_throw then error("password=stage-secret") end
      local by_id = {}
      for _, node in ipairs(nodes) do
        local normalized, err = schema.normalize(node)
        if not normalized then return nil, err end
        by_id[normalized.id] = normalized
      end
      staged = { global = global, by_id = by_id }
      return true
    end,
    stage_nodes = function(nodes)
      state.events[#state.events + 1] = "stage_nodes"
      if options.stage_throw then error("password=stage-secret") end
      staged = { global = state.globals[1], by_id = {} }
      for id, node in pairs(state.nodes) do staged.by_id[id] = node end
      for _, node in ipairs(nodes) do staged.by_id[node.id] = node end
      return true
    end,
    set_active = function(id) staged.global.active_node = id; return true end,
    clear_active = function() staged.global.active_node = nil; return true end,
    commit = function()
      state.commits = state.commits + 1
      state.events[#state.events + 1] = "commit"
      if options.commit_fail then return false end
      state.globals, state.nodes, staged = { staged.global }, staged.by_id, nil
      return true
    end,
    revert = function() state.reverts = state.reverts + 1; staged = nil; return true end
  }
  local runtime = {
    render = function(_, section, path)
      state.events[#state.events + 1] = "render:" .. tostring(section) .. ":" .. path
      if options.render_fail then return { ok = false, code = "validation_failed", message = "candidate rejected" } end
      return { ok = true, code = "rendered", message = "configuration rendered" }
    end,
    status = function() return { ok = true, code = "status", message = "runtime status", password = "must-not-print" } end,
    switch = function(_, id) return { ok = id ~= "fail", code = id ~= "fail" and "switched" or "health_failed", message = "safe" } end,
    rollback = function() return { ok = true, code = "rolled_back", message = "safe" } end,
    test_current = function() return { ok = true, code = "test_passed", message = "safe" } end,
    recover_pending = function() state.events[#state.events + 1] = "recover"; return { ok = true, code = "recovered", message = "safe" } end
  }
  local deps = {
    runtime = runtime, uci = uci,
    importer = require "xc.importer",
    json = { parse = function(text) if text == "legacy-json" then return legacy end; return options.import_value end, stringify = json_stringify },
    fs = { read = function(path)
      if path:match("nodes%.json$") then return "legacy-json" end
      if path:match("current$") then return "1\n" end
      if path:match("complete$") then if options.missing_complete then return nil, "missing" end; return "" end
      if path == "/tmp/import" then return options.import_text or "{}" end
      return nil, "missing"
    end },
    exec = { run = function(argv)
      state.events[#state.events + 1] = "xray:test"
      return options.xray_fail ~= true
    end },
    output = function(value) state.output[#state.output + 1] = value end
  }
  state.deps = deps
  return state
end

t.test("migrates captured 1 through 11 legacy shape atomically with one global", function()
  local state = fixture()
  local code = load_cli().main({ "migrate-legacy", "/etc/xc/legacy-backup-1" }, state.deps)
  t.eq(code, 0)
  t.eq(#state.globals, 1)
  local count = 0
  for _, node in pairs(state.nodes) do
    count = count + 1
    t.eq(node.reality_uk_id, nil)
    t.truthy(schema.normalize(node))
  end
  t.eq(count, 11)
  t.eq(state.globals[1].active_node, assert(state.deps.importer.parse_legacy(legacy_nodes()))[1].id)
  t.eq(state.commits, 1)
  t.truthy(state.events[1] == "recover" and state.events[2] == "stage_replace" and state.events[3]:match("^render:") and state.events[4] == "xray:test" and state.events[5] == "commit")
end)

t.test("migration requires a complete backup marker before staging", function()
  local state = fixture({ missing_complete = true })
  t.eq(load_cli().main({ "migrate-legacy", "/etc/xc/legacy-backup-1" }, state.deps), 1)
  t.eq(#state.events, 0)
  t.eq(state.commits, 0)
end)

t.test("legacy migration is idempotent", function()
  local state = fixture()
  local cli = load_cli()
  t.eq(cli.main({ "migrate-legacy", "/etc/xc/legacy-backup-1" }, state.deps), 0)
  local first = state.globals[1].active_node
  t.eq(cli.main({ "migrate-legacy", "/etc/xc/legacy-backup-1" }, state.deps), 0)
  local count = 0
  for _ in pairs(state.nodes) do count = count + 1 end
  t.eq(count, 11)
  t.eq(state.globals[1].active_node, first)
end)

t.test("migration validation failure reverts without committing", function()
  local state = fixture({ render_fail = true })
  local code = load_cli().main({ "migrate-legacy", "/etc/xc/legacy-backup-1" }, state.deps)
  t.eq(code, 1)
  t.eq(state.commits, 0)
  t.eq(state.reverts, 1)
  t.eq(#state.globals, 0)
end)

t.test("migration Xray rejection reverts without committing", function()
  local state = fixture({ xray_fail = true })
  t.eq(load_cli().main({ "migrate-legacy", "/etc/xc/legacy-backup-1" }, state.deps), 1)
  t.eq(state.commits, 0)
  t.eq(state.reverts, 1)
end)

t.test("adapter exceptions revert staged imports and never escape or leak", function()
  local migration = fixture({ stage_throw = true })
  local called, code = pcall(load_cli().main, { "migrate-legacy", "/etc/xc/legacy-backup-1" }, migration.deps)
  t.eq(called, true)
  t.eq(code, 1)
  t.eq(migration.reverts, 1)
  t.eq(table.concat(migration.output):find("stage%-secret"), nil)

  local candidate = { nodes = { one = { name = "SOCKS", protocol = "socks5", address = "127.0.0.1", port = 1080, username = "user", password = "pass" } } }
  local imported = fixture({ stage_throw = true, import_value = candidate })
  called, code = pcall(load_cli().main, { "import", "/tmp/import" }, imported.deps)
  t.eq(called, true)
  t.eq(code, 1)
  t.eq(imported.reverts, 1)
end)

t.test("CLI dispatch has stable exit codes and secret-safe JSON", function()
  local state = fixture()
  local cli = load_cli()
  t.eq(cli.main({}, state.deps), 2)
  t.eq(cli.main({ "switch" }, state.deps), 2)
  t.eq(cli.main({ "switch", "bad;id" }, state.deps), 2)
  t.eq(cli.main({ "render", "--output" }, state.deps), 2)
  t.eq(cli.main({ "render", "--output", "relative.json" }, state.deps), 2)
  t.eq(cli.main({ "import-preview", "relative.json" }, state.deps), 2)
  t.eq(cli.main({ "unknown" }, state.deps), 2)
  t.eq(cli.main({ "status" }, state.deps), 0)
  t.eq(cli.main({ "switch", "fail" }, state.deps), 1)
  t.eq(cli.main({ "rollback" }, state.deps), 0)
  t.eq(cli.main({ "test" }, state.deps), 0)
  t.eq(cli.main({ "render", "--output", "/tmp/config.json" }, state.deps), 0)
  t.eq(cli.main({ "recover-pending" }, state.deps), 0)
  local joined = table.concat(state.output, "\n")
  t.eq(joined:find("must%-not%-print"), nil)
  t.contains(joined, '"ok"')
end)

t.test("import preview never writes and import stages and commits once", function()
  local candidate = {
    nodes = { one = { name = "SOCKS", protocol = "socks5", address = "127.0.0.1", port = 1080, username = "private-user", password = "private-pass" } }
  }
  local preview = fixture({ import_value = candidate })
  local cli = load_cli()
  t.eq(cli.main({ "import-preview", "/tmp/import" }, preview.deps), 0)
  t.eq(#preview.events, 0)
  local preview_json = table.concat(preview.output)
  t.eq(preview_json:find("private%-pass"), nil)
  t.contains(preview_json, '"count":1')
  t.contains(preview_json, '"protocol":"socks"')
  local committed = fixture({ import_value = candidate })
  t.eq(cli.main({ "import", "/tmp/import" }, committed.deps), 0)
  t.eq(committed.commits, 1)
  t.eq(committed.events[1], "recover")
  t.eq(committed.events[2], "stage_nodes")
end)

t.test("lifecycle files contain guarded recovery, takeover, and bounded backup contracts", function()
  local init = read_file("root/etc/init.d/xc")
  t.contains(init, "/usr/bin/xc recover-pending")
  t.truthy(init:find("recover%-pending") < init:find("render %-%-output"))
  t.contains(init, "procd_set_param command /usr/bin/xray run -c /var/etc/xc/config.json")
  t.contains(init, "procd_set_param respawn 3600 5 5")
  t.contains(init, "procd_add_reload_trigger xc network")
  local hotplug = read_file("root/etc/hotplug.d/iface/95-xc")
  t.contains(hotplug, '"$INTERFACE" = "lan"')
  t.contains(hotplug, '"$ACTION" = "ifup"')
  t.contains(hotplug, '"$ACTION" = "ifupdate"')
  local defaults = read_file("root/etc/uci-defaults/luci-xc")
  t.truthy(defaults:find("migrate%-legacy") < defaults:find("xc%-xray disable"))
  t.truthy(defaults:find("render %-%-output") < defaults:find("xc%-xray disable"))
  t.contains(defaults, '[ -f "$candidate/nodes.json" ] || continue')
  t.contains(defaults, "backup_limit=256")
  t.contains(defaults, "backup_overflow=1")
  t.contains(defaults, '[ "$backup_overflow" = "0" ] || exit 1')
  t.contains(defaults, "backup_candidates=0")
  t.contains(defaults, '[ "$backup_candidates" -gt "0" ] || exit 0')
  t.contains(defaults, "mktemp")
  t.contains(defaults, 'sort -r "$backup_list"')
  t.contains(defaults, "*-*-*|-*|*-")
  t.contains(defaults, 'case "$backup_timestamp" in')
  t.contains(defaults, '0|[1-9]*) ;;')
  t.contains(defaults, 'case "$backup_suffix" in')
  t.contains(defaults, '[1-9]) ;;')
  t.contains(defaults, "printf '%020s %020s %s\\n'")
  t.contains(defaults, "read -r backup_timestamp backup_suffix backup")
  t.eq(defaults:find("for backup in $(", 1, true), nil)
  t.contains(defaults, "migration_succeeded=1")
  t.truthy(defaults:find("migrate%-legacy") < defaults:find("migration_succeeded=1"))
  t.truthy(defaults:find('"$migration_succeeded" = "1"', 1, true) < defaults:find("xc%-xray disable"))
  local makefile = read_file("Makefile")
  for _, name in ipairs({ "nodes.json", "current", "config.json", "config.previous", "current.previous" }) do t.contains(makefile, name) end
  t.contains(makefile, "legacy-backup-$$(date +%s)")
  t.contains(makefile, "/etc/init.d/xc-xray")
  t.contains(makefile, '[ -n "$${IPKG_INSTROOT}" ] && exit 0')
  t.contains(makefile, '[ -f /etc/xc/nodes.json ] || exit 0')
  t.contains(makefile, 'touch "$$backup/complete"')
  t.eq(makefile:find("$$$$backup", 1, true), nil)
  t.eq(makefile:find("cp %-r"), nil)
  t.eq(makefile:find("find $$backup", 1, true), nil)
end)
