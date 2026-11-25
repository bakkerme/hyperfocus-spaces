# hyperfocus-spaces

macOS Spaces-inspired horizontal workspace overview and drag-to-reorder plugin for [Omarchy](https://omarchy.org/) (`omarchy-shell`, plugin id `brandon.spaces`).

## Features

- **Top bar button** (`󰓩`) next to `omarchy.workspaces` to toggle the overview strip on the clicked monitor.
- **Trackpad gesture support** via `omarchy-shell shell toggle brandon.spaces` (e.g., 3-finger swipe up in `~/.config/hypr/input.lua`).
- **Mini desktop thumbnails**: wallpaper backdrop + scaled Hyprland window layout + app icons, with live Wayland `ScreencopyView` previews where available.
- **Per-monitor slots**: mirrors `omarchy.workspaces` (fixed slots 1–5 plus any occupied 6–10 for the active monitor's block, and guest workspaces after a divider).
- **Click to switch**: click any space card (or press `1`–`9`, `0`, or `Enter`) to jump to it and close the strip.
- **Drag to reorder (insert & shift)**: drag a space horizontally to move it to a new slot; other spaces glide smoothly to show the target slot, and Hyprland workspace IDs + saved per-workspace layouts (`~/.local/state/omarchy/workspace-layouts/`) are atomically renumbered to match.
- **Keyboard navigation**: `←`/`→` (or `h`/`l`) to select, `Shift+←`/`Shift+→` (or `Shift+h`/`Shift+l`) to reorder, `Enter`/`Space` to switch, `Esc` to close.

## Install

```bash
git clone https://github.com/bakkerme/hyperfocus-spaces.git ~/sources/hyperfocus-spaces
ln -s ~/sources/hyperfocus-spaces ~/.config/omarchy/plugins/brandon.spaces
omarchy restart shell
```

Add `{ "id": "brandon.spaces" }` to `bar.layout.left` in `~/.config/omarchy/shell.json`, and optionally bind a gesture in `~/.config/hypr/input.lua`:

```lua
hl.gesture({ fingers = 3, direction = "up", action = function() hl.dispatch(hl.dsp.exec_cmd("omarchy-shell shell toggle brandon.spaces")) end })
```

## Development & Tests

```bash
# Run pure model unit tests
node tests/model.test.mjs

# Reload after QML edits (clears Quickshell's QML component cache)
omarchy restart shell
```
