local t = require "testlib"
local platform = require "xc.platform"

local function copy(value)
  if type(value) ~= "table" then return value end
  local output = {}
  for key, child in pairs(value) do output[key] = copy(child) end
  return output
end

local function serialize(sections)
  local output = {}
  for name, section in pairs(sections) do
    local fields = {}
    for key, value in pairs(section) do fields[#fields + 1] = tostring(key) .. "=" .. tostring(value) end
    table.sort(fields)
    output[#output + 1] = name .. "{" .. table.concat(fields, ",") .. "}"
  end
  table.sort(output)
  return table.concat(output, "|")
end

local function cursor_fixture(fail_at)
  local committed = {
    global = { [".name"] = "global", [".type"] = "global", enabled = "1", active_node = "old" },
    old = { [".name"] = "old", [".type"] = "node", enabled = "1", name = "Old" }
  }
  local state = { working = copy(committed), committed = copy(committed), mutations = 0, reverts = 0 }
  local function mutate(fn)
    state.mutations = state.mutations + 1
    if state.mutations == fail_at then return false end
    fn()
    return true
  end
  local cursor = {
    foreach = function(_, _, section_type, callback)
      local names = {}
      for name, section in pairs(state.working) do if section[".type"] == section_type then names[#names + 1] = name end end
      table.sort(names)
      for _, name in ipairs(names) do callback(copy(state.working[name])) end
    end,
    get = function(_, _, section, option) return state.working[section] and state.working[section][option] end,
    get_all = function(_, _, section) return state.working[section] and copy(state.working[section]) end,
    set = function(_, _, section, option, value)
      return mutate(function()
        if value == nil then
          state.working[section] = { [".name"] = section, [".type"] = option }
        else
          state.working[section][option] = value
        end
      end)
    end,
    delete = function(_, _, section, option)
      return mutate(function()
        if option then state.working[section][option] = nil else state.working[section] = nil end
      end)
    end,
    commit = function() state.committed = copy(state.working); return true end,
    revert = function() state.reverts = state.reverts + 1; state.working = copy(state.committed); return true end
  }
  local adapters = platform.new({
    nixio = {}, fs = {}, cursor = cursor, uci_module = {},
    jsonc = { parse = function() end, stringify = function() return "{}" end }
  })
  return state, adapters.uci
end

local node = {
  id = "new", name = "New", enabled = true, protocol = "socks",
  server = "127.0.0.1", port = 1080, user = "u", password = "p"
}
local global = {
  enabled = "1", active_node = "new", listen_mode = "lan", listen_address = "",
  socks_port = "7890", http_port = "10809", health_url = "https://health.invalid/", health_timeout = "5"
}

t.test("set and clear active revert when their cursor mutation fails", function()
  local state, uci = cursor_fixture(1)
  local before = serialize(state.working)
  t.eq(uci.set_active("new"), false)
  t.eq(serialize(state.working), before)
  t.eq(state.reverts, 1)

  state, uci = cursor_fixture(1)
  before = serialize(state.working)
  t.eq(uci.clear_active(), false)
  t.eq(serialize(state.working), before)
  t.eq(state.reverts, 1)
end)

local function assert_failure_matrix(method, arguments)
  local baseline, baseline_uci = cursor_fixture(9999)
  t.truthy(baseline_uci[method](unpack(arguments)))
  local mutations = baseline.mutations
  t.truthy(mutations > 1)
  for position = 1, mutations do
    local state, uci = cursor_fixture(position)
    local before = serialize(state.working)
    local called, result = pcall(uci[method], unpack(arguments))
    t.eq(called, true, method .. " must contain mutation " .. position)
    t.eq(result, false, method .. " mutation " .. position)
    t.eq(serialize(state.working), before, method .. " atomic " .. position)
    t.eq(state.reverts, 1, method .. " revert " .. position)
  end
end

t.test("stage_nodes checks every section and set mutation atomically", function()
  assert_failure_matrix("stage_nodes", { { node } })
end)

t.test("stage_replace checks every delete section and set mutation atomically", function()
  assert_failure_matrix("stage_replace", { global, { node } })
end)

t.test("raw OpenWrt cursor creates named sections through overloaded set", function()
  local state, uci = cursor_fixture(9999)
  t.eq(uci.stage_replace(global, { node }), true)
  t.eq(state.working.global[".type"], "global")
  t.eq(state.working.new[".type"], "node")
end)

t.test("credential commits enforce config mode before and after commit", function()
  local function commit_fixture(fail_chmod, throw_commit, commit_result, throw_chmod)
    local events, chmod_calls = {}, 0
    local state = { committed = false }
    local cursor = {
      foreach = function() end,
      commit = function(_, config)
        events[#events + 1] = "commit:" .. config
        if throw_commit then error("commit-secret") end
        if commit_result == false then return false end
        state.committed = true
        return true
      end
    }
    local adapters = platform.new({
      nixio = {}, cursor = cursor, uci_module = {},
      fs = { chmod = function(path, mode)
        chmod_calls = chmod_calls + 1
        events[#events + 1] = "chmod:" .. path .. ":" .. tostring(mode)
        if chmod_calls == throw_chmod then error("password=chmod-secret") end
        return chmod_calls ~= fail_chmod
      end },
      jsonc = { parse = function() end, stringify = function() return "{}" end }
    })
    return adapters.uci, events, state
  end

  local uci, events = commit_fixture()
  local committed, outcome = uci.commit()
  t.eq(committed, true)
  t.eq(outcome, "committed")
  t.eq(table.concat(events, "|"), "chmod:/etc/config/xc:600|commit:xc|chmod:/etc/config/xc:600")

  uci, events = commit_fixture(1)
  committed, outcome = uci.commit()
  t.eq(committed, false)
  t.eq(outcome, "pre_commit_failed")
  t.eq(table.concat(events, "|"), "chmod:/etc/config/xc:600")

  uci, events = commit_fixture(nil, false, nil, 1)
  local called
  called, committed, outcome = pcall(uci.commit)
  t.eq(called, true)
  t.eq(committed, false)
  t.eq(outcome, "pre_commit_failed")
  t.eq(table.concat(events, "|"), "chmod:/etc/config/xc:600")

  uci, events = commit_fixture(nil, false, false)
  committed, outcome = uci.commit()
  t.eq(committed, false)
  t.eq(outcome, "pre_commit_failed")

  local state
  uci, events, state = commit_fixture(2)
  committed, outcome = uci.commit()
  t.eq(committed, true)
  t.eq(outcome, "committed_hardening_failed")
  t.eq(state.committed, true)
  t.eq(table.concat(events, "|"), "chmod:/etc/config/xc:600|commit:xc|chmod:/etc/config/xc:600")

  uci, events, state = commit_fixture(nil, false, nil, 2)
  called, committed, outcome = pcall(uci.commit)
  t.eq(called, true)
  t.eq(committed, true)
  t.eq(outcome, "committed_hardening_failed")
  t.eq(state.committed, true)

  uci, events = commit_fixture(nil, true)
  called, committed, outcome = pcall(uci.commit)
  t.eq(called, true)
  t.eq(committed, false)
  t.eq(outcome, "commit_unknown")
  t.eq(table.concat(events, "|"), "chmod:/etc/config/xc:600|commit:xc|chmod:/etc/config/xc:600")
end)

t.test("get_node distinguishes missing invalid and failed UCI reads", function()
  local mode = "missing"
  local cursor = {
    foreach = function() end,
    get_all = function(_, _, section)
      if mode == "throw" then error("password=read-secret") end
      if mode == "node" then return { [".name"] = section, [".type"] = "node", protocol = "socks" } end
      return nil
    end
  }
  local adapters = platform.new({
    nixio = {}, fs = {}, cursor = cursor, uci_module = {},
    jsonc = { parse = function() end, stringify = function() return "{}" end }
  })

  local node_value, outcome = adapters.uci.get_node("safe_node")
  t.eq(node_value, nil)
  t.eq(outcome, "missing")

  node_value, outcome = adapters.uci.get_node("bad;node")
  t.eq(node_value, nil)
  t.eq(outcome, "invalid_id")

  mode = "throw"
  local called
  called, node_value, outcome = pcall(adapters.uci.get_node, "safe_node")
  t.eq(called, true)
  t.eq(node_value, nil)
  t.eq(outcome, "read_failed")

  mode = "node"
  node_value, outcome = adapters.uci.get_node("safe_node")
  t.eq(type(node_value), "table")
  t.eq(outcome, "ok")
end)
