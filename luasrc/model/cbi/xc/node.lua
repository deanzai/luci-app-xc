local dispatcher = require "luci.dispatcher"
local http = require "luci.http"
local schema = require "xc.schema"

local section_id = arg[1]
if not schema.safe_section_id(section_id) then
  local invalid = Map("xc", translate("Edit node"))
  invalid.errmessage = translate("The selected node is invalid.")
  invalid.redirect = dispatcher.build_url("admin", "services", "xc", "nodes")
  return invalid
end

local m = Map("xc", translate("Edit node"))
m.redirect = dispatcher.build_url("admin", "services", "xc", "nodes")

local node = m:section(NamedSection, section_id, "node", translate("Node"))
node.addremove = false

local function current_value(option, section)
  local value = m:formvalue("cbid.xc." .. section .. "." .. option)
  if value == nil then value = m:get(section, option) end
  return value
end

local enabled = node:option(Flag, "enabled", translate("Enabled"))
enabled.default = "1"
enabled.rmempty = false

local name = node:option(Value, "name", translate("Name"))
name.rmempty = false

local protocol = node:option(ListValue, "protocol", translate("Protocol"))
protocol:value("vless", "VLESS")
protocol:value("vmess", "VMess")
protocol:value("trojan", "Trojan")
protocol:value("shadowsocks", "Shadowsocks")
protocol:value("socks", "SOCKS")
protocol:value("raw", translate("Raw outbound JSON"))
protocol.default = "vless"
protocol.rmempty = false

local protocol_fields = {
  "server", "port", "uuid", "encryption", "alter_id", "password", "user", "method",
  "transport", "security", "flow", "sni", "fingerprint", "public_key", "short_id",
  "ws_host", "ws_path", "grpc_service_name", "raw_outbound"
}
local compatible_fields = {
  vless = {
    server = true, port = true, uuid = true, encryption = true, transport = true, security = true,
    flow = true, sni = true, fingerprint = true, public_key = true, short_id = true,
    ws_host = true, ws_path = true, grpc_service_name = true
  },
  vmess = {
    server = true, port = true, uuid = true, encryption = true, alter_id = true,
    transport = true, security = true, sni = true, fingerprint = true,
    ws_host = true, ws_path = true, grpc_service_name = true
  },
  trojan = {
    server = true, port = true, password = true, transport = true, security = true,
    sni = true, fingerprint = true, ws_host = true, ws_path = true, grpc_service_name = true
  },
  shadowsocks = { server = true, port = true, password = true, method = true },
  socks = { server = true, port = true, user = true, password = true },
  raw = { raw_outbound = true }
}

function protocol.write(self, section, value)
  local written = ListValue.write(self, section, value)
  if not written then return written end
  local keep = compatible_fields[value] or {}
  for _, field in ipairs(protocol_fields) do
    local submitted = self.map:formvalue("cbid.xc." .. section .. "." .. field)
    if (not keep[field] or submitted == nil) and self.map:get(section, field) ~= nil then
      if not self.map:del(section, field) then return false end
    end
  end
  return written
end

function protocol.validate(self, value, section)
  local secret = current_value("password", section)
  if (value == "trojan" or value == "shadowsocks") and (secret == nil or secret == "") then
    return nil, translate("A password is required for this protocol.")
  end
  if value == "socks" then
    local username = current_value("user", section)
    if ((username and username ~= "") ~= (secret and secret ~= "")) then
      return nil, translate("SOCKS username and password must be supplied together.")
    end
  end
  return value
end

local server = node:option(Value, "server", translate("Server"))
for _, value in ipairs({ "vless", "vmess", "trojan", "shadowsocks", "socks" }) do
  server:depends("protocol", value)
end
server.datatype = "host"
server.rmempty = false

local port = node:option(Value, "port", translate("Port"))
for _, value in ipairs({ "vless", "vmess", "trojan", "shadowsocks", "socks" }) do
  port:depends("protocol", value)
end
port.datatype = "port"
port.rmempty = false

local uuid = node:option(Value, "uuid", translate("UUID"))
uuid:depends("protocol", "vless")
uuid:depends("protocol", "vmess")
uuid.password = true
uuid.rmempty = false

local encryption = node:option(ListValue, "encryption", translate("Encryption"))
encryption:depends("protocol", "vless")
encryption:depends("protocol", "vmess")
encryption:value("none", "none")
encryption:value("auto", "auto")
encryption:value("aes-128-gcm", "aes-128-gcm")
encryption:value("chacha20-poly1305", "chacha20-poly1305")
function encryption.validate(self, value, section)
  local selected = current_value("protocol", section)
  if (selected == "vless" and value ~= "none")
    or (selected == "vmess" and value ~= "auto" and value ~= "aes-128-gcm" and value ~= "chacha20-poly1305") then
    return nil, translate("This structured encryption is unsupported; use protocol=raw.")
  end
  return value
end

local alter_id = node:option(Value, "alter_id", translate("Alter ID"))
alter_id:depends("protocol", "vmess")
alter_id.datatype = "uinteger"
alter_id.default = "0"

local password = node:option(Value, "password", translate("Password"))
password:depends("protocol", "trojan")
password:depends("protocol", "shadowsocks")
password:depends("protocol", "socks")
password.password = true
function password.validate(self, value, section)
  local selected = current_value("protocol", section)
  if (selected == "trojan" or selected == "shadowsocks") and (value == nil or value == "") then
    return nil, translate("A password is required for this protocol.")
  end
  local username = current_value("user", section)
  if selected == "socks" and ((username and username ~= "") ~= (value and value ~= "")) then
    return nil, translate("SOCKS username and password must be supplied together.")
  end
  return value
