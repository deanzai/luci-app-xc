module("luci.controller.xc", package.seeall)
local call = require("luci.dispatcher").call
local entry = require("luci.dispatcher").entry
local cbi = require("luci.dispatcher").cbi
local template = require("luci.dispatcher").template
local alias = require("luci.dispatcher").alias


local http = require "luci.http"
local schema = require "xc.schema"
local platform = require "xc.platform"
local runtime_module = require "xc.runtime"
local importer = require "xc.importer"
local probe_module = require "xc.probe"

local REQUEST_BODY_MAX = 512 * 1024
local LOG_READ_MAX = 256 * 1024

local messages = {
  busy = "Another XC operation is in progress.",
  commit_unknown = "The save result could not be confirmed.",
  committed_hardening_failed = "The configuration was saved but its file mode could not be confirmed.",
  commit_failed = "The configuration could not be saved.",
  import_failed = "The import could not be completed.",
  internal_error = "The request could not be completed.",
  disabled_node = "The selected node is disabled.",
  invalid_node = "The selected node is invalid.",
  method_not_allowed = "This action requires POST.",
  missing_runtime = "No active runtime configuration is available.",
  missing_node = "The selected node does not exist.",
  not_implemented = "This capability is not available yet.",
  no_rollback_state = "No rollback state is available.",
  request_too_large = "The request body is too large.",
  test_failed = "The current node health test failed.",
  unsupported_node = "The selected node cannot be probed safely.",
  validation_failed = "The request did not pass validation."
}

local failure_status = {
  validation_failed = 400, invalid_node = 400,
  missing_node = 404, no_rollback_state = 404,
  method_not_allowed = 405, busy = 409, disabled_node = 409,
  request_too_large = 413, not_implemented = 501,
  unsupported_node = 422, missing_runtime = 404, test_failed = 502
}

local status_text = {
  [400] = "Bad Request", [404] = "Not Found", [405] = "Method Not Allowed",
  [409] = "Conflict", [413] = "Content Too Large", [422] = "Unprocessable Content", [500] = "Internal Server Error",
  [501] = "Not Implemented", [502] = "Bad Gateway"
}

local function respond(payload)
  http.prepare_content("application/json")
  http.write_json(payload)
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

local function post_entry(path, action)
  local target = call(action)
  target.post = true
  local node = entry(path, target)
  node.leaf = true
  return node
end

function index()
  local root = entry({ "admin", "services", "xc" }, alias("admin", "services", "xc", "settings"), _("Xray node switching"), 60)
  root.dependent = true

  entry({ "admin", "services", "xc", "settings" }, cbi("xc/settings"), _("Settings"), 10).leaf = true
  entry({ "admin", "services", "xc", "nodes" }, cbi("xc/nodes"), _("Nodes"), 20).leaf = true
  entry({ "admin", "services", "xc", "node" }, cbi("xc/node"), nil).leaf = true
  entry({ "admin", "services", "xc", "log" }, cbi("xc/log"), _("Log"), 30).leaf = true

  entry({ "admin", "services", "xc", "status" }, call("action_status")).leaf = true
  post_entry({ "admin", "services", "xc", "probe" }, "action_probe")
  post_entry({ "admin", "services", "xc", "test-current" }, "action_test_current")
  post_entry({ "admin", "services", "xc", "switch" }, "action_switch")
  post_entry({ "admin", "services", "xc", "rollback" }, "action_rollback")
  post_entry({ "admin", "services", "xc", "import-preview" }, "action_import_preview")
  post_entry({ "admin", "services", "xc", "import-commit" }, "action_import_commit")
  entry({ "admin", "services", "xc", "get-log" }, call("action_get_log")).leaf = true
  post_entry({ "admin", "services", "xc", "clear-log" }, "action_clear_log")
end

