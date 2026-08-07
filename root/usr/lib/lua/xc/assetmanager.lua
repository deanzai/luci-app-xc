local routing = require "xc.routing"
local core = require "xc.core"

local M = {}
local Manager = {}
Manager.__index = Manager

local XRAY_VERSION = routing.MAX_SUPPORTED_VERSION
local ACTIVE_DIR = routing.MANAGED_ASSET_DIR
local DEFAULT_DIR = ACTIVE_DIR .. "/default"
local SOURCE_PREFIX = "https://gh-proxy.net/"

local SOURCE_TABLE = {
  xray = {
    official = {
      id = "official", label = "Official GitHub", format = "zip",
      url = "https://github.com/XTLS/Xray-core/releases/download/v" .. XRAY_VERSION .. "/Xray-linux-%s.zip"
    },
    mirror = {
      id = "mirror", label = "GitHub mirror", format = "zip",
      url = SOURCE_PREFIX .. "https://github.com/XTLS/Xray-core/releases/download/v" .. XRAY_VERSION .. "/Xray-linux-%s.zip"
    }
  },
  geoip = {
    official = {
      id = "official", label = "Official rules release", format = "dat",
      url = "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"
    },
    mirror = {
      id = "mirror", label = "jsDelivr mirror", format = "dat",
      url = "https://fastly.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geoip.dat"
    }
  },
  geosite = {
    official = {
      id = "official", label = "Official rules release", format = "dat",
      url = "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"
    },
    mirror = {
      id = "mirror", label = "jsDelivr mirror", format = "dat",
      url = "https://fastly.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geosite.dat"
    }
  }
}

local FILE_NAMES = { geoip = "geoip.dat", geosite = "geosite.dat" }
local ARCHIVE_ARCH = {
  aarch64 = "arm64-v8a", arm = "arm32-v7a", x86_64 = "64", i386 = "32"
}
local ARCH_ALIASES = {
  aarch64 = "aarch64", arm64 = "aarch64", armv8l = "arm", armv7 = "arm", armv7l = "arm", arm = "arm",
  x86_64 = "x86_64", amd64 = "x86_64", i386 = "i386", i486 = "i386", i586 = "i386", i686 = "i386"
}

local function result(ok, code, fields)
  local output = { ok = ok, code = code }
  for key, value in pairs(fields or {}) do output[key] = value end
  return output
end

local function safe_kind(kind)
  return type(kind) == "string" and SOURCE_TABLE[kind] ~= nil
end

local function public_source(source)
  return { id = source.id, label = source.label }
end

local function asset_path(kind)
  return ACTIVE_DIR .. "/" .. FILE_NAMES[kind]
end

local function default_path(kind)
  return DEFAULT_DIR .. "/" .. FILE_NAMES[kind]
end

local function ensure_dir(fs, path)
  if fs.exists(path) then return true end
  return type(fs.mkdir) == "function" and fs.mkdir(path, 700) == true
end

local function source_path(fs, kind)
  for _, directory in ipairs({ ACTIVE_DIR, routing.ASSET_DIR, routing.FALLBACK_ASSET_DIR }) do
    local path = directory .. "/" .. FILE_NAMES[kind]
    if fs.exists(path) then return path end
  end
  return nil
end

local function arch_info(arch)
  if type(arch) ~= "string" then return nil end
  local raw = arch:lower()
  local normalized = ARCH_ALIASES[raw]
  return normalized, normalized and ARCHIVE_ARCH[normalized]
end

function M.new(adapters)
  if type(adapters) ~= "table" or type(adapters.fs) ~= "table" or type(adapters.exec) ~= "table"
    or type(adapters.now) ~= "function" or type(adapters.wall_time) ~= "function" then return nil end
  if type(adapters.fs.exists) ~= "function" or type(adapters.fs.mkdir) ~= "function"
    or type(adapters.fs.copy_file) ~= "function" or type(adapters.fs.rename) ~= "function"
    or type(adapters.fs.remove) ~= "function" or type(adapters.fs.stat) ~= "function"
    or type(adapters.exec.download) ~= "function" or type(adapters.exec.extract_xray) ~= "function" then return nil end
  return setmetatable({ fs = adapters.fs, exec = adapters.exec, core = adapters.core,
    uci = adapters.uci, now = adapters.now, wall_time = adapters.wall_time }, Manager)
end

function Manager:source(kind, id)
  if not safe_kind(kind) then return nil end
  return SOURCE_TABLE[kind][id] or SOURCE_TABLE[kind].official
end

