// Tests for Model.js, the pure half of the widget.
//
//   node tests/run.js
//
// No dependencies. Model.js is a QML `.pragma library` with no module system,
// so it runs in this realm's global scope and the names it adds become the
// module (pattern from yeleticc.vpn/tests/run.js).

const fs = require("fs")
const path = require("path")
const vm = require("vm")
const assert = require("assert")

const root = path.join(__dirname, "..")
const source = fs.readFileSync(path.join(root, "Model.js"), "utf8").replace(/^\s*\.pragma\s+library\s*$/m, "")
const before = new Set(Object.getOwnPropertyNames(globalThis))
vm.runInThisContext(source, { filename: "Model.js" })
const M = {}
for (const name of Object.getOwnPropertyNames(globalThis)) if (!before.has(name)) M[name] = globalThis[name]

const fixture = (name) => fs.readFileSync(path.join(__dirname, "fixtures", name), "utf8")
const eq = assert.deepStrictEqual
const ok = assert.ok

let passed = 0
const failures = []
function test(name, fn) {
  try { fn(); passed++ } catch (error) { failures.push({ name, error }) }
}

const ID = "A0EC2343-F05E-4776-8903-8C62BB114896"
const MARKUP = "<img src=https://example.invalid/x>"

// ------------------------------------------------------------------ identifiers

test("ids must start with hex and be 8-64 hex/dash chars", () => {
  ok(M.isValidId(ID))
  ok(M.isValidId("deadbeef"))
  ok(!M.isValidId("-a0ec2343"))
  ok(!M.isValidId("a0ec234"))
  ok(!M.isValidId("A0EC2343 rm"))
  ok(!M.isValidId("g0ec2343"))
  ok(!M.isValidId("a".repeat(65)))
  ok(!M.isValidId(null))
})

test("addresses are host:port with a valid port and no leading dash", () => {
  ok(M.isValidAddr("10.93.10.226:9000"))
  ok(M.isValidAddr("ipad.local:9000"))
  ok(M.isValidAddr("[fe80::1]:9000"))
  ok(!M.isValidAddr("-oProxy=x:9000"))
  ok(!M.isValidAddr("10.0.0.1:0"))
  ok(!M.isValidAddr("10.0.0.1:65536"))
  ok(!M.isValidAddr("10.0.0.1"))
  ok(!M.isValidAddr("a b:9000"))
})

test("unit and output names for the fixture id", () => {
  eq(M.outputNameForId(ID), "od-a0ec23")
  eq(M.outputNameForId("nope"), "")
  ok(M.isValidUnit("opendisplay-a0ec2343.service"))
  ok(M.isValidUnit("opendisplay-addr-0123abcd.service"))
  ok(M.isValidUnit("od-sender@A0EC2343\\x2dF05E\\x2d4776\\x2d8903\\x2d8C62BB114896.service"))
  ok(!M.isValidUnit("opendisplay-a0ec2343.service; rm"))
  ok(!M.isValidUnit("sshd.service"))
})

// ------------------------------------------------------------------ list

test("parseList reads the real list --json output", () => {
  const r = M.parseList(fixture("list.json"))
  eq(r.ok, true)
  eq(r.items, [{ id: ID, name: "iPad", addr: "10.93.10.226:9000", pv: 3 }])
  eq(M.parseList(fixture("list-empty.json")), { ok: true, items: [] })
})

test("parseList rejects malformed JSON and bad entries", () => {
  eq(M.parseList("not json").ok, false)
  eq(M.parseList("{}").ok, false)
  const r = M.parseList(JSON.stringify([
    { name: "bad id", addr: "1.2.3.4:9000", id: "-x", pv: 3 },
    { name: "bad addr", addr: "nope", id: "deadbeef", pv: 3 },
    { name: "ok", addr: "1.2.3.4:9000", id: "deadbeef", pv: 2.5 },
    { name: "dupe", addr: "1.2.3.4:9000", id: "DEADBEEF", pv: 3 }
  ]))
  eq(r.items.length, 1)
  eq(r.items[0].pv, 0)
})

test("parseList bounds count and name length, strips controls, keeps markup as text", () => {
  const many = []
  for (let i = 0; i < 50; i++) many.push({ name: "n" + i, addr: "1.2.3.4:9000", id: "deadbe" + String(i).padStart(2, "0"), pv: 3 })
  eq(M.parseList(JSON.stringify(many)).items.length, 32)
  const r = M.parseList(JSON.stringify([
    { name: "x".repeat(200), addr: "1.2.3.4:9000", id: "deadbeef", pv: 3 },
    { name: "a\u0000b\u001bc‮", addr: "1.2.3.4:9000", id: "deadbee0", pv: 3 },
    { name: MARKUP, addr: "1.2.3.4:9000", id: "deadbee1", pv: 3 }
  ]))
  eq(r.items[0].name.length, 64)
  eq(r.items[1].name, "abc")
  eq(r.items[2].name, MARKUP)
})

