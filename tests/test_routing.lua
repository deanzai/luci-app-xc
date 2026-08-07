local t = require "testlib"
local routing = require "xc.routing"

t.test("managed assets take precedence over package assets", function()
  local fs = { exists = function(path)
    return path == "/etc/xc/xray/assets/geosite.dat"
      or path == "/etc/xc/xray/assets/geoip.dat"
      or path == "/usr/share/xray/geosite.dat"
      or path == "/usr/share/xray/geoip.dat"
  end }
  t.eq(routing.MANAGED_ASSET_DIR, "/etc/xc/xray/assets")
  t.eq(routing.asset_dir(fs), "/etc/xc/xray/assets")
  local status = routing.asset_status(fs)
  t.eq(status.directory, "/etc/xc/xray/assets")
  t.eq(status.geosite, true)
  t.eq(status.geoip, true)
end)

t.test("package assets remain the fallback", function()
  local fs = { exists = function(path)
    return path == "/usr/share/xray/geosite.dat"
      or path == "/usr/share/xray/geoip.dat"
  end }
  t.eq(routing.asset_dir(fs), "/usr/share/xray")
end)

t.test("legacy v2ray assets remain the final fallback", function()
  local fs = { exists = function(path)
    return path == "/usr/share/v2ray/geosite.dat"
      or path == "/usr/share/v2ray/geoip.dat"
  end }
  t.eq(routing.asset_dir(fs), "/usr/share/v2ray")
end)

return true
