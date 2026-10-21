using System.Text.Json;
using UsageViewer;

var tests = new (string Name, Action Run)[]
{
    ("Shared Claude API contract", ContractFixtures),
    ("Window heartbeat validation and metadata minimization", MeterHeartbeat),
    ("Claude account isolation, zero usage, stale and malformed snapshots", ClaudeSnapshots),
    ("Claude desktop, custom and statusline source selection", ClaudeSources),
    ("Codex event order, source modes and rate-limit windows", CodexSources),
    ("Codex empty and invalid sessions", EmptyCodex),
    ("Remote snapshot monotonicity", RemoteSnapshots),
    ("Legacy settings migration and source round trip", Settings),
    ("Concurrent snapshot writes remain complete JSON", ConcurrentWrites)
};
var failed = 0;
foreach (var test in tests)
{
    try { test.Run(); Console.WriteLine($"PASS {test.Name}"); }
    catch (Exception error) { failed++; Console.Error.WriteLine($"FAIL {test.Name}: {error}"); }
}
Console.WriteLine($"{tests.Length - failed}/{tests.Length} regression groups passed.");
return failed == 0 ? 0 : 1;

static void MeterHeartbeat()
{
    var data = JsonSerializer.SerializeToElement(new { version = "1.1.0", refresh_id = Id(1), transcript = "must not persist" });
    var heartbeat = JsonSerializer.SerializeToElement(SessionMeterHeartbeat.Normalize(data, "11-1234", DateTimeOffset.UtcNow));
    Equal("11-1234", heartbeat.GetProperty("instance").GetString(), "Exact window instance");
    Equal(false, heartbeat.TryGetProperty("transcript", out _), "Conversation text must not be persisted");
    try { SessionMeterHeartbeat.Normalize(data, "../bad", DateTimeOffset.UtcNow); }
    catch (InvalidDataException) { return; }
    throw new Exception("Invalid window instance accepted");
}

static void ContractFixtures()
{
    using var document = JsonDocument.Parse(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "claude-usage.json")));
    foreach (var fixture in document.RootElement.EnumerateArray())
    {
        var name = fixture.GetProperty("name").GetString()!;
        if (fixture.TryGetProperty("invalid", out _))
        {
            try { ClaudeUsageContract.Normalize(fixture.GetProperty("input"), Id(1), DateTimeOffset.UtcNow); }
            catch (InvalidDataException) { continue; }
            throw new Exception($"{name}: invalid usage accepted");
        }
        var snapshot = JsonSerializer.SerializeToElement(ClaudeUsageContract.Normalize(fixture.GetProperty("input"), Id(1), DateTimeOffset.UtcNow, Id(2)));
        foreach (var expected in fixture.GetProperty("expected").EnumerateObject())
        {
            var section = expected.Name.EndsWith("_used") ? "percentages" : "resets_at";
            Equal(expected.Value.ToString(), snapshot.GetProperty(section).GetProperty(expected.Name).ToString(), name);
        }
        Equal(Id(1), snapshot.GetProperty("organization_id").GetString(), name);
        Equal(Id(2), snapshot.GetProperty("refresh_id").GetString(), name);
        Equal("claude-desktop-api-bridge", snapshot.GetProperty("source").GetString(), name);
        Equal("desktop", snapshot.GetProperty("source_mode").GetString(), name);
    }
}

static void ClaudeSnapshots()
{
    using var fixture = new Workspace();
    var now = DateTimeOffset.UtcNow;
    var file = $"claude-desktop-api-{Id(1)}-latest.json";
    Equal<ClaudeDesktopApiUsage?>(null, ClaudeDesktopApiUsage.Read(fixture.Root, Id(1)), "Missing snapshot");
    WriteApi(fixture.Store, Id(1), 0, 78, now);
    var usage = ClaudeDesktopApiUsage.Read(fixture.Root, Id(1));
    Equal(0d, usage!.FiveHourUsed, "Zero is valid");
    Equal(78d, usage.SevenDayUsed, "Weekly usage");
    Equal<ClaudeDesktopApiUsage?>(null, ClaudeDesktopApiUsage.Read(fixture.Root, Id(2)), "Other account must not borrow usage");
    fixture.Store.Write(file, Api(Id(2), 99, 99, now));
    Equal<ClaudeDesktopApiUsage?>(null, ClaudeDesktopApiUsage.Read(fixture.Root, Id(1)), "Wrong organization in file");
    WriteApi(fixture.Store, Id(1), 10, 20, now.AddMinutes(-6));
    File.SetLastWriteTimeUtc(Path.Combine(fixture.Root, file), now.UtcDateTime);
    Equal<ClaudeDesktopApiUsage?>(null, ClaudeDesktopApiUsage.Read(fixture.Root, Id(1)), "New mtime must not make stale data fresh");
    File.WriteAllText(Path.Combine(fixture.Root, file), "{broken");
    Equal<ClaudeDesktopApiUsage?>(null, ClaudeDesktopApiUsage.Read(fixture.Root, Id(1)), "Malformed snapshot");
}

