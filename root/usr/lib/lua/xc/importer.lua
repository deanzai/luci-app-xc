local schema = require "xc.schema"

local M = {}

local INPUT_MAX_BYTES = 524288
local MAX_CANDIDATES = 500
local NAME_MAX_BYTES = 128

local function trim(value)
  return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function percent_decode(value)
  local output = {}
  local position = 1
  while position <= #value do
    local character = value:sub(position, position)
    if character == "%" then
      local hex = value:sub(position + 1, position + 2)
      if not hex:match("^%x%x$") then return nil, "invalid percent encoding" end
      output[#output + 1] = string.char(tonumber(hex, 16))
      position = position + 3
    else
      output[#output + 1] = character
      position = position + 1
    end
  end
  return table.concat(output)
end

local function valid_utf8(value)
  local position = 1
  while position <= #value do
    local first = value:byte(position)
    if first <= 127 then
      position = position + 1
    else
      local second, third, fourth = value:byte(position + 1), value:byte(position + 2), value:byte(position + 3)
      local function continuation(byte) return byte and byte >= 128 and byte <= 191 end
      if first >= 194 and first <= 223 and continuation(second) then
        position = position + 2
      elseif first == 224 and second and second >= 160 and second <= 191 and continuation(third) then
        position = position + 3
      elseif ((first >= 225 and first <= 236) or (first >= 238 and first <= 239)) and continuation(second) and continuation(third) then
        position = position + 3
      elseif first == 237 and second and second >= 128 and second <= 159 and continuation(third) then
        position = position + 3
      elseif first == 240 and second and second >= 144 and second <= 191 and continuation(third) and continuation(fourth) then
        position = position + 4
      elseif first >= 241 and first <= 243 and continuation(second) and continuation(third) and continuation(fourth) then
        position = position + 4
      elseif first == 244 and second and second >= 128 and second <= 143 and continuation(third) and continuation(fourth) then
        position = position + 4
      else
        return false
      end
    end
  end
  return true
end

local function valid_name(value)
  return value == nil or (#value <= NAME_MAX_BYTES and valid_utf8(value))
end

local function base64_value(byte)
  if byte >= 65 and byte <= 90 then return byte - 65 end
  if byte >= 97 and byte <= 122 then return byte - 71 end
  if byte >= 48 and byte <= 57 then return byte + 4 end
  if byte == 43 or byte == 45 then return 62 end
  if byte == 47 or byte == 95 then return 63 end
end

local function base64_decode(value)
  if type(value) ~= "string" or value == "" or value:find("[^A-Za-z0-9%+/%-_%=]") then
    return nil, "invalid base64"
  end
  local unpadded, padding = value:match("^(.-)(=*)$")
  if not unpadded or #padding > 2 or unpadded:find("=", 1, true) then return nil, "invalid base64" end
  local remainder = #unpadded % 4
  if remainder == 1 then return nil, "invalid base64" end
  local needed_padding = remainder == 0 and 0 or 4 - remainder
  if #padding > 0 and (#value % 4 ~= 0 or #padding ~= needed_padding) then return nil, "invalid base64" end

  local output = {}
  local position = 1
  while position <= #unpadded do
    local a = base64_value(unpadded:byte(position))
    local b = base64_value(unpadded:byte(position + 1) or 0)
    local c = base64_value(unpadded:byte(position + 2) or 0)
    local d = base64_value(unpadded:byte(position + 3) or 0)
    local available = math.min(4, #unpadded - position + 1)
    if not a or not b or (available >= 3 and not c) or (available == 4 and not d) then return nil, "invalid base64" end
    if available == 2 and b % 16 ~= 0 then return nil, "invalid base64" end
    if available == 3 and c % 4 ~= 0 then return nil, "invalid base64" end
    output[#output + 1] = string.char(a * 4 + math.floor(b / 16))
    if available >= 3 then output[#output + 1] = string.char((b % 16) * 16 + math.floor(c / 4)) end
    if available == 4 then output[#output + 1] = string.char((c % 4) * 64 + d) end
    position = position + 4
  end
  return table.concat(output)
end

local function parse_query(source)
  local values = {}
  if source == nil or source == "" then return values end
  local position = 1
  while position <= #source do
    local separator = source:find("&", position, true)
    local piece = source:sub(position, separator and separator - 1 or #source)
    if piece == "" then return nil, "invalid URI query" end
    local equals = piece:find("=", 1, true)
    local raw_key = equals and piece:sub(1, equals - 1) or piece
    local raw_value = equals and piece:sub(equals + 1) or ""
    local key = percent_decode(raw_key)
    local value = percent_decode(raw_value)
    if not key or not value or key == "" or values[key] ~= nil then return nil, "invalid URI query" end
    values[key] = value
    if not separator then break end
    position = separator + 1
  end
  return values
end

local function parse_hostport(value)
  local host, port_text
  if value:sub(1, 1) == "[" then
    host, port_text = value:match("^%[([^%]]+)%]:(%d+)$")
    if not host or not host:find(":", 1, true) then return nil, "invalid URI authority" end
  else
    host, port_text = value:match("^([^:]+):(%d+)$")
    if not host or host:find(":", 1, true) then return nil, "invalid URI authority" end
  end
  host = percent_decode(host)
  if not host or host == "" or host:find("[%s/%?#@%[%]]") then return nil, "invalid URI authority" end
  local port = tonumber(port_text)
  if not port or port < 1 or port > 65535 then return nil, "invalid URI port" end
  return host, port
end

local function split_authority(value)
  local at = value:match("^.*()@")
  if not at then return nil, "invalid URI authority" end
  local userinfo, hostport = value:sub(1, at - 1), value:sub(at + 1)
  if userinfo:find("@", 1, true) or userinfo == "" then return nil, "invalid URI authority" end
  local host, port = parse_hostport(hostport)
  if not host then return nil, port end
  return userinfo, host, port
end

local function split_body(value, allow_query)
  local fragment
  local hash = value:find("#", 1, true)
  if hash then
    fragment = value:sub(hash + 1)
    value = value:sub(1, hash - 1)
    if fragment:find("#", 1, true) then return nil, nil, nil, "invalid URI fragment" end
    fragment = percent_decode(fragment)
    if not fragment or not valid_name(fragment) then return nil, nil, nil, "invalid name" end
  end
  local query
  local question = value:find("?", 1, true)
  if question then
    if not allow_query or value:sub(question + 1):find("?", 1, true) then return nil, nil, nil, "invalid URI query" end
    query = value:sub(question + 1)
    value = value:sub(1, question - 1)
  end
  return value, query, fragment
end

local function normalize_node(candidate)
  if not valid_name(candidate.name) then return nil, "invalid name" end
  candidate.id = "import_candidate"
  local normalized, err = schema.normalize(candidate)
  if not normalized then return nil, err end
  candidate.id = "node_" .. schema.fingerprint(normalized)
  normalized, err = schema.normalize(candidate)
  if not normalized then return nil, err end
  return normalized
end

local function structured_fields(node, query)
  node.security = query.security
  node.sni = query.sni
  node.public_key = query.pbk
  node.short_id = query.sid
  node.fingerprint = query.fp
  node.flow = query.flow
  node.transport = query.type or query.net
  node.ws_host = query.host
  node.ws_path = query.path
  node.grpc_service_name = query.serviceName
  node.encryption = query.encryption
end

local function parse_standard_uri(scheme, body)
  local authority, query_text, name, split_err = split_body(body, true)
  if not authority then return nil, split_err end
  if authority:find("/", 1, true) then return nil, "invalid URI authority" end
  local userinfo, host, port = split_authority(authority)
  if not userinfo then return nil, host end
  local query, query_err = parse_query(query_text)
  if not query then return nil, query_err end
  local credential, credential_err = percent_decode(userinfo)
  if not credential then return nil, credential_err end

  local node = { protocol = scheme, server = host, port = port, name = name }
  if scheme == "vless" then
    node.uuid = credential
    structured_fields(node, query)
  elseif scheme == "trojan" then
    node.password = credential
    structured_fields(node, query)
  end
  return normalize_node(node)
end

local function parse_socks_uri(body)
  local authority, query, name, split_err = split_body(body, false)
  if not authority then return nil, split_err end
  if query or authority:find("/", 1, true) then return nil, "invalid URI authority" end
  local userinfo, host, port = split_authority(authority)
  if not userinfo then return nil, host end
  local colon = userinfo:find(":", 1, true)
  if not colon then return nil, "invalid SOCKS credentials" end
  local user = percent_decode(userinfo:sub(1, colon - 1))
  local password = percent_decode(userinfo:sub(colon + 1))
  if not user or not password then return nil, "invalid percent encoding" end
  return normalize_node({
    protocol = "socks", server = host, port = port, name = name,
    user = user, password = password
  })
end

local function safe_json_parse(text, json_adapter)
  if type(json_adapter) ~= "table" or type(json_adapter.parse) ~= "function" then
    return nil, "JSON adapter required"
  end
  local ok, value = pcall(json_adapter.parse, text)
  if not ok or type(value) ~= "table" then return nil, "invalid JSON" end
  return value
end

local function parse_vmess_uri(body, json_adapter)
  local payload, query, name, split_err = split_body(body, false)
  if not payload then return nil, split_err end
  if query or payload:find("?", 1, true) then return nil, "invalid VMess URI" end
  local decoded = base64_decode(payload)
  if not decoded then return nil, "invalid VMess payload" end
  local value, json_err = safe_json_parse(decoded, json_adapter)
  if not value then return nil, json_err end
  local security = value.tls
  if security == nil or security == "" then security = "none" end
  return normalize_node({
    protocol = "vmess", name = name or value.ps, server = value.add, port = value.port,
    uuid = value.id, alter_id = value.aid, encryption = value.scy,
    transport = value.net, security = security, sni = value.sni,
    fingerprint = value.fp, ws_host = value.host, ws_path = value.path,
    grpc_service_name = value.serviceName
  })
end

local function parse_ss_uri(body)
  local authority, query, name, split_err = split_body(body, false)
  if not authority then return nil, split_err end
  if query then return nil, "invalid Shadowsocks URI" end
  local at = authority:match("^.*()@")
  local method, password, host, port
  if at then
    local encoded = percent_decode(authority:sub(1, at - 1))
    if not encoded then return nil, "invalid Shadowsocks credentials" end
    local decoded = base64_decode(encoded)
    if not decoded then return nil, "invalid Shadowsocks credentials" end
    method, password = decoded:match("^([^:]+):(.*)$")
    host, port = parse_hostport(authority:sub(at + 1))
  else
    local encoded = percent_decode(authority)
    if not encoded then return nil, "invalid Shadowsocks payload" end
    local decoded = base64_decode(encoded)
    if not decoded then return nil, "invalid Shadowsocks payload" end
    local userinfo, hostport = decoded:match("^(.*)@([^@]+)$")
    if userinfo then
      method, password = userinfo:match("^([^:]+):(.*)$")
      host, port = parse_hostport(hostport)
    end
  end
  if not method or password == nil or not host then return nil, "invalid Shadowsocks URI" end
  return normalize_node({
    protocol = "shadowsocks", name = name, server = host, port = port,
    method = method, password = password
  })
end

function M.parse_uri(uri, json_adapter)
  if type(uri) ~= "string" or uri == "" or #uri > INPUT_MAX_BYTES or uri:find("[%z\1-\32\127]") then
    return nil, "invalid share URI"
  end
  local scheme, body = uri:match("^([A-Za-z][A-Za-z0-9+%.%-]*)://(.+)$")
  if not scheme then return nil, "invalid share URI" end
  scheme = scheme:lower()
  if scheme == "vless" or scheme == "trojan" then return parse_standard_uri(scheme, body) end
  if scheme == "vmess" then return parse_vmess_uri(body, json_adapter) end
  if scheme == "ss" then return parse_ss_uri(body) end
  if scheme == "socks" or scheme == "socks5" then return parse_socks_uri(body) end
  return nil, "unsupported share URI scheme"
end

local escape_map = {
  ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = "\\b", ['\f'] = "\\f",
  ['\n'] = "\\n", ['\r'] = "\\r", ['\t'] = "\\t"
}

local function quote_json(value)
  return '"' .. value:gsub('[%z\1-\31\\"]', function(character)
    return escape_map[character] or string.format("\\u%04x", character:byte())
  end) .. '"'
end

local function encode_json(value, depth, seen)
  local kind = type(value)
  if kind == "string" then return quote_json(value) end
  if kind == "boolean" then return value and "true" or "false" end
  if kind == "number" then
    if value ~= value or value == math.huge or value == -math.huge then return nil end
    return tostring(value)
  end
  if kind ~= "table" or depth > 30 or seen[value] then return nil end
  seen[value] = true
  local count, maximum, array = 0, 0, true
  for key in pairs(value) do
    count = count + 1
    if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then array = false
    elseif key > maximum then maximum = key end
  end
  if array and count ~= maximum then array = false end
  local output = {}
  if array and count > 0 then
    for index = 1, maximum do
      local encoded = encode_json(value[index], depth + 1, seen)
      if not encoded then seen[value] = nil; return nil end
      output[#output + 1] = encoded
    end
    seen[value] = nil
    return "[" .. table.concat(output, ",") .. "]"
  end
  local keys = {}
  for key in pairs(value) do
    if type(key) ~= "string" then seen[value] = nil; return nil end
    keys[#keys + 1] = key
  end
  table.sort(keys)
  for _, key in ipairs(keys) do
    local encoded = encode_json(value[key], depth + 1, seen)
    if not encoded then seen[value] = nil; return nil end
    output[#output + 1] = quote_json(key) .. ":" .. encoded
  end
  seen[value] = nil
  return "{" .. table.concat(output, ",") .. "}"
end

function M.parse_outbound(table_value)
  if type(table_value) ~= "table" or type(table_value.protocol) ~= "string" then
    return nil, "invalid Xray outbound"
  end
  local raw = encode_json(table_value, 0, {})
  if not raw then return nil, "invalid Xray outbound" end
  return normalize_node({
    protocol = "raw", name = table_value.tag or table_value.protocol,
    raw_outbound = raw
  })
end

local function ordered_values(values)
  local keys = {}
  for key in pairs(values) do keys[#keys + 1] = key end
  table.sort(keys, function(left, right) return tostring(left) < tostring(right) end)
  local output = {}
  for _, key in ipairs(keys) do output[#output + 1] = values[key] end
  return output
end

function M.parse_legacy(table_value)
  if type(table_value) ~= "table" or type(table_value.nodes) ~= "table" then
    return nil, "invalid legacy nodes"
  end
  local source_nodes = ordered_values(table_value.nodes)
  if #source_nodes > MAX_CANDIDATES then return nil, "too many candidate nodes" end
  local nodes = {}
  for _, value in ipairs(source_nodes) do
    if type(value) ~= "table" then return nil, "invalid legacy node" end
    local protocol = type(value.protocol) == "string" and value.protocol:lower() or value.protocol
    if protocol == "socks5" or protocol == "naiveproxy" then protocol = "socks" end
    local node, err = normalize_node({
      protocol = protocol, name = value.name or value.remarks or value.ps,
      server = value.server or value.address or value.add, port = value.port,
      uuid = value.uuid, security = value.security, public_key = value.public_key or value.publicKey or value.pbk,
      short_id = value.short_id or value.shortId or value.sid, sni = value.sni or value.serverName,
      fingerprint = value.fingerprint or value.fp, flow = value.flow,
      transport = value.transport or value.network or value.net or value.type,
      ws_host = value.ws_host or value.host, ws_path = value.ws_path or value.path,
      grpc_service_name = value.grpc_service_name or value.serviceName,
      encryption = value.encryption, alter_id = value.alter_id or value.aid,
      method = value.method, user = value.user or value.username, password = value.password,
      enabled = value.enabled
    })
    if not node then return nil, err end
    nodes[#nodes + 1] = node
  end
  return nodes
end

function M.deduplicate(new_nodes, existing_nodes)
  if type(new_nodes) ~= "table" or type(existing_nodes) ~= "table" then
    return nil, "invalid node list"
  end
  local seen = {}
  for _, node in ipairs(existing_nodes) do seen[schema.fingerprint(node)] = true end
  local nodes, warnings = {}, {}
  for _, candidate in ipairs(new_nodes) do
    local node, err = normalize_node(candidate)
    if not node then return nil, err end
    local fingerprint = schema.fingerprint(node)
    if seen[fingerprint] then
      warnings[#warnings + 1] = "skipped duplicate node"
    else
      seen[fingerprint] = true
      nodes[#nodes + 1] = node
    end
  end
  return nodes, warnings
end

function M.parse(text, json_adapter)
  if type(text) ~= "string" then return nil, "invalid import input" end
  if #text > INPUT_MAX_BYTES then return nil, "import input too large" end
  if trim(text) == "" then return nil, "empty import input" end

  local nodes
  if trim(text):sub(1, 1) == "{" then
    local value, json_err = safe_json_parse(text, json_adapter)
    if not value then return nil, json_err end
    local err
    if value.nodes ~= nil or value.reality_uk_id ~= nil then
      nodes, err = M.parse_legacy(value)
    else
      local node
      node, err = M.parse_outbound(value)
      if node then nodes = { node } end
    end
    if not nodes then return nil, err end
  else
    nodes = {}
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
      line = trim(line:gsub("\r$", ""))
      if line ~= "" then
        if #nodes >= MAX_CANDIDATES then return nil, "too many candidate nodes" end
        local node, err = M.parse_uri(line, json_adapter)
        if not node then return nil, "invalid candidate " .. tostring(#nodes + 1) .. ": " .. err end
        nodes[#nodes + 1] = node
      end
    end
    if #nodes == 0 then return nil, "empty import input" end
  end
  if #nodes > MAX_CANDIDATES then return nil, "too many candidate nodes" end
  local unique, warnings = M.deduplicate(nodes, {})
  if not unique then return nil, warnings end
  return { nodes = unique, warnings = warnings }
end

return M
