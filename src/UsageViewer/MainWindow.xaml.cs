using System.Globalization;
using System.Diagnostics;
using System.Collections.ObjectModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
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
    private const int VkControl = 0x11;
    private const int VkMenu = 0x12;
    private const int VkP = 0x50;

    [DllImport("user32.dll")]
    private static extern short GetAsyncKeyState(int virtualKey);

    private readonly string _home = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".usage-viewer");
    private readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromSeconds(1) };
    private readonly UsageReaderService _reader = new();
    private DisplaySettings _displaySettings = DisplaySettings.Default;
    private HwndSource? _windowSource;
    private bool _isPinned;
    private bool _pinHotkeyWasDown;
    private readonly bool _settingsOnly;

    public MainWindow()
    {
        InitializeComponent();
        _settingsOnly = Environment.GetCommandLineArgs().Any(argument => argument.Equals("--settings", StringComparison.OrdinalIgnoreCase));
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
        var lines = new List<string>();
        var details = new List<string>();
        AppendGroupedUsage(lines, details, "Claude", ClaudeSources(), ClaudeUsageLine, ClaudeDetails);
        AppendGroupedUsage(lines, details, "Codex", CodexSources(), CodexUsageLine, CodexDetails);
        MainText.Text = lines.Count == 0 ? "Waiting for usage..." : string.Join("\n", lines);
        DetailText.Text = string.Join("\n", details);
    }

    private List<UsageSource> ClaudeSources() => ClaudeDesktopSources().Select((source, index) =>
        new UsageSource(source.Name, source.Group, Read($"claude-desktop-{index}-latest.json")))
        .Concat(new[] { new UsageSource("C", _displaySettings.ClaudeCliGroup, Read("claude-statusline-latest.json")) })
        .Concat(_displaySettings.ClaudeCustomSources.Select((source, index) =>
            new UsageSource(string.IsNullOrWhiteSpace(source.Name) ? $"Custom {index + 1}" : source.Name,
                source.Group, Read($"claude-custom-{index}-latest.json")))).ToList();

    private static IReadOnlyList<ConfiguredSource> ClaudeDesktopSources()
    {
        var appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        var regular = Path.Combine(appData, "Claude", "plan-usage-history.json");
        var result = new List<ConfiguredSource>();
        if (File.Exists(regular)) result.Add(new ConfiguredSource("Claude Desktop (AppData)", regular, "1"));
        try
        {
            var packages = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Packages");
            if (Directory.Exists(packages))
                result.AddRange(Directory.EnumerateDirectories(packages, "Claude_*")
                    .Select(path => Path.Combine(path, "LocalCache", "Roaming", "Claude", "plan-usage-history.json"))
                    .Where(File.Exists).OrderByDescending(File.GetLastWriteTimeUtc)
                    .Select((path, index) => new ConfiguredSource($"Claude Desktop (MSIX {index + 1})", path, (index + 2).ToString(CultureInfo.InvariantCulture))));
        }
        catch { }
        return result;
    }

    private List<UsageSource> CodexSources() => new[]
    {
        new UsageSource("D", _displaySettings.CodexDesktopGroup, Read("codex-desktop-latest.json")),
        new UsageSource("C", _displaySettings.CodexCliGroup, Read("codex-cli-latest.json"))
    }.Concat(_displaySettings.CodexSshSources.Select((source, index) =>
            new UsageSource(string.IsNullOrWhiteSpace(source.Name) ? $"SSH {index + 1}" : source.Name,
                source.Group, ReadRemoteSnapshot(index)))).ToList();

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
            Title = "Usage Viewer Settings", Owner = this, WindowStartupLocation = _settingsOnly ? WindowStartupLocation.CenterScreen : WindowStartupLocation.CenterOwner,
            Width = 720, Height = 650, MinWidth = 680, MinHeight = 500, ResizeMode = ResizeMode.CanResize,
            Background = new System.Windows.Media.SolidColorBrush(System.Windows.Media.Color.FromRgb(23, 23, 23)), WindowStyle = WindowStyle.None, AllowsTransparency = false,
            Topmost = true, ShowInTaskbar = false
        };
        var outer = new Border { Background = new System.Windows.Media.SolidColorBrush(System.Windows.Media.Color.FromRgb(23, 23, 23)), BorderBrush = System.Windows.Media.Brushes.DimGray, BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(8), Padding = new Thickness(14) };
        var root = new Grid(); root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto }); root.RowDefinitions.Add(new RowDefinition()); root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto }); outer.Child = root; dialog.Content = outer;
        var header = new StackPanel { Margin = new Thickness(0, 0, 0, 10) };
        header.Children.Add(new TextBlock { Text = "Usage Viewer Settings", Foreground = System.Windows.Media.Brushes.White, FontSize = 18, FontWeight = FontWeights.SemiBold });
        header.Children.Add(new TextBlock { Text = "Choose display groups and manage multiple Claude / SSH sources.", Foreground = System.Windows.Media.Brushes.Gray, FontSize = 11, Margin = new Thickness(0, 3, 0, 0) });
        header.Cursor = Cursors.SizeAll;
        header.MouseLeftButtonDown += (_, args) => { if (args.LeftButton == MouseButtonState.Pressed) dialog.DragMove(); };
        Grid.SetRow(header, 0); root.Children.Add(header);
        var content = new StackPanel(); var scroll = new ScrollViewer { Content = content, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled }; Grid.SetRow(scroll, 1); root.Children.Add(scroll);
        var groupCodes = BuildGroupCodes(_displaySettings);
        AddSettingsSection(content, "Built-in sources");
        var detectedDesktop = ClaudeDesktopSources();
        var configuredDesktop = detectedDesktop.Select((source, index) =>
        {
            var saved = _displaySettings.ClaudeDesktopSources.FirstOrDefault(item => item.Path.Equals(source.Path, StringComparison.OrdinalIgnoreCase));
            var fallbackGroup = index == 0 ? _displaySettings.ClaudeDesktopGroup : (index + 1).ToString(CultureInfo.InvariantCulture);
            return new ConfiguredSource(source.Name, source.Path, saved?.Group ?? fallbackGroup);
        }).ToList();
        if (configuredDesktop.Count == 0) configuredDesktop.Add(new ConfiguredSource("Claude Desktop", "", _displaySettings.ClaudeDesktopGroup));
        var claudeDesktopSelectors = configuredDesktop.Select(source => AddGroupSelector(content, source.Name, source.Group, groupCodes)).ToList();
        var claudeCli = AddGroupSelector(content, "Claude CLI", _displaySettings.ClaudeCliGroup, groupCodes);
        var codexDesktop = AddGroupSelector(content, "Codex Desktop", _displaySettings.CodexDesktopGroup, groupCodes);
        var codexCli = AddGroupSelector(content, "Codex CLI", _displaySettings.CodexCliGroup, groupCodes);
        AddSettingsSection(content, "Claude Custom sources");
        AddEditorHeader(content, false);
        var customRows = new List<SourceEditor>(); var customList = new StackPanel(); content.Children.Add(customList);
        foreach (var source in _displaySettings.ClaudeCustomSources) AddCustomEditor(customList, customRows, source, dialog, groupCodes);
        var environmentOptions = new ObservableCollection<string>(new[] { "default" }.Concat(_displaySettings.ClaudeCustomSources.Select(source => source.Name).Where(name => !string.IsNullOrWhiteSpace(name))).Distinct(StringComparer.OrdinalIgnoreCase));
        var addCustom = new Button { Content = "+  Add Claude environment", HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 5, 0, 10), Padding = new Thickness(10, 3, 10, 3) };
        addCustom.Click += (_, _) =>
        {
            var name = PromptClaudeEnvironmentName(dialog, customRows.Count + 1);
            if (string.IsNullOrWhiteSpace(name)) return;
            var profilePath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Claude-" + SafeProfileName(name));
            Directory.CreateDirectory(profilePath);
            var usageHistoryPath = Path.Combine(profilePath, "plan-usage-history.json");
            var groupCode = AddNextGroupCode(groupCodes);
            AddCustomEditor(customList, customRows, new ConfiguredSource(name, usageHistoryPath, groupCode, ProfilePath: profilePath), dialog, groupCodes);
            if (!environmentOptions.Contains(name, StringComparer.OrdinalIgnoreCase)) environmentOptions.Add(name);
        };
        content.Children.Add(addCustom);
        AddSettingsSection(content, "Codex SSH sources");
        AddEditorHeader(content, true);
        var sshRows = new List<SourceEditor>(); var sshList = new StackPanel(); content.Children.Add(sshList);
        foreach (var source in _displaySettings.CodexSshSources) AddSshEditor(sshList, sshRows, source, groupCodes);
        var addSsh = new Button { Content = "+  Add SSH source", HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 5, 0, 10), Padding = new Thickness(10, 3, 10, 3) }; addSsh.Click += (_, _) => AddSshEditor(sshList, sshRows, new ConfiguredSource($"SSH {sshRows.Count + 1}", "", AddNextGroupCode(groupCodes)), groupCodes); content.Children.Add(addSsh);
        AddSettingsSection(content, "Claude user environment");
        var environmentSelector = new ComboBox { Width = 260, ItemsSource = environmentOptions, SelectedItem = environmentOptions.Contains(_displaySettings.ClaudeUserEnvironment, StringComparer.OrdinalIgnoreCase) ? _displaySettings.ClaudeUserEnvironment : "default" };
        var openEnvironment = new Button { Content = "Open", Margin = new Thickness(8, 0, 0, 0), Padding = new Thickness(10, 3, 10, 3) }; var selectedEnvironment = environmentSelector.SelectedItem as string ?? "default";
        openEnvironment.Click += (_, _) => OpenClaudeEnvironment(selectedEnvironment, _displaySettings.ClaudeCustomSources);
        environmentSelector.SelectionChanged += (_, _) => selectedEnvironment = environmentSelector.SelectedItem as string ?? "default";
        var environmentRow = new StackPanel { Orientation = Orientation.Horizontal }; environmentRow.Children.Add(environmentSelector); environmentRow.Children.Add(openEnvironment); content.Children.Add(environmentRow);
        var actions = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 12, 0, 0) }; var cancel = new Button { Content = "Cancel", MinWidth = 80, Margin = new Thickness(0, 0, 8, 0), Padding = new Thickness(8, 3, 8, 3) }; cancel.Click += (_, _) => dialog.Close(); var save = new Button { Content = "Save", MinWidth = 80, IsDefault = true, Padding = new Thickness(8, 3, 8, 3) }; save.Click += (_, _) => { IReadOnlyList<ConfiguredSource> desktopSources = detectedDesktop.Count == 0 ? new List<ConfiguredSource>() : configuredDesktop.Select((source, index) => source with { Group = SelectedGroup(claudeDesktopSelectors[index]) }).ToList(); _displaySettings = new DisplaySettings(desktopSources, SelectedGroup(claudeCli), customRows.Where(row => !string.IsNullOrWhiteSpace(row.Name.Text)).Select(row => row.ToSource()).ToList(), SelectedGroup(codexDesktop), SelectedGroup(codexCli), sshRows.Where(row => !string.IsNullOrWhiteSpace(row.Host.Text)).Select(row => row.ToSource()).ToList(), selectedEnvironment); SaveDisplaySettings(); Refresh(); dialog.Close(); }; actions.Children.Add(cancel); actions.Children.Add(save); Grid.SetRow(actions, 2); root.Children.Add(actions); dialog.ShowDialog();
    }

    private static void AddSettingsSection(Panel panel, string title)
    {
        panel.Children.Add(new Border { Height = 1, Background = System.Windows.Media.Brushes.DimGray, Margin = new Thickness(0, 8, 0, 8) });
        panel.Children.Add(new TextBlock { Text = title, Foreground = System.Windows.Media.Brushes.White, FontSize = 13, FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 0, 0, 5) });
    }

    private static void AddEditorHeader(Panel panel, bool ssh)
    {
        var header = new Grid { Margin = new Thickness(0, 0, 0, 3) };
        var widths = ssh ? new[] { 100, 85, 145, 55, 150, 100 } : new[] { 100, 360, 110, 80 };
        var labels = ssh ? new[] { "Name", "User", "Host", "Port", "Sessions path", "Group" } : new[] { "Name / profile", "Usage history path", "Group", "" };
        for (var index = 0; index < widths.Length; index++)
        {
            header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(widths[index]) });
            var label = new TextBlock { Text = labels[index], Foreground = System.Windows.Media.Brushes.Gray, FontSize = 10, Margin = new Thickness(0, 0, 4, 0) };
            Grid.SetColumn(label, index); header.Children.Add(label);
        }
        panel.Children.Add(header);
    }

