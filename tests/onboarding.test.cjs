// Regression coverage for the first-run shortcut setup hanging on
// "Setting up your shortcuts…" (the panel never learned the script finished).
//
// Two halves, matching the two halves of the fix:
//   - the script reports its outcome on stdout, so the panel can read it from
//     a process exit instead of an inotify watch it can miss;
//   - resolveOnboarding always leaves the "running" phase, whatever it is fed.
const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');
const {spawnSync} = require('node:child_process');
const {pathToFileURL} = require('node:url');
const repo = path.resolve(__dirname, '..');
const source = fs.readFileSync(path.join(repo, 'Presets.qml'), 'utf8');
const quote = s => "'" + String(s).replaceAll("'", "'\\''") + "'";

function fixture(t) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'presets-onboarding-'));
  t.after(() => fs.rmSync(dir, {recursive: true, force: true}));
  const ctx = {
    bindingsLuaPath: path.join(dir, 'bindings.lua'),
    onboardingResultPath: path.join(dir, 'onboarding-result.json'),
    onboardingPath: path.join(dir, 'onboarding.json'),
    onboardingPhase: 'ask', onboardingResult: null, onboardingDone: false,
    pendingWrites: {}, writingPath: '', writingJson: '',
    onboardingProcess: {running: false, command: []},
    onboardingWatchdog: {running: false, restart() { this.running = true }, stop() { this.running = false }},
    saveProcess: {running: false, command: []},
    Util: {shellQuote: quote},
    Qt: {resolvedUrl: p => pathToFileURL(path.join(repo, p))},
    JSON, Object, String
  };
  ctx.root = ctx;
  vm.createContext(ctx);
  for (const match of source.matchAll(/^  function \w+\([^]*?^  }/gm)) vm.runInContext(match[0], ctx);

  // hyprctl is faked and sleep shortened so the script never touches a live
  // compositor or spends real time waiting on one.
  const env = {...process.env};
  const shell = path.join(dir, 'environment.sh');
  fs.writeFileSync(shell, 'hyprctl() { :; }\nsleep() { command sleep 0.01; }\nexport -f hyprctl sleep\n');
  env.BASH_ENV = shell;
  const run = () => spawnSync('bash', ['-c', ctx.buildOnboardingScript()], {env, encoding: 'utf8', timeout: 15000});
  return {dir, ctx, run, bindings: () => fs.readFileSync(ctx.bindingsLuaPath, 'utf8')};
}

const validBindings = '-- user bindings\no.bind("SUPER + SHIFT + R", "SSH", "alacritty")\n';

test('setup reports its result on stdout, not only into a file the panel may miss', t => {
  const f = fixture(t);
  fs.writeFileSync(f.ctx.bindingsLuaPath, validBindings);

  const {stdout} = f.run();

  assert.deepEqual(JSON.parse(stdout.trim()), {result: 'success'});
  assert.match(f.bindings(), /activatePresetSlot/);
  // The file copy still exists for anyone inspecting state by hand.
  assert.deepEqual(JSON.parse(fs.readFileSync(f.ctx.onboardingResultPath, 'utf8')), {result: 'success'});
});

test('a second run reports already-installed on stdout instead of appending twice', t => {
  const f = fixture(t);
  fs.writeFileSync(f.ctx.bindingsLuaPath, validBindings);

  f.run();
  const {stdout} = f.run();

  assert.deepEqual(JSON.parse(stdout.trim()), {result: 'already-installed'});
  assert.equal(f.bindings().match(/activatePresetSlot/g).length, 1);
});

test('a missing bindings.lua still reports, rather than leaving the panel waiting', t => {
  const f = fixture(t);

  const {stdout} = f.run();

  assert.equal(JSON.parse(stdout.trim()).result, 'error');
});

test('every reply leaves the running phase, including ones that parse to nothing', t => {
  for (const raw of ['{"result":"success"}', '{"result":"already-installed"}', '', '   ', 'not json at all']) {
    const f = fixture(t);
    f.ctx.onboardingPhase = 'running';

    f.ctx.resolveOnboarding(raw);

    assert.equal(f.ctx.onboardingPhase, 'done', `phase stuck on input ${JSON.stringify(raw)}`);
    assert.ok(f.ctx.onboardingResult, `no result to show for input ${JSON.stringify(raw)}`);
    assert.equal(f.ctx.onboardingWatchdog.running, false);
    assert.equal(f.ctx.onboardingDone, true);
  }
});

test('unreadable output is surfaced as a failure with a message, not a blank done screen', t => {
  const f = fixture(t);
  f.ctx.onboardingPhase = 'running';

  f.ctx.resolveOnboarding('');

  assert.equal(f.ctx.onboardingResult.result, 'failed');
  assert.match(f.ctx.onboardingResult.error, /nothing was changed/);
});

test('a late reply after the phase has moved on does not re-resolve it', t => {
  const f = fixture(t);
  f.ctx.onboardingPhase = 'running';
  f.ctx.resolveOnboarding('{"result":"success"}');

  f.ctx.onboardingPhase = 'ask';
  f.ctx.resolveOnboarding('{"result":"failed"}');

  assert.equal(f.ctx.onboardingPhase, 'ask');
  assert.deepEqual(f.ctx.onboardingResult, {result: 'success'});
});

test('accepting starts a tracked process and arms the watchdog', t => {
  const f = fixture(t);
  fs.writeFileSync(f.ctx.bindingsLuaPath, validBindings);

  f.ctx.acceptOnboardingShortcuts();

  assert.equal(f.ctx.onboardingPhase, 'running');
  assert.equal(f.ctx.onboardingProcess.running, true);
  assert.equal(f.ctx.onboardingWatchdog.running, true);
  assert.match(f.ctx.onboardingProcess.command.join(' '), /activatePresetSlot/);
});
