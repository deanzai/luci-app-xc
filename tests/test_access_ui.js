"use strict";

const assert = require("assert");
const fs = require("fs");
const model = fs.readFileSync("luasrc/model/cbi/xc/access.lua", "utf8");
const view = fs.readFileSync("luasrc/view/xc/access.htm", "utf8");

assert.ok(model.includes('SimpleForm("xc_access"'), "access page uses a SimpleForm shell");
for (const id of ["xc-access-page", "xc-access-dns-remote", "xc-access-dns-cn",
  "xc-access-direct-domains", "xc-access-proxy-domains", "xc-access-direct-ips",
  "xc-access-proxy-ips", "xc-access-apply", "xc-access-result"]) {
  assert.ok(view.includes('id="' + id + '"'), "missing access UI element " + id);
}
assert.ok(view.includes("access-status"), "access page loads the current configuration");
assert.ok(view.includes("access-apply"), "access page applies through the protected endpoint");
assert.ok(view.includes("JSON.stringify"), "access page submits JSON");
assert.ok(view.includes("校验失败" ) || view.includes("validation"), "access page explains validation failure");

console.log("access UI static tests passed");
