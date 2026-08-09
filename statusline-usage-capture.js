'use strict'

const fs = require('fs')
const os = require('os')
const path = require('path')

const APP_DIRECTORY = process.env.USAGE_VIEWER_HOME ||
  path.join(os.homedir(), '.usage-viewer')

const LATEST_FILE = path.join(APP_DIRECTORY, 'latest.json')
const CLAUDE_LATEST_FILE = path.join(APP_DIRECTORY, 'claude-latest.json')
const CLAUDE_STATUSLINE_LATEST_FILE = path.join(APP_DIRECTORY, 'claude-statusline-latest.json')
const HISTORY_FILE = path.join(APP_DIRECTORY, 'history.jsonl')

let stdin = ''

process.stdin.setEncoding('utf8')
process.stdin.on('data', chunk => {
  stdin += chunk
})

process.stdin.on('end', () => {
  try {
    const data = JSON.parse(stdin || '{}')
    const snapshot = buildSnapshot(data)

    fs.mkdirSync(APP_DIRECTORY, { recursive: true })
    writeJsonAtomic(CLAUDE_STATUSLINE_LATEST_FILE, snapshot)
    writeJsonAtomic(CLAUDE_LATEST_FILE, snapshot)
    writeJsonAtomic(LATEST_FILE, snapshot)
    fs.appendFileSync(HISTORY_FILE, `${JSON.stringify(snapshot)}\n`, 'utf8')

    process.stdout.write(formatStatusLine(snapshot))
  } catch (error) {
    process.stdout.write(`usage-viewer error: ${error.message}`)
  }
})

function buildSnapshot(data) {
  const context = data.context_window || {}
  const usage = context.current_usage || {}
  const rateLimits = data.rate_limits || {}
  const fiveHour = rateLimits.five_hour || {}
  const sevenDay = rateLimits.seven_day || {}

  const freshInput = toNumber(usage.input_tokens)
  const output = toNumber(usage.output_tokens)
  const cacheRead = toNumber(usage.cache_read_input_tokens)
  const cacheWrite = toNumber(usage.cache_creation_input_tokens)
  const totalInput = freshInput + cacheRead + cacheWrite
  const newInput = freshInput + cacheWrite
  const cachedPct = percent(cacheRead, totalInput)

  const sessionCostUsd = toNumber(data.cost && data.cost.total_cost_usd)
  const previous = readJson(CLAUDE_LATEST_FILE)
  const turnCostUsd = calculateTurnCost({
    previous,
    promptId: nullableString(data.prompt_id),
    sessionCostUsd
  })

  return {
    generated_at: new Date().toISOString(),
    source: 'claude-code-statusline',
    session: {
      id: nullableString(data.session_id),
      name: nullableString(data.session_name),
      transcript_path: nullableString(data.transcript_path),
      working_directory: nullableString(data.workspace && data.workspace.current_dir)
    },
    model: {
      id: nullableString(data.model && (data.model.id || data.model.model_id)),
      name: nullableString(data.model && (
        data.model.display_name ||
        data.model.name ||
        data.model.id ||
        data.model.model_id
      )),
      effort: nullableString(data.effort && data.effort.level)
    },
    prompt_id: nullableString(data.prompt_id),
    tokens: {
      total_input: totalInput,
      fresh_input: freshInput,
      cache_read_input: cacheRead,
      cache_creation_input: cacheWrite,
      new_input: newInput,
      output
    },
    percentages: {
      context_used: nullableNumber(context.used_percentage),
      context_remaining: nullableNumber(context.remaining_percentage),
      cached_input: cachedPct,
      five_hour_used: nullableNumber(fiveHour.used_percentage),
      seven_day_used: nullableNumber(sevenDay.used_percentage)
    },
    cost: {
      session_usd: sessionCostUsd,
      turn_usd: turnCostUsd
    },
    resets_at: {
      five_hour_epoch_seconds: nullableEpochSeconds(fiveHour.resets_at),
      seven_day_epoch_seconds: nullableEpochSeconds(sevenDay.resets_at)
    }
  }
}

function calculateTurnCost({ previous, promptId, sessionCostUsd }) {
  if (!previous || !Number.isFinite(previous.cost && previous.cost.session_usd)) {
    return sessionCostUsd
  }

  const previousSessionCost = toNumber(previous.cost.session_usd)

  if (sessionCostUsd < previousSessionCost) {
    return sessionCostUsd
  }

  if (promptId && promptId !== previous.prompt_id) {
    return Math.max(0, sessionCostUsd - previousSessionCost)
  }

  return toNumber(previous.cost.turn_usd)
}

function formatStatusLine(snapshot) {
  const context = snapshot.percentages.context_used
  const fiveHour = snapshot.percentages.five_hour_used

  return [
    `ctx:${context === null ? '?' : `${context.toFixed(1)}%`}`,
    `in:${formatInteger(snapshot.tokens.total_input)}`,
    `cached:${snapshot.percentages.cached_input.toFixed(1)}%`,
    `new:${formatInteger(snapshot.tokens.new_input)}`,
    `out:${formatInteger(snapshot.tokens.output)}`,
    `cost:$${snapshot.cost.session_usd.toFixed(3)}`,
    `turn:$${snapshot.cost.turn_usd.toFixed(3)}`,
    `5h:${fiveHour === null ? '?' : `${fiveHour.toFixed(2)}%`}`
  ].join(' | ')
}

function readJson(filename) {
  try {
    return JSON.parse(fs.readFileSync(filename, 'utf8'))
  } catch {
    return null
  }
}

function writeJsonAtomic(filename, value) {
  const temporaryFile = `${filename}.${process.pid}.${Date.now()}.${Math.random().toString(16).slice(2)}.tmp`
  try {
    fs.writeFileSync(temporaryFile, JSON.stringify(value, null, 2), 'utf8')
    replaceFile(temporaryFile, filename)
  } finally {
    try {
      fs.rmSync(temporaryFile, { force: true })
    } catch {
      // Best-effort cleanup.
    }
  }
}

function replaceFile(temporaryFile, filename) {
  try {
    fs.renameSync(temporaryFile, filename)
    return
  } catch (error) {
    if (!['EEXIST', 'EPERM', 'EACCES'].includes(error.code)) {
      throw error
    }
  }

  const backupFile = `${filename}.bak-${process.pid}`

  try {
    if (fs.existsSync(filename)) {
      fs.renameSync(filename, backupFile)
    }

    fs.renameSync(temporaryFile, filename)
  } finally {
    try {
      fs.rmSync(backupFile, { force: true })
    } catch {
      // Best-effort cleanup.
    }
  }
}

function nullableNumber(value) {
  if (value === null || value === undefined || value === '') {
    return null
  }

  const number = Number(value)
  return Number.isFinite(number) ? number : null
}

function nullableEpochSeconds(value) {
  const number = nullableNumber(value)

  if (number !== null) {
    return number > 9999999999 ? Math.floor(number / 1000) : number
  }

  if (typeof value === 'string') {
    const parsed = Date.parse(value)
    return Number.isFinite(parsed) ? Math.floor(parsed / 1000) : null
  }

  return null
}

function toNumber(value) {
  return nullableNumber(value) || 0
}

function nullableString(value) {
  if (value === null || value === undefined) {
    return null
  }

  const text = String(value).trim()
  return text.length > 0 ? text : null
}

function percent(part, total) {
  return total > 0 ? (part / total) * 100 : 0
}

function formatInteger(value) {
  return new Intl.NumberFormat('en-US', {
    maximumFractionDigits: 0
  }).format(value)
}
