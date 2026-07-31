local M = {}

M.DEFAULT_MAX_SIZE = 64 * 1024 * 1024
M.MANIFEST_MAX_SIZE = 65536
M.VERSION_ID_PATTERN = "^[a-z0-9][a-z0-9_%-]*$"
M.SAFE_PATH_PATTERN = "^/etc/xc/xray/"
M.HEX64_PATTERN = "^[0-9a-fA-F]+$"

local SYSTEM_MARKER = "system"
local SYSTEM_XRAY = "/usr/bin/xray"
local XRAY_ROOT = "/etc/xc/xray"
local VERSIONS_DIR = XRAY_ROOT .. "/versions"
local MARKER_NAMES = { current = true, previous = true, transaction = true }
local ARCH_ALIASES = {
  aarch64 = "aarch64", arm64 = "aarch64", armv8l = "arm", armv7 = "arm", armv7l = "arm", arm = "arm",
  x86_64 = "x86_64", amd64 = "x86_64", i386 = "i386", i486 = "i386", i586 = "i386", i686 = "i386",
  mips = "mips", mipsel = "mipsel"
}

local function safe_id(value)
  return type(value) == "string" and #value > 0 and #value <= 128
    and value:match(M.VERSION_ID_PATTERN) ~= nil
end

local function safe_version(value)
  return type(value) == "string" and #value > 0 and #value <= 64
    and value:match("^[a-z0-9][a-z0-9_.%-]*$") ~= nil
end

local function safe_arch(value)
  return type(value) == "string" and #value > 0 and #value <= 32
    and value:match("^[a-z0-9_]+$") ~= nil
end

local function safe_sha256(value)
  return type(value) == "string" and #value == 64 and value:match(M.HEX64_PATTERN) ~= nil
end

local function safe_note(value)
  if value == nil then return true end
  return type(value) == "string" and #value <= 256 and not value:find("[%z\1-\31\127]")
end

local function safe_validation(value)
  return value == nil or value == "binary" or value == "full"
end

local function safe_path(path)
  return type(path) == "string" and #path > #XRAY_ROOT and #path <= 512
    and path:sub(1, #XRAY_ROOT + 1) == XRAY_ROOT .. "/"
    and not path:find("[%z\1-\31\127]")
    and not path:find("//", 1, true)
    and not path:find("/%.%./")
    and not path:match("/%.%.$")
end

local function safe_marker_path(path)
  if not safe_path(path) then return false end
  local name = path:match("^" .. XRAY_ROOT:gsub("/", "%%/") .. "/([^/]+)$")
  return name ~= nil and MARKER_NAMES[name] == true
end

local function trim_marker(value)
  if type(value) ~= "string" then return nil end
  value = value:gsub("%s+$", "")
  if value:find("[%z\1-\31\127]") then return nil end
  return value
end

local function json_parser(json_parse)
  if type(json_parse) == "function" then return json_parse end
  local called, json = pcall(require, "luci.jsonc")
  if not called or type(json) ~= "table" or type(json.parse) ~= "function" then return nil end
  return json.parse
end

function M.system_path()
  return SYSTEM_XRAY
end

function M.versions_dir()
  return VERSIONS_DIR
end

function M.marker_path(name)
  return MARKER_NAMES[name] and XRAY_ROOT .. "/" .. name or nil
end

function M.safe_id(value)
  return safe_id(value)
end

function M.safe_sha256(value)
  return safe_sha256(value)
end

function M.normalize_arch(value)
  return type(value) == "string" and ARCH_ALIASES[value:lower()] or nil
end

function M.safe_path(value)
  return safe_path(value)
end

function M.version_path(id)
  if not safe_id(id) then return nil end
  return VERSIONS_DIR .. "/" .. id
end

function M.executable_path(id)
  local directory = M.version_path(id)
  return directory and directory .. "/xray" or nil
end

function M.manifest_path(id)
  local directory = M.version_path(id)
  return directory and directory .. "/manifest.json" or nil
end

function M.resolve_executable(marker)
  marker = trim_marker(marker)
  if marker == SYSTEM_MARKER then return SYSTEM_XRAY end
  if not safe_id(marker) then return nil end
  return M.executable_path(marker)
end

function M.read_marker(value)
  value = trim_marker(value)
  if value == SYSTEM_MARKER or safe_id(value) then return value end
  return nil
end

function M.write_marker(adapter, path, value)
  if type(adapter) ~= "table" or type(adapter.write_file) ~= "function" then return false end
  if not safe_marker_path(path) then return false end
  value = M.read_marker(value)
  if not value then return false end
  return adapter.write_file(path, value .. "\n") == true
end

function M.version_id(version, arch, sha256)
  if not safe_version(version) or not safe_arch(arch) or type(sha256) ~= "string"
    or #sha256 < 16 or not sha256:match("^[0-9a-fA-F]+$") then return nil end
  local normalized = version:gsub("[^a-z0-9]", "_")
  return "v" .. normalized .. "-" .. arch .. "-" .. sha256:sub(1, 16):lower()
end

function M.validate_manifest(value)
  if type(value) ~= "table" then return nil end
  if not safe_id(value.id) or not safe_version(value.version) or not safe_arch(value.arch) then return nil end
  if type(value.size) ~= "number" or value.size < 1 or value.size > M.DEFAULT_MAX_SIZE
    or value.size ~= math.floor(value.size) then return nil end
  if not safe_sha256(value.sha256) then return nil end
  if type(value.uploaded_at) ~= "number" or value.uploaded_at < 0
    or value.uploaded_at ~= math.floor(value.uploaded_at) then return nil end
  if not safe_note(value.note) or not safe_validation(value.validation) then return nil end
  return {
    id = value.id,
    version = value.version,
    arch = value.arch,
    size = value.size,
    sha256 = value.sha256:lower(),
    uploaded_at = value.uploaded_at,
    note = value.note, validation = value.validation
  }
end

function M.parse_manifest(text, json_parse)
  if type(text) ~= "string" or #text == 0 or #text > M.MANIFEST_MAX_SIZE then return nil end
  json_parse = json_parser(json_parse)
  if not json_parse then return nil end
  local called, value = pcall(json_parse, text)
  if not called then return nil end
  return M.validate_manifest(value)
end

function M.public_version(manifest)
  manifest = M.validate_manifest(manifest)
  if not manifest then return nil end
  return {
    id = manifest.id,
    version = manifest.version,
    arch = manifest.arch,
    size = manifest.size,
    sha256 = manifest.sha256,
    uploaded_at = manifest.uploaded_at,
    note = manifest.note, validation = manifest.validation
  }
end

function M.list_versions(adapter)
  if type(adapter) ~= "table" or type(adapter.list_dir) ~= "function"
    or type(adapter.read_file) ~= "function" then return {} end
  local entries = adapter.list_dir(VERSIONS_DIR)
  if type(entries) ~= "table" then return {} end
  local parse = json_parser(adapter.json_parse)
  if not parse then return {} end
  local results = {}
  for _, name in ipairs(entries) do
    if safe_id(name) then
      local text = adapter.read_file(M.manifest_path(name))
      local manifest = type(text) == "string" and M.parse_manifest(text, parse) or nil
      if manifest and manifest.id == name then results[#results + 1] = M.public_version(manifest) end
    end
  end
  table.sort(results, function(left, right) return left.id < right.id end)
  return results
end

return M
