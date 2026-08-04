# Async Node Switch and Exit-IP Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prevent LuCI/uhttpd request timeouts from interrupting node-switch transactions, and keep the node page and exit-IP status synchronized until the background switch finishes.

**Architecture:** The authenticated LuCI switch action validates the requested node, checks the current runtime state, and starts `/usr/bin/xc switch <section>` in a detached child process. The action returns immediately with `switch_started`; the CLI/runtime remains the single owner of the transaction lock and writes its existing shared status file. Status JSON exposes operation and recovery state, while the node page polls status until the operation is idle and then applies the server-reported active node.

**Tech Stack:** Lua 5.1, LuCI controller/templates, nixio fork/exec, existing host Lua and Node.js tests, OpenWrt IPK packaging.

---

### Task 1: Lock down the asynchronous API contract with failing tests

**Files:**
- Modify: `tests/test_controller_actions.lua`
- Modify: `tests/test_task9_ui.js`

- [x] **Step 1: Add a controller regression test** asserting that a valid switch request calls the injected background launcher with `section`, returns `{ok=true, data.code="switch_started"}`, and does not call the synchronous runtime switch method. Add status assertions for `operation` and `recovery_required`.
- [x] **Step 2: Add a node-page regression test** asserting that `switch_started` causes GET status polling, keeps all switch buttons disabled while `operation="switch"`, and only renders `Switched`/the active row after a later `operation="idle"` status response.
- [x] **Step 3: Run the focused Lua and Node tests and record the expected failures because the new API/state behavior is absent.

### Task 2: Start switches in a detached device process

**Files:**
- Modify: `root/usr/lib/lua/xc/platform.lua`
- Modify: `luasrc/controller/xc.lua`
- Modify: `tests/test_platform_process.lua`
- Modify: `tests/test_controller_actions.lua`

- [x] **Step 1: Add the injected platform contract test for a validated detached launch:** fork, create a new session, redirect child output to `/dev/null`, exec the fixed `/usr/bin/xc switch <safe-section>`, and return immediately without waiting for the child.
- [x] **Step 2: Implement only the fixed-argv background launcher and expose it as `exec.start_switch`; reject invalid section IDs and fork/setsid/exec setup failures.
- [x] **Step 3: Update `action_switch` to validate state, reject a held/broken transaction with the existing stable error envelope, invoke `start_switch`, and return `switch_started` immediately.
- [x] **Step 4: Run focused tests and the full host suite.

### Task 3: Expose transaction state and poll it in the node page

**Files:**
- Modify: `luasrc/controller/xc.lua`
- Modify: `luasrc/view/xc/node_table.htm`
- Modify: `tests/test_task9_ui.js`
- Modify: `tests/test_cbi_static.lua`

- [x] **Step 1: Include `operation`, `recovery_required`, and the safe status error in the status response.
- [x] **Step 2: After `switch_started`, poll `/status` at a bounded interval; keep the page in `Switching…` while operation is active, show failure when recovery is required or a stable error is reported, and only mark the target current after idle status confirms it.
- [x] **Step 3: Ensure stale status responses cannot overwrite a newer switch and that the exit-IP display is refreshed only after the transaction is idle.
- [x] **Step 4: Run all UI/static tests and the full host suite.

### Task 4: Release, verify, push, and deploy r16

**Files:**
- Modify: `Makefile`
- Modify: `po/zh_Hans/xc.po`
- Modify: `po/templates/xc.pot`
- Modify: `README.md` or release status documentation only if the existing release workflow requires it

- [x] **Step 1: Bump `PKG_RELEASE` from 15 to 16 and regenerate/check translation metadata if source strings changed.
- [x] **Step 2: Run `PATH=/usr/bin:/bin:/usr/local/bin sh tests/run-host.sh`, `sh scripts/check-package.sh`, and the package build/check workflow available locally.
- [x] **Step 3: Commit the surgical change as `72553e4` and push the current `main` branch.
- [x] **Step 4: Back up the device state, install r16 on `192.168.6.1`, restart/reload LuCI as required, and verify switch completion, active node, exit IP, and no pending transaction.
