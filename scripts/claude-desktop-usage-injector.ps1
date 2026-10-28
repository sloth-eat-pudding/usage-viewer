param(
  [int]$WorkerProcessId = 0,
  [string]$WorkerOrganization = '',
  [string]$WorkerRefreshId = '',
  [long]$WorkerWindowHandle = 0,
  [switch]$WorkerMeterOnly
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'claude-desktop-profiles.ps1')
. (Join-Path $PSScriptRoot 'usage-source-policy.ps1')

if ($env:CLAUDE_DESKTOP_AUTO_BRIDGE -eq '0') { exit 0 }

$usageHome = if ([string]::IsNullOrWhiteSpace($env:USAGE_VIEWER_HOME)) {
  Join-Path $env:USERPROFILE '.usage-viewer'
} else {
  $env:USAGE_VIEWER_HOME
}
$logFile = Join-Path $usageHome 'claude-desktop-usage-injector.log'
$createdNew = $false
$mutex = $null
if ($WorkerProcessId -eq 0 -and $env:CLAUDE_DESKTOP_AUTO_BRIDGE_TEST -ne '1') {
  $mutex = [System.Threading.Mutex]::new($true, 'UsageViewer.ClaudeDesktopUsageInjector.v2', [ref]$createdNew)
  if (-not $createdNew) {
    try { $acquired = $mutex.WaitOne(5000) } catch [Threading.AbandonedMutexException] { $acquired = $true }
    if (-not $acquired) { $mutex.Dispose(); exit 0 }
  }
}

New-Item -ItemType Directory -Path $usageHome -Force | Out-Null

function Write-InjectorLog {
  param([string]$Message)
  $line = "$([DateTimeOffset]::UtcNow.ToString('O')) pid=$PID $Message" + [Environment]::NewLine
  # Supervisor/worker writes and readers can briefly contend for this file.
  # Retry the short append instead of silently losing the failure reason.
  for ($attempt = 0; $attempt -lt 5; $attempt++) {
    try {
      [IO.File]::AppendAllText($logFile, $line, [Text.UTF8Encoding]::new($false))
      return
    } catch { Start-Sleep -Milliseconds 50 }
  } # Logging must never stop account recovery.
}

Write-InjectorLog 'native helper loading'

Add-Type -AssemblyName System.Windows.Forms, UIAutomationClient, UIAutomationTypes, WindowsBase
$nativeReferences = @('System.dll', 'System.Core.dll',
  [Windows.Automation.AutomationElement].Assembly.Location,
  [Windows.Automation.AutomationPattern].Assembly.Location,
  [Windows.DependencyObject].Assembly.Location)

Add-Type -ReferencedAssemblies $nativeReferences @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Automation;

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

    private static AutomationElement ConsolePrompt(long handle)
    {
        var root = AutomationElement.FromHandle(new IntPtr(handle));
        var candidates = root.FindAll(TreeScope.Descendants, new AndCondition(
            new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Edit),
            new PropertyCondition(AutomationElement.NameProperty, "Console prompt")));
        AutomationElement prompt = null;
        foreach (AutomationElement candidate in candidates)
        {
            if (candidate.Current.IsOffscreen || !candidate.Current.IsEnabled) continue;
            if (prompt != null) throw new InvalidOperationException("More than one Console prompt is visible");
            prompt = candidate;
        }
        return prompt;
    }

    private static string PromptText(AutomationElement prompt)
    {
        if (prompt == null) return null;
        object pattern;
        if (prompt.TryGetCurrentPattern(TextPattern.Pattern, out pattern)) return ((TextPattern)pattern).DocumentRange.GetText(-1);
        if (prompt.TryGetCurrentPattern(ValuePattern.Pattern, out pattern)) return ((ValuePattern)pattern).Current.Value;
        return null;
    }

    public static bool IsEmptyConsoleText(string text) { return text != null && text.TrimEnd('\r', '\n').Length == 0; }

    public static bool FocusEmptyConsole(long handle)
    {
        var prompt = ConsolePrompt(handle);
        if (prompt == null) return false;
        prompt.SetFocus();
        Thread.Sleep(100);
        prompt = ConsolePrompt(handle);
        if (!IsEmptyConsoleText(PromptText(prompt))) return false;
        return true;
    }

    public static bool FocusConsole(long handle)
    {
        var prompt = ConsolePrompt(handle);
        if (prompt == null) return false;
        prompt.SetFocus();
        return true;
    }

    public static void SelectAll() { SendShortcut(VK_CONTROL, 0x41); }
    public static void Copy() { SendShortcut(VK_CONTROL, 0x43); }
    public static void MoveToEnd() { SendShortcut(VK_CONTROL, 0x23); }

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


}
'@

