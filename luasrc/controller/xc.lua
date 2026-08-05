module("luci.controller.xc", package.seeall)

local http = require "luci.http"
local jsonc = require "luci.jsonc"
local schema = require "xc.schema"
local platform = require "xc.platform"
local runtime_module = require "xc.runtime"
local coremanager_module = require "xc.coremanager"
local importer = require "xc.importer"
local probe_module = require "xc.probe"
local logview = require "xc.logview"

local REQUEST_BODY_MAX = 512 * 1024
local CORE_UPLOAD_MAX = 64 * 1024 * 1024
local CORE_REQUEST_MAX = CORE_UPLOAD_MAX + 1024 * 1024
local LOG_READ_MAX = 256 * 1024

local messages = {
  busy = "Another XC operation is in progress.",
  core_activate_failed = "The Xray core could not be activated.",
  core_already_active = "The selected Xray core is already active.",
  core_arch_mismatch = "The uploaded Xray core architecture does not match this device.",
  core_config_invalid = "The current Xray configuration was rejected by the uploaded core.",
  core_disk_space_low = "There is not enough storage space for this Xray core.",
  core_hash_failed = "The uploaded Xray core checksum could not be calculated.",
  core_hash_invalid = "The expected SHA-256 value is invalid.",
  core_hash_mismatch = "The uploaded Xray core checksum does not match.",
  core_install_failed = "The validated Xray core could not be installed.",
  core_in_use = "The selected Xray core is currently in use or reserved for rollback.",
  core_invalid_elf = "The uploaded file is not a supported Xray ELF executable.",
  core_invalid_target = "The selected Xray core is invalid.",
  core_invalid_upload = "The Xray core upload is invalid.",
  core_manifest_invalid = "The Xray core metadata is invalid.",
  core_no_rollback = "No Xray core rollback version is available.",
  core_not_installed = "The selected Xray core is not installed or has changed.",
  core_note_invalid = "The Xray core note is invalid.",
  core_recovered = "The Xray core activation failed and the previous core was restored.",
  core_recovery_failed = "The Xray core failed and automatic recovery also failed.",
  core_recovery_required = "Xray core recovery is required before another core operation.",
  core_runtime_unavailable = "Xray core management is unavailable on this device.",
  core_upload_too_large = "The uploaded Xray core is too large.",
  core_delete_failed = "The Xray core could not be deleted.",
  core_version_invalid = "The Xray core version could not be verified.",
  fast_switch_unavailable = "Fast node switching is unavailable.",
  fast_switch_api_failed = "The fast node switching API failed.",
  fast_switch_not_applied = "The fast node switch was not applied.",
  fast_switch_commit_failed = "The fast node selection could not be saved.",
  fast_switch_recovery_required = "Fast node selection recovery is required.",
  fast_switch_target_invalid = "The fast node selection target is invalid.",
  commit_unknown = "The save result could not be confirmed.",
  committed_hardening_failed = "The configuration was saved but its file mode could not be confirmed.",
  commit_failed = "The configuration could not be saved.",
  import_failed = "The import could not be completed.",
  internal_error = "The request could not be completed.",
  invalid_request = "The request is invalid.",
  disabled_node = "The selected node is disabled.",
  invalid_node = "The selected node is invalid.",
  method_not_allowed = "This action requires POST.",
  missing_runtime = "No active runtime configuration is available.",
  missing_node = "The selected node does not exist.",
  not_implemented = "This capability is not available yet.",
  no_rollback_state = "No rollback state is available.",
  request_too_large = "The request body is too large.",
  recovery_required = "An interrupted runtime transaction must be recovered first.",
  test_failed = "The current node health test failed.",
  unsupported_node = "The selected node cannot be probed safely.",
  validation_failed = "The request did not pass validation."
}