#if false
    private void OnSettingsClickPrevious(object sender, RoutedEventArgs e)
    {
        var dialog = new Window
        {
            Title = "Usage Viewer Settings", Owner = this, WindowStartupLocation = WindowStartupLocation.CenterOwner,
            Width = 700, Height = 540, ResizeMode = ResizeMode.CanResize,
            Background = System.Windows.Media.Brushes.Transparent, WindowStyle = WindowStyle.None, AllowsTransparency = true,
            Topmost = true, ShowInTaskbar = false
        };
        var panel = new StackPanel { Margin = new Thickness(10) };
        var border = new Border { Background = new System.Windows.Media.SolidColorBrush(System.Windows.Media.Color.FromRgb(23, 23, 23)), BorderBrush = System.Windows.Media.Brushes.DimGray, BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(8) };
        border.Child = new ScrollViewer { VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Content = panel };
        dialog.Content = border;
        var title = new TextBlock { Text = "Display settings", Foreground = System.Windows.Media.Brushes.White, FontWeight = FontWeights.Bold, FontSize = 15, Margin = new Thickness(0, 0, 0, 6) };
        panel.Children.Add(title);
        var claudeDesktop = AddGroupSelector(panel, "Claude Desktop", _displaySettings.ClaudeDesktopGroup);
        var claudeCli = AddGroupSelector(panel, "Claude CLI", _displaySettings.ClaudeCliGroup);
        panel.Children.Add(new TextBlock { Text = "Claude user environment", Foreground = System.Windows.Media.Brushes.White, Margin = new Thickness(0, 8, 0, 4) });
        var environmentStatus = new TextBlock { Text = $"Current: {_displaySettings.ClaudeUserEnvironment}", Foreground = System.Windows.Media.Brushes.LightGray, Margin = new Thickness(0, 0, 0, 4) };
        var environmentButtons = new StackPanel { Orientation = Orientation.Horizontal };
        var defaultEnvironment = new Button { Content = "Open Default", Margin = new Thickness(0, 0, 8, 0) };
        var selfEnvironment = new Button { Content = "Open Self" };
        var selectedEnvironment = _displaySettings.ClaudeUserEnvironment;
        defaultEnvironment.Click += (_, _) => { OpenClaudeDefault(); selectedEnvironment = "default"; environmentStatus.Text = "Current: default"; };
        selfEnvironment.Click += (_, _) => { OpenClaudeSelf(); selectedEnvironment = "self"; environmentStatus.Text = "Current: self"; };
        environmentButtons.Children.Add(defaultEnvironment); environmentButtons.Children.Add(selfEnvironment);
        panel.Children.Add(environmentStatus); panel.Children.Add(environmentButtons);
        panel.Children.Add(new TextBlock { Text = "Claude Custom sources", Foreground = System.Windows.Media.Brushes.White, Margin = new Thickness(0, 8, 0, 4) });
        var customRows = new List<SourceEditor>(); var customList = new StackPanel(); panel.Children.Add(customList);
        foreach (var source in _displaySettings.ClaudeCustomSources) AddCustomEditor(customList, customRows, source, dialog);
        var addCustom = new Button { Content = "Add Claude custom path", HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 4, 0, 8) };
        addCustom.Click += (_, _) => AddCustomEditor(customList, customRows, new ConfiguredSource($"Custom {customRows.Count + 1}", "", "Group 1"), dialog); panel.Children.Add(addCustom);
        var codexDesktop = AddGroupSelector(panel, "Codex Desktop", _displaySettings.CodexDesktopGroup);
        var codexCli = AddGroupSelector(panel, "Codex CLI", _displaySettings.CodexCliGroup);
        panel.Children.Add(new TextBlock { Text = "Codex SSH sources", Foreground = System.Windows.Media.Brushes.White, Margin = new Thickness(0, 8, 0, 4) });
        var sshRows = new List<SourceEditor>(); var sshList = new StackPanel(); panel.Children.Add(sshList);
        foreach (var source in _displaySettings.CodexSshSources) AddSshEditor(sshList, sshRows, source);
        var addSsh = new Button { Content = "Add SSH source", HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 4, 0, 8) };
        addSsh.Click += (_, _) => AddSshEditor(sshList, sshRows, new ConfiguredSource($"SSH {sshRows.Count + 1}", "", "Group 1")); panel.Children.Add(addSsh);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 8, 0, 0) };
        var cancel = new Button { Content = "Cancel", MinWidth = 72, Margin = new Thickness(0, 0, 8, 0) }; cancel.Click += (_, _) => dialog.Close(); buttons.Children.Add(cancel);
        var save = new Button { Content = "Save", MinWidth = 72, IsDefault = true }; save.Click += (_, _) =>
        {
            _displaySettings = new DisplaySettings(SelectedGroup(claudeDesktop), SelectedGroup(claudeCli), customRows.Where(row => !string.IsNullOrWhiteSpace(row.Path.Text)).Select(row => row.ToSource()).ToList(), SelectedGroup(codexDesktop), SelectedGroup(codexCli), sshRows.Where(row => !string.IsNullOrWhiteSpace(row.Host.Text)).Select(row => row.ToSource()).ToList(), selectedEnvironment);
            SaveDisplaySettings(); Refresh(); dialog.Close();
        }; buttons.Children.Add(save); panel.Children.Add(buttons); dialog.ShowDialog();
    }

