local core = require "xc.core"

local M = {}
local Manager = {}
Manager.__index = Manager

local UPLOAD_PATTERN = "^/var/etc/xc/%.core%-upload%-[0-9A-Za-z_-]+$"
local CONFIG_PATH = "/var/etc/xc/config.json"
local LOCK_PATH = "/var/lock/xc.lock"
local MAX_HEADER = 64

local ELF_MACHINES = {
  [3] = { arch = "i386", class = 1 },
  [8] = { little = "mipsel", big = "mips", class = 1 },
  [40] = { arch = "arm", class = 1 },
  [62] = { arch = "x86_64", class = 2 },
  [183] = { arch = "aarch64", class = 2 }
}

local MACHINE_ALIASES = {
  aarch64 = "aarch64",
  arm64 = "aarch64",
  x86_64 = "x86_64",
  amd64 = "x86_64",
  i386 = "i386",
  i486 = "i386",
  i586 = "i386",
  i686 = "i386",
  mips = "mips",
  mipsel = "mipsel",
  arm = "arm",
  armv7 = "arm",
  armv7l = "arm",
  armv8l = "arm"
}

local function result(ok, code, extra)
  local value = { ok = ok, code = code }
  for key, item in pairs(extra or {}) do value[key] = item end
  return value
end

local function safe_upload(path)
  return type(path) == "string" and #path <= 256 and path:match(UPLOAD_PATTERN) ~= nil
end

local function read_le16(value, offset)
  local low, high = value:byte(offset), value:byte(offset + 1)
  return low and high and low + high * 256 or nil
end

local function read_be16(value, offset)
  local high, low = value:byte(offset), value:byte(offset + 1)
  return high and low and high * 256 + low or nil
end

local function elf_arch(header)
  if type(header) ~= "string" or #header < 20 or header:sub(1, 4) ~= "\127ELF" then return nil end
  local class, data = header:byte(5), header:byte(6)
  if class ~= 1 and class ~= 2 then return nil end
  local machine = data == 1 and read_le16(header, 19) or data == 2 and read_be16(header, 19) or nil
  local entry = machine and ELF_MACHINES[machine] or nil
  if not entry or entry.class ~= class then return nil end
  return entry.arch or (data == 1 and entry.little or entry.big)
end

local function normalize_machine(value)
  return type(value) == "string" and MACHINE_ALIASES[value:lower()] or nil
end

local function parse_version(output)
  if type(output) ~= "string" or #output > 2048 then return nil end
  return output:match("[Xx]ray%s+([0-9][0-9a-zA-Z%.%-]*)")
end

