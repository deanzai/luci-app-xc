# XC Node Table Layout Design

**Date:** 2026-07-29

## Goal

Correct the malformed node-table rendering while keeping compatibility with legacy LuCI CBI on OpenWrt/ImmortalWrt 21.02 through 24.10.

The final table order is:

`Active | Enabled | Name | Protocol | Server | Port | Latency | Actions`

Each Actions cell contains, in this order:

`Probe | Edit | Delete`

The batch `Test all` and `Stop probing` controls remain below the table.

## Root Cause

`cbi/tblsection.htm` renders every option with `cbi/cell_valueheader` and `cbi/cell_valuefooter`. Custom option templates must include `cbi/valueheader` and `cbi/valuefooter` so their output becomes a valid table cell.

The current `ping_latency.htm` and `ping.htm` templates emit a bare `<span>` and `<div>`. These become invalid direct children of `<tr>`, so the browser moves all latency and probe controls before the table. The table still creates Latency and Probe headers, leaving the associated row cells absent.

## Design

### Latency cell

Keep `_latency` as the only custom node-table option after Port. Its template includes the standard CBI value header and footer, producing one valid `<td>` per node.

The latency element exposes the cached socket result through a bounded `data-xc-socket` value (`ok`, `fail`, or empty). It continues to show the cached latency with the existing color thresholds.

### Actions cell

Remove the `_probe` DummyValue from `nodes.lua`, which removes the standalone Probe column.

Retain the stock `cbi/tblsection` template so native edit, delete, add, submit names, and section handling remain unchanged. During page initialization, `node_table.htm` locates each real node row and its native `td.cbi-section-actions > div`, derives the safe section ID from the row ID, and inserts exactly one socket indicator plus one Probe button before the native Edit and Delete buttons.

The probe queue operates on table rows marked with `data-xc-section`. A successful response updates the row's Latency cell and socket indicator. Batch and single-node testing share the existing bounded-concurrency queue.

### Compatibility

The implementation relies only on the stable legacy CBI contracts used across supported releases:

- `cbi/tblsection` row IDs and `cbi-section-table-row` class;
- `cbi-section-actions` action cell;
- `cbi/valueheader` and `cbi/valuefooter` option wrappers.

It does not fork the complete upstream `tblsection` template and does not change UCI persistence or controller response contracts.

## Failure Handling

- Initialization skips placeholder rows and rows without a valid section ID or action cell.
- Duplicate initialization must not create duplicate Probe controls.
- Failed or malformed probe responses show the translated failure state and red latency text.
- Stopping a batch invalidates the run ID so completed stale requests cannot update the active queue.

## Verification

Automated checks must verify:

- the latency template includes both CBI cell wrappers;
- `nodes.lua` no longer registers `_probe`;
- every fixture row receives exactly one Probe button;
- Probe, Edit, and Delete share the same Actions cell in that order;
- the request payload contains the correct section ID;
- no `.xc-probe-row` is a direct child of `.cbi-section`;
- existing queue concurrency, stop, and result-rendering behavior remains covered.

Router acceptance must verify, using the installed Argon theme:

- no latency or Probe controls appear above the table;
- Port is immediately followed by Latency;
- the Actions cell shows Probe, Edit, and Delete on one line at desktop width;
- all 11 node rows render and single/batch probing updates the correct row;
- the page remains usable at a narrower viewport.
