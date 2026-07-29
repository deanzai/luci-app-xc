"use strict";

const assert = require("assert");
const fs = require("fs");
const vm = require("vm");

function script(path) {
  return fs.readFileSync(path, "utf8").match(/<script[^>]*>([\s\S]*?)<\/script>/)[1];
}

function fixScript(source) {
  return source
    .replace(/<%=dispatcher\.build_url\("admin", "services", "xc", "([^"]+)"\)%>/g, "/xc/$1")
    .replace(/<%=token%>/g, "csrf-token")
    .replace(/<%=util\.serialize_json\(translate\("([^"]+)"\)\)%>/g, function(_, text) { return JSON.stringify(text); });
}

const logSource = fs.readFileSync("luasrc/view/xc/log.htm", "utf8");
assert.ok(logSource.includes('translate("Warning")'), "template has Warning level");
assert.ok(logSource.indexOf("textContent") >= 0, "template uses safe textContent");
assert.ok(logSource.indexOf("innerHTML") === -1, "template avoids innerHTML");
assert.ok(logSource.indexOf("payload.data.entries") >= 0, "template reads structured entries");

var createTextNodeFn = function(text) {
  return { nodeType: 3, textContent: String(text), data: String(text) };
};

function createElement(tag) {
  var node = { tagName: (tag || "div").toUpperCase(), id: "", disabled: false,
    style: {}, className: "", onclick: null, parentNode: null, children: [],
    classList: { add: function(name) {
      var classes = (node.className || "").split(/\s+/);
      if (classes.indexOf(name) < 0) { classes.push(name); node.className = classes.join(" "); }
    }},
    nodeType: 1,
    appendChild: function(child) {
      child.parentNode = this; this.children.push(child);
      this.firstChild = this.children[0] || null;
      this.lastChild = this.children[this.children.length - 1] || null;
      return child;
    },
    removeChild: function(child) {
      var at = this.children.indexOf(child);
      if (at >= 0) this.children.splice(at, 1);
      this.firstChild = this.children[0] || null;
      this.lastChild = this.children[this.children.length - 1] || null;
      child.parentNode = null;
      return child;
    },
    get textContent() {
      var texts = [];
      function walk(n) {
        if (n.nodeType === 3) texts.push(n.data || "");
        else if (n.children) for (var i = 0; i < n.children.length; i++) walk(n.children[i]);
      }
      walk(this);
      return texts.join("");
    },
    set textContent(v) {
      this.children = [];
      this.firstChild = null;
      this.lastChild = null;
      if (v) this.appendChild(createTextNodeFn(v));
    }
  };
  if (tag === "select") {
    node.value = "";
    node.options = [];
    node.origAppendChild = node.appendChild;
    node.appendChild = function(child) {
      child.parentNode = this;
      this.children.push(child);
      this.options.push(child);
      if (!this.value) this.value = child.value || "";
      return child;
    };
  }
  return node;
}

function xhrHarness() {
  var requests = [];
  function XHR() { this.headers = {}; this.readyState = 0; requests.push(this); }
  XHR.prototype.open = function(method, url) { this.method = method; this.url = url; };
  XHR.prototype.setRequestHeader = function(name, value) { this.headers[name] = value; };
  XHR.prototype.send = function(body) { this.body = body; };
  XHR.prototype.respond = function(value, status) {
    this.status = status || 200;
    this.responseText = JSON.stringify(value);
    this.readyState = 4;
    if (this.onreadystatechange) this.onreadystatechange();
  };
  return { XHR: XHR, requests: requests };
}

function makeDocument() {
  var doc = createElement("div");
  doc.id = "document";
  doc.createTextNode = createTextNodeFn;
  doc.createElement = function(tag) { var el = createElement(tag); el.createTextNode = createTextNodeFn; return el; };
  doc.getElementById = function(id) {
    function walk(node) {
      if (node.id === id) return node;
      for (var i = 0; i < (node.children || []).length; i++) {
        var found = walk(node.children[i]);
        if (found) return found;
      }
      return null;
    }
    return walk(this);
  };
  var ids = ["xc-log-container", "xc-log-state", "xc-log-refresh", "xc-log-clear", "xc-log-level"];
  ids.forEach(function(id) {
    var el = createElement(id === "xc-log-level" ? "select" : "div");
    el.id = id;
    doc.appendChild(el);
  });
  var select = doc.getElementById("xc-log-level");
  ["", "error", "warning", "info", "debug"].forEach(function(v) {
    var opt = createElement("option");
    opt.value = v;
    select.appendChild(opt);
  });
  return doc;
}

function logHarness() {
  var xhr = xhrHarness();
  var document = makeDocument();
  var window = {};
  vm.runInNewContext(fixScript(script("luasrc/view/xc/log.htm")),
    { window: window, document: document, XMLHttpRequest: xhr.XHR,
      JSON: JSON, String: String, Number: Number, Math: Math,
      encodeURIComponent: encodeURIComponent,
      confirm: function() { return true; }
    });
  return { document: document, requests: xhr.requests };
}

// 1. Auto-load
(function() {
  var h = logHarness();
  assert.strictEqual(h.requests.length, 1, "auto-loads on init");
  assert.ok(h.requests[0].url.indexOf("get-log") >= 0, "initial request is get-log");
  assert.strictEqual(h.requests[0].method, "GET");
}());

// 2. Structured entries
(function() {
  var h = logHarness();
  h.requests[0].respond({ ok: true, data: { entries: [
    { time: 1000, display_time: "t=1000", level: "error", source: "xray", message: "conn refused" },
    { time: 1001, display_time: "t=1001", level: "warning", source: "xc", message: "switch ok" },
    { time: 1002, display_time: "t=1002", level: "info", source: "xc", message: "probe ok" },
    { time: 1003, display_time: "", level: "debug", source: "xray", message: "debug out" }
  ]}});
  var c = h.document.getElementById("xc-log-container");
  assert.strictEqual(c.children.length, 4, "4 entries rendered");
  assert.strictEqual(c.children[0].className, "xc-log-error");
  assert.strictEqual(c.children[1].className, "xc-log-warning");
  assert.strictEqual(c.children[2].className, "xc-log-info");
  assert.strictEqual(c.children[3].className, "xc-log-debug");
  assert.ok(c.children[0].textContent.indexOf("[Xray]") >= 0);
  assert.ok(c.children[0].textContent.indexOf("[ERROR]") >= 0);
  assert.ok(c.children[0].textContent.indexOf("[t=1000]") >= 0);
  assert.ok(c.children[0].textContent.indexOf("conn refused") >= 0);
}());

// 3. Empty log shows placeholder
(function() {
  var h = logHarness();
  h.requests[0].respond({ ok: true, data: { entries: [] } });
  var c = h.document.getElementById("xc-log-container");
  assert.strictEqual(c.children.length, 1);
  assert.strictEqual(c.textContent, "(empty)");
}());

// 4. Level change
(function() {
  var h = logHarness();
  h.requests[0].respond({ ok: true, data: { entries: [] } });
  var before = h.requests.length;
  var s = h.document.getElementById("xc-log-level");
  s.value = "error";
  s.onchange();
  assert.strictEqual(h.requests.length, before + 1);
  assert.ok(h.requests[before].url.indexOf("level=error") >= 0);
}());

// 5. Clear
(function() {
  var h = logHarness();
  h.requests[0].respond({ ok: true, data: { entries: [{ time: 1, level: "info", source: "xc", message: "x" }] } });
  h.document.getElementById("xc-log-level").value = "warning";
  h.document.getElementById("xc-log-clear").onclick();
  var req = h.requests[1];
  assert.ok(req);
  assert.strictEqual(req.method, "POST");
  req.respond({ ok: true });
  assert.strictEqual(h.requests.length, 3, "clear success reloads the retained entries once");
  assert.strictEqual(h.requests[2].method, "GET");
  assert.ok(h.requests[2].url.indexOf("level=warning") >= 0, "reload keeps the selected level");
  assert.strictEqual(h.requests.filter(function(r) { return r.method === "POST"; }).length, 1,
    "reload does not issue a second clear");
  h.requests[2].respond({ ok: true, data: { entries: [
    { time: 2, display_time: "t=2", level: "warning", source: "xray", message: "still here" }
  ]}});
  assert.ok(h.document.getElementById("xc-log-container").textContent.indexOf("[Xray]") >= 0,
    "retained Xray entry remains visible after clearing XC entries");
  assert.ok(h.document.getElementById("xc-log-container").textContent.indexOf("still here") >= 0);
  assert.strictEqual(h.document.getElementById("xc-log-state").textContent,
    "XC entries cleared. Xray and system entries remain.");
  assert.strictEqual(h.requests.length, 3, "reload response does not start automatic refresh");
}());

// 6. Load failure
(function() {
  var h = logHarness();
  h.requests[0].respond({ ok: false }, 500);
  assert.ok(h.document.getElementById("xc-log-state").textContent.indexOf("Unable to load") >= 0);
}());

var levelColors = {};
["error", "warning", "info", "debug"].forEach(function(level) {
  var rule = logSource.match(new RegExp("\\.xc-log-" + level + "\\s*\\{[^}]*color\\s*:\\s*([^;}]+)", "i"));
  assert.ok(rule, "template defines a visible color for " + level);
  levelColors[rule[1].trim().toLowerCase()] = true;
});
assert.strictEqual(Object.keys(levelColors).length, 4, "all four log levels use different colors");

console.log("PASS XC log page DOM renderer");
