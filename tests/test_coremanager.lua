local t = require "testlib"
local manager_module = require "xc.coremanager"

local HASH = "51c3e26e4ba03f3aabcdef1234567890abcdef1234567890abcdef1234567890"
local HEADER = string.char(127) .. "ELF" .. string.char(2, 1, 1) .. string.rep("\0", 11) .. string.char(183, 0)

t.test("core manager maps ELF class and endianness to a compatible architecture", function()
  local little_mips = string.char(127) .. "ELF" .. string.char(1, 1, 1) .. string.rep("\0", 11) .. string.char(8, 0)
  local big_mips = string.char(127) .. "ELF" .. string.char(1, 2, 1) .. string.rep("\0", 11) .. string.char(0, 8)
  local wrong_class = string.char(127) .. "ELF" .. string.char(1, 1, 1) .. string.rep("\0", 11) .. string.char(183, 0)
  local bad_endian = string.char(127) .. "ELF" .. string.char(2, 3, 1) .. string.rep("\0", 11) .. string.char(183, 0)
  t.eq(manager_module.elf_arch(HEADER), "aarch64")
  t.eq(manager_module.elf_arch(little_mips), "mipsel")
  t.eq(manager_module.elf_arch(big_mips), "mips")
  t.eq(manager_module.elf_arch(wrong_class), nil)
  t.eq(manager_module.elf_arch(bad_endian), nil)
end)

