local t = require "testlib"
local platform = require "xc.platform"

local XRAY = { "/usr/bin/xray", "run", "-test", "-c", "/var/etc/xc/config.json" }

local function process_fixture(wait_results)
  local state = { now = 0, events = {}, wait_index = 0, reaped = false }
  local nixio = {
    stdout = 1, stderr = 2,
    fork = function() state.events[#state.events + 1] = "fork"; return 42 end,
    waitpid = function(pid, mode)
      state.events[#state.events + 1] = "wait:" .. tostring(pid) .. ":" .. tostring(mode)
      if mode == nil then state.reaped = true; return pid, "signaled", 9 end
      state.wait_index = state.wait_index + 1
      local value = wait_results[state.wait_index] or { false }
      if value[1] == pid then state.reaped = true end
      return unpack(value)
    end,
    kill = function(pid, signal) state.events[#state.events + 1] = "kill:" .. pid .. ":" .. signal; return true end
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

t.test("child timeout sends TERM then KILL and performs a final reap", function()
  local state, exec = process_fixture({ { false }, { false }, { false }, { false }, { false }, { false } })
  t.eq(exec.run(XRAY, 0.15), false)
  local events = table.concat(state.events, "|")
  t.contains(events, "kill:42:15")
  t.contains(events, "kill:42:9")
  t.contains(events, "wait:42:nil")
  t.eq(state.reaped, true)
end)

t.test("permanent wait errors fail and still terminate and reap the child", function()
  local state, exec = process_fixture({ { nil, "ECHILD" } })
  t.eq(exec.run(XRAY, 1), false)
  local events = table.concat(state.events, "|")
  t.contains(events, "kill:42:15")
  t.contains(events, "wait:42:nil")
  t.eq(state.reaped, true)
end)

t.test("exec run has a bounded default deadline", function()
  local state, exec = process_fixture({ { false } })
  state.now = 100
  t.eq(exec.run(XRAY), false)
  t.contains(table.concat(state.events, "|"), "kill:42:15")
  t.eq(state.reaped, true)
end)

t.test("curl proxy argv brackets IPv6 literals", function()
  local calls = {}
  local adapters = platform.new({
    nixio = { open = function() return nil end, sysinfo = function() return { uptime = 10 } end },
    fs = {}, cursor = { foreach = function() end }, uci_module = {},
    jsonc = { parse = function() end, stringify = function() return "{}" end },
    now = function() return 10 end,
    spawn = function(argv, deadline) calls[#calls + 1] = { argv = argv, deadline = deadline }; return true end
  })
  t.eq(adapters.exec.health_check("socks", "fd00::1", 7890, "https://health.invalid", 20), true)
  t.eq(adapters.exec.health_check("http", "fd00::1", 10809, "https://health.invalid", 20), true)
  t.eq(calls[1].argv[#calls[1].argv - 1], "[fd00::1]:7890")
  t.eq(calls[2].argv[#calls[2].argv - 1], "http://[fd00::1]:10809")
  t.eq(calls[1].deadline, 20)
  t.eq(calls[2].deadline, 20)
end)
