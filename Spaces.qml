import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui
import "SpacesModel.js" as Model

Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null
  property bool opened: false
  property bool opening: false

  property int dragWorkspaceId: -1
  property string dragFromMonitor: ""
  property string dropMonitor: ""
  property int dropIndex: -1
  property real dragX: 0
  property real dragY: 0
  readonly property bool dragging: dragWorkspaceId > 0

  property var visualOrder: ({})
  property var pendingOrder: null
  property var pendingShotMap: null
  property var frozenIds: ({})
  property bool remapping: false
  property int orderSerial: 0
  property int parkedForce: 0
  property int shotRevision: 0
  property int freezeSerial: 0
  property var snapItems: ({})
  property var shotIds: ({})
  property var shotPaths: ({})
  property int shotSerial: 0
  property var hideIcons: ({})
  // Hyprland 0.56.2 segfaults in Screenshare::CScreenshareFrame::transform()
  // if an ext-image-copy-capture frame is created while that output is
  // disconnecting. monitorremoved arrives too late to help. Never hold a
  // session open: arm one output at a time, take one still, then drop it.
  // The inhibit window also covers Quickshell calling QScreen::handle() on a
  // screen that is already gone.
  // A still we armed emits screencast start, then stop once we drop it.
  // Ignore only that pair. Any other screencast — including a stop while a
  // capture is still armed — means an output is changing. Inhibit then:
  // monitorremoved arrives too late to prevent the crash.
  property bool captureInhibited: false
  property string captureMonitor: ""
  property string recentReleaseMonitor: ""
  property int shotCursor: 0

  readonly property string cacheDir: (Quickshell.env("HOME") || "") + "/.cache/omarchy/spaces"
  readonly property var bar: shell && shell.bar ? shell.bar : null
  readonly property string barPos: bar && bar.position ? bar.position : "top"
  readonly property int barSize: bar && bar.barSize ? bar.barSize : Style.bar.sizeHorizontal
  readonly property int stripY: barPos === "top" ? barSize : 0
  readonly property int thumbHeight: Style.space(88)
  readonly property int thumbGap: Style.space(10)
  readonly property int stripHeight: thumbHeight + Style.space(28)

  function open(payloadJson) {
    if (root.opened || root.opening) return
    root.opening = true
    root.captureMonitor = ""
    root.freezeVisibleWorkspaces()
    root.showOverlay()
  }

  function close() {
    root.opened = false
    root.opening = false
    root.clearDrag()
  }

  function dismiss() {
    root.close()
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "ventajou.workspaces")
  }

  function toggle() {
    if (root.opened || root.opening) root.dismiss()
    else root.open("{}")
  }

  function showOverlay() {
    root.opening = false
    root.opened = true
  }

  function freezeVisibleWorkspaces() {
    root.freezeSerial += 1
  }

  function clearDrag() {
    dragWorkspaceId = -1
    dragFromMonitor = ""
    dropMonitor = ""
    dropIndex = -1
    root.orderSerial += 1
  }

  function forceParked() {
    root.parkedForce += 1
  }

  function evalLua(code) {
    luaProc.exec(["hyprctl", "eval", code])
  }

  function orderMap() {
    var map = {}
    var claimed = {}
    var current = root.visualOrder
    for (var key in current) {
      if (!current[key] || !current[key].length) continue
      map[key] = current[key].slice()
      for (var i = 0; i < current[key].length; i++)
        claimed[current[key][i]] = true
    }
    var mons = Hyprland.monitors.values
    for (var m = 0; m < mons.length; m++) {
      var name = String(mons[m].name || "")
      if (!name) continue
      if (!map[name]) map[name] = []
      var live = root.liveIdsOn(name)
      for (var j = 0; j < live.length; j++) {
        if (!claimed[live[j]]) {
          map[name].push(live[j])
          claimed[live[j]] = true
        }
      }
    }
    return map
  }

  function applyPersistedOrder(text) {
    if (root.pendingOrder) return
    try {
      var parsed = JSON.parse(text)
      if (!parsed || typeof parsed !== "object") return
      var next = {}
      for (var key in parsed) {
        if (parsed[key] && parsed[key].length)
          next[key] = parsed[key].slice()
      }
      root.visualOrder = next
      root.orderSerial += 1
    } catch (e) {
    }
  }

  function allLiveIds() {
    var ids = []
    var values = Hyprland.workspaces.values
    for (var i = 0; i < values.length; i++) {
      if (values[i] && values[i].id > 0)
        ids.push(values[i].id)
    }
    return ids
  }

  function packIds(orderedIds) {
    var orderSet = {}
    for (var i = 0; i < orderedIds.length; i++)
      orderSet[orderedIds[i]] = true
    var used = {}
    var live = root.allLiveIds()
    for (var j = 0; j < live.length; j++) {
      if (!orderSet[live[j]])
        used[live[j]] = true
    }
    var free = []
    var n = 1
    while (free.length < orderedIds.length) {
      if (!used[n])
        free.push(n)
      n++
    }
    return free
  }

  function remapShots(oldToNew) {
    if (!oldToNew) return
    function remap(current, asFlag) {
      var next = {}
      var seen = {}
      for (var key in current) {
        var oldId = Number(key)
        if (!oldId || seen[oldId]) continue
        seen[oldId] = true
        var mapped = oldToNew[String(oldId)]
        if (mapped === undefined || mapped === null)
          mapped = oldToNew[oldId]
        var newId = (mapped !== undefined && mapped !== null) ? mapped : oldId
        var value = asFlag ? true : (current[oldId] !== undefined ? current[oldId] : current[String(oldId)])
        next[newId] = value
        next[String(newId)] = value
      }
      return next
    }
    root.snapItems = remap(root.snapItems, false)
    root.shotPaths = remap(root.shotPaths, false)
    root.shotIds = remap(root.shotIds, true)
    root.hideIcons = remap(root.hideIcons, true)
    var items = root.snapItems
    var seen = {}
    for (var key in items) {
      var id = Number(key)
      if (!id || seen[id]) continue
      seen[id] = true
      if (items[id] && items[id].workspaceId !== id)
        items[id].workspaceId = id
    }
    root.shotRevision += 1
  }

  function commitOrder(draggedId, destName, oldIds, newIds) {
    var map = root.orderMap()
    if (destName && newIds && newIds.length)
      map[destName] = newIds.slice()
    root.pendingOrder = map
    if (oldIds && newIds && oldIds.length === newIds.length) {
      var remap = {}
      for (var i = 0; i < oldIds.length; i++)
        remap[String(oldIds[i])] = newIds[i]
      root.pendingShotMap = remap
    } else {
      root.pendingShotMap = null
    }
    root.remapping = true
    root.evalLua(Model.applyOrderLua(draggedId, destName, oldIds || [], newIds || [], map))
  }

  function focusWorkspace(id) {
    var values = Hyprland.workspaces.values
    for (var i = 0; i < values.length; i++) {
      if (values[i] && values[i].id === id && typeof values[i].activate === "function") {
        values[i].activate()
        return
      }
    }
    Hyprland.dispatch("hl.dsp.focus({ workspace = \"" + String(id) + "\" })")
  }

  function liveIdsOn(monitorName) {
    var ids = []
    var values = Hyprland.workspaces.values
    for (var i = 0; i < values.length; i++) {
      var ws = values[i]
      if (!ws || ws.id <= 0) continue
      var name = ws.monitor ? String(ws.monitor.name || "") : ""
      if (name !== monitorName) continue
      ids.push(ws.id)
    }
    return ids
  }

  function workspaceIdsOn(monitorName) {
    var _s = root.orderSerial
    if (root.remapping && root.frozenIds[monitorName] && root.frozenIds[monitorName].length)
      return root.frozenIds[monitorName]
    var live = root.liveIdsOn(monitorName)
    var preferred = root.visualOrder[monitorName]
    if (!preferred || !preferred.length)
      return live.slice().sort(function(a, b) { return a - b })

    var result = []
    var seen = {}
    for (var i = 0; i < preferred.length; i++) {
      var id = preferred[i]
      if (live.indexOf(id) !== -1 && !seen[id]) {
        result.push(id)
        seen[id] = true
      }
    }
    var leftovers = []
    for (var j = 0; j < live.length; j++) {
      if (!seen[live[j]]) leftovers.push(live[j])
    }
    leftovers.sort(function(a, b) { return a - b })
    result = result.concat(leftovers)

    // Undock interleaves two monitors' IDs. Match the bar (ID order) so the
    // strip agrees with Ctrl+Left/Right until the stacks split on redock.
    for (var k = 1; k < result.length; k++) {
      if (result[k] < result[k - 1])
        return live.slice().sort(function(a, b) { return a - b })
    }
    return result
  }

  function parkedIdsOn(monitorName) {
    var ids = root.workspaceIdsOn(monitorName)
    if (!root.dragging) return ids
    var out = []
    for (var i = 0; i < ids.length; i++) {
      if (ids[i] !== root.dragWorkspaceId) out.push(ids[i])
    }
    return out
  }

  function setVisualOrder(monitorName, ids) {
    var next = {}
    var current = root.visualOrder
    for (var key in current) next[key] = current[key]
    next[monitorName] = ids.slice()
    root.visualOrder = next
    root.orderSerial += 1
  }

  function monitorByName(name) {
    var values = Hyprland.monitors.values
    for (var i = 0; i < values.length; i++) {
      if (values[i] && String(values[i].name || "") === name)
        return values[i]
    }
    return null
  }

  function logicalSize(mon) {
    if (!mon) return { w: 1, h: 1 }
    var scale = mon.scale || 1
    return { w: mon.width / scale, h: mon.height / scale }
  }

  function thumbWidthFor(monitor) {
    if (!monitor || !monitor.height) return Style.space(140)
    return Math.max(Style.space(72), Math.round(root.thumbHeight * monitor.width / monitor.height))
  }

  function plusWidthFor(monitor) {
    return Math.max(Style.space(44), root.thumbWidthFor(monitor) * 0.35)
  }

  function copyMap(src) {
    var out = {}
    for (var key in src) out[key] = src[key]
    return out
  }

  function hideIconsFor(workspaceId) {
    if (!workspaceId || workspaceId <= 0) return
    if (root.iconsHidden(workspaceId)) return
    var next = root.copyMap(root.hideIcons)
    next[workspaceId] = true
    next[String(workspaceId)] = true
    root.hideIcons = next
  }

  function iconsHidden(workspaceId) {
    var _r = root.shotRevision
    var hidden = root.hideIcons
    return hidden[workspaceId] === true || hidden[String(workspaceId)] === true
  }

  function snapItem(workspaceId) {
    var _r = root.shotRevision
    var items = root.snapItems
    return items[workspaceId] || items[String(workspaceId)] || null
  }

  function noteShot(workspaceId, path) {
    if (!workspaceId || workspaceId <= 0 || !path)
      return
    var prev = root.shotPaths[workspaceId] || root.shotPaths[String(workspaceId)] || ""
    var paths = root.copyMap(root.shotPaths)
    paths[workspaceId] = path
    paths[String(workspaceId)] = path
    root.shotPaths = paths
    root.markShot(workspaceId)
    if (prev && prev !== path)
      Quickshell.execDetached(["rm", "-f", prev])
  }

  function shotSource(workspaceId) {
    var _r = root.shotRevision
    var paths = root.shotPaths
    var path = paths[workspaceId] || paths[String(workspaceId)] || ""
    if (!path)
      return ""
    return "file://" + path
  }

  function markShot(workspaceId) {
    if (!workspaceId || workspaceId <= 0) return
    var ids = root.copyMap(root.shotIds)
    ids[workspaceId] = true
    ids[String(workspaceId)] = true
    root.shotIds = ids
    root.hideIconsFor(workspaceId)
    root.shotRevision += 1
  }

  function hasShot(workspaceId) {
    var _r = root.shotRevision
    var ids = root.shotIds
    return ids[workspaceId] === true || ids[String(workspaceId)] === true
  }

  function ensureSnapItem(workspaceId, parentItem, w, h) {
    var existing = root.snapItem(workspaceId)
    if (existing) {
      existing.width = w
      existing.height = h
      if (existing.parent !== parentItem)
        existing.parent = parentItem
      return existing
    }
    var obj = snapComp.createObject(parentItem, {
      workspaceId: workspaceId,
      width: w,
      height: h
    })
    var items = root.copyMap(root.snapItems)
    items[workspaceId] = obj
    items[String(workspaceId)] = obj
    root.snapItems = items
    return obj
  }

  function idsEqual(a, b) {
    if (!a || !b || a.length !== b.length) return false
    for (var i = 0; i < a.length; i++) {
      if (Number(a[i]) !== Number(b[i])) return false
    }
    return true
  }

  function iconFor(className, title) {
    var tries = Model.iconCandidates(className, title)
    for (var i = 0; i < tries.length; i++) {
      var path = Quickshell.iconPath(tries[i], true)
      if (path && path.length) return path
    }
    if (root.shell && root.shell.appLibrary && tries.length)
      return root.shell.appLibrary.iconSource(tries[0])
    return Quickshell.iconPath("application-x-executable", true)
  }

  function windowsOn(workspaceId) {
    var out = []
    var values = Hyprland.toplevels.values
    for (var i = 0; i < values.length; i++) {
      var t = values[i]
      if (!t || !t.workspace || t.workspace.id !== workspaceId) continue
      var ipc = t.lastIpcObject || {}
      var className = ipc.class || ipc.initialClass || ""
      var title = t.title || ipc.title || ""
      out.push({
        icon: root.iconFor(className, title),
        name: Model.appLabel(className, title)
      })
    }
    return out
  }

  function hitMonitor(gx, gy) {
    var values = Hyprland.monitors.values
    for (var i = 0; i < values.length; i++) {
      var mon = values[i]
      if (!mon) continue
      var size = root.logicalSize(mon)
      if (gx >= mon.x && gy >= mon.y && gx < mon.x + size.w && gy < mon.y + size.h)
        return mon
    }
    return null
  }

  function beginDrag(workspaceId, monitorName, localX, localY) {
    dragWorkspaceId = workspaceId
    dragFromMonitor = monitorName
    dropMonitor = monitorName
    dropIndex = root.parkedIdsOn(monitorName).length
    root.orderSerial += 1
    root.updateDragFromOverlay(monitorName, localX, localY)
  }

  function updateDragFromOverlay(sourceMonitorName, localX, localY) {
    if (!root.dragging) return
    var src = root.monitorByName(sourceMonitorName)
    if (!src) return

    var gx = src.x + localX
    var gy = src.y + localY
    root.dragX = gx
    root.dragY = gy

    var dest = root.hitMonitor(gx, gy)
    var destName = dest ? String(dest.name || "") : sourceMonitorName
    if (!dest) dest = src
    dropMonitor = destName

    var parked = root.parkedIdsOn(destName)
    var tw = root.thumbWidthFor(dest)
    var plusW = root.plusWidthFor(dest)
    var n = parked.length
    var rowW = n * tw + Math.max(0, n) * root.thumbGap + plusW
    var destW = root.logicalSize(dest).w
    var rowX = (destW - rowW) / 2
    var destLocalX = gx - dest.x
    var xInRow = destLocalX - rowX
    var slot = tw + root.thumbGap
    var idx = slot > 0 ? Math.round(xInRow / slot) : 0
    dropIndex = Math.max(0, Math.min(n, idx))
  }

  function finishDrag() {
    if (!root.dragging) return

    var destName = dropMonitor || dragFromMonitor
    var dragged = dragWorkspaceId
    var fromMonitor = dragFromMonitor
    var insertAt = dropIndex
    var parked = root.parkedIdsOn(destName)
    if (insertAt < 0) insertAt = parked.length
    if (insertAt > parked.length) insertAt = parked.length
    var next = parked.slice()
    next.splice(insertAt, 0, dragged)

    var remaining = []
    if (fromMonitor !== destName)
      remaining = root.workspaceIdsOn(fromMonitor).filter(function(id) { return id !== dragged })

    var previous = root.workspaceIdsOn(destName)
    var unchanged = previous.length === next.length
    if (unchanged) {
      for (var i = 0; i < next.length; i++) {
        if (next[i] !== previous[i]) { unchanged = false; break }
      }
    }
    if (unchanged && fromMonitor === destName) {
      root.clearDrag()
      root.forceParked()
      return
    }

    if (fromMonitor !== destName)
      root.setVisualOrder(fromMonitor, remaining)
    root.setVisualOrder(destName, next)
    var frozen = {}
    var mons = Hyprland.monitors.values
    for (var m = 0; m < mons.length; m++) {
      var name = String(mons[m].name || "")
      if (name) frozen[name] = root.workspaceIdsOn(name)
    }
    frozen[destName] = next.slice()
    if (fromMonitor !== destName)
      frozen[fromMonitor] = remaining.slice()
    root.frozenIds = frozen
    var packed = root.packIds(next)
    root.clearDrag()
    root.forceParked()
    root.commitOrder(dragged, destName, next, packed)
  }

  function activateWorkspace(id) {
    if (!id || id <= 0) return
    root.focusWorkspace(id)
    root.dismiss()
  }

  function createWorkspace(monitorName) {
    if (!monitorName) return
    Hyprland.dispatch("hl.dsp.focus({ monitor = \"" + String(monitorName) + "\" })")
    Hyprland.dispatch("hl.dsp.focus({ workspace = \"emptynm\" })")
  }



  FileView {
    id: orderFile
    path: root.cacheDir + "/order.json"
    watchChanges: true
    printErrors: false
    onLoaded: root.applyPersistedOrder(text())
    onFileChanged: reload()
  }

  Process {
    id: luaProc
    onExited: {
      if (root.pendingOrder) {
        root.visualOrder = root.pendingOrder
        root.remapShots(root.pendingShotMap)
        root.pendingOrder = null
        root.pendingShotMap = null
      }
      root.frozenIds = ({})
      root.remapping = false
      Hyprland.refreshWorkspaces()
      root.orderSerial += 1
      root.forceParked()
    }
  }

  Component {
    id: snapComp
    ShaderEffectSource {
      property int workspaceId: 0
      live: false
      hideSource: false
      smooth: true
      recursive: false
    }
  }

  Component.onCompleted: Quickshell.execDetached(["bash", "-c",
    "rm -f " + Util.shellQuote(root.cacheDir) + "/ws-*.jpg " + Util.shellQuote(root.cacheDir) + "/ws-*.png"
  ])

  IpcHandler {
    target: "ventajou.workspaces"
    function toggle(): string {
      root.toggle()
      return "ok"
    }
    function freeze(): string {
      root.freezeVisibleWorkspaces()
      return "ok"
    }
  }

  function inhibitCapture() {
    root.captureInhibited = true
    root.captureMonitor = ""
    root.recentReleaseMonitor = ""
    resumeCapture.restart()
  }

  function markReleased(monitorName) {
    if (!monitorName)
      return
    root.recentReleaseMonitor = monitorName
    recentReleaseTimer.restart()
  }

  // screencast data is "<state>,monitor". screencastv2 appends the output name.
  // State 1 on the armed output is our still starting. State 0 is ours only
  // when it follows a release we just performed. A stop from an output that
  // disappeared is not ours, and must inhibit.
  function screencastIsOurs(event) {
    var parts = String(event && event.data ? event.data : "").split(",")
    var state = parts[0]
    var mon = parts.length >= 3 ? parts[parts.length - 1] : ""
    if (state === "1") {
      if (!root.captureMonitor)
        return false
      if (!mon)
        return true
      return mon === root.captureMonitor
    }
    if (state === "0") {
      if (!root.recentReleaseMonitor)
        return false
      if (!mon)
        return true
      return mon === root.recentReleaseMonitor
    }
    return false
  }

  function monitorNames() {
    var names = []
    var mons = Hyprland.monitors.values
    for (var i = 0; i < mons.length; i++) {
      var name = String(mons[i].name || "")
      if (name)
        names.push(name)
    }
    return names
  }

  function armNextCapture() {
    if (root.captureInhibited || root.opened || root.opening || root.captureMonitor)
      return
    var names = root.monitorNames()
    if (!names.length)
      return
    var idx = root.shotCursor % names.length
    root.shotCursor = idx + 1
    root.captureMonitor = names[idx]
  }

  Timer {
    id: shotClock
    interval: 1500
    repeat: true
    running: !root.captureInhibited && !root.opened && !root.opening && root.captureMonitor === ""
    onTriggered: root.armNextCapture()
  }

  // If the armed output never answers, drop the session instead of leaving it up.
  Timer {
    id: captureWatchdog
    interval: 2000
    repeat: false
    running: root.captureMonitor !== ""
    onTriggered: root.captureMonitor = ""
  }

  Timer {
    id: resumeCapture
    interval: 1500
    repeat: false
    onTriggered: root.captureInhibited = false
  }

  Timer {
    id: recentReleaseTimer
    interval: 400
    repeat: false
    onTriggered: root.recentReleaseMonitor = ""
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (!event || !event.name) return
      var name = String(event.name)
      if (name === "screencast" || name === "screencastv2") {
        if (root.screencastIsOurs(event))
          return
        root.inhibitCapture()
        return
      }
      if (name === "monitorremoved" || name === "monitorremovedv2"
          || name === "monitoradded" || name === "monitoraddedv2"
          || name === "configreloaded")
        root.inhibitCapture()
    }
  }

  Connections {
    target: Quickshell
    function onScreensChanged() { root.inhibitCapture() }
  }

  Variants {
    model: Quickshell.screens

    delegate: Component {
      PanelWindow {
        id: overlay
        required property var modelData

        screen: modelData
        visible: true
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.namespace: "ventajou-workspaces"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: root.opened ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None
        anchors { top: true; bottom: true; left: true; right: true }
        // Keep the surface mapped so Ctrl+Up does not wait on a fullscreen
        // layer-shell configure. Click-through when closed.
        mask: Region {
          x: 0
          y: 0
          width: (root.opened || root.dragging) ? overlay.width : 0
          height: (root.opened || root.dragging) ? overlay.height : 0
        }

        readonly property var monitor: Hyprland.monitorFor(modelData)
        readonly property string monitorName: monitor ? String(monitor.name || "") : String(modelData.name || "")
        property var parkedIds: []
        readonly property string parkedKey: {
          var _w = Hyprland.workspaces.values
          var _s = root.orderSerial
          var _d = root.dragWorkspaceId
          return root.parkedIdsOn(overlay.monitorName).join(",")
        }

        function syncParked(force) {
          var ids = root.parkedIdsOn(overlay.monitorName)
          if (!force && root.opened && !root.dragging && overlay.parkedIds.length > 0)
            return
          if (!force && ids.length === 0 && overlay.parkedIds.length > 0)
            return
          if (root.idsEqual(overlay.parkedIds, ids))
            return
          overlay.parkedIds = ids.slice()
        }

        onParkedKeyChanged: overlay.syncParked()
        onMonitorNameChanged: overlay.syncParked()
        Component.onCompleted: overlay.syncParked()
        readonly property int capW: {
          var dpr = (monitor && monitor.scale) ? monitor.scale : 1
          if (dpr < 1) dpr = 1
          return Math.max(1, Math.round(overlay.thumbW * dpr))
        }
        readonly property int capH: {
          var dpr = (monitor && monitor.scale) ? monitor.scale : 1
          if (dpr < 1) dpr = 1
          return Math.max(1, Math.round(root.thumbHeight * dpr))
        }
        readonly property int thumbW: root.thumbWidthFor(monitor)
        readonly property int plusW: root.plusWidthFor(monitor)
        readonly property int shift: Math.round(overlay.thumbW / 3)
        readonly property bool shifting: root.dragging && root.dropMonitor === overlay.monitorName && root.dropIndex >= 0
        readonly property bool showGhost: root.dragging && root.dropMonitor === overlay.monitorName
        readonly property bool captureArmed: root.captureMonitor === overlay.monitorName
            && overlay.monitorName !== ""
            && !root.captureInhibited
            && !root.opened
            && !root.opening
        readonly property bool screenCapturable: {
          var s = overlay.screen
          if (!s || !s.name) return false
          if (!(s.width > 0) || !(s.height > 0)) return false
          var mon = overlay.monitor
          return !!(mon && mon.name)
        }
        readonly property bool canCapture: overlay.screenCapturable && !root.captureInhibited

        function hitAt(localX, localY) {
          if (localY < stripClip.y || localY > stripClip.y + stripClip.height)
            return { kind: "scrim" }

          var p = row.mapFromItem(pointer, localX, localY)
          var x = p.x
          var y = p.y
          if (y < -4 || y > root.thumbHeight + 4)
            return { kind: "strip" }

          var ids = overlay.parkedIds
          var tw = overlay.thumbW
          var gap = root.thumbGap
          for (var i = 0; i < ids.length; i++) {
            var tx = i * (tw + gap) + ((overlay.shifting && i >= root.dropIndex) ? overlay.shift : 0)
            if (x >= tx && x < tx + tw)
              return { kind: "thumb", index: i, id: ids[i] }
          }
          var plusX = ids.length * (tw + gap) + ((overlay.shifting && root.dropIndex <= ids.length) ? overlay.shift : 0)
          if (x >= plusX && x < plusX + overlay.plusW)
            return { kind: "plus" }
          return { kind: "strip" }
        }

        Item {
          id: snapHolder
          x: -width - 64
          y: 0
          width: overlay.capW
          height: overlay.capH

          Loader {
            id: liveCapLoader
            anchors.fill: parent
            active: overlay.captureArmed && overlay.canCapture
            sourceComponent: liveCapComp
          }

          Component {
            id: liveCapComp
            ScreencopyView {
              anchors.fill: parent
              // One frame, then the loader is destroyed. live:true asks for the
              // next frame from updatePaintNode and is what kept a session on
              // every output, including one that was about to disappear.
              live: false
              paintCursor: false
              captureSource: overlay.screen
              constraintSize: Qt.size(overlay.capW, overlay.capH)
              onHasContentChanged: {
                if (hasContent)
                  overlay.storeShot()
              }
              // Screen destroyed or the frame failed. Do not treat that as a
              // still we finished; pause before another frame is created.
              onStopped: root.inhibitCapture()
            }
          }
        }

        property bool shotStored: false

        onCaptureArmedChanged: {
          if (overlay.captureArmed)
            overlay.shotStored = false
        }

        function storeShot() {
          if (overlay.shotStored)
            return
          if (!overlay.captureArmed || root.captureInhibited) {
            overlay.releaseCapture()
            return
          }
          var cap = liveCapLoader.item
          if (!cap || !cap.hasContent)
            return
          overlay.shotStored = true
          // The frame has to be in the scene graph before grabToImage can copy it.
          grabTimer.restart()
        }

        function grabShot() {
          var cap = liveCapLoader.item
          if (!cap || !cap.hasContent || root.captureInhibited) {
            overlay.releaseCapture()
            return
          }
          var ws = overlay.monitor && overlay.monitor.activeWorkspace
          var id = ws ? ws.id : 0
          if (!(id > 0)) {
            overlay.releaseCapture()
            return
          }
          var path = root.cacheDir + "/ws-" + id + "-" + root.shotSerial + ".png"
          root.shotSerial += 1
          var grabbed = cap.grabToImage(function(result) {
            if (result && result.saveToFile(path))
              root.noteShot(id, path)
            else
              Quickshell.execDetached(["rm", "-f", path])
            overlay.releaseCapture()
          })
          if (!grabbed)
            overlay.releaseCapture()
        }

        function releaseCapture() {
          grabTimer.stop()
          if (root.captureMonitor === overlay.monitorName) {
            root.markReleased(overlay.monitorName)
            root.captureMonitor = ""
          }
        }

        Timer {
          id: grabTimer
          interval: 32
          repeat: false
          onTriggered: overlay.grabShot()
        }

        function freezeCurrent() {
          if (liveCapLoader.item && liveCapLoader.item.hasContent)
            overlay.storeShot()
        }

        Connections {
          target: root
          function onFreezeSerialChanged() {
            if (root.freezeSerial <= 0) return
            overlay.freezeCurrent()
          }
        }

        Shortcut {
          sequence: "Escape"
          enabled: root.opened
          onActivated: root.dismiss()
        }

        Item {
          id: keyCatcher
          anchors.fill: parent
          focus: root.opened && overlay.monitor && overlay.monitor.focused
          Keys.priority: Keys.BeforeItem
          Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Escape) {
              root.dismiss()
              event.accepted = true
            }
          }
        }

        Connections {
          target: root
          function onOpenedChanged() {
            if (root.opened && overlay.monitor && overlay.monitor.focused)
              Qt.callLater(function() { keyCatcher.forceActiveFocus() })
            if (!root.opened)
              overlay.syncParked(true)
          }
          function onDraggingChanged() {
            if (root.dragging)
              Qt.callLater(function() { keyCatcher.forceActiveFocus() })
          }
          function onParkedForceChanged() {
            overlay.syncParked(true)
          }
        }

        Item {
          id: canvas
          anchors.fill: parent
          visible: true

        Rectangle {
          anchors.fill: parent
          color: Color.menu.scrim
          opacity: root.opened ? 1 : 0
          Behavior on opacity {
            NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
          }
        }

        Item {
          id: stripClip
          anchors.left: parent.left
          anchors.right: parent.right
          y: root.stripY
          height: root.stripHeight
          clip: true

        Rectangle {
          id: strip
          anchors.left: parent.left
          anchors.right: parent.right
          y: root.opened ? 0 : -root.stripHeight
          height: root.stripHeight
          color: Color.menu.background

          Behavior on y {
            NumberAnimation { duration: 150; easing.type: Easing.OutCubic }
          }

          Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: 1
            color: Color.menu.border
          }

          Item {
            id: row
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.verticalCenter: parent.verticalCenter
            height: root.thumbHeight
            width: {
              var n = overlay.parkedIds.length
              return n * overlay.thumbW + overlay.plusW + n * root.thumbGap + (overlay.shifting ? overlay.shift : 0)
            }

            Repeater {
              model: overlay.parkedIds

              WorkspaceThumb {
                required property int index
                required property int modelData
                workspaceId: modelData
                thumbW: overlay.thumbW
                thumbH: root.thumbHeight
                x: index * (overlay.thumbW + root.thumbGap) + ((overlay.shifting && index >= root.dropIndex) ? overlay.shift : 0)
                y: 0

                Behavior on x {
                  enabled: root.dragging
                  NumberAnimation { duration: 90; easing.type: Easing.OutCubic }
                }
              }
            }

            Item {
              width: overlay.plusW
              height: root.thumbHeight
              x: overlay.parkedIds.length * (overlay.thumbW + root.thumbGap) + ((overlay.shifting && root.dropIndex <= overlay.parkedIds.length) ? overlay.shift : 0)
              y: 0

              Behavior on x {
                enabled: root.dragging
                NumberAnimation { duration: 90; easing.type: Easing.OutCubic }
              }

              Rectangle {
                anchors.fill: parent
                radius: Style.cornerRadius
                color: "transparent"
                border.width: 1
                border.color: Util.alpha(Color.menu.text, 0.35)

                Text {
                  anchors.centerIn: parent
                  text: "+"
                  color: Color.menu.text
                  opacity: 0.7
                  font.pixelSize: Style.font.title
                  font.family: Style.font.family
                }
              }

            }
          }
        }
        }
        }

        MouseArea {
          id: pointer
          anchors.fill: parent
          z: 500
          enabled: root.opened && !root.remapping
          hoverEnabled: true
          preventStealing: true
          cursorShape: root.dragging ? Qt.ClosedHandCursor : Qt.ArrowCursor
          property bool pending: false
          property bool plusPressed: false
          property int pressId: -1
          property real pressX: 0
          property real pressY: 0

          onPressed: function(mouse) {
            var hit = overlay.hitAt(mouse.x, mouse.y)
            pressX = mouse.x
            pressY = mouse.y
            pending = hit.kind === "thumb"
            plusPressed = hit.kind === "plus"
            pressId = hit.kind === "thumb" ? hit.id : -1
            keyCatcher.forceActiveFocus()
          }
          onPositionChanged: function(mouse) {
            if (pending && !root.dragging && pressId > 0) {
              var dx = mouse.x - pressX
              var dy = mouse.y - pressY
              if (dx * dx + dy * dy > 144) {
                pending = false
                root.beginDrag(pressId, overlay.monitorName, mouse.x, mouse.y)
              }
            }
            if (root.dragging)
              root.updateDragFromOverlay(overlay.monitorName, mouse.x, mouse.y)
          }
          onReleased: function(mouse) {
            if (root.dragging) {
              root.updateDragFromOverlay(overlay.monitorName, mouse.x, mouse.y)
              root.finishDrag()
            } else if (pending && pressId > 0) {
              root.activateWorkspace(pressId)
            } else if (plusPressed && overlay.hitAt(mouse.x, mouse.y).kind === "plus") {
              root.createWorkspace(overlay.monitorName)
            } else {
              root.dismiss()
            }
            pending = false
            plusPressed = false
            pressId = -1
          }
          onCanceled: {
            pending = false
            plusPressed = false
            pressId = -1
            if (root.dragging) root.clearDrag()
          }
        }

        Item {
          visible: overlay.showGhost
          z: 400
          width: overlay.thumbW
          height: root.thumbHeight
          x: {
            var mon = overlay.monitor
            if (!mon) return 0
            return root.dragX - mon.x - overlay.thumbW / 2
          }
          y: root.dragY - (overlay.monitor ? overlay.monitor.y : 0) - root.thumbHeight / 2
          opacity: 0.92
          scale: 1.04

          WorkspaceCard {
            anchors.fill: parent
            workspaceId: root.dragWorkspaceId
            thumbW: overlay.thumbW
            thumbH: root.thumbHeight
          }
        }
      }
    }
  }

  component WorkspaceCard: Item {
    id: card

    property int workspaceId
    property int thumbW
    property int thumbH

    readonly property var workspace: {
      var values = Hyprland.workspaces.values
      for (var i = 0; i < values.length; i++) {
        if (values[i].id === workspaceId) return values[i]
      }
      return null
    }
    readonly property bool active: workspace ? workspace.active : false
    readonly property var clients: {
      var _t = Hyprland.toplevels.values
      return root.windowsOn(card.workspaceId)
    }
    readonly property bool hasShot: root.hasShot(card.workspaceId)
    readonly property bool showIcons: !root.iconsHidden(card.workspaceId)

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: Color.background
      border.width: card.active ? 2 : 1
      border.color: card.active ? Color.bar.active : Color.menu.border
      clip: true

      Image {
        anchors.fill: parent
        anchors.margins: 1
        visible: card.hasShot
        source: root.shotSource(card.workspaceId)
        fillMode: Image.Stretch
        asynchronous: true
        cache: false
      }

      Loader {
        anchors.fill: parent
        active: card.showIcons
        sourceComponent: iconFallback
      }

      Component {
        id: iconFallback
        Item {
          Row {
            anchors.centerIn: parent
            spacing: Style.space(8)
            visible: card.clients.length > 0

            Repeater {
              model: Math.min(card.clients.length, 4)

              Column {
                required property int index
                readonly property var client: card.clients[index] || ({ icon: "", name: "" })
                spacing: Style.space(4)
                width: Math.min(Style.space(56), card.thumbW / Math.min(card.clients.length, 4) - Style.space(8))

                Image {
                  width: Style.space(28)
                  height: Style.space(28)
                  anchors.horizontalCenter: parent.horizontalCenter
                  source: client.icon
                  fillMode: Image.PreserveAspectFit
                  asynchronous: true
                  sourceSize.width: width * 2
                  sourceSize.height: height * 2
                }

                Text {
                  width: parent.width
                  text: client.name
                  color: Color.menu.text
                  font.pixelSize: Style.font.bodySmall
                  font.family: Style.font.family
                  elide: Text.ElideRight
                  horizontalAlignment: Text.AlignHCenter
                  maximumLineCount: 1
                }
              }
            }
          }

          Text {
            anchors.centerIn: parent
            visible: card.clients.length === 0
            text: "Empty"
            color: Color.menu.text
            opacity: 0.45
            font.pixelSize: Style.font.bodySmall
            font.family: Style.font.family
          }
        }
      }
    }
  }

  component WorkspaceThumb: Item {
    id: thumb

    property int workspaceId
    property int thumbW
    property int thumbH

    width: thumbW
    height: thumbH

    WorkspaceCard {
      anchors.fill: parent
      workspaceId: thumb.workspaceId
      thumbW: thumb.thumbW
      thumbH: thumb.thumbH
    }
  }
}
