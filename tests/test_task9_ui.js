"use strict";

const assert = require("assert");
const fs = require("fs");
const vm = require("vm");

function script(path) {
  return fs.readFileSync(path, "utf8").match(/<script[^>]*>([\s\S]*?)<\/script>/)[1]
    .replace(/<%=dispatcher\.build_url\("admin", "services", "xc", "([^"]+)"\)%>/g, "/xc/$1")
    .replace(/<%=token%>/g, "csrf-token")
    .replace(/<%=probe_concurrency%>/g, "TEST_CONCURRENCY")
    .replace(/<%=util\.serialize_json\(self\.active_section or ""\)%>/g, JSON.stringify("node_0"))
    .replace(/<%=util\.serialize_json\(translate\("([^"]+)"\)\)%>/g, (_, text) => JSON.stringify(text));
}

const nodeTableSource = fs.readFileSync("luasrc/view/xc/node_table.htm", "utf8");
assert.ok(nodeTableSource.includes('translate("Test")'), "single-node button uses Test");
assert.ok(nodeTableSource.includes('value="<%:Test all%>"'), "batch button keeps Test all");
assert.ok(nodeTableSource.includes('value="<%:Stop testing%>"'), "stop button uses Stop testing");
assert.ok(nodeTableSource.includes('id="xc-node-controls"'), "node controls share one toolbar");
assert.ok(nodeTableSource.includes('dispatcher.build_url("admin", "services", "xc", "switch")'), "row switch uses authenticated controller endpoint");
assert.ok(nodeTableSource.includes('translate("Switch")'), "inactive node action uses Switch");
assert.ok(nodeTableSource.includes('translate("Current")'), "active node action uses Current");
assert.ok(nodeTableSource.includes("switch_started"), "row switch handles asynchronous completion");
assert.ok(nodeTableSource.includes("operation"), "row switch follows shared operation state");
assert.strictEqual(nodeTableSource.includes("location.reload"), false, "switch does not reload the page");

function xhrHarness() {
  const requests = [];
  function XHR() { this.headers = {}; this.readyState = 0; requests.push(this); }
  XHR.prototype.open = function(method, url) { this.method = method; this.url = url; };
  XHR.prototype.setRequestHeader = function(name, value) { this.headers[name] = value; };
  XHR.prototype.send = function(body) { this.body = body; };
  XHR.prototype.respond = function(value, status) {
    this.status = status || 200; this.responseText = JSON.stringify(value); this.readyState = 4;
    if (this.onreadystatechange) this.onreadystatechange();
  };
  XHR.prototype.respondRaw = function(value, status) {
    this.status = status || 200; this.responseText = value; this.readyState = 4;
    if (this.onreadystatechange) this.onreadystatechange();
  };
  XHR.prototype.fail = function() { if (this.onerror) this.onerror(); };
  XHR.prototype.expire = function() { if (this.ontimeout) this.ontimeout(); };
  return { XHR, requests };
}

function nodeHarness(concurrency, layout, rowCount, initiallyHidden) {
  layout = layout || "div"; rowCount = rowCount === undefined ? 6 : rowCount;
  const xhr = xhrHarness();
  const timers = [];
  function hasClass(node, name) { return (" " + node.className + " ").indexOf(" " + name + " ") >= 0; }
  function descendants(node) {
    return node.children.reduce((all, child) => all.concat(child, descendants(child)), []);
  }
  function matches(node, selector) {
    if (selector === '.cbi-section-table-row[id^="cbi-xc-"]')
      return hasClass(node, "cbi-section-table-row") && /^cbi-xc-/.test(node.id);
    if (selector === 'input.cbi-button-add') return node.tagName === "INPUT" && hasClass(node, "cbi-button-add");
    if (selector[0] === ".") return hasClass(node, selector.slice(1));
    if (selector === "td.cbi-section-actions") return node.tagName === "TD" && hasClass(node, "cbi-section-actions");
    if (selector === "div") return node.tagName === "DIV";
    if (selector === 'tr.cbi-section-table-row[id^="cbi-xc-"]')
      return node.tagName === "TR" && hasClass(node, "cbi-section-table-row") && /^cbi-xc-/.test(node.id);
    return false;
  }
  function element(tag) {
    const node = { tagName: (tag || "div").toUpperCase(), id: "", textContent: "", value: "", disabled: false,
      style: {}, className: "", onclick: null, parentNode: null, children: [], attributes: {},
      classList: {
        add(name) { if (!hasClass(node, name)) node.className += (node.className ? " " : "") + name; },
        remove(name) { node.className = node.className.split(/\s+/).filter(value => value && value !== name).join(" "); }
      },
      appendChild(child) { child.parentNode = this; this.children.push(child); return child; },
      removeChild(child) { const at = this.children.indexOf(child); if (at >= 0) this.children.splice(at, 1);
        child.parentNode = null; return child; },
      insertBefore(child, before) { child.parentNode = this; const at = this.children.indexOf(before);
        this.children.splice(at < 0 ? this.children.length : at, 0, child); return child; },
      setAttribute(name, value) { this.attributes[name] = String(value); if (name === "id") this.id = String(value); },
      getAttribute(name) { if (name === "id") return this.id || null; return this.attributes[name] === undefined ? null : this.attributes[name]; },
      querySelectorAll(selector) {
        if (selector === ".cbi-section-actions > div") return descendants(this).filter(candidate =>
          candidate.tagName === "DIV" && candidate.parentNode && hasClass(candidate.parentNode, "cbi-section-actions"));
        if (selector === "td.cbi-section-actions > div") return descendants(this).filter(candidate =>
          candidate.tagName === "DIV" && candidate.parentNode && matches(candidate.parentNode, "td.cbi-section-actions"));
        return descendants(this).filter(candidate => matches(candidate, selector));
      },
      querySelector(selector) { return this.querySelectorAll(selector)[0] || null; }
    };
    return node;
  }
  const controls = { "xc-node-controls": element("div"), "xc-probe-all": element("input"),
    "xc-probe-stop": element("input"), "xc-probe-state": element("span"), "xc-switch-state": element("span") };
  controls["xc-node-controls"].appendChild(controls["xc-probe-all"]);
  controls["xc-node-controls"].appendChild(controls["xc-probe-stop"]);
  controls["xc-node-controls"].appendChild(controls["xc-probe-state"]);
  controls["xc-node-controls"].appendChild(controls["xc-switch-state"]);
  const sectionRoot = element("div"); sectionRoot.className = "cbi-section";
  const nativeCreate = sectionRoot.appendChild(element("div")); nativeCreate.className = "cbi-section-create";
  const nativeAdd = nativeCreate.appendChild(element("input")); nativeAdd.className = "cbi-button cbi-button-add"; nativeAdd.value = "Add";
  const table = sectionRoot.appendChild(element(layout === "native" ? "table" : "div")); table.className = "table";
  const rowContainer = layout === "native" ? table.appendChild(element("tbody")) : table;
  const rows = Array.from({ length: rowCount }, (_, index) => {
    const row = element(layout === "native" ? "tr" : "div"); row.id = "cbi-xc-node_" + index; row.className = "tr cbi-section-table-row";
    const latencyCell = row.appendChild(element(layout === "native" ? "td" : "div")); latencyCell.className = "td";
    const latency = latencyCell.appendChild(element("span")); latency.className = "xc-latency";
    latency.setAttribute("data-xc-socket", index === 0 ? "ok" : index === 1 ? "fail" : "");
    const actions = row.appendChild(element(layout === "native" ? "td" : "div")); actions.className = "td cbi-section-actions";
    const actionBox = actions.appendChild(element("div"));
    if (index === 0) {
      const existingProbe = actionBox.appendChild(element("input"));
      existingProbe.className = "cbi-button cbi-button-action xc-probe-one"; existingProbe.value = "Test";
    } else if (index === 1) {
      const existingSocket = actionBox.appendChild(element("span"));
      existingSocket.className = "xc-socket"; existingSocket.textContent = "✗";
    }
    const edit = actionBox.appendChild(element("input")); edit.className = "cbi-button cbi-button-edit"; edit.value = "Edit";
    if (index === 2) {
      for (let duplicate = 0; duplicate < 2; duplicate++) {
        const socket = actionBox.appendChild(element("span")); socket.className = "xc-socket";
        const probe = actionBox.appendChild(element("input")); probe.className = "xc-probe-one"; probe.value = "Test";
      }
    }
    const remove = actionBox.appendChild(element("input")); remove.className = "cbi-button cbi-button-remove"; remove.value = "Delete";
    rowContainer.appendChild(row);
    return row;
  });
  function skippedRow(id, withActions) {
    const row = element(layout === "native" ? "tr" : "div");
    row.id = id; row.className = "tr cbi-section-table-row";
    if (withActions) {
      const actions = row.appendChild(element(layout === "native" ? "td" : "div"));
      actions.className = "td cbi-section-actions";
      const actionBox = actions.appendChild(element("div"));
      const edit = actionBox.appendChild(element("input")); edit.value = "Edit";
      const remove = actionBox.appendChild(element("input")); remove.value = "Delete";
    }
    rowContainer.appendChild(row); return row;
  }
  const skippedRows = [
    skippedRow("", true),
    skippedRow("cbi-xc-bad-id", true),
    skippedRow("cbi-xc-missing_actions", false)
  ];
  Object.keys(controls).forEach(id => { controls[id].id = id; });
  const roots = [sectionRoot, controls["xc-node-controls"]];
  const listeners = {};
  const document = {
    hidden: !!initiallyHidden,
    getElementById: id => controls[id],
    createElement: element,
    querySelectorAll: selector => roots.reduce((all, root) => all.concat(matches(root, selector) ? [root] : [], root.querySelectorAll(selector)), []),
    addEventListener: (name, fn) => { listeners[name] = fn; }
  };
  const window = {
    setTimeout: (callback, delay) => { const timer = { callback, delay, cleared: false }; timers.push(timer); return timer; },
    clearTimeout: timer => { if (timer) timer.cleared = true; }
  };
  vm.runInNewContext(script("luasrc/view/xc/node_table.htm").replace("TEST_CONCURRENCY", String(concurrency)),
    { window, document, XMLHttpRequest: xhr.XHR, JSON, Number, Math, String, encodeURIComponent });
  listeners.DOMContentLoaded();
  listeners.DOMContentLoaded();
  rows.forEach((row, index) => {
    const actionBox = row.querySelector(".cbi-section-actions > div");
    const probes = actionBox.querySelectorAll(".xc-probe-one");
    const switches = actionBox.querySelectorAll(".xc-switch-one");
    const sockets = actionBox.querySelectorAll(".xc-socket");
    assert.strictEqual(probes.length, 1, "row initialization is idempotent");
    assert.strictEqual(switches.length, 1, "row has exactly one switch button");
    assert.strictEqual(sockets.length, 1, "partial initialization restores exactly one socket");
    assert.strictEqual(row.getAttribute("data-xc-section"), "node_" + index);
    assert.deepStrictEqual(actionBox.children.map(child => child.className.indexOf("xc-socket") >= 0 ? "Socket" :
      child.className.indexOf("xc-probe-one") >= 0 ? "Probe" :
      child.className.indexOf("xc-switch-one") >= 0 ? "Switch" : child.value), ["Socket", "Probe", "Switch", "Edit", "Delete"]);
    row.section = "node_" + index; row.latency = row.querySelector(".xc-latency");
    row.socket = row.querySelector(".xc-socket"); row.button = probes[0]; row.switchButton = switches[0];
    assert.strictEqual(row.button.value, "Test", "single-node button label");
    assert.strictEqual(row.switchButton.value, index === 0 ? "Current" : "Switch");
    assert.strictEqual(row.switchButton.disabled, index === 0);
    assert.strictEqual(hasClass(row, "xc-node-active"), index === 0, "only the active row is highlighted");
  });
  assert.strictEqual(document.querySelectorAll(".xc-probe-row").filter(row => row.parentNode === sectionRoot).length, 0,
    "probe rows are never direct children of cbi-section");
  if (rows.length >= 3) {
    assert.strictEqual(rows[0].socket.textContent, "✓");
    assert.strictEqual(rows[1].socket.textContent, "✗");
    assert.strictEqual(rows[2].socket.textContent, "");
  }
  skippedRows.forEach(row => {
    assert.strictEqual(row.querySelectorAll(".xc-probe-one").length, 0, "skipped row gets no Test button");
    assert.strictEqual(row.getAttribute("data-xc-section"), null, "skipped row is not initialized");
  });
  assert.strictEqual(nativeAdd.parentNode, controls["xc-node-controls"], "native Add button moves into the shared toolbar");
  assert.strictEqual(controls["xc-node-controls"].children[0], nativeAdd, "Add is the first toolbar action");
  return { window, document, controls, rows, skippedRows, requests: xhr.requests, nativeAdd, hasClass, timers };
}

nodeHarness(3, "native");

{
  const h = nodeHarness(3, "div", 0);
  h.controls["xc-probe-all"].onclick();
  assert.strictEqual(h.requests.length, 0);
  assert.strictEqual(h.controls["xc-probe-all"].disabled, false, "empty probe run stays idle");
  assert.strictEqual(h.controls["xc-probe-state"].textContent, "");
}

for (const [configured, expected] of [[1, 1], [3, 3], [5, 5], [0, 1], [9, 5], ["bad", 3]]) {
  const h = nodeHarness(configured);
  h.controls["xc-probe-all"].onclick();
  assert.strictEqual(h.requests.length, expected, "concurrency " + configured);
}

{
  const h = nodeHarness(1);
  h.rows[2].button.onclick();
  assert.strictEqual(h.requests.length, 1);
  assert.strictEqual(JSON.parse(h.requests[0].body).section, "node_2", "single row uses shared queue payload");
  h.requests[0].respond({ ok: true, data: { socket: "ok", ping: 99, time: 99, outcome: "tcp" } });
  assert.strictEqual(h.rows[2].latency.textContent, "99 ms");
  assert.strictEqual(h.rows[2].latency.style.color, "green");
  assert.strictEqual(h.rows[2].socket.textContent, "✓");
}

{
  const h = nodeHarness(1);
  h.rows[0].button.onclick();
  h.requests[0].respond({ ok: true, data: { socket: "ok", ping: 0, time: 0, outcome: "tcp" } });
  assert.strictEqual(h.rows[0].latency.textContent, "<1 ms", "successful loopback probes are not errors");
  assert.strictEqual(h.rows[0].latency.style.color, "green");
  assert.strictEqual(h.rows[0].socket.textContent, "✓");
}

{
  const h = nodeHarness(3);
  h.rows[1].switchButton.onclick();
  assert.strictEqual(h.requests.length, 1);
  assert.strictEqual(h.requests[0].method, "POST");
  assert.ok(h.requests[0].url.indexOf("/xc/switch?token=csrf-token") >= 0);
  assert.strictEqual(JSON.parse(h.requests[0].body).section, "node_1");
  assert.strictEqual(h.rows[1].switchButton.value, "Switching…");
  h.rows.forEach(row => assert.strictEqual(row.switchButton.disabled, true, "all switch buttons lock during a switch"));
  h.requests[0].respond({ ok: true, data: { code: "switched", node: "node_1" } });
  assert.strictEqual(h.controls["xc-switch-state"].textContent, "Switched");
  assert.strictEqual(h.hasClass(h.rows[0], "xc-node-active"), false);
  assert.strictEqual(h.hasClass(h.rows[1], "xc-node-active"), true);
  assert.strictEqual(h.rows[0].switchButton.value, "Switch");
  assert.strictEqual(h.rows[0].switchButton.disabled, false);
  assert.strictEqual(h.rows[1].switchButton.value, "Current");
  assert.strictEqual(h.rows[1].switchButton.disabled, true);
}

{
  const h = nodeHarness(3);
  h.rows[1].switchButton.onclick();
  h.requests[0].respond({ ok: true, data: { code: "switch_started", node: "node_1" } });
  assert.strictEqual(h.controls["xc-switch-state"].textContent, "Switching…",
    "an accepted background switch remains pending");
  assert.strictEqual(h.rows[1].switchButton.value, "Switching…");
  h.rows.forEach(row => assert.strictEqual(row.switchButton.disabled, true,
    "all switch buttons stay disabled while operation is active"));
  h.timers[h.timers.length - 1].callback();
  assert.strictEqual(h.requests.length, 2);
  h.requests[1].respond({ ok: true, data: { operation: "switch", recovery_required: false,
    active_section: "node_0" } });
  assert.strictEqual(h.controls["xc-switch-state"].textContent, "Switching…");
  h.timers[h.timers.length - 1].callback();
  assert.strictEqual(h.requests.length, 3);
  h.requests[2].respond({ ok: true, data: { operation: "idle", recovery_required: false,
    active_section: "node_1" } });
  assert.strictEqual(h.controls["xc-switch-state"].textContent, "Switched");
  assert.strictEqual(h.hasClass(h.rows[1], "xc-node-active"), true);
  assert.strictEqual(h.rows[1].switchButton.value, "Current");
}

{
  const h = nodeHarness(3, "div", 3, true);
  h.rows[1].switchButton.onclick();
  h.requests[0].respond({ ok: true, data: { code: "switch_started", node: "node_1" } });
  assert.ok(h.timers.some(timer => !timer.cleared),
    "a background switch keeps polling while the page is hidden");
  h.timers[h.timers.length - 1].callback();
  assert.strictEqual(h.requests.length, 2);
  h.requests[1].respond({ ok: true, data: { operation: "idle", recovery_required: false,
    active_section: "node_1" } });
  assert.strictEqual(h.controls["xc-switch-state"].textContent, "Switched");
  assert.strictEqual(h.rows[1].switchButton.value, "Current");
}

{
  const h = nodeHarness(3);
  h.rows[1].switchButton.onclick();
  h.requests[0].respond({ ok: true, data: { code: "switched", node: "node_1" } });
  assert.strictEqual(h.requests.length, 2, "successful switch refreshes active state from the server");
  assert.strictEqual(h.requests[1].method, "GET");
  assert.ok(h.requests[1].url.indexOf("/xc/status") >= 0);
  h.requests[1].respond({ ok: true, data: { active_section: "node_2" } });
  assert.strictEqual(h.hasClass(h.rows[1], "xc-node-active"), false,
    "node table follows the committed active node");
  assert.strictEqual(h.hasClass(h.rows[2], "xc-node-active"), true,
    "node table highlights the server-reported active node");
}

{
  const h = nodeHarness(3);
  h.rows[1].switchButton.onclick();
  h.requests[0].respond({ ok: true, data: { code: "switched", node: "node_1" } });
  const firstRefresh = h.requests[1];
  h.rows[2].switchButton.onclick();
  h.requests[2].respond({ ok: true, data: { code: "switched", node: "node_2" } });
  const secondRefresh = h.requests[3];
  secondRefresh.respond({ ok: true, data: { active_section: "node_2" } });
  firstRefresh.respond({ ok: true, data: { active_section: "node_1" } });
  assert.strictEqual(h.hasClass(h.rows[1], "xc-node-active"), false,
    "a late refresh from an older switch cannot restore its node");
  assert.strictEqual(h.hasClass(h.rows[2], "xc-node-active"), true,
    "the newest switch remains highlighted after a stale response");
}

for (const respond of [
  request => request.respond({ ok: false, code: "validation_failed" }, 400),
  request => request.respondRaw("{malformed", 500)
]) {
  const h = nodeHarness(3);
  h.rows[2].switchButton.onclick(); respond(h.requests[0]);
  assert.strictEqual(h.controls["xc-switch-state"].textContent, "Switch failed");
  assert.strictEqual(h.hasClass(h.rows[0], "xc-node-active"), true, "failed switch keeps the prior highlight");
  assert.strictEqual(h.rows[2].switchButton.value, "Switch");
  assert.strictEqual(h.rows[2].switchButton.disabled, false);
}

for (const fail of [request => request.fail(), request => request.expire()]) {
  const h = nodeHarness(3);
  h.rows[2].switchButton.onclick();
  assert.strictEqual(h.requests[0].timeout, 12000, "switch requests have a bounded browser deadline");
  fail(h.requests[0]);
  assert.strictEqual(h.controls["xc-switch-state"].textContent, "Switch failed");
  assert.strictEqual(h.hasClass(h.rows[0], "xc-node-active"), true, "network failure keeps the prior highlight");
  assert.strictEqual(h.rows[2].switchButton.value, "Switch");
  assert.strictEqual(h.rows[2].switchButton.disabled, false);
}

for (const respond of [
  request => request.respond({ ok: false }),
  request => request.respond({ ok: true }),
  request => request.respondRaw("{malformed")
]) {
  const h = nodeHarness(1);
  h.rows[0].button.onclick(); respond(h.requests[0]);
  assert.strictEqual(h.rows[0].latency.textContent, "Error");
  assert.strictEqual(h.rows[0].latency.style.color, "red");
  assert.strictEqual(h.rows[0].socket.textContent, "Failed");
  assert.strictEqual(h.rows[0].socket.style.color, "red");
}

for (const fail of [request => request.fail(), request => request.expire()]) {
  const h = nodeHarness(1);
  h.rows[0].button.onclick();
  assert.strictEqual(h.requests[0].timeout, 12000, "probe requests have a bounded browser deadline");
  fail(h.requests[0]);
  assert.strictEqual(h.rows[0].latency.textContent, "Error");
  assert.strictEqual(h.rows[0].socket.textContent, "Failed");
  assert.strictEqual(h.controls["xc-probe-all"].disabled, false, "failed requests release the queue");
}

for (const [ping, color] of [[100, "#b7791f"], [200, "#dd6b20"], [300, "red"]]) {
  const h = nodeHarness(1); h.controls["xc-probe-all"].onclick();
  h.requests[0].respond({ ok: true, data: { socket: "ok", ping, time: ping, outcome: "tcp" } });
  assert.strictEqual(h.rows[0].latency.style.color, color);
}

{
  const h = nodeHarness(1); h.controls["xc-probe-all"].onclick(); const stale = h.requests[0];
  h.controls["xc-probe-stop"].onclick();
  stale.respond({ ok: true, data: { socket: "ok", ping: 1, time: 1, outcome: "tcp" } });
  assert.strictEqual(h.rows[0].latency.textContent, "", "stale response must not render");
  assert.strictEqual(h.requests.length, 1, "stop prevents queued work from starting");
}

{
  const h = nodeHarness(1);
  h.rows[0].button.onclick(); const stale = h.requests[0];
  h.controls["xc-probe-stop"].onclick();
  h.rows[1].button.onclick();
  assert.strictEqual(h.requests.length, 1, "restart respects outstanding stale request concurrency");
  stale.respond({ ok: true, data: { socket: "ok", ping: 1, time: 1, outcome: "tcp" } });
  assert.strictEqual(h.rows[0].latency.textContent, "", "stale request never renders after restart");
  assert.strictEqual(h.requests.length, 2, "restart begins only after stale request releases its slot");
  h.requests[1].respond({ ok: true, data: { socket: "ok", ping: 2, time: 2, outcome: "tcp" } });
  assert.strictEqual(h.rows[1].latency.textContent, "2 ms");
  assert.strictEqual(h.controls["xc-probe-all"].disabled, false);
  assert.strictEqual(h.controls["xc-probe-state"].textContent, "");
}

function importHarness() {
  const xhr = xhrHarness(), listeners = {};
  function element(tag) {
    return { tag, textContent: "", value: "", disabled: false, files: [], children: [], style: {},
      appendChild(child) { this.children.push(child); }, removeChild(child) {
        const index = this.children.indexOf(child); if (index >= 0) this.children.splice(index, 1);
      }, onclick: null, onchange: null };
  }
  const elements = {};
  ["xc-import-file", "xc-import-paste", "xc-import-preview", "xc-import-commit", "xc-import-state",
    "xc-import-warnings", "xc-import-preview-body"].forEach(id => { elements[id] = element(id); });
  const document = { getElementById: id => elements[id], createElement: element,
    addEventListener: (name, fn) => { listeners[name] = fn; } };
  function FileReader() { FileReader.last = this; }
  FileReader.prototype.readAsText = function(file) { this.file = file; };
  const window = {};
  vm.runInNewContext(script("luasrc/view/xc/import.htm"), { window, document, XMLHttpRequest: xhr.XHR,
    FileReader, JSON, String, encodeURIComponent, confirm: () => true });
  if (listeners.DOMContentLoaded) listeners.DOMContentLoaded();
  return { elements, requests: xhr.requests, FileReader };
}

{
  const h = importHarness();
  h.elements["xc-import-file"].value = "C:\\fakepath\\nodes.txt";
  h.elements["xc-import-file"].files = [{ name: "nodes.txt" }];
  h.elements["xc-import-file"].onchange();
  h.FileReader.last.result = "socks://redacted.invalid"; h.FileReader.last.onload();
  assert.strictEqual(h.requests.length, 0, "file selection never uploads");
  h.elements["xc-import-preview"].onclick();
  assert.strictEqual(h.requests[0].method, "POST"); assert.ok(h.requests[0].url.indexOf("import-preview") >= 0);
  h.requests[0].respond({ ok: true, data: { nodes: [{ section: "node_1", name: "Safe", protocol: "socks",
    server: "example.invalid", port: 1080 }], warnings: ["skipped duplicate node", "unexpected backend prose"] } });
  assert.strictEqual(h.elements["xc-import-preview-body"].children.length, 1);
  assert.strictEqual(h.elements["xc-import-warnings"].children[0].textContent, "Skipped duplicate node");
  assert.strictEqual(h.elements["xc-import-warnings"].children[1].textContent, "Import warning");
  assert.strictEqual(h.requests.length, 1, "preview does not commit");
  h.elements["xc-import-commit"].onclick();
  assert.ok(h.requests[1].url.indexOf("import-commit") >= 0);
  h.requests[1].respond({ ok: false, code: "import_failed", message: "redacted" }, 500);
  assert.notStrictEqual(h.elements["xc-import-file"].value, "", "failure retains file state");
  h.elements["xc-import-commit"].onclick(); h.requests[2].respond({ ok: true, data: { imported: 1 } });
  assert.strictEqual(h.elements["xc-import-paste"].value, "");
  assert.strictEqual(h.elements["xc-import-file"].value, "");
}

console.log("PASS Task 9 node queue and local import DOM/XHR behavior");
