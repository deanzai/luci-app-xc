local t = require "testlib"

local function read_file(path)
  local handle = io.open(path, "r")
  t.truthy(handle, path .. " is missing")
  local value = handle:read("*a")
  handle:close()
  return value
end

local function source(path)
  local ok, value = pcall(read_file, path)
  return ok and value or ""
end

local settings_path = "luasrc/model/cbi/xc/settings.lua"
local nodes_path = "luasrc/model/cbi/xc/nodes.lua"
local node_path = "luasrc/model/cbi/xc/node.lua"
local status_path = "luasrc/view/xc/status.htm"

t.test("Task 8 CBI and status files exist", function()
  for _, path in ipairs({ settings_path, nodes_path, node_path, status_path }) do
    read_file(path)
  end
end)

t.test("settings form uses exact global defaults and validation contracts", function()
  local value = source(settings_path)
  t.contains(value, 'Map("xc",')
  t.contains(value, 'NamedSection, "global", "global"')
  for option, default in pairs({
    enabled = "0", listen_mode = "lan", listen_address = "",
    socks_port = "7890", http_port = "10809", probe_concurrency = "3",
    probe_timeout = "3", probe_url = "https://www.gstatic.com/generate_204",
    health_url = "https://api.ipify.org", health_timeout = "15"
  }) do
    t.contains(value, ', "' .. option .. '"', "missing setting " .. option)
    t.contains(value, option .. '.default = "' .. default .. '"', "wrong default for " .. option)
  end
  t.contains(value, 'socks_port.datatype = "port"')
  t.contains(value, 'http_port.datatype = "port"')
  t.contains(value, 'probe_concurrency.datatype = "range(1,5)"')
  t.contains(value, 'probe_timeout.datatype = "range(1,10)"')
  t.contains(value, 'health_timeout.datatype = "range(1,30)"')
  t.contains(value, 'listen_mode:value("lan"')
  t.eq(value:find('listen_mode:value("custom"', 1, true), nil, "runtime currently supports LAN-derived listening only")
  t.contains(value, 'listen_address.readonly = true')
end)

t.test("active node choices contain only enabled real UCI nodes", function()
  local value = source(settings_path)
  t.contains(value, ', "active_node"')
  t.contains(value, 'uci:foreach("xc", "node"')
  t.contains(value, 'section.enabled == "1"')
  t.contains(value, 'active_node:value(section[".name"]')
end)

t.test("node list is anonymous, editable, removable, and secret-free", function()
  local value = source(nodes_path)
  t.contains(value, 'Map("xc",')
  t.contains(value, 'TypedSection, "node"')
  t.contains(value, 'nodes.anonymous = true')
  t.contains(value, 'nodes.addremove = true')
  t.contains(value, 'nodes.extedit = dispatcher.build_url(')
  for _, option in ipairs({ "enabled", "name", "protocol", "server", "port" }) do
    t.contains(value, ', "' .. option .. '"', "missing public node column " .. option)
  end
  t.contains(value, 'port.datatype = "port"')
  for _, secret in ipairs({ "uuid", "password", "public_key", "short_id", "raw_outbound" }) do
    t.eq(value:find(', "' .. secret .. '"', 1, true), nil, "node list leaks secret key " .. secret)
  end
end)

t.test("node removal protection reads committed UCI and emits secret-safe errors", function()
  local value = source(nodes_path)
  t.contains(value, 'function nodes.remove(self, section)')
  t.contains(value, 'uci_model.cursor()')
  t.contains(value, 'cursor:get("xc", "global", "enabled") == "1"')
  t.contains(value, 'cursor:get("xc", "global", "active_node")')
  t.contains(value, 'cursor:foreach("xc", "node"')
  t.contains(value, 'candidate.enabled == "1"')
  t.contains(value, 'TypedSection.remove(self, section)')
  t.eq(value:find("uuid", 1, true), nil)
  t.eq(value:find("password", 1, true), nil)
  t.eq(value:find("raw_outbound", 1, true), nil)
end)