local function valid_note(value)
  return value == nil or (type(value) == "string" and #value <= 256 and not value:find("[%z\1-\31\127]"))
end

local function read_marker(fs, name)
  local path = core.marker_path(name)
  if not path then return nil, "invalid_marker" end
  local value, read_error = fs.read(path, 128)
  if value == nil and read_error == "missing" then return nil, "missing" end
  if type(value) ~= "string" then return nil, "io_error" end
  local marker = core.read_marker(value)
  return marker, marker and "ok" or "invalid_marker"
end

local function write_marker(fs, name, value)
  local path = core.marker_path(name)
  if not path then return false end
  return core.write_marker(fs, path, value)
end

local function remove_marker(fs, name)
  local path = core.marker_path(name)
  return path ~= nil and fs.remove(path) == true
end

local function transaction_text(old_marker, target_marker, previous_marker, previous_known)
  local previous = previous_known and previous_marker or "none"
  return "xc-core-transaction-v2\nold=" .. old_marker .. "\ntarget=" .. target_marker
    .. "\nprevious=" .. previous .. "\n"
end

local function parse_transaction(value)
  if type(value) ~= "string" or #value > 512 then return nil end
  local old_marker, target_marker, previous_marker = value:match("^xc%-core%-transaction%-v2\nold=([^\n]+)\ntarget=([^\n]+)\nprevious=([^\n]+)\n$")
  if old_marker then
    old_marker, target_marker = core.read_marker(old_marker), core.read_marker(target_marker)
    if not old_marker or not target_marker then return nil end
    if previous_marker == "none" then return { old = old_marker, target = target_marker, previous_known = true } end
    previous_marker = core.read_marker(previous_marker)
    if not previous_marker then return nil end
    return { old = old_marker, target = target_marker, previous = previous_marker, previous_known = true }
  end
  old_marker, target_marker = value:match("^xc%-core%-transaction%-v1\nold=([^\n]+)\ntarget=([^\n]+)\n$")
  old_marker, target_marker = core.read_marker(old_marker), core.read_marker(target_marker)
  if not old_marker or not target_marker then return nil end
  return { old = old_marker, target = target_marker, previous_known = false }
end

local function enabled(value)
  return value == true or value == 1 or value == "1"
end

function Manager:_validate_path(path)
  if not safe_upload(path) then return result(false, "core_invalid_upload") end
  local stat = self.fs.stat(path)
  if type(stat) ~= "table" or stat.type == "dir" then return result(false, "core_invalid_upload") end
  local size = tonumber(stat.size)
  if not size or size < 1 or size > core.DEFAULT_MAX_SIZE then return result(false, "core_upload_too_large") end
  return result(true, "core_upload_ready", { size = math.floor(size) })
end

function Manager:validate(path, expected_sha256, note)
  local checked = self:_validate_path(path)
  if not checked.ok then return checked end
  if type(self.fs.available_space) == "function" then
    local available = self.fs.available_space(core.versions_dir())
    if type(available) ~= "number" or available < checked.size + 1024 * 1024 then
      return result(false, "core_disk_space_low")
    end
  end
  if expected_sha256 ~= nil and expected_sha256 ~= "" and not core.safe_sha256(expected_sha256) then return result(false, "core_hash_invalid") end
  if not valid_note(note) then return result(false, "core_note_invalid") end

  local header = self.fs.read_prefix(path, MAX_HEADER)
  local binary_arch = elf_arch(header)
  if not binary_arch then return result(false, "core_invalid_elf") end
  local machine = normalize_machine(self.exec.machine(self.now() + 5))
  if not machine or machine ~= binary_arch then return result(false, "core_arch_mismatch") end

  local actual_hash = self.exec.hash_file(path, self.now() + 30)
  if not core.safe_sha256(actual_hash) then return result(false, "core_hash_failed") end
  actual_hash = actual_hash:lower()
  if expected_sha256 and expected_sha256 ~= "" and actual_hash ~= expected_sha256:lower() then return result(false, "core_hash_mismatch") end

  if type(self.fs.chmod) == "function" and self.fs.chmod(path, 700) ~= true then return result(false, "core_invalid_upload") end
  local version = parse_version(self.exec.xray_version(path, self.now() + 5))
  if not version or not version:match("^[0-9][0-9a-zA-Z%.%-]*$") then return result(false, "core_version_invalid") end
  local id = core.version_id(version:lower(), binary_arch, actual_hash)
  if not id then return result(false, "core_version_invalid") end

  local validation = "binary"
  if self.fs.exists(CONFIG_PATH) then
    local tested = self.exec.run({ path, "run", "-test", "-format", "json", "-c", CONFIG_PATH }, self.now() + 30)
    if tested ~= true then return result(false, "core_config_invalid") end
    validation = "full"
  end

  local manifest = {
    id = id, version = version:lower(), arch = binary_arch, size = checked.size,
    sha256 = actual_hash, uploaded_at = self.wall_time(), note = note, validation = validation
  }
  return result(true, "core_validated", { manifest = manifest })
end

function Manager:install(path, manifest)
  if not safe_upload(path) then return result(false, "core_invalid_upload") end
  if type(manifest) ~= "table" or not core.validate_manifest(manifest) then return result(false, "core_manifest_invalid") end
  local directory, executable, manifest_path = core.version_path(manifest.id), core.executable_path(manifest.id), core.manifest_path(manifest.id)
  if not directory or not executable or not manifest_path then return result(false, "core_manifest_invalid") end
  if self.fs.exists(executable) or self.fs.exists(manifest_path) then return result(false, "core_already_installed") end
  if self.fs.mkdir(directory, 700) ~= true then return result(false, "core_install_failed") end
  if self.fs.copy_file(path, executable, core.DEFAULT_MAX_SIZE, 700) ~= true then
    self.fs.remove(executable)
    return result(false, "core_install_failed")
  end
  local encoded_ok, encoded = pcall(self.json.stringify, manifest)
  if not encoded_ok or type(encoded) ~= "string" or #encoded > core.MANIFEST_MAX_SIZE
    or self.fs.write_file(manifest_path, encoded, 600) ~= true then
    self.fs.remove(executable)
    self.fs.remove(manifest_path)
    return result(false, "core_install_failed")
  end
  return result(true, "core_installed", { version = core.public_version(manifest) })
end

function Manager:_installed_manifest(id)
  if id == "system" or not core.safe_id(id) then return nil end
  local text = self.fs.read(core.manifest_path(id), core.MANIFEST_MAX_SIZE)
  local manifest = type(text) == "string" and core.parse_manifest(text, self.json.parse) or nil
  if not manifest or manifest.id ~= id then return nil end
  local machine_called, machine_value = pcall(self.exec.machine, self.now() + 5)
  local machine = machine_called and normalize_machine(machine_value) or nil
  if not machine or machine ~= manifest.arch then return nil end
  local executable = core.executable_path(id)
  local stat = type(self.fs.stat_nofollow) == "function" and self.fs.stat_nofollow(executable) or nil
  local manifest_stat = type(self.fs.stat_nofollow) == "function" and self.fs.stat_nofollow(core.manifest_path(id)) or nil
  if type(manifest_stat) ~= "table" or manifest_stat.type ~= "reg" then return nil end
  if type(stat) ~= "table" or stat.type ~= "reg" or tonumber(stat.size) ~= manifest.size then return nil end
  local actual = self.exec.hash_file(executable, self.now() + 30)
  if type(actual) ~= "string" or actual:lower() ~= manifest.sha256 then return nil end
  return manifest
end

function Manager:_marker_valid(marker)
  if marker == "system" then
    local stat = self.fs.stat(core.system_path())
    if type(stat) ~= "table" or stat.type ~= "reg" then return false end
    local version = self.exec.xray_version(core.system_path(), self.now() + 5)
    local hash = self.exec.hash_file(core.system_path(), self.now() + 30)
    return parse_version(version) ~= nil and core.safe_sha256(hash)
  end
  return self:_installed_manifest(marker) ~= nil
end

function Manager:_runtime_ready(global)
  if not enabled(global and global.enabled) then return true end
  if self.exec.restart() ~= true then return false end
  local deadline = self.now() + 30
  if self.exec.service_state(deadline) ~= "running" then return false end
  local address = self.network and self.network() or nil
  local socks_port, http_port = tonumber(global.socks_port), tonumber(global.http_port)
  if type(address) ~= "string" or not socks_port or not http_port then return false end
  if self.exec.listener_ready("socks", address, socks_port, deadline) ~= true
    or self.exec.listener_ready("http", address, http_port, deadline) ~= true then return false end
  if type(global.health_url) ~= "string" or global.health_url == ""
    or not global.health_url:match("^https?://") then return false end
  local results = self.exec.real_connection_checks(address, socks_port, http_port, global.health_url, deadline)
  if type(results) ~= "table" or type(results.socks) ~= "table" or results.socks.ok ~= true
    or type(results.http) ~= "table" or results.http.ok ~= true then return false end
  return true
end

function Manager:_recover_pending_locked()
  local text, state = self.fs.read(core.marker_path("transaction"), 512)
  if text == nil and state == "missing" then return result(true, "core_recovered") end
  local transaction = parse_transaction(text)
  if not transaction then return result(false, "core_recovery_required", { recovery_required = true }) end
  if not self.uci or type(self.uci.get_global) ~= "function" then return result(false, "core_runtime_unavailable") end
  local global = self.uci.get_global()
  if type(global) ~= "table" then return result(false, "core_recovery_failed", { recovery_required = true }) end
  local old_called, old_valid = pcall(self._marker_valid, self, transaction.old)
  old_valid = old_called and old_valid == true
  local previous_valid = true
  if transaction.previous_known and transaction.previous then
    local called, valid = pcall(self._marker_valid, self, transaction.previous)
    previous_valid = called and valid == true
  end
  if not old_valid or not previous_valid then
    return result(false, "core_recovery_required", {
      recovery_required = true, current = transaction.old, failed_target = transaction.target
    })
  end
  if not write_marker(self.fs, "current", transaction.old) then
    return result(false, "core_recovery_failed", { recovery_required = true, current = transaction.old, failed_target = transaction.target })
  end
  if transaction.previous_known then
    local previous_ok = transaction.previous and write_marker(self.fs, "previous", transaction.previous)
      or remove_marker(self.fs, "previous")
    if not previous_ok then
      return result(false, "core_recovery_failed", { recovery_required = true, current = transaction.old, failed_target = transaction.target })
    end
  end
  if not self:_runtime_ready(global) then
    return result(false, "core_recovery_failed", { recovery_required = true, current = transaction.old, failed_target = transaction.target })
  end
  if not remove_marker(self.fs, "transaction") then
    return result(false, "core_recovery_required", { recovery_required = true, current = transaction.old, failed_target = transaction.target })
  end
  return result(true, "core_recovered", { current = transaction.old })
end

function Manager:_with_lock(callback)
  if type(self.fs.acquire_lock) ~= "function" or type(self.fs.release_lock) ~= "function" then
    return result(false, "core_runtime_unavailable")
  end
  local called, lock = pcall(self.fs.acquire_lock, LOCK_PATH)
  if not called or not lock then return result(false, "core_busy") end
  local ok, value = xpcall(callback, function() return result(false, "core_activate_failed") end)
  local released, release_result = pcall(self.fs.release_lock, lock)
  if not released or release_result ~= true then
    local read_ok, text = pcall(self.fs.read, core.marker_path("transaction"), 512)
    local pending = read_ok and parse_transaction(text)
    if pending then
      return result(false, "core_recovery_required", {
        recovery_required = true, current = pending.old, failed_target = pending.target
      })
    end
    if type(value) == "table" and value.recovery_required == true then return value end
    return result(false, "core_activate_failed")
  end
  if not ok then
    local read_ok, text = pcall(self.fs.read, core.marker_path("transaction"), 512)
    local pending = read_ok and parse_transaction(text)
    if pending then
      return result(false, "core_recovery_required", {
        recovery_required = true, current = pending.old, failed_target = pending.target
      })
    end
    return result(false, "core_activate_failed")
  end
  if type(value) ~= "table" then return result(false, "core_activate_failed") end
  return value
end

function Manager:activate(target)
  if target ~= "system" and not core.safe_id(target) then return result(false, "core_invalid_target") end
  if not self.uci or type(self.uci.get_global) ~= "function" then return result(false, "core_runtime_unavailable") end
  return self:_with_lock(function()
    local pending = self:_recover_pending_locked()
    if not pending.ok then return pending end
    local current, current_state = read_marker(self.fs, "current")
    if current_state == "missing" then current = "system" end
    if not current or current_state == "invalid_marker" then return result(false, "core_recovery_required") end
    local current_valid_called, current_valid = pcall(self._marker_valid, self, current)
    if not current_valid_called or not current_valid then return result(false, "core_recovery_required") end
    if target ~= "system" and not self:_installed_manifest(target) then return result(false, "core_not_installed") end
    if current == target then return result(true, "core_already_active", { current = current }) end
    local previous, previous_state = read_marker(self.fs, "previous")
    if previous_state == "invalid_marker" then return result(false, "core_recovery_required") end
    if previous then
      local previous_valid_called, previous_valid = pcall(self._marker_valid, self, previous)
      if not previous_valid_called or not previous_valid then return result(false, "core_recovery_required") end
    end
    local global = self.uci.get_global()
    if type(global) ~= "table" then return result(false, "core_runtime_unavailable") end
    if self.fs.write_file(core.marker_path("transaction"), transaction_text(current, target, previous, previous_state == "ok"), 600) ~= true then
      return result(false, "core_activate_failed")
    end
    if not write_marker(self.fs, "previous", current) or not write_marker(self.fs, "current", target) then
      if not remove_marker(self.fs, "transaction") then
        return result(false, "core_recovery_required", { current = current, failed_target = target, recovery_required = true })
      end
      return result(false, "core_activate_failed")
    end
    if self:_runtime_ready(global) then
      if not remove_marker(self.fs, "transaction") then
        return result(false, "core_recovery_required", { current = target, previous = current, failed_target = target, recovery_required = true })
      end
      return result(true, "core_activated", { current = target, previous = current })
    end
    local restored_current = write_marker(self.fs, "current", current)
    local restored_previous = previous and write_marker(self.fs, "previous", previous) or remove_marker(self.fs, "previous")
    if not restored_current or not restored_previous then
      return result(false, "core_recovery_failed", { current = target, failed_target = target, recovery_required = true })
    end
    local recovered = self:_runtime_ready(global)
    if recovered then
      if not remove_marker(self.fs, "transaction") then
        return result(false, "core_recovery_required", { current = current, failed_target = target, recovery_required = true })
      end
      return result(false, "core_recovered", { current = current, failed_target = target })
    end
    return result(false, "core_recovery_failed", { current = current, failed_target = target, recovery_required = true })
  end)
end

function Manager:rollback()
  local previous, state = read_marker(self.fs, "previous")
  if state == "missing" then
    local current, current_state = read_marker(self.fs, "current")
    if current_state == "missing" then current = "system" end
    if current_state == "invalid_marker" then return result(false, "core_recovery_required") end
    if current and current ~= "system" then return self:activate("system") end
    return result(false, "core_no_rollback")
  end
  if not previous or state ~= "ok" then return result(false, "core_recovery_required") end
  return self:activate(previous)
end

function Manager:delete(target)
  if not core.safe_id(target) then return result(false, "core_invalid_target") end
  return self:_with_lock(function()
    local pending = self:_recover_pending_locked()
    if not pending.ok then return pending end
    local current, current_state = read_marker(self.fs, "current")
    local previous, previous_state = read_marker(self.fs, "previous")
    if current_state == "invalid_marker" or previous_state == "invalid_marker" then return result(false, "core_recovery_required") end
    if target == current or target == previous then return result(false, "core_in_use") end
    if not self:_installed_manifest(target) then return result(false, "core_not_installed") end
    local executable, manifest = core.executable_path(target), core.manifest_path(target)
    if self.fs.remove(executable) ~= true or self.fs.remove(manifest) ~= true then return result(false, "core_delete_failed") end
    if type(self.fs.remove_dir) == "function" and self.fs.remove_dir(core.version_path(target)) ~= true then
      return result(false, "core_delete_failed")
    end
    return result(true, "core_deleted", { id = target })
  end)
end

function Manager:recover_pending()
  return self:_with_lock(function() return self:_recover_pending_locked() end)
end

function Manager:status()
  local current, current_state = read_marker(self.fs, "current")
  if current_state == "missing" then current = "system" end
  local previous, previous_state = read_marker(self.fs, "previous")
  local current_valid = current == "system"
  if current ~= "system" then
    local called, manifest = pcall(self._installed_manifest, self, current)
    current_valid = called and manifest ~= nil
  end
  local previous_valid = previous == nil or previous == "system"
  if previous and previous ~= "system" then
    local called, manifest = pcall(self._installed_manifest, self, previous)
    previous_valid = called and manifest ~= nil
  end
  local listed_versions = core.list_versions({
    list_dir = function(path) return self.fs.list_dir(path) end,
    read_file = function(path) return self.fs.read(path, core.MANIFEST_MAX_SIZE) end,
    json_parse = self.json.parse
  })
  local versions = {}
  for _, version in ipairs(listed_versions) do
    local called, manifest = pcall(self._installed_manifest, self, version.id)
    if called and manifest then versions[#versions + 1] = version end
  end
  for _, version in ipairs(versions) do
    version.current = version.id == current
    version.previous = version.id == previous
  end
  local service = "unknown"
  if type(self.exec.service_state) == "function" then
    local called, value = pcall(self.exec.service_state, self.now() + 2)
    if called and (value == "running" or value == "stopped" or value == "error") then service = value end
  end
  local current_info = { source = current == "system" and "system" or "manual", id = current }
  if current == "system" then
    local system_stat = self.fs.stat(core.system_path())
    local version_output = type(self.exec.xray_version) == "function" and self.exec.xray_version(core.system_path(), self.now() + 5) or nil
    local machine = type(self.exec.machine) == "function" and normalize_machine(self.exec.machine(self.now() + 5)) or nil
    local hash = type(self.exec.hash_file) == "function" and self.exec.hash_file(core.system_path(), self.now() + 30) or nil
    current_info.version, current_info.arch, current_info.sha256 = parse_version(version_output), machine, hash
    current_valid = type(system_stat) == "table" and system_stat.type == "reg"
      and current_info.version ~= nil and current_info.arch ~= nil and core.safe_sha256(current_info.sha256)
  else
    for _, version in ipairs(versions) do
      if version.id == current then current_info.version, current_info.arch, current_info.sha256 = version.version, version.arch, version.sha256; current_info.size = version.size; current_info.note = version.note; break end
    end
  end
  local healthy = current_state ~= "invalid_marker" and previous_state ~= "invalid_marker" and current_valid and previous_valid
  return result(healthy, healthy and "core_status" or "core_recovery_required", {
    current = current, current_info = current_info, previous = previous, versions = versions,
    status = service, recovery_required = not healthy
  })
end

function M.new(adapters)
  if type(adapters) ~= "table" or type(adapters.fs) ~= "table" or type(adapters.exec) ~= "table"
    or type(adapters.json) ~= "table" or type(adapters.now) ~= "function" or type(adapters.wall_time) ~= "function" then return nil end
  for _, name in ipairs({ "stat", "stat_nofollow", "read", "read_prefix", "exists", "mkdir", "copy_file", "write_file", "remove", "list_dir" }) do
    if type(adapters.fs[name]) ~= "function" then return nil end
  end
  for _, name in ipairs({ "hash_file", "machine", "xray_version", "run", "real_connection_checks" }) do
    if type(adapters.exec[name]) ~= "function" then return nil end
  end
  if type(adapters.json.stringify) ~= "function" or type(adapters.json.parse) ~= "function" then return nil end
  return setmetatable({ fs = adapters.fs, exec = adapters.exec, json = adapters.json,
    uci = adapters.uci, network = adapters.network, now = adapters.now, wall_time = adapters.wall_time }, Manager)
end

M.elf_arch = elf_arch
M.normalize_machine = normalize_machine
M.parse_version = parse_version

return M
