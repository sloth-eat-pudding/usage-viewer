using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Text.Json;
using System.Text.RegularExpressions;
using static UsageViewer.JsonValues;
using static UsageViewer.UsageLog;

namespace UsageViewer;

internal sealed class ClaudeUsageReader : IDisposable
{
    private readonly SnapshotStore _store;
    private readonly string _home;
    private readonly IReadOnlyList<string> _claudePlanUsageHistories;
    private readonly string? _claudePlanUsageHistory;
    private Process? _activeClaudeProcess;
    private volatile bool _disposed;
    private DateTimeOffset? _lastClaudeSelectedSourceWriteTimeUtc;
    private string? _lastClaudeSelectedSource;
    private DateTimeOffset? _lastClaudeUsageCommandTriggerUtc;
    private DateTimeOffset? _nextClaudeUsageCommandUtc;
    private DateTimeOffset? _claudeCommandFiveHourReset;
    private DateTimeOffset? _claudeCommandSevenDayReset;
    private readonly object _claudeUsageCommandLock = new();

    internal ClaudeUsageReader(SnapshotStore store, IReadOnlyList<string>? histories = null)
    {
        _store = store;
        _home = store.Home;
        _claudePlanUsageHistories = histories ?? FindClaudePlanUsageHistories();
        _claudePlanUsageHistory = FindSelectedClaudePlanUsageHistory(_claudePlanUsageHistories);
    }

    internal void Refresh()
    {
        WriteConfiguredClaudeSource();
        WriteClaudeDesktopSnapshots();
        // A fresh Desktop API response is authoritative for its organization;
        // do not let the CLI command's cached result defer applying it.
        var hasFreshDesktopApi = ReadClaudePlanUsage() is { Organization: { } organization } && ClaudeDesktopApiUsage.Read(_home, organization) is not null;
        if (!hasFreshDesktopApi && TryWriteClaudeUsageFromCommand()) return;

        var cliSource = Path.Combine(_home, "claude-statusline-latest.json");
        var desktopSource = _claudePlanUsageHistory;
        var cliWriteTime = TryGetWriteTimeUtc(cliSource);
        var desktopWriteTime = desktopSource is null ? null : TryGetWriteTimeUtc(desktopSource);

        var useCli = cliWriteTime is not null &&
            (desktopWriteTime is null || cliWriteTime > desktopWriteTime);
        var statusLine = useCli ? ReadClaudeStatuslineUsage() : null;
        if (useCli && (statusLine is null || (statusLine.FiveHourUsed is null && statusLine.SevenDayUsed is null)))
        {
            useCli = false;
        }
        var selectedSource = useCli ? cliSource : desktopSource;
        var sourceWriteTime = useCli ? cliWriteTime : desktopWriteTime;
        var desktopPlan = useCli ? null : ReadClaudePlanUsage();
        var desktopApi = desktopPlan is null ? null : ClaudeDesktopApiUsage.Read(_home, desktopPlan.Organization);
        if (desktopApi is not null && (sourceWriteTime is null || desktopApi.ObservedAt > sourceWriteTime.Value))
            sourceWriteTime = desktopApi.ObservedAt;
        if (selectedSource is null || sourceWriteTime is null) return;
        if (_lastClaudeSelectedSource == selectedSource && _lastClaudeSelectedSourceWriteTimeUtc == sourceWriteTime) return;

        double? fiveHourUsed;
        double? sevenDayUsed;
        DateTimeOffset? fiveHourReset;
        DateTimeOffset? sevenDayReset;

        if (useCli)
        {
            if (statusLine is null) return;
            fiveHourUsed = statusLine.FiveHourUsed;
            sevenDayUsed = statusLine.SevenDayUsed;
            fiveHourReset = _claudeCommandFiveHourReset ?? statusLine.FiveHourReset;
            sevenDayReset = _claudeCommandSevenDayReset ?? statusLine.SevenDayReset;
        }
        else
        {
            var plan = desktopPlan;
            if (plan is null && desktopApi is null) return;
            fiveHourUsed = desktopApi?.FiveHourUsed;
            sevenDayUsed = desktopApi?.SevenDayUsed;
            fiveHourReset = desktopApi?.FiveHourReset;
            sevenDayReset = desktopApi?.SevenDayReset;
        }

        _store.Write("claude-desktop-latest.json", new {
            generated_at = DateTimeOffset.UtcNow.ToString("O"), observed_at = sourceWriteTime.Value.ToString("O"),
            source = useCli ? "claude-code-statusline" : "claude-desktop-plan-usage-history",
            source_mode = useCli ? "cli" : "desktop",
            source_file = selectedSource,
            percentages = new {
                context_used = (double?)null,
                five_hour_used = fiveHourUsed,
                seven_day_used = sevenDayUsed
            },
            resets_at = new {
                five_hour_epoch_seconds = ToEpochSeconds(fiveHourReset),
                seven_day_epoch_seconds = ToEpochSeconds(sevenDayReset)
            },
        });

        _lastClaudeSelectedSource = selectedSource;
        _lastClaudeSelectedSourceWriteTimeUtc = sourceWriteTime;
    }

