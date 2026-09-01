using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace UsageViewer;

public sealed class UsageReaderService : IDisposable
{
    private readonly string _home = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".usage-viewer");
    private readonly IReadOnlyList<string> _claudePlanUsageHistories = FindClaudePlanUsageHistories();
    private readonly string? _claudePlanUsageHistory;
    private DateTimeOffset? _lastClaudeSelectedSourceWriteTimeUtc;
    private string? _lastClaudeSelectedSource;
    private DateTimeOffset? _lastClaudeUsageCommandTriggerUtc;
    private DateTimeOffset? _nextClaudeUsageCommandUtc;
    private DateTimeOffset? _claudeCommandFiveHourReset;
    private DateTimeOffset? _claudeCommandSevenDayReset;
    private double? _claudeCommandFiveHourUsed;
    private double? _claudeCommandSevenDayUsed;
    private readonly object _claudeUsageCommandLock = new();
    private readonly Timer _timer;
    private readonly FileSystemWatcher? _codexWatcher;
    private Process? _activeClaudeProcess;
    private Process? _remoteSyncProcess;
    private readonly HttpListener? _claudeDesktopUsageBridge;
    private readonly CancellationTokenSource _bridgeCancellation = new();
    private volatile bool _disposed;
    private int _refreshRunning;
    private int _codexDirty = 1;
    private DateTimeOffset _nextCodexPollUtc = DateTimeOffset.MinValue;
    private static readonly TimeSpan CodexPollInterval = TimeSpan.FromSeconds(10);

    public UsageReaderService()
    {
        _claudePlanUsageHistory = _claudePlanUsageHistories.FirstOrDefault();
        var codexRoot = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".codex", "sessions");
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
        _timer = new Timer(_ => Refresh(), null, TimeSpan.Zero, TimeSpan.FromSeconds(2));
        StartRemoteSync();
        _claudeDesktopUsageBridge = StartClaudeDesktopUsageBridge();
    }

    private void Refresh()
    {
        if (_disposed || Interlocked.Exchange(ref _refreshRunning, 1) != 0) return;
        try
        {
            // Claude is intentionally read first, but off the UI thread.
            try { WriteClaude(); } catch (Exception error) { TraceClaude($"claude refresh exception={error.Message}"); }
            try { WriteCodex(); } catch (Exception error) { TraceClaude($"codex refresh exception={error.Message}"); }
        }
        finally { Volatile.Write(ref _refreshRunning, 0); }
    }

    private void MarkCodexDirty(object? sender, FileSystemEventArgs e) => Volatile.Write(ref _codexDirty, 1);
    private void MarkCodexDirty(object? sender, ErrorEventArgs e) => Volatile.Write(ref _codexDirty, 1);

    private void StartRemoteSync()
    {
        try
        {
            var script = Path.Combine(AppContext.BaseDirectory, "scripts", "sync-codex-remote.ps1");
            if (!File.Exists(script)) return;
            _remoteSyncProcess = Process.Start(new ProcessStartInfo
            {
                FileName = "powershell.exe",
                Arguments = $"-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"{script}\"",
                UseShellExecute = false,
                CreateNoWindow = true,
                WorkingDirectory = AppContext.BaseDirectory
            });
        }
        catch (Exception error) { TraceClaude($"remote sync start failed={error.Message}"); }
    }

    // This is the native equivalent of claude-desktop-usage-bridge.js.  Keeping
    // it in the EXE preserves the self-contained release path (no Node needed).
    private HttpListener? StartClaudeDesktopUsageBridge()
    {
        try
        {
            var listener = new HttpListener();
            listener.Prefixes.Add("http://127.0.0.1:8765/");
            listener.Start();
            _ = Task.Run(() => ServeClaudeDesktopUsageBridge(listener, _bridgeCancellation.Token));
            return listener;
        }
        catch (Exception error)
        {
            TraceClaude($"Claude Desktop usage bridge start failed={error.Message}");
            return null;
        }
    }

    private async Task ServeClaudeDesktopUsageBridge(HttpListener listener, CancellationToken cancellationToken)
    {
        while (!cancellationToken.IsCancellationRequested)
        {
            try
            {
                var context = await listener.GetContextAsync();
                _ = Task.Run(() => HandleClaudeDesktopUsageBridgeRequest(context), cancellationToken);
            }
            catch (HttpListenerException) when (cancellationToken.IsCancellationRequested) { return; }
            catch (ObjectDisposedException) { return; }
            catch (Exception error) { TraceClaude($"Claude Desktop usage bridge request failed={error.Message}"); }
        }
    }

    private async Task HandleClaudeDesktopUsageBridgeRequest(HttpListenerContext context)
    {
        var request = context.Request;
        var response = context.Response;
        try
        {
            var origin = request.Headers["Origin"] ?? "";
            var allowedOrigin = origin is "https://claude.ai" or "https://www.claude.ai";
            if (request.HttpMethod == "GET" && request.Url?.AbsolutePath == "/health")
            {
                await WriteBridgeResponse(response, 200, "{\"status\":\"ok\"}");
                return;
            }
            if (request.HttpMethod == "OPTIONS")
            {
                if (!allowedOrigin) { await WriteBridgeResponse(response, 403); return; }
                AddCorsHeaders(response, origin);
                response.StatusCode = 204;
                response.Close();
                return;
            }
            if (request.HttpMethod != "POST" || request.Url?.AbsolutePath != "/claude-desktop-usage" || !allowedOrigin)
            {
                await WriteBridgeResponse(response, request.HttpMethod == "POST" ? 403 : 404);
                return;
            }
            var organizationId = request.QueryString["org"] ?? "";
            if (!Regex.IsMatch(organizationId, "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", RegexOptions.IgnoreCase))
            {
                await WriteBridgeResponse(response, 400, "{\"error\":\"A valid org query parameter is required\"}", origin);
                return;
            }
            if (request.ContentLength64 < 0 || request.ContentLength64 > 64 * 1024)
            {
                await WriteBridgeResponse(response, 413, "{\"error\":\"Payload too large\"}", origin);
                return;
            }
            using var body = new StreamReader(request.InputStream, request.ContentEncoding ?? Encoding.UTF8, false, 64 * 1024, leaveOpen: false);
            var json = await body.ReadToEndAsync();
            if (Encoding.UTF8.GetByteCount(json) > 64 * 1024) throw new InvalidDataException("Payload too large");
            using var document = JsonDocument.Parse(json);
            var fiveHour = ReadBridgeWindow(document.RootElement, "five_hour");
            var sevenDay = ReadBridgeWindow(document.RootElement, "seven_day");
            if (fiveHour.Used is null && sevenDay.Used is null) throw new InvalidDataException("Expected a Claude Desktop usage response");
            var now = DateTimeOffset.UtcNow;
            WriteJsonAtomic(Path.Combine(_home, $"claude-desktop-api-{organizationId}-latest.json"), new {
                generated_at = now.ToString("O"), observed_at = now.ToString("O"), source = "claude-desktop-api-bridge", source_mode = "desktop", organization_id = organizationId,
                percentages = new { five_hour_used = fiveHour.Used, seven_day_used = sevenDay.Used },
                resets_at = new { five_hour_epoch_seconds = ToEpochSeconds(fiveHour.Reset), seven_day_epoch_seconds = ToEpochSeconds(sevenDay.Reset) }
            });
            await WriteBridgeResponse(response, 204, null, origin);
        }
        catch (InvalidDataException error) { await WriteBridgeResponse(response, error.Message == "Payload too large" ? 413 : 400, $"{{\"error\":{JsonSerializer.Serialize(error.Message)}}}", request.Headers["Origin"]); }
        catch (JsonException) { await WriteBridgeResponse(response, 400, "{\"error\":\"Expected a Claude Desktop usage response\"}", request.Headers["Origin"]); }
        catch (Exception error) { TraceClaude($"Claude Desktop usage bridge handler failed={error.Message}"); await WriteBridgeResponse(response, 400, "{\"error\":\"Invalid request\"}", request.Headers["Origin"]); }
    }

    private static (double? Used, DateTimeOffset? Reset) ReadBridgeWindow(JsonElement root, string name)
    {
        var window = root.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.Object ? value : default;
        var reset = StringOrNull(window, "resets_at");
        return (NumberOrNull(window, "utilization"), DateTimeOffset.TryParse(reset, out var parsedReset) ? parsedReset : null);
    }

    private static void AddCorsHeaders(HttpListenerResponse response, string origin)
    {
        response.Headers["Access-Control-Allow-Origin"] = origin;
        response.Headers["Access-Control-Allow-Methods"] = "POST, OPTIONS";
        response.Headers["Access-Control-Allow-Headers"] = "Content-Type";
        response.Headers["Vary"] = "Origin";
    }

    private static async Task WriteBridgeResponse(HttpListenerResponse response, int statusCode, string? value = null, string? origin = null)
    {
        if (origin is "https://claude.ai" or "https://www.claude.ai") AddCorsHeaders(response, origin);
        response.StatusCode = statusCode;
        if (value is not null)
        {
            var bytes = Encoding.UTF8.GetBytes(value);
            response.ContentType = "application/json";
            response.ContentLength64 = bytes.Length;
            await response.OutputStream.WriteAsync(bytes);
        }
        response.Close();
    }

    private void WriteCodex()
    {
        // The watcher makes normal updates cheap, but it can lose events when its
        // internal buffer overflows or a file is replaced while being written.
        // Keep a periodic full scan so one missed event cannot permanently freeze
        // the displayed usage.
        var now = DateTimeOffset.UtcNow;
        var dirty = Interlocked.Exchange(ref _codexDirty, 0) != 0;
        if (_codexWatcher is not null && !dirty && now < _nextCodexPollUtc) return;
        _nextCodexPollUtc = now + CodexPollInterval;
        var root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".codex", "sessions");
        var localCandidates = new List<CodexCandidate>();
        foreach (var mode in new[] { "desktop", "cli" })
        {
            var local = FindLatestCodexUsage(root, mode);
            if (local is not null)
            {
                localCandidates.Add(local.Value);
                WriteCodexSnapshot($"codex-{mode}-latest.json", local.Value);
            }
        }
        var selectedLocal = localCandidates.OrderByDescending(candidate => candidate.Time).FirstOrDefault();
        if (selectedLocal.File is not null) WriteCodexSnapshot("codex-app-latest.json", selectedLocal);
        var remoteRoot = Path.Combine(_home, "remote-codex");
        var remoteSources = ReadConfiguredSources("remote-sources.json");
        for (var index = 0; index < remoteSources.Count; index++)
        {
            var remoteLatest = FindLatestCodexUsage(Path.Combine(remoteRoot, index.ToString(), "sessions"));
            if (remoteLatest is not null && IsSnapshotNotOlder($"codex-remote-{index}-latest.json", remoteLatest.Value.Time))
                WriteCodexSnapshot($"codex-remote-{index}-latest.json", remoteLatest.Value);
        }
        if (remoteSources.Count == 0)
        {
            var remoteLatest = FindLatestCodexUsage(Path.Combine(remoteRoot, "sessions"));
            if (remoteLatest is not null && IsSnapshotNotOlder("codex-remote-0-latest.json", remoteLatest.Value.Time))
                WriteCodexSnapshot("codex-remote-0-latest.json", remoteLatest.Value);
        }
    }

    private bool IsSnapshotNotOlder(string fileName, DateTimeOffset candidateTime)
    {
        var path = Path.Combine(_home, fileName);
        if (!File.Exists(path)) return true;
        try
        {
            using var document = JsonDocument.Parse(File.ReadAllText(path));
            var root = document.RootElement;
            var timestamp = StringOrNull(root, "observed_at") ?? StringOrNull(root, "generated_at");
            return !DateTimeOffset.TryParse(timestamp, out var currentTime) || candidateTime >= currentTime;
        }
        catch { return true; }
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

        WriteJson(fileName, new {
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
            .Select(candidate => candidate!.Value)
            .OrderByDescending(candidate => candidate.Time)
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

    private void WriteClaude()
    {
        WriteConfiguredClaudeSource();
        WriteClaudeDesktopSnapshots();
        // A fresh Desktop API response is authoritative for its organization;
        // do not let the CLI command's cached result defer applying it.
        var hasFreshDesktopApi = ReadClaudePlanUsage() is { Organization: { } organization } && ReadClaudeDesktopApiUsage(organization) is not null;
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
        var desktopApi = desktopPlan is null ? null : ReadClaudeDesktopApiUsage(desktopPlan.Organization);
        if (desktopApi is not null && (sourceWriteTime is null || desktopApi.ObservedAt > sourceWriteTime.Value))
            sourceWriteTime = desktopApi.ObservedAt;
        if (selectedSource is null || sourceWriteTime is null) return;
        if (_lastClaudeSelectedSource == selectedSource && _lastClaudeSelectedSourceWriteTimeUtc == sourceWriteTime) return;

        double? fiveHourUsed;
        double? sevenDayUsed;
        DateTimeOffset? fiveHourReset;
        DateTimeOffset? sevenDayReset;
        bool resetEstimated;

        if (useCli)
        {
            if (statusLine is null) return;
            fiveHourUsed = statusLine.FiveHourUsed;
            sevenDayUsed = statusLine.SevenDayUsed;
            fiveHourReset = _claudeCommandFiveHourReset ?? statusLine.FiveHourReset;
            sevenDayReset = _claudeCommandSevenDayReset ?? statusLine.SevenDayReset;
            resetEstimated = _claudeCommandFiveHourReset is null && _claudeCommandSevenDayReset is null;
        }
        else
        {
            var plan = desktopPlan;
            if (plan is null && _claudeCommandFiveHourUsed is null && _claudeCommandSevenDayUsed is null) return;
            fiveHourUsed = desktopApi?.FiveHourUsed ?? plan?.FiveHourUsed ?? _claudeCommandFiveHourUsed;
            sevenDayUsed = desktopApi?.SevenDayUsed ?? plan?.SevenDayUsed ?? _claudeCommandSevenDayUsed;
            fiveHourReset = desktopApi?.FiveHourReset ?? _claudeCommandFiveHourReset ?? plan?.EstimatedFiveHourReset;
            sevenDayReset = desktopApi?.SevenDayReset ?? _claudeCommandSevenDayReset ?? plan?.EstimatedSevenDayReset;
            resetEstimated = desktopApi is null && _claudeCommandFiveHourReset is null && _claudeCommandSevenDayReset is null;
        }

        WriteJson("claude-desktop-latest.json", new {
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
            reset_is_estimated = new {
                five_hour = resetEstimated && fiveHourReset is not null,
                seven_day = resetEstimated && sevenDayReset is not null
            }
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

            var desktopApi = ReadClaudeDesktopApiUsage(plan.Organization);
            var observedAt = sourceWriteTime.Value;
            if (desktopApi is not null && desktopApi.ObservedAt > observedAt) observedAt = desktopApi.ObservedAt;
            WriteJson($"claude-desktop-{index}-latest.json", new {
                generated_at = DateTimeOffset.UtcNow.ToString("O"), observed_at = observedAt.ToString("O"),
                source = "claude-desktop-plan-usage-history", source_mode = "desktop", source_file = sourcePath,
                percentages = new { context_used = (double?)null, five_hour_used = desktopApi?.FiveHourUsed ?? plan.FiveHourUsed, seven_day_used = desktopApi?.SevenDayUsed ?? plan.SevenDayUsed },
                resets_at = new { five_hour_epoch_seconds = ToEpochSeconds(desktopApi?.FiveHourReset ?? plan.EstimatedFiveHourReset), seven_day_epoch_seconds = ToEpochSeconds(desktopApi?.SevenDayReset ?? plan.EstimatedSevenDayReset) },
                reset_is_estimated = new { five_hour = desktopApi is null && plan.EstimatedFiveHourReset is not null, seven_day = desktopApi is null && plan.EstimatedSevenDayReset is not null }
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
            _claudeCommandFiveHourUsed = fiveHourUsed;
            _claudeCommandSevenDayUsed = sevenDayUsed;
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

    private static void TraceClaude(string message)
    {
        try
        {
            var directory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".usage-viewer");
            Directory.CreateDirectory(directory);
            File.AppendAllText(Path.Combine(directory, "claude-usage-command.log"), $"{DateTimeOffset.UtcNow:O} {message}{Environment.NewLine}");
        }
        catch { }
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
                var desktopApi = ReadClaudeDesktopApiUsage(usage.Organization);
                WriteJson($"claude-custom-{index}-latest.json", new {
                    generated_at = DateTimeOffset.UtcNow.ToString("O"), observed_at = usage.ObservedAt.ToString("O"),
                    source = "claude-custom-plan-usage-history", source_mode = "desktop", source_file = path,
                    percentages = new { context_used = (double?)null, five_hour_used = desktopApi?.FiveHourUsed ?? usage.FiveHourUsed, seven_day_used = desktopApi?.SevenDayUsed ?? usage.SevenDayUsed },
                    resets_at = new { five_hour_epoch_seconds = ToEpochSeconds(desktopApi?.FiveHourReset ?? usage.EstimatedFiveHourReset), seven_day_epoch_seconds = ToEpochSeconds(desktopApi?.SevenDayReset ?? usage.EstimatedSevenDayReset) },
                    reset_is_estimated = new { five_hour = desktopApi?.FiveHourReset is null, seven_day = desktopApi?.SevenDayReset is null }
                });
            }
        }
        catch { }
    }

    private ClaudeDesktopApiUsage? ReadClaudeDesktopApiUsage(string? organizationId)
    {
        if (string.IsNullOrWhiteSpace(organizationId)) return null;
        try
        {
            var path = Path.Combine(_home, $"claude-desktop-api-{organizationId}-latest.json");
            if (!File.Exists(path)) return null;
            using var document = JsonDocument.Parse(File.ReadAllText(path));
            var root = document.RootElement;
            if (StringOrNull(root, "source") != "claude-desktop-api-bridge" || !string.Equals(StringOrNull(root, "organization_id"), organizationId, StringComparison.Ordinal)) return null;
            var observedText = StringOrNull(root, "observed_at") ?? StringOrNull(root, "generated_at");
            if (!DateTimeOffset.TryParse(observedText, out var observedAt) || DateTimeOffset.UtcNow - observedAt > TimeSpan.FromMinutes(5)) return null;
            var percentages = root.TryGetProperty("percentages", out var p) ? p : default;
            var resets = root.TryGetProperty("resets_at", out var r) ? r : default;
            return new ClaudeDesktopApiUsage(observedAt, NumberOrNull(percentages, "five_hour_used"), NumberOrNull(percentages, "seven_day_used"), FutureEpoch(NumberOrNull(resets, "five_hour_epoch_seconds")), FutureEpoch(NumberOrNull(resets, "seven_day_epoch_seconds")));
        }
        catch { return null; }
    }

    private List<JsonElement> ReadConfiguredSources(string fileName)
    {
        try
        {
            var path = Path.Combine(_home, fileName);
            if (!File.Exists(path)) return new();
            using var document = JsonDocument.Parse(File.ReadAllText(path));
            return document.RootElement.TryGetProperty("sources", out var array) && array.ValueKind == JsonValueKind.Array
                ? array.EnumerateArray().Select(item => item.Clone()).ToList() : new();
        }
        catch { return new(); }
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

    private static IReadOnlyList<string> FindClaudePlanUsageHistories()
    {
        var appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        var regularInstallPath = Path.Combine(appData, "Claude", "plan-usage-history.json");
        var candidates = new List<string>();
        if (File.Exists(regularInstallPath)) candidates.Add(regularInstallPath);

        var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        try
        {
            var packages = Path.Combine(localAppData, "Packages");
            if (Directory.Exists(packages))
            {
                candidates = Directory.EnumerateDirectories(packages, "Claude_*")
                    .Select(directory => Path.Combine(directory, "LocalCache", "Roaming", "Claude", "plan-usage-history.json"))
                    .ToList();
            }
        }
        catch { }

        return candidates.Where(File.Exists)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .OrderBy(path => path.Equals(regularInstallPath, StringComparison.OrdinalIgnoreCase) ? 0 : 1)
            .ThenByDescending(File.GetLastWriteTimeUtc)
            .ToList();
    }

    private void WriteJson(string name, object value)
    {
        Directory.CreateDirectory(_home);
        var path = Path.Combine(_home, name);
        WriteJsonAtomic(path, value);
    }

    private static void WriteJsonAtomic(string path, object value)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
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
    private sealed record ClaudeDesktopApiUsage(DateTimeOffset ObservedAt, double? FiveHourUsed, double? SevenDayUsed, DateTimeOffset? FiveHourReset, DateTimeOffset? SevenDayReset);
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
            try
            {
                if (_remoteSyncProcess is not null && !_remoteSyncProcess.HasExited)
                    _remoteSyncProcess.Kill(entireProcessTree: true);
            }
            catch { }
            _remoteSyncProcess = null;
        }
        _timer.Dispose();
        _bridgeCancellation.Cancel();
        if (_claudeDesktopUsageBridge is not null)
        {
            try { _claudeDesktopUsageBridge.Stop(); } catch { }
            _claudeDesktopUsageBridge.Close();
        }
        _bridgeCancellation.Dispose();
        if (_codexWatcher is not null)
        {
            _codexWatcher.EnableRaisingEvents = false;
            _codexWatcher.Dispose();
        }
    }
}
