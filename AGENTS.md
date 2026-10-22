# Project instructions

## Usage Viewer restart rule

- After every code or configuration change, restart the Usage Viewer before reporting completion.
- Use `scripts\restart-usage-viewer.cmd` for the restart.
- Verify the relevant script syntax or build check before restarting when practical.
- Do not claim the change is complete until the restart has been triggered.

## Commit and push rule

- After completing each change, run the relevant checks, restart Usage Viewer when required above, then commit and push the intended changes to the current branch's configured remote before reporting completion.
- Do not wait for a separate request to commit or push.
- Keep local debug logs and generated runtime files out of commits.