static void ClaudeSources()
{
    using var fixture = new Workspace();
    var now = DateTimeOffset.UtcNow;
    var historyA = fixture.History("a.json", Id(1), now.AddMinutes(-2));
    var historyB = fixture.History("b.json", Id(2), now.AddMinutes(-1));
    WriteApi(fixture.Store, Id(1), 0, 10, now);
    WriteApi(fixture.Store, Id(2), 50, 70, now);
    fixture.Store.Write("claude-custom-source.json", new { sources = new[] { new { name = "Work", path = historyB } } });
    fixture.Store.Write("display-settings.json", new { claude_user_environment = "Work" });
    using var reader = new ClaudeUsageReader(fixture.Store, new[] { historyA, historyB });
    reader.Refresh(); // Fresh API observations avoid running a real Claude CLI.
    Equal(0d, fixture.Percent("claude-desktop-0-latest.json"), "First desktop account");
    Equal(50d, fixture.Percent("claude-desktop-1-latest.json"), "Second desktop account");
    Equal(50d, fixture.Percent("claude-custom-0-latest.json"), "Custom account");
    Equal(historyB, fixture.Read("claude-desktop-latest.json").GetProperty("source_file").GetString(), "Selected environment");
    fixture.Store.Write("claude-statusline-latest.json", new
    {
        source = "claude-code-statusline", generated_at = now.ToString("O"),
        percentages = new { five_hour_used = 9, seven_day_used = 11 },
        resets_at = new { five_hour_epoch_seconds = now.AddHours(1).ToUnixTimeSeconds() }
    });
    reader.Refresh();
    Equal(9d, fixture.Percent("claude-desktop-latest.json"), "Newer statusline selected");
    Equal("cli", fixture.Read("claude-desktop-latest.json").GetProperty("source_mode").GetString(), "CLI source mode");
    fixture.Store.Write("claude-statusline-latest.json", new { source = "wrong-source", generated_at = now.ToString("O") });
    reader.Refresh();
    Equal(50d, fixture.Percent("claude-desktop-latest.json"), "Invalid statusline falls back to selected desktop");
}

static void CodexSources()
{
    using var fixture = new Workspace();
    var root = Path.Combine(fixture.Root, "sessions");
    var now = DateTimeOffset.UtcNow;
    WriteSession(Path.Combine(root, "2026", "10", "20", "desktop.jsonl"), "vscode", now, 20, true);
    WriteSession(Path.Combine(root, "older-date", "cli.jsonl"), "cli", now.AddMinutes(1), 40);
    WriteSession(Path.Combine(root, "older-date", "older.jsonl"), "vscode", now.AddDays(-1), 99);
    File.AppendAllText(Path.Combine(root, "2026", "10", "20", "desktop.jsonl"), "\n{broken\n" + UsageEvent(now.AddHours(-1), 80, true));
    using var reader = new CodexUsageReader(fixture.Store, root);
    reader.Refresh();
    Equal(20d, fixture.Percent("codex-desktop-latest.json"), "Newest desktop event, not last line or newest file mtime");
    Equal(40d, fixture.Percent("codex-cli-latest.json"), "CLI source isolated");
    Equal(40d, fixture.Percent("codex-app-latest.json"), "Newest local source selected");
    Equal(21d, fixture.Percent("codex-desktop-latest.json", "seven_day_used"), "Windows mapped by duration, not primary/secondary position");
}

static void EmptyCodex()
{
    using var fixture = new Workspace();
    var root = Path.Combine(fixture.Root, "sessions");
    Directory.CreateDirectory(root);
    File.WriteAllText(Path.Combine(root, "invalid.jsonl"), "{broken\n");
    using var reader = new CodexUsageReader(fixture.Store, root);
    reader.Refresh();
    Equal(false, File.Exists(Path.Combine(fixture.Root, "codex-app-latest.json")), "Empty sources must not emit a snapshot or throw");
}

static void RemoteSnapshots()
{
    using var fixture = new Workspace();
    var now = DateTimeOffset.UtcNow;
    const string snapshot = "codex-remote-0-latest.json";
    fixture.Store.Write(snapshot, new { observed_at = now.ToString("O"), percentages = new { five_hour_used = 55 } });
    WriteSession(Path.Combine(fixture.Root, "remote-codex", "sessions", "remote.jsonl"), "cli", now.AddMinutes(-1), 2);
    using var reader = new CodexUsageReader(fixture.Store, Path.Combine(fixture.Root, "missing-local"));
    reader.Refresh();
    Equal(55d, fixture.Percent(snapshot), "Old remote session must not overwrite newer snapshot");
    Equal(false, fixture.Store.IsNotOlder(snapshot, now.AddMinutes(-1)), "Older observation rejected");
    Equal(true, fixture.Store.IsNotOlder(snapshot, now), "Equal observation accepted");
    Equal(true, fixture.Store.IsNotOlder(snapshot, now.AddMinutes(1)), "Newer observation accepted");
}

