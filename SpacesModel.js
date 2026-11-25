.pragma library

var SLOTS_PER_MONITOR = 10;
var MIN_VISIBLE_SLOTS = 5;

function blockOf(id) {
  return Math.floor((id - 1) / SLOTS_PER_MONITOR);
}

function slotOf(id) {
  return ((id - 1) % SLOTS_PER_MONITOR) + 1;
}

function slotLabel(slot) {
  return slot === SLOTS_PER_MONITOR ? "0" : String(slot);
}

function parseMonitorBlocks(text) {
  var blocks = {};
  var lines = String(text || "").split("\n");
  for (var i = 0; i < lines.length; i++) {
    var fields = lines[i].split("\t");
    if (fields.length >= 3 && fields[1] !== "") {
      var parsed = parseInt(fields[0], 10);
      if (isFinite(parsed) && parsed >= 0) blocks[fields[1]] = parsed;
    }
  }
  return blocks;
}

function resolveMonitorBlock(monitorName, blocks, activeWorkspaceId) {
  if (monitorName && blocks && blocks[monitorName] !== undefined) {
    return blocks[monitorName];
  }
  if (activeWorkspaceId > 0) {
    return blockOf(activeWorkspaceId);
  }
  return 0;
}

// Mirrors omarchy.workspaces: fixed slots 1-5 for the monitor's block,
// plus any existing/occupied workspaces 6-10 in that block.
// Guest workspaces (from unplugged monitors) are returned separately so
// monitor-workspaces.lua's reclaim tracking stays intact.
function buildMonitorSpaces(block, monitorName, workspaces) {
  var base = block * SLOTS_PER_MONITOR;
  var ownIds = [];
  for (var s = 1; s <= MIN_VISIBLE_SLOTS; s++) {
    ownIds.push(base + s);
  }

  var guestIds = [];
  var list = Array.isArray(workspaces) ? workspaces : [];
  for (var i = 0; i < list.length; i++) {
    var ws = list[i];
    if (!ws) continue;
    var id = Number(ws.id);
    if (!isFinite(id) || id <= 0) continue;
    if (blockOf(id) === block) {
      if (ownIds.indexOf(id) === -1) ownIds.push(id);
    } else if (ws.monitorName && ws.monitorName === monitorName) {
      if (guestIds.indexOf(id) === -1) guestIds.push(id);
    }
  }

  ownIds.sort(function(a, b) { return a - b; });
  guestIds.sort(function(a, b) { return a - b; });

  return {
    ownIds: ownIds,
    guestIds: guestIds
  };
}

// Pure insert-and-shift reorder planner.
//
// Given ordered monitor workspace IDs `ids` (e.g. [1, 2, 3, 4, 5]),
// dragging the space at `fromIndex` to `toIndex` produces:
//   - `renumberMoves`: [{ from, to }] for workspaces that exist in Hyprland
//   - `slotPermutation`: [{ from, to }] for all slots whose contents shifted
//     (used to migrate saved per-workspace layouts even for empty slots)
//   - `tempBase`: collision-free starting ID for two-phase renumbering
//
// Example: ids=[1,2,3,4,5], fromIndex=3 (id 4), toIndex=1 (id 2)
//   reordered = [1, 4, 2, 3, 5]
//   slotPermutation = [ {from:4, to:2}, {from:2, to:3}, {from:3, to:4} ]
function planReorder(ids, fromIndex, toIndex, allExistingIds) {
  if (!Array.isArray(ids) || ids.length < 2) return null;
  if (fromIndex < 0 || fromIndex >= ids.length) return null;
  if (toIndex < 0 || toIndex >= ids.length) return null;
  if (fromIndex === toIndex) return null;

  var reordered = ids.slice();
  var moved = reordered.splice(fromIndex, 1)[0];
  reordered.splice(toIndex, 0, moved);

  var existingSet = {};
  var maxId = 0;
  var existingList = Array.isArray(allExistingIds) ? allExistingIds : [];
  for (var e = 0; e < existingList.length; e++) {
    var eid = Number(existingList[e]);
    if (isFinite(eid) && eid > 0) {
      existingSet[eid] = true;
      if (eid > maxId) maxId = eid;
    }
  }
  for (var k = 0; k < ids.length; k++) {
    if (ids[k] > maxId) maxId = ids[k];
  }

  var slotPermutation = [];
  var renumberMoves = [];
  for (var i = 0; i < ids.length; i++) {
    var oldId = reordered[i];
    var newId = ids[i];
    if (oldId === newId) continue;
    slotPermutation.push({ from: oldId, to: newId });
    if (existingSet[oldId]) {
      renumberMoves.push({ from: oldId, to: newId });
    }
  }

  if (slotPermutation.length === 0) return null;

  return {
    fromId: ids[fromIndex],
    toId: ids[toIndex],
    slotPermutation: slotPermutation,
    renumberMoves: renumberMoves,
    tempBase: Math.max(900001, maxId + 1000)
  };
}

