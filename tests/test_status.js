"use strict";

const assert = require("assert");
const fs = require("fs");
const vm = require("vm");

function loadStatus() {
  const source = fs.readFileSync("luasrc/view/xc/status.htm", "utf8");
  let script = source.match(/<script[^>]*>([\s\S]*?)<\/script>/)[1]
    .replace(/<%=dispatcher\.build_url\("admin", "services", "xc", "([^"]+)"\)%>/g, "/xc/$1")
    .replace(/<%=token%>/g, "csrf-token")
    .replace(/<%=util\.serialize_json\(translate\("Unavailable"\)\)%>/g, '"Unavailable"');
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
  assert.strictEqual(h.elements["xc-socks-listener"].textContent, "192.0.2.1:7890");
  assert.strictEqual(h.elements["xc-exit-ip"].textContent, "203.0.113.1");
  h.elements["xc-health"].onclick();
  const health = h.requests[1];
  assert.strictEqual(health.method, "POST");
  assert.strictEqual(health.url, "/xc/test-current?token=csrf-token");
  assert.strictEqual(health.headers["Content-Type"], "application/json");
  assert.strictEqual(health.body, "{}");
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

console.log("PASS status DOM/XHR/clock behavior");
