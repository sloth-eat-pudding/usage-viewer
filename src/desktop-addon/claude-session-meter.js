(function (root, factory) {
  'use strict'
  const api = factory()
  if (typeof module === 'object' && module.exports) module.exports = api
  else {
    root.UsageViewerSessionMeter = api
    if (root.document) api.install(root)
  }
})(typeof window === 'object' ? window : globalThis, function () {
  'use strict'

  const VERSION = '1.3.0'
  const KEY = '__usageViewerSessionMeter'
  const PRICING_DATE = '2026-10-21'
  const PRICING_URL = 'https://platform.claude.com/docs/en/about-claude/pricing'
  // USD per million tokens: input, output, 5m write, 1h write, read.
  // An unknown model or pricing modifier yields an unknown estimate, never $0.
  const PRICES = {
    'claude-opus-5-5': [4, 20, 5, 8, 0.2],
    'claude-sonnet-5-5': [2, 10, 2.5, 4, 0.1],
    'claude-opus-5': [5, 25, 6.25, 10, 0.5],
    'claude-opus-4-8': [5, 25, 6.25, 10, 0.5],
    'claude-opus-4-7': [5, 25, 6.25, 10, 0.5],
    'claude-opus-4-6': [5, 25, 6.25, 10, 0.5],
    'claude-opus-4-5': [5, 25, 6.25, 10, 0.5],
    'claude-sonnet-5': [2, 10, 2.5, 4, 0.2],
    'claude-sonnet-4-6': [3, 15, 3.75, 6, 0.3],
    'claude-haiku-4-5': [1, 5, 1.25, 2, 0.1],
    'claude-fable-5-1': [10, 50, 12.5, 20, 0.25]
  }

  function number(value) {
    return typeof value === 'number' && Number.isFinite(value) && value >= 0 ? value : null
  }

  function tokens(usage, key) { return number(usage?.[key]) ?? 0 }

  function epoch(value) {
    const parsed = typeof value === 'number' ? value : Date.parse(value)
    return Number.isFinite(parsed) ? parsed : null
  }

  function estimateCost(model, usage) {
    const rates = PRICES[String(model || '').replace(/-\d{8}$/, '')]
    if (!rates || ['input_tokens', 'output_tokens', 'cache_creation_input_tokens', 'cache_read_input_tokens'].some(key => number(usage[key]) === null) ||
        (usage.speed && usage.speed !== 'standard') ||
        (usage.service_tier && usage.service_tier !== 'standard') ||
        tokens(usage.server_tool_use, 'web_search_requests') > 0) return null
    const creation = tokens(usage, 'cache_creation_input_tokens')
    const write5m = tokens(usage.cache_creation, 'ephemeral_5m_input_tokens')
    const write1h = tokens(usage.cache_creation, 'ephemeral_1h_input_tokens')
    if (creation !== write5m + write1h) return null
    if (usage.inference_geo && !['global', 'us'].includes(usage.inference_geo)) return null
    const geo = usage.inference_geo === 'us' ? 1.1 : 1
    return geo * (tokens(usage, 'input_tokens') * rates[0] + tokens(usage, 'output_tokens') * rates[1] +
      write5m * rates[2] + write1h * rates[3] + tokens(usage, 'cache_read_input_tokens') * rates[4]) / 1e6
  }

  function summarize(rows, session = {}, now = Date.now()) {
    if (!Array.isArray(rows)) throw new Error('Unsupported transcript format')
    // One assistant message may occur repeatedly as text/tool blocks stream in.
    // Retain its final usage snapshot instead of charging for each copy.
    const messages = new Map()
    const results = new Map()
    for (const [index, row] of rows.entries()) {
      if (!row || typeof row !== 'object' || row.isSidechain) continue
      const usage = row.message?.usage
      if (row.type === 'assistant' && usage && typeof usage === 'object') {
        // Desktop emits synthetic assistant rows for errors such as quota
        // limits. Explicitly empty usage is not an unpriced model request.
        if (row.message.model === '<synthetic>' &&
            ['input_tokens', 'output_tokens', 'cache_creation_input_tokens', 'cache_read_input_tokens']
              .every(key => number(usage[key]) === 0) &&
            Object.values(usage.cache_creation || {}).every(value => number(value) === 0) &&
            Object.values(usage.server_tool_use || {}).every(value => number(value) === 0)) continue
        const id = row.message.id || row.requestId || row.uuid
        // Rows without any stable identity cannot safely be deduplicated.
        if (!id) continue
        const scope = row.sessionId || ''
        const key = scope + ':' + id
        const existing = messages.get(key)
        if (!existing || (epoch(row.timestamp) ?? index) >= (epoch(existing.timestamp) ?? existing.index))
          messages.set(key, { ...row, index })
      }
      if (row.type === 'result' && number(row.total_cost_usd) !== null) {
        const id = row.uuid || `${row.session_id || ''}:${row.result_index ?? index}`
        results.set(id, { ...row, index })
      }
    }
    const ordered = [...messages.values()].sort((a, b) => (epoch(a.timestamp) ?? a.index) - (epoch(b.timestamp) ?? b.index))
    const totals = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, write5m: 0, write1h: 0 }
    let estimatedUsd = 0
    let estimateComplete = ordered.length > 0
    let lastUse = null
    let lastTtls = []
    let knownTtls = []
    for (const row of ordered) {
      const usage = row.message.usage
      totals.input += tokens(usage, 'input_tokens')
      totals.output += tokens(usage, 'output_tokens')
      totals.cacheRead += tokens(usage, 'cache_read_input_tokens')
      totals.cacheWrite += tokens(usage, 'cache_creation_input_tokens')
      const write5m = tokens(usage.cache_creation, 'ephemeral_5m_input_tokens')
      const write1h = tokens(usage.cache_creation, 'ephemeral_1h_input_tokens')
      totals.write5m += write5m
      totals.write1h += write1h
      const cost = estimateCost(row.message.model, usage)
      if (cost === null) estimateComplete = false
      else estimatedUsd += cost
      const timestamp = epoch(row.timestamp)
      if (timestamp !== null && timestamp <= now + 30000 &&
          tokens(usage, 'cache_read_input_tokens') + tokens(usage, 'cache_creation_input_tokens') > 0) {
        const writes = [write5m > 0 ? 300 : null, write1h > 0 ? 3600 : null].filter(Boolean)
        // Read-only turns inherit the most recently observed write TTL. Mixed
        // prefixes have separate possible expiries, so expose both as estimates.
        if (writes.length) knownTtls = writes
        else if (tokens(usage, 'cache_creation_input_tokens') > 0) knownTtls = []
        lastUse = timestamp
        lastTtls = knownTtls
      }
    }
    const reports = [...results.values()].sort((a, b) => (epoch(a.timestamp) ?? a.index) - (epoch(b.timestamp) ?? b.index))
    const latestReport = reports.at(-1)
    const resetDetected = reports.some((row, index) => index > 0 && row.total_cost_usd < reports[index - 1].total_cost_usd)
    const inputTotal = totals.input + totals.cacheRead + totals.cacheWrite
    return {
      sessionId: session.sessionId || null,
      model: session.model || ordered.at(-1)?.message.model || null,
      requests: ordered.length,
      totals,
      hitRate: inputTotal > 0 ? totals.cacheRead / inputTotal * 100 : null,
      cache: {
        observedAt: lastUse,
        expires: lastUse === null ? [] : lastTtls.map(ttl => ({ ttl, at: lastUse + ttl * 1000 })),
        approximate: true
      },
      cost: {
        reportedUsd: latestReport?.total_cost_usd ?? null,
        reportedAt: latestReport ? epoch(latestReport.timestamp) : null,
        estimateUsd: estimateComplete ? estimatedUsd : null,
        resetDetected,
        billing: 'engine-accounting-not-subscription-invoice'
      },
      partial: Boolean(session.transcriptTruncated || session.transcriptUnavailable),
      pricingDate: PRICING_DATE
    }
  }

  function sessionId(pathname) {
    const match = /^\/epitaxy\/(local_[0-9a-f-]{36})(?:\/|$)/i.exec(pathname || '')
    return match ? match[1] : null
  }

  function combineUsage(rows, session, payload, engineId, now = Date.now()) {
    const main = summarize(rows, session, now)
    const identity = row => row.message?.id || row.requestId || row.uuid
    const messageOwners = new Map(rows.filter(r => !r.isSidechain && r.type === 'assistant')
      .map(r => identity(r)).filter(Boolean).map(id => [id, 'main']))
    const agents = new Map()
    let complete = payload?.session_id === engineId && payload.complete === true
    for (const agent of payload?.session_id === engineId && Array.isArray(payload.agents) ? payload.agents : []) {
      if (!/^[a-z0-9-]+$/i.test(agent.id || '') || !Array.isArray(agent.rows)) { complete = false; continue }
      const current = agents.get(agent.id) || []
      for (const row of agent.rows) {
        const key = identity(row)
        if (!key) { complete = false; continue }
        if (messageOwners.has(key) && messageOwners.get(key) !== agent.id) continue
        messageOwners.set(key, agent.id) // Copies across parent/children are billed once.
        current.push({ ...row, sessionId: `${engineId}:${agent.id}`, isSidechain: false })
      }
      agents.set(agent.id, current)
    }
    const summaries = [...agents.values()].map(agentRows => summarize(agentRows, {}, now))
    const totals = { ...main.totals }
    for (const agent of summaries) for (const key of Object.keys(totals)) totals[key] += agent.totals[key]
    const inputTotal = totals.input + totals.cacheRead + totals.cacheWrite
    const agentEstimates = summaries.map(item => item.requests === 0 ? 0 : item.cost.estimateUsd)
    const estimates = [main.cost.estimateUsd, ...agentEstimates]
    return {
      ...main, main, totals, requests: main.requests + summaries.reduce((n, a) => n + a.requests, 0),
      hitRate: inputTotal > 0 ? totals.cacheRead / inputTotal * 100 : null,
      cost: { ...main.cost, reportedUsd: null, estimateUsd: estimates.every(value => value !== null)
        ? estimates.reduce((sum, value) => sum + value, 0) : null },
      subagents: { count: summaries.length, complete, missing: payload?.missing || 0,
        requests: summaries.reduce((n, a) => n + a.requests, 0),
        estimateUsd: agentEstimates.every(value => value !== null)
          ? agentEstimates.reduce((sum, value) => sum + value, 0) : null },
      partial: main.partial || !complete
    }
  }

  async function readSessionUsage(win, rows, session) {
    const hasAgents = rows.some(row => Array.isArray(row.message?.content) && row.message.content.some(
      block => block.type === 'tool_use' && ['Agent', 'Task'].includes(block.name)))
    if (!hasAgents) return summarize(rows, session)
    const ids = [...new Set(rows.filter(r => !r.isSidechain).map(r => r.sessionId)
      .filter(id => typeof id === 'string' && /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(id)))]
    const engineId = ids.length === 1 ? ids[0] : null
    let payload = null, timeout
    if (engineId && typeof win.fetch === 'function') {
      const abort = new win.AbortController()
      try {
        timeout = win.setTimeout(() => abort.abort(), 5000)
        const response = await win.fetch('http://127.0.0.1:8765/claude-subagent-usage?session=' + encodeURIComponent(engineId),
          { signal: abort.signal, cache: 'no-store' })
        if (!response.ok) throw new Error('子代理用量無法讀取')
        payload = await response.json()
      } catch { /* Keep available usage, visibly marked incomplete. */ }
      finally { win.clearTimeout(timeout) }
    }
    return combineUsage(rows, session, payload, engineId)
  }

  function countdown(expiry, now) {
    const seconds = Math.max(0, Math.ceil((expiry - now) / 1000))
    return `${Math.floor(seconds / 60).toString().padStart(2, '0')}:${(seconds % 60).toString().padStart(2, '0')}`
  }

  function labels(metrics, now = Date.now()) {
    if (!metrics) return { cache: '快取 —', hit: '命中 —', cost: '費用 —' }
    const expires = metrics.cache.expires
    const cache = expires.length
      ? expires.map(item => `${item.ttl === 3600 ? '1h' : '5m'}≈${countdown(item.at, now)}`).join(' / ')
      : metrics.cache.observedAt === null ? '未觀測快取' : 'TTL 未提供'
    const reported = metrics.cost.reportedUsd
    const estimate = metrics.cost.estimateUsd
    const costSuffix = metrics.subagents ? (metrics.subagents.complete ? ' 合計' : ' 部分') : ''
    return {
      cache: `快取 ${cache}`,
      hit: metrics.hitRate === null ? '命中 —' : `命中 ${metrics.hitRate.toFixed(1)}%`,
      cost: reported !== null ? `US$${reported.toFixed(2)} 回報${metrics.cost.resetDetected ? '·本段' : ''}` :
        estimate !== null ? `≈US$${estimate.toFixed(2)}${costSuffix}` : '費用 未提供'
    }
  }

  function details(metrics) {
    if (!metrics) return '等待目前 session 的用量資料。'
    const n = value => value.toLocaleString('en-US')
    return [
      metrics.subagents ? `主對話 + ${n(metrics.subagents.count)} 個子代理的用量合計；相同請求去重。` : '此 session 的可見主對話紀錄。',
      '快取倒數只顯示主對話，為最後一次使用時間 + 已觀測 TTL 的推估；不保證命中，也不會自動保溫。',
      metrics.subagents ? `主對話估算 ${metrics.main.cost.estimateUsd === null ? '未提供' : 'US$' + metrics.main.cost.estimateUsd.toFixed(2)} · 子代理估算 ${metrics.subagents.estimateUsd === null ? '未提供' : 'US$' + metrics.subagents.estimateUsd.toFixed(2)}` : '',
      `輸入 ${n(metrics.totals.input)} · 輸出 ${n(metrics.totals.output)}`,
      `Cache read ${n(metrics.totals.cacheRead)} · write ${n(metrics.totals.cacheWrite)}`,
      `5m write ${n(metrics.totals.write5m)} · 1h write ${n(metrics.totals.write1h)}`,
      `去重後 ${n(metrics.requests)} 筆回覆用量。命中率 = cache read / 全部輸入 tokens。`,
      metrics.cost.reportedUsd !== null
        ? '費用採最近完成回合的 total_cost_usd 累計回報，尚未包含進行中回合；不是訂閱方案的實際扣款。'
        : `費用依 ${PRICING_DATE} 官方 API 單價推估，非帳單；未知模型、費率或 TTL 不估算。`,
      metrics.cost.resetDetected ? '偵測到引擎累計值下降：顯示最新累計段，未把多段累計值相加。' : '',
      metrics.subagents && !metrics.subagents.complete ? `子代理紀錄未完整取得（未配對 ${n(metrics.subagents.missing)} 筆），目前僅為可讀取用量的小計。` : '',
      metrics.partial ? '注意：應用程式標記紀錄不完整，token 統計可能只涵蓋部分紀錄。' : ''
    ].filter(Boolean).join('\n')
  }

  function install(win) {
    if (!win?.document || !win['claude.web']?.LocalSessions) return null
    win[KEY]?.dispose()
    const doc = win.document
    // Use each Code pane's available width, retaining Claude's responsive
    // gutters, sidebar and split-pane boundaries. CSS also covers new sessions.
    for (const oldStyle of doc.querySelectorAll('#usage-viewer-full-width')) oldStyle.remove()
    const layoutStyle = doc.createElement('style')
    layoutStyle.id = 'usage-viewer-full-width'
    layoutStyle.textContent = '.epitaxy-chat-panel { --chat-column-measure: 100% !important; }'
    doc.head.appendChild(layoutStyle)
    const api = win['claude.web'].LocalSessions
    const state = { id: null, metrics: null, error: null, host: null, revision: 0, busy: false, disposed: false }
    let chips = null
    let panel = null
    let detach = null
    let eventTimer = null
    let heartbeatBusy = false
    const heartbeatConfig = win.__usageViewerSessionMeterConfig
    let scheduled = false

    function removeHost() {
      state.host?.remove()
      state.host = null
      chips = null
      panel = null
    }

    function render() {
      if (!chips) return
      const text = labels(state.metrics)
      for (const key of ['cache', 'hit', 'cost']) {
        if (chips[key].textContent !== text[key]) chips[key].textContent = text[key]
      }
      const explanation = state.error ? `更新失敗：${state.error}\n${details(state.metrics)}` : details(state.metrics)
      state.host.title = explanation
      state.host.dataset.sessionId = state.id
      if (panel.textContent !== explanation) panel.textContent = explanation
      state.host.dataset.stale = state.error ? 'true' : 'false'
    }

    function reconcile() {
      if (state.disposed) return
      const id = sessionId(win.location.pathname)
      if (id !== state.id) {
        state.id = id
        state.metrics = null
        state.error = null
        state.busy = false
        state.revision++
        removeHost()
        if (id) void refresh()
      }
      const buttons = [...doc.querySelectorAll('button[data-testid="epitaxy-cds-model-selector"]')]
      // Split panes may have several sessions. Never put primary-session data
      // next to an ambiguous model selector.
      if (!id || buttons.length !== 1) { removeHost(); return }
      if (!state.host?.isConnected || state.host.nextElementSibling !== buttons[0]) {
        removeHost()
        const host = doc.createElement('span')
        host.id = 'usage-viewer-session-meter'
        host.dataset.version = VERSION
        host.style.cssText = 'display:inline-flex;align-items:center;min-width:0;flex-shrink:1;margin-inline:6px;vertical-align:middle;'
        const shadow = host.attachShadow({ mode: 'open' })
        const style = doc.createElement('style')
        style.textContent = ':host{font:11px system-ui,sans-serif;color:inherit}button{font:inherit;color:inherit;border:1px solid #8885;border-radius:6px;padding:3px 7px;background:transparent;cursor:pointer;display:inline-flex;gap:9px;max-width:46vw;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}button:hover{background:#8882}span{white-space:nowrap}pre{position:fixed;bottom:58px;right:20px;z-index:2147483000;box-sizing:border-box;max-width:min(560px,90vw);padding:14px;border:1px solid #777;border-radius:9px;background:#202020;color:#eee;box-shadow:0 5px 24px #0007;white-space:pre-wrap;line-height:1.6;font:12px system-ui,sans-serif}:host([data-stale=true]) button{border-color:#b98a3b}a{color:inherit}'
        const button = doc.createElement('button')
        button.type = 'button'
        button.setAttribute('aria-label', '目前 session 快取與費用，點擊查看說明')
        chips = {}
        for (const key of ['cache', 'hit', 'cost']) {
          chips[key] = doc.createElement('span')
          button.appendChild(chips[key])
        }
        panel = doc.createElement('pre')
        panel.hidden = true
        button.addEventListener('click', event => { event.preventDefault(); event.stopPropagation(); panel.hidden = !panel.hidden })
        shadow.append(style, button, panel)
        buttons[0].insertAdjacentElement('beforebegin', host)
        state.host = host
      }
      render()
    }

    async function refresh() {
      if (state.disposed || !state.id || state.busy) return
      const id = state.id
      const revision = state.revision
      state.busy = true
      let timeout
      try {
        const [session, rows] = await Promise.race([
          Promise.all([api.getSession(id), api.getTranscript(id)]),
          new Promise((_, reject) => { timeout = win.setTimeout(() => reject(new Error('session 資料讀取逾時')), 10000) })
        ])
        if (state.disposed || revision !== state.revision) return
        if (!session || session.sessionId !== id) throw new Error('session 對應不符')
        const metrics = await readSessionUsage(win, rows, session)
        if (state.disposed || revision !== state.revision) return
        state.metrics = metrics
        state.error = null
      } catch (error) {
        if (!state.disposed && revision === state.revision) state.error = error.message
      } finally {
        win.clearTimeout(timeout)
        if (revision === state.revision) state.busy = false
        if (!state.disposed) render()
      }
    }

    const observer = new win.MutationObserver(() => {
      if (!scheduled && !state.disposed) {
        scheduled = true
        win.queueMicrotask(() => { scheduled = false; reconcile() })
      }
    })
    observer.observe(doc.documentElement, { childList: true, subtree: true })
    const displayTimer = win.setInterval(reconcile, 1000)
    const readTimer = win.setInterval(() => void refresh(), 15000)
    async function heartbeat() {
      if (state.disposed || heartbeatBusy || !heartbeatConfig || typeof win.fetch !== 'function') return
      if (!/^\d{1,10}-\d{1,20}$/.test(heartbeatConfig.instance || '') ||
          !/^[0-9a-f-]{36}$/i.test(heartbeatConfig.refreshId || '')) return
      heartbeatBusy = true
      let timeout
      const abort = new win.AbortController()
      try {
        timeout = win.setTimeout(() => abort.abort(), 5000)
        await win.fetch('http://127.0.0.1:8765/claude-session-meter-heartbeat?instance=' + encodeURIComponent(heartbeatConfig.instance), {
          method: 'POST', headers: { 'Content-Type': 'application/json' }, signal: abort.signal,
          body: JSON.stringify({ version: VERSION, refresh_id: heartbeatConfig.refreshId })
        })
      } catch { /* A stopped viewer must not affect Claude or its session. */ }
      finally { win.clearTimeout(timeout); heartbeatBusy = false }
    }
    const heartbeatTimer = heartbeatConfig ? win.setInterval(() => void heartbeat(), 20000) : null
    // This observes existing events; it never warms, resumes, or sends a turn.
    if (typeof api.onOnEvent === 'function') {
      try {
        detach = api.onOnEvent(() => {
          if (!eventTimer && !state.disposed) eventTimer = win.setTimeout(() => {
            eventTimer = null
            if (!state.disposed) void refresh()
          }, 1000)
        })
      } catch {}
    }
    const controller = {
      version: VERSION,
      state,
      refresh,
      dispose() {
        if (state.disposed) return
        state.disposed = true
        state.revision++
        observer.disconnect()
        win.clearInterval(displayTimer)
        win.clearInterval(readTimer)
        win.clearInterval(heartbeatTimer)
        win.clearTimeout(eventTimer)
        if (typeof detach === 'function') detach()
        removeHost()
        layoutStyle.remove()
        if (win[KEY] === controller) delete win[KEY]
      }
    }
    win[KEY] = controller
    reconcile()
    void heartbeat()
    return controller
  }

  return { VERSION, PRICING_DATE, PRICING_URL, summarize, combineUsage, readSessionUsage, estimateCost, labels, details, sessionId, install }
})
