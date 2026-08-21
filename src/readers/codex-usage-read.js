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
const CODEX_APP_LATEST_FILE = path.join(USAGE_VIEWER_HOME, 'codex-app-latest.json')
const CODEX_DESKTOP_LATEST_FILE = path.join(USAGE_VIEWER_HOME, 'codex-desktop-latest.json')
const CODEX_CLI_LATEST_FILE = path.join(USAGE_VIEWER_HOME, 'codex-cli-latest.json')
const HISTORY_FILE = path.join(USAGE_VIEWER_HOME, 'codex-history.jsonl')

try {
  const snapshots = readCodexUsageByMode()
  const snapshot = snapshots.selected
  fs.mkdirSync(USAGE_VIEWER_HOME, { recursive: true })
  if (snapshots.desktop) writeJsonAtomic(CODEX_DESKTOP_LATEST_FILE, snapshots.desktop)
  if (snapshots.cli) writeJsonAtomic(CODEX_CLI_LATEST_FILE, snapshots.cli)
  writeJsonAtomic(CODEX_APP_LATEST_FILE, snapshot)
  writeJsonAtomic(CODEX_LATEST_FILE, snapshot)
  writeJsonAtomic(LATEST_FILE, snapshot)
  fs.appendFileSync(HISTORY_FILE, `${JSON.stringify(snapshot)}\n`, 'utf8')
  process.stdout.write(formatSummary(snapshot))
} catch (error) {
  process.stderr.write(`codex usage read error: ${error.message}\n`)
  process.exitCode = 1
}

function readCodexUsageByMode() {
  const usageSessions = findLatestUsageSessionsByMode(SESSIONS_DIRECTORY)
  const desktop = usageSessions.desktop
    ? buildCodexSnapshot(usageSessions.desktop, 'desktop')
    : null
  const cli = usageSessions.cli
    ? buildCodexSnapshot(usageSessions.cli, 'cli')
    : null
  const available = [desktop, cli].filter(Boolean)

  if (available.length === 0) {
    throw new Error(`No direct Codex rate-limit usage found in ${SESSIONS_DIRECTORY}`)
  }

  return {
    desktop,
    cli,
    selected: available.sort((left, right) =>
      Date.parse(right.observed_at) - Date.parse(left.observed_at))[0]
  }
}

function buildCodexSnapshot(usageSession, sourceMode) {
  const sessionFile = usageSession.sessionFile
  const sourceFileMtime = new Date(usageSession.mtimeMs).toISOString()
  const sessionMeta = usageSession.sessionMeta
  const turnContext = usageSession.turnContext
  const tokenCount = usageSession.tokenCount

  const payload = tokenCount.payload || {}
  const info = payload.info || {}
  const lastUsage = info.last_token_usage || {}
  const totalUsage = info.total_token_usage || {}
  const rateLimits = payload.rate_limits || {}
  const primaryLimit = rateLimits.primary || {}
  const lastTotalTokens = toNumber(lastUsage.total_tokens)
  const primaryUsed = nullableNumber(primaryLimit.used_percent)
  const primaryWindowMinutes = nullableNumber(primaryLimit.window_minutes)
  const fiveHourLimit = findRateLimitWindow(rateLimits, 300)
  const sevenDayLimit = findRateLimitWindow(rateLimits, 10080)

  const inputTokens = toNumber(lastUsage.input_tokens)
  const cachedInputTokens = toNumber(lastUsage.cached_input_tokens)
  const cacheWriteInputTokens = toNumber(lastUsage.cache_write_input_tokens)
  const outputTokens = toNumber(lastUsage.output_tokens)

  return {
    generated_at: new Date().toISOString(),
    // The reader may run while Codex is appending to the session file. Keep
    // the source event time separate from the time this snapshot was written.
    observed_at: nullableString(tokenCount.timestamp) || sourceFileMtime,
    source_file_mtime: sourceFileMtime,
    source: 'codex-session-rate-limits',
    source_mode: sourceMode,
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
      context_used: null,
      context_remaining: null,
      cached_input: inputTokens > 0 ? (cachedInputTokens / inputTokens) * 100 : 0,
      five_hour_used: nullableNumber(fiveHourLimit.used_percent),
      seven_day_used: nullableNumber(sevenDayLimit.used_percent),
      primary_limit_used: primaryUsed
    },
    cost: {
      session_usd: 0,
      turn_usd: 0
    },
    rate_limits: {
      primary_window_minutes: primaryWindowMinutes,
      plan_type: nullableString(rateLimits.plan_type),
    },
    resets_at: {
      five_hour_epoch_seconds: nullableNumber(fiveHourLimit.resets_at),
      seven_day_epoch_seconds: nullableNumber(sevenDayLimit.resets_at)
    }
  }
}

function findLatestUsageSessionsByMode(root) {
  const files = [...walkFiles(root)]
    .filter(file => file.endsWith('.jsonl'))
    .map(file => ({
      file,
      mtimeMs: fs.statSync(file).mtimeMs
    }))
    .sort((left, right) => right.mtimeMs - left.mtimeMs)

  const latestByMode = {}

  for (const item of files) {
    const parsed = readUsageSessionFile(item.file)

    if (!parsed || !parsed.tokenCount) {
      continue
    }

    const mode = classifySourceMode(parsed.sessionMeta)
    if (!mode) {
      continue
    }

    const tokenTime = Date.parse(parsed.tokenCount.timestamp || '') || item.mtimeMs

    if (!latestByMode[mode] || tokenTime > latestByMode[mode].tokenTime) {
      latestByMode[mode] = {
        ...parsed,
        sessionFile: item.file,
        mtimeMs: item.mtimeMs,
        tokenTime
      }
    }

    if (latestByMode.desktop && latestByMode.cli) break
  }

  return latestByMode
}

