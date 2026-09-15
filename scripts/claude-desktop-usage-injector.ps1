$ErrorActionPreference = 'SilentlyContinue'

if ($env:CLAUDE_DESKTOP_AUTO_BRIDGE -eq '0') { exit 0 }

$usageHome = if ([string]::IsNullOrWhiteSpace($env:USAGE_VIEWER_HOME)) {
  Join-Path $env:USERPROFILE '.usage-viewer'
} else {
  $env:USAGE_VIEWER_HOME
}
$logFile = Join-Path $usageHome 'claude-desktop-usage-injector.log'
$createdNew = $false
$mutex = [System.Threading.Mutex]::new($true, 'UsageViewer.ClaudeDesktopUsageInjector.v1', [ref]$createdNew)
if (-not $createdNew) { exit 0 }

New-Item -ItemType Directory -Path $usageHome -Force | Out-Null
[IO.File]::AppendAllText($logFile, "$([DateTimeOffset]::UtcNow.ToString('O')) native helper loading$([Environment]::NewLine)")

function Write-InjectorLog {
  param([string]$Message)
  Add-Content -LiteralPath $logFile -Value "$([DateTimeOffset]::UtcNow.ToString('O')) $Message" -Encoding UTF8
}

Add-Type -AssemblyName System.Windows.Forms

