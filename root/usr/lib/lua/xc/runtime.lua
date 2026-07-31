local generator = require "xc.generator"
local schema = require "xc.schema"
local core = require "xc.core"

local M = {}
local Runtime = {}
Runtime.__index = Runtime

local LOCK_PATH = "/var/lock/xc.lock"
local RUNTIME_PATH = "/var/etc/xc/config.json"
local CANDIDATE_PATH = "/var/etc/xc/candidate.json"
local ROLLBACK_PATH = "/etc/xc/rollback/config.json"
local ROLLBACK_NODE_PATH = "/etc/xc/rollback/active_node"
local ROLLBACK_MANIFEST_PATH = "/etc/xc/rollback/current"
local STATUS_PATH = "/var/run/xc-status"
local TRANSACTION_PATH = "/etc/xc/rollback/transaction"
local MIGRATION_CANDIDATE_PATH = "/var/etc/xc/migration-candidate.json"
local MIGRATION_MARKER_PATH = "/etc/xc/migration-complete"
local UNSET_ACTIVE_MARKER = "!xc-active-unset!"
local LOG_PATH = "/var/log/xc.log"
local LOG_LOCK_PATH = "/var/lock/xc-log.lock"
local EXIT_IP_CACHE_PATH = "/var/etc/xc/exit-ip-cache"
local EXIT_IP_CACHE_TTL = 60
local LOG_LEVEL_DEBUG = "debug"
local LOG_LEVEL_INFO = "info"
local LOG_LEVEL_ERROR = "error"
local VALIDATION_TIMEOUT = 30
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
  if version ~= "xc-rollback-v1" or #generation > 64 or not generation:match("^[0-9A-Za-z_-]+$") then return nil end
  return { generation = generation, config_size = tonumber(config_size), config_hash = config_hash, active_size = tonumber(active_size), active_hash = active_hash }
end

local function valid_token(value)
  return type(value) == "string" and #value > 0 and #value <= 64 and value:match("^[0-9A-Za-z_-]+$") ~= nil
end

local TRANSACTION_PHASES = {
  install_intent = true, candidate_healthy = true, uci_committed = true,
  cleanup_pending = true, recovery_intent = true, recovery_done = true, finalize = true
}

