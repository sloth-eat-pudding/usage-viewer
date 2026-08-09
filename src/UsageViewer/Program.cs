using System.Diagnostics;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Windows.Forms;

namespace UsageViewer;

internal static class Program
{
    [STAThread]
    private static void Main()
    {
        NativeMethods.SetCurrentProcessExplicitAppUserModelID("SlothEatPudding.UsageViewer");
        ApplicationConfiguration.Initialize();
        Application.Run(new UsageOverlayForm());
    }
}

internal sealed class UsageOverlayForm : Form
{
    private readonly Size defaultWindowSize = new(440, 112);
    private readonly Point defaultWindowLocation = new(24, 48);
    private readonly string windowStateFile;
    private readonly string claudeUsageFile;
    private readonly string codexUsageFile;
    private readonly Panel panel;
    private readonly Label main;
    private readonly Label detail;
    private readonly Button resetButton;
    private readonly Button closeButton;
    private readonly System.Windows.Forms.Timer timer;
    private bool dragging;
    private Point dragStart;

    public UsageOverlayForm()
    {
        var usageHome = Environment.GetEnvironmentVariable("USAGE_VIEWER_HOME");
        if (string.IsNullOrWhiteSpace(usageHome))
        {
            usageHome = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                ".usage-viewer"
            );
        }

        claudeUsageFile = Path.Combine(usageHome, "claude-latest.json");
        codexUsageFile = Path.Combine(usageHome, "codex-latest.json");
        windowStateFile = Path.Combine(usageHome, "window-state.json");

