// Regression coverage for a profile with workspaces being rejected as empty.
//
// profileValidationError() ran Array.isArray() on values that do not always
// arrive as real JS arrays. A Repeater hands its delegate a `modelData` whose
// nested arrays are QVariantList proxies: indexing and .length work, but
// Array.isArray() is false. Clicking a profile row passes exactly that object
// (Presets.qml, the profiles Repeater), so every profile launched by mouse was
// reported as "Add at least one workspace." however many it had.
//
// The array-like below is what those proxies look like to this validator:
// object, numeric .length, integer-keyed entries, not an Array.
const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');
const repo = path.resolve(__dirname, '..');
const source = fs.readFileSync(path.join(repo, 'Presets.qml'), 'utf8');

function ctx(t) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'presets-validation-'));
  t.after(() => fs.rmSync(dir, {recursive: true, force: true}));
  const c = {
    presets: [{name: 'Work', windows: [{type: 'terminal', value: 'btop'}]}],
    profiles: [], closeModes: ['trackedOnly', 'workspaceAll', 'keepExisting'],
    windowTypes: ['terminal', 'webapp', 'custom'],
    JSON, Object, String, Array, Math, isFinite
  };
  c.root = c;
  vm.createContext(c);
  for (const m of source.matchAll(/^  function \w+\([^]*?^  }/gm)) vm.runInContext(m[0], c);
  return c;
}

// Mirrors how a QVariantList reaches JS: not an Array, but indexable with .length.
function arrayLike(items) {
  const out = {length: items.length};
  items.forEach((v, i) => { out[i] = v; });
  Object.setPrototypeOf(out, null);
  return out;
}

const rows = [{workspace: 1, preset: 'Work'}, {workspace: 3, preset: 'Work'}];
const profile = workspaces => ({name: 'Code Profile', closeMode: 'workspaceAll', workspaces});

test('a profile whose workspaces arrive as model data still validates', t => {
  const c = ctx(t);
  const ws = arrayLike(rows);

  assert.equal(Array.isArray(ws), false, 'fixture must not be a real Array');
  assert.equal(c.profileValidationError(profile(ws)), '');
});

test('the same profile as a plain array validates identically', t => {
  const c = ctx(t);

  assert.equal(c.profileValidationError(profile(rows)), '');
});

test('a preset whose windows arrive as model data is not called invalid', t => {
  const c = ctx(t);
  c.presets = [{name: 'Work', windows: arrayLike([{type: 'terminal', value: 'btop'}])}];

  assert.equal(c.profileValidationError(profile(rows)), '');
});

test('a genuinely empty profile is still rejected', t => {
  const c = ctx(t);

  assert.equal(c.profileValidationError(profile([])), 'Add at least one workspace.');
  assert.equal(c.profileValidationError(profile(arrayLike([]))), 'Add at least one workspace.');
});

test('a non-list is still rejected rather than treated as empty', t => {
  const c = ctx(t);

  for (const bad of [undefined, null, 'three', 7, {workspace: 1}]) {
    assert.equal(c.profileValidationError(profile(bad)), 'Add at least one workspace.',
      `accepted ${JSON.stringify(bad)} as a workspace list`);
  }
});

test('real validation failures still surface through a model-data list', t => {
  const c = ctx(t);

  assert.match(c.profileValidationError(profile(arrayLike([{workspace: 1, preset: 'Gone'}]))), /Missing preset: Gone/);
  assert.match(c.profileValidationError(profile(arrayLike([{workspace: 0, preset: 'Work'}]))), /Invalid workspace number/);
  assert.match(c.profileValidationError(profile(arrayLike([
    {workspace: 1, preset: 'Work'}, {workspace: 1, preset: 'Work'}]))), /appears more than once/);
});
