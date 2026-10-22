'use strict'

const assert = require('node:assert/strict')
const test = require('node:test')
const { summarize, combineUsage, readSessionUsage, estimateCost, labels, details, sessionId, install } = require('../src/desktop-addon/claude-session-meter')
const now = Date.parse('2026-10-21T00:00:00Z')
const model = 'claude-opus-5-5'
const idA = 'local_11111111-1111-1111-1111-111111111111'
const idB = 'local_22222222-2222-2222-2222-222222222222'
const usage = overrides => ({ input_tokens: 2, output_tokens: 10, cache_read_input_tokens: 100, cache_creation_input_tokens: 5,
  cache_creation: { ephemeral_1h_input_tokens: 5, ephemeral_5m_input_tokens: 0 }, ...overrides })
const message = (id, overrides = {}) => ({ type: 'assistant', timestamp: new Date(now).toISOString(), sessionId: 'engine-a',
  message: { id, model, usage: usage() }, ...overrides })

test('deduplicates streamed assistant blocks and ignores sidechains', () => {
  const first = message('m1')
  const final = message('m1', { message: { id: 'm1', model, usage: usage({ output_tokens: 20 }) } })
  const result = summarize([first, final, message('sub', { isSidechain: true })], { sessionId: idA }, now)
  assert.equal(result.requests, 1)
  assert.equal(result.totals.output, 20)
  assert.equal(result.totals.cacheRead, 100)
  assert.equal(result.hitRate, 100 / 107 * 100)
})

test('uses latest cumulative report without summing cumulative totals', () => {
  const result = summarize([
    { type: 'result', uuid: 'a', total_cost_usd: 4, timestamp: new Date(now - 10).toISOString() },
    { type: 'result', uuid: 'b', total_cost_usd: 6.38, timestamp: new Date(now).toISOString() }
  ])
  assert.equal(result.cost.reportedUsd, 6.38)
  assert.equal(result.cost.estimateUsd, null)
  assert.equal(labels(result, now).cost, 'US$6.38 回報')
})

test('flags a cumulative accounting reset instead of merging cost segments', () => {
  const result = summarize([
    { type: 'result', total_cost_usd: 8, timestamp: new Date(now - 10).toISOString() },
    { type: 'result', total_cost_usd: 1, timestamp: new Date(now).toISOString() }
  ])
  assert.equal(result.cost.reportedUsd, 1)
  assert.equal(result.cost.resetDetected, true)
  assert.match(labels(result, now).cost, /本段/)
})

test('refreshes the observed 1h cache on a later cache read', () => {
  const read = message('m2', { timestamp: new Date(now + 120000).toISOString(), message: { id: 'm2', model,
    usage: usage({ cache_creation_input_tokens: 0, cache_creation: { ephemeral_1h_input_tokens: 0, ephemeral_5m_input_tokens: 0 } }) } })
  const result = summarize([message('m1'), read], {}, now + 120000)
  assert.equal(result.cache.expires[0].at, now + 120000 + 3600000)
  assert.equal(labels(result, now + 180000).cache, '快取 1h≈59:00')
  assert.equal(labels(result, now + 7200000).cache, '快取 1h≈00:00')
})

test('preserves distinct possible 5m and 1h expiry estimates', () => {
  const row = message('m', { message: { id: 'm', model, usage: usage({ cache_creation_input_tokens: 10,
    cache_creation: { ephemeral_1h_input_tokens: 5, ephemeral_5m_input_tokens: 5 } }) } })
  const result = summarize([row], {}, now)
  assert.deepEqual(result.cache.expires.map(item => item.ttl), [300, 3600])
  assert.match(labels(result, now).cache, /5m≈05:00 \/ 1h≈60:00/)
})

test('never assumes five minutes when the write TTL is missing', () => {
  const result = summarize([message('m', { message: { id: 'm', model, usage: usage({ cache_creation: undefined }) } })], {}, now)
  assert.equal(result.cache.expires.length, 0)
  assert.equal(result.cost.estimateUsd, null)
  assert.equal(labels(result, now).cache, '快取 TTL 未提供')
})

