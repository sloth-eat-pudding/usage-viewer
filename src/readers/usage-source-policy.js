'use strict'

const fs = require('fs')
const path = require('path')

function settings(home) {
  try { return JSON.parse(fs.readFileSync(path.join(home, 'display-settings.json'), 'utf8').replace(/^\uFEFF/, '')) } catch { return {} }
}
function enabled(home, key, sourcePath) {
  const config = settings(home)
  const sources = config[key.replace(/_group$/, '_sources')]
  const source = sourcePath && Array.isArray(sources) && sources.find(item => item.path?.toLowerCase() === sourcePath.toLowerCase())
  return String(source ? source.group || '1' : config[key] || '1').trim().toLowerCase() !== 'hidden'
}
function organizationEnabled(home, organization) {
  const config = settings(home)
  const sources = [...(config.claude_desktop_sources || []), ...(config.claude_custom_sources || [])]
  const matches = sources.filter(source => {
    try {
      const history = JSON.parse(fs.readFileSync(source.path, 'utf8').replace(/^\uFEFF/, ''))
      const latest = (history.samples || []).slice().sort((a, b) => Number(b.t || Date.parse(b.timestamp)) - Number(a.t || Date.parse(a.timestamp)))[0]
      return latest?.org === organization
    } catch { return false }
  })
  return matches.length ? matches.some(source => String(source.group || '1').trim().toLowerCase() !== 'hidden')
    : enabled(home, 'claude_desktop_group')
}
module.exports = { enabled, organizationEnabled }