// ------------------------------------------------------------------ status

test("parseStatus validates every field", () => {
  const s = M.parseStatus(JSON.stringify({
    sessions: [
      { output: "od-a0ec23", pid: 42, unit: "opendisplay-a0ec2343.service", id: ID, to: ID, since: 5 },
      { output: "../etc", pid: 1, unit: null, id: null },
      { output: "od-123456", pid: 7, unit: "evil.service", id: "--wait", to: MARKUP }
    ],
    units: [
      { unit: "opendisplay-a0ec2343.service", state: "active", template: false, id: null, to: "iPad", status: 0, since: 5 },
      { unit: "opendisplay-deadbeef.service", state: "inactive" },
      { unit: "od-sender@x.service", state: "failed", template: true, id: null, to: "x", status: 3 }
    ],
    autoconnect: [ID, "nope"],
    templateInstalled: true
  }))
  eq(s.ok, true)
  eq(s.sessions.length, 2)
  eq(s.sessions[1].unit, "")
  eq(s.sessions[1].id, "")
  eq(s.sessions[1].to, MARKUP)
  eq(s.units.map(u => u.state), ["active", "failed"])
  eq(s.units[1].status, 3)
  eq(s.autoconnect, [ID])
  eq(M.parseStatus("garbage").ok, false)
})

// ------------------------------------------------------------------ log lines

test("parses every kind of log line from a real session", () => {
  const kinds = {}
  for (const line of fixture("session.log").split("\n")) {
    if (!line) continue
    const r = M.parseLogLine(line)
    kinds[r.kind] = (kinds[r.kind] || []).concat([r])
  }
  eq(kinds.connected[0].addr, "10.93.10.226:9000")
  eq(kinds.hello[0].name, "iPad")
  eq(kinds.hello[0].id, ID)
  eq(kinds.extending[0].name, "iPad")
  eq(kinds.extending[0].id, ID)
  eq(kinds.phone[0].e2e50, 17)
  eq(kinds.phone[0].transport, "WiFi")
  const last = kinds.sent[kinds.sent.length - 1]
  eq([last.fps, last.mbps], [58.6, 1.4])
  ok(kinds.sent.every(s => typeof s.fps === "number" && typeof s.mbps === "number"))
  eq(kinds.ended.length, 2)
  eq(kinds.warn.length, 1)
  ok(kinds.hello[0].ts > 0)
})

test("spec example lines parse", () => {
  eq(M.parseLogLine("2026-11-09T12:38:24.894087Z  INFO sent 58.6 fps 1.4 Mbit/s | encode p50 8.7 ms").fps, 58.6)
  const p = M.parseLogLine('2026-11-09T12:38:24.894087Z  INFO PHONE-STATS {"e2e50":17,"e2e95":24,"fps":58,"mbps":3.2,"rtt":5,"stalls":0,"transport":"WiFi"}')
  eq([p.kind, p.e2e50, p.transport], ["phone", 17, "WiFi"])
  eq(M.parseLogLine("2026-11-09T12:00:00.000000Z  INFO connection ended").kind, "ended")
  eq(M.parseLogLine("Started OpenDisplay to iPad.").kind, "other")
})

test("errors are bounded plain text, markup untouched", () => {
  const lines = fixture("errors.log").split("\n").filter(Boolean).map(M.parseLogLine)
  eq(lines[0].kind, "error")
  ok(lines[0].text.startsWith('no receiver matching "Nope"'))
  eq(lines[1].text, MARKUP + " & <b>bold</b>")
  const long = M.parseLogLine("2026-11-09T12:00:00.000000Z ERROR " + "e".repeat(500))
  eq(long.text.length, 160)
})

test("malformed PHONE-STATS and over-long lines are ignored", () => {
  eq(M.parseLogLine("2026-11-09T12:00:00.000000Z  INFO PHONE-STATS {nope").kind, "other")
  eq(M.parseLogLine("2026-11-09T12:00:00.000000Z  INFO sent " + "1".repeat(5000)), null)
  const big = M.parseLogLine('2026-11-09T12:00:00.000000Z  INFO PHONE-STATS {"e2e50":"x","transport":"' + "T".repeat(100) + '"}')
  eq(big.e2e50, -1)
  eq(big.transport.length, 16)
})

test("hello with a markup device name stays plain", () => {
  const r = M.parseLogLine('2026-11-09T12:00:00.000000Z  INFO hello: 1x1 @60 scale 2 device Some("' + MARKUP + '") id Some("' + ID + '") pv 3')
  eq(r.name, MARKUP)
  eq(r.id, ID)
  const none = M.parseLogLine("2026-11-09T12:00:00.000000Z  INFO hello: 1x1 @60 scale 2 device None id None pv 3")
  eq([none.kind, none.name, none.id], ["hello", "", ""])
})

