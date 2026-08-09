using System.IO;
using System.Text.Json;

namespace UsageViewer;

public sealed class UsageReaderService : IDisposable
{
    private readonly string _home = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".usage-viewer");
    private readonly string? _claudePlanUsageHistory = FindClaudePlanUsageHistory();
    private readonly Timer _timer;

    public UsageReaderService()
    {
        _timer = new Timer(_ => Refresh(), null, TimeSpan.Zero, TimeSpan.FromSeconds(2));
    }

    private void Refresh()
    {
        try { WriteCodex(); } catch { }
        try { WriteClaude(); } catch { }
    }

    private void WriteCodex()
    {
        var root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".codex", "sessions");
        var latestByMode = FindLatestCodexUsageByMode(root);
        if (latestByMode.Count == 0) return;

        if (latestByMode.TryGetValue("desktop", out var desktop))
            WriteCodexSnapshot("codex-desktop-latest.json", desktop);
        if (latestByMode.TryGetValue("cli", out var cli))
            WriteCodexSnapshot("codex-cli-latest.json", cli);

        var latest = latestByMode.Values.OrderByDescending(candidate => candidate.Time).First();
        WriteCodexSnapshot("codex-app-latest.json", latest);
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
        var rateLimits = payload.TryGetProperty("rate_limits", out var rl) && rl.ValueKind == JsonValueKind.Object ? rl : default;
        var primary = rateLimits.ValueKind != JsonValueKind.Undefined && rateLimits.TryGetProperty("primary", out var p) ? p : default;
        var fiveHour = FindRateLimitWindow(rateLimits, 300);
        var sevenDay = FindRateLimitWindow(rateLimits, 10080);

        WriteJson(fileName, new {
            generated_at = DateTimeOffset.UtcNow.ToString("O"), observed_at = latest.Time.ToString("O"),
            source = "codex-session-rate-limits", source_mode = latest.Mode, source_file = latest.File,
            tokens = new { total_input = input, cache_read_input = cached, output, total = totalTokens, session_total = Number(total, "total_tokens") },
            percentages = new {
                context_used = (double?)null,
                cached_input = input > 0 ? cached * 100 / input : 0,
                five_hour_used = NumberOrNull(fiveHour, "used_percent"),
                seven_day_used = NumberOrNull(sevenDay, "used_percent"),
                primary_limit_used = NumberOrNull(primary, "used_percent")
            },
            resets_at = new {
                five_hour_epoch_seconds = NumberOrNull(fiveHour, "resets_at"),
                seven_day_epoch_seconds = NumberOrNull(sevenDay, "resets_at")
            },
            rate_limits = new {
                primary_window_minutes = NumberOrNull(primary, "window_minutes"),
                plan_type = StringOrNull(rateLimits, "plan_type")
            }
        });
    }

    private static Dictionary<string, CodexCandidate> FindLatestCodexUsageByMode(string root)
    {
        var latestByMode = new Dictionary<string, CodexCandidate>(StringComparer.OrdinalIgnoreCase);
        if (!Directory.Exists(root)) return latestByMode;

        IEnumerable<(string File, DateTimeOffset Mtime)> files;
        try
        {
            files = Directory.EnumerateFiles(root, "*.jsonl", SearchOption.AllDirectories)
                .Select(file => (File: file, Mtime: new DateTimeOffset(File.GetLastWriteTimeUtc(file))))
                .OrderByDescending(item => item.Mtime)
                .Take(120)
                .ToArray();
        }
        catch { return latestByMode; }

        foreach (var item in files)
        {
            var candidate = ReadCodexUsageFile(item.File, item.Mtime);
            if (candidate is null) continue;
            if (!latestByMode.TryGetValue(candidate.Value.Mode, out var current) || candidate.Value.Time > current.Time)
                latestByMode[candidate.Value.Mode] = candidate.Value;
            if (latestByMode.ContainsKey("desktop") && latestByMode.ContainsKey("cli")) break;
        }

        return latestByMode;
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
        if (!root.TryGetProperty("payload", out var payload) ||
            !payload.TryGetProperty("rate_limits", out var rateLimits) ||
            rateLimits.ValueKind != JsonValueKind.Object) return false;

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

    private void WriteClaude()
    {
        var root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".claude", "projects");
        var latest = FindLatest(root, IsClaudeUsage);
        var plan = ReadClaudePlanUsage();
        if (latest is null && plan is null) return;

        var message = latest is not null && latest.Value.Json.TryGetProperty("message", out var m) ? m : default;
        var usage = message.ValueKind == JsonValueKind.Object && message.TryGetProperty("usage", out var u) ? u : default;
        var input = Number(usage, "input_tokens");
        var cached = Number(usage, "cache_read_input_tokens");
        var output = Number(usage, "output_tokens");
        var statusLine = ReadClaudeStatuslineUsage();
        var useStatusLine = statusLine is not null && (plan is null || statusLine.ObservedAt > plan.ObservedAt);
        var fiveHourUsed = useStatusLine ? statusLine?.FiveHourUsed ?? plan?.FiveHourUsed : plan?.FiveHourUsed;
        var sevenDayUsed = useStatusLine ? statusLine?.SevenDayUsed ?? plan?.SevenDayUsed : plan?.SevenDayUsed;
        var fiveHourReset = FirstFuture(statusLine?.FiveHourReset, plan?.EstimatedFiveHourReset);
        var sevenDayReset = FirstFuture(statusLine?.SevenDayReset, plan?.EstimatedSevenDayReset);
        var observedAt = useStatusLine
            ? statusLine!.ObservedAt
            : plan?.ObservedAt ?? latest?.Time ?? DateTimeOffset.UtcNow;

        WriteJson("claude-app-latest.json", new {
            generated_at = DateTimeOffset.UtcNow.ToString("O"), observed_at = observedAt.ToString("O"),
            source = useStatusLine ? "claude-code-statusline" : plan is null ? "claude-jsonl" : "claude-desktop-plan-usage-history",
            source_file = useStatusLine ? Path.Combine(_home, "claude-statusline-latest.json") : plan is null ? latest?.File : _claudePlanUsageHistory,
            tokens = new { total_input = input + cached, fresh_input = input, cache_read_input = cached, output },
            percentages = new {
                context_used = (double?)null,
                cached_input = input + cached > 0 ? cached * 100 / (input + cached) : 0,
                five_hour_used = fiveHourUsed,
                seven_day_used = sevenDayUsed
            },
            resets_at = new {
                five_hour_epoch_seconds = ToEpochSeconds(fiveHourReset),
                seven_day_epoch_seconds = ToEpochSeconds(sevenDayReset)
            },
            reset_is_estimated = new {
                five_hour = fiveHourReset is not null && statusLine?.FiveHourReset is null,
                seven_day = sevenDayReset is not null && statusLine?.SevenDayReset is null
            },
            plan_usage = new {
                source_file = _claudePlanUsageHistory,
                observed_at = plan?.ObservedAt.ToString("O"),
                org = plan?.Organization
            }
        });
    }

    private ClaudePlanUsage? ReadClaudePlanUsage()
    {
        if (_claudePlanUsageHistory is null || !File.Exists(_claudePlanUsageHistory)) return null;

        try
        {
            using var document = JsonDocument.Parse(File.ReadAllText(_claudePlanUsageHistory));
            if (!document.RootElement.TryGetProperty("samples", out var samples) || samples.ValueKind != JsonValueKind.Array) return null;

            var parsed = new List<ClaudePlanSample>();
            foreach (var sample in samples.EnumerateArray())
            {
                var timestamp = NumberOrNull(sample, "t");
                if (timestamp is null || !sample.TryGetProperty("u", out var values) || values.ValueKind != JsonValueKind.Object) continue;
                parsed.Add(new ClaudePlanSample(
                    DateTimeOffset.FromUnixTimeMilliseconds((long)timestamp.Value),
                    NumberOrNull(values, "fh"),
                    NumberOrNull(values, "sd"),
                    StringOrNull(sample, "org")));
            }

            if (parsed.Count == 0) return null;
            parsed.Sort((left, right) => left.Time.CompareTo(right.Time));
            var current = parsed[^1];
            return new ClaudePlanUsage(
                current.Time,
                current.FiveHour,
                current.SevenDay,
                current.Organization,
                EstimateFiveHourReset(parsed),
                EstimateSevenDayReset(parsed));
        }
        catch { return null; }
    }

    private static DateTimeOffset? EstimateFiveHourReset(IReadOnlyList<ClaudePlanSample> samples)
    {
        var latest = samples[^1];
        if (latest.FiveHour is null || latest.FiveHour <= 0) return null;

        var start = samples.Count - 1;
        for (var index = samples.Count - 2; index >= 0; index--)
        {
            var current = samples[index];
            var next = samples[index + 1];
            if (current.FiveHour is null || current.FiveHour <= 0) break;
            if (next.Time - current.Time > TimeSpan.FromMinutes(30)) break;
            if (next.FiveHour < current.FiveHour) break;
            start = index;
        }

        return FutureOnly(samples[start].Time.AddHours(5));
    }

    private static DateTimeOffset? EstimateSevenDayReset(IReadOnlyList<ClaudePlanSample> samples)
    {
        DateTimeOffset? periodStart = null;
        for (var index = 1; index < samples.Count; index++)
        {
            var previous = samples[index - 1];
            var current = samples[index];
            if (previous.SevenDay is not null && current.SevenDay is not null && current.SevenDay < previous.SevenDay)
                periodStart = current.Time;
        }
        return periodStart is null ? null : FutureOnly(periodStart.Value.AddDays(7));
    }

    private ClaudeStatuslineUsage? ReadClaudeStatuslineUsage()
    {
        try
        {
            var path = Path.Combine(_home, "claude-statusline-latest.json");
            if (!File.Exists(path)) return null;
            using var document = JsonDocument.Parse(File.ReadAllText(path));
            var root = document.RootElement;
            if (StringOrNull(root, "source") != "claude-code-statusline") return null;
            var timestamp = StringOrNull(root, "generated_at") ?? StringOrNull(root, "observed_at");
            if (!DateTimeOffset.TryParse(timestamp, out var observedAt)) return null;
            var percentages = root.TryGetProperty("percentages", out var p) ? p : default;
            var resets = root.TryGetProperty("resets_at", out var r) ? r : default;
            return new ClaudeStatuslineUsage(
                observedAt,
                NumberOrNull(percentages, "five_hour_used"),
                NumberOrNull(percentages, "seven_day_used"),
                FutureEpoch(NumberOrNull(resets, "five_hour_epoch_seconds")),
                FutureEpoch(NumberOrNull(resets, "seven_day_epoch_seconds")));
        }
        catch { return null; }
    }

    private static DateTimeOffset? FutureEpoch(double? epochSeconds)
    {
        if (epochSeconds is null) return null;
        var time = DateTimeOffset.FromUnixTimeSeconds((long)epochSeconds.Value);
        return time > DateTimeOffset.UtcNow ? time : null;
    }

    private static DateTimeOffset? FirstFuture(params object?[] values)
    {
        foreach (var value in values)
        {
            DateTimeOffset? time = value switch
            {
                double seconds => DateTimeOffset.FromUnixTimeSeconds((long)seconds),
                DateTimeOffset date => date,
                _ => null
            };
            if (time > DateTimeOffset.UtcNow) return time;
        }
        return null;
    }

    private static DateTimeOffset? FutureOnly(DateTimeOffset value) => value > DateTimeOffset.UtcNow ? value : null;
    private static long? ToEpochSeconds(DateTimeOffset? value) => value?.ToUnixTimeSeconds();

    private static string? FindClaudePlanUsageHistory()
    {
        var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        var roamingAppData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        var candidates = new List<string>
        {
            Path.Combine(localAppData, "Packages", "Claude_pzs8sxrjxfjjc", "LocalCache", "Roaming", "Claude", "plan-usage-history.json"),
            Path.Combine(roamingAppData, "Claude", "plan-usage-history.json")
        };

        try
        {
            var packages = Path.Combine(localAppData, "Packages");
            if (Directory.Exists(packages))
            {
                candidates.AddRange(Directory.EnumerateDirectories(packages, "Claude_*")
                    .Select(directory => Path.Combine(directory, "LocalCache", "Roaming", "Claude", "plan-usage-history.json")));
            }
        }
        catch { }

        return candidates.Where(File.Exists)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .OrderByDescending(File.GetLastWriteTimeUtc)
            .FirstOrDefault();
    }

    private void WriteJson(string name, object value)
    {
        Directory.CreateDirectory(_home);
        var path = Path.Combine(_home, name);
        var temp = path + ".tmp-" + Environment.ProcessId;
        File.WriteAllText(temp, JsonSerializer.Serialize(value, new JsonSerializerOptions { WriteIndented = true }));
        File.Move(temp, path, true);
    }

    private static Candidate? FindLatest(string root, Func<JsonElement, bool> predicate)
    {
        if (!Directory.Exists(root)) return null;
        Candidate? latest = null;
        var files = Directory.EnumerateFiles(root, "*.jsonl", SearchOption.AllDirectories)
            .Select(file => new { File = file, Mtime = File.GetLastWriteTimeUtc(file) })
            .OrderByDescending(item => item.Mtime)
            .Take(100);
        foreach (var item in files)
        {
            var file = item.File;
            try
            {
                foreach (var line in File.ReadLines(file))
                {
                    if (string.IsNullOrWhiteSpace(line)) continue;
                    using var doc = JsonDocument.Parse(line);
                    if (!predicate(doc.RootElement)) continue;
                    var timestamp = doc.RootElement.TryGetProperty("timestamp", out var t) && t.ValueKind == JsonValueKind.String ? t.GetString() : null;
                    // Use the source file mtime for source selection and display.
                    // The JSON event timestamp can describe an older event even
                    // while the session file is still being updated.
                    var parsed = File.GetLastWriteTimeUtc(file);
                    if (latest is null || parsed > latest.Value.Time) latest = new Candidate(file, parsed, doc.RootElement.Clone());
                }
            }
            catch { }
        }
        return latest;
    }

    private static bool IsCodexTokenCount(JsonElement j) => j.TryGetProperty("type", out var t) && t.GetString() == "event_msg" && j.TryGetProperty("payload", out var p) && p.TryGetProperty("type", out var pt) && pt.GetString() == "token_count";
    private static bool IsClaudeUsage(JsonElement j) => j.TryGetProperty("entrypoint", out var e) && e.GetString() == "claude-desktop" && j.TryGetProperty("message", out var m) && m.TryGetProperty("usage", out _);
    private static double Number(JsonElement j, string name) => NumberOrNull(j, name) ?? 0;
    private static double? NumberOrNull(JsonElement j, string name) => j.ValueKind == JsonValueKind.Object && j.TryGetProperty(name, out var p) && p.ValueKind == JsonValueKind.Number && p.TryGetDouble(out var n) ? n : null;
    private static string? StringOrNull(JsonElement j, string name) => j.ValueKind == JsonValueKind.Object && j.TryGetProperty(name, out var p) && p.ValueKind == JsonValueKind.String ? p.GetString() : null;
    private readonly record struct Candidate(string File, DateTimeOffset Time, JsonElement Json) { public string Timestamp => Time.ToString("O"); }
    private readonly record struct CodexCandidate(string File, DateTimeOffset Time, JsonElement Json, string Mode);
    private readonly record struct ClaudePlanSample(DateTimeOffset Time, double? FiveHour, double? SevenDay, string? Organization);
    private sealed record ClaudePlanUsage(DateTimeOffset ObservedAt, double? FiveHourUsed, double? SevenDayUsed, string? Organization, DateTimeOffset? EstimatedFiveHourReset, DateTimeOffset? EstimatedSevenDayReset);
    private sealed record ClaudeStatuslineUsage(DateTimeOffset ObservedAt, double? FiveHourUsed, double? SevenDayUsed, DateTimeOffset? FiveHourReset, DateTimeOffset? SevenDayReset);
    public void Dispose() => _timer.Dispose();
}
