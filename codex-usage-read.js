'use strict'

const fs = require('fs')
const os = require('os')
const path = require('path')

const CODEX_HOME = process.env.CODEX_HOME ||
  path.join(os.homedir(), '.codex')

const USAGE_VIEWER_HOME = process.env.USAGE_VIEWER_HOME ||
  path.join(os.homedir(), '.usage-viewer')

const SESSIONS_DIRECTORY = path.join(CODEX_HOME, 'sessions')
const LATEST_FILE = path.join(USAGE_VIEWER_HOME, 'latest.json')
const CODEX_LATEST_FILE = path.join(USAGE_VIEWER_HOME, 'codex-latest.json')
const HISTORY_FILE = path.join(USAGE_VIEWER_HOME, 'codex-history.jsonl')

try {
  const snapshot = readCodexUsage()
  fs.mkdirSync(USAGE_VIEWER_HOME, { recursive: true })
  writeJsonAtomic(CODEX_LATEST_FILE, snapshot)
  writeJsonAtomic(LATEST_FILE, snapshot)
  fs.appendFileSync(HISTORY_FILE, `${JSON.stringify(snapshot)}\n`, 'utf8')
  process.stdout.write(formatSummary(snapshot))
} catch (error) {
  process.stderr.write(`codex usage read error: ${error.message}\n`)
  process.exitCode = 1
}

function readCodexUsage() {
  const sessionFile = findLatestSessionFile(SESSIONS_DIRECTORY)

  if (!sessionFile) {
    throw new Error(`No Codex session files found in ${SESSIONS_DIRECTORY}`)
  }

  const lines = fs.readFileSync(sessionFile, 'utf8')
    .split(/\r?\n/)
    .filter(Boolean)

  let sessionMeta = null
  let turnContext = null
  let tokenCount = null

  for (const line of lines) {
    const event = parseJsonLine(line)
    if (!event) {
      continue
    }

    if (event.type === 'session_meta') {
      sessionMeta = event.payload || sessionMeta
      continue
    }

    if (event.type === 'turn_context') {
      turnContext = event.payload || turnContext
      continue
    }

    if (
      event.type === 'event_msg' &&
      event.payload &&
      event.payload.type === 'token_count'
    ) {
      tokenCount = event
    }
  }

  if (!tokenCount) {
    throw new Error(`No token_count event found in ${sessionFile}`)
  }

  const payload = tokenCount.payload || {}
  const info = payload.info || {}
  const lastUsage = info.last_token_usage || {}
  const totalUsage = info.total_token_usage || {}
  const rateLimits = payload.rate_limits || {}
  const primaryLimit = rateLimits.primary || {}
  const modelContextWindow = toNumber(info.model_context_window)
  const lastTotalTokens = toNumber(lastUsage.total_tokens)
  const contextUsed = modelContextWindow > 0
    ? (lastTotalTokens / modelContextWindow) * 100
    : null

  const primaryUsed = nullableNumber(primaryLimit.used_percent)
  const primaryWindowMinutes = nullableNumber(primaryLimit.window_minutes)
  const isSevenDayWindow = primaryWindowMinutes === 10080
  const isFiveHourWindow = primaryWindowMinutes === 300

  const inputTokens = toNumber(lastUsage.input_tokens)
  const cachedInputTokens = toNumber(lastUsage.cached_input_tokens)
  const cacheWriteInputTokens = toNumber(lastUsage.cache_write_input_tokens)
  const outputTokens = toNumber(lastUsage.output_tokens)

  return {
    generated_at: new Date().toISOString(),
    source: 'codex-session-jsonl',
    source_file: sessionFile,
    session: {
      id: nullableString(sessionMeta && (sessionMeta.session_id || sessionMeta.id)),
      name: null,
      transcript_path: sessionFile,
      working_directory: nullableString(
        (turnContext && turnContext.cwd) ||
        (sessionMeta && sessionMeta.cwd)
      )
    },
    model: {
      id: nullableString(
        (turnContext && turnContext.model) ||
        (sessionMeta && sessionMeta.model)
      ),
      name: nullableString(
        (turnContext && turnContext.model) ||
        (sessionMeta && sessionMeta.model)
      ),
      effort: nullableString(
        (turnContext && (turnContext.effort || turnContext.summary)) ||
        (sessionMeta && sessionMeta.effort)
      )
    },
    prompt_id: nullableString(tokenCount.payload && tokenCount.payload.turn_id),
    tokens: {
      total_input: inputTokens,
      fresh_input: Math.max(0, inputTokens - cachedInputTokens),
      cache_read_input: cachedInputTokens,
      cache_creation_input: cacheWriteInputTokens,
      new_input: Math.max(0, inputTokens - cachedInputTokens) + cacheWriteInputTokens,
      output: outputTokens,
      reasoning_output: toNumber(lastUsage.reasoning_output_tokens),
      total: lastTotalTokens,
      session_total: toNumber(totalUsage.total_tokens)
    },
    percentages: {
      context_used: contextUsed,
      context_remaining: contextUsed === null ? null : Math.max(0, 100 - contextUsed),
      cached_input: inputTokens > 0 ? (cachedInputTokens / inputTokens) * 100 : 0,
      five_hour_used: isFiveHourWindow ? primaryUsed : null,
      seven_day_used: isSevenDayWindow ? primaryUsed : null,
      primary_limit_used: primaryUsed
    },
    cost: {
      session_usd: 0,
      turn_usd: 0
    },
    rate_limits: {
      primary: {
        used_percent: primaryUsed,
        window_minutes: primaryWindowMinutes,
        resets_at_epoch_seconds: nullableNumber(primaryLimit.resets_at)
      },
      plan_type: nullableString(rateLimits.plan_type),
      limit_id: nullableString(rateLimits.limit_id),
      rate_limit_reached_type: nullableString(rateLimits.rate_limit_reached_type)
    },
    resets_at: {
      five_hour_epoch_seconds: isFiveHourWindow ? nullableNumber(primaryLimit.resets_at) : null,
      seven_day_epoch_seconds: isSevenDayWindow ? nullableNumber(primaryLimit.resets_at) : null
    }
  }
}