test("transport labels", () => {
  eq(M.transportLabel("WiFi"), "Wi-Fi")
  eq(M.transportLabel("usb"), "USB")
  eq(M.transportLabel("Tailscale"), "Tailscale")
  eq(M.transportLabel("x".repeat(40)).length, 12)
})

// ------------------------------------------------------------------ versions

test("compareVersions is numeric", () => {
  eq(M.compareVersions("1.30.2", "1.31.0"), -1)
  eq(M.compareVersions("1.31.0", "1.100.0"), -1)
  eq(M.compareVersions("v1.100.0", "1.31.0"), 1)
  eq(M.compareVersions("1.30.2", "v1.30.2"), 0)
})

test("version and update info are validated", () => {
  eq(M.parseVersionInfo('{"installed":true,"version":"1.30.2","path":"/x","managed":"user"}').installed, true)
  eq(M.parseVersionInfo('{"installed":false}').installed, false)
  eq(M.parseVersionInfo('{"installed":true,"version":"1.30.2","managed":"root"}').managed, "other")
  const u = M.parseUpdateInfo('{"latest":"1.31.0","newer":true,"htmlUrl":"https://evil.example/x"}')
  eq([u.ok, u.latest, u.newer], [true, "1.31.0", true])
  eq(u.htmlUrl, "https://github.com/peetzweg/opendisplay/releases/latest")
  eq(M.parseUpdateInfo("nope").ok, false)
})

// ------------------------------------------------------------------ presets + settings

test("preset mapping and effective bitrate", () => {
  eq(M.presetForBitrate(35), "sharp")
  eq(M.presetForBitrate(20), "balanced")
  eq(M.presetForBitrate(8), "light")
  eq(M.presetForBitrate(12), "")
  eq(M.effectiveBitrate({}, ID), 20)
  eq(M.effectiveBitrate({ "bitrate-mbps": 30 }, ID), 30)
  eq(M.effectiveBitrate({ "bitrate-mbps": 30, receiver: { ["a0ec2343-f05e-4776-8903-8c62bb114896"]: { "bitrate-mbps": 8 } } }, ID), 8)
})

test("Balanced deletes the key only when the fallback is already 20", () => {
  eq(M.presetChange({}, "balanced"), { key: "bitrate-mbps", value: "" })
  eq(M.presetChange({ "bitrate-mbps": 30 }, "balanced"), { key: "bitrate-mbps", value: "20" })
  eq(M.presetChange({}, "sharp"), { key: "bitrate-mbps", value: "35" })
  eq(M.presetChange({}, "nope"), null)
})

test("validateSetting mirrors the helper's rules", () => {
  eq(M.validateSetting("bitrate-mbps", 35, "receiver"), { ok: true, value: "35" })
  eq(M.validateSetting("bitrate-mbps", 201, "receiver").ok, false)
  eq(M.validateSetting("bitrate-mbps", "2.5", "receiver").ok, false)
  eq(M.validateSetting("scale", "1.5", "receiver").value, "1.5")
  eq(M.validateSetting("scale", "1.3", "receiver").ok, false)
  eq(M.validateSetting("scale", "mac", "receiver").ok, true)
  eq(M.validateSetting("max-fps", 240, "global").ok, true)
  eq(M.validateSetting("max-fps", 0, "global").ok, false)
  eq(M.validateSetting("encoder", "openh264", "global").ok, true)
  eq(M.validateSetting("encoder", "nvenc", "global").ok, false)
  eq(M.validateSetting("cursor", "off", "global").ok, true)
  eq(M.validateSetting("tailscale", false, "global").value, "false")
  eq(M.validateSetting("position", "auto-right", "global").ok, false)
  eq(M.validateSetting("workspace", "8", "global").ok, false)
  eq(M.validateSetting("max-fps", 60, "receiver").ok, false)
  eq(M.validateSetting("bitrate-mbps", "", "receiver"), { ok: true, value: "" })
})

// ------------------------------------------------------------------ known + merge

test("known receivers: remember, bound, most recent", () => {
  let known = []
  for (let i = 0; i < 20; i++) known = M.rememberReceiver(known, "deadbe" + String(i).padStart(2, "0"), "n" + i, "1.2.3.4:9000", 1000 + i)
  eq(known.length, 16)
  eq(known[0].name, "n19")
  known = M.rememberReceiver(known, "deadbe05", "", "", 5000)
  eq(known[0].name, "n5")
  eq(known[0].lastAddr, "1.2.3.4:9000")
  eq(M.lastUsedReceiver(known).id, "deadbe05")
  eq(M.sanitizeKnown([{ id: "-x" }, { id: ID, name: MARKUP }]), [{ id: ID, name: MARKUP, lastAddr: "", lastUsed: 0 }])
})

test("relativeDays", () => {
  const now = Date.UTC(2026, 10, 9)
  eq(M.relativeDays(now - 2 * 86400000 - 5, now), 2)
  eq(M.relativeDays(now - 1000, now), 0)
  eq(M.relativeDays(0, now), -1)
  eq(M.relativeDays(now + 5000, now), 0)
})

