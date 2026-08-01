local t = require "testlib"
local real_schema = require "xc.schema"
local real_logview = require "xc.logview"

local function json_escape(value)
  return '"' .. value:gsub('[%z\1-\31\\"]', function(character)
    if character == '"' then return '\\"' end
    if character == "\\" then return "\\\\" end
    return string.format("\\u%04x", character:byte())
  end) .. '"'
end

local function json_encode(value)
  local kind = type(value)
  if kind == "nil" then return "null" end
  if kind == "boolean" or kind == "number" then return tostring(value) end
  if kind == "string" then return json_escape(value) end
  assert(kind == "table", "unsupported fixture JSON value")

  local count, maximum, array = 0, 0, true
  for key in pairs(value) do
    count = count + 1
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then array = false
    elseif key > maximum then maximum = key end
  end
  if array and maximum == count then
    local encoded = {}
    for index = 1, maximum do encoded[index] = json_encode(value[index]) end
    return "[" .. table.concat(encoded, ",") .. "]"
  end

  local keys = {}
  for key in pairs(value) do
    assert(type(key) == "string", "unsupported fixture JSON object key")
    keys[#keys + 1] = key
  end
  table.sort(keys)
  local encoded = {}
  for index, key in ipairs(keys) do encoded[index] = json_escape(key) .. ":" .. json_encode(value[key]) end
  return "{" .. table.concat(encoded, ",") .. "}"
end

local function controller_fixture(options)
  options = options or {}
  local state = { reverts = 0, commits = 0, fs_events = {}, log_events = {}, encoded = {} }
  local body = options.body or "{}"
  local http = {
    getenv = function(name)
      if name == "REQUEST_METHOD" then return options.method or "POST" end
      if name == "CONTENT_LENGTH" then return tostring(options.content_length or #body) end
    end,
    content = function()
      if options.content_throw then error("raw-body=content-secret") end
      return body
    end,
    prepare_content = function(value) state.content_type = value end,
    status = function(code) state.status = code end,
    formvalue = function(name)
      if name == "level" then return options.level end
    end,
    write = function(value)
      if options.write_throw then error("password=write-secret") end
      if options.write_yield then coroutine.yield(value) end
      state.response_text = (state.response_text or "") .. value
    end,
    write_json = function(value)
      state.write_json_calls = (state.write_json_calls or 0) + 1
      state.response = value
    end
  }
  local jsonc = {
    stringify = function(value)
      if options.stringify_throw then error("password=stringify-secret") end
      if options.stringify_invalid then return nil end
      local encoded = json_encode(value)
      state.response = value
      state.encoded[encoded] = value
      return encoded
    end,
    parse = function(value) return state.encoded[value] end
  }
  state.parse_response = jsonc.parse
  local node = {
    id = "safe_node", name = "Safe", enabled = true, protocol = "socks",
    server = "127.0.0.1", port = 1080
  }
  local adapters = {
    json = {
      parse = function(value)
        if options.log_json and options.log_json[value] ~= nil then return options.log_json[value] end
        if options.request_parse_throw then error("raw-body=request-secret") end
        return options.request or { section = "safe_node" }
      end,
      stringify = function() return "{}" end
    },
    uci = {
      get_node = options.get_node or function() return node, "ok" end,
      list_nodes = function()
        if type(options.existing_nodes) == "function" then return options.existing_nodes() end
        return options.existing_nodes or {}
      end,
      stage_nodes = function()
        if options.stage_throw then error("password=stage-secret") end
        return options.stage_ok ~= false
      end,
      commit = function()
        state.commits = state.commits + 1
        if options.commit_throw then error("password=commit-secret") end
        return options.commit_ok ~= false, options.commit_outcome or "committed"
      end,
      revert = function() state.reverts = state.reverts + 1; return true end
    },
    fs = {
      ensure_layout = function()
        state.layout_calls = (state.layout_calls or 0) + 1
        if options.layout_throw then error("path=layout-secret") end
        return options.layout_ok ~= false
      end,
      read = function() return "" end,
      remove = function() return true end,
      read_tail = options.read_tail or function(path, maximum)
        state.fs_events[#state.fs_events + 1] = "read_tail:" .. path .. ":" .. tostring(maximum)
        if options.log_error then return nil, options.log_error end
        return options.log_content or ""
      end,
      acquire_lock = options.acquire_lock or function(path)
        state.fs_events[#state.fs_events + 1] = "acquire:" .. path
        if options.lock_busy then return nil end
        return { path = path }
      end,
      truncate = options.truncate or function(path)
        state.fs_events[#state.fs_events + 1] = "truncate:" .. path
        if options.truncate_throw then error("password=truncate-secret") end
        return options.truncate_ok ~= false
      end,
      release_lock = options.release_lock or function(lock)
        state.fs_events[#state.fs_events + 1] = "release:" .. tostring(lock and lock.path)
        if options.release_throw then error("password=release-secret") end
        return options.release_ok ~= false
      end
    },
    exec = {
      xray_logs = function(deadline)
        state.xray_deadline = deadline
        if options.xray_throw then error("stderr=raw-secret-error") end
        return options.xray_content
      end
    },
    now = function() return options.uptime or 7200 end,
    wall_time = function() return options.wall_time or 1785326400 end
  }
  local runtime_instance = options.runtime_instance or {
    switch = function() return { ok = true, code = "switched", node = "safe_node" } end,
    rollback = function() return { ok = true, code = "rolled_back" } end,
    status = function() return { ok = true, service = "running", lock = "unlocked" } end,
    test_current = options.test_current or function() return { ok = true, code = "test_passed" } end,
    record_event = function(_, message, fields, level)
      if options.log_throw then error("password=logger-secret") end
      state.log_events[#state.log_events + 1] = { message = message, fields = fields, level = level }
      return true
    end
  }
  local importer = {
    parse = options.import_parse or function()
      return { nodes = options.import_nodes or { node }, warnings = {} }
    end,
    deduplicate = function(nodes) return nodes, {} end
  }

  local replacements = {
    ["luci.http"] = http,
    ["luci.jsonc"] = jsonc,
    ["xc.schema"] = real_schema,
    ["xc.logview"] = real_logview,
    ["xc.platform"] = { new = function()
      if options.backend_throw then error("password=backend-secret") end
      return adapters
    end },
    ["xc.runtime"] = { new = function()
      if options.runtime_new_throw then error("password=runtime-new-secret") end
      return runtime_instance
    end, paths = {
      log = "/var/log/xc.log", log_lock = "/var/lock/xc-log.lock"
    } },
    ["xc.importer"] = importer,
    ["xc.probe"] = options.probe_module or { new = function()
      return { run = function(_, section, selected, timeout)
        state.probe = { section = section, node = selected, timeout = timeout }
        if options.probe_throw then error("server=probe-secret.invalid") end
        return options.probe_result or { socket = "ok", ping = 12, time = 12, outcome = "tcp" }
      end }
    end }
  }
  local saved = {}
  for name, replacement in pairs(replacements) do saved[name], package.loaded[name] = package.loaded[name], replacement end
  saved["luci.controller.xc"] = package.loaded["luci.controller.xc"]
  package.loaded["luci.controller.xc"] = nil
  assert(loadfile("luasrc/controller/xc.lua"))()
  local controller = assert(package.loaded["luci.controller.xc"])
  package.loaded["luci.controller.xc"] = saved["luci.controller.xc"]
  for name in pairs(replacements) do package.loaded[name] = saved[name] end
  return controller, state
end

t.test("controller fails closed before runtime status when protected layout is unavailable", function()
  for _, options in ipairs({ { layout_ok = false }, { layout_throw = true } }) do
    local controller, state = controller_fixture(options)
    controller.action_status()
    t.eq(state.response.ok, false)
    t.eq(state.response.code, "internal_error")
    t.eq(state.layout_calls, 1)
  end
end)

t.test("get-log returns merged structured entries and an XC-only clear scope", function()
  local xc_line = "xc-warning"
  local controller, state = controller_fixture({
    level = "warning",
    log_content = xc_line,
    log_json = { [xc_line] = { time = 1785327994, level = "warning", message = "XC warning" } },
    xray_content = "Wed Jul 29 20:26:35 2026 daemon.warn xray[31]: Xray warning"
  })
  controller.action_get_log()
  t.eq(state.response.ok, true)
  t.eq(state.response.data.clear_scope, "xc")
  t.eq(#state.response.data.entries, 2)
  t.eq(state.response.data.entries[1].source, "xc")
  t.eq(state.response.data.entries[2].source, "xray")
  t.eq(state.xray_deadline, 7202)
  t.eq(state.fs_events[1], "read_tail:/var/log/xc.log:262144")
end)

t.test("get-log maps structured node IDs to current UCI node names for display", function()
  local line = "xc-node"
  local controller, state = controller_fixture({
    level = "info",
    existing_nodes = {
      { id = "safe_node", name = "Main Node" },
      { id = "other_node", name = "Backup Node" }
    },
    log_content = line,
    log_json = { [line] = {
      time = 1785327994, level = "info", message = "node switched",
      fields = { node = "safe_node", code = "switched" }
    } }
  })
  controller.action_get_log()
  t.eq(state.response.ok, true)
  t.contains(state.response.data.entries[1].message, "node=Main Node")
  t.eq(state.response.data.entries[1].message:find("safe_node", 1, true), nil)
end)

t.test("get-log still returns logs when node name lookup fails", function()
  local line = "xc-node"
  local controller, state = controller_fixture({
    level = "info",
    existing_nodes = function() error("password=list-secret") end,
    log_content = line,
    log_json = { [line] = {
      time = 1785327994, level = "info", message = "node switched",
      fields = { node = "safe_node" }
    } }
  })
  controller.action_get_log()
  t.eq(state.response.ok, true)
  t.contains(state.response.data.entries[1].message, "node=safe_node")
end)

t.test("get-log serializes an empty entry list as a JSON array", function()
  local controller, state = controller_fixture({ level = "warning", log_content = "" })
  controller.action_get_log()
  t.eq(state.write_json_calls, nil)
  t.eq(state.content_type, "application/json")
  t.contains(state.response_text, '"data":{"clear_scope":"xc","entries":[]}')
  t.eq(state.response_text:find('"entries":{}', 1, true), nil)
  local parsed = state.parse_response(state.response_text)
  t.eq(parsed.ok, true)
  t.eq(type(parsed.data.entries), "table")
  t.eq(#parsed.data.entries, 0)
end)

t.test("controller JSON serialization preserves objects arrays and safe fallback envelopes", function()
  local line = "xc-warning"
  local controller, state = controller_fixture({
    level = "warning",
    log_content = line,
    log_json = { [line] = { time = 1, level = "warning", message = "safe" } }
  })
  controller.action_get_log()
  t.contains(state.response_text, '"entries":[{')
  t.contains(state.response_text, '"data":{')

  controller, state = controller_fixture({ level = "invalid" })
  controller.action_get_log()
  t.eq(state.status, 400)
  t.contains(state.response_text, '"ok":false')
  t.contains(state.response_text, '"code":"invalid_request"')

  for _, options in ipairs({ { stringify_throw = true }, { stringify_invalid = true } }) do
    controller, state = controller_fixture(options)
    local called = pcall(controller.action_status)
    t.eq(called, true)
    t.eq(state.status, 500)
    t.eq(state.response_text, '{"ok":false,"code":"internal_error","message":"The request could not be completed."}')
    t.eq(state.response_text:find("stringify%-secret"), nil)
  end
end)

t.test("controller response writer remains yieldable on LuCI 21.02", function()
  local controller = controller_fixture({ write_yield = true })
  local request = coroutine.create(controller.action_status)
  local resumed, encoded = coroutine.resume(request)
  t.eq(resumed, true)
  t.contains(encoded, '"ok":true')
  t.eq(coroutine.status(request), "suspended")
  t.eq(coroutine.resume(request), true)
  t.eq(coroutine.status(request), "dead")
end)

t.test("get-log defaults a missing level to all and rejects every invalid value", function()
  local controller, state = controller_fixture({ log_content = "" })
  controller.action_get_log()
  t.eq(state.response.ok, true)
  t.eq(type(state.response.data.entries), "table")

  for _, level in ipairs({ "", "warn", "Warning", "all ", "debug%00" }) do
    controller, state = controller_fixture({ level = level, log_content = "do-not-read" })
    controller.action_get_log()
    t.eq(state.response.ok, false)
    t.eq(state.response.code, "invalid_request")
    t.eq(state.status, 400)
    t.eq(#state.fs_events, 0)
    t.eq(state.xray_deadline, nil)
  end
end)

t.test("get-log degrades Xray capture failures but fails closed on XC read faults", function()
  local xc_line = "xc-info"
  local options = {
    log_content = xc_line,
    log_json = { [xc_line] = { time = 1, level = "info", message = "XC safe" } },
    xray_throw = true
  }
  local controller, state = controller_fixture(options)
  local called = pcall(controller.action_get_log)
  t.eq(called, true)
  t.eq(state.response.ok, true)
  t.eq(#state.response.data.entries, 1)
  t.eq(state.response.data.entries[1].message, "XC safe")
  t.eq(tostring(state.response):find("raw%-secret%-error"), nil)

  controller, state = controller_fixture({ log_error = "io_error", xray_content = "stderr raw body" })
  called = pcall(controller.action_get_log)
  t.eq(called, true)
  t.eq(state.response.ok, false)
  t.eq(state.response.code, "internal_error")
  t.eq(state.xray_deadline, nil)
  t.eq(tostring(state.response):find("stderr raw body", 1, true), nil)
end)

t.test("controller distinguishes missing nodes from uncertain and throwing UCI reads", function()
  local controller, state = controller_fixture({ get_node = function() return nil, "missing" end })
  controller.action_switch()
  t.eq(state.response.code, "missing_node")

  controller, state = controller_fixture({ get_node = function() return nil, "read_failed" end })
  controller.action_switch()
  t.eq(state.response.code, "internal_error")

  controller, state = controller_fixture({ get_node = function() return nil, "read_failed" end })
  controller.action_probe()
  t.eq(state.response.code, "internal_error")

  controller, state = controller_fixture({ get_node = function() error("password=read-secret") end })
  local called = pcall(controller.action_switch)
  t.eq(called, true)
  t.eq(state.response.code, "internal_error")
  t.eq(state.response.message:find("read%-secret"), nil)
end)

t.test("controller returns a sanitized real probe result", function()
  local controller, state = controller_fixture()
  controller.action_probe()
  t.eq(state.response.ok, true)
  t.eq(state.response.data.socket, "ok")
  t.eq(state.response.data.ping, 12)
  t.eq(state.probe.section, "safe_node")
end)

t.test("controller records every probe result with fixed bounded fields and levels", function()
  local controller, state = controller_fixture({
    body = '{"section":"safe_node","password":"request-secret","server":"secret.invalid"}'
  })
  controller.action_probe()
  t.eq(state.response.ok, true)
  t.eq(#state.log_events, 1)
  local event = state.log_events[1]
  t.eq(event.message, "node probe completed")
  t.eq(event.level, "debug")
  t.eq(event.fields.node, "safe_node")
  t.eq(event.fields.outcome, "success")
  t.eq(event.fields.code, "tcp")
  t.eq(event.fields.ping, 12)
  t.eq(event.fields.time, 12)
  t.eq(event.fields.password, nil)
  t.eq(event.fields.server, nil)

  controller, state = controller_fixture({
    probe_result = { socket = "fail", ping = 0, time = 1000000, outcome = "timeout" }
  })
  controller.action_probe()
  t.eq(state.response.ok, true)
  t.eq(#state.log_events, 1)
  event = state.log_events[1]
  t.eq(event.level, "error")
  t.eq(event.fields.outcome, "failure")
  t.eq(event.fields.code, "timeout")
  t.eq(event.fields.time, 10000)

  controller, state = controller_fixture({
    probe_result = { socket = "fail", ping = 0, time = 1, outcome = "password_secret" }
  })
  controller.action_probe()
  t.eq(state.log_events[1].fields.code, "internal_error")
end)

t.test("controller records early probe failures with stable codes and no request body", function()
  local controller, state = controller_fixture({
    body = '{"password":"request-secret","uri":"vless://secret.invalid"}', request_parse_throw = true
  })
  local called = pcall(controller.action_probe)
  t.eq(called, true)
  t.eq(state.response.code, "validation_failed")
  t.eq(#state.log_events, 1)
  local event = state.log_events[1]
  t.eq(event.message, "node probe completed")
  t.eq(event.level, "error")
  t.eq(event.fields.outcome, "failure")
  t.eq(event.fields.code, "validation_failed")
  t.eq(event.fields.node, nil)
  for _, value in pairs(event.fields) do
    if type(value) == "string" then
      t.eq(value:find("request-secret", 1, true), nil)
      t.eq(value:find("secret.invalid", 1, true), nil)
    end
  end

  controller, state = controller_fixture({ probe_throw = true })
  called = pcall(controller.action_probe)
  t.eq(called, true)
  t.eq(state.response.code, "internal_error")
  t.eq(#state.log_events, 1)
  t.eq(state.log_events[1].fields.code, "internal_error")
end)

t.test("controller records rejected probe and import requests once", function()
  local controller, state = controller_fixture({ method = "GET" })
  controller.action_probe()
  t.eq(state.response.code, "method_not_allowed")
  t.eq(#state.log_events, 1)
  t.eq(state.log_events[1].fields.code, "method_not_allowed")

  controller, state = controller_fixture({ body = "", content_length = 0 })
  controller.action_import_commit()
  t.eq(state.response.code, "validation_failed")
  t.eq(#state.log_events, 1)
  t.eq(state.log_events[1].fields.code, "validation_failed")
  t.eq(state.log_events[1].fields.count, 0)

  controller, state = controller_fixture({ method = "GET", runtime_new_throw = true })
  local called = pcall(controller.action_probe)
  t.eq(called, true)
  t.eq(state.response.code, "method_not_allowed")
end)

t.test("controller contains request body read faults for probe and import", function()
  for _, case in ipairs({
    { action = "action_probe", message = "node probe completed" },
    { action = "action_import_commit", message = "import commit completed" }
  }) do
    local controller, state = controller_fixture({ content_throw = true })
    local called = pcall(controller[case.action])
    t.eq(called, true)
    t.eq(state.response.ok, false)
    t.eq(state.response.code, "internal_error")
    t.eq(state.status, 500)
    t.eq(state.content_type, "application/json")
    t.eq(tostring(state.response.message):find("content-secret", 1, true), nil)
    t.eq(#state.log_events, 1)
    t.eq(state.log_events[1].message, case.message)
    t.eq(state.log_events[1].level, "error")
    t.eq(state.log_events[1].fields.code, "internal_error")
    t.eq(state.log_events[1].fields.outcome, "failure")
  end
end)

t.test("controller rejects disabled and unsupported probe nodes", function()
  local controller, state = controller_fixture({ get_node = function()
    return { id = "safe_node", enabled = false, protocol = "socks", server = "127.0.0.1", port = 1080 }, "ok"
  end })
  controller.action_probe(); t.eq(state.response.code, "disabled_node"); t.eq(state.status, 409)

  controller, state = controller_fixture({ get_node = function()
    return { id = "safe_node", enabled = true, protocol = "raw", raw_outbound = "secret" }, "ok"
  end })
  controller.action_probe(); t.eq(state.response.code, "unsupported_node"); t.eq(state.status, 422)
end)

t.test("authenticated current-node health action reports stable success and failure envelopes", function()
  local controller, state = controller_fixture({ test_current = function() return { ok = true, code = "test_passed" } end })
  controller.action_test_current()
  t.eq(state.response.ok, true); t.eq(state.response.data.code, "test_passed"); t.eq(state.status, nil)

  controller, state = controller_fixture({ test_current = function() return { ok = false, code = "test_failed" } end })
  controller.action_test_current()
  t.eq(state.response.ok, false); t.eq(state.response.code, "test_failed"); t.eq(state.status, 502)

  controller, state = controller_fixture({ method = "GET" })
  controller.action_test_current()
  t.eq(state.response.code, "method_not_allowed"); t.eq(state.status, 405)
end)

t.test("status exposes only a sanitized exit IP from runtime", function()
  local controller, state = controller_fixture({ runtime_instance = {
    switch = function() return { ok = true } end, rollback = function() return { ok = true } end,
    test_current = function() return { ok = true } end,
    status = function() return { ok = true, service = "running", lock = "unlocked", exit_ip = "203.0.113.9" } end
  } })
  controller.action_status()
  t.eq(state.response.data.exit_ip, "203.0.113.9")
end)

t.test("controller reverts only definitely uncommitted imports", function()
  local controller, state = controller_fixture({ commit_ok = false, commit_outcome = "pre_commit_failed" })
  controller.action_import_commit()
  t.eq(state.response.code, "commit_failed")
  t.eq(state.reverts, 1)
  t.eq(state.status, 500)

  controller, state = controller_fixture({ commit_ok = false, commit_outcome = "commit_unknown" })
  controller.action_import_commit()
  t.eq(state.response.code, "commit_unknown")
  t.eq(state.reverts, 0)
  t.eq(state.status, 500)

  controller, state = controller_fixture({ commit_ok = true, commit_outcome = "committed_hardening_failed" })
  controller.action_import_commit()
  t.eq(state.response.code, "committed_hardening_failed")
  t.eq(state.reverts, 0)
  t.eq(state.status, 500)

  controller, state = controller_fixture({ stage_ok = false })
  controller.action_import_commit()
  t.eq(state.response.code, "import_failed")
  t.eq(state.reverts, 1)

  controller, state = controller_fixture({ stage_throw = true })
  local called = pcall(controller.action_import_commit)
  t.eq(called, true)
  t.eq(state.response.code, "internal_error")
  t.eq(state.reverts, 1)

  controller, state = controller_fixture({ commit_throw = true })
  called = pcall(controller.action_import_commit)
  t.eq(called, true)
  t.eq(state.response.code, "commit_unknown")
  t.eq(state.reverts, 0)
end)

t.test("controller records import commit success and failure once with safe finite fields", function()
  local controller, state = controller_fixture({ body = '{"password":"import-secret","uri":"vless://secret.invalid"}' })
  controller.action_import_commit()
  t.eq(state.response.ok, true)
  t.eq(#state.log_events, 1)
  local event = state.log_events[1]
  t.eq(event.message, "import commit completed")
  t.eq(event.level, "info")
  t.eq(event.fields.outcome, "success")
  t.eq(event.fields.code, "committed")
  t.eq(event.fields.count, 1)
  t.eq(event.fields.password, nil)
  t.eq(event.fields.uri, nil)

  controller, state = controller_fixture({ commit_ok = false, commit_outcome = "pre_commit_failed" })
  controller.action_import_commit()
  t.eq(state.response.code, "commit_failed")
  t.eq(#state.log_events, 1)
  event = state.log_events[1]
  t.eq(event.level, "error")
  t.eq(event.fields.outcome, "failure")
  t.eq(event.fields.code, "commit_failed")
  t.eq(event.fields.count, 1)
end)

t.test("controller logging faults never change probe or import HTTP envelopes", function()
  local controller, state = controller_fixture({ log_throw = true })
  local called = pcall(controller.action_probe)
  t.eq(called, true)
  t.eq(state.response.ok, true)
  t.eq(state.response.data.socket, "ok")

  controller, state = controller_fixture({ log_throw = true })
  called = pcall(controller.action_import_commit)
  t.eq(called, true)
  t.eq(state.response.ok, true)
  t.eq(state.response.data.imported, 1)
  t.eq(state.commits, 1)

  controller, state = controller_fixture({ log_throw = true, stage_ok = false })
  called = pcall(controller.action_import_commit)
  t.eq(called, true)
  t.eq(state.response.ok, false)
  t.eq(state.response.code, "import_failed")
  t.eq(state.reverts, 1)
  t.eq(tostring(state.response.message):find("logger-secret", 1, true), nil)
end)

t.test("controller failure envelopes use stable HTTP status codes", function()
  local cases = {
    {
      expected = 405,
      run = function()
        local controller, state = controller_fixture({ method = "GET" })
        controller.action_probe(); return state
      end
    },
    {
      expected = 413,
      run = function()
        local controller, state = controller_fixture({ content_length = 512 * 1024 + 1 })
        controller.action_probe(); return state
      end
    },
    {
      expected = 400,
      run = function()
        local controller, state = controller_fixture({ request = { section = "bad;node" } })
        controller.action_switch(); return state
      end
    },
    {
      expected = 404,
      run = function()
        local controller, state = controller_fixture({ get_node = function() return nil, "missing" end })
        controller.action_switch(); return state
      end
    },
    {
      expected = 409,
      run = function()
        local controller, state = controller_fixture({
          runtime_instance = {
            switch = function() return { ok = false, code = "busy" } end,
            rollback = function() return { ok = true } end,
            status = function() return { ok = true, service = "running", lock = "held" } end
          }
        })
        controller.action_switch(); return state
      end
    },
    {
      expected = 404,
      run = function()
        local controller, state = controller_fixture({
          runtime_instance = {
            switch = function() return { ok = true } end,
            rollback = function() return { ok = false, code = "no_rollback_state" } end,
            status = function() return { ok = true, service = "running", lock = "held" } end
          }
        })
        controller.action_rollback(); return state
      end
    },
    {
      expected = 500,
      run = function()
        local controller, state = controller_fixture({ get_node = function() return nil, "read_failed" end })
        controller.action_switch(); return state
      end
    }
  }
  for _, case in ipairs(cases) do
    local state = case.run()
    t.eq(state.status, case.expected)
    t.eq(state.content_type, "application/json")
    t.eq(state.response.ok, false)
    t.eq(type(state.response.message), "string")
  end
end)

return { fixture = controller_fixture }