local failure_status = {
  validation_failed = 400, invalid_node = 400, invalid_request = 400,
  missing_node = 404, no_rollback_state = 404,
  method_not_allowed = 405, busy = 409, disabled_node = 409,
  request_too_large = 413, not_implemented = 501, recovery_required = 409,
  unsupported_node = 422, missing_runtime = 404, test_failed = 502,
  fast_switch_target_invalid = 400, fast_switch_api_failed = 502,
  fast_switch_not_applied = 502, fast_switch_commit_failed = 500,
  fast_switch_unavailable = 503, fast_switch_recovery_required = 503,
  core_hash_invalid = 400, core_invalid_upload = 400, core_invalid_target = 400, core_note_invalid = 400,
  core_arch_mismatch = 422, core_invalid_elf = 422, core_config_invalid = 422, core_hash_mismatch = 422,
  core_disk_space_low = 507,
  core_upload_too_large = 413, core_busy = 409, core_no_rollback = 404, core_not_installed = 404,
  core_already_active = 409, core_recovery_required = 409, core_recovered = 502, core_recovery_failed = 503,
  core_activate_failed = 502, core_install_failed = 500, core_manifest_invalid = 422, core_version_invalid = 422,
  core_hash_failed = 502, core_runtime_unavailable = 501, core_in_use = 409, core_delete_failed = 500
}

local status_text = {
  [400] = "Bad Request", [404] = "Not Found", [405] = "Method Not Allowed",
  [409] = "Conflict", [413] = "Content Too Large", [422] = "Unprocessable Content", [500] = "Internal Server Error",
  [501] = "Not Implemented", [502] = "Bad Gateway", [503] = "Service Unavailable",
  [507] = "Insufficient Storage"
}

local INTERNAL_ERROR_JSON = '{"ok":false,"code":"internal_error","message":"The request could not be completed."}'

local function respond(payload)
  http.prepare_content("application/json")
  local encoded_ok, encoded = pcall(jsonc.stringify, payload)
  if not encoded_ok or type(encoded) ~= "string" or encoded == "" then
    http.status(500, status_text[500])
    http.write(INTERNAL_ERROR_JSON)
    return false
  end
  http.write(encoded)
  return true
end

local function success(data)
  respond({ ok = true, data = data or {} })
end

local function failure(code)
  if type(code) ~= "string" or not code:match("^[a-z][a-z_]*$") then code = "internal_error" end
  local status = failure_status[code] or 500
  http.status(status, status_text[status])
  respond({ ok = false, code = code, message = messages[code] or "The request failed safely." })
end

function index()
  local function action_target(action)
    -- Lua 5.1's dispatcher reads name/argv while the 24.10 ucode bridge
    -- reads module/function. Keep both descriptors in sync so the same
    -- controller works on every supported LuCI generation. Do not provide
    -- an empty Lua parameters table: the ucode bridge sees it as an object,
    -- not an iterable array.
    return {
      type = "call",
      name = action,
      argv = {},
      module = "luci.controller.xc",
      ["function"] = action
    }
  end

  local function post_entry(path, action)
    local target = action_target(action)
    target.post = true
    local node = entry(path, target)
    node.leaf = true
    return node
  end
  local root = entry({ "admin", "services", "xc" }, alias("admin", "services", "xc", "settings"), _("Xray node switching"), 60)
  root.dependent = true

  entry({ "admin", "services", "xc", "settings" }, cbi("xc/settings"), _("Settings"), 10).leaf = true
  entry({ "admin", "services", "xc", "nodes" }, cbi("xc/nodes"), _("Nodes"), 20).leaf = true
  entry({ "admin", "services", "xc", "node" }, cbi("xc/node"), nil).leaf = true
  entry({ "admin", "services", "xc", "core" }, form("xc/core"), _("Xray core"), 25).leaf = true
  entry({ "admin", "services", "xc", "log" }, form("xc/log"), _("Log"), 30).leaf = true

  entry({ "admin", "services", "xc", "status" }, action_target("action_status")).leaf = true
  entry({ "admin", "services", "xc", "core-status" }, action_target("action_core_status")).leaf = true
  post_entry({ "admin", "services", "xc", "probe" }, "action_probe")
  post_entry({ "admin", "services", "xc", "test-current" }, "action_test_current")
  post_entry({ "admin", "services", "xc", "switch" }, "action_switch")
  post_entry({ "admin", "services", "xc", "fast-switch" }, "action_fast_switch")
  post_entry({ "admin", "services", "xc", "rollback" }, "action_rollback")
  post_entry({ "admin", "services", "xc", "import-preview" }, "action_import_preview")
  post_entry({ "admin", "services", "xc", "import-commit" }, "action_import_commit")
  entry({ "admin", "services", "xc", "get-log" }, action_target("action_get_log")).leaf = true
  post_entry({ "admin", "services", "xc", "clear-log" }, "action_clear_log")
  post_entry({ "admin", "services", "xc", "core-upload" }, "action_core_upload")
  post_entry({ "admin", "services", "xc", "core-activate" }, "action_core_activate")
  post_entry({ "admin", "services", "xc", "core-rollback" }, "action_core_rollback")
  post_entry({ "admin", "services", "xc", "core-delete" }, "action_core_delete")