#endif
    private static string? PromptClaudeEnvironmentName(Window owner, int index)
    {
        var prompt = new Window
        {
            Title = "Add Claude environment", Owner = owner, WindowStartupLocation = WindowStartupLocation.CenterOwner,
            Width = 380, Height = 170, ResizeMode = ResizeMode.NoResize, ShowInTaskbar = false, Topmost = true,
            Background = new System.Windows.Media.SolidColorBrush(System.Windows.Media.Color.FromRgb(28, 28, 28))
        };
        var root = new StackPanel { Margin = new Thickness(16) };
        root.Children.Add(new TextBlock { Text = "Environment name", Foreground = System.Windows.Media.Brushes.White, Margin = new Thickness(0, 0, 0, 6) });
        var nameBox = new TextBox { Text = $"Custom {index}", Margin = new Thickness(0, 0, 0, 12) }; root.Children.Add(nameBox);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        var cancel = new Button { Content = "Cancel", MinWidth = 72, Margin = new Thickness(0, 0, 8, 0) }; cancel.Click += (_, _) => prompt.DialogResult = false;
        var add = new Button { Content = "Add", MinWidth = 72, IsDefault = true }; add.Click += (_, _) => { if (!string.IsNullOrWhiteSpace(nameBox.Text)) prompt.DialogResult = true; };
        buttons.Children.Add(cancel); buttons.Children.Add(add); root.Children.Add(buttons); prompt.Content = root;
        nameBox.SelectAll(); nameBox.Focus();
        return prompt.ShowDialog() == true ? nameBox.Text.Trim() : null;
    }

    private static void AddCustomEditor(Panel panel, List<SourceEditor> rows, ConfiguredSource source, Window owner, ObservableCollection<string> groupCodes)
    {
        var editor = new SourceEditor(source, false, groupCodes); rows.Add(editor); var row = editor.BuildRow();
        var choose = new Button { Content = "Choose", Margin = new Thickness(4, 0, 0, 0) };
        choose.Click += (_, _) => { var picker = new OpenFileDialog { Filter = "Claude history|plan-usage-history.json|JSON files (*.json)|*.json" }; if (picker.ShowDialog(owner) == true) editor.Path.Text = picker.FileName; };
        Grid.SetColumn(choose, 3); row.Children.Add(choose); panel.Children.Add(row);
    }

    private static void AddSshEditor(Panel panel, List<SourceEditor> rows, ConfiguredSource source, ObservableCollection<string> groupCodes)
    {
        var editor = new SourceEditor(source, true, groupCodes); rows.Add(editor); panel.Children.Add(editor.BuildRow());
    }

    private sealed class SourceEditor
    {
        public TextBox Name { get; } = new(); public TextBox Path { get; } = new(); public TextBox User { get; } = new(); public TextBox Host { get; } = new(); public TextBox Port { get; } = new(); public TextBox SessionsPath { get; } = new(); public ComboBox Group { get; } = new();
        private readonly bool _ssh;
        public SourceEditor(ConfiguredSource source, bool ssh, ObservableCollection<string> groupCodes) { _ssh = ssh; Name.Text = source.Name; Path.Text = source.Path; User.Text = source.User; Host.Text = source.Host; Port.Text = source.Port.ToString(CultureInfo.InvariantCulture); SessionsPath.Text = source.SessionsPath; Group.ItemsSource = groupCodes; Group.SelectedItem = NormalizeGroup(source.Group); }
        public Grid BuildRow()
        {
            var row = new Grid { Margin = new Thickness(0, 0, 0, 5) }; foreach (var width in _ssh ? new[] { 100, 85, 145, 55, 150, 100 } : new[] { 100, 360, 110, 80 }) row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(width) });
            var fields = _ssh ? new Control[] { Name, User, Host, Port, SessionsPath, Group } : new Control[] { Name, Path, Group };
            for (var i = 0; i < fields.Length; i++) { fields[i].Margin = new Thickness(0, 0, 4, 0); Grid.SetColumn(fields[i], i); row.Children.Add(fields[i]); }
            return row;
        }
        public ConfiguredSource ToSource() => new(Name.Text.Trim(), Path.Text.Trim(), NormalizeGroup(Group.SelectedItem as string ?? "1"), User.Text.Trim(), Host.Text.Trim(), int.TryParse(Port.Text, out var port) ? port : 22, "", SessionsPath.Text.Trim(), _ssh ? "" : System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Claude-" + SafeProfileName(Name.Text.Trim())));
    }

    private static void OpenClaudeDefault()
    {
        try { Process.Start(new ProcessStartInfo { FileName = "explorer.exe", Arguments = "shell:AppsFolder", UseShellExecute = true }); } catch { }
    }

    private static void OpenClaudeSelf()
    {
        try
        {
            var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            var candidates = new[] { Path.Combine(localAppData, "Programs", "Claude", "Claude.exe"), Path.Combine(localAppData, "Claude", "Claude.exe") };
            var executable = candidates.FirstOrDefault(File.Exists) ?? "Claude.exe";
            var profile = Path.Combine(localAppData, "Claude-Self");
            Directory.CreateDirectory(profile);
            Process.Start(new ProcessStartInfo { FileName = executable, Arguments = $"--user-data-dir=\"{profile}\"", UseShellExecute = true });
        }
        catch { }
    }

    private static void OpenClaudeEnvironment(string environment, IReadOnlyList<ConfiguredSource> sources)
    {
        if (environment.Equals("default", StringComparison.OrdinalIgnoreCase)) { OpenClaudeDefault(); return; }
        if (environment.Equals("self", StringComparison.OrdinalIgnoreCase)) { OpenClaudeSelf(); return; }
        var source = sources.FirstOrDefault(item => item.Name.Equals(environment, StringComparison.OrdinalIgnoreCase));
        var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        var profile = string.IsNullOrWhiteSpace(source?.ProfilePath) ? Path.Combine(localAppData, "Claude-" + SafeProfileName(environment)) : source.ProfilePath;
        var executable = new[] { Path.Combine(localAppData, "Programs", "Claude", "Claude.exe"), Path.Combine(localAppData, "Claude", "Claude.exe") }.FirstOrDefault(File.Exists) ?? "Claude.exe";
        try { Directory.CreateDirectory(profile); Process.Start(new ProcessStartInfo { FileName = executable, Arguments = $"--user-data-dir=\"{profile}\"", UseShellExecute = true }); } catch { }
    }

    private static string SafeProfileName(string name) => string.Join("", name.Where(character => char.IsLetterOrDigit(character) || character is '-' or '_'));

