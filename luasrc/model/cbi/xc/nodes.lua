local dispatcher = require "luci.dispatcher"
local http = require "luci.http"
local uci_model = require "luci.model.uci"

local m = Map("xc", translate("Nodes"),
  translate("Only non-sensitive node properties are shown in this list."))

local nodes = m:section(TypedSection, "node", translate("Configured nodes"))
nodes.anonymous = true
nodes.addremove = true
nodes.template = "xc/node_table"
nodes.extedit = dispatcher.build_url("admin", "services", "xc", "node", "%s")

local page_cursor = uci_model.cursor()
nodes.active_section = page_cursor:get("xc", "global", "active_node")
local configured_concurrency = tonumber(page_cursor:get("xc", "global", "probe_concurrency")) or 3
configured_concurrency = math.floor(configured_concurrency)
if configured_concurrency < 1 then configured_concurrency = 1 elseif configured_concurrency > 5 then configured_concurrency = 5 end
nodes.probe_concurrency = configured_concurrency

local probe_reader
local adapters_ok, platform = pcall(require, "xc.platform")
local probe_ok, probe_module = pcall(require, "xc.probe")
if adapters_ok and probe_ok then
  local made, adapters = pcall(platform.new)
  if made and adapters then
    local reader_ok, reader = pcall(probe_module.new, adapters)
    if reader_ok then probe_reader = reader end
  end
end

function nodes.create(self)
  local section = TypedSection.create(self)
  if section then
    http.redirect(self.extedit:format(section))
  end
  return section
end

function nodes.remove(self, section)
  local cursor = uci_model.cursor()
  local plugin_enabled = cursor:get("xc", "global", "enabled") == "1"
  if plugin_enabled then
    local active = cursor:get("xc", "global", "active_node")
    if active == section then
      self.map.errmessage = translate("The active node cannot be deleted while XC is enabled. Switch nodes first.")
      return nil
    end

    local enabled_count = 0
    local target_enabled = false
    cursor:foreach("xc", "node", function(candidate)
      if candidate.enabled == "1" then
        enabled_count = enabled_count + 1
        if candidate[".name"] == section then target_enabled = true end
      end
    end)
    if target_enabled and enabled_count == 1 then
      self.map.errmessage = translate("The only enabled node cannot be deleted while XC is enabled. Disable XC first.")
      return nil
    end
  end
  return TypedSection.remove(self, section)
end

local enabled = nodes:option(Flag, "enabled", translate("Enabled"))
enabled.default = "1"
enabled.rmempty = false

local name = nodes:option(DummyValue, "name", translate("Name"))
name.default = "-"

local protocol = nodes:option(DummyValue, "protocol", translate("Protocol"))
protocol.default = "-"

local server = nodes:option(DummyValue, "server", translate("Server"))
server.default = "-"

local port = nodes:option(DummyValue, "port", translate("Port"))
port.datatype = "port"
port.default = "-"

local latency = nodes:option(DummyValue, "_latency", translate("Latency"))
latency.template = "xc/ping_latency"
function latency.cfgvalue(self, section)
  if not probe_reader then return nil end
  local ok, cached = pcall(probe_reader.cached, probe_reader, section)
  return ok and cached or nil
end

if SimpleSection then
  local import = m:section(SimpleSection)
  import.template = "xc/import"
end

return m
