local M = {}

local function skip_whitespace(text, pos)
  while pos <= #text do
    local c = text:sub(pos, pos)
    if c == " " or c == "\t" or c == "\n" or c == "\r" then
      pos = pos + 1
    else
      break
    end
  end
  return pos
end

local function parse_string(text, pos)
  if text:sub(pos, pos) ~= '"' then return nil, pos end
  pos = pos + 1
  local result = {}
  while pos <= #text do
    local c = text:sub(pos, pos)
    if c == '"' then
      return table.concat(result), pos + 1
    end
    if c == "\\" then
      pos = pos + 1
      local next = text:sub(pos, pos)
      if next == "n" then result[#result + 1] = "\n"
      elseif next == "t" then result[#result + 1] = "\t"
      elseif next == "r" then result[#result + 1] = "\r"
      elseif next == "\\" then result[#result + 1] = "\\"
      elseif next == '"' then result[#result + 1] = '"'
      else result[#result + 1] = next end
    else
      result[#result + 1] = c
    end
    pos = pos + 1
  end
  return nil, pos
end

local function parse_number(text, pos)
  local start = pos
  if text:sub(pos, pos) == "-" then pos = pos + 1 end
  while pos <= #text and text:sub(pos, pos):match("%d") do pos = pos + 1 end
  if text:sub(pos, pos) == "." then
    pos = pos + 1
    while pos <= #text and text:sub(pos, pos):match("%d") do pos = pos + 1 end
  end
  local num_str = text:sub(start, pos - 1)
  return tonumber(num_str), pos
end

local function parse_value(text, pos)
  pos = skip_whitespace(text, pos)
  if pos > #text then return nil, pos end
  local c = text:sub(pos, pos)
  if c == '"' then return parse_string(text, pos) end
  if c == "{" then
    local obj = {}
    pos = pos + 1
    pos = skip_whitespace(text, pos)
    if text:sub(pos, pos) == "}" then return obj, pos + 1 end
    while true do
      local key, val
      key, pos = parse_string(text, pos)
      if not key then return nil, pos end
      pos = skip_whitespace(text, pos)
      if text:sub(pos, pos) ~= ":" then return nil, pos end
      pos = pos + 1
      val, pos = parse_value(text, pos)
      obj[key] = val
      pos = skip_whitespace(text, pos)
      local sep = text:sub(pos, pos)
      if sep == "}" then return obj, pos + 1 end
      if sep ~= "," then return nil, pos end
      pos = pos + 1
    end
  end
  if c == "[" then
    local arr = {}
    pos = pos + 1
    pos = skip_whitespace(text, pos)
    if text:sub(pos, pos) == "]" then return arr, pos + 1 end
    while true do
      local val
      val, pos = parse_value(text, pos)
      arr[#arr + 1] = val
      pos = skip_whitespace(text, pos)
      local sep = text:sub(pos, pos)
      if sep == "]" then return arr, pos + 1 end
      if sep ~= "," then return nil, pos end
      pos = pos + 1
    end
  end
  if c == "t" and text:sub(pos, pos + 3) == "true" then return true, pos + 4 end
  if c == "f" and text:sub(pos, pos + 4) == "false" then return false, pos + 5 end
  if c == "n" and text:sub(pos, pos + 3) == "null" then return nil, pos + 4 end
  if c == "-" or c:match("%d") then return parse_number(text, pos) end
  return nil, pos
end

function M.parse(text)
  if type(text) ~= "string" then return nil end
  local value, pos = parse_value(text, 1)
  if not value then return nil end
  pos = skip_whitespace(text, pos)
  if pos <= #text then return nil end
  return value
end

return M
