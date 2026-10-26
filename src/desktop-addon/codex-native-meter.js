/* Runtime-only Codex Desktop experiment. No credentials or conversation reads. */
(() => {
  'use strict'
  const key = '__usageViewerCodexNativeMeter'
  const version = '0.5.0'
  const previous = window[key]
  if (previous?.version === version || previous?.status().stopped) return
  previous?.destroy()
  let snapshot = null
  let stopped = false
  let row = null
  let label = null
  let layoutStyle = null
  const percent = value => typeof value === 'number' && Number.isFinite(value) && value >= 0 && value <= 100 ? `${Math.round(value)}%` : '—'
  function threadId() {
    const editors = [...document.querySelectorAll('[data-codex-composer][contenteditable="true"]')]
      .filter(e => e.getBoundingClientRect().width > 0 && e.getBoundingClientRect().height > 0)
    if (editors.length !== 1) return null
    let element = editors[0]
    while (element && !Object.keys(element).some(k => k.startsWith('__reactFiber$'))) element = element.parentElement
    let fiber = element?.[Object.keys(element).find(k => k.startsWith('__reactFiber$'))]
    let root = fiber
    for (let i = 0; root?.return && i < 250; i++) root = root.return
    if (root?.stateNode?.current && root.stateNode.current !== root) fiber = fiber?.alternate
    const ids = new Set()
    for (let i = 0; fiber && i < 150; i++, fiber = fiber.return) {
      const id = fiber.memoizedProps?.threadId || fiber.memoizedProps?.conversationId
      if (typeof id === 'string' && /^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i.test(id)) ids.add(id)
    }
    return ids.size === 1 ? [...ids][0] : null
  }
  function render() {
    if (stopped || !label) return
    if (snapshot && snapshot.thread_id !== threadId()) snapshot = { thread_id: threadId(), five_hour_used: snapshot.five_hour_used,
      seven_day_used: snapshot.seven_day_used, quota_observed_at: snapshot.quota_observed_at }
    const observed = Date.parse(snapshot?.observed_at || '')
    const quotaTime = Date.parse(snapshot?.quota_observed_at || '')
    const quotaFresh = Number.isFinite(quotaTime) && Date.now() - quotaTime < 90000 && quotaTime < Date.now() + 5000
    const stale = !quotaFresh && (!Number.isFinite(observed) || Date.now() - observed > 300000 || observed > Date.now() + 60000)
    const expiry = snapshot?.cache_estimate?.assumed_ttl_seconds === 1800 ? Date.parse(snapshot.cache_estimate.expires_at) : NaN
    const seconds = Number.isFinite(expiry) ? Math.max(0, Math.ceil((expiry - Date.now()) / 1000)) : null
    const cacheTime = seconds === null ? '快取時間未知' : seconds === 0 ? '30m估算窗已過' :
      `快取≈${Math.floor(seconds / 60).toString().padStart(2, '0')}:${(seconds % 60).toString().padStart(2, '0')}（假設30m）`
    const cost = typeof snapshot?.cost_usd === 'number' && Number.isFinite(snapshot.cost_usd) && snapshot.cost_usd >= 0
      ? `成本≈US$${snapshot.cost_usd.toFixed(4)}（API標準價）` : '成本未知'
    const text = `用量  5h ${percent(snapshot?.five_hour_used)}  ·  7d ${percent(snapshot?.seven_day_used)}  ·  快取命中 ${percent(snapshot?.cached_input)}  ·  ${cacheTime}  ·  ${cost}${stale ? '  ·  資料較舊或未知' : ''}`
    if (label.textContent !== text) label.textContent = text
    row.title = 'Usage Viewer · 額度為已使用百分比\n額度來源：此 profile 的桌面登入查詢；查詢不可用時採本機用量紀錄。快取與成本來源：目前聊天在此 profile 的本機用量紀錄。\n成本依各次模型與累計 token 差額，按 2026-10-26 API 標準價格估算，GPT-6 已含長上下文倍率；非訂閱帳單，不含子代理、工具費、速度與區域加價。未知價格、快取寫入費或紀錄不全顯示未知。\n倒數以最後用量事件加 API 預設 30 分鐘粗估，非 Desktop 實際到期時間。\n額度查詢時間：' + (quotaFresh ? new Date(quotaTime).toLocaleString() : '未知') + '\n聊天觀測時間：' + (Number.isFinite(observed) ? new Date(observed).toLocaleString() : '未知')
    row.style.opacity = stale ? '0.65' : '1'
  }
  function mount() {
    if (stopped) return
    const editors = [...document.querySelectorAll('[data-codex-composer][contenteditable="true"]')]
      .filter(e => e.getBoundingClientRect().width > 0 && e.getBoundingClientRect().height > 0)
    if (editors.length !== 1) { row?.remove(); row = label = null; return }
    const body = editors[0].closest('[data-composer-body]')
    const root = body?.parentElement
    if (!root?.hasAttribute('data-composer-layout')) { row?.remove(); row = label = null; return }
    if (!layoutStyle) {
      layoutStyle = document.createElement('style')
      layoutStyle.id = 'usage-viewer-codex-full-width'
      // Expand only the app's thread columns; retain its gutters, sidebars,
      // split-pane boundaries and message/code-block overflow handling.
      layoutStyle.textContent = `
        :root[data-usage-viewer-full-width] [class~="max-w-(--thread-body-max-width)"],
        :root[data-usage-viewer-full-width] [class~="max-w-(--thread-content-max-width)"] { max-width: 100% !important; }
        :root[data-usage-viewer-full-width] [class~="w-[min(100%,var(--thread-content-max-width))]"] { width: 100% !important; }
      `
      document.head.appendChild(layoutStyle)
      document.documentElement.setAttribute('data-usage-viewer-full-width', '')
    }
    if (row?.isConnected && row.parentElement === root) return
    row?.remove()
    row = document.createElement('div')
    row.dataset.usageViewerNativeMeter = '1'
    row.style.cssText = 'display:flex;align-items:center;justify-content:flex-end;gap:8px;flex:0 0 auto;grid-column:1 / -1;font:11px/1.5 inherit;color:var(--text-secondary,#aaa);padding:2px 2px 0;min-width:0;'
    label = document.createElement('span')
    label.style.cssText = 'font-size:11px;white-space:normal;'
    const close = document.createElement('button')
    close.type = 'button'
    close.textContent = '×'
    close.setAttribute('aria-label', '移除 Usage Viewer 用量標籤')
    close.style.cssText = 'border:0;background:transparent;color:inherit;cursor:pointer;font-size:14px;line-height:18px;padding:0 3px;'
    close.addEventListener('click', event => { event.preventDefault(); event.stopPropagation(); destroy() })
    row.append(label, close)
    root.insertBefore(row, body)
    render()
  }
  const observer = new MutationObserver(mount)
  const freshnessTimer = setInterval(render, 1000)
  function destroy() {
    stopped = true
    observer.disconnect()
    clearInterval(freshnessTimer)
    layoutStyle?.remove()
    layoutStyle = null
    document.documentElement.removeAttribute('data-usage-viewer-full-width')
    row?.remove()
    row = label = null
    // Keep a tombstone so the watcher cannot undo the user's close action.
  }
  window[key] = {
    version,
    threadId,
    update(value) { if (!stopped) { snapshot = value; mount(); render() } },
    destroy,
    status() { return { stopped, mounted: !!row?.isConnected, fullWidth: !!layoutStyle?.isConnected, version, count: document.querySelectorAll('[data-usage-viewer-native-meter]').length } }
  }
  observer.observe(document.documentElement, { childList: true, subtree: true })
  mount()
})()
