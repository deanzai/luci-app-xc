local t = require "testlib"
local logview = require "xc.logview"

local WALL_TIME = 1785326400
local UPTIME = 7200

local function adapter(values)
  return { parse = function(line)
    local value = values[line]
    if value == "throw" then error("malformed") end
    return value
  end }
end

local function collect(xc_lines, parsed, xray_lines, level)
  return logview.collect({
    xc = table.concat(xc_lines or {}, "\n"),
    xray = table.concat(xray_lines or {}, "\n"),
    level = level,
    json = adapter(parsed or {}),
    wall_time = WALL_TIME,
    uptime = UPTIME
  })
end

t.test("logview accepts only the fixed level allowlist and filters exact levels", function()
  local lines, parsed = {}, {}
  for index, level in ipairs({ "error", "warning", "info", "debug" }) do
    local line = "level-" .. level
    lines[index] = line
    parsed[line] = { time = 1785327900 + index, level = level, message = level .. " event" }
  end
  for _, level in ipairs({ "error", "warning", "info", "debug" }) do
    local entries = assert(collect(lines, parsed, nil, level))
    t.eq(#entries, 1)
    t.eq(entries[1].level, level)
  end
  t.eq(#assert(collect(lines, parsed, nil, "all")), 4)
  for _, invalid in ipairs({ "warn", "Warning", "", "all ", 1, false }) do
    local entries, err = collect(lines, parsed, nil, invalid)
    t.eq(entries, nil); t.eq(err, "invalid_level")
  end
end)

t.test("logview converts XC epoch and legacy uptime while preserving display semantics", function()
  local epoch, legacy = "epoch", "legacy"
  local entries = assert(collect({ epoch, legacy }, {
    [epoch] = { time = 1785327995, level = "warning", message = "epoch event" },
    [legacy] = { time = 1595, level = "info", message = "legacy event" }
  }, nil, "all"))
  t.eq(entries[1].time, WALL_TIME - UPTIME + 1595)
  t.eq(entries[1].display_time, "T+00:26:35")
  t.eq(entries[2].time, 1785327995)
  t.eq(entries[2].display_time, "2026-07-29 20:26:35")
end)

t.test("logview accepts only exact numeric Xray process tags and normalizes safe fallback text", function()
  local xray = {
    "Wed Jul 29 20:26:35 2026 daemon.warn xray[123]: warning safe message",
    "Wed Jul 29 20:26:36 2026 daemon.info xray-helper[123]: must be ignored",
    "Wed Jul 29 20:26:37 2026 daemon.info notxray[7]: must be ignored",
    "Wed Jul 29 20:26:38 2026 daemon.notice xray[9]: unstructured safe text"
  }
  local entries = assert(collect(nil, nil, xray, "all"))
  t.eq(#entries, 2)
  t.eq(entries[1].display_time, "2026-07-29 20:26:35")
  t.eq(entries[1].level, "warning")
  t.eq(entries[1].source, "xray")
  t.eq(entries[1].message, "warning safe message")
  t.eq(entries[2].level, "warning")
  t.eq(entries[2].message, "unstructured safe text")
end)

t.test("logview retains exact Xray tags when their timestamp is unparseable", function()
  local entries = assert(collect(nil, nil, {
    "timestamp-unavailable daemon.notice xray[44]: safe fallback message"
  }, "all"))
  t.eq(#entries, 1)
  t.eq(entries[1].source, "xray")
  t.eq(entries[1].level, "warning")
  t.eq(entries[1].message, "safe fallback message")
end)

t.test("logview stably merges by normalized time and isolates malformed lines", function()
  local entries = assert(collect({ "late", "bad", "same" }, {
    late = { time = 1785328000, level = "info", message = "late" },
    bad = "throw",
    same = { time = 1785327995, level = "info", message = "xc same" }
  }, {
    "Wed Jul 29 20:26:35 2026 daemon.info xray[12]: xray same"
  }, "all"))
  t.eq(#entries, 3)
  t.eq(entries[1].message, "xc same")
  t.eq(entries[2].message, "xray same")
  t.eq(entries[3].message, "late")
end)

t.test("logview strictly validates XC field types without poisoning neighboring entries", function()
  local entries = assert(collect({ "valid", "bad-time", "negative-time", "bad-level", "bad-message", "bad-fields" }, {
    valid = { time = 1, level = "debug", message = "safe", fields = { node = "alpha", attempts = 2 } },
    ["bad-time"] = { time = "1", level = "debug", message = "bad" },
    ["negative-time"] = { time = -1, level = "debug", message = "bad" },
    ["bad-level"] = { time = 2, level = {}, message = "bad" },
    ["bad-message"] = { time = 3, level = "debug", message = {} },
    ["bad-fields"] = { time = 4, level = "debug", message = "bad", fields = "bad" }
  }, nil, "all"))
  t.eq(#entries, 1)
  t.contains(entries[1].message, "safe")
  t.contains(entries[1].message, "node=alpha")
  t.contains(entries[1].message, "attempts=2")
end)

t.test("logview bounds inputs entries and UTF-8 messages", function()
  local lines, parsed = {}, {}
  for index = 1, 700 do
    local line = "bounded-" .. index
    lines[index] = line
    parsed[line] = { time = index, level = "info", message = "bounded message" }
  end
  local entries = assert(collect(lines, parsed, nil, "all"))
  t.eq(#entries, 512)
  local long_line = "long-message"
  entries = assert(collect({ long_line }, {
    [long_line] = { time = 1, level = "info", message = string.rep("x", 2000) .. "中" }
  }, nil, "all"))
  t.truthy(#entries[1].message <= 1024)
  t.eq(entries[1].message:find("[\128-\191]$"), nil)
  local oversized = assert(logview.collect({
    xc = string.rep("q", 400000), xray = string.rep("r", 400000), level = "all",
    json = adapter({}), wall_time = WALL_TIME, uptime = UPTIME
  }))
  t.truthy(#oversized <= 512)
end)

t.test("logview redacts representative secrets from messages and structured fields", function()
  local uuid = "123e4567-e89b-12d3-a456-426614174000"
  local uri = "vless://" .. uuid .. "@secret.invalid:443/path"
  local line = "secret-entry"
  local xray_secret = "Wed Jul 29 20:26:35 2026 daemon.err xray[123]: password=hunter2 token=tok-value " .. uri .. " {\"raw\":\"json-secret\"}"
  local entries = assert(collect({ line }, {
    [line] = {
      time = 1785327994, level = "error", message = "uuid " .. uuid .. " password=xc-pass " .. uri,
      fields = { token = "field-token", raw_content = "raw-secret", node = "safe-node" }
    }
  }, { xray_secret }, "all"))
  local output = ""
  for _, entry in ipairs(entries) do output = output .. entry.message end
  for _, secret in ipairs({ uuid, "hunter2", "tok-value", "xc-pass", "field-token", "raw-secret", "json-secret", "vless://", "secret.invalid" }) do
    t.eq(output:find(secret, 1, true), nil, "leaked " .. secret)
  end
  t.contains(output, "[redacted]")
  t.contains(output, "safe-node")
end)

t.test("logview fully redacts quoted credentials and Authorization Bearer tokens", function()
  local line = "quoted-secrets"
  local message = table.concat({
    "safe prefix",
    'password="hunter two"',
    "passwd='single UNIQUE_SECRET'",
    'ToKeN: "token with space"',
    "api_key=plain-secret",
    "Authorization: Bearer bearer-secret",
    "aUtHoRiZaTiOn: bEaReR mixed-bearer-secret",
    'PASSWORD = "mixed UNIQUE_CASE_VALUE"',
    "safe suffix"
  }, " ")
  local entries = assert(collect({ line }, {
    [line] = { time = 1785327995, level = "warning", message = message }
  }, nil, "all"))
  local output = entries[1].message
  for _, secret in ipairs({
    "hunter two", "two", "single UNIQUE_SECRET", "UNIQUE_SECRET",
    "token with space", "with space", "plain-secret", "bearer-secret",
    "mixed-bearer-secret", "mixed UNIQUE_CASE_VALUE", "UNIQUE_CASE_VALUE"
  }) do
    t.eq(output:find(secret, 1, true), nil, "quoted credential leaked " .. secret)
  end
  t.contains(output, "safe prefix")
  t.contains(output, "safe suffix")
  t.contains(output, "[redacted]")
  t.truthy(#output <= 1024)
end)

return true
