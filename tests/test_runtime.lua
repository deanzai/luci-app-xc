local t = require "testlib"
local runtime = require "xc.runtime"

local UUID = "11111111-1111-1111-1111-111111111111"
local RUNTIME = "/var/etc/xc/config.json"
local ROLLBACK = "/etc/xc/rollback/config.json"
local ROLLBACK_NODE = "/etc/xc/rollback/active_node"
local PENDING_ROLLBACK = ROLLBACK .. ".pending"
local PENDING_ROLLBACK_NODE = ROLLBACK_NODE .. ".pending"
local UNSET_ACTIVE = "!xc-active-unset!"
local MANIFEST = "/etc/xc/rollback/current"

local function checksum(value)
  local hash = 5381
  for index = 1, #value do hash = (hash * 33 + value:byte(index)) % 2147483647 end
  return string.format("%08x", hash)
end

local function journal(config, active, generation)
  generation = generation or "100-1"
  local prefix = "/etc/xc/rollback/generation-" .. generation
  local manifest = table.concat({ "xc-rollback-v1", generation, tostring(#config), checksum(config), tostring(#active), checksum(active), "" }, "\n")
  return { [MANIFEST] = manifest, [prefix .. ".config"] = config, [prefix .. ".active"] = active }
end

local function merge(left, right)
  for key, value in pairs(right) do left[key] = value end
  return left
end
local LOCK = "/var/lock/xc.lock"

local function quote(value)
  return '"' .. value:gsub('[%z\1-\31\\"]', function(character)
    local escapes = { ['\\'] = '\\\\', ['"'] = '\\"', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }
    return escapes[character] or string.format("\\u%04x", character:byte())
  end) .. '"'
end

local function stringify(value)
  local kind = type(value)
  if kind == "nil" then return "null" end
  if kind == "boolean" then return value and "true" or "false" end
  if kind == "number" then return tostring(value) end
  if kind == "string" then return quote(value) end
  if kind ~= "table" then error("unsupported JSON value") end
  local count, maximum, array = 0, 0, true
  for key in pairs(value) do
    count = count + 1
    if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then array = false
    elseif key > maximum then maximum = key end
  end
  if count == 0 then return "[]" end
  if array and maximum == count then
    local values = {}
    for index = 1, maximum do values[index] = stringify(value[index]) end
    return "[" .. table.concat(values, ",") .. "]"
  end
  local keys = {}
  for key in pairs(value) do
    if type(key) ~= "string" then error("mixed JSON table") end
    keys[#keys + 1] = key
  end
  table.sort(keys)
  local values = {}
  for _, key in ipairs(keys) do values[#values + 1] = quote(key) .. ":" .. stringify(value[key]) end
  return "{" .. table.concat(values, ",") .. "}"
end

local function node(id, enabled)
  return {
    id = id, name = "Node " .. id, enabled = enabled,
    protocol = "vless", server = id .. ".invalid", port = 443,
    uuid = UUID, encryption = "none", transport = "tcp", security = "none"
  }
end

local function fixture(options)
  options = options or {}
  local events, files = {}, {}
  for path, content in pairs(options.files or {}) do files[path] = content end
  local global = options.global or { active_node = "old", socks_port = 7890, http_port = 10809 }
  global.health_url = global.health_url or "https://health.invalid/generate_204"
  global.health_timeout = global.health_timeout or 5
  local nodes = options.nodes or { node("old", true), node("new", true) }
  local by_id = {}
  for _, value in ipairs(nodes) do by_id[value.id] = value end
  local original_active = global.active_node
  local state = { events = events, files = files, global = global }
  local function event(value) events[#events + 1] = value end
  local uci = {
    get_global = function() event("uci:get_global"); return global end,
    list_nodes = function() event("uci:list_nodes"); return nodes end,
    get_node = function(id) event("uci:get_node:" .. tostring(id)); return by_id[id] end,
    set_active = function(id)
      event("uci:set_active:" .. tostring(id))
      if options.throw_set_active then error("password=adapter-secret") end
      global.active_node = id
      return true
    end,
    clear_active = function()
      event("uci:clear_active")
      global.active_node = nil
      return true
    end,
    commit = function()
      event("uci:commit")
      if (options.commit_failures or 0) > 0 then
        options.commit_failures = options.commit_failures - 1
        return false
      end
      return options.commit_ok ~= false
    end,
    revert = function() event("uci:revert"); global.active_node = original_active; return true end
  }
  local fs = {
    acquire_lock = function(path)
      event("fs:lock:" .. path)
      if options.throw_acquire then error("token=lock-secret") end
      if options.busy then return nil end
      return { path = path, kernel_flock = true }
    end,
    release_lock = function() event("fs:unlock"); return options.release_ok ~= false end,
    read = function(path, maximum) event("fs:read:" .. path); if maximum and files[path] and #files[path] > maximum then return nil end; return files[path] end,
    exists = function(path) event("fs:exists:" .. path); return files[path] ~= nil end,
    write_temp = function(path, content)
      local temporary = path .. ".tmp.123"
      event("fs:write_temp:" .. temporary)
      files[temporary] = content
      return { path = temporary }
    end,
    chmod = function(path, mode) event("fs:chmod:" .. path .. ":" .. tostring(mode)); return true end,
    fsync = function(handle)
      event("fs:fsync:" .. handle.path)
      if options.throw_fsync or (options.fsync_failures or 0) > 0 then
        if options.fsync_failures then options.fsync_failures = options.fsync_failures - 1 end
        error("raw adapter exception {secret}")
      end
      return true
    end,
    close = function(handle) event("fs:close:" .. handle.path); return true end,
    fsync_dir = function(path) event("fs:fsync_dir:" .. path); return options.fsync_dir_ok ~= false end,
    rename = function(source, destination)
      event("fs:rename:" .. source .. ":" .. destination)
      files[destination], files[source] = files[source], nil
      return true
    end,
    remove = function(path) event("fs:remove:" .. path); if options.remove_ok == false then return false end; files[path] = nil; return true end,
    append = function(path, content) event("fs:append:" .. path); files[path] = (files[path] or "") .. content; return true end
  }
  local exec = {
    run = function(argv)
      event("exec:run:" .. table.concat(argv, "|"))
      return options.validation_ok ~= false
    end,
    restart = function()
      event("exec:restart")
      if (options.restart_failures or 0) > 0 then
        options.restart_failures = options.restart_failures - 1
        return false
      end
      return options.restart_ok ~= false
    end,
    stop = function() event("exec:stop"); return options.stop_ok ~= false end,
    listener_ready = function(kind, address, port)
      event("exec:listener:" .. kind .. ":" .. address .. ":" .. tostring(port))
      if options.listener_failures and (options.listener_failures[kind] or 0) > 0 then
        options.listener_failures[kind] = options.listener_failures[kind] - 1
        return false
      end
      return not options.listener_fail or options.listener_fail ~= kind
    end,
    health_check = function(kind, address, port, health_url, deadline)
      event("exec:health:" .. kind .. ":" .. address .. ":" .. tostring(port))
      state.health_url, state.health_deadline = health_url, deadline
      if options.health_failures and (options.health_failures[kind] or 0) > 0 then
        options.health_failures[kind] = options.health_failures[kind] - 1
        return false
      end
      return not options.health_fail or options.health_fail ~= kind
    end,
    service_state = function() return "running" end
  }
  state.runtime = assert(runtime.new({
    uci = uci, fs = fs, exec = exec, json = { stringify = stringify },
    network = function() return "192.168.6.1" end,
    now = function() return 123 end,
    sleep = function() event("sleep") end
  }))
  return state
end

local function event_index(events, sought)
  for index, value in ipairs(events) do if value == sought then return index end end
end

t.test("render rejects missing and disabled active nodes", function()
  local missing = fixture({ global = { active_node = "gone", socks_port = 7890, http_port = 10809 }, nodes = { node("only", true) } })
  local result = missing.runtime:render(nil, "/tmp/render.json")
  t.eq(result.ok, false)
  t.eq(result.code, "missing_node")
  t.eq(missing.files["/tmp/render.json"], nil)

  local disabled = fixture({ global = { active_node = "off", socks_port = 7890, http_port = 10809 }, nodes = { node("off", false) } })
  result = disabled.runtime:render(nil, "/tmp/render.json")
  t.eq(result.ok, false)
  t.eq(result.code, "disabled_node")
end)

t.test("render auto-selects only a sole enabled node and writes atomically", function()
  local state = fixture({ global = { socks_port = 7890, http_port = 10809 }, nodes = { node("off", false), node("only", true) } })
  local result = state.runtime:render(nil, "/tmp/render.json")
  t.eq(result.ok, true)
  t.eq(result.node, "only")
  t.contains(state.files["/tmp/render.json"], '"listen":"192.168.6.1"')
  t.truthy(event_index(state.events, "fs:chmod:/tmp/render.json.tmp.123:0600"))
  t.truthy(event_index(state.events, "fs:fsync:/tmp/render.json.tmp.123"))
  t.truthy(event_index(state.events, "fs:close:/tmp/render.json.tmp.123"))
  t.truthy(event_index(state.events, "fs:rename:/tmp/render.json.tmp.123:/tmp/render.json"))

  local multiple = fixture({ global = { socks_port = 7890, http_port = 10809 }, nodes = { node("one", true), node("two", true) } })
  t.eq(multiple.runtime:render(nil, "/tmp/render.json").code, "active_node_required")
  local none = fixture({ global = { socks_port = 7890, http_port = 10809 }, nodes = { node("off", false) } })
  t.eq(none.runtime:render(nil, "/tmp/render.json").code, "no_enabled_nodes")
  local corrupt = fixture({ global = { active_node = "", socks_port = 7890, http_port = 10809 }, nodes = { node("only", true) } })
  t.eq(corrupt.runtime:render(nil, "/tmp/render.json").code, "invalid_node")
end)

t.test("render validates section IDs and uses lossless raw encoding", function()
  local raw = {
    id = "raw_node", name = "raw", enabled = true, protocol = "raw",
    raw_outbound = '{"protocol":"freedom","tag":"replace","settings":{"large":9007199254740993,"missing":null}}'
  }
  local state = fixture({ global = { socks_port = 7890, http_port = 10809 }, nodes = { raw } })
  local unsafe = state.runtime:render("bad;reboot", "/tmp/render.json")
  t.eq(unsafe.code, "invalid_node")
  local result = state.runtime:render("raw_node", "/tmp/render.json")
  t.eq(result.ok, true)
  t.contains(state.files["/tmp/render.json"], '"large":9007199254740993')
  t.contains(state.files["/tmp/render.json"], '"missing":null')
  t.eq(state.files["/tmp/render.json"]:find("__XC_RAW_OUTBOUND_", 1, true), nil)
end)

t.test("switch validates before snapshot and commits only after listeners and health", function()
  local state = fixture({ files = { [RUNTIME] = "old-runtime" } })
  local result = state.runtime:switch("new")
  t.eq(result.ok, true)
  t.eq(result.code, "switched")
  t.eq(state.global.active_node, "new")
  t.truthy(state.files[MANIFEST])
  t.eq(state.files["/etc/xc/rollback/generation-123-1.config"], "old-runtime")
  t.eq(state.files["/etc/xc/rollback/generation-123-1.active"], "old")
  local candidate = RUNTIME .. ".candidate"
  local test_event = "exec:run:/usr/bin/xray|run|-test|-c|" .. candidate
  t.truthy(event_index(state.events, test_event) < event_index(state.events, "exec:restart"))
  t.truthy(event_index(state.events, test_event) < event_index(state.events, "fs:write_temp:/etc/xc/rollback/generation-123-1.config.tmp.123"))
  t.truthy(event_index(state.events, "exec:health:http:192.168.6.1:10809") < event_index(state.events, "uci:set_active:new"))
  t.truthy(event_index(state.events, "uci:set_active:new") < event_index(state.events, "uci:commit"))
  t.truthy(event_index(state.events, "uci:commit") < event_index(state.events, "fs:rename:" .. MANIFEST .. ".tmp.123:" .. MANIFEST))
  t.eq(state.health_url, "https://health.invalid/generate_204")
  t.eq(state.health_deadline, 128)
  t.eq(state.events[#state.events], "fs:unlock")
end)

t.test("failed switch preserves the prior successful rollback generation", function()
  local state = fixture({
    health_fail = "http",
    files = merge({ [RUNTIME] = "runtime-B" }, journal("runtime-A", "A")),
    global = { active_node = "B", socks_port = 7890, http_port = 10809 },
    nodes = { node("A", true), node("B", true), node("C", true) }
  })
  local result = state.runtime:switch("C")
  t.eq(result.code, "health_failed")
  t.eq(state.files[RUNTIME], "runtime-B")
  t.eq(state.global.active_node, "B")
  t.truthy(state.files[MANIFEST])
  t.eq(state.files["/etc/xc/rollback/generation-100-1.config"], "runtime-A")
  t.eq(state.files[PENDING_ROLLBACK], nil)
  t.eq(state.files[PENDING_ROLLBACK_NODE], nil)
end)

t.test("failed Xray validation never restarts and releases the lock", function()
  local state = fixture({ validation_ok = false, files = { [RUNTIME] = "old-runtime" } })
  local result = state.runtime:switch("new")
  t.eq(result.ok, false)
  t.eq(result.code, "validation_failed")
  t.eq(event_index(state.events, "exec:restart"), nil)
  t.eq(state.global.active_node, "old")
  t.eq(state.events[#state.events], "fs:unlock")
  t.eq(state.files[RUNTIME .. ".candidate"], nil)

  local invalid_health = fixture({ global = { active_node = "old", socks_port = 7890, http_port = 10809, health_url = "file:///secret", health_timeout = 999 } })
  result = invalid_health.runtime:switch("new")
  t.eq(result.code, "generation_failed")
  t.eq(event_index(invalid_health.events, "exec:restart"), nil)
end)

t.test("listener and health failures restore the previous config and active node", function()
  for failure, code in pairs({ listener_fail = "listener_failed", health_fail = "health_failed" }) do
    local options = { files = { [RUNTIME] = "old-runtime" } }
    options[failure] = failure == "listener_fail" and "http" or "socks"
    local state = fixture(options)
    local result = state.runtime:switch("new")
    t.eq(result.ok, false)
    t.eq(result.code, code)
    t.eq(state.files[RUNTIME], "old-runtime")
    t.eq(state.global.active_node, "old")
    t.truthy(event_index(state.events, "uci:set_active:old"))
    t.eq(state.events[#state.events], "fs:unlock")
  end
end)

t.test("listener readiness waits and both health entries are always checked", function()
  local state = fixture({ listener_failures = { socks = 1 }, files = { [RUNTIME] = "old-runtime" } })
  local result = state.runtime:switch("new")
  t.eq(result.ok, true)
  t.truthy(event_index(state.events, "sleep"))

  local failed = fixture({ health_fail = "socks", files = { [RUNTIME] = "old-runtime" } })
  result = failed.runtime:switch("new")
  t.eq(result.code, "health_failed")
  t.truthy(event_index(failed.events, "exec:health:socks:192.168.6.1:7890"))
  t.truthy(event_index(failed.events, "exec:health:http:192.168.6.1:10809"))
end)

t.test("a failed first switch stops service when no old runtime exists", function()
  local state = fixture({ health_fail = "http" })
  local result = state.runtime:switch("new")
  t.eq(result.ok, false)
  t.eq(result.code, "health_failed_no_previous_config")
  t.eq(state.files[RUNTIME], nil)
  t.truthy(event_index(state.events, "exec:stop"))
  t.eq(state.global.active_node, "old")
end)

t.test("lock contention returns busy without generating a candidate", function()
  local state = fixture({ busy = true })
  local result = state.runtime:switch("new")
  t.eq(result.ok, false)
  t.eq(result.code, "busy")
  t.eq(event_index(state.events, "uci:get_global"), nil)
  t.eq(event_index(state.events, "fs:unlock"), nil)
end)

t.test("central lock protects runtime render and rejects acquire or release faults", function()
  local rendered = fixture()
  local result = rendered.runtime:render("new", RUNTIME)
  t.eq(result.ok, true)
  t.eq(rendered.events[1], "fs:lock:" .. LOCK)
  t.eq(rendered.events[#rendered.events], "fs:unlock")

  local acquire = fixture({ throw_acquire = true })
  result = acquire.runtime:switch("new")
  t.eq(result.code, "internal_error")
  t.eq(result.message:find("lock-secret", 1, true), nil)

  local release = fixture({ release_ok = false, validation_ok = false })
  result = release.runtime:switch("new")
  t.eq(result.code, "internal_error")
end)

t.test("adapter exceptions release the lock and return generic secret-safe errors", function()
  local state = fixture({ throw_set_active = true, files = { [RUNTIME] = "old-runtime" } })
  local result = state.runtime:switch("new")
  t.eq(result.ok, false)
  t.eq(result.code, "recovery_failed")
  t.eq(result.message:find("adapter-secret", 1, true), nil)
  t.eq(state.events[#state.events], "fs:unlock")
end)

t.test("atomic write failures close and remove temporary files", function()
  local state = fixture({ throw_fsync = true })
  local result = state.runtime:switch("new")
  t.eq(result.ok, false)
  t.eq(result.code, "internal_error")
  local temporary = RUNTIME .. ".candidate.tmp.123"
  t.truthy(event_index(state.events, "fs:close:" .. temporary))
  t.truthy(event_index(state.events, "fs:remove:" .. temporary))
  t.eq(state.files[temporary], nil)
  t.eq(state.events[#state.events], "fs:unlock")
end)

t.test("rollback reports no snapshot and restores a one-generation snapshot", function()
  local none = fixture()
  local result = none.runtime:rollback()
  t.eq(result.ok, false)
  t.eq(result.code, "no_rollback_state")
  t.eq(none.events[#none.events], "fs:unlock")

  local state = fixture({ files = merge({ [RUNTIME] = "new-runtime" }, journal("old-runtime", "old")), global = { active_node = "new", socks_port = 7890, http_port = 10809 } })
  result = state.runtime:rollback()
  t.eq(result.ok, true)
  t.eq(result.code, "rolled_back")
  t.eq(state.files[RUNTIME], "old-runtime")
  t.eq(state.global.active_node, "old")
  t.eq(state.files[MANIFEST], nil)
  t.truthy(event_index(state.events, "fs:chmod:" .. RUNTIME .. ".tmp.123:0600") < event_index(state.events, "exec:restart"))
  t.truthy(event_index(state.events, "exec:restart") < event_index(state.events, "uci:commit"))
  t.truthy(event_index(state.events, "exec:listener:http:192.168.6.1:10809"))
  t.truthy(event_index(state.events, "exec:health:socks:192.168.6.1:7890"))
  t.truthy(event_index(state.events, "exec:health:http:192.168.6.1:10809"))
end)

t.test("rollback rejects corrupt journal snapshots before Xray or installation", function()
  local files = journal("old-runtime", "old")
  files["/etc/xc/rollback/generation-100-1.config"] = "tampered"
  files[RUNTIME] = "current-runtime"
  local state = fixture({ files = files })
  local result = state.runtime:rollback()
  t.eq(result.code, "no_rollback_state")
  t.eq(state.files[RUNTIME], "current-runtime")
  t.eq(event_index(state.events, "exec:restart"), nil)
end)

t.test("rollback failures restore the pre-rollback runtime UCI and service", function()
  local cases = {
    { options = { restart_failures = 1 }, code = "restart_failed" },
    { options = { commit_failures = 1 }, code = "commit_failed" },
    { options = { health_failures = { http = 1 } }, code = "health_failed" },
    { options = { fsync_failures = 1 }, code = "internal_error" }
  }
  for _, case in ipairs(cases) do
    case.options.files = merge({ [RUNTIME] = "runtime-new" }, journal("runtime-old", "old"))
    case.options.global = { active_node = "new", socks_port = 7890, http_port = 10809 }
    local state = fixture(case.options)
    local result = state.runtime:rollback()
    t.eq(result.ok, false)
    t.eq(result.code, case.code)
    t.eq(state.files[RUNTIME], "runtime-new")
    t.eq(state.global.active_node, "new")
    t.truthy(state.files[MANIFEST])
    t.eq(state.events[#state.events], "fs:unlock")
  end
end)

t.test("rollback restores an explicitly unset active node", function()
  local state = fixture({
    files = { [RUNTIME] = "runtime-before" },
    global = { socks_port = 7890, http_port = 10809 },
    nodes = { node("only", true) }
  })
  local switched = state.runtime:switch(nil)
  t.eq(switched.ok, true)
  t.eq(state.global.active_node, "only")
  t.eq(state.files["/etc/xc/rollback/generation-123-1.active"], UNSET_ACTIVE)
  local rolled_back = state.runtime:rollback()
  t.eq(rolled_back.ok, true)
  t.eq(state.global.active_node, nil)
  t.truthy(event_index(state.events, "uci:clear_active"))
  t.eq(state.files[RUNTIME], "runtime-before")
end)

t.test("status and test_current omit credentials and use only fixed argv", function()
  local secret_node = node("old", true)
  secret_node.name = "https://sub.invalid/opaque-secret-token"
  local state = fixture({ files = { [RUNTIME] = "raw-secret-runtime" }, nodes = { secret_node } })
  local status = state.runtime:status()
  t.eq(status.ok, true)
  t.eq(status.active_node, "old")
  t.eq(status.node.name, "[redacted]")
  t.eq(status.node.uuid, nil)
  t.eq(status.node.raw_outbound, nil)
  t.eq(status.service, "running")
  t.eq(status.operation, "idle")
  t.eq(status.active_state, "selected")
  t.eq(status.listen.address, "192.168.6.1")
  t.eq(status.listeners.socks, true)
  t.eq(status.listeners.http, true)
  local tested = state.runtime:test_current()
  t.eq(tested.ok, true)
  t.eq(state.events[#state.events], "exec:run:/usr/bin/xray|run|-test|-c|" .. RUNTIME)
  t.eq(stringify(status):find(UUID, 1, true), nil)
  t.eq(stringify(status):find("https://", 1, true), nil)
  t.eq(stringify(status):find("opaque-secret-token", 1, true), nil)
  t.eq(stringify(tested):find("raw-secret-runtime", 1, true), nil)
end)

t.test("status distinguishes unset and invalid active state", function()
  local unset = fixture({ global = { socks_port = 7890, http_port = 10809 }, nodes = { node("only", true) } })
  t.eq(unset.runtime:status().active_state, "unset")
  local invalid = fixture({ global = { active_node = "bad;secret", socks_port = 7890, http_port = 10809 } })
  local status = invalid.runtime:status()
  t.eq(status.active_state, "invalid")
  t.eq(status.active_node, nil)
  t.eq(stringify(status):find("bad;secret", 1, true), nil)
end)

t.test("logging redacts credentials links raw content and bounds output", function()
  local state = fixture()
  local link = "vless://" .. UUID .. "@secret.invalid:443?security=reality#private"
  local result = state.runtime:log(
    "failed " .. UUID .. " password=hunter2 TOKEN=tok-value api_key=api-value private-key=key-value -----BEGIN PRIVATE KEY----- PEMSECRET -----END PRIVATE KEY----- " .. link .. " https://sub.invalid/opaque-secret-token hysteria2://edge.invalid/share-secret {\"raw\":\"do-not-log\"}" .. string.rep("x", 5000),
    { password = "field-secret", raw_content = "raw-field-secret", url = "https://u:p@host/path?q=secret#frag", node = "safe-node" }
  )
  t.eq(result.ok, true)
  local line = state.files["/var/log/xc.log"]
  t.truthy(#line <= 2048)
  for _, secret in ipairs({ UUID, "hunter2", "tok-value", "api-value", "key-value", "PEMSECRET", "vless://", "hysteria2://", "secret.invalid", "sub.invalid", "edge.invalid", "opaque-secret-token", "share-secret", "do-not-log", "field-secret", "raw-field-secret", "q=secret", "u:p" }) do
    t.eq(line:find(secret, 1, true), nil, "log leaked " .. secret)
  end
  t.contains(line, "safe-node")
  t.contains(line, "[redacted]")
end)

t.test("logging enforces the total cap and fsyncs the log directory", function()
  local state = fixture({ files = { ["/var/log/xc.log"] = string.rep("a", 262140) } })
  local result = state.runtime:log("bounded event", { node = "safe" })
  t.eq(result.ok, true)
  t.truthy(#state.files["/var/log/xc.log"] <= 262144)
  t.truthy(event_index(state.events, "fs:chmod:/var/log/xc.log.tmp.123:0600"))
  t.truthy(event_index(state.events, "fs:fsync_dir:/var/log"))
end)

return true
