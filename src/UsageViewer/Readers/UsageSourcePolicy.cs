using System.IO;
using System.Text.Json;

namespace UsageViewer;

internal static class UsageSourcePolicy
{
    internal static bool Enabled(string home, string key, string? path = null)
    {
        try
        {
            using var document = JsonDocument.Parse(File.ReadAllText(Path.Combine(home, "display-settings.json")));
            var root = document.RootElement;
            if (path is not null && root.TryGetProperty(key.Replace("_group", "_sources"), out var sources) && sources.ValueKind == JsonValueKind.Array)
                foreach (var source in sources.EnumerateArray())
                    if (source.TryGetProperty("path", out var sourcePath) && string.Equals(sourcePath.GetString(), path, StringComparison.OrdinalIgnoreCase))
                        return !source.TryGetProperty("group", out var group) || !Hidden(group.GetString());
            return !root.TryGetProperty(key, out var value) || !Hidden(value.GetString());
        }
        catch { return true; }
    }

    internal static bool Hidden(string? group) => string.Equals(group?.Trim(), "Hidden", StringComparison.OrdinalIgnoreCase);

    internal static bool OrganizationEnabled(string home, string organization)
    {
        var settings = new DisplaySettingsStore(home).Load();
        var matches = new List<ConfiguredSource>();
        foreach (var source in settings.ClaudeDesktopSources.Concat(settings.ClaudeCustomSources))
        {
            try
            {
                using var history = JsonDocument.Parse(File.ReadAllText(source.Path));
                var latest = history.RootElement.GetProperty("samples").EnumerateArray().OrderByDescending(sample =>
                    sample.TryGetProperty("t", out var t) && t.TryGetInt64(out var number) ? number :
                    sample.TryGetProperty("timestamp", out var timestamp) && DateTimeOffset.TryParse(timestamp.GetString(), out var date) ? date.ToUnixTimeMilliseconds() : 0).FirstOrDefault();
                if (latest.ValueKind == JsonValueKind.Object && latest.TryGetProperty("org", out var org) && org.GetString() == organization) matches.Add(source);
            }
            catch { }
        }
        return matches.Count > 0 ? matches.Any(source => !Hidden(source.Group)) : Enabled(home, "claude_desktop_group");
    }
}
