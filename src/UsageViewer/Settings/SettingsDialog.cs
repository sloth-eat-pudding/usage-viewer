using System.Collections.ObjectModel;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using Microsoft.Win32;
using static UsageViewer.DisplayGroups;

namespace UsageViewer;

internal static class SettingsDialog
{
    internal static DisplaySettings? Show(Window owner, bool settingsOnly, DisplaySettings settings, IReadOnlyList<ConfiguredSource> detectedDesktop)
    {
        DisplaySettings? result = null;
        var dialog = new Window
        {
            Title = "Usage Viewer Settings", Owner = owner, WindowStartupLocation = settingsOnly ? WindowStartupLocation.CenterScreen : WindowStartupLocation.CenterOwner,
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
        var groupCodes = BuildGroupCodes(settings);
        AddSettingsSection(content, "Display layout");
        var layoutSelector = new ComboBox { Width = 260, HorizontalAlignment = HorizontalAlignment.Left, ItemsSource = new[] { "Two rows / columns", "Stacked rows" }, SelectedIndex = settings.DisplayLayout == "stacked" ? 1 : 0 };
        content.Children.Add(layoutSelector);
        AddSettingsSection(content, "Built-in sources");
        var configuredDesktop = detectedDesktop.Select((source, index) =>
        {
            var saved = settings.ClaudeDesktopSources.FirstOrDefault(item => item.Path.Equals(source.Path, StringComparison.OrdinalIgnoreCase));
            var fallbackGroup = source.Group;
            return new ConfiguredSource(source.Name, source.Path, saved?.Group ?? fallbackGroup);
        }).ToList();
        if (configuredDesktop.Count == 0) configuredDesktop.Add(new ConfiguredSource("Claude Desktop", "", settings.ClaudeDesktopGroup));
        var claudeDesktopSelectors = configuredDesktop.Select(source => AddGroupSelector(content, source.Name, source.Group, groupCodes)).ToList();
        var claudeCli = AddGroupSelector(content, "Claude CLI", settings.ClaudeCliGroup, groupCodes);
        var codexDesktop = AddGroupSelector(content, "Codex Desktop", settings.CodexDesktopGroup, groupCodes);
        var codexCli = AddGroupSelector(content, "Codex CLI", settings.CodexCliGroup, groupCodes);
        AddSettingsSection(content, "Codex account windows");
        content.Children.Add(new TextBlock { Text = "Choose a data folder for a Codex window with full width, cache timing and cost estimates (Node.js 22+).", Foreground = System.Windows.Media.Brushes.Gray, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 6) });
        var codexAccounts = new ComboBox { Width = 260, DisplayMemberPath = nameof(CodexAccountChoice.Name) };
        void RefreshCodexAccounts()
        {
            var (accounts, selected) = ReadCodexAccounts();
            codexAccounts.ItemsSource = accounts;
            codexAccounts.SelectedItem = accounts.FirstOrDefault(account => account.Id == selected) ?? accounts.FirstOrDefault();
        }
        RefreshCodexAccounts();
        codexAccounts.DropDownOpened += (_, _) => RefreshCodexAccounts();
        var openCodex = new Button { Content = "Open", Margin = new Thickness(8, 0, 0, 0), Padding = new Thickness(10, 4, 10, 4) };
        openCodex.Click += (_, _) => { if (codexAccounts.SelectedItem is CodexAccountChoice account) OpenCodexProfileCreator(dialog, account.Id); };
        var createCodex = new Button { Content = "Manage accounts…", Margin = new Thickness(8, 0, 0, 0), Padding = new Thickness(10, 4, 10, 4) };
        createCodex.Click += (_, _) => OpenCodexProfileCreator(dialog);
        var codexAccountRow = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 0, 8) };
        codexAccountRow.Children.Add(codexAccounts); codexAccountRow.Children.Add(openCodex); codexAccountRow.Children.Add(createCodex);
        content.Children.Add(codexAccountRow);
        AddSettingsSection(content, "Claude Custom sources");
        AddEditorHeader(content, false);
        var customRows = new List<SourceEditor>(); var customList = new StackPanel(); content.Children.Add(customList);
        foreach (var source in settings.ClaudeCustomSources) AddCustomEditor(customList, customRows, source, dialog, groupCodes);
        var environmentOptions = new ObservableCollection<string>(new[] { "default" }.Concat(settings.ClaudeCustomSources.Select(source => source.Name).Where(name => !string.IsNullOrWhiteSpace(name))).Distinct(StringComparer.OrdinalIgnoreCase));
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
        foreach (var source in settings.CodexSshSources) AddSshEditor(sshList, sshRows, source, groupCodes);
        var addSsh = new Button { Content = "+  Add SSH source", HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 5, 0, 10), Padding = new Thickness(10, 3, 10, 3) }; addSsh.Click += (_, _) => AddSshEditor(sshList, sshRows, new ConfiguredSource($"SSH {sshRows.Count + 1}", "", AddNextGroupCode(groupCodes)), groupCodes); content.Children.Add(addSsh);
        AddSettingsSection(content, "Claude user environment");
        var environmentSelector = new ComboBox { Width = 260, ItemsSource = environmentOptions, SelectedItem = environmentOptions.Contains(settings.ClaudeUserEnvironment, StringComparer.OrdinalIgnoreCase) ? settings.ClaudeUserEnvironment : "default" };
        var openEnvironment = new Button { Content = "Open", Margin = new Thickness(8, 0, 0, 0), Padding = new Thickness(10, 3, 10, 3) }; var selectedEnvironment = environmentSelector.SelectedItem as string ?? "default";
        openEnvironment.Click += (_, _) => OpenClaudeEnvironment(selectedEnvironment, settings.ClaudeCustomSources);
        environmentSelector.SelectionChanged += (_, _) => selectedEnvironment = environmentSelector.SelectedItem as string ?? "default";
        var environmentRow = new StackPanel { Orientation = Orientation.Horizontal }; environmentRow.Children.Add(environmentSelector); environmentRow.Children.Add(openEnvironment); content.Children.Add(environmentRow);
        var actions = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 12, 0, 0) }; var cancel = new Button { Content = "Cancel", MinWidth = 80, Margin = new Thickness(0, 0, 8, 0), Padding = new Thickness(8, 3, 8, 3) }; cancel.Click += (_, _) => dialog.Close(); var save = new Button { Content = "Save", MinWidth = 80, IsDefault = true, Padding = new Thickness(8, 3, 8, 3) }; save.Click += (_, _) => { IReadOnlyList<ConfiguredSource> desktopSources = detectedDesktop.Count == 0 ? new List<ConfiguredSource>() : configuredDesktop.Select((source, index) => source with { Group = SelectedGroup(claudeDesktopSelectors[index]) }).ToList(); result = new DisplaySettings(desktopSources, SelectedGroup(claudeCli), customRows.Where(row => !string.IsNullOrWhiteSpace(row.Name.Text)).Select(row => row.ToSource()).ToList(), SelectedGroup(codexDesktop), SelectedGroup(codexCli), sshRows.Where(row => !string.IsNullOrWhiteSpace(row.Host.Text)).Select(row => row.ToSource()).ToList(), selectedEnvironment, layoutSelector.SelectedIndex == 1 ? "stacked" : "columns"); dialog.Close(); }; actions.Children.Add(cancel); actions.Children.Add(save); Grid.SetRow(actions, 2); root.Children.Add(actions); dialog.ShowDialog();
        return result;
    }

    private static void AddSettingsSection(Panel panel, string title)
    {
        panel.Children.Add(new Border { Height = 1, Background = System.Windows.Media.Brushes.DimGray, Margin = new Thickness(0, 8, 0, 8) });
        panel.Children.Add(new TextBlock { Text = title, Foreground = System.Windows.Media.Brushes.White, FontSize = 13, FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 0, 0, 5) });
    }

    private sealed record CodexAccountChoice(string Id, string Name);

    private static (List<CodexAccountChoice> Accounts, string Selected) ReadCodexAccounts()
    {
        var accounts = new List<CodexAccountChoice>();
        var selected = "default";
        try
        {
            var home = Environment.GetEnvironmentVariable("USAGE_VIEWER_HOME") ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".usage-viewer");
            using var document = System.Text.Json.JsonDocument.Parse(File.ReadAllText(Path.Combine(home, "codex-account-profile-ui.json")));
            var root = document.RootElement;
            if (root.TryGetProperty("selected_id", out var choice)) selected = choice.GetString() ?? selected;
            if (root.TryGetProperty("profiles", out var profiles))
                foreach (var profile in profiles.EnumerateArray())
                {
                    var id = profile.GetProperty("id").GetString();
                    var name = profile.GetProperty("name").GetString();
                    if (!string.IsNullOrWhiteSpace(id) && !string.IsNullOrWhiteSpace(name)) accounts.Add(new(id, name));
                }
        }
        catch { }
        if (!accounts.Any(account => account.Id == "default")) accounts.Insert(0, new CodexAccountChoice("default", "Codex"));
        return (accounts, selected);
    }

    private static void OpenCodexProfileCreator(Window owner, string? profileId = null)
    {
        try
        {
            var home = Environment.GetEnvironmentVariable("USAGE_VIEWER_HOME") ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".usage-viewer");
            var scripts = Path.Combine(home, "profile-launcher");
            Directory.CreateDirectory(scripts);
            foreach (var (resourceName, filename) in new[] {
                ("UsageViewer.CreateCodexAccountProfile.ps1", "create-codex-account-profile.ps1"),
                ("UsageViewer.CodexAccountRegistry.ps1", "codex-account-registry.ps1"),
                ("UsageViewer.StartCodexAccountProfile.ps1", "start-codex-account-profile.ps1"),
                ("UsageViewer.StartCodexNativeMeter.ps1", "start-codex-native-meter.ps1"),
                ("UsageViewer.CodexNativeDriver.cjs", "codex-native-meter.cjs"),
                ("UsageViewer.CodexProfileMetrics.cjs", "codex-profile-metrics.cjs"),
                ("UsageViewer.CodexDesktopUsage.cjs", "codex-desktop-usage.cjs"),
                ("UsageViewer.CodexNativeMeter.js", "codex-native-meter.js") })
            {
                using var resource = typeof(SettingsDialog).Assembly.GetManifestResourceStream(resourceName) ?? throw new InvalidDataException($"Missing {resourceName}");
                using var reader = new StreamReader(resource);
                File.WriteAllText(Path.Combine(scripts, filename), reader.ReadToEnd(), new System.Text.UTF8Encoding(filename.EndsWith(".ps1", StringComparison.OrdinalIgnoreCase)));
            }
            var start = new ProcessStartInfo { FileName = "powershell.exe", UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = scripts };
            foreach (var argument in new[] { "-NoProfile", "-STA", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-File", Path.Combine(scripts, "create-codex-account-profile.ps1") }) start.ArgumentList.Add(argument);
            if (profileId is not null) { start.ArgumentList.Add("-OpenProfileId"); start.ArgumentList.Add(profileId); }
            Process.Start(start);
        }
        catch (Exception error) { MessageBox.Show(owner, error.Message, "Codex account window", MessageBoxButton.OK, MessageBoxImage.Error); }
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

    private static ComboBox AddGroupSelector(Panel panel, string label, string selected, ObservableCollection<string> groupCodes)
    {
        var row = new Grid { Margin = new Thickness(0, 0, 0, 7) };
        row.ColumnDefinitions.Add(new ColumnDefinition()); row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(115) });
        var text = new TextBlock { Text = label, Foreground = System.Windows.Media.Brushes.LightGray, VerticalAlignment = VerticalAlignment.Center };
        var selector = new ComboBox { ItemsSource = groupCodes, SelectedItem = NormalizeGroup(selected) };
        Grid.SetColumn(selector, 1); row.Children.Add(text); row.Children.Add(selector); panel.Children.Add(row);
        return selector;
    }

    private static string SelectedGroup(ComboBox selector) => NormalizeGroup(selector.SelectedItem as string ?? "1");

}
