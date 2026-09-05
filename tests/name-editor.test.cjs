const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {spawnSync} = require('node:child_process');

test('Return and keypad Enter submit without activating the parent (#1)', t => {
  const runner = '/usr/lib/qt6/bin/qmltestrunner';
  if (!fs.existsSync(runner)) {
    t.skip('Requires a Qt runtime');
    return;
  }
  const imports = fs.mkdtempSync(path.join(os.tmpdir(), 'presets-qml-imports-'));
  t.after(() => fs.rmSync(imports, {recursive: true, force: true}));
  const ui = path.join(imports, 'qs', 'Ui');
  fs.mkdirSync(ui, {recursive: true});
  fs.writeFileSync(path.join(ui, 'qmldir'), 'module qs.Ui\nTextField 1.0 TextField.qml\n');
  // The Omarchy text field adds styling only. A plain control keeps the key
  // propagation boundary real without loading Quickshell's static plugins.
  fs.writeFileSync(path.join(ui, 'TextField.qml'), 'import QtQuick.Controls\nTextField {}\n');
  const result = spawnSync(runner, ['-input', path.join(__dirname, 'tst_name_editor.qml'), '-import', imports], {
    encoding: 'utf8',
    env: {...process.env, QT_QPA_PLATFORM: 'offscreen', QT_QUICK_CONTROLS_STYLE: 'Basic', QT_QPA_PLATFORMTHEME: 'basic'}
  });
  assert.equal(result.status, 0, result.stdout + result.stderr);
  assert.match(result.stdout, /4 passed, 0 failed/);
});
