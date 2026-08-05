local t = require "testlib"
local platform = require "xc.platform"

local XRAY = { "/usr/bin/xray", "run", "-test", "-format", "json", "-c", "/var/etc/xc/config.json" }

local function api_fixture(options)
  options = options or {}
  local calls = { spawn = {}, capture = {} }
  local adapters = platform.new({
    nixio = {}, fs = {}, cursor = { foreach = function() end }, uci_module = {},
    jsonc = {
      parse = options.json_parse or function() return nil end,
      stringify = function() return "{}" end
    },
    now = function() return options.now or 100 end,
    spawn = function(argv, deadline)
      calls.spawn[#calls.spawn + 1] = { argv = argv, deadline = deadline }
      return options.spawn_result ~= false
    end,
    capture = function(argv, deadline, maximum, raw)
      calls.capture[#calls.capture + 1] = { argv = argv, deadline = deadline, maximum = maximum, raw = raw }
      return options.output
    end
  })
  return calls, adapters.exec
end

t.test("xray API override uses the selected path and fixed argv on success", function()
  local calls, exec = api_fixture()
  t.eq(exec.xray_api_override("/etc/xc/xray/versions/v26_6_27/xray", "xc-balancer", "xc-node-node_1"), true)
  t.eq(table.concat(calls.spawn[1].argv, "|"), "/etc/xc/xray/versions/v26_6_27/xray|api|bo|--server=127.0.0.1:10085|-b|xc-balancer|xc-node-node_1")
  t.eq(calls.spawn[1].deadline, 110)
end)

t.test("xray API override reports process failure", function()
  local calls, exec = api_fixture({ spawn_result = false })
  t.eq(exec.xray_api_override("/usr/bin/xray", "xc-balancer", "xc-node-node_1"), false)
  t.eq(#calls.spawn, 1)
end)

t.test("xray API override uses a bounded timeout for a timed out process", function()
  local calls, exec = api_fixture({ now = 50, spawn_result = false })
  t.eq(exec.xray_api_override("/usr/bin/xray", "xc-balancer", "xc-node-node_1"), false)
  t.eq(calls.spawn[1].deadline, 60)
  t.truthy(calls.spawn[1].deadline < 1000000)
end)

t.test("xray API balancer uses fixed argv and parses CLI current tag", function()
  local calls, exec = api_fixture({ output = "Balancer: xc-balancer\nCurrent: xc-node-node_2\n" })
  t.eq(exec.xray_api_balancer("/usr/bin/xray", "xc-balancer"), "xc-node-node_2")
  t.eq(table.concat(calls.capture[1].argv, "|"), "/usr/bin/xray|api|bi|--server=127.0.0.1:10085|xc-balancer")
  t.eq(calls.capture[1].deadline, 110)
  t.eq(calls.capture[1].maximum, 4096)
  t.eq(calls.capture[1].raw, true)
end)

t.test("xray API balancer parses a JSON selected tag for the requested balancer", function()
  local json = '{"balancer":"xc-balancer","selected":"xc-node-node_3"}'
  local parsed = false
  local calls, exec = api_fixture({
    output = json,
    json_parse = function(value)
      parsed = value == json
      if parsed then return { balancer = "xc-balancer", selected = "xc-node-node_3" } end
    end
  })
  t.eq(exec.xray_api_balancer("/usr/bin/xray", "xc-balancer"), "xc-node-node_3")
  t.eq(parsed, true)
  t.eq(#calls.capture, 1)
end)

t.test("xray API balancer fails closed on process failure", function()
  local _, exec = api_fixture({ output = nil })
  t.eq(exec.xray_api_balancer("/usr/bin/xray", "xc-balancer"), nil)
end)

t.test("xray API balancer fails closed on oversized output", function()
  local calls, exec = api_fixture({ output = string.rep("x", 4097) })
  t.eq(exec.xray_api_balancer("/usr/bin/xray", "xc-balancer"), nil)
  t.eq(calls.capture[1].maximum, 4096)
end)

t.test("xray API balancer fails closed on malformed or unsafe output", function()
  local malformed = {
    "Current: xc-node-node_1;secret\n",
    "Current: not-a-node-tag\n",
    "Current: xc-node-node_1\nSelected: xc-node-node_2;secret\n"
  }
  for _, output in ipairs(malformed) do
    local _, exec = api_fixture({ output = output })
    t.eq(exec.xray_api_balancer("/usr/bin/xray", "xc-balancer"), nil)
  end
end)

t.test("xray API calls reject unsafe paths and tags without spawning or capturing", function()
  local invalid_override = {
    { "/tmp/xray", "xc-balancer", "xc-node-node_1" },
    { "/usr/bin/xray", "xc balancer", "xc-node-node_1" },
    { "/usr/bin/xray", "xc-balancer;secret", "xc-node-node_1" },
    { "/usr/bin/xray", "xc-balancer", "xc node" },
    { "/usr/bin/xray", "xc-balancer", "xc-node-node_1;secret" },
    { "/usr/bin/xray", "xc-balancer", "xc-node-a-b" },
    { "/usr/bin/xray", "xc-balancer", "xc-node--" },
    { "/usr/bin/xray", "xc-balancer", "xc-node-" .. string.rep("a", 64) },
    { "/usr/bin/xray", "xc-balancer", "xc-node-node_1\nsecret" }
  }
  for _, value in ipairs(invalid_override) do
    local calls, exec = api_fixture({ output = "Current: xc-node-node_1\n" })
    t.eq(exec.xray_api_override(value[1], value[2], value[3]), false)
    t.eq(#calls.spawn, 0)
    t.eq(#calls.capture, 0)
  end

  local invalid_balancer = {
    { "/tmp/xray", "xc-balancer" },
    { "/usr/bin/xray", "xc balancer" },
    { "/usr/bin/xray", "xc-balancer;secret" },
    { "/usr/bin/xray", "xc-balancer\nsecret" },
    { "/usr/bin/xray", string.rep("x", 65) }
  }
  for _, value in ipairs(invalid_balancer) do
    local calls, exec = api_fixture({ output = "Current: xc-node-node_1\n" })
    t.eq(exec.xray_api_balancer(value[1], value[2]), nil)
    t.eq(#calls.spawn, 0)
    t.eq(#calls.capture, 0)
  end
end)

t.test("xray API balancer never returns complete API output", function()
  local output = "Current: xc-node-node_4\nsecret-field: UUID-or-token\n"
  local _, exec = api_fixture({ output = output })
  local selected = exec.xray_api_balancer("/usr/bin/xray", "xc-balancer")
  t.eq(selected, "xc-node-node_4")
  t.eq(selected ~= output, true, "API output must not be returned verbatim")
  t.eq(selected:find("UUID-or-token", 1, true), nil)
end)

local function process_fixture(wait_results, options)
  options = options or {}
  local state = { now = 0, events = {}, wait_index = 0, reaped = false, killed = false }
  local nixio = {
    stdout = 1, stderr = 2,
    fork = function() state.events[#state.events + 1] = "fork"; return 42 end,
    waitpid = function(pid, mode)
      state.events[#state.events + 1] = "wait:" .. tostring(pid) .. ":" .. tostring(mode)
      if mode == nil then state.reaped = true; return pid, "signaled", 9 end
      state.wait_index = state.wait_index + 1
      local value = state.killed and options.after_kill or wait_results[state.wait_index] or { false }
      if value[1] == pid then state.reaped = true end
      return unpack(value)
    end,
    kill = function(pid, signal)
      state.events[#state.events + 1] = "kill:" .. pid .. ":" .. signal
      if signal == 9 then state.killed = true end
      return true
    end
  }
  local adapters = platform.new({
    nixio = nixio, fs = {}, cursor = { foreach = function() end }, uci_module = {},
    jsonc = { parse = function() end, stringify = function() return "{}" end },
    now = function() return state.now end,
    sleep = function(seconds) state.now = state.now + seconds; state.events[#state.events + 1] = "sleep" end
  })
  return state, adapters.exec
end

t.test("child execution polls nohang and reaps a successful exit before deadline", function()
  local state, exec = process_fixture({ { false }, { 42, "exited", 0 } })
  t.eq(exec.run(XRAY, 1), true)
  t.eq(state.reaped, true)
  t.contains(table.concat(state.events, "|"), "wait:42:nohang")
  t.eq(table.concat(state.events, "|"):find("kill:", 1, true), nil)
end)

t.test("child timeout sends TERM then KILL and reaps with bounded nohang polling", function()
  local state, exec = process_fixture({ { false } }, { after_kill = { 42, "signaled", 9 } })
  t.eq(exec.run(XRAY, 0.15), false)
  local events = table.concat(state.events, "|")
  t.contains(events, "kill:42:15")
  t.contains(events, "kill:42:9")
  t.eq(events:find("wait:42:nil", 1, true), nil)
  t.eq(state.reaped, true)
end)

t.test("permanent wait errors fail and still terminate and reap the child", function()
  local state, exec = process_fixture({ { nil, "ECHILD" } }, { after_kill = { 42, "signaled", 9 } })
  t.eq(exec.run(XRAY, 1), false)
  local events = table.concat(state.events, "|")
  t.contains(events, "kill:42:15")
  t.eq(events:find("wait:42:nil", 1, true), nil)
  t.eq(state.reaped, true)
end)

t.test("SIGKILL does not permit an unbounded blocking reap when the child remains alive", function()
  local state, exec = process_fixture({ { false } })
  t.eq(exec.run(XRAY, 0.15), false)
  local events = table.concat(state.events, "|")
  t.contains(events, "kill:42:9")
  t.eq(events:find("wait:42:nil", 1, true), nil)
  t.eq(state.reaped, false)
  t.truthy(state.now < 3)
end)

t.test("exec run has a bounded default deadline", function()
  local state, exec = process_fixture({ { false } }, { after_kill = { 42, "signaled", 9 } })
  state.now = 100
  t.eq(exec.run(XRAY), false)
  t.contains(table.concat(state.events, "|"), "kill:42:15")
  t.eq(state.reaped, true)
end)

t.test("exec run forwards the selected Xray asset directory", function()
  local captured
  local adapters = platform.new({
    nixio = {}, fs = {}, cursor = { foreach = function() end }, uci_module = {},
    jsonc = { parse = function() end, stringify = function() return "{}" end },
    now = function() return 0 end,
    spawn = function(argv, deadline, environment)
      captured = environment
      return true
    end
  })
  t.eq(adapters.exec.run(XRAY, 1, { XRAY_LOCATION_ASSET = "/usr/share/v2ray" }), true)
  t.eq(captured.XRAY_LOCATION_ASSET, "/usr/share/v2ray")
end)

t.test("background switch forwards only a safe fixed command and returns without waiting", function()
  local captured
  local adapters = platform.new({
    nixio = {}, fs = {}, cursor = { foreach = function() end }, uci_module = {},
    jsonc = { parse = function() end, stringify = function() return "{}" end },
    background = function(argv)
      captured = argv
      return true
    end
  })
  t.eq(adapters.exec.start_switch("node_1"), true)
  t.eq(table.concat(captured, "|"), "/usr/bin/xc|switch|node_1")
  t.eq(adapters.exec.start_switch("bad;node"), false)
end)

t.test("platform defaults the asset environment from a stat adapter", function()
  local captured
  platform.new({
    nixio = { setenv = function(name, value) captured = { name, value }; return true end },
    fs = { stat = function(path)
      return path:match("^/usr/share/v2ray/") and { type = "reg" } or nil
    end },
    cursor = { foreach = function() end }, uci_module = {},
    jsonc = { parse = function() end, stringify = function() return "{}" end }
  })
  t.eq(captured[1], "XRAY_LOCATION_ASSET")
  t.eq(captured[2], "/usr/share/v2ray")
end)

t.test("platform does not probe a LuCI fs module through its looping metatable", function()
  local looping_fs = setmetatable({}, { __index = function(value, key) return value[key] end })
  local called = pcall(platform.new, {
    nixio = { setenv = function() return true end }, fs = looping_fs,
    cursor = { foreach = function() end }, uci_module = {},
    jsonc = { parse = function() end, stringify = function() return "{}" end }
  })
  t.eq(called, true)
end)

t.test("real connection checks use bounded proxy GETs and return measured status", function()
  local calls = {}
  local adapters = platform.new({
    nixio = {}, fs = {}, cursor = { foreach = function() end }, uci_module = {},
    jsonc = { parse = function() end, stringify = function() return "{}" end }, now = function() return 10 end,
    capture = function(argv, deadline, maximum, raw)
      calls[#calls + 1] = { argv = argv, deadline = deadline, maximum = maximum, raw = raw }
      return "0.123\t204\n"
    end
  })
  local result = adapters.exec.real_connection_check("socks", "fd00::1", 7890, "https://health.invalid", 20)
  t.eq(result.ok, true)
  t.eq(result.time, 123)
  t.eq(result.status, 204)
  t.eq(calls[1].raw, true)
  t.eq(calls[1].maximum, 128)
  t.eq(calls[1].deadline, 20)
  t.eq(table.concat(calls[1].argv, "|"), "/usr/bin/curl|--fail|--silent|--show-error|--max-time|10|--connect-timeout|5|--write-out|%{time_total}\\t%{http_code}|--output|/dev/null|--socks5-hostname|[fd00::1]:7890|https://health.invalid")

  result = adapters.exec.real_connection_check("http", "fd00::1", 10809, "https://health.invalid", 20)
  t.eq(result.ok, true)
  t.eq(result.time, 123)
  t.eq(result.status, 204)
  t.eq(calls[2].argv[#calls[2].argv - 1], "http://[fd00::1]:10809")
end)

t.test("real connection checks fail closed on malformed curl output", function()
  local adapters = platform.new({
    nixio = {}, fs = {}, cursor = { foreach = function() end }, uci_module = {},
    jsonc = { parse = function() end, stringify = function() return "{}" end }, now = function() return 10 end,
    capture = function() return "not-a-measurement" end
  })
  local result = adapters.exec.real_connection_check("socks", "127.0.0.1", 7890, "https://health.invalid", 20)
  t.eq(result.ok, false)
end)

t.test("exit IP observation uses fixed curl argv, bounded output, and injected capture", function()
  local calls = {}
  local adapters = platform.new({
    nixio = {}, fs = {}, cursor = { foreach = function() end }, uci_module = {},
    jsonc = { parse = function() end, stringify = function() return "{}" end }, now = function() return 10 end,
    capture = function(argv, deadline, maximum)
      calls[#calls + 1] = { argv = argv, deadline = deadline, maximum = maximum }
      return "203.0.113.7\n"
    end
  })
  t.eq(adapters.exec.observe_exit_ip("socks", "fd00::1", 7890, "https://health.invalid/ip", 12), "203.0.113.7\n")
  t.eq(calls[1].deadline, 12); t.eq(calls[1].maximum, 128)
  t.eq(calls[1].argv[1], "/usr/bin/curl")
  t.eq(calls[1].argv[#calls[1].argv - 1], "[fd00::1]:7890")
  t.eq(calls[1].argv[#calls[1].argv], "https://health.invalid/ip")
  t.eq(table.concat(calls[1].argv, "|"):find("192.168.6.1:7890", 1, true), nil)
  t.eq(adapters.exec.observe_exit_ip("socks", "127.0.0.1", 7890, "file:///secret", 12), nil)
  t.eq(adapters.exec.observe_exit_ip("socks", "127.0.0.1", 7890, "https://health.invalid", 10), nil)
end)
