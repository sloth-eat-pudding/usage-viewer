using System.IO;

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
}
