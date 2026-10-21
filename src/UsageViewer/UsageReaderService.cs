using System.IO;
using static UsageViewer.UsageLog;

namespace UsageViewer;

// Owns the update schedule and component lifetime; source-specific work belongs
// to each reader, and the HTTP bridge and helper processes own their resources.
public sealed class UsageReaderService : IDisposable
{
    private readonly ClaudeUsageReader _claude;
    private readonly CodexUsageReader _codex;
    private readonly ClaudeDesktopUsageBridge _bridge;
    private readonly BackgroundProcesses _processes;
    private readonly Timer _timer;
    private int _disposed;
    private readonly object _refreshLock = new();

    public UsageReaderService()
    {
        var home = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".usage-viewer");
        var store = new SnapshotStore(home);
        _claude = new ClaudeUsageReader(store);
        _codex = new CodexUsageReader(store);
        _bridge = new ClaudeDesktopUsageBridge(home);
        _processes = new BackgroundProcesses(home);
        _bridge.Start();
        _processes.Start();
        _timer = new Timer(_ => Refresh(), null, TimeSpan.Zero, TimeSpan.FromSeconds(2));
    }

    private void Refresh()
    {
        if (Volatile.Read(ref _disposed) != 0 || !Monitor.TryEnter(_refreshLock)) return;
        try
        {
            if (Volatile.Read(ref _disposed) != 0) return;
            try { _claude.Refresh(); } catch (Exception error) { TraceClaude($"claude refresh exception={error.Message}"); }
            try { _codex.Refresh(); } catch (Exception error) { TraceClaude($"codex refresh exception={error.Message}"); }
        }
        finally { Monitor.Exit(_refreshLock); }
    }

    public void Dispose()
    {
        if (Interlocked.Exchange(ref _disposed, 1) != 0) return;
        _timer.Dispose();
        // Let an in-flight refresh finish before disposing the readers it uses.
        lock (_refreshLock)
        {
            _claude.Dispose();
            _codex.Dispose();
            _bridge.Dispose();
            _processes.Dispose();
        }
    }
}
