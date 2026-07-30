local t = require "testlib"
local runtime = require "xc.runtime"

local UUID = "11111111-1111-1111-1111-111111111111"
local RUNTIME = "/var/etc/xc/config.json"
local XRAY_CANDIDATE = "/var/etc/xc/candidate.json"
local ROLLBACK = "/etc/xc/rollback/config.json"
local ROLLBACK_NODE = "/etc/xc/rollback/active_node"
local PENDING_ROLLBACK = ROLLBACK .. ".pending"
local PENDING_ROLLBACK_NODE = ROLLBACK_NODE .. ".pending"
local UNSET_ACTIVE = "!xc-active-unset!"
local MANIFEST = "/etc/xc/rollback/current"
local TRANSACTION = "/etc/xc/rollback/transaction"
local STATUS = "/var/run/xc-status"
local LOG = "/var/log/xc.log"
local LOG_LOCK = "/var/lock/xc-log.lock"
local EXIT_IP_CACHE = "/var/etc/xc/exit-ip-cache"

local function checksum(value)
  local hash = 5381
  for index = 1, #value do hash = (hash * 33 + value:byte(index)) % 2147483647 end
  return string.format("%08x", hash)
end

local function valid_utf8(value)
  local index = 1
  local function continuation(position)
    local byte = value:byte(position)
    return byte ~= nil and byte >= 128 and byte <= 191
  end
  while index <= #value do
    local first = value:byte(index)
    if first <= 127 then
      index = index + 1
    elseif first >= 194 and first <= 223 and continuation(index + 1) then
      index = index + 2
    elseif first >= 224 and first <= 239 then
      local second = value:byte(index + 1)
      if not second or not continuation(index + 2)
        or (first == 224 and (second < 160 or second > 191))
        or (first == 237 and (second < 128 or second > 159))
        or (first ~= 224 and first ~= 237 and (second < 128 or second > 191)) then return false end
      index = index + 3
    elseif first >= 240 and first <= 244 then
      local second = value:byte(index + 1)
      if not second or not continuation(index + 2) or not continuation(index + 3)
        or (first == 240 and (second < 144 or second > 191))
        or (first == 244 and (second < 128 or second > 143))
        or (first ~= 240 and first ~= 244 and (second < 128 or second > 191)) then return false end
      index = index + 4
    else
      return false
    end
  end
  return true
end

