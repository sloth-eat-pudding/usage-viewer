using System.Globalization;
using System.IO;
using System.Text.Json;
using static UsageViewer.JsonValues;

namespace UsageViewer;

// Keep this contract aligned with readers/claude-usage-contract.js. Both
// implementations run against the fixtures in tests/fixtures/claude-usage.json.
internal static class ClaudeUsageContract
{
    internal static object Normalize(JsonElement root, string organizationId, DateTimeOffset now, string? refreshId = null)
    {
        var fiveHour = ReadWindow(root, "session", "five_hour");
        var sevenDay = ReadWindow(root, "weekly_all", "seven_day");
        if (fiveHour.Used is null && sevenDay.Used is null)
            throw new InvalidDataException("Expected a Claude Desktop usage response");

        return new
        {
            generated_at = now.ToString("O"), observed_at = now.ToString("O"),
            source = "claude-desktop-api-bridge", source_mode = "desktop", organization_id = organizationId,
            refresh_id = refreshId,
            percentages = new { five_hour_used = fiveHour.Used, seven_day_used = sevenDay.Used },
            resets_at = new { five_hour_epoch_seconds = ToEpochSeconds(fiveHour.Reset), seven_day_epoch_seconds = ToEpochSeconds(sevenDay.Reset) }
        };
    }

    private static (double? Used, DateTimeOffset? Reset) ReadWindow(JsonElement root, string kind, string legacyName)
    {
        var legacy = root.ValueKind == JsonValueKind.Object && root.TryGetProperty(legacyName, out var value) ? value : default;
        var used = Percentage(legacy, "utilization");
        DateTimeOffset? reset = DateTimeOffset.TryParse(StringOrNull(legacy, "resets_at"), out var parsed) ? parsed : null;
        if (root.ValueKind == JsonValueKind.Object && root.TryGetProperty("limits", out var limits) && limits.ValueKind == JsonValueKind.Array)
        {
            foreach (var limit in limits.EnumerateArray())
            {
                if (StringOrNull(limit, "kind") != kind) continue;
                used = Percentage(limit, "percent") ?? used;
                if (DateTimeOffset.TryParse(StringOrNull(limit, "resets_at"), out var canonicalReset)) reset = canonicalReset;
                break;
            }
        }
        return (used, reset);
    }

    private static double? Percentage(JsonElement root, string name)
    {
        var number = NumberOrNull(root, name);
        if (number is null && double.TryParse(StringOrNull(root, name), NumberStyles.Float, CultureInfo.InvariantCulture, out var parsed))
            number = parsed;
        return number is >= 0 and <= 100 ? number : null;
    }
}
