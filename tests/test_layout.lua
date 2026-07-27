local t = require "testlib"

t.test("required package files exist", function()
  for _, path in ipairs({
    "Makefile", "root/etc/config/xc", "root/etc/init.d/xc",
    "root/usr/bin/xc", "luasrc/controller/xc.lua"
  }) do
    t.truthy(io.open(path, "r"), path .. " is missing")
  end
end)
