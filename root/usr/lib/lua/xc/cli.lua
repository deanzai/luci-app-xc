local schema = require "xc.schema"

local M = {}
local MAX_IMPORT = 524288
local MAX_CURRENT = 256
local MIGRATION_CANDIDATE = "/var/etc/xc/migration-candidate.json"
local MIGRATION_MARKER = "/etc/xc/migration-complete"

local messages = {
  invalid_arguments = "invalid command arguments",
  import_failed = "import input is invalid",
  import_staged_failed = "import could not be staged",
  import_commit_failed = "import could not be committed",
  migration_failed = "legacy migration failed",
  validation_failed = "Xray rejected the candidate configuration"
}

local function response(ok, code, extra)
  local value = { ok = ok, code = code, message = messages[code] or code:gsub("_", " ") }
  for key, item in pairs(extra or {}) do value[key] = item end
  return value
end

local function trim(value)
  return type(value) == "string" and value:match("^%s*(.-)%s*$") or nil
end

local function safe_summary(node)
  return { id = node.id, name = node.name, protocol = node.protocol, enabled = node.enabled ~= false }
end

local function safe_path(path)
  return type(path) == "string" and #path > 1 and #path <= 512 and path:sub(1, 1) == "/"
    and not path:find("[%z\1-\31\127]") and not path:find("/%.%./") and not path:match("/%.%.$")
end

