'use strict'

// Receives the Claude Desktop usage response from a DevTools snippet. The
// authenticated request stays inside Claude Desktop; this process receives
// only usage percentages and reset timestamps over the loopback interface.
const fs = require('fs')
const http = require('http')
const os = require('os')
const path = require('path')
const { normalizeUsage } = require('./claude-usage-contract')
const { readSubagentUsage } = require('./claude-subagent-usage')

const USAGE_VIEWER_HOME = process.env.USAGE_VIEWER_HOME ||
  path.join(os.homedir(), '.usage-viewer')
const PORT = Number.parseInt(process.env.CLAUDE_DESKTOP_USAGE_BRIDGE_PORT || '8765', 10)
const ALLOWED_ORIGINS = new Set(['https://claude.ai', 'https://www.claude.ai'])
const MAX_BODY_BYTES = 64 * 1024
const ORGANIZATION_ID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

if (!Number.isInteger(PORT) || PORT < 1 || PORT > 65535) {
  throw new Error('CLAUDE_DESKTOP_USAGE_BRIDGE_PORT must be a valid TCP port')
}

http.createServer((request, response) => {
  const origin = request.headers.origin || ''
  const requestUrl = new URL(request.url || '/', 'http://127.0.0.1')

  if (request.method === 'OPTIONS') {
    if (!ALLOWED_ORIGINS.has(origin)) return respond(response, 403)
    response.writeHead(204, corsHeaders(origin))
    return response.end()
  }

  if (request.method === 'GET' && requestUrl.pathname === '/health') {
    return respond(response, 200, { status: 'ok' })
  }

  if (request.method === 'GET' && requestUrl.pathname === '/claude-subagent-usage') {
    if (!ALLOWED_ORIGINS.has(origin)) return respond(response, 403)
    try { return respond(response, 200, readSubagentUsage(requestUrl.searchParams.get('session') || ''), origin) }
    catch { return respond(response, 400, { error: 'Invalid session ID' }, origin) }
  }

  const isMeterHeartbeat = requestUrl.pathname === '/claude-session-meter-heartbeat'
  if (request.method !== 'POST' || (!isMeterHeartbeat && requestUrl.pathname !== '/claude-desktop-usage')) {
    return respond(response, 404)
  }

  if (!ALLOWED_ORIGINS.has(origin)) {
    return respond(response, 403)
  }

  const organizationId = requestUrl.searchParams.get('org') || ''
  const instance = requestUrl.searchParams.get('instance') || ''
  if (isMeterHeartbeat && !/^\d{1,10}-\d{1,20}$/.test(instance)) {
    return respond(response, 400, { error: 'Invalid window instance' }, origin)
  }
  if (!isMeterHeartbeat && !ORGANIZATION_ID_PATTERN.test(organizationId)) {
    return respond(response, 400, { error: 'A valid org query parameter is required' }, origin)
  }

  let body = ''
  let tooLarge = false
  request.setEncoding('utf8')
  request.on('data', chunk => {
    body += chunk
    if (Buffer.byteLength(body, 'utf8') > MAX_BODY_BYTES) {
      tooLarge = true
      request.destroy()
    }
  })
  request.on('end', () => {
    if (tooLarge) return respond(response, 413, { error: 'Payload too large' }, origin)

    try {
      if (isMeterHeartbeat) {
        const data = JSON.parse(body)
        if (!data || typeof data.version !== 'string' || !/^\d+\.\d+\.\d+$/.test(data.version) ||
            typeof data.refresh_id !== 'string' || !ORGANIZATION_ID_PATTERN.test(data.refresh_id)) throw new Error('Invalid meter heartbeat')
        // Only a window identity and version are persisted, never session text.
        writeJsonAtomic(path.join(USAGE_VIEWER_HOME, `claude-session-meter-${instance}-latest.json`), {
          source: 'claude-session-meter', instance, version: data.version,
          refresh_id: data.refresh_id, observed_at: new Date().toISOString()
        })
        return respond(response, 204, null, origin)
      }
      const snapshot = normalizeUsage(JSON.parse(body), organizationId)
      const refreshId = requestUrl.searchParams.get('refresh_id') || ''
      if (refreshId && !ORGANIZATION_ID_PATTERN.test(refreshId)) throw new Error('Invalid refresh_id')
      if (refreshId) snapshot.refresh_id = refreshId
      fs.mkdirSync(USAGE_VIEWER_HOME, { recursive: true })
      writeJsonAtomic(snapshotFileForOrganization(organizationId), snapshot)
      respond(response, 204, null, origin)
    } catch (error) {
      respond(response, 400, { error: error.message }, origin)
    }
  })
}).listen(PORT, '127.0.0.1', () => {
  process.stdout.write(`Claude Desktop usage bridge listening on 127.0.0.1:${PORT}\n`)
})

function snapshotFileForOrganization(organizationId) {
  return path.join(USAGE_VIEWER_HOME, `claude-desktop-api-${organizationId}-latest.json`)
}

function corsHeaders(origin) {
  return {
    'Access-Control-Allow-Origin': origin,
    'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type',
    Vary: 'Origin'
  }
}

function respond(response, statusCode, value = null, origin = '') {
  const headers = origin && ALLOWED_ORIGINS.has(origin) ? corsHeaders(origin) : {}
  if (value === null) {
    response.writeHead(statusCode, headers)
    return response.end()
  }

  response.writeHead(statusCode, { ...headers, 'Content-Type': 'application/json' })
  response.end(JSON.stringify(value))
}

function writeJsonAtomic(filename, value) {
  fs.mkdirSync(path.dirname(filename), { recursive: true })
  const temporaryFile = `${filename}.${process.pid}.${Date.now()}.tmp`
  try {
    fs.writeFileSync(temporaryFile, JSON.stringify(value, null, 2), 'utf8')
    fs.renameSync(temporaryFile, filename)
  } finally {
    try { fs.rmSync(temporaryFile, { force: true }) } catch {}
  }
}
