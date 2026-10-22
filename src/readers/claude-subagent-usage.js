'use strict'
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const UUID = /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i
const USAGE_KEYS = ['input_tokens', 'output_tokens', 'cache_read_input_tokens', 'cache_creation_input_tokens',
  'cache_creation', 'server_tool_use', 'speed', 'service_tier', 'inference_geo']

// Return accounting fields only. Never expose message content or accept a path
// from the renderer. Each child must link to an Agent/Task tool call in this tree.
function readSubagentUsage(sessionId, projectsRoot = path.join(process.env.CLAUDE_HOME || path.join(os.homedir(), '.claude'), 'projects')) {
  if (!UUID.test(sessionId)) throw new Error('Invalid session ID')
  const result = { session_id: sessionId, agents: [], complete: true, missing: 0 }
  let roots
  try {
    roots = fs.readdirSync(projectsRoot, { withFileTypes: true }).filter(e => e.isDirectory())
      .map(e => path.join(projectsRoot, e.name)).filter(dir => fs.existsSync(path.join(dir, sessionId + '.jsonl')))
  } catch { return { ...result, complete: false } }
  if (roots.length !== 1) return { ...result, complete: false }
  const project = roots[0]
  const safeFile = file => {
    const relative = path.relative(fs.realpathSync(project), fs.realpathSync(file))
    if (relative.startsWith('..') || path.isAbsolute(relative) || fs.statSync(file).size > 64 * 1024 * 1024) throw new Error('Unreadable transcript')
    return file
  }
  const readRows = file => {
    const rows = []
    for (const line of fs.readFileSync(safeFile(file), 'utf8').split(/\r?\n/)) {
      if (!line.trim()) continue
      try {
        const row = JSON.parse(line)
        if (!row || typeof row !== 'object' || Array.isArray(row)) { result.complete = false; continue }
        rows.push(row)
      } catch { result.complete = false }
    }
    return rows
  }
  const tools = new Set()
  const collectTools = rows => {
    for (const row of rows) {
      if (row.sessionId !== sessionId) continue
      for (const block of Array.isArray(row.message?.content) ? row.message.content : []) {
        if (block.type === 'tool_use' && ['Agent', 'Task'].includes(block.name) && typeof block.id === 'string') tools.add(block.id)
      }
    }
  }
  let parent
  try { parent = readRows(path.join(project, sessionId + '.jsonl')); collectTools(parent.filter(r => !r.isSidechain)) }
  catch { return { ...result, complete: false } }
  const candidates = []
  for (const dir of [project, path.join(project, sessionId, 'subagents')]) {
    try {
      for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
        const match = /^agent-([a-z0-9-]+)\.meta\.json$/i.exec(entry.name)
        if (!entry.isFile() || !match) continue
        const meta = JSON.parse(fs.readFileSync(safeFile(path.join(dir, entry.name)), 'utf8'))
        candidates.push({ id: match[1], tool: meta.toolUseId, file: path.join(dir, `agent-${match[1]}.jsonl`) })
      }
    } catch (error) { if (error.code !== 'ENOENT') result.complete = false }
  }
  const seen = new Set(), foundTools = new Set()
  let progress = true
  while (progress) {
    progress = false
    for (const candidate of candidates) {
      if (!tools.has(candidate.tool) || seen.has(candidate.id)) continue
      seen.add(candidate.id); progress = true
      if (seen.size > 256) { result.complete = false; continue }
      try {
        const rows = readRows(candidate.file)
        // A sibling file from another parent or agent must never be borrowed.
        if (!rows.length || rows.some(r => r.sessionId && r.sessionId !== sessionId || r.agentId && r.agentId !== candidate.id)) {
          result.complete = false; continue
        }
        collectTools(rows)
        const accounting = rows.filter(r => r.type === 'assistant' && r.message?.usage).map(r => ({
          type: 'assistant', sessionId: `${sessionId}:${candidate.id}`, timestamp: r.timestamp,
          uuid: r.uuid, requestId: r.requestId,
          message: { id: r.message.id, model: r.message.model,
            usage: Object.fromEntries(USAGE_KEYS.filter(k => Object.hasOwn(r.message.usage, k)).map(k => [k, r.message.usage[k]])) }
        }))
        result.agents.push({ id: candidate.id, rows: accounting })
        foundTools.add(candidate.tool)
      } catch { result.complete = false }
    }
  }
  result.missing = [...tools].filter(id => !foundTools.has(id)).length
  if (result.missing) result.complete = false
  return result
}
module.exports = { readSubagentUsage }
