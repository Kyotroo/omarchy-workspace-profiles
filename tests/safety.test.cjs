const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');
const {spawn, spawnSync} = require('node:child_process');
const {pathToFileURL} = require('node:url');
const repo = path.resolve(__dirname, '..');
const source = fs.readFileSync(path.join(repo, 'Presets.qml'), 'utf8');
const quote = s => "'" + String(s).replaceAll("'", "'\\''") + "'";

function model(dir) {
  const calls = [];
  const ctx = {
    presets: [{name: 'Work', windows: []}], profiles: [], shortcuts: [], selectedIndex: 0, profileIndex: 0, activationSteps: [],
    closeModes: ['trackedOnly', 'workspaceAll', 'keepExisting'], windowTypes: ['terminal', 'webapp', 'custom'],
    activationRunning: false, activationError: '', mode: 'list',
    pendingWrites: {}, writingPath: '', writingJson: '', saveError: '',
    presetsPath: path.join(dir, 'presets.json'), profilesPath: path.join(dir, 'profiles.json'),
    shortcutsPath: path.join(dir, 'shortcuts.json'),
    activeProfilePath: path.join(dir, 'active-profile.json'), progressPath: path.join(dir, 'activation-progress.json'),
    bar: {run: script => calls.push(script)},
    activationProcess: {running: false, command: []},
    saveProcess: {running: false, command: []},
    Util: {shellQuote: quote, cloneJson: x => JSON.parse(JSON.stringify(x)), execDetached: s => calls.push(s)},
    Qt: {resolvedUrl: p => pathToFileURL(path.join(repo, p))},
    calls
  };
  ctx.root = ctx;
  vm.createContext(ctx);
  for (const match of source.matchAll(/^  function \w+\([^]*?^  }/gm)) vm.runInContext(match[0], ctx);
  return ctx;
}

function fixture(t, clients = []) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'presets-test-'));
  t.after(() => fs.rmSync(dir, {recursive: true, force: true}));
  const env = {...process.env, HYPRLAND_INSTANCE_SIGNATURE: 'test-session', TEST_CLIENTS: path.join(dir, 'clients.json'), TEST_LOG: path.join(dir, 'calls.jsonl')};
  fs.writeFileSync(env.TEST_CLIENTS, JSON.stringify({workspace: 1, clients}));
  fs.writeFileSync(env.TEST_LOG, '');
  const fake = `${quote(process.execPath)} ${quote(path.join(__dirname, 'fake-hyprctl.cjs'))}`;
  const shell = path.join(dir, 'environment.sh');
  fs.writeFileSync(shell, `hyprctl() { ${fake} "$@"; }\nkill() { ${fake} kill "$@"; }\nomarchy-notification-send() { :; }\nsleep() { command sleep 0.005; }\nexport -f hyprctl kill omarchy-notification-send sleep\n`);
  env.BASH_ENV = shell;
  return {dir, env, ctx: model(dir), clients: () => JSON.parse(fs.readFileSync(env.TEST_CLIENTS)).clients,
    logs: () => fs.readFileSync(env.TEST_LOG, 'utf8').trim().split('\n').filter(Boolean).map(JSON.parse)};
}
const client = (address, pid, workspace = 1) => ({address, pid, initialClass: 'test-app', workspace: {id: workspace}});
const profile = (name = 'A', closeMode = 'trackedOnly') => ({name, closeMode, workspaces: [{workspace: 1, preset: 'Work'}]});
function tracked(f, records) {
  fs.writeFileSync(f.ctx.activeProfilePath, JSON.stringify({version: 2, windows: records}));
}
const record = (profile, address, pid, workspace = 1) => ({profile, address, pid, workspace, initialClass: 'test-app', session: 'test-session'});
function run(f, p = profile()) {
  return spawnSync('bash', ['-c', f.ctx.buildProfileScript(p)], {env: f.env, encoding: 'utf8', timeout: 15000});
}

test('closing one window preserves another window with the same PID (#2)', t => {
  const f = fixture(t, [client('0xaa', 100), client('0xbb', 100, 9)]);
  const result = run(f, profile('A', 'workspaceAll'));
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(f.clients().map(c => c.address), ['0xbb']);
});

test('trackedOnly does not close another profile or a moved window (#3)', t => {
  const f = fixture(t, [client('0xaa', 100), client('0xbb', 200, 9)]);
  tracked(f, [record('A', '0xaa', 100), record('B', '0xbb', 200)]);
  const result = run(f, profile('B'));
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(f.clients().map(c => c.address), ['0xaa', '0xbb']);
});

test('profile preflight rejects a missing reference before submitting any launch (#4)', t => {
  const f = fixture(t);
  const p = profile(); p.workspaces.push({workspace: 2, preset: 'Deleted'});
  const result = f.ctx.activateProfile(p);
  assert.notEqual(result, 'ok');
  assert.equal(f.ctx.calls.some(call => !call.startsWith('omarchy-notification-send ')), false);
  assert.equal(f.ctx.activationProcess.running, false);
  assert.match(f.ctx.activationError, /Deleted/);
});

