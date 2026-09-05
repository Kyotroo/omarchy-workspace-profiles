#!/bin/bash
# Invoked with a validated, immutable launch plan by Presets.qml.
set -Eeuo pipefail
state_dir=$1
plan=$2
mkdir -p "$state_dir"
# This descriptor belongs only to the coordinator, never launched apps.
exec 9>"$state_dir/activation.lock"
flock -n 9 || { echo 'Another profile activation is running.' >&2; exit 75; }

progress_file="$state_dir/activation-progress.json"
active_file="$state_dir/active-profile.json"
progress_started=false
failure='Profile activation failed.'
tmp=''
atomic_write() {
  tmp=$(mktemp "$1.XXXXXX")
  printf '%s\n' "$2" > "$tmp"
  mv -- "$tmp" "$1"
  tmp=''
}
finish() {
  local rc=$?
  trap - EXIT
  if [ "$rc" -ne 0 ]; then
    echo "$failure" >&2
    if "$progress_started"; then
      local failed
      failed=$(jq --arg error "$failure" 'map(if .status != "done" then .status="failed" | .error=$error else . end)' "$progress_file") && atomic_write "$progress_file" "$failed"
    fi
  fi
  [ -z "$tmp" ] || rm -f -- "$tmp"
  exit "$rc"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
fail() { failure=$1; exit 1; }

# Check every workspace before issuing even the first compositor command.
jq -e '
  (.name | type == "string" and length > 0) and
  (.closeMode == "trackedOnly" or .closeMode == "workspaceAll" or .closeMode == "keepExisting") and
  (.workspaces | type == "array" and length > 0) and
  all(.workspaces[];
    (.workspace | type == "number" and . >= 1 and floor == .) and
    (.preset | type == "string" and length > 0) and
    (.commands | type == "array") and all(.commands[]; type == "string" and length > 0)) and
  ([.workspaces[].workspace] | length == (unique | length))
' <<< "$plan" >/dev/null || fail 'Invalid profile launch plan; no workspaces were changed.'
profile_name=$(jq -r .name <<< "$plan")
close_mode=$(jq -r .closeMode <<< "$plan")
session=${HYPRLAND_INSTANCE_SIGNATURE:?Missing Hyprland session identity}
ownership='{"version":2,"windows":[]}'
if [ -f "$active_file" ]; then
  previous=$(cat "$active_file")
  jq -e 'type == "object"' <<< "$previous" >/dev/null || fail 'Cannot read window ownership; no workspaces were changed.'
  # Legacy records lack PID/session identity. Leave those windows alone.
  if jq -e '.version == 2' <<< "$previous" >/dev/null; then
    jq -e '.windows | type == "array"' <<< "$previous" >/dev/null || fail 'Invalid window ownership records.'
    ownership=$previous
  fi
fi
refresh_ownership() {
  local clients
  clients=$(hyprctl clients -j)
  # Keep live records for ALL profiles, including windows moved elsewhere.
  ownership=$(jq --arg session "$session" --argjson clients "$clients" '
    .windows |= map(select(.session == $session) | . as $w |
      select(any($clients[]; .address == $w.address and .pid == $w.pid and .initialClass == $w.initialClass)))
  ' <<< "$ownership")
  atomic_write "$active_file" "$ownership"
}
refresh_ownership
progress=$(jq '[.workspaces[] | {workspace, preset, status:"pending"}]' <<< "$plan")
atomic_write "$progress_file" "$progress"
progress_started=true

mark_step() {
  progress=$(jq --argjson index "$1" --arg status "$2" '.[$index].status=$status' <<< "$progress")
  atomic_write "$progress_file" "$progress"
}
current_client() {
  hyprctl clients -j | jq -c --argjson expected "$1" '
    .[] | select(.address == $expected.address and .pid == $expected.pid
      and .initialClass == $expected.initialClass and .workspace.id == $expected.workspace.id)'
}
close_window() {
  local expected=$1 current address
  current=$(current_client "$expected")
  [ -n "$current" ] || return 0
  address=$(jq -r .address <<< "$current")
  [[ "$address" =~ ^0x[0-9a-fA-F]+$ ]] || fail 'Invalid window address.'
  hyprctl dispatch "hl.dsp.window.close({ window = \"address:$address\" })" >/dev/null
  for ((poll=0; poll<30; poll++)); do
    current=$(current_client "$expected")
    [ -n "$current" ] || return 0
    sleep 0.1
  done
  fail "A window on workspace $ws did not close. Resolve any save dialog and retry; the application was not terminated."
}
wait_workspace() {
  for ((poll=0; poll<30; poll++)); do
    [ "$(hyprctl activeworkspace -j | jq -r .id)" = "$ws" ] && return 0
    sleep 0.1
  done
  fail "Workspace $ws could not be focused."
}
launch_window() {
  local command=$1 before after new count
  before=$(hyprctl clients -j | jq '[.[].address]')
  # Re-focus before each launch if the user moved elsewhere during a wait.
  hyprctl dispatch "hl.dsp.focus({ workspace = \"$ws\" })" >/dev/null
  wait_workspace
  bash -lc "$command" 9>&- </dev/null >/dev/null 2>&1 &
  disown
  for ((poll=0; poll<50; poll++)); do
    after=$(hyprctl clients -j)
    new=$(jq --argjson before "$before" --argjson ws "$ws" '
      [.[] | select(.workspace.id == $ws) | . as $c | select($before | index($c.address) | not)]' <<< "$after")
    count=$(jq length <<< "$new")
    if [ "$count" -gt 0 ]; then
      # Never guess ownership when several windows arrive together.
      [ "$count" -eq 1 ] || fail "Several windows appeared on workspace $ws; ownership is ambiguous."
      ownership=$(jq --arg profile "$profile_name" --arg session "$session" --arg preset "$preset" --argjson client "$(jq '.[0]' <<< "$new")" '
        .windows += [{profile:$profile, session:$session, preset:$preset,
          workspace:$client.workspace.id, address:$client.address, pid:$client.pid, initialClass:$client.initialClass}]
      ' <<< "$ownership")
      # Commit after every window so later failure retains known ownership.
      atomic_write "$active_file" "$ownership"
      return 0
    fi
    sleep 0.1
  done
  fail "No new window appeared for $preset on workspace $ws."
}

count=$(jq '.workspaces | length' <<< "$plan")
for ((index=0; index<count; index++)); do
  step=$(jq -c --argjson index "$index" '.workspaces[$index]' <<< "$plan")
  ws=$(jq -r .workspace <<< "$step")
  preset=$(jq -r .preset <<< "$step")
  mark_step "$index" running
  hyprctl dispatch "hl.dsp.focus({ workspace = \"$ws\" })" >/dev/null
  wait_workspace
  hyprctl keyword workspace "$ws, layout:scrolling" >/dev/null
  clients=$(hyprctl clients -j)
  targets='[]'
  if [ "$close_mode" = workspaceAll ]; then
    targets=$(jq --argjson ws "$ws" '[.[] | select(.workspace.id == $ws)]' <<< "$clients")
  elif [ "$close_mode" = trackedOnly ]; then
    targets=$(jq --arg profile "$profile_name" --argjson ws "$ws" --argjson ownership "$ownership" '
      [.[] | select(.workspace.id == $ws) | . as $c |
        select(any($ownership.windows[]; .profile == $profile and .workspace == $ws
          and .address == $c.address and .pid == $c.pid and .initialClass == $c.initialClass))]
    ' <<< "$clients")
    if [ "$(jq --argjson ws "$ws" '[.[] | select(.workspace.id == $ws)] | length' <<< "$clients")" -gt "$(jq length <<< "$targets")" ]; then
      omarchy-notification-send "Workspace $ws still has other windows" "$profile_name only closes its own tracked windows" 9>&- >/dev/null 2>&1 || true
    fi
  fi
  while IFS= read -r target; do
    close_window "$target"
    # Remove confirmed-closed identities immediately, before an application
    # can reuse an address. Moving a window does not discard its ownership.
    refresh_ownership
  done < <(jq -c '.[]' <<< "$targets")
  while IFS= read -r command; do
    launch_window "$(jq -r . <<< "$command")"
  done < <(jq -c '.commands[]' <<< "$step")
  mark_step "$index" done
done
