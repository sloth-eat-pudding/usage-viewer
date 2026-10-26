'use strict'
const fs = require('node:fs')
const path = require('node:path')
const crypto = require('node:crypto')
const { connect, debuggerUrl } = require('./codex-native-meter.cjs')

// Runs in the verified local Codex renderer. Only these read-only methods are allowed.
async function rendererQuery() {
  if (typeof window.electronBridge?.sendMessageFromView !== 'function') throw Error('Unsupported desktop bridge')
  const request = (method, params) => new Promise((resolve, reject) => {
    const id = 'usage-viewer-quota:' + crypto.randomUUID()
    const done = () => { clearTimeout(timer); window.removeEventListener('message', on) }
    const on = event => {
      const data = event.data
      if (data?.type !== 'mcp-response' || data.hostId !== 'local' || data.message?.id !== id) return
      done()
      data.message.error ? reject(Error('Desktop account query failed')) : resolve(data.message.result)
    }
    const timer = setTimeout(() => { done(); reject(Error('Desktop account query timed out')) }, 10000)
    window.addEventListener('message', on)
    Promise.resolve().then(() => window.electronBridge.sendMessageFromView({ type: 'mcp-request', hostId: 'local',
      request: { id, method, params }, source: 'account', timeoutMs: 8000 }))
      .catch(() => { done(); reject(Error('Desktop bridge disconnected')) })
  })
  const before = await request('account/read', { refreshToken: false })
  if (!before?.account || before.account.type !== 'chatgpt') throw Error('Desktop account is signed out')
  const limits = await request('account/rateLimits/read')
  const after = await request('account/read', { refreshToken: false })
  const identity = account => account && [account.id, account.email].some(value => typeof value === 'string' && value.length > 0)
    ? JSON.stringify([account.id, account.email, account.planType]) : null
  if (!identity(before.account) || identity(before.account) !== identity(after?.account)) throw Error('Desktop account changed during query')
  return { identity: identity(after.account), limits }
}

function normalize(result, profileId, now = new Date().toISOString()) {
  if (!result?.identity || !/^[a-z0-9_-]+$/i.test(profileId)) throw Error('Missing account pairing')
  const response = result.limits
  // A present map is authoritative; never fall back to an unrelated legacy bucket.
  const bucket = response?.rateLimitsByLimitId != null ? response.rateLimitsByLimitId.codex : response?.rateLimits
  if (!bucket || (bucket.limitId && bucket.limitId !== 'codex')) throw Error('Unsupported Codex limit bucket')
  const windows = [bucket.primary, bucket.secondary].filter(Boolean)
  const window = minutes => {
    const value = windows.find(w => w.windowDurationMins === minutes)
    if (!value) return { used: null, reset: null }
    if (typeof value.usedPercent !== 'number' || !Number.isFinite(value.usedPercent) || value.usedPercent < 0 || value.usedPercent > 100 ||
        !Number.isSafeInteger(value.resetsAt) || value.resetsAt <= 0) throw Error('Invalid desktop quota window')
    return { used: value.usedPercent, reset: value.resetsAt }
  }
  const five = window(300), seven = window(10080)
  if (five.used === null && seven.used === null) throw Error('Unsupported desktop quota windows')
  return { generated_at: now, observed_at: now, source: 'codex-desktop-bridge', source_mode: 'desktop',
    profile_id: profileId, account_key: crypto.createHash('sha256').update(result.identity).digest('hex'),
    percentages: { five_hour_used: five.used, seven_day_used: seven.used, primary_limit_used: seven.used },
    resets_at: { five_hour_epoch_seconds: five.reset, seven_day_epoch_seconds: seven.reset },
    rate_limits: { plan_type: typeof bucket.planType === 'string' ? bucket.planType : null } }
}

async function json(origin, route) {
  const response = await fetch(origin + route, { signal: AbortSignal.timeout(3000), redirect: 'error' })
  if (!response.ok) throw Error('Desktop debugger unavailable')
  return response.json()
}

