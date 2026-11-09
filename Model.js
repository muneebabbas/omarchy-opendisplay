.pragma library

// Pure helpers for the OpenDisplay widget: parsing od-sender output, validating
// everything that crosses a process boundary, and the small decisions the UI
// makes from that data. No Qt calls, so tests/run.js can load it under node.
//
// Everything that comes from od-sender, the receiver, the network or a file is
// untrusted: it is bounded here and always rendered as plain text.

var MAX_RECEIVERS = 32
var MAX_NAME = 64
var MAX_LOG_LINE = 4096
var MAX_ERROR = 160
var MAX_KNOWN = 16
var DEFAULT_BITRATE = 20

var ID_RE = /^[0-9A-Fa-f][0-9A-Fa-f-]{7,63}$/
var ADDR_RE = /^[A-Za-z0-9\[][A-Za-z0-9.\-:\[\]]{0,79}:([0-9]{1,5})$/
var UNIT_RE = /^(opendisplay-[0-9a-f]{8}|opendisplay-addr-[0-9a-f]{8}|od-sender@[A-Za-z0-9\\_.:-]{1,300})\.service$/
var OUTPUT_RE = /^od-[0-9a-f]{6}$/

var PRESETS = [
  { name: "sharp", bitrate: 35 },
  { name: "balanced", bitrate: 20 },
  { name: "light", bitrate: 8 }
]

var PRESET_NAMES = PRESETS.map(function (p) { return p.name })

var ENCODERS = ["auto", "x264", "openh264", "v4l2m2m"]
var CURSORS = ["auto", "video", "off"]
var SCALE_CHOICES = ["passthrough", "mac", "1", "1.5", "2", "3"]

// ------------------------------------------------------------------ text

function stripControl(value) {
  // C0/C1 controls, DEL, and the bidi overrides that can reorder a line.
  return String(value === undefined || value === null ? "" : value)
    .replace(/[\u0000-\u001f\u007f-\u009f‪-‮⁦-⁩]/g, "")
}

function clampText(value, max) {
  var text = stripControl(value).replace(/\s+/g, " ").trim()
  if (text.length <= max) return text
  return text.substring(0, Math.max(0, max - 1)) + "…"
}

// notify-send renders a subset of markup in the body, so neutralize it there.
function escapeMarkup(value) {
  return String(value === undefined || value === null ? "" : value)
    .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
}

// ------------------------------------------------------------------ identifiers

function isValidId(id) {
  return typeof id === "string" && ID_RE.test(id)
}

function isValidAddr(addr) {
  if (typeof addr !== "string") return false
  var m = ADDR_RE.exec(addr)
  if (!m) return false
  var port = parseInt(m[1], 10)
  return port >= 1 && port <= 65535
}

function isValidUnit(unit) {
  return typeof unit === "string" && UNIT_RE.test(unit)
}

function hexOnly(id) {
  return String(id || "").replace(/[^0-9A-Fa-f]/g, "").toLowerCase()
}

// The virtual display od-sender creates: "od-" + first 6 hex chars, lowercased.
function outputNameForId(id) {
  if (!isValidId(id)) return ""
  return "od-" + hexOnly(id).substring(0, 6)
}

function sameId(a, b) {
  return isValidId(a) && isValidId(b) && a.toUpperCase() === b.toUpperCase()
}

// ------------------------------------------------------------------ od-sender list

function parseJson(raw) {
  try {
    return { ok: true, value: JSON.parse(String(raw || "")) }
  } catch (e) {
    return { ok: false, value: null }
  }
}

function parseList(raw) {
  var parsed = parseJson(raw)
  if (!parsed.ok || !(parsed.value instanceof Array)) return { ok: false, items: [] }
  var items = []
  var seen = {}
  for (var i = 0; i < parsed.value.length && items.length < MAX_RECEIVERS; i++) {
    var r = parsed.value[i]
    if (!r || typeof r !== "object") continue
    if (!isValidId(r.id) || !isValidAddr(r.addr)) continue
    var key = r.id.toUpperCase()
    if (seen[key]) continue
    seen[key] = true
    var name = clampText(r.name, MAX_NAME)
    items.push({
      id: r.id,
      name: name !== "" ? name : r.id.substring(0, 8),
      addr: r.addr,
      pv: typeof r.pv === "number" && isFinite(r.pv) && Math.floor(r.pv) === r.pv ? r.pv : 0
    })
  }
  return { ok: true, items: items }
}

// ------------------------------------------------------------------ helper status --json

function toInt(value, fallback) {
  var n = typeof value === "number" ? value : parseInt(String(value), 10)
  return isFinite(n) ? Math.floor(n) : fallback
}

function parseStatus(raw) {
  var parsed = parseJson(raw)
  var out = { ok: false, sessions: [], units: [], autoconnect: [], templateInstalled: false }
  if (!parsed.ok || !parsed.value || typeof parsed.value !== "object") return out
  var v = parsed.value
  out.ok = true
  out.templateInstalled = v.templateInstalled === true
  var list = v.sessions instanceof Array ? v.sessions : []
  for (var i = 0; i < list.length && out.sessions.length < MAX_RECEIVERS; i++) {
    var s = list[i]
    if (!s || !OUTPUT_RE.test(String(s.output))) continue
    out.sessions.push({
      output: s.output,
      pid: toInt(s.pid, 0),
      unit: isValidUnit(s.unit) ? s.unit : "",
      id: isValidId(s.id) ? s.id : "",
      to: clampText(s.to, 96),
      since: toInt(s.since, 0)
    })
  }
  var units = v.units instanceof Array ? v.units : []
  for (var j = 0; j < units.length && out.units.length < MAX_RECEIVERS * 2; j++) {
    var u = units[j]
    if (!u || !isValidUnit(u.unit)) continue
    var state = String(u.state || "")
    if (["active", "activating", "deactivating", "failed"].indexOf(state) === -1) continue
    out.units.push({
      unit: u.unit,
      state: state,
      template: u.template === true,
      id: isValidId(u.id) ? u.id : "",
      to: clampText(u.to, 96),
      status: toInt(u.status, 0),
      since: toInt(u.since, 0)
    })
  }
  var auto = v.autoconnect instanceof Array ? v.autoconnect : []
  for (var k = 0; k < auto.length && out.autoconnect.length < MAX_RECEIVERS; k++) {
    if (isValidId(auto[k])) out.autoconnect.push(auto[k])
  }
  return out
}

// ------------------------------------------------------------------ log lines

var LOG_RE = /^(\d{4}-\d{2}-\d{2}T[0-9:.]+Z)\s+(TRACE|DEBUG|INFO|WARN|ERROR)\s+(.*)$/

function parseLogLine(line) {
  var text = String(line === undefined || line === null ? "" : line)
  if (text.length > MAX_LOG_LINE) return null
  text = text.replace(/\x1b\[[0-9;]*m/g, "").replace(/\r$/, "")
  var m = LOG_RE.exec(text)
  if (!m) return { kind: "other", ts: 0 }
  var ts = Date.parse(m[1])
  var level = m[2]
  var msg = m[3]
  var r

  if ((r = /^sent ([0-9.]+) fps ([0-9.]+) Mbit\/s/.exec(msg))) {
    return { kind: "sent", ts: ts, fps: parseFloat(r[1]), mbps: parseFloat(r[2]) }
  }
  if (msg.indexOf("PHONE-STATS ") === 0) {
    var stats = parseJson(msg.substring("PHONE-STATS ".length))
    if (!stats.ok || !stats.value || typeof stats.value !== "object") return { kind: "other", ts: ts }
    var s = stats.value
    return {
      kind: "phone",
      ts: ts,
      e2e50: typeof s.e2e50 === "number" && isFinite(s.e2e50) ? s.e2e50 : -1,
      transport: typeof s.transport === "string" ? clampText(s.transport, 16) : ""
    }
  }
  if ((r = /^connected to receiver (\S+)/.exec(msg))) {
    return { kind: "connected", ts: ts, addr: isValidAddr(r[1]) ? r[1] : "" }
  }
  if ((r = /^hello: .* device (?:Some\("(.*)"\)|None) id (?:Some\("([^"]*)"\)|None)/.exec(msg))) {
    var hname = clampText(String(r[1] || "").replace(/\\"/g, "\""), MAX_NAME)
    return { kind: "hello", ts: ts, name: hname, id: isValidId(r[2]) ? r[2] : "" }
  }
  if ((r = /^Extending onto (.*) \(([0-9A-Fa-f-]+)\):/.exec(msg))) {
    return { kind: "extending", ts: ts, name: clampText(r[1], MAX_NAME), id: isValidId(r[2]) ? r[2] : "" }
  }
  if (/^connection ended/.test(msg) || /^removed virtual display/.test(msg)) {
    return { kind: "ended", ts: ts }
  }
  if (level === "ERROR") return { kind: "error", ts: ts, text: clampText(msg, MAX_ERROR) }
  if (level === "WARN") return { kind: "warn", ts: ts, text: clampText(msg, MAX_ERROR) }
  return { kind: "other", ts: ts }
}

function transportLabel(value) {
  var t = clampText(value, 12)
  if (t === "WiFi") return "Wi-Fi"
  if (t.toUpperCase() === "USB") return "USB"
  return t
}

// ------------------------------------------------------------------ version + release

function versionParts(v) {
  var m = /^v?(\d+)\.(\d+)\.(\d+)/.exec(String(v || ""))
  if (!m) return null
  return [parseInt(m[1], 10), parseInt(m[2], 10), parseInt(m[3], 10)]
}

function compareVersions(a, b) {
  var pa = versionParts(a)
  var pb = versionParts(b)
  if (!pa || !pb) return 0
  for (var i = 0; i < 3; i++) {
    if (pa[i] < pb[i]) return -1
    if (pa[i] > pb[i]) return 1
  }
  return 0
}

function parseVersionInfo(raw) {
  var p = parseJson(raw)
  var v = p.ok && p.value && typeof p.value === "object" ? p.value : {}
  var version = versionParts(v.version) ? String(v.version).replace(/^v/, "") : ""
  var managed = ["user", "package", "other"].indexOf(v.managed) !== -1 ? v.managed : "other"
  return { installed: v.installed === true && version !== "", version: version, managed: managed, path: clampText(v.path, 256) }
}

function isGithubUrl(url) {
  return typeof url === "string" && url.length <= 512 && /^https:\/\/github\.com\/peetzweg\/opendisplay\/[A-Za-z0-9._\/-]*$/.test(url)
}

function parseUpdateInfo(raw) {
  var p = parseJson(raw)
  var v = p.ok && p.value && typeof p.value === "object" ? p.value : null
  if (!v || !versionParts(v.latest)) return { ok: false, latest: "", newer: false, htmlUrl: "" }
  return {
    ok: true,
    latest: String(v.latest).replace(/^v/, "").substring(0, 32),
    newer: v.newer === true,
    htmlUrl: isGithubUrl(v.htmlUrl) ? v.htmlUrl : "https://github.com/peetzweg/opendisplay/releases/latest"
  }
}

// ------------------------------------------------------------------ sender.toml

function parseConfig(raw) {
  var p = parseJson(raw)
  return p.ok && p.value && typeof p.value === "object" && !(p.value instanceof Array) ? p.value : {}
}

function receiverTable(config, id) {
  var tables = config && config.receiver && typeof config.receiver === "object" ? config.receiver : {}
  if (!isValidId(id)) return {}
  for (var key in tables) {
    if (String(key).toUpperCase() === id.toUpperCase() && tables[key] && typeof tables[key] === "object") return tables[key]
  }
  return {}
}

function topBitrate(config) {
  var top = config ? config["bitrate-mbps"] : undefined
  return typeof top === "number" && isFinite(top) ? top : DEFAULT_BITRATE
}

function effectiveBitrate(config, id) {
  var rec = receiverTable(config, id)["bitrate-mbps"]
  if (typeof rec === "number" && isFinite(rec)) return rec
  return topBitrate(config)
}

function presetForBitrate(n) {
  for (var i = 0; i < PRESETS.length; i++) if (PRESETS[i].bitrate === n) return PRESETS[i].name
  return ""
}

function bitrateForPreset(name) {
  for (var i = 0; i < PRESETS.length; i++) if (PRESETS[i].name === name) return PRESETS[i].bitrate
  return -1
}

// What selecting a preset writes into the receiver table. "" deletes the key.
function presetChange(config, name) {
  var bitrate = bitrateForPreset(name)
  if (bitrate < 0) return null
  if (name === "balanced" && topBitrate(config) === DEFAULT_BITRATE) return { key: "bitrate-mbps", value: "" }
  return { key: "bitrate-mbps", value: String(bitrate) }
}

function effectiveScale(config, id) {
  var v = receiverTable(config, id).scale
  if (v === undefined) v = config ? config.scale : undefined
  if (v === undefined || v === null) return "passthrough"
  return String(v)
}

// Scale for the receiver table. Passthrough deletes the key only when the
// top-level scale would give the same result; otherwise it is written
// explicitly so it overrides the top-level value.
function scaleChange(config, id, value) {
  var text = String(value)
  if (text === "passthrough") {
    var top = config ? config.scale : undefined
    var inherit = top === undefined || top === null || String(top) === "passthrough"
    return { key: "scale", value: inherit ? "" : "passthrough" }
  }
  return { key: "scale", value: text }
}

function globalValue(config, key, fallback) {
  var v = config ? config[key] : undefined
  return v === undefined || v === null ? fallback : v
}

// Same rules as bin/sender-config.py, so the UI rejects input before calling it.
// Returns { ok, value } with value normalized to the text form the helper takes;
// "" means "delete the key".
function validateSetting(key, value, scope) {
  var text = String(value === undefined || value === null ? "" : value).trim()
  var isReceiver = scope === "receiver"
  if (text === "") {
    var deletable = isReceiver ? ["bitrate-mbps", "scale"] : ["max-fps", "encoder", "cursor", "tailscale"]
    return deletable.indexOf(key) !== -1 ? { ok: true, value: "" } : { ok: false, value: "" }
  }
  if (isReceiver) {
    if (key === "bitrate-mbps") {
      if (!/^[0-9]{1,3}$/.test(text)) return { ok: false, value: "" }
      var b = parseInt(text, 10)
      return b >= 1 && b <= 200 ? { ok: true, value: String(b) } : { ok: false, value: "" }
    }
    if (key === "scale") {
      if (text === "passthrough" || text === "mac") return { ok: true, value: text }
      if (!/^[0-9](\.[0-9]{1,2})?$/.test(text)) return { ok: false, value: "" }
      var s = parseFloat(text)
      if (s < 1 || s > 4 || Math.round(s * 4) !== s * 4) return { ok: false, value: "" }
      return { ok: true, value: String(s) }
    }
    return { ok: false, value: "" }
  }
  if (key === "max-fps") {
    if (!/^[0-9]{1,3}$/.test(text)) return { ok: false, value: "" }
    var f = parseInt(text, 10)
    return f >= 1 && f <= 240 ? { ok: true, value: String(f) } : { ok: false, value: "" }
  }
  if (key === "encoder") return ENCODERS.indexOf(text) !== -1 ? { ok: true, value: text } : { ok: false, value: "" }
  if (key === "cursor") return CURSORS.indexOf(text) !== -1 ? { ok: true, value: text } : { ok: false, value: "" }
  if (key === "tailscale") return text === "true" || text === "false" ? { ok: true, value: text } : { ok: false, value: "" }
  return { ok: false, value: "" }
}

// ------------------------------------------------------------------ known receivers

function sanitizeKnown(list) {
  var out = []
  var seen = {}
  var arr = list instanceof Array ? list : []
  for (var i = 0; i < arr.length && out.length < MAX_KNOWN; i++) {
    var k = arr[i]
    if (!k || !isValidId(k.id) || seen[k.id.toUpperCase()]) continue
    seen[k.id.toUpperCase()] = true
    out.push({
      id: k.id,
      name: clampText(k.name, MAX_NAME) || k.id.substring(0, 8),
      lastAddr: isValidAddr(k.lastAddr) ? k.lastAddr : "",
      lastUsed: toInt(k.lastUsed, 0)
    })
  }
  return out
}

function rememberReceiver(list, id, name, addr, now) {
  if (!isValidId(id)) return sanitizeKnown(list)
  var old = sanitizeKnown(list)
  var prev = null
  var rest = []
  for (var i = 0; i < old.length; i++) {
    if (sameId(old[i].id, id)) prev = old[i]
    else rest.push(old[i])
  }
  var entry = {
    id: id,
    name: clampText(name, MAX_NAME) || (prev ? prev.name : id.substring(0, 8)),
    lastAddr: isValidAddr(addr) ? addr : (prev ? prev.lastAddr : ""),
    lastUsed: toInt(now, 0)
  }
  return [entry].concat(rest).slice(0, MAX_KNOWN)
}

function lastUsedReceiver(list) {
  var known = sanitizeKnown(list)
  var best = null
  for (var i = 0; i < known.length; i++) if (!best || known[i].lastUsed > best.lastUsed) best = known[i]
  return best
}

function findKnown(list, id) {
  var known = sanitizeKnown(list)
  for (var i = 0; i < known.length; i++) if (sameId(known[i].id, id)) return known[i]
  return null
}

// Whole days between two millisecond timestamps, never negative.
function relativeDays(ts, now) {
  var t = toInt(ts, 0)
  if (t <= 0) return -1
  var d = Math.floor((toInt(now, 0) - t) / 86400000)
  return d < 0 ? 0 : d
}

// ------------------------------------------------------------------ sessions + merge

// A session id is resolved from (in order): what the helper learned from the
// sender's command line, the hello line, then by matching the od-xxxxxx output
// against discovered and known receivers.
function idForOutput(output, discovered, known) {
  var pools = [discovered instanceof Array ? discovered : [], sanitizeKnown(known)]
  for (var p = 0; p < pools.length; p++) {
    var found = ""
    for (var i = 0; i < pools[p].length; i++) {
      if (outputNameForId(pools[p][i].id) === output) {
        if (found !== "" && !sameId(found, pools[p][i].id)) return ""
        found = pools[p][i].id
      }
    }
    if (found !== "") return found
  }
  return ""
}

// cards: one per live session (connected or reconnecting).
// others: discovered receivers that aren't live (possibly connecting), plus
// offline receivers with auto-connect on: waiting when their template unit
// is running, paused when it isn't (e.g. the user disconnected it).
function mergeReceivers(discovered, known, sessions, autoIds, now) {
  var disc = discovered instanceof Array ? discovered : []
  var knownList = sanitizeKnown(known)
  var sess = sessions instanceof Array ? sessions : []
  var autos = autoIds instanceof Array ? autoIds : []
  var cards = []
  var others = []
  var used = {}

  function isAuto(id) {
    for (var a = 0; a < autos.length; a++) if (sameId(autos[a], id)) return true
    return false
  }
  function discoveredFor(id) {
    for (var d = 0; d < disc.length; d++) if (sameId(disc[d].id, id)) return disc[d]
    return null
  }
  function nameFor(id, fallback) {
    var d = discoveredFor(id)
    if (d) return d.name
    var k = findKnown(knownList, id)
    if (k) return k.name
    return fallback || (isValidId(id) ? id.substring(0, 8) : "")
  }

  var connecting = {}
  for (var i = 0; i < sess.length; i++) {
    var s = sess[i]
    if (s.state === "connecting" || s.state === "waiting") {
      if (isValidId(s.id)) connecting[s.id.toUpperCase()] = s
      else if (s.state === "connecting") {
        others.push({ key: s.key, id: "", name: s.name || s.to || "", addr: s.to || "", state: "connecting",
          autoConnect: false, lastUsedDays: -1, unit: s.unit || "" })
      }
      continue
    }
    var card = {}
    for (var f in s) card[f] = s[f]
    card.name = s.name || nameFor(s.id, s.to || s.output)
    card.autoConnect = isValidId(s.id) && isAuto(s.id)
    cards.push(card)
    if (isValidId(s.id)) used[s.id.toUpperCase()] = true
  }

  for (var j = 0; j < disc.length; j++) {
    var r = disc[j]
    var key = r.id.toUpperCase()
    if (used[key]) continue
    used[key] = true
    var k = findKnown(knownList, r.id)
    var c = connecting[key]
    others.push({
      key: r.id, id: r.id, name: r.name, addr: r.addr,
      state: c ? c.state : "idle",
      autoConnect: isAuto(r.id),
      lastUsedDays: k ? relativeDays(k.lastUsed, now) : -1,
      unit: c ? (c.unit || "") : ""
    })
  }

  // Offline receivers that will connect on their own, and connecting ones
  // that aren't in the latest scan.
  var extra = []
  for (var ck in connecting) if (!used[ck]) extra.push(connecting[ck].id)
  for (var a2 = 0; a2 < autos.length; a2++) if (!used[autos[a2].toUpperCase()] && extra.indexOf(autos[a2]) === -1) extra.push(autos[a2])
  for (var e = 0; e < extra.length; e++) {
    var id = extra[e]
    if (used[id.toUpperCase()]) continue
    used[id.toUpperCase()] = true
    var cs = connecting[id.toUpperCase()]
    var kk = findKnown(knownList, id)
    var auto = isAuto(id)
    others.push({
      key: id, id: id, name: nameFor(id, ""), addr: kk ? kk.lastAddr : "",
      state: cs && cs.state === "connecting" ? "connecting"
        : (auto ? (cs && cs.state === "waiting" ? "waiting" : "paused") : "idle"),
      autoConnect: auto,
      lastUsedDays: kk ? relativeDays(kk.lastUsed, now) : -1,
      unit: cs ? (cs.unit || "") : ""
    })
  }
  return { cards: cards, others: others }
}

function hasSessionId(list, id) {
  for (var i = 0; i < list.length; i++) if (list[i].id && String(list[i].id).toUpperCase() === String(id).toUpperCase()) return true
  return false
}

function blank(o) {
  o.fps = -1; o.mbps = -1; o.latency = -1; o.transport = ""
  return o
}

// Everything the panel shows as a session, from helper status plus what the
// log tails learned. Pure: inputs are never modified.
function buildSessions(status, live, pending, discovered, known, now) {
  var st = status || {}
  var lv = live || {}
  var pd = pending || {}
  var ss = st.sessions instanceof Array ? st.sessions : []
  var us = st.units instanceof Array ? st.units : []
  var out = []
  var seen = {}

  for (var i = 0; i < ss.length; i++) {
    var s = ss[i]
    var key = s.unit !== "" ? s.unit : s.output
    var l = lv[key] || {}
    var id = s.id || l.id || idForOutput(s.output, discovered, known)
    var state = "live"
    if (s.unit !== "" && l.tailStartMs && now - Math.max(l.tailStartMs, l.lastLogMs || 0) > 15000) state = "reconnecting"
    if (s.unit !== "") seen[s.unit] = true
    out.push({
      key: key, id: id, unit: s.unit, output: s.output, pid: s.pid, to: s.to,
      external: s.unit === "", template: s.unit.indexOf("od-sender@") === 0,
      name: l.name || "", state: state,
      fps: l.fps === undefined ? -1 : l.fps,
      mbps: l.mbps === undefined ? -1 : l.mbps,
      latency: l.latency === undefined ? -1 : l.latency,
      transport: l.transport || ""
    })
  }

  for (var j = 0; j < us.length; j++) {
    var u = us[j]
    if (seen[u.unit] || (u.state !== "active" && u.state !== "activating")) continue
    var ul = lv[u.unit] || {}
    seen[u.unit] = true
    out.push(blank({
      key: u.unit, id: u.id || ul.id || "", unit: u.unit, output: "", to: u.to, external: false,
      template: u.template, name: ul.name || "", state: u.template ? "waiting" : "connecting"
    }))
  }

  for (var p in pd) {
    var pid = pd[p].id || p
    if (hasSessionId(out, pid)) continue
    out.push(blank({
      key: "pending:" + String(pid).toUpperCase(), id: pid, unit: "", output: "", to: "", external: false,
      template: false, name: "", state: "connecting"
    }))
  }
  return out
}

// Settles Connect clicks against fresh helper status. A failed unit older than
// the click is stale and is not blamed for it.
function reconcilePending(pending, pendingUnits, status, now) {
  var st = status || {}
  var ss = st.sessions instanceof Array ? st.sessions : []
  var us = st.units instanceof Array ? st.units : []
  var np = {}
  var nu = {}
  var failures = []

  function running(u) { return u.state === "active" || u.state === "activating" }

  for (var key in pending) {
    var entry = pending[key]
    var id = entry.id || key
    var resolved = hasSessionId(ss, id)
    var failed = null
    var present = resolved
    for (var i = 0; i < us.length; i++) {
      if (!us[i].id || us[i].id.toUpperCase() !== String(id).toUpperCase()) continue
      // A running transient unit is still connecting (od-sender searches for
      // up to 10 s before failing), so only a live session resolves the
      // connect. A running auto-connect template means the helper left it to
      // that unit, which is as good as done.
      if (running(us[i])) { present = true; if (us[i].template) resolved = true }
      else if (us[i].state === "failed" && us[i].since * 1000 >= entry.since - 1000) failed = us[i]
    }
    if (resolved) continue
    if (failed) { failures.push({ unit: failed.unit, status: failed.status, id: id }); continue }
    if (!present && now - entry.since > 30000) continue
    np[key] = entry
  }

  for (var unit in pendingUnits) {
    var since = pendingUnits[unit]
    var done = false
    var bad = null
    var alive = false
    for (var j = 0; j < ss.length; j++) if (ss[j].unit === unit) done = true
    for (var k = 0; k < us.length; k++) {
      if (us[k].unit !== unit) continue
      if (running(us[k])) alive = true
      else if (us[k].state === "failed" && us[k].since * 1000 >= since - 1000) bad = us[k]
    }
    if (done) continue
    if (bad) { failures.push({ unit: unit, status: bad.status, id: bad.id || "" }); continue }
    if (!alive && now - since > 30000) continue
    nu[unit] = since
  }
  return { pending: np, pendingUnits: nu, failures: failures }
}

// Folds one parsed log line into a unit's live entry.
function reduceLive(entry, parsed, now, opts) {
  var l = {}
  for (var f in entry) l[f] = entry[f]
  var o = opts || {}
  var r = parsed
  var fx = { needStatus: false, used: null, notifyConnected: false }
  var identity = r.kind === "hello" || r.kind === "extending"

  if (o.historic === true) {
    if (r.kind === "connected" && !l.addr) l.addr = r.addr
    if (identity && r.name !== "" && !l.name) l.name = r.name
    if (identity && r.id !== "" && !l.id) l.id = r.id
    if (r.kind === "extending" && l.id) fx.used = { id: l.id, name: l.name || "", addr: l.addr || "", ts: r.ts > 0 ? r.ts : now }
    return { entry: l, effects: fx }
  }

  l.lastLogMs = now
  if (r.ts > 0) l.lastLogTs = r.ts
  if (r.kind === "sent") { l.fps = r.fps; l.mbps = r.mbps }
  else if (r.kind === "phone") {
    if (r.e2e50 >= 0) l.latency = r.e2e50
    if (r.transport !== "") l.transport = r.transport
  } else if (r.kind === "connected") {
    l.addr = r.addr
    delete l.fps; delete l.mbps; delete l.latency
    fx.needStatus = true
  } else if (r.kind === "hello") {
    if (r.name !== "") l.name = r.name
    if (r.id !== "") l.id = r.id
  } else if (r.kind === "extending") {
    if (r.name !== "") l.name = r.name
    if (r.id !== "") l.id = r.id
    fx.needStatus = true
    if (l.id) fx.used = { id: l.id, name: l.name || "", addr: l.addr || "", ts: r.ts > 0 ? r.ts : now }
    fx.notifyConnected = r.ts > 0 && r.ts >= (o.tailStartMs || 0) - 2000
  } else if (r.kind === "ended") {
    fx.needStatus = true
  } else if (r.kind === "error") {
    l.lastError = r.text
  }
  return { entry: l, effects: fx }
}

// The journal timestamp is identical in every per-monitor copy of the widget,
// so these keys let the notification helper dedupe across monitors.
function droppedNotificationKey(unit, entry) {
  return "dropped:" + unit + ":" + (entry && entry.lastLogTs || 0)
}

function connectedNotificationKey(unit, ts) {
  return "connected:" + unit + ":" + ts
}

function pick(list, fields) {
  var out = []
  for (var i = 0; i < list.length; i++) {
    var o = {}
    for (var f = 0; f < fields.length; f++) o[fields[f]] = list[i][fields[f]]
    out.push(o)
  }
  return JSON.stringify(out)
}

// Structure only (no live stats), so a stats tick doesn't rebuild the lists.
function cardsSignature(cards) {
  return pick(cards instanceof Array ? cards : [], ["key", "id", "name", "state", "autoConnect", "external", "template", "unit", "output"])
}

function othersSignature(others) {
  return pick(others instanceof Array ? others : [], ["key", "id", "name", "addr", "state", "autoConnect", "lastUsedDays", "unit"])
}

// Helper exit code to i18n key. "" means show the raw stderr line.
function helperError(code) {
  if (code === 2) return { key: "error.invalidValue", doctor: false }
  if (code === 5) return { key: "error.cantRun", doctor: true }
  if (code === 6) return { key: "error.rejected", doctor: true }
  if (code === 7) return { key: "error.autoConnectUnit", doctor: false }
  if (code === 8) return { key: "error.notInstalled", doctor: false }
  if (code === 9) return { key: "error.externalSender", doctor: false }
  if (code === 10) return { key: "error.packageManaged", doctor: false }
  if (code === 11) return { key: "error.offline", doctor: false }
  return { key: "", doctor: false }
}

// False when the stored entry is already current, so nothing needs writing.
function shouldRemember(known, id, name, when) {
  var prev = findKnown(known, id)
  if (prev && prev.lastUsed >= when && (name === "" || prev.name === clampText(name, MAX_NAME))) return false
  return true
}

// Resolves an IPC "connect <name>" by id, or by name only when unambiguous.
function resolveTarget(text, rows) {
  var q = String(text || "").trim()
  var list = rows instanceof Array ? rows : []
  if (q === "") return { id: "", error: "missing" }
  for (var i = 0; i < list.length; i++) if (sameId(list[i].id, q)) return { id: list[i].id, error: "" }
  var hits = []
  for (var j = 0; j < list.length; j++) {
    if (isValidId(list[j].id) && String(list[j].name) === q && hits.indexOf(list[j].id) === -1) hits.push(list[j].id)
  }
  if (hits.length === 1) return { id: hits[0], error: "" }
  if (hits.length > 1) return { id: "", error: "ambiguous" }
  if (isValidId(q)) return { id: q, error: "" }
  return { id: "", error: "notfound" }
}

// ------------------------------------------------------------------ bar + errors

function connectErrorKind(exitCode) {
  if (exitCode === 3) return "notFound"
  if (exitCode === 2) return "badConfig"
  if (exitCode === 4) return "ambiguous"
  return "other"
}

function formatRate(value) {
  if (typeof value !== "number" || !isFinite(value) || value < 0) return ""
  return value >= 10 ? String(Math.round(value)) : String(Math.round(value * 10) / 10)
}