function readUsageSessionFile(sessionFile) {
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
      event.payload.type === 'token_count' &&
      hasDirectRateLimitUsage(event)
    ) {
      tokenCount = event
    }
  }

  return {
    sessionMeta,
    turnContext,
    tokenCount
  }
}

function classifySourceMode(sessionMeta) {
  const source = nullableString(sessionMeta && sessionMeta.source)
    ?.toLowerCase()
  const originator = nullableString(sessionMeta && sessionMeta.originator)
    ?.toLowerCase()

  if (
    (originator || '').includes('desktop') ||
    (originator || '').includes('codex_vscode') ||
    source === 'vscode' ||
    source === 'codex_vscode'
  ) {
    return 'desktop'
  }

  if (source === 'cli' || (originator || '').includes('codex-tui')) {
    return 'cli'
  }

  return null
}

function hasDirectRateLimitUsage(event) {
  const rateLimits = event && event.payload && event.payload.rate_limits
  return ['primary', 'secondary'].some(name =>
    nullableNumber(rateLimits && rateLimits[name] && rateLimits[name].used_percent) !== null)
}

function findRateLimitWindow(rateLimits, windowMinutes) {
  for (const name of ['primary', 'secondary']) {
    const limit = rateLimits && rateLimits[name]
    if (nullableNumber(limit && limit.window_minutes) === windowMinutes) {
      return limit
    }
  }
  return {}
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
  const temporaryFile = `${filename}.${process.pid}.${Date.now()}.${Math.random().toString(16).slice(2)}.tmp`
  try {
    let written = false
    let lastError
    for (let attempt = 0; attempt < 8 && !written; attempt += 1) {
      try {
        fs.writeFileSync(temporaryFile, JSON.stringify(value, null, 2), 'utf8')
        written = true
      } catch (error) {
        lastError = error
        if (!['EPERM', 'EACCES', 'EBUSY'].includes(error.code)) throw error
        waitMilliseconds(75)
      }
    }
    if (!written) throw lastError
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
  let lastError

  // UsageViewer.exe may briefly hold the destination while it refreshes.
  // Windows does not allow replacing an open file, so retry the atomic
  // rename before falling back to the backup-file path.
  for (let attempt = 0; attempt < 8; attempt += 1) {
    try {
      fs.renameSync(temporaryFile, filename)
      return
    } catch (error) {
      lastError = error
      if (!['EEXIST', 'EPERM', 'EACCES'].includes(error.code)) {
        throw error
      }
      waitMilliseconds(75)
    }
  }

  const backupFile = `${filename}.bak-${process.pid}`

  try {
    if (fs.existsSync(filename)) {
      renameWithRetry(filename, backupFile, lastError)
    }

    renameWithRetry(temporaryFile, filename, lastError)
  } finally {
    try {
      fs.rmSync(backupFile, { force: true })
    } catch {
      // Best-effort cleanup.
    }
  }
}

function renameWithRetry(source, destination, fallbackError) {
  let lastError = fallbackError
  for (let attempt = 0; attempt < 8; attempt += 1) {
    try {
      fs.renameSync(source, destination)
      return
    } catch (error) {
      lastError = error
      if (!['EEXIST', 'EPERM', 'EACCES'].includes(error.code)) {
        throw error
      }
      waitMilliseconds(75)
    }
  }
  throw lastError
}

function waitMilliseconds(milliseconds) {
  // Synchronous reader: Atomics.wait provides a small blocking delay without
  // introducing another dependency or changing the CLI's execution model.
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, milliseconds)
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
  return [
    `Codex source: ${snapshot.source_mode}`,
    `7d: ${formatPercent(snapshot.percentages.seven_day_used)}`,
    `5h: ${formatPercent(snapshot.percentages.five_hour_used)}`,
    `Input: ${formatInteger(snapshot.tokens.total_input)}`,
    `Cached input: ${formatInteger(snapshot.tokens.cache_read_input)} (${snapshot.percentages.cached_input.toFixed(1)}%)`,
    `New input: ${formatInteger(snapshot.tokens.new_input)}`,
    `Output: ${formatInteger(snapshot.tokens.output)}`,
    `Reasoning output: ${formatInteger(snapshot.tokens.reasoning_output)}`,
    `Session total: ${formatInteger(snapshot.tokens.session_total)}`,
    `Plan: ${snapshot.rate_limits.plan_type || '?'}`,
    `Primary window minutes: ${snapshot.rate_limits.primary_window_minutes || '?'}`,
    `7d reset: ${formatEpoch(snapshot.resets_at.seven_day_epoch_seconds)}`,
    `5h reset: ${formatEpoch(snapshot.resets_at.five_hour_epoch_seconds)}`,
    `Source: ${snapshot.source_file}`
  ].join('\n') + '\n'
}

function formatPercent(value) {
  const number = nullableNumber(value)
  return number === null ? '?' : `${number.toFixed(2)}%`
}

function formatInteger(value) {
  return new Intl.NumberFormat('en-US', {
    maximumFractionDigits: 0
  }).format(value)
}

function formatEpoch(epochSeconds) {
  const number = nullableNumber(epochSeconds)
  if (number === null) {
    return '?'
  }

  return new Date(number * 1000).toISOString()
}
