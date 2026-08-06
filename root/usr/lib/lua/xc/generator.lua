local schema = require "xc.schema"
local routing = require "xc.routing"
local access = require "xc.access"

local M = {}
local RAW_FRAGMENT = {}
local ENCODE_MAX_DEPTH = 64
local ENCODE_MAX_MEMBERS = 16384

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
local xray_log_levels = { error = true, warning = true, info = true, debug = true }
local DYNAMIC_API_PORT = 10085
local DYNAMIC_NODE_LIMIT = 256
local fingerprints = {
  chrome = true, firefox = true, safari = true, ios = true, android = true,
  edge = true, ["360"] = true, qq = true, random = true, randomized = true
}
local vmess_securities = {
  auto = true, ["aes-128-gcm"] = true, ["chacha20-poly1305"] = true
}
local vless_flows = {
  ["xtls-rprx-vision"] = true,
  ["xtls-rprx-vision-udp443"] = true
}
local shadowsocks_methods = {
  ["aes-128-gcm"] = true,
  ["aead_aes_128_gcm"] = true,
  ["aes-256-gcm"] = true,
  ["aead_aes_256_gcm"] = true,
  ["chacha20-poly1305"] = true,
  ["aead_chacha20_poly1305"] = true,
  ["chacha20-ietf-poly1305"] = true,
  ["xchacha20-poly1305"] = true,
  ["aead_xchacha20_poly1305"] = true,
  ["xchacha20-ietf-poly1305"] = true,
  ["2022-blake3-aes-128-gcm"] = true,
  ["2022-blake3-aes-256-gcm"] = true,
  ["2022-blake3-chacha20-poly1305"] = true
}

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
    if #octet > 3 or (#octet > 1 and octet:sub(1, 1) == "0") or tonumber(octet) > 255 then return false end
  end
  return true
end

