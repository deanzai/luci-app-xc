local M = {}

local DEFAULTS = {
  dns_remote = "https://8.8.8.8/dns-query",
  dns_cn = "223.5.5.5",
  dns_fallback = "https://1.1.1.1/dns-query"
}

local MAX_RULES = 256
local MAX_TEXT = 65536
local MAX_RULE_LENGTH = 1024

local function trim(value)
  return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function copy_list(values)
  local output = {}
  for index, value in ipairs(values or {}) do output[index] = value end
  return output
end

local function input_value(input, key)
  if input[key] ~= nil then return input[key] end
  return input["access_" .. key]
end

local function valid_host(value)
  if type(value) ~= "string" or value == "" or #value > 253 then return false end
  if value:find("[%z\1-\32\127/@?#]") then return false end
  if value:match("^%.") or value:match("%.$") or value:match("^%-") or value:match("%-$") then return false end
  for label in value:gmatch("[^%.]+") do
    if #label > 63 or label:match("^%-") or label:match("%-$")
      or not label:match("^[A-Za-z0-9][A-Za-z0-9%-]*$") then
      return false
    end
  end
  return true
end

local function valid_ipv4(value)
  local count = 0
  for part in value:gmatch("[^%.]+") do
    count = count + 1
    if not part:match("^%d%d?%d?$") or tonumber(part) > 255 then return false end
  end
  return count == 4
end

local function valid_ipv6(value)
  if not value:find(":", 1, true) or value:find("[^0-9A-Fa-f:%.]", 1) then return false end
  local double = value:find("::", 1, true)
  if double and value:find("::", double + 2, true) then return false end
  local left, right = value, ""
  if double then
    left = value:sub(1, double - 1)
    right = value:sub(double + 2)
  end
  local groups = 0
  local function count_groups(part)
    if part == "" then return true end
    for group in part:gmatch("[^:]+") do
      if group:find("%.", 1, true) then
        if not valid_ipv4(group) then return false end
        groups = groups + 2
      else
        if #group < 1 or #group > 4 then return false end
        groups = groups + 1
      end
    end
    return true
  end
  if not count_groups(left) or not count_groups(right) then return false end
  return double and groups < 8 or (not double and groups == 8)
end

local function valid_ip(value)
  if type(value) ~= "string" or value == "" then return false end
  return valid_ipv4(value) or valid_ipv6(value)
end

local function valid_ip_rule(value)
  local address, prefix = value:match("^([^/]+)/(%d+)$")
  if address then
    if not valid_ip(address) then return false end
    prefix = tonumber(prefix)
    if valid_ipv4(address) then return prefix <= 32 end
    return prefix <= 128
  end
  return valid_ip(value)
end

local function valid_dns(value, allow_https)
  if type(value) ~= "string" or #value == 0 or #value > 2048
    or value:find("[%z\1-\31\127%s]") then return false end
  if allow_https and value:match("^https://") then
    local host, port, path = value:match("^https://([^/:]+):(%d+)(/.*)$")
    if not host then host, path = value:match("^https://([^/:]+)(/.*)$") end
    if not host then return false end
    if port and (tonumber(port) < 1 or tonumber(port) > 65535) then return false end
    if not valid_host(host) or not path or path == "/" then return false end
    return true
  end
  return valid_ip(value) or valid_host(value)
end

local function prefixed(value, prefix)
  return value:match("^" .. prefix .. ":(.+)$")
end

local function normalize_domain_rule(value)
  local kind, payload
  for _, candidate in ipairs({ "full", "domain", "geosite" }) do
    payload = value:match("^" .. candidate .. ":(.+)$")
    if payload then kind = candidate; break end
  end
  if kind then
    payload = trim(payload)
    if payload == "" or #payload > 253 or payload:find("[%z\1-\31\127%s]") then return nil end
    if kind == "geosite" then
      if not payload:match("^[A-Za-z0-9_.!%-]+$") then return nil end
    elseif not valid_host(payload) then
      return nil
    end
    return kind .. ":" .. payload:lower()
  end
  if value:find(":", 1, true) then return nil end
  if not valid_host(value) then return nil end
  return "domain:" .. value:lower()
end

local function normalize_ip_rule(value)
  local geo = prefixed(value, "geoip")
  if geo then
    geo = trim(geo)
    if geo == "" or #geo > 128 or not geo:match("^[A-Za-z0-9_.!%-]+$") then return nil end
    return "geoip:" .. geo:lower()
  end
  if value:find(":", 1, true) and not valid_ip_rule(value) then return nil end
  if not valid_ip_rule(value) then return nil end
  return value:lower()
end

