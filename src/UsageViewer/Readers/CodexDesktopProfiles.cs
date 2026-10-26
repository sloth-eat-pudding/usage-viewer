using System.IO;
using System.Text.Json;
using static UsageViewer.JsonValues;

namespace UsageViewer;

internal static class CodexDesktopProfiles
{
    internal static JsonElement? ReadFresh(string path, string? profileId = null)
    {
        try
        {
            using var document = JsonDocument.Parse(File.ReadAllText(path));
            var root = document.RootElement;
            if (StringOrNull(root, "source") != "codex-desktop-bridge" ||
                (profileId is not null && StringOrNull(root, "profile_id") != profileId) ||
                !DateTimeOffset.TryParse(StringOrNull(root, "observed_at"), out var time)) return null;
            var age = DateTimeOffset.UtcNow - time;
            return age >= TimeSpan.FromSeconds(-5) && age < TimeSpan.FromSeconds(90) ? root.Clone() : null;
        }
        catch { return null; }
    }

    internal static IReadOnlyList<(string Name, string Id, JsonElement Snapshot)> ReadAccounts(string home)
    {
        var result = new List<(string, string, JsonElement)>();
        try
        {
            using var registry = JsonDocument.Parse(File.ReadAllText(Path.Combine(home, "codex-account-profile-ui.json")));
            foreach (var profile in registry.RootElement.GetProperty("profiles").EnumerateArray())
            {
                var id = StringOrNull(profile, "id");
                if (string.IsNullOrEmpty(id) || id == "default" || id.Any(c => !char.IsAsciiLetterOrDigit(c) && c != '_' && c != '-')) continue;
                var snapshot = ReadFresh(Path.Combine(home, $"codex-account-{id}-latest.json"), id);
                if (snapshot is not null) result.Add((StringOrNull(profile, "name") ?? id, id, snapshot.Value));
            }
        }
        catch { }
        return result;
    }
}
