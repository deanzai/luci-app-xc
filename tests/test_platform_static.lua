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
    "list_generation_files", "trash_generation", "delete_trashed_generation", "listener_ready", "real_connection_check", "observe_exit_ip",
    "service_state", "start_switch", "stringify"
  }) do t.contains(source, name .. " = function") end
  t.contains(source, "stat_nofollow = function")
  t.contains(source, "nixio.open")
  t.contains(source, ':lock("tlock")')
  t.contains(source, ":sync()")
  t.contains(source, "O_EXCL")
  t.contains(source, "O_NOFOLLOW")
  t.contains(source, "MONOTONIC")
  t.contains(source, 'nixio.exec(unpack(argv))')
  t.contains(source, "nixio.setsid")
  t.contains(source, '"/usr/bin/xc", "switch"')
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

t.test("platform nofollow stat checks every path component", function()
  local source = read_file("root/usr/lib/lua/xc/platform.lua")
  t.contains(source, 'for component in path:gmatch("[^/]+") do')
  t.contains(source, 'prefix = prefix and prefix .. "/" .. component')
  t.contains(source, 'nixio.open(prefix, nixio.open_flags("rdonly") + O_NOFOLLOW)')
end)

t.test("platform syncs a nofollow directory fd without the unsupported O_DIRECTORY flag", function()
  local opened_flags, stat_called
  local handle = {
    stat = function()
      stat_called = true
      return { type = "dir" }
    end,
    sync = function() return true end,
    close = function() return true end
  }
  local adapters = require("xc.platform").new({
    nixio = {
      open_flags = function(mode) t.eq(mode, "rdonly"); return 0 end,
      open = function(_, flags) opened_flags = flags; return handle end
    },
    fs = {}, cursor = { foreach = function() end }, uci_module = {},
    jsonc = { parse = function() end, stringify = function() return "{}" end }
  })
  t.eq(adapters.fs.fsync_dir("/var/etc/xc"), true)
  t.eq(opened_flags, 131072)
  t.eq(stat_called, true)

  local regular_synced, regular_closed = false, false
  local regular_adapters = require("xc.platform").new({
    nixio = {
      open_flags = function() return 0 end,
      open = function()
        return {
          stat = function() return { type = "reg" } end,
          sync = function() regular_synced = true; return true end,
          close = function() regular_closed = true; return true end
        }
      end
    },
    fs = {}, cursor = { foreach = function() end }, uci_module = {},
    jsonc = { parse = function() end, stringify = function() return "{}" end }
  })
  t.eq(regular_adapters.fs.fsync_dir("/var/etc/xc"), false)
  t.eq(regular_synced, false)
  t.eq(regular_closed, true)
end)

t.test("platform allocates generation tokens when uptime milliseconds exceed 32-bit integers", function()
  package.loaded["xc.platform"] = nil
  local platform = require "xc.platform"
  local files = {}
  local fake_fs = {
    stat = function(path) return files[path] and { type = "reg" } or nil end,
    unlink = function(path) files[path] = nil; return true end,
    dir = function() return function() return nil end end,
    chmod = function() return true end,
    rename = function(source, destination)
      files[destination], files[source] = files[source], nil
      return true
    end
  }
  local fake_nixio = {
    open_flags = function() return 0 end,
    getpid = function() return 42 end,
    open = function(path)
      if path == "/proc/uptime" then
        return {
          read = function() return "3516071.77 13848543.32\n" end,
          close = function() return true end
        }
      end
      files[path] = true
      return { sync = function() return true end, close = function() return true end }
    end
  }
  local adapters = platform.new({
    nixio = fake_nixio, fs = fake_fs, now = function() return 3516071.77 end,
    cursor = { foreach = function() end }, uci_module = {},
    jsonc = { parse = function() end, stringify = function() return "{}" end }
  })
  local token = adapters.fs.allocate_generation("/etc/xc/rollback")
  t.truthy(token)
  t.truthy(token:match("^3516071770%-42%-%d+$"))
end)

