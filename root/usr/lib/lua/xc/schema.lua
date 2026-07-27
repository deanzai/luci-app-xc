local M = {}

M.supported_protocols = {
  vless = true,
  vmess = true,
  trojan = true,
  shadowsocks = true,
  socks = true,
  raw = true
}

local structured_protocols = {
  vless = true,
  vmess = true,
  trojan = true,
  shadowsocks = true
}

local supported_transports = { tcp = true, ws = true, grpc = true }
local supported_security = { none = true, tls = true, reality = true }
local known_fields = {
  id = true, name = true, protocol = true, server = true, port = true,
  uuid = true, security = true, public_key = true, short_id = true,
  sni = true, fingerprint = true, transport = true, ws_host = true,
  ws_path = true, grpc_service_name = true, raw_outbound = true,
  enabled = true, flow = true, encryption = true, method = true,
  user = true, password = true, alter_id = true
}

local function invalid(field)
  return nil, "invalid " .. field
end

local function has_controls(value)
  return value:find("[%z\1-\31\127]") ~= nil
end

local function checked_string(value, field, required)
  if value == nil then
    if required then return invalid(field) end
    return nil
  end
  if type(value) ~= "string" or has_controls(value) then
    return invalid(field)
  end
  if required and value == "" then return invalid(field) end
  return value
end

local function integer(value, field, minimum, maximum, default)
  if value == nil then return default end
  if type(value) == "string" then
    if not value:match("^%d+$") then return invalid(field) end
    value = tonumber(value)
  end
  if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge or value > 9007199254740991 or value ~= math.floor(value) or value < minimum or (maximum and value > maximum) then
    return invalid(field)
  end
  return value
end

function M.safe_section_id(value)
  return type(value) == "string" and value:match("^[A-Za-z0-9_]+$") ~= nil
end

local function canonical_lower(value, field, required)
  local result, err = checked_string(value, field, required)
  if err then return nil, err end
  if result == nil then return nil end
  return result:lower()
end

local function copy_future_scalars(input, output)
  for key, value in pairs(input) do
    if not known_fields[key] then
      if type(value) == "string" then
        local checked, err = checked_string(value, tostring(key), false)
        if err then return nil, err end
        output[key] = checked
      elseif type(value) == "boolean" then
        output[key] = value
      elseif type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge then
        output[key] = value
      end
    end
  end
  return true
end

function M.normalize(input)
  if type(input) ~= "table" then return invalid("node") end
  local output = {}
  for key, value in pairs(input) do
    if type(value) == "string" and has_controls(value) then return invalid(tostring(key)) end
  end
  local ok, err = copy_future_scalars(input, output)
  if not ok then return nil, err end

  local id = checked_string(input.id, "section", true)
  if not id or not M.safe_section_id(id) then return invalid("section") end
  output.id = id

  local protocol, protocol_err = canonical_lower(input.protocol, "protocol", true)
  if protocol_err or not M.supported_protocols[protocol] then return invalid("protocol") end
  output.protocol = protocol

  for _, field in ipairs({ "name", "flow", "encryption", "method", "user", "password", "public_key", "short_id", "sni", "fingerprint", "ws_host", "ws_path", "grpc_service_name", "raw_outbound" }) do
    local value, value_err = checked_string(input[field], field, false)
    if value_err then return nil, value_err end
    if value ~= nil then output[field] = value end
  end
  if input.enabled ~= nil then
    if type(input.enabled) ~= "boolean" then return invalid("enabled") end
    output.enabled = input.enabled
  end

  if protocol == "raw" then
    if input.server ~= nil then return invalid("server") end
    if input.port ~= nil then return invalid("port") end
    if not output.raw_outbound or output.raw_outbound == "" then return invalid("raw_outbound") end
    if output.name == nil or output.name == "" then output.name = "raw" end
    return output
  end

  local server, server_err = canonical_lower(input.server, "server", true)
  if server_err or server:find("%s") then return invalid("server") end
  output.server = server
  local port, port_err = integer(input.port, "port", 1, 65535)
  if port_err then return nil, port_err end
  output.port = port
  if output.name == nil or output.name == "" then output.name = server end

  if protocol == "socks" then
    if input.transport ~= nil then return invalid("transport") end
    if input.security ~= nil then return invalid("security") end
    local user_present = input.user ~= nil
    local password_present = input.password ~= nil
    if user_present ~= password_present then return invalid(user_present and "password" or "user") end
    return output
  end

  local transport, transport_err = canonical_lower(input.transport or "tcp", "transport", true)
  if transport_err or not supported_transports[transport] then return invalid("transport") end
  output.transport = transport
  local security, security_err = canonical_lower(input.security or "none", "security", true)
  if security_err or not supported_security[security] then return invalid("security") end
  output.security = security
  if security == "tls" and (not output.sni or output.sni == "") then return invalid("sni") end
  if security == "reality" and (not output.sni or output.sni == "") then return invalid("sni") end
  if security == "reality" and (not output.public_key or output.public_key == "") then return invalid("public_key") end

  if protocol == "vless" or protocol == "vmess" then
    local uuid, uuid_err = checked_string(input.uuid, "uuid", true)
    if uuid_err or not uuid:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$") then return invalid("uuid") end
    output.uuid = uuid
  end
  if protocol == "vless" then
    local encryption, encryption_err = canonical_lower(input.encryption or "none", "encryption", true)
    if encryption_err then return nil, encryption_err end
    output.encryption = encryption
  elseif protocol == "vmess" then
    local alter_id, alter_err = integer(input.alter_id, "alter_id", 0, nil, 0)
    if alter_err then return nil, alter_err end
    output.alter_id = alter_id
  elseif protocol == "trojan" then
    if not output.password or output.password == "" then return invalid("password") end
  elseif protocol == "shadowsocks" then
    local method, method_err = canonical_lower(input.method, "method", true)
    if method_err then return nil, method_err end
    output.method = method
    if not output.password or output.password == "" then return invalid("password") end
  end
  return output
