local generator = require "xc.generator"
local schema = require "xc.schema"

local M = {}
local Runtime = {}
Runtime.__index = Runtime

local LOCK_PATH = "/var/lock/xc.lock"
local RUNTIME_PATH = "/var/etc/xc/config.json"
local CANDIDATE_PATH = RUNTIME_PATH .. ".candidate"
local ROLLBACK_PATH = "/etc/xc/rollback/config.json"
local ROLLBACK_NODE_PATH = "/etc/xc/rollback/active_node"
local LOG_PATH = "/var/log/xc.log"
local XRAY_TEST = { "/usr/bin/xray", "run", "-test", "-c", RUNTIME_PATH }
local sanitize_text

local messages = {
  rendered = "configuration rendered",
  switched = "node switched",
  rolled_back = "rollback restored",
  busy = "another runtime operation is in progress",
  invalid_node = "invalid node identifier",
  missing_node = "selected node does not exist",
  disabled_node = "selected node is disabled",
  active_node_required = "an active node must be selected",
  no_enabled_nodes = "no enabled nodes are available",
  invalid_output = "invalid output path",
  generation_failed = "configuration generation failed",
  encoding_failed = "configuration encoding failed",
  validation_failed = "Xray rejected the candidate configuration",
  restart_failed = "Xray service restart failed",
  listener_failed = "Xray listeners did not become ready",
  health_failed = "proxy health checks failed",
  commit_failed = "active node could not be committed",
  no_rollback_state = "no rollback state is available",
  missing_runtime = "runtime configuration is missing",
  test_passed = "runtime configuration is valid",
  test_failed = "runtime configuration is invalid",
  internal_error = "runtime operation failed",
  logged = "log entry appended"
}
messages.status = "runtime status"

local function result(ok, code, extra)
  local value = { ok = ok, code = code, message = messages[code] or "runtime operation failed" }
  for key, item in pairs(extra or {}) do value[key] = item end
  return value
end

local function action_ok(value)
  if value == false or value == nil then return false end
  if type(value) == "number" then return value == 0 end
  if type(value) == "table" and value.ok ~= nil then return value.ok == true end
  return true
end

local function enabled(value)
  return value == true or value == 1 or value == "1"
end

local function shallow_copy(value)
  local output = {}
  for key, item in pairs(value or {}) do output[key] = item end
  return output
end

local function valid_output_path(path)
  if type(path) ~= "string" or #path < 2 or #path > 512 or path:sub(1, 1) ~= "/" then return false end
  if path:find("[%z\1-\31\127]") or path:find("/%.%./") or path:match("/%.%.$") then return false end
  return true
end

function Runtime:_atomic_write(path, content)
  local temporary = path .. ".tmp." .. tostring(self.now())
  local handle, closed
  local ok = xpcall(function()
    handle = self.fs.write_temp(temporary, content)
    if not handle then error("atomic write failed", 0) end
    if not action_ok(self.fs.chmod(temporary, "0600")) then error("atomic write failed", 0) end
    if not action_ok(self.fs.fsync(handle)) then error("atomic write failed", 0) end
    if not action_ok(self.fs.close(handle)) then error("atomic write failed", 0) end
    closed = true
    if not action_ok(self.fs.rename(temporary, path)) then error("atomic write failed", 0) end
  end, function() return false end)
  if not ok then
    if handle and not closed then pcall(self.fs.close, handle) end
    pcall(self.fs.remove, temporary)
    error("atomic write failed", 0)
  end
  return true
end

