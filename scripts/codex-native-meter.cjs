'use strict'
const fs = require('node:fs')
const path = require('node:path')
const os = require('node:os')
const { readSession } = require('./codex-profile-metrics.cjs')

function estimateCacheWindow(data, now = Date.now()) {
  const model = /^gpt-(\d+)(?:\.(\d+))?(?:-|$)/i.exec(data.model?.id || data.model?.name || '')
  const eligible = model && (Number(model[1]) >= 6 || (Number(model[1]) === 5 && Number(model[2]) >= 6))
  const observed = Date.parse(data.observed_at || '')
  const usedCache = ['cache_read_input', 'cache_creation_input'].some(key =>
    typeof data.tokens?.[key] === 'number' && Number.isFinite(data.tokens[key]) && data.tokens[key] > 0)
  if (!eligible || !usedCache || !Number.isFinite(observed) || observed > now + 60000) return null
  // User-requested approximation based on API docs, not a measured Desktop TTL.
  return { assumed_ttl_seconds: 1800, expires_at: new Date(observed + 1800000).toISOString() }
}

function readNativeSnapshot(directory) {
  try {
    const data = JSON.parse(fs.readFileSync(path.join(directory, 'codex-desktop-latest.json'), 'utf8'))
    const percent = value => typeof value === 'number' && Number.isFinite(value) && value >= 0 && value <= 100 ? value : null
    return {
      observed_at: typeof data.observed_at === 'string' ? data.observed_at : null,
      five_hour_used: percent(data.percentages?.five_hour_used),
      seven_day_used: percent(data.percentages?.seven_day_used),
      cached_input: percent(data.percentages?.cached_input),
      cache_estimate: estimateCacheWindow(data)
    }
  } catch { return null }
}

function options(argv) {
  const result = { port: 19335, mode: 'once' }
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i]
    if (arg === '--port') result.port = Number(argv[++i])
    else if (arg === '--browser-id') result.browserId = argv[++i]
    else if (arg === '--screenshot') result.screenshot = path.resolve(argv[++i])
    else if (arg === '--watch') result.mode = 'watch'
    else if (arg === '--remove') result.mode = 'remove'
    else if (arg === '--reinstall') result.reinstall = true
    else if (arg === '--codex-home') result.codexHome = path.resolve(argv[++i])
    else throw new Error(`Unknown argument: ${arg}`)
  }
  if (!Number.isInteger(result.port) || result.port < 1024 || result.port > 65535 ||
      !/^[a-f0-9-]{36}$/i.test(result.browserId || '')) throw new Error('Explicit verified --browser-id and valid port required')
  return result
}

function debuggerUrl(value, port, kind) {
  const url = new URL(value)
  if (url.protocol !== 'ws:' || url.hostname !== '127.0.0.1' || Number(url.port) !== port ||
      url.username || url.password || url.search || url.hash ||
      !new RegExp(`^/devtools/${kind}/[a-z0-9-]+$`, 'i').test(url.pathname)) throw new Error('Nonlocal or unexpected debugger URL')
  return url
}

async function connect(url) {
  const socket = new WebSocket(url)
  await new Promise((resolve, reject) => {
    const timer = setTimeout(() => { socket.close(); reject(new Error('CDP connection timeout')) }, 5000)
    socket.onopen = () => { clearTimeout(timer); resolve() }
    socket.onerror = () => { clearTimeout(timer); reject(new Error('CDP connection failed')) }
  })
  let next = 0
  const pending = new Map()
  socket.onmessage = event => {
    const message = JSON.parse(event.data)
    const entry = pending.get(message.id)
    if (!entry) return
    pending.delete(message.id)
    clearTimeout(entry.timer)
    message.error ? entry.reject(new Error(message.error.message)) : entry.resolve(message.result)
  }
  socket.onclose = () => {
    for (const entry of pending.values()) { clearTimeout(entry.timer); entry.reject(new Error('CDP disconnected')) }
    pending.clear()
  }
  return {
    send(method, params = {}) {
      return new Promise((resolve, reject) => {
        const id = ++next
        const timer = setTimeout(() => { pending.delete(id); reject(new Error('CDP request timeout')) }, 5000)
        pending.set(id, { resolve, reject, timer })
        socket.send(JSON.stringify({ id, method, params }))
      })
    },
    close() { socket.close() }
  }
}

