import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import vm from "node:vm";

const modelPath = path.resolve(import.meta.dirname, "..", "SpacesModel.js");
const src = fs
  .readFileSync(modelPath, "utf8")
  .replace(/^\.pragma\s+library\s*/m, "");

const ctx = { Math, Number, String, Array, isFinite, parseInt };
vm.createContext(ctx);
vm.runInContext(src, ctx);

// 1. Monitor block parsing & resolution
const blocks = ctx.parseMonitorBlocks(
  "0\teDP-1\tBOE 0x095F\n1\tDP-12\tBenQ RD280U HAR1\n2\t\tUnplugged\n"
);
assert.equal(blocks["eDP-1"], 0);
assert.equal(blocks["DP-12"], 1);
assert.equal(ctx.resolveMonitorBlock("DP-12", blocks, 1), 1);
assert.equal(ctx.resolveMonitorBlock("HDMI-A-1", blocks, 23), 2);
assert.equal(ctx.resolveMonitorBlock("HDMI-A-1", blocks, -1), 0);

// 2. buildMonitorSpaces: fixed 1-5 + occupied 6-10 + guest separation
const built = ctx.buildMonitorSpaces(1, "DP-12", [
  { id: 12, monitorName: "DP-12" },
  { id: 16, monitorName: "DP-12" },
  { id: 19, monitorName: "DP-12" },
  { id: 2, monitorName: "eDP-1" },
  { id: 23, monitorName: "DP-12" }, // guest from unplugged monitor block 2
  { id: -98, monitorName: "DP-12" }, // special workspace ignored
]);
assert.deepEqual(Array.from(built.ownIds), [11, 12, 13, 14, 15, 16, 19]);
assert.deepEqual(Array.from(built.guestIds), [23]);

// 3. planReorder: macOS insert & shift (backward: drag space 4 to slot 2)
const planBack = ctx.planReorder([1, 2, 3, 4, 5], 3, 1, [1, 2, 4, 11]);
assert.equal(planBack.fromId, 4);
assert.equal(planBack.toId, 2);
assert.deepEqual(JSON.parse(JSON.stringify(planBack.slotPermutation)), [
  { from: 4, to: 2 },
  { from: 2, to: 3 },
  { from: 3, to: 4 },
]);
// Workspace 3 didn't exist in Hyprland, so only 4 and 2 need changeworkspaceid
assert.deepEqual(JSON.parse(JSON.stringify(planBack.renumberMoves)), [
  { from: 4, to: 2 },
  { from: 2, to: 3 },
]);
assert.ok(planBack.tempBase >= 900001);

// 4. planReorder: forward (drag space 2 to slot 4)
const planFwd = ctx.planReorder([11, 12, 13, 14, 15], 1, 3, [11, 12, 13, 14, 15]);
assert.deepEqual(JSON.parse(JSON.stringify(planFwd.slotPermutation)), [
  { from: 13, to: 12 },
  { from: 14, to: 13 },
  { from: 12, to: 14 },
]);
assert.equal(planFwd.renumberMoves.length, 3);

// No-op when same index
assert.equal(ctx.planReorder([1, 2, 3, 4, 5], 2, 2, [1, 2, 3]), null);

// 5. visualIndexDuringDrag & dropIndexForX
assert.equal(ctx.visualIndexDuringDrag(0, 3, 1), 0);
assert.equal(ctx.visualIndexDuringDrag(1, 3, 1), 2);
assert.equal(ctx.visualIndexDuringDrag(2, 3, 1), 3);
assert.equal(ctx.visualIndexDuringDrag(3, 3, 1), 1);
assert.equal(ctx.visualIndexDuringDrag(4, 3, 1), 4);

assert.equal(ctx.dropIndexForX(10, 200, 12, 5), 0);
assert.equal(ctx.dropIndexForX(250, 200, 12, 5), 1);
assert.equal(ctx.dropIndexForX(9999, 200, 12, 5), 4);

// 6. logicalMonitorRect (fractional scale + rotated monitor)
const benq = ctx.logicalMonitorRect({
  x: 2400,
  y: 0,
  width: 3840,
  height: 2560,
  scale: 1.6,
  transform: 0,
});
assert.equal(benq.width, 2400);
assert.equal(benq.height, 1600);
const portrait = ctx.logicalMonitorRect({
  x: 0,
  y: 0,
  width: 3840,
  height: 2560,
  scale: 2,
  transform: 1,
});
assert.equal(portrait.width, 1280);
assert.equal(portrait.height, 1920);

// 7. projectWindows: multi-monitor offset, z-order (tiled < floating), hidden filtered
const projected = ctx.projectWindows(
  [
    {
      address: "0x1",
      class: "foot",
      title: "term",
      at: [2400, 30],
      size: [1200, 1570],
      floating: false,
      focusHistoryID: 1,
    },
    {
      address: "0x2",
      class: "chromium",
      title: "browser",
      at: [3600, 30],
      size: [1200, 1570],
      floating: false,
      focusHistoryID: 2,
    },
    {
      address: "0x3",
      class: "calc",
      title: "popup",
      at: [3000, 400],
      size: [400, 400],
      floating: true,
      focusHistoryID: 0,
    },
    {
      address: "0x4",
      class: "hidden",
      title: "x",
      at: [2400, 0],
      size: [400, 400],
      hidden: true,
    },
  ],
  benq,
  240,
  160
);
assert.equal(projected.length, 3);
assert.equal(projected[2].appClass, "calc");
assert.equal(projected[2].floating, true);
assert.ok(projected[0].x >= 2 && projected[0].width > 100);

// 8. Markup neutralization regression test (Omarchy Plugin UI Safety)
assert.equal(
  ctx.escapePlainText('<img src="https://example.invalid/tracker"> & <b>hi</b>'),
  '&lt;img src="https://example.invalid/tracker"&gt; &amp; &lt;b&gt;hi&lt;/b&gt;'
);

console.log("ALL SPACES MODEL TESTS PASSED");
