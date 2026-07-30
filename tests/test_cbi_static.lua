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
local log_path = "luasrc/model/cbi/xc/log.lua"
local config_path = "root/etc/config/xc"

t.test("Task 8 CBI and status files exist", function()
  for _, path in ipairs({ settings_path, nodes_path, node_path, status_path, log_path }) do
    read_file(path)
  end
end)

t.test("log page uses a permission-independent SimpleForm shell", function()
  local value = source(log_path)
  local compact = value:gsub("%s+", "")
  t.contains(value, 'SimpleForm("xc_log"')
  t.contains(value, 'm:section(SimpleSection)')
  t.contains(value, 'section.template = "xc/log"')
  t.truthy(
    compact:find("m.submit=false", 1, true)
      and compact:find("m.reset=false", 1, true)
      and compact:find("m.cancel=false", 1, true)
    or compact:find("m.submit,m.reset,m.cancel=false,false,false", 1, true),
    "log form must explicitly disable submit, reset, and cancel controls"
  )
  t.eq(value:find('Map("xc"', 1, true), nil)
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
  t.eq(value:find('.datatype = "url"', 1, true), nil, "LuCI 24.10 legacy CBI has no url datatype token")
  t.contains(value, "local function validate_http_url")
  t.contains(value, "probe_url.validate = validate_http_url")
  t.contains(value, "health_url.validate = validate_http_url")
  t.contains(value, 'listen_mode:value("lan"')
  t.eq(value:find('listen_mode:value("custom"', 1, true), nil, "runtime currently supports LAN-derived listening only")
  t.contains(value, 'listen_address.readonly = true')
end)

