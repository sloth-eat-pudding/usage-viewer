# Codex Desktop account quota

Usage Viewer polls the existing Codex Desktop bridge every 30 seconds. It reads
`account/read` (without token refresh) before and after `account/rateLimits/read`
to reject account changes during a query. It does not start an App Server, read
credential files, or make model requests.

The reader accepts only the official Store executable owning an exclusive IPv4
loopback debugger listener, an exact registered desktop profile path, the browser
identity discovered for that process, and one unambiguous main renderer. New
accounts must be registered and opened through Usage Viewer's account selector.
The original account launcher is also supported. Other test instances are excluded.

Each profile gets its own quota snapshot and overlay group. Its native meter uses
the same profile's quota even before any chat usage events exist. Token, cache,
and cost metrics continue to require the current chat's local accounting events.
Account identifiers are hashed; email and raw bridge responses are not saved.

Disconnected queries retry up to three times. Each poll rediscovers the process
and browser, so app restarts, reloads, and port changes can recover without pinning
an old browser ID. Cache freshness expires after 90 seconds. Failed queries mark
their profile unavailable; the existing session reader remains a fallback with
its original event timestamp. Other accounts continue polling independently.

Both the modern `rateLimitsByLimitId.codex` response and the legacy `rateLimits`
response are supported. Unknown buckets, window shapes, invalid percentages, or
missing reset times are rejected. An incompatible future Desktop version cannot
silently replace a valid quota with a different product's limit.

Run `scripts/watch-codex-desktop-usage.ps1 -Once` for a read-only check. Output
contains only profile IDs, status, and percentages. `scripts/restart-usage-viewer.cmd`
starts the background poller; the WPF application also starts it with a shared
mutex to prevent concurrent pollers.
