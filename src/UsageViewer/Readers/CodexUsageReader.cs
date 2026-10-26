using System.IO;
using System.Text.Json;
using static UsageViewer.JsonValues;

namespace UsageViewer;

internal sealed class CodexUsageReader : IDisposable
{
    private readonly SnapshotStore _store;
    private readonly string _home;
    private readonly string _sessionsRoot;
    private readonly FileSystemWatcher? _codexWatcher;
    private int _codexDirty = 1;
    private DateTimeOffset _nextCodexPollUtc = DateTimeOffset.MinValue;
    private static readonly TimeSpan CodexPollInterval = TimeSpan.FromSeconds(10);

    internal CodexUsageReader(SnapshotStore store, string? sessionsRoot = null)
    {
        _store = store;
        _home = store.Home;
        _sessionsRoot = sessionsRoot ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".codex", "sessions");
        var codexRoot = _sessionsRoot;
        if (Directory.Exists(codexRoot))
        {
            try
            {
                _codexWatcher = new FileSystemWatcher(codexRoot, "*.jsonl")
                {
                    IncludeSubdirectories = true,
                    NotifyFilter = NotifyFilters.FileName | NotifyFilters.LastWrite | NotifyFilters.Size,
                    EnableRaisingEvents = true
                };
                _codexWatcher.Created += MarkCodexDirty;
                _codexWatcher.Changed += MarkCodexDirty;
                _codexWatcher.Renamed += MarkCodexDirty;
                _codexWatcher.Error += MarkCodexDirty;
            }
            catch { _codexWatcher = null; }
        }
    }

    private void MarkCodexDirty(object? sender, FileSystemEventArgs e) => Volatile.Write(ref _codexDirty, 1);
    private void MarkCodexDirty(object? sender, ErrorEventArgs e) => Volatile.Write(ref _codexDirty, 1);

    internal void Refresh()
    {
        // The watcher makes normal updates cheap, but it can lose events when its
        // internal buffer overflows or a file is replaced while being written.
        // Keep a periodic full scan so one missed event cannot permanently freeze
        // the displayed usage.
        var now = DateTimeOffset.UtcNow;
        var dirty = Interlocked.Exchange(ref _codexDirty, 0) != 0;
        if (_codexWatcher is not null && !dirty && now < _nextCodexPollUtc) return;
        _nextCodexPollUtc = now + CodexPollInterval;
        var root = _sessionsRoot;
        var bridge = CodexDesktopProfiles.ReadFresh(Path.Combine(_home, "codex-desktop-bridge-latest.json"), "default");
        if (bridge is not null)
        {
            _store.Write("codex-desktop-latest.json", bridge.Value);
            _store.Write("codex-app-latest.json", bridge.Value);
        }
        var localCandidates = new List<CodexCandidate>();
        foreach (var mode in new[] { "desktop", "cli" })
        {
            var local = FindLatestCodexUsage(root, mode);
            if (local is not null)
            {
                localCandidates.Add(local.Value);
                if (mode != "desktop" || bridge is null) WriteCodexSnapshot($"codex-{mode}-latest.json", local.Value);
            }
        }
        var selectedLocal = localCandidates.OrderByDescending(candidate => candidate.Time).FirstOrDefault();
        if (selectedLocal.File is not null && bridge is null) WriteCodexSnapshot("codex-app-latest.json", selectedLocal);
        var remoteRoot = Path.Combine(_home, "remote-codex");
        var remoteSources = _store.ReadConfiguredSources("remote-sources.json");
        for (var index = 0; index < remoteSources.Count; index++)
        {
            var remoteLatest = FindLatestCodexUsage(Path.Combine(remoteRoot, index.ToString(), "sessions"));
            if (remoteLatest is not null && _store.IsNotOlder($"codex-remote-{index}-latest.json", remoteLatest.Value.Time))
                WriteCodexSnapshot($"codex-remote-{index}-latest.json", remoteLatest.Value);
        }
        if (remoteSources.Count == 0)
        {
            // Without remote-sources.json the synchronizer still copies the
            // config\remote.env host into slot 0; older versions used the root.
            var remoteLatest = new[] { Path.Combine(remoteRoot, "0", "sessions"), Path.Combine(remoteRoot, "sessions") }
                .Select(directory => FindLatestCodexUsage(directory))
                .Where(candidate => candidate is not null)
                .OrderByDescending(candidate => candidate!.Value.Time)
                .FirstOrDefault();
            if (remoteLatest is not null && _store.IsNotOlder("codex-remote-0-latest.json", remoteLatest.Value.Time))
                WriteCodexSnapshot("codex-remote-0-latest.json", remoteLatest.Value);
        }
    }

    private void WriteCodexSnapshot(string fileName, CodexCandidate latest)
    {
        var payload = latest.Json.GetProperty("payload");
        var info = payload.TryGetProperty("info", out var i) ? i : default;
        var last = info.ValueKind != JsonValueKind.Undefined && info.TryGetProperty("last_token_usage", out var l) ? l : default;
        var total = info.ValueKind != JsonValueKind.Undefined && info.TryGetProperty("total_token_usage", out var t) ? t : default;
        var input = Number(last, "input_tokens");
        var cached = Number(last, "cached_input_tokens");
        var output = Number(last, "output_tokens");
        var totalTokens = Number(last, "total_tokens");
        // Codex Desktop stores rate_limits beside payload, not inside payload.
        var rateLimits = latest.Json.TryGetProperty("rate_limits", out var rl) && rl.ValueKind == JsonValueKind.Object
            ? rl
            : latest.Json.TryGetProperty("payload", out var nestedPayload) && nestedPayload.TryGetProperty("rate_limits", out var nestedRl) && nestedRl.ValueKind == JsonValueKind.Object
                ? nestedRl
                : default;
        var fiveHour = FindRateLimitWindow(rateLimits, 300);
        var sevenDay = FindRateLimitWindow(rateLimits, 10080);

        _store.Write(fileName, new {
            generated_at = DateTimeOffset.UtcNow.ToString("O"), observed_at = latest.Time.ToString("O"),
            source = "codex-session-rate-limits", source_mode = latest.Mode, source_file = latest.File,
            tokens = new { total_input = input, cache_read_input = cached, output, total = totalTokens, session_total = Number(total, "total_tokens") },
            percentages = new {
                context_used = (double?)null,
                cached_input = input > 0 ? cached * 100 / input : 0,
                five_hour_used = NumberOrNull(fiveHour, "used_percent"),
                seven_day_used = NumberOrNull(sevenDay, "used_percent"),
                primary_limit_used = NumberOrNull(sevenDay, "used_percent")
            },
            resets_at = new {
                five_hour_epoch_seconds = NumberOrNull(fiveHour, "resets_at"),
                seven_day_epoch_seconds = NumberOrNull(sevenDay, "resets_at")
            },
            rate_limits = new {
                primary_window_minutes = NumberOrNull(sevenDay, "window_minutes"),
                plan_type = StringOrNull(rateLimits, "plan_type")
            }
        });
    }

    private static CodexCandidate? FindLatestCodexUsage(string root, string? requiredMode = null)
    {
        if (!Directory.Exists(root)) return null;

        IEnumerable<(string File, DateTimeOffset Mtime)> files;
        try
        {
            files = Directory.EnumerateFiles(root, "*.jsonl", SearchOption.AllDirectories)
                .Select(file => (File: file, Mtime: new DateTimeOffset(File.GetLastWriteTimeUtc(file))))
                .OrderByDescending(item => item.Mtime)
                .ToArray();
        }
        catch { return null; }

        // Scan every date directory and choose by the event timestamp, rather
        // than by the containing file's mtime. This remains correct when Codex
        // creates a new YYYY\\MM\\DD directory or appends to an older file.
        return files
            .Select(item => ReadCodexUsageFile(item.File, item.Mtime))
            .Where(candidate => candidate is not null &&
                (requiredMode is null || candidate.Value.Mode.Equals(requiredMode, StringComparison.OrdinalIgnoreCase)))
            .OrderByDescending(candidate => candidate!.Value.Time)
            .FirstOrDefault();
    }

    private static CodexCandidate? ReadCodexUsageFile(string file, DateTimeOffset fallbackTime)
    {
        try
        {
            using var stream = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            using var reader = new StreamReader(stream);
            JsonElement? sessionMeta = null;
            JsonElement? latestUsage = null;
            var latestUsageTime = DateTimeOffset.MinValue;

            while (reader.ReadLine() is { } line)
            {
                if (string.IsNullOrWhiteSpace(line)) continue;
                try
                {
                    using var document = JsonDocument.Parse(line);
                    var root = document.RootElement;
                    if (root.TryGetProperty("type", out var type) && type.GetString() == "session_meta" &&
                        root.TryGetProperty("payload", out var metaPayload))
                    {
                        sessionMeta = metaPayload.Clone();
                        continue;
                    }

                    if (!IsCodexTokenCount(root) || !HasDirectRateLimitUsage(root)) continue;
                    var eventTime = ParseEventTime(root) ?? fallbackTime;
                    if (eventTime < latestUsageTime) continue;
                    latestUsage = root.Clone();
                    latestUsageTime = eventTime;
                }
                catch { }
            }

            if (sessionMeta is null || latestUsage is null) return null;
            var mode = ClassifyCodexMode(sessionMeta.Value);
            return mode is null ? null : new CodexCandidate(file, latestUsageTime, latestUsage.Value, mode);
        }
        catch { return null; }
    }

    private static bool HasDirectRateLimitUsage(JsonElement root)
    {
        var rateLimits = root.TryGetProperty("rate_limits", out var direct) && direct.ValueKind == JsonValueKind.Object
            ? direct
            : root.TryGetProperty("payload", out var payload) && payload.TryGetProperty("rate_limits", out var nested)
                ? nested
                : default;
        if (rateLimits.ValueKind != JsonValueKind.Object) return false;

        foreach (var name in new[] { "primary", "secondary" })
        {
            if (rateLimits.TryGetProperty(name, out var limit) && NumberOrNull(limit, "used_percent") is not null)
                return true;
        }
        return false;
    }

    private static string? ClassifyCodexMode(JsonElement sessionMeta)
    {
        var source = StringOrNull(sessionMeta, "source")?.ToLowerInvariant();
        var originator = StringOrNull(sessionMeta, "originator")?.ToLowerInvariant();
        if ((originator?.Contains("desktop") ?? false) || (originator?.Contains("codex_vscode") ?? false) || source is "vscode" or "codex_vscode")
            return "desktop";
        if (source == "cli" || (originator?.Contains("codex-tui") ?? false))
            return "cli";
        return null;
    }

    private static DateTimeOffset? ParseEventTime(JsonElement root)
    {
        if (root.TryGetProperty("timestamp", out var timestamp) && timestamp.ValueKind == JsonValueKind.String &&
            DateTimeOffset.TryParse(timestamp.GetString(), out var time)) return time;
        return null;
    }

    private static JsonElement FindRateLimitWindow(JsonElement rateLimits, double windowMinutes)
    {
        if (rateLimits.ValueKind != JsonValueKind.Object) return default;
        foreach (var name in new[] { "primary", "secondary" })
        {
            if (rateLimits.TryGetProperty(name, out var limit) &&
                limit.ValueKind == JsonValueKind.Object &&
                NumberOrNull(limit, "window_minutes") == windowMinutes) return limit;
        }
        return default;
    }

    private static bool IsCodexTokenCount(JsonElement j) => j.TryGetProperty("type", out var t) && t.GetString() == "event_msg" && j.TryGetProperty("payload", out var p) && p.TryGetProperty("type", out var pt) && pt.GetString() == "token_count";
    private readonly record struct CodexCandidate(string File, DateTimeOffset Time, JsonElement Json, string Mode);

    public void Dispose()
    {
        if (_codexWatcher is not null)
        {
            _codexWatcher.EnableRaisingEvents = false;
            _codexWatcher.Dispose();
        }
    }
}
