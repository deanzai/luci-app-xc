# Task 6 Quality Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close all Task 6 quality-review findings without touching a live router, preserving atomic UCI/runtime behavior across OpenWrt 21.02, fresh installs, upgrades, and offline-root packaging.

**Architecture:** Keep the platform adapter responsible for OpenWrt method compatibility, filesystem permissions, and bounded child processes. Give the runtime a narrow migration-exclusive capability that holds the existing runtime lock while CLI migration stages UCI, renders losslessly, validates Xray, commits, writes a durable source marker, and cleans its candidate. Keep package lifecycle scripts responsible for rooted backup/install permissions and failure-atomic service takeover.

**Tech Stack:** Lua 5.1, OpenWrt raw `uci` cursor/nixio/procd, POSIX shell, OpenWrt package Make definitions, repository Lua test harness.

---

### Task 1: Raw UCI compatibility, configuration modes, layout, and empty active state

**Files:**
- Modify: `tests/test_platform_uci.lua`
- Modify: `tests/test_platform_static.lua`
- Modify: `tests/test_runtime.lua`
- Modify: `root/usr/lib/lua/xc/platform.lua`
- Modify: `root/usr/bin/xc`
- Modify: `root/etc/config/xc`

- [ ] **Step 1: Write failing adapter tests**

Use a fake cursor with only OpenWrt 21.02 raw methods. Its overloaded `set(config, section, type)` creates a named section and `set(config, section, option, value)` writes an option; do not expose `section()`. Add a commit test that requires checked `chmod('/etc/config/xc', 0600)` immediately before and after `cursor:commit('xc')`. Add a clean-filesystem test requiring `ensure_layout()` to create and chmod `/etc/xc`, `/etc/xc/rollback`, and `/var/etc/xc` as `0700`.

- [ ] **Step 2: Write failing empty-active tests**

Require `get_global()` to normalize `active_node=''` to `nil`, require a sole enabled node to auto-select, and require the shipped UCI default not to contain `option active_node ''`.

- [ ] **Step 3: Run RED**

Run `./.tools/lua5.1 tests/run.lua`. Expected failures: staging calls missing `section()`, commit lacks mode checks, layout provisioning is absent, and empty active state is invalid.

- [ ] **Step 4: Implement minimal platform changes**

Create named sections with checked raw calls:

```lua
mutation(cursor.set, "xc", "global", "global")
mutation(cursor.set, "xc", normalized.id, "node")
```

Normalize an empty global active option to `nil`. Wrap `cursor:commit('xc')` with checked `nixio.fs.chmod('/etc/config/xc', 600)` calls. At every nixio boundary use permission digits (`600`/`700`), not Unix decimal bitmasks. Add `fs.ensure_layout()` using checked `mkdirr`, `stat`, and `chmod`; invoke it from `root/usr/bin/xc` before constructing the runtime. Remove the empty active option from `root/etc/config/xc`.

- [ ] **Step 5: Run GREEN**

Run the full Lua suite and require zero failures.

### Task 2: Deadline-aware child processes and IPv6 proxy arguments

**Files:**
- Create: `tests/test_platform_process.lua`
- Modify: `tests/test_platform_static.lua`
- Modify: `tests/test_runtime.lua`
- Modify: `root/usr/lib/lua/xc/platform.lua`
- Modify: `root/usr/lib/lua/xc/runtime.lua`

- [ ] **Step 1: Write failing process tests**

Drive `exec.run(argv, deadline)` with fake monotonic time and `waitpid(pid, 'nohang')`. Cover successful reap, nonzero exit, permanent wait error, timeout TERM, timeout KILL, and final blocking reap. Assert the child never remains unreaped. Capture curl argv and require IPv6 proxy hosts as `[fd00::1]:port` and `http://[fd00::1]:port`.

- [ ] **Step 2: Write failing runtime deadline tests**