t.test("node editor covers supported structured protocols and raw outbound", function()
  local value = source(node_path)
  t.contains(value, 'Map("xc",')
  t.contains(value, 'NamedSection, section_id, "node"')
  for _, protocol in ipairs({ "vless", "vmess", "trojan", "shadowsocks", "socks", "raw" }) do
    t.contains(value, 'protocol:value("' .. protocol .. '"', "missing protocol " .. protocol)
  end
  for _, option in ipairs({
    "uuid", "encryption", "method", "transport", "security", "sni", "fingerprint",
    "public_key", "short_id", "ws_host", "ws_path", "grpc_service_name", "user",
    "password", "raw_outbound"
  }) do
    t.contains(value, ', "' .. option .. '"', "missing conditional field " .. option)
  end
  for _, secret in ipairs({ "uuid", "password", "public_key", "short_id" }) do
    t.contains(value, 'Value, "' .. secret .. '"', secret .. " must use a legacy-compatible value")
    t.contains(value, secret .. ".password = true", secret .. " must render as a password input")
  end
  t.eq(value:find("Password,", 1, true), nil, "LuCI 21.02 has no Password CBI class")
  t.contains(value, 'port.datatype = "port"')
  t.contains(value, 'schema.raw_outbound_with_tag(value, "xc-validation")')
  t.contains(value, 'function raw_outbound.validate(self, value, section)')
  t.contains(value, 'function protocol.validate(self, value, section)')
  t.contains(value, 'SOCKS username and password must be supplied together.')
  t.contains(value, 'A password is required for this protocol.')
  t.contains(value, 'use protocol=raw')
end)

t.test("conditional fields depend on both protocol and security or transport", function()
  local value = source(node_path)
  t.eq(value:find('transport:depends("protocol", "shadowsocks")', 1, true), nil)
  t.eq(value:find('security:depends("protocol", "shadowsocks")', 1, true), nil)
  for _, dependency in ipairs({
    'sni:depends({ protocol = "vless", security = "tls" })',
    'sni:depends({ protocol = "vmess", security = "tls" })',
    'sni:depends({ protocol = "trojan", security = "tls" })',
    'sni:depends({ protocol = "vless", security = "reality" })',
    'fingerprint:depends({ protocol = "vless", security = "tls" })',
    'public_key:depends({ protocol = "vless", security = "reality" })',
    'short_id:depends({ protocol = "vless", security = "reality" })',
    'ws_host:depends({ protocol = "vless", transport = "ws" })',
    'ws_path:depends({ protocol = "vmess", transport = "ws" })',
    'grpc_service_name:depends({ protocol = "trojan", transport = "grpc" })'
  }) do
    t.contains(value, dependency)
  end
end)

local function load_node_editor(config)
  local base = {}
  function base:value() end
  function base:depends() end
  function base:write(section, value)
    return self.map:set(section, self.option, value)
  end

  local function class()
    return setmetatable({}, { __index = base })
  end

  local map = { config = "xc", options = {}, values = config, forms = {} }
  function map:section()
    local section = { map = self }
    function section:option(option_class, option)
      local value = setmetatable({ map = self.map, option = option }, { __index = option_class })
      self.map.options[option] = value
      return value
    end
    return section
  end
  function map:set(_, option, value) self.values[option] = value; return true end
  function map:del(_, option) self.values[option] = nil; return true end
  function map:get(_, option) return self.values[option] end
  function map:formvalue(key) return self.forms[key] end

  local classes = {
    NamedSection = {}, Flag = class(), Value = class(), ListValue = class(), TextValue = class()
  }
  local environment = {
    arg = { "node_1" },
    Map = function() return map end,
    translate = function(value) return value end,
    ipairs = ipairs,
    pairs = pairs,
    setmetatable = setmetatable,
    type = type,
    require = function(name)
      if name == "luci.dispatcher" then
        return { build_url = function(...) return table.concat({ ... }, "/") end }
      elseif name == "luci.http" then
        return { redirect = function() end }
      end
      return require(name)
    end
  }
  for name, value in pairs(classes) do environment[name] = value end
  setmetatable(environment, { __index = _G })

  local chunk = assert(loadfile(node_path))
  setfenv(chunk, environment)
  assert(chunk())
  return map, classes
end

