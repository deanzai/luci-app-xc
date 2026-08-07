local t = require "testlib"
local manager_module = require "xc.assetmanager"

local function fixture(options)
  options = options or {}
  local files = options.files or {}
  local dirs = {
    ["/etc/xc/xray/assets"] = true,
    ["/etc/xc/xray/assets/default"] = true
  }
  local events = {}
  local fs = {
    exists = function(path) return files[path] ~= nil or dirs[path] == true end,
    stat = function(path)
      if files[path] ~= nil then return { type = "reg", size = #files[path] } end
      if dirs[path] then return { type = "dir" } end
      return nil
    end,
    mkdir = function(path) dirs[path] = true; return true end,
    copy_file = function(source, destination)
      if files[source] == nil then return false end
      files[destination] = files[source]
      events[#events + 1] = "copy:" .. source .. ":" .. destination
      return true
    end,
    rename = function(source, destination)
      if files[source] == nil then return false end
      files[destination], files[source] = files[source], nil
      events[#events + 1] = "rename:" .. source .. ":" .. destination
      return true
    end,
    remove = function(path) files[path] = nil; return true end,
    read = function(path) return files[path] end,
    write_file = function(path, content) files[path] = content; return true end
  }
  local exec = {
    download = function(url, path)
      events[#events + 1] = "download:" .. url .. ":" .. path
      if options.download_ok == false then return false end
      files[path] = options.downloaded or "downloaded-new"
      return true
    end,
    extract_xray = function(_, path)
      files[path] = options.extracted or "xray-binary"
      return options.extract_ok ~= false
    end,
    machine = function() return options.machine or "aarch64" end,
    hash_file = function() return "51c3e26e4ba03f3aabcdef1234567890abcdef1234567890abcdef1234567890" end
  }
  local core = {
    install = function(_, path, manifest)
      if files[path] == nil then return { ok = false, code = "core_install_failed" } end
      events[#events + 1] = "core-install:" .. manifest.id
      return { ok = true, code = "core_installed", version = manifest }
    end,
    rollback = function() return { ok = true, code = "core_rolled_back" } end
  }
  local manager = manager_module.new({
    fs = fs, exec = exec, core = core,
    uci = { get_global = function() return {} end },
    now = function() return 100 end, wall_time = function() return 1700000000 end
  })
  return manager, { files = files, dirs = dirs, events = events }
end

t.test("asset sources are fixed and invalid source falls back to official", function()
  local manager = assert(fixture())
  local sources = manager:sources("geoip")
  t.truthy(#sources >= 2)
  t.truthy(manager:source("geoip", "official"))
  t.eq(manager:source("geoip", "user-url"), manager:source("geoip", "official"))
  t.eq(manager:source("user-kind", "official"), nil)
end)

t.test("asset update keeps one immutable default snapshot", function()
  local manager, state = fixture({ files = {
    ["/usr/share/xray/geoip.dat"] = "package-old"
  } })
  t.truthy(manager:update("geoip", "official").ok)
  t.eq(state.files["/etc/xc/xray/assets/default/geoip.dat"], "package-old")
  t.eq(state.files["/etc/xc/xray/assets/geoip.dat"], "downloaded-new")
  state.downloaded = "downloaded-later"
  t.truthy(manager:update("geoip", "mirror").ok)
  t.eq(state.files["/etc/xc/xray/assets/default/geoip.dat"], "package-old")
  t.truthy(manager:rollback("geoip").ok)
  t.eq(state.files["/etc/xc/xray/assets/geoip.dat"], "package-old")
end)

t.test("asset download failure preserves the active file", function()
  local manager, state = fixture({ download_ok = false, files = {
    ["/etc/xc/xray/assets/geoip.dat"] = "current"
  } })
  local result = manager:update("geoip", "official")
  t.eq(result.ok, false)
  t.eq(result.code, "asset_download_failed")
  t.eq(state.files["/etc/xc/xray/assets/geoip.dat"], "current")
end)

t.test("xray update installs an inactive downloaded core without semantic validation", function()
  local manager, state = fixture({ downloaded = "xray-archive" })
  local result = manager:update("xray", "official")
  t.eq(result.ok, true)
  t.eq(result.code, "asset_updated")
  t.truthy(state.events[2]:match("core%-install:v26_6_27%-aarch64%-"))
end)

t.test("xray update normalizes common uname architecture aliases", function()
  local manager, state = fixture({ machine = "armv7l" })
  local result = manager:update("xray", "official")
  t.eq(result.ok, true)
  t.truthy(state.events[2]:match("core%-install:v26_6_27%-arm%-"))
end)

t.test("asset rollback without a default snapshot is safe", function()
  local manager, state = fixture({ files = { ["/etc/xc/xray/assets/geoip.dat"] = "current" } })
  local result = manager:rollback("geoip")
  t.eq(result.ok, false)
  t.eq(result.code, "asset_no_default")
  t.eq(state.files["/etc/xc/xray/assets/geoip.dat"], "current")
end)

return true
