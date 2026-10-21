using System.Globalization;

namespace UsageViewer;

internal static class DisplayGroups
{
    internal static int GroupNumber(string? value)
    {
        var normalized = NormalizeGroup(value ?? "");
        return int.TryParse(normalized, NumberStyles.None, CultureInfo.InvariantCulture, out var number) && number > 0 ? number : 0;
    }

    internal static string NormalizeGroup(string value)
    {
        if (value.Equals("Hidden", StringComparison.OrdinalIgnoreCase)) return "Hidden";
        if (value.StartsWith("Group ", StringComparison.OrdinalIgnoreCase)) value = value[6..].Trim();
        return int.TryParse(value, NumberStyles.None, CultureInfo.InvariantCulture, out var number) && number > 0 ? number.ToString(CultureInfo.InvariantCulture) : "1";
    }

}
