using System.IO;

namespace UsageViewer;

internal static class UsageLog
{
    internal static void TraceClaude(string message)
    {
        try
        {
            var directory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".usage-viewer");
            Directory.CreateDirectory(directory);
            File.AppendAllText(Path.Combine(directory, "claude-usage-command.log"), $"{DateTimeOffset.UtcNow:O} {message}{Environment.NewLine}");
        }
        catch { }
    }

}
