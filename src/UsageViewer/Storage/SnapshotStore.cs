using System.IO;
using System.Text.Json;
using static UsageViewer.JsonValues;

namespace UsageViewer;

internal sealed class SnapshotStore
{
    private readonly string _home;
    internal string Home => _home;

    internal SnapshotStore(string home) => _home = home;

    internal void Write(string name, object value) => WriteAtomic(Path.Combine(_home, name), value);

    internal static void WriteAtomic(string path, object value)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        // Refresh and HTTP requests can write concurrently in the same process.
        var temporaryPath = path + ".tmp-" + Guid.NewGuid().ToString("N");
        try
        {
            File.WriteAllText(temporaryPath, JsonSerializer.Serialize(value, new JsonSerializerOptions { WriteIndented = true }));
            Replace(temporaryPath, path);
        }
        finally
        {
            if (File.Exists(temporaryPath)) File.Delete(temporaryPath);
        }
    }

    private static void Replace(string temporaryPath, string path)
    {
        // Windows may briefly deny replacement while another writer or a file
        // scanner holds the destination. Keep the complete temporary file and
        // retry; never fall back to truncating the currently valid snapshot.
        for (var attempt = 0; ; attempt++)
        {
            try { FrameworkCompat.MoveReplacing(temporaryPath, path); return; }
            catch (IOException) when (attempt < 5) { Thread.Sleep(25 * (attempt + 1)); }
            catch (UnauthorizedAccessException) when (attempt < 5) { Thread.Sleep(25 * (attempt + 1)); }
        }
    }

    internal List<JsonElement> ReadConfiguredSources(string fileName)
    {
        try
        {
            var path = Path.Combine(_home, fileName);
            if (!File.Exists(path)) return new();
            using var document = JsonDocument.Parse(File.ReadAllText(path));
            return document.RootElement.TryGetProperty("sources", out var array) && array.ValueKind == JsonValueKind.Array
                ? array.EnumerateArray().Select(item => item.Clone()).ToList() : new();
        }
        catch { return new(); }
    }

    internal bool IsNotOlder(string fileName, DateTimeOffset candidateTime)
    {
        var path = Path.Combine(_home, fileName);
        if (!File.Exists(path)) return true;
        try
        {
            using var document = JsonDocument.Parse(File.ReadAllText(path));
            var root = document.RootElement;
            var timestamp = StringOrNull(root, "observed_at") ?? StringOrNull(root, "generated_at");
            return !DateTimeOffset.TryParse(timestamp, out var currentTime) || candidateTime >= currentTime;
        }
        catch { return true; }
    }

}
