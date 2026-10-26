'use strict'
const { test } = require('node:test')
const assert = require('node:assert/strict')
const { options, debuggerUrl, readNativeSnapshot } = require('../scripts/codex-native-meter.cjs')
const identity = '11111111-2222-3333-4444-555555555555'
test('native snapshots minimize data and distinguish zero from unknown', () => {
  const fs = require('node:fs'), path = require('node:path'), os = require('node:os')
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'codex-native-'))
  try {
    assert.equal(readNativeSnapshot(directory), null)
    const file = path.join(directory, 'codex-desktop-latest.json')
    fs.writeFileSync(file, JSON.stringify({ session: { id: 'PRIVATE' }, source_file: 'PRIVATE',
      percentages: { five_hour_used: 0, seven_day_used: 101, cached_input: 0 } }))
    assert.deepEqual(readNativeSnapshot(directory), { observed_at: null, five_hour_used: 0, seven_day_used: null, cached_input: 0 })
    fs.writeFileSync(file, JSON.stringify({ percentages: { cached_input: '100' } }))
    assert.equal(readNativeSnapshot(directory).cached_input, null)
    fs.writeFileSync(file, '{')
    assert.equal(readNativeSnapshot(directory), null)
  } finally { fs.rmSync(directory, { recursive: true, force: true }) }
})
test('native experiment requires an explicit browser identity and bounded port', () => {
  assert.throws(() => options([]))
  for (const port of ['0', '65536', 'abc']) assert.throws(() => options(['--port', port, '--browser-id', identity]))
  assert.throws(() => options(['--browser-id', '../foreign']))
  assert.throws(() => options(['--browser-id', identity, '--typo']))
  assert.equal(options(['--browser-id', identity, '--remove']).mode, 'remove')
})
test('CDP destinations cannot escape the exact loopback port and target kind', () => {
  for (const url of [
    `ws://evil.example:19335/devtools/page/abc`,
    `ws://127.0.0.1:19336/devtools/page/abc`,
    `wss://127.0.0.1:19335/devtools/page/abc`,
    `ws://user:pass@127.0.0.1:19335/devtools/page/abc`,
    `ws://127.0.0.1:19335/devtools/page/abc?redirect=1`,
    `ws://127.0.0.1:19335/devtools/browser/abc`
  ]) assert.throws(() => debuggerUrl(url, 19335, 'page'))
  assert.equal(debuggerUrl(`ws://127.0.0.1:19335/devtools/page/abc`, 19335, 'page').hostname, '127.0.0.1')
})
