local schema = require "xc.schema"

local M = {}
local unpack = unpack or table.unpack
local generation_sequence = 0
local O_NOFOLLOW = 131072
local O_DIRECTORY = 65536
local MONOTONIC_SOURCE = "/proc/uptime"

local function safe_path(path)
  return type(path) == "string" and #path > 1 and #path <= 512 and path:sub(1, 1) == "/"
    and not path:find("[%z\1-\31\127]") and not path:find("/%.%./") and not path:match("/%.%.$")
end

local function safe_token(value)
  return type(value) == "string" and #value > 0 and #value <= 64 and value:match("^[0-9A-Za-z_-]+$") ~= nil
end

local function enabled(value) return value == true or value == 1 or value == "1" end

local function scalar(value)
  if type(value) == "boolean" then return value and "1" or "0" end
  if type(value) == "number" then return tostring(value) end
  if type(value) == "string" then return value end
end

local function public_section(section)
  if type(section) ~= "table" then return nil end
  local output = { id = section[".name"] }
  for key, value in pairs(section) do
    if type(key) == "string" and key:sub(1, 1) ~= "." then output[key] = value end
  end
  if output.active_node == "" then output.active_node = nil end
  if output.enabled ~= nil then output.enabled = enabled(output.enabled) end
  return output
end

local function poll_child(nixio, pid)
  local called, waited, state, status = pcall(nixio.waitpid, pid, "nohang")
  if not called or waited == nil then return nil end
  if waited == false or waited == 0 then return false end
  if waited ~= pid and waited ~= true then return nil end
  return true, state == "exited" and status == 0
end

local function nixio_mode(mode)
  if mode == "0600" or mode == 600 then return 600 end
  if mode == "0700" or mode == 700 then return 700 end
  return nil
end

local function terminate_and_reap(nixio, pid, now, sleep)
  pcall(nixio.kill, pid, 15)
  local grace = now() + 1
  while now() < grace do
    local finished = poll_child(nixio, pid)
    if finished == true then return false end
    if finished == nil then break end
    sleep(0.05)
  end
  pcall(nixio.kill, pid, 9)
  local reap_deadline = now() + 1
  while now() < reap_deadline do
    local finished = poll_child(nixio, pid)
    if finished == true or finished == nil then return false end
    sleep(0.05)
  end
  return false
end

local function wait_status(nixio, pid, deadline, now, sleep)
  while now() < deadline do
    local finished, success = poll_child(nixio, pid)
    if finished == true then return success end
    if finished == nil then return terminate_and_reap(nixio, pid, now, sleep) end
    sleep(0.05)
  end
  return terminate_and_reap(nixio, pid, now, sleep)
end

local function valid_argv(argv)
  if type(argv) ~= "table" or #argv < 1 or #argv > 16 then return false end
  for _, value in ipairs(argv) do
    if type(value) ~= "string" or #value == 0 or #value > 2048 or value:find("[%z\1-\31\127]") then return false end
  end
  return argv[1]:sub(1, 1) == "/"
end

local function spawn(nixio, argv, deadline, now, sleep)
  if not valid_argv(argv) then return false end
  local pid = nixio.fork()
  if pid == 0 then
    local null = nixio.open("/dev/null", "w")
    if null then
      nixio.dup(null, nixio.stdout)
      nixio.dup(null, nixio.stderr)
      null:close()
    end
    nixio.exec(unpack(argv))
    os.exit(127)
  end
  if type(pid) ~= "number" or pid < 1 then return false end
  return wait_status(nixio, pid, deadline, now, sleep)
end

local function errno_missing(nixio, code)
  if code == 2 or code == "ENOENT" then return true end
  local current = nixio.errno and nixio.errno() or nil
  return current == 2 or current == "ENOENT"
end

