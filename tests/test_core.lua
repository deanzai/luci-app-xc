local t = require "testlib"

local function read_file(path)
  local handle = assert(io.open(path, "rb"))
  local value = assert(handle:read("*a"))
  handle:close()
  return value
end

t.test("core.lua has no shell, io.popen, or os.execute calls", function()
  local source = read_file("root/usr/lib/lua/xc/core.lua")
  t.eq(source:find("os.execute", 1, true), nil)
  t.eq(source:find("io.popen", 1, true), nil)
  t.eq(source:find("shell", 1, true), nil)
end)

t.test("core.lua defines required public functions", function()
  local source = read_file("root/usr/lib/lua/xc/core.lua")
  for _, name in ipairs({
    "system_path", "version_path", "resolve_executable",
    "read_marker", "write_marker", "list_versions", "parse_manifest",
    "validate_manifest", "public_version", "version_id",
    "DEFAULT_MAX_SIZE", "MANIFEST_MAX_SIZE", "VERSION_ID_PATTERN"
  }) do
    t.contains(source, name)
  end
end)

t.test("system marker resolves to /usr/bin/xray", function()
  local core = require "xc.core"
  t.eq(core.system_path(), "/usr/bin/xray")
  t.eq(core.resolve_executable("system"), "/usr/bin/xray")
end)

t.test("version path is constructed safely", function()
  local core = require "xc.core"
  local path = core.version_path("v26_6_27-aarch64-51c3e26e4ba03f3a")
  t.eq(path, "/etc/xc/xray/versions/v26_6_27-aarch64-51c3e26e4ba03f3a")
end)

t.test("version path rejects unsafe IDs", function()
  local core = require "xc.core"
  local path = core.version_path("../etc/passwd")
  t.eq(path, nil)
  path = core.version_path("foo/bar")
  t.eq(path, nil)
  path = core.version_path("")
  t.eq(path, nil)
  path = core.version_path("a b")
  t.eq(path, nil)
end)

t.test("resolve_executable rejects invalid markers", function()
  local core = require "xc.core"
  t.eq(core.resolve_executable(nil), nil)
  t.eq(core.resolve_executable(""), nil)
  t.eq(core.resolve_executable("../../usr/bin/xray"), nil)
  t.eq(core.resolve_executable("not-valid..id"), nil)
end)

t.test("resolve_executable resolves valid version ID", function()
  local core = require "xc.core"
  local path = core.resolve_executable("v26_6_27-aarch64-51c3e26e4ba03f3a")
  t.eq(path, "/etc/xc/xray/versions/v26_6_27-aarch64-51c3e26e4ba03f3a/xray")
end)

t.test("DEFAULT_MAX_SIZE is 64 MiB", function()
  local core = require "xc.core"
  t.eq(core.DEFAULT_MAX_SIZE, 64 * 1024 * 1024)
end)

t.test("VERSION_ID_PATTERN matches valid IDs", function()
  local core = require "xc.core"
  local id1 = "v26_6_27-aarch64-51c3e26e4ba03f3a"
  local id2 = "v1_0_0-x86_64-abcdef1234567890"
  t.truthy(id1:match(core.VERSION_ID_PATTERN))
  t.truthy(id2:match(core.VERSION_ID_PATTERN))
end)

t.test("VERSION_ID_PATTERN rejects invalid IDs", function()
  local core = require "xc.core"
  local bad1 = "../../etc/passwd"
  local bad2 = "foo bar"
  local bad3 = ""
  local bad4 = "UPPER"
  t.eq(bad1:match(core.VERSION_ID_PATTERN), nil)
  t.eq(bad2:match(core.VERSION_ID_PATTERN), nil)
  t.eq(bad3:match(core.VERSION_ID_PATTERN), nil)
  t.eq(bad4:match(core.VERSION_ID_PATTERN), nil)
end)

t.test("version_id normalizes version and includes arch and hash", function()
  local core = require "xc.core"
  local id = core.version_id("26.6.27", "aarch64", "51c3e26e4ba03f3aabcdef1234567890")
  t.truthy(id:match("^v26_6_27%-aarch64%-51c3e26e4ba03f3a$"))
end)