local function require_post()
  if http.getenv("REQUEST_METHOD") ~= "POST" then failure("method_not_allowed"); return false end
  local length_text = http.getenv("CONTENT_LENGTH")
  if length_text == nil then failure("validation_failed"); return false end
  if not length_text:match("^%d+$") then failure("validation_failed"); return false end
  local length = tonumber(length_text) or 0
  if length > REQUEST_BODY_MAX then failure("request_too_large"); return false end
  return true
end

local function request_body(required)
  if not require_post() then return nil end
  local body = http.content() or ""
  if #body > REQUEST_BODY_MAX then failure("request_too_large"); return nil end
  if required and body == "" then failure("validation_failed"); return nil end
  return body
end

local function new_backend()
  local called, adapters = pcall(platform.new)
  if not called or type(adapters) ~= "table" then return nil end
  local runtime_instance = runtime_module.new(adapters)
  if not runtime_instance then return nil end
  return adapters, runtime_instance
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
    exit_ip = status.exit_ip,
    last_error = status.last_error
  })
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
  local body = request_body(true)
  if not body then return end
  local adapters = new_backend()
  if not adapters then failure("internal_error"); return end
  local selected, code = requested_node(adapters, body)
  if not selected then failure(code); return end
  if selected.node.enabled ~= true and selected.node.enabled ~= 1 and selected.node.enabled ~= "1" then failure("disabled_node"); return end
  if selected.node.protocol == "raw" or not schema.supported_protocols[selected.node.protocol]
    or type(selected.node.server) ~= "string" or not tonumber(selected.node.port) then failure("unsupported_node"); return end
  local timeout = tonumber(selected.request.timeout)
  if not timeout then
    local global_ok, global = pcall(adapters.uci.get_global)
    if global_ok and type(global) == "table" then timeout = tonumber(global.probe_timeout) end
  end
  timeout = math.floor(timeout or 3)
  if timeout < 1 then timeout = 1 elseif timeout > 10 then timeout = 10 end
  local probe_ok, probe_instance = pcall(probe_module.new, adapters)
  if not probe_ok or type(probe_instance) ~= "table" then failure("internal_error"); return end
  local called, result = pcall(function() return probe_instance:run(selected.section_id, selected.node, timeout) end)
  if not called or type(result) ~= "table" or (result.socket ~= "ok" and result.socket ~= "fail")
    or type(result.ping) ~= "number" or type(result.time) ~= "number" then failure("internal_error"); return end
  success({ socket = result.socket, ping = result.ping, time = result.time, outcome = result.outcome })
end

function action_switch()
  local body = request_body(true)
  if not body then return end
  local adapters, runtime_instance = new_backend()
  if not runtime_instance then failure("internal_error"); return end
  local selected, code = requested_node(adapters, body)
  if not selected then failure(code); return end
  local called, result = pcall(function() return runtime_instance:switch(selected.section_id) end)
  if not called then failure("internal_error"); return end
  runtime_response(result)
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
  local body = request_body(true)
  if not body then return end
  local adapters = new_backend()
  if not adapters then failure("internal_error"); return end

  local dirty, commit_started = false, false
  local called, result, code, revert_allowed = xpcall(function()
    local parsed = importer.parse(body, adapters.json)
    if type(parsed) ~= "table" then return nil, "validation_failed", true end
    local nodes, warnings = importer.deduplicate(parsed.nodes, adapters.uci.list_nodes())
    if type(nodes) ~= "table" then return nil, "validation_failed", true end
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
    failure(commit_started and "commit_unknown" or "internal_error")
    return
  end
  if not result then
    if revert_allowed then pcall(function() adapters.uci.revert() end) end
    failure(code or "internal_error")
    return
  end
  success(result)
end

function action_get_log()
  local adapters = new_backend()
  if not adapters then failure("internal_error"); return end
  local called, content, read_error = pcall(adapters.fs.read_tail, runtime_module.paths.log, LOG_READ_MAX)
  if not called then failure("internal_error"); return end
  if content == nil and read_error ~= "missing" then failure("internal_error"); return end
  success({ log = content or "" })
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
