'use strict'

const fs = require('fs')
const os = require('os')
const path = require('path')

const CLAUDE_HOME = process.env.CLAUDE_HOME ||
  path.join(os.homedir(), '.claude')

const USAGE_VIEWER_HOME = process.env.USAGE_VIEWER_HOME ||
  path.join(os.homedir(), '.usage-viewer')

const PROJECTS_DIRECTORY = path.join(CLAUDE_HOME, 'projects')
const CLAUDE_DESKTOP_DATA_DIRECTORY = process.env.CLAUDE_DESKTOP_DATA_DIRECTORY ||
  path.join(
    process.env.LOCALAPPDATA || path.join(os.homedir(), 'AppData', 'Local'),
    'Packages',
    'Claude_pzs8sxrjxfjjc',
    'LocalCache',
    'Roaming',
    'Claude'
  )
const PLAN_USAGE_HISTORY_FILE = path.join(
  CLAUDE_DESKTOP_DATA_DIRECTORY,
  'plan-usage-history.json'
)
const LATEST_FILE = path.join(USAGE_VIEWER_HOME, 'latest.json')
const CLAUDE_LATEST_FILE = path.join(USAGE_VIEWER_HOME, 'claude-latest.json')
const CLAUDE_APP_LATEST_FILE = path.join(USAGE_VIEWER_HOME, 'claude-app-latest.json')
const CLAUDE_STATUSLINE_LATEST_FILE = path.join(USAGE_VIEWER_HOME, 'claude-statusline-latest.json')
const HISTORY_FILE = path.join(USAGE_VIEWER_HOME, 'history.jsonl')

try {
  const snapshot = readClaudeDesktopUsage()
  fs.mkdirSync(USAGE_VIEWER_HOME, { recursive: true })
  writeJsonAtomic(CLAUDE_LATEST_FILE, snapshot)
  writeJsonAtomic(CLAUDE_APP_LATEST_FILE, snapshot)
  writeJsonAtomic(LATEST_FILE, snapshot)
  fs.appendFileSync(HISTORY_FILE, `${JSON.stringify(snapshot)}\n`, 'utf8')
  process.stdout.write(formatSummary(snapshot))
} catch (error) {
  process.stderr.write(`claude desktop usage read error: ${error.message}\n`)
  process.exitCode = 1
}

