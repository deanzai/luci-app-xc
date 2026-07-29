local m = SimpleForm("xc_log", translate("Log"),
  translate("XC runtime and Xray core logs are shown here. Sensitive values are redacted."))
m.submit = false
m.reset = false
m.cancel = false

local section = m:section(SimpleSection)
section.template = "xc/log"

return m
