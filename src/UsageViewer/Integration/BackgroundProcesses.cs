using System.Diagnostics;
using System.IO;
using System.Text;
using static UsageViewer.UsageLog;

namespace UsageViewer;

internal sealed class BackgroundProcesses : IDisposable
{
    private readonly string _home;
    private Process? _claudeUsageInjectorProcess;
    private Process? _codexUsageProcess;

    internal BackgroundProcesses(string home) => _home = home;
    internal void Start()
    {
        StartCodexDesktopUsage();
        StartClaudeDesktopUsageInjector();
    }

    private void StartCodexDesktopUsage()
    {
        try
        {
            var directory = Path.Combine(_home, "codex-desktop-reader");
            Directory.CreateDirectory(directory);
            foreach (var (resourceName, filename) in new[] {
                ("UsageViewer.WatchCodexDesktopUsage.ps1", "watch-codex-desktop-usage.ps1"),
                ("UsageViewer.UsageSourcePolicy.ps1", "usage-source-policy.ps1"),
                ("UsageViewer.CodexDesktopUsage.cjs", "codex-desktop-usage.cjs"),
                ("UsageViewer.CodexNativeDriver.cjs", "codex-native-meter.cjs"),
                ("UsageViewer.CodexProfileMetrics.cjs", "codex-profile-metrics.cjs") })
            {
                using var resource = typeof(UsageReaderService).Assembly.GetManifestResourceStream(resourceName)
                    ?? throw new InvalidDataException($"Missing {resourceName}");
                using var reader = new StreamReader(resource);
                File.WriteAllText(Path.Combine(directory, filename), reader.ReadToEnd(), new UTF8Encoding(filename.EndsWith(".ps1")));
            }
            _codexUsageProcess = Process.Start(new ProcessStartInfo {
                FileName = "powershell.exe", UseShellExecute = false, CreateNoWindow = true,
                Arguments = $"-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"{Path.Combine(directory, "watch-codex-desktop-usage.ps1")}\""
            });
        }
        catch (Exception error) { TraceClaude($"Codex desktop reader start failed={error.Message}"); }
    }

    private void StartClaudeDesktopUsageInjector()
    {
        if (Environment.GetEnvironmentVariable("CLAUDE_DESKTOP_AUTO_BRIDGE") == "0") return;
        try
        {
            using var resource = typeof(UsageReaderService).Assembly.GetManifestResourceStream("UsageViewer.ClaudeDesktopUsageInjector.ps1");
            if (resource is null) return;
            using var reader = new StreamReader(resource, Encoding.UTF8);
            var script = reader.ReadToEnd();
            var path = Path.Combine(_home, "claude-desktop-usage-injector.ps1");
            Directory.CreateDirectory(_home);
            if (!File.Exists(path) || File.ReadAllText(path) != script) File.WriteAllText(path, script, new UTF8Encoding(false));
            using var profilesResource = typeof(UsageReaderService).Assembly.GetManifestResourceStream("UsageViewer.ClaudeDesktopProfiles.ps1");
            using (var policyResource = typeof(UsageReaderService).Assembly.GetManifestResourceStream("UsageViewer.UsageSourcePolicy.ps1"))
            using (var policyReader = new StreamReader(policyResource ?? throw new InvalidDataException("Usage source policy is missing")))
                File.WriteAllText(Path.Combine(_home, "usage-source-policy.ps1"), policyReader.ReadToEnd(), new UTF8Encoding(false));
            if (profilesResource is null) throw new InvalidDataException("Claude profile discovery script is missing");
            using (var profilesReader = new StreamReader(profilesResource, Encoding.UTF8))
            {
                var profiles = profilesReader.ReadToEnd();
                var profilesPath = Path.Combine(_home, "claude-desktop-profiles.ps1");
                if (!File.Exists(profilesPath) || File.ReadAllText(profilesPath) != profiles)
                    File.WriteAllText(profilesPath, profiles, new UTF8Encoding(false));
            }
            using var meterResource = typeof(UsageReaderService).Assembly.GetManifestResourceStream("UsageViewer.ClaudeSessionMeter.js");
            if (meterResource is not null)
            {
                using var meterReader = new StreamReader(meterResource, Encoding.UTF8);
                var meter = meterReader.ReadToEnd();
                var meterPath = Path.Combine(_home, "claude-session-meter.js");
                if (!File.Exists(meterPath) || File.ReadAllText(meterPath) != meter)
                    File.WriteAllText(meterPath, meter, new UTF8Encoding(false));
            }
            _claudeUsageInjectorProcess = Process.Start(new ProcessStartInfo
            {
                FileName = "powershell.exe",
                Arguments = $"-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"{path}\"",
                UseShellExecute = false,
                CreateNoWindow = true,
                WorkingDirectory = _home
            });
        }
        catch (Exception error) { TraceClaude($"Claude Desktop usage injector start failed={error.Message}"); }
    }


    public void Dispose()
    {
        Stop(_claudeUsageInjectorProcess);
        Stop(_codexUsageProcess);
    }

    private static void Stop(Process? process)
    {
        if (process is null) return;
        try { if (!process.HasExited) FrameworkCompat.KillTree(process); }
        catch { }
        finally { process.Dispose(); }
    }
}