local function normalize_rules(value, kind)
  if value == nil or value == "" then return {} end
  if type(value) ~= "string" or #value > MAX_TEXT then return nil, "access_rule_too_long" end
  local output, seen = {}, {}
  for line in (value .. "\n"):gmatch("(.-)\r?\n") do
    line = trim(line)
    if line ~= "" then
      if #line > MAX_RULE_LENGTH then return nil, "access_rule_too_long" end
      local normalized = kind == "domain" and normalize_domain_rule(line) or normalize_ip_rule(line)
      if not normalized then return nil, "access_rule_invalid" end
      if not seen[normalized] then
        if #output >= MAX_RULES then return nil, "access_rule_too_many" end
        seen[normalized] = true
        output[#output + 1] = normalized
      end
    end
  end
  return output
end

local function normalize_dns(input, key, fallback, allow_https)
  local value = input_value(input, key)
  if value == nil or value == "" then value = fallback end
  if type(value) ~= "string" then return nil, "access_dns_invalid" end
  value = trim(value)
  if not valid_dns(value, allow_https) then return nil, "access_dns_invalid" end
  return value
end

function M.normalize(input)
  if type(input) ~= "table" then return nil, "access_invalid" end
  local dns_remote, code = normalize_dns(input, "dns_remote", DEFAULTS.dns_remote, true)
  if not dns_remote then return nil, code end
  local dns_cn
  dns_cn, code = normalize_dns(input, "dns_cn", DEFAULTS.dns_cn, false)
  if not dns_cn then return nil, code end
  local dns_fallback
  dns_fallback, code = normalize_dns(input, "dns_fallback", DEFAULTS.dns_fallback, true)
  if not dns_fallback then return nil, code end

  local direct_domains
  direct_domains, code = normalize_rules(input_value(input, "direct_domains"), "domain")
  if not direct_domains then return nil, code end
  local proxy_domains
  proxy_domains, code = normalize_rules(input_value(input, "proxy_domains"), "domain")
  if not proxy_domains then return nil, code end
  local direct_ips
  direct_ips, code = normalize_rules(input_value(input, "direct_ips"), "ip")
  if not direct_ips then return nil, code end
  local proxy_ips
  proxy_ips, code = normalize_rules(input_value(input, "proxy_ips"), "ip")
  if not proxy_ips then return nil, code end

  local direct, proxy = {}, {}
  for _, value in ipairs(direct_domains) do direct[value] = true end
  for _, value in ipairs(direct_ips) do direct[value] = true end
  for _, value in ipairs(proxy_domains) do proxy[value] = true end
  for _, value in ipairs(proxy_ips) do proxy[value] = true end
  for value in pairs(direct) do
    if proxy[value] then return nil, "access_rule_conflict" end
  end

  return {
    dns_remote = dns_remote, dns_cn = dns_cn, dns_fallback = dns_fallback,
    direct_domains = direct_domains, proxy_domains = proxy_domains,
    direct_ips = direct_ips, proxy_ips = proxy_ips
  }
end

local function add_rule(rules, field, values, outbound)
  if #values == 0 then return end
  local rule = { type = "field", [field] = copy_list(values) }
  if outbound == "proxy" then
    rule.outboundTag = "proxy-selected"
  else
    rule.outboundTag = outbound
  end
  rules[#rules + 1] = rule
end

function M.rules(value, target)
  if type(value) ~= "table" then return nil, "access_invalid" end
  local rules = {}
  add_rule(rules, "domain", value.direct_domains or {}, "direct")
  if #(value.proxy_domains or {}) > 0 then
    local rule = { type = "field", domain = copy_list(value.proxy_domains) }
    if type(target) == "table" and type(target.balancerTag) == "string" and target.balancerTag ~= "" then
      rule.balancerTag = target.balancerTag
    else
      rule.outboundTag = "proxy-selected"
    end
    rules[#rules + 1] = rule
  end
  add_rule(rules, "ip", value.direct_ips or {}, "direct")
  if #(value.proxy_ips or {}) > 0 then
    local rule = { type = "field", ip = copy_list(value.proxy_ips) }
    if type(target) == "table" and type(target.balancerTag) == "string" and target.balancerTag ~= "" then
      rule.balancerTag = target.balancerTag
    else
      rule.outboundTag = "proxy-selected"
    end
    rules[#rules + 1] = rule
  end
  return rules
end

function M.uci(value)
  if type(value) ~= "table" then return nil end
  local function lines(values) return table.concat(values or {}, "\n") end
  return {
    access_dns_remote = value.dns_remote, access_dns_cn = value.dns_cn, access_dns_fallback = value.dns_fallback,
    access_direct_domains = lines(value.direct_domains), access_proxy_domains = lines(value.proxy_domains),
    access_direct_ips = lines(value.direct_ips), access_proxy_ips = lines(value.proxy_ips)
  }
end

M.defaults = function()
  return {
    dns_remote = DEFAULTS.dns_remote, dns_cn = DEFAULTS.dns_cn, dns_fallback = DEFAULTS.dns_fallback,
    direct_domains = {}, proxy_domains = {}, direct_ips = {}, proxy_ips = {}
  }
end

return M