t.test("version_id rejects invalid version strings", function()
  local core = require "xc.core"
  t.eq(core.version_id("", "aarch64", "51c3e26e4ba03f3aabcdef1234567890"), nil)
  t.eq(core.version_id("../../evil", "aarch64", "51c3e26e4ba03f3aabcdef1234567890"), nil)
  t.eq(core.version_id("1.0.0", "aarch64", "zzz"), nil)
end)

local function mock_json_parse(text)
  local json = require "tests.mock_json"
  return json.parse(text)
end

t.test("parse_manifest validates required fields", function()
  local core = require "xc.core"
  local m = core.parse_manifest('{"id":"v1_0_0-aarch64-abcdef1234567890","version":"1.0.0","arch":"aarch64","size":12345,"sha256":"51c3e26e4ba03f3aabcdef1234567890abcdef1234567890abcdef1234567890","uploaded_at":1234567890}', mock_json_parse)
  t.truthy(m)
  t.eq(m.version, "1.0.0")
  t.eq(m.arch, "aarch64")
  t.eq(m.size, 12345)
end)

t.test("parse_manifest rejects missing fields", function()
  local core = require "xc.core"
  t.eq(core.parse_manifest('{"version":"1.0.0"}', mock_json_parse), nil)
  t.eq(core.parse_manifest('{"id":"v1_0_0-aarch64-abcdef1234567890"}', mock_json_parse), nil)
  t.eq(core.parse_manifest('{}', mock_json_parse), nil)
  t.eq(core.parse_manifest('not json', mock_json_parse), nil)
end)

t.test("parse_manifest rejects oversized input", function()
  local core = require "xc.core"
  local big = string.rep("a", core.MANIFEST_MAX_SIZE + 1)
  t.eq(core.parse_manifest(big, mock_json_parse), nil)
end)

t.test("validate_manifest checks field constraints", function()
  local core = require "xc.core"
  t.eq(core.validate_manifest({}), nil)
  t.eq(core.validate_manifest({id = "bad id"}), nil)
  t.eq(core.validate_manifest({id = "v1_0_0-aarch64-abcdef1234567890", version = ""}), nil)
  t.eq(core.validate_manifest({id = "v1_0_0-aarch64-abcdef1234567890", version = "1.0.0", arch = "BAD!"}), nil)
  t.eq(core.validate_manifest({id = "v1_0_0-aarch64-abcdef1234567890", version = "1.0.0", arch = "aarch64", size = -1}), nil)
  t.eq(core.validate_manifest({id = "v1_0_0-aarch64-abcdef1234567890", version = "1.0.0", arch = "aarch64", size = 12345, sha256 = "short"}), nil)
end)

t.test("validate_manifest accepts valid manifest", function()
  local core = require "xc.core"
  local m = {
    id = "v1_0_0-aarch64-abcdef1234567890",
    version = "1.0.0",
    arch = "aarch64",
    size = 12345,
    sha256 = "51c3e26e4ba03f3aabcdef1234567890abcdef1234567890abcdef1234567890",
    uploaded_at = 1234567890
  }
  t.truthy(core.validate_manifest(m))
end)

t.test("manifest validation state is retained and constrained", function()
  local core = require "xc.core"
  local m = {
    id = "v1_0_0-aarch64-abcdef1234567890", version = "1.0.0", arch = "aarch64",
    size = 12345, sha256 = "51c3e26e4ba03f3aabcdef1234567890abcdef1234567890abcdef1234567890",
    uploaded_at = 1234567890, validation = "full"
  }
  local validated = core.validate_manifest(m)
  t.eq(validated.validation, "full")
  t.eq(core.public_version(m).validation, "full")
  m.validation = "unknown"
  t.eq(core.validate_manifest(m), nil)
end)

