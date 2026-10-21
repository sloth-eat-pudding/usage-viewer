using System.Text.Json;
using System.Text.Json.Serialization;
using static UsageViewer.DisplayGroups;

namespace UsageViewer;

internal sealed record ConfiguredSource(
    [property: JsonPropertyName("name")] string Name,
    [property: JsonPropertyName("path")] string Path,
    [property: JsonPropertyName("group")] string Group,
    [property: JsonPropertyName("user")] string User = "",
    [property: JsonPropertyName("host")] string Host = "",
    [property: JsonPropertyName("port")] int Port = 22,
    [property: JsonPropertyName("key_path")] string KeyPath = "",
    [property: JsonPropertyName("sessions_path")] string SessionsPath = "~/.codex/sessions",
    [property: JsonPropertyName("profile_path")] string ProfilePath = "");
internal sealed record DisplaySettings(IReadOnlyList<ConfiguredSource> ClaudeDesktopSources, string ClaudeCliGroup, IReadOnlyList<ConfiguredSource> ClaudeCustomSources, string CodexDesktopGroup, string CodexCliGroup, IReadOnlyList<ConfiguredSource> CodexSshSources, string ClaudeUserEnvironment)
{
    public string ClaudeDesktopGroup => ClaudeDesktopSources.FirstOrDefault()?.Group ?? "1";
    public string ClaudeCustomPath => ClaudeCustomSources.FirstOrDefault()?.Path ?? "";
    public string ClaudeCustomGroup => ClaudeCustomSources.FirstOrDefault()?.Group ?? "1";
    public string CodexSshGroup => CodexSshSources.FirstOrDefault()?.Group ?? "2";
    public static DisplaySettings Default { get; } = new(Array.Empty<ConfiguredSource>(), "1", Array.Empty<ConfiguredSource>(), "1", "1", Array.Empty<ConfiguredSource>(), "default");
    public static DisplaySettings FromJson(JsonElement root) => new(
        Sources(root, "claude_desktop_sources", null, "claude_desktop_group", "Desktop"), Group(root, "claude_cli_group", "1"), Sources(root, "claude_custom_sources", "claude_custom_path", "claude_custom_group", "Custom"),
        Group(root, "codex_desktop_group", "1"), Group(root, "codex_cli_group", "1"), Sources(root, "codex_ssh_sources", null, "codex_ssh_group", "SSH"), Environment(root));
    public object ToStorage() => new { claude_desktop_group = ClaudeDesktopGroup, claude_desktop_sources = ClaudeDesktopSources, claude_cli_group = ClaudeCliGroup, claude_custom_sources = ClaudeCustomSources, codex_desktop_group = CodexDesktopGroup, codex_cli_group = CodexCliGroup, codex_ssh_sources = CodexSshSources, claude_user_environment = ClaudeUserEnvironment };
    private static string String(JsonElement root, string name) => root.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() ?? "" : "";
    private static string Group(JsonElement root, string name, string fallback) { var value = String(root, name); return string.IsNullOrWhiteSpace(value) ? fallback : NormalizeGroup(value); }
    private static IReadOnlyList<ConfiguredSource> Sources(JsonElement root, string arrayName, string? legacyPathName, string legacyGroupName, string defaultName)
    {
        var result = new List<ConfiguredSource>();
        if (root.TryGetProperty(arrayName, out var array) && array.ValueKind == JsonValueKind.Array)
            foreach (var item in array.EnumerateArray())
            {
                var path = String(item, "path");
                var name = String(item, "name");
                var group = Group(item, "group", "1");
                var user = String(item, "user");
                var host = String(item, "host");
                var keyPath = String(item, "key_path");
                var sessionsPath = String(item, "sessions_path");
                var profilePath = String(item, "profile_path");
                var port = item.TryGetProperty("port", out var portValue) && portValue.TryGetInt32(out var parsedPort) ? parsedPort : 22;
                if (!string.IsNullOrWhiteSpace(path) || legacyPathName is null) result.Add(new(name, path, group, user, host, port, keyPath, string.IsNullOrWhiteSpace(sessionsPath) ? "~/.codex/sessions" : sessionsPath, profilePath));
            }
        if (result.Count == 0 && legacyPathName is not null)
        {
            var path = String(root, legacyPathName);
            if (!string.IsNullOrWhiteSpace(path)) result.Add(new(defaultName + " 1", path, Group(root, legacyGroupName, "1")));
        }
        return result;
    }
    private static string Environment(JsonElement root) { var value = String(root, "claude_user_environment"); return string.IsNullOrWhiteSpace(value) || value.Equals("self", StringComparison.OrdinalIgnoreCase) ? "default" : value; }
}
