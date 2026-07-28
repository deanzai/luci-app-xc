local m = SimpleForm("xc_log", translate("Log"),
  translate("The final 256 KiB of the XC runtime log is shown. Sensitive values are redacted before logging."))

m.submit = false
m.reset = false

local section = m:section(SimpleSection)
section.template = "xc/log"

return m
