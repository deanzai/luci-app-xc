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
    "list_generation_files", "trash_generation", "delete_trashed_generation", "listener_ready", "health_check",
    "service_state", "stringify"
  }) do t.contains(source, name .. " = function") end
  t.contains(source, "nixio.open")
  t.contains(source, ':lock("tlock")')
  t.contains(source, ":sync()")
  t.contains(source, "O_EXCL")
  t.contains(source, "O_NOFOLLOW")
  t.contains(source, "MONOTONIC")
  t.contains(source, 'nixio.exec(unpack(argv))')
  t.contains(source, 'nixio.open("/proc/uptime", "r")')
  t.contains(source, "setblocking(false)")
  t.contains(source, "nixio.poll")
  t.contains(source, 'getsockopt("socket", "error")')
  t.contains(source, "--socks5-hostname")
  t.contains(source, "--proxy")
  t.eq(source:find("os.execute", 1, true), nil)
  t.eq(source:find("clock_gettime", 1, true), nil)
  t.eq(source:find(":flock", 1, true), nil)
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
  t.eq(source:find("io.stderr", 1, true), nil)
end)
