"use strict";

const assert = require("assert");
const fs = require("fs");
const vm = require("vm");

function script(path) {
  return fs.readFileSync(path, "utf8").match(/<script[^>]*>([\s\S]*?)<\/script>/)[1]
    .replace(/<%=dispatcher\.build_url\("admin", "services", "xc", "([^"]+)"\)%>/g, "/xc/$1")
    .replace(/<%=token%>/g, "csrf-token")
    .replace(/<%=probe_concurrency%>/g, "TEST_CONCURRENCY")
    .replace(/<%=util\.serialize_json\(translate\("([^"]+)"\)\)%>/g, (_, text) => JSON.stringify(text));
}

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
  return { XHR, requests };
}

function nodeHarness(concurrency) {
  const xhr = xhrHarness();
  function element() { return { textContent: "", disabled: false, style: {}, className: "", onclick: null }; }
  const controls = { "xc-probe-all": element(), "xc-probe-stop": element(), "xc-probe-state": element() };
  const rows = [0, 1, 2, 3, 4, 5].map(index => {
    const latency = element(), socket = element(), button = element();
    return {
      section: "node_" + index, latency, socket, button,
      getAttribute: name => name === "data-xc-section" ? "node_" + index : null,
      querySelector: selector => ({ ".xc-latency": latency, ".xc-socket": socket, ".xc-probe-one": button })[selector]
    };
  });
  const document = {
    getElementById: id => controls[id],
    querySelectorAll: selector => selector === ".xc-probe-row" ? rows : [],
    addEventListener: (name, fn) => { if (name === "DOMContentLoaded") fn(); }
  };
  const window = {};
  vm.runInNewContext(script("luasrc/view/xc/node_table.htm").replace("TEST_CONCURRENCY", String(concurrency)),
    { window, document, XMLHttpRequest: xhr.XHR, JSON, Number, Math, String, encodeURIComponent });
  return { window, controls, rows, requests: xhr.requests };
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
  assert.strictEqual(h.rows[2].socket.textContent, "OK");
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
