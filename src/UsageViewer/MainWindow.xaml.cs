using System.Globalization;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
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
    private const int WmNcHitTest = 0x0084;
    private const nint HtTransparent = -1;
    private const nint HtClient = 1;
    private const int VkControl = 0x11;
    private const int VkMenu = 0x12;
    private const int VkP = 0x50;

    [DllImport("user32.dll")]
    private static extern short GetAsyncKeyState(int virtualKey);

    private readonly string _home = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".usage-viewer");
    private readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromSeconds(1) };
    private readonly UsageReaderService? _reader;
    private readonly Mutex? _instanceMutex;
    private DisplaySettings _displaySettings = DisplaySettings.Default;
    private HwndSource? _windowSource;
    private bool _isPinned;
    private bool _pinHotkeyWasDown;
    private readonly bool _settingsOnly;

    public MainWindow()
    {
        InitializeComponent();
        _settingsOnly = Environment.GetCommandLineArgs().Any(argument => argument.Equals("--settings", StringComparison.OrdinalIgnoreCase));
        if (!_settingsOnly)
        {
            // Like the script overlay, keep one viewer so the bridge port and
            // helper processes are never started twice.
            _instanceMutex = new Mutex(true, "UsageViewer.Wpf.v1", out var createdNew);
            if (!createdNew)
            {
                _instanceMutex.Dispose();
                _instanceMutex = null;
                _settingsOnly = true;
                ShowInTaskbar = false;
                Opacity = 0;
                Loaded += (_, _) => Close();
                return;
            }
            _reader = new UsageReaderService();
        }
        if (_settingsOnly)
        {
            ShowInTaskbar = false;
            Opacity = 0;
            Width = 1;
            Height = 1;
            SizeToContent = SizeToContent.Manual;
            WindowStartupLocation = WindowStartupLocation.CenterScreen;
        }
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
            var pinHotkeyDown = IsKeyDown(VkControl) && IsKeyDown(VkMenu) && IsKeyDown(VkP);
            if (pinHotkeyDown && !_pinHotkeyWasDown) OnPinClick(this, new RoutedEventArgs());
            _pinHotkeyWasDown = pinHotkeyDown;
            Refresh();
            EnsureTopmost();
        };
        _timer.Start();
        Refresh();
        if (_settingsOnly) Loaded += (_, _) => { OnSettingsClick(this, new RoutedEventArgs()); Close(); };
    }

    private void Refresh()
    {
        var rows = new List<(string Main, string Detail)>();
        AppendGroupedUsage(rows, "A", ClaudeSources(), ClaudeUsageLine);
        AppendGroupedUsage(rows, "O", CodexSources(), CodexUsageLine);
        var columns = _displaySettings.DisplayLayout != "stacked" && rows.Count > 0;
        StackedPanel.Visibility = columns ? Visibility.Collapsed : Visibility.Visible;
        ColumnsPanel.Visibility = columns ? Visibility.Visible : Visibility.Collapsed;
        if (columns)
        {
            UpdateColumns(rows);
            return;
        }
        MainText.Text = rows.Count == 0 ? "Waiting for Claude / Codex usage..." : string.Join("\n", rows.Select(row => row.Main));
        DetailText.Text = string.Join("\n", rows.Select(row => row.Detail));
        DetailText.Visibility = rows.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
    }

    private void UpdateColumns(IReadOnlyList<(string Main, string Detail)> rows)
    {
        while (ColumnsPanel.Children.Count > rows.Count) ColumnsPanel.Children.RemoveAt(ColumnsPanel.Children.Count - 1);
        while (ColumnsPanel.Children.Count < rows.Count)
        {
            var column = new StackPanel { Margin = new Thickness(ColumnsPanel.Children.Count == 0 ? 0 : 20, 0, 0, 0) };
            column.Children.Add(new TextBlock { Foreground = MainText.Foreground, FontSize = MainText.FontSize, FontWeight = MainText.FontWeight });
            column.Children.Add(new TextBlock { Foreground = DetailText.Foreground, FontSize = DetailText.FontSize, Margin = DetailText.Margin });
            ColumnsPanel.Children.Add(column);
        }
        for (var index = 0; index < rows.Count; index++)
        {
            var column = (StackPanel)ColumnsPanel.Children[index];
            ((TextBlock)column.Children[0]).Text = rows[index].Main;
            ((TextBlock)column.Children[1]).Text = rows[index].Detail;
        }
    }

    private List<UsageSource> ClaudeSources() => ClaudeDesktopUsageSources()
        .Concat(new[] { new UsageSource("C", _displaySettings.ClaudeCliGroup, Read("claude-statusline-latest.json")) })
        .Concat(_displaySettings.ClaudeCustomSources.Select((source, index) =>
            new UsageSource(AbbreviateSourceLabel(string.IsNullOrWhiteSpace(source.Name) ? $"Custom {index + 1}" : source.Name, "Claude"),
                source.Group, Read($"claude-custom-{index}-latest.json")))).ToList();

    private IEnumerable<UsageSource> ClaudeDesktopUsageSources()
    {
        var desktop = ClaudeDesktopSources();
        // Without a detected profile, the script overlay still shows the
        // reader's combined Desktop snapshot; keep that source visible here.
        if (desktop.Count == 0)
            return new[] { new UsageSource("D", _displaySettings.ClaudeDesktopGroup, Read("claude-desktop-latest.json")) };
        return desktop.Select((source, index) =>
            new UsageSource(AbbreviateSourceLabel(source.Name, "Claude"), source.Group, Read($"claude-desktop-{index}-latest.json")));
    }

    private IReadOnlyList<ConfiguredSource> ClaudeDesktopSources() =>
        ClaudeDesktopProfiles.FindWithMappings().Select(profile =>
        {
            var saved = _displaySettings.ClaudeDesktopSources.FirstOrDefault(source =>
                source.Path.Equals(profile.Path, StringComparison.OrdinalIgnoreCase) ||
                source.Path.Equals(profile.LegacyPath, StringComparison.OrdinalIgnoreCase));
            return new ConfiguredSource(saved?.Name ?? profile.Name, profile.Path, saved?.Group ?? profile.Group);
        }).ToList();

    private List<UsageSource> CodexSources() => new[]
    {
        new UsageSource("D", _displaySettings.CodexDesktopGroup, Read("codex-desktop-latest.json")),
        new UsageSource("C", _displaySettings.CodexCliGroup, Read("codex-cli-latest.json"))
    }.Concat(CodexDesktopProfiles.ReadAccounts(_home).Select(account =>
            new UsageSource(AbbreviateSourceLabel(account.Name, "Codex"), "account:" + account.Id, account.Snapshot)))
        .Concat(CodexSshUsageSources()).ToList();

    private IEnumerable<UsageSource> CodexSshUsageSources()
    {
        // With no configured SSH source, the synchronizer falls back to
        // config\remote.env; show that snapshot as the overlay does.
        if (_displaySettings.CodexSshSources.Count == 0)
            return new[] { new UsageSource("SSH 1", _displaySettings.CodexSshGroup, ReadRemoteSnapshot(0)) };
        return _displaySettings.CodexSshSources.Select((source, index) =>
            new UsageSource(AbbreviateSourceLabel(string.IsNullOrWhiteSpace(source.Name) ? $"SSH {index + 1}" : source.Name, "Codex"),
                source.Group, ReadRemoteSnapshot(index)));
    }

    private static string AbbreviateSourceLabel(string label, string product)
    {
        var words = Regex.Matches(label, @"[\p{L}\p{N}]+").Cast<Match>()
            .Select(match => match.Value)
            .Where(word => !word.All(char.IsDigit))
            .ToList();
        if (words.Count > 1 && words[0].Equals(product, StringComparison.OrdinalIgnoreCase)) words.RemoveAt(0);
        var abbreviation = string.Concat(words.Select(word => char.ToUpperInvariant(word[0])));
        return string.IsNullOrWhiteSpace(abbreviation) ? "?" : abbreviation;
    }

    private JsonElement? ReadRemoteSnapshot(int index)
    {
        var indexedFile = $"codex-remote-{index}-latest.json";
        // Older/background readers use the legacy unindexed name for the
        // first SSH source. Prefer the indexed snapshot when it exists.
        return index == 0 && !File.Exists(Path.Combine(_home, indexedFile))
            ? Read("codex-remote-latest.json")
            : Read(indexedFile);
    }

    private static void AppendGroupedUsage(
        List<(string Main, string Detail)> rows,
        string product,
        IEnumerable<UsageSource> sources,
        Func<JsonElement?, string> usageLine)
    {
        foreach (var group in sources
            .Where(source => source.Snapshot is not null && source.Group != "Hidden")
            .GroupBy(source => source.Group)
            .OrderBy(group => group.Key, StringComparer.Ordinal))
        {
            var newest = group.OrderByDescending(source => Timestamp(source.Snapshot)).First();
            var labels = string.Join("+", group.Select(source => source.Label));
            rows.Add(($"{product}  {usageLine(newest.Snapshot)}  ({labels})", $"{product}  {Details(newest.Snapshot)}  ({labels})"));
        }
    }

    private static DateTimeOffset Timestamp(JsonElement? root)
    {
        if (root is not null)
        {
            if (root.Value.TryGetProperty("desktop_api", out var desktopApi) &&
                desktopApi.ValueKind == JsonValueKind.Object &&
                desktopApi.TryGetProperty("observed_at", out var apiObserved) &&
                apiObserved.ValueKind == JsonValueKind.String &&
                DateTimeOffset.TryParse(apiObserved.GetString(), out var apiTimestamp))
                return apiTimestamp;
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
            if (JsonValues.StringOrNull(document.RootElement, "source") == "codex-desktop-bridge")
                return CodexDesktopProfiles.ReadFresh(path);
            return document.RootElement.Clone();
        }
        catch { return null; }
    }

    private static string Percent(JsonElement? root, string name, string missing)
    {
        if (root is null || !root.Value.TryGetProperty("percentages", out var percentages) || !percentages.TryGetProperty(name, out var value) || value.ValueKind != JsonValueKind.Number) return missing;
        return $"{value.GetDouble().ToString("0.##", CultureInfo.InvariantCulture)}%";
    }

    // Same text as the script overlay: Claude shows "?" and Codex "-" for a missing window.
    private static string ClaudeUsageLine(JsonElement? root) =>
        $"7d {Percent(root, "seven_day_used", "?")}  |  5h {Percent(root, "five_hour_used", "?")}";

    private static string CodexUsageLine(JsonElement? root) =>
        $"7d {Percent(root, "seven_day_used", "-")}  |  5h {Percent(root, "five_hour_used", "-")}";

    private static string Details(JsonElement? root)
    {
        if (root is null) return "";
        var sevenDay = Reset(root.Value, "seven_day_epoch_seconds", "7d", relative: false);
        var fiveHour = Reset(root.Value, "five_hour_epoch_seconds", "5h", relative: false);
        return $"{(string.IsNullOrWhiteSpace(sevenDay) ? "?" : sevenDay)} | {(string.IsNullOrWhiteSpace(fiveHour) ? "?" : fiveHour)} | {Age(root)}";
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
        if (root.Value.TryGetProperty("desktop_api", out var desktopApi) &&
            desktopApi.ValueKind == JsonValueKind.Object &&
            desktopApi.TryGetProperty("observed_at", out var apiObserved) &&
            apiObserved.ValueKind == JsonValueKind.String)
            timestamp = apiObserved.GetString();
        if (timestamp is null && root.Value.TryGetProperty("observed_at", out var observed) && observed.ValueKind == JsonValueKind.String)
            timestamp = observed.GetString();
        if (DateTimeOffset.TryParse(timestamp, out var time))
        {
            var age = DateTimeOffset.Now - time;
            if (age.TotalMinutes < 1) return $"{Math.Max(0, (int)age.TotalSeconds)}s ago";
            if (age.TotalHours < 1) return $"{(int)age.TotalMinutes}m ago";
            return $"{(int)age.TotalHours}h ago";
        }
        return "";
    }

    private void OnPreviewMouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (_isPinned || e.LeftButton != MouseButtonState.Pressed || IsInteractiveControl(e.OriginalSource as DependencyObject)) return;
        try
        {
            DragMove();
            e.Handled = true;
        }
        catch (InvalidOperationException)
        {
            // The mouse button may have been released while WPF was entering its move loop.
        }
    }

    private static bool IsInteractiveControl(DependencyObject? element)
    {
        while (element is not null)
        {
            if (element is ButtonBase or Thumb) return true;
            element = System.Windows.Media.VisualTreeHelper.GetParent(element);
        }
        return false;
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
        MinWidth = _isPinned ? 180 : 340;
        EnsureTopmost();
    }

    private static bool IsKeyDown(int virtualKey) => (GetAsyncKeyState(virtualKey) & 0x8000) != 0;

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
        if (!_settingsOnly) SaveWindowState();
        _timer.Stop();
        _reader?.Dispose();
        _windowSource?.RemoveHook(WindowMessageHook);
        if (_instanceMutex is not null)
        {
            _instanceMutex.ReleaseMutex();
            _instanceMutex.Dispose();
        }
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

    private void LoadDisplaySettings() => _displaySettings = new DisplaySettingsStore(_home).Load();

    private void OnSettingsClick(object sender, RoutedEventArgs e)
    {
        var settings = SettingsDialog.Show(this, _settingsOnly, _displaySettings, ClaudeDesktopSources());
        if (settings is null) return;
        _displaySettings = settings;
        SaveDisplaySettings();
        Refresh();
    }

    private void SaveDisplaySettings() => new DisplaySettingsStore(_home).Save(_displaySettings);

    private readonly record struct UsageSource(string Label, string Group, JsonElement? Snapshot);

}