        Text = "Usage Viewer";
        FormBorderStyle = FormBorderStyle.None;
        StartPosition = FormStartPosition.Manual;
        MinimumSize = new Size(360, 104);
        var savedBounds = LoadWindowBounds();
        Location = savedBounds.Location;
        Size = savedBounds.Size;
        TopMost = true;
        ShowIcon = true;
        ShowInTaskbar = true;
        BackColor = Color.FromArgb(1, 2, 3);
        TransparencyKey = BackColor;
        Opacity = 0.92;

        Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath);

        panel = new Panel
        {
            Dock = DockStyle.Fill,
            BackColor = Color.FromArgb(28, 32, 38)
        };
        Controls.Add(panel);

        resetButton = new Button
        {
            Anchor = AnchorStyles.Top | AnchorStyles.Right,
            FlatStyle = FlatStyle.Flat,
            BackColor = Color.FromArgb(28, 32, 38),
            ForeColor = Color.FromArgb(174, 185, 196),
            Font = new Font("Segoe UI", 9, FontStyle.Bold),
            Location = new Point(394, 6),
            Size = new Size(28, 24),
            Text = "R",
            TabStop = false
        };
        resetButton.FlatAppearance.BorderSize = 0;
        resetButton.Click += (_, _) =>
        {
            Location = defaultWindowLocation;
            Size = defaultWindowSize;
            SaveWindowBounds();
            UpdateUsageView();
            ResizeOverlayToContent();
        };
        panel.Controls.Add(resetButton);

        closeButton = new Button
        {
            Anchor = AnchorStyles.Top | AnchorStyles.Right,
            FlatStyle = FlatStyle.Flat,
            BackColor = Color.FromArgb(28, 32, 38),
            ForeColor = Color.FromArgb(220, 226, 232),
            Font = new Font("Segoe UI", 10, FontStyle.Bold),
            Location = new Point(426, 6),
            Size = new Size(28, 24),
            Text = "X",
            TabStop = false
        };
        closeButton.FlatAppearance.BorderSize = 0;
        closeButton.Click += (_, _) => Close();
        panel.Controls.Add(closeButton);

        main = new Label
        {
            AutoSize = false,
            Location = new Point(14, 12),
            Size = new Size(392, 48),
            Font = new Font("Cascadia Mono", 15, FontStyle.Bold),
            ForeColor = Color.FromArgb(126, 231, 180),
            Text = "Waiting for usage..."
        };
        panel.Controls.Add(main);

        detail = new Label
        {
            AutoSize = false,
            Location = new Point(14, 62),
            Size = new Size(392, 36),
            Font = new Font("Cascadia Mono", 9, FontStyle.Regular),
            ForeColor = Color.White,
            Text = ""
        };
        panel.Controls.Add(detail);

        foreach (Control control in new Control[] { this, panel, main, detail })
        {
            control.MouseDown += HandleMouseDown;
            control.MouseMove += HandleMouseMove;
            control.MouseUp += HandleMouseUp;
        }

        var menu = new ContextMenuStrip();
        var closeItem = new ToolStripMenuItem("Close");
        closeItem.Click += (_, _) => Close();
        menu.Items.Add(closeItem);
        ContextMenuStrip = menu;
        panel.ContextMenuStrip = menu;

        Resize += (_, _) => LayoutOverlay();
        ResizeEnd += (_, _) => SaveWindowBounds();
        Move += (_, _) =>
        {
            if (!dragging)
            {
                SaveWindowBounds();
            }
        };
        FormClosing += (_, _) => SaveWindowBounds();

        timer = new System.Windows.Forms.Timer
        {
            Interval = 1000
        };
        timer.Tick += (_, _) =>
        {
            UpdateUsageView();
            ResizeOverlayToContent();
        };

        UpdateUsageView();
        ResizeOverlayToContent();
        timer.Start();
    }

    protected override void WndProc(ref Message message)
    {
        const int wmNcHitTest = 0x84;
        const int htClient = 1;
        const int gripSize = 8;

        base.WndProc(ref message);

        if (message.Msg != wmNcHitTest || (int)message.Result != htClient)
        {
            return;
        }

        var cursor = PointToClient(Cursor.Position);
        var left = cursor.X <= gripSize;
        var right = cursor.X >= ClientSize.Width - gripSize;
        var top = cursor.Y <= gripSize;
        var bottom = cursor.Y >= ClientSize.Height - gripSize;

        message.Result = (left, right, top, bottom) switch
        {
            (true, _, true, _) => (IntPtr)13,
            (_, true, true, _) => (IntPtr)14,
            (true, _, _, true) => (IntPtr)16,
            (_, true, _, true) => (IntPtr)17,
            (true, _, _, _) => (IntPtr)10,
            (_, true, _, _) => (IntPtr)11,
            (_, _, true, _) => (IntPtr)12,
            (_, _, _, true) => (IntPtr)15,
            _ => message.Result
        };
    }

    private void LayoutOverlay()
    {
        main.Width = Math.Max(80, panel.ClientSize.Width - 28);
        detail.Width = main.Width;
        resetButton.Left = panel.ClientSize.Width - 66;
        closeButton.Left = panel.ClientSize.Width - 34;
    }

    private void HandleMouseDown(object? sender, MouseEventArgs e)
    {
        if (e.Button != MouseButtons.Left)
        {
            return;
        }

        var hitTest = GetResizeHitTest();
        if (hitTest != 0)
        {
            NativeMethods.ReleaseCapture();
            NativeMethods.SendMessage(Handle, NativeMethods.WmNcLButtonDown, hitTest, 0);
            return;
        }

        dragging = true;
        dragStart = e.Location;
    }

    private void HandleMouseMove(object? sender, MouseEventArgs e)
    {
        if (!dragging)
        {
            return;
        }

        Left += e.X - dragStart.X;
        Top += e.Y - dragStart.Y;
    }

    private void HandleMouseUp(object? sender, MouseEventArgs e)
    {
        if (dragging)
        {
            dragging = false;
            SaveWindowBounds();
            return;
        }

        dragging = false;
    }

    private int GetResizeHitTest()
    {
        const int grip = 10;
        var cursor = PointToClient(Cursor.Position);
        var left = cursor.X <= grip;
        var right = cursor.X >= ClientSize.Width - grip;
        var top = cursor.Y <= grip;
        var bottom = cursor.Y >= ClientSize.Height - grip;

        if (left && top) return 13;
        if (right && top) return 14;
        if (left && bottom) return 16;
        if (right && bottom) return 17;
        if (left) return 10;
        if (right) return 11;
        if (top) return 12;
        if (bottom) return 15;
        return 0;
    }

    private void UpdateUsageView()
    {
        using var claude = ReadUsageJson(claudeUsageFile);
        using var codex = ReadUsageJson(codexUsageFile);

        if (claude is null && codex is null)
        {
            main.Text = "Waiting for Claude / Codex usage...";
            detail.Text = "";
            return;
        }

        var codexLine = codex is null
            ? "Codex ?%"
            : $"Codex {FormatPercent(GetFirstDouble(codex.RootElement, new[] { "percentages", "seven_day_used" }, new[] { "percentages", "primary_limit_used" }), 2)}";

        var claudeLine = claude is null
            ? "Claude ?% ?%"
            : FormatClaudeUsageLine(claude.RootElement);

        main.Text = codexLine + Environment.NewLine + claudeLine;

        var codexTimeLine = codex is null
            ? "Codex ? reset ?"
            : $"Codex {FormatAge(GetTimestamp(codex.RootElement))} - {FormatReset(GetResetEpoch(codex.RootElement))}";

        var claudeTimeLine = claude is null
            ? "Claude ? reset ?"
            : $"Claude {FormatAge(GetTimestamp(claude.RootElement))} - {FormatReset(GetResetEpoch(claude.RootElement))}";

        detail.Text = codexTimeLine + Environment.NewLine + claudeTimeLine;
    }

    private void ResizeOverlayToContent()
    {
        var mainWidth = MeasureMultilineTextWidth(main.Text, main.Font);
        var detailWidth = MeasureMultilineTextWidth(detail.Text, detail.Font);
        var desiredWidth = Math.Max(MinimumSize.Width, Math.Max(mainWidth, detailWidth) + 34);
        desiredWidth = Math.Min(760, desiredWidth);

        if (Math.Abs(Width - desiredWidth) > 8)
        {
            Width = desiredWidth;
            SaveWindowBounds();
        }

        var desiredHeight = Math.Max(MinimumSize.Height, defaultWindowSize.Height);

        if (Math.Abs(Height - desiredHeight) > 6)
        {
            Height = desiredHeight;
            SaveWindowBounds();
        }
    }

    private Rectangle LoadWindowBounds()
    {
        try
        {
            if (!File.Exists(windowStateFile))
            {
                return new Rectangle(defaultWindowLocation, defaultWindowSize);
            }

            using var state = JsonDocument.Parse(File.ReadAllText(windowStateFile));
            var root = state.RootElement;
            var x = GetInt(root, "x") ?? defaultWindowLocation.X;
            var y = GetInt(root, "y") ?? defaultWindowLocation.Y;
            var width = Math.Max(MinimumSize.Width, GetInt(root, "width") ?? defaultWindowSize.Width);
            var height = Math.Max(MinimumSize.Height, GetInt(root, "height") ?? defaultWindowSize.Height);
            var bounds = new Rectangle(x, y, width, height);

            return IsVisibleOnAnyScreen(bounds)
                ? bounds
                : new Rectangle(defaultWindowLocation, defaultWindowSize);
        }
        catch (Exception error)
        {
            Debug.WriteLine(error.Message);
            return new Rectangle(defaultWindowLocation, defaultWindowSize);
        }
    }

    private void SaveWindowBounds()
    {
        if (WindowState != FormWindowState.Normal)
        {
            return;
        }

        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(windowStateFile)!);
            var state = new WindowStateSnapshot(Left, Top, Width, Height);
            var json = JsonSerializer.Serialize(state, new JsonSerializerOptions { WriteIndented = true });
            File.WriteAllText(windowStateFile, json);
        }
        catch (Exception error)
        {
            Debug.WriteLine(error.Message);
        }
    }

    private static bool IsVisibleOnAnyScreen(Rectangle bounds)
    {
        return Screen.AllScreens.Any(screen =>
        {
            var visibleArea = Rectangle.Intersect(screen.WorkingArea, bounds);
            return visibleArea.Width >= 80 && visibleArea.Height >= 40;
        });
    }

    private static int MeasureMultilineTextWidth(string text, Font font)
    {
        var maxWidth = 0;
        foreach (var line in text.Replace("\r\n", "\n").Split('\n'))
        {
            maxWidth = Math.Max(maxWidth, TextRenderer.MeasureText(line, font).Width);
        }

        return maxWidth;
    }

    private static JsonDocument? ReadUsageJson(string filename)
    {
        if (!File.Exists(filename))
        {
            return null;
        }

        try
        {
            return JsonDocument.Parse(File.ReadAllText(filename));
        }
        catch (Exception error)
        {
            Debug.WriteLine(error.Message);
            return null;
        }
    }

    private static double? GetFirstDouble(JsonElement root, params string[][] paths)
    {
        foreach (var path in paths)
        {
            var value = GetDouble(root, path);
            if (value is not null)
            {
                return value;
            }
        }

        return null;
    }

    private static double? GetDouble(JsonElement root, params string[] path)
    {
        var current = root;
        foreach (var part in path)
        {
            if (current.ValueKind != JsonValueKind.Object || !current.TryGetProperty(part, out current))
            {
                return null;
            }
        }

        return current.ValueKind switch
        {
            JsonValueKind.Number when current.TryGetDouble(out var number) => number,
            JsonValueKind.String when double.TryParse(current.GetString(), out var number) => number,
            _ => null
        };
    }

    private static int? GetInt(JsonElement root, string propertyName)
    {
        if (!root.TryGetProperty(propertyName, out var value) && !root.TryGetProperty(ToPascalCase(propertyName), out value))
        {
            return null;
        }

        return value.ValueKind switch
        {
            JsonValueKind.Number when value.TryGetInt32(out var number) => number,
            JsonValueKind.String when int.TryParse(value.GetString(), out var number) => number,
            _ => null
        };
    }

    private static string ToPascalCase(string value)
    {
        return string.IsNullOrEmpty(value)
            ? value
            : char.ToUpperInvariant(value[0]) + value[1..];
    }

    private static string FormatPercent(double? value, int digits)
    {
        return value is null ? "?" : value.Value.ToString($"N{digits}") + "%";
    }

    private static string FormatClaudeUsageLine(JsonElement root)
    {
        var week = FormatPercent(GetDouble(root, "percentages", "seven_day_used"), 2);
        var fiveHour = FormatPercent(GetDouble(root, "percentages", "five_hour_used"), 2);

        if (week != "?" || fiveHour != "?")
        {
            return $"Claude {week} {fiveHour}";
        }

        return $"Claude in {FormatCompactCount(GetDouble(root, "tokens", "total_input"))} out {FormatCompactCount(GetDouble(root, "tokens", "output"))}";
    }

    private static string FormatCompactCount(double? value)
    {
        if (value is null)
        {
            return "?";
        }

        if (value >= 1_000_000)
        {
            return (value.Value / 1_000_000).ToString("N1") + "m";
        }

        if (value >= 1_000)
        {
            return (value.Value / 1_000).ToString("N1") + "k";
        }

        return value.Value.ToString("N0");
    }

    private static string? GetTimestamp(JsonElement root)
    {
        return GetString(root, "observed_at") ?? GetString(root, "generated_at");
    }

    private static string? GetString(JsonElement root, string propertyName)
    {
        if (!root.TryGetProperty(propertyName, out var value))
        {
            return null;
        }

        return value.ValueKind == JsonValueKind.String
            ? value.GetString()
            : null;
    }

    private static double? GetResetEpoch(JsonElement root)
    {
        return GetFirstDouble(
            root,
            new[] { "resets_at", "seven_day_epoch_seconds" },
            new[] { "rate_limits", "primary", "resets_at_epoch_seconds" }
        );
    }

    private static string FormatAge(string? iso)
    {
        if (string.IsNullOrWhiteSpace(iso) || !DateTimeOffset.TryParse(iso, out var timestamp))
        {
            return "?";
        }

        var age = DateTimeOffset.Now - timestamp;

        if (age.TotalSeconds < 60)
        {
            return Math.Max(0, (int)age.TotalSeconds) + "s ago";
        }

        if (age.TotalMinutes < 60)
        {
            return (int)age.TotalMinutes + "m ago";
        }

        return (int)age.TotalHours + "h ago";
    }

    private static string FormatReset(double? epochSeconds)
    {
        if (epochSeconds is null)
        {
            return "?";
        }

        try
        {
            return DateTimeOffset
                .FromUnixTimeSeconds((long)epochSeconds.Value)
                .ToLocalTime()
                .ToString("ddd HH:mm");
        }
        catch
        {
            return "?";
        }
    }
}

internal sealed record WindowStateSnapshot(
    [property: JsonPropertyName("x")] int X,
    [property: JsonPropertyName("y")] int Y,
    [property: JsonPropertyName("width")] int Width,
    [property: JsonPropertyName("height")] int Height
);

internal static class NativeMethods
{
    public const int WmNcLButtonDown = 0xA1;

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern int SetCurrentProcessExplicitAppUserModelID(string appID);

    [DllImport("user32.dll")]
    public static extern bool ReleaseCapture();

    [DllImport("user32.dll")]
    public static extern IntPtr SendMessage(IntPtr hWnd, int msg, int wParam, int lParam);
}
