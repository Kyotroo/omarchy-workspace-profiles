// Optional integration check on Omarchy: load the widget headlessly and
// run its actual Quickshell Process save queue. All plugin state is redirected
// into a temporary directory; the installed widget/configuration is untouched.
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const assert = require('node:assert/strict');
const {spawnSync} = require('node:child_process');
const repo = path.resolve(__dirname, '..');
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'presets-qml-'));
try {
  for (const folder of ['Commons', 'services']) fs.symlinkSync('/usr/share/omarchy/shell/' + folder, path.join(dir, folder));
  fs.mkdirSync(path.join(dir, 'Ui'));
  for (const file of fs.readdirSync('/usr/share/omarchy/shell/Ui')) {
    if (file !== 'KeyboardPanel.qml') fs.symlinkSync('/usr/share/omarchy/shell/Ui/' + file, path.join(dir, 'Ui', file));
  }
  // Quickshell has no offscreen PanelWindow backend. Replace only that
  // surface; controls, FileViews, and Process instances stay real.
  fs.writeFileSync(path.join(dir, 'Ui', 'KeyboardPanel.qml'), `
import QtQuick
Item {
  property var anchorItem
  property var owner
  property var bar
  property bool open
  property var focusTarget
  property real contentWidth
  property real contentHeight
  width: contentWidth; height: contentHeight
  function fittedContentWidth(value) { return value }
  function fittedContentHeight(value, cap) { return Math.min(value, cap) }
}
`);
  fs.symlinkSync(path.join(repo, 'scripts'), path.join(dir, 'scripts'));
  fs.symlinkSync(path.join(repo, 'NameEditor.qml'), path.join(dir, 'NameEditor.qml'));
  const source = fs.readFileSync(path.join(repo, 'Presets.qml'), 'utf8').replaceAll(
    'Quickshell.env("HOME") + "/.local/state/omarchy/kdm-presets/', JSON.stringify(dir).slice(0, -1) + '/');
  fs.writeFileSync(path.join(dir, 'Presets.qml'), source);
  const shellQuote = value => "'" + value.replaceAll("'", "'\\''") + "'";
  const environment = path.join(dir, 'environment.sh');
  fs.writeFileSync(environment, `hyprctl() { ${shellQuote(process.execPath)} ${shellQuote(path.join(__dirname, 'fake-hyprctl.cjs'))} "$@"; }\nomarchy-notification-send() { :; }\nexport -f hyprctl omarchy-notification-send\n`);
  fs.writeFileSync(path.join(dir, 'clients.json'), JSON.stringify({workspace: 1, clients: []}));
  fs.writeFileSync(path.join(dir, 'calls.jsonl'), '');
  fs.writeFileSync(path.join(dir, 'shell.qml'), `
import QtQuick
import Quickshell
import "." as Plugin
ShellRoot {
  property bool launched: false
  Plugin.Presets { id: widget }
  Timer {
    interval: 200; running: true
    onTriggered: {
      widget.presets = [{name: "Latest", windows: []}]
      widget.persistJson(widget.presetsPath, [{name: "Old", windows: []}])
      widget.persistPresets()
      widget.persistJson(widget.profilesPath, [{name: "Profile"}])
      check.start()
    }
  }
  Timer {
    id: check; interval: 100; repeat: true
    onTriggered: {
      if (widget.writingPath === "" && Object.keys(widget.pendingWrites).length === 0) {
        if (widget.saveError !== "" || widget.presets[0].name !== "Latest") throw new Error("Save queue lost an edit")
        if (!launched) {
          var profile = {name: "A", closeMode: "keepExisting", workspaces: [{workspace: 1, preset: "Latest"}]}
          if (widget.activateProfile(profile) !== "ok" || widget.activateProfile(profile) !== "busy") throw new Error("Activation guard failed")
          launched = true
        } else if (!widget.activationRunning && widget.activationComplete) {
          if (widget.activationError !== "") throw new Error(widget.activationError)
          console.log("PRESETS_SMOKE_PASSED")
          Qt.quit()
        }
      }
    }
  }
}
`);
  const result = spawnSync('quickshell', ['--no-color', '-p', path.join(dir, 'shell.qml')], {
    encoding: 'utf8', timeout: 15000,
    env: {...process.env, WAYLAND_DISPLAY: '', QT_QPA_PLATFORM: 'offscreen', QT_QUICK_CONTROLS_STYLE: 'Basic', QT_QPA_PLATFORMTHEME: 'basic',
      BASH_ENV: environment, HYPRLAND_INSTANCE_SIGNATURE: 'test-session', TEST_CLIENTS: path.join(dir, 'clients.json'), TEST_LOG: path.join(dir, 'calls.jsonl')}
  });
  const output = result.stdout + result.stderr;
  assert.equal(result.status, 0, output);
  assert.match(output, /PRESETS_SMOKE_PASSED/);
  assert.doesNotMatch(output, /WARN scene:|ERROR:/);
  assert.deepEqual(JSON.parse(fs.readFileSync(path.join(dir, 'presets.json'))), [{name: 'Latest', windows: []}]);
  assert.deepEqual(JSON.parse(fs.readFileSync(path.join(dir, 'profiles.json'))), [{name: 'Profile'}]);
  console.log('QML widget compiled with a stub display surface; actual Process save queue and activation lifecycle passed.');
} finally {
  fs.rmSync(dir, {recursive: true, force: true});
}