t.test("public_version returns only safe fields", function()
  local core = require "xc.core"
  local m = {
    id = "v1_0_0-aarch64-abcdef1234567890",
    version = "1.0.0",
    arch = "aarch64",
    size = 12345,
    sha256 = "51c3e26e4ba03f3aabcdef1234567890abcdef1234567890abcdef1234567890",
    uploaded_at = 1234567890,
    note = "test build"
  }
  local pub = core.public_version(m)
  t.eq(pub.id, "v1_0_0-aarch64-abcdef1234567890")
  t.eq(pub.version, "1.0.0")
  t.eq(pub.arch, "aarch64")
  t.eq(pub.size, 12345)
  t.eq(pub.sha256, "51c3e26e4ba03f3aabcdef1234567890abcdef1234567890abcdef1234567890")
  t.eq(pub.uploaded_at, 1234567890)
  t.eq(pub.note, "test build")
  t.eq(pub.internal_path, nil)
  t.eq(pub.secret_field, nil)
end)

t.test("read_marker validates content", function()
  local core = require "xc.core"
  t.eq(core.read_marker("system"), "system")
  t.eq(core.read_marker("v1_0_0-aarch64-abcdef1234567890"), "v1_0_0-aarch64-abcdef1234567890")
  t.eq(core.read_marker(""), nil)
  t.eq(core.read_marker("bad id"), nil)
  t.eq(core.read_marker("../../etc/passwd"), nil)
end)

t.test("write_marker validates before writing", function()
  local core = require "xc.core"
  local written = {}
  local adapter = {
    write_file = function(path, content) written[path] = content; return true end,
    read_file = function() return nil, "missing" end,
    exists = function() return false end,
    mkdir = function() return true end,
    list_dir = function() return {} end,
    remove = function() return true end,
    hash_file = function() return nil end,
    read_link = function() return nil end
  }
  t.truthy(core.write_marker(adapter, "/etc/xc/xray/current", "system"))
  t.truthy(core.write_marker(adapter, "/etc/xc/xray/current", "v1_0_0-aarch64-abcdef1234567890"))
  t.eq(core.write_marker(adapter, "/etc/xc/xray/current", "../../etc/passwd"), false)
  t.eq(core.write_marker(adapter, "/etc/xc/xray/current", ""), false)
end)

t.test("list_versions returns empty when directory missing", function()
  local core = require "xc.core"
  local adapter = {
    write_file = function() return true end,
    read_file = function() return nil, "missing" end,
    exists = function() return false end,
    mkdir = function() return true end,
    list_dir = function() return nil end,
    remove = function() return true end,
    hash_file = function() return nil end,
    read_link = function() return nil end,
    json_parse = mock_json_parse
  }
  local versions = core.list_versions(adapter)
  t.eq(#versions, 0)
end)

t.test("list_versions reads manifests and returns public fields", function()
  local core = require "xc.core"
  local manifest = '{"id":"v1_0_0-aarch64-abcdef1234567890","version":"1.0.0","arch":"aarch64","size":12345,"sha256":"51c3e26e4ba03f3aabcdef1234567890abcdef1234567890abcdef1234567890","uploaded_at":1234567890}'
  local adapter = {
    write_file = function() return true end,
    read_file = function(path)
      if path:find("manifest.json") then return manifest, nil end
      return nil, "missing"
    end,
    exists = function() return false end,
    mkdir = function() return true end,
    list_dir = function() return { "v1_0_0-aarch64-abcdef1234567890" } end,
    remove = function() return true end,
    hash_file = function() return "51c3e26e4ba03f3aabcdef1234567890abcdef1234567890abcdef1234567890", nil end,
    read_link = function() return nil end,
    json_parse = mock_json_parse
  }
  local versions = core.list_versions(adapter)
  t.eq(#versions, 1)
  t.eq(versions[1].id, "v1_0_0-aarch64-abcdef1234567890")
  t.eq(versions[1].version, "1.0.0")
end)

t.test("list_versions skips invalid manifests", function()
  local core = require "xc.core"
  local adapter = {
    write_file = function() return true end,
    read_file = function() return "not valid json", nil end,
    exists = function() return false end,
    mkdir = function() return true end,
    list_dir = function() return { "bad-entry" } end,
    remove = function() return true end,
    hash_file = function() return nil end,
    read_link = function() return nil end,
    json_parse = mock_json_parse
  }
  local versions = core.list_versions(adapter)
  t.eq(#versions, 0)
end)