local function safe_result(value)
  if type(value) ~= "table" then return response(false, "internal_error") end
  local output = { ok = value.ok == true, code = tostring(value.code or "internal_error"), message = tostring(value.message or "runtime operation failed") }
  for _, key in ipairs({ "active_node", "active_state", "service", "operation", "lock", "recovery_required", "exit_ip", "node", "nodes", "path", "listen", "listeners", "count" }) do
    if value[key] ~= nil then output[key] = value[key] end
  end
  if type(output.node) == "table" then output.node = safe_summary(output.node) end
  if type(output.nodes) == "table" then
    local summaries = {}
    for index, node in ipairs(output.nodes) do if index <= 256 and type(node) == "table" then summaries[#summaries + 1] = safe_summary(node) end end
    output.nodes = summaries
  end
  if type(value.warnings) == "table" then
    output.warnings = {}
    for index, warning in ipairs(value.warnings) do
      if index > 256 then break end
      if type(warning) == "string" and #warning <= 128 and not warning:find("[%z\1-\31\127]") then output.warnings[#output.warnings + 1] = warning end
    end
  end
  return output
end

local function emit(deps, value)
  local ok, encoded = pcall(deps.json.stringify, value)
  if not ok or type(encoded) ~= "string" then encoded = '{"ok":false,"code":"internal_error","message":"runtime operation failed"}' end
  deps.output(encoded)
end

local function invalid(deps)
  local value = response(false, "invalid_arguments")
  emit(deps, value)
  return 2
end

local function finish(deps, value)
  value = safe_result(value)
  emit(deps, value)
  return value.ok and 0 or 1
end

local function parse_file(path, deps)
  if not safe_path(path) then return nil end
  local text, read_error = deps.fs.read(path, MAX_IMPORT)
  if type(text) ~= "string" then return nil, read_error end
  local parsed = deps.importer.parse(text, deps.json)
  if type(parsed) ~= "table" or type(parsed.nodes) ~= "table" then return nil end
  local normalized = {}
  for _, node in ipairs(parsed.nodes) do
    local value = schema.normalize(node)
    if not value then return nil end
    normalized[#normalized + 1] = value
  end
  return normalized, parsed.warnings or {}
end

local function preview(path, deps)
  local nodes, warnings = parse_file(path, deps)
  if not nodes then return response(false, "import_failed") end
  local unique, duplicate_warnings = deps.importer.deduplicate(nodes, deps.uci.list_nodes() or {})
  if not unique then return response(false, "import_failed") end
  for _, warning in ipairs(duplicate_warnings or {}) do warnings[#warnings + 1] = warning end
  local summaries = {}
  for _, node in ipairs(unique) do summaries[#summaries + 1] = safe_summary(node) end
  return response(true, "import_preview", { count = #summaries, nodes = summaries, warnings = warnings })
end

local function import_commit(path, deps)
  local nodes = parse_file(path, deps)
  if not nodes then return response(false, "import_failed") end
  local unique, warnings = deps.importer.deduplicate(nodes, deps.uci.list_nodes() or {})
  if not unique then return response(false, "import_failed") end
  if #unique > 0 then
    local recovered = deps.runtime:recover_pending()
    if not recovered.ok then return recovered end
    local stage_call, staged = pcall(deps.uci.stage_nodes, unique)
    if not stage_call or not staged then pcall(deps.uci.revert); return response(false, "import_staged_failed") end
    local commit_call, committed = pcall(deps.uci.commit)
    if not commit_call or not committed then pcall(deps.uci.revert); return response(false, "import_commit_failed") end
  end
  return response(true, "imported", { count = #unique, warnings = warnings or {} })
end

local function legacy_global(existing, active)
  existing = existing or {}
  return {
    enabled = "1", active_node = active,
    listen_mode = existing.listen_mode or "lan", listen_address = existing.listen_address or "",
    socks_port = existing.socks_port or "7890", http_port = existing.http_port or "10809",
    probe_concurrency = existing.probe_concurrency or "3", probe_timeout = existing.probe_timeout or "3",
    probe_url = existing.probe_url or "https://www.gstatic.com/generate_204",
    health_url = existing.health_url or "https://api.ipify.org", health_timeout = existing.health_timeout or "15"
  }
end

local function checksum(value)
  local hash = 5381
  for index = 1, #value do hash = (hash * 33 + value:byte(index)) % 2147483647 end
  return string.format("%08x", hash)
end

local function migration_marker(directory, text)
  local source = directory:match("/([^/]+)$")
  if not source or #source > 128 or not source:match("^[0-9A-Za-z_.+-]+$") then return nil end
  return table.concat({ "xc-migration-v1", source, tostring(#text), checksum(text), "" }, "\n")
end

local function migrate_legacy(directory, deps)
  if type(directory) ~= "string" or not directory:match("^/[%w%._/%-%+]+$") or directory:find("/%.%./") then
    return response(false, "migration_failed")
  end
  local complete = deps.fs.read(directory .. "/complete", 1)
  if type(complete) ~= "string" then return response(false, "migration_failed") end
  local text = deps.fs.read(directory .. "/nodes.json", MAX_IMPORT)
  if type(text) ~= "string" then return response(false, "migration_failed") end
  local current_text, current_error = deps.fs.read(directory .. "/current", MAX_CURRENT)
  if current_text == nil and current_error ~= "missing" then return response(false, "migration_failed") end
  local marker_text = migration_marker(directory, text .. "\0" .. (current_text or ""))
  if not marker_text then return response(false, "migration_failed") end
  local ok, legacy = pcall(deps.json.parse, text)
  if not ok or type(legacy) ~= "table" then return response(false, "migration_failed") end
  local nodes = deps.importer.parse_legacy(legacy)
  if type(nodes) ~= "table" or #nodes == 0 then return response(false, "migration_failed") end
  for index, node in ipairs(nodes) do
    local normalized = schema.normalize(node)
    if not normalized then return response(false, "migration_failed") end
    nodes[index] = normalized
  end

  local current = trim(current_text)
  local active
  if current and type(legacy.nodes) == "table" and legacy.nodes[current] ~= nil then
    local keys = {}
    for key in pairs(legacy.nodes) do keys[#keys + 1] = key end
    table.sort(keys, function(left, right) return tostring(left) < tostring(right) end)
    for index, key in ipairs(keys) do if tostring(key) == current then active = nodes[index].id; break end end
  end
  if not active and #nodes == 1 then active = nodes[1].id end
  return deps.runtime:exclusive("migration", function(capability)
    local committed, dirty = false, false
    local operation_ok, value = xpcall(function()
      local completed, marker_error = deps.fs.read(MIGRATION_MARKER, 1024)
      if completed ~= nil then
        if type(completed) ~= "string" or not completed:match("^xc%-migration%-v1\n[0-9A-Za-z_.+%-]+\n%d+\n%x%x%x%x%x%x%x%x\n$") then
          return response(false, "migration_failed")
        end
        return response(true, "migrated", { already_migrated = true })
      end
      if marker_error ~= "missing" then return response(false, "migration_failed") end

      local existing_call, existing = pcall(deps.uci.list_nodes)
      if not existing_call or type(existing) ~= "table" then return response(false, "migration_failed") end
      if #existing > 0 then
        local marker_call, marker_written = pcall(capability.write, MIGRATION_MARKER, marker_text)
        if not marker_call or not marker_written then return response(false, "migration_failed") end
        return response(true, "migrated", { existing_config = true })
      end

      local global = legacy_global(deps.uci.get_global(), active)
      dirty = true
      local stage_call, staged = pcall(deps.uci.stage_replace, global, nodes)
      if not stage_call or not staged then return response(false, "migration_failed") end

      local render_call, rendered = pcall(capability.render, active, MIGRATION_CANDIDATE)
      if not render_call or type(rendered) ~= "table" or not rendered.ok then
        local render_code = render_call and type(rendered) == "table" and rendered.code or "validation_failed"
        return response(false, render_code)
      end
      local test_call, tested = pcall(deps.exec.run,
        { "/usr/bin/xray", "run", "-test", "-c", MIGRATION_CANDIDATE }, deps.now() + 30)
      if not test_call or not tested then return response(false, "validation_failed") end

      local commit_call, commit_result = pcall(deps.uci.commit)
      if not commit_call or not commit_result then return response(false, "migration_failed") end
      committed = true
      local marker_call, marker_written = pcall(capability.write, MIGRATION_MARKER, marker_text)
      if not marker_call or not marker_written then return response(false, "migration_failed") end
      return response(true, "migrated", { count = #nodes, active_node = active })
    end, function() return response(false, "migration_failed") end)
    if not operation_ok or type(value) ~= "table" then value = response(false, "migration_failed") end
    if not value.ok and dirty and not committed then pcall(deps.uci.revert) end
    local cleanup_call, cleaned = pcall(deps.fs.remove, MIGRATION_CANDIDATE)
    if not cleanup_call or not cleaned then return response(false, "migration_failed") end
    return value
  end)
end

function M.main(argv, deps)
  argv = argv or {}
  if type(deps) ~= "table" or type(deps.output) ~= "function" or type(deps.json) ~= "table" then return 2 end
  local command = argv[1]
  if command == "status" and #argv == 1 then return finish(deps, deps.runtime:status()) end
  if command == "switch" and #argv == 2 and schema.safe_section_id(argv[2]) then return finish(deps, deps.runtime:switch(argv[2])) end
  if command == "rollback" and #argv == 1 then return finish(deps, deps.runtime:rollback()) end
  if command == "test" and #argv == 1 then return finish(deps, deps.runtime:test_current()) end
  if command == "recover-pending" and #argv == 1 then return finish(deps, deps.runtime:recover_pending()) end
  if command == "render" and #argv == 3 and argv[2] == "--output" and safe_path(argv[3]) then return finish(deps, deps.runtime:render(nil, argv[3])) end
  if command == "import-preview" and #argv == 2 and safe_path(argv[2]) then return finish(deps, preview(argv[2], deps)) end
  if command == "import" and #argv == 2 and safe_path(argv[2]) then return finish(deps, import_commit(argv[2], deps)) end
  if command == "migrate-legacy" and #argv == 2 then return finish(deps, migrate_legacy(argv[2], deps)) end
  return invalid(deps)
end

return M
