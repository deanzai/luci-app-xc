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
local ROLLBACK_MANIFEST_PATH = "/etc/xc/rollback/current"
local UNSET_ACTIVE_MARKER = "!xc-active-unset!"
local LOG_PATH = "/var/log/xc.log"
local XRAY_TEST = { "/usr/bin/xray", "run", "-test", "-c", RUNTIME_PATH }
local sanitize_text

local function checksum(value)
  local hash = 5381
  for index = 1, #value do hash = (hash * 33 + value:byte(index)) % 2147483647 end
  return string.format("%08x", hash)
end

local function generation_paths(generation)
  local prefix = "/etc/xc/rollback/generation-" .. generation
  return prefix .. ".config", prefix .. ".active"
end

local function manifest_for(generation, config, active)
  return table.concat({ "xc-rollback-v1", generation, tostring(#config), checksum(config), tostring(#active), checksum(active), "" }, "\n")
end

local function parse_manifest(value)
  if type(value) ~= "string" or #value > 1024 then return nil end
  local version, generation, config_size, config_hash, active_size, active_hash = value:match("^([^\n]+)\n([^\n]+)\n(%d+)\n(%x+)\n(%d+)\n(%x+)\n$")
  if version ~= "xc-rollback-v1" or not generation:match("^[0-9]+%-[0-9]+$") then return nil end
  return { generation = generation, config_size = tonumber(config_size), config_hash = config_hash, active_size = tonumber(active_size), active_hash = active_hash }
end

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
  recovery_failed = "runtime recovery failed",
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

local function active_marker(active)
  if active == nil then return UNSET_ACTIVE_MARKER end
  if not schema.safe_section_id(active) then error("invalid active node", 0) end
  return active
end

local function decode_active_marker(marker)
  if marker == UNSET_ACTIVE_MARKER then return nil, true end
  if type(marker) == "string" and schema.safe_section_id(marker) then return marker, true end
  return nil, false
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
  local temporary, handle, closed
  local ok = xpcall(function()
    handle = self.fs.write_temp(path, content)
    if type(handle) ~= "table" or type(handle.path) ~= "string" or handle.path == path then error("atomic write failed", 0) end
    temporary = handle.path
    if not action_ok(self.fs.chmod(temporary, "0600")) then error("atomic write failed", 0) end
    if not action_ok(self.fs.fsync(handle)) then error("atomic write failed", 0) end
    if not action_ok(self.fs.close(handle)) then error("atomic write failed", 0) end
    closed = true
    if not action_ok(self.fs.rename(temporary, path)) then error("atomic write failed", 0) end
    if not action_ok(self.fs.fsync_dir(path:match("^(.+)/[^/]+$"))) then error("atomic write failed", 0) end
  end, function() return false end)
  if not ok then
    if handle and not closed then pcall(self.fs.close, handle) end
    if temporary then pcall(self.fs.remove, temporary) end
    error("atomic write failed", 0)
  end
  return true
end

function Runtime:_checked_remove(path)
  if not self.fs.exists(path) then return true end
  if not action_ok(self.fs.remove(path)) then return false end
  return action_ok(self.fs.fsync_dir(path:match("^(.+)/[^/]+$")))
end

function Runtime:_load(section_id)
  local global = self.uci.get_global()
  if type(global) ~= "table" then return nil, nil, result(false, "internal_error") end
  local selected = section_id
  if selected ~= nil then
    if not schema.safe_section_id(selected) then return nil, nil, result(false, "invalid_node") end
  else
    selected = global.active_node
    if selected ~= nil then
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
  local health_timeout = tonumber(generation_global.health_timeout)
  if type(generation_global.health_url) ~= "string" or #generation_global.health_url > 2048
    or not generation_global.health_url:match("^https?://") or generation_global.health_url:find("[%z\1-\31\127]")
    or not health_timeout or health_timeout < 1 or health_timeout > 30 then
    return nil, nil, result(false, "generation_failed")
  end
  generation_global.health_timeout = health_timeout
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
  local function render_operation()
    local encoded, node_id, encode_error = self:_encode(section_id)
    if encode_error then return encode_error end
    self:_atomic_write(output_path, encoded)
    return result(true, "rendered", { node = node_id, path = output_path })
  end
  if output_path == RUNTIME_PATH then return self:_with_lock("render", render_operation) end
  local ok, value = xpcall(render_operation, function() return result(false, "internal_error") end)
  return value
end

function Runtime:_with_lock(operation, fn)
  local acquired, lock = pcall(self.fs.acquire_lock, LOCK_PATH)
  if not acquired then self.last_error = "lock_error"; return result(false, "internal_error") end
  if not lock then return result(false, "busy") end
  self.operation = operation
  local ok, value = xpcall(fn, function() return result(false, "internal_error") end)
  local release_call, release_value = pcall(self.fs.release_lock, lock)
  self.operation = nil
  if not release_call or not action_ok(release_value) then self.last_error = "lock_release_failed"; return result(false, "internal_error") end
  if not ok then self.last_error = value.code end
  return value
end

function Runtime:_apply_active(active)
  local changed
  if active == nil then changed = self.uci.clear_active()
  elseif not schema.safe_section_id(active) then return false
  else changed = self.uci.set_active(active) end
  if not action_ok(changed) or not action_ok(self.uci.commit()) then return false end
  return true
end

function Runtime:_readiness(global)
  local address = self.network()
  local socks_port, http_port = global.socks_port, global.http_port
  local health_url, timeout = global.health_url, tonumber(global.health_timeout)
  if type(health_url) ~= "string" or #health_url > 2048 or not health_url:match("^https?://") or health_url:find("[%z\1-\31\127]") or not timeout or timeout < 1 or timeout > 30 then return "health_failed" end
  local deadline = self.now() + timeout
  local listeners_ready = false
  for attempt = 1, 10 do
    local socks_ready = action_ok(self.exec.listener_ready("socks", address, socks_port, deadline))
    local http_ready = action_ok(self.exec.listener_ready("http", address, http_port, deadline))
    if socks_ready and http_ready then listeners_ready = true; break end
    if attempt < 10 then self.sleep(1) end
  end
  if not listeners_ready then return "listener_failed" end
  local socks_healthy = action_ok(self.exec.health_check("socks", address, socks_port, health_url, deadline))
  local http_healthy = action_ok(self.exec.health_check("http", address, http_port, health_url, deadline))
  if not socks_healthy or not http_healthy then return "health_failed" end
end

function Runtime:_restore_previous(context, failure_code)
  if context.old_config ~= nil then
    self:_atomic_write(RUNTIME_PATH, context.old_config)
  else
    if not self:_checked_remove(RUNTIME_PATH) then return result(false, "recovery_failed") end
  end
  if not self:_apply_active(context.old_active) then error("restore failed", 0) end
  if context.old_config ~= nil then
    if not action_ok(self.exec.restart()) then error("restore failed", 0) end
  else
    if not action_ok(self.exec.stop()) then return result(false, "recovery_failed", { service = "unknown" }) end
  end
  if context.generation_config and not self:_checked_remove(context.generation_config) then
    local stopped = action_ok(self.exec.stop()); return result(false, "recovery_failed", { service = stopped and "stopped" or "unknown" })
  end
  if context.generation_active and not self:_checked_remove(context.generation_active) then
    local stopped = action_ok(self.exec.stop()); return result(false, "recovery_failed", { service = stopped and "stopped" or "unknown" })
  end
  if context.old_config ~= nil then return result(false, failure_code) end
  return result(false, failure_code .. "_no_previous_config", {
    message = (messages[failure_code] or messages.internal_error) .. "; service stopped because no previous configuration exists"
  })
end

function Runtime:_best_effort_restore(context)
  if context.old_config ~= nil then self:_atomic_write(RUNTIME_PATH, context.old_config)
  elseif not self:_checked_remove(RUNTIME_PATH) then error("recovery failed", 0) end
  if not self:_apply_active(context.old_active) then error("recovery failed", 0) end
  if context.old_config ~= nil then
    if not action_ok(self.exec.restart()) then error("recovery failed", 0) end
  elseif not action_ok(self.exec.stop()) then error("recovery failed", 0) end
end

function Runtime:_restore_rollback_generation(context)
  if context.prior_manifest ~= nil then self:_atomic_write(ROLLBACK_MANIFEST_PATH, context.prior_manifest)
  elseif not self:_checked_remove(ROLLBACK_MANIFEST_PATH) then error("manifest recovery failed", 0) end
end

function Runtime:_promote_pending_snapshot(context)
  context.promotion_started = true
  if context.old_config == nil then
    if not self:_checked_remove(ROLLBACK_MANIFEST_PATH) then error("snapshot promotion failed", 0) end
    return
  end
  self:_atomic_write(ROLLBACK_MANIFEST_PATH, context.new_manifest)
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
  context.prior_manifest = self.fs.read(ROLLBACK_MANIFEST_PATH, 1024)
  if context.old_config ~= nil then
    self.sequence = self.sequence + 1
    context.generation = tostring(self.now()) .. "-" .. tostring(self.sequence)
    context.generation_config, context.generation_active = generation_paths(context.generation)
    local marker = active_marker(context.old_active)
    self:_atomic_write(context.generation_config, context.old_config)
    self:_atomic_write(context.generation_active, marker)
    context.new_manifest = manifest_for(context.generation, context.old_config, marker)
  end
  if not action_ok(self.fs.rename(CANDIDATE_PATH, RUNTIME_PATH)) then error("runtime replace failed", 0) end
  context.replaced = true

  if not action_ok(self.exec.restart()) then return self:_restore_previous(context, "restart_failed") end
  local readiness_error = self:_readiness(global)
  if readiness_error then return self:_restore_previous(context, readiness_error) end
  if not self:_apply_active(node_id) then
    return self:_restore_previous(context, "commit_failed")
  end
  self:_promote_pending_snapshot(context)
  context.replaced = false
  return result(true, "switched", { node = node_id })
end

function Runtime:switch(section_id)
  return self:_with_lock("switch", function()
    local context = { replaced = false }
    local ok, value = xpcall(function() return self:_switch_locked(section_id, context) end, function() return result(false, "internal_error") end)
    if not ok then
      local recovery_ok = true
      if context.replaced then recovery_ok = pcall(function() self:_best_effort_restore(context) end) end
      if context.promotion_started then recovery_ok = pcall(function() self:_restore_rollback_generation(context) end) and recovery_ok end
      if context.generation_config then recovery_ok = self:_checked_remove(context.generation_config) and recovery_ok end
      if context.generation_active then recovery_ok = self:_checked_remove(context.generation_active) and recovery_ok end
      if not recovery_ok then
        local stopped = action_ok(self.exec.stop())
        return result(false, "recovery_failed", { service = stopped and "stopped" or "unknown" })
      end
    end
    return value
  end)
end

function Runtime:_restore_rollback_attempt(context, failure_code)
  if context.pre_config ~= nil then self:_atomic_write(RUNTIME_PATH, context.pre_config)
  elseif not self:_checked_remove(RUNTIME_PATH) then error("rollback recovery failed", 0) end
  if not self:_apply_active(context.pre_active) then error("rollback recovery failed", 0) end
  if context.pre_config ~= nil then
    if not action_ok(self.exec.restart()) then error("rollback recovery failed", 0) end
  else
    if not action_ok(self.exec.stop()) then error("rollback recovery failed", 0) end
  end
  context.installed = false
  return result(false, failure_code)
end

function Runtime:_best_effort_restore_rollback(context)
  if context.pre_config ~= nil then self:_atomic_write(RUNTIME_PATH, context.pre_config)
  elseif not self:_checked_remove(RUNTIME_PATH) then error("recovery failed", 0) end
  if not self:_apply_active(context.pre_active) then error("recovery failed", 0) end
  if context.pre_config ~= nil then
    if not action_ok(self.exec.restart()) then error("recovery failed", 0) end
  elseif not action_ok(self.exec.stop()) then error("recovery failed", 0) end
end

function Runtime:_rollback_locked(context)
  if not self.fs.exists(ROLLBACK_MANIFEST_PATH) then
    return result(false, "no_rollback_state")
  end
  local manifest_text = self.fs.read(ROLLBACK_MANIFEST_PATH, 1024)
  local manifest = parse_manifest(manifest_text)
  if not manifest or manifest.config_size > 1048576 or manifest.active_size > 256 then return result(false, "no_rollback_state") end
  local config_path, active_path = generation_paths(manifest.generation)
  local config = self.fs.read(config_path, 1048576)
  local marker = self.fs.read(active_path, 256)
  if type(config) ~= "string" or type(marker) ~= "string" or #config ~= manifest.config_size or checksum(config) ~= manifest.config_hash or #marker ~= manifest.active_size or checksum(marker) ~= manifest.active_hash then
    return result(false, "no_rollback_state")
  end
  local node_id, marker_ok = decode_active_marker(marker)
  if type(config) ~= "string" or not marker_ok then
    return result(false, "no_rollback_state")
  end
  local global = self.uci.get_global()
  if type(global) ~= "table" then return result(false, "internal_error") end
  context.pre_config = self.fs.read(RUNTIME_PATH)
  context.pre_active = global.active_node
  local validation_argv = { XRAY_TEST[1], XRAY_TEST[2], XRAY_TEST[3], XRAY_TEST[4], config_path }
  if not action_ok(self.exec.run(validation_argv)) then return result(false, "validation_failed") end
  self:_atomic_write(RUNTIME_PATH, config)
  context.installed = true
  if not action_ok(self.exec.restart()) then return self:_restore_rollback_attempt(context, "restart_failed") end
  local readiness_error = self:_readiness(global)
  if readiness_error then return self:_restore_rollback_attempt(context, readiness_error) end
  if not self:_apply_active(node_id) then return self:_restore_rollback_attempt(context, "commit_failed") end
  if not self:_checked_remove(ROLLBACK_MANIFEST_PATH) then return self:_restore_rollback_attempt(context, "internal_error") end
  context.installed = false
  local extra = {}
  if node_id ~= nil then extra.node = node_id else extra.active_node_unset = true end
  return result(true, "rolled_back", extra)
end

function Runtime:rollback()
  return self:_with_lock("rollback", function()
    local context = { installed = false }
    local ok, value = xpcall(function() return self:_rollback_locked(context) end, function() return result(false, "internal_error") end)
    if not ok and context.installed then
      local recovered = pcall(function() self:_best_effort_restore_rollback(context) end)
      if not recovered then
        local stopped = action_ok(self.exec.stop())
        return result(false, "recovery_failed", { service = stopped and "stopped" or "unknown" })
      end
    end
    return value
  end)
end

function Runtime:status()
  local ok, value = xpcall(function()
    local global = self.uci.get_global()
    if type(global) ~= "table" then return result(false, "internal_error") end
    local active = global.active_node
    local safe_active = type(active) == "string" and schema.safe_section_id(active) and active or nil
    local active_state = active == nil and "unset" or (safe_active and "selected" or "invalid")
    local service = self.exec.service_state(self.now() + 2)
    if service ~= "running" and service ~= "stopped" and service ~= "error" then service = "unknown" end
    local address = self.network()
    local listener_deadline = self.now() + 2
    local listeners = {
      socks = action_ok(self.exec.listener_ready("socks", address, tonumber(global.socks_port), listener_deadline)),
      http = action_ok(self.exec.listener_ready("http", address, tonumber(global.http_port), listener_deadline))
    }
    local output = result(true, "status", {
      active_node = safe_active,
      active_state = active_state,
      runtime_config = self.fs.exists(RUNTIME_PATH),
      service = service, operation = self.operation or "idle", lock = self.operation and "held" or "unlocked",
      listen = { address = sanitize_text(address, 64), socks_port = tonumber(global.socks_port), http_port = tonumber(global.http_port) },
      listeners = listeners,
      last_error = self.last_error
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
  value = value:gsub("%-%-%-%-%-[Bb][Ee][Gg][Ii][Nn] [Pp][Rr][Ii][Vv][Aa][Tt][Ee] [Kk][Ee][Yy]%-%-%-%-%-.-%-%-%-%-%-[Ee][Nn][Dd] [Pp][Rr][Ii][Vv][Aa][Tt][Ee] [Kk][Ee][Yy]%-%-%-%-%-", "[redacted]")
  value = value:gsub("%a[%w+%.%-]*://[^%s]+", "[redacted]")
  value = value:gsub("%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x", "[redacted]")
  value = value:gsub("[Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]%s*[:=]%s*[^%s,;]+", "password=[redacted]")
  value = value:gsub("[Pp][Aa][Ss][Ss][Ww][Dd]%s*[:=]%s*[^%s,;]+", "passwd=[redacted]")
  value = value:gsub("[Tt][Oo][Kk][Ee][Nn]%s*[:=]%s*[^%s,;]+", "token=[redacted]")
  value = value:gsub("[Ss][Ee][Cc][Rr][Ee][Tt]%s*[:=]%s*[^%s,;]+", "secret=[redacted]")
  value = value:gsub("[Aa][Pp][Ii][_-][Kk][Ee][Yy]%s*[:=]%s*[^%s,;]+", "api_key=[redacted]")
  value = value:gsub("[Pp][Rr][Ii][Vv][Aa][Tt][Ee][_-][Kk][Ee][Yy]%s*[:=]%s*[^%s,;]+", "private_key=[redacted]")
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
    local current = self.fs.read(LOG_PATH, 262144) or ""
    local combined = current .. encoded .. "\n"
    if #combined > 262144 then combined = combined:sub(#combined - 262144 + 1) end
    self:_atomic_write(LOG_PATH, combined)
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
  local methods = {
    uci = { "get_global", "get_node", "list_nodes", "set_active", "clear_active", "commit", "revert" },
    fs = { "acquire_lock", "release_lock", "read", "write_temp", "chmod", "fsync", "fsync_dir", "close", "rename", "exists", "remove" },
    exec = { "run", "restart", "stop", "listener_ready", "health_check", "service_state" },
    json = { "stringify" }
  }
  for adapter, names in pairs(methods) do
    for _, name in ipairs(names) do if type(adapters[adapter][name]) ~= "function" then return nil, "invalid runtime adapters" end end
  end
  return setmetatable({
    uci = adapters.uci, fs = adapters.fs, exec = adapters.exec, json = adapters.json,
    network = adapters.network, now = adapters.now, sleep = adapters.sleep, sequence = 0
  }, Runtime)
end

M.paths = {
  lock = LOCK_PATH, runtime = RUNTIME_PATH, candidate = CANDIDATE_PATH,
  rollback = ROLLBACK_PATH, rollback_node = ROLLBACK_NODE_PATH,
  rollback_manifest = ROLLBACK_MANIFEST_PATH,
  log = LOG_PATH
}
M.unset_active_marker = UNSET_ACTIVE_MARKER

return M
