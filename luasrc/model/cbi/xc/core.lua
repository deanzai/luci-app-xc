local m = SimpleForm("xc_core", translate("Xray"),
  translate("XC runtime and Xray core logs are shown here. Sensitive values are redacted."))
m.submit = false
m.reset = false
m.cancel = false

local section = m:section(SimpleSection)
section.template = "xc/core"

return m
