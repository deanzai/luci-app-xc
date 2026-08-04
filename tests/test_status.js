"use strict";

const assert = require("assert");
const fs = require("fs");
const vm = require("vm");

function loadStatus() {
  const source = fs.readFileSync("luasrc/view/xc/status.htm", "utf8");
  let script = source.match(/<script[^>]*>([\s\S]*?)<\/script>/)[1]
    .replace(/<%=dispatcher\.build_url\("admin", "services", "xc", "([^"]+)"\)%>/g, "/xc/$1")
    .replace(/<%=token%>/g, "csrf-token")
    .replace(/<%=util\.serialize_json\(translate\("([^"]+)"\)\)%>/g, (_, text) => JSON.stringify(text));
  const elements = {};
  ["xc-service-state", "xc-active-node", "xc-socks-listener", "xc-http-listener", "xc-exit-ip",
    "xc-restart", "xc-health", "xc-rollback", "xc-action-result"].forEach(id => {
    elements[id] = { id, textContent: "", disabled: false, onclick: null };
  });
  const listeners = {}, timers = [], requests = [];
  const document = {
    hidden: false,
    getElementById: id => elements[id],
    addEventListener: (name, callback) => { listeners[name] = callback; }
  };
  function XHR() { this.readyState = 0; this.headers = {}; this.aborted = false; requests.push(this); }
  XHR.prototype.open = function(method, url) { this.method = method; this.url = url; };
  XHR.prototype.setRequestHeader = function(name, value) { this.headers[name] = value; };
  XHR.prototype.send = function(body) { this.body = body; };
  XHR.prototype.abort = function() { this.aborted = true; this.readyState = 4; if (this.onreadystatechange) this.onreadystatechange(); };
  XHR.prototype.respond = function(value) {
    this.responseText = JSON.stringify(value); this.readyState = 4; if (this.onreadystatechange) this.onreadystatechange();
  };
  const window = {
    setTimeout: (callback, delay) => { const timer = { callback, delay, cleared: false }; timers.push(timer); return timer; },
    clearTimeout: timer => { timer.cleared = true; }
  };
  vm.runInNewContext(script, { window, document, XMLHttpRequest: XHR, JSON, String, encodeURIComponent });
  return { elements, document, listeners, timers, requests };
}

function status(data) { return { ok: true, data: Object.assign({ service_state: "running", active_section: "node_1", active_name: "Node", lock_state: "unlocked" }, data) }; }

{
  const h = loadStatus();
  h.requests[0].respond(status({ listen_ip: "192.0.2.1", socks_port: 7890, http_port: 10809, exit_ip: "203.0.113.1" }));
  assert.strictEqual(h.elements["xc-service-state"].textContent, "Running");
  assert.strictEqual(h.elements["xc-socks-listener"].textContent, "192.0.2.1:7890");
  assert.strictEqual(h.elements["xc-exit-ip"].textContent, "203.0.113.1");
  h.elements["xc-health"].onclick();
  const health = h.requests[1];
  assert.strictEqual(health.method, "POST");
  assert.strictEqual(health.url, "/xc/test-current?token=csrf-token");
  assert.strictEqual(health.headers["Content-Type"], "application/json");
  assert.strictEqual(health.body, "{}");
}

{
  const h = loadStatus(); h.requests[0].respond(status({ service_state: "stopped" }));
  assert.strictEqual(h.elements["xc-service-state"].textContent, "Stopped");
}

{
  const h = loadStatus(); h.requests[0].respond({ ok: false });
  assert.strictEqual(h.elements["xc-service-state"].textContent, "Error");
  assert.strictEqual(h.elements["xc-action-result"].textContent, "Status request failed");
}

{
  const h = loadStatus(), request = h.requests[0];
  request.responseText = "{"; request.readyState = 4; request.onreadystatechange();
  assert.strictEqual(h.elements["xc-action-result"].textContent, "Invalid server response");
}

{
  const h = loadStatus(); h.requests[0].respond(status({}));
  h.elements["xc-health"].onclick();
  assert.strictEqual(h.elements["xc-action-result"].textContent, "Working…");
  h.requests[1].respond({ ok: true, data: {} });
  assert.strictEqual(h.elements["xc-action-result"].textContent, "Operation completed");
}

{
  const h = loadStatus(); h.requests[0].respond(status({}));
  h.elements["xc-health"].onclick(); h.requests[1].respond({ ok: false, code: "not_implemented" });
  assert.strictEqual(h.elements["xc-action-result"].textContent, "Health testing is not implemented yet");
}

{
  const h = loadStatus(); h.requests[0].respond(status({}));
  h.elements["xc-restart"].onclick(); h.requests[1].respond({ ok: false, code: "test_failed" });
  assert.strictEqual(h.elements["xc-action-result"].textContent, "Operation failed");
}

for (const [address, port, expected] of [["fd00::1", 7890, "[fd00::1]:7890"], ["", 7890, "-"], ["192.0.2.1", null, "-"]]) {
  const h = loadStatus(); h.requests[0].respond(status({ listen_ip: address, socks_port: port }));
  assert.strictEqual(h.elements["xc-socks-listener"].textContent, expected);
}

{
  const h = loadStatus();
  h.requests[0].respond(status({ active_name: "<img src=x onerror=alert(1)>" }));
  assert.strictEqual(h.elements["xc-active-node"].textContent, "<img src=x onerror=alert(1)>");
  const poll = h.timers[h.timers.length - 1]; assert.strictEqual(poll.delay, 5000);
  h.document.hidden = true; h.listeners.visibilitychange(); assert.strictEqual(poll.cleared, true);
  h.document.hidden = false; h.listeners.visibilitychange(); assert.strictEqual(h.requests.length, 2);
}

{
  const h = loadStatus(); h.requests[0].respond(status({}));
  const timer = h.timers[h.timers.length - 1]; timer.callback();
  const staleStatus = h.requests[1];
  h.elements["xc-restart"].onclick();
  const mutation = h.requests[2]; mutation.respond({ ok: true, data: { code: "switched" } });
  assert.strictEqual(staleStatus.aborted, true, "mutation completion must supersede an in-flight poll");
  const refresh = h.requests[h.requests.length - 1];
  assert.strictEqual(refresh.method, "GET");
  assert.strictEqual(h.elements["xc-restart"].disabled, true, "controls stay disabled through refresh");
  refresh.respond(status({}));
  assert.strictEqual(h.elements["xc-restart"].disabled, false);
}

{
  const h = loadStatus(); h.requests[0].respond(status({}));
  h.elements["xc-restart"].onclick();
  h.requests[1].respond({ ok: true, data: { code: "switch_started", node: "node_1" } });
  assert.strictEqual(h.elements["xc-action-result"].textContent, "Working…",
    "status page waits for the detached switch");
  assert.strictEqual(h.elements["xc-restart"].disabled, true);
  const refresh = h.requests[h.requests.length - 1];
  refresh.respond(status({ operation: "switch" }));
  assert.strictEqual(h.elements["xc-restart"].disabled, true);
  h.timers[h.timers.length - 1].callback();
  const completed = h.requests[h.requests.length - 1];
  completed.respond(status({ operation: "idle" }));
  assert.strictEqual(h.elements["xc-action-result"].textContent, "Operation completed");
  assert.strictEqual(h.elements["xc-restart"].disabled, false);
}

console.log("PASS status DOM/XHR/clock behavior");