$developerModeEnabled = $false
$developerSettings = @((Join-Path $env:APPDATA 'Claude\developer_settings.json'))
$packagesRoot = Join-Path $env:LOCALAPPDATA 'Packages'
if (Test-Path -LiteralPath $packagesRoot) {
  $developerSettings += @(Get-ChildItem -LiteralPath $packagesRoot -Directory -Filter 'Claude_*' |
    ForEach-Object { Join-Path $_.FullName 'LocalCache\Roaming\Claude\developer_settings.json' })
}
$developerSettings += @(Get-ClaudeDesktopProfiles | ForEach-Object { Join-Path (Split-Path -Parent $_.path) 'developer_settings.json' })
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

function Get-ClaudeTargets {
  param([switch]$IncludeHidden)
  $defaultProfiles = @(Get-ClaudeDesktopProfiles)
  $files = @($defaultProfiles | ForEach-Object { $_.path })
  $customSources = @()
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
  $targets = @()
  foreach ($file in $files) {
    $groupKey = if (@($defaultProfiles | Where-Object { $_.path -ieq $file }).Count) { 'claude_desktop_group' } else { 'claude_custom_group' }
    $enabled = Test-UsageSourceEnabled $usageHome $groupKey $file
    if (-not $enabled -and -not $IncludeHidden) { continue }
    try {
      $history = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
      # A history file can contain samples from organizations that are no
      # longer associated with the current Claude session. Requesting all of
      # them produces noisy 404s from Claude's API. The newest sample is the
      # organization that matches the profile's current session.
      $latestSample = @($history.samples |
        Where-Object { $_.t -as [long] -or $_.timestamp } |
        Sort-Object -Property @{ Expression = {
          if ($_.t -as [long]) { [long]$_.t } else { [DateTimeOffset]::Parse([string]$_.timestamp).ToUnixTimeMilliseconds() }
        }; Descending = $true } |
        Select-Object -First 1)
      $organization = [string]($latestSample | Select-Object -First 1).org
      if ($organization -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
        $profile = Split-Path -Parent $file
        $configuredSource = @($customSources | Where-Object { $_.path -eq $file -and $_.profile_path } | Select-Object -First 1)
        if ($configuredSource.Count -gt 0) { $profile = [string]$configuredSource[0].profile_path }
        $targets += [pscustomobject]@{
          Organization = $organization
          Enabled = $enabled
          Profile = $profile
          IsDefault = @($defaultProfiles | Where-Object { $_.path -ieq $file }).Count -gt 0
        }
      }
    } catch { Write-InjectorLog "history read failed file=$file reason=$($_.Exception.Message)" }
  }
  return @($targets | Sort-Object Profile,Organization -Unique)
}

function Get-ClaudeOrganizations {
  return @(Get-ClaudeTargets | ForEach-Object { $_.Organization } | Sort-Object -Unique)
}

function Read-BridgeObservation {
  param([string]$Organization, [string]$RefreshId = '')
  try {
    $snapshot = [IO.File]::ReadAllText((Join-Path $usageHome "claude-desktop-api-$Organization-latest.json")) | ConvertFrom-Json
    if ($snapshot.source -ne 'claude-desktop-api-bridge' -or $snapshot.organization_id -ne $Organization) { return $null }
    if ($RefreshId -and $snapshot.refresh_id -ne $RefreshId) { return $null }
    $values = @($snapshot.percentages.five_hour_used, $snapshot.percentages.seven_day_used) | Where-Object { $null -ne $_ }
    if (@($values).Count -eq 0) { return $null }
    foreach ($value in $values) {
      if ($value -isnot [ValueType] -or [double]::IsNaN([double]$value) -or [double]$value -lt 0 -or [double]$value -gt 100) { return $null }
    }
    $observation = [DateTimeOffset]::Parse([string]$snapshot.observed_at)
    if ($observation -gt [DateTimeOffset]::UtcNow.AddSeconds(30)) { return $null }
    return $observation
  } catch { return $null }
}

function Get-StaleClaudeOrganizations {
  param([string[]]$Organizations)
  $stale = @()
  foreach ($organization in $Organizations) {
    $observation = Read-BridgeObservation $organization
    if ($null -eq $observation -or ([DateTimeOffset]::UtcNow - $observation).TotalSeconds -ge 150) {
      $stale += $organization
    }
  }
  return @($stale)
}

function Test-FreshBridgeSnapshot {
  param([string[]]$Organizations)
  return $Organizations.Count -gt 0 -and @(Get-StaleClaudeOrganizations $Organizations).Count -eq 0
}

