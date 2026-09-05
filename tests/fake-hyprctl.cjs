// Compositor boundary for integration tests. Never contacts a real desktop.
const fs = require('node:fs');
const statePath = process.env.TEST_CLIENTS;
const read = () => JSON.parse(fs.readFileSync(statePath, 'utf8'));
const write = state => fs.writeFileSync(statePath, JSON.stringify(state));
const args = process.argv.slice(2);
const log = value => fs.appendFileSync(process.env.TEST_LOG, JSON.stringify(value) + '\n');
if (args[0] === 'clients') {
  console.log(JSON.stringify(read().clients));
} else if (args[0] === 'activeworkspace') {
  console.log(JSON.stringify({id: read().workspace}));
} else if (args[0] === 'dispatch') {
  log(args);
  const focus = args[1].match(/^hl\.dsp\.focus\(\{ workspace = "(\d+)" \}\)$/);
  const close = args[1].match(/^hl\.dsp\.window\.close\(\{ window = "address:(0x[0-9a-f]+)" \}\)$/);
  if (focus) {
    if (process.env.TEST_GATE) {
      fs.writeFileSync(process.env.TEST_GATE + '.entered', '');
      while (!fs.existsSync(process.env.TEST_GATE)) Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 10);
    }
    const state = read(); state.workspace = Number(focus[1]); write(state);
  } else if (close) {
    if (!process.env.TEST_REFUSE_CLOSE) {
      const state = read(); state.clients = state.clients.filter(c => c.address !== close[1]); write(state);
    }
  } else { console.error('Unsupported dispatch:', args[1]); process.exit(1); }
} else if (args[0] === 'keyword') {
  log(args);
} else if (args[0] === 'kill') {
  log(args);
  const state = read(); state.clients = state.clients.filter(c => c.pid !== Number(args[1])); write(state);
} else if (args[0] === 'open') {
  const state = read();
  state.clients.push({address: args[1], pid: Number(args[2]), initialClass: 'test-app', workspace: {id: state.workspace}});
  write(state);
} else { throw new Error('Unexpected fake hyprctl command: ' + args.join(' ')); }
