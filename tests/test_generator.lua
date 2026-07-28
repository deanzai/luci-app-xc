local t = require "testlib"
local generator = require "xc.generator"

local UUID_ONE = "11111111-1111-1111-1111-111111111111"
local PRIVATE_CIDRS = {
  "0.0.0.0/8",
  "10.0.0.0/8",
  "127.0.0.0/8",
  "169.254.0.0/16",
  "172.16.0.0/12",
  "192.168.0.0/16",
  "224.0.0.0/4",
  "::1/128",
  "fc00::/7",
  "fe80::/10"
}

local function global(overrides)
  local value = {
    listen_address = "192.168.6.1",
    socks_port = 7890,
    http_port = 10809
  }
  for key, item in pairs(overrides or {}) do value[key] = item end
  return value
end

local function assert_array_equal(actual, expected)
  t.eq(#actual, #expected)
  for index, item in ipairs(expected) do t.eq(actual[index], item) end
end

local function has_key(value, sought, seen)
  if type(value) ~= "table" then return false end
  seen = seen or {}
  if seen[value] then return false end
  seen[value] = true
  for key, item in pairs(value) do
    if key == sought or has_key(item, sought, seen) then return true end
  end
  return false
end

t.test("builds compatible unauthenticated SOCKS and HTTP inbounds", function()
  local cfg = assert(generator.build(global(), {
    protocol = "vless", server = "vless.invalid", port = 443,
    uuid = UUID_ONE, encryption = "none", transport = "tcp", security = "none"
  }))

  t.eq(#cfg.inbounds, 2)
  t.eq(cfg.inbounds[1].tag, "socks-in")
  t.eq(cfg.inbounds[1].listen, "192.168.6.1")
  t.eq(cfg.inbounds[1].port, 7890)
  t.eq(cfg.inbounds[1].protocol, "socks")
  t.eq(cfg.inbounds[1].settings.auth, "noauth")
  t.eq(cfg.inbounds[1].settings.udp, true)
  t.eq(cfg.inbounds[1].settings.accounts, nil)
  t.eq(cfg.inbounds[2].tag, "http-in")
  t.eq(cfg.inbounds[2].listen, "192.168.6.1")
  t.eq(cfg.inbounds[2].port, 10809)
  t.eq(cfg.inbounds[2].protocol, "http")
  t.eq(cfg.inbounds[2].settings.accounts, nil)

  for _, inbound in ipairs(cfg.inbounds) do
    t.eq(inbound.sniffing.enabled, true)
    t.eq(inbound.sniffing.routeOnly, true)
    assert_array_equal(inbound.sniffing.destOverride, { "http", "tls" })
  end
end)

t.test("puts the selected outbound first and routes only exact literal CIDRs directly", function()
  local cfg = assert(generator.build(global(), {
    protocol = "vless", server = "vless.invalid", port = 443,
    uuid = UUID_ONE, transport = "tcp", security = "none"
  }))

  t.eq(#cfg.outbounds, 3)
  t.eq(cfg.outbounds[1].tag, "proxy-selected")
  t.eq(cfg.outbounds[2].tag, "direct")
  t.eq(cfg.outbounds[2].protocol, "freedom")
  t.eq(cfg.outbounds[3].tag, "block")
  t.eq(cfg.outbounds[3].protocol, "blackhole")
  t.eq(cfg.routing.domainStrategy, "AsIs")
  t.eq(#cfg.routing.rules, 1)
  t.eq(cfg.routing.rules[1].type, "field")
  t.eq(cfg.routing.rules[1].outboundTag, "direct")
  assert_array_equal(cfg.routing.rules[1].ip, PRIVATE_CIDRS)
  t.eq(has_key(cfg, "reality_uk"), false)
  t.eq(has_key(cfg, "reality_uk_id"), false)
  t.eq(#cfg.outbounds, 3, "must not add a dedicated-domain outbound")
end)

t.test("returns independent deterministic routing tables", function()
  local node = {
    protocol = "vless", server = "vless.invalid", port = 443,
    uuid = UUID_ONE, transport = "tcp", security = "none"
  }
  local first = assert(generator.build(global(), node))
  first.routing.rules[1].ip[1] = "mutated-by-caller"
  local second = assert(generator.build(global(), node))
  assert_array_equal(second.routing.rules[1].ip, PRIVATE_CIDRS)
end)

t.test("maps VLESS Reality over TCP without changing credential bytes", function()
  local public_key = "PUB+/CaseSensitive=="
  local outbound = assert(generator.build_outbound({
    protocol = "vless", server = "reality.invalid", port = 443,
    uuid = UUID_ONE, encryption = "none", flow = "xtls-rprx-vision",
    transport = "tcp", security = "reality", sni = "cover.invalid",
    public_key = public_key, short_id = "aB09", fingerprint = "chrome"
  }, "chosen"))

  t.eq(outbound.tag, "chosen")
  t.eq(outbound.protocol, "vless")
  t.eq(outbound.settings.vnext[1].address, "reality.invalid")
  t.eq(outbound.settings.vnext[1].port, 443)
  t.eq(outbound.settings.vnext[1].users[1].id, UUID_ONE)
  t.eq(outbound.settings.vnext[1].users[1].encryption, "none")
  t.eq(outbound.settings.vnext[1].users[1].flow, "xtls-rprx-vision")
  t.eq(outbound.streamSettings.network, "tcp")
  t.eq(outbound.streamSettings.security, "reality")
  t.eq(outbound.streamSettings.tcpSettings.header.type, "none")
  t.eq(outbound.streamSettings.realitySettings.serverName, "cover.invalid")
  t.eq(outbound.streamSettings.realitySettings.publicKey, public_key)
  t.eq(outbound.streamSettings.realitySettings.shortId, "aB09")
  t.eq(outbound.streamSettings.realitySettings.fingerprint, "chrome")
end)

t.test("maps VLESS TLS and WebSocket fields", function()
  local outbound = assert(generator.build_outbound({
    protocol = "vless", server = "tls.invalid", port = 8443,
    uuid = UUID_ONE, encryption = "none", transport = "ws", security = "tls",
    sni = "sni.invalid", fingerprint = "firefox",
    ws_host = "cdn.invalid", ws_path = "/socket"
  }, "proxy-selected"))

  t.eq(outbound.settings.vnext[1].users[1].id, UUID_ONE)
  t.eq(outbound.streamSettings.network, "ws")
  t.eq(outbound.streamSettings.security, "tls")
  t.eq(outbound.streamSettings.wsSettings.path, "/socket")
  t.eq(outbound.streamSettings.wsSettings.headers.Host, "cdn.invalid")
  t.eq(outbound.streamSettings.tlsSettings.serverName, "sni.invalid")
  t.eq(outbound.streamSettings.tlsSettings.fingerprint, "firefox")
  t.eq(outbound.streamSettings.tlsSettings.allowInsecure, false)
end)

t.test("maps VMess over gRPC with current Xray user fields", function()
  local outbound = assert(generator.build_outbound({
    protocol = "vmess", server = "vmess.invalid", port = 443,
    uuid = UUID_ONE, alter_id = 0, encryption = "auto",
    transport = "grpc", grpc_service_name = "edge-service", security = "tls",
    sni = "vmess.invalid"
  }, "proxy-selected"))

  t.eq(outbound.protocol, "vmess")
  t.eq(outbound.settings.vnext[1].users[1].id, UUID_ONE)
  t.eq(outbound.settings.vnext[1].users[1].alterId, 0)
  t.eq(outbound.settings.vnext[1].users[1].security, "auto")
  t.eq(outbound.streamSettings.network, "grpc")
  t.eq(outbound.streamSettings.grpcSettings.serviceName, "edge-service")
  t.eq(outbound.streamSettings.tlsSettings.serverName, "vmess.invalid")
end)

t.test("maps Xray 24 and 26 compatible VLESS Reality over gRPC", function()
  local outbound = assert(generator.build_outbound({
    protocol = "vless", server = "reality-grpc.invalid", port = 443,
    uuid = UUID_ONE, encryption = "none", transport = "grpc",
    grpc_service_name = "reality-service", security = "reality",
    sni = "cover.invalid", public_key = "PublicKey+/Bytes", short_id = "a1b2",
    fingerprint = "chrome"
  }, "proxy-selected"))

  t.eq(outbound.streamSettings.network, "grpc")
  t.eq(outbound.streamSettings.grpcSettings.serviceName, "reality-service")
  t.eq(outbound.streamSettings.security, "reality")
  t.eq(outbound.streamSettings.realitySettings.publicKey, "PublicKey+/Bytes")
end)

t.test("maps Trojan and Shadowsocks server records", function()
  local password = "p@ss+/Keep-Bytes"
  local trojan = assert(generator.build_outbound({
    protocol = "trojan", server = "trojan.invalid", port = 443,
    password = password, transport = "tcp", security = "tls", sni = "trojan.invalid"
  }, "trojan-tag"))
  t.eq(trojan.protocol, "trojan")
  t.eq(trojan.settings.servers[1].address, "trojan.invalid")
  t.eq(trojan.settings.servers[1].port, 443)
  t.eq(trojan.settings.servers[1].password, password)
  t.eq(trojan.streamSettings.tcpSettings.header.type, "none")

  local shadowsocks = assert(generator.build_outbound({
    protocol = "shadowsocks", server = "ss.invalid", port = 8388,
    method = "aes-256-gcm", password = password,
    transport = "tcp", security = "none"
  }, "ss-tag"))
  t.eq(shadowsocks.protocol, "shadowsocks")
  t.eq(shadowsocks.settings.servers[1].address, "ss.invalid")
  t.eq(shadowsocks.settings.servers[1].port, 8388)
  t.eq(shadowsocks.settings.servers[1].method, "aes-256-gcm")
  t.eq(shadowsocks.settings.servers[1].password, password)
end)

t.test("maps authenticated and unauthenticated SOCKS outbounds", function()
  local password = "SOCKS-secret+/"
  local authenticated = assert(generator.build_outbound({
    protocol = "socks", server = "socks.invalid", port = 1080,
    user = "CaseSensitiveUser", password = password
  }, "auth"))
  t.eq(authenticated.settings.servers[1].users[1].user, "CaseSensitiveUser")
  t.eq(authenticated.settings.servers[1].users[1].pass, password)

  local anonymous = assert(generator.build_outbound({
    protocol = "socks", server = "127.0.0.1", port = 1081
  }, "anonymous"))
  t.eq(anonymous.protocol, "socks")
  t.eq(anonymous.settings.servers[1].address, "127.0.0.1")
  t.eq(anonymous.settings.servers[1].port, 1081)
  t.eq(anonymous.settings.servers[1].users, nil)
  t.eq(anonymous.streamSettings, nil)
end)

t.test("clones a decoded raw outbound and authoritatively overrides its tag", function()
  local raw = {
    protocol = "wireguard",
    tag = "do-not-keep",
    settings = { secretKey = "RawSecret+/", peers = { { endpoint = "peer.invalid:51820" } } }
  }
  local node = { protocol = "raw", raw_outbound_table = raw }
  local outbound = assert(generator.build_outbound(node, "proxy-selected"))

  t.eq(outbound.protocol, "wireguard")
  t.eq(outbound.tag, "proxy-selected")
  t.eq(outbound.settings.secretKey, "RawSecret+/")
  t.eq(outbound.settings.peers[1].endpoint, "peer.invalid:51820")
  t.truthy(outbound ~= raw)
  t.truthy(outbound.settings ~= raw.settings)
  t.eq(raw.tag, "do-not-keep")
  t.eq(node.raw_outbound_table, raw)

  local table_valued = assert(generator.build_outbound({
    protocol = "raw", raw_outbound = { protocol = "freedom", tag = "old" }
  }, "replacement"))
  t.eq(table_valued.protocol, "freedom")
  t.eq(table_valued.tag, "replacement")
end)

t.test("documents the raw JSON adapter boundary and safely rejects unsafe raw tables", function()
  local secret = "do-not-echo-this-raw-secret"
  local value, err = generator.build_outbound({
    protocol = "raw", raw_outbound = '{"password":"' .. secret .. '"}'
  }, "proxy-selected")
  t.eq(value, nil)
  t.contains(err, "raw outbound")
  t.eq(err:find(secret, 1, true), nil)

  local cyclic = { protocol = "freedom", password = secret }
  cyclic.settings = cyclic
  local _, cycle_err = generator.build_outbound({ protocol = "raw", raw_outbound_table = cyclic }, "proxy-selected")
  t.contains(cycle_err, "raw outbound")
  t.eq(cycle_err:find(secret, 1, true), nil)

  local nested = { protocol = "freedom" }
  local cursor = nested
  for _ = 1, 33 do cursor.child = {}; cursor = cursor.child end
  local _, depth_err = generator.build_outbound({ protocol = "raw", raw_outbound_table = nested }, "proxy-selected")
  t.contains(depth_err, "raw outbound")

  local too_many = { protocol = "freedom" }
  for index = 1, 8192 do too_many["member" .. index] = index end
  local _, member_err = generator.build_outbound({ protocol = "raw", raw_outbound_table = too_many }, "proxy-selected")
  t.contains(member_err, "raw outbound")
end)

t.test("rejects unsafe globals without mutating caller input", function()
  local node = {
    protocol = "vless", server = "immutable.invalid", port = 443,
    uuid = UUID_ONE, transport = "tcp", security = "none"
  }
  local input_global = global({ socks_port = "7890", http_port = "10809" })
  local cfg = assert(generator.build(input_global, node))
  t.eq(cfg.inbounds[1].port, 7890)
  t.eq(input_global.socks_port, "7890")
  t.eq(node.security, "none")

  for _, invalid in ipairs({
    global({ listen_address = "0.0.0.0;reboot" }),
    global({ listen_address = "host name" }),
    global({ socks_port = 0 }),
    global({ http_port = 65536 }),
    global({ socks_port = 7890, http_port = 7890 })
  }) do
    local value, err = generator.build(invalid, node)
    t.eq(value, nil)
    t.truthy(err)
  end
end)

t.test("requires raw for unsupported structured combinations and protocols", function()
  local value, err = generator.build_outbound({
    protocol = "vless", server = "unsupported.invalid", port = 443,
    uuid = UUID_ONE, transport = "ws", security = "reality",
    sni = "cover.invalid", public_key = "key"
  }, "proxy-selected")
  t.eq(value, nil)
  t.contains(err, "protocol=raw")

  local flow, flow_err = generator.build_outbound({
    protocol = "vless", server = "unsupported.invalid", port = 443,
    uuid = UUID_ONE, flow = "xtls-rprx-vision", transport = "grpc",
    security = "tls", sni = "cover.invalid"
  }, "proxy-selected")
  t.eq(flow, nil)
  t.contains(flow_err, "protocol=raw")

  local unknown, unknown_err = generator.build_outbound({
    protocol = "hysteria2", server = "unsupported.invalid", port = 443
  }, "proxy-selected")
  t.eq(unknown, nil)
  t.contains(unknown_err, "protocol=raw")

  local invalid_vmess, vmess_err = generator.build_outbound({
    protocol = "vmess", server = "vmess.invalid", port = 443,
    uuid = UUID_ONE, alter_id = math.huge, transport = "tcp", security = "none"
  }, "proxy-selected")
  t.eq(invalid_vmess, nil)
  t.truthy(vmess_err)
end)

return true
