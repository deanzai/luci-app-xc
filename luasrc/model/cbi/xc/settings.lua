local uci_model = require "luci.model.uci"

local function validate_http_url(self, value)
  if type(value) == "string"
    and #value <= 2048
    and value:match("^https?://")
    and not value:find("[%z\1-\31\127]") then
    return value
  end
  return nil, translate("Enter an HTTP or HTTPS URL.")
end

local m = Map("xc", translate("Xray node switching"),
  translate("Manage the local SOCKS and HTTP Xray listeners."))

local global = m:section(NamedSection, "global", "global", translate("Basic settings"))
global.addremove = false

local enabled = global:option(Flag, "enabled", translate("Enable"))
enabled.default = "0"
enabled.rmempty = false

local xray_log_level = global:option(ListValue, "xray_log_level", translate("Xray log level"))
xray_log_level:value("error", translate("Error"))
xray_log_level:value("warning", translate("Warning"))
xray_log_level:value("info", translate("Info"))
xray_log_level:value("debug", translate("Debug"))
xray_log_level.default = "warning"
xray_log_level.rmempty = false

local active_node = global:option(ListValue, "active_node", translate("Active node"))
active_node.rmempty = true
active_node:value("", translate("Not selected"))
local uci = uci_model.cursor()
uci:foreach("xc", "node", function(section)
  if section.enabled == "1" then
    active_node:value(section[".name"], section.name or section[".name"])
  end
end)

local listen_mode = global:option(ListValue, "listen_mode", translate("Listen mode"))
listen_mode:value("lan", translate("LAN address"))
listen_mode.default = "lan"
listen_mode.rmempty = false

local listen_address = global:option(Value, "listen_address", translate("Listen address"),
  translate("The runtime derives this address from network.lan and falls back to 127.0.0.1."))
listen_address.datatype = "ipaddr"
listen_address.default = ""
listen_address.rmempty = true
listen_address.readonly = true

local socks_port = global:option(Value, "socks_port", translate("SOCKS port"))
socks_port.datatype = "port"
socks_port.default = "7890"
socks_port.rmempty = false

local http_port = global:option(Value, "http_port", translate("HTTP port"))
http_port.datatype = "port"
http_port.default = "10809"
http_port.rmempty = false

local probe_concurrency = global:option(Value, "probe_concurrency", translate("Probe concurrency"))
probe_concurrency.datatype = "range(1,5)"
probe_concurrency.default = "3"
probe_concurrency.rmempty = false

local probe_timeout = global:option(Value, "probe_timeout", translate("Probe timeout"))
probe_timeout.datatype = "range(1,10)"
probe_timeout.default = "3"
probe_timeout.rmempty = false

local probe_url = global:option(Value, "probe_url", translate("Probe URL"))
probe_url.validate = validate_http_url
probe_url.default = "https://www.gstatic.com/generate_204"
probe_url.rmempty = false

local health_url = global:option(Value, "health_url", translate("Health check URL"))
health_url.validate = validate_http_url
health_url.default = "https://api.ipify.org"
health_url.rmempty = false

local health_timeout = global:option(Value, "health_timeout", translate("Health check timeout"))
health_timeout.datatype = "range(1,30)"
health_timeout.default = "15"
health_timeout.rmempty = false

local status = m:section(SimpleSection)
status.template = "xc/status"

return m