// Compute the shifted visual slot index for card `index` while `dragIndex` is
// hovering over `dropIndex`.
function visualIndexDuringDrag(index, dragIndex, dropIndex) {
  if (dragIndex < 0 || dropIndex < 0 || dragIndex === dropIndex) return index;
  if (index === dragIndex) return dropIndex;
  if (dragIndex < dropIndex && index > dragIndex && index <= dropIndex) return index - 1;
  if (dragIndex > dropIndex && index >= dropIndex && index < dragIndex) return index + 1;
  return index;
}

// Map a card center X coordinate inside the strip to a clamped drop slot index.
function dropIndexForX(centerX, cardWidth, cardSpacing, count) {
  if (count <= 1) return 0;
  var stride = cardWidth + cardSpacing;
  if (stride <= 0) return 0;
  var idx = Math.floor(centerX / stride);
  if (idx < 0) return 0;
  if (idx >= count) return count - 1;
  return idx;
}

// Logical monitor size accounting for scale and 90/270-degree rotation.
function logicalMonitorRect(monitor) {
  if (!monitor) return { x: 0, y: 0, width: 1920, height: 1080 };
  var scale = Number(monitor.scale);
  if (!isFinite(scale) || scale <= 0) scale = 1;
  var w = Number(monitor.width) / scale;
  var h = Number(monitor.height) / scale;
  var transform = Number(monitor.transform || 0);
  if (transform % 2 === 1) {
    var tmp = w;
    w = h;
    h = tmp;
  }
  return {
    x: Number(monitor.x || 0),
    y: Number(monitor.y || 0),
    width: Math.max(1, w),
    height: Math.max(1, h)
  };
}

// Project Hyprland clients on a workspace onto a mini desktop thumbnail card.
// Tiled windows draw beneath floating windows; within each layer, more recently
// focused windows (lower focusHistoryID) draw on top.
function projectWindows(clients, monitorRect, cardWidth, cardHeight) {
  if (!Array.isArray(clients) || clients.length === 0) return [];
  if (!monitorRect || monitorRect.width <= 0 || monitorRect.height <= 0) return [];
  if (cardWidth <= 0 || cardHeight <= 0) return [];

  var visible = [];
  for (var i = 0; i < clients.length; i++) {
    var c = clients[i];
    if (!c || c.hidden || c.mapped === false) continue;
    var at = Array.isArray(c.at) ? c.at : [0, 0];
    var size = Array.isArray(c.size) ? c.size : [0, 0];
    if (size[0] <= 0 || size[1] <= 0) continue;
    visible.push(c);
  }

  visible.sort(function(a, b) {
    var af = a.floating ? 1 : 0;
    var bf = b.floating ? 1 : 0;
    if (af !== bf) return af - bf;
    var ah = isFinite(Number(a.focusHistoryID)) ? Number(a.focusHistoryID) : 9999;
    var bh = isFinite(Number(b.focusHistoryID)) ? Number(b.focusHistoryID) : 9999;
    return bh - ah;
  });

  var sx = cardWidth / monitorRect.width;
  var sy = cardHeight / monitorRect.height;
  var out = [];

  for (var j = 0; j < visible.length; j++) {
    var w = visible[j];
    var rx = (Number(w.at[0]) - monitorRect.x) * sx;
    var ry = (Number(w.at[1]) - monitorRect.y) * sy;
    var rw = Number(w.size[0]) * sx;
    var rh = Number(w.size[1]) * sy;

    // Clamp cleanly inside card bounds while keeping tiny windows visible.
    var x1 = Math.max(2, Math.min(cardWidth - 10, rx));
    var y1 = Math.max(2, Math.min(cardHeight - 10, ry));
    var x2 = Math.max(x1 + 8, Math.min(cardWidth - 2, rx + rw));
    var y2 = Math.max(y1 + 8, Math.min(cardHeight - 2, ry + rh));

    out.push({
      address: String(w.address || ""),
      appClass: String(w.class || w.initialClass || ""),
      title: String(w.title || w.initialTitle || w.class || ""),
      floating: !!w.floating,
      fullscreen: Number(w.fullscreen || 0) > 0,
      x: x1,
      y: y1,
      width: x2 - x1,
      height: y2 - y1,
      zIndex: j + 1
    });
  }

  return out;
}

function normalizeAddress(address) {
  var s = String(address || "").trim().toLowerCase();
  if (!s) return "";
  return s.indexOf("0x") === 0 ? s : ("0x" + s);
}

// Neutralize markup characters for any shared tooltip sink that might interpret AutoText.
function escapePlainText(value) {
  return String(value || "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}
