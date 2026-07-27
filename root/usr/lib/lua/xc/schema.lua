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
  if type(value) ~= "number" or value ~= math.floor(value) or value < minimum or (maximum and value > maximum) then
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

local function copy_strings(input, output)
  for key, value in pairs(input) do
    if not known_fields[key] and type(value) == "string" then
      local checked, err = checked_string(value, tostring(key), false)
      if err then return nil, err end
      output[key] = checked
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
  local ok, err = copy_strings(input, output)
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
    local user_present = output.user ~= nil and output.user ~= ""
    local password_present = output.password ~= nil and output.password ~= ""
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
    local uuid, uuid_err = canonical_lower(input.uuid, "uuid", true)
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

function M.fingerprint(node)
  local fields = { "protocol", "server", "port", "uuid", "password", "method", "user", "security", "transport", "sni", "public_key", "short_id", "flow", "encryption", "alter_id", "raw_outbound" }
  local identity = {}
  for _, field in ipairs(fields) do identity[#identity + 1] = identity_piece(node and node[field]) end
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