t.test("protocol writes remove incompatible UCI fields and leave schema-valid nodes", function()
  local schema = require "xc.schema"
  local uuid = "11111111-1111-1111-1111-111111111111"
  local fields = {
    "server", "port", "uuid", "encryption", "alter_id", "password", "user", "method",
    "transport", "security", "flow", "sni", "fingerprint", "public_key", "short_id",
    "ws_host", "ws_path", "grpc_service_name", "raw_outbound"
  }
  local cases = {
    vless = {
      server = "vless.example", port = "443", uuid = uuid, encryption = "none",
      transport = "tcp", security = "none"
    },
    vmess = {
      server = "vmess.example", port = "443", uuid = uuid, encryption = "auto",
      alter_id = "0", transport = "tcp", security = "none"
    },
    trojan = {
      server = "trojan.example", port = "443", password = "trojan-secret",
      transport = "tcp", security = "tls", sni = "trojan.example"
    },
    shadowsocks = {
      server = "ss.example", port = "8388", password = "ss-secret", method = "aes-128-gcm"
    },
    socks = {
      server = "socks.example", port = "1080", user = "proxy-user", password = "proxy-secret"
    },
    raw = { raw_outbound = '{"protocol":"freedom"}' }
  }

  for selected, target in pairs(cases) do
    local config = {
      [".name"] = "node_1", enabled = "1", name = "Node", protocol = "vless",
      server = "stale.example", port = "6553", uuid = uuid, encryption = "none", alter_id = "9",
      password = "stale-secret", user = "stale-user", method = "aes-256-gcm",
      transport = "ws", security = "reality", flow = "xtls-rprx-vision",
      sni = "stale.example", fingerprint = "chrome", public_key = string.rep("A", 43), short_id = "ab",
      ws_host = "stale.example", ws_path = "/stale", grpc_service_name = "stale",
      raw_outbound = '{"protocol":"blackhole"}'
    }
    for key, value in pairs(target) do config[key] = value end
    local map = load_node_editor(config)
    map.forms["cbid.xc.node_1.protocol"] = selected
    for key, value in pairs(target) do
      map.forms["cbid.xc.node_1." .. key] = value
    end
    local written = map.options.protocol:write("node_1", selected)
    t.truthy(written, selected .. " protocol write failed")
    t.eq(config.protocol, selected)

    -- LuCI 21.02 parses protocol before the later target fields.
    for key, value in pairs(target) do config[key] = value end

    local allowed = { enabled = true, name = true, protocol = true }
    for key in pairs(target) do allowed[key] = true end
    for _, field in ipairs(fields) do
      if not allowed[field] then t.eq(config[field], nil, selected .. " retained stale " .. field) end
    end

    local normalized_input = { id = "node_1", enabled = true }
    for key, value in pairs(config) do
      if key:sub(1, 1) ~= "." and key ~= "enabled" then normalized_input[key] = value end
    end
    local normalized, err = schema.normalize(normalized_input)
    t.truthy(normalized, selected .. " save is not schema-valid: " .. tostring(err))
  end
end)

t.test("status template polls safely and reuses authenticated action routes", function()
  local value = source(status_path)
  for _, id in ipairs({
    "xc-service-state", "xc-active-node", "xc-socks-listener", "xc-http-listener", "xc-exit-ip",
    "xc-restart", "xc-health", "xc-rollback", "xc-action-result"
  }) do
    t.contains(value, 'id="' .. id .. '"', "missing status element " .. id)
  end
  t.contains(value, 'dispatcher.build_url("admin", "services", "xc", "status")')
  t.contains(value, 'dispatcher.build_url("admin", "services", "xc", "switch")')
  t.contains(value, 'dispatcher.build_url("admin", "services", "xc", "probe")')
  t.contains(value, 'dispatcher.build_url("admin", "services", "xc", "rollback")')
  t.contains(value, "5000")
  t.contains(value, "document.hidden")
  t.contains(value, 'document.addEventListener("visibilitychange"')
  t.contains(value, "<%=token%>")
  t.contains(value, 'encodeURIComponent(csrfToken)')
  t.contains(value, 'JSON.stringify(payload || {})')
  t.contains(value, 'xhr.setRequestHeader("Content-Type", "application/json")')
  t.contains(value, 'data.code === "not_implemented"')
  t.contains(value, 'unavailableText')
  t.contains(value, 'data.exit_ip || unavailableText')
  t.contains(value, 'textContent')
  t.eq(value:find("innerHTML", 1, true), nil)
  t.eq(value:find("os.execute", 1, true), nil)
  t.eq(value:find("/bin/", 1, true), nil)
end)