Add-Type @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public static class ClaudeUsageInjectorNative
{
    private const uint INPUT_KEYBOARD = 1;
    private const uint KEYEVENTF_KEYUP = 0x0002;
    private const uint KEYEVENTF_UNICODE = 0x0004;
    private const uint WM_CLOSE = 0x0010;
    private const uint WM_COMMAND = 0x0111;
    private const uint MF_BYPOSITION = 0x0400;
    private const byte VK_CONTROL = 0x11;
    private const byte VK_SHIFT = 0x10;
    private const byte VK_MENU = 0x12;
    private const byte VK_I = 0x49;
    private const byte VK_J = 0x4A;
    private const byte VK_P = 0x50;
    private const byte VK_V = 0x56;

    public sealed class WindowInfo
    {
        public long Handle { get; set; }
        public int ProcessId { get; set; }
        public string Title { get; set; }
        public long Area { get; set; }
        public bool Cloaked { get; set; }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct RECT { public int left, top, right, bottom; }

    [StructLayout(LayoutKind.Sequential)]
    private struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }

    [StructLayout(LayoutKind.Sequential)]
    private struct MOUSEINPUT
    {
        public int dx, dy;
        public uint mouseData, dwFlags, time;
        public UIntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct KEYBDINPUT
    {
        public ushort wVk, wScan;
        public uint dwFlags, time;
        public UIntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Explicit)]
    private struct INPUTUNION
    {
        [FieldOffset(0)] public MOUSEINPUT mi;
        [FieldOffset(0)] public KEYBDINPUT ki;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct INPUT { public uint type; public INPUTUNION data; }

    private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
    [DllImport("dwmapi.dll")] private static extern int DwmGetWindowAttribute(IntPtr hWnd, int attribute, out int value, int size);
    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] private static extern void SwitchToThisWindow(IntPtr hWnd, bool altTab);
    [DllImport("user32.dll")] private static extern bool BringWindowToTop(IntPtr hWnd);
    [DllImport("user32.dll")] private static extern bool ShowWindow(IntPtr hWnd, int command);
    [DllImport("user32.dll")] private static extern bool AttachThreadInput(uint attach, uint attachTo, bool value);
    [DllImport("kernel32.dll")] private static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] private static extern bool PostMessage(IntPtr hWnd, uint message, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] private static extern IntPtr GetMenu(IntPtr hWnd);
    [DllImport("user32.dll")] private static extern int GetMenuItemCount(IntPtr menu);
    [DllImport("user32.dll")] private static extern IntPtr GetSubMenu(IntPtr menu, int position);
    [DllImport("user32.dll")] private static extern uint GetMenuItemID(IntPtr menu, int position);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetMenuString(IntPtr menu, uint item, StringBuilder text, int count, uint flags);
    [DllImport("user32.dll")] private static extern void keybd_event(byte virtualKey, byte scanCode, uint flags, UIntPtr extraInfo);
    [DllImport("user32.dll")] private static extern uint SendInput(uint count, INPUT[] inputs, int size);
    [DllImport("user32.dll")] private static extern bool GetLastInputInfo(ref LASTINPUTINFO info);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint message, IntPtr wParam, string lParam, uint flags, uint timeout, out IntPtr result);

    public static WindowInfo[] FindClaudeWindows(bool devTools)
    {
        var processIds = new HashSet<int>();
        foreach (var process in Process.GetProcessesByName("Claude")) processIds.Add(process.Id);
        var windows = new List<WindowInfo>();
        EnumWindows((handle, _) => {
            uint processId;
            GetWindowThreadProcessId(handle, out processId);
            if (!processIds.Contains((int)processId) || !IsWindowVisible(handle)) return true;
            var title = new StringBuilder(512);
            GetWindowText(handle, title, title.Capacity);
            RECT rect;
            GetWindowRect(handle, out rect);
            int cloakedValue;
            var cloaked = DwmGetWindowAttribute(handle, 14, out cloakedValue, sizeof(int)) == 0 && cloakedValue != 0;
            var area = Math.Max(0, rect.right - rect.left) * (long)Math.Max(0, rect.bottom - rect.top);
            var windowTitle = title.ToString();
            var isDevTools = windowTitle.IndexOf("DevTools", StringComparison.OrdinalIgnoreCase) >= 0 ||
                windowTitle.IndexOf("Developer Tools", StringComparison.OrdinalIgnoreCase) >= 0;
            if (isDevTools == devTools)
                windows.Add(new WindowInfo { Handle = handle.ToInt64(), ProcessId = (int)processId, Title = windowTitle, Area = area, Cloaked = cloaked });
            return true;
        }, IntPtr.Zero);
        return windows.ToArray();
    }

    public static long ForegroundWindow() { return GetForegroundWindow().ToInt64(); }
    public static bool Focus(long handle)
    {
        if (handle == 0) return false;
        var window = new IntPtr(handle);
        var currentThread = GetCurrentThreadId();
        uint foregroundProcessId;
        var foregroundThread = GetWindowThreadProcessId(GetForegroundWindow(), out foregroundProcessId);
        var attached = foregroundThread != 0 && foregroundThread != currentThread && AttachThreadInput(currentThread, foregroundThread, true);
        try
        {
            ShowWindow(window, 9);
            BringWindowToTop(window);
            SetForegroundWindow(window);
            if (GetForegroundWindow() != window) SwitchToThisWindow(window, true);
            return GetForegroundWindow() == window;
        }
        finally { if (attached) AttachThreadInput(currentThread, foregroundThread, false); }
    }
    public static void Close(long handle) { if (handle != 0) PostMessage(new IntPtr(handle), WM_CLOSE, IntPtr.Zero, IntPtr.Zero); }

    public static bool OpenDevToolsFromMenu(long handle)
    {
        if (handle == 0) return false;
        uint command;
        if (!FindDevToolsCommand(GetMenu(new IntPtr(handle)), out command)) return false;
        return PostMessage(new IntPtr(handle), WM_COMMAND, new IntPtr(command), IntPtr.Zero);
    }

    private static bool FindDevToolsCommand(IntPtr menu, out uint command)
    {
        command = 0;
        if (menu == IntPtr.Zero) return false;
        var count = GetMenuItemCount(menu);
        for (var position = 0; position < count; position++)
        {
            var submenu = GetSubMenu(menu, position);
            if (submenu != IntPtr.Zero && FindDevToolsCommand(submenu, out command)) return true;
            var text = new StringBuilder(256);
            GetMenuString(menu, (uint)position, text, text.Capacity, MF_BYPOSITION);
            var label = text.ToString().Replace("&", "");
            if (label.IndexOf("Show Dev Tools", StringComparison.OrdinalIgnoreCase) < 0 ||
                label.IndexOf("Show All", StringComparison.OrdinalIgnoreCase) >= 0) continue;
            var id = GetMenuItemID(menu, position);
            if (id == UInt32.MaxValue) continue;
            command = id;
            return true;
        }
        return false;
    }

    public static uint IdleMilliseconds()
    {
        var info = new LASTINPUTINFO { cbSize = (uint)Marshal.SizeOf(typeof(LASTINPUTINFO)) };
        return GetLastInputInfo(ref info) ? unchecked((uint)Environment.TickCount - info.dwTime) : 0;
    }

    public static void BroadcastEnvironmentChanged()
    {
        IntPtr result;
        SendMessageTimeout(new IntPtr(0xffff), 0x001A, IntPtr.Zero, "Environment", 0x0002, 5000, out result);
    }

    public static void OpenDevTools()
    {
        SendChord(VK_CONTROL, VK_MENU, VK_I);
    }

    public static void OpenCommandMenu()
    {
        SendChord(VK_CONTROL, VK_SHIFT, VK_P);
    }

    public static void ShowConsolePanel()
    {
        SendChord(VK_CONTROL, VK_SHIFT, VK_J);
    }

    public static void OpenConsole()
    {
        SendShortcut(VK_CONTROL, 0xC0);
    }

    public static void Paste()
    {
        SendShortcut(VK_CONTROL, VK_V);
    }

    public static void Execute()
    {
        keybd_event(0x0D, 0, 0, UIntPtr.Zero);
        keybd_event(0x0D, 0, KEYEVENTF_KEYUP, UIntPtr.Zero);
    }

    private static void SendShortcut(byte modifier, byte key)
    {
        keybd_event(modifier, 0, 0, UIntPtr.Zero);
        keybd_event(key, 0, 0, UIntPtr.Zero);
        keybd_event(key, 0, KEYEVENTF_KEYUP, UIntPtr.Zero);
        keybd_event(modifier, 0, KEYEVENTF_KEYUP, UIntPtr.Zero);
    }

    private static void SendChord(byte first, byte second, byte key)
    {
        var inputs = new INPUT[6];
        inputs[0].type = inputs[1].type = inputs[2].type = inputs[3].type = inputs[4].type = inputs[5].type = INPUT_KEYBOARD;
        inputs[0].data.ki.wVk = first;
        inputs[1].data.ki.wVk = second;
        inputs[2].data.ki.wVk = key;
        inputs[3].data.ki.wVk = key;
        inputs[3].data.ki.dwFlags = KEYEVENTF_KEYUP;
        inputs[4].data.ki.wVk = second;
        inputs[4].data.ki.dwFlags = KEYEVENTF_KEYUP;
        inputs[5].data.ki.wVk = first;
        inputs[5].data.ki.dwFlags = KEYEVENTF_KEYUP;
        SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(INPUT)));
    }

    public static bool TypeUnicode(string text)
    {
        foreach (char character in text)
        {
            var inputs = new INPUT[2];
            inputs[0].type = INPUT_KEYBOARD;
            inputs[0].data.ki.wScan = character;
            inputs[0].data.ki.dwFlags = KEYEVENTF_UNICODE;
            inputs[1] = inputs[0];
            inputs[1].data.ki.dwFlags = KEYEVENTF_UNICODE | KEYEVENTF_KEYUP;
            if (SendInput(2, inputs, Marshal.SizeOf(typeof(INPUT))) != 2) return false;
            // Electron can acknowledge a large burst while dropping characters
            // before the DevTools editor processes them.
            Thread.Sleep(2);
        }
        keybd_event(0x0D, 0, 0, UIntPtr.Zero);
        keybd_event(0x0D, 0, KEYEVENTF_KEYUP, UIntPtr.Zero);
        return true;
    }
}
'@