function Test-SessionMeterHeartbeat {
  param([string]$Instance, [string]$RefreshId = '', [string]$Version = '1.3.0')
  if ($Instance -notmatch '^\d{1,10}-\d{1,20}$') { return $false }
  try {
    $file = Join-Path $usageHome "claude-session-meter-$Instance-latest.json"
    $heartbeat = [IO.File]::ReadAllText($file) | ConvertFrom-Json
    if ($heartbeat.source -ne 'claude-session-meter' -or $heartbeat.instance -ne $Instance -or $heartbeat.version -ne $Version) { return $false }
    if ($RefreshId -and $heartbeat.refresh_id -ne $RefreshId) { return $false }
    $observedAt = [DateTimeOffset]::Parse([string]$heartbeat.observed_at)
    $age = ([DateTimeOffset]::UtcNow - $observedAt).TotalSeconds
    return $age -ge -30 -and $age -lt 75
  } catch { return $false }
}

function Get-SessionMeterWindows {
  param([object[]]$Processes, [object[]]$Windows)
  $mainIds = @($Processes | Where-Object { -not $_.CommandLine -or $_.CommandLine -notmatch '--type=' } |
    ForEach-Object { [int]$_.ProcessId })
  return @($Windows | Where-Object {
    $mainIds -contains $_.ProcessId -and -not $_.Cloaked -and $_.Title -and $_.Area -gt 10000
  } | Sort-Object Handle -Unique)
}

function New-InjectionScript {
  param([string[]]$Organizations, [string]$RefreshId = '', [string]$SessionMeterPath = '', [string]$WindowKey = '', [switch]$MeterOnly)
  # The same payload runs in Desktop's Code renderer. It only reads the
  # currently selected session and adds a reversible badge beside its model.
  if (-not $SessionMeterPath -and $PSScriptRoot) {
    $SessionMeterPath = Join-Path $PSScriptRoot '..\src\desktop-addon\claude-session-meter.js'
    if (-not (Test-Path -LiteralPath $SessionMeterPath)) {
      $SessionMeterPath = Join-Path $PSScriptRoot 'claude-session-meter.js'
    }
  }
  $sessionMeterScript = if ($SessionMeterPath -and (Test-Path -LiteralPath $SessionMeterPath)) { [IO.File]::ReadAllText($SessionMeterPath) } else { '' }
  $sessionMeterFound = -not [string]::IsNullOrWhiteSpace($sessionMeterScript)
  if ($WindowKey) {
    if ($WindowKey -notmatch '^\d{1,10}-\d{1,20}$') { throw 'Invalid window key' }
    $meterConfig = @{ instance = $WindowKey; refreshId = $RefreshId } | ConvertTo-Json -Compress
    $sessionMeterScript = "window.__usageViewerSessionMeterConfig=$meterConfig;`n$sessionMeterScript"
  }
  # Updating the meter must not replace an already healthy account-usage timer.
  if ($MeterOnly) {
    if (-not $sessionMeterFound) { throw 'Session meter payload was not found' }
    return $sessionMeterScript
  }
  # Passing a one-item array through the pipeline is unwrapped by PowerShell,
  # producing a JSON string. -InputObject preserves the array so JavaScript
  # iterates organization IDs instead of individual UUID characters.
  $organizationJson = ConvertTo-Json -InputObject @($Organizations) -Compress
  $refreshJson = ConvertTo-Json -InputObject $RefreshId -Compress
  $diagnosticProbe = if ($env:CLAUDE_DESKTOP_AUTO_BRIDGE_KEEP_DEVTOOLS -eq '1') {
    "const dt=document.title;document.title='Usage Viewer injection probe';setTimeout(()=>document.title=dt,10000);"
  } else { '' }
  return @"
(()=>{
  $diagnosticProbe
  const k='__usageViewerBridgeV3',o=new Set($organizationJson),refreshId=$refreshJson;
  if(window[k])clearInterval(window[k]);
  let busy=false;
  const f=async()=>{
    if(busy)return;
    busy=true;
    try{
      for(const g of o){
        const controller=new AbortController();
        const timeout=setTimeout(()=>controller.abort(),10000);
        try{
          const gate=await fetch('http://127.0.0.1:8765/usage-enabled?org='+encodeURIComponent(g),{cache:'no-store',signal:controller.signal});
          if(!gate.ok || !(await gate.json()).enabled)continue;
          const r=await fetch('/api/organizations/'+g+'/usage?usage_viewer_refresh='+Date.now(),{
            credentials:'include',cache:'no-store',signal:controller.signal
          });
          if(!r.ok)throw new Error('Claude usage HTTP '+r.status);
          const u=await r.json();
          const b=await fetch('http://127.0.0.1:8765/claude-desktop-usage?org='+encodeURIComponent(g)+'&refresh_id='+encodeURIComponent(refreshId),{
            method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(u),signal:controller.signal
          });
          if(!b.ok)throw new Error('Usage bridge HTTP '+b.status);
        }catch(error){console.warn('[Usage Viewer]',g,error.message)}
        finally{clearTimeout(timeout)}
      }
    }finally{busy=false}
  };
  f();window[k]=setInterval(f,60000);
})()
;
$sessionMeterScript
"@.Trim()
}

