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
  XHR.prototype.respondText = function(value, status) {
    this.status = status || 200;
    this.responseText = value;
    this.readyState = 4;
    if (this.onreadystatechange) this.onreadystatechange();
  };
  XHR.prototype.respond = function(value, status) {
    this.respondText(JSON.stringify(value), status);
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

function assertControlsDisabled(h, disabled, context) {
  ["xc-log-refresh", "xc-log-clear", "xc-log-level"].forEach(function(id) {
    assert.strictEqual(h.document.getElementById(id).disabled, disabled, context + ": " + id);
  });
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
  var row = c.children[0];
  assert.strictEqual(row.children.length, 4, "entry has four structured fields");
  ["xc-log-source", "xc-log-level", "xc-log-time", "xc-log-message"].forEach(function(className, i) {
    assert.strictEqual(row.children[i].tagName, "SPAN");
    assert.strictEqual(row.children[i].className, className);
  });
  assert.strictEqual(row.children[0].textContent, "[Xray] ");
  assert.strictEqual(row.children[1].textContent, "[ERROR] ");
  assert.strictEqual(row.children[2].textContent, "[t=1000] ");
  assert.strictEqual(row.children[3].textContent, "conn refused");
}());

// 3. Untrusted log values remain text
(function() {
  var h = logHarness();
  var message = '<script>steal()</script> password=hunter2 token="abc" Authorization: Bearer xyz';
  h.requests[0].respond({ ok: true, data: { entries: [
    { time: 1000, display_time: "<script>time()</script>", level: "error", source: "xray", message: message }
  ]}});
  var row = h.document.getElementById("xc-log-container").children[0];
  assert.strictEqual(row.children[2].textContent, "[<script>time()</script>] ");
  assert.strictEqual(row.children[3].textContent, message);
  var scripts = 0;
  (function countScripts(node) {
    if (node.nodeType === 1 && node.tagName === "SCRIPT") scripts++;
    for (var i = 0; i < (node.children || []).length; i++) countScripts(node.children[i]);
  }(row));
  assert.strictEqual(scripts, 0, "log values do not create script elements");
}());

// 4. Invalid entries are isolated
(function() {
  var h = logHarness();
  assert.doesNotThrow(function() {
    h.requests[0].respond({ ok: true, data: { entries: [
      null,
      { time: 2, display_time: "t=2", level: "info", source: "xray", message: "valid remains" },
      { time: 3, display_time: "t=3", level: 7, source: "xc", message: "invalid level" }
    ]}});
  }, "a malformed entry does not abort the response");
  var c = h.document.getElementById("xc-log-container");
  assert.strictEqual(c.children.length, 1, "only the valid entry is rendered");
  assert.strictEqual(c.children[0].textContent, "[Xray] [INFO] [t=2] valid remains");
  assertControlsDisabled(h, false, "mixed response completes");
}());

(function() {
  var h = logHarness();
  assert.doesNotThrow(function() {
    h.requests[0].respond({ ok: true, data: { entries: [
      null,
      { display_time: "t=1", level: "info", source: "bogus", message: "bad source" },
      { display_time: "t=2", level: "bogus", source: "xc", message: "bad level" },
      { display_time: 3, level: "info", source: "xc", message: "bad time" },
      { display_time: "t=4", level: "info", source: "xc", message: null }
    ]}});
  }, "an all-invalid response does not throw");
  assert.strictEqual(h.document.getElementById("xc-log-state").textContent, "Unable to load the log");
  assert.strictEqual(h.document.getElementById("xc-log-container").children.length, 0);
  assertControlsDisabled(h, false, "all-invalid response completes");
}());

// 5. Empty log shows placeholder
(function() {
  var h = logHarness();
  h.requests[0].respond({ ok: true, data: { entries: [] } });
  var c = h.document.getElementById("xc-log-container");
  assert.strictEqual(c.children.length, 1);
  assert.strictEqual(c.textContent, "(empty)");
}());

// 6. Level allowlist
["", "error", "warning", "info", "debug"].forEach(function(level) {
  var h = logHarness();
  var s = h.document.getElementById("xc-log-level");
  s.value = level;
  s.onchange();
  assert.strictEqual(h.requests.length, 2);
  assert.strictEqual(h.requests[1].url, "/xc/get-log" + (level ? "?level=" + level : ""),
    "allowed level is sent: " + (level || "all"));
});

(function() {
  var h = logHarness();
  var s = h.document.getElementById("xc-log-level");
  s.value = "bogus";
  s.onchange();
  assert.strictEqual(h.requests[1].url, "/xc/get-log", "unknown level safely falls back to All");
  assert.strictEqual(h.requests[1].url.indexOf("bogus"), -1, "unknown level never enters the query");
}());

// 7. Clear
(function() {
  var h = logHarness();
  h.requests[0].respond({ ok: true, data: { entries: [
    { time: 1, display_time: "t=1", level: "info", source: "xc", message: "x" }
  ]}});
  h.document.getElementById("xc-log-level").value = "warning";
  h.document.getElementById("xc-log-clear").onclick();
  assertControlsDisabled(h, true, "clear POST is pending");
  var req = h.requests[1];
  assert.ok(req);
  assert.strictEqual(req.method, "POST");
  req.respond({ ok: true });
  assert.strictEqual(h.requests.length, 3, "clear success reloads the retained entries once");
  assert.strictEqual(h.requests[2].method, "GET");
  assert.ok(h.requests[2].url.indexOf("level=warning") >= 0, "reload keeps the selected level");
  assertControlsDisabled(h, true, "clear completed but retained-entry GET is pending");
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
  assertControlsDisabled(h, false, "retained-entry GET completed");
  assert.strictEqual(h.requests.length, 3, "reload response does not start automatic refresh");
}());

// 8. Load failure
(function() {
  var h = logHarness();
  h.requests[0].respond({ ok: false }, 500);
  assert.ok(h.document.getElementById("xc-log-state").textContent.indexOf("Unable to load") >= 0);
}());

(function() {
  var h = logHarness();
  h.requests[0].respondText("{not-json");
  assert.strictEqual(h.document.getElementById("xc-log-state").textContent, "Unable to load the log",
    "malformed JSON shows the translated load failure");
}());

(function() {
  var h = logHarness();
  h.requests[0].respond({ ok: true, data: { entries: {
    0: { time: 1, display_time: "t=1", level: "info", source: "xray", message: "not an array" },
    length: 1
  }}});
  assert.strictEqual(h.document.getElementById("xc-log-state").textContent, "Unable to load the log",
    "array-like entries object is rejected");
  assert.strictEqual(h.document.getElementById("xc-log-container").children.length, 0,
    "invalid entries are not rendered");
}());

var levelColors = {};
["error", "warning", "info", "debug"].forEach(function(level) {
  var rule = logSource.match(new RegExp("\\.xc-log-" + level + "\\s*\\{[^}]*color\\s*:\\s*([^;}]+)", "i"));
  assert.ok(rule, "template defines a visible color for " + level);
  levelColors[rule[1].trim().toLowerCase()] = true;
});
assert.strictEqual(Object.keys(levelColors).length, 4, "all four log levels use different colors");

console.log("PASS XC log page DOM renderer");