    private void WriteClaudeDesktopSnapshots()
    {
        for (var index = 0; index < _claudePlanUsageHistories.Count; index++)
        {
            var sourcePath = _claudePlanUsageHistories[index];
            var sourceWriteTime = TryGetWriteTimeUtc(sourcePath);
            var plan = ReadClaudePlanUsage(sourcePath);
            if (plan is null || sourceWriteTime is null) continue;

            var desktopApi = ClaudeDesktopApiUsage.Read(_home, plan.Organization);
            var observedAt = sourceWriteTime.Value;
            if (desktopApi is not null && desktopApi.ObservedAt > observedAt) observedAt = desktopApi.ObservedAt;
            _store.Write($"claude-desktop-{index}-latest.json", new {
                generated_at = DateTimeOffset.UtcNow.ToString("O"), observed_at = observedAt.ToString("O"),
                source = "claude-desktop-plan-usage-history", source_mode = "desktop", source_file = sourcePath,
                 percentages = new { context_used = (double?)null, five_hour_used = desktopApi?.FiveHourUsed, seven_day_used = desktopApi?.SevenDayUsed },
                 resets_at = new { five_hour_epoch_seconds = ToEpochSeconds(desktopApi?.FiveHourReset), seven_day_epoch_seconds = ToEpochSeconds(desktopApi?.SevenDayReset) }
            });
        }
    }

    private bool TryWriteClaudeUsageFromCommand()
    {
        lock (_claudeUsageCommandLock)
        {
            var now = DateTimeOffset.UtcNow;
            var cliWriteTime = TryGetWriteTimeUtc(Path.Combine(_home, "claude-statusline-latest.json"));
            var desktopWriteTime = _claudePlanUsageHistory is null ? null : TryGetWriteTimeUtc(_claudePlanUsageHistory);
            var sourceMarker = new[] { cliWriteTime, desktopWriteTime }.Max();
            var sourceChanged = sourceMarker is not null && sourceMarker != _lastClaudeUsageCommandTriggerUtc;
            var resetDue = _nextClaudeUsageCommandUtc is null || now >= _nextClaudeUsageCommandUtc;

            if (!sourceChanged && !resetDue && _lastClaudeUsageCommandTriggerUtc is not null) return true;

            if (!TryRunClaudeUsageCommand(out var output)) return false;
            if (!TryParseClaudeUsage(output, out var fiveHourUsed, out var sevenDayUsed, out var fiveHourReset, out var sevenDayReset))
            {
                TraceClaude($"parse failed output={output.Replace("\r", " ").Replace("\n", " | ")}");
                return false;
            }

            _lastClaudeUsageCommandTriggerUtc = sourceMarker ?? now;
            _claudeCommandFiveHourReset = fiveHourReset;
            _claudeCommandSevenDayReset = sevenDayReset;
            _nextClaudeUsageCommandUtc = new[] { fiveHourReset, sevenDayReset }
                .Where(value => value is not null && value > now)
                .OrderBy(value => value)
                .FirstOrDefault() ?? now.AddMinutes(5);
            // Keep the original file-based percentages; only carry the exact
            // reset timestamps into the snapshot written by WriteClaude().
            _lastClaudeSelectedSource = null;
            _lastClaudeSelectedSourceWriteTimeUtc = null;
            return false;
        }
    }

    private bool TryRunClaudeUsageCommand(out string output)
    {
        output = "";
        try
        {
            var command = FindClaudeCliCommand();
            if (command is null) { TraceClaude("command not found"); return false; }
            TraceClaude($"command={command}");

            using var process = new Process
            {
                StartInfo = new ProcessStartInfo
                {
                    FileName = "cmd.exe",
                    UseShellExecute = false,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    CreateNoWindow = true
                }
            };
            var commandLine = command.Contains(' ', StringComparison.Ordinal)
                ? $"\"{command}\" -p /usage"
                : $"{command} -p /usage";
            process.StartInfo.Arguments = $"/d /s /c \"{commandLine}\"";
            lock (_claudeUsageCommandLock)
            {
                if (_disposed) return false;
                _activeClaudeProcess = process;
            }
            if (!process.Start()) { TraceClaude("process start returned false"); return false; }
            if (!process.WaitForExit(15000))
            {
                try { process.Kill(entireProcessTree: true); } catch { }
                TraceClaude("timeout");
                return false;
            }
            output = process.StandardOutput.ReadToEnd();
            var exitCode = process.ExitCode;
            TraceClaude($"exit={exitCode} output={output.Replace("\r", " ").Replace("\n", " | ")}");
            return exitCode == 0 && !string.IsNullOrWhiteSpace(output);
        }
        catch (Exception error) { TraceClaude($"exception={error}"); return false; }
        finally
        {
            lock (_claudeUsageCommandLock)
            {
                try
                {
                    if (_activeClaudeProcess is not null && !_activeClaudeProcess.HasExited)
                        _activeClaudeProcess.Kill(entireProcessTree: true);
                }
                catch { }
                _activeClaudeProcess = null;
            }
        }
    }

