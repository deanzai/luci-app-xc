local m = SimpleForm("xc_access")
m.submit = false
m.reset = false
m.cancel = false

local section = m:section(SimpleSection)
section.template = "xc/access"

return m
