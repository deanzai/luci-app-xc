local t = require "testlib"
local real_schema = require "xc.schema"
local real_logview = require "xc.logview"

local function controller_fixture(options)
  options = options or {}
  local state = { reverts = 0, commits = 0, fs_events = {} }
  local body = options.body or "{}"
  local http = {
    getenv = function(name)
      if name == "REQUEST_METHOD" then return options.method or "POST" end
      if name == "CONTENT_LENGTH" then return tostring(options.content_length or #body) end
    end,
    content = function() return body end,
    prepare_content = function(value) state.content_type = value end,
    status = function(code) state.status = code end,
    formvalue = function(name)
      if name == "level" then return options.level end
    end,
    write_json = function(value) state.response = value end
  }
  local node = {
    id = "safe_node", name = "Safe", enabled = true, protocol = "socks",
    server = "127.0.0.1", port = 1080
  }
  local adapters = {
    json = {
      parse = function(value)
        if options.log_json and options.log_json[value] ~= nil then return options.log_json[value] end
        return options.request or { section = "safe_node" }
      end,
      stringify = function() return "{}" end
    },
    uci = {
      get_node = options.get_node or function() return node, "ok" end,
      list_nodes = function() return options.existing_nodes or {} end,
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
    test_current = options.test_current or function() return { ok = true, code = "test_passed" } end
  }
  local importer = {
    parse = options.import_parse or function()
      return { nodes = options.import_nodes or { node }, warnings = {} }
    end,
    deduplicate = function(nodes) return nodes, {} end
  }

  local replacements = {
    ["luci.http"] = http,
    ["xc.schema"] = real_schema,
    ["xc.logview"] = real_logview,
    ["xc.platform"] = { new = function() return adapters end },
    ["xc.runtime"] = { new = function() return runtime_instance end, paths = {
      log = "/var/log/xc.log", log_lock = "/var/lock/xc-log.lock"
    } },
    ["xc.importer"] = importer,
    ["xc.probe"] = options.probe_module or { new = function()
      return { run = function(_, section, selected, timeout)
        state.probe = { section = section, node = selected, timeout = timeout }
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
