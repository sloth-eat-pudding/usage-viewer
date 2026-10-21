using System.IO;
using System.Text.Json;

namespace UsageViewer;

internal sealed class DisplaySettingsStore
{
    private readonly string _home;
    internal DisplaySettingsStore(string home) => _home = home;

    internal DisplaySettings Load()
    {
        try
        {
            var path = Path.Combine(_home, "display-settings.json");
            if (!File.Exists(path)) return DisplaySettings.Default;
            using var document = JsonDocument.Parse(File.ReadAllText(path));
            return DisplaySettings.FromJson(document.RootElement);
        }
        catch { return DisplaySettings.Default; }
    }


    internal void Save(DisplaySettings settings)
    {
        try
        {
            Directory.CreateDirectory(_home);
            File.WriteAllText(Path.Combine(_home, "display-settings.json"), JsonSerializer.Serialize(settings.ToStorage(), new JsonSerializerOptions { WriteIndented = true }));
            File.WriteAllText(Path.Combine(_home, "claude-custom-source.json"), JsonSerializer.Serialize(new { sources = settings.ClaudeCustomSources }, new JsonSerializerOptions { WriteIndented = true }));
            File.WriteAllText(Path.Combine(_home, "remote-sources.json"), JsonSerializer.Serialize(new { sources = settings.CodexSshSources }, new JsonSerializerOptions { WriteIndented = true }));
        }
        catch { }
    }

}