async function json(url) {
  const response = await fetch(url, { signal: AbortSignal.timeout(5000), redirect: 'error' })
  if (!response.ok) throw new Error(`CDP HTTP ${response.status}`)
  return response.json()
}

async function run(config) {
  const origin = `http://127.0.0.1:${config.port}`
  const version = await json(`${origin}/json/version`)
  const browser = debuggerUrl(version.webSocketDebuggerUrl, config.port, 'browser')
  if (browser.pathname !== `/devtools/browser/${config.browserId}`) throw new Error('Browser identity changed; refusing injection')
  const targets = (await json(`${origin}/json/list`)).filter(target => {
    if (target.type !== 'page') return false
    try { const url = new URL(target.url); return url.protocol === 'app:' && url.host === '-' && url.pathname === '/index.html' } catch { return false }
  })
  const localPayload = path.join(__dirname, 'codex-native-meter.js')
  const payload = fs.readFileSync(fs.existsSync(localPayload) ? localPayload : path.join(__dirname, '../src/desktop-addon/codex-native-meter.js'), 'utf8')
  let mounted = 0
  for (const target of targets) {
    const client = await connect(debuggerUrl(target.webSocketDebuggerUrl, config.port, 'page').href)
    try {
      // Only the active thread ID is read from the renderer, never text or credentials.
      const reset = config.reinstall ? 'window.__usageViewerCodexNativeMeter?.destroy();delete window.__usageViewerCodexNativeMeter;' : ''
      if (config.mode !== 'remove') await client.send('Runtime.evaluate', { expression: `${reset}${payload}` })
      const active = config.mode === 'remove' ? null : await client.send('Runtime.evaluate', {
        expression: 'window.__usageViewerCodexNativeMeter.threadId()', returnByValue: true })
      const threadId = active?.result?.value || null
      const data = readSession(config.codexHome || process.env.CODEX_HOME || path.join(os.homedir(), '.codex'), threadId)
      const snapshot = data ? { ...data, model: undefined, tokens: undefined, cache_estimate: estimateCacheWindow(data), thread_id: threadId } : null
      const expression = config.mode === 'remove' ? 'window.__usageViewerCodexNativeMeter?.destroy()' :
        `window.__usageViewerCodexNativeMeter.update(${JSON.stringify(snapshot)});window.__usageViewerCodexNativeMeter.status()`
      const result = await client.send('Runtime.evaluate', { expression, returnByValue: true })
      if (result.exceptionDetails) throw new Error('Renderer rejected the meter payload')
      if (result.result?.value?.mounted) {
        mounted++
        if (config.screenshot) {
          const shot = await client.send('Page.captureScreenshot', { format: 'png' })
          fs.writeFileSync(config.screenshot, Buffer.from(shot.data, 'base64'))
          config.screenshot = null
        }
      }
    } finally { client.close() }
  }
  return { targets: targets.length, mounted, mode: config.mode }
}

async function main() {
  const config = options(process.argv.slice(2))
  console.log(JSON.stringify(await run(config)))
  config.reinstall = false
  if (config.mode === 'watch') {
    let failures = 0
    const timer = setInterval(async () => {
      if (main.pending) return
      main.pending = true
      try { await run(config); failures = 0 } catch (error) {
        if (++failures >= 6) { clearInterval(timer); console.error(error.message); process.exitCode = 1 }
      }
      finally { main.pending = false }
    }, 5000)
  }
}
if (require.main === module) main().catch(error => { console.error(error.message); process.exitCode = 1 })
module.exports = { options, debuggerUrl, readNativeSnapshot, estimateCacheWindow, run }
