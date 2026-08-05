local t = require "testlib"
local platform = require "xc.platform"

local XRAY = { "/usr/bin/xray", "run", "-test", "-format", "json", "-c", "/var/etc/xc/config.json" }

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

t.test("parallel real connection checks build both bounded proxy requests", function()
  local calls = {}
  local adapters = platform.new({
    nixio = {}, fs = {}, cursor = { foreach = function() end }, uci_module = {},
    jsonc = { parse = function() end, stringify = function() return "{}" end }, now = function() return 10 end,
    capture_parallel = function(requests, deadline, maximum, raw)
      calls[#calls + 1] = { requests = requests, deadline = deadline, maximum = maximum, raw = raw }
      return { socks = "0.123\t204\n", http = "0.234\t204\n" }
    end
  })
  local result = adapters.exec.real_connection_checks("fd00::1", 7890, 10809, "https://health.invalid", 20)
  t.eq(result.socks.ok, true)
  t.eq(result.socks.time, 123)
  t.eq(result.socks.status, 204)
  t.eq(result.http.ok, true)
  t.eq(result.http.time, 234)
  t.eq(result.http.status, 204)
  t.eq(calls[1].deadline, 20)
  t.eq(calls[1].maximum, 128)
  t.eq(calls[1].raw, true)
  t.eq(#calls[1].requests, 2)
  t.eq(calls[1].requests[1].kind, "socks")
  t.eq(calls[1].requests[2].kind, "http")
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
