using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Windows;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Threading;

namespace UsageViewer;

public partial class MainWindow : Window
{
    private static readonly IntPtr HwndTopmost = new(-1);
    private const uint SwpNoSize = 0x0001;
    private const uint SwpNoMove = 0x0002;
    private const uint SwpNoActivate = 0x0010;
    private const uint SwpNoOwnerZOrder = 0x0200;

    private readonly string _home = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".usage-viewer");
    private readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromSeconds(1) };
    private readonly UsageReaderService _reader = new();

    public MainWindow()
    {
        InitializeComponent();
        LoadWindowState();
        SourceInitialized += (_, _) => EnsureTopmost();
        Activated += (_, _) => EnsureTopmost();
        Deactivated += (_, _) => Dispatcher.BeginInvoke(EnsureTopmost, DispatcherPriority.Background);
        _timer.Tick += (_, _) =>
        {
            Refresh();
            EnsureTopmost();
        };
        _timer.Start();
        Refresh();
    }

    private void Refresh()
    {
        var claude = Read("claude-app-latest.json");
        var codex = Read("codex-app-latest.json");
        var lines = new List<string>();
        if (claude is not null) lines.Add($"Claude  {ClaudeUsageLine(claude)}");
        if (codex is not null) lines.Add($"Codex   {CodexUsageLine(codex)}");
        MainText.Text = lines.Count == 0 ? "Waiting for usage..." : string.Join("\n", lines);
        DetailText.Text = AllDetails(claude, codex);
    }

    private JsonElement? Read(string name)
    {
        try
        {
            var path = Path.Combine(_home, name);
            if (!File.Exists(path)) return null;
            using var document = JsonDocument.Parse(File.ReadAllText(path));
            return document.RootElement.Clone();
        }
        catch { return null; }
    }

    private static string Percent(JsonElement? root, string name)
    {
        if (root is null || !root.Value.TryGetProperty("percentages", out var percentages) || !percentages.TryGetProperty(name, out var value) || value.ValueKind != JsonValueKind.Number) return "?";
        return $"{value.GetDouble():0.##}%";
    }

    private static string ClaudeUsageLine(JsonElement? root)
    {
        var fiveHour = Percent(root, "five_hour_used");
        var sevenDay = Percent(root, "seven_day_used");
        return $"7d {sevenDay}  |  5h {fiveHour}";
    }

    private static string CodexUsageLine(JsonElement? root)
    {
        var weekly = Percent(root, "seven_day_used");
        var fiveHour = Percent(root, "five_hour_used");
        var parts = new List<string>();
        if (weekly != "?") parts.Add($"7d {weekly}");
        if (fiveHour != "?") parts.Add($"5h {fiveHour}");
        if (parts.Count > 0) return string.Join("  |  ", parts);
        return "usage unavailable";
    }

    private static string CodexSourceSuffix(JsonElement? root)
    {
        if (root is not null && root.Value.TryGetProperty("source_mode", out var mode) && mode.ValueKind == JsonValueKind.String)
        {
            return mode.GetString() == "cli" ? "(C)" : "(D)";
        }
        return "";
    }

    private static string ClaudeSourceSuffix(JsonElement? root)
    {
        if (root is null) return "";
        if (root.Value.TryGetProperty("source_mode", out var mode) && mode.ValueKind == JsonValueKind.String)
        {
            return mode.GetString() == "cli" ? "(C)" : mode.GetString() == "desktop" ? "(D)" : "";
        }
        if (!root.Value.TryGetProperty("source", out var source) || source.ValueKind != JsonValueKind.String) return "";
        return source.GetString() == "claude-code-statusline" ? "(C)" : "(D)";
    }

    private static string ClaudeDetails(JsonElement? root)
    {
        if (root is null) return "";
        var parts = new List<string>();
        var sevenDay = Reset(root.Value, "seven_day_epoch_seconds", "7d", relative: false);
        var fiveHour = Reset(root.Value, "five_hour_epoch_seconds", "5h", relative: false);
        if (!string.IsNullOrWhiteSpace(sevenDay)) parts.Add(sevenDay);
        if (!string.IsNullOrWhiteSpace(fiveHour)) parts.Add(fiveHour);
        var age = Age(root);
        if (!string.IsNullOrWhiteSpace(age)) parts.Add(age);
        return string.Join(" | ", parts);
    }

    private static string CodexDetails(JsonElement? root)
    {
        if (root is null) return "";
        var parts = new List<string>();
        var sevenDay = Reset(root.Value, "seven_day_epoch_seconds", "7d", relative: false);
        var fiveHour = Reset(root.Value, "five_hour_epoch_seconds", "5h", relative: false);
        if (!string.IsNullOrWhiteSpace(sevenDay)) parts.Add(sevenDay);
        if (!string.IsNullOrWhiteSpace(fiveHour)) parts.Add(fiveHour);
        var age = Age(root);
        if (!string.IsNullOrWhiteSpace(age)) parts.Add(age);
        return string.Join(" | ", parts);
    }

    private static string AllDetails(JsonElement? claude, JsonElement? codex)
    {
        var lines = new List<string>();
        var claudeDetails = ClaudeDetails(claude);
        var codexDetails = CodexDetails(codex);
        if (!string.IsNullOrWhiteSpace(claudeDetails)) lines.Add($"Claude  {claudeDetails}  {ClaudeSourceSuffix(claude)}");
        if (!string.IsNullOrWhiteSpace(codexDetails)) lines.Add($"Codex   {codexDetails}  {CodexSourceSuffix(codex)}");
        return string.Join("\n", lines);
    }

    private static string Reset(JsonElement root, string name, string label, bool relative)
    {
        if (!root.TryGetProperty("resets_at", out var resets) ||
            !resets.TryGetProperty(name, out var value) ||
            value.ValueKind != JsonValueKind.Number ||
            !value.TryGetInt64(out var epochSeconds)) return "";

        var time = DateTimeOffset.FromUnixTimeSeconds(epochSeconds);
        if (time <= DateTimeOffset.UtcNow) return "";
        var estimated = false;
        if (root.TryGetProperty("reset_is_estimated", out var estimates))
        {
            var estimateName = name.StartsWith("five_hour", StringComparison.Ordinal) ? "five_hour" : "seven_day";
            estimated = estimates.TryGetProperty(estimateName, out var flag) && flag.ValueKind == JsonValueKind.True;
        }

        var prefix = estimated ? "~" : "";
        if (!relative)
        {
            var format = label == "5h" ? "HH:mm" : "ddd HH:mm";
            return $"{prefix}{time.ToLocalTime().ToString(format, CultureInfo.InvariantCulture)}";
        }

        var remaining = time - DateTimeOffset.UtcNow;
        var hours = (int)remaining.TotalHours;
        var minutes = Math.Max(0, remaining.Minutes);
        return $"{label} reset {prefix}in {hours}h {minutes}m";
    }

    private static string Age(JsonElement? root)
    {
        if (root is null) return "";
        string? timestamp = null;
        if (root.Value.TryGetProperty("observed_at", out var observed) && observed.ValueKind == JsonValueKind.String) timestamp = observed.GetString();
        if (DateTimeOffset.TryParse(timestamp, out var time))
        {
            var age = DateTimeOffset.Now - time;
            if (age.TotalMinutes < 1) return $"{Math.Max(0, (int)age.TotalSeconds)}s ago";
            if (age.TotalHours < 1) return $"{(int)age.TotalMinutes}m ago";
            return $"{(int)age.TotalHours}h ago";
        }
        return "";
    }

    private void OnMouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (e.ButtonState == MouseButtonState.Pressed) DragMove();
    }

    private void OnCloseClick(object sender, RoutedEventArgs e)
    {
        Close();
    }

    private void EnsureTopmost()
    {
        var handle = new WindowInteropHelper(this).Handle;
        if (handle == IntPtr.Zero) return;

        Topmost = true;
        SetWindowPos(
            handle,
            HwndTopmost,
            0,
            0,
            0,
            0,
            SwpNoSize | SwpNoMove | SwpNoActivate | SwpNoOwnerZOrder);
    }

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetWindowPos(
        IntPtr hWnd,
        IntPtr hWndInsertAfter,
        int x,
        int y,
        int width,
        int height,
        uint flags);

    protected override void OnClosed(EventArgs e)
    {
        SaveWindowState();
        _timer.Stop();
        _reader.Dispose();
        base.OnClosed(e);
    }

    private void LoadWindowState()
    {
        try
        {
            var path = Path.Combine(_home, "window-state.json");
            if (!File.Exists(path)) return;
            using var document = JsonDocument.Parse(File.ReadAllText(path));
            var root = document.RootElement;
            if (root.TryGetProperty("left", out var left)) Left = left.GetDouble();
            else if (root.TryGetProperty("x", out var x)) Left = x.GetDouble();
            if (root.TryGetProperty("top", out var top)) Top = top.GetDouble();
            else if (root.TryGetProperty("y", out var y)) Top = y.GetDouble();
        }
        catch { }
    }

    private void SaveWindowState()
    {
        try
        {
            Directory.CreateDirectory(_home);
            var state = new { left = Left, top = Top };
            File.WriteAllText(Path.Combine(_home, "window-state.json"), JsonSerializer.Serialize(state));
        }
        catch { }
    }
}
