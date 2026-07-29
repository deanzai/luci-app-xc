local M = {}

local LEVELS = { all = true, error = true, warning = true, info = true, debug = true }
local ENTRY_LEVELS = { error = true, warning = true, info = true, debug = true }
local SOURCE_MAX = 262144
local LINE_MAX = 8192
local LINE_COUNT_MAX = 4096
local ENTRY_MAX = 512
local MESSAGE_MAX = 1024

local months = {
  Jan = 1, Feb = 2, Mar = 3, Apr = 4, May = 5, Jun = 6,
  Jul = 7, Aug = 8, Sep = 9, Oct = 10, Nov = 11, Dec = 12
}

local function utf8_prefix(value, maximum)
  if #value <= maximum then return value end
  local index = maximum
  while index > 0 do
    local byte = value:byte(index)
    if byte < 128 then return value:sub(1, index) end
    if byte >= 194 and byte <= 244 then
      local width = byte < 224 and 2 or (byte < 240 and 3 or 4)
      return value:sub(1, index + width - 1 <= maximum and index + width - 1 or index - 1)
    end
    index = index - 1
  end
  return ""
end

local function after_secret(value, start_at)
  local quote = value:sub(start_at, start_at)
  if quote == '"' or quote == "'" then
    local index = start_at + 1
    while index <= #value do
      local character = value:sub(index, index)
      if character == "\\" then
        index = index + 2
      elseif character == quote then
        return index + 1
      else
        index = index + 1
      end
    end
    return #value + 1
  end
  local index = start_at
  while index <= #value and not value:sub(index, index):match("[%s,;]") do index = index + 1 end
  return index
end

