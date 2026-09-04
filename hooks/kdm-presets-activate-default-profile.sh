#!/bin/bash
# omarchy:summary=Activate the kdm.presets default profile (if any) at login
# Runs via ~/.config/omarchy/hooks/post-boot.d/ (installed with
# `omarchy hook install post-boot`), which the default autostart.lua already
# invokes ~2s after Hyprland starts (by which point omarchy-shell, started
# earlier in the same autostart block, should be up).
set -euo pipefail

profiles_file="$HOME/.local/state/omarchy/kdm-presets/profiles.json"
[ -f "$profiles_file" ] || exit 0

name=$(jq -r '(.[] | select(.default == true) | .name) // empty' "$profiles_file" 2>/dev/null | head -n1)
[ -n "$name" ] || exit 0

omarchy-shell kdm.presets activateProfile "$name" >/dev/null 2>&1 || true