t.test("Xray runtime log level has an exact UCI default and ListValue contract", function()
  local config = source(config_path)
  t.contains(config, "\toption xray_log_level 'warning'\n")

  local base = {}
  function base:value(key, label)
    self.values[#self.values + 1] = { key, label }
  end
  local classes = {
    NamedSection = {}, SimpleSection = {}, Flag = {}, Value = {}, ListValue = base
  }
  local map = { options = {} }
  function map:section()
    local section = {}
    function section:option(option_class, option)
      local value = setmetatable({ option_class = option_class, values = {} }, { __index = option_class })
      map.options[option] = value
      return value
    end
    return section
  end
  local environment = {
    Map = function() return map end,
    translate = function(value) return value end,
    require = function(name)
      if name == "luci.model.uci" then
        return { cursor = function() return { foreach = function() end } end }
      end
      return require(name)
    end
  }
  for name, value in pairs(classes) do environment[name] = value end
  setmetatable(environment, { __index = _G })

  local chunk = assert(loadfile(settings_path))
  setfenv(chunk, environment)
  assert(chunk())

  local option = assert(map.options.xray_log_level)
  t.eq(option.option_class, classes.ListValue)
  t.eq(option.default, "warning")
  t.eq(option.rmempty, false)
  t.eq(#option.values, 4)
  local expected = {
    { "error", "Error" }, { "warning", "Warning" },
    { "info", "Info" }, { "debug", "Debug" }
  }
  for index, value in ipairs(expected) do
    t.eq(option.values[index][1], value[1])
    t.eq(option.values[index][2], value[2])
  end
  for _, name in ipairs({ "probe_url", "health_url" }) do
    local url_option = assert(map.options[name])
    t.eq(url_option:validate("https://example.invalid/path", "global"), "https://example.invalid/path")
    t.eq(url_option:validate("http://127.0.0.1/health", "global"), "http://127.0.0.1/health")
    for _, invalid in ipairs({ "ftp://example.invalid", "example.invalid", "https://bad\n.invalid", string.rep("a", 2049) }) do
      local accepted, message = url_option:validate(invalid, "global")
      t.eq(accepted, nil)
      t.eq(message, "Enter an HTTP or HTTPS URL.")
    end
  end
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
  t.contains(value, 'nodes.active_section = page_cursor:get("xc", "global", "active_node")')
  t.eq(value:find(', "_active"', 1, true), nil, "active node is highlighted instead of using a dedicated column")
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

local function run_remove_case(global, configured, target)
  local removed, map, captured = nil, nil, nil
  local cursor = {
    get = function(_, _, section, option) return global[section] and global[section][option] end,
    foreach = function(_, _, _, callback) for _, node in ipairs(configured) do callback(node) end end
  }
  local typed = {
    create = function() return "new_node" end,
    remove = function(_, section) removed = section; return true end
  }
  local base = {}; function base:value() end
  local function class() return setmetatable({}, { __index = base }) end
  local environment = {
    Map = function()
      map = { uci = cursor }
      function map:section()
        captured = { map = self }
        function captured:option(option_class) return setmetatable({ map = self.map }, { __index = option_class }) end
        return captured
      end
      return map
    end,
    TypedSection = typed, DummyValue = class(), Flag = class(), translate = function(v) return v end,
    require = function(name)
      if name == "luci.dispatcher" then return { build_url = function(...) return table.concat({ ... }, "/") end } end
      if name == "luci.http" then return { redirect = function() end } end
      if name == "luci.model.uci" then return { cursor = function() return cursor end } end
      return require(name)
    end
  }
  setmetatable(environment, { __index = _G })
  local chunk = assert(loadfile(nodes_path)); setfenv(chunk, environment); assert(chunk())
  local outcome = captured:remove(target)
  return outcome, removed, map.errmessage
end

t.test("node deletion guards execute across service, active, enabled, and count states", function()
  local nodes = {
    { [".name"] = "one", enabled = "1" }, { [".name"] = "two", enabled = "1" },
    { [".name"] = "off", enabled = "0" }
  }
  local cases = {
    { enabled = "1", active = "one", target = "one", blocked = true },
    { enabled = "1", active = "one", target = "two", blocked = false },
    { enabled = "1", active = "one", target = "off", blocked = false },
    { enabled = "0", active = "one", target = "one", blocked = false }
  }
  for _, case in ipairs(cases) do
    local outcome, removed = run_remove_case({ global = { enabled = case.enabled, active_node = case.active } }, nodes, case.target)
    t.eq(outcome == nil, case.blocked)
    local expected_removed = case.blocked and nil or case.target
    if case.blocked then expected_removed = nil end
    t.eq(removed, expected_removed, "remove delegation mismatch for enabled=" .. case.enabled .. " target=" .. case.target)
  end
  local outcome, removed, message = run_remove_case({ global = { enabled = "1", active_node = "off" } },
    { { [".name"] = "one", enabled = "1" }, { [".name"] = "off", enabled = "0" } }, "one")
  t.eq(outcome, nil); t.eq(removed, nil); t.contains(message, "only enabled node")
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

local function load_node_editor(config, faults)
  faults = faults or {}
  local base = {}
  function base:value(key)
    self.keylist = self.keylist or {}
    self.keylist[#self.keylist + 1] = tostring(key)
  end
  function base:depends(condition, expected)
    self.dependencies = self.dependencies or {}
    self.dependencies[#self.dependencies + 1] = type(condition) == "table" and condition or { [condition] = expected }
  end
  function base:write(section, value)
    return self.map:set(section, self.option, value)
  end
  function base:remove(section) return self.map:del(section, self.option) end
  function base:transform(value) return value end
  function base:validate(value)
    if not self.is_list then return value end
    for _, allowed in ipairs(self.keylist or {}) do if allowed == value then return value end end
    return nil
  end
  function base:add_error(_, kind)
    self.map.errors[self.option] = kind
    self.map.save = false
  end
  function base:parse(section)
    local value = self.map:formvalue("cbid.xc." .. section .. "." .. self.option)
    local configured = self.map:get(section, self.option)
    if value and #value > 0 then
      local valid = self:validate(value, section)
      valid = self:transform(valid)
      if valid == nil then
        self:add_error(section, "invalid")
      elseif valid ~= configured and self:write(section, valid) then
        self.section.changed = true
      end
    elseif self.rmempty ~= false or self.optional then
      if self:remove(section) then self.section.changed = true end
    elseif configured ~= value then
      self:validate(nil, section)
      self:add_error(section, "missing")
    end
  end

  local function class(is_list)
    return setmetatable({ is_list = is_list }, { __index = base })
  end

  local map = { config = "xc", options = {}, option_order = {}, values = config, forms = {}, errors = {}, save = true }
  function map:section()
    local section = { map = self, changed = false }
    self.section_model = section
    function section:option(option_class, option)
      local value = setmetatable({ map = self.map, section = self, option = option }, { __index = option_class })
      self.map.options[option] = value
      self.map.option_order[#self.map.option_order + 1] = value
      return value
    end
    return section
  end
  function map:set(_, option, value)
    if self.values[option] == value then return false end
    if faults.set == option then return false end
    self.values[option] = value
    return true
  end
  function map:del(_, option)
    if self.values[option] == nil then return false end
    if faults.del == option then return false end
    self.values[option] = nil
    return true
  end
  function map:get(_, option) return self.values[option] end
  function map:formvalue(key) return self.forms[key] end
  function map:parse(section)
    self.changed_after = {}
    for _, option in ipairs(self.option_order) do
      option:parse(section)
      self.changed_after[option.option] = self.section_model.changed
    end
    return self.save
  end

  local classes = {
    NamedSection = {}, Flag = class(), Value = class(), ListValue = class(true), TextValue = class()
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

local function submit(map, values)
  for option, value in pairs(values) do map.forms["cbid.xc.node_1." .. option] = value end
  return map:parse("node_1")
end

t.test("LuCI parse removes TLS and Reality fields during security transitions", function()
  local base = {
    [".name"] = "node_1", enabled = "1", name = "Node", protocol = "vless",
    server = "edge.invalid", port = "443", uuid = "11111111-1111-1111-1111-111111111111",
    encryption = "none", transport = "tcp"
  }
  local cases = {
    { from = "tls", to = "none", stale = { sni = "edge.invalid", fingerprint = "chrome" } },
    { from = "reality", to = "tls", visible = { sni = "tls.invalid" }, stale = { public_key = string.rep("A", 43), short_id = "ab" } },
    { from = "reality", to = "none", stale = { sni = "edge.invalid", public_key = string.rep("A", 43), short_id = "ab" } }
  }
  for _, case in ipairs(cases) do
    local config = {}; for key, value in pairs(base) do config[key] = value end
    config.security = case.from
    for key, value in pairs(case.stale) do config[key] = value end
    local map = load_node_editor(config)
    local form = { enabled = "1", name = "Node", protocol = "vless", server = "edge.invalid", port = "443",
      uuid = base.uuid, encryption = "none", transport = "tcp", security = case.to }
    for key, value in pairs(case.visible or {}) do form[key] = value end
    t.eq(submit(map, form), true, case.from .. " -> " .. case.to .. " parse failed")
    t.eq(next(map.errors), nil)
    for key in pairs(case.stale) do
      if not (case.visible and case.visible[key]) then t.eq(config[key], nil, "retained hidden " .. key) end
    end
  end
end)

t.test("LuCI parse enforces visible required fields and cleans protocol and transport transitions", function()
  local uuid = "11111111-1111-1111-1111-111111111111"
  local config = { [".name"] = "node_1", enabled = "1", name = "Node", protocol = "vless",
    server = "old.invalid", port = "443", uuid = uuid, encryption = "none", transport = "ws",
    security = "tls", sni = "old.invalid", ws_host = "old.invalid", ws_path = "/old" }
  local map = load_node_editor(config)
  t.eq(submit(map, { enabled = "1", name = "Node", protocol = "vless", server = "new.invalid", port = "443",
    uuid = uuid, encryption = "none", transport = "grpc", security = "none", grpc_service_name = "svc" }), true)
  t.eq(config.ws_host, nil); t.eq(config.ws_path, nil); t.eq(config.sni, nil); t.eq(config.grpc_service_name, "svc")

  config = { [".name"] = "node_1", enabled = "1", name = "Node", protocol = "vless", server = "old.invalid",
    port = "443", uuid = uuid, encryption = "none", transport = "tcp", security = "reality",
    public_key = string.rep("A", 43), short_id = "ab" }
  map = load_node_editor(config)
  t.eq(submit(map, { enabled = "1", name = "Node", protocol = "raw", raw_outbound = '{"protocol":"freedom"}' }), true)
  t.eq(config.server, nil); t.eq(config.public_key, nil); t.eq(config.raw_outbound, '{"protocol":"freedom"}')

  config = { [".name"] = "node_1", enabled = "1", name = "Node", protocol = "vless", server = "old.invalid", security = "none" }
  map = load_node_editor(config)
  t.eq(submit(map, { enabled = "1", name = "Node", protocol = "vless", security = "tls" }), false)
  t.eq(map.errors.server, "missing")
end)

t.test("LuCI parse marks custom ListValue transitions changed and leaves no-op submissions unchanged", function()
  local uuid = "11111111-1111-1111-1111-111111111111"
  local cases = {
    {
      label = "protocol", config = { protocol = "vless", server = "old.invalid", port = "443", uuid = uuid,
        encryption = "none", transport = "tcp", security = "none" },
      form = { protocol = "raw", raw_outbound = '{"protocol":"freedom"}' }
    },
    {
      label = "transport", config = { protocol = "vless", server = "edge.invalid", port = "443", uuid = uuid,
        encryption = "none", transport = "ws", security = "none", ws_host = "edge.invalid", ws_path = "/ws" },
      form = { protocol = "vless", server = "edge.invalid", port = "443", uuid = uuid, encryption = "none",
        transport = "grpc", security = "none", grpc_service_name = "svc" }
    },
    {
      label = "security", config = { protocol = "vless", server = "edge.invalid", port = "443", uuid = uuid,
        encryption = "none", transport = "tcp", security = "reality", sni = "edge.invalid",
        public_key = string.rep("A", 43), short_id = "ab" },
      form = { protocol = "vless", server = "edge.invalid", port = "443", uuid = uuid, encryption = "none",
        transport = "tcp", security = "tls", sni = "edge.invalid" }
    }
  }
  for _, case in ipairs(cases) do
    case.config[".name"], case.config.enabled, case.config.name = "node_1", "1", "Node"
    case.form.enabled, case.form.name = "1", "Node"
    local map = load_node_editor(case.config)
    t.eq(submit(map, case.form), true, case.label .. " transition failed validation")
    t.eq(map.changed_after[case.label], true, case.label .. " writer did not mark the section changed")
  end

  local config = { [".name"] = "node_1", enabled = "1", name = "Node", protocol = "vless",
    server = "edge.invalid", port = "443", uuid = uuid, encryption = "none", transport = "tcp", security = "none" }
  local map = load_node_editor(config)
  t.eq(submit(map, { enabled = "1", name = "Node", protocol = "vless", server = "edge.invalid", port = "443",
    uuid = uuid, encryption = "none", transport = "tcp", security = "none" }), true)
  t.eq(map.section_model.changed, false, "no-op submission was falsely marked changed")
end)

t.test("custom ListValue transitions fail visibly and restore partial staged mutations", function()
  local uuid = "11111111-1111-1111-1111-111111111111"
  local function reality_config()
    return { [".name"] = "node_1", enabled = "1", name = "Node", protocol = "vless", server = "edge.invalid",
      port = "443", uuid = uuid, encryption = "none", transport = "tcp", security = "reality",
      sni = "edge.invalid", public_key = string.rep("A", 43), short_id = "ab" }
  end
  local config = reality_config()
  local map = load_node_editor(config, { set = "security" })
  t.eq(map.options.security:write("node_1", "tls"), false)
  t.eq(config.security, "reality"); t.eq(config.public_key, string.rep("A", 43))
  t.eq(map.errors.security, "write"); t.eq(map.save, false)

  config = reality_config()
  map = load_node_editor(config, { del = "public_key" })
  t.eq(map.options.security:write("node_1", "tls"), false)
  t.eq(config.security, "reality"); t.eq(config.public_key, string.rep("A", 43)); t.eq(config.short_id, "ab")
  t.eq(map.errors.security, "write"); t.eq(map.save, false)

  config = { [".name"] = "node_1", enabled = "1", name = "Node", protocol = "vless", server = "edge.invalid",
    port = "443", uuid = uuid, encryption = "none", transport = "ws", security = "none",
    ws_host = "edge.invalid", ws_path = "/ws" }
  map = load_node_editor(config, { del = "ws_path" })
  t.eq(map.options.transport:write("node_1", "tcp"), false)
  t.eq(config.transport, "ws"); t.eq(config.ws_host, "edge.invalid"); t.eq(config.ws_path, "/ws")
  t.eq(map.errors.transport, "write"); t.eq(map.save, false)
end)

t.test("custom ListValue writers treat absent cleanup as no-op and report genuine changes only", function()
  local config = { protocol = "vless", security = "tls", sni = "edge.invalid" }
  local map = load_node_editor(config)
  local security = map.options.security
  t.eq(security:write("node_1", "tls"), false)
  t.eq(map.errors.security, nil)
  t.eq(security:write("node_1", "none"), true)
  t.eq(config.security, "none"); t.eq(config.sni, nil)
end)

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
    map.options.protocol:write("node_1", selected)
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
  t.contains(value, 'dispatcher.build_url("admin", "services", "xc", "test-current")')
  t.contains(value, 'dispatcher.build_url("admin", "services", "xc", "rollback")')
  t.contains(value, "5000")
  t.contains(value, "document.hidden")
  t.contains(value, 'document.addEventListener("visibilitychange"')
  t.contains(value, "<%=token%>")
  t.contains(value, 'encodeURIComponent(csrfToken)')
  t.contains(value, 'JSON.stringify(payload || {})')
  t.contains(value, 'xhr.setRequestHeader("Content-Type", "application/json")')
  t.contains(value, 'unavailableText')
  t.contains(value, 'data.exit_ip || unavailableText')
  t.contains(value, 'textContent')
  t.eq(value:find("innerHTML", 1, true), nil)
  t.eq(value:find("os.execute", 1, true), nil)
  t.eq(value:find("/bin/", 1, true), nil)
end)