test('zero cache use does not create a cache countdown', () => {
  const row = message('m', { message: { id: 'm', model, usage: usage({ cache_read_input_tokens: 0,
    cache_creation_input_tokens: 0, cache_creation: undefined }) } })
  assert.equal(summarize([row], {}, now).cache.observedAt, null)
})

test('prices 1h cache writes separately and keeps unsupported costs unknown', () => {
  assert.equal(estimateCost(model, usage()), (2 * 4 + 10 * 20 + 100 * 0.2 + 5 * 8) / 1e6)
  assert.equal(estimateCost('unknown-model', usage()), null)
  assert.equal(estimateCost(model, {}), null)
  assert.equal(estimateCost(model, usage({ speed: 'fast' })), null)
  assert.equal(estimateCost(model, usage({ server_tool_use: { web_search_requests: 1 } })), null)
})

test('marks truncated transcript statistics as partial', () => {
  assert.equal(summarize([message('m')], { transcriptTruncated: true }).partial, true)
})

test('zero-token synthetic quota errors do not cancel a real session cost estimate', () => {
  const synthetic = message('quota-error', { message: { id: 'quota-error', model: '<synthetic>',
    usage: usage({ input_tokens: 0, output_tokens: 0, cache_read_input_tokens: 0, cache_creation_input_tokens: 0,
      cache_creation: { ephemeral_1h_input_tokens: 0, ephemeral_5m_input_tokens: 0 },
      server_tool_use: { web_search_requests: 0, web_fetch_requests: 0 } }) } })
  const expected = summarize([message('m')], {}, now)
  const result = summarize([message('m'), synthetic], {}, now)
  assert.equal(result.cost.estimateUsd, expected.cost.estimateUsd)
  assert.deepEqual(result.totals, expected.totals)
  assert.equal(result.requests, 1)
  assert.equal(summarize([synthetic]).cost.estimateUsd, null)
  for (const overrides of [{ input_tokens: 1 }, { output_tokens: undefined },
    { server_tool_use: { web_search_requests: 1 } }, { cache_creation: { ephemeral_1h_input_tokens: 1 } }]) {
    const unpriced = { ...synthetic, message: { ...synthetic.message, usage: { ...synthetic.message.usage, ...overrides } } }
    assert.equal(summarize([message('m'), unpriced]).cost.estimateUsd, null)
  }
})

test('recognizes only the observed Desktop Code route', () => {
  assert.equal(sessionId('/epitaxy/' + idA), idA)
  assert.equal(sessionId('/chat/' + idA), null)
  assert.equal(sessionId('/epitaxy/not-a-session'), null)
})

function fakeWindow(api) {
  const intervals = new Map()
  let next = 0
  return {
    document: { documentElement: {}, querySelectorAll: () => [] },
    location: { pathname: '/epitaxy/' + idA },
    'claude.web': { LocalSessions: api },
    MutationObserver: class { observe() {} disconnect() {} },
    queueMicrotask,
    setTimeout, clearTimeout,
    setInterval(fn) { const id = ++next; intervals.set(id, fn); return id },
    clearInterval(id) { intervals.delete(id) },
    intervals
  }
}
const settle = () => new Promise(resolve => setImmediate(resolve))

test('sums children once without adding a parent cumulative report or mixing cache clocks', () => {
  const parent = message('parent')
  const child = message('child', { isSidechain: true, timestamp: new Date(now + 120000).toISOString() })
  const rows = [parent, { type: 'result', total_cost_usd: 100, timestamp: new Date(now).toISOString() }]
  const payload = { session_id: 'engine', complete: true, agents: [
    { id: 'a1', rows: [parent, child, child] }, { id: 'a1', rows: [child] }, { id: 'a2', rows: [child] }
  ] }
  const result = combineUsage(rows, {}, payload, 'engine', now + 120000)
  assert.equal(result.requests, 2)
  assert.equal(result.totals.cacheRead, 200)
  assert.equal(result.cost.reportedUsd, null)
  assert.equal(result.cost.estimateUsd, summarize([parent]).cost.estimateUsd * 2)
  assert.deepEqual(result.cache, summarize([parent], {}, now + 120000).cache)
  assert.match(labels(result).cost, /合計/)
  assert.match(details(result), /主對話估算/)
})