t.test("platform captures Xray logs with fixed argv bounded output and a finite deadline", function()
  local calls = {}
  local adapters = require("xc.platform").new({
    nixio = {}, fs = {}, cursor = { foreach = function() end }, uci_module = {},
    jsonc = { parse = function() end, stringify = function() return "{}" end },
    now = function() return 10 end,
    capture = function(argv, deadline, maximum)
      calls[#calls + 1] = { argv = argv, deadline = deadline, maximum = maximum }
      return "xray output"
    end
  })
  t.eq(adapters.exec.xray_logs(12), "xray output")
  t.eq(table.concat(calls[1].argv, "|"), "/sbin/logread|-e|xray\\[")
  t.eq(calls[1].deadline, 12)
  t.eq(calls[1].maximum, 262144)
  for _, invalid in ipairs({ 10, 311, math.huge, -math.huge }) do
    t.eq(adapters.exec.xray_logs(invalid), nil)
  end
  t.eq(#calls, 1)

  local source = read_file("root/usr/lib/lua/xc/platform.lua")
  t.contains(source, "wall_time = function() return os.time() end")
  t.contains(source, 'capture_process({ "/sbin/logread", "-e", "xray\\\\[" }, deadline, 262144)')
  t.contains(source, "spawn_capture(nixio, argv, temporary, deadline, now_process, sleep_process)")
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
  t.contains(source, 'require "xc.coremanager"')
  t.contains(source, "adapters.core = core_manager")
end)

t.test("CLI core status recovers pending transactions before reading status", function()
  local source = read_file("root/usr/lib/lua/xc/cli.lua")
  local recover = assert(source:find('pcall(deps.core.recover_pending, deps.core)', 1, true))
  local status = assert(source:find('return finish(deps, deps.core:status())', 1, true))
  t.truthy(recover < status)
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

t.test("core.lua rejects shell, io.popen, and unsafe path traversal", function()
  local source = read_file("root/usr/lib/lua/xc/core.lua")
  t.eq(source:find("os.execute", 1, true), nil)
  t.eq(source:find("io.popen", 1, true), nil)
  t.eq(source:find('"shell"', 1, true), nil)
  t.eq(source:find("'shell'", 1, true), nil)
  t.contains(source, "VERSIONS_DIR")
  t.contains(source, "SYSTEM_XRAY")
  t.contains(source, "safe_id")
  t.contains(source, "safe_path")
  t.contains(source, "/etc/xc/xray/")
end)

t.test("init script recovers a pending core transaction before resolving xray", function()
  local init = read_file("root/etc/init.d/xc")
  t.contains(init, "if [ -f /etc/xc/xray/transaction ]; then")
  t.contains(init, "/usr/bin/xc core-recover")
  t.contains(init, 'XC_RUNTIME_PREPARED" != "1"')
  local start_body = assert(init:match("start_service%(%) {%s*(.-)%s*}"))
  local transaction_index = start_body:find("transaction", 1, true)
  local prepared_index = start_body:find('"$XC_RUNTIME_PREPARED" != "1"', 1, true)
  t.truthy(transaction_index)
  t.truthy(prepared_index)
  t.truthy(transaction_index > prepared_index)
end)

t.test("init script rejects symlinked manual cores and only accepts safe IDs", function()
  local init = read_file("root/etc/init.d/xc")
  t.contains(init, "[ ! -L \"$path\" ]")
  local resolve_body = assert(init:match("resolve_xray%(%) {%s*(.-)%s*}"))
  t.contains(resolve_body, "*[!a-z0-9_-]*")
  t.contains(resolve_body, "/etc/xc/xray/versions/$current/xray")
  t.contains(resolve_body, "-x \"$path\"")
  t.contains(resolve_body, "/etc/xc/xray/versions/$current/manifest.json")
  t.contains(resolve_body, "sha256sum \"$path\"")
  t.contains(resolve_body, '"$manifest_id" = "$current"')
  t.contains(resolve_body, 'ls -ld "$path" 2>/dev/null')
  t.contains(resolve_body, 'ls -ld "$manifest" 2>/dev/null')
  t.eq(resolve_body:find('stat -c %a', 1, true), nil)
end)

t.test("core upload streams a single fixed field and removes temp files on failure", function()
  local source = read_file("luasrc/controller/xc.lua")
  t.contains(source, "http.setfilehandler")
  t.contains(source, 'local field_name = type(field) == "table" and field.name or field')
  t.contains(source, 'if field_name ~= "core_file" then return end')
  t.contains(source, "adapters.fs.write_upload(upload, chunk, CORE_UPLOAD_MAX)")
  t.contains(source, "adapters.fs.close_upload(upload, true)")
  local coremanager = read_file("root/usr/lib/lua/xc/coremanager.lua")
  t.contains(coremanager, "self.fs.read_prefix(path, MAX_HEADER)")
  t.contains(coremanager, '"read_prefix"')
  t.contains(coremanager, "self.fs.chmod(path, 700)")
  local platform = read_file("root/usr/lib/lua/xc/platform.lua")
  t.contains(platform, 'path:match("^/var/etc/xc/%.core%-upload%-[0-9A-Za-z_-]+$")')
  local removals = 0
  for _ in source:gmatch("pcall%(adapters%.fs%.remove, upload%.path%)") do removals = removals + 1 end
  t.truthy(removals >= 2)
end)

t.test("platform listener_ready retries while the listener is not ready", function()
  package.loaded["xc.platform"] = nil
  local platform = require "xc.platform"
  local connects = 0
  local now_value = 100.0
  local function fake_handle()
    local current = tostring(now_value) .. " 200.00\n"
    return {
      read = function() return current end,
      close = function() return true end
    }
  end
  local function advance()
    now_value = now_value + 0.5
  end
  local function build(succeed_on)
    connects = 0
    local nixio = {
      socket = function()
        return {
          setblocking = function() return true end,
          connect = function()
            connects = connects + 1
            if connects >= succeed_on then return true, 0 end
            return nil, 111
          end,
          getsockopt = function() return 0 end,
          close = function() return true end
        }
      end,
      poll_flags = function() return 12 end,
      poll = function() return 1 end,
      const = { EINPROGRESS = 115, EWOULDBLOCK = 11, EAGAIN = 11 },
      open = function(path, flags)
        if path == "/proc/uptime" then advance(); return fake_handle() end
        return nil
      end,
      open_flags = function() return 0 end,
      sysinfo = function() return {} end,
      nanosleep = function() end
    }
    return platform.new({
      nixio = nixio,
      fs = {}, cursor = { foreach = function() end }, uci_module = {},
      jsonc = { parse = function() end, stringify = function() return "{}" end },
      now = function() return now_value end
    })
  end

  local adapters = build(2)
  t.eq(adapters.exec.listener_ready("socks", "192.168.13.1", 7890, now_value + 10), true)
  t.eq(connects, 2)

  now_value = 100.0
  local timeout_adapters = build(math.huge)
  t.eq(timeout_adapters.exec.listener_ready("http", "192.168.13.1", 10809, now_value + 2), false)
  t.truthy(connects < 150)
end)

t.test("CLI exposes only fixed-path dynamic rendering and safe selection commands", function()
  local source = read_file("root/usr/lib/lua/xc/cli.lua")
  t.contains(source, "render-dynamic")
  t.contains(source, "fast-switch")
  t.contains(source, "restore-selection")
  t.contains(source, "/var/etc/xc/config.json")
  t.contains(source, "/var/etc/xc/candidate.json")
  t.contains(source, "schema.safe_section_id(argv[2])")
  t.contains(source, '"selection_mode"')
  t.contains(source, '"runtime_active_node"')
  t.contains(source, '"selection_state"')
end)

t.test("init renders dynamic config and restores selection without restart loops", function()
  local source = read_file("root/etc/init.d/xc")
  t.contains(source, "/usr/bin/xc render-dynamic --output /var/etc/xc/config.json")
  t.contains(source, "/usr/bin/xc restore-selection")
  t.contains(source, "api bi --server=127.0.0.1:10085 xc-balancer")
  t.contains(source, "api_attempts")
  t.contains(source, "selection_restore_failed")
  local close = assert(source:find("procd_close_instance", 1, true))
  local api_probe = assert(source:find("api bi --server=127.0.0.1:10085 xc-balancer", 1, true))
  local restore = assert(source:find("restore-selection", 1, true))
  t.truthy(restore > close)
  t.truthy(restore > api_probe)
  t.contains(source, ") >/dev/null 2>&1 &")
  t.contains(source, "|| true")
end)
