local t = require "testlib"
local schema = require "xc.schema"

local function node(fields)
  return fields
end

t.test("normalizes a VLESS Reality node", function()
  local value = assert(schema.normalize(node({
    id = "node_1", name = "UK", protocol = "vless", server = "host.example",
    port = "443", uuid = "11111111-1111-1111-1111-111111111111",
    security = "reality", public_key = "pub", short_id = "ab", sni = "www.example.com"
  })))
  t.eq(value.port, 443)
  t.eq(value.protocol, "vless")
end)

t.test("rejects unsafe section ids and ports", function()
  local _, err = schema.normalize(node({ id = "node;reboot", protocol = "socks", server = "127.0.0.1", port = 70000 }))
  t.contains(err, "section")
end)

t.test("fingerprint ignores display name", function()
  local a = assert(schema.normalize(node({ id = "a", name = "A", protocol = "socks", server = "h", port = 1 })))
  local b = assert(schema.normalize(node({ id = "b", name = "B", protocol = "socks", server = "h", port = 1 })))
  t.eq(schema.fingerprint(a), schema.fingerprint(b))
end)

t.test("normalizes each credentialed protocol", function()
  t.truthy(schema.normalize(node({ id = "v", protocol = "vless", server = "h", port = 1, uuid = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA" })))
  local vmess = assert(schema.normalize(node({ id = "m", protocol = "vmess", server = "h", port = 1, uuid = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", alter_id = "2" })))
  t.eq(vmess.alter_id, 2)
  t.truthy(schema.normalize(node({ id = "t", protocol = "trojan", server = "h", port = 1, password = "secret" })))
  local ss = assert(schema.normalize(node({ id = "s", protocol = "shadowsocks", server = "h", port = 1, method = "AES-128-GCM", password = "secret" })))
  t.eq(ss.method, "aes-128-gcm")
end)

t.test("rejects missing required credentials", function()
  for _, value in ipairs({
    { id = "v", protocol = "vless", server = "h", port = 1 },
    { id = "m", protocol = "vmess", server = "h", port = 1 },
    { id = "t", protocol = "trojan", server = "h", port = 1 },
    { id = "s", protocol = "shadowsocks", server = "h", port = 1, method = "aes-128-gcm" },
    { id = "x", protocol = "shadowsocks", server = "h", port = 1, password = "secret" }
  }) do
    local _, err = schema.normalize(value)
    t.truthy(err)
  end
end)

t.test("requires SOCKS credentials to be paired", function()
  t.truthy(schema.normalize(node({ id = "s", protocol = "socks", server = "h", port = 1 })))
  t.truthy(schema.normalize(node({ id = "s", protocol = "socks", server = "h", port = 1, user = "", password = "" })))
  local _, err = schema.normalize(node({ id = "s", protocol = "socks", server = "h", port = 1, user = "u" }))
  t.contains(err, "password")
end)

t.test("validates raw nodes without server and port", function()
  local raw = assert(schema.normalize(node({ id = "r", protocol = "raw", raw_outbound = "{\\\"protocol\\\":\\\"freedom\\\"}" })))
  t.eq(raw.name, "raw")
  local _, err = schema.normalize(node({ id = "r", protocol = "raw", raw_outbound = "" }))
  t.contains(err, "raw_outbound")
end)

t.test("limits structured transports and security", function()
  for _, transport in ipairs({ "tcp", "ws", "grpc" }) do
    t.truthy(schema.normalize(node({ id = "v", protocol = "vless", server = "h", port = 1, uuid = "11111111-1111-1111-1111-111111111111", transport = transport })))
  end
  local _, transport_err = schema.normalize(node({ id = "v", protocol = "vless", server = "h", port = 1, uuid = "11111111-1111-1111-1111-111111111111", transport = "quic" }))
  t.contains(transport_err, "transport")
  local _, tls_err = schema.normalize(node({ id = "v", protocol = "vless", server = "h", port = 1, uuid = "11111111-1111-1111-1111-111111111111", security = "tls" }))
  t.contains(tls_err, "sni")
  local _, reality_err = schema.normalize(node({ id = "v", protocol = "vless", server = "h", port = 1, uuid = "11111111-1111-1111-1111-111111111111", security = "reality", sni = "h" }))
  t.contains(reality_err, "public_key")
end)

t.test("accepts server formats and rejects unsafe strings", function()
  for _, server in ipairs({ "192.0.2.1", "2001:db8::1", "[2001:db8::1]", "Example.COM" }) do
    t.truthy(schema.normalize(node({ id = "s", protocol = "socks", server = server, port = 1 })))
  end
  local _, server_err = schema.normalize(node({ id = "s", protocol = "socks", server = "bad host", port = 1 }))
  t.contains(server_err, "server")
  local _, control_err = schema.normalize(node({ id = "s", protocol = "socks", server = "h", port = 1, name = "bad\nname" }))
  t.contains(control_err, "name")
end)

t.test("rejects control characters in every string field", function()
  local _, err = schema.normalize(node({ id = "s", protocol = "socks", server = "h", port = 1, future_field = "bad\127value" }))
  t.contains(err, "future_field")
  local _, secret_err = schema.normalize(node({ id = "t", protocol = "trojan", server = "h", port = 1, password = "bad\rvalue" }))
  t.contains(secret_err, "password")
end)

t.test("normalizes safe fields and validates numeric formats", function()
  local value = assert(schema.normalize(node({ id = "Node_1", protocol = "VLESS", server = "Example.COM", port = "1", uuid = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", security = "NONE", transport = "WS", encryption = "NONE" })))
  t.eq(value.server, "example.com")
  t.eq(value.uuid, "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
  t.eq(value.transport, "ws")
  local _, uuid_err = schema.normalize(node({ id = "v", protocol = "vless", server = "h", port = 1, uuid = "bad" }))
  t.contains(uuid_err, "uuid")
  local _, port_err = schema.normalize(node({ id = "s", protocol = "socks", server = "h", port = "1.5" }))
  t.contains(port_err, "port")
  local _, alter_err = schema.normalize(node({ id = "m", protocol = "vmess", server = "h", port = 1, uuid = "11111111-1111-1111-1111-111111111111", alter_id = -1 }))
  t.contains(alter_err, "alter_id")
end)

t.test("does not mutate input and applies structured defaults", function()
  local input = { id = "v", protocol = "vless", server = "H", port = "1", uuid = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA" }
  local value = assert(schema.normalize(input))
  t.eq(input.server, "H")
  t.eq(input.port, "1")
  t.eq(value.security, "none")
  t.eq(value.transport, "tcp")
  t.eq(value.encryption, "none")
  t.eq(value.name, "h")
end)

t.test("validates tables and creates secret-free fingerprints", function()
  local a = assert(schema.normalize(node({ id = "a", protocol = "trojan", server = "H", port = 1, password = "secret", enabled = true })))
  local b = assert(schema.normalize(node({ id = "b", protocol = "trojan", server = "h", port = 2, password = "secret", enabled = false })))
  t.truthy(schema.validate(a))
  local fingerprint = schema.fingerprint(a)
  t.truthy(fingerprint:match("^[0-9a-f]+$"))
  t.truthy(fingerprint ~= schema.fingerprint(b))
  t.truthy(not fingerprint:find(a.password, 1, true))
  t.truthy(not fingerprint:find("11111111", 1, true))
  local uuid_changed = assert(schema.normalize(node({ id = "u", protocol = "vless", server = "h", port = 1, uuid = "22222222-2222-2222-2222-222222222222" })))
  local uuid_original = assert(schema.normalize(node({ id = "u", protocol = "vless", server = "h", port = 1, uuid = "11111111-1111-1111-1111-111111111111" })))
  t.truthy(schema.fingerprint(uuid_changed) ~= schema.fingerprint(uuid_original))
  local other_protocol = assert(schema.normalize(node({ id = "r", protocol = "raw", raw_outbound = "{}" })))
  local other_server = assert(schema.normalize(node({ id = "s", protocol = "socks", server = "other", port = 1 })))
  local base_socks = assert(schema.normalize(node({ id = "s", protocol = "socks", server = "h", port = 1 })))
  t.truthy(schema.fingerprint(base_socks) ~= schema.fingerprint(other_protocol))
  t.truthy(schema.fingerprint(base_socks) ~= schema.fingerprint(other_server))
  t.truthy(schema.safe_section_id("abc_123"))
  t.truthy(not schema.safe_section_id(""))
  t.truthy(not schema.safe_section_id("bad-id"))
end)