test("mergeReceivers: discovered + known + auto-connect + external session", () => {
  const PIXEL = "BEEF0000-0000-0000-0000-000000000001"
  const MAC = "CAFE0000-0000-0000-0000-000000000002"
  const now = Date.UTC(2026, 10, 9)
  const discovered = [
    { id: ID, name: "iPad", addr: "10.0.0.2:9000", pv: 3 },
    { id: PIXEL, name: "Pixel 8", addr: "10.0.0.3:9000", pv: 3 },
    { id: PIXEL, name: "Pixel dupe", addr: "10.0.0.3:9000", pv: 3 }
  ]
  const known = [
    { id: PIXEL, name: "Pixel 8", lastAddr: "10.0.0.3:9000", lastUsed: now - 2 * 86400000 },
    { id: MAC, name: "Mac", lastAddr: "10.0.0.4:9000", lastUsed: now - 86400000 },
    { id: "DDDD0000-0000", name: "Old", lastAddr: "", lastUsed: 1 }
  ]
  const sessions = [{ key: "od-a0ec23", id: ID, name: "", output: "od-a0ec23", unit: "", external: true, state: "live" }]
  const r = M.mergeReceivers(discovered, known, sessions, [MAC], now)
  eq(r.cards.length, 1)
  eq(r.cards[0].name, "iPad")
  eq(r.cards[0].external, true)
  eq(r.others.map(o => [o.name, o.state, o.lastUsedDays]), [["Pixel 8", "idle", 2], ["Mac", "paused", 1]])
})

test("mergeReceivers: connecting rows, including connect-by-IP without an id", () => {
  const discovered = [{ id: ID, name: "iPad", addr: "10.0.0.2:9000", pv: 3 }]
  const sessions = [
    { key: "opendisplay-a0ec2343.service", id: ID, unit: "opendisplay-a0ec2343.service", state: "connecting" },
    { key: "opendisplay-addr-01234567.service", id: "", to: "10.0.0.9:9000", unit: "opendisplay-addr-01234567.service", state: "connecting" }
  ]
  const r = M.mergeReceivers(discovered, [], sessions, [], 0)
  eq(r.cards.length, 0)
  eq(r.others.map(o => [o.name, o.state]), [["10.0.0.9:9000", "connecting"], ["iPad", "connecting"]])
})

test("idForOutput matches discovered first, refuses ambiguity", () => {
  const d = [{ id: ID }]
  eq(M.idForOutput("od-a0ec23", d, []), ID)
  eq(M.idForOutput("od-a0ec23", [{ id: ID }, { id: "A0EC2399-0000" }], []), "")
  eq(M.idForOutput("od-a0ec23", [], [{ id: ID, name: "iPad" }]), ID)
})

test("resolveTarget connects by id, or by a unique name only", () => {
  const rows = [{ id: ID, name: "iPad" }, { id: "BEEF0000-1", name: "Phone" }, { id: "CAFE0000-1", name: "Phone" }]
  eq(M.resolveTarget(ID.toLowerCase(), rows), { id: ID, error: "" })
  eq(M.resolveTarget("iPad", rows), { id: ID, error: "" })
  eq(M.resolveTarget("Phone", rows).error, "ambiguous")
  eq(M.resolveTarget("Nope", rows).error, "notfound")
  eq(M.resolveTarget(MARKUP, rows).error, "notfound")
})


// ------------------------------------------------------------------ shared corpus

test("shared validation corpus", () => {
  const c = JSON.parse(fixture("validation.json"))
  for (const v of c.ids.valid) ok(M.isValidId(v), "id should be valid: " + v)
  for (const v of c.ids.invalid) ok(!M.isValidId(v), "id should be invalid: " + v)
  for (const v of c.addrs.valid) ok(M.isValidAddr(v), "addr should be valid: " + v)
  for (const v of c.addrs.invalid) ok(!M.isValidAddr(v), "addr should be invalid: " + v)
  ok(c.settings.length > 0)
  for (const s of c.settings) {
    eq(M.validateSetting(s.key, s.value, s.scope).ok, s.ok, s.scope + " " + s.key + "=" + JSON.stringify(s.value))
  }
})

// ------------------------------------------------------------------ new logic

const U1 = "opendisplay-a0ec2343.service"
const T1 = "od-sender@" + ID.replace(/-/g, "\\x2d") + ".service"
const clone = (v) => JSON.parse(JSON.stringify(v))
const mkSession = (o) => Object.assign({ output: "od-a0ec23", pid: 1, unit: "", id: "", to: "", since: 0 }, o)
const mkUnit = (o) => Object.assign({ unit: U1, state: "active", template: false, id: "", to: "", status: 0, since: 0 }, o)
const mkStatus = (o) => Object.assign({ ok: true, sessions: [], units: [], autoconnect: [], templateInstalled: true }, o)

test("PRESET_NAMES derives from PRESETS", () => {
  eq(M.PRESET_NAMES, ["sharp", "balanced", "light"])
})

