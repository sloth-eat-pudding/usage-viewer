using System.IO;
using System.Text.Json;

namespace UsageViewer;

internal static class ClaudeDesktopProfiles
{
    internal sealed record Profile(string Name, string Path, string LegacyPath, string Group);

    internal static IReadOnlyList<Profile> Find(string? appData = null, string? localAppData = null)
    {
        appData ??= Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        localAppData ??= Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        var result = new List<Profile>();
        var regular = System.IO.Path.Combine(appData, "Claude", "plan-usage-history.json");
        if (File.Exists(regular)) result.Add(new("Claude Desktop (AppData)", regular, regular, "1"));
        var families = new SortedDictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var migrated in new[] { true, false })
        {
            var root = System.IO.Path.Combine(localAppData, migrated ? "Claude-Data" : "Packages");
            try
            {
                if (!Directory.Exists(root)) continue;
                foreach (var directory in Directory.EnumerateDirectories(root, "*"))
                {
                    var family = System.IO.Path.GetFileName(directory);
                    if (!family.StartsWith("claude_", StringComparison.OrdinalIgnoreCase)) continue;
                    var history = migrated ? System.IO.Path.Combine(directory, "plan-usage-history.json")
                        : System.IO.Path.Combine(directory, "LocalCache", "Roaming", "Claude", "plan-usage-history.json");
                    if (File.Exists(history) && !families.ContainsKey(family)) families.Add(family, history);
                }
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
        var index = 0;
        foreach (var entry in families)
        {
            var (family, history) = (entry.Key, entry.Value);
            index++;
            result.Add(new($"Claude Desktop (MSIX {index})", history,
                System.IO.Path.Combine(localAppData, "Packages", family, "LocalCache", "Roaming", "Claude", "plan-usage-history.json"),
                (index + 1).ToString(System.Globalization.CultureInfo.InvariantCulture)));
        }
        return result;
    }

    // Detected profiles, or, when none exist, the explicit organization
    // mappings the script readers also fall back to.
    internal static IReadOnlyList<Profile> FindWithMappings(string? home = null)
    {
        var detected = Find();
        if (detected.Count > 0) return detected;
        return Mappings(home).Select((mapping, index) =>
            new Profile($"Claude Desktop (mapped {index + 1})", mapping.Path, mapping.Path, (index + 1).ToString(System.Globalization.CultureInfo.InvariantCulture))).ToList();
    }

    // A saved path from before the Claude-Data migration still names the same profile.
    internal static string Resolve(string path, IReadOnlyList<Profile>? profiles = null)
    {
        foreach (var profile in profiles ?? Find())
            if (path.Equals(profile.Path, StringComparison.OrdinalIgnoreCase) || path.Equals(profile.LegacyPath, StringComparison.OrdinalIgnoreCase))
                return profile.Path;
        return path;
    }

    internal static string? MappedOrganization(string path, string? home = null) =>
        Mappings(home).FirstOrDefault(mapping => mapping.Path.Equals(path, StringComparison.OrdinalIgnoreCase)).OrganizationId;

    // config\claude-profile-organizations.json maps a profile's history path to
    // its organization so a missing history file can still pair with the
    // Desktop API snapshot. Only explicit mappings are used, never a guess.
    internal static IReadOnlyList<(string Path, string OrganizationId)> Mappings(string? home = null)
    {
        home ??= Environment.GetEnvironmentVariable("USAGE_VIEWER_HOME") is { Length: > 0 } configured
            ? configured
            : System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".usage-viewer");
        var candidates = new[]
        {
            System.IO.Path.Combine(home, "claude-profile-organizations.json"),
            System.IO.Path.Combine(AppContext.BaseDirectory, "config", "claude-profile-organizations.json"),
            System.IO.Path.Combine(AppContext.BaseDirectory, "..", "config", "claude-profile-organizations.json")
        };
        foreach (var candidate in candidates)
        {
            try
            {
                if (!File.Exists(candidate)) continue;
                using var document = JsonDocument.Parse(File.ReadAllText(candidate));
                if (!document.RootElement.TryGetProperty("sources", out var sources) || sources.ValueKind != JsonValueKind.Array) continue;
                var result = new List<(string, string)>();
                foreach (var source in sources.EnumerateArray())
                {
                    var path = JsonValues.StringOrNull(source, "path");
                    var organization = JsonValues.StringOrNull(source, "organization_id");
                    if (!string.IsNullOrWhiteSpace(path) && !string.IsNullOrWhiteSpace(organization)) result.Add((path!, organization!));
                }
                return result;
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
            catch (JsonException) { }
        }
        return Array.Empty<(string, string)>();
    }
}