end

local function require_post(maximum)
  if http.getenv("REQUEST_METHOD") ~= "POST" then failure("method_not_allowed"); return false, "method_not_allowed" end
  local length_text = http.getenv("CONTENT_LENGTH")
  if length_text == nil then failure("validation_failed"); return false, "validation_failed" end
  if not length_text:match("^%d+$") then failure("validation_failed"); return false, "validation_failed" end
  local length = tonumber(length_text) or 0
  maximum = maximum or REQUEST_BODY_MAX
  if length > maximum then failure("request_too_large"); return false, "request_too_large" end
  return true
end

local function request_body(required)
  local valid, code = require_post()
  if not valid then return nil, code end
  local content_ok, body = pcall(http.content)
  if not content_ok or (body ~= nil and type(body) ~= "string") then
    failure("internal_error")
    return nil, "internal_error"
  end
  body = body or ""
  if #body > REQUEST_BODY_MAX then failure("request_too_large"); return nil, "request_too_large" end
  if required and body == "" then failure("validation_failed"); return nil, "validation_failed" end
  return body
end

local function new_backend()
  local called, adapters = pcall(platform.new)
  if not called or type(adapters) ~= "table" then return nil end
  local layout_called, layout_ok = pcall(adapters.fs.ensure_layout)
  if not layout_called or layout_ok ~= true then return nil end
  local runtime_called, runtime_instance = pcall(runtime_module.new, adapters)
  if not runtime_called or not runtime_instance then return nil end
  local core_called, core_instance = pcall(coremanager_module.new, adapters)
  if not core_called or not core_instance then return adapters, runtime_instance, nil end
  return adapters, runtime_instance, core_instance
end

local function record_event(runtime_instance, message, fields, level)
  if type(runtime_instance) == "table" and type(runtime_instance.record_event) == "function" then
    pcall(runtime_instance.record_event, runtime_instance, message, fields, level)
  end
end

local probe_codes = {
  disabled_node = true, error = true, internal_error = true, invalid_node = true,
  method_not_allowed = true, missing_node = true, request_too_large = true,
  tcp = true, tcp_only_grpc = true, tcp_only_reality = true, timeout = true,
  tls = true, tls_error = true, tls_unsupported = true,
  unsupported = true, unsupported_node = true, validation_failed = true,
  ws = true, ws_error = true
}

local function bounded_number(value)
  if type(value) ~= "number" or value ~= value then return 0 end
  value = math.floor(value + 0.5)
  if value < 0 then return 0 end
  if value > 10000 then return 10000 end
  return value
end

local function probe_event(runtime_instance, ok, code, node, ping, elapsed)
  local stable_code = probe_codes[code] and code or "internal_error"
  local fields = { code = stable_code, outcome = ok and "success" or "failure" }
  if schema.safe_section_id(node) then fields.node = node end
  if ping ~= nil then fields.ping = bounded_number(ping) end
  if elapsed ~= nil then fields.time = bounded_number(elapsed) end
  record_event(runtime_instance, "node probe completed", fields, ok and "debug" or "error")
end

local function import_event(runtime_instance, ok, code, count)
  if type(code) ~= "string" or not code:match("^[a-z][a-z_]*$") then code = "internal_error" end
  count = tonumber(count) or 0
  if count < 0 then count = 0 elseif count > 10000 then count = 10000 end
  record_event(runtime_instance, "import commit completed", {
    code = code, count = math.floor(count), outcome = ok and "success" or "failure"
  }, ok and "info" or "error")
end

