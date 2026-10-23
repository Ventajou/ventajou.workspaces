function luaQuote(value) {
  return "\"" + String(value || "").replace(/\\/g, "\\\\").replace(/"/g, "\\\"") + "\""
}

function luaIntList(ids) {
  var out = []
  for (var i = 0; i < ids.length; i++)
    out.push(String(Math.floor(Number(ids[i]))))
  return "{" + out.join(",") + "}"
}

function jsonIds(ids) {
  var out = []
  for (var i = 0; i < ids.length; i++)
    out.push(String(Math.floor(Number(ids[i]))))
  return "[" + out.join(",") + "]"
}

function applyOrderLua(draggedId, destMonitor, oldIds, newIds, orderByMonitor) {
  var jsonRows = []
  for (var name in orderByMonitor) {
    var list = orderByMonitor[name] || []
    jsonRows.push(JSON.stringify(String(name)) + ":" + jsonIds(list))
  }

  var dragged = Math.floor(Number(draggedId))
  if (!isFinite(dragged)) dragged = -1

  return [
    "(function()",
    "  local dest = " + luaQuote(destMonitor),
    "  local dragged = " + dragged,
    "  local oldIds = " + luaIntList(oldIds || []),
    "  local newIds = " + luaIntList(newIds || []),
    "  if dragged > 0 and dest ~= \"\" then",
    "    local ws = hl.get_workspace(dragged)",
    "    if ws and ws.monitor and ws.monitor.name ~= dest then",
    "      hl.dispatch(hl.dsp.workspace.move({ workspace = ws, monitor = dest }))",
    "    end",
    "  end",
    "  local function change(from, to)",
    "    if from == to then return end",
    "    local ws = hl.get_workspace(from)",
    "    if not ws then return end",
    "    hl.dispatch(hl.dsp.workspace.change_id({ workspace = ws, id = to }))",
    "  end",
    "  local need = #oldIds > 0 and #oldIds == #newIds",
    "  if need then",
    "    need = false",
    "    for i, id in ipairs(oldIds) do",
    "      if id ~= newIds[i] then need = true break end",
    "    end",
    "  end",
    "  if need then",
    "    local temp = 500000",
    "    for i, id in ipairs(oldIds) do change(id, temp + i) end",
    "    for i, id in ipairs(newIds) do change(temp + i, id) end",
    "  end",
    "  os.execute(\"mkdir -p \" .. os.getenv(\"HOME\") .. \"/.cache/omarchy/spaces\")",
    "  local path = os.getenv(\"HOME\") .. \"/.cache/omarchy/spaces/order.json\"",
    "  local f = io.open(path, \"w\")",
    "  if f then",
    "    f:write(" + luaQuote("{" + jsonRows.join(",") + "}") + ")",
    "    f:close()",
    "  end",
    "end)()"
  ].join("\n")
}

function focusLua(workspaceId) {
  return "hl.dispatch(hl.dsp.focus({ workspace = " + luaQuote(String(workspaceId)) + " }))"
}

function newWorkspaceLua(monitorName) {
  return [
    "(function()",
    "  hl.dispatch(hl.dsp.focus({ monitor = " + luaQuote(monitorName) + " }))",
    "  hl.dispatch(hl.dsp.focus({ workspace = \"emptynm\" }))",
    "end)()"
  ].join("\n")
}

function arrayMove(list, from, to) {
  var next = list.slice()
  if (from < 0 || from >= next.length) return next
  var item = next.splice(from, 1)[0]
  if (to < 0) to = 0
  if (to > next.length) to = next.length
  next.splice(to, 0, item)
  return next
}

function appLabel(className, title) {
  var t = String(title || "").replace(/^\s+|\s+$/g, "")
  if (t) {
    t = t.replace(/^•\s*/, "")
    var cut = t.split(" - ")[0].split(" | ")[0]
    if (cut.length > 0 && cut.length <= 42) return cut
    return t
  }
  var c = String(className || "")
  if (!c) return "App"
  var parts = c.split(".")
  return parts[parts.length - 1] || c
}

function iconCandidates(className, title) {
  var c = String(className || "")
  var tries = []
  function add(value) {
    var v = String(value || "")
    if (!v) return
    if (tries.indexOf(v) === -1) tries.push(v)
    var lower = v.toLowerCase()
    if (tries.indexOf(lower) === -1) tries.push(lower)
  }
  add(c)
  if (c.indexOf("__") !== -1) add(c.split("__")[0])
  var dotted = c.split(".")
  if (dotted.length) add(dotted[dotted.length - 1])
  var titled = String(title || "").replace(/^\s+|\s+$/g, "").split(/[\s|•\-]+/)[0]
  add(titled)
  return tries
}
