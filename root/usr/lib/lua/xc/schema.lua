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
local JSON_MAX_DEPTH = 32
local JSON_MAX_LENGTH = 524288
local JSON_MAX_UNITS = 8192
local canonical_json
local canonical_raw_cache = setmetatable({}, { __mode = "k" })

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
    local canonical = canonical_json(output.raw_outbound)
    if not canonical then return invalid("raw_outbound") end
    canonical_raw_cache[output] = { source = output.raw_outbound, value = canonical }
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

local function decimal_magnitude(value)
  local first = value:find("[^0]")
  return first and value:sub(first) or "0"
end

local function compare_decimal_magnitudes(left, right)
  if #left ~= #right then return #left < #right and -1 or 1 end
  if left == right then return 0 end
  return left < right and -1 or 1
end

local function add_decimal_magnitudes(left, right)
  local output, carry, left_index, right_index = {}, 0, #left, #right
  while left_index > 0 or right_index > 0 or carry > 0 do
    local digit = carry
    if left_index > 0 then digit = digit + left:byte(left_index) - 48; left_index = left_index - 1 end
    if right_index > 0 then digit = digit + right:byte(right_index) - 48; right_index = right_index - 1 end
    output[#output + 1] = string.char(48 + digit % 10)
    carry = math.floor(digit / 10)
  end
  for index = 1, math.floor(#output / 2) do
    output[index], output[#output - index + 1] = output[#output - index + 1], output[index]
  end
  return table.concat(output)
end

local function subtract_decimal_magnitudes(left, right)
  local output, borrow, left_index, right_index = {}, 0, #left, #right
  while left_index > 0 do
    local digit = left:byte(left_index) - 48 - borrow
    if right_index > 0 then digit = digit - (right:byte(right_index) - 48); right_index = right_index - 1 end
    if digit < 0 then digit = digit + 10; borrow = 1 else borrow = 0 end
    output[#output + 1] = string.char(48 + digit)
    left_index = left_index - 1
  end
  while #output > 1 and output[#output] == "0" do output[#output] = nil end
  for index = 1, math.floor(#output / 2) do
    output[index], output[#output - index + 1] = output[#output - index + 1], output[index]
  end
  return table.concat(output)
end

local function add_signed_decimal(sign, magnitude, offset)
  if offset == 0 then return sign, magnitude end
  local offset_sign = offset < 0 and -1 or 1
  local offset_magnitude = tostring(math.abs(offset))
  if sign == 0 then return offset_sign, offset_magnitude end
  if sign == offset_sign then return sign, add_decimal_magnitudes(magnitude, offset_magnitude) end
  local comparison = compare_decimal_magnitudes(magnitude, offset_magnitude)
  if comparison == 0 then return 0, "0" end
  if comparison > 0 then return sign, subtract_decimal_magnitudes(magnitude, offset_magnitude) end
  return offset_sign, subtract_decimal_magnitudes(offset_magnitude, magnitude)
end

canonical_json = function(source, top_level_tag)
  if #source > JSON_MAX_LENGTH then return nil end
  local position, length, units = 1, #source, 0
  local function consume_unit()
    units = units + 1
    return units <= JSON_MAX_UNITS
  end
  local function whitespace()
    while position <= length do
      local byte = source:byte(position)
      if byte ~= 32 and byte ~= 9 and byte ~= 10 and byte ~= 13 then return end
      position = position + 1
    end
  end
  local parse_value
  local function utf8_end(index)
    local first = source:byte(index)
    local second, third, fourth = source:byte(index + 1), source:byte(index + 2), source:byte(index + 3)
    local function continuation(value) return value and value >= 128 and value <= 191 end
    if first >= 194 and first <= 223 and continuation(second) then return index + 2 end
    if first == 224 and second and second >= 160 and second <= 191 and continuation(third) then return index + 3 end
    if ((first >= 225 and first <= 236) or (first >= 238 and first <= 239)) and continuation(second) and continuation(third) then return index + 3 end
    if first == 237 and second and second >= 128 and second <= 159 and continuation(third) then return index + 3 end
    if first == 240 and second and second >= 144 and second <= 191 and continuation(third) and continuation(fourth) then return index + 4 end
    if first >= 241 and first <= 243 and continuation(second) and continuation(third) and continuation(fourth) then return index + 4 end
    if first == 244 and second and second >= 128 and second <= 143 and continuation(third) and continuation(fourth) then return index + 4 end
  end
  local string_escapes = { ['"'] = '"', ['\\'] = '\\', ['/'] = '/', b = '\b', f = '\f', n = '\n', r = '\r', t = '\t' }
  local function parse_string()
    position = position + 1
    local output = {}
    local chunk_start = position
    while position <= length do
      local byte = source:byte(position)
      if byte == 34 then
        if position > chunk_start then output[#output + 1] = source:sub(chunk_start, position - 1) end
        position = position + 1
        return table.concat(output)
      end
      if byte == 92 then
        if position > chunk_start then output[#output + 1] = source:sub(chunk_start, position - 1) end
        position = position + 1
        local escape = source:sub(position, position)
        if string_escapes[escape] then
          output[#output + 1] = string_escapes[escape]
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
        chunk_start = position
      elseif byte < 32 then
        return nil
      else
        if byte >= 128 then
          local next_position = utf8_end(position)
          if not next_position then return nil end
          position = next_position
        else
          position = position + 1
        end
      end
    end
  end
  local function parse_number()
    local negative = false
    if source:sub(position, position) == "-" then negative = true; position = position + 1 end
    local integer_start = position
    local first = source:byte(position)
    if first == 48 then
      position = position + 1
      if source:byte(position) and source:byte(position) >= 48 and source:byte(position) <= 57 then return nil end
    elseif first and first >= 49 and first <= 57 then
      repeat position = position + 1; first = source:byte(position) until not first or first < 48 or first > 57
    else
      return nil
    end
    local integer_end = position - 1
    local fraction_start, fraction_end
    if source:sub(position, position) == "." then
      position = position + 1
      fraction_start = position
      local digit = source:byte(position)
      if not digit or digit < 48 or digit > 57 then return nil end
      repeat position = position + 1; digit = source:byte(position) until not digit or digit < 48 or digit > 57
      fraction_end = position - 1
    end
    local exponent_sign, exponent_magnitude = 0, "0"
    local exponent = source:sub(position, position)
    if exponent == "e" or exponent == "E" then
      position = position + 1
      local sign = source:sub(position, position)
      if sign == "+" or sign == "-" then
        exponent_sign = sign == "-" and -1 or 1
        position = position + 1
      else
        exponent_sign = 1
      end
      local exponent_start = position
      local digit = source:byte(position)
      if not digit or digit < 48 or digit > 57 then return nil end
      repeat position = position + 1; digit = source:byte(position) until not digit or digit < 48 or digit > 57
      exponent_magnitude = decimal_magnitude(source:sub(exponent_start, position - 1))
      if exponent_magnitude == "0" then exponent_sign = 0 end
    end
    local coefficient = source:sub(integer_start, integer_end)
    local fraction_length = 0
    if fraction_start then
      coefficient = coefficient .. source:sub(fraction_start, fraction_end)
      fraction_length = fraction_end - fraction_start + 1
    end
    coefficient = decimal_magnitude(coefficient)
    if coefficient == "0" then return { kind = "number", value = "0" } end
    local trailing_zeros = 0
    while coefficient:byte(#coefficient - trailing_zeros) == 48 do trailing_zeros = trailing_zeros + 1 end
    if trailing_zeros > 0 then coefficient = coefficient:sub(1, #coefficient - trailing_zeros) end
    exponent_sign, exponent_magnitude = add_signed_decimal(exponent_sign, exponent_magnitude, trailing_zeros - fraction_length)
    local value = (negative and "-" or "") .. coefficient
    if exponent_sign ~= 0 then value = value .. "e" .. (exponent_sign < 0 and "-" or "") .. exponent_magnitude end
    return { kind = "number", value = value }
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
      if not consume_unit() then return nil end
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
    if not consume_unit() then return nil end
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
  if not value or value.kind ~= "object" or position <= length then return nil end
  if top_level_tag ~= nil then
    local protocol = value.values.protocol
    if not protocol
      or protocol.kind ~= "string"
      or protocol.value == ""
      or #protocol.value > 128
      or has_controls(protocol.value)
      or not protocol.value:match("^[A-Za-z0-9_.-]+$") then
      return nil
    end
    if value.values.tag == nil then
      if units + 2 > JSON_MAX_UNITS then return nil end
      value.keys[#value.keys + 1] = "tag"
    end
    value.values.tag = { kind = "string", value = top_level_tag }
  end
  local quote_escapes = { ['\\'] = '\\\\', ['"'] = '\\"', ['\b'] = '\\b', ['\f'] = '\\f', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }
  local function quote(value)
    return '"' .. value:gsub('[%z\1-\31\\"]', function(character)
      return quote_escapes[character] or string.format("\\u%04x", character:byte())
    end) .. '"'
  end
  local function encode(item, depth)
    if item.kind == "string" then return quote(item.value) end
    if item.kind == "number" then return item.value end
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

function M.raw_outbound_with_tag(source, tag)
  local checked_source, source_err = checked_string(source, "raw_outbound", true)
  local checked_tag, tag_err = checked_string(tag, "tag", true)
  if source_err or tag_err or #checked_tag > 128 then return invalid("raw_outbound") end
  local canonical = canonical_json(checked_source, checked_tag)
  if not canonical or #canonical > JSON_MAX_LENGTH then return invalid("raw_outbound") end
  return canonical
end

local function identity_parts(node)
  node = node or {}
  local protocol = type(node.protocol) == "string" and node.protocol:lower() or node.protocol
  local parts = {
    protocol,
    type(node.server) == "string" and node.server:lower() or node.server,
    node.port
  }
  if protocol == "vless" or protocol == "vmess" then
    parts[#parts + 1] = type(node.uuid) == "string" and node.uuid:lower() or node.uuid
  elseif protocol == "trojan" then
    parts[#parts + 1] = node.password
  elseif protocol == "shadowsocks" then
    parts[#parts + 1] = type(node.method) == "string" and node.method:lower() or node.method
    parts[#parts + 1] = node.password
  elseif protocol == "socks" then
    parts[#parts + 1] = node.user
  elseif protocol == "raw" then
    local cached = canonical_raw_cache[node]
    local canonical
    if cached and cached.source == node.raw_outbound then
      canonical = cached.value
    else
      canonical = canonical_json(node.raw_outbound or "")
      if canonical then
        canonical_raw_cache[node] = { source = node.raw_outbound, value = canonical }
      end
    end
    if not canonical then return nil end
    parts[#parts + 1] = canonical
  end
  for index, value in ipairs(parts) do parts[index] = value == nil and "" or tostring(value) end
  return parts
end

function M.identity_equal(left, right)
  local left_parts, right_parts = identity_parts(left), identity_parts(right)
  if not left_parts or not right_parts or #left_parts ~= #right_parts then return false end
  for index, value in ipairs(left_parts) do
    if value ~= right_parts[index] then return false end
  end
  return true
end

function M.fingerprint(node)
  local parts = identity_parts(node) or { "invalid" }
  local hashes = { 0, 104729, 130363, 169087 }
  local multipliers = { 131, 137, 149, 157 }
  local function hash_bytes(value)
    for position = 1, #value do
      local byte = value:byte(position)
      for index = 1, #hashes do
        hashes[index] = (hashes[index] * multipliers[index] + byte) % 2147483647
      end
    end
  end
  local function hash_piece(value)
    hash_bytes(tostring(#value))
    hash_bytes(":")
    hash_bytes(value)
  end
  for _, value in ipairs(parts) do hash_piece(value) end
  local output = {}
  for index, hash in ipairs(hashes) do output[index] = string.format("%08x", hash) end
  return table.concat(output)
end

return M