function findLatestSessionFile(root) {
  let latest = null

  for (const file of walkFiles(root)) {
    if (!file.endsWith('.jsonl')) {
      continue
    }

    const stat = fs.statSync(file)
    if (!latest || stat.mtimeMs > latest.mtimeMs) {
      latest = {
        file,
        mtimeMs: stat.mtimeMs
      }
    }
  }

  return latest && latest.file
}

function* walkFiles(directory) {
  if (!fs.existsSync(directory)) {
    return
  }

  for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
    const fullPath = path.join(directory, entry.name)

    if (entry.isDirectory()) {
      yield* walkFiles(fullPath)
    } else if (entry.isFile()) {
      yield fullPath
    }
  }
}

function parseJsonLine(line) {
  try {
    return JSON.parse(line)
  } catch {
    return null
  }
}

function writeJsonAtomic(filename, value) {
  const temporaryFile = `${filename}.${process.pid}.tmp`
  fs.writeFileSync(temporaryFile, JSON.stringify(value, null, 2), 'utf8')

  try {
    fs.rmSync(filename, { force: true })
  } catch {
    // Ignore replacement races.
  }

  fs.renameSync(temporaryFile, filename)
}

function nullableNumber(value) {
  if (value === null || value === undefined || value === '') {
    return null
  }

  const number = Number(value)
  return Number.isFinite(number) ? number : null
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

function formatSummary(snapshot) {
  const week = snapshot.percentages.seven_day_used
  const primary = snapshot.percentages.primary_limit_used
  const limit = week === null ? primary : week
  const limitName = week === null ? 'limit' : 'week'

  return [
    `codex ${limitName}:${limit === null ? '?' : `${limit.toFixed(2)}%`}`,
    `in:${formatInteger(snapshot.tokens.total_input)}`,
    `cached:${snapshot.percentages.cached_input.toFixed(1)}%`,
    `out:${formatInteger(snapshot.tokens.output)}`,
    `ctx:${snapshot.percentages.context_used === null ? '?' : `${snapshot.percentages.context_used.toFixed(1)}%`}`
  ].join(' | ')
}

function formatInteger(value) {
  return new Intl.NumberFormat('en-US', {
    maximumFractionDigits: 0
  }).format(value)
}