$developerModeEnabled = $false
$developerSettings = @((Join-Path $env:APPDATA 'Claude\developer_settings.json'))
$packagesRoot = Join-Path $env:LOCALAPPDATA 'Packages'
if (Test-Path -LiteralPath $packagesRoot) {
  $developerSettings += @(Get-ChildItem -LiteralPath $packagesRoot -Directory -Filter 'Claude_*' |
    ForEach-Object { Join-Path $_.FullName 'LocalCache\Roaming\Claude\developer_settings.json' })
}
foreach ($settingsFile in $developerSettings) {
  try {
    if ((Get-Content -LiteralPath $settingsFile -Raw | ConvertFrom-Json).allowDevTools -eq $true) {
      $developerModeEnabled = $true
      break
    }
  } catch {}
}

$savedDevToolsMode = [Environment]::GetEnvironmentVariable('CLAUDE_DEV_TOOLS', 'User')
if (-not $developerModeEnabled) {
  Write-InjectorLog 'Claude Developer Mode is not enabled; automatic injection is waiting.'
} elseif ([string]::IsNullOrWhiteSpace($savedDevToolsMode)) {
  Write-InjectorLog 'setup required: run scripts\configure-claude-desktop-auto-bridge.ps1 once'
}

function Get-ClaudeOrganizations {
  $files = @()
  $settingsFile = Join-Path $usageHome 'display-settings.json'
  $environment = 'default'
  try {
    if (Test-Path -LiteralPath $settingsFile) {
      $environment = [string]((Get-Content -LiteralPath $settingsFile -Raw | ConvertFrom-Json).claude_user_environment)
    }
  } catch {}

  if ([string]::IsNullOrWhiteSpace($environment) -or $environment -eq 'default') {
    $regular = Join-Path $env:APPDATA 'Claude\plan-usage-history.json'
    if (Test-Path -LiteralPath $regular) { $files += $regular }
    $packages = Join-Path $env:LOCALAPPDATA 'Packages'
    if (Test-Path -LiteralPath $packages) {
      $files += @(Get-ChildItem -LiteralPath $packages -Directory -Filter 'Claude_*' |
        ForEach-Object { Join-Path $_.FullName 'LocalCache\Roaming\Claude\plan-usage-history.json' } |
        Where-Object { Test-Path -LiteralPath $_ })
    }
    # Include every configured Claude profile as well.  Profiles such as
    # Claude-Self live outside the regular APPDATA/MSIX locations and would
    # otherwise be displayed by the reader but never included in the bridge
    # injection target list.
    $customSourcesFile = Join-Path $usageHome 'claude-custom-source.json'
    if (Test-Path -LiteralPath $customSourcesFile) {
      try {
        $customSettings = Get-Content -LiteralPath $customSourcesFile -Raw | ConvertFrom-Json
        $customSources = if ($null -ne $customSettings.sources) { @($customSettings.sources) } else { @($customSettings) }
        $files += @($customSources | ForEach-Object { [string]$_.path } |
          Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and (Test-Path -LiteralPath $_) })
      } catch {}
    }
  } else {
    # The DevTools request runs inside the profile opened by Settings. Use only
    # that profile's history so its organization ID matches its session token.
    $customSourcesFile = Join-Path $usageHome 'claude-custom-source.json'
    if (Test-Path -LiteralPath $customSourcesFile) {
      try {
        $customSettings = Get-Content -LiteralPath $customSourcesFile -Raw | ConvertFrom-Json
        $customSources = if ($null -ne $customSettings.sources) { @($customSettings.sources) } else { @($customSettings) }
        $files += @($customSources | Where-Object { [string]$_.name -eq $environment } | ForEach-Object { [string]$_.path } |
          Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and (Test-Path -LiteralPath $_) })
      } catch {}
    }
  }
  $organizations = @()
  foreach ($file in $files) {
    try {
      $history = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
      $organizations += @($history.samples | ForEach-Object { [string]$_.org } |
        Where-Object { $_ -match '^[0-9a-fA-F-]{36}$' })
    } catch {}
  }
  return @($organizations | Sort-Object -Unique)
}

