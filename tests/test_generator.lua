local t = require "testlib"
local generator = require "xc.generator"
local routing = require "xc.routing"

local UUID_ONE = "11111111-1111-1111-1111-111111111111"
local REALITY_PUBLIC_KEY = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
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

local function json_quote(value)
  local escapes = { ['\\'] = '\\\\', ['"'] = '\\"', ['\b'] = '\\b', ['\f'] = '\\f', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }
  return '"' .. value:gsub('[%z\1-\31\\"]', function(character)
    return escapes[character] or string.format("\\u%04x", character:byte())
  end) .. '"'
end

-- luci.jsonc represents an empty Lua table as a JSON array. This intentionally
-- reproduces that boundary instead of pretending Lua has distinct object/array types.
local function luci_compatible_stringify(value)
  local kind = type(value)
  if kind == "nil" then return "null" end
  if kind == "boolean" then return value and "true" or "false" end
  if kind == "number" then return tostring(value) end
  if kind == "string" then return json_quote(value) end
  if kind ~= "table" then error("unsupported test JSON value") end

  local count, maximum, array = 0, 0, true
  for key in pairs(value) do
    count = count + 1
    if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then
      array = false
    elseif key > maximum then
      maximum = key
    end
  end
  if count == 0 then return "[]" end
  if array and maximum == count then
    local output = {}
    for index = 1, maximum do output[index] = luci_compatible_stringify(value[index]) end
    return "[" .. table.concat(output, ",") .. "]"
  end

  local keys = {}
  for key in pairs(value) do
    if type(key) ~= "string" then error("mixed test JSON table") end
    keys[#keys + 1] = key
  end
  table.sort(keys)
  local output = {}
  for _, key in ipairs(keys) do
    output[#output + 1] = json_quote(key) .. ":" .. luci_compatible_stringify(value[key])
  end
  return "{" .. table.concat(output, ",") .. "}"
end

local luci_json = { stringify = luci_compatible_stringify }

t.test("builds the default Xray log block and preserves every allowed log level", function()
  local node = {
    protocol = "vless", server = "vless.invalid", port = 443,
    uuid = UUID_ONE, encryption = "none", transport = "tcp", security = "none"
  }
  local default_config = assert(generator.build(global(), node))
  t.eq(default_config.log.access, "none")
  t.eq(default_config.log.loglevel, "warning")
  t.eq(default_config.log.dnsLog, false)

  for _, level in ipairs({ "error", "warning", "info", "debug" }) do
    local config = assert(generator.build(global({ xray_log_level = level }), node))
    t.eq(config.log.access, "none")
    t.eq(config.log.loglevel, level)
    t.eq(config.log.dnsLog, false)
  end
end)

t.test("rejects non-string and unknown Xray log levels before a config can be encoded", function()
  for _, level in ipairs({ false, true, 1, {}, "trace" }) do
    local config, err = generator.build(global({ xray_log_level = level }), {
      protocol = "vless", server = "vless.invalid", port = 443,
      uuid = UUID_ONE, encryption = "none", transport = "tcp", security = "none"
    })
    t.eq(config, nil)
    t.eq(err, "invalid Xray log level")

    local calls = 0
    if config then
      generator.encode(config, { stringify = function() calls = calls + 1; return "{}" end })
    end
    t.eq(calls, 0)
  end
end)

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
  t.eq(cfg.inbounds[2].settings, nil)

  for _, inbound in ipairs(cfg.inbounds) do
    t.eq(inbound.sniffing.enabled, true)
    t.eq(inbound.sniffing.routeOnly, true)
    assert_array_equal(inbound.sniffing.destOverride, { "http", "tls" })
  end
end)

t.test("puts the selected outbound first and keeps literal private CIDRs directly routed", function()
  local cfg = assert(generator.build(global(), {
    protocol = "vless", server = "vless.invalid", port = 443,
    uuid = UUID_ONE, transport = "tcp", security = "none"
  }))

  t.eq(#cfg.outbounds, 3)
  t.eq(cfg.outbounds[1].tag, "proxy-selected")
  t.eq(cfg.outbounds[2].tag, "direct")
  t.eq(cfg.outbounds[2].protocol, "freedom")
  t.eq(cfg.outbounds[2].settings, nil)
  t.eq(cfg.outbounds[3].tag, "block")
  t.eq(cfg.outbounds[3].protocol, "blackhole")
  t.eq(cfg.routing.domainStrategy, "IPIfNonMatch")
  t.truthy(#cfg.routing.rules > 1)
  local private_rule
  for _, rule in ipairs(cfg.routing.rules) do
    if rule.ip and #rule.ip == #PRIVATE_CIDRS then private_rule = rule end
  end
  t.truthy(private_rule)
  t.eq(private_rule.type, "field")
  t.eq(private_rule.outboundTag, "direct")
  assert_array_equal(private_rule.ip, PRIVATE_CIDRS)
  t.eq(has_key(cfg, "reality_uk"), false)
  t.eq(has_key(cfg, "reality_uk_id"), false)
  t.eq(#cfg.outbounds, 3, "must not add a dedicated-domain outbound")
end)

t.test("applies the preset geo routing rules to the selected outbound", function()
  local cfg = assert(generator.build(global(), {
    protocol = "vless", server = "vless.invalid", port = 443,
    uuid = UUID_ONE, transport = "tcp", security = "none"
  }))

  t.eq(#cfg.routing.rules, 11)
  t.eq(cfg.routing.rules[3].domain[1], "geosite:category-ads-all")
  t.eq(cfg.routing.rules[3].outboundTag, "block")
  t.eq(cfg.routing.rules[4].ip[1], "geoip:private")
  t.eq(cfg.routing.rules[4].outboundTag, "direct")
  t.eq(cfg.routing.rules[5].domain[1], "geosite:private")
  t.eq(cfg.routing.rules[5].outboundTag, "direct")
  t.eq(cfg.routing.rules[6].outboundTag, "direct")
  t.eq(cfg.routing.rules[7].outboundTag, "proxy-selected")
  t.eq(cfg.routing.rules[8].domain[1], "geosite:geolocation-!cn")
  t.eq(cfg.routing.rules[8].outboundTag, "proxy-selected")
  t.eq(cfg.routing.rules[9].ip[1], "geoip:cn")
  t.eq(cfg.routing.rules[9].outboundTag, "direct")
  t.eq(cfg.routing.rules[10].domain[1], "geosite:cn")
  t.eq(cfg.routing.rules[10].outboundTag, "direct")
  t.eq(cfg.routing.rules[11].outboundTag, "proxy-selected")
  t.eq(has_key(cfg, "reality-uk"), false)
end)

t.test("adds split DNS servers and routes remote DNS queries through the selected outbound", function()
  local cfg = assert(generator.build(global(), {
    protocol = "vless", server = "vless.invalid", port = 443,
    uuid = UUID_ONE, transport = "tcp", security = "none"
  }))

  t.eq(cfg.dns.queryStrategy, "UseIPv4")
  t.eq(cfg.dns.tag, "dns-in")
  t.eq(cfg.dns.disableCache, false)
  t.eq(cfg.dns.disableFallbackIfMatch, true)
  t.eq(#cfg.dns.servers, 4)
  t.eq(cfg.dns.servers[1].tag, nil)
  t.eq(cfg.dns.servers[1].address, "https://8.8.8.8/dns-query")
  t.eq(cfg.dns.servers[1].domains[1], "geosite:geolocation-!cn")
  t.eq(cfg.dns.servers[1].skipFallback, true)
  t.eq(cfg.dns.servers[2].address, "223.5.5.5")
  t.eq(cfg.dns.servers[2].domains[1], "geosite:cn")
  t.eq(cfg.dns.servers[2].skipFallback, true)
  t.eq(cfg.dns.servers[3].address, "localhost")
  t.eq(cfg.dns.servers[3].domains[1], "geosite:private")
  t.eq(cfg.dns.servers[3].skipFallback, true)
  t.eq(cfg.dns.servers[4].tag, nil)
  t.eq(cfg.dns.servers[4].address, "https://1.1.1.1/dns-query")
  t.eq(cfg.dns.servers[4].domains, nil)
  t.eq(cfg.dns.servers[4].skipFallback, false)

  t.eq(cfg.routing.rules[1].type, "field")
  assert_array_equal(cfg.routing.rules[1].inboundTag, { "dns-in" })
  t.eq(cfg.routing.rules[1].outboundTag, "proxy-selected")
end)

t.test("disables geo preset rules without removing private network protection", function()
  local cfg = assert(generator.build(global({ routing_enabled = "0" }), {
    protocol = "vless", server = "vless.invalid", port = 443,
    uuid = UUID_ONE, transport = "tcp", security = "none"
  }))
  t.eq(#cfg.routing.rules, 1)
  assert_array_equal(cfg.routing.rules[1].ip, PRIVATE_CIDRS)
  t.eq(cfg.dns, nil)
end)

t.test("returns independent deterministic routing tables", function()
  local node = {
    protocol = "vless", server = "vless.invalid", port = 443,
    uuid = UUID_ONE, transport = "tcp", security = "none"
  }
  local first = assert(generator.build(global(), node))
  first.routing.rules[1].inboundTag[1] = "mutated-by-caller"
  first.routing.rules[2].ip[1] = "mutated-by-caller"
  first.dns.servers[1].domains[1] = "mutated-by-caller"
  local second = assert(generator.build(global(), node))
  assert_array_equal(second.routing.rules[1].inboundTag, { "dns-in" })
  assert_array_equal(second.routing.rules[2].ip, PRIVATE_CIDRS)
  t.eq(second.dns.servers[1].domains[1], "geosite:geolocation-!cn")
end)

t.test("maps VLESS Reality over TCP without changing credential bytes", function()
  local public_key = REALITY_PUBLIC_KEY
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
    sni = "cover.invalid", public_key = REALITY_PUBLIC_KEY, short_id = "a1b2",
    fingerprint = "chrome"
  }, "proxy-selected"))

  t.eq(outbound.streamSettings.network, "grpc")
  t.eq(outbound.streamSettings.grpcSettings.serviceName, "reality-service")
  t.eq(outbound.streamSettings.security, "reality")
  t.eq(outbound.streamSettings.realitySettings.publicKey, REALITY_PUBLIC_KEY)
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

t.test("losslessly splices an authoritative raw outbound with a replaced tag", function()
  local raw = '{"protocol":"freedom","tag":"do-not-keep","settings":{"object":{},"array":[],"missing":null,"large":9007199254740993,"text":"__XC_RAW_OUTBOUND_1__"}}'
  local node = { protocol = "raw", raw_outbound = raw }
  local cfg = assert(generator.build(global(), node))
  t.eq(cfg.outbounds[1].tag, "proxy-selected")
  t.eq(node.raw_outbound, raw)

  -- A caller-controlled surrounding string that resembles the internal marker
  -- must survive unchanged and must not consume the raw replacement.
  cfg.note = "__XC_RAW_OUTBOUND_1__"
  local encoded = assert(generator.encode(cfg, luci_json))
  t.contains(encoded, '"array":[]')
  t.contains(encoded, '"object":{}')
  t.contains(encoded, '"missing":null')
  t.contains(encoded, '"large":9007199254740993')
  t.contains(encoded, '"tag":"proxy-selected"')
  t.contains(encoded, '"text":"__XC_RAW_OUTBOUND_1__"')
  t.contains(encoded, '"note":"__XC_RAW_OUTBOUND_1__"')
  t.eq(encoded:find("do-not-keep", 1, true), nil)
end)

t.test("rejects all untyped raw tables and keeps raw errors secret-safe", function()
  local secret = "do-not-echo-this-raw-secret"
  local value, err = generator.build_outbound({
    protocol = "raw", raw_outbound = '{"password":"' .. secret .. '"'
  }, "proxy-selected")
  t.eq(value, nil)
  t.contains(err, "raw outbound")
  t.eq(err:find(secret, 1, true), nil)

  for _, node in ipairs({
    { protocol = "raw", raw_outbound = { protocol = "freedom", password = secret } },
    { protocol = "raw", raw_outbound_table = { protocol = "freedom", password = secret } }
  }) do
    local table_value, table_err = generator.build_outbound(node, "proxy-selected")
    t.eq(table_value, nil)
    t.contains(table_err, "raw outbound")
    t.eq(table_err:find(secret, 1, true), nil)
  end
end)

t.test("omits empty objects before LuCI-compatible serialization", function()
  local cfg = assert(generator.build(global(), {
    protocol = "vless", server = "ws.invalid", port = 80,
    uuid = UUID_ONE, transport = "ws", security = "none"
  }))
  t.eq(cfg.inbounds[2].settings, nil)
  t.eq(cfg.outbounds[2].settings, nil)
  t.eq(cfg.outbounds[1].streamSettings.wsSettings.headers, nil)
  local encoded = assert(generator.encode(cfg, luci_json))
  t.eq(encoded:find('"settings":[]', 1, true), nil)
  t.eq(encoded:find('"headers":[]', 1, true), nil)
end)

t.test("rejects an encoder that does not emit exactly one private raw marker", function()
  local secret = "do-not-echo-encoder-secret"
  local cfg = assert(generator.build(global(), {
    protocol = "raw", raw_outbound = '{"protocol":"freedom","password":"' .. secret .. '"}'
  }))
  local encoded, err = generator.encode(cfg, { stringify = function() return "{}" end })
  t.eq(encoded, nil)
  t.truthy(err)
  t.eq(err:find(secret, 1, true), nil)
end)

t.test("rejects non-JSON table shapes before calling the adapter", function()
  local invalid_tables = {
    { [1000000000] = "sparse" },
    { [1] = "numeric", ["1"] = "string" },
    { [1] = "first", [3] = "hole" },
    { [1] = "array", named = "object" },
    { [math.huge] = "positive infinity" },
    { [-math.huge] = "negative infinity" },
    { [1.5] = "fractional" },
    { [0] = "zero" },
    { [-1] = "negative" },
    { [100000000000000000000] = "huge" }
  }
  for _, value in ipairs(invalid_tables) do
    local calls = 0
    local encoded, err = generator.encode(value, {
      stringify = function()
        calls = calls + 1
        return "{}"
      end
    })
    t.eq(encoded, nil)
    t.contains(err, "input")
    t.eq(calls, 0)
  end
end)

t.test("emits representative configs accepted by Xray when available", function()
  local xray = os.getenv("XRAY_BIN")
  if not xray or xray == "" then
    if os.execute("command -v xray >/dev/null 2>&1") ~= 0 then return end
    xray = "xray"
  end
  local cases = {
    { config = assert(generator.build(global({ listen_address = "127.0.0.1" }), {
      protocol = "vless", server = "reality.invalid", port = 443,
      uuid = UUID_ONE, encryption = "none", flow = "xtls-rprx-vision",
      transport = "tcp", security = "reality", sni = "cover.invalid",
      public_key = REALITY_PUBLIC_KEY, short_id = "a1b2", fingerprint = "chrome"
    })), accepted = true },
    { config = assert(generator.build(global({ listen_address = "127.0.0.1", routing_enabled = "0" }), {
      protocol = "vless", server = "reality.invalid", port = 443,
      uuid = UUID_ONE, encryption = "none", flow = "xtls-rprx-vision",
      transport = "tcp", security = "reality", sni = "cover.invalid",
      public_key = REALITY_PUBLIC_KEY, short_id = "a1b2", fingerprint = "chrome"
    })), accepted = true },
    { config = assert(generator.build(global({ listen_address = "127.0.0.1", routing_enabled = "0" }), {
      protocol = "vless", server = "reality.invalid", port = 443,
      uuid = UUID_ONE, encryption = "none", flow = "xtls-rprx-vision-udp443",
      transport = "tcp", security = "reality", sni = "cover.invalid",
      public_key = REALITY_PUBLIC_KEY, short_id = "a1b2", fingerprint = "chrome"
    })), accepted = true },
    { config = assert(generator.build(global({ listen_address = "127.0.0.1", routing_enabled = "0" }), {
      protocol = "raw", raw_outbound = '{"protocol":"freedom","tag":"old","settings":{"domainStrategy":"UseIP"}}'
    })), accepted = true }
  }
  local invalid_flow = assert(generator.build(global({ listen_address = "127.0.0.1", routing_enabled = "0" }), {
    protocol = "vless", server = "reality.invalid", port = 443,
    uuid = UUID_ONE, encryption = "none", flow = "xtls-rprx-vision",
    transport = "tcp", security = "reality", sni = "cover.invalid",
    public_key = REALITY_PUBLIC_KEY, short_id = "a1b2", fingerprint = "chrome"
  }))
  invalid_flow.outbounds[1].settings.vnext[1].users[1].flow = "invalid-flow"
  cases[#cases + 1] = { config = invalid_flow, accepted = false }

  for index, case in ipairs(cases) do
    local encoded = assert(generator.encode(case.config, luci_json))
    local path = "tests/tmp/generator-xray-" .. index .. ".json"
    local handle = assert(io.open(path, "wb"))
    assert(handle:write(encoded))
    handle:close()
    local status = os.execute("'" .. xray:gsub("'", "'\\''") .. "' run -test -c " .. path .. " >/dev/null 2>&1")
    os.remove(path)
    if case.accepted then t.eq(status, 0) else t.truthy(status ~= 0) end
  end
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

t.test("accepts only syntactically valid IPv4 and IPv6 listen addresses", function()
  local node = { protocol = "socks", server = "127.0.0.1", port = 1080 }
  for _, address in ipairs({
    "0.0.0.0", "192.168.6.1", "::", "::1", "2001:db8::1",
    "2001:0db8:0000:0000:0000:ff00:0042:8329", "::ffff:192.0.2.1"
  }) do
    t.truthy(generator.build(global({ listen_address = address }), node))
  end
  for _, address in ipairs({
    "256.0.0.1", "01.2.3.4", "1:2:3", "1::2::3", "2001:db8:::1",
    "2001:db8:0:0:0:0:0:0:1", "[::1]", "gggg::1", "host.invalid"
  }) do
    local value, err = generator.build(global({ listen_address = address }), node)
    t.eq(value, nil)
    t.contains(err, "listen")
  end
end)

t.test("validates Reality public keys short IDs and fingerprints", function()
  local function reality(fields)
    local node = {
      protocol = "vless", server = "reality.invalid", port = 443,
      uuid = UUID_ONE, encryption = "none", transport = "tcp", security = "reality",
      sni = "cover.invalid", public_key = REALITY_PUBLIC_KEY,
      short_id = "a1b2", fingerprint = "chrome"
    }
    for key, value in pairs(fields) do node[key] = value end
    return node
  end
  for _, fields in ipairs({
    { public_key = string.rep("A", 42) },
    { public_key = string.rep("A", 42) .. "+" },
    { public_key = string.rep("A", 44) },
    { short_id = "abc" },
    { short_id = "zz" },
    { short_id = "001122334455667788" },
    { fingerprint = "unsafe" }
  }) do
    local value, err = generator.build_outbound(reality(fields), "proxy-selected")
    t.eq(value, nil)
    t.truthy(err)
    t.eq(err:find(fields.public_key or fields.short_id or fields.fingerprint, 1, true), nil)
  end
end)

t.test("uses only Xray 24 and 26 common structured allowlists", function()
  for _, flow in ipairs({ "", "xtls-rprx-vision", "xtls-rprx-vision-udp443" }) do
    t.truthy(generator.build_outbound({
      protocol = "vless", server = "vless.invalid", port = 443, uuid = UUID_ONE,
      encryption = "none", flow = flow, transport = "tcp", security = "tls",
      sni = "vless.invalid"
    }, "proxy-selected"))
  end
  t.truthy(generator.build_outbound({
    protocol = "vless", server = "vless.invalid", port = 443, uuid = UUID_ONE,
    encryption = "none", transport = "tcp", security = "tls", sni = "vless.invalid"
  }, "proxy-selected"))

  for _, method in ipairs({ "aes-128-gcm", "aes-256-gcm", "chacha20-poly1305", "xchacha20-poly1305" }) do
    t.truthy(generator.build_outbound({
      protocol = "shadowsocks", server = "ss.invalid", port = 8388,
      method = method, password = "secret", transport = "tcp", security = "none"
    }, "proxy-selected"))
  end
  for _, security in ipairs({ "auto", "aes-128-gcm", "chacha20-poly1305" }) do
    t.truthy(generator.build_outbound({
      protocol = "vmess", server = "vmess.invalid", port = 443, uuid = UUID_ONE,
      encryption = security, transport = "tcp", security = "none"
    }, "proxy-selected"))
  end
  for _, fingerprint in ipairs({ "chrome", "firefox", "safari", "ios", "android", "edge", "360", "qq", "random", "randomized" }) do
    t.truthy(generator.build_outbound({
      protocol = "vless", server = "tls.invalid", port = 443, uuid = UUID_ONE,
      encryption = "none", transport = "tcp", security = "tls",
      sni = "tls.invalid", fingerprint = fingerprint
    }, "proxy-selected"))
  end

  local unsupported = {
    {
      protocol = "vless", server = "vless.invalid", port = 443, uuid = UUID_ONE,
      encryption = "none", flow = "xtls-rprx-direct", transport = "tcp",
      security = "tls", sni = "vless.invalid"
    },
    {
      protocol = "vless", server = "vless.invalid", port = 443, uuid = UUID_ONE,
      encryption = "none", flow = "invalid-flow", transport = "tcp",
      security = "tls", sni = "vless.invalid"
    },
    {
      protocol = "vless", server = "vless.invalid", port = 443, uuid = UUID_ONE,
      encryption = "auto", transport = "tcp", security = "none"
    },
    {
      protocol = "vmess", server = "vmess.invalid", port = 443, uuid = UUID_ONE,
      encryption = "none", transport = "tcp", security = "none"
    },
    {
      protocol = "shadowsocks", server = "ss.invalid", port = 8388,
      method = "none", password = "secret", transport = "tcp", security = "none"
    },
    {
      protocol = "trojan", server = "trojan.invalid", port = 443,
      password = "secret", flow = "xtls-rprx-vision",
      transport = "tcp", security = "tls", sni = "trojan.invalid"
    }
  }
  for _, node in ipairs(unsupported) do
    local value, err = generator.build_outbound(node, "proxy-selected")
    t.eq(value, nil)
    t.contains(err, "protocol=raw")
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

t.test("routes only proxy targets through an explicit balancer", function()
  local legacy = routing.build(global())
  local dynamic = routing.build(global(), { balancerTag = "xc-balancer" })
  t.eq(legacy[1].outboundTag, "proxy-selected")
  t.eq(dynamic[1].balancerTag, "xc-balancer")
  t.eq(dynamic[1].outboundTag, nil)

  local expected = {
    [2] = "direct", [3] = "block", [4] = "direct", [5] = "direct",
    [6] = "direct", [9] = "direct", [10] = "direct"
  }
  for index, rule in ipairs(dynamic) do
    if index == 1 or index == 7 or index == 8 or index == 11 then
      t.eq(rule.balancerTag, "xc-balancer")
      t.eq(rule.outboundTag, nil)
    else
      t.eq(rule.outboundTag, expected[index])
      t.eq(rule.balancerTag, nil)
    end
  end
end)

t.test("derives node tags only from safe section IDs", function()
  t.eq(generator.node_tag("node_1"), "xc-node-node_1")
  for _, section_id in ipairs({ "", "bad-id", "bad/id", "bad id", "bad..id" }) do
    t.eq(generator.node_tag(section_id), nil)
  end
  t.eq(generator.node_tag(nil), nil)
end)

t.test("builds a dynamic balancer configuration with loopback Xray API", function()
  local function dynamic_node(id)
    return {
      id = id, enabled = true, protocol = "vless", server = id .. ".invalid", port = 443,
      uuid = UUID_ONE, encryption = "none", transport = "tcp", security = "none"
    }
  end

  local cfg = assert(generator.build_dynamic(global(), { dynamic_node("old"), dynamic_node("new") }))
  t.eq(cfg.api.tag, "xc-api")
  t.eq(#cfg.api.services, 1)
  t.eq(cfg.api.services[1], "RoutingService")
  t.eq(#cfg.balancers, 1)
  t.eq(cfg.balancers[1].tag, "xc-balancer")
  assert_array_equal(cfg.balancers[1].selector, { "xc-node-old", "xc-node-new" })

  t.eq(#cfg.inbounds, 3)
  t.eq(cfg.inbounds[3].tag, "xc-api")
  t.eq(cfg.inbounds[3].listen, "127.0.0.1")
  t.eq(cfg.inbounds[3].port, 10085)
  t.eq(cfg.inbounds[3].protocol, "dokodemo-door")
  t.eq(cfg.inbounds[3].settings.address, "127.0.0.1")

  t.eq(cfg.outbounds[1].tag, "xc-node-old")
  t.eq(cfg.outbounds[2].tag, "xc-node-new")
  t.eq(cfg.outbounds[3].tag, "direct")
  t.eq(cfg.outbounds[4].tag, "block")
  t.eq(cfg.outbounds[5].tag, "xc-api-out")
  t.eq(cfg.outbounds[5].protocol, "freedom")
  local api_rule
  for _, rule in ipairs(cfg.routing.rules) do
    if rule.inboundTag and rule.inboundTag[1] == "xc-api" then api_rule = rule end
  end
  t.truthy(api_rule)
  t.eq(api_rule.outboundTag, "xc-api-out")
  for _, rule in ipairs(cfg.routing.rules) do
    t.eq(rule.outboundTag == "proxy-selected", false)
  end
end)

t.test("rejects empty, invalid, disabled, and duplicate dynamic nodes", function()
  local function dynamic_node(id, enabled)
    return {
      id = id, enabled = enabled, protocol = "vless", server = id .. ".invalid", port = 443,
      uuid = UUID_ONE, encryption = "none", transport = "tcp", security = "none"
    }
  end
  local cases = {
    {},
    { dynamic_node("disabled", false) },
    { dynamic_node("bad-id", true) },
    { dynamic_node("duplicate", true), dynamic_node("duplicate", true) }
  }
  for _, nodes in ipairs(cases) do
    local cfg, err = generator.build_dynamic(global(), nodes)
    t.eq(cfg, nil)
    t.truthy(err)
  end
  local cfg, err = generator.build_dynamic(global(), nil)
  t.eq(cfg, nil)
  t.truthy(err)
end)

return true