#if false
    private void OnSettingsClickLegacy(object sender, RoutedEventArgs e)
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
            var customSources = string.IsNullOrWhiteSpace(customPath.ToolTip?.ToString())
                ? _displaySettings.ClaudeCustomSources
                : new[] { new ConfiguredSource("Custom 1", customPath.ToolTip!.ToString()!, SelectedGroup(claudeCustom)) };
            var sshSources = _displaySettings.CodexSshSources.Count > 0
                ? _displaySettings.CodexSshSources
                : new[] { new ConfiguredSource("SSH 1", "", SelectedGroup(codexSsh)) };
            _displaySettings = new DisplaySettings(SelectedGroup(claudeDesktop), SelectedGroup(claudeCli), customSources, SelectedGroup(codexDesktop), SelectedGroup(codexCli), sshSources, _displaySettings.ClaudeUserEnvironment);
            SaveDisplaySettings(); Refresh(); dialog.Close();
        };
        buttons.Children.Add(cancel); buttons.Children.Add(save); panel.Children.Add(buttons);
        dialog.ShowDialog();
    }

#endif
    private static ObservableCollection<string> BuildGroupCodes(DisplaySettings settings)
    {
        var groups = settings.ClaudeDesktopSources.Select(source => source.Group)
            .Append(settings.ClaudeCliGroup).Append(settings.CodexDesktopGroup).Append(settings.CodexCliGroup)
            .Concat(settings.ClaudeCustomSources.Select(source => source.Group))
            .Concat(settings.CodexSshSources.Select(source => source.Group));
        var maximum = groups.Select(GroupNumber).DefaultIfEmpty(0).Max();
        var result = new ObservableCollection<string>(Enumerable.Range(1, Math.Max(2, maximum)).Select(number => number.ToString(CultureInfo.InvariantCulture)));
        result.Add("Hidden");
        return result;
    }

    private static string AddNextGroupCode(ObservableCollection<string> groupCodes)
    {
        var next = groupCodes.Select(GroupNumber).DefaultIfEmpty(0).Max() + 1;
        var code = next.ToString(CultureInfo.InvariantCulture);
        groupCodes.Insert(Math.Max(0, groupCodes.Count - 1), code);
        return code;
    }

    private static int GroupNumber(string? value)
    {
        var normalized = NormalizeGroup(value ?? "");
        return int.TryParse(normalized, NumberStyles.None, CultureInfo.InvariantCulture, out var number) && number > 0 ? number : 0;
    }

    private static string NormalizeGroup(string value)
    {
        if (value.Equals("Hidden", StringComparison.OrdinalIgnoreCase)) return "Hidden";
        if (value.StartsWith("Group ", StringComparison.OrdinalIgnoreCase)) value = value[6..].Trim();
        return int.TryParse(value, NumberStyles.None, CultureInfo.InvariantCulture, out var number) && number > 0 ? number.ToString(CultureInfo.InvariantCulture) : "1";
    }

    private static ComboBox AddGroupSelector(Panel panel, string label, string selected, ObservableCollection<string> groupCodes)
    {
        var row = new Grid { Margin = new Thickness(0, 0, 0, 7) };
        row.ColumnDefinitions.Add(new ColumnDefinition()); row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(115) });
        var text = new TextBlock { Text = label, Foreground = System.Windows.Media.Brushes.LightGray, VerticalAlignment = VerticalAlignment.Center };
        var selector = new ComboBox { ItemsSource = groupCodes, SelectedItem = NormalizeGroup(selected) };
        Grid.SetColumn(selector, 1); row.Children.Add(text); row.Children.Add(selector); panel.Children.Add(row);
        return selector;
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
            File.WriteAllText(Path.Combine(_home, "claude-custom-source.json"), JsonSerializer.Serialize(new { sources = _displaySettings.ClaudeCustomSources }, new JsonSerializerOptions { WriteIndented = true }));
            File.WriteAllText(Path.Combine(_home, "remote-sources.json"), JsonSerializer.Serialize(new { sources = _displaySettings.CodexSshSources }, new JsonSerializerOptions { WriteIndented = true }));
        }
        catch { }
    }

    private static bool ValidGroup(string value) => value.Equals("Hidden", StringComparison.OrdinalIgnoreCase) || GroupNumber(value) > 0;
    private static string SelectedGroup(ComboBox selector) => NormalizeGroup(selector.SelectedItem as string ?? "1");

    private readonly record struct UsageSource(string Label, string Group, JsonElement? Snapshot);
    private sealed record ConfiguredSource(
        [property: JsonPropertyName("name")] string Name,
        [property: JsonPropertyName("path")] string Path,
        [property: JsonPropertyName("group")] string Group,
        [property: JsonPropertyName("user")] string User = "",
        [property: JsonPropertyName("host")] string Host = "",
        [property: JsonPropertyName("port")] int Port = 22,
        [property: JsonPropertyName("key_path")] string KeyPath = "",
        [property: JsonPropertyName("sessions_path")] string SessionsPath = "~/.codex/sessions",
        [property: JsonPropertyName("profile_path")] string ProfilePath = "");
    private sealed record DisplaySettings(IReadOnlyList<ConfiguredSource> ClaudeDesktopSources, string ClaudeCliGroup, IReadOnlyList<ConfiguredSource> ClaudeCustomSources, string CodexDesktopGroup, string CodexCliGroup, IReadOnlyList<ConfiguredSource> CodexSshSources, string ClaudeUserEnvironment)
    {
        public string ClaudeDesktopGroup => ClaudeDesktopSources.FirstOrDefault()?.Group ?? "1";
        public string ClaudeCustomPath => ClaudeCustomSources.FirstOrDefault()?.Path ?? "";
        public string ClaudeCustomGroup => ClaudeCustomSources.FirstOrDefault()?.Group ?? "1";
        public string CodexSshGroup => CodexSshSources.FirstOrDefault()?.Group ?? "2";
        public static DisplaySettings Default { get; } = new(Array.Empty<ConfiguredSource>(), "1", Array.Empty<ConfiguredSource>(), "1", "1", Array.Empty<ConfiguredSource>(), "default");
        public static DisplaySettings FromJson(JsonElement root) => new(
            Sources(root, "claude_desktop_sources", null, "claude_desktop_group", "Desktop"), Group(root, "claude_cli_group", "1"), Sources(root, "claude_custom_sources", "claude_custom_path", "claude_custom_group", "Custom"),
            Group(root, "codex_desktop_group", "1"), Group(root, "codex_cli_group", "1"), Sources(root, "codex_ssh_sources", null, "codex_ssh_group", "SSH"), Environment(root));
        public object ToStorage() => new { claude_desktop_group = ClaudeDesktopGroup, claude_desktop_sources = ClaudeDesktopSources, claude_cli_group = ClaudeCliGroup, claude_custom_sources = ClaudeCustomSources, codex_desktop_group = CodexDesktopGroup, codex_cli_group = CodexCliGroup, codex_ssh_sources = CodexSshSources, claude_user_environment = ClaudeUserEnvironment };
        private static string String(JsonElement root, string name) => root.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() ?? "" : "";
        private static string Group(JsonElement root, string name, string fallback) { var value = String(root, name); return string.IsNullOrWhiteSpace(value) ? fallback : NormalizeGroup(value); }
        private static IReadOnlyList<ConfiguredSource> Sources(JsonElement root, string arrayName, string? legacyPathName, string legacyGroupName, string defaultName)
        {
            var result = new List<ConfiguredSource>();
            if (root.TryGetProperty(arrayName, out var array) && array.ValueKind == JsonValueKind.Array)
                foreach (var item in array.EnumerateArray())
                {
                    var path = String(item, "path");
                    var name = String(item, "name");
                    var group = Group(item, "group", "1");
                    var user = String(item, "user");
                    var host = String(item, "host");
                    var keyPath = String(item, "key_path");
                    var sessionsPath = String(item, "sessions_path");
                    var profilePath = String(item, "profile_path");
                    var port = item.TryGetProperty("port", out var portValue) && portValue.TryGetInt32(out var parsedPort) ? parsedPort : 22;
                    if (!string.IsNullOrWhiteSpace(path) || legacyPathName is null) result.Add(new(name, path, group, user, host, port, keyPath, string.IsNullOrWhiteSpace(sessionsPath) ? "~/.codex/sessions" : sessionsPath, profilePath));
                }
            if (result.Count == 0 && legacyPathName is not null)
            {
                var path = String(root, legacyPathName);
                if (!string.IsNullOrWhiteSpace(path)) result.Add(new(defaultName + " 1", path, Group(root, legacyGroupName, "1")));
            }
            return result;
        }
        private static string Environment(JsonElement root) { var value = String(root, "claude_user_environment"); return string.IsNullOrWhiteSpace(value) || value.Equals("self", StringComparison.OrdinalIgnoreCase) ? "default" : value; }
    }
}