local function redact_values(value, prefix)
  local output, cursor = {}, 1
  while cursor <= #value do
    local first, last = value:find(prefix, cursor)
    if not first then break end
    output[#output + 1] = value:sub(cursor, last)
    output[#output + 1] = "[redacted]"
    cursor = after_secret(value, last + 1)
  end
  output[#output + 1] = value:sub(cursor)
  return table.concat(output)
end

local function redact_assignment(value, key)
  return redact_values(value, key .. "%s*[:=]%s*")
end

local function redact_bearer(value)
  return redact_values(value,
    "[Aa][Uu][Tt][Hh][Oo][Rr][Ii][Zz][Aa][Tt][Ii][Oo][Nn]%s*:%s*[Bb][Ee][Aa][Rr][Ee][Rr]%s+")
end

local function sanitize(value, maximum)
  if type(value) ~= "string" then value = tostring(value) end
  value = utf8_prefix(value, LINE_MAX)
  if value:find("{", 1, true) then value = value:gsub("%b{}", "[redacted]") end
  if value:find("[", 1, true) then value = value:gsub("%b[]", "[redacted]") end
  value = value:gsub("%-%-%-%-%-[Bb][Ee][Gg][Ii][Nn] [Pp][Rr][Ii][Vv][Aa][Tt][Ee] [Kk][Ee][Yy]%-%-%-%-%-.-%-%-%-%-%-[Ee][Nn][Dd] [Pp][Rr][Ii][Vv][Aa][Tt][Ee] [Kk][Ee][Yy]%-%-%-%-%-", "[redacted]")
  if value:find("://", 1, true) then value = value:gsub("%a[%w+%.%-]*://[^%s]+", "[redacted]") end
  value = value:gsub("%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x", "[redacted]")
  value = redact_bearer(value)
  value = redact_assignment(value, "[Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]")
  value = redact_assignment(value, "[Pp][Aa][Ss][Ss][Ww][Dd]")
  value = redact_assignment(value, "[Tt][Oo][Kk][Ee][Nn]")
  value = redact_assignment(value, "[Ss][Ee][Cc][Rr][Ee][Tt]")
  value = redact_assignment(value, "[Aa][Pp][Ii][_-][Kk][Ee][Yy]")
  value = redact_assignment(value, "[Pp][Rr][Ii][Vv][Aa][Tt][Ee][_-][Kk][Ee][Yy]")
  return utf8_prefix(value, maximum or MESSAGE_MAX)
end

local function sensitive_key(key)
  local lowered = key:lower()
  for _, fragment in ipairs({
    "password", "passwd", "uuid", "secret", "token", "api_key", "apikey",
    "private_key", "privatekey", "credential", "userinfo", "share", "link",
    "uri", "url", "raw", "content", "config"
  }) do
    if lowered:find(fragment, 1, true) then return true end
  end
  return false
end

local function bounded_lines(value)
  if type(value) ~= "string" then return function() end end
  value = value:sub(1, SOURCE_MAX)
  local position, count = 1, 0
  return function()
    if position > #value or count >= LINE_COUNT_MAX then return nil end
    local newline = value:find("\n", position, true)
    local line
    if newline then line, position = value:sub(position, newline - 1), newline + 1
    else line, position = value:sub(position), #value + 1 end
    count = count + 1
    if line:sub(-1) == "\r" then line = line:sub(1, -2) end
    return line:sub(1, LINE_MAX)
  end
end

local function display_duration(seconds)
  seconds = math.max(0, math.floor(seconds))
  return string.format("T+%02d:%02d:%02d", math.floor(seconds / 3600), math.floor(seconds / 60) % 60, seconds % 60)
end

local function display_epoch(value)
  local called, result = pcall(os.date, "%Y-%m-%d %H:%M:%S", value)
  return called and type(result) == "string" and result or "unknown"
end

local function fields_message(message, fields)
  local parts = { sanitize(message, MESSAGE_MAX) }
  if fields ~= nil then
    local keys = {}
    for key in pairs(fields) do
      if type(key) == "string" and key:match("^[A-Za-z0-9_.-]+$") then keys[#keys + 1] = key end
    end
    table.sort(keys)
    for index, key in ipairs(keys) do
      if index > 16 then break end
      local value = fields[key]
      local safe
      if sensitive_key(key) then safe = "[redacted]"
      elseif type(value) == "string" or type(value) == "number" or type(value) == "boolean" then safe = sanitize(value, 128)
      else safe = "[redacted]" end
      parts[#parts + 1] = key:sub(1, 64) .. "=" .. safe
    end
  end
  return utf8_prefix(table.concat(parts, " "), MESSAGE_MAX)
end

local function parse_xc(line, options, order)
  if line == "" or type(options.json) ~= "table" or type(options.json.parse) ~= "function" then return nil end
  local called, value = pcall(options.json.parse, line)
  if not called or type(value) ~= "table" or type(value.time) ~= "number"
    or value.time < 0 or value.time ~= value.time or value.time == math.huge or value.time == -math.huge
    or not ENTRY_LEVELS[value.level] or type(value.message) ~= "string"
    or (value.fields ~= nil and type(value.fields) ~= "table") then return nil end
  local epoch, shown
  if value.time < 1000000000 then
    epoch = options.wall_time - options.uptime + value.time
    shown = display_duration(value.time)
  else
    epoch = value.time
    shown = display_epoch(value.time)
  end
  return {
    time = epoch, display_time = shown, level = value.level, source = "xc",
    message = fields_message(value.message, value.fields), _order = order
  }
end

local function epoch_from_parts(year, month, day, hour, minute, second)
  month = months[month] or tonumber(month)
  if not month then return nil end
  local called, value = pcall(os.time, {
    year = tonumber(year), month = month, day = tonumber(day), hour = tonumber(hour),
    min = tonumber(minute), sec = tonumber(second), isdst = false
  })
  return called and type(value) == "number" and value or nil
end

local function xray_parts(line, wall_time)
  local month, day, hour, minute, second, year, facility, tag, message =
    line:match("^%a%a%a%s+(%a%a%a)%s+(%d%d?)%s+(%d%d):(%d%d):(%d%d)%s+(%d%d%d%d)%s+(%S+)%s+(xray%[%d+%]:)%s*(.*)$")
  if not tag then
    month, day, hour, minute, second, year, facility, tag, message =
      line:match("^(%a%a%a)%s+(%d%d?)%s+(%d%d):(%d%d):(%d%d)%s+(%d%d%d%d)%s+(%S+)%s+(xray%[%d+%]:)%s*(.*)$")
  end
  if not tag then
    month, day, hour, minute, second, facility, tag, message =
      line:match("^(%a%a%a)%s+(%d%d?)%s+(%d%d):(%d%d):(%d%d)%s+(%S+)%s+(xray%[%d+%]:)%s*(.*)$")
    year = os.date("%Y", wall_time)
  end
  if tag then return epoch_from_parts(year, month, day, hour, minute, second), facility, message end

  local numeric_month
  year, numeric_month, day, hour, minute, second, facility, tag, message =
    line:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)[T ](%d%d):(%d%d):(%d%d)[^%s]*%s+(%S+)%s+(xray%[%d+%]:)%s*(.*)$")
  if tag then return epoch_from_parts(year, numeric_month, day, hour, minute, second), facility, message end

  facility, tag, message = line:match("^(%S+)%s+(xray%[%d+%]:)%s*(.*)$")
  if tag then return nil, facility, message end
  facility, tag, message = line:match("^.*%s(%S+)%s+(xray%[%d+%]:)%s*(.*)$")
  if tag then return nil, facility, message end
  return nil
end

local function xray_level(facility)
  local suffix = type(facility) == "string" and facility:match("%.([A-Za-z]+)$") or nil
  suffix = suffix and suffix:lower() or ""
  if suffix == "err" or suffix == "error" or suffix == "crit" or suffix == "alert" or suffix == "emerg" then return "error" end
  if suffix == "warn" or suffix == "warning" then return "warning" end
  if suffix == "info" then return "info" end
  if suffix == "debug" then return "debug" end
  return "warning"
end

local function parse_xray(line, options, order)
  local epoch, facility, message = xray_parts(line, options.wall_time)
  if facility == nil or type(message) ~= "string" then return nil end
  epoch = epoch or options.wall_time
  return {
    time = epoch, display_time = epoch and display_epoch(epoch) or "unknown",
    level = xray_level(facility), source = "xray", message = sanitize(message, MESSAGE_MAX), _order = order
  }
end

function M.collect(options)
  if type(options) ~= "table" or not LEVELS[options.level]
    or type(options.wall_time) ~= "number" or type(options.uptime) ~= "number" then return nil, "invalid_level" end
  local entries, order = {}, 0
  local function append(iterator, parser)
    for line in iterator do
      order = order + 1
      local entry = parser(line, options, order)
      if entry and (options.level == "all" or entry.level == options.level) then entries[#entries + 1] = entry end
    end
  end
  append(bounded_lines(options.xc), parse_xc)
  append(bounded_lines(options.xray), parse_xray)
  table.sort(entries, function(left, right)
    if left.time == right.time then return left._order < right._order end
    return left.time < right.time
  end)
  if #entries > ENTRY_MAX then
    local recent = {}
    for index = #entries - ENTRY_MAX + 1, #entries do recent[#recent + 1] = entries[index] end
    entries = recent
  end
  for _, entry in ipairs(entries) do entry._order = nil end
  return entries
end

return M
