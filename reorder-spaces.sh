#!/bin/bash
set -euo pipefail

# Atomically reorders Hyprland workspaces (via two-phase changeworkspaceid) and
# migrates any saved per-workspace Omarchy layout files to match the new IDs.
#
# Usage:
#   reorder-spaces.sh <temp_base> <renumber_pairs> <layout_pairs>
#
# Where:
#   temp_base       Positive integer >= 1000 used as the collision-free staging base
#   renumber_pairs  Comma-separated old:new pairs for existing Hyprland workspaces (or "-")
#   layout_pairs    Comma-separated old:new pairs for all shifted slots (or "-")

if (( $# != 3 )); then
  echo "Usage: $0 <temp_base> <renumber_pairs> <layout_pairs>" >&2
  exit 2
fi

TEMP_BASE=$1
RENUMBER_SPEC=$2
LAYOUT_SPEC=$3

[[ $TEMP_BASE =~ ^[0-9]+$ ]] && (( TEMP_BASE >= 1000 )) || {
  echo "Invalid temp_base: $TEMP_BASE" >&2
  exit 2
}

parse_pairs() {
  local spec=$1
  local -n out_from=$2
  local -n out_to=$3
  out_from=()
  out_to=()
  [[ $spec == "-" || -z $spec ]] && return 0

  local IFS=','
  local pair old new
  for pair in $spec; do
    [[ $pair =~ ^([1-9][0-9]*):([1-9][0-9]*)$ ]] || {
      echo "Invalid pair: $pair" >&2
      exit 2
    }
    old=${BASH_REMATCH[1]}
    new=${BASH_REMATCH[2]}
    out_from+=("$old")
    out_to+=("$new")
  done
}

declare -a REN_FROM REN_TO LAY_FROM LAY_TO
parse_pairs "$RENUMBER_SPEC" REN_FROM REN_TO
parse_pairs "$LAYOUT_SPEC" LAY_FROM LAY_TO

# 1. Execute two-phase workspace ID renumbering inside Hyprland in one Lua eval
#    so there are no ID collisions and no intermediate jitter between subprocesses.
if (( ${#REN_FROM[@]} > 0 )); then
  lua_code=""
  for i in "${!REN_FROM[@]}"; do
    old=${REN_FROM[$i]}
    tmp=$(( TEMP_BASE + i ))
    lua_code+="if hl.get_workspace($old) then hl.dispatch(hl.dsp.workspace.change_id({ workspace = \"$old\", id = $tmp })) end; "
  done
  for i in "${!REN_FROM[@]}"; do
    new=${REN_TO[$i]}
    tmp=$(( TEMP_BASE + i ))
    lua_code+="if hl.get_workspace($tmp) then hl.dispatch(hl.dsp.workspace.change_id({ workspace = \"$tmp\", id = $new })) end; "
  done
  hyprctl eval "$lua_code" >/dev/null
fi

# 2. Migrate saved per-workspace layout modes (~/.local/state/omarchy/workspace-layouts/<id>.lua)
#    so tiling/scrolling/floating layouts travel with their space.
MODES_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/workspace-layouts"
if (( ${#LAY_FROM[@]} > 0 )) && [[ -d $MODES_DIR ]]; then
  declare -A old_modes
  any_saved=0

  for old in "${LAY_FROM[@]}"; do
    mode_file="$MODES_DIR/$old.lua"
    if [[ -r $mode_file ]]; then
      if mode=$(sed -nE 's/.*mode[[:space:]]*=[[:space:]]*"(dwindle|scrolling|floating)".*/\1/p' "$mode_file" | head -n1) && [[ -n $mode ]]; then
        old_modes[$old]=$mode
        any_saved=1
      fi
    fi
  done

  if (( any_saved )); then
    default_mode=$(omarchy-hyprland-workspace-layout-default 2>/dev/null || echo "dwindle")
    apply_lua=""

    for i in "${!LAY_FROM[@]}"; do
      old=${LAY_FROM[$i]}
      new=${LAY_TO[$i]}
      target_file="$MODES_DIR/$new.lua"
      mode=${old_modes[$old]:-}

      if [[ -n $mode && $mode != "$default_mode" ]]; then
        stmt="o.workspace_mode({ workspace = \"$new\", mode = \"$mode\" })"
        tmp_file=$(mktemp "$MODES_DIR/.$new.lua.XXXXXX")
        printf '%s\n' "$stmt" >"$tmp_file"
        mv -f "$tmp_file" "$target_file"
        apply_lua+="$stmt; "
      else
        rm -f "$target_file"
        apply_lua+="o.workspace_mode({ workspace = \"$new\", mode = \"$default_mode\" }); "
      fi
    done

    if [[ -n $apply_lua ]]; then
      hyprctl eval "$apply_lua" >/dev/null 2>&1 || true
    fi
    omarchy-shell -q omarchy.workspaces refresh || true
    omarchy-shell -q omarchy.dock refresh || true
  fi
fi
