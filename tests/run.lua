package.path = "tests/?.lua;root/usr/lib/lua/?.lua;root/usr/lib/lua/?/init.lua;" .. package.path

local testlib = require "testlib"
local manifest = "tests/tmp/test-files"
assert(os.execute("mkdir -p tests/tmp && find tests -maxdepth 1 -type f -name 'test_*.lua' -print | sort > " .. manifest) == 0)
local handle = assert(io.open(manifest, "r"))
for path in handle:lines() do
  local module = path:gsub("^tests/", ""):gsub("%.lua$", "")
  require(module)
end
handle:close()
os.remove(manifest)

if not testlib.finish() then
  os.exit(1)
end
