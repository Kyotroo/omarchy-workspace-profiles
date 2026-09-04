#!/bin/bash
set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_home=$(mktemp -d)
trap 'rm -rf -- "$test_home"' EXIT

mkdir -p "$test_home/.config/hypr"
: > "$test_home/.config/hypr/bindings.lua"
: > "$test_home/omarchy-invocations.log"

test_config="$test_home/quickshell-test"
mkdir -p "$test_config"
ln -s /usr/share/omarchy/shell/Commons "$test_config/Commons"
ln -s /usr/share/omarchy/shell/Ui "$test_config/Ui"
ln -s "$repo_dir" "$test_config/Plugin"
cp "$repo_dir/tests/runtime/shell.qml" "$test_config/shell.qml"

run_action() {
  local action=$1
  : > "$test_home/omarchy-invocations.log"
  HOME="$test_home" \
  OMARCHY_TEST_LOG="$test_home/omarchy-invocations.log" \
  KDM_PRESETS_TEST_ACTION="$action" \
  PATH="$repo_dir/tests/fixtures/bin:$PATH" \
    quickshell --path "$test_config/shell.qml" --no-color >/dev/null 2>&1
}

run_action decline
if [[ -s "$test_home/omarchy-invocations.log" ]]; then
  echo "FAIL: declining shortcut setup installed a post-boot hook" >&2
  sed 's/^/  observed: /' "$test_home/omarchy-invocations.log" >&2
  exit 1
fi

run_action accept
if [[ -s "$test_home/omarchy-invocations.log" ]]; then
  echo "FAIL: accepting shortcut setup installed a post-boot hook" >&2
  sed 's/^/  observed: /' "$test_home/omarchy-invocations.log" >&2
  exit 1
fi

run_action set-default
expected="hook install post-boot $test_home/.config/omarchy/plugins/kdm.presets/hooks/kdm-presets-activate-default-profile.sh"
actual=$(<"$test_home/omarchy-invocations.log")
if [[ "$actual" != "$expected" ]]; then
  echo "FAIL: setting a default profile did not install the plugin-specific hook" >&2
  printf '  expected: %s\n  actual:   %s\n' "$expected" "$actual" >&2
  exit 1
fi

echo "PASS: startup hook requires explicit default-profile consent"