function Get-ClaudeWebDevTools {
  param([object]$Window, [object[]]$Tools)
  $matchingTools = @($Tools | Where-Object {
    $_.ProcessId -eq $Window.ProcessId -and -not $_.Cloaked -and
    $_.Title -match '^(?:DevTools|Developer Tools)\s*-\s*https://claude\.ai(?:/|$)'
  })
  if ($matchingTools.Count -gt 1) { throw 'More than one Claude web DevTools window matches this profile' }
  if ($matchingTools.Count -eq 1) { return $matchingTools[0] }
  return $null
}

function Invoke-ClaudeInjection {
  param([object]$Window, [string[]]$Organizations, [string]$RefreshId, [switch]$MeterOnly)
  $devTools = $null
  $openedDevTools = $false
  $clipboardChanged = $false
  $previousClipboardText = $null
  $clipboardProbe = ''
  $pastedText = $null
  try {
    $existing = @([ClaudeUsageInjectorNative]::FindClaudeWindows($true))
    $devTools = Get-ClaudeWebDevTools $Window $existing
    if ($devTools) {
      # CLAUDE_DEV_TOOLS=undocked opens this window on every Claude launch.
      # Reuse an empty prompt instead of deferring forever; never close it.
      $profileWindows = @([ClaudeUsageInjectorNative]::FindClaudeWindows($false) |
        Where-Object { $_.ProcessId -eq $Window.ProcessId -and -not $_.Cloaked -and $_.Title -and $_.Area -gt 10000 })
      if ($profileWindows.Count -ne 1) { throw 'Cannot pair existing DevTools with one Claude window' }
    } else {
      if (-not [ClaudeUsageInjectorNative]::Focus($Window.Handle)) { throw 'Could not focus Claude' }
      [ClaudeUsageInjectorNative]::OpenDevTools()
      $deadline = [DateTimeOffset]::UtcNow.AddSeconds(5)
      do {
        Start-Sleep -Milliseconds 200
        $devTools = Get-ClaudeWebDevTools $Window @([ClaudeUsageInjectorNative]::FindClaudeWindows($true))
      } while ($null -eq $devTools -and [DateTimeOffset]::UtcNow -lt $deadline)
      if ($null -eq $devTools) { throw 'Claude web DevTools did not open within 5 seconds; check Developer Mode' }
      $openedDevTools = $existing.Handle -notcontains $devTools.Handle
    }
    Write-InjectorLog "stage=console process=$($Window.ProcessId) reused=$(-not $openedDevTools)"
    if (-not [ClaudeUsageInjectorNative]::Focus($devTools.Handle)) { throw 'Could not focus DevTools' }
    Start-Sleep -Milliseconds 300
    # Select the Console panel directly. A command menu/drawer can focus the
    # filter or another panel and previously accepted the paste unnoticed.
    [ClaudeUsageInjectorNative]::ShowConsolePanel()
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds(5)
    $promptReady = $false
    do {
      Start-Sleep -Milliseconds 200
      if ([ClaudeUsageInjectorNative]::ForegroundWindow() -ne $devTools.Handle) { throw 'Focus changed before console selection' }
      $promptReady = [ClaudeUsageInjectorNative]::FocusEmptyConsole($devTools.Handle)
    } while (-not $promptReady -and [DateTimeOffset]::UtcNow -lt $deadline)
    if (-not $promptReady) { throw 'Console prompt is unavailable or contains a draft; leaving it unchanged' }
    # Capture only text, avoiding delayed IDataObject enumeration that hung
    # the former long-running updater. This worker has an external timeout.
    if ([Windows.Forms.Clipboard]::ContainsText()) { $previousClipboardText = [Windows.Forms.Clipboard]::GetText() }
    # Paste the complete script at once; do not type it character by character.
    $script = New-InjectionScript $Organizations $RefreshId -WindowKey "$($Window.ProcessId)-$($Window.Handle)" -MeterOnly:$MeterOnly
    [Windows.Forms.Clipboard]::SetText($script)
    $clipboardChanged = $true
    Write-InjectorLog "stage=paste process=$($Window.ProcessId) characters=$($script.Length)"
    if ([ClaudeUsageInjectorNative]::ForegroundWindow() -ne $devTools.Handle) { throw 'Focus changed before script paste' }
    if (-not [ClaudeUsageInjectorNative]::FocusEmptyConsole($devTools.Handle)) { throw 'Console prompt changed before script paste' }
    [ClaudeUsageInjectorNative]::Paste()
    Start-Sleep -Milliseconds 500
    if ([ClaudeUsageInjectorNative]::ForegroundWindow() -ne $devTools.Handle) { throw 'Focus changed before script submission' }
    # CodeMirror exposes only its visible lines through UI Automation. Copy
    # the focused prompt to verify all lines, using a sentinel so a failed
    # copy cannot accidentally validate the clipboard used for the paste.
    $clipboardProbe = 'UsageViewer-copy-' + [guid]::NewGuid().ToString()
    [Windows.Forms.Clipboard]::SetText($clipboardProbe)
    if (-not [ClaudeUsageInjectorNative]::FocusConsole($devTools.Handle)) { throw 'Console prompt disappeared after paste' }
    [ClaudeUsageInjectorNative]::SelectAll()
    [ClaudeUsageInjectorNative]::Copy()
    Start-Sleep -Milliseconds 200
    $pastedText = [Windows.Forms.Clipboard]::GetText()
    [ClaudeUsageInjectorNative]::MoveToEnd()
    if (-not (Test-ConsoleScriptText $pastedText $script)) { throw 'Console did not accept the complete script; not executing' }
    if ([ClaudeUsageInjectorNative]::ForegroundWindow() -ne $devTools.Handle) { throw 'Focus changed during script verification' }
    [ClaudeUsageInjectorNative]::Execute()
    Write-InjectorLog "stage=submitted process=$($Window.ProcessId)"
    # Submission is not success. The supervisor waits for a new API observation.
    Start-Sleep -Milliseconds 800
    return $true
  } catch {
    Write-InjectorLog "stage=failed process=$($Window.ProcessId) reason=$($_.Exception.Message)"
    return $false
  } finally {
    # Restore previous text only if the clipboard still contains our content.
    # If the user copied something during the operation, leave their copy alone.
    try {
      if ($clipboardChanged -and $null -ne $previousClipboardText) {
        $currentText = [Windows.Forms.Clipboard]::GetText()
        if (($script -and $currentText -eq $script) -or $currentText -eq $clipboardProbe -or ($pastedText -and $currentText -eq $pastedText)) {
          [Windows.Forms.Clipboard]::SetText($previousClipboardText)
        }
      }
    } catch { Write-InjectorLog "clipboard text restore failed reason=$($_.Exception.Message)" }
    if ($openedDevTools -and $env:CLAUDE_DESKTOP_AUTO_BRIDGE_KEEP_DEVTOOLS -ne '1') {
      [ClaudeUsageInjectorNative]::Close($devTools.Handle)
      Start-Sleep -Milliseconds 150
    }
  }
}