test("buildSessions: live, reconnecting, connecting, waiting, pending, external id", () => {
  const now = 1000000
  const status = mkStatus({
    sessions: [
      mkSession({ unit: U1, id: ID }),
      mkSession({ unit: T1, output: "od-beef00", id: "BEEF0000-0000-0000-0000-000000000001" }),
      mkSession({ output: "od-cafe00" })
    ],
    units: [
      mkUnit({ unit: "opendisplay-11111111.service", state: "activating", to: "x" }),
      mkUnit({ unit: "od-sender@DDDD0000.service", template: true, id: "DDDD0000-0000" }),
      mkUnit({ unit: "opendisplay-22222222.service", state: "failed" }),
      mkUnit({ unit: "opendisplay-33333333.service", state: "deactivating" }),
      mkUnit({ unit: U1 })
    ]
  })
  const live = {
    [U1]: { tailStartMs: now - 60000, lastLogMs: now - 1000, name: "iPad", fps: 58, mbps: 1.4, latency: 17, transport: "WiFi" },
    [T1]: { tailStartMs: now - 60000, lastLogMs: now - 20000 }
  }
  const pending = {
    [ID.toUpperCase()]: { id: ID, since: now },
    "AAAA0000-0000": { id: "aaaa0000-0000", since: now }
  }
  const discovered = [{ id: "CAFE0000-0000-0000-0000-000000000009", name: "Mac", addr: "1.2.3.4:9000" }]
  const known = []
  const snap = clone([status, live, pending, discovered, known])
  const r = M.buildSessions(status, live, pending, discovered, known, now)
  eq(clone([status, live, pending, discovered, known]), snap)

  eq(r[0], { key: U1, id: ID, unit: U1, output: "od-a0ec23", pid: 1, to: "", external: false, template: false,
    name: "iPad", state: "live", fps: 58, mbps: 1.4, latency: 17, transport: "WiFi" })
  eq(r[1].state, "reconnecting")
  eq(r[1].template, true)
  eq([r[1].fps, r[1].transport], [-1, ""])
  eq([r[2].key, r[2].external, r[2].state, r[2].id], ["od-cafe00", true, "live", "CAFE0000-0000-0000-0000-000000000009"])
  eq(r[3].state, "connecting")
  eq(r[3].fps, -1)
  eq([r[4].state, r[4].template, r[4].id], ["waiting", true, "DDDD0000-0000"])
  eq(r.length, 6)
  eq(r[5], { key: "pending:AAAA0000-0000", id: "aaaa0000-0000", unit: "", output: "", to: "", external: false,
    template: false, name: "", state: "connecting", fps: -1, mbps: -1, latency: -1, transport: "" })
})

test("buildSessions: pending covered by a session (case-insensitive) is not added", () => {
  const status = mkStatus({ sessions: [mkSession({ unit: U1, id: ID })] })
  const r = M.buildSessions(status, {}, { [ID.toUpperCase()]: { id: ID.toLowerCase(), since: 0 } }, [], [], 0)
  eq(r.length, 1)
})

test("reconcilePending: a live session or an auto-connect template resolves; a running transient unit is still connecting", () => {
  const now = 100000
  const pending = {
    [ID]: { id: ID, since: now },
    "BEEF0000-0000": { id: "BEEF0000-0000", since: now },
    "CAFE0000-0000": { id: "CAFE0000-0000", since: now },
    "DDDD0000-0000": { id: "DDDD0000-0000", since: now }
  }
  const status = mkStatus({
    sessions: [mkSession({ id: ID })],
    units: [
      mkUnit({ id: "beef0000-0000", state: "activating" }),
      mkUnit({ unit: "od-sender@DDDD0000\\x2d0000.service", id: "DDDD0000-0000", state: "active", template: true })
    ]
  })
  const snap = clone([pending, status])
  const r = M.reconcilePending(pending, {}, status, now)
  eq(clone([pending, status]), snap)
  eq(Object.keys(r.pending).sort(), ["BEEF0000-0000", "CAFE0000-0000"])
  eq(r.failures, [])
})

test("reconcilePending: a connect that runs, then fails, is reported (regression)", () => {
  const click = 500000
  let pending = { [ID]: { id: ID, since: click } }
  let r = M.reconcilePending(pending, {}, mkStatus({ units: [mkUnit({ id: ID, state: "active", since: click / 1000 })] }), click + 5000)
  eq(Object.keys(r.pending), [ID])
  r = M.reconcilePending(r.pending, {}, mkStatus({ units: [mkUnit({ id: ID, state: "failed", status: 3, since: click / 1000 })] }), click + 11000)
  eq(r.failures, [{ unit: U1, status: 3, id: ID }])
  // Still running long after the click: not dropped by the 30 s timeout.
  r = M.reconcilePending(pending, {}, mkStatus({ units: [mkUnit({ id: ID, state: "active", since: click / 1000 })] }), click + 60000)
  eq(Object.keys(r.pending), [ID])
})

