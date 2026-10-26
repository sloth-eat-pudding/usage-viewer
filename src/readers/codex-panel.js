'use strict'

const fs = require('node:fs')
const path = require('node:path')

// Return only display fields; never expose session paths, IDs, or transcripts.
function readPanelSnapshot(directory) {
  try {
    const data = JSON.parse(fs.readFileSync(path.join(directory, 'codex-desktop-latest.json'), 'utf8'))
    const number = value => typeof value === 'number' && Number.isFinite(value) && value >= 0 ? value : null
    const percent = value => { const n = number(value); return n !== null && n <= 100 ? n : null }
    return {
      observed_at: typeof data.observed_at === 'string' ? data.observed_at : null,
      model: typeof data.model?.name === 'string' ? data.model.name : null,
      five_hour_used: percent(data.percentages?.five_hour_used),
      seven_day_used: percent(data.percentages?.seven_day_used),
      five_hour_reset: number(data.resets_at?.five_hour_epoch_seconds),
      seven_day_reset: number(data.resets_at?.seven_day_epoch_seconds),
      cached_input: percent(data.percentages?.cached_input),
      turn_tokens: number(data.tokens?.total),
      session_tokens: number(data.tokens?.session_total)
    }
  } catch { return null }
}

function handlePanelRequest(request, response, directory, port) {
  const endpoint = (request.url || '').split('?')[0]
  if (!['/codex-panel', '/codex-panel-data'].includes(endpoint)) return false
  const origin = request.headers.origin
  const localOrigin = `http://127.0.0.1:${port}`
  // No cross-origin access, including Claude's otherwise allowed bridge origin.
  if (request.method !== 'GET' || request.headers.host !== `127.0.0.1:${port}` ||
      (origin && origin !== localOrigin) || request.headers['sec-fetch-site'] === 'cross-site') {
    response.writeHead(403)
    response.end()
    return true
  }
  const isData = endpoint === '/codex-panel-data'
  const data = isData ? readPanelSnapshot(directory) : null
  response.writeHead(isData && !data ? 503 : 200, {
    'Content-Type': isData ? 'application/json; charset=utf-8' : 'text/html; charset=utf-8',
    'Cache-Control': 'no-store',
    'X-Content-Type-Options': 'nosniff',
    'Content-Security-Policy': "default-src 'none'; script-src 'self'; style-src 'unsafe-inline'; connect-src 'self'; frame-ancestors 'self'"
  })
  response.end(isData ? JSON.stringify(data || { error: 'snapshot_unavailable' }) :
    fs.readFileSync(path.join(__dirname, '../desktop-addon/codex-panel.html')))
  return true
}

module.exports = { readPanelSnapshot, handlePanelRequest }