local function requested_node(adapters, body)
  local called, value = pcall(adapters.json.parse, body)
  if not called or type(value) ~= "table" then return nil, "validation_failed" end
  local section_id = value.section
  if not schema.safe_section_id(section_id) then return nil, "invalid_node" end
  local read_ok, node, outcome = pcall(adapters.uci.get_node, section_id)
  if not read_ok then return nil, "internal_error" end
  if node == nil and outcome == "missing" then return nil, "missing_node" end
  if type(node) ~= "table" or outcome ~= "ok" then return nil, "internal_error" end
  return { section_id = section_id, node = node, request = value }
end

local function runtime_response(result)
  if type(result) ~= "table" then failure("internal_error"); return end
  if not result.ok then failure(result.code or "internal_error"); return end
  success({ code = result.code, node = result.node, active_node_unset = result.active_node_unset })
end

local function public_nodes(nodes)
  local output = {}
  for index, node in ipairs(nodes or {}) do
    output[index] = {
      section = node.id,
      name = type(node.name) == "string" and node.name or "",
      protocol = schema.supported_protocols[node.protocol] and node.protocol or nil,
      server = type(node.server) == "string" and node.server or nil,
      port = tonumber(node.port)
    }
  end
  return output
end

local function node_name_map(adapters)
  if type(adapters) ~= "table" or type(adapters.uci) ~= "table"
    or type(adapters.uci.list_nodes) ~= "function" then return nil end
  local called, nodes = pcall(adapters.uci.list_nodes)
  if not called or type(nodes) ~= "table" then return nil end
  local output = {}
  for _, node in ipairs(nodes) do
    if type(node) == "table" and schema.safe_section_id(node.id)
      and type(node.name) == "string" and node.name ~= "" and #node.name <= 256 then
      output[node.id] = node.name
    end
  end
  return output
end

