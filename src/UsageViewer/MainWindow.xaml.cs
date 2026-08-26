using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Threading;
using Microsoft.Win32;

namespace UsageViewer;

public partial class MainWindow : Window
{
    private static readonly IntPtr HwndTopmost = new(-1);
    private const uint SwpNoSize = 0x0001;
    private const uint SwpNoMove = 0x0002;
    private const uint SwpNoActivate = 0x0010;
    private const uint SwpNoOwnerZOrder = 0x0200;
    private const int WmNcHitTest = 0x0084;
    private const nint HtTransparent = -1;
    private const nint HtClient = 1;

    private readonly string _home = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".usage-viewer");
    private readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromSeconds(1) };
    private readonly UsageReaderService _reader = new();
    private DisplaySettings _displaySettings = DisplaySettings.Default;
    private HwndSource? _windowSource;
    private bool _isPinned;

    public MainWindow()
    {
        InitializeComponent();
        LoadWindowState();
        LoadDisplaySettings();
        SourceInitialized += (_, _) =>
        {
            _windowSource = HwndSource.FromHwnd(new WindowInteropHelper(this).Handle);
            _windowSource?.AddHook(WindowMessageHook);
            EnsureTopmost();
        };
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
        var lines = new List<string>();
        var details = new List<string>();
        AppendGroupedUsage(lines, details, "Claude", ClaudeSources(), ClaudeUsageLine, ClaudeDetails);
        AppendGroupedUsage(lines, details, "Codex", CodexSources(), CodexUsageLine, CodexDetails);
        MainText.Text = lines.Count == 0 ? "Waiting for usage..." : string.Join("\n", lines);
        DetailText.Text = string.Join("\n", details);
    }

    private List<UsageSource> ClaudeSources() => new()
    {
        new("D", _displaySettings.ClaudeDesktopGroup, Read("claude-desktop-latest.json")),
        new("C", _displaySettings.ClaudeCliGroup, Read("claude-statusline-latest.json")),
        new("Custom", _displaySettings.ClaudeCustomGroup, string.IsNullOrWhiteSpace(_displaySettings.ClaudeCustomPath) ? null : Read("claude-custom-latest.json"))
    };

    private List<UsageSource> CodexSources() => new()
    {
        new("D", _displaySettings.CodexDesktopGroup, Read("codex-desktop-latest.json")),
        new("C", _displaySettings.CodexCliGroup, Read("codex-cli-latest.json")),
        new("SSH", _displaySettings.CodexSshGroup, Read("codex-remote-latest.json"))
    };

    private static void AppendGroupedUsage(
        List<string> lines,
        List<string> details,
        string product,
        IEnumerable<UsageSource> sources,
        Func<JsonElement?, string> usageLine,
        Func<JsonElement?, string> detailLine)
    {
        foreach (var group in sources
            .Where(source => source.Snapshot is not null && source.Group != "Hidden")
            .GroupBy(source => source.Group)
            .OrderBy(group => group.Key, StringComparer.Ordinal))
        {
            var newest = group.OrderByDescending(source => Timestamp(source.Snapshot)).First();
            var labels = string.Join("+", group.Select(source => source.Label));
            lines.Add($"{product,-6}{usageLine(newest.Snapshot)}  ({labels})");
            var detail = detailLine(newest.Snapshot);
            if (!string.IsNullOrWhiteSpace(detail)) details.Add($"{product,-6}{detail}  ({labels})");
        }
    }

    private static DateTimeOffset Timestamp(JsonElement? root)
    {
        if (root is not null)
        {
            foreach (var name in new[] { "observed_at", "generated_at" })
                if (root.Value.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String && DateTimeOffset.TryParse(value.GetString(), out var timestamp))
                    return timestamp;
        }
        return DateTimeOffset.MinValue;
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
        if (root is null || !root.Value.TryGetProperty("percentages", out var percentages) || !percentages.TryGetProperty(name, out var value) || value.ValueKind != JsonValueKind.Number) return "-";
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
        return $"7d {weekly}  |  5h {fiveHour}";
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
        if (!_isPinned && e.ButtonState == MouseButtonState.Pressed) DragMove();
    }

    private void OnPinClick(object sender, RoutedEventArgs e)
    {
        _isPinned = !_isPinned;
        PinButton.Content = _isPinned ? "U" : "P";
        PinButton.ToolTip = _isPinned ? "解除釘選" : "釘選並讓其他區域點擊穿透";
        PinButton.Background = _isPinned
            ? new System.Windows.Media.SolidColorBrush(System.Windows.Media.Color.FromRgb(45, 75, 45))
            : System.Windows.Media.Brushes.Transparent;
        OverlayBorder.Background = _isPinned ? System.Windows.Media.Brushes.Transparent : new System.Windows.Media.SolidColorBrush(System.Windows.Media.Color.FromArgb(232, 23, 23, 23));
        OverlayBorder.BorderBrush = _isPinned ? System.Windows.Media.Brushes.Transparent : System.Windows.Media.Brushes.DimGray;
        SettingsButton.Visibility = _isPinned ? Visibility.Collapsed : Visibility.Visible;
        CloseButton.Visibility = _isPinned ? Visibility.Collapsed : Visibility.Visible;
        EnsureTopmost();
    }

    private nint WindowMessageHook(nint hwnd, int message, nint wParam, nint lParam, ref bool handled)
    {
        if (!_isPinned || message != WmNcHitTest) return IntPtr.Zero;
        var x = unchecked((short)(long)lParam);
        var y = unchecked((short)((long)lParam >> 16));
        var pinTopLeft = PinButton.PointToScreen(new Point(0, 0));
        var pinBounds = new Rect(pinTopLeft, new Size(PinButton.ActualWidth, PinButton.ActualHeight));
        handled = true;
        return pinBounds.Contains(new Point(x, y)) ? HtClient : HtTransparent;
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
        _windowSource?.RemoveHook(WindowMessageHook);
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

    private void LoadDisplaySettings()
    {
        try
        {
            var path = Path.Combine(_home, "display-settings.json");
            if (!File.Exists(path)) return;
            using var document = JsonDocument.Parse(File.ReadAllText(path));
            _displaySettings = DisplaySettings.FromJson(document.RootElement);
        }
        catch { _displaySettings = DisplaySettings.Default; }
    }

    private void OnSettingsClick(object sender, RoutedEventArgs e)
    {
        var dialog = new Window
        {
            Title = "Usage Viewer Settings", Owner = this, WindowStartupLocation = WindowStartupLocation.CenterOwner,
            SizeToContent = SizeToContent.WidthAndHeight, ResizeMode = ResizeMode.NoResize,
            Background = System.Windows.Media.Brushes.Transparent, WindowStyle = WindowStyle.None, AllowsTransparency = true,
            Topmost = true, ShowInTaskbar = false
        };
        var panel = new StackPanel { Margin = new Thickness(16), Width = 340 };
        var border = new Border { Background = new System.Windows.Media.SolidColorBrush(System.Windows.Media.Color.FromRgb(23, 23, 23)), BorderBrush = System.Windows.Media.Brushes.DimGray, BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(8), Child = panel };
        dialog.Content = border;
        var dialogTitle = new TextBlock { Text = "Display settings", Foreground = System.Windows.Media.Brushes.White, FontWeight = FontWeights.Bold, FontSize = 15, Margin = new Thickness(0, 0, 0, 12), Cursor = Cursors.SizeAll };
        dialogTitle.MouseLeftButtonDown += (_, args) => { if (args.LeftButton == MouseButtonState.Pressed) dialog.DragMove(); };
        panel.Children.Add(dialogTitle);

        var claudeDesktop = AddGroupSelector(panel, "Claude Desktop", _displaySettings.ClaudeDesktopGroup);
        var claudeCli = AddGroupSelector(panel, "Claude CLI", _displaySettings.ClaudeCliGroup);
        var claudeCustom = AddGroupSelector(panel, "Claude Custom", _displaySettings.ClaudeCustomGroup);
        var customPath = new TextBlock { Text = string.IsNullOrWhiteSpace(_displaySettings.ClaudeCustomPath) ? "No custom source selected" : _displaySettings.ClaudeCustomPath, Foreground = System.Windows.Media.Brushes.LightGray, TextTrimming = TextTrimming.CharacterEllipsis, ToolTip = _displaySettings.ClaudeCustomPath, Margin = new Thickness(0, -3, 0, 8) };
        var choosePath = new Button { Content = "Choose Claude history…", Margin = new Thickness(0, 0, 0, 12) };
        choosePath.Click += (_, _) =>
        {
            var picker = new OpenFileDialog { Filter = "Claude usage history (plan-usage-history.json)|plan-usage-history.json|JSON files (*.json)|*.json", FileName = "plan-usage-history.json" };
            if (picker.ShowDialog(dialog) == true) { customPath.Text = picker.FileName; customPath.ToolTip = picker.FileName; }
        };
        panel.Children.Add(customPath); panel.Children.Add(choosePath);
        var codexDesktop = AddGroupSelector(panel, "Codex Desktop", _displaySettings.CodexDesktopGroup);
        var codexCli = AddGroupSelector(panel, "Codex CLI", _displaySettings.CodexCliGroup);
        var codexSsh = AddGroupSelector(panel, "Codex Remote (SSH)", _displaySettings.CodexSshGroup);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 8, 0, 0) };
        var cancel = new Button { Content = "Cancel", MinWidth = 72, Margin = new Thickness(0, 0, 8, 0) };
        cancel.Click += (_, _) => dialog.Close();
        var save = new Button { Content = "Save", MinWidth = 72, IsDefault = true };
        save.Click += (_, _) =>
        {
            _displaySettings = new DisplaySettings(SelectedGroup(claudeDesktop), SelectedGroup(claudeCli), customPath.ToolTip?.ToString() ?? "", SelectedGroup(claudeCustom), SelectedGroup(codexDesktop), SelectedGroup(codexCli), SelectedGroup(codexSsh), _displaySettings.ClaudeUserEnvironment);
            SaveDisplaySettings(); Refresh(); dialog.Close();
        };
        buttons.Children.Add(cancel); buttons.Children.Add(save); panel.Children.Add(buttons);
        dialog.ShowDialog();
    }

    private static ComboBox AddGroupSelector(Panel panel, string label, string selected)
    {
        var row = new Grid { Margin = new Thickness(0, 0, 0, 7) };
        row.ColumnDefinitions.Add(new ColumnDefinition()); row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(115) });
        var text = new TextBlock { Text = label, Foreground = System.Windows.Media.Brushes.LightGray, VerticalAlignment = VerticalAlignment.Center };
        var selector = new ComboBox { ItemsSource = new[] { "Group 1", "Group 2", "Group 3", "Hidden" }, SelectedItem = ValidGroup(selected) ? selected : "Group 1" };
        Grid.SetColumn(selector, 1); row.Children.Add(text); row.Children.Add(selector); panel.Children.Add(row);
        return selector;
    }

    private void SaveDisplaySettings()
    {
        try
        {
            Directory.CreateDirectory(_home);
            File.WriteAllText(Path.Combine(_home, "display-settings.json"), JsonSerializer.Serialize(_displaySettings.ToStorage(), new JsonSerializerOptions { WriteIndented = true }));
            File.WriteAllText(Path.Combine(_home, "claude-custom-source.json"), JsonSerializer.Serialize(new { path = _displaySettings.ClaudeCustomPath }, new JsonSerializerOptions { WriteIndented = true }));
        }
        catch { }
    }

    private static bool ValidGroup(string value) => value is "Group 1" or "Group 2" or "Group 3" or "Hidden";
    private static string SelectedGroup(ComboBox selector) => selector.SelectedItem as string is { } group && ValidGroup(group) ? group : "Group 1";

    private readonly record struct UsageSource(string Label, string Group, JsonElement? Snapshot);
    private sealed record DisplaySettings(string ClaudeDesktopGroup, string ClaudeCliGroup, string ClaudeCustomPath, string ClaudeCustomGroup, string CodexDesktopGroup, string CodexCliGroup, string CodexSshGroup, string ClaudeUserEnvironment)
    {
        public static DisplaySettings Default { get; } = new("Group 1", "Group 1", "", "Group 1", "Group 1", "Group 1", "Group 2", "default");
        public static DisplaySettings FromJson(JsonElement root) => new(
            Group(root, "claude_desktop_group", "Group 1"), Group(root, "claude_cli_group", "Group 1"), String(root, "claude_custom_path"), Group(root, "claude_custom_group", "Group 1"),
            Group(root, "codex_desktop_group", "Group 1"), Group(root, "codex_cli_group", "Group 1"), Group(root, "codex_ssh_group", "Group 2"), Environment(root));
        public object ToStorage() => new { claude_desktop_group = ClaudeDesktopGroup, claude_cli_group = ClaudeCliGroup, claude_custom_path = ClaudeCustomPath, claude_custom_group = ClaudeCustomGroup, codex_desktop_group = CodexDesktopGroup, codex_cli_group = CodexCliGroup, codex_ssh_group = CodexSshGroup, claude_user_environment = ClaudeUserEnvironment };
        private static string String(JsonElement root, string name) => root.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() ?? "" : "";
        private static string Group(JsonElement root, string name, string fallback) { var value = String(root, name); return ValidGroup(value) ? value : fallback; }
        private static string Environment(JsonElement root) => String(root, "claude_user_environment") is "self" ? "self" : "default";
    }
}