test("reconcilePending: fresh failure reported, stale failure ignored", () => {
  const click = 500000
  const pending = { [ID]: { id: ID, since: click } }
  const fresh = mkStatus({ units: [mkUnit({ id: ID, state: "failed", status: 3, since: click / 1000 })] })
  const r = M.reconcilePending(pending, {}, fresh, click + 2000)
  eq(r.failures, [{ unit: U1, status: 3, id: ID }])
  eq(r.pending, {})
  const stale = mkStatus({ units: [mkUnit({ id: ID, state: "failed", status: 3, since: click / 1000 - 60 })] })
  const r2 = M.reconcilePending(pending, {}, stale, click + 2000)
  eq(r2.failures, [])
  eq(Object.keys(r2.pending), [ID])
})

test("reconcilePending: pendingUnits resolve, fail, stale, and time out", () => {
  const click = 500000
  const mk = (u) => mkStatus({ units: [u] })
  let r = M.reconcilePending({}, { [U1]: click }, mk(mkUnit({ id: ID, state: "failed", status: 6, since: click / 1000 })), click + 1000)
  eq(r.failures, [{ unit: U1, status: 6, id: ID }])
  eq(r.pendingUnits, {})
  r = M.reconcilePending({}, { [U1]: click }, mk(mkUnit({ state: "failed", since: 1 })), click + 1000)
  eq(r.failures, [])
  eq(r.pendingUnits, { [U1]: click })
  // Running is still connecting, even past the timeout.
  r = M.reconcilePending({}, { [U1]: click }, mk(mkUnit({ state: "active" })), click + 40000)
  eq(r.pendingUnits, { [U1]: click })
  r = M.reconcilePending({}, { [U1]: click }, mkStatus({ sessions: [mkSession({ unit: U1 })] }), click + 1000)
  eq(r.pendingUnits, {})
  const units = { [U1]: click }
  r = M.reconcilePending({}, units, mkStatus(), click + 31000)
  eq(r.pendingUnits, {})
  eq(units, { [U1]: click })
})

test("reconcilePending: nothing matching drops after 30 s only", () => {
  const pending = { [ID]: { id: ID, since: 1000 } }
  eq(Object.keys(M.reconcilePending(pending, {}, mkStatus(), 31000).pending), [ID])
  eq(M.reconcilePending(pending, {}, mkStatus(), 31001).pending, {})
  eq(pending, { [ID]: { id: ID, since: 1000 } })
})

const line = (rest) => M.parseLogLine("2026-11-09T12:00:00.000Z  INFO " + rest)
const TS = Date.parse("2026-11-09T12:00:00.000Z")

test("reduceLive: stats, phone, hello, ended, error", () => {
  const e0 = { tailStartMs: 1 }
  let r = M.reduceLive(e0, line("sent 58.6 fps 1.4 Mbit/s"), 500, { historic: false, tailStartMs: 1 })
  eq([r.entry.fps, r.entry.mbps, r.entry.lastLogMs, r.entry.lastLogTs], [58.6, 1.4, 500, TS])
  eq(e0, { tailStartMs: 1 })
  eq(r.effects, { needStatus: false, used: null, notifyConnected: false })
  r = M.reduceLive(r.entry, line('PHONE-STATS {"e2e50":17,"transport":"WiFi"}'), 600, { historic: false })
  eq([r.entry.latency, r.entry.transport], [17, "WiFi"])
  r = M.reduceLive(r.entry, line('PHONE-STATS {"e2e50":-5,"transport":""}'), 700, { historic: false })
  eq([r.entry.latency, r.entry.transport], [17, "WiFi"])
  r = M.reduceLive(undefined, line('hello: 1x1 @60 scale 2 device Some("iPad") id Some("' + ID + '") pv 3'), 800, { historic: false })
  eq([r.entry.name, r.entry.id], ["iPad", ID])
  r = M.reduceLive(r.entry, line("connection ended"), 900, { historic: false })
  eq(r.effects.needStatus, true)
  r = M.reduceLive(r.entry, M.parseLogLine("2026-11-09T12:00:00.000Z ERROR boom"), 900, { historic: false })
  eq(r.entry.lastError, "boom")
})

test("reduceLive: connected clears stats and wants status", () => {
  const e = { fps: 1, mbps: 2, latency: 3, transport: "USB" }
  const r = M.reduceLive(e, line("connected to receiver 10.0.0.2:9000"), 10, { historic: false })
  eq(r.entry.addr, "10.0.0.2:9000")
  ok(!("fps" in r.entry) && !("mbps" in r.entry) && !("latency" in r.entry))
  eq(r.entry.transport, "USB")
  eq(r.effects.needStatus, true)
  eq(e.fps, 1)
})

