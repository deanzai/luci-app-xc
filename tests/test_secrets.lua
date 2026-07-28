local t = require "testlib"
local runtime_module = require "xc.runtime"
local controller_fixture = require("test_controller_actions").fixture

local function read_file(path)
  local handle = assert(io.open(path, "r"))
  local value = assert(handle:read("*a"))
  handle:close()
  return value
end

local function runtime_fixture()
  local files = {}
  local function yes() return true end
  local adapters = {
    now = function() return 1 end,
    sleep = yes,
    network = function() return "127.0.0.1" end,
    json = { stringify = function(value)
      local parts = {}
      for key, item in pairs(value) do
        parts[#parts + 1] = string.format('%q:%q', tostring(key), tostring(item))
      end
      return "{" .. table.concat(parts, ",") .. "}"
    end },
    uci = {
      get_global = yes, get_node = yes, list_nodes = function() return {} end,
      set_active = yes, clear_active = yes, commit = yes, revert = yes
    },
    exec = {
      run = yes, restart = yes, stop = yes, listener_ready = yes,
      health_check = yes, service_state = function() return "stopped" end
    },
    fs = {
      acquire_lock = function() return {} end, release_lock = yes,
      lock_state = function() return "unlocked" end,
      allocate_generation = function() return "generation" end,
      list_generation_files = function() return {} end,
      trash_generation = yes, delete_trashed_generation = yes,
      read = function(path) return files[path], files[path] and nil or "missing" end,
      write_temp = function(path, value) return { path = path .. ".tmp", value = value } end,
      chmod = function() return true end,
      fsync = function() return true end,
      close = function() return true end,
      rename = function(source, destination)
        files[destination], files[source] = files[source], nil
        return true
      end,
      fsync_dir = function() return true end,
      exists = function(path) return files[path] ~= nil end,
      remove = function() return true end
    }
  }
  adapters.fs.write_temp = function(path, value)
    adapters.fs.pending = { path = path .. ".tmp", value = value }
    files[adapters.fs.pending.path] = value
    return adapters.fs.pending
  end
  return runtime_module.new(adapters), files
end

t.test("log helper redacts credentials links and raw outbound JSON", function()
  local runtime, files = runtime_fixture()
  local uuid = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
  local password = "task10-password"
  local link = "vless://" .. uuid .. "@secret.invalid:443?security=tls#Private"
  local raw = '{"protocol":"trojan","password":"raw-password"}'
  local result = runtime:log("failure " .. uuid .. " password=" .. password .. " " .. link .. " " .. raw, {
    uuid = uuid, password = password, share_link = link, raw_outbound = raw
  })
  t.eq(result.ok, true)
  local output = files[runtime_module.paths.log]
  for _, secret in ipairs({ uuid, password, link, "secret.invalid", raw, "raw-password" }) do
    t.eq(output:find(secret, 1, true), nil, "log leaked " .. secret)
  end
end)

t.test("public controller errors cannot echo exception secrets", function()
  local source = read_file("luasrc/controller/xc.lua")
  t.contains(source, 'xpcall(function()')
  t.contains(source, 'function() return "internal_error" end')
  t.contains(source, 'message = messages[code] or "The request failed safely."')
  t.eq(source:find("tostring(err)", 1, true), nil)
end)

t.test("controller exception responses redact representative secret values", function()
  local secrets = {
    "bbbbbbbb-cccc-4ddd-8eee-ffffffffffff",
    "controller-password",
    "vless://bbbbbbbb-cccc-4ddd-8eee-ffffffffffff@private.invalid:443#Private",
    '{"protocol":"trojan","password":"raw-controller-password"}',
    "raw-controller-password"
  }
  local controller, state = controller_fixture({ import_parse = function()
    error(table.concat(secrets, " "))
  end })
  controller.action_import_preview()
  local public = table.concat({
    tostring(state.status), tostring(state.content_type), tostring(state.response.ok),
    tostring(state.response.code), tostring(state.response.message)
  }, " ")
  t.eq(state.status, 400)
  t.eq(state.response.code, "validation_failed")
  for _, secret in ipairs(secrets) do
    t.eq(public:find(secret, 1, true), nil, "controller response leaked " .. secret)
  end
end)

t.test("log UI uses authenticated bounded tail and truncate endpoints", function()
  local controller = read_file("luasrc/controller/xc.lua")
  local model = read_file("luasrc/model/cbi/xc/log.lua")
  local view = read_file("luasrc/view/xc/log.htm")
  t.contains(controller, '{ "admin", "services", "xc", "get-log" }')
  t.contains(controller, 'post_entry({ "admin", "services", "xc", "clear-log" }')
  t.contains(controller, 'LOG_READ_MAX = 256 * 1024')
  t.contains(controller, 'adapters.fs.read_tail, runtime_module.paths.log, LOG_READ_MAX')
  t.contains(controller, 'adapters.fs.truncate, runtime_module.paths.log')
  t.eq(controller:find('adapters.fs.remove(runtime_module.paths.log)', 1, true), nil)
  t.contains(model, 'template = "xc/log"')
  t.contains(view, 'build_url("admin", "services", "xc", "get-log")')
  t.contains(view, 'build_url("admin", "services", "xc", "clear-log")')
  t.contains(view, 'confirm(')
  t.contains(view, '<%:Refresh%>')
  t.contains(view, '<%:Clear log%>')
end)

t.test("package scripts are executable", function()
  for _, path in ipairs({
    "root/etc/init.d/xc", "root/etc/hotplug.d/iface/95-xc",
    "root/etc/uci-defaults/luci-xc", "root/usr/bin/xc"
  }) do
    t.eq(os.execute("test -x " .. path), 0, path .. " must be executable")
  end
end)

t.test("rpcd ACL and ucitrack grant access only to xc", function()
  local acl = read_file("root/usr/share/rpcd/acl.d/luci-app-xc.json")
  local track = read_file("root/usr/share/ucitrack/luci-app-xc.json")
  t.contains(acl, '"read"')
  t.contains(acl, '"write"')
  t.contains(acl, '"uci": [ "xc" ]')
  t.eq(acl:find('"ubus"', 1, true), nil)
  t.eq(acl:find('"file"', 1, true), nil)
  t.eq(acl:find('"network"', 1, true), nil)
  t.contains(track, '"config": "xc"')
  t.contains(track, '"init": "xc"')
end)

t.test("translation catalogs cover visible XC menu button and status strings", function()
  local pot = read_file("po/templates/xc.pot")
  local po = read_file("po/zh_Hans/xc.po")
  local function catalog(value, translated)
    local entries, current = {}
    for line in value:gmatch("[^\r\n]+") do
      local id = line:match('^msgid "(.*)"$')
      if id then current = id; if not translated then entries[id] = true end end
      local message = line:match('^msgstr "(.*)"$')
      if translated and message and current then entries[current] = message end
    end
    return entries
  end
  local template_entries = catalog(pot, false)
  local translations = catalog(po, true)
  local required = {}
  local function require_message(message) required[message] = true end
  for _, path in ipairs({
    "luasrc/controller/xc.lua", "luasrc/model/cbi/xc/settings.lua",
    "luasrc/model/cbi/xc/nodes.lua", "luasrc/model/cbi/xc/node.lua",
    "luasrc/model/cbi/xc/log.lua", "luasrc/view/xc/status.htm",
    "luasrc/view/xc/node_table.htm", "luasrc/view/xc/import.htm",
    "luasrc/view/xc/log.htm"
  }) do
    local source = read_file(path)
    for message in source:gmatch('translate%(%s*"([^"\r\n]+)"') do require_message(message) end
    for message in source:gmatch('_%(%s*"([^"\r\n]+)"') do require_message(message) end
    for message in source:gmatch('<%%:([^%%\r\n]+)%%>') do require_message(message) end
  end
  for _, message in ipairs({
    "Add", "Edit", "Delete", "Switch", "Probe all", "Import", "Running", "Stopped",
    "Working…", "Operation completed", "Operation failed", "Rollback",
    "Runtime status", "Service", "SOCKS listener", "HTTP listener", "Exit IP",
    "Restart service", "Manual rollback", "Local import", "Test all", "Test"
  }) do
    require_message(message)
  end
  for message in pairs(required) do
    t.truthy(template_entries[message], "POT missing " .. message)
    t.truthy(translations[message] and translations[message] ~= "", "Simplified Chinese translation missing " .. message)
  end
end)
