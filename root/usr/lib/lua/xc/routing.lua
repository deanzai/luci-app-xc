local M = {}
local access = require "xc.access"

M.ASSET_DIR = "/usr/share/xray"
M.FALLBACK_ASSET_DIR = "/usr/share/v2ray"
M.GEOSITE_PATH = M.ASSET_DIR .. "/geosite.dat"
M.GEOIP_PATH = M.ASSET_DIR .. "/geoip.dat"
M.FALLBACK_GEOSITE_PATH = M.FALLBACK_ASSET_DIR .. "/geosite.dat"
M.FALLBACK_GEOIP_PATH = M.FALLBACK_ASSET_DIR .. "/geoip.dat"
M.MAX_SUPPORTED_VERSION = "26.6.27"

local PRIVATE_CIDRS = {
  "0.0.0.0/8",
  "10.0.0.0/8",
  "127.0.0.0/8",
  "169.254.0.0/16",
  "172.16.0.0/12",
  "192.168.0.0/16",
  "224.0.0.0/4",
  "::1/128",
  "fc00::/7",
  "fe80::/10"
}

local PRESET_RULES = {
  { type = "field", domain = { "geosite:category-ads-all" }, outboundTag = "block" },
  { type = "field", ip = { "geoip:private" }, outboundTag = "direct" },
  { type = "field", domain = { "geosite:private" }, outboundTag = "direct" },
  {
    type = "field",
    domain = {
      "full:ik.chenmandi.eu.org", "domain:chenmandi.eu.org",
      "full:atls4.778688.xyz", "domain:778688.xyz"
    },
    ip = { "192.168.0.0/16", "10.0.0.0/8", "172.16.0.0/12", "120.237.86.198", "104.224.159.174" },
    outboundTag = "direct"
  },
  {
    type = "field",
    domain = {
      "geosite:openai", "geosite:youtube", "geosite:twitter", "geosite:telegram",
      "geosite:tiktok", "geosite:netflix", "geosite:google", "geosite:facebook",
      "full:voice.google.com", "domain:voice.googleusercontent.com"
    },
    outboundTag = "proxy-selected"
  },
  { type = "field", domain = { "geosite:geolocation-!cn" }, outboundTag = "proxy-selected" },
  { type = "field", ip = { "geoip:cn" }, outboundTag = "direct" },
  { type = "field", domain = { "geosite:cn" }, outboundTag = "direct" },
  {
    type = "field",
    domain = {
      "full:publicwsldistros.blob.core.windows.net", "full:services.googleapis.cn",
      "full:registry-1.docker.io", "full:www.cpu-monkey.com", "domain:armbian.org",
      "domain:armbian.com", "domain:cpu-monkey.com", "domain:vsean.net"
    },
    outboundTag = "proxy-selected"
  }
}

local DNS_INBOUND_TAG = "dns-in"

local DNS_SERVERS = {
  {
    address = "https://8.8.8.8/dns-query",
    domains = {
      "geosite:geolocation-!cn", "geosite:openai", "geosite:youtube",
      "geosite:twitter", "geosite:telegram", "geosite:tiktok",
      "geosite:netflix", "geosite:google", "geosite:facebook"
    },
    skipFallback = true
  },
  {
    address = "223.5.5.5",
    domains = { "geosite:cn" },
    skipFallback = true
  },
  {
    address = "localhost",
    domains = { "geosite:private" },
    skipFallback = true
  },
  {
    address = "https://1.1.1.1/dns-query",
    skipFallback = false
  }
}

local function copy(value)
  if type(value) ~= "table" then return value end
  local output = {}
  for key, item in pairs(value) do output[key] = copy(item) end
  return output
end

local function enabled(value)
  return value ~= false and value ~= 0 and value ~= "0"
end

local function asset_exists(fs, path)
  local probe = fs.exists
  if type(probe) == "function" then
    local called, value = pcall(probe, path)
    return called and value ~= nil and value ~= false
  end
  probe = fs.stat
  if type(probe) ~= "function" then return false end
  local called, value = pcall(probe, path)
  if not called or value == nil or value == false then return false end
  return type(value) ~= "table" or value.type == nil or value.type == "reg"
