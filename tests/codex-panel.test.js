'use strict'
const { test } = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { readPanelSnapshot, handlePanelRequest } = require('../src/readers/codex-panel')

test('panel exposes only display data and preserves zero; missing or partial snapshots stay unknown', () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'codex-panel-'))
  try {
    assert.equal(readPanelSnapshot(directory), null)
    const file = path.join(directory, 'codex-desktop-latest.json')
    fs.writeFileSync(file, JSON.stringify({ source_file: 'PRIVATE PATH', session: { id: 'PRIVATE ID' },
      percentages: { five_hour_used: 0, seven_day_used: 101, cached_input: '20' },
      tokens: { session_total: 123 }, model: { name: 'test-model' } }))
    const result = readPanelSnapshot(directory)
    assert.equal(result.five_hour_used, 0)
    assert.equal(result.seven_day_used, null)
    assert.equal(result.cached_input, null)
    assert.equal(result.session_tokens, 123)
    assert.equal(result.model, 'test-model')
    assert.ok(!JSON.stringify(result).includes('PRIVATE'))
    fs.writeFileSync(file, '{')
    assert.equal(readPanelSnapshot(directory), null)
  } finally { fs.rmSync(directory, { recursive: true, force: true }) }
})

test('panel refuses foreign origins and DNS rebinding hosts, and reports missing data as unavailable', () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'codex-panel-'))
  const request = (headers = {}, method = 'GET', url = '/codex-panel-data') => {
    const response = { writeHead(status, headers) { this.status = status; this.headers = headers }, end(body) { this.body = body } }
    const handled = handlePanelRequest({ url, method, headers: { host: '127.0.0.1:8765', ...headers } }, response, directory, 8765)
    return { handled, ...response }
  }
  try {
    assert.equal(request().status, 503)
    assert.equal(request({ origin: 'https://claude.ai' }).status, 403)
    assert.equal(request({ host: 'attacker.example:8765' }).status, 403)
    assert.equal(request({ 'sec-fetch-site': 'cross-site' }).status, 403)
    assert.equal(request({}, 'POST').status, 403)
    const html = request({}, 'GET', '/codex-panel')
    assert.equal(html.status, 200)
    assert.ok(html.headers['Content-Security-Policy'].includes("connect-src 'self'"))
    assert.equal(request({}, 'GET', '/other').handled, false)
  } finally { fs.rmSync(directory, { recursive: true, force: true }) }
})
