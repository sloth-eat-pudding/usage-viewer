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
  const rateLimits = data.rate_limits || {}
  const fiveHour = rateLimits.five_hour || {}
  const sevenDay = rateLimits.seven_day || {}

  return {
    generated_at: new Date().toISOString(),
    source: 'claude-code-statusline',
    source_mode: 'cli',
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
    percentages: {
      context_used: nullableNumber(context.used_percentage),
      context_remaining: nullableNumber(context.remaining_percentage),
      five_hour_used: nullableNumber(fiveHour.used_percentage),
      seven_day_used: nullableNumber(sevenDay.used_percentage)
    },
    resets_at: {
      five_hour_epoch_seconds: nullableEpochSeconds(fiveHour.resets_at),
      seven_day_epoch_seconds: nullableEpochSeconds(sevenDay.resets_at)
    }
  }
}

function formatStatusLine(snapshot) {
  const fiveHour = snapshot.percentages.five_hour_used
  const sevenDay = snapshot.percentages.seven_day_used

  return [
    `7d:${sevenDay === null ? '?' : `${sevenDay.toFixed(2)}%`}`,
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