test("reduceLive: extending notifies only for lines written after the tail started", () => {
  const ext = line("Extending onto iPad (" + ID + "):")
  const base = { addr: "1.2.3.4:9000" }
  let r = M.reduceLive(base, ext, 99, { historic: false, tailStartMs: TS - 1000 })
  eq(r.effects.notifyConnected, true)
  eq(r.effects.needStatus, true)
  eq(r.effects.used, { id: ID, name: "iPad", addr: "1.2.3.4:9000", ts: TS })
  r = M.reduceLive(base, ext, 99, { historic: false, tailStartMs: TS + 2000 })
  eq(r.effects.notifyConnected, true)
  r = M.reduceLive(base, ext, 99, { historic: false, tailStartMs: TS + 5000 })
  eq(r.effects.notifyConnected, false)
  r = M.reduceLive(base, ext, 99, { historic: false, tailStartMs: TS + 2001 })
  eq(r.effects.notifyConnected, false)
})

test("reduceLive: historic is identity only", () => {
  const ext = line("Extending onto iPad (" + ID + "):")
  const r = M.reduceLive({ lastLogMs: 5, lastLogTs: 6, fps: 9 }, ext, 99, { historic: true, tailStartMs: 0 })
  eq([r.entry.lastLogMs, r.entry.lastLogTs, r.entry.fps], [5, 6, 9])
  eq([r.entry.name, r.entry.id], ["iPad", ID])
  eq(r.effects.notifyConnected, false)
  eq(r.effects.needStatus, false)
  eq(r.effects.used.ts, TS)
  const c = M.reduceLive({ addr: "keep" }, line("connected to receiver 10.0.0.2:9000"), 1, { historic: true })
  eq(c.entry.addr, "keep")
  const h = M.reduceLive({ name: "old" }, line('hello: 1x1 @60 scale 2 device Some("New") id Some("' + ID + '") pv 3'), 1, { historic: true })
  eq([h.entry.name, h.entry.id, h.entry.lastLogMs], ["old", ID, undefined])
  eq(M.reduceLive({}, M.parseLogLine("Started"), 7, { historic: true }).effects.used, null)
})

test("notification keys dedupe by journal timestamp, not local clock", () => {
  eq(M.droppedNotificationKey(T1, { lastLogMs: 1, lastLogTs: 77 }), M.droppedNotificationKey(T1, { lastLogMs: 999, lastLogTs: 77 }))
  eq(M.droppedNotificationKey(T1, undefined), "dropped:" + T1 + ":0")
  eq(M.connectedNotificationKey(T1, 5), "connected:" + T1 + ":5")
})

test("signatures ignore stats but track structure", () => {
  const card = { key: "k", id: ID, name: "iPad", state: "live", autoConnect: false, external: false, template: true, unit: T1, output: "o", fps: 1, mbps: 1, latency: 1, transport: "USB" }
  const same = Object.assign({}, card, { fps: 60, mbps: 9, latency: 30, transport: "WiFi" })
  eq(M.cardsSignature([card]), M.cardsSignature([same]))
  ok(M.cardsSignature([card]) !== M.cardsSignature([Object.assign({}, card, { state: "reconnecting" })]))
  const other = { key: "k", id: ID, name: "n", addr: "a", state: "idle", autoConnect: false, lastUsedDays: 1, unit: "", fps: 1 }
  eq(M.othersSignature([other]), M.othersSignature([Object.assign({}, other, { fps: 2 })]))
  ok(M.othersSignature([other]) !== M.othersSignature([Object.assign({}, other, { state: "paused" })]))
  ok(M.othersSignature([other]) !== M.othersSignature([Object.assign({}, other, { lastUsedDays: 2 })]))
})

test("scaleChange passthrough depends on the top-level scale", () => {
  eq(M.scaleChange({}, ID, "passthrough"), { key: "scale", value: "" })
  eq(M.scaleChange({ scale: "passthrough" }, ID, "passthrough"), { key: "scale", value: "" })
  eq(M.scaleChange({ scale: 2 }, ID, "passthrough"), { key: "scale", value: "passthrough" })
  eq(M.scaleChange({ scale: 2 }, ID, "1.5"), { key: "scale", value: "1.5" })
  eq(M.scaleChange({}, ID, 2), { key: "scale", value: "2" })
})

test("helperError maps exit codes to i18n keys", () => {
  const want = { 2: ["error.invalidValue", false], 5: ["error.cantRun", true], 6: ["error.rejected", true], 7: ["error.autoConnectUnit", false],
    8: ["error.notInstalled", false], 9: ["error.externalSender", false], 10: ["error.packageManaged", false], 11: ["error.offline", false] }
  for (const code of Object.keys(want)) eq(M.helperError(Number(code)), { key: want[code][0], doctor: want[code][1] })
  eq(M.helperError(1), { key: "", doctor: false })
  eq(M.helperError(undefined), { key: "", doctor: false })
})

