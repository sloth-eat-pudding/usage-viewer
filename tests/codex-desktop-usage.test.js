'use strict'
const { test } = require('node:test')
const assert = require('node:assert/strict')
const vm = require('node:vm')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { execFileSync } = require('node:child_process')
const { normalize, retryQuery, rendererQuery, readFreshBridge } = require('../scripts/codex-desktop-usage.cjs')
const { quotaHome } = require('../scripts/codex-native-meter.cjs')
const bucket = (five = 0, seven = 15) => ({ limitId: 'codex', planType: 'plus',
  primary: { windowDurationMins: 300, usedPercent: five, resetsAt: 1800000000 },
  secondary: { windowDurationMins: 10080, usedPercent: seven, resetsAt: 1800500000 } })
const result = (identity, limits = bucket()) => ({ identity, limits: { rateLimits: limits } })

test('account snapshots are independent and only select the Codex bucket', () => {
  assert.equal(quotaHome({ codexHome: path.resolve('second/codex') }), path.resolve('second/usage'), 'Legacy profile watchers cannot borrow default account quota')
  assert.equal(quotaHome({ usageHome: 'explicit' }), 'explicit')
  const first = normalize(result('first'), 'first')
  const second = normalize(result('second', bucket(20, 3)), 'second')
  assert.equal(first.percentages.five_hour_used, 0)
  assert.equal(second.percentages.five_hour_used, 20)
  assert.notEqual(first.account_key, second.account_key)
  assert.equal(JSON.stringify(first).includes('first@'), false)
  assert.equal(normalize({ identity: 'a', limits: { rateLimits: bucket(99), rateLimitsByLimitId: { codex: bucket(10) } } }, 'a').percentages.five_hour_used, 10)
  assert.throws(() => normalize({ identity: 'a', limits: { rateLimits: bucket(), rateLimitsByLimitId: { other: bucket() } } }, 'a'))
  for (const value of [-1, 101, '20', NaN, null]) assert.throws(() => normalize(result('a', bucket(value)), 'a'))
  const partial = bucket(); partial.secondary = null
  assert.equal(normalize(result('a', partial), 'a').percentages.seven_day_used, null)
  assert.throws(() => normalize(result('a'), '../foreign'))
  assert.throws(() => normalize(result(null), 'a'))
})

test('bounded retries recover disconnects without mixing profile configuration', async () => {
  const config = { id: 'second', port: 19339 }
  let calls = 0
  const delays = []
  assert.equal(await retryQuery(config, async received => {
    assert.equal(received, config)
    if (++calls < 3) throw Error('disconnected')
    return 'second account'
  }, async ms => delays.push(ms)), 'second account')
  assert.deepEqual(delays, [250, 500])
  calls = 0
  await assert.rejects(retryQuery(config, async () => { calls++; throw Error('unsupported') }, async () => {}), /unsupported/)
  assert.equal(calls, 3)
})

async function simulate(accounts) {
  const listeners = new Set(), methods = []
  let reads = 0
  const window = {
    addEventListener: (_, callback) => listeners.add(callback),
    removeEventListener: (_, callback) => listeners.delete(callback),
    electronBridge: { async sendMessageFromView(message) {
      methods.push(message.request.method)
      assert.equal(message.hostId, 'local')
      const response = message.request.method === 'account/read' ? { account: accounts[reads++] } : { rateLimits: bucket() }
      for (const callback of [...listeners]) {
        callback({ data: { type: 'mcp-response', hostId: 'foreign', message: { id: message.request.id, result: {} } } })
        callback({ data: { type: 'mcp-response', hostId: 'local', message: { id: message.request.id, result: response } } })
      }
    } }
  }
  try {
    return await vm.runInNewContext(`(${rendererQuery})()`, { window, crypto: require('node:crypto').webcrypto, setTimeout, clearTimeout })
  } finally {
    assert.equal(listeners.size, 0, 'Every request removes its listener')
    assert.ok(methods.every(method => ['account/read', 'account/rateLimits/read'].includes(method)))
  }
}

test('renderer validates login before and after the query and rejects account switches', async () => {
  const account = { type: 'chatgpt', email: 'test@example.invalid', planType: 'plus' }
  assert.ok((await simulate([account, account])).limits)
  await assert.rejects(simulate([account, { ...account, email: 'other@example.invalid' }]), /changed/)
  await assert.rejects(simulate([null]), /signed out/)
  await assert.rejects(simulate([{ type: 'apiKey' }]), /signed out/)
  await assert.rejects(simulate([{ type: 'chatgpt' }, { type: 'chatgpt' }]), /changed/)
})

test('formal reader can publish fresh desktop quota without session events and rejects expired bridge cache', () => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'codex-bridge-'))
  try {
    const file = path.join(home, 'codex-desktop-bridge-latest.json')
    const snapshot = normalize(result('private account'), 'default')
    fs.writeFileSync(file, JSON.stringify(snapshot))
    assert.ok(readFreshBridge(home))
    assert.equal(readFreshBridge(home, Date.now() + 100000), null)
    execFileSync(process.execPath, [path.join(__dirname, '../src/readers/codex-usage-read.js')], {
      env: { ...process.env, USAGE_VIEWER_HOME: home, CODEX_HOME: path.join(home, 'empty') }
    })
    const data = JSON.parse(fs.readFileSync(path.join(home, 'codex-desktop-latest.json')))
    assert.equal(data.source, 'codex-desktop-bridge')
    assert.equal(data.percentages.five_hour_used, 0)
    assert.equal(JSON.stringify(data).includes('private account'), false)
    fs.writeFileSync(file, JSON.stringify({ ...snapshot, observed_at: null, status: 'unavailable' }))
    assert.equal(readFreshBridge(home), null)
  } finally { fs.rmSync(home, { recursive: true, force: true }) }
})
