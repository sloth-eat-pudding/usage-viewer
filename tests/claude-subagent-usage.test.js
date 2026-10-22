const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { test } = require('node:test')
const { readSubagentUsage } = require('../src/readers/claude-subagent-usage')
const id = '11111111-1111-1111-1111-111111111111'
const other = '22222222-2222-2222-2222-222222222222'
function fixture(run) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'uv-subagent-test-'))
  const project = path.join(root, 'project')
  fs.mkdirSync(project)
  const write = (file, value) => fs.writeFileSync(path.join(project, file),
    Array.isArray(value) ? value.map(row => JSON.stringify(row)).join('\n') : JSON.stringify(value))
  const tool = (toolId, name = 'Agent') => ({ sessionId: id, type: 'assistant', message: { content: [{ type: 'tool_use', name, id: toolId }] } })
  const assistant = (agentId, overrides = {}) => ({ sessionId: id, agentId, type: 'assistant', isSidechain: true,
    uuid: agentId + '-uuid', timestamp: '2026-10-22T00:00:00Z', message: { id: 'msg-' + agentId, model: 'claude-opus-5-5',
      content: [{ type: 'text', text: 'PRIVATE CONTENT' }], usage: { input_tokens: 10, output_tokens: 20 } }, ...overrides })
  try { run({ root, project, write, tool, assistant }) }
  finally { fs.rmSync(root, { recursive: true, force: true }) }
}
test('reads linked children and grandchildren, excluding other accounts and conversation text', () => fixture(({root, write, tool, assistant}) => {
  write(id + '.jsonl', [tool('t1')])
  write('agent-a1.meta.json', { toolUseId: 't1' })
  write('agent-a1.jsonl', [assistant('a1'), tool('t2', 'Task')])
  write('agent-a2.meta.json', { toolUseId: 't2' })
  write('agent-a2.jsonl', [assistant('a2')])
  write('agent-other.meta.json', { toolUseId: 'unrelated' })
  write('agent-other.jsonl', [assistant('other', { sessionId: other })])
  const result = readSubagentUsage(id, root)
  assert.equal(result.complete, true)
  assert.deepEqual(result.agents.map(a => a.id), ['a1', 'a2'])
  assert.equal(result.agents[0].rows[0].sessionId, id + ':a1')
  assert.equal(JSON.stringify(result).includes('PRIVATE CONTENT'), false)
  assert.equal(JSON.stringify(result).includes('toolUseId'), false)
}))
test('missing, mismatched and malformed transcripts are incomplete, never zero complete usage', () => fixture(({root, write, tool, assistant}) => {
  assert.equal(readSubagentUsage(id, root).complete, false)
  write(id + '.jsonl', [tool('t1')])
  assert.equal(readSubagentUsage(id, root).missing, 1)
  write('agent-a1.meta.json', { toolUseId: 't1' })
  write('agent-a1.jsonl', [assistant('a1', { sessionId: other })])
  assert.equal(readSubagentUsage(id, root).agents.length, 0)
  write('agent-a1.jsonl', [assistant('a1', { agentId: 'a2' })])
  assert.equal(readSubagentUsage(id, root).complete, false)
  write('agent-a1.jsonl', [assistant('a1')])
  assert.equal(readSubagentUsage(id, root).complete, true)
  assert.throws(() => readSubagentUsage('../' + id, root))
}))
test('supports the nested subagents directory without duplicating an agent', () => fixture(({root, project, write, tool, assistant}) => {
  write(id + '.jsonl', [tool('t1')])
  const subdir = path.join(project, id, 'subagents')
  fs.mkdirSync(subdir, { recursive: true })
  for (const dir of [project, subdir]) {
    fs.writeFileSync(path.join(dir, 'agent-a1.meta.json'), JSON.stringify({ toolUseId: 't1' }))
    fs.writeFileSync(path.join(dir, 'agent-a1.jsonl'), JSON.stringify(assistant('a1')))
  }
  assert.equal(readSubagentUsage(id, root).agents.length, 1)
  assert.equal(readSubagentUsage(id, root).complete, true)
}))
