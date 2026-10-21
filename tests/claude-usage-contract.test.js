'use strict'

const assert = require('node:assert/strict')
const test = require('node:test')
const fixtures = require('./fixtures/claude-usage.json')
const { normalizeUsage } = require('../src/readers/claude-usage-contract')
const organization = '11111111-1111-1111-1111-111111111111'

for (const fixture of fixtures) {
  test(fixture.name, () => {
    if (fixture.invalid) {
      assert.throws(() => normalizeUsage(fixture.input, organization), /Expected a Claude Desktop usage response/)
      return
    }
    const snapshot = normalizeUsage(fixture.input, organization)
    assert.deepEqual({ ...snapshot.percentages, ...snapshot.resets_at }, fixture.expected)
    assert.equal(snapshot.organization_id, organization)
    assert.equal(snapshot.source, 'claude-desktop-api-bridge')
    assert.equal(snapshot.source_mode, 'desktop')
    assert.equal(snapshot.generated_at, snapshot.observed_at)
  })
}
