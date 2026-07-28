local t = require "testlib"

local function read_file(path)
  local handle = assert(io.open(path, "rb"))
  local value = assert(handle:read("*a"))
  handle:close()
  return value
end

t.test("platform adapter exposes complete runtime contract without shell interpolation", function()
  local source = read_file("root/usr/lib/lua/xc/platform.lua")
  for _, name in ipairs({
    "get_global", "get_node", "list_nodes", "set_active", "clear_active", "commit", "revert",
    "acquire_lock", "release_lock", "lock_state", "write_temp", "fsync_dir", "allocate_generation",
    "list_generation_files", "trash_generation", "delete_trashed_generation", "listener_ready", "health_check", "observe_exit_ip",
    "service_state", "stringify"
  }) do t.contains(source, name .. " = function") end
  t.contains(source, "nixio.open")
  t.contains(source, ':lock("tlock")')
  t.contains(source, ":sync()")
  t.contains(source, "O_EXCL")
  t.contains(source, "O_NOFOLLOW")
  t.contains(source, "MONOTONIC")
  t.contains(source, 'nixio.exec(unpack(argv))')
  t.contains(source, "null:close()")
  t.truthy(source:find("null:close()", 1, true) < source:find("nixio.exec(unpack(argv))", 1, true))
  t.contains(source, 'nixio.open("/proc/uptime", "r")')
  t.contains(source, "setblocking(false)")
  t.contains(source, "nixio.poll")
  t.contains(source, 'getsockopt("socket", "error")')
  t.contains(source, "--socks5-hostname")
  t.contains(source, "--proxy")
  t.eq(source:find("os.execute", 1, true), nil)
  t.eq(source:find("clock_gettime", 1, true), nil)
  t.eq(source:find(":flock", 1, true), nil)
  t.eq(source:find("384", 1, true), nil)
  t.eq(source:find("448", 1, true), nil)
end)

t.test("platform generation trash resumes an interrupted pair move", function()
  package.loaded["xc.platform"] = nil
  local platform = require "xc.platform"
  local directory, token = "/etc/xc/rollback", "safe"
  local files = {
    [directory .. "/.trash-safe.config"] = true,
    [directory .. "/generation-safe.active"] = true
  }
  local fake_fs = {
    stat = function(path) return files[path] and { type = "reg" } or nil end,
    rename = function(source, destination) if not files[source] or files[destination] then return false end; files[destination], files[source] = true, nil; return true end,
    unlink = function(path) files[path] = nil; return true end,
    dir = function() return function() return nil end end,
    chmod = function() return true end
  }
  local adapters = platform.new({
    nixio = { open_flags = function() return 0 end, const = { ENOENT = 2 }, getpid = function() return 1 end },
    fs = fake_fs,
    cursor = { foreach = function() end },
    uci_module = {}, jsonc = { parse = function() end, stringify = function() return "{}" end }
  })
  t.eq(adapters.fs.trash_generation(directory, token), token)
  t.truthy(files[directory .. "/.trash-safe.config"])
  t.truthy(files[directory .. "/.trash-safe.active"])
  t.eq(files[directory .. "/generation-safe.active"], nil)
  t.eq(adapters.fs.trash_generation(directory, token), token)
end)

t.test("CLI entrypoint loads concrete adapters and emits JSON only", function()
  local source = read_file("root/usr/bin/xc")
  t.contains(source, 'require "xc.platform"')
  t.contains(source, 'require "xc.cli"')
  t.contains(source, "adapters.fs.ensure_layout()")
  t.eq(source:find("io.stderr", 1, true), nil)
end)

t.test("platform provisions private runtime directories on a clean filesystem", function()
  local entries, events = {}, {}
  local fake_fs = {
    stat = function(path) return entries[path] and { type = "dir" } or nil end,
    mkdirr = function(path) entries[path] = true; events[#events + 1] = "mkdir:" .. path; return true end,
    chmod = function(path, mode) events[#events + 1] = "chmod:" .. path .. ":" .. tostring(mode); return entries[path] == true end
  }
  local adapters = require("xc.platform").new({
    nixio = {}, fs = fake_fs, cursor = { foreach = function() end }, uci_module = {},
    jsonc = { parse = function() end, stringify = function() return "{}" end }
  })
  t.eq(type(adapters.fs.ensure_layout), "function")
  t.eq(adapters.fs.ensure_layout(), true)
  for _, path in ipairs({ "/etc/xc", "/etc/xc/rollback", "/var/etc/xc" }) do
    t.truthy(entries[path])
    t.contains(table.concat(events, "|"), "chmod:" .. path .. ":700")
  end
end)

t.test("platform normalizes an empty active option and ships no empty default", function()
  local adapters = require("xc.platform").new({
    nixio = {}, fs = {}, uci_module = {},
    cursor = { foreach = function(_, _, kind, callback)
      if kind == "global" then callback({ [".name"] = "global", [".type"] = "global", active_node = "" }) end
    end },
    jsonc = { parse = function() end, stringify = function() return "{}" end }
  })
  t.eq(adapters.uci.get_global().active_node, nil)
  local config = read_file("root/etc/config/xc")
  t.eq(config:find("option active_node", 1, true), nil)
end)

t.test("runtime restart uses a prepared fixed-argv action while ordinary reload renders", function()
  local calls, outcomes = {}, { true, false, true }
  local adapters = require("xc.platform").new({
    nixio = {}, fs = {}, cursor = { foreach = function() end }, uci_module = {},
    jsonc = { parse = function() end, stringify = function() return "{}" end },
    now = function() return 10 end,
    spawn = function(argv)
      calls[#calls + 1] = table.concat(argv, "|")
      return outcomes[#calls]
    end
  })
  local called, result = pcall(adapters.exec.restart)
  t.eq(called, true); t.eq(result, true)
  called, result = pcall(adapters.exec.restart)
  t.eq(called, true); t.eq(result, false)
  called, result = pcall(adapters.exec.restart)
  t.eq(called, true); t.eq(result, true)
  for _, call in ipairs(calls) do t.eq(call, "/etc/init.d/xc|restart_prepared") end

  local platform_source = read_file("root/usr/lib/lua/xc/platform.lua")
  t.eq(platform_source:find('"signal"', 1, true), nil)
  local init = read_file("root/etc/init.d/xc")
  t.contains(init, "reload_service()")
  t.contains(init, 'EXTRA_COMMANDS="restart_prepared"')
  t.contains(init, '"$XC_RUNTIME_PREPARED" != "1"')
  local reload_body = assert(init:match("reload_service%(%) {%s*(.-)%s*}"))
  t.eq(reload_body:find("XC_RUNTIME_PREPARED", 1, true), nil)
  t.contains(reload_body, "stop || return 1")
  local prepared_body = assert(init:match("restart_prepared%(%) {%s*(.-)%s*}"))
  t.truthy(prepared_body:find("XC_RUNTIME_PREPARED=1", 1, true) < prepared_body:find("stop", 1, true))
end)