end

function M.validate(node)
  local value, err = M.normalize(node)
  if not value then return nil, err end
  return true
end

local function identity_piece(value)
  value = value == nil and "" or tostring(value)
  return #value .. ":" .. value
end

local function utf8_character(codepoint)
  if codepoint < 128 then return string.char(codepoint) end
  if codepoint < 2048 then
    return string.char(192 + math.floor(codepoint / 64), 128 + codepoint % 64)
  end
  if codepoint < 65536 then
    return string.char(224 + math.floor(codepoint / 4096), 128 + math.floor(codepoint / 64) % 64, 128 + codepoint % 64)
  end
  return string.char(240 + math.floor(codepoint / 262144), 128 + math.floor(codepoint / 4096) % 64, 128 + math.floor(codepoint / 64) % 64, 128 + codepoint % 64)
end

local JSON_MAX_DEPTH = 32
local JSON_MAX_LENGTH = 65536

local function canonical_json(source)
  if #source > JSON_MAX_LENGTH then return nil end
  local position, length = 1, #source
  local function whitespace()
    while position <= length and source:sub(position, position):match("%s") do position = position + 1 end
  end
  local parse_value
  local function parse_string()
    position = position + 1
    local output = {}
    while position <= length do
      local character = source:sub(position, position)
      if character == '"' then position = position + 1; return table.concat(output) end
      if character == "\\" then
        position = position + 1
        local escape = source:sub(position, position)
        local escapes = { ['"'] = '"', ['\\'] = '\\', ['/'] = '/', b = '\b', f = '\f', n = '\n', r = '\r', t = '\t' }
        if escapes[escape] then
          output[#output + 1] = escapes[escape]
          position = position + 1
        elseif escape == "u" then
          local hex = source:sub(position + 1, position + 4)
          if not hex:match("^%x%x%x%x$") then return nil end
          local codepoint = tonumber(hex, 16)
          position = position + 5
          if codepoint >= 55296 and codepoint <= 56319 then
            if source:sub(position, position + 1) ~= "\\u" then return nil end
            local low_hex = source:sub(position + 2, position + 5)
            if not low_hex:match("^%x%x%x%x$") then return nil end
            local low = tonumber(low_hex, 16)
            if low < 56320 or low > 57343 then return nil end
            codepoint = 65536 + (codepoint - 55296) * 1024 + low - 56320
            position = position + 6
          elseif codepoint >= 56320 and codepoint <= 57343 then
            return nil
          end
          output[#output + 1] = utf8_character(codepoint)
        else
          return nil
        end
      elseif character:byte() < 32 then
        return nil
      else
        output[#output + 1] = character
        position = position + 1
      end
    end
  end
  local function parse_number()
    local start = position
    if source:sub(position, position) == "-" then position = position + 1 end
    local first = source:byte(position)
    if first == 48 then
      position = position + 1
      if source:byte(position) and source:byte(position) >= 48 and source:byte(position) <= 57 then return nil end
    elseif first and first >= 49 and first <= 57 then
      repeat position = position + 1; first = source:byte(position) until not first or first < 48 or first > 57
    else
      return nil
    end
    if source:sub(position, position) == "." then
      position = position + 1
      local digit = source:byte(position)
      if not digit or digit < 48 or digit > 57 then return nil end
      repeat position = position + 1; digit = source:byte(position) until not digit or digit < 48 or digit > 57
    end
    local exponent = source:sub(position, position)
    if exponent == "e" or exponent == "E" then
      position = position + 1
      local sign = source:sub(position, position)
      if sign == "+" or sign == "-" then position = position + 1 end
      local digit = source:byte(position)
      if not digit or digit < 48 or digit > 57 then return nil end
      repeat position = position + 1; digit = source:byte(position) until not digit or digit < 48 or digit > 57
    end
    local value = source:sub(start, position - 1)
    local number = tonumber(value)
    if not number or number ~= number or number == math.huge or number == -math.huge then return nil end
    return { kind = "number", value = number }
  end
  local function parse_array(depth)
    position = position + 1; whitespace()
    local values = {}
    if source:sub(position, position) == "]" then position = position + 1; return { kind = "array", values = values } end
    while true do
      local value = parse_value(depth + 1)
      if not value then return nil end
      values[#values + 1] = value; whitespace()
      local separator = source:sub(position, position)
      if separator == "]" then position = position + 1; return { kind = "array", values = values } end
      if separator ~= "," then return nil end
      position = position + 1; whitespace()
    end
  end
  local function parse_object(depth)
    position = position + 1; whitespace()
    local values, keys, seen = {}, {}, {}
    if source:sub(position, position) == "}" then position = position + 1; return { kind = "object", values = values, keys = keys } end
    while true do
      if source:sub(position, position) ~= '"' then return nil end
      local key = parse_string(); if not key or seen[key] then return nil end
      seen[key] = true; whitespace()
      if source:sub(position, position) ~= ":" then return nil end
      position = position + 1
      local value = parse_value(depth + 1); if not value then return nil end
      values[key] = value; keys[#keys + 1] = key; whitespace()
      local separator = source:sub(position, position)
      if separator == "}" then position = position + 1; return { kind = "object", values = values, keys = keys } end
      if separator ~= "," then return nil end
      position = position + 1; whitespace()
    end
  end
  parse_value = function(depth)
    whitespace()
    local character = source:sub(position, position)
    if character == '"' then local value = parse_string(); return value and { kind = "string", value = value } end
    if character == "{" then if depth >= JSON_MAX_DEPTH then return nil end; return parse_object(depth) end
    if character == "[" then if depth >= JSON_MAX_DEPTH then return nil end; return parse_array(depth) end
    if source:sub(position, position + 3) == "true" then position = position + 4; return { kind = "boolean", value = true } end
    if source:sub(position, position + 4) == "false" then position = position + 5; return { kind = "boolean", value = false } end
    if source:sub(position, position + 3) == "null" then position = position + 4; return { kind = "null" } end
    return parse_number()
  end
  local value = parse_value(0); whitespace()
  if not value or position <= length then return nil end
  local function quote(value)
    return '"' .. value:gsub('[%z\1-\31\\"]', function(character)
      local escapes = { ['\\'] = '\\\\', ['"'] = '\\"', ['\b'] = '\\b', ['\f'] = '\\f', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }
      return escapes[character] or string.format("\\u%04x", character:byte())
    end) .. '"'
  end
  local function encode(item, depth)
    if item.kind == "string" then return quote(item.value) end
    if item.kind == "number" then return string.format("%.17g", item.value) end
    if item.kind == "boolean" then return item.value and "true" or "false" end
    if item.kind == "null" then return "null" end
    local output = {}
    if item.kind == "array" then
      if depth >= JSON_MAX_DEPTH then return nil end
      for index, child in ipairs(item.values) do
        local encoded = encode(child, depth + 1)
        if not encoded then return nil end
        output[#output + 1] = encoded
      end
      return "[" .. table.concat(output, ",") .. "]"
    end
    if depth >= JSON_MAX_DEPTH then return nil end
    table.sort(item.keys)
    for _, key in ipairs(item.keys) do
      local encoded = encode(item.values[key], depth + 1)
      if not encoded then return nil end
      output[#output + 1] = quote(key) .. ":" .. encoded
    end
    return "{" .. table.concat(output, ",") .. "}"
  end
  return encode(value, 0)
end

function M.fingerprint(node)
  node = node or {}
  local identity = { identity_piece(node.protocol), identity_piece(node.server and node.server:lower() or nil), identity_piece(node.port) }
  if node.protocol == "vless" or node.protocol == "vmess" then
    identity[#identity + 1] = identity_piece(node.uuid and node.uuid:lower() or nil)
  elseif node.protocol == "trojan" then
    identity[#identity + 1] = identity_piece(node.password)
  elseif node.protocol == "shadowsocks" then
    identity[#identity + 1] = identity_piece(node.method and node.method:lower() or nil)
    identity[#identity + 1] = identity_piece(node.password)
  elseif node.protocol == "socks" then
    identity[#identity + 1] = identity_piece(node.user)
  elseif node.protocol == "raw" then
    identity[#identity + 1] = identity_piece(canonical_json(node.raw_outbound or "") or node.raw_outbound)
  end
  local hash = 0
  for index = 1, #identity do
    local part = identity[index]
    for position = 1, #part do
      hash = (hash * 131 + part:byte(position)) % 2147483647
    end
  end
  return string.format("%08x", hash)
end

return M
