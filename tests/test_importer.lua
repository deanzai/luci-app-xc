local t = require "testlib"
local schema = require "xc.schema"
local importer = require "xc.importer"

local UUID_ONE = "11111111-1111-1111-1111-111111111111"
local UUID_TWO = "22222222-2222-2222-2222-222222222222"
local VMESS_JSON = '{"v":"2","ps":"Synthetic VMess","add":"vmess.invalid","port":"443","id":"' .. UUID_TWO .. '","aid":"0","scy":"auto","net":"ws","type":"none","host":"cdn.invalid","path":"/socket","tls":"tls","sni":"vmess.invalid","fp":"firefox"}'
local VMESS_BASE64 = "eyJ2IjoiMiIsInBzIjoiU3ludGhldGljIFZNZXNzIiwiYWRkIjoidm1lc3MuaW52YWxpZCIsInBvcnQiOiI0NDMiLCJpZCI6IjIyMjIyMjIyLTIyMjItMjIyMi0yMjIyLTIyMjIyMjIyMjIyMiIsImFpZCI6IjAiLCJzY3kiOiJhdXRvIiwibmV0Ijoid3MiLCJ0eXBlIjoibm9uZSIsImhvc3QiOiJjZG4uaW52YWxpZCIsInBhdGgiOiIvc29ja2V0IiwidGxzIjoidGxzIiwic25pIjoidm1lc3MuaW52YWxpZCIsImZwIjoiZmlyZWZveCJ9"
local RAW_JSON = '{"protocol":"freedom","tag":"synthetic-raw","settings":{"domainStrategy":"UseIP"}}'
local LOSSLESS_RAW_JSON = '{"protocol":"freedom","settings":{"items":[],"missing":null,"large":9007199254740993}}'
local EQUIVALENT_LOSSLESS_RAW_JSON = '{ "settings" : { "large" : 9007199254740993, "missing" : null, "items" : [] }, "protocol" : "freedom" }'

local legacy_table = {
  reality_uk_id = "legacy_reality",
  nodes = {
    legacy_reality = {
      name = "Synthetic Reality", protocol = "vless", address = "reality.invalid",
      port = 443, uuid = UUID_ONE, security = "reality", serverName = "cover.invalid",
      publicKey = "synthetic-public-key", shortId = "a1b2c3d4", fingerprint = "chrome",
      flow = "xtls-rprx-vision", network = "tcp"
    },
    legacy_socks = {
      name = "Synthetic NaiveProxy", protocol = "socks5", address = "127.0.0.1",
      port = 1080, username = "synthetic-user", password = "synthetic-password"
    }
  }
}

local raw_table = {
  protocol = "freedom", tag = "synthetic-raw",
  settings = { domainStrategy = "UseIP" }
}

local function read_file(path)
  local handle = assert(io.open(path, "rb"))
  local value = assert(handle:read("*a"))
  handle:close()
  return value
end

local legacy_json = read_file("tests/fixtures/legacy-nodes.json")

local json_adapter = {
  parse = function(text)
    if text == VMESS_JSON then return {
      v = "2", ps = "Synthetic VMess", add = "vmess.invalid", port = "443",
      id = UUID_TWO, aid = "0", scy = "auto", net = "ws", type = "none",
      host = "cdn.invalid", path = "/socket", tls = "tls",
      sni = "vmess.invalid", fp = "firefox"
    } end
    if text == legacy_json then return legacy_table end
    if text == RAW_JSON then return raw_table end
    if text == LOSSLESS_RAW_JSON or text == EQUIVALENT_LOSSLESS_RAW_JSON then
      return { protocol = "freedom", settings = { items = {}, large = 9007199254740993 } }
    end
    return nil, "synthetic JSON parse failure"
  end
}

local function assert_safe_unique_ids(nodes)
  local seen = {}
  for _, node in ipairs(nodes) do
    t.truthy(schema.safe_section_id(node.id), "expected a safe generated section id")
    t.truthy(not seen[node.id], "expected unique generated section ids")
    seen[node.id] = true
  end
end

