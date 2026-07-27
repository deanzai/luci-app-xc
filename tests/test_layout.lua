local t = require "testlib"

t.test("Makefile exists", function()
  t.truthy(io.open("Makefile", "r"), "Makefile is missing")
end)

for _, path in ipairs({
  "root/etc/config/xc", "root/etc/init.d/xc",
  "root/usr/bin/xc", "luasrc/controller/xc.lua"
}) do
  t.test(path .. " exists", function()
    t.truthy(io.open(path, "r"), path .. " is missing")
  end)
end