test('saving twice does not dispatch concurrent writers (#5)', t => {
  const f = fixture(t);
  f.ctx.persistJson(f.ctx.presetsPath, [1]);
  f.ctx.persistJson(f.ctx.presetsPath, [1, 2]);
  assert.equal(f.ctx.calls.length, 0, 'saves must be managed, not detached');
  assert.equal(f.ctx.saveProcess.running, true);
  assert.equal(JSON.parse(f.ctx.pendingWrites[f.ctx.presetsPath]).length, 2);
});

test('a second profile request is busy and preserves the first run (#6)', t => {
  const f = fixture(t);
  assert.equal(f.ctx.activateProfile(profile()), 'ok');
  const steps = JSON.stringify(f.ctx.activationSteps);
  assert.equal(f.ctx.activateProfile(profile('B')), 'busy');
  assert.equal(JSON.stringify(f.ctx.activationSteps), steps);
});

test('a refused close fails visibly without killing the app or launching replacements (#2)', t => {
  const f = fixture(t, [client('0xaa', 100), client('0xbb', 100, 9)]);
  f.env.TEST_REFUSE_CLOSE = '1';
  f.ctx.presets[0].windows = [{type: 'custom', value: 'hyprctl open 0xcc 300'}];
  const result = run(f, profile('A', 'workspaceAll'));
  assert.notEqual(result.status, 0);
  assert.deepEqual(f.clients().map(c => c.address), ['0xaa', '0xbb']);
  const progress = JSON.parse(fs.readFileSync(f.ctx.progressPath));
  assert.equal(progress[0].status, 'failed');
  assert.match(progress[0].error, /did not close/);
});

test('matching owned windows close, but reused addresses and old sessions do not (#3)', t => {
  const f = fixture(t, [client('0xaa', 100), client('0xbb', 222), client('0xcc', 300)]);
  tracked(f, [record('A', '0xaa', 100), record('A', '0xbb', 200), {...record('A', '0xcc', 300), session: 'previous-session'}]);
  assert.equal(run(f).status, 0);
  assert.deepEqual(f.clients().map(c => c.address), ['0xbb', '0xcc']);
});

test('legacy records without process/session identity are left alone (#3)', t => {
  const f = fixture(t, [client('0xaa', 100)]);
  fs.writeFileSync(f.ctx.activeProfilePath, JSON.stringify({profile: 'A', windows: [{workspace: 1, address: '0xaa'}]}));
  assert.equal(run(f).status, 0);
  assert.deepEqual(f.clients().map(c => c.address), ['0xaa']);
});

test('a closed window record cannot later claim a reused address in the same process (#3)', t => {
  const f = fixture(t, [client('0xaa', 100)]);
  tracked(f, [record('A', '0xaa', 100)]);
  assert.equal(run(f).status, 0);
  assert.deepEqual(JSON.parse(fs.readFileSync(f.ctx.activeProfilePath)).windows, []);
  fs.writeFileSync(f.env.TEST_CLIENTS, JSON.stringify({workspace: 1, clients: [client('0xaa', 100)]}));
  assert.equal(run(f).status, 0);
  assert.equal(f.clients().length, 1);
});

test('ownership is retained across profile switches and partial launch failure (#3)', t => {
  const f = fixture(t, [client('0xaa', 100)]);
  tracked(f, [record('A', '0xaa', 100)]);
  f.ctx.presets[0].windows = [{type: 'custom', value: 'hyprctl open 0xbb 200'}, {type: 'custom', value: 'false'}];
  const result = run(f, profile('B', 'keepExisting'));
  assert.notEqual(result.status, 0);
  const state = JSON.parse(fs.readFileSync(f.ctx.activeProfilePath));
  assert.deepEqual(state.windows.map(w => [w.profile, w.address]), [['A', '0xaa'], ['B', '0xbb']]);
});

test('deleting a referenced preset is rejected without changing saved data (#4)', t => {
  const f = fixture(t);
  f.ctx.profiles = [profile()];
  f.ctx.deletePresetAt(0);
  assert.equal(f.ctx.presets.length, 1);
  assert.equal(f.ctx.saveProcess.running, false);
});

test('invalid later workspace stops the entire launch before compositor calls (#4)', t => {
  const f = fixture(t, [client('0xaa', 100)]);
  const plan = {name: 'A', closeMode: 'workspaceAll', workspaces: [
    {workspace: 1, preset: 'Work', commands: []}, {workspace: -1, preset: 'Broken', commands: []}
  ]};
  const result = spawnSync('bash', [path.join(repo, 'scripts/activate-profile.sh'), f.dir, JSON.stringify(plan)], {env: f.env, encoding: 'utf8'});
  assert.notEqual(result.status, 0);
  assert.deepEqual(f.logs(), []);
  assert.equal(f.clients().length, 1);
});

