import QtQuick
import QtQml
import Quickshell
import Quickshell.Io
import qs.Commons
import "Model.js" as Model

// State and processes for the OpenDisplay widget; no UI.
//
// Sessions live in systemd user units (see bin/omarchy-opendisplay), so all
// state here is rebuilt from `status --json` and per-unit log tails, and a
// shell restart loses nothing.
Item {
  id: root

  property var settings: ({})
  property var knownReceivers: []
  property var strings: null
  property bool panelOpen: false
  readonly property bool checkUpdates: setting("checkUpdates", true) !== false

  signal receiverUsed(string id, string name, string addr, double when)

  readonly property string helperPath: decodeURIComponent(String(Qt.resolvedUrl("bin/omarchy-opendisplay")).replace(/^file:\/\//, ""))

  // --- od-sender install state
  property bool versionKnown: false
  property bool installed: false
  property string version: ""
  property string managed: ""
  property string latest: ""
  property string htmlUrl: "https://github.com/peetzweg/opendisplay/releases/latest"
  property bool releaseKnown: false
  property bool releaseError: false
  readonly property bool updateAvailable: installed && latest !== "" && Model.compareVersions(version, latest) < 0
  // "" | "updating" | "updated" | "error"
  property string updateState: ""
  property string updateMessage: ""
  property double lastUpdateCheckMs: 0

  // --- receivers and sessions
  property bool scanning: false
  property bool scanned: false
  property var discovered: []
  property var status: ({ ok: false, sessions: [], units: [], autoconnect: [], templateInstalled: false })
  property var config: ({})
  property var cards: []
  property var others: []
  property var connectingNames: []
  readonly property bool anyActive: cards.length > 0 || connectingNames.length > 0 || tailUnits.length > 0
  readonly property bool busy: _current !== null || installProc.running

  // --- errors: a translation key (+ arg) or raw untrusted text, rendered plain
  property string errorKey: ""
  property string errorArg: ""
  property string errorRaw: ""
  property bool errorDoctor: false
  readonly property bool hasError: errorKey !== "" || errorRaw !== ""

  // Per-unit live data from the log tails: { fps, mbps, latency, transport,
  // name, id, addr, lastLogMs, tailStartMs, connectedTs, lastError }
  property var _live: ({})
  // id/unit -> ms when a connect was requested and not yet seen live.
  property var _pending: ({})
  property var _pendingUnits: ({})
  property var _droppedNotified: ({})
  property var _queue: []
  property var _current: null
  property var tailUnits: []
  property string _tailSig: "[]"
  readonly property double startedMs: Date.now()

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function t(key) { return strings ? strings.t(key) : key }

  // ------------------------------------------------------------ errors

  function clearError() {
    errorKey = ""; errorArg = ""; errorRaw = ""; errorDoctor = false
  }

  function setError(key, arg, doctor) {
    errorRaw = ""
    errorKey = key
    errorArg = arg || ""
    errorDoctor = doctor === true
  }

  function setRawError(text, doctor) {
    var line = lastLine(text)
    if (line === "") { setError("error.commandFailed"); return }
    errorKey = ""
    errorArg = ""
    errorRaw = Model.clampText(line, 160)
    errorDoctor = doctor === true
  }

  function lastLine(text) {
    var lines = String(text || "").split("\n")
    for (var i = lines.length - 1; i >= 0; i--) {
      var l = Model.stripControl(lines[i]).trim()
      if (l !== "") return l
    }
    return ""
  }

  // Known helper messages get translated; anything else is shown as-is.
  function errorFromHelper(text) {
    var line = lastLine(text)
    if (/rejected the setting/.test(line)) setError("error.rejected", "", true)
    else if (/Auto-connect needs the od-sender systemd unit/.test(line)) setError("error.autoConnectUnit")
    else if (/invalid address/.test(line)) setError("error.invalidAddr")
    else setRawError(line)
  }

  // ------------------------------------------------------------ action queue

  // Helper commands run one at a time, in order, so a preset click followed by
  // a restart can't race. `done(exitCode, stdout, stderr)` runs afterwards.
  function enqueue(args, done) {
    var q = _queue.slice()
    q.push({ command: [helperPath].concat(args), done: done || null })
    _queue = q
    pump()
  }

  function pump() {
    // _current stays set until its result is handled, which can be a moment
    // after the process itself has exited.
    if (_current !== null || _queue.length === 0) return
    var q = _queue.slice()
    _current = q.shift()
    _queue = q
    actionProc.command = _current.command
    actionProc.running = true
  }

  // ------------------------------------------------------------ refresh

  function refreshStatus() {
    if (statusProc.running) { statusDebounce.restart(); return }
    statusProc.running = true
  }

  function scheduleStatus() { statusDebounce.restart() }

  function refreshVersion() {
    if (!versionProc.running) versionProc.running = true
  }

  function refreshConfig() {
    if (!configProc.running) configProc.running = true
  }

  function scan() {
    if (!installed || scanProc.running) return
    scanning = true
    scanProc.running = true
  }

  function checkUpdate(force) {
    if (updateProc.running) return
    // The first-run card needs the release; otherwise honor the setting.
    if (installed && !checkUpdates && force !== true) return
    lastUpdateCheckMs = Date.now()
    updateProc.running = true
  }

  function onPanelOpened() {
    refreshVersion()
    refreshStatus()
    refreshConfig()
    scan()
    var stale = Date.now() - lastUpdateCheckMs > 6 * 3600 * 1000
    if (!installed && versionKnown && !releaseKnown) checkUpdate(true)
    else if (stale && checkUpdates) checkUpdate(false)
  }

  // ------------------------------------------------------------ sessions

  function liveFor(unit) {
    return _live[unit] || null
  }

  function rebuild() {
    var now = Date.now()
    var sessions = []
    var seenUnits = {}
    var connecting = []

    for (var i = 0; i < status.sessions.length; i++) {
      var s = status.sessions[i]
      var key = s.unit !== "" ? s.unit : s.output
      var live = liveFor(key) || {}
      var id = s.id || live.id || Model.idForOutput(s.output, discovered, knownReceivers)
      var state = "live"
      if (s.unit !== "" && live.tailStartMs && now - Math.max(live.tailStartMs, live.lastLogMs || 0) > 15000) state = "reconnecting"
      if (s.unit !== "") seenUnits[s.unit] = true
      sessions.push({
        key: key, id: id, unit: s.unit, output: s.output, pid: s.pid, to: s.to,
        external: s.unit === "", template: s.unit.indexOf("od-sender@") === 0,
        name: live.name || "", state: state,
        fps: live.fps === undefined ? -1 : live.fps,
        mbps: live.mbps === undefined ? -1 : live.mbps,
        latency: live.latency === undefined ? -1 : live.latency,
        transport: live.transport || ""
      })
      if (id !== "") delete _pending[id.toUpperCase()]
      if (s.unit !== "") delete _pendingUnits[s.unit]
    }

    for (var j = 0; j < status.units.length; j++) {
      var u = status.units[j]
      if (seenUnits[u.unit] || u.state === "failed" || u.state === "deactivating") continue
      var ul = liveFor(u.unit) || {}
      var uid = u.id || ul.id || ""
      sessions.push({
        key: u.unit, id: uid, unit: u.unit, output: "", to: u.to, external: false, template: u.template,
        name: ul.name || "", state: u.template ? "waiting" : "connecting"
      })
      seenUnits[u.unit] = true
    }

    // Pressed Connect, but status hasn't seen the unit yet.
    for (var pid in _pending) {
      var found = false
      for (var k = 0; k < sessions.length; k++) if (sessions[k].id !== "" && sessions[k].id.toUpperCase() === pid) found = true
      if (!found) sessions.push({ key: "pending:" + pid, id: _pending[pid].id, unit: "", state: "connecting", name: "" })
    }

    var merged = Model.mergeReceivers(discovered, knownReceivers, sessions, status.autoconnect, now)
    for (var m = 0; m < merged.others.length; m++) {
      if (merged.others[m].state === "connecting") connecting.push(merged.others[m].name)
    }
    cards = merged.cards
    others = merged.others
    connectingNames = connecting
    checkDropped(now)
  }

  function checkDropped(now) {
    for (var i = 0; i < cards.length; i++) {
      var c = cards[i]
      if (!c.template) continue
      var live = liveFor(c.unit) || {}
      var quiet = now - Math.max(live.tailStartMs || now, live.lastLogMs || 0)
      if (quiet > 30000 && !_droppedNotified[c.unit]) {
        _droppedNotified[c.unit] = true
        notify(t("notify.dropped").arg(c.name), "dropped:" + c.unit + ":" + (live.lastLogMs || 0))
      } else if (quiet < 15000) {
        delete _droppedNotified[c.unit]
      }
    }
  }

  function applyStatus(raw) {
    var parsed = Model.parseStatus(raw)
    if (!parsed.ok) return
    // A connect whose unit has failed: map the exit code to a message.
    for (var i = 0; i < parsed.units.length; i++) {
      var u = parsed.units[i]
      if (u.state !== "failed") continue
      var pendingId = u.id && _pending[u.id.toUpperCase()] ? u.id.toUpperCase() : ""
      if (pendingId === "" && !_pendingUnits[u.unit]) {
        // The id lives in the unit description only for template units; a
        // transient unit named after a pending id counts too.
        for (var p in _pending) if (Model.transientUnitForId(_pending[p].id) === u.unit) pendingId = p
      }
      if (pendingId === "" && !_pendingUnits[u.unit]) continue
      if (pendingId !== "") delete _pending[pendingId]
      delete _pendingUnits[u.unit]
      reportConnectFailure(u.unit, u.status)
    }
    // Pending entries that went nowhere (unit gone without failing).
    var now = Date.now()
    for (var p2 in _pending) {
      var unitName = Model.transientUnitForId(_pending[p2].id)
      var still = false
      for (var j = 0; j < parsed.units.length; j++) if (parsed.units[j].unit === unitName || Model.sameId(parsed.units[j].id, _pending[p2].id)) still = true
      if (!still && now - _pending[p2].since > 4000) delete _pending[p2]
    }
    for (var pu in _pendingUnits) {
      var exists = false
      for (var k = 0; k < parsed.units.length; k++) if (parsed.units[k].unit === pu) exists = true
      if (!exists && now - _pendingUnits[pu] > 4000) delete _pendingUnits[pu]
    }
    status = parsed
    syncTails()
    rebuild()
  }

  function reportConnectFailure(unit, code) {
    var kind = Model.connectErrorKind(code)
    if (kind === "notFound") setError("error.notFound")
    else if (kind === "badConfig") setError("error.badConfig", "", true)
    else {
      var live = liveFor(unit)
      if (live && live.lastError) setRawError(live.lastError)
      else enqueue(["last-error", unit], function(code2, out) {
        var r = Model.parseLogLine(lastLine(out))
        if (r && r.kind === "error") setRawError(r.text)
        else setError("error.commandFailed")
      })
    }
    // Reported; clear the failed unit (the queue runs after last-error).
    enqueue(["disconnect", unit], function() { scheduleStatus() })
  }

  function syncTails() {
    var units = []
    for (var i = 0; i < status.units.length; i++) {
      var u = status.units[i]
      if (u.state === "active" || u.state === "activating") units.push(u.unit)
    }
    units.sort()
    var sig = JSON.stringify(units)
    if (sig === _tailSig) return
    _tailSig = sig
    // Forget live data for units that are gone.
    var next = {}
    for (var k in _live) if (units.indexOf(k) !== -1) next[k] = _live[k]
    _live = next
    tailUnits = units
  }

  function tailStarted(unit) {
    var l = _live[unit] || {}
    l.tailStartMs = Date.now()
    _live[unit] = l
    // The tail replays only recent lines; fetch the session's opening lines
    // once for the receiver's name, id and address.
    enqueue(["first-lines", unit], function(code, out) {
      var lines = String(out || "").split("\n")
      for (var i = 0; i < lines.length; i++) if (lines[i] !== "") root.handleLog(unit, lines[i], true)
    })
  }

  function handleLog(unit, line, historic) {
    var r = Model.parseLogLine(line)
    if (!r) return
    if (tailUnits.indexOf(unit) === -1) return
    var l = _live[unit] || { tailStartMs: Date.now() }
    if (historic === true) {
      // Identity only; never resets stats or counts as activity.
      if (r.kind === "connected" && !l.addr) l.addr = r.addr
      if ((r.kind === "hello" || r.kind === "extending") && r.name !== "" && !l.name) l.name = r.name
      if ((r.kind === "hello" || r.kind === "extending") && r.id !== "" && !l.id) l.id = r.id
      if (r.kind === "extending" && l.id) receiverUsed(l.id, l.name || "", l.addr || "", r.ts > 0 ? r.ts : Date.now())
      _live[unit] = l
      rebuildThrottle.start()
      return
    }
    l.lastLogMs = Date.now()
    var fresh = r.ts > 0 && r.ts >= startedMs - 2000
    var needStatus = false
    if (r.kind === "sent") { l.fps = r.fps; l.mbps = r.mbps }
    else if (r.kind === "phone") {
      if (r.e2e50 >= 0) l.latency = r.e2e50
      if (r.transport !== "") l.transport = r.transport
    } else if (r.kind === "connected") {
      l.addr = r.addr
      l.fps = undefined; l.mbps = undefined; l.latency = undefined
      needStatus = true
    } else if (r.kind === "hello") {
      if (r.name !== "") l.name = r.name
      if (r.id !== "") l.id = r.id
    } else if (r.kind === "extending") {
      if (r.name !== "") l.name = r.name
      if (r.id !== "") l.id = r.id
      needStatus = true
      var id = l.id || ""
      if (id !== "") {
        delete _pending[id.toUpperCase()]
        receiverUsed(id, l.name || "", l.addr || "", r.ts > 0 ? r.ts : Date.now())
      }
      delete _pendingUnits[unit]
      if (fresh && unit.indexOf("od-sender@") === 0) notify(t("notify.connected").arg(l.name || id), "connected:" + unit + ":" + r.ts)
    } else if (r.kind === "ended") {
      needStatus = true
    } else if (r.kind === "error") {
      l.lastError = r.text
    }
    _live[unit] = l
    if (needStatus) scheduleStatus()
    rebuildThrottle.start()
  }

  // ------------------------------------------------------------ actions

  function connect(id) {
    if (!Model.isValidId(id)) return false
    clearError()
    var p = _pending
    p[id.toUpperCase()] = { id: id, since: Date.now() }
    _pending = p
    rebuild()
    enqueue(["connect", id], function(code, out, err) {
      if (code !== 0) {
        delete _pending[id.toUpperCase()]
        errorFromHelper(err || out)
      }
      scheduleStatus()
    })
    return true
  }

  function connectAddr(addr) {
    var a = String(addr || "").trim()
    if (!Model.isValidAddr(a)) { setError("error.invalidAddr"); return false }
    clearError()
    enqueue(["connect-addr", a], function(code, out, err) {
      if (code !== 0) errorFromHelper(err || out)
      else {
        var unit = lastLine(out)
        if (Model.isValidUnit(unit)) _pendingUnits[unit] = Date.now()
      }
      scheduleStatus()
    })
    return true
  }

  function connectLast() {
    var last = Model.lastUsedReceiver(knownReceivers)
    if (!last) { notify(t("error.noRecent"), "norecent"); return "no recent receiver" }
    connect(last.id)
    return "connecting " + last.name
  }

  function targetFor(card) {
    if (!card) return ""
    if (card.unit && card.unit !== "" && (card.id === "" || card.unit.indexOf("opendisplay-addr-") === 0)) return card.unit
    if (card.id !== "") return card.id
    if (card.output) return card.output
    return ""
  }

  function disconnect(target) {
    var t2 = String(target || "")
    if (t2 === "") return
    clearError()
    if (Model.isValidId(t2)) delete _pending[t2.toUpperCase()]
    enqueue(["disconnect", t2], function(code, out, err) {
      if (code !== 0) errorFromHelper(err || out)
      scheduleStatus()
    })
  }

  function disconnectAll() {
    var targets = []
    for (var i = 0; i < cards.length; i++) targets.push(targetFor(cards[i]))
    for (var j = 0; j < status.units.length; j++) {
      var u = status.units[j]
      if (!u.template && (u.state === "active" || u.state === "activating") && targets.indexOf(u.unit) === -1) targets.push(u.unit)
    }
    _pending = ({})
    for (var k = 0; k < targets.length; k++) if (targets[k] !== "") disconnect(targets[k])
    return targets.length
  }

  function cardForId(id) {
    for (var i = 0; i < cards.length; i++) if (Model.sameId(cards[i].id, id)) return cards[i]
    return null
  }

  function restartCard(card) {
    var target = card.unit !== "" ? card.unit : card.id
    if (target === "") return
    enqueue(["restart", target], function(code, out, err) {
      if (code !== 0) errorFromHelper(err || out)
      scheduleStatus()
    })
  }

  function applyConfigLocally(receiverId, key, value) {
    var next = JSON.parse(JSON.stringify(config || {}))
    var table = next
    if (receiverId !== "") {
      if (!next.receiver || typeof next.receiver !== "object") next.receiver = {}
      var tkey = receiverId
      for (var k in next.receiver) if (k.toUpperCase() === receiverId.toUpperCase()) tkey = k
      if (!next.receiver[tkey]) next.receiver[tkey] = {}
      table = next.receiver[tkey]
    }
    if (value === "") delete table[key]
    else if (value === "true" || value === "false") table[key] = value === "true"
    else if (/^[0-9.]+$/.test(value)) table[key] = parseFloat(value)
    else table[key] = value
    config = next
  }

  function writeConfig(receiverId, key, value, restartTargets) {
    var args = ["config-set"]
    if (receiverId !== "") args.push("--receiver", receiverId)
    args.push(key + "=" + value)
    clearError()
    applyConfigLocally(receiverId, key, value)
    enqueue(args, function(code, out, err) {
      if (code === 0 || code === 5) {
        if (code === 5) setError("error.cantRun", "", true)
        for (var i = 0; i < restartTargets.length; i++) restartCard(restartTargets[i])
      } else {
        errorFromHelper(err || out)
      }
      refreshConfig()
    })
  }

  function setReceiverOption(id, key, value) {
    if (!Model.isValidId(id)) return false
    var v = Model.validateSetting(key, value, "receiver")
    if (!v.ok) { setError("error.invalidValue"); return false }
    var card = cardForId(id)
    writeConfig(id, key, v.value, card ? [card] : [])
    return true
  }

  function setPreset(id, name) {
    var change = Model.presetChange(config, name)
    if (!change) return false
    return setReceiverOption(id, change.key, change.value)
  }

  function setGlobalOption(key, value) {
    var v = Model.validateSetting(key, value, "global")
    if (!v.ok) { setError("error.invalidValue"); return false }
    writeConfig("", key, v.value, cards.filter(function(c) { return c.unit !== "" || c.id !== "" }))
    return true
  }

  function setAutoConnect(id, on) {
    if (!Model.isValidId(id)) return
    clearError()
    if (on && !status.templateInstalled) { setError("error.autoConnectUnit"); return }
    enqueue(["autoconnect", id, on ? "on" : "off"], function(code, out, err) {
      if (code !== 0) errorFromHelper(err || out)
      scheduleStatus()
    })
  }

  function installOrUpdate() {
    if (installProc.running || managed === "package") return
    clearError()
    updateState = "updating"
    updateMessage = ""
    installProc.running = true
  }

  function openDoctor() { Quickshell.execDetached([helperPath, "doctor"]) }
  function openDetails() { Quickshell.execDetached([helperPath, "details"]) }
  function openRelease() {
    var url = Model.isGithubUrl(htmlUrl) ? htmlUrl : "https://github.com/peetzweg/opendisplay/releases/latest"
    Quickshell.execDetached(["omarchy-launch-browser", url])
  }

  // `key` dedupes the copies of this widget on other monitors (see helper).
  function notify(body, key) {
    // notify-send renders a subset of markup in the body; names are untrusted.
    var k = String(key || ("msg-" + Date.now())).replace(/[^A-Za-z0-9._:@-]/g, "_").substring(0, 200)
    Quickshell.execDetached([helperPath, "notify", k, Model.escapeMarkup(body)])
  }

  // IPC status line; English like other shell IPC output.
  function statusLine() {
    if (!installed) return "od-sender not installed"
    if (cards.length > 1) return "Extending onto " + cards.length + " displays"
    if (cards.length === 1) {
      var c = cards[0]
      return "Extending onto " + c.name + (c.state === "reconnecting" ? " (reconnecting)" : (c.fps >= 0 ? " · " + Model.formatRate(c.fps) + " fps" : ""))
    }
    if (connectingNames.length > 0) return "Connecting to " + connectingNames[0]
    return "Not connected"
  }

  // ------------------------------------------------------------ timers

  Timer {
    id: statusTimer
    interval: root.anyActive ? 5000 : 30000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refreshStatus()
  }

  Timer {
    id: statusDebounce
    interval: 300
    onTriggered: root.refreshStatus()
  }

  Timer {
    id: rebuildThrottle
    interval: 250
    onTriggered: root.rebuild()
  }

  Timer {
    // Re-evaluates "Reconnecting…" (no log lines for 15 s) between polls.
    interval: 5000
    repeat: true
    running: root.cards.length > 0
    onTriggered: root.rebuild()
  }

  Timer {
    id: scanTimer
    interval: 20000
    repeat: true
    running: root.panelOpen && root.installed
    onTriggered: root.scan()
  }

  Timer {
    // Update checks: 60 s after start, then daily; only if enabled.
    id: updateTimer
    interval: 60000
    repeat: true
    running: true
    onTriggered: {
      interval = 24 * 3600 * 1000
      if (root.installed && root.checkUpdates) root.checkUpdate(false)
    }
  }

  Timer {
    id: updatedTimer
    interval: 4000
    onTriggered: if (root.updateState === "updated") root.updateState = ""
  }

  Component.onCompleted: {
    refreshVersion()
    refreshConfig()
  }

  // ------------------------------------------------------------ processes

  // A helper process whose result is handled once it has exited *and* both
  // output streams have ended; on its own, onExited can fire before the last
  // of the output has been collected.
  component Job: Process {
    id: job
    signal finished(int code, string out, string err)
    property int _code: -1
    property bool _outDone: false
    property bool _errDone: false
    property string _out: ""
    property string _err: ""
    function _maybe() {
      if (_code < 0 || !_outDone || !_errDone) return
      var c = _code
      _code = -1
      finished(c, _out, _err)
    }
    onRunningChanged: if (running) { _code = -1; _outDone = false; _errDone = false; _out = ""; _err = "" }
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: { job._out = text; job._outDone = true; job._maybe() } }
    stderr: StdioCollector { waitForEnd: true; onStreamFinished: { job._err = text; job._errDone = true; job._maybe() } }
    onExited: function(code) { job._code = code; job._maybe() }
  }

  Job {
    id: versionProc
    command: [root.helperPath, "version"]
    onFinished: function(code, out) {
      var v = Model.parseVersionInfo(out)
      var wasInstalled = root.installed
      root.installed = v.installed
      root.version = v.version
      root.managed = v.installed ? v.managed : ""
      root.versionKnown = true
      if (root.installed && !wasInstalled && root.panelOpen) root.scan()
      if (!root.installed && root.panelOpen && !root.releaseKnown) root.checkUpdate(true)
    }
  }

  Job {
    id: statusProc
    command: [root.helperPath, "status", "--json"]
    onFinished: function(code, out) { if (code === 0) root.applyStatus(out) }
  }

  Job {
    id: scanProc
    command: [root.helperPath, "list"]
    onFinished: function(code, out) {
      root.scanning = false
      var r = Model.parseList(out)
      if (code === 0 && r.ok) {
        var sig = JSON.stringify(r.items)
        if (sig !== JSON.stringify(root.discovered)) root.discovered = r.items
        root.scanned = true
        root.rebuild()
      } else if (root.installed) {
        root.setError("error.scanFailed")
      }
    }
  }

  Job {
    id: configProc
    command: [root.helperPath, "config-get"]
    onFinished: function(code, out) {
      var c = Model.parseConfig(out)
      if (code === 0) root.config = c
      else if (c.error) root.setError("error.badConfig", "", true)
    }
  }

  Job {
    id: updateProc
    command: [root.helperPath, "check-update"]
    onFinished: function(code, out) {
      var u = Model.parseUpdateInfo(out)
      if (code === 0 && u.ok) {
        root.latest = u.latest
        root.htmlUrl = u.htmlUrl
        root.releaseKnown = true
        root.releaseError = false
      } else {
        root.releaseError = true
      }
    }
  }

  Job {
    id: installProc
    command: [root.helperPath, "install"]
    onFinished: function(code, out, err) {
      if (code === 0) {
        root.updateState = "updated"
        root.updateMessage = root.latest
        updatedTimer.restart()
        if (!root.panelOpen) root.notify(root.t("notify.updated").arg(root.latest), "updated:" + root.latest)
      } else {
        root.updateState = "error"
        root.updateMessage = Model.clampText(root.lastLine(err + "\n" + out), 160)
      }
      root.refreshVersion()
      root.scheduleStatus()
    }
  }

  Job {
    id: actionProc
    onFinished: function(code, out, err) {
      var job = root._current
      root._current = null
      if (job && job.done) {
        try { job.done(code, out, err) }
        catch (e) { console.warn("opendisplay", e) }
      }
      Qt.callLater(root.pump)
    }
  }

  // One journal tail per active unit; replaced only when the set changes.
  Instantiator {
    model: root.tailUnits
    delegate: Process {
      required property string modelData
      command: [root.helperPath, "logs", modelData]
      running: true
      stdout: SplitParser { onRead: function(line) { root.handleLog(modelData, line) } }
      Component.onCompleted: root.tailStarted(modelData)
      Component.onDestruction: running = false
    }
  }
}