function Runtime:_load(section_id)
  local global = self.uci.get_global()
  if type(global) ~= "table" then return nil, nil, result(false, "internal_error") end
  local selected = section_id
  if selected ~= nil and selected ~= "" and not schema.safe_section_id(selected) then
    return nil, nil, result(false, "invalid_node")
  end
  if selected == nil or selected == "" then
    selected = global.active_node
    if selected ~= nil and selected ~= "" then
      if not schema.safe_section_id(selected) then return nil, nil, result(false, "invalid_node") end
    else
      local available = {}
      for _, candidate in ipairs(self.uci.list_nodes() or {}) do
        if type(candidate) == "table" and enabled(candidate.enabled) then available[#available + 1] = candidate end
      end
      if #available == 0 then return nil, nil, result(false, "no_enabled_nodes") end
      if #available ~= 1 then return nil, nil, result(false, "active_node_required") end
      selected = available[1].id
    end
  end
  if not schema.safe_section_id(selected) then return nil, nil, result(false, "invalid_node") end
  local node = self.uci.get_node(selected)
  if type(node) ~= "table" then return nil, nil, result(false, "missing_node") end
  if not enabled(node.enabled) then return nil, nil, result(false, "disabled_node") end
  local normalized_input = shallow_copy(node)
  normalized_input.enabled = true
  normalized_input.id = selected
  local normalized = schema.normalize(normalized_input)
  if not normalized then return nil, nil, result(false, "generation_failed") end
  local generation_global = shallow_copy(global)
  generation_global.listen_address = self.network()
  return generation_global, normalized, nil
end

function Runtime:_encode(section_id)
  local global, node, load_error = self:_load(section_id)
  if load_error then return nil, nil, load_error end
  local config = generator.build(global, node)
  if not config then return nil, nil, result(false, "generation_failed") end
  local encoded = generator.encode(config, self.json)
  if not encoded then return nil, nil, result(false, "encoding_failed") end
  return encoded, node.id, nil
end

function Runtime:render(section_id, output_path)
  if not valid_output_path(output_path) then return result(false, "invalid_output") end
  local ok, value = xpcall(function()
    local encoded, node_id, encode_error = self:_encode(section_id)
    if encode_error then return encode_error end
    self:_atomic_write(output_path, encoded)
    return result(true, "rendered", { node = node_id, path = output_path })
  end, function() return result(false, "internal_error") end)
  if not ok then return value end
  return value
end

function Runtime:_restore_previous(context, failure_code)
  if context.old_config ~= nil then
    self:_atomic_write(RUNTIME_PATH, context.old_config)
  else
    pcall(self.fs.remove, RUNTIME_PATH)
  end
  if context.old_active ~= nil and context.old_active ~= "" then
    if not action_ok(self.uci.set_active(context.old_active)) then error("restore failed", 0) end
    if not action_ok(self.uci.commit()) then error("restore failed", 0) end
  else
    self.uci.revert()
  end
  if context.old_config ~= nil then
    if not action_ok(self.exec.restart()) then error("restore failed", 0) end
    return result(false, failure_code)
  end
  self.exec.stop()
  return result(false, failure_code .. "_no_previous_config", {
    message = (messages[failure_code] or messages.internal_error) .. "; service stopped because no previous configuration exists"
  })
end

function Runtime:_best_effort_restore(context)
  pcall(function()
    if context.old_config ~= nil then self:_atomic_write(RUNTIME_PATH, context.old_config)
    else self.fs.remove(RUNTIME_PATH) end
  end)
  pcall(function()
    if context.old_active ~= nil and context.old_active ~= "" then
      self.uci.set_active(context.old_active)
      self.uci.commit()
    else
      self.uci.revert()
    end
  end)
  if context.old_config ~= nil then pcall(self.exec.restart) else pcall(self.exec.stop) end
end

function Runtime:_switch_locked(section_id, context)
  local encoded, node_id, encode_error = self:_encode(section_id)
  if encode_error then return encode_error end
  self:_atomic_write(CANDIDATE_PATH, encoded)
  local validation_argv = { XRAY_TEST[1], XRAY_TEST[2], XRAY_TEST[3], XRAY_TEST[4], CANDIDATE_PATH }
  if not action_ok(self.exec.run(validation_argv)) then
    self.fs.remove(CANDIDATE_PATH)
    return result(false, "validation_failed")
  end

  local global = self.uci.get_global()
  if type(global) ~= "table" then error("invalid UCI state", 0) end
  context.old_active = global.active_node
  context.old_config = self.fs.read(RUNTIME_PATH)
  if context.old_config ~= nil then
    self:_atomic_write(ROLLBACK_PATH, context.old_config)
  else
    pcall(self.fs.remove, ROLLBACK_PATH)
  end
  self:_atomic_write(ROLLBACK_NODE_PATH, context.old_active or "")
  if not action_ok(self.fs.rename(CANDIDATE_PATH, RUNTIME_PATH)) then error("runtime replace failed", 0) end
  context.replaced = true

  if not action_ok(self.exec.restart()) then return self:_restore_previous(context, "restart_failed") end
  local address = self.network()
  local socks_port, http_port = global.socks_port, global.http_port
  local listeners_ready = false
  for attempt = 1, 10 do
    local socks_ready = action_ok(self.exec.listener_ready("socks", address, socks_port))
    local http_ready = action_ok(self.exec.listener_ready("http", address, http_port))
    if socks_ready and http_ready then listeners_ready = true; break end
    if attempt < 10 then self.sleep(1) end
  end
  if not listeners_ready then
    return self:_restore_previous(context, "listener_failed")
  end
  local socks_healthy = action_ok(self.exec.health_check("socks", address, socks_port))
  local http_healthy = action_ok(self.exec.health_check("http", address, http_port))
  if not socks_healthy or not http_healthy then
    return self:_restore_previous(context, "health_failed")
  end
  if not action_ok(self.uci.set_active(node_id)) or not action_ok(self.uci.commit()) then
    pcall(self.uci.revert)
    return self:_restore_previous(context, "commit_failed")
  end
  context.replaced = false
  return result(true, "switched", { node = node_id })
end

function Runtime:switch(section_id)
  local lock = self.fs.acquire_lock(LOCK_PATH)
  if not lock then return result(false, "busy") end
  local context = { replaced = false }
  local ok, value = xpcall(function() return self:_switch_locked(section_id, context) end, function()
    return result(false, "internal_error")
  end)
  if not ok then
    pcall(self.fs.remove, CANDIDATE_PATH)
    if context.replaced then self:_best_effort_restore(context) end
  end
  local released = pcall(self.fs.release_lock, lock)
  if not released then return result(false, "internal_error") end
  return value
end

function Runtime:_rollback_locked()
  if not self.fs.exists(ROLLBACK_PATH) or not self.fs.exists(ROLLBACK_NODE_PATH) then
    return result(false, "no_rollback_state")
  end
  local config = self.fs.read(ROLLBACK_PATH)
  local node_id = self.fs.read(ROLLBACK_NODE_PATH)
  if type(config) ~= "string" or type(node_id) ~= "string" or not schema.safe_section_id(node_id) then
    return result(false, "no_rollback_state")
  end
  self:_atomic_write(RUNTIME_PATH, config)
  if not action_ok(self.uci.set_active(node_id)) or not action_ok(self.uci.commit()) then
    pcall(self.uci.revert)
    return result(false, "commit_failed")
  end
  if not action_ok(self.exec.restart()) then return result(false, "restart_failed") end
  self.fs.remove(ROLLBACK_PATH)
  self.fs.remove(ROLLBACK_NODE_PATH)
  return result(true, "rolled_back", { node = node_id })
end

function Runtime:rollback()
  local lock = self.fs.acquire_lock(LOCK_PATH)
  if not lock then return result(false, "busy") end
  local ok, value = xpcall(function() return self:_rollback_locked() end, function()
    return result(false, "internal_error")
  end)
  local released = pcall(self.fs.release_lock, lock)
  if not released then return result(false, "internal_error") end
  return value
end

function Runtime:status()
  local ok, value = xpcall(function()
    local global = self.uci.get_global()
    if type(global) ~= "table" then return result(false, "internal_error") end
    local active = global.active_node
    local safe_active = type(active) == "string" and schema.safe_section_id(active) and active or nil
    local output = result(true, "status", {
      active_node = safe_active,
      runtime_config = self.fs.exists(RUNTIME_PATH)
    })
    if safe_active then
      local node = self.uci.get_node(safe_active)
      if type(node) == "table" then
        output.node = {
          id = safe_active,
          name = sanitize_text(node.name or "", 128),
          protocol = schema.supported_protocols[node.protocol] and node.protocol or nil,
          enabled = enabled(node.enabled)
        }
      end
    end
    return output
  end, function() return result(false, "internal_error") end)
  if not ok then return value end
  return value
end

function Runtime:test_current()
  local ok, value = xpcall(function()
    if not self.fs.exists(RUNTIME_PATH) then return result(false, "missing_runtime") end
    local argv = { XRAY_TEST[1], XRAY_TEST[2], XRAY_TEST[3], XRAY_TEST[4], XRAY_TEST[5] }
    if action_ok(self.exec.run(argv)) then return result(true, "test_passed") end
    return result(false, "test_failed")
  end, function() return result(false, "internal_error") end)
  if not ok then return value end
  return value
end

sanitize_text = function(value, maximum)
  if type(value) ~= "string" then value = tostring(value) end
  value = value:sub(1, 8192)
  value = value:gsub("%b{}", "[redacted]"):gsub("%b[]", "[redacted]")
  value = value:gsub("%a[%w+%.%-]*://[^%s]+", function(url)
    local scheme = url:match("^(%a[%w+%.%-]*):")
    scheme = scheme and scheme:lower() or ""
    if scheme == "vless" or scheme == "vmess" or scheme == "trojan" or scheme == "ss" or scheme == "socks" then
      return "[redacted]"
    end
    if url:find("@", 1, true) or url:find("?", 1, true) or url:find("#", 1, true) then return "[redacted]" end
    return url
  end)
  value = value:gsub("%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x", "[redacted]")
  value = value:gsub("[Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]%s*[:=]%s*[^%s,;]+", "password=[redacted]")
  return value:sub(1, maximum or 256)
end

local function sensitive_key(key)
  local lowered = key:lower()
  for _, fragment in ipairs({ "password", "passwd", "uuid", "secret", "token", "credential", "userinfo", "share", "link", "uri", "url", "raw", "content", "config" }) do
    if lowered:find(fragment, 1, true) then return true end
  end
  return false
end

function Runtime:log(message, fields)
  local ok, value = xpcall(function()
    local safe_fields, count = {}, 0
    if type(fields) == "table" then
      local keys = {}
      for key in pairs(fields) do
        if type(key) == "string" and key:match("^[A-Za-z0-9_.-]+$") then keys[#keys + 1] = key end
      end
      table.sort(keys)
      for _, key in ipairs(keys) do
        if count >= 16 then break end
        local safe_key = key:sub(1, 64)
        local field = fields[key]
        if sensitive_key(key) then safe_fields[safe_key] = "[redacted]"
        elseif type(field) == "string" or type(field) == "number" or type(field) == "boolean" then
          safe_fields[safe_key] = sanitize_text(field, 128)
        else
          safe_fields[safe_key] = "[redacted]"
        end
        count = count + 1
      end
    end
    local entry = { time = self.now(), message = sanitize_text(message, 512), fields = safe_fields }
    local encoded = generator.encode(entry, self.json)
    if type(encoded) ~= "string" then encoded = '{"message":"log entry redacted"}' end
    if #encoded > 2047 then encoded = '{"message":"log entry truncated"}' end
    if not action_ok(self.fs.append(LOG_PATH, encoded .. "\n")) then return result(false, "internal_error") end
    return result(true, "logged")
  end, function() return result(false, "internal_error") end)
  if not ok then return value end
  return value
end

function M.new(adapters)
  if type(adapters) ~= "table" then return nil, "invalid runtime adapters" end
  local required_tables = { "uci", "fs", "exec", "json" }
  for _, name in ipairs(required_tables) do if type(adapters[name]) ~= "table" then return nil, "invalid runtime adapters" end end
  for _, name in ipairs({ "network", "now", "sleep" }) do if type(adapters[name]) ~= "function" then return nil, "invalid runtime adapters" end end
  return setmetatable({
    uci = adapters.uci, fs = adapters.fs, exec = adapters.exec, json = adapters.json,
    network = adapters.network, now = adapters.now, sleep = adapters.sleep
  }, Runtime)
end

M.paths = {
  lock = LOCK_PATH, runtime = RUNTIME_PATH, candidate = CANDIDATE_PATH,
  rollback = ROLLBACK_PATH, rollback_node = ROLLBACK_NODE_PATH, log = LOG_PATH
}

return M