Record the second argument passed to every Xray validation in switch, rollback/recovery, and `test_current`; require a finite deadline greater than current monotonic time.

- [ ] **Step 3: Run RED**

Run the full suite. Expected failures: blocking `waitpid`, no deadline propagation, no TERM/KILL cleanup, and unbracketed IPv6 proxy argv.

- [ ] **Step 4: Implement bounded spawning**

Poll with `waitpid(pid, 'nohang')` until a supplied deadline or a bounded default, treating OpenWrt 21.02's boolean `false` as the still-running result (and accepting numeric `0` for compatible test doubles). On timeout send TERM, poll through a short grace interval, send KILL if needed, and perform a final blocking reap. Treat invalid/permanent wait results as failure and clean up the child. Pass deadlines through all spawn users and from runtime Xray validation calls. Bracket IPv6 literals before composing curl proxy strings.

- [ ] **Step 5: Run GREEN**

Run the full suite and require zero failures.

### Task 3: Serialized, one-shot, bounded migration

**Files:**
- Modify: `tests/test_migration.lua`
- Modify: `tests/test_runtime.lua`
- Modify: `root/usr/lib/lua/xc/runtime.lua`
- Modify: `root/usr/lib/lua/xc/cli.lua`

- [ ] **Step 1: Write failing migration transaction tests**

Require one runtime lock around `stage_replace -> locked render -> Xray test -> UCI commit -> migration marker`. Require `/etc/xc/migration-complete` to contain a version, source snapshot identity, byte count, and checksum. Run a second migration with stale legacy input after customizing UCI and assert no `stage_replace` or commit occurs. Also assert an established XC node set without a marker is never replaced.

- [ ] **Step 2: Write failing cleanup matrix**

For success and failures at render, Xray, UCI commit, and marker write, assert `/var/etc/xc/migration-candidate.json` is removed before releasing the lock. Before commit failures must revert staged UCI; every candidate remains bounded by the runtime atomic writer.

- [ ] **Step 3: Run RED**

Run the full suite. Expected failures: recursive render lock, no durable marker, stale migration replacement, and leaked candidate paths.

- [ ] **Step 4: Add a narrow runtime exclusive capability**

Expose `Runtime:exclusive('migration', callback)` as an allowlisted wrapper over `_with_lock`. Pass the callback a capability table with only `render(section, path)` using the lock-held render primitive and `write(path, content)` using the bounded atomic writer. Do not expose lock handles or permit arbitrary operation names.

- [ ] **Step 5: Make CLI migration transactional**

Inside the exclusive callback, validate the backup, short-circuit a valid completed marker or an established XC node set, stage once, render the migration candidate without reacquiring the lock, call Xray with a finite deadline, commit UCI, write the source-bound marker, and remove the candidate on every terminal path. Revert only pre-commit staged failures and return secret-safe results.

- [ ] **Step 6: Run GREEN**

Run the full suite and require zero failures.

### Task 4: Installation, offline backup, and failure-atomic takeover

**Files:**
- Modify: `tests/test_migration.lua`
- Modify: `Makefile`
- Modify: `root/etc/init.d/xc`
- Modify: `root/etc/uci-defaults/luci-xc`

- [ ] **Step 1: Write failing expanded-script tests**

Extract Make `preinst` and `postinst`, replace Make `$$` escaping, and execute them against a temporary absolute `IPKG_INSTROOT`. Assert offline preinst copies only rooted legacy files, skips backup once the rooted migration marker exists, never invokes services, provisions rooted rollback `0700`, and leaves rooted config `0600` after postinst.

- [ ] **Step 2: Write failing lifecycle contracts**

Require live init startup to install `/etc/xc/rollback` as `0700` and chmod `/etc/config/xc` to `0600`. Require uci-default to exit successfully when the migration marker exists and to treat CLI migration as the single render/test/commit transaction.

- [ ] **Step 3: Write failing takeover state-machine tests**

