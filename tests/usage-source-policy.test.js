'use strict'
const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { enabled, organizationEnabled } = require('../src/readers/usage-source-policy')

test('visibility is reloaded per poll and each profile overrides the shared group', () => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'usage-policy-'))
  try {
    const hidden = path.join(home, 'hidden.json')
    const shown = path.join(home, 'shown.json')
    fs.writeFileSync(hidden, JSON.stringify({ samples: [{ t: 1, org: 'old' }, { t: 2, org: 'hidden-org' }] }))
    fs.writeFileSync(shown, JSON.stringify({ samples: [{ t: 3, org: 'shown-org' }] }))
    const save = config => fs.writeFileSync(path.join(home, 'display-settings.json'), '\uFEFF' + JSON.stringify(config))
    assert.equal(enabled(home, 'codex_cli_group'), true)
    save({ codex_cli_group: 'Hidden', claude_desktop_group: 'Hidden', claude_desktop_sources: [
      { path: hidden, group: 'hidden' }, { path: shown, group: '2' }
    ] })
    assert.equal(enabled(home, 'codex_cli_group'), false)
    assert.equal(enabled(home, 'claude_desktop_group', shown.toUpperCase()), true)
    assert.equal(enabled(home, 'claude_desktop_group', hidden), false)
    assert.equal(organizationEnabled(home, 'hidden-org'), false)
    assert.equal(organizationEnabled(home, 'shown-org'), true)
    save({ codex_cli_group: '1', claude_desktop_sources: [{ path: hidden, group: '2' }] })
    assert.equal(enabled(home, 'codex_cli_group'), true)
    assert.equal(organizationEnabled(home, 'hidden-org'), true)
  } finally { fs.rmSync(home, { recursive: true, force: true }) }
})