static void Settings()
{
    using var fixture = new Workspace();
    var store = new DisplaySettingsStore(fixture.Root);
    Equal("default", store.Load().ClaudeUserEnvironment, "Missing settings use defaults");
    fixture.Store.Write("display-settings.json", new
    {
        claude_custom_path = "C:\\legacy\\plan-usage-history.json", claude_custom_group = "Group 3",
        claude_cli_group = "hidden", claude_user_environment = "self"
    });
    var legacy = store.Load();
    Equal("3", legacy.ClaudeCustomSources[0].Group, "Legacy custom path migration");
    Equal("Hidden", legacy.ClaudeCliGroup, "Case-insensitive hidden");
    Equal("default", legacy.ClaudeUserEnvironment, "Legacy environment migration");
    var source = new ConfiguredSource("SSH", "", "12", "user", "host", 2222, "C:\\key", "~/sessions", "C:\\profile");
    var settings = legacy with { CodexSshSources = new[] { source }, ClaudeUserEnvironment = "Work" };
    store.Save(settings);
    var loaded = store.Load();
    Equal(source, loaded.CodexSshSources[0], "All source fields survive round trip");
    Equal("Work", loaded.ClaudeUserEnvironment, "Custom environment survives round trip");
    Equal("host", fixture.Read("remote-sources.json").GetProperty("sources")[0].GetProperty("host").GetString(), "Remote reader settings emitted");
    Equal(1, fixture.Read("claude-custom-source.json").GetProperty("sources").GetArrayLength(), "Custom reader settings emitted");
    File.WriteAllText(Path.Combine(fixture.Root, "display-settings.json"), "{broken");
    Equal("default", store.Load().ClaudeUserEnvironment, "Malformed settings use defaults");
}

static void ConcurrentWrites()
{
    using var fixture = new Workspace();
    Parallel.For(0, 30, index => fixture.Store.Write("latest.json", new { index, payload = new string('x', 1024) }));
    Equal(1024, fixture.Read("latest.json").GetProperty("payload").GetString()!.Length, "Complete JSON after competing writes");
    Equal(0, Directory.GetFiles(fixture.Root, "*.tmp-*").Length, "Temporary files cleaned up");
}

static string Id(int value) => $"00000000-0000-0000-0000-{value:000000000000}";
static object Api(string organization, double fiveHour, double sevenDay, DateTimeOffset observed) => new
{
    source = "claude-desktop-api-bridge", organization_id = organization,
    observed_at = observed.ToString("O"), percentages = new { five_hour_used = fiveHour, seven_day_used = sevenDay },
    resets_at = new { five_hour_epoch_seconds = DateTimeOffset.UtcNow.AddHours(1).ToUnixTimeSeconds(), seven_day_epoch_seconds = DateTimeOffset.UtcNow.AddDays(1).ToUnixTimeSeconds() }
};
static void WriteApi(SnapshotStore store, string org, double fiveHour, double sevenDay, DateTimeOffset time) => store.Write($"claude-desktop-api-{org}-latest.json", Api(org, fiveHour, sevenDay, time));
static string UsageEvent(DateTimeOffset time, double percent, bool direct = false)
{
    var limits = new { secondary = new { used_percent = percent, window_minutes = 300, resets_at = time.AddHours(1).ToUnixTimeSeconds() }, primary = new { used_percent = percent + 1, window_minutes = 10080, resets_at = time.AddDays(1).ToUnixTimeSeconds() } };
    return direct
        ? JsonSerializer.Serialize(new { timestamp = time.ToString("O"), type = "event_msg", payload = new { type = "token_count" }, rate_limits = limits })
        : JsonSerializer.Serialize(new { timestamp = time.ToString("O"), type = "event_msg", payload = new { type = "token_count", rate_limits = limits } });
}
static void WriteSession(string file, string mode, DateTimeOffset time, double percent, bool direct = false)
{
    Directory.CreateDirectory(Path.GetDirectoryName(file)!);
    File.WriteAllText(file, JsonSerializer.Serialize(new { type = "session_meta", payload = new { source = mode } }) + "\n" + UsageEvent(time, percent, direct) + "\n");
}
static void Equal<T>(T expected, T actual, string reason)
{
    if (!EqualityComparer<T>.Default.Equals(expected, actual)) throw new Exception($"{reason}: expected {expected}, actual {actual}");
}

sealed class Workspace : IDisposable
{
    internal string Root { get; } = Path.Combine(Path.GetTempPath(), "usage-viewer-regression-" + Guid.NewGuid().ToString("N"));
    internal SnapshotStore Store { get; }
    internal Workspace() { Directory.CreateDirectory(Root); Store = new SnapshotStore(Root); }
    internal JsonElement Read(string file) => JsonSerializer.Deserialize<JsonElement>(File.ReadAllText(Path.Combine(Root, file)));
    internal double Percent(string file, string field = "five_hour_used") => Read(file).GetProperty("percentages").GetProperty(field).GetDouble();
    internal string History(string name, string organization, DateTimeOffset time)
    {
        Store.Write(name, new { samples = new[] { new { t = time.ToUnixTimeMilliseconds(), org = organization, u = new { fh = 90, sd = 95 } } } });
        var file = Path.Combine(Root, name);
        File.SetLastWriteTimeUtc(file, time.UtcDateTime);
        return file;
    }
    public void Dispose() => Directory.Delete(Root, recursive: true);
}