function Get-StaleClaudeOrganizations {
  param([string[]]$Organizations)
  $stale = @()
  foreach ($organization in $Organizations) {
    $snapshot = Join-Path $usageHome "claude-desktop-api-$organization-latest.json"
    if (-not (Test-Path -LiteralPath $snapshot) -or
        ([DateTimeOffset]::UtcNow - [DateTimeOffset](Get-Item -LiteralPath $snapshot).LastWriteTimeUtc).TotalSeconds -ge 150) {
      $stale += $organization
    }
  }
  return @($stale)
}

function Test-FreshBridgeSnapshot {
  param([string[]]$Organizations)
  return $Organizations.Count -gt 0 -and @(Get-StaleClaudeOrganizations $Organizations).Count -eq 0
}

function New-InjectionScript {
  param([string[]]$Organizations)
  # Passing a one-item array through the pipeline is unwrapped by PowerShell,
  # producing a JSON string. -InputObject preserves the array so JavaScript
  # iterates organization IDs instead of individual UUID characters.
  $organizationJson = ConvertTo-Json -InputObject @($Organizations) -Compress
  $diagnosticProbe = if ($env:CLAUDE_DESKTOP_AUTO_BRIDGE_KEEP_DEVTOOLS -eq '1') {
    "const dt=document.title;document.title='Usage Viewer injection probe';setTimeout(()=>document.title=dt,10000);"
  } else { '' }
  return @"
(()=>{$diagnosticProbe const k='__usageViewerBridgeV2',o=$organizationJson;if(window[k])clearInterval(window[k]);const f=async()=>{for(const g of o)try{const r=await fetch('/api/organizations/'+g+'/usage');if(!r.ok)continue;const u=await r.json();await fetch('http://127.0.0.1:8765/claude-desktop-usage?org='+encodeURIComponent(g),{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(u)})}catch{}};f();window[k]=setInterval(f,60000)})()
"@.Trim()
}