    private static string? FindClaudeCliCommand()
    {
        var appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        var cliRoot = Path.Combine(appData, "Claude", "claude-code");
        try
        {
            var installed = Directory.Exists(cliRoot)
                ? Directory.EnumerateFiles(cliRoot, "claude.exe", SearchOption.AllDirectories)
                    .OrderByDescending(File.GetLastWriteTimeUtc)
                    .FirstOrDefault()
                : null;
            if (installed is not null) return installed;
        }
        catch { }

        var path = Environment.GetEnvironmentVariable("PATH") ?? "";
        foreach (var directory in path.Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            foreach (var name in new[] { "claude.exe", "claude.cmd", "claude.bat", "claude" })
            {
                var candidate = Path.Combine(directory, name);
                if (File.Exists(candidate)) return candidate;
            }
        }
        return null;
    }

    private static bool TryParseClaudeUsage(
        string output,
        out double fiveHourUsed,
        out double sevenDayUsed,
        out DateTimeOffset? fiveHourReset,
        out DateTimeOffset? sevenDayReset)
    {
        fiveHourUsed = 0;
        sevenDayUsed = 0;
        fiveHourReset = null;
        sevenDayReset = null;

        // Claude may add terminal control characters when invoked through cmd.exe.
        output = Regex.Replace(output, @"\x1B(?:\[[0-9;?]*[ -/]*[@-~])", "");
        const string resetPattern = @"(?<reset>[A-Za-z]{3}\s+\d{1,2},\s+\d{1,2}(?::\d{2})?[ap]m)(?:\s+\((?<zone>[^)]+)\))?";
        var options = RegexOptions.IgnoreCase | RegexOptions.Singleline;
        var session = Regex.Match(output, $@"Current\s+session\s*:\s*(?<percent>[0-9]+(?:\.[0-9]+)?)%.*?resets\s+{resetPattern}", options);
        var week = Regex.Match(output, $@"Current\s+week\s+\(all\s+models\)\s*:\s*(?<percent>[0-9]+(?:\.[0-9]+)?)%.*?resets\s+{resetPattern}", options);
        if (!session.Success || !week.Success ||
            !double.TryParse(session.Groups["percent"].Value, NumberStyles.Float, CultureInfo.InvariantCulture, out fiveHourUsed) ||
            !double.TryParse(week.Groups["percent"].Value, NumberStyles.Float, CultureInfo.InvariantCulture, out sevenDayUsed)) return false;

        fiveHourReset = ParseClaudeReset(session.Groups["reset"].Value, session.Groups["zone"].Value);
        sevenDayReset = ParseClaudeReset(week.Groups["reset"].Value, week.Groups["zone"].Value);
        return fiveHourReset is not null && sevenDayReset is not null;
    }

    private static DateTimeOffset? ParseClaudeReset(string text, string zoneName)
    {
        if (Regex.IsMatch(text, @",\s*\d{1,2}\s*[ap]m$", RegexOptions.IgnoreCase))
            text = Regex.Replace(text, @",\s*(?<hour>\d{1,2})\s*(?<ampm>[ap]m)$", ",${hour}:00${ampm}", RegexOptions.IgnoreCase);
        text = Regex.Replace(text, "am$", "AM", RegexOptions.IgnoreCase);
        text = Regex.Replace(text, "pm$", "PM", RegexOptions.IgnoreCase);
        if (!DateTime.TryParseExact(text, "MMM d, h:mmtt", CultureInfo.InvariantCulture, DateTimeStyles.AllowWhiteSpaces, out var localTime)) return null;
        var windowsZone = string.IsNullOrWhiteSpace(zoneName) || zoneName.Equals("Asia/Taipei", StringComparison.OrdinalIgnoreCase)
            ? "Taipei Standard Time"
            : zoneName;
        try
        {
            var zone = TimeZoneInfo.FindSystemTimeZoneById(windowsZone);
            var utc = TimeZoneInfo.ConvertTimeToUtc(DateTime.SpecifyKind(localTime, DateTimeKind.Unspecified), zone);
            return new DateTimeOffset(utc);
        }
        catch { return null; }
    }

