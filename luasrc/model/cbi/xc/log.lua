local m = Map("xc")

local log = m:section(TypedSection, "_log", translate("Log"),
  translate("XC runtime log uses JSON format. Entries older than 256 KiB are automatically trimmed."))
log.anonymous = true
log.template = "xc/log"

return m