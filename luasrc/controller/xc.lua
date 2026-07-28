module("luci.controller.xc", package.seeall)

local http = require "luci.http"
local schema = require "xc.schema"
local platform = require "xc.platform"
local runtime_module = require "xc.runtime"
local importer = require "xc.importer"

local REQUEST_BODY_MAX = 512 * 1024
local LOG_READ_MAX = 256 * 1024

local messages = {
  busy = "Another XC operation is in progress.",
  commit_failed = "The configuration could not be saved.",
  import_failed = "The import could not be completed.",
  internal_error = "The request could not be completed.",
  invalid_node = "The selected node is invalid.",
  method_not_allowed = "This action requires POST.",
  missing_node = "The selected node does not exist.",
  no_rollback_state = "No rollback state is available.",
  request_too_large = "The request body is too large.",
  validation_failed = "The request did not pass validation."
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
  local root = entry({ "admin", "services", "xc" }, alias("admin", "services", "xc", "status"), _("Xray node switching"), 60)
  root.dependent = true

  entry({ "admin", "services", "xc", "settings" }, cbi("xc/settings"), _("Settings"), 10).leaf = true
  entry({ "admin", "services", "xc", "nodes" }, cbi("xc/nodes"), _("Nodes"), 20).leaf = true
  entry({ "admin", "services", "xc", "node" }, cbi("xc/node"), nil).leaf = true
  entry({ "admin", "services", "xc", "log" }, cbi("xc/log"), _("Log"), 30).leaf = true

  entry({ "admin", "services", "xc", "status" }, call("action_status")).leaf = true
  post_entry({ "admin", "services", "xc", "probe" }, "action_probe")
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
  local node = adapters.uci.get_node(section_id)
  if type(node) ~= "table" then return nil, "missing_node" end
  return { section_id = section_id, node = node }
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
    last_error = status.last_error
  })
end

function action_probe()
  local body = request_body(true)
  if not body then return end
  local adapters = new_backend()
  if not adapters then failure("internal_error"); return end
  local selected, code = requested_node(adapters, body)
  if not selected then failure(code); return end
  success({
    section = selected.section_id,
    name = type(selected.node.name) == "string" and selected.node.name or "",
    protocol = schema.supported_protocols[selected.node.protocol] and selected.node.protocol or nil,
    socket = false,
    ping = false
  })
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

  local called, result, code = xpcall(function()
    local parsed = importer.parse(body, adapters.json)
    if type(parsed) ~= "table" then return nil, "validation_failed" end
    local nodes, warnings = importer.deduplicate(parsed.nodes, adapters.uci.list_nodes())
    if type(nodes) ~= "table" then return nil, "validation_failed" end
    warnings = append_warnings(parsed.warnings, warnings)
    for _, node in ipairs(nodes) do
      if not schema.validate(node) then return nil, "validation_failed" end
    end
    if #nodes > 0 then
      if not adapters.uci.stage_nodes(nodes) then return nil, "import_failed" end
      if not adapters.uci.commit() then return nil, "commit_failed" end
    end
    return { imported = #nodes, nodes = public_nodes(nodes), warnings = warnings or {} }
  end, function() return "internal_error" end)

  if not called or not result then
    pcall(function() adapters.uci.revert() end)
    failure(called and code or "internal_error")
    return
  end
  success(result)
end

function action_get_log()
  local adapters = new_backend()
  if not adapters then failure("internal_error"); return end
  local called, content, read_error = pcall(adapters.fs.read, runtime_module.paths.log, LOG_READ_MAX)
  if not called then failure("internal_error"); return end
  if content == nil and read_error ~= "missing" then failure("internal_error"); return end
  success({ log = content or "" })
end

function action_clear_log()
  if not request_body(false) then return end
  local adapters = new_backend()
  if not adapters then failure("internal_error"); return end
  local called, removed = pcall(adapters.fs.remove, runtime_module.paths.log)
  if not called or removed ~= true then failure("internal_error"); return end
  success({ cleared = true })
end