    private static DateTimeOffset? TryGetWriteTimeUtc(string path)
    {
        try
        {
            return File.Exists(path) ? new DateTimeOffset(File.GetLastWriteTimeUtc(path)) : null;
        }
        catch { return null; }
    }

    private ClaudePlanUsage? ReadClaudePlanUsage() => ReadClaudePlanUsage(_claudePlanUsageHistory);

    private static ClaudePlanUsage? ReadClaudePlanUsage(string? sourcePath)
    {
        if (sourcePath is null || !File.Exists(sourcePath)) return null;

        try
        {
            using var document = JsonDocument.Parse(File.ReadAllText(sourcePath));
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

    private void WriteConfiguredClaudeSource()
    {
        var settingsPath = Path.Combine(_home, "claude-custom-source.json");
        if (!File.Exists(settingsPath)) return;
        try
        {
            using var document = JsonDocument.Parse(File.ReadAllText(settingsPath));
            var sources = document.RootElement.TryGetProperty("sources", out var array) && array.ValueKind == JsonValueKind.Array
                ? array.EnumerateArray().ToList()
                : new List<JsonElement> { document.RootElement };
            for (var index = 0; index < sources.Count; index++)
            {
                var path = StringOrNull(sources[index], "path");
                if (string.IsNullOrWhiteSpace(path)) continue;
                var usage = ReadClaudePlanUsage(path);
                if (usage is null) continue;
                var desktopApi = ClaudeDesktopApiUsage.Read(_home, usage.Organization);
                _store.Write($"claude-custom-{index}-latest.json", new {
                    generated_at = DateTimeOffset.UtcNow.ToString("O"), observed_at = usage.ObservedAt.ToString("O"),
                    source = "claude-custom-plan-usage-history", source_mode = "desktop", source_file = path,
                percentages = new { context_used = (double?)null, five_hour_used = desktopApi?.FiveHourUsed, seven_day_used = desktopApi?.SevenDayUsed },
                resets_at = new { five_hour_epoch_seconds = ToEpochSeconds(desktopApi?.FiveHourReset), seven_day_epoch_seconds = ToEpochSeconds(desktopApi?.SevenDayReset) }
                });
            }
        }
        catch { }
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

    private static IReadOnlyList<string> FindClaudePlanUsageHistories() =>
        ClaudeDesktopProfiles.Find().Select(profile => profile.Path).ToList();

    private string? FindSelectedClaudePlanUsageHistory(IReadOnlyList<string> defaults)
    {
        var settingsPath = Path.Combine(_home, "display-settings.json");
        var environment = "default";
        try
        {
            if (File.Exists(settingsPath))
            {
                using var settings = JsonDocument.Parse(File.ReadAllText(settingsPath));
                if (settings.RootElement.TryGetProperty("claude_user_environment", out var value))
                    environment = value.GetString() ?? "default";
            }
        }
        catch { }

        if (!string.IsNullOrWhiteSpace(environment) && !string.Equals(environment, "default", StringComparison.OrdinalIgnoreCase))
        {
            var customPath = Path.Combine(_home, "claude-custom-source.json");
            try
            {
                if (File.Exists(customPath))
                {
                    using var custom = JsonDocument.Parse(File.ReadAllText(customPath));
                    if (custom.RootElement.TryGetProperty("sources", out var sources) && sources.ValueKind == JsonValueKind.Array)
                    {
                        foreach (var source in sources.EnumerateArray())
                        {
                            var name = source.TryGetProperty("name", out var n) ? n.GetString() : null;
                            var path = source.TryGetProperty("path", out var p) ? p.GetString() : null;
                            if (string.Equals(name, environment, StringComparison.OrdinalIgnoreCase) && !string.IsNullOrWhiteSpace(path) && File.Exists(path))
                                return path;
                        }
                    }
                }
            }
            catch { }
        }

        return defaults.FirstOrDefault();
    }

    private readonly record struct ClaudePlanSample(DateTimeOffset Time, double? FiveHour, double? SevenDay, string? Organization);
    private sealed record ClaudePlanUsage(DateTimeOffset ObservedAt, double? FiveHourUsed, double? SevenDayUsed, string? Organization, DateTimeOffset? EstimatedFiveHourReset, DateTimeOffset? EstimatedSevenDayReset);
    private sealed record ClaudeStatuslineUsage(DateTimeOffset ObservedAt, double? FiveHourUsed, double? SevenDayUsed, DateTimeOffset? FiveHourReset, DateTimeOffset? SevenDayReset);

    public void Dispose()
    {
        lock (_claudeUsageCommandLock)
        {
            if (_disposed) return;
            _disposed = true;
            try
            {
                if (_activeClaudeProcess is not null && !_activeClaudeProcess.HasExited)
                    _activeClaudeProcess.Kill(entireProcessTree: true);
            }
            catch { }
            _activeClaudeProcess = null;
        }
    }
}
