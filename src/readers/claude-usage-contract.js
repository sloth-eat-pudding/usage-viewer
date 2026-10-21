'use strict'

// Pure usage normalization shared by the HTTP bridge and contract tests.
function normalizeUsage(data, organizationId) {
  const fiveHour = normalizeUsageWindow(data, 'session', 'five_hour')
  const sevenDay = normalizeUsageWindow(data, 'weekly_all', 'seven_day')

  if (fiveHour.used_percentage === null && sevenDay.used_percentage === null) {
    throw new Error('Expected a Claude Desktop usage response')
  }

  const now = new Date().toISOString()
  return {
    generated_at: now,
    observed_at: now,
    source: 'claude-desktop-api-bridge',
    source_mode: 'desktop',
    organization_id: organizationId,
    percentages: {
      five_hour_used: fiveHour.used_percentage,
      seven_day_used: sevenDay.used_percentage
    },
    resets_at: {
      five_hour_epoch_seconds: fiveHour.reset_epoch_seconds,
      seven_day_epoch_seconds: sevenDay.reset_epoch_seconds
    }
  }
}

function normalizeUsageWindow(data, limitKind, legacyKey) {
  const legacy = normalizeWindow(data && data[legacyKey])
  const limit = data && Array.isArray(data.limits)
    ? data.limits.find(item => item && item.kind === limitKind)
    : null

  if (!limit) return legacy

  const canonical = normalizeWindow({
    utilization: limit.percent,
    resets_at: limit.resets_at
  })
  return {
    used_percentage: canonical.used_percentage ?? legacy.used_percentage,
    reset_epoch_seconds: canonical.reset_epoch_seconds ?? legacy.reset_epoch_seconds
  }
}

function normalizeWindow(window) {
  const candidate = nullableNumber(window && window.utilization)
  const usage = candidate !== null && candidate >= 0 && candidate <= 100 ? candidate : null
  const timestamp = Date.parse((window && window.resets_at) || '')
  return {
    used_percentage: usage,
    reset_epoch_seconds: Number.isFinite(timestamp) ? Math.floor(timestamp / 1000) : null
  }
}

function nullableNumber(value) {
  if (!['number', 'string'].includes(typeof value) ||
      (typeof value === 'string' && value.trim() === '')) return null
  const number = Number(value)
  return Number.isFinite(number) ? number : null
}


module.exports = { normalizeUsage }
