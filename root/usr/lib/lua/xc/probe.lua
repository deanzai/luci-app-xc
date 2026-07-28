local M = {}

local CACHE_PATH = "/tmp/xc-probe-cache.json"
local CACHE_LOCK = "/tmp/xc-probe-cache.lock"
local CACHE_MAX = 65536

local function clamp_timeout(value)
  value = math.floor(tonumber(value) or 3)
  if value < 1 then return 1 end
  if value > 10 then return 10 end
  return value
end

local function close_socket(socket)
  if socket and type(socket.close) == "function" then pcall(socket.close, socket) end
end

local function sanitize_result(value)
  if type(value) ~= "table" then return nil end
  local socket = value.socket == "ok" and "ok" or "fail"
  local outcome = type(value.outcome) == "string" and value.outcome:match("^[a-z_]+$") and value.outcome or "error"
  local milliseconds = tonumber(value.time) or 0
  if milliseconds < 0 then milliseconds = 0 elseif milliseconds > 10000 then milliseconds = 10000 end
  milliseconds = math.floor(milliseconds + 0.5)
  local ping = tonumber(value.ping) or 0
  if ping < 0 then ping = 0 elseif ping > 10000 then ping = 10000 end
  return { socket = socket, outcome = outcome, ping = math.floor(ping + 0.5), time = milliseconds }
end

local function sanitize_cache(value)
  local output, count = { version = 1, results = {} }, 0
  if type(value) ~= "table" or value.version ~= 1 or type(value.results) ~= "table" then return output end
  for section, result in pairs(value.results) do
    if count >= 512 then break end
    if type(section) == "string" and section:match("^[A-Za-z0-9_]+$") then
      local sanitized = sanitize_result(result)
      if sanitized then output.results[section] = sanitized; count = count + 1 end
    end
  end
  return output
end

local function default_network(now)
  local nixio = require "nixio"
  local network = {}

  function network.connect(host, port, deadline)
    if type(host) ~= "string" or #host < 1 or #host > 255 or host:find("[%z\1-\31\127]")
      or type(port) ~= "number" or port < 1 or port > 65535 then return nil, "failed" end
    local family = host:find(":", 1, true) and "inet6" or "inet"
    local socket = nixio.socket(family, "stream")
    if not socket then return nil, "failed" end
    if not socket:setblocking(false) then close_socket(socket); return nil, "failed" end
    local connected, err = socket:connect(host, tostring(port))
    if not connected and err ~= nixio.const.EINPROGRESS and err ~= nixio.const.EWOULDBLOCK and err ~= nixio.const.EAGAIN then
      close_socket(socket); return nil, "failed"
    end
    if not connected then
      local remaining = deadline - now()
      if remaining <= 0 then close_socket(socket); return nil, "timeout" end
      local poll = { { fd = socket, events = nixio.poll_flags("out", "err") } }
      local ready = nixio.poll(poll, math.max(1, math.min(10000, math.floor(remaining * 1000))))
      if not ready or ready < 1 then close_socket(socket); return nil, "timeout" end
      if socket:getsockopt("socket", "error") ~= 0 then close_socket(socket); return nil, "failed" end
    end
    if now() >= deadline then close_socket(socket); return nil, "timeout" end
    socket:setblocking(true)
    local remaining = math.max(1, math.ceil(deadline - now()))
    pcall(socket.setopt, socket, "socket", "rcvtimeo", remaining)
    pcall(socket.setopt, socket, "socket", "sndtimeo", remaining)
    return socket, "ok"
  end

  function network.tls(socket, sni, deadline)
    if type(sni) ~= "string" or #sni < 1 or #sni > 255 or now() >= deadline then return false, "failed" end
    if type(nixio.tls) ~= "function" then return false, "unsupported" end
    local ok, wrapped = pcall(function()
      local context = nixio.tls("client")
      if not context then return nil end
      local stream = context:create(socket)
      if not stream then return nil end
      local connected = stream:connect()
      if connected ~= true then close_socket(stream); return nil end
      return stream
    end)
    if not ok or not wrapped then return false, "failed" end
    return true, "ok", wrapped
  end

  function network.websocket(socket, host, path, deadline)
    if type(host) ~= "string" or #host < 1 or #host > 255 or host:find("[\r\n]")
      or type(path) ~= "string" or #path < 1 or #path > 2048 or path:sub(1, 1) ~= "/" or path:find("[\r\n]")
      or now() >= deadline then return false, "failed" end
    local request = "GET " .. path .. " HTTP/1.1\r\nHost: " .. host .. "\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
      .. "Sec-WebSocket-Key: WEMtcHJvYmUta2V5LTEyMw==\r\nSec-WebSocket-Version: 13\r\n\r\n"
    local written = socket:write(request)
    if type(written) ~= "number" or written ~= #request or now() >= deadline then return false, "failed" end
    local response = socket:read(4097)
    if type(response) ~= "string" or #response > 4096 then return false, "failed" end
    return response:match("^HTTP/1%.[01] 101[%s]") ~= nil, "ok"
  end
  return network