test('incomplete or wrong-session children are visibly partial, unknown pricing stays unknown', () => {
  const rows = [message('parent')]
  const partial = combineUsage(rows, {}, { session_id: 'engine', complete: false, missing: 1, agents: [] }, 'engine')
  assert.equal(partial.partial, true)
  assert.match(labels(partial).cost, /部分/)
  assert.match(details(partial), /未配對 1/)
  const wrong = combineUsage(rows, {}, { session_id: 'other', complete: true, agents: [{id:'a1',rows:[message('child')]}] }, 'engine')
  assert.equal(wrong.subagents.count, 0)
  assert.equal(wrong.partial, true)
  const unpriced = message('unknown', {message:{id:'unknown',model:'unknown',usage:usage()}})
  const unknown = combineUsage(rows, {}, {session_id:'engine',complete:true,agents:[{id:'a1',rows:[unpriced]}]}, 'engine')
  assert.equal(unknown.cost.estimateUsd, null)
})

test('reads child accounting only for one unambiguous engine and retains parent on bridge failure', async () => {
  const engine = '11111111-1111-1111-1111-111111111111'
  const rows = [message('parent', {sessionId:engine}), {sessionId:engine,type:'assistant',message:{content:[{type:'tool_use',name:'Agent',id:'t1'}]}}]
  const win = {AbortController,setTimeout,clearTimeout,fetch:async url => {
    assert.match(url, /session=11111111-1111-1111-1111-111111111111$/)
    return {ok:true,json:async()=>({session_id:engine,complete:true,agents:[{id:'a1',rows:[message('child')]}]})}
  }}
  assert.equal((await readSessionUsage(win,rows,{})).requests,2)
  win.fetch = async () => { throw new Error('offline') }
  const offline = await readSessionUsage(win, rows, {})
  assert.equal(offline.requests, 1)
  assert.equal(offline.partial, true)
})

test('late results from a previous session cannot overwrite the active session', async () => {
  let resolveOld
  const win = fakeWindow({
    getSession: async id => ({ sessionId: id }),
    getTranscript: id => id === idA ? new Promise(resolve => { resolveOld = resolve }) : Promise.resolve([message('b')])
  })
  const controller = install(win)
  win.location.pathname = '/epitaxy/' + idB
  ;[...win.intervals.values()][0]()
  await settle()
  assert.equal(controller.state.metrics.sessionId, idB)
  resolveOld([message('a')])
  await settle()
  assert.equal(controller.state.metrics.sessionId, idB)
  controller.dispose()
  assert.equal(win.intervals.size, 0)
})

test('reinstall cleans up timers; a mismatched session produces no borrowed metrics', async () => {
  const win = fakeWindow({ getSession: async () => ({ sessionId: idB }), getTranscript: async () => [message('b')] })
  const old = install(win)
  const current = install(win)
  await settle()
  assert.equal(old.state.disposed, true)
  assert.equal(win.intervals.size, 2)
  assert.equal(current.state.metrics, null)
  assert.match(current.state.error, /session 對應不符/)
  current.dispose()
})

test('each Desktop instance sends an independent heartbeat without session data', async () => {
  const requests = []
  const create = instance => {
    const win = fakeWindow({ getSession: async () => ({ sessionId: idA }), getTranscript: async () => [] })
    win.__usageViewerSessionMeterConfig = { instance, refreshId: '11111111-1111-1111-1111-111111111111' }
    win.AbortController = AbortController
    win.fetch = async (url, options) => { requests.push({ url, body: JSON.parse(options.body) }); return { ok: true } }
    return win
  }
  const first = create('11-1234')
  const second = create('22-5678')
  const a = install(first)
  const b = install(second)
  await settle()
  assert.equal(requests.length, 2)
  assert.match(requests[0].url, /instance=11-1234$/)
  assert.match(requests[1].url, /instance=22-5678$/)
  assert.deepEqual(Object.keys(requests[0].body).sort(), ['refresh_id', 'version'])
  a.dispose(); b.dispose()
  assert.equal(first.intervals.size, 0)
  assert.equal(second.intervals.size, 0)
})