function Test-ConsoleScriptText {
  param([string]$Actual, [string]$Expected)
  return $Expected.Length -gt 0 -and $Actual.Replace("`r`n", "`n").TrimEnd("`r`n".ToCharArray()) -ceq
    $Expected.Replace("`r`n", "`n").TrimEnd("`r`n".ToCharArray())
}

if ($WorkerProcessId -gt 0) {
  if (-not $WorkerMeterOnly -and $WorkerOrganization -notmatch '^[0-9a-fA-F-]{36}$') { exit 2 }
  $window = [ClaudeUsageInjectorNative]::FindClaudeWindows($false) |
    Where-Object { $_.ProcessId -eq $WorkerProcessId -and -not $_.Cloaked -and
      ($WorkerWindowHandle -eq 0 -or $_.Handle -eq $WorkerWindowHandle) } |
    Sort-Object Area -Descending | Select-Object -First 1
  if ($null -eq $window) { Write-InjectorLog 'worker has no visible profile window'; exit 3 }
  $workerOrganizations = if ($WorkerMeterOnly) { @() } else { @($WorkerOrganization) }
  if (Invoke-ClaudeInjection $window $workerOrganizations $WorkerRefreshId -MeterOnly:$WorkerMeterOnly) { exit 0 }
  exit 4
}

if ($env:CLAUDE_DESKTOP_AUTO_BRIDGE_TEST -eq '1') {
  $testOrganizations = @(Get-ClaudeOrganizations)
  if ($testOrganizations.Count -eq 0) { throw 'No Claude organization was found for the injector self-test.' }
  $testScript = New-InjectionScript $testOrganizations
  if ($testScript -notmatch '__usageViewerBridgeV3' -or
      $testScript -notmatch '127\.0\.0\.1:8765' -or
      $testScript -notmatch 'o=new Set\(\[') {
    throw 'The generated Claude injection script is invalid.'
  }
  foreach ($organization in $testOrganizations) {
    if ($testScript -notmatch [regex]::Escape('"' + $organization + '"')) {
      throw "The generated Claude injection script omitted organization $organization."
    }
  }
  Write-Output "Claude usage injector self-test passed ($($testOrganizations.Count) organization(s))."
  exit 0
}