function readClaudeDesktopUsage() {
  const latest = findLatestUsage(PROJECTS_DIRECTORY)

  if (!latest) {
    throw new Error(`No Claude Desktop usage found in ${PROJECTS_DIRECTORY}`)
  }

  const entry = latest.entry
  const sourceFileMtime = new Date(latest.mtimeMs).toISOString()
  const message = entry.message || {}
  const usage = message.usage || {}
  const iterations = Array.isArray(usage.iterations) ? usage.iterations : []
  const lastIteration = iterations.length > 0 ? iterations[iterations.length - 1] : {}

  const inputTokens = firstNumber([
    usage.input_tokens,
    lastIteration.input_tokens
  ])
  const cacheReadInputTokens = firstNumber([
    usage.cache_read_input_tokens,
    lastIteration.cache_read_input_tokens
  ])
  const cacheCreationInputTokens = firstNumber([
    usage.cache_creation_input_tokens,
    lastIteration.cache_creation_input_tokens
  ])
  const outputTokens = firstNumber([
    usage.output_tokens,
    lastIteration.output_tokens
  ])
  const totalInput = inputTokens + cacheReadInputTokens + cacheCreationInputTokens
  const planUsage = readLatestPlanUsage()
  const previous = readJson(CLAUDE_LATEST_FILE)
  const previousResets = previous && previous.resets_at ? previous.resets_at : {}
  const statusLineResets = readLatestStatusLineResets()
  const estimatedResets = estimatePlanUsageResets()
  const fiveHourReset = firstFutureEpochSeconds([
    statusLineResets.five_hour_epoch_seconds,
    previousResets.five_hour_epoch_seconds,
    estimatedResets.five_hour_epoch_seconds
  ])
  const sevenDayReset = firstFutureEpochSeconds([
    statusLineResets.seven_day_epoch_seconds,
    previousResets.seven_day_epoch_seconds,
    estimatedResets.seven_day_epoch_seconds
  ])

  return {
    generated_at: new Date().toISOString(),
    observed_at: nullableString(entry.timestamp) || sourceFileMtime,
    source_file_mtime: sourceFileMtime,
    source: 'claude-desktop-jsonl',
    source_file: latest.file,
    session: {
      id: nullableString(entry.sessionId),
      name: null,
      transcript_path: latest.file,
      working_directory: nullableString(entry.cwd)
    },
    model: {
      id: nullableString(message.model),
      name: nullableString(message.model),
      effort: nullableString(entry.effort)
    },
    prompt_id: nullableString(message.id || entry.requestId),
    tokens: {
      total_input: totalInput,
      fresh_input: inputTokens,
      cache_read_input: cacheReadInputTokens,
      cache_creation_input: cacheCreationInputTokens,
      new_input: inputTokens + cacheCreationInputTokens,
      output: outputTokens
    },
    percentages: {
      context_used: null,
      context_remaining: null,
      cached_input: totalInput > 0 ? (cacheReadInputTokens / totalInput) * 100 : 0,
      five_hour_used: planUsage ? nullableNumber(planUsage.usage.fh) : null,
      seven_day_used: planUsage ? nullableNumber(planUsage.usage.sd) : null
    },
    cost: {
      session_usd: null,
      turn_usd: null
    },
    resets_at: {
      five_hour_epoch_seconds: fiveHourReset,
      seven_day_epoch_seconds: sevenDayReset
    },
    estimated_resets_at: {
      five_hour_epoch_seconds: estimatedResets.five_hour_epoch_seconds,
      seven_day_epoch_seconds: estimatedResets.seven_day_epoch_seconds,
      source: estimatedResets.source
    },
    plan_usage: {
      source_file: planUsage ? PLAN_USAGE_HISTORY_FILE : null,
      observed_at: planUsage ? new Date(planUsage.timestamp).toISOString() : null,
      org: planUsage ? nullableString(planUsage.org) : null
    }
  }
}

function readLatestStatusLineResets() {
  const empty = {
    five_hour_epoch_seconds: null,
    seven_day_epoch_seconds: null
  }

  const latest = readJson(CLAUDE_STATUSLINE_LATEST_FILE)

  if (latest && latest.source === 'claude-code-statusline' && latest.resets_at) {
    return {
      five_hour_epoch_seconds: futureEpochSeconds(latest.resets_at.five_hour_epoch_seconds),
      seven_day_epoch_seconds: futureEpochSeconds(latest.resets_at.seven_day_epoch_seconds)
    }
  }

  const file = HISTORY_FILE

  if (!fs.existsSync(file)) {
    return empty
  }

  try {
    const stat = fs.statSync(file)
    const bytesToRead = Math.min(stat.size, 4 * 1024 * 1024)
    const buffer = Buffer.alloc(bytesToRead)
    const fd = fs.openSync(file, 'r')

    try {
      fs.readSync(fd, buffer, 0, bytesToRead, stat.size - bytesToRead)
    } finally {
      fs.closeSync(fd)
    }

    const lines = buffer.toString('utf8').split(/\r?\n/).filter(Boolean)

    for (let index = lines.length - 1; index >= 0; index -= 1) {
      let entry

      try {
        entry = JSON.parse(lines[index])
      } catch {
        continue
      }

      if (entry.source !== 'claude-code-statusline' || !entry.resets_at) {
        continue
      }

      return {
        five_hour_epoch_seconds: futureEpochSeconds(entry.resets_at.five_hour_epoch_seconds),
        seven_day_epoch_seconds: futureEpochSeconds(entry.resets_at.seven_day_epoch_seconds)
      }
    }
  } catch {
    return empty
  }

  return empty
}