function Manager:sources(kind)
  if not safe_kind(kind) then return {} end
  local values = {}
  for _, id in ipairs({ "official", "mirror" }) do
    values[#values + 1] = public_source(SOURCE_TABLE[kind][id])
  end
  return values
end

function Manager:status()
  local assets = routing.asset_status(self.fs)
  local defaults = {}
  for _, kind in ipairs({ "geoip", "geosite" }) do defaults[kind] = self.fs.exists(default_path(kind)) end
  assets.sources = {}
  assets.selected = {}
  assets.defaults = defaults
  for _, kind in ipairs({ "xray", "geoip", "geosite" }) do
    assets.sources[kind] = self:sources(kind)
    local selected = "official"
    local global = self.uci and self.uci.get_global and self.uci.get_global() or nil
    local option = type(global) == "table" and global[kind .. "_update_source"] or nil
    if type(option) == "string" and SOURCE_TABLE[kind][option] then selected = option end
    assets.selected[kind] = selected
  end
  return assets
end

function Manager:_update_geo(kind, source)
  local fs = self.fs
  if not ensure_dir(fs, ACTIVE_DIR) or not ensure_dir(fs, DEFAULT_DIR) then return result(false, "asset_install_failed") end
  local target, temporary = asset_path(kind), "/var/etc/xc/.asset-update-" .. kind
  if not fs.exists(default_path(kind)) then
    local baseline = fs.exists(target) and target or source_path(fs, kind)
    if baseline and not fs.copy_file(baseline, default_path(kind), 67108864, 600) then
      return result(false, "asset_install_failed")
    end
  end
  fs.remove(temporary)
  if self.exec.download(source.url, temporary, 67108864, self.now() + 120) ~= true then
    fs.remove(temporary)
    return result(false, "asset_download_failed")
  end
  local renamed = fs.rename(temporary, target)
  fs.remove(temporary)
  if not renamed then return result(false, "asset_install_failed") end
  return result(true, "asset_updated", { kind = kind, source = source.id, default = fs.exists(default_path(kind)) })
end

function Manager:_update_xray(source)
  if type(self.core) ~= "table" or type(self.core.install) ~= "function"
    or type(self.exec.machine) ~= "function" or type(self.exec.hash_file) ~= "function" then
    return result(false, "asset_runtime_unavailable")
  end
  local raw_arch = self.exec.machine(self.now() + 5)
  local arch, release_arch = arch_info(raw_arch)
  if not arch or not release_arch then return result(false, "asset_invalid") end
  local archive = "/var/etc/xc/.asset-update-xray.zip"
  local binary = "/var/etc/xc/.asset-update-xray"
  self.fs.remove(archive); self.fs.remove(binary)
  local url = string.format(source.url, release_arch)
  if self.exec.download(url, archive, 67108864, self.now() + 120) ~= true then
    self.fs.remove(archive); return result(false, "asset_download_failed")
  end
  if self.exec.extract_xray(archive, binary, self.now() + 30) ~= true then
    self.fs.remove(archive); self.fs.remove(binary); return result(false, "asset_install_failed")
  end
  local stat = self.fs.stat(binary)
  local hash = self.exec.hash_file(binary, self.now() + 30)
  if type(stat) ~= "table" or stat.type ~= "reg" or type(stat.size) ~= "number" or stat.size < 1
    or type(hash) ~= "string" then
    self.fs.remove(archive); self.fs.remove(binary); return result(false, "asset_install_failed")
  end
  local id = core.version_id(XRAY_VERSION, arch, hash)
  local manifest = id and { id = id, version = XRAY_VERSION, arch = arch, size = stat.size,
    sha256 = hash, uploaded_at = self.wall_time(), validation = "binary" } or nil
  local installed = manifest and self.core:install(binary, manifest) or nil
  self.fs.remove(archive); self.fs.remove(binary)
  if type(installed) ~= "table" or installed.ok ~= true then return result(false, "asset_install_failed") end
  return result(true, "asset_updated", { kind = "xray", source = source.id, version = installed.version })
end

function Manager:update(kind, source_id)
  if not safe_kind(kind) then return result(false, "asset_invalid") end
  local source = self:source(kind, source_id)
  if kind == "xray" then return self:_update_xray(source) end
  return self:_update_geo(kind, source)
end

function Manager:rollback(kind)
  if kind == "xray" then
    if type(self.core) ~= "table" or type(self.core.rollback) ~= "function" then return result(false, "asset_runtime_unavailable") end
    return self.core:rollback()
  end
  if not FILE_NAMES[kind] then return result(false, "asset_invalid") end
  local backup = default_path(kind)
  if not self.fs.exists(backup) then return result(false, "asset_no_default") end
  if self.fs.copy_file(backup, asset_path(kind), 67108864, 600) ~= true then return result(false, "asset_install_failed") end
  return result(true, "asset_rolled_back", { kind = kind })
end

M.ACTIVE_DIR = ACTIVE_DIR
M.DEFAULT_DIR = DEFAULT_DIR
M.SOURCES = SOURCE_TABLE

return M
