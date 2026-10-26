/* Runtime-only Codex Desktop experiment. No credentials or conversation reads. */
(() => {
  'use strict'
  const key = '__usageViewerCodexNativeMeter'
  const version = '0.2.0'
  const previous = window[key]
  if (previous?.version === version || previous?.status().stopped) return
  previous?.destroy()
  let snapshot = null
  let stopped = false
  let row = null
  let label = null
  let layoutStyle = null
  const percent = value => typeof value === 'number' && Number.isFinite(value) && value >= 0 && value <= 100 ? `${Math.round(value)}%` : '—'
  function render() {
    if (stopped || !label) return
    const observed = Date.parse(snapshot?.observed_at || '')
    const stale = !Number.isFinite(observed) || Date.now() - observed > 300000 || observed > Date.now() + 60000
    const text = `用量  5h ${percent(snapshot?.five_hour_used)}  ·  7d ${percent(snapshot?.seven_day_used)}  ·  來源快取命中 ${percent(snapshot?.cached_input)}  ·  期限未知${stale ? '  ·  資料較舊或未知' : ''}`
    if (label.textContent !== text) label.textContent = text
    row.title = 'Usage Viewer 試作 · 額度為已使用百分比\n來源：最近有用量紀錄的 Desktop session，可能是其他聊天\n快取命中率為該來源最近一次輸入的 cached input / input tokens；本機紀錄未提供到期時間，無法可靠倒數。\n觀測時間：' + (Number.isFinite(observed) ? new Date(observed).toLocaleString() : '未知')
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
  const freshnessTimer = setInterval(render, 30000)
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
    update(value) { if (!stopped) { snapshot = value; mount(); render() } },
    destroy,
    status() { return { stopped, mounted: !!row?.isConnected, fullWidth: !!layoutStyle?.isConnected, version, count: document.querySelectorAll('[data-usage-viewer-native-meter]').length } }
  }
  observer.observe(document.documentElement, { childList: true, subtree: true })
  mount()
})()
