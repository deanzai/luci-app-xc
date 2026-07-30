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

t.test("clear log serializes truncate with the runtime log lock", function()
  local controller, state = controller_fixture()
  controller.action_clear_log()
  t.eq(state.response.ok, true)
  t.eq(state.fs_events[1], "acquire:/var/lock/xc-log.lock")
  t.eq(state.fs_events[2], "truncate:/var/log/xc.log")
  t.eq(state.fs_events[3], "release:/var/lock/xc-log.lock")
end)

t.test("log controller behavior uses fixed bounded paths and safe failure envelopes", function()
  local uuid = "cccccccc-dddd-4eee-8fff-aaaaaaaaaaaa"
  local raw_tail = "raw-tail password=tail-secret token=tail-token vless://" .. uuid .. "@private.invalid:443"
  local controller, state = controller_fixture({
    log_content = raw_tail,
    log_json = { [raw_tail] = {
      time = 1785327995, level = "warning",
      message = "password=tail-secret token=tail-token vless://" .. uuid .. "@private.invalid:443",
      fields = { raw_content = '{"password":"raw-json-secret"}', node = "safe-node" }
    } }
  })
  controller.action_get_log()
  t.eq(state.response.ok, true)
  t.eq(state.response.data.clear_scope, "xc")
  t.eq(state.response.data.log, nil)
  t.eq(#state.response.data.entries, 1)
  t.eq(state.response.data.entries[1].source, "xc")
  t.contains(state.response.data.entries[1].message, "safe-node")
  local public = state.response.data.entries[1].message
  for _, secret in ipairs({ raw_tail, "tail-secret", "tail-token", uuid, "vless://", "private.invalid", "raw-json-secret" }) do
    t.eq(public:find(secret, 1, true), nil, "structured log response leaked " .. secret)
  end
  t.eq(state.fs_events[1], "read_tail:/var/log/xc.log:262144")

  controller, state = controller_fixture({ log_error = "missing" })
  controller.action_get_log()
  t.eq(state.response.ok, true); t.eq(#state.response.data.entries, 0)
  t.eq(state.response.data.clear_scope, "xc")

  controller, state = controller_fixture({ log_error = "io_error" })
  controller.action_get_log()
  t.eq(state.response.code, "internal_error"); t.eq(state.status, 500)

  controller, state = controller_fixture({ read_tail = function()
    error("password=read-tail-secret")
  end })
  controller.action_get_log()
  t.eq(state.response.code, "internal_error")
  t.eq(state.response.message:find("read%-tail%-secret"), nil)

  for _, options in ipairs({
    { truncate_ok = false }, { truncate_throw = true },
    { release_ok = false }, { release_throw = true }
  }) do
    controller, state = controller_fixture(options)
    controller.action_clear_log()
    t.eq(state.response.code, "internal_error")
    t.eq(state.fs_events[1], "acquire:/var/lock/xc-log.lock")
    t.eq(state.fs_events[#state.fs_events], "release:/var/lock/xc-log.lock")
  end

  controller, state = controller_fixture({ lock_busy = true })
  controller.action_clear_log()
  t.eq(state.response.code, "busy"); t.eq(state.status, 409)
  t.eq(#state.fs_events, 1)
end)

local function platform_log_fixture(options)
  options = options or {}
  local state = { content = options.content or "", opens = {}, flag_calls = {} }
  local function handle()
    local position = 0
    return {
      seek = function(_, offset, whence)
        if options.seek_fail then return nil end
        if whence == "end" then position = #state.content + offset else position = offset end
        return position
      end,
      read = function(_, maximum)
        if options.read_fail then return nil end
        local value = state.content:sub(position + 1, position + maximum)
        position = position + #value
        return value
      end,
      sync = function() return options.sync_ok ~= false end,
      close = function() return options.close_ok ~= false end
    }
  end
  local nixio = {
    open_flags = function(...)
      local values = { ... }; state.flag_calls[#state.flag_calls + 1] = table.concat(values, ",")
      return 32
    end,
    open = function(path, flags, mode)
      state.opens[#state.opens + 1] = { path = path, flags = flags, mode = mode }
      if options.open_error then return nil, options.open_error end
      if state.flag_calls[#state.flag_calls]:find("trunc", 1, true) then state.content = "" end
      return handle()
    end,
    getpid = function() return 1 end
  }
  local fs = {
    chmod = function(path, mode)
      state.chmod = { path = path, mode = mode }
      return options.chmod_ok ~= false
    end
  }
  local platform = require "xc.platform"
  local adapters = platform.new({
    nixio = nixio, fs = fs, cursor = { foreach = function() end }, uci_module = {},
    jsonc = { parse = function() end, stringify = function() return "{}" end }
  })
  return state, adapters.fs
end

t.test("platform log adapters select bounded tails and fail closed", function()
  local state, fs = platform_log_fixture({ content = "abcdef" })
  t.eq(fs.read_tail("/var/log/xc.log", 4), "cdef")
  t.eq(state.opens[1].path, "/var/log/xc.log")
  t.eq(state.opens[1].flags, 32 + 131072)
  t.eq(state.flag_calls[1], "rdonly")

  state, fs = platform_log_fixture({ content = "small" })
  t.eq(fs.read_tail("/var/log/xc.log", 262144), "small")

  state, fs = platform_log_fixture({ open_error = 2 })
  local value, code = fs.read_tail("/var/log/xc.log", 10)
  t.eq(value, nil); t.eq(code, "missing")

  for _, options in ipairs({ { seek_fail = true }, { read_fail = true } }) do
    state, fs = platform_log_fixture(options)
    value, code = fs.read_tail("/var/log/xc.log", 10)
    t.eq(value, nil); t.eq(code, "io_error")
  end

  state, fs = platform_log_fixture({ content = "old" })
  t.eq(fs.truncate("/var/log/xc.log"), true)
  t.eq(state.content, "")
  t.eq(state.flag_calls[1], "wronly,creat,trunc")
  t.eq(state.opens[1].flags, 32 + 131072)
  t.eq(state.opens[1].mode, 600)
  t.eq(state.chmod.path, "/var/log/xc.log"); t.eq(state.chmod.mode, 600)

  for _, options in ipairs({
    { open_error = "EIO" }, { sync_ok = false }, { close_ok = false }, { chmod_ok = false }
  }) do
    _, fs = platform_log_fixture(options)
    t.eq(fs.truncate("/var/log/xc.log"), false)
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

t.test("translation catalogs are unique complete and fully translated", function()
  local function unquote(value)
    local chunk = assert(loadstring("return " .. value))
    return chunk()
  end

  local function parse_catalog(path, require_translation)
    local entries, seen, block = {}, {}, nil
    local function finish()
      if not block then return end
      t.eq(block.fuzzy, false, path .. " fuzzy msgid " .. block.msgid)
      if block.msgid == "" then block = nil; return end
      t.eq(seen[block.msgid], nil, path .. " duplicate msgid " .. block.msgid)
      seen[block.msgid] = true
      if require_translation then
        t.truthy(block.msgstr and block.msgstr ~= "", path .. " empty msgstr " .. block.msgid)
      end
      entries[block.msgid] = block.msgstr
      block = nil
    end
    for line in (read_file(path) .. "\n"):gmatch("([^\r\n]*)\r?\n") do
      if line == "" then
        finish()
      elseif line:match("^#,") and line:match("fuzzy") then
        block = block or { msgid = "", msgstr = "", field = nil, fuzzy = false }
        block.fuzzy = true
      else
        local field, quoted = line:match("^(msgid)%s+(\".*\")$")
        if not field then field, quoted = line:match("^(msgstr)%s+(\".*\")$") end
        if field then
          block = block or { msgid = "", msgstr = "", field = nil, fuzzy = false }
          block[field], block.field = unquote(quoted), field
        elseif block and block.field and line:match('^"') then
          block[block.field] = block[block.field] .. unquote(line)
        end
      end
    end
    finish()
    return entries, seen
  end

  local required = {}
  local source_list = os.tmpname()
  t.eq(os.execute("find luasrc -type f \\( -name '*.lua' -o -name '*.htm' \\) -print > " .. source_list), 0,
    "unable to discover LuCI sources")
  local files = assert(io.open(source_list, "r"))
  for path in files:lines() do
    local source = read_file(path)
    for message in source:gmatch('translate%(%s*"([^"\r\n]+)"') do required[message] = true end
    for message in source:gmatch('_%(%s*"([^"\r\n]+)"') do required[message] = true end
    for message in source:gmatch('<%%:([^%%\r\n]+)%%>') do required[message] = true end
  end
  files:close()
  os.remove(source_list)

  local template_entries = parse_catalog("po/templates/xc.pot", false)
  local translations = parse_catalog("po/zh_Hans/xc.po", true)
  for message in pairs(required) do
    t.truthy(template_entries[message] ~= nil, "POT missing " .. message)
    t.truthy(translations[message] ~= nil, "Simplified Chinese translation missing " .. message)
  end
  for message in pairs(template_entries) do
    t.truthy(required[message], "POT contains obsolete msgid " .. message)
  end
  for message in pairs(translations) do
    t.truthy(required[message], "PO contains obsolete msgid " .. message)
  end

  local untranslated_allowlist = { XC = true, Xray = true, OK = true, UUID = true }
  for message, translation in pairs(translations) do
    if not untranslated_allowlist[message] then
      t.truthy(translation ~= message, "untranslated Simplified Chinese msgid " .. message)
    end
  end
  local canonical = {
    ["Test"] = "测速", ["Test all"] = "全部测速", ["Stop testing"] = "停止测速",
    ["Latency"] = "延迟", ["Warning"] = "警告", ["Info"] = "信息", ["Debug"] = "调试"
  }
  for message, translation in pairs(canonical) do
    t.eq(translations[message], translation, "non-canonical translation for " .. message)
  end
end)

t.test("probe and import templates translate every stable visible state and warning", function()
  local probe = read_file("luasrc/view/xc/node_table.htm")
  local import = read_file("luasrc/view/xc/import.htm")
  for _, message in ipairs({ "Error", "Failed", "Timed out", "Testing…", "Stopped", "Test" }) do
    t.contains(probe, 'translate("' .. message .. '")', "probe does not translate " .. message)
  end
  for _, literal in ipairs({
    'latency.textContent = "error"', 'socket.textContent = "fail"',
    'latency.textContent = "timeout"', 'state.textContent = "testing"',
    'state.textContent = "stopped"', '? "ok" : "fail"'
  }) do
    t.eq(probe:find(literal, 1, true), nil, "probe exposes untranslated state " .. literal)
  end
  for _, message in ipairs({
    "File read failed", "Import source is empty", "Previewing…", "Preview failed",
    "Ready", "Confirm import?", "Importing…", "Import failed", "Imported",
    "Skipped duplicate node", "Import warning"
  }) do
    t.contains(import, 'translate("' .. message .. '")', "import does not translate " .. message)
  end
  t.contains(import, '"skipped duplicate node"')
  t.eq(import:find("String(items[warningIndex])", 1, true), nil, "raw backend warning is rendered")
end)

t.test("status template translates visible states and action fallbacks", function()
  local status = read_file("luasrc/view/xc/status.htm")
  for _, message in ipairs({
    "Running", "Stopped", "Error", "Status request failed", "Invalid server response",
    "Working…", "Health testing is not implemented yet", "Operation completed", "Operation failed"
  }) do
    t.contains(status, 'translate("' .. message .. '")', "status does not translate " .. message)
  end
  for _, literal in ipairs({
    'text("xc-service-state", "error")', 'message: "Invalid server response"',
    'text("xc-action-result", "Working…")', 'data.message || "Health testing is not implemented yet"',
    'text("xc-action-result", "Operation completed")', 'data.message || data.code || "Operation failed"'
  }) do
    t.eq(status:find(literal, 1, true), nil, "status exposes untranslated literal " .. literal)
  end
  t.contains(status, 'state === "running"')
  t.contains(status, 'state === "stopped"')
  t.contains(status, 'data.code === "not_implemented"')
end)
