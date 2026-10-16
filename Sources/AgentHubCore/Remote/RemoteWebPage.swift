import Foundation

/// The phone page served at `/`. It holds no data itself; it reads the
/// pairing token from the link's `#token=` fragment (which browsers never
/// send to the server), keeps it on the phone, and calls the JSON API with it.
public enum RemoteWebPage {
    public static let html = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
<meta name="theme-color" content="#07080F">
<title>Agent Hub</title>
<style>
:root { --bg:#07080F; --deep:#0D1020; --card:rgba(255,255,255,.05); --stroke:rgba(255,255,255,.1);
  --text:#E8EDF7; --dim:#8F96B0; --faint:#61697F; --cyan:#22D3EE; --violet:#8B5CF6; --amber:#F59E0B; --green:#34D399; --rose:#F43F5E; }
@media (prefers-color-scheme: light) { :root { --bg:#F5F6FA; --deep:#EAECF4; --card:#fff; --stroke:rgba(0,0,0,.1);
  --text:#13161F; --dim:#545C72; --faint:#858C9E; --cyan:#0E9AB0; --violet:#6D3FD8; } }
* { box-sizing:border-box; -webkit-tap-highlight-color:transparent; }
html,body { margin:0; background:linear-gradient(var(--bg),var(--deep)) fixed; color:var(--text);
  font:15px/1.45 -apple-system,BlinkMacSystemFont,system-ui,sans-serif; min-height:100vh; }
header { position:sticky; top:0; z-index:5; display:flex; align-items:center; gap:10px;
  padding:calc(env(safe-area-inset-top) + 10px) 16px 10px; background:color-mix(in srgb,var(--bg) 88%,transparent);
  backdrop-filter:blur(12px); -webkit-backdrop-filter:blur(12px); border-bottom:1px solid var(--stroke); }
header h1 { font-size:16px; margin:0; flex:1; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
.logo { width:26px; height:26px; border-radius:8px; background:linear-gradient(135deg,var(--cyan),var(--violet)); flex:none; }
button { font:inherit; color:inherit; border:1px solid var(--stroke); background:var(--card); border-radius:999px; padding:7px 14px; }
button.primary { background:linear-gradient(90deg,var(--cyan),var(--violet)); color:#fff; border:none; font-weight:600; }
button.danger { color:var(--rose); }
main { padding:12px 16px calc(env(safe-area-inset-bottom) + 120px); max-width:760px; margin:0 auto; }
.card { background:var(--card); border:1px solid var(--stroke); border-radius:16px; padding:14px; margin:10px 0; }
.chat { display:block; width:100%; text-align:left; border-radius:16px; padding:14px; }
.row { display:flex; align-items:center; gap:8px; }
.title { font-weight:600; flex:1; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
.meta { color:var(--faint); font-size:12px; }
.dot { width:8px; height:8px; border-radius:50%; flex:none; }
.running { background:var(--cyan); } .needsInput { background:var(--amber); } .done { background:var(--green); } .failed { background:var(--rose); }
.badge { font:600 11px ui-monospace,monospace; letter-spacing:.06em; text-transform:uppercase; padding:2px 8px; border-radius:999px; }
.badge.needs { color:var(--amber); background:rgba(245,158,11,.14); }
.badge.live { color:var(--cyan); background:rgba(34,211,238,.14); }
.user { margin:14px 0 14px 15%; padding:10px 14px; border-radius:16px; background:linear-gradient(135deg,rgba(34,211,238,.25),rgba(139,92,246,.28)); white-space:pre-wrap; word-wrap:break-word; }
.agent { font-weight:600; }
.text { white-space:pre-wrap; word-wrap:break-word; margin:8px 0; }
pre { white-space:pre-wrap; word-wrap:break-word; font:12px/1.4 ui-monospace,monospace; background:rgba(0,0,0,.25); padding:10px; border-radius:10px; margin:8px 0; max-height:260px; overflow:auto; }
.tool { font:12.5px ui-monospace,monospace; color:var(--dim); border:1px solid var(--stroke); border-radius:10px; padding:8px 10px; margin:6px 0; }
.tool.ask { border-color:var(--amber); }
.tool .actions { display:flex; gap:8px; margin-top:8px; justify-content:flex-end; }
.system { color:var(--dim); font-size:13px; margin:6px 0; }
.composer { position:fixed; left:0; right:0; bottom:0; padding:10px 12px calc(env(safe-area-inset-bottom) + 10px);
  background:color-mix(in srgb,var(--bg) 92%,transparent); backdrop-filter:blur(12px); -webkit-backdrop-filter:blur(12px); border-top:1px solid var(--stroke); }
.composer form { display:flex; gap:8px; max-width:760px; margin:0 auto; }
textarea { flex:1; font:inherit; color:var(--text); background:var(--card); border:1px solid var(--stroke); border-radius:16px; padding:10px 12px; resize:none; height:44px; max-height:140px; }
.empty { text-align:center; color:var(--dim); margin-top:30vh; padding:0 20px; }
.err { color:var(--rose); }
</style>
</head>
<body>
<header><div class="logo"></div><h1 id="title">Agent Hub</h1><span id="right"></span></header>
<main id="main"><p class="empty">Connecting…</p></main>
<div class="composer" id="composer" hidden>
  <form id="form"><textarea id="input" placeholder="Message… @claude, @codex"></textarea><button class="primary" type="submit">Send</button></form>
</div>
<script>
(function () {
  "use strict";
  var hash = new URLSearchParams(location.hash.slice(1));
  if (hash.get("token")) {
    try { localStorage.setItem("agenthub-token", hash.get("token")); } catch (e) {}
    history.replaceState(null, "", location.pathname);
  }
  var token = null;
  try { token = localStorage.getItem("agenthub-token"); } catch (e) {}
  var state = null, openChat = null, timer = null, busy = false;
  var main = document.getElementById("main");

  function el(tag, cls, text) {
    var node = document.createElement(tag);
    if (cls) node.className = cls;
    if (text != null) node.textContent = text;
    return node;
  }
  function ago(iso) {
    var s = Math.max(0, (Date.now() - new Date(iso).getTime()) / 1000);
    if (s < 60) return "just now";
    if (s < 3600) return Math.floor(s / 60) + "m ago";
    if (s < 86400) return Math.floor(s / 3600) + "h ago";
    return Math.floor(s / 86400) + "d ago";
  }
  function api(method, path, body) {
    return fetch(path, {
      method: method,
      headers: { "Authorization": "Bearer " + token, "Content-Type": "application/json" },
      body: body ? JSON.stringify(body) : undefined,
      cache: "no-store"
    }).then(function (r) {
      if (r.status === 401) throw new Error("This link isn't paired. Scan the QR code in Agent Hub → Settings → Remote again.");
      if (!r.ok) return r.json().catch(function () { return {}; }).then(function (j) { throw new Error(j.error || ("Error " + r.status)); });
      return r.status === 204 ? null : r.json();
    });
  }
  function showError(message) {
    main.replaceChildren(el("p", "empty err", message));
  }
  function refresh() {
    if (!token) { showError("Open the link from the QR code in Agent Hub → Settings → Remote to pair this phone."); return; }
    if (busy) return;
    busy = true;
    api("GET", "/api/state").then(function (s) { state = s; render(); })
      .catch(function (e) { showError(e.message); })
      .then(function () { busy = false; });
  }
  function schedule() {
    clearInterval(timer);
    timer = setInterval(function () { if (!document.hidden) refresh(); }, 2000);
  }

  function render() {
    var right = document.getElementById("right");
    right.replaceChildren();
    document.getElementById("composer").hidden = false;
    var chat = openChat && state.chats.find(function (c) { return c.id === openChat; });
    if (!chat) { openChat = null; renderList(); return; }
    document.getElementById("title").textContent = chat.title;
    var back = el("button", null, "‹ Chats");
    back.onclick = function () { openChat = null; render(); window.scrollTo(0, 0); };
    right.appendChild(back);
    if (chat.busy) {
      var stop = el("button", "danger", "Stop");
      stop.style.marginLeft = "6px";
      stop.onclick = function () { api("POST", "/api/stop", { chatID: chat.id }).then(refresh).catch(alertError); };
      right.appendChild(stop);
    }
    var nearBottom = window.innerHeight + window.scrollY >= document.body.scrollHeight - 80;
    var nodes = [];
    chat.entries.forEach(function (entry) {
      if (entry.kind === "user") { nodes.push(el("div", "user", entry.text)); return; }
      var run = entry.run, card = el("div", "card");
      var head = el("div", "row");
      head.appendChild(el("span", "dot " + run.status));
      head.appendChild(el("span", "agent", run.agent));
      if (run.step) head.appendChild(el("span", "badge live", "step " + run.step));
      var spacer = el("span", "meta", (run.tokens ? run.tokens.toLocaleString() + " tokens" : "") + (run.model ? " · " + run.model : ""));
      spacer.style.marginLeft = "auto";
      head.appendChild(spacer);
      card.appendChild(head);
      if (!run.messages.length && run.active) card.appendChild(el("div", "system", "Working…"));
      run.messages.forEach(function (m) {
        if (m.kind === "text") card.appendChild(el("div", "text", m.text));
        else if (m.kind === "output") card.appendChild(el("pre", null, m.text));
        else if (m.kind === "system") card.appendChild(el("div", "system", m.text));
        else if (m.kind === "tool") {
          var ask = m.state === "awaitingApproval";
          var tool = el("div", "tool" + (ask ? " ask" : ""));
          tool.appendChild(el("div", null, (stateIcon(m.state)) + " " + (m.tool || "tool").replace("__", " › ") + " " + (m.arguments || "").slice(0, 300)));
          if (ask) {
            var actions = el("div", "actions");
            var deny = el("button", null, "Deny"), allow = el("button", "primary", "Allow");
            deny.onclick = function () { approve(m.id, false); };
            allow.onclick = function () { approve(m.id, true); };
            actions.append(deny, allow);
            tool.appendChild(actions);
          }
          card.appendChild(tool);
        }
      });
      nodes.push(card);
    });
    main.replaceChildren.apply(main, nodes);
    if (nearBottom) window.scrollTo(0, document.body.scrollHeight);
  }
  function stateIcon(s) {
    return s === "awaitingApproval" ? "✋" : s === "running" ? "⋯" : s === "succeeded" ? "✓" : s === "failed" ? "✕" : s === "denied" ? "⦸" : "•";
  }
  function renderList() {
    document.getElementById("title").textContent = "Agent Hub · " + state.host;
    if (!state.chats.length) { main.replaceChildren(el("p", "empty", "No chats yet. Send a message below to start one.")); return; }
    var nodes = state.chats.map(function (c) {
      var b = el("button", "chat card");
      var row = el("div", "row");
      row.appendChild(el("span", "title", c.title));
      if (c.needsApproval) row.appendChild(el("span", "badge needs", "approve"));
      else if (c.busy) row.appendChild(el("span", "badge live", "live"));
      b.appendChild(row);
      b.appendChild(el("div", "meta", ago(c.updatedAt) + (c.folder ? " · " + c.folder.split("/").pop() : "")));
      b.onclick = function () { openChat = c.id; render(); window.scrollTo(0, document.body.scrollHeight); };
      return b;
    });
    main.replaceChildren.apply(main, nodes);
  }
  function approve(id, approved) {
    api("POST", "/api/approve", { messageID: id, approved: approved }).then(refresh).catch(alertError);
  }
  function alertError(e) { alert(e.message); }

  var input = document.getElementById("input");
  input.addEventListener("input", function () { input.style.height = "44px"; input.style.height = Math.min(input.scrollHeight, 140) + "px"; });
  document.getElementById("form").addEventListener("submit", function (event) {
    event.preventDefault();
    var text = input.value.trim();
    if (!text) return;
    api("POST", "/api/send", { chatID: openChat, text: text }).then(function (r) {
      input.value = ""; input.style.height = "44px";
      if (r && r.chatID) openChat = r.chatID;
      if (r && r.notice) alert(r.notice);
      refresh();
    }).catch(alertError);
  });
  document.addEventListener("visibilitychange", function () { if (!document.hidden) refresh(); });
  refresh();
  schedule();
})();
</script>
</body>
</html>
"""#
}