end

local user = node:option(Value, "user", translate("SOCKS username"))
user:depends("protocol", "socks")
function user.validate(self, value, section)
  local secret = current_value("password", section)
  if (value and value ~= "") ~= (secret and secret ~= "") then
    return nil, translate("SOCKS username and password must be supplied together.")
  end
  return value
end

local method = node:option(ListValue, "method", translate("Shadowsocks method"))
method:depends("protocol", "shadowsocks")
for _, value in ipairs({
  "aes-128-gcm", "aes-256-gcm", "chacha20-ietf-poly1305", "xchacha20-ietf-poly1305",
  "2022-blake3-aes-128-gcm", "2022-blake3-aes-256-gcm", "2022-blake3-chacha20-poly1305"
}) do method:value(value) end

local transport = node:option(ListValue, "transport", translate("Transport"))
for _, value in ipairs({ "vless", "vmess", "trojan" }) do
  transport:depends("protocol", value)
end
transport:value("tcp", "TCP")
transport:value("ws", "WebSocket")
transport:value("grpc", "gRPC")
transport.default = "tcp"
function transport.validate(self, value, section)
  if current_value("security", section) == "reality" and value ~= "tcp" and value ~= "grpc" then
    return nil, translate("Reality with this transport is unsupported; use protocol=raw.")
  end
  return value
end

local security = node:option(ListValue, "security", translate("Security"))
for _, value in ipairs({ "vless", "vmess", "trojan" }) do
  security:depends("protocol", value)
end
security:value("none", translate("None"))
security:value("tls", "TLS")
security:value("reality", "Reality")
security.default = "none"
function security.validate(self, value, section)
  if value == "reality" and current_value("protocol", section) ~= "vless" then
    return nil, translate("Reality is supported only for structured VLESS nodes; use protocol=raw.")
  end
  return value
end

local flow = node:option(ListValue, "flow", translate("Flow"))
flow:depends({ protocol = "vless", transport = "tcp" })
flow:value("", translate("None"))
flow:value("xtls-rprx-vision", "xtls-rprx-vision")
flow:value("xtls-rprx-vision-udp443", "xtls-rprx-vision-udp443")
function flow.validate(self, value, section)
  if value ~= "" and current_value("transport", section) ~= "tcp" then
    return nil, translate("This flow requires TCP; use protocol=raw for other combinations.")
  end
  return value
end

local sni = node:option(Value, "sni", translate("Server name (SNI)"))
sni:depends({ protocol = "vless", security = "tls" })
sni:depends({ protocol = "vmess", security = "tls" })
sni:depends({ protocol = "trojan", security = "tls" })
sni:depends({ protocol = "vless", security = "reality" })
sni.datatype = "host"
sni.rmempty = false

local fingerprint = node:option(ListValue, "fingerprint", translate("TLS fingerprint"))
fingerprint:depends({ protocol = "vless", security = "tls" })
fingerprint:depends({ protocol = "vmess", security = "tls" })
fingerprint:depends({ protocol = "trojan", security = "tls" })
fingerprint:depends({ protocol = "vless", security = "reality" })
fingerprint:value("", translate("Default"))
for _, value in ipairs({ "chrome", "firefox", "safari", "ios", "android", "edge", "360", "qq", "random", "randomized" }) do
  fingerprint:value(value)
end

local public_key = node:option(Value, "public_key", translate("Reality public key"))
public_key:depends({ protocol = "vless", security = "reality" })
public_key.password = true
public_key.rmempty = false

local short_id = node:option(Value, "short_id", translate("Reality short ID"))
short_id:depends({ protocol = "vless", security = "reality" })
short_id.password = true

local ws_host = node:option(Value, "ws_host", translate("WebSocket Host"))
ws_host:depends({ protocol = "vless", transport = "ws" })
ws_host:depends({ protocol = "vmess", transport = "ws" })
ws_host:depends({ protocol = "trojan", transport = "ws" })
ws_host.datatype = "host"

local ws_path = node:option(Value, "ws_path", translate("WebSocket path"))
ws_path:depends({ protocol = "vless", transport = "ws" })
ws_path:depends({ protocol = "vmess", transport = "ws" })
ws_path:depends({ protocol = "trojan", transport = "ws" })
ws_path.placeholder = "/"

local grpc_service_name = node:option(Value, "grpc_service_name", translate("gRPC service name"))
grpc_service_name:depends({ protocol = "vless", transport = "grpc" })
grpc_service_name:depends({ protocol = "vmess", transport = "grpc" })
grpc_service_name:depends({ protocol = "trojan", transport = "grpc" })

local raw_outbound = node:option(TextValue, "raw_outbound", translate("Raw outbound JSON"),
  translate("Use a complete Xray outbound JSON object for uncommon or unsupported combinations."))
raw_outbound:depends("protocol", "raw")
raw_outbound.rows = 20
raw_outbound.wrap = "off"
raw_outbound.rmempty = false
function raw_outbound.validate(self, value, section)
  if not schema.raw_outbound_with_tag(value, "xc-validation") then
    return nil, translate("Raw outbound JSON must be a valid JSON object with a protocol.")
  end
  return value
end

return m