function Start-ConfiguredClaudeProfiles {
  $settingsFile = Join-Path $usageHome 'claude-custom-source.json'
  if (-not (Test-Path -LiteralPath $settingsFile)) { return }
  try {
    $settings = Get-Content -LiteralPath $settingsFile -Raw | ConvertFrom-Json
    $sources = if ($null -ne $settings.sources) { @($settings.sources) } else { @($settings) }
    $profiles = @($sources | Where-Object { Test-UsageSourceEnabled $usageHome 'claude_custom_group' ([string]$_.path) } | ForEach-Object {
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
    # A custom profile is a separate Electron session; it does not start the
    # installed app's default session. Start that session independently.
    $defaultRunning = @($processes | Where-Object {
      $_.CommandLine -and $_.CommandLine -notmatch '--type=' -and
      ($_.CommandLine -notmatch '--user-data-dir' -or
       $_.CommandLine.IndexOf((Join-Path $env:APPDATA 'Claude'), [StringComparison]::OrdinalIgnoreCase) -ge 0)
    }).Count -gt 0
    if (-not $defaultRunning -and (Test-UsageSourceEnabled $usageHome 'claude_desktop_group')) {
      $app = Get-StartApps -ErrorAction Stop | Where-Object { $_.Name -eq 'Claude' } | Select-Object -First 1
      if ($app) {
        Start-Process -FilePath 'explorer.exe' -ArgumentList "shell:AppsFolder\$($app.AppID)" -WindowStyle Hidden -ErrorAction Stop
      } else {
        Start-Process -FilePath $executable -WindowStyle Hidden -ErrorAction Stop
      }
      Write-InjectorLog 'started default Claude profile'
    }
    foreach ($profile in $profiles) {
      # A profile may keep its Electron process alive after its window closes.
      # Reopening that existing session makes it available to the injector.
      $profileProcesses = @($processes | Where-Object {
        $_.CommandLine -and $_.CommandLine -notmatch '--type=' -and
        $_.CommandLine.IndexOf($profile, [StringComparison]::OrdinalIgnoreCase) -ge 0
      } | ForEach-Object { [int]$_.ProcessId })
      $running = @([ClaudeUsageInjectorNative]::FindClaudeWindows($false) |
        Where-Object { $profileProcesses -contains $_.ProcessId }).Count -gt 0
      if (-not $running) {
        Start-Process -FilePath $executable -ArgumentList "--user-data-dir=`"$profile`"" -WindowStyle Hidden -ErrorAction Stop
        Write-InjectorLog "started configured Claude profile=$profile"
      }
    }
  } catch {
    Write-InjectorLog "configured profile startup failed: $($_.Exception.Message)"
  }
}

function Get-TargetWindow {
  param([object]$Target, [object[]]$Processes, [object[]]$Windows)
  $ids = @($Processes | Where-Object {
    if (-not $_.CommandLine -or $_.CommandLine -match '--type=') { return $false }
    $profileMatch = [regex]::Match($_.CommandLine, '--user-data-dir(?:=|\s+)(?:"([^"]+)"|(\S+))')
    if (-not $profileMatch.Success) { return $Target.IsDefault }
    $processProfile = if ($profileMatch.Groups[1].Success) { $profileMatch.Groups[1].Value } else { $profileMatch.Groups[2].Value }
    $profileMatches = $processProfile.TrimEnd('\') -eq $Target.Profile.TrimEnd('\')
    return $profileMatches -or ($Target.IsDefault -and $processProfile.TrimEnd('\') -eq (Join-Path $env:APPDATA 'Claude'))
  } | ForEach-Object { [int]$_.ProcessId })
  return $Windows | Where-Object { $ids -contains $_.ProcessId -and -not $_.Cloaked -and $_.Title } |
    Sort-Object Area -Descending | Select-Object -First 1
}

function Get-RetryDelaySeconds {
  param([int]$Failures)
  return @(30, 60, 120)[[Math]::Min([Math]::Max($Failures - 1, 0), 2)]
}

function Get-ClaudeRetryState {
  param([hashtable]$States, [string]$Key, [object]$Window)
  $instance = if ($Window) { "$($Window.ProcessId)-$($Window.Handle)" } else { '' }
  if (-not $States.ContainsKey($Key) -or ($instance -and $States[$Key].Instance -ne $instance)) {
    $States[$Key] = @{ Failures = 0; NextAttempt = [DateTimeOffset]::MinValue; Instance = $instance }
  }
  return $States[$Key]
}

function Invoke-BoundedInjection {
  param([object]$Window, [string]$Organization = '', [switch]$MeterOnly, [switch]$SkipObservation)
  $startedAt = [DateTimeOffset]::UtcNow
  $refreshId = [guid]::NewGuid().ToString()
  $existingTools = @([ClaudeUsageInjectorNative]::FindClaudeWindows($true) | ForEach-Object { $_.Handle })
  $worker = $null
  try {
    $workerArguments = @(
      '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $PSCommandPath + '"'),
      '-WorkerProcessId', [string]$Window.ProcessId, '-WorkerWindowHandle', [string]$Window.Handle, '-WorkerRefreshId', $refreshId
    )
    if ($MeterOnly) { $workerArguments += '-WorkerMeterOnly' }
    else { $workerArguments += @('-WorkerOrganization', $Organization) }
    $worker = Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -PassThru -ErrorAction Stop -ArgumentList $workerArguments `
      -RedirectStandardError (Join-Path $usageHome 'claude-desktop-usage-worker.stderr.log') `
      -RedirectStandardOutput (Join-Path $usageHome 'claude-desktop-usage-worker.stdout.log')
    # Keep the process handle before a short-lived worker can exit. Otherwise
    # Windows PowerShell's Start-Process can return a null ExitCode later.
    $null = $worker.Handle
    $deadline = $startedAt.AddSeconds(45)
    while (-not $worker.HasExited -and [DateTimeOffset]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 200 }
    if (-not $worker.HasExited) {
      $worker.Kill()
      Write-InjectorLog "worker timeout organization=$Organization limit=45s"
      return $false
    }
    $null = $worker.WaitForExit(1000)
    if ($worker.ExitCode -ne 0) {
      Write-InjectorLog "worker failed organization=$Organization exit=$($worker.ExitCode); see claude-desktop-usage-worker.stderr.log"
      return $false
    }
    if ($SkipObservation) { return $true }
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds(15)
    do {
      if ($MeterOnly) {
        if (Test-SessionMeterHeartbeat "$($Window.ProcessId)-$($Window.Handle)" $refreshId) { return $true }
      } else {
        $observation = Read-BridgeObservation $Organization $refreshId
        if ($null -ne $observation -and $observation -ge $startedAt) { return $true }
      }
      Start-Sleep -Milliseconds 250
    } while ([DateTimeOffset]::UtcNow -lt $deadline)
    Write-InjectorLog "no new valid API observation organization=$Organization"
    return $false
  } finally {
    if ($worker) {
      if (-not $worker.HasExited) { $worker.Kill() }
      $worker.Dispose()
    }
    # A killed worker cannot execute its own finally block.
    $tools = @([ClaudeUsageInjectorNative]::FindClaudeWindows($true) |
      Where-Object { $_.ProcessId -eq $Window.ProcessId -and $existingTools -notcontains $_.Handle })
    if ($env:CLAUDE_DESKTOP_AUTO_BRIDGE_KEEP_DEVTOOLS -ne '1') {
      foreach ($tool in $tools) { [ClaudeUsageInjectorNative]::Close($tool.Handle) }
    }
  }
}

Write-InjectorLog 'supervisor started'
$states = @{}
$meterStates = @{}
$visibilityUpdated = @{}
$nextWindowCheck = [DateTimeOffset]::MinValue
$nextProfileCheck = [DateTimeOffset]::MinValue
$nextBridgeLog = [DateTimeOffset]::MinValue
$forceOnce = $env:CLAUDE_DESKTOP_AUTO_BRIDGE_FORCE_ONCE -eq '1'
try {
  while ($true) {
    Start-Sleep -Seconds 1
    try {
      # Meter discovery is independent of account history and quota freshness.
      # A newly opened second profile must not be skipped because another
      # window is still refreshing the same organization's usage snapshot.
      if ([DateTimeOffset]::UtcNow -ge $nextWindowCheck) {
        $nextWindowCheck = [DateTimeOffset]::UtcNow.AddSeconds(5)
        $meterProcesses = @(Get-CimInstance Win32_Process -Filter "Name = 'Claude.exe'" -ErrorAction Stop)
        $meterWindows = @(Get-SessionMeterWindows $meterProcesses @([ClaudeUsageInjectorNative]::FindClaudeWindows($false)))
        # Replace timers installed by older versions even if their source is
        # already hidden. The new timer checks visibility before any quota call.
        foreach ($hiddenTarget in @(Get-ClaudeTargets -IncludeHidden | Where-Object { -not $_.Enabled })) {
          if ($null -eq (Read-BridgeObservation $hiddenTarget.Organization)) { continue }
          $hiddenWindow = Get-TargetWindow $hiddenTarget $meterProcesses $meterWindows
          if ($null -eq $hiddenWindow) { continue }
          $hiddenKey = "$($hiddenWindow.ProcessId)-$($hiddenWindow.Handle)|$($hiddenTarget.Organization)"
          if ($visibilityUpdated.ContainsKey($hiddenKey) -or [ClaudeUsageInjectorNative]::IdleMilliseconds() -lt 2500) { continue }
          if (Invoke-BoundedInjection $hiddenWindow $hiddenTarget.Organization -SkipObservation) { $visibilityUpdated[$hiddenKey] = $true }
        }
        $activeInstances = @($meterWindows | ForEach-Object { "$($_.ProcessId)-$($_.Handle)" })
        foreach ($instance in @($meterStates.Keys)) { if ($activeInstances -notcontains $instance) { $meterStates.Remove($instance) } }
        $meterAttempted = $false
        foreach ($meterWindow in $meterWindows) {
          $instance = "$($meterWindow.ProcessId)-$($meterWindow.Handle)"
          if (Test-SessionMeterHeartbeat $instance) { continue }
          if (-not $meterStates.ContainsKey($instance)) { $meterStates[$instance] = @{ Failures = 0; NextAttempt = [DateTimeOffset]::MinValue } }
          $meterState = $meterStates[$instance]
          if ([DateTimeOffset]::UtcNow -lt $meterState.NextAttempt) { continue }
          if ([ClaudeUsageInjectorNative]::IdleMilliseconds() -lt 2500) { break }
          try {
            $meterHealth = Invoke-RestMethod -Uri 'http://127.0.0.1:8765/health' -TimeoutSec 2
            if ($meterHealth.status -ne 'ok') { break }
          } catch { break }
          $meterAttempted = $true
          Write-InjectorLog "meter attempt window=$instance"
          if (Invoke-BoundedInjection $meterWindow -MeterOnly) {
            $meterState.Failures = 0
            $meterState.NextAttempt = [DateTimeOffset]::UtcNow.AddSeconds(75)
            Write-InjectorLog "meter verified window=$instance version=1.3.0"
          } else {
            $meterState.Failures++
            $meterState.NextAttempt = [DateTimeOffset]::UtcNow.AddSeconds((Get-RetryDelaySeconds $meterState.Failures))
            Write-InjectorLog "meter retry window=$instance failures=$($meterState.Failures)"
          }
          break
        }
        if ($meterAttempted) { continue }
      }
      $targets = @(Get-ClaudeTargets)
      $staleOrganizations = @(Get-StaleClaudeOrganizations @($targets | ForEach-Object { $_.Organization }))
      if ($targets.Count -eq 0 -or (-not $forceOnce -and $staleOrganizations.Count -eq 0)) { continue }
      # Avoid stealing focus when the bridge itself is unavailable.
      try {
        $health = Invoke-RestMethod -Uri 'http://127.0.0.1:8765/health' -TimeoutSec 2
        if ($health.status -ne 'ok') { throw 'Invalid bridge health response' }
      } catch {
        if ([DateTimeOffset]::UtcNow -ge $nextBridgeLog) {
          Write-InjectorLog "bridge unavailable; waiting for bridge watchdog reason=$($_.Exception.Message)"
          $nextBridgeLog = [DateTimeOffset]::UtcNow.AddMinutes(1)
        }
        Start-Sleep -Seconds 5
        continue
      }
      if ([DateTimeOffset]::UtcNow -ge $nextProfileCheck) {
        Start-ConfiguredClaudeProfiles
        $nextProfileCheck = [DateTimeOffset]::UtcNow.AddMinutes(2)
      }
      if ([ClaudeUsageInjectorNative]::IdleMilliseconds() -lt 2500) { continue }
      $processes = @(Get-CimInstance Win32_Process -Filter "Name = 'Claude.exe'" -ErrorAction Stop)
      $windows = @([ClaudeUsageInjectorNative]::FindClaudeWindows($false))
      foreach ($target in $targets) {
        if (-not $forceOnce -and $staleOrganizations -notcontains $target.Organization) { continue }
        $key = $target.Profile + '|' + $target.Organization
        $window = Get-TargetWindow $target $processes $windows
        # A restarted or updated Claude renderer must not inherit the previous
        # process's failure cooldown.
        $state = Get-ClaudeRetryState $states $key $window
        if ([DateTimeOffset]::UtcNow -lt $state.NextAttempt) { continue }
        $success = $false
        if ($null -eq $window) {
          Write-InjectorLog "profile window unavailable organization=$($target.Organization) profile=$($target.Profile)"
        } else {
          Write-InjectorLog "attempt organization=$($target.Organization) process=$($window.ProcessId) failures=$($state.Failures)"
          $success = Invoke-BoundedInjection $window $target.Organization
        }
        if ($success) {
          $state.Failures = 0
          $state.NextAttempt = [DateTimeOffset]::UtcNow.AddSeconds(150)
          Write-InjectorLog "verified fresh API observation organization=$($target.Organization)"
        } else {
          $state.Failures++
          $delay = Get-RetryDelaySeconds $state.Failures
          $state.NextAttempt = [DateTimeOffset]::UtcNow.AddSeconds($delay)
          Write-InjectorLog "retry organization=$($target.Organization) in=${delay}s"
        }
        $forceOnce = $false
        break # Recheck idle state and freshness before operating another profile.
      }
      # Discard state for accounts removed from configuration.
      $activeKeys = @($targets | ForEach-Object { $_.Profile + '|' + $_.Organization })
      foreach ($key in @($states.Keys)) { if ($activeKeys -notcontains $key) { $states.Remove($key) } }
    } catch {
      Write-InjectorLog "supervisor iteration failed reason=$($_.Exception.Message)"
      Start-Sleep -Seconds 5
    }
  }
} finally {
  Write-InjectorLog 'supervisor stopped'
  if ($mutex) { $mutex.ReleaseMutex(); $mutex.Dispose() }
}