function finishSave(f) {
  const [command, ...args] = f.ctx.saveProcess.command;
  const result = spawnSync(command, args, {encoding: 'utf8'});
  f.ctx.saveProcess.running = false;
  f.ctx.finishWrite(result.status);
  return result;
}

test('queued saves finish in order and all files contain their newest snapshot (#5)', t => {
  const f = fixture(t);
  f.ctx.persistJson(f.ctx.presetsPath, [1]);
  f.ctx.persistJson(f.ctx.profilesPath, ['A']);
  f.ctx.persistJson(f.ctx.presetsPath, [1, 2]);
  f.ctx.persistJson(f.ctx.presetsPath, [1, 2, 3]);
  f.ctx.persistJson(f.ctx.shortcutsPath, [{name: 'Work', slot: 1}]);
  for (let i = 0; f.ctx.writingPath && i < 10; i++) assert.equal(finishSave(f).status, 0);
  assert.equal(f.ctx.writingPath, '');
  assert.deepEqual(JSON.parse(fs.readFileSync(f.ctx.presetsPath)), [1, 2, 3]);
  assert.deepEqual(JSON.parse(fs.readFileSync(f.ctx.profilesPath)), ['A']);
  assert.deepEqual(JSON.parse(fs.readFileSync(f.ctx.shortcutsPath)), [{name: 'Work', slot: 1}]);
  assert.equal(fs.readdirSync(f.dir).some(name => /json\./.test(name)), false, 'temporary writes must be cleaned');
});

test('failed save preserves the latest pending edit and succeeds after retry (#5)', t => {
  const f = fixture(t);
  const blocker = path.join(f.dir, 'blocked');
  fs.writeFileSync(blocker, 'not a directory');
  const destination = path.join(blocker, 'presets.json');
  f.ctx.persistJson(destination, [1]);
  f.ctx.persistJson(destination, [1, 2]);
  assert.notEqual(finishSave(f).status, 0);
  assert.match(f.ctx.saveError, /save/);
  assert.deepEqual(JSON.parse(f.ctx.pendingWrites[destination]), [1, 2]);
  fs.unlinkSync(blocker);
  f.ctx.startNextWrite();
  assert.equal(finishSave(f).status, 0);
  assert.deepEqual(JSON.parse(fs.readFileSync(destination)), [1, 2]);
  assert.equal(f.ctx.saveError, '');
});

test('a stale disk reload cannot replace unsaved edits (#5)', t => {
  const f = fixture(t);
  f.ctx.presets = [{name: 'Latest', windows: []}];
  f.ctx.persistPresets();
  f.ctx.loadPresets('[{"name":"Old","windows":[]}]');
  assert.equal(f.ctx.presets[0].name, 'Latest');
});

async function until(predicate) {
  for (let n = 0; n < 300; n++) {
    if (predicate()) return;
    await new Promise(resolve => setTimeout(resolve, 10));
  }
  throw new Error('Timed out waiting for process barrier');
}
function start(f, p) {
  const child = spawn('bash', ['-c', f.ctx.buildProfileScript(p)], {env: f.env, stdio: ['ignore', 'pipe', 'pipe']});
  let stderr = '';
  child.stderr.on('data', data => stderr += data);
  const done = new Promise(resolve => child.on('exit', code => resolve({code, stderr})));
  return {child, done};
}

test('script lock rejects a second process without overwriting progress, then releases (#6)', async t => {
  const f = fixture(t);
  f.env.TEST_GATE = path.join(f.dir, 'release');
  const first = start(f, profile());
  t.after(() => { if (first.child.exitCode === null) first.child.kill(); });
  await until(() => fs.existsSync(f.env.TEST_GATE + '.entered'));
  const before = fs.readFileSync(f.ctx.progressPath, 'utf8');
  const second = run(f, profile('B'));
  assert.equal(second.status, 75, second.stderr);
  assert.equal(fs.readFileSync(f.ctx.progressPath, 'utf8'), before);
  fs.writeFileSync(f.env.TEST_GATE, '');
  const result = await first.done;
  assert.equal(result.code, 0, result.stderr);
  delete f.env.TEST_GATE;
  assert.equal(run(f, profile('B')).status, 0);
});

test('running applications do not inherit the activation lock (#6)', t => {
  const f = fixture(t);
  f.ctx.presets[0].windows = [{type: 'custom', value: 'hyprctl open 0xbb 200; command sleep 1'}];
  assert.equal(run(f, profile('A', 'keepExisting')).status, 0);
  f.ctx.presets[0].windows = [];
  assert.equal(run(f, profile('B', 'keepExisting')).status, 0);
});

test('failed activation releases the process lock for a retry (#6)', t => {
  const f = fixture(t, [client('0xaa', 100)]);
  f.env.TEST_REFUSE_CLOSE = '1';
  assert.notEqual(run(f, profile('A', 'workspaceAll')).status, 0);
  delete f.env.TEST_REFUSE_CLOSE;
  assert.equal(run(f, profile('A', 'workspaceAll')).status, 0);
  assert.equal(f.clients().length, 0);
});
