'use strict'
const assert = require('node:assert/strict')
const fs = require('node:fs')
const vm = require('node:vm')
const http = require('node:http')
const net = require('node:net')
const { spawn } = require('node:child_process')
const path = require('node:path')
const source = fs.readFileSync(process.argv[2], 'utf8').replace(/^\uFEFF/, '')
const bridge = require('../src/readers/claude-usage-contract')
assert.throws(() => bridge.normalizeUsage({}, 'org'))
for (const value of [null, undefined, '', ' ', false, -1, 101]) {
  assert.throws(() => bridge.normalizeUsage({ five_hour: { utilization: value } }, 'org'))
}
assert.equal(bridge.normalizeUsage({ five_hour: { utilization: 0 } }, 'org').percentages.five_hour_used, 0)
assert.equal(bridge.normalizeUsage({ limits: [{ kind: 'weekly_all', percent: 78 }] }, 'org').percentages.seven_day_used, 78)

async function run() {
  const calls = []
  const intervals = []
  const timers = new Map()
  let nextTimer = 0
  let apiStatus = 404
  let block = null
  const context = vm.createContext({
    window: {}, AbortController, console: { warn() {} },
    setInterval(fn) { intervals.push(fn); return intervals.length }, clearInterval() {},
    setTimeout(fn) { const id = ++nextTimer; timers.set(id, fn); return id },
    clearTimeout(id) { timers.delete(id) },
    async fetch(url, options) {
      calls.push({ url, options })
      if (url.startsWith('/api/')) {
        if (block) await new Promise((resolve, reject) => {
          block.resolve = resolve
          options.signal.addEventListener('abort', () => reject(new Error('aborted')), { once: true })
        })
        return { ok: apiStatus === 200, status: apiStatus, json: async () => ({ five_hour: { utilization: 0 } }) }
      }
      return { ok: true, status: 204 }
    }
  })
  vm.runInContext(source, context)
  await new Promise(resolve => setImmediate(resolve))
  assert.equal(calls.length, 1)
  apiStatus = 200
  await intervals[0]() // A transient 404 must not permanently remove this account.
  assert.equal(calls.length, 3)
  assert.equal(calls[2].options.method, 'POST')
  assert.equal(calls[0].options.credentials, 'include')
  block = {}
  const pending = intervals[0]()
  const before = calls.length
  await intervals[0]()
  assert.equal(calls.length, before, 'Slow requests must not overlap')
  for (const timeout of timers.values()) timeout()
  await pending
  block = null
  await intervals[0]()
  assert.equal(calls.length, before + 2, 'An aborted request must allow the next refresh')
  assert.equal(timers.size, 0)
  await testHttpBridge()
  console.log('JavaScript tests passed: normalization, transient 404 recovery, timeout recovery, overlap prevention.')
}

async function testHttpBridge() {
  const reservation = net.createServer()
  await new Promise(resolve => reservation.listen(0, '127.0.0.1', resolve))
  const port = reservation.address().port
  await new Promise(resolve => reservation.close(resolve))
  const child = spawn(process.execPath, [path.join(__dirname, '../src/readers/claude-desktop-usage-bridge.js')], {
    env: { ...process.env, USAGE_VIEWER_HOME: path.dirname(process.argv[2]), CLAUDE_DESKTOP_USAGE_BRIDGE_PORT: String(port) },
    stdio: 'ignore'
  })
  function request(endpoint, body) {
    return new Promise((resolve, reject) => {
      const req = http.request({ hostname: '127.0.0.1', port, path: endpoint, method: body ? 'POST' : 'GET',
        headers: { Origin: 'https://claude.ai', 'Content-Type': 'application/json' }, timeout: 1000 }, res => {
        res.resume(); res.on('end', () => resolve(res.statusCode))
      })
      req.on('error', reject); req.on('timeout', () => req.destroy(new Error('request timeout')))
      req.end(body ? JSON.stringify(body) : undefined)
    })
  }
  try {
    let ready = false
    for (let attempt = 0; attempt < 30; attempt++) {
      try { ready = await request('/health') === 200 } catch {}
      if (ready) break
      await new Promise(resolve => setTimeout(resolve, 100))
    }
    assert.equal(ready, true, 'Bridge must start')
    const org = '11111111-1111-1111-1111-111111111111'
    const refreshId = '22222222-2222-2222-2222-222222222222'
    const endpoint = `/claude-desktop-usage?org=${org}&refresh_id=${refreshId}`
    assert.equal(await request(endpoint, { five_hour: { utilization: 0 } }), 204)
    const file = path.join(path.dirname(process.argv[2]), `claude-desktop-api-${org}-latest.json`)
    const snapshot = JSON.parse(fs.readFileSync(file, 'utf8'))
    assert.equal(snapshot.refresh_id, refreshId)
    assert.equal(snapshot.percentages.five_hour_used, 0)
    assert.equal(await request(endpoint, {}), 400)
    assert.equal(JSON.parse(fs.readFileSync(file, 'utf8')).refresh_id, refreshId, 'Invalid input must not overwrite valid data')
    assert.equal(await request(`/claude-desktop-usage?org=${org}&refresh_id=invalid`, { five_hour: { utilization: 0 } }), 400)
    const heartbeatPath = '/claude-session-meter-heartbeat?instance=11-1234'
    assert.equal(await request(heartbeatPath, { version: '1.1.0', refresh_id: refreshId, transcript: 'must not persist' }), 204)
    const heartbeatFile = path.join(path.dirname(process.argv[2]), 'claude-session-meter-11-1234-latest.json')
    const heartbeat = JSON.parse(fs.readFileSync(heartbeatFile, 'utf8'))
    assert.equal(heartbeat.instance, '11-1234')
    assert.equal(heartbeat.refresh_id, refreshId)
    assert.equal(heartbeat.transcript, undefined)
    assert.equal(await request('/claude-session-meter-heartbeat?instance=22-5678', { version: '1.1.0', refresh_id: refreshId }), 204)
    assert.equal(JSON.parse(fs.readFileSync(heartbeatFile, 'utf8')).instance, '11-1234', 'Second profile must not overwrite the first heartbeat')
    assert.equal(await request('/claude-session-meter-heartbeat?instance=../bad', { version: '1.1.0', refresh_id: refreshId }), 400)
    assert.equal(await request(heartbeatPath, { version: 'bad', refresh_id: refreshId }), 400)
    console.log('HTTP bridge tests passed: acknowledgement, zero usage, invalid response rejection, snapshot preservation.')
  } finally {
    child.kill()
    await new Promise(resolve => { if (child.exitCode !== null) resolve(); else child.once('exit', resolve) })
  }
}
run().catch(error => { console.error(error); process.exitCode = 1 })