local function journal(config, active, generation)
  generation = generation or "100-1"
  local prefix = "/etc/xc/rollback/generation-" .. generation
  local manifest = table.concat({ "xc-rollback-v1", generation, tostring(#config), checksum(config), tostring(#active), checksum(active), "" }, "\n")
  return { [MANIFEST] = manifest, [prefix .. ".config"] = config, [prefix .. ".active"] = active }
end

local function transaction(phase, old_config, old_active, new_config, new_active, kind, generation, target, old_service, prior)
  generation, kind = generation or "123-1", kind or "switch"
  old_config, old_active = old_config or "", old_active or UNSET_ACTIVE
  return table.concat({
    "xc-transaction-v2", generation, kind, phase, generation, target or "-",
    old_config == "" and "0" or "1", tostring(#old_config), checksum(old_config),
    tostring(#old_active), checksum(old_active), tostring(#new_config), checksum(new_config),
    tostring(#new_active), checksum(new_active), old_service or "running", prior or "-", ""
  }, "\n")
end

local function merge(left, right)
  for key, value in pairs(right) do left[key] = value end
  return left
end
local LOCK = "/var/lock/xc.lock"
local MAIN_UNLOCK = "fs:unlock:" .. LOCK
local LOG_UNLOCK = "fs:unlock:" .. LOG_LOCK

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
  local events, files = options.events or {}, options.shared_files or {}
  for path, content in pairs(options.files or {}) do files[path] = content end
  local global = options.global or { active_node = "old", socks_port = 7890, http_port = 10809 }
  global.health_url = global.health_url or "https://health.invalid/generate_204"
  global.health_timeout = global.health_timeout or 5
  local nodes = options.nodes or { node("old", true), node("new", true) }
  local by_id = {}
  for _, value in ipairs(nodes) do by_id[value.id] = value end
  local original_active = global.active_node
  local state = { events = events, files = files, global = global, writes = {}, validation_deadlines = {} }
  local generation_count = 0
  local held_locks = {}
  local function event(value) events[#events + 1] = value end
  local function acquire_fixture_lock(path)
    event("fs:lock:" .. path)
    if options.throw_acquire then error("token=lock-secret") end
    if options.busy or held_locks[path] then return nil end
    held_locks[path] = true
    return { path = path, kernel_flock = true }
  end
  local function release_fixture_lock(lock)
    event("fs:unlock:" .. tostring(lock and lock.path))
    if lock then held_locks[lock.path] = nil end
    return options.release_ok ~= false
  end
  local uci = {
    get_global = function() event("uci:get_global"); return global end,
    list_nodes = function() event("uci:list_nodes"); return nodes end,
    get_node = function(id)
      event("uci:get_node:" .. tostring(id))
      local forced = options.get_node_outcome
      if forced then return forced == "ok" and by_id[id] or nil, forced end
      local value = by_id[id]
      return value, value and "ok" or "missing"
    end,
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
      if options.throw_commit then error("password=commit-secret") end
      if (options.commit_failures or 0) > 0 then
        options.commit_failures = options.commit_failures - 1
        return false, "pre_commit_failed"
      end
      if options.commit_ok == false then return false, options.commit_outcome or "pre_commit_failed" end
      return true, options.commit_outcome or "committed"
    end,
    revert = function() event("uci:revert"); global.active_node = original_active; return true end
  }
  local fs = {
    acquire_lock = acquire_fixture_lock,
    release_lock = release_fixture_lock,
    lock_state = function(path)
      event("fs:lock_state:" .. path)
      if options.lock_state then return options.lock_state(path) end
      return options.busy and "held" or "unlocked"
    end,
    allocate_generation = function()
      generation_count = generation_count + 1
      return options.generation or ("123-" .. generation_count)
    end,
    list_generation_files = function() return options.generation_files or {} end,
    trash_generation = function(directory, generation)
      event("fs:trash_generation:" .. generation)
      if options.trash_ok == false then return nil end
      local token = generation
      if files[directory .. "/generation-" .. generation .. ".config"] ~= nil then
        files[directory .. "/.trash-" .. token .. ".config"] = files[directory .. "/generation-" .. generation .. ".config"]
        files[directory .. "/.trash-" .. token .. ".active"] = files[directory .. "/generation-" .. generation .. ".active"]
      end
      files[directory .. "/generation-" .. generation .. ".config"] = nil
      files[directory .. "/generation-" .. generation .. ".active"] = nil
      return token
    end,
    delete_trashed_generation = function(directory, token)
      event("fs:delete_trashed_generation:" .. token)
      if (options.delete_trash_failures or 0) > 0 then
        options.delete_trash_failures = options.delete_trash_failures - 1
        return false
      end
      if options.delete_trash_ok == false then return false end
      files[directory .. "/.trash-" .. token .. ".config"] = nil
      files[directory .. "/.trash-" .. token .. ".active"] = nil
      return true
    end,
    remove_generation = function(directory, generation)
      event("fs:remove_generation:" .. generation)
      files[directory .. "/generation-" .. generation .. ".config"] = nil
      files[directory .. "/generation-" .. generation .. ".active"] = nil
      return true
    end,
    read = function(path, maximum)
      event("fs:read:" .. path)
      if options.read_errors and options.read_errors[path] then return nil, options.read_errors[path] end
      if files[path] == nil then return nil, "missing" end
      if maximum and #files[path] > maximum then return nil, "too_large" end
      return files[path]
    end,
    exists = function(path) event("fs:exists:" .. path); return files[path] ~= nil end,
    write_temp = function(path, content)
      if path == EXIT_IP_CACHE and options.cache_write_race then
        local competing_lock = acquire_fixture_lock(LOCK)
        if competing_lock then
          state.competing_switch_started = true
          global.active_node = "new"
          release_fixture_lock(competing_lock)
        end
      end
      local temporary = path .. ".tmp.123"
      event("fs:write_temp:" .. temporary)
      state.writes[#state.writes + 1] = { path = path, content = content }
      files[temporary] = content
      return { path = temporary }
    end,
    chmod = function(path, mode) event("fs:chmod:" .. path .. ":" .. tostring(mode)); return true end,
    fsync = function(handle)
      event("fs:fsync:" .. handle.path)
      if options.throw_fsync or options.fsync_fail_path == handle.path or (options.fsync_failures or 0) > 0 then
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
    run = function(argv, deadline)
      event("exec:run:" .. table.concat(argv, "|"))
      state.validation_deadlines[#state.validation_deadlines + 1] = deadline
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
    listener_ready = function(kind, address, port, deadline)
      event("exec:listener:" .. kind .. ":" .. address .. ":" .. tostring(port))
      state.listener_deadlines = state.listener_deadlines or {}
      state.listener_deadlines[#state.listener_deadlines + 1] = deadline
      if options.listener_hook then options.listener_hook(kind, deadline, global) end
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
    observe_exit_ip = function(kind, address, port, health_url, deadline)
      event("exec:exit_ip:" .. kind .. ":" .. address .. ":" .. tostring(port))
      state.exit_ip_url, state.exit_ip_deadline = health_url, deadline
      if options.observe_hook then options.observe_hook(global, files) end
      if options.exit_ip_throw then error("password=exit-secret") end
      return options.exit_ip
    end,
    service_state = function() return options.service_state or "running" end
  }
  state.runtime = assert(runtime.new({
    uci = uci, fs = fs, exec = exec, json = { stringify = stringify },
    network = function() return "192.168.6.1" end,
    now = options.now or function() return 123 end,
    wall_time = options.wall_time or function() return 1785326400 end,
    sleep = function() event("sleep"); if options.sleep_hook then options.sleep_hook() end end
  }))
  return state
end

local function event_index(events, sought)
  for index, value in ipairs(events) do if value == sought then return index end end
end

local function occurrences(value, sought)
  local count, offset = 0, 1
  while true do
    local first, last = (value or ""):find(sought, offset, true)
    if not first then return count end
    count, offset = count + 1, last + 1
  end
end

t.test("exit IP cache resides under the protected runtime directory", function()
  t.eq(runtime.paths.exit_ip_cache, "/var/etc/xc/exit-ip-cache")
end)

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
  local empty = fixture({ global = { active_node = "", socks_port = 7890, http_port = 10809 }, nodes = { node("only", true) } })
  local empty_result = empty.runtime:render(nil, "/tmp/render.json")
  t.eq(empty_result.ok, true)
  t.eq(empty_result.node, "only")
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

t.test("render records exactly one final debug or error event with wall time", function()
  local succeeded = fixture()
  local value = succeeded.runtime:render("new", "/tmp/render.json")
  t.eq(value.ok, true)
  local line = succeeded.files[LOG]
  t.eq(occurrences(line, '"message":"configuration render completed"'), 1)
  t.contains(line, '"level":"debug"')
  t.contains(line, '"code":"rendered"')
  t.contains(line, '"node":"new"')
  t.contains(line, '"outcome":"success"')
  t.contains(line, '"time":1785326400')

  local failed = fixture()
  value = failed.runtime:render("bad;password=render-secret", "/tmp/render.json")
  t.eq(value.code, "invalid_node")
  line = failed.files[LOG]
  t.eq(occurrences(line, '"message":"configuration render completed"'), 1)
  t.contains(line, '"level":"error"')
  t.contains(line, '"code":"invalid_node"')
  t.contains(line, '"outcome":"failure"')
  t.eq(line:find("render-secret", 1, true), nil)
end)

t.test("switch records exactly one final info or error event", function()
  local succeeded = fixture({ files = { [RUNTIME] = "old-runtime" } })
  local value = succeeded.runtime:switch("new")
  t.eq(value.ok, true)
  local line = succeeded.files[LOG]
  t.eq(occurrences(line, '"message":"node switch completed"'), 1)
  t.contains(line, '"level":"info"')
  t.contains(line, '"code":"switched"')
  t.contains(line, '"node":"new"')
  t.contains(line, '"outcome":"success"')
  t.eq(occurrences(line, '"message":"switched to node"'), 0)

  local failed = fixture({ validation_ok = false, files = { [RUNTIME] = "old-runtime" } })
  value = failed.runtime:switch("new")
  t.eq(value.code, "validation_failed")
  line = failed.files[LOG]
  t.eq(occurrences(line, '"message":"node switch completed"'), 1)
  t.contains(line, '"level":"error"')
  t.contains(line, '"code":"validation_failed"')
  t.contains(line, '"outcome":"failure"')
end)

t.test("rollback records exactly one final info or error event", function()
  local files = merge({ [RUNTIME] = "new-runtime" }, journal("old-runtime", "old"))
  local succeeded = fixture({ files = files, global = { active_node = "new", socks_port = 7890, http_port = 10809 } })
  local value = succeeded.runtime:rollback()
  t.eq(value.ok, true)
  local line = succeeded.files[LOG]
  t.eq(occurrences(line, '"message":"rollback completed"'), 1)
  t.contains(line, '"level":"info"')
  t.contains(line, '"code":"rolled_back"')
  t.contains(line, '"outcome":"success"')

  local failed = fixture()
  value = failed.runtime:rollback()
  t.eq(value.code, "no_rollback_state")
  line = failed.files[LOG]
  t.eq(occurrences(line, '"message":"rollback completed"'), 1)
  t.contains(line, '"level":"error"')
  t.contains(line, '"code":"no_rollback_state"')
  t.contains(line, '"outcome":"failure"')
end)

t.test("event logger faults never change runtime results or primary last_error", function()
  local succeeded = fixture({ files = { [RUNTIME] = "old-runtime" } })
  local success_attempts = 0
  succeeded.runtime.log = function(self)
    success_attempts = success_attempts + 1
    self.last_error = "logger_fault"
    error("password=logger-secret")
  end
  local called, value = pcall(succeeded.runtime.switch, succeeded.runtime, "new")
  t.eq(called, true)
  t.eq(value.ok, true)
  t.eq(value.code, "switched")
  t.eq(success_attempts, 1)
  t.eq(succeeded.runtime.last_error, nil)

  local failed = fixture({ validation_ok = false, files = { [RUNTIME] = "old-runtime" } })
  local failure_attempts = 0
  failed.runtime.log = function(self)
    failure_attempts = failure_attempts + 1
    self.last_error = "logger_fault"
    error("raw logger exception")
  end
  called, value = pcall(failed.runtime.switch, failed.runtime, "new")
  t.eq(called, true)
  t.eq(value.ok, false)
  t.eq(value.code, "validation_failed")
  t.eq(failure_attempts, 1)
  t.eq(failed.runtime.last_error, "validation_failed")
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
  local candidate = XRAY_CANDIDATE
  local test_event = "exec:run:/usr/bin/xray|run|-test|-c|" .. candidate
  t.truthy(event_index(state.events, test_event) < event_index(state.events, "exec:restart"))
  t.truthy(event_index(state.events, test_event) < event_index(state.events, "fs:write_temp:/etc/xc/rollback/generation-123-1.config.tmp.123"))
  t.truthy(event_index(state.events, "exec:health:http:192.168.6.1:10809") < event_index(state.events, "uci:set_active:new"))
  t.truthy(event_index(state.events, "uci:set_active:new") < event_index(state.events, "uci:commit"))
  t.truthy(event_index(state.events, "uci:commit") < event_index(state.events, "fs:rename:" .. MANIFEST .. ".tmp.123:" .. MANIFEST))
  t.eq(state.health_url, "https://health.invalid/generate_204")
  t.eq(state.health_deadline, 128)
  t.truthy(event_index(state.events, MAIN_UNLOCK))
  t.eq(state.events[#state.events], LOG_UNLOCK)
end)

t.test("runtime treats a committed hardening warning as committed state", function()
  local state = fixture({
    commit_outcome = "committed_hardening_failed",
    files = { [RUNTIME] = "old-runtime" }
  })
  local result = state.runtime:switch("new")
  t.eq(result.ok, true)
  t.eq(result.commit_outcome, "committed_hardening_failed")
  t.eq(state.global.active_node, "new")
  t.eq(event_index(state.events, "uci:revert"), nil)
end)

t.test("runtime reverts only a definitely uncommitted active-node commit", function()
  local state = fixture({
    commit_failures = 1,
    files = { [RUNTIME] = "old-runtime" }
  })
  local result = state.runtime:switch("new")
  t.eq(result.ok, false)
  t.eq(result.code, "commit_failed")
  t.truthy(event_index(state.events, "uci:revert"))
  t.eq(state.global.active_node, "old")
  t.eq(state.files[TRANSACTION], nil)
end)

t.test("runtime stops an uncertain commit and preserves transaction evidence", function()
  for _, options in ipairs({
    { commit_ok = false, commit_outcome = "commit_unknown" },
    { throw_commit = true }
  }) do
    options.files = { [RUNTIME] = "old-runtime" }
    local state = fixture(options)
    local result = state.runtime:switch("new")
    t.eq(result.ok, false)
    t.eq(result.code, "commit_unknown")
    t.eq(event_index(state.events, "uci:revert"), nil)
    t.truthy(event_index(state.events, "exec:stop"))
    t.truthy(type(state.files[TRANSACTION]) == "string")
    t.contains(state.files[TRANSACTION], "\ncandidate_healthy\n")
    t.eq(state.files[RUNTIME] == "old-runtime", false)
  end

  local rollback_files = merge({ [RUNTIME] = "new-runtime" }, journal("old-runtime", "old"))
  local rollback = fixture({
    commit_ok = false, commit_outcome = "commit_unknown", files = rollback_files,
    global = { active_node = "new", socks_port = 7890, http_port = 10809 }
  })
  local rollback_result = rollback.runtime:rollback()
  t.eq(rollback_result.ok, false)
  t.eq(rollback_result.code, "commit_unknown")
  t.eq(event_index(rollback.events, "uci:revert"), nil)
  t.truthy(event_index(rollback.events, "exec:stop"))
  t.contains(rollback.files[TRANSACTION], "\ncandidate_healthy\n")
end)

t.test("typed node read failures fail closed in load switch and status", function()
  local loaded = fixture({ get_node_outcome = "read_failed" })
  local _, _, load_error = loaded.runtime:_load("new")
  t.eq(load_error.code, "internal_error")

  local switched = fixture({
    get_node_outcome = "read_failed",
    files = { [RUNTIME] = "old-runtime" }
  })
  local switch_result = switched.runtime:switch("new")
  t.eq(switch_result.ok, false)
  t.eq(switch_result.code, "internal_error")
  t.eq(event_index(switched.events, "fs:rename:" .. XRAY_CANDIDATE .. ":" .. RUNTIME), nil)

  local status_state = fixture({ get_node_outcome = "read_failed" })
  local status_result = status_state.runtime:status()
  t.eq(status_result.ok, false)
  t.eq(status_result.code, "internal_error")
end)

t.test("runtime maps only typed missing nodes to missing_node", function()
  local missing = fixture({ get_node_outcome = "missing" })
  local _, _, missing_error = missing.runtime:_load("new")
  t.eq(missing_error.code, "missing_node")
  t.eq(missing.runtime:status().code, "missing_node")

  local uncertain = fixture({ get_node_outcome = "future_outcome" })
  local _, _, uncertain_error = uncertain.runtime:_load("new")
  t.eq(uncertain_error.code, "internal_error")
end)

t.test("failed switch preserves the prior successful rollback generation", function()
  local state = fixture({
    health_failures = { http = 1 },
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
  t.truthy(event_index(state.events, MAIN_UNLOCK))
  t.eq(state.events[#state.events], LOG_UNLOCK)
  t.eq(state.files[XRAY_CANDIDATE], nil)

  local invalid_health = fixture({ global = { active_node = "old", socks_port = 7890, http_port = 10809, health_url = "file:///secret", health_timeout = 999 } })
  result = invalid_health.runtime:switch("new")
  t.eq(result.code, "generation_failed")
  t.eq(event_index(invalid_health.events, "exec:restart"), nil)
end)

t.test("listener and health failures restore the previous config and active node", function()
  for failure, code in pairs({ listener_failures = "listener_failed", health_failures = "health_failed" }) do
    local options = { files = { [RUNTIME] = "old-runtime" } }
    options[failure] = failure == "listener_failures" and { http = 10 } or { socks = 1 }
    local state = fixture(options)
    local result = state.runtime:switch("new")
    t.eq(result.ok, false)
    t.eq(result.code, code)
    t.eq(state.files[RUNTIME], "old-runtime")
    t.eq(state.global.active_node, "old")
    t.truthy(event_index(state.events, "uci:set_active:old"))
    t.truthy(event_index(state.events, MAIN_UNLOCK))
    t.eq(state.events[#state.events], LOG_UNLOCK)
  end
end)

t.test("listener readiness waits and both health entries are always checked", function()
  local state = fixture({ listener_failures = { socks = 1 }, files = { [RUNTIME] = "old-runtime" } })
  local result = state.runtime:switch("new")
  t.eq(result.ok, true)
  t.truthy(event_index(state.events, "sleep"))

  local failed = fixture({ health_failures = { socks = 1 }, files = { [RUNTIME] = "old-runtime" } })
  result = failed.runtime:switch("new")
  t.eq(result.code, "health_failed")
  t.truthy(event_index(failed.events, "exec:health:socks:192.168.6.1:7890"))
  t.truthy(event_index(failed.events, "exec:health:http:192.168.6.1:10809"))
end)

t.test("a failed first switch stops service when no old runtime exists", function()
  local state = fixture({ health_failures = { http = 1 } })
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
  t.eq(event_index(state.events, MAIN_UNLOCK), nil)
end)

t.test("central lock protects runtime render and rejects acquire or release faults", function()
  local rendered = fixture()
  local result = rendered.runtime:render("new", RUNTIME)
  t.eq(result.ok, true)
  t.eq(rendered.events[1], "fs:lock:" .. LOCK)
  t.truthy(event_index(rendered.events, MAIN_UNLOCK))
  t.eq(rendered.events[#rendered.events], LOG_UNLOCK)

  local acquire = fixture({ throw_acquire = true })
  result = acquire.runtime:switch("new")
  t.eq(result.code, "internal_error")
  t.eq(result.message:find("lock-secret", 1, true), nil)

  local release = fixture({ release_ok = false, validation_ok = false })
  result = release.runtime:switch("new")
  t.eq(result.code, "internal_error")
  t.eq(occurrences(release.files[LOG], '"message":"node switch completed"'), 1)
  t.contains(release.files[LOG], '"code":"internal_error"')
end)

t.test("migration exclusive capability renders and writes under one runtime lock", function()
  local state = fixture({ nodes = { node("only", true) }, global = { active_node = "only", socks_port = 7890, http_port = 10809 } })
  t.eq(type(state.runtime.exclusive), "function")
  local value = state.runtime:exclusive("migration", function(capability)
    local rendered = capability.render("only", "/var/etc/xc/migration-candidate.json")
    if not rendered.ok then return rendered end
    capability.write("/etc/xc/migration-complete", "marker")
    return { ok = true, code = "rendered", message = "configuration rendered" }
  end)
  t.eq(value.ok, true)
  local joined = table.concat(state.events, "|")
  local first_lock = assert(joined:find("fs:lock:/var/lock/xc.lock", 1, true))
  local write = assert(joined:find("fs:write_temp:/etc/xc/migration-complete", 1, true))
  local unlock = assert(joined:find(MAIN_UNLOCK, 1, true))
  t.truthy(first_lock < write and write < unlock)
  local _, locks = joined:gsub("fs:lock:/var/lock/xc.lock", "")
  t.eq(locks, 1)
  t.eq(occurrences(state.files[LOG], '"message":"configuration render completed"'), 1)
end)

t.test("adapter exceptions release the lock and return generic secret-safe errors", function()
  local state = fixture({ throw_set_active = true, files = { [RUNTIME] = "old-runtime" } })
  local result = state.runtime:switch("new")
  t.eq(result.ok, false)
  t.eq(result.code, "recovery_failed")
  t.eq(result.message:find("adapter-secret", 1, true), nil)
  t.truthy(event_index(state.events, MAIN_UNLOCK))
  t.eq(state.events[#state.events], LOG_UNLOCK)
end)

t.test("atomic write failures close and remove temporary files", function()
  local state = fixture({ fsync_fail_path = XRAY_CANDIDATE .. ".tmp.123" })
  local result = state.runtime:switch("new")
  t.eq(result.ok, false)
  t.eq(result.code, "internal_error")
  local temporary = XRAY_CANDIDATE .. ".tmp.123"
  t.truthy(event_index(state.events, "fs:close:" .. temporary))
  t.truthy(event_index(state.events, "fs:remove:" .. temporary))
  t.eq(state.files[temporary], nil)
  t.truthy(event_index(state.events, MAIN_UNLOCK))
  t.eq(state.events[#state.events], LOG_UNLOCK)
end)

t.test("rollback reports no snapshot and restores a one-generation snapshot", function()
  local none = fixture()
  local result = none.runtime:rollback()
  t.eq(result.ok, false)
  t.eq(result.code, "no_rollback_state")
  t.truthy(event_index(none.events, MAIN_UNLOCK))
  t.eq(none.events[#none.events], LOG_UNLOCK)

  local state = fixture({ files = merge({ [RUNTIME] = "new-runtime" }, journal("old-runtime", "old")), global = { active_node = "new", socks_port = 7890, http_port = 10809 } })
  result = state.runtime:rollback()
  t.eq(result.ok, true)
  t.eq(result.code, "rolled_back")
  t.eq(state.files[RUNTIME], "old-runtime")
  t.eq(state.global.active_node, "old")
  t.eq(state.files[MANIFEST], nil)
  t.truthy(event_index(state.events, "fs:chmod:" .. XRAY_CANDIDATE .. ".tmp.123:0600") < event_index(state.events, "exec:restart"))
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
    t.truthy(event_index(state.events, MAIN_UNLOCK))
    t.eq(state.events[#state.events], LOG_UNLOCK)
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

t.test("status observes a bounded whitelisted exit IP through the local proxy", function()
  local valid = fixture({ exit_ip = "203.0.113.9\n" })
  local status = valid.runtime:status()
  t.eq(status.exit_ip, "203.0.113.9")
  t.eq(valid.exit_ip_url, valid.global.health_url)
  t.eq(valid.exit_ip_deadline, 128)
  t.truthy(event_index(valid.events, "exec:exit_ip:socks:192.168.6.1:7890"))

  for _, unsafe in ipairs({ "", "203.0.113.9 secret", "https://credential.invalid", "999.1.1.1", "::::", "1:2", string.rep("1", 200) }) do
    local failed_fixture = fixture({ exit_ip = unsafe })
    local failed = failed_fixture.runtime:status()
    t.eq(failed.ok, true); t.eq(failed.exit_ip, nil)
  end
  local thrown_fixture = fixture({ exit_ip_throw = true })
  local thrown = thrown_fixture.runtime:status()
  t.eq(thrown.ok, true); t.eq(thrown.exit_ip, nil)
end)

t.test("status keeps one listener deadline and computes exit observation deadline afterwards", function()
  local clock = 10
  local state = fixture({
    exit_ip = "203.0.113.9",
    now = function() return clock end,
    listener_hook = function(kind)
      if kind == "http" then clock = 20 end
    end
  })
  local status = state.runtime:status()
  t.eq(status.exit_ip, "203.0.113.9")
  t.eq(state.listener_deadlines[1], 12)
  t.eq(state.listener_deadlines[2], 12)
  t.eq(state.exit_ip_deadline, 25)
end)

t.test("status reuses only a fresh strict same-node exit IP cache", function()
  local wall_now = 1000
  local valid_cache = "node=old\nobserved_at=941\nip=203.0.113.10\n"
  local cached = fixture({ shared_files = { [EXIT_IP_CACHE] = valid_cache }, wall_time = function() return wall_now end, exit_ip = "198.51.100.1" })
  t.eq(cached.runtime:status().exit_ip, "203.0.113.10")
  t.eq(event_index(cached.events, "exec:exit_ip:socks:192.168.6.1:7890"), nil)
  t.truthy(event_index(cached.events, "fs:read:" .. EXIT_IP_CACHE))

  local invalid = {
    "node=new\nobserved_at=999\nip=203.0.113.10\n",
    "node=old\nobserved_at=940\nip=203.0.113.10\n",
    "node=old\nobserved_at=1001\nip=203.0.113.10\n",
    "node=old\nobserved_at=1.5\nip=203.0.113.10\n",
    "node=old\nobserved_at=abc\nip=203.0.113.10\n",
    "node=old\nobserved_at=999\nip=999.0.0.1\n",
    "node=bad;node\nobserved_at=999\nip=203.0.113.10\n",
    "node=old\nnode=old\nobserved_at=999\nip=203.0.113.10\n",
    "node=old\nobserved_at=999\nip=203.0.113.10\nextra=x\n",
    "node=old\nobserved_at=999\nip=203.0.113.10",
    "observed_at=999\nnode=old\nip=203.0.113.10\n",
    string.rep("x", 513)
  }
  for index, content in ipairs(invalid) do
    local state = fixture({ shared_files = { [EXIT_IP_CACHE] = content }, wall_time = function() return wall_now end, exit_ip = "198.51.100.2" })
    t.eq(state.runtime:status().exit_ip, "198.51.100.2", "accepted malformed cache " .. index)
    t.truthy(event_index(state.events, "exec:exit_ip:socks:192.168.6.1:7890"), "did not observe for malformed cache " .. index)
  end
end)

t.test("successful exit observation writes an atomic private node cache", function()
  local state = fixture({ exit_ip = "2001:db8::9\n", wall_time = function() return 1785326499 end })
  local status = state.runtime:status()
  t.eq(status.exit_ip, "2001:db8::9")
  t.eq(state.files[EXIT_IP_CACHE], "node=old\nobserved_at=1785326499\nip=2001:db8::9\n")
  local temporary = EXIT_IP_CACHE .. ".tmp.123"
  t.truthy(event_index(state.events, "fs:write_temp:" .. temporary))
  t.truthy(event_index(state.events, "fs:chmod:" .. temporary .. ":0600"))
  t.truthy(event_index(state.events, "fs:fsync:" .. temporary))
  t.truthy(event_index(state.events, "fs:rename:" .. temporary .. ":" .. EXIT_IP_CACHE))
end)

t.test("failed exit observation without a fresh cache stays secret-safe", function()
  for _, options in ipairs({
    { exit_ip = "curl: password=secret body={credential}" },
    { exit_ip_throw = true }
  }) do
    local state = fixture(options)
    local status = state.runtime:status()
    t.eq(status.ok, true)
    t.eq(status.exit_ip, nil)
    t.eq(state.files[EXIT_IP_CACHE], nil)
    local encoded = stringify(status)
    t.eq(encoded:find("curl", 1, true), nil)
    t.eq(encoded:find("secret", 1, true), nil)
    t.eq(encoded:find("credential", 1, true), nil)
  end
end)

t.test("status drops exit observations when active node or runtime lock changes", function()
  local changed_node = fixture({
    exit_ip = "203.0.113.20",
    observe_hook = function(global) global.active_node = "new" end
  })
  local status = changed_node.runtime:status()
  t.eq(status.exit_ip, nil)
  t.eq(changed_node.files[EXIT_IP_CACHE], nil)
  t.truthy(event_index(changed_node.events, "fs:lock:" .. LOCK))
  t.truthy(event_index(changed_node.events, MAIN_UNLOCK))

  local changed_lock_options = { exit_ip = "203.0.113.21" }
  changed_lock_options.lock_state = function() return changed_lock_options.busy and "held" or "unlocked" end
  changed_lock_options.observe_hook = function() changed_lock_options.busy = true end
  local changed_lock = fixture(changed_lock_options)
  status = changed_lock.runtime:status()
  t.eq(status.exit_ip, nil)
  t.eq(changed_lock.files[EXIT_IP_CACHE], nil)
end)

t.test("exit cache commit excludes a switch starting after the final context check", function()
  local state = fixture({ exit_ip = "203.0.113.22", cache_write_race = true })
  local status = state.runtime:status()
  t.eq(state.competing_switch_started, nil)
  t.eq(state.global.active_node, "old")
  t.eq(status.exit_ip, "203.0.113.22")
  t.eq(state.files[EXIT_IP_CACHE], "node=old\nobserved_at=1785326400\nip=203.0.113.22\n")
  local locked = assert(event_index(state.events, "fs:lock:" .. LOCK))
  local replaced = assert(event_index(state.events, "fs:rename:" .. EXIT_IP_CACHE .. ".tmp.123:" .. EXIT_IP_CACHE))
  local unlocked = assert(event_index(state.events, MAIN_UNLOCK))
  t.truthy(locked < replaced and replaced < unlocked)
end)

t.test("status never returns another node cache across a switch race", function()
  local files = { [EXIT_IP_CACHE] = "node=old\nobserved_at=999\nip=203.0.113.30\n" }
  local state = fixture({
    shared_files = files,
    wall_time = function() return 1000 end,
    lock_state = function() return "unlocked" end,
    listener_hook = function(kind, _, global)
      if kind == "http" then global.active_node = "new" end
    end,
    exit_ip = nil
  })
  local status = state.runtime:status()
  t.eq(status.exit_ip, nil)
end)

t.test("exit cache fails closed on a non-idle operation marker", function()
  local files = {
    [STATUS] = "operation=switch\ntime=1\n",
    [EXIT_IP_CACHE] = "node=old\nobserved_at=999\nip=203.0.113.31\n"
  }
  local state = fixture({ shared_files = files, wall_time = function() return 1000 end })
  local status = state.runtime:status()
  t.eq(status.operation, "idle")
  t.eq(status.exit_ip, nil)
end)

t.test("exit IP status accepts strict IPv4 and IPv6 forms and rejects malformed addresses", function()
  local valid = {
    "0.0.0.0", "255.255.255.255", "::", "::1", "2001:db8::1",
    "2001:db8:0:1:2:3:4:5", "1:2:3:4:5:6:7:8", "1:2:3:4:5:6:7::",
    "::1:2:3:4:5:6:7", "::ffff:192.0.2.1", "2001:db8::192.0.2.1", "1:2:3:4:5::192.0.2.1"
  }
  for _, address in ipairs(valid) do
    local state = fixture({ exit_ip = address })
    t.eq(state.runtime:status().exit_ip, address, "rejected valid address " .. address)
  end
  local invalid = {
    ":::1", "1:::2", ":1:2:3:4:5:6:7", "1:2:3:4:5:6:7:8:",
    "1:2:3:4:5:6:7", "1:2:3:4:5:6:7:8:9", "1::2::3", "2001:db8::g",
    "1:2:3:4:5:6:7:8::", "::1:2:3:4:5:6:7:8", "1:2:3:4:5:6::192.0.2.1",
    "::ffff:192.0.2.999", "::ffff:192.0.2", "192.0.2.1::", "2001:db8:192.0.2.1::1",
    "01.2.3.4", "1.2.3.4.5"
  }
  for _, address in ipairs(invalid) do
    local state = fixture({ exit_ip = address })
    t.eq(state.runtime:status().exit_ip, nil, "accepted malformed address " .. address)
  end
end)

t.test("status skips exit IP observation unless service and SOCKS listener are healthy", function()
  local stopped = fixture({ service_state = "stopped", exit_ip = "203.0.113.9" })
  local status = stopped.runtime:status()
  t.eq(status.service, "stopped"); t.eq(status.exit_ip, nil)
  t.eq(event_index(stopped.events, "exec:exit_ip:socks:192.168.6.1:7890"), nil)

  local unavailable = fixture({ listener_fail = "socks", exit_ip = "203.0.113.9" })
  status = unavailable.runtime:status()
  t.eq(status.listeners.socks, false); t.eq(status.exit_ip, nil)
  t.eq(event_index(unavailable.events, "exec:exit_ip:socks:192.168.6.1:7890"), nil)
end)

t.test("every runtime Xray validation receives a finite monotonic deadline", function()
  local current = fixture({ files = { [RUNTIME] = "runtime" } })
  t.eq(current.runtime:test_current().ok, true)
  t.eq(current.validation_deadlines[1], 153)

  local switched = fixture({ files = { [RUNTIME] = "old-runtime" } })
  t.eq(switched.runtime:switch("new").ok, true)
  t.truthy(#switched.validation_deadlines >= 1)
  for _, deadline in ipairs(switched.validation_deadlines) do t.eq(deadline, 153) end
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

t.test("switch durably records install intent before replacing runtime", function()
  local state = fixture({ files = { [RUNTIME] = "old-runtime" } })
  t.eq(state.runtime:switch("new").ok, true)
  local intent, replace
  for index, write in ipairs(state.writes) do
    if write.path == TRANSACTION and write.content:find("\ninstall_intent\n", 1, true) then intent = index end
  end
  replace = event_index(state.events, "fs:rename:" .. XRAY_CANDIDATE .. ":" .. RUNTIME)
  local intent_rename = event_index(state.events, "fs:rename:" .. TRANSACTION .. ".tmp.123:" .. TRANSACTION)
  t.truthy(intent)
  t.truthy(intent_rename < replace)
  t.truthy(event_index(state.events, "fs:fsync_dir:/etc/xc/rollback") < replace)
end)

t.test("recover_pending restores a checksum-validated pre-UCI transaction idempotently", function()
  local files = {
    [RUNTIME] = "candidate-runtime",
    ["/etc/xc/rollback/generation-123-1.config"] = "old-runtime",
    ["/etc/xc/rollback/generation-123-1.active"] = "old",
    [TRANSACTION] = transaction("install_intent", "old-runtime", "old", "candidate-runtime", "new")
  }
  local state = fixture({ shared_files = files, global = { active_node = "old", socks_port = 7890, http_port = 10809 } })
  local first = state.runtime:recover_pending()
  t.eq(first.ok, true)
  t.eq(files[RUNTIME], "old-runtime")
  local validation = "exec:run:/usr/bin/xray|run|-test|-c|/etc/xc/rollback/generation-123-1.config"
  t.truthy(event_index(state.events, validation) < event_index(state.events, "fs:write_temp:" .. RUNTIME .. ".tmp.123"))
  t.eq(files[TRANSACTION], nil)
  t.eq(state.runtime:recover_pending().ok, true)
  t.eq(files[RUNTIME], "old-runtime")
end)

t.test("automatic preflight recovers before render mutates its output", function()
  local files = {
    [RUNTIME] = "candidate-runtime",
    ["/etc/xc/rollback/generation-123-1.config"] = "old-runtime",
    ["/etc/xc/rollback/generation-123-1.active"] = "old",
    [TRANSACTION] = transaction("install_intent", "old-runtime", "old", "candidate-runtime", "new")
  }
  local state = fixture({ shared_files = files })
  local rendered = state.runtime:render("new", "/tmp/render.json")
  t.eq(rendered.ok, true)
  t.eq(files[RUNTIME], "old-runtime")
  t.truthy(event_index(state.events, "exec:restart") < event_index(state.events, "fs:write_temp:/tmp/render.json.tmp.123"))
end)

t.test("typed read failures abort switch and rollback before installation", function()
  local switched = fixture({ files = { [RUNTIME] = "old-runtime" }, read_errors = { [RUNTIME] = "io_error" } })
  local value = switched.runtime:switch("new")
  t.eq(value.ok, false)
  t.eq(switched.files[RUNTIME], "old-runtime")
  t.eq(switched.files[XRAY_CANDIDATE], nil)
  t.eq(event_index(switched.events, "fs:rename:" .. XRAY_CANDIDATE .. ":" .. RUNTIME), nil)

  local files = merge({ [RUNTIME] = "new-runtime" }, journal("old-runtime", "old"))
  local rolled = fixture({ files = files, read_errors = { [MANIFEST] = "too_large" } })
  value = rolled.runtime:rollback()
  t.eq(value.ok, false)
  t.eq(rolled.files[RUNTIME], "new-runtime")
  t.eq(event_index(rolled.events, "exec:restart"), nil)
end)

t.test("finalize and recovery_done converge after evidence was already removed", function()
  for _, phase in ipairs({ "finalize", "recovery_done" }) do
    local files = {
      [RUNTIME] = phase == "finalize" and "candidate-runtime" or nil,
      [TRANSACTION] = transaction(phase, "", UNSET_ACTIVE, "candidate-runtime", "new", "switch")
    }
    local state = fixture({ shared_files = files })
    t.eq(state.runtime:recover_pending().ok, true)
    t.eq(files[TRANSACTION], nil)
    t.eq(state.runtime:recover_pending().ok, true)
  end
end)

t.test("log rotation is serialized and retains only complete newline records", function()
  local old = string.rep("z", 262130) .. "\ncomplete\n"
  local state = fixture({ files = { ["/var/log/xc.log"] = old } })
  t.eq(state.runtime:log("next", {}).ok, true)
  t.eq(state.events[1], "fs:lock:/var/lock/xc-log.lock")
  t.eq(state.events[#state.events], LOG_UNLOCK)
  local value = state.files["/var/log/xc.log"]
  t.truthy(#value <= 262144)
  t.eq(value:sub(1, 1), "c")
  t.eq(value:find("z", 1, true), nil)
  t.eq(value:sub(-1), "\n")
end)

t.test("rollback rejects a preservation generation collision before overwriting evidence", function()
  local files = merge({ [RUNTIME] = "new-runtime" }, journal("old-runtime", "old"))
  local state = fixture({ files = files, generation = "100-1", global = { active_node = "new", socks_port = 7890, http_port = 10809 } })
  local value = state.runtime:rollback()
  t.eq(value.ok, false)
  t.eq(state.files["/etc/xc/rollback/generation-100-1.config"], "old-runtime")
  t.truthy(state.files[MANIFEST])
  t.eq(state.files[RUNTIME], "new-runtime")
end)

t.test("scavenge refuses an invalid manifest rather than deleting possibly referenced evidence", function()
  local files = {
    [MANIFEST] = "corrupt-but-present\n",
    ["/etc/xc/rollback/generation-safe.config"] = "evidence",
    ["/etc/xc/rollback/generation-safe.active"] = "old"
  }
  local state = fixture({ shared_files = files, generation_files = { "generation-safe.config", "generation-safe.active" } })
  t.eq(state.runtime:recover_pending().ok, false)
  t.eq(files["/etc/xc/rollback/generation-safe.config"], "evidence")
  t.eq(event_index(state.events, "fs:trash_generation:safe"), nil)
end)

t.test("logging never truncates a UTF-8 sequence", function()
  local state = fixture()
  t.eq(state.runtime:log(string.rep("a", 511) .. "中", {}).ok, true)
  local value = state.files["/var/log/xc.log"]
  t.truthy(valid_utf8(value))
end)

t.test("phase recovery converges across instances before and after UCI commit", function()
  for _, phase in ipairs({ "install_intent", "candidate_healthy", "recovery_intent", "uci_committed", "cleanup_pending" }) do
    local files = {
      [RUNTIME] = "candidate-runtime",
      ["/etc/xc/rollback/generation-123-1.config"] = "old-runtime",
      ["/etc/xc/rollback/generation-123-1.active"] = "old",
      [TRANSACTION] = transaction(phase, "old-runtime", "old", "candidate-runtime", "new")
    }
    if phase == "cleanup_pending" then
      files[MANIFEST] = journal("old-runtime", "old", "123-1")[MANIFEST]
    end
    local committed = phase == "uci_committed" or phase == "cleanup_pending"
    local global = { active_node = committed and "new" or "old", socks_port = 7890, http_port = 10809 }
    local first = fixture({ shared_files = files, global = global })
    t.eq(first.runtime:recover_pending().ok, true, phase)
    t.eq(files[RUNTIME], committed and "candidate-runtime" or "old-runtime", phase)
    local second = fixture({ shared_files = files, global = global })
    t.eq(second.runtime:recover_pending().ok, true, phase)
    t.eq(files[TRANSACTION], nil, phase)
  end
end)

t.test("cleanup interruption leaves a valid new manifest and retryable cleanup_pending", function()
  local files = merge({ [RUNTIME] = "runtime-B" }, journal("runtime-A", "A"))
  local global = { active_node = "B", socks_port = 7890, http_port = 10809 }
  local first = fixture({
    shared_files = files, global = global, delete_trash_ok = false,
    nodes = { node("A", true), node("B", true), node("C", true) }
  })
  t.eq(first.runtime:switch("C").ok, false)
  t.truthy(files[MANIFEST])
  t.contains(files[TRANSACTION], "\ncleanup_pending\n")
  t.eq(files["/etc/xc/rollback/generation-123-1.config"], "runtime-B")

  local second = fixture({ shared_files = files, global = global })
  t.eq(second.runtime:recover_pending().ok, true)
  t.eq(files[TRANSACTION], nil)
  t.truthy(files[MANIFEST])
  t.eq(files["/etc/xc/rollback/generation-123-1.config"], "runtime-B")
  t.eq(files["/etc/xc/rollback/generation-100-1.config"], nil)
end)

t.test("readiness checks the deadline after sleep and after final health success", function()
  local clock = 0
  local state = fixture({
    files = { [RUNTIME] = "old-runtime" }, listener_failures = { socks = 1 },
    now = function() return clock end,
    sleep_hook = function() clock = 6 end
  })
  local value = state.runtime:switch("new")
  t.eq(value.code, "health_failed")
  t.eq(event_index(state.events, "uci:set_active:new"), nil)
end)

t.test("status constrains lock state and marks stale operation with a transaction as interrupted", function()
  local files = {
    ["/var/run/xc-status"] = "operation=switch\ntime=1\n",
    [TRANSACTION] = transaction("install_intent", "old-runtime", "old", "candidate-runtime", "new")
  }
  local state = fixture({ shared_files = files })
  local status = state.runtime:status()
  t.eq(status.lock, "unlocked")
  t.eq(status.operation, "interrupted")
  t.eq(status.recovery_required, true)
end)

t.test("status reports a pending transaction even when shared operation is idle", function()
  local files = {
    ["/var/run/xc-status"] = "operation=idle\nlast_error=recovery_failed\n",
    [TRANSACTION] = transaction("recovery_intent", "old-runtime", "old", "candidate-runtime", "new")
  }
  local status = fixture({ shared_files = files }).runtime:status()
  t.eq(status.operation, "interrupted")
  t.eq(status.recovery_required, true)
end)

t.test("recovery typed-read failures stop the uncertain candidate service", function()
  local files = { [RUNTIME] = "candidate-runtime", [TRANSACTION] = "opaque" }
  local state = fixture({ shared_files = files, read_errors = { [TRANSACTION] = "io_error" } })
  t.eq(state.runtime:recover_pending().code, "recovery_failed")
  t.truthy(event_index(state.events, "exec:stop"))
end)

t.test("switch records cleanup_pending before publishing the new manifest", function()
  local state = fixture({ files = { [RUNTIME] = "old-runtime" } })
  t.eq(state.runtime:switch("new").ok, true)
  local cleanup_write, manifest_write
  for index, write in ipairs(state.writes) do
    if write.path == TRANSACTION and write.content:find("\ncleanup_pending\n", 1, true) then cleanup_write = index end
    if write.path == MANIFEST then manifest_write = index end
  end
  t.truthy(cleanup_write < manifest_write)
end)

t.test("phase transitions cannot confuse a generation token with the phase field", function()
  local files = {
    [RUNTIME] = "candidate-runtime",
    ["/etc/xc/rollback/generation-install_intent.config"] = "old-runtime",
    ["/etc/xc/rollback/generation-install_intent.active"] = "old",
    [TRANSACTION] = transaction("install_intent", "old-runtime", "old", "candidate-runtime", "new", "switch", "install_intent")
  }
  local state = fixture({ shared_files = files })
  t.eq(state.runtime:recover_pending().ok, true)
  local recovery_write
  for _, write in ipairs(state.writes) do
    if write.path == TRANSACTION and write.content:find("recovery_intent", 1, true) then recovery_write = write.content; break end
  end
  local version, token, kind, phase = recovery_write:match("^([^\n]+)\n([^\n]+)\n([^\n]+)\n([^\n]+)\n")
  t.eq(version, "xc-transaction-v2")
  t.eq(token, "install_intent")
  t.eq(kind, "switch")
  t.eq(phase, "recovery_intent")
  t.eq(files[TRANSACTION], nil)
  t.eq(files[RUNTIME], "old-runtime")
end)

t.test("scavenge retries deterministic trash deletion across runtime instances", function()
  local files = {
    ["/etc/xc/rollback/generation-orphan.config"] = "orphan-config",
    ["/etc/xc/rollback/generation-orphan.active"] = "old"
  }
  local first = fixture({
    shared_files = files,
    generation_files = { "generation-orphan.config", "generation-orphan.active" },
    delete_trash_ok = false
  })
  t.eq(first.runtime:recover_pending().code, "recovery_failed")
  t.eq(files["/etc/xc/rollback/generation-orphan.config"], nil)
  t.eq(files["/etc/xc/rollback/.trash-orphan.config"], "orphan-config")

  local second = fixture({
    shared_files = files,
    generation_files = { ".trash-orphan.config", ".trash-orphan.active" }
  })
  t.eq(second.runtime:recover_pending().ok, true)
  t.eq(files["/etc/xc/rollback/.trash-orphan.config"], nil)
  t.eq(files["/etc/xc/rollback/.trash-orphan.active"], nil)
  t.truthy(event_index(second.events, "fs:delete_trashed_generation:orphan"))
end)

t.test("scavenge ignores malformed trash names and propagates post-transaction cleanup failure", function()
  local unrelated = "/etc/xc/rollback/.trash-../outside.config"
  local files = {
    [unrelated] = "untouched",
    ["/etc/xc/rollback/generation-orphan.config"] = "orphan-config",
    ["/etc/xc/rollback/generation-orphan.active"] = "old",
    ["/etc/xc/rollback/generation-123-1.config"] = "old-runtime",
    ["/etc/xc/rollback/generation-123-1.active"] = "old",
    [TRANSACTION] = transaction("finalize", "old-runtime", "old", "candidate-runtime", "new")
  }
  local state = fixture({
    shared_files = files,
    generation_files = { ".trash-../outside.config", ".trash-bad!.active", "generation-orphan.config", "generation-orphan.active" },
    delete_trash_ok = false
  })
  t.eq(state.runtime:recover_pending().code, "recovery_failed")
  t.eq(files[unrelated], "untouched")
  t.eq(event_index(state.events, "fs:delete_trashed_generation:../outside"), nil)
end)

return true