t.test("maps every VLESS Reality URI field", function()
  local uri = "vless://" .. UUID_ONE .. "@reality.invalid:443?security=reality&sni=cover.invalid&pbk=synthetic%2Bpublic%2Fkey&sid=a1b2&fp=chrome&flow=xtls-rprx-vision&type=ws&host=cdn.invalid&path=%2Fedge&serviceName=ignored-for-ws#Synthetic%20Reality"
  local node = assert(importer.parse_uri(uri, json_adapter))
  t.eq(node.protocol, "vless")
  t.eq(node.uuid, UUID_ONE)
  t.eq(node.server, "reality.invalid")
  t.eq(node.port, 443)
  t.eq(node.security, "reality")
  t.eq(node.sni, "cover.invalid")
  t.eq(node.public_key, "synthetic+public/key")
  t.eq(node.short_id, "a1b2")
  t.eq(node.fingerprint, "chrome")
  t.eq(node.flow, "xtls-rprx-vision")
  t.eq(node.transport, "ws")
  t.eq(node.ws_host, "cdn.invalid")
  t.eq(node.ws_path, "/edge")
  t.eq(node.grpc_service_name, "ignored-for-ws")
  t.eq(node.name, "Synthetic Reality")
end)

t.test("maps VMess base64 JSON through the injected JSON adapter", function()
  local node = assert(importer.parse_uri("vmess://" .. VMESS_BASE64, json_adapter))
  t.eq(node.protocol, "vmess")
  t.eq(node.server, "vmess.invalid")
  t.eq(node.port, 443)
  t.eq(node.uuid, UUID_TWO)
  t.eq(node.alter_id, 0)
  t.eq(node.transport, "ws")
  t.eq(node.ws_host, "cdn.invalid")
  t.eq(node.ws_path, "/socket")
  t.eq(node.security, "tls")
  t.eq(node.sni, "vmess.invalid")
  t.eq(node.fingerprint, "firefox")
  t.eq(node.name, "Synthetic VMess")
end)

t.test("parses Trojan, SIP002 Shadowsocks, and SOCKS userinfo", function()
  local trojan = assert(importer.parse_uri("trojan://p%40ss%2Bword@trojan.invalid:443?security=tls&sni=cover.invalid&type=grpc&serviceName=svc#Synthetic%20Trojan", json_adapter))
  t.eq(trojan.password, "p@ss+word")
  t.eq(trojan.security, "tls")
  t.eq(trojan.transport, "grpc")
  t.eq(trojan.grpc_service_name, "svc")

  local ss = assert(importer.parse_uri("ss://YWVzLTI1Ni1nY206c3ludGhldGljK3Bhc3M@ss.invalid:8388#Synthetic%20SS", json_adapter))
  t.eq(ss.protocol, "shadowsocks")
  t.eq(ss.method, "aes-256-gcm")
  t.eq(ss.password, "synthetic+pass")

  local socks = assert(importer.parse_uri("socks://synthetic-user:p%40ss%2Bword@socks.invalid:1080#Synthetic%20SOCKS", json_adapter))
  t.eq(socks.protocol, "socks")
  t.eq(socks.user, "synthetic-user")
  t.eq(socks.password, "p@ss+word")

  local socks5 = assert(importer.parse_uri("socks5://user2:pass2@[2001:db8::20]:1081#IPv6", json_adapter))
  t.eq(socks5.server, "2001:db8::20")
  t.eq(socks5.port, 1081)
  t.eq(socks5.user, "user2")
end)

