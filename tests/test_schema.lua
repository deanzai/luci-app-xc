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
  local _, port_err = schema.normalize(node({ id = "node_1", protocol = "socks", server = "127.0.0.1", port = 70000 }))
  t.contains(port_err, "port")
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
  local _, empty_user_err = schema.normalize(node({ id = "s", protocol = "socks", server = "h", port = 1, user = "" }))
  t.contains(empty_user_err, "password")
  local _, empty_password_err = schema.normalize(node({ id = "s", protocol = "socks", server = "h", port = 1, password = "" }))
  t.contains(empty_password_err, "user")
end)

t.test("validates raw nodes without server and port", function()
  local raw = assert(schema.normalize(node({ id = "r", protocol = "raw", raw_outbound = "{\"protocol\":\"freedom\"}" })))
  t.eq(raw.name, "raw")
  local _, err = schema.normalize(node({ id = "r", protocol = "raw", raw_outbound = "" }))
  t.contains(err, "raw_outbound")
  local _, server_err = schema.normalize(node({ id = "r", protocol = "raw", raw_outbound = "{}", server = "h" }))
  t.contains(server_err, "server")
  local _, port_err = schema.normalize(node({ id = "r", protocol = "raw", raw_outbound = "{}", port = 1 }))
  t.contains(port_err, "port")
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
  t.eq(value.uuid, "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")
  t.eq(value.transport, "ws")
  local _, uuid_err = schema.normalize(node({ id = "v", protocol = "vless", server = "h", port = 1, uuid = "bad" }))
  t.contains(uuid_err, "uuid")
  local _, port_err = schema.normalize(node({ id = "s", protocol = "socks", server = "h", port = "1.5" }))
  t.contains(port_err, "port")
  local _, alter_err = schema.normalize(node({ id = "m", protocol = "vmess", server = "h", port = 1, uuid = "11111111-1111-1111-1111-111111111111", alter_id = -1 }))
  t.contains(alter_err, "alter_id")
  local _, huge_err = schema.normalize(node({ id = "m", protocol = "vmess", server = "h", port = 1, uuid = "11111111-1111-1111-1111-111111111111", alter_id = math.huge }))
  t.contains(huge_err, "alter_id")
  local _, overflow_err = schema.normalize(node({ id = "m", protocol = "vmess", server = "h", port = 1, uuid = "11111111-1111-1111-1111-111111111111", alter_id = "999999999999999999999999999999999999999999999999999999999999" }))
  t.contains(overflow_err, "alter_id")
end)

