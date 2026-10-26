'use strict'
const fs = require('node:fs')
const path = require('node:path')
// Standard, short-context API equivalents, USD / million tokens. Checked 2026-10-26.
// https://developers.openai.com/api/docs/pricing
const rates = { 'gpt-6.1-sol': [2, .1, 10], 'gpt-6-astra': [10, 1, 50],
  'gpt-6-luna': [.1, .01, .5], 'gpt-5.6-sol': [4, .4, 20] }
const validId = value => typeof value === 'string' && /^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i.test(value)
const count = value => typeof value === 'number' && Number.isSafeInteger(value) && value >= 0
function summarize(text, id) {
  if (!validId(id)) return null
  let identity, model, lastModel, last, limits, observed, previous = [0, 0, 0], usd = 0, complete = true, events = 0
  for (const line of text.split(/\r?\n/)) {
    let e
    try { e = JSON.parse(line) } catch { if (line.trim()) complete = false; continue }
    if (e.type === 'session_meta') { identity = e.payload?.id || e.payload?.session_id; model = e.payload?.model || model }
    if (e.type === 'turn_context') model = e.payload?.model || model
    if (e.type !== 'event_msg' || e.payload?.type !== 'token_count') continue
    limits = e.rate_limits || e.payload.rate_limits || limits
    const total = e.payload.info?.total_token_usage, usage = e.payload.info?.last_token_usage
    if (!total) { complete = false; continue }
    const current = [total.input_tokens, total.cached_input_tokens, total.output_tokens]
    if (!current.every(count) || current[1] > current[0]) { complete = false; continue }
    if (current.every((v, i) => v === previous[i])) continue // quota refreshes do not renew the cache clock
    let delta = current.map((v, i) => v - previous[i])
    if (delta.some(v => v < 0)) { complete = false; delta = current }
    previous = current
    const rate = rates[model]
    const long = usage?.input_tokens > 272000
    if (!rate || delta[1] > delta[0] || !usage || !count(usage.input_tokens) || (long && !model.startsWith('gpt-6')) ||
        (usage.cache_write_input_tokens || 0) > 0) complete = false
    else usd += (((delta[0] - delta[1]) * rate[0] + delta[1] * rate[1]) * (long ? 2 : 1) +
      delta[2] * rate[2] * (long ? 1.5 : 1)) / 1e6
    last = usage; lastModel = model; observed = e.timestamp; events++
  }
  if (identity !== id || !events) return null
  const percent = value => typeof value === 'number' && Number.isFinite(value) && value >= 0 && value <= 100 ? value : null
  const windows = Object.values(limits || {}).filter(v => v && typeof v === 'object')
  return { observed_at: observed || null, model: { id: lastModel },
    tokens: { cache_read_input: last?.cached_input_tokens, cache_creation_input: last?.cache_write_input_tokens },
    five_hour_used: percent(windows.find(v => v.window_minutes === 300)?.used_percent),
    seven_day_used: percent(windows.find(v => v.window_minutes === 10080)?.used_percent),
    cached_input: count(last?.input_tokens) && last.input_tokens > 0 && count(last.cached_input_tokens)
      ? percent(100 * last.cached_input_tokens / last.input_tokens) : null,
    cost_usd: complete ? usd : null }
}
function readSession(home, id) {
  if (!validId(id)) return null
  const matches = []
  function walk(directory) {
    for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
      if (entry.isSymbolicLink()) continue
      const file = path.join(directory, entry.name)
      if (entry.isDirectory()) walk(file)
      else if (entry.name.endsWith(`${id}.jsonl`)) matches.push(file)
    }
  }
  try {
    walk(path.join(home, 'sessions'))
    if (matches.length !== 1) return null
    return summarize(fs.readFileSync(matches[0], 'utf8'), id)
  } catch { return null }
}
module.exports = { summarize, readSession, validId }
