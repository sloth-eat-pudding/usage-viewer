using System.IO;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace UsageViewer;

internal static class ClaudeSubagentUsage
{
    private static readonly string[] UsageKeys = { "input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens",
        "cache_creation", "server_tool_use", "speed", "service_tier", "inference_geo" };

    internal static object Read(string sessionId, string? projectsRoot = null)
    {
        if (!Guid.TryParseExact(sessionId, "D", out _)) throw new InvalidDataException("Invalid session ID");
        projectsRoot ??= Path.Combine(Environment.GetEnvironmentVariable("CLAUDE_HOME") ??
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".claude"), "projects");
        var agents = new List<object>();
        var complete = true;
        var tools = new HashSet<string>();
        var found = new HashSet<string>();
        object Result() => new { session_id = sessionId, agents, complete, missing = tools.Except(found).Count() };
        try
        {
            var projects = Directory.EnumerateDirectories(projectsRoot).Where(dir =>
                (File.GetAttributes(dir) & FileAttributes.ReparsePoint) == 0 && File.Exists(Path.Combine(dir, sessionId + ".jsonl"))).ToList();
            if (projects.Count != 1) { complete = false; return Result(); }
            var project = Path.GetFullPath(projects[0]);
            string SafeFile(string file)
            {
                var relative = Path.GetRelativePath(project, Path.GetFullPath(file));
                if (relative.StartsWith("..", StringComparison.Ordinal) || Path.IsPathRooted(relative) || new FileInfo(file).Length > 64 * 1024 * 1024)
                    throw new IOException("Unreadable transcript");
                for (var current = Path.GetFullPath(file); current != project; current = Path.GetDirectoryName(current)!)
                    if ((File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0) throw new IOException("Linked transcript");
                return file;
            }
            List<JsonElement> Rows(string file)
            {
                var rows = new List<JsonElement>();
                foreach (var line in File.ReadLines(SafeFile(file)))
                {
                    if (string.IsNullOrWhiteSpace(line)) continue;
                    try
                    {
                        var row = JsonSerializer.Deserialize<JsonElement>(line);
                        if (row.ValueKind == JsonValueKind.Object) rows.Add(row);
                        else complete = false;
                    }
                    catch (JsonException) { complete = false; }
                }
                return rows;
            }
            void CollectTools(IEnumerable<JsonElement> rows)
            {
                foreach (var row in rows)
                {
                    if (Text(row, "sessionId") != sessionId || !row.TryGetProperty("message", out var message) ||
                        !message.TryGetProperty("content", out var blocks) || blocks.ValueKind != JsonValueKind.Array) continue;
                    foreach (var block in blocks.EnumerateArray())
                        if (Text(block, "type") == "tool_use" && Text(block, "name") is "Agent" or "Task" && Text(block, "id") is { } id) tools.Add(id);
                }
            }
            CollectTools(Rows(Path.Combine(project, sessionId + ".jsonl")).Where(row =>
                !row.TryGetProperty("isSidechain", out var sidechain) || sidechain.ValueKind != JsonValueKind.True));
            var candidates = new List<(string Id, string Tool, string File)>();
            foreach (var dir in new[] { project, Path.Combine(project, sessionId, "subagents") })
            {
                if (!Directory.Exists(dir)) continue;
                foreach (var file in Directory.EnumerateFiles(dir, "agent-*.meta.json"))
                {
                    try
                    {
                        var match = Regex.Match(Path.GetFileName(file), @"^agent-([a-z0-9-]+)\.meta\.json$", RegexOptions.IgnoreCase);
                        if (!match.Success) continue;
                        var meta = JsonSerializer.Deserialize<JsonElement>(File.ReadAllText(SafeFile(file)));
                        if (Text(meta, "toolUseId") is { } tool)
                            candidates.Add((match.Groups[1].Value, tool, Path.Combine(dir, $"agent-{match.Groups[1].Value}.jsonl")));
                    }
                    catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException) { complete = false; }
                }
            }
            var seen = new HashSet<string>();
            var progress = true;
            while (progress)
            {
                progress = false;
                foreach (var candidate in candidates)
                {
                    if (!tools.Contains(candidate.Tool) || !seen.Add(candidate.Id)) continue;
                    progress = true;
                    if (seen.Count > 256) { complete = false; continue; }
                    try
                    {
                        var rows = Rows(candidate.File);
                        if (rows.Count == 0 || rows.Any(row => Text(row, "sessionId") is { } sid && sid != sessionId ||
                            Text(row, "agentId") is { } aid && aid != candidate.Id)) { complete = false; continue; }
                        CollectTools(rows);
                        var accounting = new List<object>();
                        foreach (var row in rows)
                        {
                            if (Text(row, "type") != "assistant" || !row.TryGetProperty("message", out var message) ||
                                !message.TryGetProperty("usage", out var usage) || usage.ValueKind != JsonValueKind.Object) continue;
                            accounting.Add(new { type = "assistant", sessionId = sessionId + ":" + candidate.Id,
                                timestamp = Text(row, "timestamp"), uuid = Text(row, "uuid"), requestId = Text(row, "requestId"),
                                message = new { id = Text(message, "id"), model = Text(message, "model"),
                                    usage = usage.EnumerateObject().Where(p => UsageKeys.Contains(p.Name)).ToDictionary(p => p.Name, p => p.Value) } });
                        }
                        agents.Add(new { id = candidate.Id, rows = accounting });
                        found.Add(candidate.Tool);
                    }
                    catch (Exception error) when (error is IOException or UnauthorizedAccessException) { complete = false; }
                }
            }
            if (tools.Except(found).Any()) complete = false;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { complete = false; }
        return Result();
    }

    private static string? Text(JsonElement element, string name) => element.ValueKind == JsonValueKind.Object &&
        element.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;
}