function M.new(injected)
  injected = injected or {}
  local nixio = injected.nixio or require "nixio"
  local nfs = injected.fs or require "nixio.fs"
  local uci_module = injected.uci_module or require "uci"
  local jsonc = injected.jsonc or require "luci.jsonc"
  local cursor = injected.cursor or uci_module.cursor()
  local now_process = injected.now or function() return M.now(nixio) end
  local sleep_process = injected.sleep or function(seconds)
    local whole = math.floor(seconds)
    nixio.nanosleep(whole, math.floor((seconds - whole) * 1000000000))
  end
  local spawn_process = injected.spawn or function(argv, deadline)
    return spawn(nixio, argv, deadline, now_process, sleep_process)
  end
  local capture_process = injected.capture or function(argv, deadline, maximum)
    if not valid_argv(argv) or type(maximum) ~= "number" or maximum < 1 or maximum > 1024 then return nil end
    generation_sequence = generation_sequence + 1
    local temporary = "/var/etc/xc/.observe-" .. tostring(nixio.getpid()) .. "-" .. tostring(generation_sequence)
    if nfs.stat(temporary) then return nil end
    local command = {}
    for index = 1, #argv - 1 do command[#command + 1] = argv[index] end
    command[#command + 1] = "--output"; command[#command + 1] = temporary; command[#command + 1] = argv[#argv]
    if not spawn_process(command, deadline) then nfs.unlink(temporary); return nil end
    local handle = nixio.open(temporary, nixio.open_flags("rdonly") + O_NOFOLLOW)
    if not handle then nfs.unlink(temporary); return nil end
    local value = handle:read(maximum + 1)
    local closed = handle:close()
    nfs.unlink(temporary)
    if closed ~= true or type(value) ~= "string" or #value > maximum then return nil end
    return value
  end

  local function foreach(section_type, callback)
    cursor:foreach("xc", section_type, callback)
  end

  local function revert_failure()
    pcall(cursor.revert, cursor, "xc")
    return false
  end

  local function mutation(method, ...)
    local ok, result = pcall(method, cursor, ...)
    return ok and result ~= false and result ~= nil
  end

  local function set_values(section, values)
    for key, value in pairs(values) do
      if type(key) == "string" and key ~= "id" and key:sub(1, 1) ~= "." then
        local item = scalar(value)
        if item ~= nil and not mutation(cursor.set, "xc", section, key, item) then return false end
      end
    end
    return true
  end

  local uci = {
    get_global = function()
      local values = {}
      foreach("global", function(section) values[#values + 1] = public_section(section) end)
      if #values ~= 1 then return nil end
      return values[1]
    end,
    get_node = function(id)
      if not schema.safe_section_id(id) then return nil, "invalid_id" end
      local called, section = pcall(cursor.get_all, cursor, "xc", id)
      if not called then return nil, "read_failed" end
      if not section or section[".type"] ~= "node" then return nil, "missing" end
      local node = public_section(section)
      if not node then return nil, "read_failed" end
      return node, "ok"
    end,
    list_nodes = function()
      local values = {}
      foreach("node", function(section)
        local value = public_section(section)
        if value and schema.safe_section_id(value.id) then values[#values + 1] = value end
      end)
      table.sort(values, function(left, right) return left.id < right.id end)
      return values
    end,
    set_active = function(id)
      if not schema.safe_section_id(id) then return false end
      if not mutation(cursor.set, "xc", "global", "active_node", id) then return revert_failure() end
      return true
    end,
    clear_active = function()
      if cursor:get("xc", "global", "active_node") == nil then return true end
      if not mutation(cursor.delete, "xc", "global", "active_node") then return revert_failure() end
      return true
    end,
    commit = function()
      local pre_called, pre_secured = pcall(nfs.chmod, "/etc/config/xc", 600)
      if not pre_called or pre_secured ~= true then return false, "pre_commit_failed" end
      local called, result = pcall(cursor.commit, cursor, "xc")
      if not called then
        pcall(nfs.chmod, "/etc/config/xc", 600)
        return false, "commit_unknown"
      end
      if result ~= true and result ~= 0 then return false, "pre_commit_failed" end
      local post_called, post_secured = pcall(nfs.chmod, "/etc/config/xc", 600)
      if not post_called or post_secured ~= true then return true, "committed_hardening_failed" end
      return true, "committed"
    end,
    revert = function() cursor:revert("xc"); return true end,
    stage_replace = function(global, nodes)
      if type(global) ~= "table" or type(nodes) ~= "table" then return false end
      local normalized_nodes = {}
      for index, node in ipairs(nodes) do
        local normalized = schema.normalize(node)
        if not normalized then return false end
        normalized_nodes[index] = normalized
      end
      local sections = {}
      foreach("global", function(section) sections[#sections + 1] = section[".name"] end)
      foreach("node", function(section) sections[#sections + 1] = section[".name"] end)
      for _, section in ipairs(sections) do
        if not mutation(cursor.delete, "xc", section) then return revert_failure() end
      end
      if not mutation(cursor.set, "xc", "global", "global") then return revert_failure() end
      if not set_values("global", global) then return revert_failure() end
      for _, normalized in ipairs(normalized_nodes) do
        if not mutation(cursor.set, "xc", normalized.id, "node") then return revert_failure() end
        if not set_values(normalized.id, normalized) then return revert_failure() end
      end
      return true
    end,
    stage_nodes = function(nodes)
      if type(nodes) ~= "table" then return false end
      local normalized_nodes = {}
      for index, node in ipairs(nodes) do
        local normalized = schema.normalize(node)
        if not normalized or cursor:get_all("xc", normalized.id) then return false end
        normalized_nodes[index] = normalized
      end
      for _, normalized in ipairs(normalized_nodes) do
        if not mutation(cursor.set, "xc", normalized.id, "node") then return revert_failure() end
        if not set_values(normalized.id, normalized) then return revert_failure() end
      end
      return true
    end
  }

  local O_WRONLY, O_CREAT, O_EXCL = "wronly", "creat", "excl"
  local function open_exclusive(path)
    local flags = nixio.open_flags(O_WRONLY, O_CREAT, O_EXCL) + O_NOFOLLOW
    return nixio.open(path, flags, 600)
  end

  local function ensure_directory(path)
    local information = nfs.stat(path)
    if not information then
      if type(nfs.mkdirr) ~= "function" or nfs.mkdirr(path) ~= true then return false end
      information = nfs.stat(path)
    end
    return type(information) == "table" and information.type == "dir" and nfs.chmod(path, 700) == true
  end

  local fs = {
    ensure_layout = function()
      for _, path in ipairs({ "/etc/xc", "/etc/xc/rollback", "/var/etc/xc" }) do
        if not ensure_directory(path) then return false end
      end
      local config = nfs.stat("/etc/config/xc")
      return not config or nfs.chmod("/etc/config/xc", 600) == true
    end,
    acquire_lock = function(path)
      if not safe_path(path) then return nil end
      local handle = nixio.open(path, nixio.open_flags("rdwr", "creat") + O_NOFOLLOW, 600)
      if not handle then return nil end
      if not handle:lock("tlock") then handle:close(); return nil end
      return { fd = handle, path = path }
    end,
    release_lock = function(handle)
      if type(handle) ~= "table" or not handle.fd then return false end
      local unlocked = handle.fd:lock("ulock")
      local closed = handle.fd:close()
      handle.fd = nil
      return unlocked == true and closed == true
    end,
    lock_state = function(path)
      if not safe_path(path) then return "unknown" end
      local handle = nixio.open(path, nixio.open_flags("rdwr", "creat") + O_NOFOLLOW, 600)
      if not handle then return "unknown" end
      local locked = handle:lock("tlock")
      if locked then handle:lock("ulock") end
      handle:close()
      return locked and "unlocked" or "held"
    end,
    read = function(path, maximum)
      if not safe_path(path) or type(maximum) ~= "number" or maximum < 0 or maximum > 1048576 then return nil, "io_error" end
      local handle, code = nixio.open(path, nixio.open_flags("rdonly") + O_NOFOLLOW)
      if not handle then return nil, errno_missing(nixio, code) and "missing" or "io_error" end
      local chunks, total = {}, 0
      while total <= maximum do
        local chunk = handle:read(math.min(65536, maximum + 1 - total))
        if chunk == nil then handle:close(); return nil, "io_error" end
        if chunk == "" then break end
        total = total + #chunk
        if total > maximum then handle:close(); return nil, "too_large" end
        chunks[#chunks + 1] = chunk
      end
      if handle:close() ~= true then return nil, "io_error" end
      return table.concat(chunks)
    end,
    read_tail = function(path, maximum)
      if not safe_path(path) or type(maximum) ~= "number" or maximum < 0 or maximum > 1048576 then return nil, "io_error" end
      local handle, code = nixio.open(path, nixio.open_flags("rdonly") + O_NOFOLLOW)
      if not handle then return nil, errno_missing(nixio, code) and "missing" or "io_error" end
      local size = handle:seek(0, "end")
      if type(size) ~= "number" then handle:close(); return nil, "io_error" end
      local offset = math.max(0, size - maximum)
      if offset > 0 and handle:seek(offset, "set") ~= offset then handle:close(); return nil, "io_error" end
      local chunks, total = {}, 0
      while total < maximum do
        local chunk = handle:read(math.min(65536, maximum - total))
        if chunk == nil then handle:close(); return nil, "io_error" end
        if chunk == "" then break end
        total = total + #chunk
        chunks[#chunks + 1] = chunk
      end
      if handle:close() ~= true then return nil, "io_error" end
      return table.concat(chunks)
    end,
    truncate = function(path)
      if not safe_path(path) then return false end
      local handle = nixio.open(path, nixio.open_flags("wronly", "creat", "trunc") + O_NOFOLLOW, 600)
      if not handle then return false end
      local synced = handle:sync() == true
      local closed = handle:close() == true
      return synced and closed and nfs.chmod(path, 600) == true
    end,
    write_temp = function(path, content)
      if not safe_path(path) or type(content) ~= "string" or #content > 1048576 then return nil end
      for attempt = 1, 32 do
        generation_sequence = generation_sequence + 1
        local temporary = path .. ".tmp." .. tostring(nixio.getpid()) .. "." .. tostring(generation_sequence) .. "." .. tostring(attempt)
        local handle = open_exclusive(temporary)
        if handle then
          local offset = 1
          while offset <= #content do
            local written = handle:write(content:sub(offset))
            if type(written) ~= "number" or written < 1 then handle:close(); nfs.unlink(temporary); return nil end
            offset = offset + written
          end
          return { fd = handle, path = temporary }
        end
      end
      return nil
    end,
    chmod = function(path, mode)
      local value = nixio_mode(mode)
      return safe_path(path) and value ~= nil and nfs.chmod(path, value) == true
    end,
    fsync = function(handle) return type(handle) == "table" and handle.fd and handle.fd:sync() == true end,
    fsync_dir = function(path)
      if not safe_path(path) then return false end
      local handle = nixio.open(path, nixio.open_flags("rdonly") + O_DIRECTORY + O_NOFOLLOW)
      if not handle then return false end
      local ok = handle:sync() == true
      handle:close()
      return ok
    end,
    close = function(handle)
      if type(handle) ~= "table" or not handle.fd then return false end
      local ok = handle.fd:close() == true
      handle.fd = nil
      return ok
    end,
    rename = function(source, destination) return safe_path(source) and safe_path(destination) and nfs.rename(source, destination) == true end,
    exists = function(path) return safe_path(path) and nfs.stat(path) ~= nil or false end,
    remove = function(path)
      if not safe_path(path) then return false end
      if not nfs.stat(path) then return true end
      return nfs.unlink(path) == true
    end,
    allocate_generation = function(directory)
      if not safe_path(directory) then return nil end
      for attempt = 1, 64 do
        generation_sequence = generation_sequence + 1
        local milliseconds = math.floor(M.now(nixio) * 1000)
        local token = string.format("%x-%x-%x", milliseconds, nixio.getpid(), generation_sequence)
        local reservation = directory .. "/.reserve-" .. token
        if not nfs.stat(directory .. "/generation-" .. token .. ".config")
          and not nfs.stat(directory .. "/generation-" .. token .. ".active")
          and not nfs.stat(directory .. "/.trash-" .. token .. ".config")
          and not nfs.stat(directory .. "/.trash-" .. token .. ".active") then
          local handle = open_exclusive(reservation)
          if handle then
            local synced, closed = handle:sync(), handle:close()
            if synced and closed then return token end
            nfs.unlink(reservation)
          end
        end
      end
      return nil
    end,
    list_generation_files = function(directory, limit)
      if not safe_path(directory) or type(limit) ~= "number" or limit < 1 or limit > 256 then return nil end
      local output = {}
      local iterator = nfs.dir(directory)
      if not iterator then return output end
      local scanned = 0
      for basename in iterator do
        scanned = scanned + 1
        if #output >= limit or scanned > 1024 then break end
        if basename:match("^generation%-%w[%w_-]*%.[A-Za-z]+$") or basename:match("^%.trash%-%w[%w_-]*%.[A-Za-z]+$") then
          output[#output + 1] = basename
        end
      end
      table.sort(output)
      return output
    end,
    trash_generation = function(directory, token)
      if not safe_path(directory) or not safe_token(token) then return nil end
      local config = directory .. "/generation-" .. token .. ".config"
      local active = directory .. "/generation-" .. token .. ".active"
      local trash_config = directory .. "/.trash-" .. token .. ".config"
      local trash_active = directory .. "/.trash-" .. token .. ".active"
      local source_config, source_active = nfs.stat(config), nfs.stat(active)
      local target_config, target_active = nfs.stat(trash_config), nfs.stat(trash_active)
      if not source_config and not source_active then
        if (target_config and target_active) or (not target_config and not target_active) then return token end
        return nil
      end
      if target_config and not source_config and source_active and not target_active then
        if nfs.rename(active, trash_active) ~= true then return nil end
      elseif target_active and not source_active and source_config and not target_config then
        if nfs.rename(config, trash_config) ~= true then return nil end
      elseif source_config and source_active and not target_config and not target_active then
        if nfs.rename(config, trash_config) ~= true then return nil end
        if nfs.rename(active, trash_active) ~= true then nfs.rename(trash_config, config); return nil end
      else
        return nil
      end
      nfs.unlink(directory .. "/.reserve-" .. token)
      return token
    end,
    delete_trashed_generation = function(directory, token)
      if not safe_path(directory) or not safe_token(token) then return false end
      for _, suffix in ipairs({ ".config", ".active" }) do
        local path = directory .. "/.trash-" .. token .. suffix
        if nfs.stat(path) and nfs.unlink(path) ~= true then return false end
      end
      nfs.unlink(directory .. "/.reserve-" .. token)
      return true
    end
  }

  local exec = {
    run = function(argv, deadline)
      if type(argv) ~= "table" or #argv ~= 5 or argv[1] ~= "/usr/bin/xray" or argv[2] ~= "run"
        or argv[3] ~= "-test" or argv[4] ~= "-c" or not safe_path(argv[5]) then return false end
      deadline = deadline or (now_process() + 30)
      if type(deadline) ~= "number" or deadline <= now_process() or deadline > now_process() + 300 then return false end
      return spawn_process(argv, deadline)
    end,
    restart = function()
      return spawn_process({ "/etc/init.d/xc", "restart_prepared" }, now_process() + 30)
    end,
    stop = function() return spawn_process({ "/etc/init.d/xc", "stop" }, now_process() + 30) end,
    service_state = function(deadline)
      deadline = deadline or (now_process() + 2)
      return spawn_process({ "/etc/init.d/xc", "running" }, deadline) and "running" or "stopped"
    end,
    listener_ready = function(kind, address, port, deadline)
      if (kind ~= "socks" and kind ~= "http") or type(address) ~= "string" or not tonumber(port) or M.now(nixio) >= deadline then return false end
      local family = address:find(":", 1, true) and "inet6" or "inet"
      local socket = nixio.socket(family, "stream")
      if not socket then return false end
      if not socket:setblocking(false) then socket:close(); return false end
      local connected, connect_error = socket:connect(address, tostring(port))
      if not connected and connect_error ~= nixio.const.EINPROGRESS and connect_error ~= nixio.const.EWOULDBLOCK
        and connect_error ~= nixio.const.EAGAIN then socket:close(); return false end
      if not connected then
        local remaining = deadline - M.now(nixio)
        if remaining <= 0 then socket:close(); return false end
        local descriptor = { { fd = socket, events = nixio.poll_flags("out", "err") } }
        local ready = nixio.poll(descriptor, math.max(1, math.min(30000, math.floor(remaining * 1000))))
        if not ready or ready < 1 then socket:close(); return false end
        local socket_error = socket:getsockopt("socket", "error")
        if socket_error ~= 0 then socket:close(); return false end
      end
      if M.now(nixio) >= deadline then socket:close(); return false end
      socket:close()
      return true
    end,
    health_check = function(kind, address, port, url, deadline)
      if (kind ~= "socks" and kind ~= "http") or type(address) ~= "string" or not tonumber(port)
        or type(url) ~= "string" or not url:match("^https?://") then return false end
      local remaining = math.floor(deadline - now_process())
      if remaining < 1 then return false end
      local proxy_flag = kind == "socks" and "--socks5-hostname" or "--proxy"
      local host = address:find(":", 1, true) and ("[" .. address .. "]") or address
      local proxy = kind == "socks" and (host .. ":" .. tostring(port)) or ("http://" .. host .. ":" .. tostring(port))
      return spawn_process({ "/usr/bin/curl", "--fail", "--silent", "--show-error", "--max-time", tostring(remaining),
        "--connect-timeout", tostring(math.min(remaining, 5)), proxy_flag, proxy, url }, deadline)
    end,
    observe_exit_ip = function(kind, address, port, url, deadline)
      if (kind ~= "socks" and kind ~= "http") or type(address) ~= "string" or not tonumber(port)
        or type(url) ~= "string" or not url:match("^https?://") then return nil end
      local remaining = math.floor(deadline - now_process())
      if remaining < 1 then return nil end
      local proxy_flag = kind == "socks" and "--socks5-hostname" or "--proxy"
      local host = address:find(":", 1, true) and ("[" .. address .. "]") or address
      local proxy = kind == "socks" and (host .. ":" .. tostring(port)) or ("http://" .. host .. ":" .. tostring(port))
      return capture_process({ "/usr/bin/curl", "--fail", "--silent", "--show-error", "--max-time", tostring(remaining),
        "--connect-timeout", tostring(math.min(remaining, 5)), "--max-filesize", "128", proxy_flag, proxy, url }, deadline, 128)
    end
  }

  local json = {
    parse = function(value) return jsonc.parse(value) end,
    stringify = function(value) return jsonc.stringify(value) end
  }

  local function network()
    local address = cursor:get("network", "lan", "ipaddr")
    if type(address) ~= "string" then return "127.0.0.1" end
    return address:match("^([^/]+)")
  end

  return {
    uci = uci, fs = fs, exec = exec, json = json, network = network,
    now = now_process,
    sleep = function(seconds) if seconds > 0 and seconds <= 30 then sleep_process(seconds) end end
  }
end

function M.now(nixio)
  local handle = nixio.open("/proc/uptime", "r")
  if handle then
    local value = handle:read(64)
    handle:close()
    local seconds = type(value) == "string" and tonumber(value:match("^(%d+%.?%d*)")) or nil
    if seconds then return seconds end
  end
  local info = nixio.sysinfo()
  return tonumber(info and info.uptime) or 0
end

return M