local function parse_transaction(value)
  if type(value) ~= "string" or #value > 1024 or value:sub(-1) ~= "\n" then return nil end
  local fields = {}
  for line in value:gmatch("([^\n]*)\n") do fields[#fields + 1] = line end
  if #fields ~= 17 or fields[1] ~= "xc-transaction-v2" or not valid_token(fields[2])
    or not valid_token(fields[5]) or fields[2] ~= fields[5]
    or (fields[3] ~= "switch" and fields[3] ~= "rollback") or not TRANSACTION_PHASES[fields[4]]
    or (fields[6] ~= "-" and not valid_token(fields[6]))
    or (fields[17] ~= "-" and not valid_token(fields[17]))
    or (fields[7] ~= "0" and fields[7] ~= "1")
    or not fields[9]:match("^%x%x%x%x%x%x%x%x$") or not fields[11]:match("^%x%x%x%x%x%x%x%x$")
    or not fields[13]:match("^%x%x%x%x%x%x%x%x$") or not fields[15]:match("^%x%x%x%x%x%x%x%x$")
    or (fields[16] ~= "running" and fields[16] ~= "stopped" and fields[16] ~= "unknown") then return nil end
  local numbers = {}
  for _, index in ipairs({ 8, 10, 12, 14 }) do
    numbers[index] = tonumber(fields[index])
    local maximum = (index == 8 or index == 12) and 1048576 or 256
    if not numbers[index] or numbers[index] < 0 or numbers[index] > maximum then return nil end
  end
  return {
    token = fields[2], kind = fields[3], phase = fields[4], generation = fields[5],
    target_generation = fields[6] ~= "-" and fields[6] or nil, old_present = fields[7] == "1",
    old_size = numbers[8], old_hash = fields[9], old_active_size = numbers[10], old_active_hash = fields[11],
    new_size = numbers[12], new_hash = fields[13], new_active_size = numbers[14], new_active_hash = fields[15],
    old_service = fields[16], prior_generation = fields[17] ~= "-" and fields[17] or nil
  }
end

local function transaction_text(context, phase)
  return table.concat({
    "xc-transaction-v2", context.generation, context.kind, phase, context.generation,
    context.target_generation or "-", context.old_config ~= nil and "1" or "0",
    tostring(#(context.old_config or "")), checksum(context.old_config or ""),
    tostring(#context.old_marker), checksum(context.old_marker), tostring(#context.new_config), checksum(context.new_config),
    tostring(#context.new_marker), checksum(context.new_marker), context.old_service or "unknown",
    context.prior_generation or "-", ""
  }, "\n")
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
  commit_unknown = "active node commit result is unknown",
  no_rollback_state = "no rollback state is available",
  missing_runtime = "runtime configuration is missing",
  test_passed = "runtime configuration is valid",
  test_failed = "runtime configuration is invalid",
  internal_error = "runtime operation failed",
  recovery_failed = "runtime recovery failed",
  recovered = "pending runtime transaction recovered",
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

local function selected_xray(self)
  local fs = self.fs
  local marker_path = core.marker_path("current")
  local marker_text, read_error = fs.read(marker_path, 128)
  if marker_text == nil and read_error == "missing" then return core.system_path() end
  local marker = core.read_marker(marker_text)
  local path = marker and core.resolve_executable(marker) or nil
  if not path then return nil end
  if marker == "system" then return path end
  if type(fs.stat_nofollow) ~= "function" or type(self.json.parse) ~= "function"
    or type(self.exec.machine) ~= "function" or type(self.exec.hash_file) ~= "function" then return nil end
  local stat_called, stat = pcall(fs.stat_nofollow, path)
  if not stat_called or type(stat) ~= "table" or stat.type ~= "reg" then return nil end
  local manifest_called, manifest_text = pcall(fs.read, core.manifest_path(marker), core.MANIFEST_MAX_SIZE)
  if not manifest_called or type(manifest_text) ~= "string" then return nil end
  local parsed_called, manifest = pcall(core.parse_manifest, manifest_text, self.json.parse)
  if not parsed_called or not manifest or manifest.id ~= marker or tonumber(stat.size) ~= manifest.size then return nil end
  local machine_called, machine_value = pcall(self.exec.machine, self.now() + 5)
  if not machine_called or core.normalize_arch(machine_value) ~= manifest.arch then return nil end
  local hash_called, actual_hash = pcall(self.exec.hash_file, path, self.now() + 30)
  if not hash_called or not core.safe_sha256(actual_hash) or actual_hash:lower() ~= manifest.sha256 then return nil end
  return path
end

local function enabled(value)
  return value == true or value == 1 or value == "1"
end

local function read_node(uci, section_id)
  local node, outcome = uci.get_node(section_id)
  if outcome == "ok" and type(node) == "table" then return node end
  if outcome == "missing" and node == nil then return nil, "missing_node" end
  return nil, "internal_error"
end

function Runtime:_xray_test_argv(config_path)
  local path = selected_xray(self)
  if not path then return nil end
  return { path, "run", "-test", "-c", config_path }
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
    pcall(self.fs.fsync_dir, path:match("^(.+)/[^/]+$"))
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

function Runtime:_trash_generation(generation)
  if not generation then return true end
  local trash = self.fs.trash_generation("/etc/xc/rollback", generation)
  -- The adapter contract makes the generation token the stable trash token.
  if trash ~= generation then return false end
  if not action_ok(self.fs.fsync_dir("/etc/xc/rollback")) then return false end
  return self:_delete_trashed_generation(trash)
end

function Runtime:_delete_trashed_generation(token)
  if not valid_token(token) then return false end
  if not action_ok(self.fs.delete_trashed_generation("/etc/xc/rollback", token)) then return false end
  return action_ok(self.fs.fsync_dir("/etc/xc/rollback"))
end

function Runtime:_write_transaction(context, phase)
  self:_atomic_write(TRANSACTION_PATH, transaction_text(context, phase))
  context.phase = phase
end

function Runtime:_read_generation(transaction)
  local config_path, active_path = generation_paths(transaction.generation)
  local config = self:_read_optional(config_path, 1048576)
  local marker = self:_read_optional(active_path, 256)
  if type(config) ~= "string" or type(marker) ~= "string"
    or #config ~= transaction.old_size or checksum(config) ~= transaction.old_hash
    or #marker ~= transaction.old_active_size or checksum(marker) ~= transaction.old_active_hash then return nil end
  if transaction.old_present == false and config ~= "" then return nil end
  local active, valid = decode_active_marker(marker)
  if not valid then return nil end
  return { config = transaction.old_present and config or nil, marker = marker, active = active }
end

function Runtime:_read_optional(path, maximum)
  local value, read_error = self.fs.read(path, maximum)
  if value == nil and read_error ~= "missing" then error("bounded read failed", 0) end
  return value
end

function Runtime:_load(section_id)
  local global = self.uci.get_global()
  if type(global) ~= "table" then return nil, nil, result(false, "internal_error") end
  local selected = section_id
  if selected ~= nil then
    if not schema.safe_section_id(selected) then return nil, nil, result(false, "invalid_node") end
  else
    selected = global.active_node
    if selected == "" then selected = nil end
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
  local node, node_error = read_node(self.uci, selected)
  if not node then return nil, nil, result(false, node_error) end
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

function Runtime:_render_locked(section_id, output_path)
  if not valid_output_path(output_path) then self.last_error = "invalid_output"; return result(false, "invalid_output") end
  local encoded, node_id, encode_error = self:_encode(section_id)
  if encode_error then return encode_error end
  self:_atomic_write(output_path, encoded)
  return result(true, "rendered", { node = node_id, path = output_path })
end

function Runtime:render(section_id, output_path)
  return self:_with_lock("render", function() return self:_render_locked(section_id, output_path) end, section_id)
end

function Runtime:_record_completion(operation, value, requested_node)
  local definitions = {
    render = { message = "configuration render completed", success_level = LOG_LEVEL_DEBUG },
    switch = { message = "node switch completed", success_level = LOG_LEVEL_INFO },
    rollback = { message = "rollback completed", success_level = LOG_LEVEL_INFO }
  }
  local definition = definitions[operation]
  if not definition or type(value) ~= "table" then return end
  local code = type(value.code) == "string" and value.code:match("^[a-z][a-z_]*$") and value.code or "internal_error"
  local fields = { code = code, outcome = value.ok and "success" or "failure" }
  local node = value.node or requested_node
  if schema.safe_section_id(node) then fields.node = node end
  self:record_event(definition.message, fields, value.ok and definition.success_level or LOG_LEVEL_ERROR)
end

function Runtime:_with_lock(operation, fn, requested_node)
  local acquired, lock = pcall(self.fs.acquire_lock, LOCK_PATH)
  if not acquired then
    self.last_error = "lock_error"
    local value = result(false, "internal_error")
    self:_record_completion(operation, value, requested_node)
    return value
  end
  if not lock then
    self.last_error = "busy"
    local value = result(false, "busy")
    self:_record_completion(operation, value, requested_node)
    return value
  end
  if operation ~= "recover" then
    local recovered_ok, recovered = xpcall(function() return self:_recover_pending_locked() end, function()
      self:_safe_stop()
      return result(false, "recovery_failed")
    end)
    if not recovered_ok or not recovered.ok then
      self.last_error = "recovery_failed"
      pcall(self.fs.release_lock, lock)
      local value = result(false, "recovery_failed")
      self:_record_completion(operation, value, requested_node)
      return value
    end
  end
  self.operation = operation
  local status_started = pcall(function() self:_atomic_write(STATUS_PATH, "operation=" .. operation .. "\ntime=" .. tostring(self.now()) .. "\n") end)
  if not status_started then
    self.last_error = "internal_error"
    local value = result(false, "internal_error")
    pcall(self.fs.release_lock, lock); self.operation = nil
    self:_record_completion(operation, value, requested_node)
    return value
  end
  local ok, value = xpcall(fn, function()
    if operation == "recover" then self:_safe_stop(); return result(false, "recovery_failed") end
    return result(false, "internal_error")
  end)
  if type(value) ~= "table" then value = result(false, "internal_error") end
  self.last_error = (not value.ok) and value.code or nil
  local status_finished = pcall(function() self:_atomic_write(STATUS_PATH, "operation=idle\nlast_error=" .. tostring(self.last_error or "") .. "\ntime=" .. tostring(self.now()) .. "\n") end)
  local release_call, release_value = pcall(self.fs.release_lock, lock)
  self.operation = nil
  if not status_finished or not release_call or not action_ok(release_value) then
    self.last_error = "lock_release_failed"
    value = result(false, "internal_error")
  end
  self:_record_completion(operation, value, requested_node)
  return value
end

function Runtime:exclusive(operation, callback)
  if operation ~= "migration" or type(callback) ~= "function" then return result(false, "internal_error") end
  return self:_with_lock("migration", function()
    local capability = {
      render = function(section_id, output_path)
        if output_path ~= MIGRATION_CANDIDATE_PATH then return result(false, "invalid_output") end
        local rendered_ok, rendered = xpcall(function()
          return self:_render_locked(section_id, output_path)
        end, function() return result(false, "internal_error") end)
        if not rendered_ok or type(rendered) ~= "table" then rendered = result(false, "internal_error") end
        self:_record_completion("render", rendered, section_id)
        return rendered
      end,
      write = function(path, content)
        if path ~= MIGRATION_MARKER_PATH or type(content) ~= "string" or #content > 1024 then return false end
        return pcall(self._atomic_write, self, path, content)
      end
    }
    return callback(capability)
  end)
end

function Runtime:_apply_active(active)
  local mutation_call, changed = pcall(function()
    if active == nil then return self.uci.clear_active() end
    if not schema.safe_section_id(active) then return false end
    return self.uci.set_active(active)
  end)
  if not mutation_call or not action_ok(changed) then
    pcall(self.uci.revert)
    return false, "pre_commit_failed"
  end
  local commit_call, committed, outcome = pcall(self.uci.commit)
  if not commit_call then return false, "commit_unknown" end
  if committed == true and (outcome == "committed" or outcome == "committed_hardening_failed") then
    return true, outcome
  end
  if committed == false and outcome == "pre_commit_failed" then
    pcall(self.uci.revert)
    return false, outcome
  end
  return false, "commit_unknown"
end

function Runtime:_readiness(global)
  local address = self.network()
  local socks_port, http_port = global.socks_port, global.http_port
  local health_url, timeout = global.health_url, tonumber(global.health_timeout)
  if type(health_url) ~= "string" or #health_url > 2048 or not health_url:match("^https?://") or health_url:find("[%z\1-\31\127]") or not timeout or timeout < 1 or timeout > 30 then return "health_failed" end
  local deadline = self.now() + timeout
  local listeners_ready = false
  for attempt = 1, 10 do
    if self.now() >= deadline then return "health_failed" end
    local socks_ready = action_ok(self.exec.listener_ready("socks", address, socks_port, deadline))
    if self.now() >= deadline then return "health_failed" end
    local http_ready = action_ok(self.exec.listener_ready("http", address, http_port, deadline))
    if self.now() >= deadline then return "health_failed" end
    if socks_ready and http_ready then listeners_ready = true; break end
    if attempt < 10 then
      local remaining = deadline - self.now()
      if remaining <= 0 then return "health_failed" end
      self.sleep(math.min(1, remaining))
      if self.now() >= deadline then return "health_failed" end
    end
  end
  if not listeners_ready then return "listener_failed" end
  if self.now() >= deadline then return "health_failed" end
  local socks_healthy = action_ok(self.exec.health_check("socks", address, socks_port, health_url, deadline))
  if self.now() >= deadline then return "health_failed" end
  local http_healthy = action_ok(self.exec.health_check("http", address, http_port, health_url, deadline))
  if self.now() >= deadline then return "health_failed" end
  if not socks_healthy or not http_healthy then return "health_failed" end
end

function Runtime:_safe_stop()
  local ok, stopped = pcall(self.exec.stop)
  return ok and action_ok(stopped)
end

function Runtime:_restore_transaction(transaction, old)
  local ok = xpcall(function()
    if old.config ~= nil then
      local config_path = generation_paths(transaction.generation)
      local argv = self:_xray_test_argv(config_path)
      if not argv or not action_ok(self.exec.run(argv, self.now() + VALIDATION_TIMEOUT)) then error("old runtime validation failed", 0) end
      self:_atomic_write(RUNTIME_PATH, old.config)
    elseif not self:_checked_remove(RUNTIME_PATH) then error("runtime removal failed", 0) end
    if not self:_apply_active(old.active) then error("active recovery failed", 0) end
    if transaction.old_service == "running" and old.config ~= nil then
      if not action_ok(self.exec.restart()) then error("restart recovery failed", 0) end
      local global = self.uci.get_global()
      if type(global) ~= "table" or self:_readiness(global) then error("readiness recovery failed", 0) end
    elseif not self:_safe_stop() then error("stop recovery failed", 0) end
  end, function() return false end)
  if not ok then self:_safe_stop(); return false end
  return true
end

function Runtime:_finish_recovery(transaction)
  if not self:_trash_generation(transaction.generation) then return false end
  return self:_checked_remove(TRANSACTION_PATH)
end

local function change_transaction_phase(transaction, phase)
  local version, token, kind, current, remainder = transaction._text:match("^([^\n]+)\n([^\n]+)\n([^\n]+)\n([^\n]+)\n(.*)$")
  if not version or current ~= transaction.phase then error("invalid transaction phase", 0) end
  return table.concat({ version, token, kind, phase, remainder }, "\n")
end

function Runtime:_mark_phase(transaction, phase)
  local text = change_transaction_phase(transaction, phase)
  self:_atomic_write(TRANSACTION_PATH, text)
  transaction.phase, transaction._text = phase, text
end

function Runtime:_complete_switch(transaction, old)
  self:_mark_phase(transaction, "cleanup_pending")
  if transaction.old_present then
    self:_atomic_write(ROLLBACK_MANIFEST_PATH, manifest_for(transaction.generation, old.config, old.marker))
  elseif not self:_checked_remove(ROLLBACK_MANIFEST_PATH) then return false end
  if transaction.prior_generation and transaction.prior_generation ~= transaction.generation
    and not self:_trash_generation(transaction.prior_generation) then return false end
  self:_mark_phase(transaction, "finalize")
  return self:_cleanup_finalized(transaction)
end

function Runtime:_complete_rollback(transaction)
  self:_mark_phase(transaction, "finalize")
  return self:_cleanup_finalized(transaction)
end

function Runtime:_cleanup_finalized(transaction)
  if transaction.kind == "switch" then
    if transaction.prior_generation and transaction.prior_generation ~= transaction.generation
      and not self:_trash_generation(transaction.prior_generation) then return false end
    if not transaction.old_present and not self:_trash_generation(transaction.generation) then return false end
    return self:_checked_remove(TRANSACTION_PATH)
  end
  if not self:_checked_remove(ROLLBACK_MANIFEST_PATH) then return false end
  if transaction.target_generation and not self:_trash_generation(transaction.target_generation) then return false end
  if not self:_trash_generation(transaction.generation) then return false end
  return self:_checked_remove(TRANSACTION_PATH)
end

function Runtime:_validate_live(transaction)
  local config = self:_read_optional(RUNTIME_PATH, 1048576)
  if type(config) ~= "string" or #config ~= transaction.new_size or checksum(config) ~= transaction.new_hash then return false end
  local global = self.uci.get_global()
  if type(global) ~= "table" then return false end
  local marker_ok, marker = pcall(active_marker, global.active_node)
  if not marker_ok or #marker ~= transaction.new_active_size or checksum(marker) ~= transaction.new_active_hash then return false end
  local argv = self:_xray_test_argv(RUNTIME_PATH)
  if not argv or not action_ok(self.exec.run(argv, self.now() + VALIDATION_TIMEOUT)) or not action_ok(self.exec.restart()) or self:_readiness(global) then return false end
  return true
end

function Runtime:_scavenge(transaction)
  local referenced = {}
  if transaction then referenced[transaction.generation] = true; if transaction.target_generation then referenced[transaction.target_generation] = true end end
  local manifest_text = self:_read_optional(ROLLBACK_MANIFEST_PATH, 1024)
  local manifest = parse_manifest(manifest_text)
  if manifest_text ~= nil and not manifest then return false end
  if manifest then referenced[manifest.generation] = true end
  local values = self.fs.list_generation_files("/etc/xc/rollback", 256)
  if type(values) ~= "table" or #values > 256 then return false end
  local found, trashed = {}, {}
  for _, name in ipairs(values) do
    if type(name) == "string" then
      local token = name:match("^generation%-([0-9A-Za-z_-]+)%.config$") or name:match("^generation%-([0-9A-Za-z_-]+)%.active$")
      if token and valid_token(token) and not referenced[token] then found[token] = true end
      local trash_token = name:match("^%.trash%-([0-9A-Za-z_-]+)%.config$") or name:match("^%.trash%-([0-9A-Za-z_-]+)%.active$")
      if trash_token and valid_token(trash_token) and not referenced[trash_token] then trashed[trash_token] = true end
    end
  end
  for token in pairs(trashed) do if not self:_delete_trashed_generation(token) then return false end end
  for token in pairs(found) do if not self:_trash_generation(token) then return false end end
  return true
end

function Runtime:_recover_pending_locked()
  local record = self:_read_optional(TRANSACTION_PATH, 1024)
  if record == nil then
    if not self:_scavenge(nil) then return result(false, "recovery_failed") end
    return result(true, "recovered")
  end
  local transaction = parse_transaction(record)
  if not transaction then self:_safe_stop(); return result(false, "recovery_failed") end
  transaction._text = record
  if transaction.phase == "recovery_done" then
    if not self:_finish_recovery(transaction) then self:_safe_stop(); return result(false, "recovery_failed") end
    if not self:_scavenge(nil) then return result(false, "recovery_failed") end
    return result(true, "recovered")
  elseif transaction.phase == "finalize" then
    if not self:_cleanup_finalized(transaction) then self:_safe_stop(); return result(false, "recovery_failed") end
    if not self:_scavenge(nil) then return result(false, "recovery_failed") end
    return result(true, "recovered")
  end
  local old = self:_read_generation(transaction)
  if not old then self:_safe_stop(); return result(false, "recovery_failed") end
  local ok
  if transaction.phase == "cleanup_pending" then ok = self:_complete_switch(transaction, old)
  elseif transaction.phase == "uci_committed" and self:_validate_live(transaction) then
    ok = transaction.kind == "switch" and self:_complete_switch(transaction, old) or self:_complete_rollback(transaction)
  else
    self:_mark_phase(transaction, "recovery_intent")
    ok = self:_restore_transaction(transaction, old)
    if ok then self:_mark_phase(transaction, "recovery_done"); ok = self:_finish_recovery(transaction) end
  end
  if not ok then self:_safe_stop(); return result(false, "recovery_failed") end
  if not self:_scavenge(nil) then return result(false, "recovery_failed") end
  return result(true, "recovered")
end

function Runtime:recover_pending()
  return self:_with_lock("recover", function() return self:_recover_pending_locked() end)
end

function Runtime:_service_state()
  local deadline = self.now() + 2
  if self.now() >= deadline then return "unknown" end
  local state = self.exec.service_state(deadline)
  if self.now() >= deadline or (state ~= "running" and state ~= "stopped") then return "unknown" end
  return state
end

local function valid_ipv4(value)
  local octets = { value:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$") }
  if #octets ~= 4 then return false end
  for _, octet in ipairs(octets) do
    local number = tonumber(octet)
    if number > 255 or tostring(number) ~= octet then return false end
  end
  return true
end

local function valid_observed_ip(value)
  if valid_ipv4(value) then return true end
  if #value > 64 or not value:find(":", 1, true) or not value:match("^[0-9A-Fa-f:.]+$") then return false end
  if value:find(":::", 1, true) then return false end
  local first_double = value:find("::", 1, true)
  if first_double and value:find("::", first_double + 2, true) then return false end
  if value:sub(1, 1) == ":" and value:sub(1, 2) ~= "::" then return false end
  if value:sub(-1) == ":" and value:sub(-2) ~= "::" then return false end

  local units = 0
  if value:find(".", 1, true) then
    local prefix, tail = value:match("^(.*:)([^:]+)$")
    if not prefix or not valid_ipv4(tail) then return false end
    value = prefix .. "v4"
  end
  for group in value:gmatch("[^:]+") do
    if group == "v4" then
      units = units + 2
    elseif #group < 1 or #group > 4 or not group:match("^[0-9A-Fa-f]+$") then
      return false
    else
      units = units + 1
    end
  end
  if first_double then return units < 8 end
  return units == 8
end

local function parse_exit_ip_cache(value, active, wall_now)
  if type(value) ~= "string" or type(active) ~= "string" or type(wall_now) ~= "number" then return nil end
  local node, observed_text, ip = value:match("^node=([^\n]+)\nobserved_at=([^\n]+)\nip=([^\n]+)\n$")
  if not node or node ~= active or not schema.safe_section_id(node) or not observed_text:match("^%d+$") then return nil end
  local observed_at = tonumber(observed_text)
  if not observed_at or observed_at < 0 or observed_at ~= math.floor(observed_at) or tostring(observed_at) ~= observed_text then return nil end
  local age = wall_now - observed_at
  if age < 0 or age >= EXIT_IP_CACHE_TTL or not valid_observed_ip(ip) then return nil end
  return ip
end

function Runtime:_with_exit_context(section_id, fn)
  local acquired, lock = pcall(self.fs.acquire_lock, LOCK_PATH)
  if not acquired or not lock then return false end
  local called, context_ok = xpcall(function()
    local global = self.uci.get_global()
    if type(global) ~= "table" or global.active_node ~= section_id then return false end
    if self:_read_optional(TRANSACTION_PATH, 1024) ~= nil then return false end
    local shared_status = self:_read_optional(STATUS_PATH, 1024) or ""
    local operation = shared_status:match("operation=([A-Za-z_]+)") or "idle"
    if operation ~= "idle" then return false end
    fn()
    return true
  end, function() return false end)
  local released, release_value = pcall(self.fs.release_lock, lock)
  return called and context_ok and released and action_ok(release_value)
end

function Runtime:_cached_exit_ip(section_id, wall_now)
  local read_ok, value = pcall(self.fs.read, EXIT_IP_CACHE_PATH, 512)
  if not read_ok then return nil end
  return parse_exit_ip_cache(value, section_id, wall_now)
end

function Runtime:_prepare_transaction(kind, old_config, old_active, new_config, new_active, target, prior)
  local generation = self.fs.allocate_generation("/etc/xc/rollback")
  if not valid_token(generation) then error("generation allocation failed", 0) end
  if generation == target or generation == prior then error("generation collision", 0) end
  local config_path, active_path = generation_paths(generation)
  local marker = active_marker(old_active)
  self:_atomic_write(config_path, old_config or "")
  self:_atomic_write(active_path, marker)
  return {
    generation = generation, kind = kind, target_generation = target, old_config = old_config,
    old_marker = marker, new_config = new_config, new_marker = active_marker(new_active),
    old_service = self:_service_state(), prior_generation = prior
  }
end

function Runtime:_abort_transaction(context, code)
  local record = self:_read_optional(TRANSACTION_PATH, 1024)
  local transaction = parse_transaction(record)
  if not transaction then self:_safe_stop(); return result(false, "recovery_failed") end
  transaction._text = record
  local old = self:_read_generation(transaction)
  if not old then self:_safe_stop(); return result(false, "recovery_failed") end
  self:_mark_phase(transaction, "recovery_intent")
  if not self:_restore_transaction(transaction, old) then return result(false, "recovery_failed") end
  self:_mark_phase(transaction, "recovery_done")
  if not self:_finish_recovery(transaction) then return result(false, "recovery_failed") end
  if context.old_config == nil then
    return result(false, code .. "_no_previous_config", { message = (messages[code] or messages.internal_error) .. "; service stopped because no previous configuration exists" })
  end
  return result(false, code)
end

function Runtime:_install_candidate(context)
  if not action_ok(self.fs.rename(CANDIDATE_PATH, RUNTIME_PATH)) then error("runtime replace failed", 0) end
  if not action_ok(self.fs.fsync_dir("/var/etc/xc")) then error("runtime replace failed", 0) end
  context.installed = true
end

function Runtime:_switch_locked(section_id)
  local encoded, node_id, encode_error = self:_encode(section_id)
  if encode_error then return encode_error end
  self:_atomic_write(CANDIDATE_PATH, encoded)
  local argv = self:_xray_test_argv(CANDIDATE_PATH)
  if not argv or not action_ok(self.exec.run(argv, self.now() + VALIDATION_TIMEOUT)) then
    if not self:_checked_remove(CANDIDATE_PATH) then return result(false, "internal_error") end
    return result(false, "validation_failed")
  end
  local global, old_config, context
  local prepared = xpcall(function()
    global = self.uci.get_global()
    if type(global) ~= "table" then error("invalid UCI state", 0) end
    old_config = self:_read_optional(RUNTIME_PATH, 1048576)
    local prior_text = self:_read_optional(ROLLBACK_MANIFEST_PATH, 1024)
    local prior = parse_manifest(prior_text)
    context = self:_prepare_transaction("switch", old_config, global.active_node, encoded, node_id, nil, prior and prior.generation)
  end, function() return false end)
  if not prepared then
    if not self:_checked_remove(CANDIDATE_PATH) then return result(false, "recovery_failed") end
    return result(false, "internal_error")
  end
  self:_write_transaction(context, "install_intent")
  local ok, value = xpcall(function()
    self:_install_candidate(context)
    if not action_ok(self.exec.restart()) then return self:_abort_transaction(context, "restart_failed") end
    local readiness_error = self:_readiness(global)
    if readiness_error then return self:_abort_transaction(context, readiness_error) end
    self:_write_transaction(context, "candidate_healthy")
    local committed, commit_outcome = self:_apply_active(node_id)
    if not committed then
      if commit_outcome == "pre_commit_failed" then return self:_abort_transaction(context, "commit_failed") end
      self:_safe_stop()
      return result(false, "commit_unknown")
    end
    self:_write_transaction(context, "uci_committed")
    local transaction = assert(parse_transaction(self:_read_optional(TRANSACTION_PATH, 1024)))
    transaction._text = self:_read_optional(TRANSACTION_PATH, 1024)
    local old = assert(self:_read_generation(transaction))
    if not self:_complete_switch(transaction, old) then return result(false, "recovery_failed") end
    return result(true, "switched", { node = node_id, commit_outcome = commit_outcome })
  end, function() return result(false, "internal_error") end)
  if not ok or (not value.ok and value.code ~= "commit_unknown" and self.fs.exists(TRANSACTION_PATH)) then
    local recovered = self:_recover_pending_locked()
    if not recovered.ok then return result(false, "recovery_failed") end
  end
  return value
end

function Runtime:switch(section_id)
  return self:_with_lock("switch", function() return self:_switch_locked(section_id) end, section_id)
end

function Runtime:_rollback_locked()
  local manifest_text = self:_read_optional(ROLLBACK_MANIFEST_PATH, 1024)
  if manifest_text == nil then return result(false, "no_rollback_state") end
  local manifest = parse_manifest(manifest_text)
  if not manifest or manifest.config_size > 1048576 or manifest.active_size > 256 then return result(false, "no_rollback_state") end
  local config_path, active_path = generation_paths(manifest.generation)
  local config, marker = self:_read_optional(config_path, 1048576), self:_read_optional(active_path, 256)
  if type(config) ~= "string" or type(marker) ~= "string" or #config ~= manifest.config_size or checksum(config) ~= manifest.config_hash
    or #marker ~= manifest.active_size or checksum(marker) ~= manifest.active_hash then return result(false, "no_rollback_state") end
  local node_id, marker_ok = decode_active_marker(marker)
  if not marker_ok then return result(false, "no_rollback_state") end
  self:_atomic_write(CANDIDATE_PATH, config)
  local argv = self:_xray_test_argv(CANDIDATE_PATH)
  if not argv or not action_ok(self.exec.run(argv, self.now() + VALIDATION_TIMEOUT)) then
    if not self:_checked_remove(CANDIDATE_PATH) then return result(false, "internal_error") end
    return result(false, "validation_failed")
  end
  local global, old_config, context
  local prepared = xpcall(function()
    global = self.uci.get_global()
    if type(global) ~= "table" then error("invalid UCI state", 0) end
    old_config = self:_read_optional(RUNTIME_PATH, 1048576)
    context = self:_prepare_transaction("rollback", old_config, global.active_node, config, node_id, manifest.generation, manifest.generation)
  end, function() return false end)
  if not prepared then
    if not self:_checked_remove(CANDIDATE_PATH) then return result(false, "recovery_failed") end
    return result(false, "internal_error")
  end
  self:_write_transaction(context, "install_intent")
  local ok, value = xpcall(function()
    self:_install_candidate(context)
    if not action_ok(self.exec.restart()) then return self:_abort_transaction(context, "restart_failed") end
    local readiness_error = self:_readiness(global)
    if readiness_error then return self:_abort_transaction(context, readiness_error) end
    self:_write_transaction(context, "candidate_healthy")
    local committed, commit_outcome = self:_apply_active(node_id)
    if not committed then
      if commit_outcome == "pre_commit_failed" then return self:_abort_transaction(context, "commit_failed") end
      self:_safe_stop()
      return result(false, "commit_unknown")
    end
    self:_write_transaction(context, "uci_committed")
    local record = self:_read_optional(TRANSACTION_PATH, 1024)
    local transaction = assert(parse_transaction(record)); transaction._text = record
    if not self:_complete_rollback(transaction) then return result(false, "recovery_failed") end
    local extra = {}; if node_id then extra.node = node_id else extra.active_node_unset = true end
    extra.commit_outcome = commit_outcome
    return result(true, "rolled_back", extra)
  end, function() return result(false, "internal_error") end)
  if not ok or (not value.ok and value.code ~= "commit_unknown" and self.fs.exists(TRANSACTION_PATH)) then
    local recovered = self:_recover_pending_locked()
    if not recovered.ok then return result(false, "recovery_failed") end
  end
  return value
end

function Runtime:rollback()
  return self:_with_lock("rollback", function() return self:_rollback_locked() end)
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
    local shared_status = self:_read_optional(STATUS_PATH, 1024) or ""
    local shared_operation = shared_status:match("operation=([A-Za-z_]+)") or "idle"
    local shared_error = shared_status:match("last_error=([A-Za-z0-9_]+)")
    local lock_state = self.fs.lock_state(LOCK_PATH)
    if lock_state ~= "held" and lock_state ~= "unlocked" then lock_state = "unknown" end
    local pending = self:_read_optional(TRANSACTION_PATH, 1024) ~= nil
    local recovery_required = lock_state == "unlocked" and pending
    if recovery_required then
      shared_operation = "interrupted"
    elseif lock_state == "unlocked" and shared_operation ~= "idle" then
      shared_operation = "idle"
    end
    local listener_deadline = self.now() + 2
    local listeners = {
      socks = action_ok(self.exec.listener_ready("socks", address, tonumber(global.socks_port), listener_deadline)),
      http = action_ok(self.exec.listener_ready("http", address, tonumber(global.http_port), listener_deadline))
    }
    local exit_ip
    local can_observe = service == "running" and listeners.socks and safe_active and lock_state == "unlocked"
      and not pending and shared_operation == "idle" and type(self.exec.observe_exit_ip) == "function"
      and type(global.health_url) == "string"
    if can_observe then
      local wall_now = self.wall_time()
      local cached = self:_cached_exit_ip(safe_active, wall_now)
      if cached then
        if not self:_with_exit_context(safe_active, function() exit_ip = cached end) then exit_ip = nil end
      elseif not cached then
        local observation_deadline = self.now() + 5
        local observed, observed_value = pcall(self.exec.observe_exit_ip, "socks", address, tonumber(global.socks_port), global.health_url, observation_deadline)
        if observed and type(observed_value) == "string" then
          observed_value = observed_value:match("^%s*(.-)%s*$")
          if valid_observed_ip(observed_value) then
            local context_ok = self:_with_exit_context(safe_active, function()
              exit_ip = observed_value
              local observed_at = self.wall_time()
              if type(observed_at) == "number" and observed_at >= 0 and observed_at == math.floor(observed_at) then
                pcall(self._atomic_write, self, EXIT_IP_CACHE_PATH, "node=" .. safe_active .. "\nobserved_at=" .. tostring(observed_at) .. "\nip=" .. observed_value .. "\n")
              end
            end)
            if not context_ok then exit_ip = nil end
          end
        end
      end
    end
    local output = result(true, "status", {
      active_node = safe_active,
      active_state = active_state,
      runtime_config = self.fs.exists(RUNTIME_PATH),
      service = service, operation = shared_operation, lock = lock_state, recovery_required = recovery_required,
      listen = { address = sanitize_text(address, 64), socks_port = tonumber(global.socks_port), http_port = tonumber(global.http_port) },
      listeners = listeners,
      exit_ip = exit_ip,
      last_error = shared_error
    })
    if safe_active then
      local node, node_error = read_node(self.uci, safe_active)
      if not node then return result(false, node_error) end
      output.node = {
        id = safe_active,
        name = sanitize_text(node.name or "", 128),
        protocol = schema.supported_protocols[node.protocol] and node.protocol or nil,
        enabled = enabled(node.enabled)
      }
    end
    return output
  end, function() return result(false, "internal_error") end)
  if not ok or not value.ok then self.last_error = value.code or "internal_error" end
  return value
end

function Runtime:test_current()
  local ok, value = xpcall(function()
    if not self.fs.exists(RUNTIME_PATH) then return result(false, "missing_runtime") end
    local argv = self:_xray_test_argv(RUNTIME_PATH)
    if argv and action_ok(self.exec.run(argv, self.now() + VALIDATION_TIMEOUT)) then return result(true, "test_passed") end
    return result(false, "test_failed")
  end, function() return result(false, "internal_error") end)
  if not ok or not value.ok then self.last_error = value.code or "internal_error" end
  return value
end

local function utf8_prefix(value, maximum)
  if #value <= maximum then return value end
  local index = maximum
  while index > 0 do
    local byte = value:byte(index)
    if byte < 128 then return value:sub(1, index) end
    if byte >= 194 and byte <= 244 then
      local width = byte < 224 and 2 or (byte < 240 and 3 or 4)
      return value:sub(1, index + width - 1 <= maximum and index + width - 1 or index - 1)
    end
    index = index - 1
  end
  return ""
end

sanitize_text = function(value, maximum)
  if type(value) ~= "string" then value = tostring(value) end
  value = utf8_prefix(value, 8192)
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
  return utf8_prefix(value, maximum or 256)
end

local function sensitive_key(key)
  local lowered = key:lower()
  for _, fragment in ipairs({ "password", "passwd", "uuid", "secret", "token", "api_key", "apikey", "private_key", "privatekey", "key_id", "keyid", "credential", "userinfo", "share", "link", "uri", "url", "raw", "content", "config" }) do
    if lowered:find(fragment, 1, true) then return true end
  end
  return false
end

function Runtime:log(message, fields, level)
  if level == nil then level = LOG_LEVEL_INFO end
  if level ~= LOG_LEVEL_DEBUG and level ~= LOG_LEVEL_INFO and level ~= LOG_LEVEL_ERROR then level = LOG_LEVEL_INFO end
  local acquired, lock = pcall(self.fs.acquire_lock, LOG_LOCK_PATH)
  if not acquired or not lock then self.last_error = acquired and "busy" or "lock_error"; return result(false, acquired and "busy" or "internal_error") end
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
    local entry = { time = self.wall_time(), level = level, message = sanitize_text(message, 512), fields = safe_fields }
    local encoded = self.json.stringify(entry)
    if type(encoded) ~= "string" then encoded = '{"message":"log entry redacted"}' end
    if #encoded > 2047 then encoded = '{"message":"log entry truncated"}' end
    local current = self:_read_optional(LOG_PATH, 262144) or ""
    local combined = current .. encoded .. "\n"
    if #combined > 262144 then
      local newline = combined:find("\n", #combined - 262144 + 1, true)
      combined = newline and combined:sub(newline + 1) or (encoded .. "\n")
    end
    self:_atomic_write(LOG_PATH, combined)
    return result(true, "logged")
  end, function() return result(false, "internal_error") end)
  local released, release_value = pcall(self.fs.release_lock, lock)
  if not ok or not released or not action_ok(release_value) then self.last_error = "internal_error"; return result(false, "internal_error") end
  self.last_error = not value.ok and value.code or nil
  return value
end

function Runtime:record_event(message, fields, level)
  local primary_error = self.last_error
  local called, value = pcall(self.log, self, message, fields, level)
  self.last_error = primary_error
  return called and type(value) == "table" and value.ok == true
end

function M.new(adapters)
  if type(adapters) ~= "table" then return nil, "invalid runtime adapters" end
  local required_tables = { "uci", "fs", "exec", "json" }
  for _, name in ipairs(required_tables) do if type(adapters[name]) ~= "table" then return nil, "invalid runtime adapters" end end
  for _, name in ipairs({ "network", "now", "sleep" }) do if type(adapters[name]) ~= "function" then return nil, "invalid runtime adapters" end end
  local methods = {
    uci = { "get_global", "get_node", "list_nodes", "set_active", "clear_active", "commit", "revert" },
    fs = { "acquire_lock", "release_lock", "lock_state", "allocate_generation", "list_generation_files", "trash_generation", "delete_trashed_generation", "read", "write_temp", "chmod", "fsync", "fsync_dir", "close", "rename", "exists", "remove" },
    exec = { "run", "restart", "stop", "listener_ready", "health_check", "service_state" },
    json = { "stringify", "parse" }
  }
  for adapter, names in pairs(methods) do
    for _, name in ipairs(names) do if type(adapters[adapter][name]) ~= "function" then return nil, "invalid runtime adapters" end end
  end
  return setmetatable({
    uci = adapters.uci, fs = adapters.fs, exec = adapters.exec, json = adapters.json,
    network = adapters.network, now = adapters.now, wall_time = adapters.wall_time or adapters.now, sleep = adapters.sleep, sequence = 0
  }, Runtime)
end

M.paths = {
  lock = LOCK_PATH, runtime = RUNTIME_PATH, candidate = CANDIDATE_PATH,
  rollback_directory = "/etc/xc/rollback",
  rollback = ROLLBACK_PATH, rollback_node = ROLLBACK_NODE_PATH,
  rollback_manifest = ROLLBACK_MANIFEST_PATH,
  transaction = TRANSACTION_PATH, status = STATUS_PATH,
  migration_candidate = MIGRATION_CANDIDATE_PATH, migration_marker = MIGRATION_MARKER_PATH,
  log = LOG_PATH, log_lock = LOG_LOCK_PATH, exit_ip_cache = EXIT_IP_CACHE_PATH
}
M.unset_active_marker = UNSET_ACTIVE_MARKER

return M