t.test("parses newline-separated mixed links atomically", function()
  local text = table.concat({
    "vless://" .. UUID_ONE .. "@one.invalid:443?security=reality&sni=cover.invalid&pbk=synthetic-key#One",
    "",
    "trojan://synthetic-password@two.invalid:443?security=tls&sni=two.invalid#Two",
    "socks5://user:password@three.invalid:1080#Three"
  }, "\r\n")
  local result = assert(importer.parse(text, json_adapter))
  t.eq(#result.nodes, 3)
  t.eq(#result.warnings, 0)
  assert_safe_unique_ids(result.nodes)
  local again = assert(importer.parse(text, json_adapter))
  for index, node in ipairs(result.nodes) do t.eq(node.id, again.nodes[index].id) end
end)

t.test("maps synthetic legacy VLESS Reality and NaiveProxy SOCKS5 nodes", function()
  local result = assert(importer.parse(legacy_json, json_adapter))
  t.eq(#result.nodes, 2)
  local reality, socks = result.nodes[1], result.nodes[2]
  t.eq(reality.protocol, "vless")
  t.eq(reality.public_key, "synthetic-public-key")
  t.eq(reality.short_id, "a1b2c3d4")
  t.eq(reality.sni, "cover.invalid")
  t.eq(reality.reality_uk_id, nil)
  t.eq(socks.protocol, "socks")
  t.eq(socks.user, "synthetic-user")
  t.eq(socks.password, "synthetic-password")
  t.eq(socks.reality_uk_id, nil)
  assert_safe_unique_ids(result.nodes)

  local direct = assert(importer.parse_legacy(legacy_table))
  t.eq(#direct, 2)
end)

t.test("wraps one raw Xray outbound object as a normalized raw node", function()
  local result = assert(importer.parse(RAW_JSON, json_adapter))
  t.eq(#result.nodes, 1)
  t.eq(result.nodes[1].protocol, "raw")
  t.eq(result.nodes[1].name, "synthetic-raw")
  t.contains(result.nodes[1].raw_outbound, '"protocol":"freedom"')
  t.truthy(schema.validate(result.nodes[1]))

  local direct = assert(importer.parse_outbound(raw_table))
  t.eq(direct.protocol, "raw")
end)

t.test("preserves authoritative outbound JSON bytes and exact identity", function()
  local result = assert(importer.parse(LOSSLESS_RAW_JSON, json_adapter))
  local node = result.nodes[1]
  t.eq(node.raw_outbound, LOSSLESS_RAW_JSON)
  t.contains(node.raw_outbound, '"items":[]')
  t.contains(node.raw_outbound, '"missing":null')
  t.contains(node.raw_outbound, '9007199254740993')

  local equivalent = assert(importer.parse(EQUIVALENT_LOSSLESS_RAW_JSON, json_adapter)).nodes[1]
  t.eq(schema.fingerprint(node), schema.fingerprint(equivalent))
  t.truthy(schema.identity_equal(node, equivalent))
end)

t.test("rejects ambiguous table-only raw outbound encoding", function()
  local empty_array, array_err = importer.parse_outbound({
    protocol = "freedom", settings = { items = {} }
  })
  t.eq(empty_array, nil)
  t.contains(array_err, "authoritative")

  local large_number, number_err = importer.parse_outbound({
    protocol = "freedom", settings = { large = 9007199254740992 }
  })
  t.eq(large_number, nil)
  t.contains(number_err, "authoritative")

  local fractional, fractional_err = importer.parse_outbound({
    protocol = "freedom", settings = { ratio = 0.123456789012345 }
  })
  t.eq(fractional, nil)
  t.contains(fractional_err, "authoritative")
end)

t.test("encodes an unambiguous table-only safe integer exactly", function()
  local node = assert(importer.parse_outbound({
    protocol = "freedom", settings = { exact = 9007199254740991 }
  }))
  t.contains(node.raw_outbound, '"exact":9007199254740991')
end)

t.test("keeps distinct nodes from the reproduced legacy fingerprint collision", function()
  local result = assert(importer.parse(table.concat({
    "socks://RCEHK7eT96Di:one@collision.invalid:1080#One",
    "socks://3m8Z8H7ZXstB:two@collision.invalid:1080#Two"
  }, "\n"), json_adapter))
  t.eq(#result.nodes, 2)
  t.truthy(result.nodes[1].id ~= result.nodes[2].id)
  t.truthy(not schema.identity_equal(result.nodes[1], result.nodes[2]))
end)

t.test("defaults bare Trojan links to TLS with host SNI", function()
  local node = assert(importer.parse_uri("trojan://synthetic-password@trojan-default.invalid:443#Default", json_adapter))
  t.eq(node.security, "tls")
  t.eq(node.sni, "trojan-default.invalid")

  local explicit = assert(importer.parse_uri("trojan://synthetic-password@trojan-default.invalid:443?security=none&sni=override.invalid#Explicit", json_adapter))
  t.eq(explicit.security, "none")
  t.eq(explicit.sni, "override.invalid")
end)

t.test("validates names supplied by schema defaults", function()
  local long, long_err = importer.parse_uri("socks://u:p@" .. string.rep("a", 129) .. ":1080", json_adapter)
  t.eq(long, nil)
  t.contains(long_err, "name")

  local invalid, invalid_err = importer.parse_uri("socks://u:p@" .. string.char(0xC0, 0x80) .. ":1080", json_adapter)
  t.eq(invalid, nil)
  t.contains(invalid_err, "name")
end)

t.test("rejects unknown structured query parameters", function()
  local prefix = "vless://" .. UUID_ONE .. "@bounded.invalid:443?"
  local unknown, unknown_err = importer.parse_uri(prefix .. "unknown=value", json_adapter)
  t.eq(unknown, nil)
  t.contains(unknown_err, "query")
end)

t.test("rejects oversized structured query values", function()
  local prefix = "vless://" .. UUID_ONE .. "@bounded.invalid:443?"
  local oversized, oversized_err = importer.parse_uri(prefix .. "type=ws&path=" .. string.rep("x", 2049), json_adapter)
  t.eq(oversized, nil)
  t.contains(oversized_err, "query")
end)

t.test("rejects a 52,000-parameter URI without retaining unknown keys", function()
  local prefix = "vless://" .. UUID_ONE .. "@bounded.invalid:443?"
  local parameters = {}
  for index = 1, 52000 do parameters[index] = "k" .. index .. "=x" end
  local excessive, excessive_err = importer.parse_uri(prefix .. table.concat(parameters, "&"), json_adapter)
  t.eq(excessive, nil)
  t.contains(excessive_err, "query")
end)

t.test("fails the whole mixed import when any candidate is malformed", function()
  local secret_uri = "trojan://do-not-echo-this-secret@bad.invalid:not-a-port#Bad"
  local result, err = importer.parse("socks://user:pass@good.invalid:1080#Good\n" .. secret_uri, json_adapter)
  t.eq(result, nil)
  t.truthy(err)
  t.truthy(not err:find(secret_uri, 1, true))
  t.truthy(not err:find("do-not-echo-this-secret", 1, true))
end)

t.test("deduplicates with schema fingerprints and returns warnings", function()
  local one = assert(importer.parse_uri("socks://user:one@same.invalid:1080#One", json_adapter))
  local duplicate = assert(importer.parse_uri("socks://user:two@same.invalid:1080#Different", json_adapter))
  local other = assert(importer.parse_uri("socks://other:two@same.invalid:1080#Other", json_adapter))
  local nodes, warnings = importer.deduplicate({ one, duplicate, other }, {})
  t.eq(#nodes, 2)
  t.eq(#warnings, 1)
  t.contains(warnings[1], "duplicate")

  local none, existing_warnings = importer.deduplicate({ one }, { duplicate })
  t.eq(#none, 0)
  t.eq(#existing_warnings, 1)

  local parsed = assert(importer.parse("socks://user:one@same.invalid:1080#One\nsocks://user:two@same.invalid:1080#Different", json_adapter))
  t.eq(#parsed.nodes, 1)
  t.eq(#parsed.warnings, 1)
end)

t.test("rejects malformed percent, base64, authorities, and ports safely", function()
  local sources = {
    "trojan://bad%ZZ@host.invalid:443",
    "vmess://%%%",
    "socks://user:pass@[2001:db8::1:1080",
    "socks://user:pass@host.invalid",
    "socks://user:pass@host.invalid:0",
    "socks://user:pass@host.invalid:65536",
    "socks://user:pass@2001:db8::1:1080"
  }
  for _, source in ipairs(sources) do
    local node, err = importer.parse_uri(source, json_adapter)
    t.eq(node, nil)
    t.truthy(err)
    t.truthy(not err:find(source, 1, true))
    t.truthy(not err:find("user:pass", 1, true))
  end
end)

t.test("enforces input, candidate, and UTF-8 name limits", function()
  local too_large, large_err = importer.parse(string.rep("x", 524289), json_adapter)
  t.eq(too_large, nil)
  t.contains(large_err, "large")

  local links = {}
  for index = 1, 501 do
    links[index] = "socks://u:p@node" .. index .. ".invalid:1080"
  end
  local too_many, count_err = importer.parse(table.concat(links, "\n"), json_adapter)
  t.eq(too_many, nil)
  t.contains(count_err, "many")

  local long_name, name_err = importer.parse_uri("socks://u:p@host.invalid:1080#" .. string.rep("a", 129), json_adapter)
  t.eq(long_name, nil)
  t.contains(name_err, "name")

  local bad_utf8, utf8_err = importer.parse_uri("socks://u:p@host.invalid:1080#" .. string.char(0xC0, 0x80), json_adapter)
  t.eq(bad_utf8, nil)
  t.contains(utf8_err, "name")
end)

return true
