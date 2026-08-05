# Real connection parallel checks and switch timing design

## Goal

Reduce normal node-switch latency by running the SOCKS and HTTP real-connection checks concurrently, while preserving the existing requirement that both checks succeed before the active node is committed. Add bounded, secret-free phase timing fields to the completion log so device measurements identify the actual slow phase.

## Scope

- Add a platform adapter that executes the fixed-argv SOCKS and HTTP curl checks concurrently under one shared deadline.
- Keep the existing per-request result validation, bounded output, retry behavior, and rollback semantics.
- Use the parallel adapter for runtime readiness checks. A successful first pair completes immediately; if only one side fails, only that side uses the existing bounded retry path.
- Record `validate_ms`, `restart_ms`, `listener_ms`, `connection_ms`, `commit_ms`, and `total_ms` when available, plus a stable `failure_phase` for failures.
- Keep logs limited to numeric durations, stable result codes, operation names, and safe internal node IDs. Never log URLs, credentials, raw configuration, or curl output.
- Bump the package release from r18 to r19 after implementation.

## Non-goals

- Do not lower the configured real-connection timeout.
- Do not remove the SOCKS or HTTP validation requirement.
- Do not change the LuCI interaction model or introduce a second unsafe switch path.
- Do not replace Xray with Mihomo or redesign switching around a hot-reload API.

## Data flow

1. `Runtime:_switch_locked` starts a timing context before candidate validation.
2. Candidate Xray validation, prepared restart, listener readiness, parallel real-connection checks, active-node commit, and cleanup each close a timing phase.
3. `Runtime:_readiness` invokes the platform parallel check for both local listeners.
4. The platform starts two bounded curl children with fixed arguments and collects each bounded result before the shared deadline. It returns independent typed SOCKS/HTTP results.
5. Runtime accepts the candidate only when both typed results are successful. Any failure continues through the existing transaction recovery path.
6. `_record_completion` emits the timing fields through the existing secret-safe structured logger.

## Compatibility and failure handling

- Existing single-check behavior remains available for the retry of an individual failed side and for code paths that do not use the pair adapter.
- If the pair adapter cannot start, collect, parse, or safely terminate either child, that side is a failed check; the runtime must not commit the candidate.
- The shared deadline is authoritative. A child that outlives it is terminated and reaped using the existing bounded process rules.
- Timing values are non-negative integer milliseconds and are omitted when a phase did not start or did not complete.

## Verification

- Platform tests prove both child checks are launched before waiting, output is parsed independently, malformed output fails closed, and the shared deadline is honored.
- Runtime tests prove parallel readiness is required before commit, a single failed side retries without weakening the two-sided requirement, rollback state is preserved, and timing fields are recorded on success and failure.
- Run the full host suite and package checks.
- Build r19, verify package hashes, install it on `192.168.6.1`, and confirm service, listeners, real proxy requests, active-node switching, and timing logs.