local function valid_ipv6(value)
  local compressed_at = value:find("::", 1, true)
  if compressed_at and value:find("::", compressed_at + 2, true) then return false end
  local left, right
  if compressed_at then
    left = value:sub(1, compressed_at - 1)
    right = value:sub(compressed_at + 2)
    if left:find(":", 1, true) == 1 or left:sub(-1) == ":"
      or right:find(":", 1, true) == 1 or right:sub(-1) == ":" then
      return false
    end
  else
    left, right = value, ""
  end

  local parts = {}
  local function append(side)
    if side == "" then return true end
    local start = 1
    while true do
      local separator = side:find(":", start, true)
      local part = separator and side:sub(start, separator - 1) or side:sub(start)
      if part == "" then return false end
      parts[#parts + 1] = part
      if not separator then return true end
      start = separator + 1
    end
  end
  if not append(left) or not append(right) then return false end

  local units = 0
  for index, part in ipairs(parts) do
    if part:find(".", 1, true) then
      if index ~= #parts or not valid_ipv4(part) then return false end
      units = units + 2
    else
      if #part < 1 or #part > 4 or not part:match("^%x+$") then return false end
      units = units + 1
    end
  end
  if compressed_at then return units < 8 end
  return units == 8
end

local function valid_listen_address(value)
  if not safe_string(value, false) or #value > 64 then return false end
  if valid_ipv4(value) then return true end
  return value:find(":", 1, true) ~= nil and valid_ipv6(value)
end

local function raw_outbound(node, tag)
  if type(node.raw_outbound) ~= "string" or node.raw_outbound_table ~= nil then
    return nil, "invalid raw outbound"
  end
  local fragment = schema.raw_outbound_with_tag(node.raw_outbound, tag)
  if not fragment then return nil, "invalid raw outbound" end
  return { tag = tag, [RAW_FRAGMENT] = fragment }
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
    and (node.protocol ~= "vless" or transport ~= "tcp") then
    return unsupported_error()
  end
  if not optional_safe_string(node.fingerprint)
    or not optional_safe_string(node.ws_host)
    or not optional_safe_string(node.ws_path)
    or not optional_safe_string(node.grpc_service_name) then
    return structured_error()
  end
  if node.fingerprint and node.fingerprint ~= "" and not fingerprints[node.fingerprint] then
    return unsupported_error()
  end

  local output = { network = transport, security = security }
  if transport == "tcp" then
    output.tcpSettings = { header = { type = "none" } }
  elseif transport == "ws" then
    output.wsSettings = {
      path = node.ws_path and node.ws_path ~= "" and node.ws_path or "/"
    }
    if node.ws_host and node.ws_host ~= "" then output.wsSettings.headers = { Host = node.ws_host } end
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
    if #node.public_key ~= 43 or not node.public_key:match("^[A-Za-z0-9_-]+$") then
      return structured_error()
    end
    if node.short_id ~= nil
      and (#node.short_id > 16 or #node.short_id % 2 ~= 0 or not node.short_id:match("^%x*$")) then
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
    local encryption = node.encryption or "none"
    if encryption ~= "none" then return unsupported_error() end
    if node.flow and node.flow ~= "" and not vless_flows[node.flow] then return unsupported_error() end
    user.encryption = encryption
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
    local encryption = node.encryption or "auto"
    if not vmess_securities[encryption] then return unsupported_error() end
    user.alterId = alter_id
    user.security = encryption
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
  else
    if not safe_string(node.method, false) or not safe_string(node.password, false) then return structured_error() end
    if not shadowsocks_methods[node.method] then return unsupported_error() end
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

local function collect_encode_strings(value, depth, state)
  local kind = type(value)
  if kind == "string" then
    state.bytes = state.bytes + #value
    if state.bytes > 1048576 then return false end
    state.strings[value] = true
    return true
  end
  if kind == "number" then
    return value == value and value ~= math.huge and value ~= -math.huge
  end
  if kind == "boolean" then return true end
  if kind ~= "table" or depth > ENCODE_MAX_DEPTH or getmetatable(value) ~= nil then return false end

  local fragment = rawget(value, RAW_FRAGMENT)
  if fragment ~= nil then
    if type(fragment) ~= "string" or not safe_string(rawget(value, "tag"), false) then return false end
    state.raw_count = state.raw_count + 1
    state.bytes = state.bytes + #fragment
    return state.raw_count <= 1 and state.bytes <= 1048576
  end
  if state.seen[value] then return false end
  state.seen[value] = true
  local shape, maximum, count = nil, 0, 0
  for key, item in pairs(value) do
    state.members = state.members + 1
    if state.members > ENCODE_MAX_MEMBERS then return false end
    local key_kind = type(key)
    if key_kind == "string" then
      if shape == "array" then return false end
      shape = "object"
      state.bytes = state.bytes + #key
      state.strings[key] = true
    elseif key_kind == "number" then
      if shape == "object"
        or key ~= key
        or key == math.huge
        or key == -math.huge
        or key ~= math.floor(key)
        or key < 1
        or key > ENCODE_MAX_MEMBERS then
        return false
      end
      shape = "array"
      count = count + 1
      if key > maximum then maximum = key end
    else
      return false
    end
    if state.bytes > 1048576 or not collect_encode_strings(item, depth + 1, state) then return false end
  end
  if shape == "array" and maximum ~= count then return false end
  state.seen[value] = nil
  return true
end

local function prepare_encode_value(value, marker, state)
  if type(value) ~= "table" then return value end
  local fragment = rawget(value, RAW_FRAGMENT)
  if fragment ~= nil then
    state.fragment = fragment
    return marker
  end
  local output = {}
  for key, item in pairs(value) do
    output[key] = prepare_encode_value(item, marker, state)
  end
  return output
end

function M.encode(config, json_adapter)
  if type(config) ~= "table" or type(json_adapter) ~= "table" then
    return nil, "invalid JSON encoding input"
  end
  local stringify = json_adapter.stringify or json_adapter.encode
  if type(stringify) ~= "function" then return nil, "invalid JSON encoding adapter" end

  local scan = { strings = {}, seen = {}, members = 0, bytes = 0, raw_count = 0 }
  if not collect_encode_strings(config, 0, scan) then return nil, "invalid JSON encoding input" end
  local marker_index, marker = 1
  repeat
    marker = "__XC_RAW_OUTBOUND_" .. marker_index .. "__"
    marker_index = marker_index + 1
  until not scan.strings[marker]

  local prepared_state = {}
  local prepared = prepare_encode_value(config, marker, prepared_state)
  local ok, encoded = pcall(stringify, prepared)
  if not ok or type(encoded) ~= "string" then return nil, "invalid JSON encoding" end
  if scan.raw_count == 0 then return encoded end

  local quoted_marker = '"' .. marker .. '"'
  local first = encoded:find(quoted_marker, 1, true)
  if not first or encoded:find(quoted_marker, first + #quoted_marker, true) then
    return nil, "invalid JSON encoding"
  end
  return encoded:sub(1, first - 1) .. prepared_state.fragment .. encoded:sub(first + #quoted_marker)
end

local function sniffing()
  return {
    enabled = true,
    routeOnly = true,
    destOverride = { "http", "tls" }
  }
end

local function validate_global(global)
  if type(global) ~= "table" then return nil, "invalid generator input" end
  local xray_log_level = global.xray_log_level
  if xray_log_level == nil then xray_log_level = "warning" end
  if type(xray_log_level) ~= "string" or not xray_log_levels[xray_log_level] then
    return nil, "invalid Xray log level"
  end
  if not valid_listen_address(global.listen_address) then return nil, "invalid global listen address" end
  local socks_port = port_number(global.socks_port)
  local http_port = port_number(global.http_port)
  if not socks_port or not http_port or socks_port == http_port then return nil, "invalid global ports" end
  local access_value, access_error = access.normalize(global)
  if not access_value then return nil, access_error end
  return {
    loglevel = xray_log_level,
    socks_port = socks_port,
    http_port = http_port,
    access = access_value
  }
end

function M.node_tag(section_id)
  if not schema.safe_section_id(section_id) then return nil end
  return "xc-node-" .. section_id
end

local function dynamic_enabled(value)
  return value == true or value == 1 or value == "1"
end

local function dynamic_nodes(nodes)
  if type(nodes) ~= "table" then return nil, "invalid dynamic nodes" end

  local maximum = 0
  for index in pairs(nodes) do
    if type(index) ~= "number" or index ~= index or index == math.huge or index == -math.huge
      or index < 1 or index > DYNAMIC_NODE_LIMIT or index ~= math.floor(index) then
      return nil, "invalid dynamic nodes"
    end
    if index > maximum then maximum = index end
  end
  if maximum == 0 then return nil, "no enabled dynamic nodes" end

  local outbounds, selector, seen = {}, {}, {}
  local node_count = 0
  for index = 1, maximum do
    local node = nodes[index]
    if type(node) ~= "table" or not dynamic_enabled(node.enabled) then
      return nil, "invalid dynamic node"
    end
    local normalized, normalize_error = schema.normalize(node)
    if not normalized or not dynamic_enabled(normalized.enabled) then
      return nil, normalize_error or "invalid dynamic node"
    end
    local tag = M.node_tag(normalized.id)
    if not tag then return nil, "invalid dynamic node" end
    if seen[tag] then return nil, "duplicate dynamic node" end
    seen[tag] = true
    local outbound, err = M.build_outbound(normalized, tag)
    if not outbound then return nil, err end
    node_count = node_count + 1
    outbounds[node_count] = outbound
    selector[node_count] = tag
  end
  return outbounds, selector, node_count
end

function M.build(global, node)
  if type(global) ~= "table" or type(node) ~= "table" then return nil, "invalid generator input" end
  local validated, validation_error = validate_global(global)
  if not validated then return nil, validation_error end

  local selected, err = M.build_outbound(node, "proxy-selected")
  if not selected then return nil, err end
  local config = {
    log = { access = "none", loglevel = validated.loglevel, dnsLog = false },
    inbounds = {
      {
        tag = "socks-in",
        listen = global.listen_address,
        port = validated.socks_port,
        protocol = "socks",
        settings = { auth = "noauth", udp = true },
        sniffing = sniffing()
      },
      {
        tag = "http-in",
        listen = global.listen_address,
        port = validated.http_port,
        protocol = "http",
        sniffing = sniffing()
      }
    },
    outbounds = {
      selected,
      { tag = "direct", protocol = "freedom" },
      { tag = "block", protocol = "blackhole", settings = { response = { type = "none" } } }
    },
    routing = {
      domainStrategy = "IPIfNonMatch",
      rules = routing.build(global, nil, validated.access)
    }
  }
  config.dns = routing.dns(global, validated.access)
  return config
end

function M.build_dynamic(global, nodes)
  local validated, validation_error = validate_global(global)
  if not validated then return nil, validation_error end
  if validated.socks_port == DYNAMIC_API_PORT or validated.http_port == DYNAMIC_API_PORT then
    return nil, "invalid dynamic API port"
  end
  local node_outbounds, selector, node_count = dynamic_nodes(nodes)
  if not node_outbounds then return nil, selector end

  local config = {
    log = { access = "none", loglevel = validated.loglevel, dnsLog = false },
    api = { tag = "xc-api", services = { "RoutingService" } },
    inbounds = {
      {
        tag = "socks-in",
        listen = global.listen_address,
        port = validated.socks_port,
        protocol = "socks",
        settings = { auth = "noauth", udp = true },
        sniffing = sniffing()
      },
      {
        tag = "http-in",
        listen = global.listen_address,
        port = validated.http_port,
        protocol = "http",
        sniffing = sniffing()
      },
      {
        tag = "xc-api",
        listen = "127.0.0.1",
        port = DYNAMIC_API_PORT,
        protocol = "dokodemo-door",
        settings = { address = "127.0.0.1" }
      }
    },
    outbounds = node_outbounds,
    routing = {
      domainStrategy = "IPIfNonMatch",
      balancers = { { tag = "xc-balancer", selector = selector } },
      rules = {
        { type = "field", inboundTag = { "xc-api" }, outboundTag = "xc-api" }
      }
    }
  }
  local outbound_count = node_count
  outbound_count = outbound_count + 1
  config.outbounds[outbound_count] = { tag = "direct", protocol = "freedom" }
  outbound_count = outbound_count + 1
  config.outbounds[outbound_count] = { tag = "block", protocol = "blackhole", settings = { response = { type = "none" } } }
  outbound_count = outbound_count + 1
  config.outbounds[outbound_count] = { tag = "xc-api", protocol = "freedom" }
  local routing_rules = routing.build(global, { balancerTag = "xc-balancer" }, validated.access)
  local routing_rule_count = 1
  for _, rule in ipairs(routing_rules) do
    routing_rule_count = routing_rule_count + 1
    config.routing.rules[routing_rule_count] = rule
  end
  config.dns = routing.dns(global, validated.access)
  return config
end

return M