function readLatestPlanUsage() {
  if (!fs.existsSync(PLAN_USAGE_HISTORY_FILE)) {
    return null
  }

  try {
    const data = JSON.parse(fs.readFileSync(PLAN_USAGE_HISTORY_FILE, 'utf8'))
    const samples = Array.isArray(data.samples) ? data.samples : []
    const latest = samples
      .filter(sample => sample && sample.u && Number.isFinite(Number(sample.t)))
      .sort((left, right) => Number(right.t) - Number(left.t))[0]

    if (!latest) {
      return null
    }

    return {
      timestamp: Number(latest.t),
      org: latest.org,
      usage: latest.u
    }
  } catch {
    return null
  }
}

function estimatePlanUsageResets() {
  const empty = {
    five_hour_epoch_seconds: null,
    seven_day_epoch_seconds: null,
    source: null
  }

  if (!fs.existsSync(PLAN_USAGE_HISTORY_FILE)) {
    return empty
  }

  try {
    const data = JSON.parse(fs.readFileSync(PLAN_USAGE_HISTORY_FILE, 'utf8'))
    const samples = (Array.isArray(data.samples) ? data.samples : [])
      .filter(sample => sample && sample.u && Number.isFinite(Number(sample.t)))
      .map(sample => ({
        timestamp: Number(sample.t),
        fiveHour: nullableNumber(sample.u.fh),
        sevenDay: nullableNumber(sample.u.sd)
      }))
      .sort((left, right) => left.timestamp - right.timestamp)

    if (samples.length === 0) {
      return empty
    }

    return {
      five_hour_epoch_seconds: estimateFiveHourReset(samples),
      seven_day_epoch_seconds: estimateSevenDayReset(samples),
      source: 'claude-desktop-plan-usage-history-estimate'
    }
  } catch {
    return empty
  }
}

function estimateFiveHourReset(samples) {
  const latest = samples[samples.length - 1]

  if (!latest || !Number.isFinite(latest.fiveHour) || latest.fiveHour <= 0) {
    return null
  }

  let startIndex = samples.length - 1

  for (let index = samples.length - 2; index >= 0; index -= 1) {
    const current = samples[index]
    const next = samples[index + 1]

    if (!Number.isFinite(current.fiveHour) || current.fiveHour <= 0) {
      break
    }

    if (next.timestamp - current.timestamp > 30 * 60 * 1000) {
      break
    }

    startIndex = index
  }

  const resetMillis = samples[startIndex].timestamp + (5 * 60 * 60 * 1000)
  return futureEpochSeconds(Math.floor(resetMillis / 1000))
}

function estimateSevenDayReset(samples) {
  let resetStartMillis = null

  for (let index = 1; index < samples.length; index += 1) {
    const previous = samples[index - 1]
    const current = samples[index]

    if (
      Number.isFinite(previous.sevenDay) &&
      Number.isFinite(current.sevenDay) &&
      current.sevenDay < previous.sevenDay
    ) {
      resetStartMillis = current.timestamp
    }
  }

  if (resetStartMillis === null) {
    return null
  }

  const resetMillis = resetStartMillis + (7 * 24 * 60 * 60 * 1000)
  return futureEpochSeconds(Math.floor(resetMillis / 1000))
}

function findLatestUsage(root) {
  if (!fs.existsSync(root)) {
    return null
  }

  const files = [...walkFiles(root)]
    .filter(file => file.endsWith('.jsonl'))
    .map(file => ({
      file,
      mtimeMs: fs.statSync(file).mtimeMs
    }))
    .sort((left, right) => right.mtimeMs - left.mtimeMs)
    .slice(0, 100)

  let latest = null

  for (const item of files) {
    const entry = readLatestUsageEntry(item.file)

    if (!entry) {
      continue
    }

    if (entry.entrypoint !== 'claude-desktop') {
      continue
    }

    const timestamp = Date.parse(entry.timestamp || '') || item.mtimeMs

    if (!latest || timestamp > latest.timestamp) {
      latest = {
        file: item.file,
        mtimeMs: item.mtimeMs,
        timestamp,
        entry
      }
    }
  }

  return latest
}

