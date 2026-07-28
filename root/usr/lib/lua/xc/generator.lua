local M = {}

local RAW_MAX_DEPTH = 32
local RAW_MAX_MEMBERS = 8192

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

local structured_protocols = {
  vless = true,
  vmess = true,
  trojan = true,
  shadowsocks = true,
  socks = true
}

local transports = { tcp = true, ws = true, grpc = true }
local securities = { none = true, tls = true, reality = true }

local function copy_array(value)
  local output = {}
  for index, item in ipairs(value) do output[index] = item end
  return output
end

local function has_controls(value)
  return value:find("[%z\1-\31\127]") ~= nil
end

local function safe_string(value, allow_empty)
  return type(value) == "string"
    and (allow_empty or value ~= "")
    and not has_controls(value)
end

local function optional_safe_string(value)
  return value == nil or safe_string(value, true)
end

local function port_number(value)
  if type(value) == "string" then
    if not value:match("^%d+$") or #value > 5 then return nil end
    value = tonumber(value)
  end
  if type(value) ~= "number" or value ~= math.floor(value) or value < 1 or value > 65535 then
    return nil
  end
  return value
end

local function valid_ipv4(value)
  local a, b, c, d = value:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
  if not a then return false end
  for _, octet in ipairs({ a, b, c, d }) do
    if #octet > 3 or tonumber(octet) > 255 then return false end
  end
  return true
end

local function valid_listen_address(value)
  if not safe_string(value, false) or #value > 64 then return false end
  if valid_ipv4(value) then return true end
  return value:find(":", 1, true) ~= nil
    and value:match("^[%x:%.]+$") ~= nil
    and value:find(":::", 1, true) == nil
end

local function clone_raw(value, depth, state)
  local kind = type(value)
  if kind == "string" or kind == "boolean" then return value end
  if kind == "number" then
    if value ~= value or value == math.huge or value == -math.huge then return nil end
    return value
  end
  if kind ~= "table" or depth > RAW_MAX_DEPTH or getmetatable(value) ~= nil then return nil end
  if state.seen[value] then return nil end
  state.seen[value] = true

  local output = {}
  for key, item in pairs(value) do
    state.members = state.members + 1
    if state.members > RAW_MAX_MEMBERS then return nil end
    local key_kind = type(key)
    if key_kind ~= "string" and key_kind ~= "number" then return nil end
    if key_kind == "number" and (key ~= key or key == math.huge or key == -math.huge or key ~= math.floor(key) or key < 1) then
      return nil
    end
    local copy = clone_raw(item, depth + 1, state)
    if copy == nil and item ~= nil then return nil end
    output[key] = copy
  end

  state.seen[value] = nil
  return output
end

local function raw_outbound(node, tag)
  local source
  if node.raw_outbound_table ~= nil then
    source = node.raw_outbound_table
  elseif type(node.raw_outbound) == "table" then
    source = node.raw_outbound
  else
    return nil, "invalid raw outbound; decoded table required"
  end
  if type(source) ~= "table" then return nil, "invalid raw outbound; decoded table required" end

  local output = clone_raw(source, 0, { seen = {}, members = 0 })
  if not output or not safe_string(output.protocol, false) then return nil, "invalid raw outbound" end
  output.tag = tag
  return output
end

local function structured_error()
  return nil, "invalid structured node"
end

local function unsupported_error()
  return nil, "unsupported structured node; use protocol=raw"
end

local function valid_common_node(node)
  return safe_string(node.server, false)
    and not node.server:find("%s")
    and port_number(node.port) ~= nil
end

local function stream_settings(node)
  local transport = node.transport or "tcp"
  local security = node.security or "none"
  if not transports[transport] or not securities[security] then return unsupported_error() end
  if security == "reality"
    and (node.protocol ~= "vless" or (transport ~= "tcp" and transport ~= "grpc")) then
    return unsupported_error()
  end
  if node.flow ~= nil and node.flow ~= ""
    and ((node.protocol ~= "vless" and node.protocol ~= "trojan") or transport ~= "tcp") then
    return unsupported_error()
  end
  if not optional_safe_string(node.fingerprint)
    or not optional_safe_string(node.ws_host)
    or not optional_safe_string(node.ws_path)
    or not optional_safe_string(node.grpc_service_name) then
    return structured_error()
  end

  local output = { network = transport, security = security }
  if transport == "tcp" then
    output.tcpSettings = { header = { type = "none" } }
  elseif transport == "ws" then
    output.wsSettings = {
      path = node.ws_path and node.ws_path ~= "" and node.ws_path or "/",
      headers = {}
    }
    if node.ws_host and node.ws_host ~= "" then output.wsSettings.headers.Host = node.ws_host end
  else
    output.grpcSettings = { serviceName = node.grpc_service_name or "" }
  end

  if security == "tls" then
    if not safe_string(node.sni, false) then return structured_error() end
    output.tlsSettings = {
      serverName = node.sni,
      allowInsecure = false
    }
    if node.fingerprint and node.fingerprint ~= "" then output.tlsSettings.fingerprint = node.fingerprint end
  elseif security == "reality" then
    if not safe_string(node.sni, false)
      or not safe_string(node.public_key, false)
      or not optional_safe_string(node.short_id) then
      return structured_error()
    end
    output.realitySettings = {
      serverName = node.sni,
      publicKey = node.public_key
    }
    if node.short_id ~= nil then output.realitySettings.shortId = node.short_id end
    if node.fingerprint and node.fingerprint ~= "" then output.realitySettings.fingerprint = node.fingerprint end
  end
  return output
