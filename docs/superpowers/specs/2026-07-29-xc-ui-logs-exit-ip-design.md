# XC UI, Logging, and Exit IP Design

**Date:** 2026-07-29

## Goal

Complete the Simplified Chinese interface, name node latency testing accurately, restore and extend the log page, integrate privacy-safe Xray runtime logs, and make the active node's public exit IP reliable on OpenWrt/ImmortalWrt 21.02 through 24.10.

Deployment to the authorized router at `192.168.6.1` and device acceptance must succeed before implementation commits are pushed to GitHub.

## User-visible terminology and translations

The node action currently labelled `Probe` is a connectivity and latency test. It is not a bandwidth test. The Chinese interface uses:

- `测速` for one node;
- `全部测速` for the batch action;
- `停止测速` for stopping queued work;
- `延迟` for the measured latency column.

English source strings remain meaningful fallbacks. The POT and Simplified Chinese PO catalogs contain one canonical entry per message, cover every visible LuCI string, and are rebuilt into the device translation format. No duplicate `msgid` entries remain.

## Unified log page

XC keeps one Log tab. It displays two privacy-bounded sources in one chronological view:

1. XC operational JSON records from `/var/log/xc.log`;
2. Xray runtime records captured by the existing procd stdout/stderr integration and OpenWrt `logd` ring buffer.

Xray access logging remains disabled. Only Xray runtime messages are included. Each rendered row identifies its source as `[XC]` or `[Xray]`; there is no source selector.

### Levels and controls

The level selector contains:

`All | Error | Warning | Info | Debug`

Refresh reloads both bounded sources. Clear truncates only the XC log under the existing XC log lock. It must not attempt to erase the shared OpenWrt system ring buffer, and the page explains this limitation. The page performs no automatic refresh in this iteration.

The Settings page adds an Xray runtime log-level option:

`Error | Warning | Info | Debug`

The default is `Warning`. Changing it follows the existing UCI save/apply and Xray configuration reload path. The generated Xray configuration explicitly disables access logging and emits runtime messages at the selected level.

### Normalization and display

The authenticated log endpoint reads bounded tails only. It validates the requested level against the fixed allowlist, normalizes both sources into entries containing `time`, `level`, `source`, and `message`, and never returns arbitrary command output or credentials.

The browser renders entries with DOM `textContent`, not log-derived HTML. Error, warning, info, and debug receive distinct CSS classes. New XC records use router wall-clock epoch time. Legacy XC records whose `time` value is monotonic uptime are displayed as `T+HH:MM:SS`. Xray log timestamps are parsed from the bounded `logread` output when valid; unparseable lines remain safe plain text.

XC records sanitized operational events for service start/stop, configuration rendering, node switching, single/batch testing outcomes, imports, rollback, and failures. Event fields remain bounded and pass through the existing credential/link/raw-content redaction policy.

## Log page failure correction

The log page uses a `SimpleForm` so it does not require UCI read permission merely to display runtime logs. A `SimpleSection` explicitly attaches the `xc/log` template. This corrects both prior failure modes:

- `Map("xc")` could fail with an insufficient-UCI-permission message;
- the incomplete `SimpleForm` conversion rendered only the title because no section referenced the template.

Malformed endpoint responses display a translated load failure. Invalid individual log lines cannot abort rendering of the remaining valid entries.

## Exit IP

Exit IP means the public IP observed through the selected node via XC's local SOCKS listener and the configured health-check URL. It is not the router WAN address.

Listener readiness keeps its existing short deadline. Exit-IP observation receives a separate maximum five-second deadline; it does not reuse the already-consumed two-second listener deadline. A validated observation is cached in a private runtime file for 60 seconds. Status polls return the fresh cached IP without another public request. Cache content is accepted only when its timestamp and strict IPv4/IPv6 value validate.

If service or SOCKS listener health fails, no observation is attempted. If a refresh fails and no fresh valid cache exists, the UI displays the translated `Unavailable` state. The endpoint never exposes curl stderr or arbitrary response bodies.

## Compatibility and security

- Lua remains compatible with Lua 5.1 and LuCI CBI on 21.02 through 24.10.
- Browser JavaScript stays ES5-compatible with the existing templates.
- Xray access logs are never enabled.
- Xray system-log reads use fixed argv and bounded output; no shell interpolation is introduced.
- Log messages, fields, and endpoint payloads remain size-bounded and secret-safe.
- Translation generation must not include device configuration or live log content.

## Verification

Automated tests must verify:

- every visible source string has exactly one POT entry and one non-empty Simplified Chinese translation;
- the single and batch controls use the approved latency-test terminology;
- `SimpleForm` attaches one `SimpleSection` with `xc/log` and does not instantiate `Map("xc")`;
- level validation covers all/error/warning/info/debug and rejects arbitrary values;
- XC and Xray records normalize, merge, filter, escape, and remain bounded;
- clear affects only the XC log while holding the XC log lock;
- Xray access logging is disabled and runtime log level defaults to warning;
- XC operational events are emitted at the appropriate level without leaking representative secrets;
- exit-IP observation uses a distinct bounded deadline, validates addresses, caches for 60 seconds, and fails closed;
- existing node queue, switching, import, rollback, status, packaging, and Lua syntax tests remain green.

Device acceptance must verify before any push:

- Settings, Nodes, Runtime Status, and Log render completely in Simplified Chinese;
- one-node and batch buttons read `测速`, `全部测速`, and `停止测速` and retain their tested behavior;
- the Log tab displays XC and Xray runtime entries, source tags, readable times, colors, and every level filter;
- Clear removes XC entries but accurately explains that Xray/system entries remain;
- Exit IP displays the real proxy egress IP on the current device instead of `Unavailable` under normal network conditions;
- no browser console error, LuCI exception, secret exposure, or Argon layout regression is present.

Only after these checks pass are implementation commits pushed to `https://github.com/deanzai/luci-app-xc.git`.
