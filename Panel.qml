import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// OpenDisplay bar widget: bar button + keyboard panel. All state and
// processes live in Service.qml; this file is UI only.
Panel {
  id: root
  moduleName: "io.github.muneebabbas.opendisplay"
  ipcTarget: "io.github.muneebabbas.opendisplay"
  manageIpc: false

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  readonly property Item panelFlick: panel.loadedContent ? panel.loadedContent.panelFlick : null

  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color urgent: bar ? bar.urgent : Commons.Color.urgent
  readonly property color accent: Commons.Color.accent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property bool showNameInBar: setting("showNameInBar", true) !== false
  readonly property var knownReceivers: Model.sanitizeKnown(setting("knownReceivers", []))

  // --- derived display state
  readonly property var cards: od.cards
  readonly property var others: od.others
  readonly property bool connected: cards.length > 0
  readonly property bool connecting: od.connectingNames.length > 0
  readonly property bool reconnecting: {
    for (var i = 0; i < cards.length; i++) if (cards[i].state === "reconnecting") return true
    return false
  }
  readonly property bool pulsing: (connecting && !connected) || reconnecting
  readonly property bool showEmpty: od.installed && cards.length === 0 && others.length === 0
  readonly property var barLabelInfo: Model.barLabel({ showName: showNameInBar, cards: cards, connectingNames: od.connectingNames })
  readonly property string barLabel: barLabelInfo.kind === "name" ? barLabelInfo.text
    : (barLabelInfo.kind === "count" ? strings.tn("bar.count", barLabelInfo.count).arg(Commons.I18n.formatNumber(barLabelInfo.count)) : "")

  readonly property string heroMeta: {
    if (!od.versionKnown) return ""
    if (!od.installed) return strings.t("meta.notConnected")
    if (cards.length > 1) return strings.tn("meta.extendingCount", cards.length).arg(Commons.I18n.formatNumber(cards.length))
    if (cards.length === 1) return strings.t("meta.extending").arg(cards[0].name)
    if (connecting) return strings.t("meta.connecting").arg(od.connectingNames[0])
    return strings.t("meta.notConnected")
  }

  readonly property string barTooltip: {
    if (!od.installed) return strings.t("bar.tooltipNotInstalled")
    if (cards.length > 1) return strings.tn("bar.tooltipCount", cards.length).arg(Commons.I18n.formatNumber(cards.length))
    if (cards.length === 1) {
      var c = cards[0]
      var fps = statsFor(c.key).fps
      if (fps >= 0) return strings.t("bar.tooltipLive").arg(c.name).arg(Commons.I18n.formatNumber(Number(Model.formatRate(fps))))
      return strings.t("bar.tooltipLiveNoStats").arg(c.name)
    }
    if (connecting) return strings.t("bar.tooltipConnecting").arg(od.connectingNames[0])
    return strings.t("bar.tooltipIdle")
  }

  readonly property string errorText: od.errorKey === "" ? od.errorRaw
    : (od.errorArg !== "" ? strings.t(od.errorKey).arg(od.errorArg) : strings.t(od.errorKey))

  // --- footer
  readonly property string footerKind: {
    if (!od.installed) return ""
    if (od.updateState === "updating") return "updating"
    if (od.updateState === "updated") return "updated"
    if (od.updateState === "error") return "error"
    if (od.updateAvailable && od.managed === "package") return "pacman"
    if (od.updateAvailable) return "update"
    return ""
  }
  readonly property bool footerClickable: footerKind === "update" || footerKind === "pacman" || footerKind === "error"

  // --- per-session UI state
  property var advOpen: ({})
  property bool ipEntryOpen: false
  property bool confirmOpen: false
  // Controls that need the keyboard (a focused field, an open dropdown)
  // register here by name; the panel's own key handling pauses while any is held.
  property var inputLockHolders: ({})
  readonly property bool inputLocked: {
    for (var h in inputLockHolders) if (inputLockHolders[h] === true) return true
    return false
  }

  function setInputLock(holder, on) {
    if ((inputLockHolders[holder] === true) === on) return
    var next = {}
    for (var h in inputLockHolders) if (h !== holder) next[h] = inputLockHolders[h]
    if (on) next[holder] = true
    inputLockHolders = next
  }

  // Number edits wait for a pause in typing, then go out together.
  property var pendingEdits: ({})

  function queueEdit(scope, rid, key, value) {
    var next = {}
    for (var e in pendingEdits) next[e] = pendingEdits[e]
    next[scope + "|" + rid + "|" + key] = { scope: scope, rid: rid, key: key, value: value }
    pendingEdits = next
    editDebounce.restart()
  }

  Timer {
    id: editDebounce
    interval: 800
    onTriggered: {
      var edits = root.pendingEdits
      root.pendingEdits = ({})
      for (var e in edits) {
        var edit = edits[e]
        if (edit.scope === "receiver") od.setReceiverOption(edit.rid, edit.key, edit.value)
        else od.setGlobalOption(edit.key, edit.value)
      }
    }
  }

  // Escape or Enter in a number field hands the keyboard back to the panel.
  function releaseField(event) {
    if (event.key === Qt.Key_Escape || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      if (panel.loadedContent) panel.loadedContent.forceActiveFocus()
      event.accepted = true
    }
  }

  function statsFor(key) { return od.stats[key] || ({}) }

  function advKey(id, key) { return id !== "" ? id.toUpperCase() : key }
  function isAdvOpen(k) { return advOpen[k] === true }
  function toggleAdv(k) {
    var next = {}
    for (var x in advOpen) next[x] = advOpen[x]
    next[k] = !next[k]
    advOpen = next
  }

  // The "All receivers" block appears once, in the first open Advanced section.
  readonly property string firstAdvKey: {
    for (var i = 0; i < cards.length; i++) {
      var k = advKey(cards[i].id, cards[i].key)
      if (cards[i].id !== "" && isAdvOpen(k)) return k
    }
    for (var j = 0; j < others.length; j++) {
      var k2 = advKey(others[j].id, others[j].key)
      if (others[j].id !== "" && others[j].state !== "waiting" && isAdvOpen(k2)) return k2
    }
    return ""
  }

  // --- keyboard cursor: a flat list of target keys in visual order
  property bool cursorActive: false
  property string cursorKey: "rescan"
  property int cursorIndex: 0
  property int presetCursor: 1

  // "kind" or "kind:arg"; the arg may itself contain colons.
  function navKey(kind, key) { return key === undefined ? kind : kind + ":" + key }
  function parseNavKey(k) {
    var i = String(k).indexOf(":")
    return i === -1 ? { kind: String(k), arg: "" } : { kind: k.substring(0, i), arg: k.substring(i + 1) }
  }

  // The Advanced controls of one open section, in visual order.
  function pushAdvancedKeys(keys, akey) {
    keys.push(navKey("auto", akey))
    keys.push(navKey("bitrate", akey))
    keys.push(navKey("scale", akey))
    if (firstAdvKey === akey) {
      keys.push(navKey("fps"))
      keys.push(navKey("encoder"))
      keys.push(navKey("cursor"))
      keys.push(navKey("tailscale"))
    }
    keys.push(navKey("doctor", akey))
  }

  readonly property var navKeys: {
    var keys = []
    if (od.installed) keys.push("rescan")
    if (od.versionKnown && !od.installed) {
      if (od.releaseError) keys.push("retry")
      else { keys.push("install"); keys.push("release") }
    }
    for (var i = 0; i < cards.length; i++) {
      var c = cards[i]
      keys.push(navKey("disc", c.key))
      if (c.id !== "") {
        keys.push(navKey("preset", c.key))
        keys.push(navKey("adv", c.key))
        if (isAdvOpen(advKey(c.id, c.key))) pushAdvancedKeys(keys, advKey(c.id, c.key))
      }
    }
    for (var j = 0; j < others.length; j++) {
      var o = others[j]
      if (o.id === "" || o.state === "waiting") continue
      if (o.state !== "connecting") keys.push(navKey("conn", o.key))
      keys.push(navKey("chev", o.key))
      if (isAdvOpen(advKey(o.id, o.key))) pushAdvancedKeys(keys, advKey(o.id, o.key))
    }
    if (showEmpty) { keys.push("emptyRescan"); keys.push("emptyIp"); keys.push("emptyDoctor") }
    if (footerClickable) keys.push("footer")
    return keys
  }

  function hasCursor(key) { return cursorActive && cursorKey === key }
  function setCursor(key) {
    cursorActive = true
    cursorKey = key
    var i = navKeys.indexOf(key)
    if (i !== -1) cursorIndex = i
  }

  // When the row under the cursor goes away (Connect became a card), stay at
  // the same position rather than jumping back to the top.
  function ensureCursor() {
    var i = navKeys.indexOf(cursorKey)
    if (i !== -1) { cursorIndex = i; return }
    if (navKeys.length === 0) { cursorKey = ""; return }
    cursorIndex = Math.max(0, Math.min(cursorIndex, navKeys.length - 1))
    cursorKey = navKeys[cursorIndex]
  }

  function moveCursor(dx, dy) {
    ensureCursor()
    if (dx !== 0 && parseNavKey(cursorKey).kind === "preset") {
      presetCursor = Math.max(0, Math.min(Model.PRESET_NAMES.length - 1, presetCursor + dx))
      return
    }
    if (dy === 0) return
    var i = navKeys.indexOf(cursorKey)
    var next = Math.max(0, Math.min(navKeys.length - 1, i + dy))
    if (next >= 0 && next < navKeys.length) { cursorKey = navKeys[next]; cursorIndex = next }
    var parsed = parseNavKey(cursorKey)
    if (parsed.kind === "preset") presetCursor = presetIndexFor(cardByKey(parsed.arg))
    scrollCursorIntoView()
  }

  function cardByKey(key) {
    for (var i = 0; i < cards.length; i++) if (cards[i].key === key) return cards[i]
    return null
  }
  function rowByKey(key) {
    for (var i = 0; i < others.length; i++) if (others[i].key === key) return others[i]
    return null
  }

  function presetIndexFor(card) {
    if (!card) return 1
    var i = Model.PRESET_NAMES.indexOf(Model.presetForBitrate(Model.effectiveBitrate(od.config, card.id)))
    return i === -1 ? 1 : i
  }

  // The card or row whose Advanced section has this key.
  function receiverByAkey(akey) {
    for (var i = 0; i < cards.length; i++) if (advKey(cards[i].id, cards[i].key) === akey) return cards[i]
    for (var j = 0; j < others.length; j++) if (advKey(others[j].id, others[j].key) === akey) return others[j]
    return null
  }

  function activateCursor() {
    ensureCursor()
    var k = cursorKey
    var p = parseNavKey(k)
    var arg = p.arg
    if (k === "rescan" || k === "emptyRescan") od.scan()
    else if (k === "retry") od.checkUpdate(true)
    else if (k === "install") requestInstall()
    else if (k === "release") od.openRelease()
    else if (k === "emptyIp") openIpEntry()
    else if (k === "emptyDoctor") od.openDoctor()
    else if (k === "footer") footerAction()
    else if (p.kind === "disc") od.disconnect(od.targetFor(cardByKey(arg)))
    else if (p.kind === "preset") {
      var c = cardByKey(arg)
      if (c) od.setPreset(c.id, Model.PRESET_NAMES[presetCursor])
    } else if (p.kind === "adv") {
      var c2 = cardByKey(arg)
      if (c2) toggleAdv(advKey(c2.id, c2.key))
    } else if (p.kind === "conn") {
      var r = rowByKey(arg)
      if (r) od.connect(r.id)
    } else if (p.kind === "chev") {
      var r2 = rowByKey(arg)
      if (r2) toggleAdv(advKey(r2.id, r2.key))
    } else if (p.kind === "auto") {
      var r3 = receiverByAkey(arg)
      if (r3 && !od.busy) od.setAutoConnect(r3.id, r3.autoConnect !== true)
    } else if (k === "tailscale") {
      if (!od.busy) od.setGlobalOption("tailscale", Model.globalValue(od.config, "tailscale", true) !== false ? "false" : "true")
    } else if (p.kind === "bitrate" || k === "fps") {
      var field = panel.loadedContent ? panel.loadedContent.findTarget(k) : null
      if (field) field.field.forceActiveFocus()
    } else if (p.kind === "scale" || k === "encoder" || k === "cursor") {
      var dropdown = panel.loadedContent ? panel.loadedContent.findTarget(k) : null
      if (dropdown) dropdown.open()
    } else if (p.kind === "doctor") {
      od.openDoctor()
    }
  }

  function scrollCursorIntoView() {
    if (!panelFlick || !panel.loadedContent) return
    Qt.callLater(function() {
      var item = panel.loadedContent.findTarget(cursorKey)
      if (!item) return
      var margin = Style.space(6)
      var point = item.mapToItem(panelFlick.contentItem, 0, 0)
      var top = point.y
      var bottom = top + item.height
      var maxY = Math.max(0, panelFlick.contentHeight - panelFlick.height)
      if (top < panelFlick.contentY + margin) panelFlick.contentY = Math.max(0, top - margin)
      else if (bottom > panelFlick.contentY + panelFlick.height - margin) panelFlick.contentY = Math.min(maxY, bottom + margin - panelFlick.height)
    })
  }

  function openIpEntry() {
    ipEntryOpen = true
    Qt.callLater(function() { if (panel.loadedContent) panel.loadedContent.focusIpField() })
  }

  function requestInstall() {
    if (od.busy || od.updateState === "updating") return
    if (cards.length > 0) {
      confirmOpen = true
      Qt.callLater(function() { if (panel.loadedContent) panel.loadedContent.focusConfirm() })
    } else {
      od.installOrUpdate()
    }
  }

  function footerAction() {
    if (footerKind === "update") requestInstall()
    else if (footerKind === "pacman") od.openRelease()
    else if (footerKind === "error") od.openDetails()
  }

  function persistKnown(id, name, addr, when) {
    if (!Model.shouldRemember(knownReceivers, id, name, when)) return
    var next = Model.rememberReceiver(knownReceivers, id, name, addr, when)
    if (!root.bar || !root.bar.shell || typeof root.bar.shell.updateEntryInline !== "function") return
    var entry = { id: root.moduleName }
    for (var key in settings) if (key !== "id") entry[key] = settings[key]
    entry.knownReceivers = next
    root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function rightClick() {
    var result = od.toggleLast()
    if (result === "notinstalled") root.open()
    else if (result === "none") od.notify(strings.t("error.noRecent"), "norecent:" + Date.now())
    else if (result === "missing") {
      var last = Model.lastUsedReceiver(root.knownReceivers)
      od.notify(strings.t("error.recentMissing").arg(last ? last.name : ""), "missing:" + Date.now())
    }
  }

  function statsLine(card) {
    var st = statsFor(card.key)
    if (card.state === "reconnecting") return strings.t("row.reconnecting")
    if (card.external && !(st.fps >= 0)) return strings.t("row.external")
    var dash = "–"
    var fps = st.fps >= 0 ? Commons.I18n.formatNumber(Number(Model.formatRate(st.fps))) : dash
    var mbps = st.mbps >= 0 ? Commons.I18n.formatNumber(st.mbps, st.mbps >= 10 ? 0 : 1) : dash
    var ms = st.latency >= 0 ? Commons.I18n.formatNumber(st.latency) : dash
    return strings.t("stats.line").arg(fps).arg(mbps).arg(ms)
  }

  function rowSecondary(row) {
    if (row.state === "waiting") return strings.t("row.waiting")
    if (row.state === "paused") return strings.t("row.paused")
    if (row.lastUsedDays === 0) return strings.t("row.lastUsedToday")
    if (row.lastUsedDays > 0) return strings.tn("row.lastUsedDays", row.lastUsedDays).arg(Commons.I18n.formatNumber(row.lastUsedDays))
    return row.addr
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: {
    if (opened) {
      cursorActive = false
      ipEntryOpen = false
      confirmOpen = false
      if (panelFlick) panelFlick.contentY = 0
      od.onPanelOpened()
      Qt.callLater(function() { if (panel.loadedContent) panel.loadedContent.forceActiveFocus() })
    } else {
      // A control destroyed or hidden mid-edit must not leave the keys dead.
      inputLockHolders = ({})
    }
  }
  onNavKeysChanged: ensureCursor()

  Service {
    id: od
    settings: root.settings
    knownReceivers: root.knownReceivers
    strings: strings
    panelOpen: root.opened
    onReceiverUsed: function(id, name, addr, when) { root.persistKnown(id, name, addr, when) }
  }

  ShellIpc {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function status(): string { return od.statusLine() }
    function connect(name: string): string {
      var rows = root.cards.concat(root.others)
      var known = root.knownReceivers
      for (var i = 0; i < known.length; i++) rows.push({ id: known[i].id, name: known[i].name })
      var r = Model.resolveTarget(name, rows)
      if (r.error === "ambiguous") return "ambiguous: use the id"
      if (r.error !== "") return "not found"
      od.connect(r.id)
      return "connecting"
    }
    function disconnect(name: string): string {
      var r = Model.resolveTarget(name, root.cards)
      if (r.error === "ambiguous") return "ambiguous: use the id"
      if (r.error !== "") return "not connected"
      od.disconnect(od.targetFor(od.cardForId(r.id)) || r.id)
      return "disconnecting"
    }
    function disconnectAll(): string { return "disconnecting " + od.disconnectAll() }
    function rescan(): string { root.open(); od.scan(); return "scanning" }
  }

  // ------------------------------------------------------------ bar button

  TextMetrics {
    id: barLabelMetrics
    font.family: button.fontFamily
    font.pixelSize: button.fontSize
    text: root.barLabel
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    labelText: vertical ? "" : root.barLabel
    slotSize: Style.bar.iconSlot + (labelText !== "" ? Math.ceil(barLabelMetrics.advanceWidth) + Style.space(10) : 0)
    tooltipText: root.barTooltip
    iconComponent: Component {
      Item {
        OpenDisplayIcon {
          id: barIcon
          x: (parent.width - width) / 2
          y: (parent.height - height) / 2
          iconSize: button.iconSize
          color: root.connected || root.pulsing ? root.barForeground : Qt.darker(root.barForeground, 1.55)
          badge: od.updateAvailable
          badgeColor: root.urgent
          opacity: 1.0

          SequentialAnimation on opacity {
            running: root.pulsing && !Style.reduceMotion
            loops: Animation.Infinite
            NumberAnimation { to: 0.45; duration: Style.duration(420); easing.type: Easing.InOutQuad }
            NumberAnimation { to: 1.0; duration: Style.duration(420); easing.type: Easing.InOutQuad }
            onRunningChanged: if (!running) barIcon.opacity = 1.0
          }
        }
      }
    }
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.rightClick()
      else if (buttonCode === Qt.MiddleButton) { root.open(); od.scan() }
      else root.toggle()
    }
  }

  // ------------------------------------------------------------ panel

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight, Style.space(620))

    content: PanelKeyCatcher {
      id: keyCatcher
      property alias panelFlick: panelFlick
      implicitHeight: column.implicitHeight
      anchors.fill: parent
      blocked: root.confirmOpen || root.inputLocked || ipField.activeFocus

      function focusIpField() { ipField.forceActiveFocus() }
      function focusConfirm() { confirmHost.forceActiveFocus() }
      function findTarget(key) { return findIn(column, key) }
      function findIn(item, key) {
        if (!item) return null
        if (item.navKey !== undefined && item.navKey === key && item.visible) return item
        for (var i = 0; i < item.children.length; i++) {
          var hit = findIn(item.children[i], key)
          if (hit) return hit
        }
        return null
      }

      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; root.ensureCursor(); return }
        root.moveCursor(dx, dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          // --- hero
          Item {
            id: header
            width: parent.width
            implicitHeight: hero.implicitHeight

            PanelHero {
              id: hero
              width: parent.width
              title: "OpenDisplay"
              meta: root.heroMeta
              foreground: root.foreground
              fontFamily: root.fontFamily
              iconComponent: Component {
                OpenDisplayIcon {
                  iconSize: Style.font.display
                  color: root.connected ? root.foreground : root.dim
                  badge: false
                }
              }
              trailingControl: Component {
                Button {
                  id: rescanButton
                  property string navKey: "rescan"
                  property bool mouseOver: false
                  visible: od.installed
                  iconText: "\u{f0450}"
                  iconSpinning: od.scanning
                  foreground: root.dim
                  fontFamily: root.fontFamily
                  hasCursor: root.hasCursor("rescan")
                  onHovered: function(h) { mouseOver = h; if (h) root.setCursor("rescan") }
                  onClicked: od.scan()
                  PanelToolTip {
                    visible: rescanButton.mouseOver
                    text: strings.t("action.rescan")
                    fontFamily: root.fontFamily
                  }
                }
              }
            }
          }

          // --- one-line error under the hero
          Row {
            visible: od.hasError
            width: parent.width
            spacing: Style.space(8)

            Text {
              textFormat: Text.PlainText
              width: parent.width - (doctorLink.visible ? doctorLink.width + parent.spacing : 0)
              text: root.errorText
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            LinkText {
              id: doctorLink
              visible: od.errorDoctor
              text: strings.t("advanced.doctor")
              color: root.urgent
              onClicked: od.openDoctor()
            }
          }

          // --- first run
          CursorSurface {
            visible: od.versionKnown && !od.installed
            width: parent.width
            implicitHeight: firstRun.implicitHeight + Style.space(24)
            color: Style.normalFillFor(root.foreground, root.accent)
            foreground: root.foreground

            Column {
              id: firstRun
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.margins: Style.space(12)
              spacing: Style.space(10)

              Row {
                width: parent.width
                spacing: Style.space(10)
                OpenDisplayIcon {
                  iconSize: Style.font.iconLarge
                  color: root.dim
                  anchors.verticalCenter: parent.verticalCenter
                }
                Column {
                  width: parent.width - Style.font.iconLarge - parent.spacing
                  spacing: Style.space(2)
                  Text {
                    textFormat: Text.PlainText
                    width: parent.width
                    text: od.releaseError ? strings.t("firstRun.offline") : strings.t("firstRun.title")
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    font.bold: true
                    elide: Text.ElideRight
                  }
                  Text {
                    textFormat: Text.PlainText
                    width: parent.width
                    visible: !od.releaseError
                    text: od.releaseKnown ? strings.t("firstRun.detail").arg(od.latest) : strings.t("firstRun.checking")
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    wrapMode: Text.WordWrap
                  }
                }
              }

              Row {
                spacing: Style.space(8)
                Button {
                  property string navKey: "retry"
                  visible: od.releaseError
                  text: strings.t("action.retry")
                  bordered: true
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  hasCursor: root.hasCursor("retry")
                  onHovered: function(h) { if (h) root.setCursor("retry") }
                  onClicked: od.checkUpdate(true)
                }
                Button {
                  property string navKey: "install"
                  visible: !od.releaseError
                  text: od.updateState === "updating" ? strings.t("firstRun.installing") : strings.t("firstRun.install")
                  iconText: od.updateState === "updating" ? "\u{f0450}" : ""
                  iconSpinning: od.updateState === "updating"
                  bordered: true
                  background: Style.selectedFillFor(root.foreground, root.accent)
                  accent: root.accent
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  hasCursor: root.hasCursor("install")
                  onHovered: function(h) { if (h) root.setCursor("install") }
                  onClicked: if (od.releaseKnown) root.requestInstall()
                }
                Button {
                  property string navKey: "release"
                  visible: !od.releaseError
                  text: strings.t("firstRun.viewRelease")
                  foreground: root.dim
                  fontFamily: root.fontFamily
                  hasCursor: root.hasCursor("release")
                  onHovered: function(h) { if (h) root.setCursor("release") }
                  onClicked: od.openRelease()
                }
              }

              Text {
                textFormat: Text.PlainText
                visible: od.updateState === "error"
                width: parent.width
                text: od.updateMessage
                color: root.urgent
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }
            }
          }

          // --- receivers
          PanelSectionHeader {
            visible: od.installed
            text: strings.t("section.receivers").toUpperCase()
            font.letterSpacing: 1.2
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Column {
            visible: od.installed
            width: parent.width
            spacing: Style.space(6)

            Repeater {
              model: root.cards
              ReceiverCard {
                required property var modelData
                width: parent.width
                card: modelData
              }
            }

            Repeater {
              model: root.others
              ReceiverRow {
                required property var modelData
                width: parent.width
                row: modelData
              }
            }
          }

          // --- empty state
          Column {
            visible: root.showEmpty
            width: parent.width
            spacing: Style.space(10)

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: od.scanned ? strings.t("empty.text") : strings.t("empty.scanning")
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            Row {
              spacing: Style.space(6)
              Button {
                property string navKey: "emptyRescan"
                text: strings.t("action.rescan")
                iconText: "\u{f0450}"
                iconSpinning: od.scanning
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                iconSize: Style.font.bodySmall
                hasCursor: root.hasCursor("emptyRescan")
                onHovered: function(h) { if (h) root.setCursor("emptyRescan") }
                onClicked: od.scan()
              }
              Button {
                property string navKey: "emptyIp"
                text: strings.t("empty.connectByIp")
                bordered: true
                selected: root.ipEntryOpen
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                hasCursor: root.hasCursor("emptyIp")
                onHovered: function(h) { if (h) root.setCursor("emptyIp") }
                onClicked: root.ipEntryOpen ? (root.ipEntryOpen = false) : root.openIpEntry()
              }
              Button {
                property string navKey: "emptyDoctor"
                text: strings.t("empty.doctor")
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                hasCursor: root.hasCursor("emptyDoctor")
                onHovered: function(h) { if (h) root.setCursor("emptyDoctor") }
                onClicked: od.openDoctor()
              }
            }

            TextField {
              id: ipField
              visible: root.ipEntryOpen
              width: parent.width
              foreground: root.foreground
              placeholderText: "192.168.1.20:9000"
              maximumLength: 85
              onAccepted: {
                if (od.connectAddr(text)) {
                  text = ""
                  root.ipEntryOpen = false
                  keyCatcher.forceActiveFocus()
                }
              }
              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Escape) {
                  root.ipEntryOpen = false
                  keyCatcher.forceActiveFocus()
                  event.accepted = true
                }
              }
            }
          }

          // --- footer
          Column {
            visible: od.installed
            width: parent.width
            spacing: Style.space(10)

            PanelSeparator { foreground: root.foreground }

            Item {
              width: parent.width
              implicitHeight: Math.max(versionText.implicitHeight, footerLink.implicitHeight)

              Text {
                id: versionText
                textFormat: Text.PlainText
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: strings.t("footer.version").arg(od.version)
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Row {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(6)
                width: Math.min(implicitWidth, parent.width - versionText.implicitWidth - Style.space(12))
                layoutDirection: Qt.RightToLeft

                LinkText {
                  id: footerLink
                  property string navKey: "footer"
                  visible: root.footerKind !== ""
                  width: Math.min(implicitWidth, parent.parent.width - versionText.implicitWidth - Style.space(12))
                  hasCursor: root.hasCursor("footer")
                  clickable: root.footerClickable
                  text: {
                    if (root.footerKind === "update") return strings.t("footer.update").arg(od.latest)
                    if (root.footerKind === "updating") return strings.t("footer.updating")
                    if (root.footerKind === "updated") return strings.t("footer.updated").arg(od.updateMessage)
                    if (root.footerKind === "pacman") return strings.t("footer.pacman")
                    if (root.footerKind === "error") return strings.t("footer.error").arg(od.updateMessage)
                    return ""
                  }
                  color: root.footerKind === "update" || root.footerKind === "error" ? root.urgent : root.dim
                  onHovered: root.setCursor("footer")
                  onClicked: root.footerAction()
                }

                Text {
                  visible: root.footerKind === "updating"
                  text: "\u{f0450}"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  anchors.verticalCenter: parent.verticalCenter
                  textFormat: Text.PlainText
                  RotationAnimation on rotation {
                    running: root.footerKind === "updating" && !Style.reduceMotion
                    from: 0; to: 360; duration: Style.duration(900); loops: Animation.Infinite
                  }
                }
              }
            }
          }
        }
      }

      // --- update confirmation (Enter cancels by default)
      Item {
        id: confirmHost
        anchors.fill: parent
        visible: root.confirmOpen
        z: 20
        Keys.onPressed: function(event) { event.accepted = confirm.handleKey(event) }

        ConfirmDialog {
          id: confirm
          anchors.fill: parent
          opened: root.confirmOpen
          selectedIndex: 0
          message: strings.t("confirm.update").arg(root.cards.length > 0 ? root.cards[0].name : "")
          cancelText: strings.t("confirm.cancel")
          confirmText: strings.t("confirm.updateButton")
          foreground: root.foreground
          fontFamily: root.fontFamily
          onCanceled: { root.confirmOpen = false; keyCatcher.forceActiveFocus() }
          onConfirmed: { root.confirmOpen = false; keyCatcher.forceActiveFocus(); od.installOrUpdate() }
          onOpenedChanged: if (opened) selectedIndex = 0
        }
      }
    }
  }

  // ------------------------------------------------------------ components

  component LinkText: Text {
    id: link
    signal clicked()
    signal hovered()
    property bool hasCursor: false
    property bool clickable: true
    textFormat: Text.PlainText
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    font.underline: hasCursor || linkMouse.containsMouse && clickable
    elide: Text.ElideRight
    MouseArea {
      id: linkMouse
      anchors.fill: parent
      enabled: link.clickable
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: link.hovered()
      onClicked: link.clicked()
    }
  }

  component StatusDot: Rectangle {
    width: Math.max(5, Math.round(Style.font.caption * 0.55))
    height: width
    radius: width / 2
  }

  component ReceiverCard: BorderSurface {
    id: cardRoot
    property var card: ({})
    readonly property string akey: root.advKey(card.id || "", card.key || "")
    readonly property bool hasId: (card.id || "") !== ""
    readonly property bool dimmed: card.state === "reconnecting"
    readonly property string currentPreset: hasId ? Model.presetForBitrate(Model.effectiveBitrate(od.config, card.id)) : ""

    color: Style.normalFillFor(root.foreground, root.accent)
    radius: Style.cornerRadius
    implicitHeight: cardColumn.implicitHeight + Style.space(24)

    Column {
      id: cardColumn
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.margins: Style.space(12)
      spacing: Style.space(12)

      RowLayout {
        width: parent.width
        spacing: Style.space(10)

        OpenDisplayIcon {
          iconSize: Style.font.icon
          color: cardRoot.dimmed ? root.dim : root.foreground
          Layout.alignment: Qt.AlignVCenter
        }

        ColumnLayout {
          Layout.fillWidth: true
          spacing: Style.space(2)

          Row {
            Layout.fillWidth: true
            spacing: Style.space(6)

            StatusDot {
              anchors.verticalCenter: parent.verticalCenter
              color: cardRoot.dimmed ? root.dim : root.accent
            }
            Text {
              id: cardName
              textFormat: Text.PlainText
              anchors.verticalCenter: parent.verticalCenter
              text: cardRoot.card.name || ""
              width: Math.min(implicitWidth, parent.width - Style.space(12) - tag.implicitWidth - Style.space(12))
              color: cardRoot.dimmed ? root.dim : root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
              elide: Text.ElideRight
            }
            Text {
              id: tag
              textFormat: Text.PlainText
              anchors.verticalCenter: parent.verticalCenter
              visible: text !== ""
              text: Model.transportLabel(root.statsFor(cardRoot.card.key).transport || "").toUpperCase()
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.letterSpacing: 1
            }
          }

          Text {
            textFormat: Text.PlainText
            Layout.fillWidth: true
            text: root.statsLine(cardRoot.card)
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideRight
          }
        }

        Button {
          property string navKey: root.navKey("disc", cardRoot.card.key)
          text: strings.t("action.disconnect")
          bordered: true
          foreground: root.foreground
          fontFamily: root.fontFamily
          hasCursor: root.hasCursor(navKey)
          Layout.alignment: Qt.AlignVCenter
          onHovered: function(h) { if (h) root.setCursor(navKey) }
          onClicked: od.disconnect(od.targetFor(cardRoot.card))
        }
      }

      // Presets: equal-width chips; the hint shows on hover and keyboard cursor.
      Row {
        id: presetRow
        property string navKey: root.navKey("preset", cardRoot.card.key)
        visible: cardRoot.hasId
        width: parent.width
        spacing: Style.space(8)

        Repeater {
          model: Model.PRESET_NAMES
          Button {
            id: presetButton
            required property string modelData
            required property int index
            width: (presetRow.width - presetRow.spacing * 2) / 3
            text: strings.t("preset." + modelData)
            bordered: true
            selected: cardRoot.currentPreset === modelData
            foreground: root.foreground
            fontFamily: root.fontFamily
            hasCursor: root.hasCursor(presetRow.navKey) && root.presetCursor === index
            onHovered: function(h) { if (h) { root.setCursor(presetRow.navKey); root.presetCursor = index } }
            onClicked: od.setPreset(cardRoot.card.id, modelData)

            PanelToolTip {
              visible: presetButton.hot
              text: strings.t("preset." + presetButton.modelData + "Hint")
              fontFamily: root.fontFamily
            }
          }
        }
      }

      Expander {
        visible: cardRoot.hasId
        width: parent.width
        navKey: root.navKey("adv", cardRoot.card.key)
        open: root.isAdvOpen(cardRoot.akey)
        onToggled: root.toggleAdv(cardRoot.akey)
      }

      Collapsible {
        width: parent.width
        open: cardRoot.hasId && root.isAdvOpen(cardRoot.akey)
        AdvancedSection {
          width: parent.width
          rid: cardRoot.card.id || ""
          receiverName: cardRoot.card.name || ""
          connected: true
          akey: cardRoot.akey
          autoConnect: cardRoot.card.autoConnect === true
          showGlobals: root.firstAdvKey === cardRoot.akey
        }
      }
    }
  }

  component ReceiverRow: Item {
    id: rowRoot
    property var row: ({})
    readonly property string akey: root.advKey(row.id || "", row.key || "")
    readonly property bool waiting: row.state === "waiting"
    readonly property bool isConnecting: row.state === "connecting"
    readonly property bool canExpand: (row.id || "") !== "" && !waiting

    implicitHeight: rowColumn.implicitHeight

    Column {
      id: rowColumn
      width: parent.width
      spacing: Style.space(6)

      RowLayout {
        width: parent.width
        spacing: Style.space(10)

        Item { Layout.preferredWidth: Style.space(2); Layout.preferredHeight: 1 }

        OpenDisplayIcon {
          iconSize: Style.font.icon
          color: root.dim
          Layout.alignment: Qt.AlignVCenter
        }

        ColumnLayout {
          Layout.fillWidth: true
          spacing: Style.space(2)
          opacity: rowRoot.waiting ? 0.6 : 1.0

          Text {
            textFormat: Text.PlainText
            Layout.fillWidth: true
            text: rowRoot.row.name || ""
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            font.bold: true
            elide: Text.ElideRight
          }
          Text {
            textFormat: Text.PlainText
            Layout.fillWidth: true
            visible: text !== ""
            text: root.rowSecondary(rowRoot.row)
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideRight
          }
        }

        Button {
          id: chevButton
          property string navKey: root.navKey("chev", rowRoot.row.key)
          property bool mouseOver: false
          visible: rowRoot.canExpand
          iconText: "\u{f0140}"
          iconRotation: root.isAdvOpen(rowRoot.akey) ? 180 : 0
          foreground: root.dim
          fontFamily: root.fontFamily
          horizontalPadding: Style.space(6)
          hasCursor: root.hasCursor(navKey)
          Layout.alignment: Qt.AlignVCenter
          onHovered: function(h) { mouseOver = h; if (h) root.setCursor(navKey) }
          onClicked: root.toggleAdv(rowRoot.akey)
          PanelToolTip {
            visible: chevButton.mouseOver
            text: strings.t("advanced.title")
            fontFamily: root.fontFamily
          }
        }

        Button {
          property string navKey: root.navKey("conn", rowRoot.row.key)
          visible: !rowRoot.waiting && (rowRoot.row.id || "") !== "" || rowRoot.isConnecting
          text: rowRoot.isConnecting ? strings.t("action.connecting") : strings.t("action.connect")
          iconText: rowRoot.isConnecting ? "\u{f0450}" : ""
          iconSpinning: rowRoot.isConnecting
          bordered: true
          background: rowRoot.isConnecting ? "transparent" : Style.selectedFillFor(root.foreground, root.accent)
          accent: root.accent
          foreground: root.foreground
          fontFamily: root.fontFamily
          hasCursor: root.hasCursor(navKey)
          Layout.alignment: Qt.AlignVCenter
          onHovered: function(h) { if (h && !rowRoot.isConnecting) root.setCursor(navKey) }
          onClicked: if (!rowRoot.isConnecting) od.connect(rowRoot.row.id)
        }
      }

      Collapsible {
        width: parent.width
        open: rowRoot.canExpand && root.isAdvOpen(rowRoot.akey)
        BorderSurface {
          width: parent.width
          color: Style.normalFillFor(root.foreground, root.accent)
          radius: Style.cornerRadius
          implicitHeight: rowAdvanced.implicitHeight + Style.space(20)
          AdvancedSection {
            id: rowAdvanced
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: Style.space(10)
            rid: rowRoot.row.id || ""
            receiverName: rowRoot.row.name || ""
            connected: false
            akey: rowRoot.akey
            autoConnect: rowRoot.row.autoConnect === true
            showGlobals: root.firstAdvKey === rowRoot.akey
            showSeparator: false
          }
        }
      }
    }
  }

  component Expander: Item {
    id: exp
    property bool open: false
    property string navKey: ""
    signal toggled()
    implicitHeight: expRow.implicitHeight + Style.space(4)

    CursorSurface {
      anchors.fill: parent
      anchors.leftMargin: -Style.space(4)
      anchors.rightMargin: -Style.space(4)
      hasCursor: root.hasCursor(exp.navKey)
      foreground: root.foreground
    }

    Row {
      id: expRow
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(6)
      Text {
        textFormat: Text.PlainText
        text: "▸"
        rotation: exp.open ? 90 : 0
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        anchors.verticalCenter: parent.verticalCenter
      }
      Text {
        textFormat: Text.PlainText
        text: strings.t("advanced.title")
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: root.setCursor(exp.navKey)
      onClicked: exp.toggled()
    }
  }

  // Animates its height to the content (180 ms in, 120 ms out).
  component Collapsible: Item {
    id: coll
    property bool open: false
    default property alias content: collContent.data
    clip: true
    height: open ? collContent.childrenRect.height : 0
    visible: height > 0
    implicitHeight: height
    Behavior on height {
      NumberAnimation { duration: coll.open ? Style.duration(180) : Style.duration(120); easing.type: Easing.OutCubic }
    }
    Item {
      id: collContent
      width: parent.width
      height: childrenRect.height
    }
  }

  component AdvancedSection: Column {
    id: adv
    property string rid: ""
    property string akey: ""
    property string receiverName: ""
    property bool connected: false
    property bool autoConnect: false
    property bool showGlobals: false
    property bool showSeparator: true
    readonly property real controlWidth: Math.min(Style.space(150), width * 0.48)
    readonly property string scaleValue: Model.effectiveScale(od.config, rid)
    readonly property var scaleOptions: Model.SCALE_CHOICES.indexOf(scaleValue) !== -1 ? Model.SCALE_CHOICES : Model.SCALE_CHOICES.concat([scaleValue])

    spacing: Style.space(8)

    PanelSeparator { visible: adv.showSeparator; foreground: root.foreground }

    SettingRow {
      label: strings.t("advanced.autoConnect")
      ToggleSwitch {
        id: autoSwitch
        property string navKey: root.navKey("auto", adv.akey)
        checked: adv.autoConnect
        busy: od.busy
        cursorRing: true
        cursorPad: Style.space(2)
        hasCursor: root.hasCursor(navKey)
        foreground: root.foreground
        onHovered: function(h) { if (h) root.setCursor(navKey) }
        onToggled: od.setAutoConnect(adv.rid, !adv.autoConnect)
        PanelToolTip {
          visible: autoSwitch.containsMouse
          text: strings.t("advanced.autoConnectHint")
          fontFamily: root.fontFamily
        }
      }
    }

    SettingRow {
      label: strings.t("advanced.bitrate")
      Row {
        spacing: Style.space(6)
        NumberField {
          id: bitrateField
          property string navKey: root.navKey("bitrate", adv.akey)
          readonly property string lockId: "bitrate|" + adv.rid
          fieldWidth: adv.controlWidth - mbpsLabel.implicitWidth - Style.space(6)
          from: 1
          to: 200
          value: Math.round(Model.effectiveBitrate(od.config, adv.rid))
          foreground: root.foreground
          fontFamily: root.fontFamily
          hasCursor: root.hasCursor(navKey)
          onHovered: function(h) { if (h) root.setCursor(navKey) }
          onModified: function(v) { root.queueEdit("receiver", adv.rid, "bitrate-mbps", v) }
          Keys.onPressed: function(event) { root.releaseField(event) }
          Connections {
            target: bitrateField.field
            function onActiveFocusChanged() { root.setInputLock(bitrateField.lockId, bitrateField.field.activeFocus) }
          }
          Component.onDestruction: root.setInputLock(lockId, false)
        }
        Text {
          id: mbpsLabel
          textFormat: Text.PlainText
          anchors.verticalCenter: parent.verticalCenter
          text: strings.t("advanced.mbps")
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
      }
    }

    SettingRow {
      label: strings.t("advanced.scale")
      Dropdown {
        id: scaleDropdown
        property string navKey: root.navKey("scale", adv.akey)
        readonly property string lockId: "scale|" + adv.rid
        width: adv.controlWidth
        options: adv.scaleOptions
        value: adv.scaleValue
        showLabel: false
        foreground: root.foreground
        fontFamily: root.fontFamily
        hasCursor: root.hasCursor(navKey)
        onHovered: function(h) { if (h) root.setCursor(navKey) }
        onPopupOpenChanged: root.setInputLock(lockId, popupOpen)
        onChanged: function(v) { od.setScale(adv.rid, v) }
        Component.onDestruction: root.setInputLock(lockId, false)
      }
    }

    PanelSectionHeader {
      visible: adv.showGlobals
      text: strings.t("advanced.allReceivers")
      foreground: root.foreground
      fontFamily: root.fontFamily
      fontSize: Style.font.caption
      topPadding: Style.space(4)
    }

    SettingRow {
      visible: adv.showGlobals
      label: strings.t("advanced.maxFps")
      NumberField {
        id: fpsField
        property string navKey: root.navKey("fps")
        fieldWidth: adv.controlWidth
        from: 1
        to: 240
        value: Number(Model.globalValue(od.config, "max-fps", 60))
        foreground: root.foreground
        fontFamily: root.fontFamily
        hasCursor: root.hasCursor(navKey)
        onHovered: function(h) { if (h) root.setCursor(navKey) }
        onModified: function(v) { root.queueEdit("global", "", "max-fps", v) }
        Keys.onPressed: function(event) { root.releaseField(event) }
        Connections {
          target: fpsField.field
          function onActiveFocusChanged() { root.setInputLock("fps", fpsField.field.activeFocus) }
        }
        Component.onDestruction: root.setInputLock("fps", false)
      }
    }

    SettingRow {
      visible: adv.showGlobals
      label: strings.t("advanced.encoder")
      Dropdown {
        property string navKey: root.navKey("encoder")
        width: adv.controlWidth
        options: Model.ENCODERS
        value: String(Model.globalValue(od.config, "encoder", "auto"))
        showLabel: false
        foreground: root.foreground
        fontFamily: root.fontFamily
        hasCursor: root.hasCursor(navKey)
        onHovered: function(h) { if (h) root.setCursor(navKey) }
        onPopupOpenChanged: root.setInputLock("encoder", popupOpen)
        onChanged: function(v) { od.setGlobalOption("encoder", v) }
        Component.onDestruction: root.setInputLock("encoder", false)
      }
    }

    SettingRow {
      visible: adv.showGlobals
      label: strings.t("advanced.cursor")
      Dropdown {
        property string navKey: root.navKey("cursor")
        width: adv.controlWidth
        options: Model.CURSORS
        value: String(Model.globalValue(od.config, "cursor", "auto"))
        showLabel: false
        foreground: root.foreground
        fontFamily: root.fontFamily
        hasCursor: root.hasCursor(navKey)
        onHovered: function(h) { if (h) root.setCursor(navKey) }
        onPopupOpenChanged: root.setInputLock("cursor", popupOpen)
        onChanged: function(v) { od.setGlobalOption("cursor", v) }
        Component.onDestruction: root.setInputLock("cursor", false)
      }
    }

    SettingRow {
      visible: adv.showGlobals
      label: strings.t("advanced.tailscale")
      ToggleSwitch {
        property string navKey: root.navKey("tailscale")
        readonly property bool on: Model.globalValue(od.config, "tailscale", true) !== false
        checked: on
        busy: od.busy
        cursorRing: true
        cursorPad: Style.space(2)
        hasCursor: root.hasCursor(navKey)
        onHovered: function(h) { if (h) root.setCursor(navKey) }
        foreground: root.foreground
        onToggled: od.setGlobalOption("tailscale", on ? "false" : "true")
      }
    }

    Item {
      width: parent.width
      implicitHeight: Math.max(changesText.implicitHeight, advDoctor.implicitHeight) + Style.space(2)
      Text {
        id: changesText
        textFormat: Text.PlainText
        anchors.left: parent.left
        anchors.right: advDoctor.left
        anchors.rightMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        text: adv.connected ? strings.t("advanced.changesReconnect").arg(adv.receiverName) : strings.t("advanced.changesNextTime")
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
      LinkText {
        id: advDoctor
        property string navKey: root.navKey("doctor", adv.akey)
        hasCursor: root.hasCursor(navKey)
        onHovered: root.setCursor(navKey)
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        text: strings.t("advanced.doctor")
        color: root.dim
        onClicked: od.openDoctor()
      }
    }
  }

  component SettingRow: Item {
    id: settingRow
    property string label: ""
    default property alias control: controlHolder.data
    width: parent ? parent.width : implicitWidth
    implicitHeight: Math.max(settingLabel.implicitHeight, controlHolder.childrenRect.height)

    Text {
      id: settingLabel
      textFormat: Text.PlainText
      anchors.left: parent.left
      anchors.right: controlHolder.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      text: settingRow.label
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
    }
    Item {
      id: controlHolder
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      width: Math.max(1, childrenRect.width)
      height: childrenRect.height
    }
  }
}
