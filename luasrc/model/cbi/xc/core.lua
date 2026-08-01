local m = SimpleForm("xc_core")
m.submit = false
m.reset = false
m.cancel = false

local section = m:section(SimpleSection)
section.template = "xc/core"

return m
