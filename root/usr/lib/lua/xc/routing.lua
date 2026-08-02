local M = {}

M.ASSET_DIR = "/usr/share/xray"
M.GEOSITE_PATH = M.ASSET_DIR .. "/geosite.dat"
M.GEOIP_PATH = M.ASSET_DIR .. "/geoip.dat"

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

local function copy(value)
  if type(value) ~= "table" then return value end
  local output = {}
  for key, item in pairs(value) do output[key] = copy(item) end
  return output
end

local function enabled(value)
  return value ~= false and value ~= 0 and value ~= "0"
end

function M.required_assets(global)
  if type(global) == "table" and not enabled(global.routing_enabled) then return {} end
  return { M.GEOSITE_PATH, M.GEOIP_PATH }
end

function M.build(global)
  local rules = {
    { type = "field", ip = copy(PRIVATE_CIDRS), outboundTag = "direct" }
  }
  if type(global) == "table" and not enabled(global.routing_enabled) then return rules end
  for _, rule in ipairs(PRESET_RULES) do rules[#rules + 1] = copy(rule) end
  return rules
end

return M
