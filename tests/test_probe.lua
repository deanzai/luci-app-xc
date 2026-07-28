local t = require "testlib"

local function load_probe()
  local ok, value = pcall(require, "xc.probe")
  t.truthy(ok, "xc.probe must exist")
  return value
end

local function fixture(options)
  options = options or {}
  local state = { closed = 0, locks = 0, unlocks = 0, writes = {}, reads = options.cache }
  local ticks = options.ticks or { 10, 10.042 }
  local tick = 0
  local socket = { close = function() state.closed = state.closed + 1; return true end }
  local network = {
    connect = function(host, port, deadline)
      state.host, state.port, state.deadline = host, port, deadline
      if options.connect == "timeout" then return nil, "timeout" end
      if options.connect == "fail" then return nil, "failed" end
      return socket, "ok"
    end,
    tls = function(_, sni)
      state.tls_sni = sni
      return options.tls ~= false, options.tls == false and "failed" or "ok"
    end,
    websocket = function(_, host, path)
      state.ws_host, state.ws_path = host, path
      return options.ws ~= false, options.ws == false and "failed" or "ok"
    end
  }
  local fs = {
    acquire_lock = function(path) state.locks = state.locks + 1; state.lock_path = path; return { fd = true } end,
    release_lock = function() state.unlocks = state.unlocks + 1; return true end,
    read = function(_, maximum) state.read_max = maximum; return state.reads or nil, state.reads and nil or "missing" end,
    write_temp = function(path, value) state.writes[#state.writes + 1] = value; return { fd = true, path = path .. ".tmp" } end,
    chmod = function() return true end, fsync = function() return true end, close = function() return true end,
    rename = function() return true end, fsync_dir = function() return true end, remove = function() return true end
  }
  local json = {
    parse = function(value)
      if value == "corrupt" then error("bad json") end
      return options.parsed_cache
    end,
    stringify = function(value)
      state.encoded = value
      return '{"version":1,"results":{}}'
    end
  }
  local adapters = {
    network = network, fs = fs, json = json,
    now = function() tick = tick + 1; return ticks[tick] or ticks[#ticks] end
  }
  return load_probe().new(adapters), state
end

local function node(values)
  local output = { id = "safe_node", enabled = true, protocol = "vless", server = "example.invalid",
    port = 443, transport = "tcp", security = "none", uuid = "do-not-cache" }
  for key, value in pairs(values or {}) do output[key] = value end
  return output
end

t.test("probe reports bounded TCP success and always closes the socket", function()
  local probe, state = fixture()
  local result = probe:run("safe_node", node(), 3)
  t.eq(result.socket, "ok"); t.eq(result.outcome, "tcp"); t.eq(result.ping, 42); t.eq(result.time, 42)
  t.eq(state.host, "example.invalid"); t.eq(state.port, 443); t.eq(state.closed, 1)
end)

t.test("probe distinguishes TCP failure and timeout without fabricating success", function()
  local probe, state = fixture({ connect = "fail" })
  local result = probe:run("safe_node", node(), 3)
  t.eq(result.socket, "fail"); t.eq(result.outcome, "error"); t.eq(result.ping, 0); t.eq(state.closed, 0)
  probe, state = fixture({ connect = "timeout" })
  result = probe:run("safe_node", node(), 3)
  t.eq(result.socket, "fail"); t.eq(result.outcome, "timeout"); t.eq(state.closed, 0)
end)

t.test("probe performs applicable TLS and WebSocket handshakes and closes on failure", function()
  local probe, state = fixture()
  local result = probe:run("safe_node", node({ security = "tls", sni = "cover.invalid" }), 3)
  t.eq(result.outcome, "tls"); t.eq(state.tls_sni, "cover.invalid"); t.eq(state.closed, 1)
  probe, state = fixture()
  result = probe:run("safe_node", node({ transport = "ws", security = "tls", sni = "cover.invalid",
    ws_host = "cdn.invalid", ws_path = "/edge" }), 3)
  t.eq(result.outcome, "ws"); t.eq(state.ws_host, "cdn.invalid"); t.eq(state.ws_path, "/edge"); t.eq(state.closed, 1)
  probe, state = fixture({ tls = false })
  result = probe:run("safe_node", node({ security = "tls", sni = "cover.invalid" }), 3)
  t.eq(result.socket, "fail"); t.eq(result.outcome, "tls_error"); t.eq(state.closed, 1)
end)

t.test("probe labels gRPC and raw modes explicitly", function()
  local probe = fixture()
  local result = probe:run("safe_node", node({ transport = "grpc" }), 3)
  t.eq(result.socket, "ok"); t.eq(result.outcome, "tcp_only_grpc")
  result = probe:run("safe_node", node({ protocol = "raw", server = nil, port = nil }), 3)
  t.eq(result.socket, "fail"); t.eq(result.outcome, "unsupported")
end)

t.test("probe clamps timeouts to one through ten seconds", function()
  local probe, state = fixture({ ticks = { 20, 20.001 } })
  probe:run("safe_node", node(), -5); t.eq(state.deadline, 21)
  probe, state = fixture({ ticks = { 30, 30.001 } })
  probe:run("safe_node", node(), 99); t.eq(state.deadline, 40)
end)

t.test("probe cache tolerates corruption, locks atomic writes, and remains secret-free", function()
  local probe, state = fixture({ cache = "corrupt" })
  local cached = probe:cached("safe_node")
  t.eq(cached, nil)
  local result = probe:run("safe_node", node({ password = "never-store", public_key = "never-store-either" }), 3)
  t.eq(state.locks, 2); t.eq(state.unlocks, 2); t.eq(state.read_max, 65536)
  t.truthy(type(state.encoded.results.safe_node.time) == "number")
  t.eq(state.encoded.results.safe_node.password, nil); t.eq(state.encoded.results.safe_node.public_key, nil)
end)

t.test("probe cache strips unknown and secret fields from every retained entry", function()
  local probe, state = fixture({ cache = "existing", parsed_cache = { version = 1, results = {
    other = { socket = "ok", ping = 5, time = 5, outcome = "tcp", password = "old-secret", raw = "old-link" }
  } } })
  probe:run("safe_node", node(), 3)
  t.eq(state.encoded.results.other.password, nil); t.eq(state.encoded.results.other.raw, nil)
  t.eq(state.encoded.results.other.socket, "ok"); t.eq(state.encoded.results.other.ping, 5)
end)

t.test("default TLS adapter uses the LuCI 21.02 nixio TLS context API", function()
  local saved_nixio, saved_tls = package.loaded.nixio, package.loaded["nixio.tls"]
  local state = { closed = 0 }
  local plain = {
    setblocking = function() return true end, connect = function() return true end,
    setopt = function() return true end, close = function() state.closed = state.closed + 1; return true end
  }
  local wrapped = {
    connect = function(_, argument) state.handshake_argument = argument; return true end,
    close = function() state.closed = state.closed + 1; return true end
  }
  package.loaded.nixio = {
    const = {}, socket = function() return plain end,
    tls = function(mode)
      state.tls_mode = mode
      return { create = function(_, socket) t.eq(socket, plain); return wrapped end }
    end
  }
  package.loaded["nixio.tls"] = nil
  local fs = {
    acquire_lock = function() return nil end, release_lock = function() return true end,
    read = function() return nil, "missing" end
  }
  local runner = load_probe().new({ fs = fs, json = { parse = function() end, stringify = function() end }, now = function() return 1 end })
  local result = runner:run("safe_node", node({ security = "tls", sni = "cover.invalid" }), 3)
  package.loaded.nixio, package.loaded["nixio.tls"] = saved_nixio, saved_tls
  t.eq(result.socket, "ok"); t.eq(result.outcome, "tls"); t.eq(state.tls_mode, "client")
  t.eq(state.handshake_argument, nil); t.eq(state.closed, 1)
end)

return true