test("shouldRemember skips only an up-to-date entry", () => {
  const known = [{ id: ID, name: "iPad", lastAddr: "", lastUsed: 100 }]
  eq(M.shouldRemember(known, ID, "iPad", 100), false)
  eq(M.shouldRemember(known, ID, "", 50), false)
  eq(M.shouldRemember(known, ID, "iPad", 101), true)
  eq(M.shouldRemember(known, ID, "Renamed", 100), true)
  eq(M.shouldRemember(known, "deadbeef", "x", 1), true)
  eq(M.shouldRemember([], ID, "", 0), true)
})

test("mergeReceivers: auto-connect offline is paused unless a waiting session exists", () => {
  const MAC = "CAFE0000-0000-0000-0000-000000000002"
  const r = M.mergeReceivers([], [], [], [MAC], 0)
  eq(r.others.map(o => [o.state, o.autoConnect]), [["paused", true]])
  const w = M.mergeReceivers([], [], [{ key: T1, id: MAC, unit: T1, state: "waiting" }], [MAC], 0)
  eq(w.others.map(o => [o.state, o.autoConnect]), [["waiting", true]])
  const online = M.mergeReceivers([{ id: MAC, name: "Mac", addr: "1.2.3.4:9000" }], [], [], [MAC], 0)
  eq(online.others[0].state, "idle")
  eq(online.others[0].autoConnect, true)
})

// ------------------------------------------------------------------ sinks

test("notification bodies escape markup; everything else stays raw", () => {
  eq(M.escapeMarkup(MARKUP + " & more"), "&lt;img src=https://example.invalid/x&gt; &amp; more")
  eq(M.clampText(MARKUP, 64), MARKUP)
})

function textBlocks(src) {
  // Returns { line, body } for each Text block; body has nested blocks removed.
  const lines = src.split("\n")
  const out = []
  for (let i = 0; i < lines.length; i++) {
    if (!/^\s*(component\s+\w+\s*:\s*)?Text\s*\{/.test(lines[i])) continue
    let depth = 0
    let own = ""
    for (let j = i; j < lines.length; j++) {
      const text = j === i ? lines[i].slice(lines[i].indexOf("Text")) : lines[j]
      const code = text.replace(/"(?:[^"\\]|\\.)*"/g, '""').replace(/\/\/.*$/, "")
      for (const ch of code) {
        if (ch === "{") depth++
        else if (ch === "}") depth--
        else if (depth === 1) own += ch
      }
      if (depth === 1) own += "\n"
      if (depth <= 0) break
    }
    out.push({ line: i + 1, body: own })
  }
  return out
}

test("QML sinks: every Text block sets PlainText at its own top level", () => {
  for (const file of fs.readdirSync(root).filter(f => f.endsWith(".qml"))) {
    const src = fs.readFileSync(path.join(root, file), "utf8")
    for (const b of textBlocks(src)) {
      ok(/textFormat:\s*Text\.PlainText/.test(b.body), file + ":" + b.line + " Text block lacks textFormat: Text.PlainText")
    }
    ok(!/Text\.(RichText|StyledText|AutoText|MarkdownText)/.test(src), file + " uses a rich text format")
  }
})

test("textBlocks ignores PlainText set only in a nested child", () => {
  const bad = "Text {\n  Text {\n    textFormat: Text.PlainText\n  }\n}\n"
  const good = "Text {\n  textFormat: Text.PlainText\n  Text {\n    x: 1\n  }\n}\n"
  ok(!/Text\.PlainText/.test(textBlocks(bad)[0].body))
  ok(/Text\.PlainText/.test(textBlocks(good)[0].body))
})

test("rate formatting", () => {
  eq(M.formatRate(58.6), "59")
  eq(M.formatRate(1.44), "1.4")
  eq(M.formatRate(0), "0")
  eq(M.formatRate(-1), "")
})

test("connect exit codes", () => {
  eq(M.connectErrorKind(3), "notFound")
  eq(M.connectErrorKind(2), "badConfig")
  eq(M.connectErrorKind(1), "other")
})

// ------------------------------------------------------------------ i18n catalog

test("i18n/en.json parses and plural entries have one/other", () => {
  const cat = JSON.parse(fs.readFileSync(path.join(root, "i18n", "en.json"), "utf8"))
  for (const [k, v] of Object.entries(cat)) {
    if (typeof v === "object") ok(v.one && v.other, k)
    else ok(typeof v === "string", k)
  }
  // Every key used in QML exists.
  for (const file of fs.readdirSync(root).filter(f => f.endsWith(".qml"))) {
    const src = fs.readFileSync(path.join(root, file), "utf8")
    for (const m of src.matchAll(/strings\.tn?\("([^"]+)"\s*[,)]/g)) ok(m[1] in cat, file + " uses missing key " + m[1])
  }
})

for (const f of failures) {
  console.error("FAIL " + f.name)
  console.error("  " + String(f.error && f.error.stack || f.error).split("\n").slice(0, 6).join("\n  "))
}
console.log(passed + " passed, " + failures.length + " failed")
process.exit(failures.length ? 1 : 0)