end

local function read_cache(self)
  local lock = self.fs.acquire_lock(CACHE_LOCK)
  if not lock then return { version = 1, results = {} } end
  local cache = { version = 1, results = {} }
  local ok, content = pcall(self.fs.read, CACHE_PATH, CACHE_MAX)
  if ok and type(content) == "string" then
    local parsed_ok, parsed = pcall(self.json.parse, content)
    if parsed_ok then cache = sanitize_cache(parsed) end
  end
  pcall(self.fs.release_lock, lock)
  return cache
end

local function write_cache(self, section, result)
  local lock = self.fs.acquire_lock(CACHE_LOCK)
  if not lock then return false end
  local success = false
  local ok = pcall(function()
    local cache = { version = 1, results = {} }
    local content = self.fs.read(CACHE_PATH, CACHE_MAX)
    if type(content) == "string" then
      local parsed_ok, parsed = pcall(self.json.parse, content)
      if parsed_ok then cache = sanitize_cache(parsed) end
    end
    cache.results[section] = sanitize_result(result)
    local encoded = self.json.stringify(cache)
    if type(encoded) ~= "string" or #encoded > CACHE_MAX then return end
    local temporary = self.fs.write_temp(CACHE_PATH, encoded)
    if not temporary then return end
    if not self.fs.chmod(temporary.path, "0600") or not self.fs.fsync(temporary) or not self.fs.close(temporary)
      or not self.fs.rename(temporary.path, CACHE_PATH) or not self.fs.fsync_dir("/tmp") then
      pcall(self.fs.remove, temporary.path); return
    end
    success = true
  end)
  pcall(self.fs.release_lock, lock)
  return ok and success
end

function M.new(adapters)
  adapters = adapters or {}
  local self = {
    fs = assert(adapters.fs), json = assert(adapters.json), now = assert(adapters.now),
    network = adapters.network
  }
  if type(self.network) ~= "table" then self.network = default_network(self.now) end

  function self:cached(section)
    local cache = read_cache(self)
    return sanitize_result(cache.results[section])
  end

  function self:run(section, node, timeout)
    if type(node) ~= "table" or node.protocol == "raw" or type(node.server) ~= "string" or not tonumber(node.port) then
      return { socket = "fail", ping = 0, time = 0, outcome = "unsupported" }
    end
    local started = self.now()
    local deadline = started + clamp_timeout(timeout)
    local socket, connect_outcome = self.network.connect(node.server, tonumber(node.port), deadline)
    local result
    if not socket then
      local elapsed = math.max(0, math.min(10000, (self.now() - started) * 1000))
      result = { socket = "fail", ping = 0, time = elapsed, outcome = connect_outcome == "timeout" and "timeout" or "error" }
    else
      local current = socket
      local ok, outcome = true, "tcp"
      if node.transport == "grpc" then
        outcome = "tcp_only_grpc"
      elseif node.security == "reality" then
        outcome = "tcp_only_reality"
      elseif node.security == "tls" then
        local tls_ok, tls_outcome, wrapped = self.network.tls(current, node.sni or node.server, deadline)
        if wrapped then current = wrapped end
        ok, outcome = tls_ok == true, tls_ok and "tls" or (tls_outcome == "unsupported" and "tls_unsupported" or "tls_error")
      end
      if ok and node.transport == "ws" then
        local ws_ok = self.network.websocket(current, node.ws_host or node.sni or node.server, node.ws_path or "/", deadline)
        ok, outcome = ws_ok == true, ws_ok and "ws" or "ws_error"
      end
      local elapsed = math.max(0, math.min(10000, (self.now() - started) * 1000))
      result = { socket = ok and "ok" or "fail", ping = ok and elapsed or 0, time = elapsed, outcome = outcome }
      close_socket(current)
      if current ~= socket then socket = nil end
    end
    result = sanitize_result(result)
    if type(section) == "string" and section:match("^[A-Za-z0-9_]+$") then write_cache(self, section, result) end
    return result
  end
  return self
end

M.paths = { cache = CACHE_PATH, lock = CACHE_LOCK }
return M