Run uci-default with fake old/new init scripts for each disable/stop/enable/start failure. Assert every mutation result is checked; on failure the new service is disabled/stopped and the old service returns to its exact prior enabled/running state.

- [ ] **Step 4: Run RED**

Run the full suite. Expected failures: offline preinst exits before backup, no postinst permissions, no install-time rollback directory, marker is ignored, and service takeover is not failure-atomic.

- [ ] **Step 5: Implement rooted package scripts**

Validate `IPKG_INSTROOT` as empty or absolute, prefix every backup/install path, chmod an existing config before preinst backup, skip backups when the rooted migration marker exists, and add postinst that provisions `etc/xc/rollback` with `0700` and config with `0600` for both live and offline roots without service actions.

- [ ] **Step 6: Implement lifecycle safety**

Use checked `install -d -m 0700` and config chmod in init. In uci-default, use the completed marker to skip only migration so a failed or interrupted service takeover remains retryable; migrate candidates through the serialized CLI command, capture old enabled/running states without treating unsupported rc.common help as a successful `running` probe, and use a checked restoration function for every takeover failure. After starting the new procd service, require bounded consecutive `running` checks so rc.common cannot hide a failed `start_service()`.

- [ ] **Step 7: Run GREEN**

Run the full suite and require zero failures.

### Task 5: Verification and focused commit

**Files:**
- Verify all modified production and test files.

- [ ] **Step 1: Run final verification**

Run the full Lua suite, Lua `loadfile()` checks, `sh -n` for init/hotplug/uci-default, expanded Make preinst/postinst syntax checks, `git diff --check`, and executable-mode checks.

- [ ] **Step 2: Review requirement coverage**

Check all ten review findings plus IPv6 curl brackets against tests and the cached diff. Confirm no live-router command ran and record target-only OpenWrt integration risks.

- [ ] **Step 3: Commit**

Stage only scoped files and create one focused Task 6 quality-hardening commit. Report RED/GREEN evidence, changed files, SHA, and residual target-only risks.

### Task 6: Formal re-review follow-up

**Files:**
- Modify: `Makefile`
- Modify: `root/etc/uci-defaults/luci-xc`
- Modify: `root/usr/lib/lua/xc/cli.lua`
- Modify: `root/usr/lib/lua/xc/platform.lua`
- Modify: `tests/test_migration.lua`
- Modify: `tests/test_platform_process.lua`
- Modify: `tests/test_platform_static.lua`

- [x] **Step 1: Verify upstream LuCI postinst behavior**

Compare `luci.mk` on OpenWrt 21.02, 22.03, 23.05, and 24.10. Preserve live-root defaults execution/removal, LuCI cache invalidation, and rpcd refresh semantics while keeping offline-root postinst limited to rooted permission provisioning.

- [x] **Step 2: Separate migration and takeover completion**

Keep `migration-complete` source-bound to the migrated or adopted snapshot. Write an independent private `takeover-complete` marker only after bounded new-service running checks; future upgrades must skip takeover and preserve a user's later enabled/running choices.

- [x] **Step 3: Treat service state as authoritative**

Do not trust procd start request return codes as final state. Check new and restored services with bounded running probes, including the case where a start request returns nonzero after the service became running.

- [x] **Step 4: Bound final child reaping and close inherited descriptors**

After SIGKILL use only bounded `waitpid(..., 'nohang')` polling and return if the child cannot yet be reaped. Close the original `/dev/null` descriptor after duplicating it to stdout and stderr.

- [x] **Step 5: Tighten legacy process fallback**

Require both an exact `/usr/bin/xray` argv zero and an exact `/etc/xc/config.json` argument while scanning a bounded number of `/proc` command lines.

- [x] **Step 6: Run RED then GREEN**

The seven new behavioral tests and strengthened contracts produced 13 expected failures on `d341a6d`; the minimal implementation passes the full 154-test suite.
