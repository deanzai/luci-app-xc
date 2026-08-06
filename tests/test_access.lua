local t = require "testlib"
local access = require "xc.access"

t.test("access defaults are deterministic", function()
  local value = assert(access.normalize({}))
  t.eq(value.dns_remote, "https://8.8.8.8/dns-query")
  t.eq(value.dns_cn, "223.5.5.5")
  t.eq(value.dns_fallback, "https://1.1.1.1/dns-query")
  t.eq(#value.direct_domains, 0)
  t.eq(#value.proxy_domains, 0)
end)

t.test("access normalizes direct and proxy rules", function()
  local value = assert(access.normalize({
    dns_remote = "https://9.9.9.9/dns-query",
    dns_cn = "114.114.114.114",
    dns_fallback = "https://1.0.0.1/dns-query",
    direct_domains = "example.com\nfull:lan.example.com",
    proxy_domains = "geosite:openai",
    direct_ips = "192.0.2.0/24\ngeoip:private",
    proxy_ips = "198.51.100.0/24"
  }))
  t.eq(value.dns_remote, "https://9.9.9.9/dns-query")
  t.eq(value.direct_domains[1], "domain:example.com")
  t.eq(value.direct_domains[2], "full:lan.example.com")
  t.eq(value.proxy_domains[1], "geosite:openai")
  t.eq(value.direct_ips[1], "192.0.2.0/24")
  t.eq(value.direct_ips[2], "geoip:private")
end)

t.test("access rejects invalid DNS and conflicting rules", function()
  local value, code = access.normalize({ dns_remote = "file:///tmp/dns" })
  t.eq(value, nil)
  t.eq(code, "access_dns_invalid")
  value, code = access.normalize({ direct_domains = "example.com", proxy_domains = "example.com" })
  t.eq(value, nil)
  t.eq(code, "access_rule_conflict")
end)

t.test("access builds direct and proxy Xray rules", function()
  local value = assert(access.normalize({ direct_domains = "example.com", proxy_domains = "openai.com", direct_ips = "192.0.2.0/24" }))
  local rules = assert(access.rules(value, { balancerTag = "xc-balancer" }))
  t.eq(#rules, 3)
  t.eq(rules[1].outboundTag, "direct")
  t.eq(rules[2].balancerTag, "xc-balancer")
  t.eq(rules[3].outboundTag, "direct")
end)

return true