local function append_warnings(first, second)
  local output = {}
  for _, warning in ipairs(first or {}) do output[#output + 1] = warning end
  for _, warning in ipairs(second or {}) do output[#output + 1] = warning end
  return output
end

function action_status()
  local _, runtime_instance = new_backend()
  if not runtime_instance then failure("internal_error"); return end
  local called, status = pcall(runtime_instance.status, runtime_instance)
  if not called or type(status) ~= "table" then failure("internal_error"); return end
  if not status.ok then failure(status.code or "internal_error"); return end
  success({
    service_state = status.service,
    active_section = status.active_node,
    active_name = status.node and status.node.name,
    active_protocol = status.node and status.node.protocol,
    listen_ip = status.listen and status.listen.address,
    socks_port = status.listen and status.listen.socks_port,
    http_port = status.listen and status.listen.http_port,
    lock_state = status.lock,
    operation = status.operation,
    recovery_required = status.recovery_required,
    selection_mode = status.selection_mode,
    runtime_active_node = status.runtime_active_node,
    selection_state = status.selection_state,
    exit_ip = status.exit_ip,
    last_error = status.last_error
  })
end

local function core_event(runtime_instance, message, value)
  if type(runtime_instance) ~= "table" or type(value) ~= "table" then return end
  local code = type(value.code) == "string" and value.code or "internal_error"
  if not code:match("^[a-z][a-z_]*$") then code = "internal_error" end
  local fields = { code = code, outcome = value.ok and "success" or "failure" }
  for _, key in ipairs({ "id", "current", "previous", "failed_target" }) do
    if type(value[key]) == "string" and #value[key] <= 128
      and value[key]:match("^[a-z0-9][a-z0-9_%-]*$") then fields[key] = value[key] end
  end
  if type(value.version) == "table" then
    if type(value.version.id) == "string" and #value.version.id <= 128
      and value.version.id:match("^[a-z0-9][a-z0-9_%-]*$") then
      fields.id = value.version.id
    end
    if type(value.version.version) == "string" and #value.version.version <= 64
      and value.version.version:match("^[a-z0-9][a-z0-9_.%-]*$") then
      fields.version = value.version.version
    end
    if type(value.version.arch) == "string" and #value.version.arch <= 32
      and value.version.arch:match("^[a-z0-9_]+$") then
      fields.arch = value.version.arch
    end
    if type(value.version.size) == "number" and value.version.size >= 0
      and value.version.size <= CORE_UPLOAD_MAX then
      fields.size = math.floor(value.version.size)
    end
    if type(value.version.sha256) == "string" and #value.version.sha256 == 64
      and value.version.sha256:match("^[0-9A-Fa-f]+$") then
      fields.sha256 = value.version.sha256:sub(1, 16):lower()
    end
  end
  record_event(runtime_instance, message, fields, value.ok and "info" or "error")
end

local function core_exception_value(core_instance)
  local fallback = { ok = false, code = "core_recovery_required", recovery_required = true }
  if type(core_instance) ~= "table" then return fallback end
  local recovered_called, recovered = pcall(core_instance.recover_pending, core_instance)
  if recovered_called and type(recovered) == "table"
    and (recovered.recovery_required == true or recovered.current ~= nil
      or recovered.previous ~= nil or recovered.failed_target ~= nil)
    then
    return recovered
  end
  local status_called, status = pcall(core_instance.status, core_instance)
  if status_called and type(status) == "table" and status.recovery_required == true then
    return status
  end
  return fallback
end

local function core_failure_response(code, value)
  if type(code) ~= "string" or not code:match("^[a-z][a-z_]*$") then code = "core_activate_failed" end
  local payload = { ok = false, code = code, message = messages[code] or "The request failed safely." }
  if type(value) == "table" then
    if value.recovery_required == true then payload.recovery_required = true end
    for _, key in ipairs({ "current", "previous", "failed_target" }) do
      if type(value[key]) == "string" and #value[key] <= 128
        and value[key]:match("^[a-z0-9][a-z0-9_%-]*$") then payload[key] = value[key] end
    end
  end
  http.status(failure_status[code] or 500, status_text[failure_status[code] or 500])
  respond(payload)
end

local function core_result(runtime_instance, value, message)
  if type(value) ~= "table" then
    core_event(runtime_instance, message, { ok = false, code = "core_activate_failed" })
    failure("core_activate_failed"); return
  end
  core_event(runtime_instance, message, value)
  if not value.ok then core_failure_response(value.code or "core_activate_failed", value); return end
  success(value)
end

function action_core_status()
  local _, runtime_instance, core_instance = new_backend()
  if not core_instance then failure("core_runtime_unavailable"); return end
  local recovered_ok, recovered = pcall(core_instance.recover_pending, core_instance)
  if recovered_ok and type(recovered) == "table" then core_event(runtime_instance, "core recovery", recovered) end
  if not recovered_ok or type(recovered) ~= "table" or not recovered.ok then
    local recovery_failure = recovered_ok and type(recovered) == "table"
      and recovered or core_exception_value(core_instance)
    if not recovered_ok then core_event(runtime_instance, "core recovery", recovery_failure) end
    core_failure_response(recovery_failure.code or "core_recovery_required", recovery_failure)
    return
  end
  local called, status = pcall(core_instance.status, core_instance)
  if not called or type(status) ~= "table" then
    local status_failure = core_exception_value(core_instance)
    core_event(runtime_instance, "core status", status_failure)
    core_failure_response(status_failure.code or "core_recovery_required", status_failure)
    return
  end
  if not status.ok then core_failure_response(status.code or "core_recovery_required", status); return end
  success(status)
end

function action_core_upload()
  local valid, code = require_post(CORE_REQUEST_MAX)
  if not valid then return end
  local adapters, runtime_instance, core_instance = new_backend()
  if not core_instance or type(http.setfilehandler) ~= "function"
    or type(adapters.fs.open_upload) ~= "function" or type(adapters.fs.write_upload) ~= "function"
    or type(adapters.fs.close_upload) ~= "function" then
    core_event(runtime_instance, "core upload completed", { ok = false, code = "core_runtime_unavailable" })
    failure("core_runtime_unavailable"); return
  end

  local upload, upload_closed, upload_error, field_seen
  local handler_ok = pcall(http.setfilehandler, function(field, chunk, eof)
    local field_name = type(field) == "table" and field.name or field
    if field_name ~= "core_file" then return end
    field_seen = true
    if upload_error then return end
    if not upload then upload = adapters.fs.open_upload() end
    if not upload then upload_error = "core_install_failed"; return end
    if chunk and #chunk > 0 and not adapters.fs.write_upload(upload, chunk, CORE_UPLOAD_MAX) then upload_error = "core_upload_too_large" end
    if eof and not upload_error then
      upload_closed = adapters.fs.close_upload(upload, true)
      if not upload_closed then upload_error = "core_install_failed" end
    end
  end)
  if not handler_ok then core_event(runtime_instance, "core upload completed", { ok = false, code = "core_runtime_unavailable" }); failure("core_runtime_unavailable"); return end

  local form_ok, expected, note = pcall(function()
    http.formvalue("core_file")
    return http.formvalue("sha256"), http.formvalue("note")
  end)
  if not form_ok or upload_error then
    if upload and not upload_closed then pcall(adapters.fs.close_upload, upload, false) end
    if upload then pcall(adapters.fs.remove, upload.path) end
    local code = upload_error or "core_invalid_upload"
    core_event(runtime_instance, "core upload completed", { ok = false, code = code })
    failure(code); return
  end
  if not field_seen or not upload or not upload_closed then
    core_event(runtime_instance, "core upload completed", { ok = false, code = "core_invalid_upload" })
    failure("core_invalid_upload"); return
  end
  local checked_ok, checked = pcall(core_instance.validate, core_instance, upload.path, expected, note)
  if not checked_ok or type(checked) ~= "table" or not checked.ok then
    pcall(adapters.fs.remove, upload.path)
    local code = checked_ok and checked.code or "core_activate_failed"
    core_event(runtime_instance, "core upload completed", { ok = false, code = code })
    failure(code); return
  end
  local installed_ok, installed = pcall(core_instance.install, core_instance, upload.path, checked.manifest)
  pcall(adapters.fs.remove, upload.path)
  if not installed_ok or type(installed) ~= "table" or not installed.ok then
    local code = installed_ok and installed.code or "core_install_failed"
    core_event(runtime_instance, "core upload completed", { ok = false, code = code })
    failure(code); return
  end
  core_event(runtime_instance, "core upload completed", installed)
  success(installed)
end

function action_core_activate()
  local valid = require_post()
  if not valid then return end
  local _, runtime_instance, core_instance = new_backend()
  if not core_instance then
    core_event(runtime_instance, "core activation", { ok = false, code = "core_runtime_unavailable" })
    failure("core_runtime_unavailable"); return
  end
  local target = http.formvalue("id")
  local called, value = pcall(core_instance.activate, core_instance, target)
  if not called then
    value = core_exception_value(core_instance)
    core_event(runtime_instance, "core activation", value)
    core_failure_response(value.code or "core_activate_failed", value)
    return
  end
  core_result(runtime_instance, value, "core activation")
end

function action_core_rollback()
  local valid = require_post()
  if not valid then return end
  local _, runtime_instance, core_instance = new_backend()
  if not core_instance then
    core_event(runtime_instance, "core rollback", { ok = false, code = "core_runtime_unavailable" })
    failure("core_runtime_unavailable"); return
  end
  local called, value = pcall(core_instance.rollback, core_instance)
  if not called then
    value = core_exception_value(core_instance)
    core_event(runtime_instance, "core rollback", value)
    core_failure_response(value.code or "core_activate_failed", value)
    return
  end
  core_result(runtime_instance, value, "core rollback")
end

function action_core_delete()
  local valid = require_post()
  if not valid then return end
  local _, runtime_instance, core_instance = new_backend()
  if not core_instance then
    core_event(runtime_instance, "core deletion", { ok = false, code = "core_runtime_unavailable" })
    failure("core_runtime_unavailable"); return
  end
  local target = http.formvalue("id")
  local called, value = pcall(core_instance.delete, core_instance, target)
  if not called then
    value = core_exception_value(core_instance)
    core_event(runtime_instance, "core deletion", value)
    core_failure_response(value.code or "core_activate_failed", value)
    return
  end
  core_result(runtime_instance, value, "core deletion")
end

function action_test_current()
  if not request_body(false) then return end
  local _, runtime_instance = new_backend()
  if not runtime_instance then failure("internal_error"); return end
  local called, result = pcall(function() return runtime_instance:test_current() end)
  if not called then failure("internal_error"); return end
  runtime_response(result)
end

function action_probe()
  local body, request_code = request_body(true)
  if not body then
    local _, runtime_instance = new_backend()
    probe_event(runtime_instance, false, request_code or "validation_failed")
    return
  end
  local adapters, runtime_instance = new_backend()
  if not adapters then failure("internal_error"); return end
  local selected, code = requested_node(adapters, body)
  if not selected then probe_event(runtime_instance, false, code); failure(code); return end
  if selected.node.enabled ~= true and selected.node.enabled ~= 1 and selected.node.enabled ~= "1" then
    probe_event(runtime_instance, false, "disabled_node", selected.section_id); failure("disabled_node"); return
  end
  if selected.node.protocol == "raw" or not schema.supported_protocols[selected.node.protocol]
    or type(selected.node.server) ~= "string" or not tonumber(selected.node.port) then
    probe_event(runtime_instance, false, "unsupported_node", selected.section_id); failure("unsupported_node"); return
  end
  local timeout = tonumber(selected.request.timeout)
  if not timeout then
    local global_ok, global = pcall(adapters.uci.get_global)
    if global_ok and type(global) == "table" then timeout = tonumber(global.probe_timeout) end
  end
  timeout = math.floor(timeout or 3)
  if timeout < 1 then timeout = 1 elseif timeout > 10 then timeout = 10 end
  local probe_ok, probe_instance = pcall(probe_module.new, adapters)
  if not probe_ok or type(probe_instance) ~= "table" then
    probe_event(runtime_instance, false, "internal_error", selected.section_id); failure("internal_error"); return
  end
  local called, result = pcall(function() return probe_instance:run(selected.section_id, selected.node, timeout) end)
  if not called or type(result) ~= "table" or (result.socket ~= "ok" and result.socket ~= "fail")
    or type(result.ping) ~= "number" or type(result.time) ~= "number" then
    probe_event(runtime_instance, false, "internal_error", selected.section_id); failure("internal_error"); return
  end
  probe_event(runtime_instance, result.socket == "ok", result.outcome, selected.section_id, result.ping, result.time)
  success({ socket = result.socket, ping = result.ping, time = result.time, outcome = result.outcome })
end

function action_switch()
  local body = request_body(true)
  if not body then return end
  local adapters, runtime_instance = new_backend()
  if not runtime_instance then failure("internal_error"); return end
  local selected, code = requested_node(adapters, body)
  if not selected then failure(code); return end
  local status_called, status = pcall(runtime_instance.status, runtime_instance)
  if not status_called or type(status) ~= "table" or not status.ok then failure("internal_error"); return end
  if status.recovery_required then failure("recovery_required"); return end
  if status.lock == "held" or (status.operation and status.operation ~= "idle") then failure("busy"); return end
  if type(adapters.exec) ~= "table" or type(adapters.exec.start_switch) ~= "function" then
    failure("internal_error"); return
  end
  local started_called, started = pcall(adapters.exec.start_switch, selected.section_id)
  if not started_called or started ~= true then failure("internal_error"); return end
  success({ code = "switch_started", node = selected.section_id })
end

function action_fast_switch()
  local body = request_body(true)
  if not body then return end
  local adapters, runtime_instance = new_backend()
  if not runtime_instance then failure("internal_error"); return end
  local selected, code = requested_node(adapters, body)
  if not selected then failure(code); return end
  if selected.node.enabled ~= true and selected.node.enabled ~= 1 and selected.node.enabled ~= "1" then
    failure("disabled_node"); return
  end
  local called, result = pcall(function()
    return runtime_instance:fast_switch(selected.section_id)
  end)
  if not called or type(result) ~= "table" then failure("internal_error"); return end
  if not result.ok then failure(result.code or "internal_error"); return end
  if result.code ~= "fast_switched" then failure("internal_error"); return end
  success({ code = result.code, node = selected.section_id })
end

function action_rollback()
  if not request_body(false) then return end
  local _, runtime_instance = new_backend()
  if not runtime_instance then failure("internal_error"); return end
  local called, result = pcall(function() return runtime_instance:rollback() end)
  if not called then failure("internal_error"); return end
  runtime_response(result)
end

function action_import_preview()
  local body = request_body(true)
  if not body then return end
  local adapters = new_backend()
  if not adapters then failure("internal_error"); return end
  local called, result = pcall(importer.parse, body, adapters.json)
  if not called or type(result) ~= "table" then failure("validation_failed"); return end
  success({ nodes = public_nodes(result.nodes), warnings = result.warnings or {} })
end

function action_import_commit()
  local body, request_code = request_body(true)
  if not body then
    local _, runtime_instance = new_backend()
    import_event(runtime_instance, false, request_code or "validation_failed", 0)
    return
  end
  local adapters, runtime_instance = new_backend()
  if not adapters then failure("internal_error"); return end

  local dirty, commit_started, imported_count = false, false, 0
  local called, result, code, revert_allowed = xpcall(function()
    local parsed = importer.parse(body, adapters.json)
    if type(parsed) ~= "table" then return nil, "validation_failed", true end
    local nodes, warnings = importer.deduplicate(parsed.nodes, adapters.uci.list_nodes())
    if type(nodes) ~= "table" then return nil, "validation_failed", true end
    imported_count = #nodes
    warnings = append_warnings(parsed.warnings, warnings)
    for _, node in ipairs(nodes) do
      if not schema.validate(node) then return nil, "validation_failed", true end
    end
    if #nodes > 0 then
      dirty = true
      if not adapters.uci.stage_nodes(nodes) then return nil, "import_failed", true end
      commit_started = true
      local committed, outcome = adapters.uci.commit()
      if outcome == "committed_hardening_failed" then
        return nil, "committed_hardening_failed", false
      end
      if not committed then
        if outcome == "pre_commit_failed" then return nil, "commit_failed", true end
        return nil, outcome == "commit_unknown" and outcome or "commit_unknown", false
      end
      if outcome ~= "committed" then return nil, "commit_unknown", false end
    end
    return { imported = #nodes, nodes = public_nodes(nodes), warnings = warnings or {} }
  end, function() return "internal_error" end)

  if not called then
    if dirty and not commit_started then pcall(function() adapters.uci.revert() end) end
    local failure_code = commit_started and "commit_unknown" or "internal_error"
    import_event(runtime_instance, false, failure_code, imported_count)
    failure(failure_code)
    return
  end
  if not result then
    if revert_allowed then pcall(function() adapters.uci.revert() end) end
    code = code or "internal_error"
    import_event(runtime_instance, false, code, imported_count)
    failure(code)
    return
  end
  import_event(runtime_instance, true, "committed", imported_count)
  success(result)
end

function action_get_log()
  local level = http.formvalue("level")
  if level == nil then level = "all" end
  if level ~= "all" and level ~= "error" and level ~= "warning" and level ~= "info" and level ~= "debug" then
    failure("invalid_request"); return
  end
  local adapters = new_backend()
  if not adapters then failure("internal_error"); return end
  local called, xc_content, read_error = pcall(adapters.fs.read_tail, runtime_module.paths.log, LOG_READ_MAX)
  if not called then failure("internal_error"); return end
  if xc_content == nil and read_error ~= "missing" then failure("internal_error"); return end

  local time_ok, uptime, wall_time = pcall(function() return adapters.now(), adapters.wall_time() end)
  if not time_ok or type(uptime) ~= "number" or type(wall_time) ~= "number" then failure("internal_error"); return end
  local xray_content = ""
  if type(adapters.exec) == "table" and type(adapters.exec.xray_logs) == "function" then
    local captured, value = pcall(adapters.exec.xray_logs, uptime + 2)
    if captured and type(value) == "string" then xray_content = value end
  end
  local normalized, entries = pcall(logview.collect, {
    xc = xc_content or "", xray = xray_content, level = level, json = adapters.json,
    wall_time = wall_time, uptime = uptime, node_names = node_name_map(adapters)
  })
  if not normalized or type(entries) ~= "table" then failure("internal_error"); return end
  success({ entries = entries, clear_scope = "xc" })
end

function action_clear_log()
  if not request_body(false) then return end
  local adapters = new_backend()
  if not adapters then failure("internal_error"); return end
  local acquired, lock = pcall(adapters.fs.acquire_lock, runtime_module.paths.log_lock)
  if not acquired then failure("internal_error"); return end
  if not lock then failure("busy"); return end
  local called, truncated = pcall(adapters.fs.truncate, runtime_module.paths.log)
  local released, release_result = pcall(adapters.fs.release_lock, lock)
  if not called or truncated ~= true or not released or release_result ~= true then
    failure("internal_error"); return
  end
  success({ cleared = true })
end
