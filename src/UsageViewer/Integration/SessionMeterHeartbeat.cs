using System.IO;
using System.Text.Json;
using System.Text.RegularExpressions;
using static UsageViewer.JsonValues;

namespace UsageViewer;

internal static class SessionMeterHeartbeat
{
    internal static object Normalize(JsonElement data, string instance, DateTimeOffset now)
    {
        var version = StringOrNull(data, "version") ?? "";
        var refreshId = StringOrNull(data, "refresh_id") ?? "";
        if (!Regex.IsMatch(instance, @"^\d{1,10}-\d{1,20}$") ||
            !Regex.IsMatch(version, @"^\d+\.\d+\.\d+$") || !Guid.TryParseExact(refreshId, "D", out _))
            throw new InvalidDataException("Invalid meter heartbeat");
        return new { source = "claude-session-meter", instance, version, refresh_id = refreshId, observed_at = now.ToString("O") };
    }
}