function Invoke-ClaudeInjection {
  param([object]$Window, [string[]]$Organizations)
  $previousForeground = [ClaudeUsageInjectorNative]::ForegroundWindow()
  $devTools = [ClaudeUsageInjectorNative]::FindClaudeWindows($true) |
    Where-Object { $_.ProcessId -eq $Window.ProcessId } |
    Select-Object -First 1
  if ($null -eq $devTools) {
    if (-not [ClaudeUsageInjectorNative]::Focus($Window.Handle)) {
      Write-InjectorLog 'could not focus Claude to open DevTools'
      return $false
    }
    [ClaudeUsageInjectorNative]::OpenDevTools()
    for ($wait = 0; $wait -lt 15 -and $null -eq $devTools; $wait++) {
      Start-Sleep -Milliseconds 300
      $devTools = [ClaudeUsageInjectorNative]::FindClaudeWindows($true) |
        Where-Object { $_.ProcessId -eq $Window.ProcessId } |
        Select-Object -First 1
    }
    if ($null -eq $devTools) {
      Write-InjectorLog 'could not open Claude DevTools; Developer Mode may not be active for this process'
      return $false
    }
    Write-InjectorLog 'opened Claude DevTools for injection'
  }

  if (-not [ClaudeUsageInjectorNative]::Focus($devTools.Handle)) { return $false }
  Start-Sleep -Milliseconds 300
  [ClaudeUsageInjectorNative]::OpenCommandMenu()
  Start-Sleep -Milliseconds 300
  [ClaudeUsageInjectorNative]::TypeUnicode('Show Console') | Out-Null
  Start-Sleep -Milliseconds 1200
  [ClaudeUsageInjectorNative]::OpenConsole()
  Start-Sleep -Milliseconds 400
  [ClaudeUsageInjectorNative]::TypeUnicode('allow pasting') | Out-Null
  Start-Sleep -Milliseconds 300
  $injectionScript = New-InjectionScript $Organizations
  Write-InjectorLog "pasting injection script characters=$($injectionScript.Length)"
  $typed = $false
  $previousClipboard = $null
  $hadClipboardData = $false
  try {
    $previousClipboard = [System.Windows.Forms.Clipboard]::GetDataObject()
    $hadClipboardData = $null -ne $previousClipboard
    Write-InjectorLog 'clipboard captured'
    [System.Windows.Forms.Clipboard]::SetText($injectionScript)
    Write-InjectorLog 'clipboard prepared'
    [ClaudeUsageInjectorNative]::Paste()
    Start-Sleep -Milliseconds 400
    [ClaudeUsageInjectorNative]::Execute()
    Write-InjectorLog 'clipboard paste executed'
    $typed = $true
  } catch {
    Write-InjectorLog 'clipboard paste failed; falling back to paced keyboard input'
    $typed = [ClaudeUsageInjectorNative]::TypeUnicode($injectionScript)
  } finally {
    Start-Sleep -Milliseconds 300
    try {
      if ($hadClipboardData) {
        [System.Windows.Forms.Clipboard]::SetDataObject($previousClipboard, $true)
      } else {
        [System.Windows.Forms.Clipboard]::Clear()
      }
      Write-InjectorLog 'clipboard restored'
    } catch {
      Write-InjectorLog 'clipboard restore failed'
    }
  }
  Start-Sleep -Milliseconds 800
  if ($env:CLAUDE_DESKTOP_AUTO_BRIDGE_KEEP_DEVTOOLS -eq '1') {
    $probeVisible = @([ClaudeUsageInjectorNative]::FindClaudeWindows($false) |
      Where-Object { $_.ProcessId -eq $Window.ProcessId -and $_.Title -eq 'Usage Viewer injection probe' }).Count -gt 0
    Write-InjectorLog "diagnostic execution probe visible=$probeVisible"
    Write-InjectorLog 'diagnostic mode: keeping DevTools focused for 30 seconds'
    Start-Sleep -Seconds 30
  } else {
    [ClaudeUsageInjectorNative]::Close($devTools.Handle)
    Start-Sleep -Milliseconds 150
    [ClaudeUsageInjectorNative]::Focus($previousForeground) | Out-Null
  }
  return $typed
}

