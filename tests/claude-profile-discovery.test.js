const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const vm = require('node:vm')
const { test } = require('node:test')

test('profile migration prefers Claude-Data and keeps legacy and regular installs working', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'uv-profiles-'))
  try {
    const appData = path.join(root, 'roaming')
    const localData = path.join(root, 'local')
    const regular = path.join(appData, 'Claude', 'plan-usage-history.json')
    const legacy = path.join(localData, 'Packages', 'Claude_test', 'LocalCache', 'Roaming', 'Claude', 'plan-usage-history.json')
    const migrated = path.join(localData, 'Claude-Data', 'claude_test', 'plan-usage-history.json')
    for (const file of [regular, legacy, migrated]) {
      fs.mkdirSync(path.dirname(file), { recursive: true })
      fs.writeFileSync(file, '{"samples":[]}')
    }
    const source = fs.readFileSync(path.join(__dirname, '../src/readers/claude-desktop-usage-read.js'), 'utf8')
    const discovery = source.slice(source.indexOf('function findPlanUsageHistoryFiles()'), source.indexOf('function readProfileMappings()'))
    const context = vm.createContext({ fs, os, path, CLAUDE_DESKTOP_DATA_DIRECTORY: null,
      process: { env: { APPDATA: appData, LOCALAPPDATA: localData } }, readProfileMappings: () => [] })
    vm.runInContext(discovery, context)
    const find = () => Array.from(context.findPlanUsageHistoryFiles())
    assert.deepEqual(find(), [regular, migrated])
    fs.unlinkSync(migrated)
    assert.deepEqual(find(), [regular, legacy])
    fs.unlinkSync(legacy)
    assert.deepEqual(find(), [regular])
  } finally {
    fs.rmSync(root, { recursive: true, force: true })
  }
})