function readLatestUsageEntry(file) {
  let latest = null

  for (const line of fs.readFileSync(file, 'utf8').split(/\r?\n/)) {
    if (!line.trim()) {
      continue
    }

    let entry

    try {
      entry = JSON.parse(line)
    } catch {
      continue
    }

    if (!hasUsage(entry)) {
      continue
    }

    latest = entry
  }

  return latest
}

function hasUsage(entry) {
  const usage = entry &&
    entry.message &&
    entry.message.role === 'assistant' &&
    entry.message.usage

  if (!usage) {
    return false
  }

  return [
    usage.input_tokens,
    usage.cache_creation_input_tokens,
    usage.cache_read_input_tokens,
    usage.output_tokens
  ].some(value => Number.isFinite(Number(value)))
}

function* walkFiles(root) {
  const entries = fs.readdirSync(root, { withFileTypes: true })

  for (const entry of entries) {
    const fullPath = path.join(root, entry.name)

    if (entry.isDirectory()) {
      yield* walkFiles(fullPath)
    } else if (entry.isFile()) {
      yield fullPath
    }
  }
}

function firstNumber(values) {
  for (const value of values) {
    const number = toNumber(value)

    if (Number.isFinite(number)) {
      return number
    }
  }

  return 0
}

function toNumber(value) {
  if (value === null || value === undefined || value === '') {
    return 0
  }

  const number = Number(value)
  return Number.isFinite(number) ? number : 0
}

function nullableString(value) {
  if (value === null || value === undefined || value === '') {
    return null
  }

  return String(value)
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

function futureEpochSeconds(value) {
  const epochSeconds = nullableEpochSeconds(value)

  if (epochSeconds === null) {
    return null
  }

  const nowSeconds = Math.floor(Date.now() / 1000)
  return epochSeconds > nowSeconds ? epochSeconds : null
}

function firstFutureEpochSeconds(values) {
  for (const value of values) {
    const epochSeconds = futureEpochSeconds(value)

    if (epochSeconds !== null) {
      return epochSeconds
    }
  }

  return null
}

function readJson(file) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'))
  } catch {
    return null
  }
}

function writeJsonAtomic(file, data) {
  const tempFile = `${file}.tmp-${process.pid}-${Date.now()}-${Math.random().toString(16).slice(2)}`
  try {
    fs.writeFileSync(tempFile, `${JSON.stringify(data, null, 2)}\n`, 'utf8')
    replaceFile(tempFile, file)
  } finally {
    try {
      fs.rmSync(tempFile, { force: true })
    } catch {
      // Best-effort cleanup.
    }
  }
}

function replaceFile(tempFile, file) {
  try {
    fs.renameSync(tempFile, file)
    return
  } catch (error) {
    if (!['EEXIST', 'EPERM', 'EACCES'].includes(error.code)) {
      throw error
    }
  }

  const backupFile = `${file}.bak-${process.pid}`

  try {
    if (fs.existsSync(file)) {
      fs.renameSync(file, backupFile)
    }

    fs.renameSync(tempFile, file)
  } finally {
    try {
      fs.rmSync(backupFile, { force: true })
    } catch {
      // Best-effort cleanup.
    }
  }
}

function formatSummary(snapshot) {
  return [
    `Claude Desktop ${snapshot.model.name || 'unknown'}`,
    `in ${formatCount(snapshot.tokens.total_input)}`,
    `out ${formatCount(snapshot.tokens.output)}`,
    `cached ${formatPercent(snapshot.percentages.cached_input)}`
  ].join(' ')
}

function formatCount(value) {
  return Number(value || 0).toLocaleString('en-US')
}

function formatPercent(value) {
  if (value === null || value === undefined) {
    return '?'
  }

  return `${Number(value).toFixed(1)}%`
}
