'use strict'
const byId = id => document.getElementById(id)
const percent = value => value === null ? '—' : `${Math.round(value)}%`
const date = value => new Date(value).toLocaleString('zh-TW', { hour12: false })
let pending = false
async function refresh() {
  if (pending) return
  pending = true
  try {
    const response = await fetch('/codex-panel-data', { cache: 'no-store', signal: AbortSignal.timeout(4000) })
    if (!response.ok) throw new Error('snapshot unavailable')
    const data = await response.json()
    byId('model').textContent = data.model || '未知模型'
    for (const [prefix, key] of [['five', 'five_hour'], ['seven', 'seven_day']]) {
      const value = data[`${key}_used`]
      byId(prefix).textContent = percent(value)
      byId(`${prefix}-bar`).style.width = `${value ?? 0}%`
      const reset = data[`${key}_reset`]
      byId(`${prefix}-reset`).textContent = reset ? `重置時間 · ${date(reset * 1000)}` : '尚無重置時間'
    }
    byId('cache').textContent = percent(data.cached_input)
    byId('tokens').textContent = data.session_tokens === null ? '—' : data.session_tokens.toLocaleString('zh-TW')
    const stale = !data.observed_at || Date.now() - Date.parse(data.observed_at) > 5 * 60 * 1000 || !Number.isFinite(Date.parse(data.observed_at))
    document.body.classList.toggle('stale', stale)
    byId('status').textContent = stale ? '較舊快照' : '已連線'
    byId('updated').textContent = data.observed_at ? `資料觀測時間 · ${date(data.observed_at)}` : '觀測時間未知'
    byId('error').hidden = true
  } catch {
    byId('status').textContent = '無法更新'
    document.body.classList.add('stale')
    byId('error').hidden = false
    byId('error').textContent = '目前無法讀取本機快照；下方若有數值，為上次成功取得的資料。請確認 Usage Viewer 已啟動。'
  } finally { pending = false }
}
byId('refresh').addEventListener('click', refresh)
refresh()
setInterval(refresh, 5000)
