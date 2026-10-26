'use strict'
const { test } = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs'), os = require('node:os'), path = require('node:path')
const { summarize, readSession } = require('../scripts/codex-profile-metrics.cjs')
const id = '11111111-2222-3333-4444-555555555555'
const meta = { type: 'session_meta', payload: { id } }
const context = model => ({ type: 'turn_context', payload: { model } })
const event = (input, cached, output, timestamp = '2026-10-26T08:00:00Z') => ({ type: 'event_msg', timestamp,
  payload: { type: 'token_count', info: { total_token_usage: { input_tokens: input, cached_input_tokens: cached, output_tokens: output },
    last_token_usage: { input_tokens: 1000, cached_input_tokens: 800, output_tokens: 100 } } },
  rate_limits: { primary: { window_minutes: 300, used_percent: 20 }, secondary: { window_minutes: 10080, used_percent: 0 } } })
const text = (...events) => events.map(e => JSON.stringify(e)).join('\n')
test('current-profile matching never reads another folder, session, or symlink', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'codex-profile-'))
  try {
    const home = path.join(root, 'a'), other = path.join(root, 'b')
    for (const dir of [home, other]) fs.mkdirSync(path.join(dir, 'sessions'), { recursive: true })
    const file = path.join(other, 'sessions', `rollout-${id}.jsonl`)
    fs.writeFileSync(file, text(meta, context('gpt-6.1-sol'), event(1000, 800, 100)))
    assert.equal(readSession(home, id), null)
    assert.equal(readSession(other, '../b'), null)
    assert.ok(readSession(other, id))
    fs.writeFileSync(path.join(home, 'sessions', `rollout-${id}.jsonl`), text({ ...meta, payload: { id: 'foreign' } }, event(1000, 800, 100)))
    assert.equal(readSession(home, id), null)
    fs.symlinkSync(path.join(other, 'sessions'), path.join(home, 'sessions', 'linked'), 'junction')
    assert.equal(readSession(home, id), null)
  } finally { fs.rmSync(root, { recursive: true, force: true }) }
})
test('mixed-model cumulative deltas price cached input once and quota refresh does not extend the cache clock', () => {
  const a = event(1000, 800, 100), b = event(2000, 1600, 200, '2026-10-26T08:01:00Z')
  const refresh = { ...b, timestamp: '2026-10-26T08:05:00Z' }
  const summary = summarize(text(meta, context('gpt-6.1-sol'), a, a, context('gpt-6-astra'), b, refresh), id)
  assert.ok(Math.abs(summary.cost_usd - .00928) < 1e-10)
  assert.equal(summary.observed_at, b.timestamp)
  assert.equal(summary.cached_input, 80)
  assert.equal(summary.seven_day_used, 0)
  assert.equal(summary.five_hour_used, 20)
})
test('unknown models, incomplete counters, resets and writes are unknown', () => {
  const a = event(1000, 800, 100)
  for (const body of [
    text(meta, context('unpriced'), a),
    text(meta, context('gpt-6.1-sol'), a, event(900, 700, 50)),
    text(meta, context('gpt-6.1-sol'), a) + '\n{"type":',
    text(meta, context('gpt-5.6-sol'), { ...a, payload: { ...a.payload, info: { ...a.payload.info, last_token_usage: { input_tokens: 300000 } } } }),
    text(meta, context('gpt-6.1-sol'), { ...a, payload: { ...a.payload, info: { ...a.payload.info, last_token_usage: { input_tokens: 1000, cache_write_input_tokens: 200 } } } })
  ]) assert.equal(summarize(body, id).cost_usd, null)
  assert.equal(summarize(text(meta, context('gpt-6.1-sol')), id), null)
  assert.equal(summarize(text(meta, a), 'foreign'), null)
})
test('GPT-6 long context applies input 2x and output 1.5x above 272K', () => {
  const a = event(300000, 200000, 1000)
  a.payload.info.last_token_usage.input_tokens = 300000
  assert.equal(summarize(text(meta, context('gpt-6.1-sol'), a), id).cost_usd, .455)
})