t.test("does not mutate input and applies structured defaults", function()
  local input = { id = "v", protocol = "vless", server = "H", port = "1", uuid = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", password = "P@ss", public_key = "Key+Value" }
  local value = assert(schema.normalize(input))
  t.eq(input.server, "H")
  t.eq(input.port, "1")
  t.eq(value.security, "none")
  t.eq(value.transport, "tcp")
  t.eq(value.encryption, "none")
  t.eq(value.name, "h")
  t.eq(input.uuid, "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")
  t.eq(input.password, "P@ss")
  t.eq(input.public_key, "Key+Value")
  t.eq(value.uuid, "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")
  t.eq(value.password, "P@ss")
  t.eq(value.public_key, "Key+Value")
end)

t.test("retains harmless future scalar fields", function()
  local value = assert(schema.normalize(node({ id = "s", protocol = "socks", server = "h", port = 1, future_string = "value", future_number = 42, future_boolean = true, future_table = { unsafe = true } })))
  t.eq(value.future_string, "value")
  t.eq(value.future_number, 42)
  t.eq(value.future_boolean, true)
  t.eq(value.future_table, nil)
  local _, err = schema.normalize(node({ id = "s", protocol = "socks", server = "h", port = 1, future_string = "bad\nvalue" }))
  t.contains(err, "future_string")
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
  local enabled_a = assert(schema.normalize(node({ id = "ea", protocol = "socks", server = "h", port = 1, enabled = true })))
  local enabled_b = assert(schema.normalize(node({ id = "eb", protocol = "socks", server = "h", port = 1, enabled = false })))
  t.eq(schema.fingerprint(enabled_a), schema.fingerprint(enabled_b))
  local raw = assert(schema.normalize(node({ id = "r", protocol = "raw", raw_outbound = "{\"password\":\"raw-secret\"}" })))
  t.truthy(not schema.fingerprint(raw):find("raw-secret", 1, true))
  t.truthy(not schema.fingerprint(raw):find("password", 1, true))
  t.truthy(schema.safe_section_id("abc_123"))
  t.truthy(not schema.safe_section_id(""))
  t.truthy(not schema.safe_section_id("bad-id"))
end)

t.test("fingerprint uses only protocol identity and canonical raw JSON", function()
  local vless_a = assert(schema.normalize(node({ id = "v1", protocol = "vless", server = "h", port = 1, uuid = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", transport = "tcp" })))
  local vless_b = assert(schema.normalize(node({ id = "v2", protocol = "vless", server = "h", port = 1, uuid = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", transport = "ws", security = "tls", sni = "different" })))
  t.eq(schema.fingerprint(vless_a), schema.fingerprint(vless_b))
  local vmess_a = assert(schema.normalize(node({ id = "m1", protocol = "vmess", server = "h", port = 1, uuid = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", alter_id = 0 })))
  local vmess_b = assert(schema.normalize(node({ id = "m2", protocol = "vmess", server = "h", port = 1, uuid = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", alter_id = 8, transport = "grpc" })))
  t.eq(schema.fingerprint(vmess_a), schema.fingerprint(vmess_b))
  local trojan_a = assert(schema.normalize(node({ id = "t1", protocol = "trojan", server = "h", port = 1, password = "secret" })))
  local trojan_b = assert(schema.normalize(node({ id = "t2", protocol = "trojan", server = "h", port = 1, password = "secret", transport = "ws", security = "tls", sni = "different" })))
  t.eq(schema.fingerprint(trojan_a), schema.fingerprint(trojan_b))
  local ss_a = assert(schema.normalize(node({ id = "s1", protocol = "shadowsocks", server = "h", port = 1, method = "aes-128-gcm", password = "secret" })))
  local ss_b = assert(schema.normalize(node({ id = "s2", protocol = "shadowsocks", server = "h", port = 1, method = "aes-128-gcm", password = "secret", transport = "grpc" })))
  t.eq(schema.fingerprint(ss_a), schema.fingerprint(ss_b))
  local socks_a = assert(schema.normalize(node({ id = "k1", protocol = "socks", server = "h", port = 1, user = "user", password = "one" })))
  local socks_b = assert(schema.normalize(node({ id = "k2", protocol = "socks", server = "h", port = 1, user = "user", password = "two" })))
  t.eq(schema.fingerprint(socks_a), schema.fingerprint(socks_b))
  local raw_a = assert(schema.normalize(node({ id = "r1", protocol = "raw", raw_outbound = "{\"protocol\":\"freedom\",\"settings\":{\"a\":1,\"b\":true}}" })))
  local raw_b = assert(schema.normalize(node({ id = "r2", protocol = "raw", raw_outbound = "{\"settings\":{\"b\":true,\"a\":1},\"protocol\":\"freedom\"}" })))
  t.eq(schema.fingerprint(raw_a), schema.fingerprint(raw_b))
end)

t.test("bounds raw JSON nesting without exposing secrets", function()
  local function nested(depth, body)
    return string.rep("{\"layer\":", depth) .. body .. string.rep("}", depth)
  end
  local below_a = assert(schema.normalize(node({ id = "d1", protocol = "raw", raw_outbound = nested(30, "{\"a\":1,\"b\":2}") })))
  local below_b = assert(schema.normalize(node({ id = "d2", protocol = "raw", raw_outbound = nested(30, "{\"b\":2,\"a\":1}") })))
  t.eq(schema.fingerprint(below_a), schema.fingerprint(below_b))
  local _, err = schema.normalize(node({ id = "d3", protocol = "raw", raw_outbound = nested(33, "{\"secret\":\"do-not-expose\",\"a\":1}") }))
  t.contains(err, "raw_outbound")
end)

t.test("canonicalizes a bounded large numeric array", function()
  local compact, spaced = {}, {}
  for index = 1, 4096 do
    compact[#compact + 1] = tostring(index)
    spaced[#spaced + 1] = " " .. tostring(index) .. " "
  end
  local a = assert(schema.normalize(node({ id = "n1", protocol = "raw", raw_outbound = "{\"numbers\":[" .. table.concat(compact, ",") .. "]}" })))
  local b = assert(schema.normalize(node({ id = "n2", protocol = "raw", raw_outbound = "{ \"numbers\" : [" .. table.concat(spaced, ",") .. "] }" })))
  t.eq(schema.fingerprint(a), schema.fingerprint(b))
end)

t.test("canonicalizes raw JSON numbers without losing precision", function()
  local function raw_fingerprint(id, number)
    local value = assert(schema.normalize(node({
      id = id, protocol = "raw", raw_outbound = "{\"number\":" .. number .. "}"
    })))
    return schema.fingerprint(value)
  end

  local zero = raw_fingerprint("zero", "0")
  t.eq(zero, raw_fingerprint("negative_zero", "-0"))
  t.eq(zero, raw_fingerprint("exponent_zero", "0e999999"))
  t.eq(zero, raw_fingerprint("decimal_zero", "-0.000E-999999"))

  local decimal = raw_fingerprint("decimal", "1230")
  t.eq(decimal, raw_fingerprint("decimal_scale", "1.2300e3"))
  t.eq(decimal, raw_fingerprint("exponent_scale", "123000e-2"))

  local exact = raw_fingerprint("exact", "9007199254740992")
  t.eq(exact, raw_fingerprint("exact_scale", "900719925474099200e-2"))
  t.truthy(exact ~= raw_fingerprint("next_integer", "9007199254740993"))

  local huge = raw_fingerprint("huge", "1e400")
  t.eq(huge, raw_fingerprint("huge_scale", "10e399"))
  t.truthy(huge ~= raw_fingerprint("huge_distinct", "2e400"))
end)

t.test("bounds raw JSON semantic tokens and object members", function()
  local function dense_array(count)
    local values = {}
    for index = 1, count do values[index] = "0" end
    return "{\"items\":[" .. table.concat(values, ",") .. "]}"
  end

  -- Root object + its member + array + 8,189 values = 8,192 units.
  t.truthy(schema.normalize(node({ id = "tokens_ok", protocol = "raw", raw_outbound = dense_array(8189) })))
  local _, err = schema.normalize(node({ id = "tokens_over", protocol = "raw", raw_outbound = dense_array(8190) }))
  t.contains(err, "raw_outbound")
end)

t.test("accepts canonical raw JSON through the 512 KiB boundary", function()
  local function object_with_data(length, reverse)
    local data = string.rep("x", length)
    if reverse then return "{\"data\":\"" .. data .. "\",\"kind\":\"raw\"}" end
    return "{\"kind\":\"raw\",\"data\":\"" .. data .. "\"}"
  end
  local large_a = object_with_data(66000, false)
  local large_b = object_with_data(66000, true)
  local a = assert(schema.normalize(node({ id = "l1", protocol = "raw", raw_outbound = large_a })))
  local b = assert(schema.normalize(node({ id = "l2", protocol = "raw", raw_outbound = large_b })))
  t.eq(schema.fingerprint(a), schema.fingerprint(b))
  local boundary = "{\"data\":\"" .. string.rep("x", 524277) .. "\"}"
  t.eq(#boundary, 524288)
  t.truthy(schema.normalize(node({ id = "m1", protocol = "raw", raw_outbound = boundary })))
  local _, over_err = schema.normalize(node({ id = "m2", protocol = "raw", raw_outbound = boundary .. " " }))
  t.contains(over_err, "raw_outbound")
end)

t.test("rejects malformed raw JSON", function()
  local _, err = schema.normalize(node({ id = "bad", protocol = "raw", raw_outbound = "{\"unterminated\":" }))
  t.contains(err, "raw_outbound")
end)

t.test("requires raw JSON objects at the top level", function()
  for _, raw_outbound in ipairs({ "[]", "\"text\"", "1", "true", "null" }) do
    local _, err = schema.normalize(node({ id = "root", protocol = "raw", raw_outbound = raw_outbound }))
    t.contains(err, "raw_outbound")
  end
end)

t.test("validates unescaped UTF-8 in raw JSON strings", function()
  local valid = {
    string.char(0x24),
    string.char(0xC2, 0xA2),
    string.char(0xE2, 0x82, 0xAC),
    string.char(0xF0, 0x9F, 0x98, 0x80)
  }
  for index, bytes in ipairs(valid) do
    t.truthy(schema.normalize(node({ id = "utf" .. index, protocol = "raw", raw_outbound = "{\"x\":\"" .. bytes .. "\"}" })))
  end
  local invalid = {
    string.char(0x80), string.char(0xC0, 0x80), string.char(0xE0, 0x80, 0x80),
    string.char(0xED, 0xA0, 0x80), string.char(0xF0, 0x80, 0x80, 0x80),
    string.char(0xF4, 0x90, 0x80, 0x80), string.char(0xF5, 0x80, 0x80, 0x80),
    string.char(0xC2), string.char(0xE2, 0x82), string.char(0xF0, 0x90, 0x80)
  }
  for index, bytes in ipairs(invalid) do
    local _, err = schema.normalize(node({ id = "badutf" .. index, protocol = "raw", raw_outbound = "{\"x\":\"" .. bytes .. "\"}" }))
    t.contains(err, "raw_outbound")
  end
  local escaped = assert(schema.normalize(node({ id = "escape", protocol = "raw", raw_outbound = "{\"x\":\"\\uD83D\\uDE00\"}" })))
  local literal = assert(schema.normalize(node({ id = "literal", protocol = "raw", raw_outbound = "{\"x\":\"" .. string.char(0xF0, 0x9F, 0x98, 0x80) .. "\"}" })))
  t.eq(schema.fingerprint(escaped), schema.fingerprint(literal))
end)