local function fixture(options)
  options = options or {}
  local files = {
    ["/var/etc/xc/.core-upload-1"] = string.rep("x", options.size or 128),
    ["/var/etc/xc/config.json"] = "{}",
    ["/usr/bin/xray"] = string.rep("s", 128)
  }
  local dirs, writes, lock_state = {}, {}, false
  local read_before_lock = false
  local run_argv
  local fs = {
    stat = function(path)
      if files[path] then return { type = "reg", size = #files[path] } end
      if dirs[path] then return { type = "dir" } end
      return nil
    end,
    stat_nofollow = function(path)
      if options.symlink_path == path then return nil end
      if files[path] then return { type = "reg", size = #files[path] } end
      if dirs[path] then return { type = "dir" } end
      return nil
    end,
    read = function(path, maximum)
      if options.transaction_read_requires_lock and path == "/etc/xc/xray/transaction" and not lock_state then
        read_before_lock = true
      end
      local value = files[path]
      if value == nil then return nil, "missing" end
      if #value > maximum then return nil, "too_large" end
      return value, nil
    end,
    read_prefix = function(path, maximum)
      local value = files[path]
      if value == nil then return nil, "missing" end
      return value:sub(1, maximum), nil
    end,
    exists = function(path) return files[path] ~= nil or dirs[path] == true end,
    mkdir = function(path) dirs[path] = true; return true end,
    copy_file = function(source, destination) files[destination] = files[source]; return true end,
    write_file = function(path, content)
      if options.fail_restore_marker and path == "/etc/xc/xray/current" and content == "system\n" then return false end
      writes[path] = content; files[path] = content; return true
    end,
    chmod = function() return true end,
    fsync_dir = function() return true end,
    remove = function(path)
      if options.fail_transaction_remove and path == "/etc/xc/xray/transaction" then return false end
      files[path] = nil; writes[path] = nil; return true
    end,
    remove_dir = function(path) dirs[path] = nil; return true end,
    available_space = function() return options.available_space or 128 * 1024 * 1024 end,
    list_dir = function() return options.entries or {} end,
    acquire_lock = function()
      if options.lock_busy or lock_state then return nil end
      lock_state = true; return {}
    end,
    release_lock = function()
      lock_state = false
      return options.release_lock_ok ~= false
    end
  }
  local exec = {
    hash_file = function() return options.hash or HASH end,
    machine = function() return options.machine or "aarch64" end,
    xray_version = function() return options.version_output or "Xray 26.6.27 (Xray, Penetrates Everything.)" end,
    run = function(argv)
      run_argv = argv
      return options.config_ok ~= false
    end,
    restart = function()
      if options.throw_restart then error("restart failed") end
      if type(options.restart_sequence) == "table" and #options.restart_sequence > 0 then
        local value = table.remove(options.restart_sequence, 1)
        options.last_restart = value
        return value
      end
      options.last_restart = options.restart_ok ~= false
      return options.last_restart
    end,
    service_state = function() return options.last_restart == false and "stopped" or "running" end,
    listener_ready = function() return options.ready ~= false end,
    real_connection_check = function() return options.healthy ~= false and { ok = true, time = 1, status = 204 } or { ok = false } end
  }
  local json = {
    parse = function(text)
      local id, version, arch, size, sha256, uploaded_at = text:match('"id":"([^"]+)".-"version":"([^"]+)".-"arch":"([^"]+)".-"size":(%d+).-"sha256":"([^"]+)".-"uploaded_at":(%d+)')
      if not id then return nil end
      return { id = id, version = version, arch = arch, size = tonumber(size), sha256 = sha256, uploaded_at = tonumber(uploaded_at) }
    end,
    stringify = function(value)
      return '{"id":"' .. value.id .. '","version":"' .. value.version .. '","arch":"' .. value.arch
        .. '","size":' .. tostring(value.size) .. ',"sha256":"' .. value.sha256 .. '","uploaded_at":' .. tostring(value.uploaded_at) .. '}'
    end
  }
  local adapters = {
    fs = fs, exec = exec, json = json,
    uci = { get_global = function() return {
      enabled = options.enabled or "0", socks_port = "7890", http_port = "10809", health_url = options.health_url or "https://health.invalid"
    } end },
    network = function() return "192.0.2.1" end,
    now = function() return 100 end, wall_time = function() return 1700000000 end
  }
  return manager_module.new(adapters), files, writes, adapters, function() return read_before_lock end, function() return run_argv end
end

t.test("core manager rejects wrong hash and architecture", function()
  local manager, files = fixture({ hash = string.rep("0", 64) })
  files["/var/etc/xc/.core-upload-1"] = HEADER .. string.rep("x", 128)
  local result = manager:validate("/var/etc/xc/.core-upload-1", HASH)
  t.eq(result.ok, false)
  t.eq(result.code, "core_hash_mismatch")

  manager, files = fixture({ machine = "x86_64" })
  files["/var/etc/xc/.core-upload-1"] = HEADER .. string.rep("x", 128)
  result = manager:validate("/var/etc/xc/.core-upload-1")
  t.eq(result.ok, false)
  t.eq(result.code, "core_arch_mismatch")
end)

t.test("core manager accepts matching ELF and current config", function()
  local manager, files, _, _, _, get_run_argv = fixture()
  files["/var/etc/xc/.core-upload-1"] = HEADER .. string.rep("x", 128)
  local result = manager:validate("/var/etc/xc/.core-upload-1", HASH, "test build")
  t.eq(result.ok, true)
  t.eq(result.manifest.version, "26.6.27")
  t.eq(result.manifest.arch, "aarch64")
  t.eq(result.manifest.sha256, HASH)
  t.eq(result.manifest.validation, "full")
  t.eq(table.concat(get_run_argv(), "|"), "/var/etc/xc/.core-upload-1|run|-test|-format|json|-c|/var/etc/xc/config.json")
end)

t.test("core manager rejects a core that cannot validate the current config", function()
  local manager, files = fixture({ config_ok = false })
  files["/var/etc/xc/.core-upload-1"] = HEADER .. string.rep("x", 128)
  t.eq(manager:validate("/var/etc/xc/.core-upload-1").code, "core_config_invalid")
end)

t.test("core manager installs only validated versions", function()
  local manager, files, writes = fixture()
  files["/var/etc/xc/.core-upload-1"] = HEADER .. string.rep("x", 128)
  local checked = assert(manager:validate("/var/etc/xc/.core-upload-1"))
  local installed = manager:install("/var/etc/xc/.core-upload-1", checked.manifest)
  t.eq(installed.ok, true)
  t.eq(installed.version.id, "v26_6_27-aarch64-51c3e26e4ba03f3a")
  t.truthy(writes["/etc/xc/xray/versions/v26_6_27-aarch64-51c3e26e4ba03f3a/manifest.json"])
end)

t.test("core manager uses safe validation limits", function()
  local manager = fixture({ size = 64 * 1024 * 1024 + 1 })
  local result = manager:validate("/var/etc/xc/.core-upload-1")
  t.eq(result.ok, false)
  t.eq(result.code, "core_upload_too_large")
  result = manager:validate("/tmp/../etc/passwd")
  t.eq(result.ok, false)
  t.eq(result.code, "core_invalid_upload")
end)

t.test("core manager rejects uploads when the core store is low on space", function()
  local manager, files = fixture({ available_space = 1024 })
  files["/var/etc/xc/.core-upload-1"] = HEADER .. string.rep("x", 128)
  t.eq(manager:validate("/var/etc/xc/.core-upload-1").code, "core_disk_space_low")
end)

t.test("core manager activates a staged version without replacing system xray", function()
  local manager, files = fixture()
  local system_xray = files["/usr/bin/xray"]
  files["/var/etc/xc/.core-upload-1"] = HEADER .. string.rep("x", 128)
  local checked = assert(manager:validate("/var/etc/xc/.core-upload-1"))
  assert(manager:install("/var/etc/xc/.core-upload-1", checked.manifest).ok)
  local activated = manager:activate(checked.manifest.id)
  t.eq(activated.ok, true)
  t.eq(activated.code, "core_activated")
  t.eq(manager:status().current, checked.manifest.id)
  t.eq(files["/usr/bin/xray"], system_xray)
end)

t.test("core manager restores the previous marker after activation failure", function()
  local manager, files = fixture({ enabled = "1", restart_sequence = { false, true } })
  files["/var/etc/xc/.core-upload-1"] = HEADER .. string.rep("x", 128)
  local checked = assert(manager:validate("/var/etc/xc/.core-upload-1"))
  assert(manager:install("/var/etc/xc/.core-upload-1", checked.manifest).ok)
  local failed = manager:activate(checked.manifest.id)
  t.eq(failed.ok, false)
  t.eq(failed.code, "core_recovered")
  t.eq(manager:status().current, "system")
end)

t.test("core manager rejects invalid expected SHA-256 and note", function()
  local manager, files = fixture()
  files["/var/etc/xc/.core-upload-1"] = HEADER .. string.rep("x", 128)
  t.eq(manager:validate("/var/etc/xc/.core-upload-1", "not-a-hash").code, "core_hash_invalid")
  t.eq(manager:validate("/var/etc/xc/.core-upload-1", "").ok, true)
  t.eq(manager:validate("/var/etc/xc/.core-upload-1", HASH, "ok note").ok, true)
  t.eq(manager:validate("/var/etc/xc/.core-upload-1", HASH, "bad\1note").code, "core_note_invalid")
  t.eq(manager:validate("/var/etc/xc/.core-upload-1", HASH, string.rep("x", 300)).code, "core_note_invalid")
end)

t.test("core manager reports already active targets", function()
  local manager, files = fixture()
  files["/var/etc/xc/.core-upload-1"] = HEADER .. string.rep("x", 128)
  local checked = assert(manager:validate("/var/etc/xc/.core-upload-1"))
  assert(manager:install("/var/etc/xc/.core-upload-1", checked.manifest).ok)
  t.eq(manager:activate("system").code, "core_already_active")
  assert(manager:activate(checked.manifest.id).ok)
  t.eq(manager:activate(checked.manifest.id).code, "core_already_active")
end)

t.test("core manager rolls back to the previous core", function()
  local manager, files = fixture()
  files["/var/etc/xc/.core-upload-1"] = HEADER .. string.rep("x", 128)
  local checked = assert(manager:validate("/var/etc/xc/.core-upload-1"))
  assert(manager:install("/var/etc/xc/.core-upload-1", checked.manifest).ok)
  assert(manager:activate(checked.manifest.id).ok)
  local rolled_back = manager:rollback()
  t.eq(rolled_back.ok, true)
  t.eq(rolled_back.code, "core_activated")
  t.eq(manager:status().current, "system")
end)

t.test("core manager rejects rollback when no previous core exists", function()
  local manager = fixture()
  t.eq(manager:rollback().code, "core_no_rollback")
end)

t.test("core manager rolls back a manual core to system when previous marker is absent", function()
  local manager, files = fixture()
  files["/var/etc/xc/.core-upload-1"] = HEADER .. string.rep("x", 128)
  local checked = assert(manager:validate("/var/etc/xc/.core-upload-1"))
  assert(manager:install("/var/etc/xc/.core-upload-1", checked.manifest).ok)
  assert(manager:activate(checked.manifest.id).ok)
  files["/etc/xc/xray/previous"] = nil
  local rolled_back = manager:rollback()
  t.eq(rolled_back.ok, true)
  t.eq(rolled_back.code, "core_activated")
  t.eq(rolled_back.current, "system")
  t.eq(manager:status().current, "system")
end)

t.test("core manager refuses to delete the current or previous core", function()
  local manager, files = fixture()
  files["/var/etc/xc/.core-upload-1"] = HEADER .. string.rep("x", 128)
  local checked = assert(manager:validate("/var/etc/xc/.core-upload-1"))
  assert(manager:install("/var/etc/xc/.core-upload-1", checked.manifest).ok)
  assert(manager:activate(checked.manifest.id).ok)
  t.eq(manager:delete(checked.manifest.id).code, "core_in_use")
  assert(manager:activate("system").ok)
  t.eq(manager:delete(checked.manifest.id).code, "core_in_use")
end)

t.test("core manager deletes only inactive versions", function()
  local manager, files = fixture()
  files["/var/etc/xc/.core-upload-1"] = HEADER .. string.rep("x", 128)
  local checked = assert(manager:validate("/var/etc/xc/.core-upload-1"))
  assert(manager:install("/var/etc/xc/.core-upload-1", checked.manifest).ok)
  local deleted = manager:delete(checked.manifest.id)
  t.eq(deleted.ok, true)
  t.eq(files["/etc/xc/xray/versions/" .. checked.manifest.id .. "/xray"], nil)
  t.eq(files["/etc/xc/xray/versions/" .. checked.manifest.id .. "/manifest.json"], nil)
  t.eq(manager:delete(checked.manifest.id).code, "core_not_installed")
end)

t.test("core manager recovers a pending interrupted transaction", function()
  local manager, files, writes = fixture()
  local id = "v26_6_27-aarch64-51c3e26e4ba03f3a"
  files["/usr/bin/xray"] = string.rep("s", 128)
  files["/etc/xc/xray/current"] = id .. "\n"
  files["/etc/xc/xray/transaction"] = "xc-core-transaction-v1\nold=system\ntarget=" .. id .. "\n"
  local recovered = manager:recover_pending()
  t.eq(recovered.ok, true)
  t.eq(recovered.code, "core_recovered")
  t.eq(writes["/etc/xc/xray/current"], "system\n")
  t.eq(files["/etc/xc/xray/transaction"], nil)
  t.eq(manager:status().current, "system")
end)

t.test("core manager restores the preserved previous marker after interruption", function()
  local manager, files, writes = fixture()
  local id = "v26_6_27-aarch64-51c3e26e4ba03f3a"
  local previous = "v25_1_0-aarch64-0123456789abcdef"
  files["/usr/bin/xray"] = string.rep("s", 128)
  files["/etc/xc/xray/current"] = id .. "\n"
  files["/etc/xc/xray/previous"] = "system\n"
  files["/etc/xc/xray/versions/" .. previous .. "/xray"] = string.rep("p", 128)
  files["/etc/xc/xray/versions/" .. previous .. "/manifest.json"] =
    '{"id":"' .. previous .. '","version":"25.1.0","arch":"aarch64","size":128,"sha256":"' .. HASH .. '","uploaded_at":1}'
  files["/etc/xc/xray/transaction"] = "xc-core-transaction-v2\nold=system\ntarget=" .. id
    .. "\nprevious=" .. previous .. "\n"
  local recovered = manager:recover_pending()
  t.eq(recovered.ok, true)
  t.eq(writes["/etc/xc/xray/current"], "system\n")
  t.eq(writes["/etc/xc/xray/previous"], previous .. "\n")
  t.eq(files["/etc/xc/xray/transaction"], nil)
end)

t.test("core manager refuses to clear an interrupted transaction with a missing core", function()
  local manager, files = fixture()
  files["/etc/xc/xray/transaction"] = "xc-core-transaction-v2\nold=v25_1_0-aarch64-0123456789abcdef\ntarget=system\nprevious=none\n"
  local recovered = manager:recover_pending()
  t.eq(recovered.ok, false)
  t.eq(recovered.code, "core_recovery_required")
  t.truthy(files["/etc/xc/xray/transaction"])
end)

t.test("core manager rejects an invalid pending transaction", function()
  local manager, files = fixture()
  files["/etc/xc/xray/transaction"] = "garbage"
  t.eq(manager:recover_pending().code, "core_recovery_required")
  files["/etc/xc/xray/transaction"] = "xc-core-transaction-v1\nold=../../evil\ntarget=system\n"
  t.eq(manager:recover_pending().code, "core_recovery_required")
end)

t.test("core manager serializes deletion behind the shared lock", function()
  local manager, files = fixture({ lock_busy = true })
  files["/var/etc/xc/.core-upload-1"] = HEADER .. string.rep("x", 128)
  local checked = assert(manager:validate("/var/etc/xc/.core-upload-1"))
  assert(manager:install("/var/etc/xc/.core-upload-1", checked.manifest).ok)
  t.eq(manager:delete(checked.manifest.id).code, "core_busy")
end)

t.test("core manager reads pending transactions only after acquiring the lock", function()
  local manager, files, _, _, read_before_lock = fixture({ transaction_read_requires_lock = true })
  files["/etc/xc/xray/transaction"] = "xc-core-transaction-v1\nold=system\ntarget=v26_6_27-aarch64-51c3e26e4ba03f3a\n"
  manager:recover_pending()
  t.eq(read_before_lock(), false)
end)

t.test("core manager fails closed when recovery marker cannot be restored", function()
  local manager, files = fixture({ enabled = "1", restart_sequence = { false, true }, fail_restore_marker = true })
  files["/var/etc/xc/.core-upload-1"] = HEADER .. string.rep("x", 128)
  local checked = assert(manager:validate("/var/etc/xc/.core-upload-1"))
  assert(manager:install("/var/etc/xc/.core-upload-1", checked.manifest).ok)
  local failed = manager:activate(checked.manifest.id)
  t.eq(failed.code, "core_recovery_failed")
  t.eq(failed.recovery_required, true)
end)

t.test("core manager reports an uncleared transaction after activation", function()
  local manager, files = fixture({ fail_transaction_remove = true })
  files["/var/etc/xc/.core-upload-1"] = HEADER .. string.rep("x", 128)
  local checked = assert(manager:validate("/var/etc/xc/.core-upload-1"))
  assert(manager:install("/var/etc/xc/.core-upload-1", checked.manifest).ok)
  local activated = manager:activate(checked.manifest.id)
  t.eq(activated.ok, false)
  t.eq(activated.code, "core_recovery_required")
end)

t.test("core manager preserves pending recovery details when lock release fails", function()
  local manager, files = fixture({ fail_transaction_remove = true, release_lock_ok = false })
  files["/var/etc/xc/.core-upload-1"] = HEADER .. string.rep("x", 128)
  local checked = assert(manager:validate("/var/etc/xc/.core-upload-1"))
  assert(manager:install("/var/etc/xc/.core-upload-1", checked.manifest).ok)
  local failed = manager:activate(checked.manifest.id)
  t.eq(failed.code, "core_recovery_required")
  t.eq(failed.recovery_required, true)
  t.truthy(files["/etc/xc/xray/transaction"])
end)

t.test("core manager exposes recovery when activation throws after writing a transaction", function()
  local manager, files = fixture({ throw_restart = true, enabled = "1" })
  files["/var/etc/xc/.core-upload-1"] = HEADER .. string.rep("x", 128)
  local checked = assert(manager:validate("/var/etc/xc/.core-upload-1"))
  assert(manager:install("/var/etc/xc/.core-upload-1", checked.manifest).ok)
  local failed = manager:activate(checked.manifest.id)
  t.eq(failed.code, "core_recovery_required")
  t.eq(failed.recovery_required, true)
  t.truthy(files["/etc/xc/xray/transaction"])
end)

t.test("core manager requires a health URL when runtime health is enabled", function()
  local manager, files = fixture({ enabled = "1", health_url = "" })
  files["/var/etc/xc/.core-upload-1"] = HEADER .. string.rep("x", 128)
  local checked = assert(manager:validate("/var/etc/xc/.core-upload-1"))
  assert(manager:install("/var/etc/xc/.core-upload-1", checked.manifest).ok)
  t.eq(manager:activate(checked.manifest.id).code, "core_recovery_failed")
end)

t.test("core manager fails closed when the current manual core is missing or tampered", function()
  local manager, files, _, adapters = fixture()
  files["/var/etc/xc/.core-upload-1"] = HEADER .. string.rep("x", 128)
  local checked = assert(manager:validate("/var/etc/xc/.core-upload-1"))
  assert(manager:install("/var/etc/xc/.core-upload-1", checked.manifest).ok)
  assert(manager:activate(checked.manifest.id).ok)
  adapters.exec.hash_file = function(path)
    if path:match("/etc/xc/xray/versions/") then return string.rep("0", 64) end
    return HASH
  end
  local status = manager:status()
  t.eq(status.ok, false)
  t.eq(status.recovery_required, true)
  t.eq(status.current, checked.manifest.id)
end)

t.test("core manager rejects a manual manifest for another device architecture", function()
  local id = "v26_6_27-aarch64-51c3e26e4ba03f3a"
  local manager, files = fixture({ entries = { id }, machine = "x86_64" })
  files["/etc/xc/xray/current"] = id .. "\n"
  files["/etc/xc/xray/versions/" .. id .. "/xray"] = string.rep("x", 128)
  files["/etc/xc/xray/versions/" .. id .. "/manifest.json"] =
    '{"id":"' .. id .. '","version":"26.6.27","arch":"aarch64","size":128,"sha256":"' .. HASH .. '","uploaded_at":1}'
  local status = manager:status()
  t.eq(status.ok, false)
  t.eq(status.recovery_required, true)
  t.eq(#status.versions, 0)
end)

t.test("core manager status lists only complete installed versions", function()
  local id = "v26_6_27-aarch64-51c3e26e4ba03f3a"
  local manager, files = fixture({ entries = { id } })
  files["/var/etc/xc/.core-upload-1"] = HEADER .. string.rep("x", 128)
  local checked = assert(manager:validate("/var/etc/xc/.core-upload-1"))
  assert(manager:install("/var/etc/xc/.core-upload-1", checked.manifest).ok)
  t.eq(#manager:status().versions, 1)
  files["/etc/xc/xray/versions/" .. id .. "/xray"] = nil
  t.eq(#manager:status().versions, 0)
end)

t.test("core manager rejects a symlinked manual executable", function()
  local id = "v26_6_27-aarch64-51c3e26e4ba03f3a"
  local executable = "/etc/xc/xray/versions/" .. id .. "/xray"
  local manager, files = fixture({ entries = { id }, symlink_path = executable })
  files["/etc/xc/xray/current"] = id .. "\n"
  files[executable] = string.rep("x", 128)
  files["/etc/xc/xray/versions/" .. id .. "/manifest.json"] =
    '{"id":"' .. id .. '","version":"26.6.27","arch":"aarch64","size":128,"sha256":"' .. HASH .. '","uploaded_at":1}'
  local status = manager:status()
  t.eq(status.ok, false)
  t.eq(status.recovery_required, true)
  t.eq(#status.versions, 0)
end)

t.test("core manager marks a missing system core as recovery required", function()
  local manager, files = fixture()
  files["/usr/bin/xray"] = nil
  local status = manager:status()
  t.eq(status.ok, false)
  t.eq(status.recovery_required, true)
end)

return true
