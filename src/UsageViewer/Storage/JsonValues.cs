using System.Text.Json;

namespace UsageViewer;

internal static class JsonValues
{
    internal static double Number(JsonElement j, string name) => NumberOrNull(j, name) ?? 0;
    internal static double? NumberOrNull(JsonElement j, string name) => j.ValueKind == JsonValueKind.Object && j.TryGetProperty(name, out var p) && p.ValueKind == JsonValueKind.Number && p.TryGetDouble(out var n) ? n : null;
    internal static string? StringOrNull(JsonElement j, string name) => j.ValueKind == JsonValueKind.Object && j.TryGetProperty(name, out var p) && p.ValueKind == JsonValueKind.String ? p.GetString() : null;

    internal static DateTimeOffset? FutureEpoch(double? epochSeconds)
    {
        if (epochSeconds is null) return null;
        var time = DateTimeOffset.FromUnixTimeSeconds((long)epochSeconds.Value);
        return time > DateTimeOffset.UtcNow ? time : null;
    }

    internal static DateTimeOffset? FutureOnly(DateTimeOffset value) => value > DateTimeOffset.UtcNow ? value : null;
    internal static long? ToEpochSeconds(DateTimeOffset? value) => value?.ToUnixTimeSeconds();

}