end

function M.asset_dir(fs)
  if type(fs) ~= "table" or (type(fs.exists) ~= "function" and type(fs.stat) ~= "function") then return nil end
  for _, directory in ipairs({ M.ASSET_DIR, M.FALLBACK_ASSET_DIR }) do
    if asset_exists(fs, directory .. "/geosite.dat") and asset_exists(fs, directory .. "/geoip.dat") then
      return directory
    end
  end
  return nil
end

function M.asset_status(fs)
  local directory = M.asset_dir(fs)
  local geosite = asset_exists(fs, M.GEOSITE_PATH) or asset_exists(fs, M.FALLBACK_GEOSITE_PATH)
  local geoip = asset_exists(fs, M.GEOIP_PATH) or asset_exists(fs, M.FALLBACK_GEOIP_PATH)
  return {
    directory = directory,
    geosite = geosite,
    geoip = geoip,
    ready = directory ~= nil,
    supported_version = M.MAX_SUPPORTED_VERSION,
    manual_upgrade = false
  }
end

function M.required_assets(global, fs)
  if type(global) == "table" and not enabled(global.routing_enabled) then return {} end
  local directory = M.asset_dir(fs)
  if directory then
    return { directory .. "/geosite.dat", directory .. "/geoip.dat" }
  end
  return { M.GEOSITE_PATH, M.GEOIP_PATH }
end

function M.dns(global, access_value)
  if type(global) == "table" and not enabled(global.routing_enabled) then return nil end
  if type(access_value) ~= "table" then access_value = access.normalize(global or {}) end
  if type(access_value) ~= "table" then return nil end
  -- Use the top-level DNS tag: it is supported by the old 21.02 core line,
  -- while per-name-server tags only appeared in newer Xray releases.
  return {
    tag = DNS_INBOUND_TAG,
    servers = {
      {
        address = access_value.dns_remote,
        domains = copy(DNS_SERVERS[1].domains),
        skipFallback = true
      },
      {
        address = access_value.dns_cn,
        domains = copy(DNS_SERVERS[2].domains),
        skipFallback = true
      },
      copy(DNS_SERVERS[3]),
      {
        address = access_value.dns_fallback,
        skipFallback = false
      }
    },
    queryStrategy = "UseIPv4",
    disableCache = false,
    disableFallbackIfMatch = true
  }
end

local function apply_proxy_target(rule, target)
  if rule.outboundTag ~= "proxy-selected" then return rule end
  if type(target) == "table" and type(target.balancerTag) == "string" and target.balancerTag ~= "" then
    rule.outboundTag = nil
    rule.balancerTag = target.balancerTag
  end
  return rule
end

function M.build(global, target, access_value)
  local rules = {}
  if type(access_value) ~= "table" then access_value = access.normalize(global or {}) end
  if type(global) ~= "table" or enabled(global.routing_enabled) then
    rules[#rules + 1] = apply_proxy_target({
      type = "field",
      inboundTag = { DNS_INBOUND_TAG },
      outboundTag = "proxy-selected"
    }, target)
  end
  rules[#rules + 1] = { type = "field", ip = copy(PRIVATE_CIDRS), outboundTag = "direct" }
  if type(access_value) == "table" then
    for _, custom in ipairs(access.rules(access_value, target) or {}) do rules[#rules + 1] = custom end
  end
  if type(global) == "table" and not enabled(global.routing_enabled) then
    if type(target) == "table" and type(target.balancerTag) == "string" and target.balancerTag ~= "" then
      rules[#rules + 1] = apply_proxy_target({ type = "field", outboundTag = "proxy-selected" }, target)
    end
    return rules
  end
  for _, rule in ipairs(PRESET_RULES) do
    rules[#rules + 1] = apply_proxy_target(copy(rule), target)
  end
  return rules
end

return M
