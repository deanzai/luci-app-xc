local t = require "testlib"
local schema = require "xc.schema"
local MIGRATION_CANDIDATE = "/var/etc/xc/migration-candidate.json"
local MIGRATION_MARKER = "/etc/xc/migration-complete"
local TAKEOVER_MARKER = "/etc/xc/takeover-complete"

local function read_file(path)
  local handle = assert(io.open(path, "rb"))
  local value = assert(handle:read("*a"))
  handle:close()
  return value
end

local function write_file(path, value)
  local handle = assert(io.open(path, "wb"))
  assert(handle:write(value))
  handle:close()
end

local function command_output(command)
  local output = "tests/tmp/command-output"
  assert(os.execute(command .. " >" .. output) == 0)
  local value = read_file(output)
  os.remove(output)
  return value:gsub("%s+$", "")
end

local function make_script(name)
  local source = read_file("Makefile")
  local marker = "define Package/$(PKG_NAME)/" .. name
  local first = source:find(marker, 1, true)
  if not first then return nil end
  local body_start = assert(source:find("\n", first, true)) + 1
  local body_end = assert(source:find("\nendef", body_start, true)) - 1
  return source:sub(body_start, body_end):gsub("%$%$", "$")
end

local function replace_plain(value, old, new)
  local output, offset = {}, 1
  while true do
    local first, last = value:find(old, offset, true)
    if not first then output[#output + 1] = value:sub(offset); break end
    output[#output + 1] = value:sub(offset, first - 1)
    output[#output + 1] = new
    offset = last + 1
  end
  return table.concat(output)
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
  local files = options.files or {}
  if options.marker then files[MIGRATION_MARKER] = options.marker end
  local state = { globals = {}, nodes = {}, commits = 0, reverts = 0, events = {}, output = {}, files = files }
  local staged
  local uci = {
    get_global = function() if options.global_throw then error("global-secret") end; return staged and staged.global or state.globals[1] end,
    get_node = function(id)
      local node = (staged and staged.by_id or state.nodes)[id]
      return node, node and "ok" or "missing"
    end,
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
      if options.commit_throw then error("password=commit-secret") end
      if options.commit_fail then return false, options.commit_outcome or "pre_commit_failed" end
      if options.commit_outcome == "commit_unknown" then
        if options.unknown_committed then state.globals, state.nodes, staged = { staged.global }, staged.by_id, nil end
        return false, "commit_unknown"
      end
      state.globals, state.nodes, staged = { staged.global }, staged.by_id, nil
      return true, options.commit_outcome or "committed"
    end,
    revert = function() state.reverts = state.reverts + 1; staged = nil; return true end
  }
  local runtime = {
    render = function(_, section, path)
      state.events[#state.events + 1] = "render:" .. tostring(section) .. ":" .. path
      files[path] = "candidate"
      if options.render_fail then return { ok = false, code = "validation_failed", message = "candidate rejected" } end
      return { ok = true, code = "rendered", message = "configuration rendered" }
    end,
    exclusive = function(_, operation, callback)
      state.events[#state.events + 1] = "lock:" .. tostring(operation)
      local called, value = pcall(callback, {
        render = function(section, path)
          state.events[#state.events + 1] = "render:" .. tostring(section) .. ":" .. path
          files[path] = "candidate"
          if options.render_fail then return { ok = false, code = "validation_failed", message = "candidate rejected" } end
          return { ok = true, code = "rendered", message = "configuration rendered" }
        end,
        write = function(path, content)
          state.events[#state.events + 1] = "marker"
          if options.marker_write_fail then return false end
          files[path] = content
          return true
        end
      })
      state.events[#state.events + 1] = "unlock:" .. tostring(operation)
      if not called then return { ok = false, code = "internal_error", message = "runtime operation failed" } end
      return value
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
      if options.read_throw and path == MIGRATION_MARKER then error("read-secret") end
      if files[path] ~= nil then return files[path] end
      if path:match("nodes%.json$") then return "legacy-json" end
      if path:match("current$") then return "1\n" end
      if path:match("/complete$") then if options.missing_complete then return nil, "missing" end; return "" end
      if path == "/tmp/import" then return options.import_text or "{}" end
      return nil, "missing"
    end,
    remove = function(path)
      state.events[#state.events + 1] = "remove:" .. path
      if options.remove_fail then return false end
      files[path] = nil
      return true
    end },
    exec = { run = function(argv, deadline)
      state.events[#state.events + 1] = "xray:test"
      state.xray_deadline = deadline
      return options.xray_fail ~= true
    end },
    now = function() if options.now_throw then error("clock-secret") end; return 123 end,
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
  local joined = table.concat(state.events, "|")
  t.contains(joined, "lock:migration|stage_replace|render:")
  t.contains(joined, "xray:test|commit|marker|remove:" .. MIGRATION_CANDIDATE .. "|unlock:migration")
  t.eq(state.xray_deadline, 153)
  t.contains(state.files[MIGRATION_MARKER], "xc-migration-v1\nlegacy-backup-1\n14\n")
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
  state.globals[1].health_url = "https://custom.invalid/"
  state.nodes.custom = { id = "custom", name = "customized" }
  local stages = 0
  for _, event in ipairs(state.events) do if event == "stage_replace" then stages = stages + 1 end end
  local commits = state.commits
  t.eq(cli.main({ "migrate-legacy", "/etc/xc/legacy-backup-1" }, state.deps), 0)
  t.eq(state.commits, commits)
  t.eq(state.globals[1].health_url, "https://custom.invalid/")
  t.truthy(state.nodes.custom)
  local later_stages = 0
  for _, event in ipairs(state.events) do if event == "stage_replace" then later_stages = later_stages + 1 end end
  t.eq(later_stages, stages)
  local count = 0
  for _ in pairs(state.nodes) do count = count + 1 end
  t.eq(count, 12)
  t.eq(state.globals[1].active_node, first)
end)

t.test("legacy migration never replaces an established XC configuration without a marker", function()
  local state = fixture()
  state.globals[1] = { enabled = "1", active_node = "custom", health_url = "https://custom.invalid/" }
  state.nodes.custom = { id = "custom", name = "customized", enabled = true }
  t.eq(load_cli().main({ "migrate-legacy", "/etc/xc/legacy-backup-1" }, state.deps), 0)
  t.eq(state.commits, 0)
  t.eq(state.reverts, 0)
  t.eq(state.globals[1].active_node, "custom")
  t.truthy(state.nodes.custom)
  t.eq(table.concat(state.events, "|"):find("stage_replace", 1, true), nil)
  t.contains(state.files[MIGRATION_MARKER], "xc-migration-v1\nlegacy-backup-1\n14\n")
end)

t.test("established XC adoption fails closed when its source marker cannot be written", function()
  local state = fixture({ marker_write_fail = true })
  state.globals[1] = { enabled = "0", active_node = "custom" }
  state.nodes.custom = { id = "custom", name = "customized", enabled = true }
  t.eq(load_cli().main({ "migrate-legacy", "/etc/xc/legacy-backup-1" }, state.deps), 1)
  t.eq(state.commits, 0)
  t.eq(state.reverts, 0)
  t.eq(state.files[MIGRATION_MARKER], nil)
end)

t.test("migration removes its bounded candidate on every terminal path", function()
  for _, case in ipairs({
    { name = "success" },
    { name = "render", render_fail = true },
    { name = "xray", xray_fail = true },
    { name = "commit", commit_fail = true },
    { name = "marker", marker_write_fail = true }
  }) do
    local state = fixture(case)
    load_cli().main({ "migrate-legacy", "/etc/xc/legacy-backup-1" }, state.deps)
    t.eq(state.files[MIGRATION_CANDIDATE], nil, case.name)
    local joined = table.concat(state.events, "|")
    t.contains(joined, "remove:" .. MIGRATION_CANDIDATE, case.name)
    t.truthy(joined:find("remove:" .. MIGRATION_CANDIDATE, 1, true) < joined:find("unlock:migration", 1, true), case.name)
    if case.render_fail or case.xray_fail or case.commit_fail then t.truthy(state.reverts >= 1, case.name) end
  end
end)

t.test("migration adapter exceptions still clean stale candidate before unlock", function()
  for _, case in ipairs({
    { name = "read", read_throw = true },
    { name = "global", global_throw = true },
    { name = "clock", now_throw = true }
  }) do
    case.files = { [MIGRATION_CANDIDATE] = "stale-candidate" }
    local state = fixture(case)
    local called, code = pcall(load_cli().main, { "migrate-legacy", "/etc/xc/legacy-backup-1" }, state.deps)
    t.eq(called, true, case.name)
    t.eq(code, 1, case.name)
    t.eq(state.files[MIGRATION_CANDIDATE], nil, case.name)
    local joined = table.concat(state.events, "|")
    t.truthy(joined:find("remove:" .. MIGRATION_CANDIDATE, 1, true) < joined:find("unlock:migration", 1, true), case.name)
  end
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

t.test("CLI log-event accepts only fixed lifecycle events", function()
  local state = fixture()
  local recorded = {}
  state.deps.runtime.record_event = function(_, message, fields, level)
    recorded[#recorded + 1] = { message = message, fields = fields, level = level }
    return true
  end
  local cli = load_cli()
  t.eq(cli.main({ "log-event", "service_started" }, state.deps), 0)
  t.eq(cli.main({ "log-event", "service_stopped" }, state.deps), 0)
  t.eq(#recorded, 2)
  t.eq(recorded[1].message, "service started")
  t.eq(recorded[2].message, "service stopped")
  t.eq(next(recorded[1].fields), nil)
  t.eq(next(recorded[2].fields), nil)
  t.eq(recorded[1].level, "info")
  t.eq(recorded[2].level, "info")

  for _, argv in ipairs({
    { "log-event", "service_restarted" },
    { "log-event", "service_started", "extra" },
    { "log-event" }
  }) do
    t.eq(cli.main(argv, state.deps), 2)
  end
  t.eq(#recorded, 2)
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

t.test("CLI keeps committed imports when post-commit hardening reports a warning", function()
  local candidate = {
    nodes = { one = { name = "SOCKS", protocol = "socks5", address = "127.0.0.1", port = 1080 } }
  }
  local state = fixture({ import_value = candidate, commit_outcome = "committed_hardening_failed" })
  t.eq(load_cli().main({ "import", "/tmp/import" }, state.deps), 0)
  t.eq(state.commits, 1)
  t.eq(state.reverts, 0)
  t.truthy(next(state.nodes))
  t.contains(table.concat(state.output), '"commit_outcome":"committed_hardening_failed"')

  local migration = fixture({ commit_outcome = "committed_hardening_failed" })
  t.eq(load_cli().main({ "migrate-legacy", "/etc/xc/legacy-backup-1" }, migration.deps), 0)
  t.eq(migration.commits, 1)
  t.eq(migration.reverts, 0)
  t.contains(table.concat(migration.output), '"commit_outcome":"committed_hardening_failed"')
end)

t.test("CLI reverts only pre-commit failures and exposes uncertain commits", function()
  local candidate = {
    nodes = { one = { name = "SOCKS", protocol = "socks5", address = "127.0.0.1", port = 1080 } }
  }
  local precommit = fixture({ import_value = candidate, commit_fail = true })
  t.eq(load_cli().main({ "import", "/tmp/import" }, precommit.deps), 1)
  t.eq(precommit.reverts, 1)
  t.contains(table.concat(precommit.output), '"code":"import_commit_failed"')

  for _, options in ipairs({
    { import_value = candidate, commit_outcome = "commit_unknown" },
    { import_value = candidate, commit_throw = true }
  }) do
    local uncertain = fixture(options)
    t.eq(load_cli().main({ "import", "/tmp/import" }, uncertain.deps), 1)
    t.eq(uncertain.reverts, 0)
    t.contains(table.concat(uncertain.output), '"code":"commit_unknown"')
  end

  for _, options in ipairs({
    { commit_outcome = "commit_unknown" },
    { commit_throw = true }
  }) do
    local uncertain = fixture(options)
    t.eq(load_cli().main({ "migrate-legacy", "/etc/xc/legacy-backup-1" }, uncertain.deps), 1)
    t.eq(uncertain.reverts, 0)
    t.contains(table.concat(uncertain.output), '"code":"commit_unknown"')
    t.eq(uncertain.files[MIGRATION_MARKER], nil)
  end
end)

t.test("migration retry adopts a commit that was previously reported unknown", function()
  local state = fixture({ commit_outcome = "commit_unknown", unknown_committed = true })
  local cli = load_cli()
  t.eq(cli.main({ "migrate-legacy", "/etc/xc/legacy-backup-1" }, state.deps), 1)
  t.eq(state.reverts, 0)
  t.eq(state.files[MIGRATION_MARKER], nil)
  t.truthy(next(state.nodes))

  t.eq(cli.main({ "migrate-legacy", "/etc/xc/legacy-backup-1" }, state.deps), 0)
  t.eq(state.commits, 1)
  t.eq(state.reverts, 0)
  t.contains(state.files[MIGRATION_MARKER], "xc-migration-v1\nlegacy-backup-1\n14\n")
end)

t.test("lifecycle files contain guarded recovery, takeover, and bounded backup contracts", function()
  local init = read_file("root/etc/init.d/xc")
  local wrapper = read_file("root/usr/bin/xc")
  t.contains(init, "resolve_asset_dir()")
  t.contains(init, "export XRAY_LOCATION_ASSET=\"$asset_dir\"")
  t.contains(init, "unset XRAY_LOCATION_ASSET")
  t.eq(wrapper:find("nixio.setenv", 1, true), nil)
  t.contains(init, "mkdir -p /etc/xc/rollback /etc/xc/xray/versions /var/etc/xc /var/log")
  t.contains(init, "chmod 0700 /etc/xc /etc/xc/rollback /etc/xc/xray /etc/xc/xray/versions /var/etc/xc")
  t.contains(init, "chmod 0600 /etc/config/xc")
  t.contains(init, "/usr/bin/xc recover-pending")
  t.truthy(init:find("recover%-pending") < init:find("render %-%-output"))
  t.contains(init, 'procd_set_param command "$xray_path" run -c /var/etc/xc/config.json')
  t.contains(init, 'xray_path="$(resolve_xray)"')
  t.contains(init, "procd_set_param respawn 3600 5 5")
  t.contains(init, "procd_add_reload_trigger xc network")
  local hotplug = read_file("root/etc/hotplug.d/iface/95-xc")
  t.contains(hotplug, '"$INTERFACE" = "lan"')
  t.contains(hotplug, '"$ACTION" = "ifup"')
  t.contains(hotplug, '"$ACTION" = "ifupdate"')
  local defaults = read_file("root/etc/uci-defaults/luci-xc")
  t.contains(defaults, "if [ ! -f /etc/xc/migration-complete ]; then")
  t.contains(defaults, "/etc/xc/takeover-complete")
  t.eq(defaults:find("/etc/init.d/xc start || takeover_failed", 1, true), nil)
  t.eq(defaults:find("/etc/init.d/xc-xray start || restore_failed", 1, true), nil)
  t.truthy(defaults:find("migrate%-legacy") < defaults:find("xc%-xray disable"))
  t.eq(defaults:find("/usr/bin/xc render", 1, true), nil)
  t.eq(defaults:find("/usr/bin/xray run", 1, true), nil)
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
  t.contains(makefile, 'root="$${IPKG_INSTROOT:-}"')
  t.contains(makefile, '"$$xc_dir/migration-complete"')
  t.contains(makefile, "define Package/$(PKG_NAME)/postinst")
  t.contains(makefile, 'chmod 0700 "$$root/etc/xc" "$$root/etc/xc/rollback" "$$root/etc/xc/xray" "$$root/etc/xc/xray/versions" "$$root/var/etc/xc"')
  t.contains(makefile, 'chmod 0600 "$$root/etc/config/xc"')
  t.contains(makefile, '(. /etc/uci-defaults/luci-xc) && rm -f /etc/uci-defaults/luci-xc')
  t.contains(makefile, 'rm -f /tmp/luci-indexcache /tmp/luci-indexcache.*')
  t.contains(makefile, '/etc/init.d/rpcd reload')
  t.contains(makefile, 'touch "$$backup/complete"')
  t.eq(makefile:find("$$$$backup", 1, true), nil)
  t.eq(makefile:find("cp %-r"), nil)
  t.eq(makefile:find("find $$backup", 1, true), nil)
end)

t.test("expanded preinst backs up only the offline root and skips completed migration", function()
  local preinst = make_script("preinst")
  t.eq(type(preinst), "string")
  local root = "/tmp/luci-xc-package-root"
  os.execute("rm -rf '" .. root .. "'")
  assert(os.execute("mkdir -p '" .. root .. "/etc/xc' '" .. root .. "/etc/config' '" .. root .. "/etc/init.d' '" .. root .. "/usr/bin'") == 0)
  write_file(root .. "/etc/xc/nodes.json", "legacy-secret")
  write_file(root .. "/etc/xc/current", "1\n")
  write_file(root .. "/etc/config/xc", "config package 'xc'\n")
  write_file(root .. "/etc/config-xc", "sentinel")
  assert(os.execute("mkdir -p tests/tmp && chmod 0644 '" .. root .. "/etc/xc/nodes.json' '" .. root .. "/etc/config/xc'") == 0)
  write_file("tests/tmp/preinst-expanded.sh", preinst)
  assert(os.execute("IPKG_INSTROOT='" .. root .. "' sh tests/tmp/preinst-expanded.sh") == 0)
  local backup = command_output("find '" .. root .. "/etc/xc' -maxdepth 1 -type d -name 'legacy-backup-*' | head -n 1")
  t.truthy(#backup > 0)
  t.eq(read_file(backup .. "/nodes.json"), "legacy-secret")
  t.eq(command_output("stat -c %a '" .. root .. "/etc/config/xc'"), "600")
  local before = command_output("find '" .. root .. "/etc/xc' -maxdepth 1 -type d -name 'legacy-backup-*' | wc -l")
  write_file(root .. "/etc/xc/migration-complete", "xc-migration-v1\nsource\n1\n00000000\n")
  write_file(root .. "/etc/xc/nodes.json", "stale-secret")
  assert(os.execute("IPKG_INSTROOT='" .. root .. "' sh tests/tmp/preinst-expanded.sh") == 0)
  local after = command_output("find '" .. root .. "/etc/xc' -maxdepth 1 -type d -name 'legacy-backup-*' | wc -l")
  t.eq(after, before)
end)

t.test("expanded postinst provisions rollback and config modes in an offline root", function()
  local postinst = make_script("postinst")
  t.eq(type(postinst), "string")
  local root = "/tmp/luci-xc-postinst-root"
  os.execute("rm -rf '" .. root .. "'")
  assert(os.execute("mkdir -p '" .. root .. "/etc/config'") == 0)
  write_file(root .. "/etc/config/xc", "config package 'xc'\n")
  assert(os.execute("mkdir -p '" .. root .. "/etc/uci-defaults' '" .. root .. "/etc/init.d' '" .. root .. "/tmp/luci-modulecache'") == 0)
  write_file(root .. "/etc/uci-defaults/luci-xc", "#!/bin/sh\nexit 7\n")
  write_file(root .. "/etc/init.d/rpcd", "#!/bin/sh\nexit 7\n")
  write_file(root .. "/tmp/luci-indexcache.1", "cache")
  assert(os.execute("chmod 0755 '" .. root .. "/etc/uci-defaults/luci-xc' '" .. root .. "/etc/init.d/rpcd'") == 0)
  assert(os.execute("chmod 0644 '" .. root .. "/etc/config/xc'") == 0)
  write_file("tests/tmp/postinst-expanded.sh", postinst)
  assert(os.execute("IPKG_INSTROOT='" .. root .. "' sh tests/tmp/postinst-expanded.sh") == 0)
  t.eq(command_output("stat -c %a '" .. root .. "/etc/xc/rollback'"), "700")
  t.eq(command_output("stat -c %a '" .. root .. "/etc/config/xc'"), "600")
  t.eq(read_file(root .. "/etc/uci-defaults/luci-xc"), "#!/bin/sh\nexit 7\n")
  t.eq(read_file(root .. "/tmp/luci-indexcache.1"), "cache")
end)

local function live_postinst_fixture(default_status)
  local root = "/tmp/luci-xc-live-postinst-root"
  os.execute("rm -rf '" .. root .. "'")
  assert(os.execute("mkdir -p '" .. root .. "/etc/config' '" .. root .. "/etc/uci-defaults' '" .. root ..
    "/etc/init.d' '" .. root .. "/tmp/luci-modulecache' '" .. root .. "/bin'") == 0)
  write_file(root .. "/etc/config/xc", "config package 'xc'\n")
  write_file(root .. "/etc/uci-defaults/luci-xc", "#!/bin/sh\nprintf 'defaults\\n' >>\"$EVENTS\"\nexit " .. tostring(default_status or 0) .. "\n")
  write_file(root .. "/etc/init.d/rpcd", "#!/bin/sh\nprintf 'rpcd:%s\\n' \"$*\" >>\"$EVENTS\"\nexit 0\n")
  write_file(root .. "/bin/killall", "#!/bin/sh\nprintf 'killall:%s\\n' \"$*\" >>\"$EVENTS\"\nexit 0\n")
  write_file(root .. "/tmp/luci-indexcache", "cache")
  write_file(root .. "/tmp/luci-indexcache.1", "cache")
  assert(os.execute("chmod 0755 '" .. root .. "/etc/uci-defaults/luci-xc' '" .. root .. "/etc/init.d/rpcd' '" .. root .. "/bin/killall'") == 0)
  local source = make_script("postinst")
  for _, mapping in ipairs({
    { "/etc/uci-defaults/luci-xc", root .. "/etc/uci-defaults/luci-xc" },
    { "/etc/init.d/rpcd", root .. "/etc/init.d/rpcd" },
    { "/tmp/luci-indexcache", root .. "/tmp/luci-indexcache" },
    { "/tmp/luci-modulecache", root .. "/tmp/luci-modulecache" },
    { "/etc/config/xc", root .. "/etc/config/xc" },
    { "/var/etc/xc", root .. "/var/etc/xc" },
    { "/etc/xc", root .. "/etc/xc" }
  }) do source = replace_plain(source, mapping[1], mapping[2]) end
  write_file("tests/tmp/postinst-live-expanded.sh", source)
  return root
end

t.test("expanded live postinst runs and removes defaults then refreshes LuCI and rpcd", function()
  local root = live_postinst_fixture(0)
  local command = "EVENTS='" .. root .. "/events' PATH='" .. root .. "/bin:'$PATH sh tests/tmp/postinst-live-expanded.sh"
  t.eq(os.execute(command), 0)
  t.eq(io.open(root .. "/etc/uci-defaults/luci-xc", "rb"), nil)
  t.eq(io.open(root .. "/tmp/luci-indexcache", "rb"), nil)
  t.eq(io.open(root .. "/tmp/luci-indexcache.1", "rb"), nil)
  t.eq(command_output("test ! -d '" .. root .. "/tmp/luci-modulecache' && printf removed"), "removed")
  local events = read_file(root .. "/events")
  t.contains(events, "defaults\n")
  t.contains(events, "rpcd:reload\n")
end)

t.test("expanded live postinst retains a failing defaults script and aborts maintenance", function()
  local root = live_postinst_fixture(1)
  local command = "EVENTS='" .. root .. "/events' PATH='" .. root .. "/bin:'$PATH sh tests/tmp/postinst-live-expanded.sh"
  t.truthy(os.execute(command) ~= 0)
  t.truthy(io.open(root .. "/etc/uci-defaults/luci-xc", "rb"))
  t.eq(read_file(root .. "/events"), "defaults\n")
end)

t.test("generated wrapper and repeated configure accept an already completed takeover", function()
  local root = live_postinst_fixture(0)
  local config = "config package 'xc'\n\toption enabled '1'\n"
  local marker = "xc-takeover-v1\n"
  local xc_state = "1 1\n"
  local legacy_state = "0 0\n"
  assert(os.execute("mkdir -p '" .. root .. "/etc/xc'") == 0)
  write_file(root .. "/etc/config/xc", config)
  write_file(root .. "/etc/uci-defaults/luci-xc", table.concat({
    "#!/bin/sh\n",
    "printf 'defaults\\n' >>\"$EVENTS\"\n",
    "printf 'xc-takeover-v1\\n' >\"$MARKER\"\n",
    "printf '1 1\\n' >\"$XC_STATE\"\n",
    "printf '0 0\\n' >\"$LEGACY_STATE\"\n"
  }))
  write_file(root .. "/etc/init.d/rpcd", "#!/bin/sh\nprintf 'rpcd:%s\\n' \"$*\" >>\"$EVENTS\"\nexit 1\n")
  write_file(root .. "/bin/killall", "#!/bin/sh\nprintf 'killall:%s\\n' \"$*\" >>\"$EVENTS\"\nexit 1\n")
  write_file("tests/tmp/generated-postinst-wrapper.sh", table.concat({
    "#!/bin/sh\n",
    "set -eu\n",
    "( . \"$DEFAULTS\" ) && rm -f \"$DEFAULTS\"\n",
    "sh tests/tmp/postinst-live-expanded.sh\n"
  }))

  local env = table.concat({
    "EVENTS='" .. root .. "/events'",
    "MARKER='" .. root .. "/etc/xc/takeover-complete'",
    "XC_STATE='" .. root .. "/xc.state'",
    "LEGACY_STATE='" .. root .. "/legacy.state'",
    "DEFAULTS='" .. root .. "/etc/uci-defaults/luci-xc'",
    "PATH='" .. root .. "/bin:'$PATH"
  }, " ")
  t.eq(os.execute(env .. " sh tests/tmp/generated-postinst-wrapper.sh"), 0)
  t.eq(select(2, read_file(root .. "/events"):gsub("defaults\n", "")), 1)
  t.eq(os.execute(env .. " sh tests/tmp/postinst-live-expanded.sh"), 0)

  t.eq(io.open(root .. "/etc/uci-defaults/luci-xc", "rb"), nil)
  t.eq(read_file(root .. "/etc/config/xc"), config)
  t.eq(read_file(root .. "/etc/xc/takeover-complete"), marker)
  t.eq(read_file(root .. "/xc.state"), xc_state)
  t.eq(read_file(root .. "/legacy.state"), legacy_state)
  t.eq(io.open(root .. "/tmp/luci-indexcache", "rb"), nil)
  t.eq(io.open(root .. "/tmp/luci-indexcache.1", "rb"), nil)
  t.eq(command_output("test ! -d '" .. root .. "/tmp/luci-modulecache' && printf removed"), "removed")
  local events = read_file(root .. "/events")
  t.eq(select(2, events:gsub("defaults\n", "")), 1)
  t.eq(select(2, events:gsub("rpcd:reload\n", "")), 2)
  t.eq(select(2, events:gsub("killall:%-HUP rpcd\n", "")), 2)
end)

local SERVICE_SCRIPT = [[#!/bin/sh
name="${0##*/}"
state="$STATE_DIR/$name"
read -r enabled running <"$state"
action="$1"
if [ "$FAIL_SERVICE" = "$name" ] && [ "$FAIL_ACTION" = "$action" ]; then exit 1; fi
if [ "$HELP_RUNNING_SERVICE" = "$name" ] && [ "$action" = "running" ]; then
	echo "Syntax: $name [command]"
	exit "${HELP_RUNNING_STATUS:-0}"
fi
case "$action" in
	enabled) [ "$enabled" = "1" ] ;;
	running) [ "$running" = "1" ] ;;
	enable) enabled=1 ;;
	disable) enabled=0 ;;
	start) [ "$NOOP_START_SERVICE" = "$name" ] || running=1 ;;
	stop) running=0 ;;
	*) exit 2 ;;
esac
case "$action" in enabled|running) exit $? ;; esac
printf '%s %s\n' "$enabled" "$running" >"$state"
if [ "$RETURN_FAILURE_AFTER_SERVICE" = "$name" ] && [ "$RETURN_FAILURE_AFTER_ACTION" = "$action" ]; then exit 1; fi
]]

local function takeover_fixture(old_enabled, old_running)
  local root = "/tmp/luci-xc-takeover-root"
  os.execute("rm -rf '" .. root .. "'")
  assert(os.execute("mkdir -p '" .. root .. "/etc/xc/legacy-backup-1' '" .. root .. "/etc/init.d' '" .. root .. "/usr/bin' '" .. root .. "/var/etc/xc' '" .. root .. "/tmp' '" .. root .. "/state' '" .. root .. "/proc' '" .. root .. "/bin'") == 0)
  write_file(root .. "/etc/xc/legacy-backup-1/complete", "")
  write_file(root .. "/etc/xc/legacy-backup-1/nodes.json", "legacy")
  write_file(root .. "/etc/init.d/xc", SERVICE_SCRIPT)
  write_file(root .. "/etc/init.d/xc-xray", SERVICE_SCRIPT)
  write_file(root .. "/state/xc", "0 0\n")
  write_file(root .. "/state/xc-xray", tostring(old_enabled) .. " " .. tostring(old_running) .. "\n")
  write_file(root .. "/usr/bin/xc", "#!/bin/sh\nexit 0\n")
  write_file(root .. "/usr/bin/xray", "#!/bin/sh\nexit 0\n")
  write_file(root .. "/bin/sleep", "#!/bin/sh\nexit 0\n")
  assert(os.execute("chmod 0755 '" .. root .. "/etc/init.d/xc' '" .. root .. "/etc/init.d/xc-xray' '" .. root .. "/usr/bin/xc' '" .. root .. "/usr/bin/xray' '" .. root .. "/bin/sleep'") == 0)
  local source = read_file("root/etc/uci-defaults/luci-xc")
  local mappings = {
    { "/var/etc/xc", root .. "/var/etc/xc" }, { "/etc/init.d/xc-xray", root .. "/etc/init.d/xc-xray" },
    { "/etc/init.d/xc", root .. "/etc/init.d/xc" }, { "/etc/xc", root .. "/etc/xc" },
    { "/usr/bin/xray", root .. "/usr/bin/xray" }, { "/usr/bin/xc", root .. "/usr/bin/xc" },
    { "/tmp/luci-xc", root .. "/tmp/luci-xc" }, { "/proc", root .. "/proc" }
  }
  for index, mapping in ipairs(mappings) do source = replace_plain(source, mapping[1], "__XC_PATH_" .. index .. "__") end
  for index, mapping in ipairs(mappings) do source = replace_plain(source, "__XC_PATH_" .. index .. "__", mapping[2]) end
  write_file("tests/tmp/uci-default-expanded.sh", source)
  return root
end

t.test("uci-default takeover restores exact old service state on every step failure", function()
  for _, failure in ipairs({
    { service = "xc-xray", action = "disable" }, { service = "xc-xray", action = "stop" },
    { service = "xc", action = "enable" }, { service = "xc", action = "start" }
  }) do
    local root = takeover_fixture(1, 1)
    local command = "STATE_DIR='" .. root .. "/state' FAIL_SERVICE='" .. failure.service .. "' FAIL_ACTION='" .. failure.action .. "' sh tests/tmp/uci-default-expanded.sh"
    t.truthy(os.execute(command) ~= 0, failure.service .. ":" .. failure.action)
    t.eq(read_file(root .. "/state/xc-xray"), "1 1\n", failure.service .. ":" .. failure.action)
    t.eq(read_file(root .. "/state/xc"), "0 0\n", failure.service .. ":" .. failure.action)
  end
end)

t.test("uci-default rejects a swallowed procd start failure and restores legacy", function()
  local root = takeover_fixture(1, 1)
  local command = "PATH='" .. root .. "/bin:'$PATH STATE_DIR='" .. root ..
    "/state' NOOP_START_SERVICE='xc' sh tests/tmp/uci-default-expanded.sh"
  t.truthy(os.execute(command) ~= 0)
  t.eq(read_file(root .. "/state/xc-xray"), "1 1\n")
  t.eq(read_file(root .. "/state/xc"), "0 0\n")
end)

t.test("uci-default accepts a nonzero procd start request once the new service is running", function()
  local root = takeover_fixture(1, 1)
  local command = "PATH='" .. root .. "/bin:'$PATH STATE_DIR='" .. root ..
    "/state' RETURN_FAILURE_AFTER_SERVICE='xc' RETURN_FAILURE_AFTER_ACTION='start' sh tests/tmp/uci-default-expanded.sh"
  t.eq(os.execute(command), 0)
  t.eq(read_file(root .. "/state/xc-xray"), "0 0\n")
  t.eq(read_file(root .. "/state/xc"), "1 1\n")
  t.truthy(io.open(root .. TAKEOVER_MARKER, "rb"))
end)

t.test("uci-default does not mistake unsupported running help for a stopped legacy process", function()
  local root = takeover_fixture(1, 0)
  local command = "PATH='" .. root .. "/bin:'$PATH STATE_DIR='" .. root ..
    "/state' HELP_RUNNING_SERVICE='xc-xray' FAIL_SERVICE='xc' FAIL_ACTION='start' sh tests/tmp/uci-default-expanded.sh"
  t.truthy(os.execute(command) ~= 0)
  t.eq(read_file(root .. "/state/xc-xray"), "1 0\n")
  t.eq(read_file(root .. "/state/xc"), "0 0\n")
end)

t.test("uci-default detects a running non-procd legacy process by its exact config argument", function()
  local root = takeover_fixture(1, 1)
  assert(os.execute("mkdir -p '" .. root .. "/proc/123'") == 0)
  write_file(root .. "/proc/123/cmdline", root .. "/usr/bin/xray\0run\0-c\0" .. root .. "/etc/xc/config.json\0")
  local command = "PATH='" .. root .. "/bin:'$PATH STATE_DIR='" .. root ..
    "/state' HELP_RUNNING_SERVICE='xc-xray' HELP_RUNNING_STATUS='1' FAIL_SERVICE='xc' FAIL_ACTION='start' sh tests/tmp/uci-default-expanded.sh"
  t.truthy(os.execute(command) ~= 0)
  t.eq(read_file(root .. "/state/xc-xray"), "1 1\n")
  t.eq(read_file(root .. "/state/xc"), "0 0\n")
end)

t.test("uci-default does not treat a non-Xray process reading the legacy config as running", function()
  local root = takeover_fixture(1, 0)
  assert(os.execute("mkdir -p '" .. root .. "/proc/124'") == 0)
  write_file(root .. "/proc/124/cmdline", "/bin/cat\0" .. root .. "/etc/xc/config.json\0")
  local command = "PATH='" .. root .. "/bin:'$PATH STATE_DIR='" .. root ..
    "/state' HELP_RUNNING_SERVICE='xc-xray' FAIL_SERVICE='xc' FAIL_ACTION='start' sh tests/tmp/uci-default-expanded.sh"
  t.truthy(os.execute(command) ~= 0)
  t.eq(read_file(root .. "/state/xc-xray"), "1 0\n")
end)

t.test("uci-default completed migration marker skips migration but resumes takeover", function()
  local root = takeover_fixture(1, 1)
  write_file(root .. "/etc/xc/migration-complete", "xc-migration-v1\nsource\n1\n00000000\n")
  assert(os.execute("STATE_DIR='" .. root .. "/state' sh tests/tmp/uci-default-expanded.sh") == 0)
  t.eq(read_file(root .. "/state/xc-xray"), "0 0\n")
  t.eq(read_file(root .. "/state/xc"), "1 1\n")
  t.truthy(io.open(root .. TAKEOVER_MARKER, "rb"))
end)

t.test("uci-default completed takeover preserves later user-disabled service state", function()
  local root = takeover_fixture(0, 0)
  write_file(root .. MIGRATION_MARKER, "xc-migration-v1\nsource\n1\n00000000\n")
  write_file(root .. TAKEOVER_MARKER, "xc-takeover-v1\n")
  assert(os.execute("STATE_DIR='" .. root .. "/state' sh tests/tmp/uci-default-expanded.sh") == 0)
  t.eq(read_file(root .. "/state/xc-xray"), "0 0\n")
  t.eq(read_file(root .. "/state/xc"), "0 0\n")
end)