end

local function vnext_outbound(node, tag)
  if not safe_string(node.uuid, false) then return structured_error() end
  local user = { id = node.uuid }
  if node.protocol == "vless" then
    if not optional_safe_string(node.encryption) or not optional_safe_string(node.flow) then return structured_error() end
    user.encryption = node.encryption or "none"
    if node.flow and node.flow ~= "" then user.flow = node.flow end
  else
    local alter_id = node.alter_id == nil and 0 or node.alter_id
    if type(alter_id) == "string" then
      if not alter_id:match("^%d+$") then return structured_error() end
      alter_id = tonumber(alter_id)
    end
    if type(alter_id) ~= "number"
      or alter_id ~= alter_id
      or alter_id == math.huge
      or alter_id == -math.huge
      or alter_id ~= math.floor(alter_id)
      or alter_id < 0
      or alter_id > 9007199254740991 then
      return structured_error()
    end
    if not optional_safe_string(node.encryption) then return structured_error() end
    user.alterId = alter_id
    user.security = node.encryption or "auto"
  end

  local stream, err = stream_settings(node)
  if not stream then return nil, err end
  return {
    tag = tag,
    protocol = node.protocol,
    settings = {
      vnext = {
        { address = node.server, port = port_number(node.port), users = { user } }
      }
    },
    streamSettings = stream
  }
end

local function server_outbound(node, tag)
  local server = { address = node.server, port = port_number(node.port) }
  if node.protocol == "trojan" then
    if not safe_string(node.password, false) or not optional_safe_string(node.flow) then return structured_error() end
    server.password = node.password
    if node.flow and node.flow ~= "" then server.flow = node.flow end
  else
    if not safe_string(node.method, false) or not safe_string(node.password, false) then return structured_error() end
    server.method = node.method
    server.password = node.password
  end
  local stream, err = stream_settings(node)
  if not stream then return nil, err end
  return {
    tag = tag,
    protocol = node.protocol,
    settings = { servers = { server } },
    streamSettings = stream
  }
end

local function socks_outbound(node, tag)
  if node.transport ~= nil or node.security ~= nil then return unsupported_error() end
  local server = { address = node.server, port = port_number(node.port) }
  if node.user ~= nil or node.password ~= nil then
    if not safe_string(node.user, true) or not safe_string(node.password, true) then return structured_error() end
    server.users = { { user = node.user, pass = node.password } }
  end
  return {
    tag = tag,
    protocol = "socks",
    settings = { servers = { server } }
  }
end

function M.build_outbound(node, tag)
  if type(node) ~= "table" or not safe_string(tag, false) or #tag > 128 then return structured_error() end
  if node.protocol == "raw" then return raw_outbound(node, tag) end
  if not structured_protocols[node.protocol] then return unsupported_error() end
  if not valid_common_node(node) then return structured_error() end
  if node.protocol == "socks" then return socks_outbound(node, tag) end
  if node.protocol == "vless" or node.protocol == "vmess" then return vnext_outbound(node, tag) end
  return server_outbound(node, tag)
end

local function sniffing()
  return {
    enabled = true,
    routeOnly = true,
    destOverride = { "http", "tls" }
  }
end

function M.build(global, node)
  if type(global) ~= "table" or type(node) ~= "table" then return nil, "invalid generator input" end
  if not valid_listen_address(global.listen_address) then return nil, "invalid global listen address" end
  local socks_port = port_number(global.socks_port)
  local http_port = port_number(global.http_port)
  if not socks_port or not http_port or socks_port == http_port then return nil, "invalid global ports" end

  local selected, err = M.build_outbound(node, "proxy-selected")
  if not selected then return nil, err end
  return {
    inbounds = {
      {
        tag = "socks-in",
        listen = global.listen_address,
        port = socks_port,
        protocol = "socks",
        settings = { auth = "noauth", udp = true },
        sniffing = sniffing()
      },
      {
        tag = "http-in",
        listen = global.listen_address,
        port = http_port,
        protocol = "http",
        settings = {},
        sniffing = sniffing()
      }
    },
    outbounds = {
      selected,
      { tag = "direct", protocol = "freedom", settings = {} },
      { tag = "block", protocol = "blackhole", settings = { response = { type = "none" } } }
    },
    routing = {
      domainStrategy = "AsIs",
      rules = {
        { type = "field", ip = copy_array(PRIVATE_CIDRS), outboundTag = "direct" }
      }
    }
  }
end

return M
