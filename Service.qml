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
  readonly property bool scanning: scanProc.pending || usbProc.pending
  property bool scanned: false
  property var discovered: []
  // Receivers plugged in by USB (usb-list), merged with `discovered` by id.
  property var usbDevices: []
  property var status: ({ ok: false, sessions: [], units: [], autoconnect: [], templateInstalled: false, wifi: true, usb: "missing" })
  // Global "Wi-Fi connections" switch; the helper's flag file is the truth.
  readonly property bool wifiEnabled: status.wifi !== false
  // usbmuxd: "running" | "installed" | "missing"
  readonly property string usbState: status.usb || "missing"
  property var config: ({})
  // `cards` and `others` are reassigned only when their structure changes, so
  // the panel's delegates survive a stats tick; live numbers are in `stats`.
  property var cards: []
  property var others: []
  property var stats: ({})
  property var connectingNames: []
  // A waiting auto-connect template alone is not a reason to poll every 5 s.
  readonly property bool hasRunningSession: {
    var units = status.units || []
    for (var i = 0; i < units.length; i++) {
      if (!units[i].template && (units[i].state === "active" || units[i].state === "activating")) return true
    }
    return false
  }
  readonly property bool anyActive: cards.length > 0 || connectingNames.length > 0 || hasRunningSession
  readonly property bool busy: actions.busy || installProc.pending

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
  property string _cardsSig: ""
  property string _othersSig: ""
  property string _statsSig: ""
  property string _connectingSig: "[]"
  // JS mirror of tailModel's units, for lookups.
  property var tailUnits: []
  property string _tailSig: "[]"
  // Where the helper stamps every change, so other monitors' copies of this
  // widget refresh too. Set once the first status call has succeeded.
  property string stampPath: ""

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

  // The helper's exit code picks the message; only an unmapped failure shows
  // its own last stderr line (raw, untrusted).
  function handleHelperError(code, out, err) {
    var e = Model.helperError(code)
    if (e.key !== "") { setError(e.key, "", e.doctor); return }
    var line = lastLine(err)
    setRawError(line !== "" ? line : lastLine(out))
  }

  function forgetPending(id) {
    var key = String(id || "").toUpperCase()
    if (key === "" || !_pending[key]) return
    var next = {}
    for (var k in _pending) if (k !== key) next[k] = _pending[k]
    _pending = next
  }

  function forgetPendingUnit(unit) {
    if (_pendingUnits[unit] === undefined) return
    var next = {}
    for (var k in _pendingUnits) if (k !== unit) next[k] = _pendingUnits[k]
    _pendingUnits = next
  }

  // ------------------------------------------------------------ refresh

  function refreshStatus() {
    if (statusProc.pending) { statusDebounce.restart(); return }
    statusProc.running = true
  }

  function scheduleStatus() { statusDebounce.restart() }

  function refreshVersion() {
    if (!versionProc.pending) versionProc.running = true
  }

  function refreshConfig() {
    if (!configProc.pending) configProc.running = true
  }

  // Discovery: USB always, the network only while Wi-Fi connections are on.
  function scan() {
    if (!installed) return
    if (!usbProc.pending) usbProc.running = true
    if (wifiEnabled && !scanProc.pending) scanProc.running = true
  }

  function setWifi(on) {
    clearError()
    if (!on) { discovered = []; rebuild() }
    actions.enqueue(["wifi", on ? "on" : "off"], function(code, out, err) {
      if (code !== 0) handleHelperError(code, out, err)
      else {
        // The helper has switched; reflect it now so scan() (which skips the
        // network while wifiEnabled is false) doesn't wait for the status refresh.
        var next = {}
        for (var k in status) next[k] = status[k]
        next.wifi = on
        status = next
        if (on) scan()
      }
      refreshStatus()
    })
  }

  function checkUpdate(force) {
    if (updateProc.pending) return
    // The first-run card needs the release; otherwise honor the setting.
    if (installed && !checkUpdates && force !== true) return
    lastUpdateCheckMs = Date.now()
    // Without --force the helper answers from its cache when it is under 6 h old.
    updateProc.command = force === true ? [helperPath, "check-update", "--force"] : [helperPath, "check-update"]
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

  function rebuild() {
    var now = Date.now()
    var sessions = Model.buildSessions(status, _live, _pending, discovered, knownReceivers, now)
    var merged = Model.mergeReceivers(discovered, knownReceivers, sessions, status.autoconnect, now, usbDevices)

    var connecting = []
    for (var m = 0; m < merged.others.length; m++) {
      if (merged.others[m].state === "connecting") connecting.push(merged.others[m].name)
    }
    var live = {}
    for (var c = 0; c < merged.cards.length; c++) {
      var card = merged.cards[c]
      live[card.key] = {
        fps: card.fps === undefined ? -1 : card.fps,
        mbps: card.mbps === undefined ? -1 : card.mbps,
        latency: card.latency === undefined ? -1 : card.latency,
        transport: card.transport || ""
      }
    }

    var cardsSig = Model.cardsSignature(merged.cards)
    if (cardsSig !== _cardsSig) { _cardsSig = cardsSig; cards = merged.cards }
    var othersSig = Model.othersSignature(merged.others)
    if (othersSig !== _othersSig) { _othersSig = othersSig; others = merged.others }
    var statsSig = JSON.stringify(live)
    if (statsSig !== _statsSig) { _statsSig = statsSig; stats = live }
    var connectingSig = JSON.stringify(connecting)
    if (connectingSig !== _connectingSig) { _connectingSig = connectingSig; connectingNames = connecting }
  }

  // Called from the 5 s timer, never from rebuild().
  function checkDropped(now) {
    for (var i = 0; i < cards.length; i++) {
      var c = cards[i]
      if (!c.template) continue
      var live = _live[c.unit] || {}
      var quiet = now - Math.max(live.tailStartMs || now, live.lastLogMs || 0)
      if (quiet > 30000 && !_droppedNotified[c.unit]) {
        _droppedNotified[c.unit] = true
        notify(t("notify.dropped").arg(c.name), Model.droppedNotificationKey(c.unit, _live[c.unit]))
      } else if (quiet < 15000) {
        delete _droppedNotified[c.unit]
      }
    }
  }

  function applyStatus(raw) {
    var parsed = Model.parseStatus(raw)
    if (!parsed.ok) return
    var r = Model.reconcilePending(_pending, _pendingUnits, parsed, Date.now())
    _pending = r.pending
    _pendingUnits = r.pendingUnits
    for (var i = 0; i < r.failures.length; i++) reportConnectFailure(r.failures[i].unit, r.failures[i].status)
    // Wi-Fi turned off (here or on another monitor): drop what the network showed.
    if (!parsed.wifi && discovered.length > 0) discovered = []
    status = parsed
    syncTails()
    rebuild()
  }

  function reportConnectFailure(unit, code) {
    var kind = Model.connectErrorKind(code)
    if (kind === "notFound") setError("error.notFound")
    else if (kind === "badConfig") setError("error.badConfig", "", true)
    else {
      var live = _live[unit]
      if (live && live.lastError) setRawError(live.lastError)
      else lookups.enqueue(["last-error", unit], function(code2, out) {
        var r = Model.parseLogLine(lastLine(out))
        if (r && r.kind === "error") setRawError(r.text)
        else setError("error.commandFailed")
      })
    }
    // Reported; clear the failed unit.
    actions.enqueue(["disconnect", unit], function() { scheduleStatus() })
  }

  // One log tail per active unit. tailModel is diffed in place: handing the
  // Instantiator a fresh array would restart every tail whenever the set changed.
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
    // Before the model changes, so a new tail's first lines are accepted.
    tailUnits = units
    var have = {}
    for (var r = tailModel.count - 1; r >= 0; r--) {
      var unit = tailModel.get(r).unit
      if (units.indexOf(unit) === -1) tailModel.remove(r)
      else have[unit] = true
    }
    for (var n = 0; n < units.length; n++) if (!have[units[n]]) tailModel.append({ unit: units[n] })
  }

  function tailStarted(unit) {
    var l = _live[unit] || {}
    l.tailStartMs = Date.now()
    _live[unit] = l
    // The tail replays only recent lines; fetch the session's opening lines
    // once for the receiver's name, id and address.
    lookups.enqueue(["first-lines", unit], function(code, out) {
      var lines = String(out || "").split("\n")
      for (var i = 0; i < lines.length; i++) if (lines[i] !== "") root.handleLog(unit, lines[i], true)
    })
  }

  function handleLog(unit, line, historic) {
    var parsed = Model.parseLogLine(line)
    if (!parsed || tailUnits.indexOf(unit) === -1) return
    var now = Date.now()
    var cur = _live[unit]
    var res = Model.reduceLive(cur, parsed, now, { historic: historic === true, tailStartMs: (cur || {}).tailStartMs || now })
    _live[unit] = res.entry
    var fx = res.effects
    if (fx.needStatus) scheduleStatus()
    if (fx.used) {
      forgetPending(fx.used.id)
      receiverUsed(fx.used.id, fx.used.name, fx.used.addr, fx.used.ts)
    }
    if (parsed.kind === "extending" && historic !== true) forgetPendingUnit(unit)
    if (fx.notifyConnected && unit.indexOf("od-sender@") === 0) {
      notify(t("notify.connected").arg(res.entry.name || res.entry.id || ""), Model.connectedNotificationKey(unit, parsed.ts))
    }
    rebuildThrottle.start()
  }

  // ------------------------------------------------------------ actions

  // Over USB when the receiver is plugged in, else over Wi-Fi if allowed.
  function connect(id) {
    if (!Model.isValidId(id)) return false
    var route = Model.connectRoute(id, usbDevices, wifiEnabled)
    if (route === "") { setError("error.notOnUsb"); return false }
    clearError()
    var p = {}
    for (var k in _pending) p[k] = _pending[k]
    p[id.toUpperCase()] = { id: id, since: Date.now(), via: route }
    _pending = p
    rebuild()
    actions.enqueue([route === "usb" ? "connect-usb" : "connect", id], function(code, out, err) {
      if (code !== 0) {
        forgetPending(id)
        handleHelperError(code, out, err)
        rebuild()
      }
      scheduleStatus()
    })
    return true
  }

  function connectAddr(addr) {
    if (!wifiEnabled) { setError("error.wifiOff"); return false }
    var a = String(addr || "").trim()
    if (!Model.isValidAddr(a)) { setError("error.invalidAddr"); return false }
    clearError()
    actions.enqueue(["connect-addr", a], function(code, out, err) {
      if (code !== 0) handleHelperError(code, out, err)
      else {
        var unit = lastLine(out)
        if (Model.isValidUnit(unit)) {
          var pu = {}
          for (var k in _pendingUnits) pu[k] = _pendingUnits[k]
          pu[unit] = Date.now()
          _pendingUnits = pu
          rebuild()
        }
      }
      scheduleStatus()
    })
    return true
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
    if (Model.isValidId(t2)) forgetPending(t2)
    actions.enqueue(["disconnect", t2], function(code, out, err) {
      if (code !== 0) handleHelperError(code, out, err)
      scheduleStatus()
    })
  }

  // Everything running, plus connects that haven't shown up in status yet.
  function disconnectAll() {
    var targets = []
    function add(target) { if (target !== "" && targets.indexOf(target) === -1) targets.push(target) }
    for (var i = 0; i < cards.length; i++) add(targetFor(cards[i]))
    for (var j = 0; j < status.units.length; j++) {
      var u = status.units[j]
      if (!u.template && (u.state === "active" || u.state === "activating")) add(u.unit)
    }
    for (var p in _pending) add(_pending[p].id || p)
    for (var pu in _pendingUnits) add(pu)
    _pending = ({})
    _pendingUnits = ({})
    for (var k = 0; k < targets.length; k++) disconnect(targets[k])
    rebuild()
    return targets.length
  }

  // Bar right-click: stop everything, or reconnect the last receiver. The
  // panel turns the result into a message.
  function toggleLast() {
    if (!installed) return "notinstalled"
    if (cards.length > 0 || connectingNames.length > 0) { disconnectAll(); return "disconnected" }
    var last = Model.lastUsedReceiver(knownReceivers)
    if (!last) return "none"
    // With Wi-Fi off only USB is possible: look at what's plugged in now.
    if (!wifiEnabled) {
      lookups.enqueue(["usb-list"], function(code, out) {
        var r = Model.parseUsbList(out)
        if (r.ok) applyUsb(r.items)
        if (Model.connectRoute(last.id, usbDevices, false) === "usb") connect(last.id)
        else notify(t("error.recentNotOnUsb").arg(last.name), "missing:" + Date.now())
      })
      return "connecting"
    }
    // By id only: it streams the desktop, so never jump to a lookalike name.
    var online = Model.onUsb(usbDevices, last.id)
    for (var i = 0; i < others.length; i++) {
      var o = others[i]
      if (Model.sameId(o.id, last.id) && o.state !== "waiting" && o.state !== "paused") online = true
    }
    if (!online && scanned) return "missing"
    connect(last.id)
    return "connecting"
  }

  function applyUsb(items) {
    if (JSON.stringify(items) === JSON.stringify(usbDevices)) return
    usbDevices = items
    rebuild()
  }

  function cardForId(id) {
    for (var i = 0; i < cards.length; i++) if (Model.sameId(cards[i].id, id)) return cards[i]
    return null
  }

  function restartCard(card) {
    var target = card.unit !== "" ? card.unit : card.id
    if (target === "") return
    actions.enqueue(["restart", target], function(code, out, err) {
      if (code !== 0) handleHelperError(code, out, err)
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
    actions.enqueue(args, function(code, out, err) {
      if (code === 0 || code === 5) {
        if (code === 5) setError("error.cantRun", "", true)
        for (var i = 0; i < restartTargets.length; i++) restartCard(restartTargets[i])
      } else {
        handleHelperError(code, out, err)
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

  function setScale(id, value) {
    var change = Model.scaleChange(config, id, value)
    return setReceiverOption(id, change.key, change.value)
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
    actions.enqueue(["autoconnect", id, on ? "on" : "off"], function(code, out, err) {
      if (code !== 0) handleHelperError(code, out, err)
      scheduleStatus()
    })
  }

  function installOrUpdate() {
    if (installProc.pending || managed === "package") return
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
      var fps = (stats[c.key] || {}).fps
      var link = Model.linkLabel(c.via, (stats[c.key] || {}).transport)
      return "Extending onto " + c.name + " over " + link + (c.state === "reconnecting" ? " (reconnecting)" : (fps >= 0 ? " · " + Model.formatRate(fps) + " fps" : ""))
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
    onTriggered: { root.rebuild(); root.checkDropped(Date.now()) }
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
    // True from start until the result has been delivered, which is later than
    // `running` going false; guards check this instead of `running`.
    property bool pending: false
    function _maybe() {
      if (_code < 0 || !_outDone || !_errDone) return
      var c = _code
      _code = -1
      pending = false
      finished(c, _out, _err)
    }
    onRunningChanged: if (running) { pending = true; _code = -1; _outDone = false; _errDone = false; _out = ""; _err = "" }
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: { job._out = text; job._outDone = true; job._maybe() } }
    stderr: StdioCollector { waitForEnd: true; onStreamFinished: { job._err = text; job._errDone = true; job._maybe() } }
    onExited: function(code) { job._code = code; job._maybe() }
  }

  // Runs helper commands one at a time, in order, so a preset click followed
  // by a restart can't race. `done(exitCode, stdout, stderr)` runs afterwards.
  component HelperQueue: Item {
    id: queue
    property var _queue: []
    property var _current: null
    readonly property bool busy: _current !== null

    function enqueue(args, done) {
      var q = _queue.slice()
      q.push({ command: [root.helperPath].concat(args), done: done || null })
      _queue = q
      _pump()
    }

    function _pump() {
      // _current stays set until its result is handled, which can be a moment
      // after the process itself has exited.
      if (_current !== null || _queue.length === 0) return
      var q = _queue.slice()
      _current = q.shift()
      _queue = q
      proc.command = _current.command
      proc.running = true
    }

    Job {
      id: proc
      onFinished: function(code, out, err) {
        var job = queue._current
        queue._current = null
        if (job && job.done) {
          try { job.done(code, out, err) }
          catch (e) { console.warn("opendisplay", e) }
        }
        Qt.callLater(queue._pump)
      }
    }
  }

  // Mutating commands. Lookups (first-lines, last-error) get their own queue
  // so they never wait behind, or hold up, a connect or a settings write.
  HelperQueue { id: actions }
  HelperQueue { id: lookups }

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
    onFinished: function(code, out) {
      if (code !== 0) return
      var runtime = Quickshell.env("XDG_RUNTIME_DIR") || ""
      if (root.stampPath === "" && runtime !== "") root.stampPath = runtime + "/omarchy-opendisplay/changed"
      root.applyStatus(out)
    }
  }

  Job {
    id: scanProc
    command: [root.helperPath, "list"]
    onFinished: function(code, out) {
      var r = Model.parseList(out)
      var ok = code === 0 && r.ok
      var action = Model.scanErrorAction(ok, root.installed, root.errorKey)
      if (action === "clear") root.clearError()
      else if (action === "set") root.setError("error.scanFailed")
      if (!ok) return
      // Wi-Fi may have been turned off while this scan ran.
      var items = root.wifiEnabled ? r.items : []
      if (JSON.stringify(items) !== JSON.stringify(root.discovered)) root.discovered = items
      root.scanned = true
      root.rebuild()
    }
  }

  Job {
    id: usbProc
    command: [root.helperPath, "usb-list"]
    onFinished: function(code, out) {
      var r = Model.parseUsbList(out)
      if (code === 0 && r.ok) root.applyUsb(r.items)
      if (!root.wifiEnabled) { root.scanned = true; root.rebuild() }
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
        var e = Model.helperError(code)
        root.updateMessage = Model.clampText(e.key !== "" ? root.t(e.key) : root.lastLine(err !== "" ? err : out), 160)
      }
      root.refreshVersion()
      root.scheduleStatus()
    }
  }

  FileView {
    path: root.stampPath
    watchChanges: root.stampPath !== ""
    printErrors: false
    onFileChanged: {
      reload()
      root.scheduleStatus()
      root.refreshConfig()
    }
  }

  ListModel { id: tailModel }

  Instantiator {
    model: tailModel
    delegate: Process {
      required property string unit
      command: [root.helperPath, "logs", unit]
      running: true
      stdout: SplitParser { onRead: function(line) { root.handleLog(unit, line) } }
      Component.onCompleted: root.tailStarted(unit)
      Component.onDestruction: running = false
    }
  }
}