if ($env:CLAUDE_DESKTOP_AUTO_BRIDGE_TEST -eq '1') {
  $testOrganizations = @(Get-ClaudeOrganizations)
  if ($testOrganizations.Count -eq 0) { throw 'No Claude organization was found for the injector self-test.' }
  $testScript = New-InjectionScript $testOrganizations
  if ($testScript -notmatch '__usageViewerBridgeV2' -or
      $testScript -notmatch '127\.0\.0\.1:8765' -or
      $testScript -notmatch 'o=\[') {
    throw 'The generated Claude injection script is invalid.'
  }
  foreach ($organization in $testOrganizations) {
    if ($testScript -notmatch [regex]::Escape('"' + $organization + '"')) {
      throw "The generated Claude injection script omitted organization $organization."
    }
  }
  Write-Output "Claude usage injector self-test passed ($($testOrganizations.Count) organization(s))."
  $mutex.ReleaseMutex()
  $mutex.Dispose()
  exit 0
}

function Start-ConfiguredClaudeProfiles {
  $settingsFile = Join-Path $usageHome 'claude-custom-source.json'
  if (-not (Test-Path -LiteralPath $settingsFile)) { return }
  try {
    $settings = Get-Content -LiteralPath $settingsFile -Raw | ConvertFrom-Json
    $sources = if ($null -ne $settings.sources) { @($settings.sources) } else { @($settings) }
    $profiles = @($sources | ForEach-Object {
      if ($_.profile_path) { [string]$_.profile_path }
    } | Where-Object { Test-Path -LiteralPath (Join-Path $_ 'plan-usage-history.json') } | Sort-Object -Unique)
    if ($profiles.Count -eq 0) { return }
    $processes = @(Get-CimInstance Win32_Process -Filter "Name = 'Claude.exe'" -ErrorAction Stop)
    $executable = $processes | Where-Object { $_.ExecutablePath } | Select-Object -First 1 -ExpandProperty ExecutablePath
    if (-not $executable) {
      $package = Get-AppxPackage -Name 'Claude' -ErrorAction Stop | Select-Object -First 1
      if ($package) { $executable = Join-Path $package.InstallLocation 'app\Claude.exe' }
    }
    if (-not $executable -or -not (Test-Path -LiteralPath $executable)) {
      Write-InjectorLog 'configured profiles could not start: Claude executable not found'
      return
    }
    foreach ($profile in $profiles) {
      $running = @($processes | Where-Object {
        $_.CommandLine -and $_.CommandLine.IndexOf($profile, [StringComparison]::OrdinalIgnoreCase) -ge 0
      }).Count -gt 0
      if (-not $running) {
        Start-Process -FilePath $executable -ArgumentList "--user-data-dir=`"$profile`"" -WindowStyle Hidden -ErrorAction Stop
        Write-InjectorLog "started configured Claude profile=$profile"
      }
    }
  } catch {
    Write-InjectorLog "configured profile startup failed: $($_.Exception.Message)"
  }
}

Write-InjectorLog 'started'
Start-ConfiguredClaudeProfiles
$attemptsByProcess = @{}
$nextAttemptUtc = [DateTimeOffset]::MinValue
$forceOnce = $env:CLAUDE_DESKTOP_AUTO_BRIDGE_FORCE_ONCE -eq '1'

try {
  while ($true) {
    Start-Sleep -Seconds 1
    $organizations = @(Get-ClaudeOrganizations)
    if ($organizations.Count -eq 0 -or (-not $forceOnce -and (Test-FreshBridgeSnapshot $organizations))) { continue }
    if ([DateTimeOffset]::UtcNow -lt $nextAttemptUtc) { continue }
    if ([ClaudeUsageInjectorNative]::IdleMilliseconds() -lt 2500) { continue }

    $window = [ClaudeUsageInjectorNative]::FindClaudeWindows($false) |
      # Minimized Claude windows have only a tiny restore-icon rectangle. They
      # are still valid account sessions and Focus() restores them before use.
      Where-Object { -not $_.Cloaked -and -not [string]::IsNullOrWhiteSpace($_.Title) } |
      Sort-Object @{ Expression = {
        if ($attemptsByProcess.ContainsKey($_.ProcessId)) { [int]$attemptsByProcess[$_.ProcessId] } else { 0 }
      } },
      # Prefer the newest Claude window. An older background/profile window can
      # stay alive for days and otherwise monopolize every injection attempt.
      @{ Expression = { (Get-Process -Id $_.ProcessId).StartTime }; Descending = $true },
      @{ Expression = 'Area'; Descending = $true } |
      Select-Object -First 1
    if ($null -eq $window) { continue }
    $attemptCount = if ($attemptsByProcess.ContainsKey($window.ProcessId)) { [int]$attemptsByProcess[$window.ProcessId] } else { 0 }
    if ($attemptCount -ge 4) {
      # Four failures trigger a cooldown, not a permanent ban for this process.
      $attemptsByProcess[$window.ProcessId] = 0
      $nextAttemptUtc = [DateTimeOffset]::UtcNow.AddMinutes(30)
      continue
    }

    $attemptsByProcess[$window.ProcessId] = $attemptCount + 1
    $forceOnce = $false
    Write-InjectorLog "injecting process=$($window.ProcessId) organizations=$($organizations.Count) attempt=$($attemptCount + 1)"
    $staleBefore = @(Get-StaleClaudeOrganizations $organizations)
    if (Invoke-ClaudeInjection $window $organizations) {
      Start-Sleep -Seconds 3
      $staleAfter = @(Get-StaleClaudeOrganizations $organizations)
      if ($staleAfter.Count -eq 0) {
        Write-InjectorLog 'bridge snapshot refreshed successfully'
        $attemptsByProcess[$window.ProcessId] = 0
        $nextAttemptUtc = [DateTimeOffset]::UtcNow.AddMinutes(2)
        continue
      }
      if ($staleAfter.Count -lt $staleBefore.Count) {
        Write-InjectorLog "bridge snapshot partially refreshed; remaining=$($staleAfter.Count)"
        $nextAttemptUtc = [DateTimeOffset]::UtcNow.AddSeconds(2)
        continue
      }
    }
    Write-InjectorLog 'injection did not refresh a bridge snapshot'
    $delayMinutes = @(1, 3, 10, 30)[[Math]::Min($attemptCount, 3)]
    $nextAttemptUtc = [DateTimeOffset]::UtcNow.AddMinutes($delayMinutes)
  }
} finally {
  Write-InjectorLog 'stopped'
  $mutex.ReleaseMutex()
  $mutex.Dispose()
}
