using System.IO;
using System.Text.Json;
using static UsageViewer.JsonValues;

namespace UsageViewer;

internal sealed record ClaudeDesktopApiUsage(DateTimeOffset ObservedAt, double? FiveHourUsed, double? SevenDayUsed, DateTimeOffset? FiveHourReset, DateTimeOffset? SevenDayReset)
{
    internal static ClaudeDesktopApiUsage? Read(string home, string? organizationId)
    {
        if (string.IsNullOrWhiteSpace(organizationId)) return null;
        try
        {
            var path = Path.Combine(home, $"claude-desktop-api-{organizationId}-latest.json");
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

}
