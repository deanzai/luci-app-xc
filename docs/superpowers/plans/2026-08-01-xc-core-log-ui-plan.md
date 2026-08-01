# XC Core and Log UI Refinement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans (or subagent-driven-development) to implement this plan task-by-task.

**Goal:** Remove duplicated core-page log text, align current-core values into a status-style two-column table, and display safe node names in the log UI without changing persisted log records.

**Architecture:** The core page will omit the outer SimpleForm title/description and keep its existing functional sections. The current-core markup will use the same LuCI table/tr/td pattern as the runtime status page while retaining all existing element IDs and JavaScript. Log records will continue storing section IDs; `action_get_log()` will build a best-effort UCI ID-to-name map and pass it to `logview.collect()`, where only the exact `node` field is mapped, sanitized, and safely falls back to the ID.

**Tech Stack:** Lua 5.1, LuCI CBI/HTML templates, Node DOM harness, existing Lua testlib, gettext catalogs.

---

### Task 1: Add failing core-page regression tests

**Files:**
- Modify: `tests/test_core_ui.js`
- Modify: `luasrc/model/cbi/xc/core.lua` (after tests fail)
- Modify: `luasrc/view/xc/core.htm` (after tests fail)

- [x] Add static assertions that the core model no longer contains the duplicate runtime-log description and that the current-core section uses `.table`, `.tr`, and `.td left` rather than `dl.cbi-value-list`.
- [x] Run `node tests/test_core_ui.js` and confirm the new assertions fail against the current implementation.
- [x] Change the model to `SimpleForm("xc_core")` and replace only the current-core `dl/dt/dd` wrapper with five status-style table rows, preserving all existing element IDs.
- [x] Run `node tests/test_core_ui.js` and confirm the dynamic status, XSS, version list, and action tests pass.

### Task 2: Add failing log node-name mapping tests

**Files:**
- Modify: `tests/test_logview.lua`
- Modify: `tests/test_controller_actions.lua`
- Modify: `root/usr/lib/lua/xc/logview.lua` (after tests fail)
- Modify: `luasrc/controller/xc.lua` (after tests fail)

- [x] Add `logview.collect()` cases proving `node_names.safe_node = "Main Node"` renders `node=Main Node`, unknown IDs remain unchanged, and names containing URL/token-like text are redacted without exposing the original ID when a safe name exists.
- [x] Add an `action_get_log()` case with an injected UCI node name and assert the response message uses that name while the mapping is read only at request time.
- [x] Run the focused Lua tests and confirm the new mapping assertions fail before production changes.
- [x] Extend `fields_message()` with an optional `node_names` map used only for `key == "node"`; apply existing sanitization and bounded output, and fall back to the original ID for missing/invalid mappings.
- [x] In `action_get_log()`, best-effort call `adapters.uci.list_nodes()` under `pcall`, build a map from safe section IDs to safe names, and pass it to `logview.collect()` without changing the log file or failing log reads when mapping is unavailable.
- [x] Re-run the focused Lua tests and confirm all mapping, fallback, redaction, and existing secret-safety assertions pass.

### Task 3: Full verification and device deployment

**Files:**
- Modify: `README.md` only if the UI behavior description needs a direct update.
- Modify: `po/templates/xc.pot` and `po/zh_Hans/xc.po` only if the implementation introduces new visible strings.

- [x] Run `bash tests/run-host.sh`; require 352+ Lua tests, all Node UI tests, package checks, translation/LMO checks, and both SDK matrix checks to pass.
- [x] Run `git diff --check` and inspect the complete diff for secret leakage and unintended changes.
- [x] Build/deploy the updated IPK to `192.168.13.1`, backing up `/etc/config/xc` first; do not replace `/usr/bin/xray` or the managed 26.6.27 core.
- [x] Verify the core page has no duplicate log introduction, current-core values render left/right, and the log page displays a node name with ID fallback for an unknown node.
- [ ] Verify XC service, 7890/10809 listeners, active node, and recent switch logs remain healthy.

### Task 4: Review and commit

- [x] Request independent code review for core-page layout, log mapping boundaries, compatibility, and privacy behavior.
- [x] Fix any Critical/Important findings and rerun the affected tests.
- [ ] Commit the verified changes with a focused message; do not push until explicitly requested.