async function query(config) {
  const origin = `http://127.0.0.1:${config.port}`
  const version = await json(origin, '/json/version')
  const browser = debuggerUrl(version.webSocketDebuggerUrl, config.port, 'browser')
  if (browser.pathname !== `/devtools/browser/${config.browser_id}`) throw Error('Desktop browser changed')
  const targets = (await json(origin, '/json/list')).filter(t => {
    try { const url = new URL(t.url); return t.type === 'page' && url.protocol === 'app:' && url.host === '-' && url.pathname === '/index.html' && !url.search && !url.hash } catch { return false }
  })
  if (targets.length !== 1) throw Error('Ambiguous desktop main window')
  const client = await connect(debuggerUrl(targets[0].webSocketDebuggerUrl, config.port, 'page').href)
  try {
    const result = await client.send('Runtime.evaluate', { expression: `(${rendererQuery})()`, awaitPromise: true, returnByValue: true }, 35000)
    if (result.exceptionDetails || !result.result?.value) {
      const message = result.exceptionDetails?.exception?.description?.split('\n')[0]
      throw Error(message?.startsWith('Error: Desktop') || message === 'Error: Unsupported desktop bridge' ? message : 'Desktop bridge query unavailable or signed out')
    }
    return normalize(result.result.value, config.id)
  } finally { client.close() }
}

async function retryQuery(config, read = query, delay = ms => new Promise(resolve => setTimeout(resolve, ms))) {
  let last
  for (let attempt = 0; attempt < 3; attempt++) {
    try { return await read(config) } catch (error) { last = error }
    if (attempt < 2) await delay(250 * (attempt + 1))
  }
  throw last
}

function writeAtomic(file, data) {
  fs.mkdirSync(path.dirname(file), { recursive: true })
  const temp = `${file}.${process.pid}.tmp`
  try {
    fs.writeFileSync(temp, JSON.stringify(data, null, 2))
    for (let attempt = 0; ; attempt++) {
      try { fs.renameSync(temp, file); break }
      catch (error) {
        if (attempt >= 5 || !['EPERM', 'EACCES', 'EBUSY'].includes(error.code)) throw error
        Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 50)
      }
    }
  }
  finally { fs.rmSync(temp, { force: true }) }
}

function readFreshBridge(home, now = Date.now()) {
  try {
    const data = JSON.parse(fs.readFileSync(path.join(home, 'codex-desktop-bridge-latest.json'), 'utf8'))
    const age = now - Date.parse(data.observed_at)
    return data.source === 'codex-desktop-bridge' && age >= -5000 && age < 90000 ? data : null
  } catch { return null }
}

async function main() {
  let input = ''
  for await (const chunk of process.stdin) input += chunk
  const configs = JSON.parse(input.replace(/^\uFEFF/, ''))
  await Promise.all(configs.map(async config => {
    try {
      const snapshot = await retryQuery(config)
      writeAtomic(path.join(config.output, 'codex-desktop-bridge-latest.json'), snapshot)
      // Account-specific files are always separate, including profiles with no session events.
      writeAtomic(path.join(config.home, `codex-account-${config.id}-latest.json`), snapshot)
      console.log(JSON.stringify({ profile: config.id, status: 'ok', five_hour: snapshot.percentages.five_hour_used, seven_day: snapshot.percentages.seven_day_used }))
    } catch (error) {
      const unavailable = { source: 'codex-desktop-bridge', profile_id: config.id, generated_at: new Date().toISOString(), status: 'unavailable' }
      try {
        writeAtomic(path.join(config.output, 'codex-desktop-bridge-latest.json'), unavailable)
        writeAtomic(path.join(config.home, `codex-account-${config.id}-latest.json`), unavailable)
      } catch { /* A locked cache still expires; other accounts continue independently. */ }
      console.error(JSON.stringify({ profile: config.id, status: 'unavailable', reason: error.message }))
    }
  }))
}
if (require.main === module) main().catch(() => { console.error('Desktop discovery input failed'); process.exitCode = 1 })
module.exports = { normalize, rendererQuery, query, retryQuery, readFreshBridge }
