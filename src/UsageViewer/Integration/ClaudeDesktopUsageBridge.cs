using System.IO;
using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using static UsageViewer.UsageLog;

namespace UsageViewer;

internal sealed class ClaudeDesktopUsageBridge : IDisposable
{
    private readonly string _home;
    private readonly CancellationTokenSource _bridgeCancellation = new();
    private HttpListener? _listener;

    internal ClaudeDesktopUsageBridge(string home) => _home = home;
    internal void Start() => _listener = StartClaudeDesktopUsageBridge();

    // This is the native equivalent of claude-desktop-usage-bridge.js.  Keeping
    // it in the EXE preserves the self-contained release path (no Node needed).
    private HttpListener? StartClaudeDesktopUsageBridge()
    {
        try
        {
            var listener = new HttpListener();
            listener.Prefixes.Add("http://127.0.0.1:8765/");
            listener.Start();
            _ = Task.Run(() => ServeClaudeDesktopUsageBridge(listener, _bridgeCancellation.Token));
            return listener;
        }
        catch (Exception error)
        {
            TraceClaude($"Claude Desktop usage bridge start failed={error.Message}");
            return null;
        }
    }

    private async Task ServeClaudeDesktopUsageBridge(HttpListener listener, CancellationToken cancellationToken)
    {
        while (!cancellationToken.IsCancellationRequested)
        {
            try
            {
                var context = await listener.GetContextAsync();
                _ = Task.Run(() => HandleClaudeDesktopUsageBridgeRequest(context), cancellationToken);
            }
            catch (HttpListenerException) when (cancellationToken.IsCancellationRequested) { return; }
            catch (ObjectDisposedException) { return; }
            catch (Exception error) { TraceClaude($"Claude Desktop usage bridge request failed={error.Message}"); }
        }
    }

    private async Task HandleClaudeDesktopUsageBridgeRequest(HttpListenerContext context)
    {
        var request = context.Request;
        var response = context.Response;
        try
        {
            var origin = request.Headers["Origin"] ?? "";
            var allowedOrigin = origin is "https://claude.ai" or "https://www.claude.ai";
            if (request.HttpMethod == "GET" && request.Url?.AbsolutePath == "/health")
            {
                await WriteBridgeResponse(response, 200, "{\"status\":\"ok\"}");
                return;
            }
            if (request.HttpMethod == "OPTIONS")
            {
                if (!allowedOrigin) { await WriteBridgeResponse(response, 403); return; }
                AddCorsHeaders(response, origin);
                response.StatusCode = 204;
                response.Close();
                return;
            }
            var isMeterHeartbeat = request.Url?.AbsolutePath == "/claude-session-meter-heartbeat";
            if (request.HttpMethod != "POST" || (!isMeterHeartbeat && request.Url?.AbsolutePath != "/claude-desktop-usage") || !allowedOrigin)
            {
                await WriteBridgeResponse(response, request.HttpMethod == "POST" ? 403 : 404);
                return;
            }
            var organizationId = request.QueryString["org"] ?? "";
            var instance = request.QueryString["instance"] ?? "";
            if (isMeterHeartbeat && !Regex.IsMatch(instance, @"^\d{1,10}-\d{1,20}$"))
            {
                await WriteBridgeResponse(response, 400, "{\"error\":\"Invalid window instance\"}", origin);
                return;
            }
            if (!isMeterHeartbeat && !Regex.IsMatch(organizationId, "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", RegexOptions.IgnoreCase))
            {
                await WriteBridgeResponse(response, 400, "{\"error\":\"A valid org query parameter is required\"}", origin);
                return;
            }
            if (request.ContentLength64 < 0 || request.ContentLength64 > 64 * 1024)
            {
                await WriteBridgeResponse(response, 413, "{\"error\":\"Payload too large\"}", origin);
                return;
            }
            using var body = new StreamReader(request.InputStream, request.ContentEncoding ?? Encoding.UTF8, false, 64 * 1024, leaveOpen: false);
            var json = await body.ReadToEndAsync();
            if (Encoding.UTF8.GetByteCount(json) > 64 * 1024) throw new InvalidDataException("Payload too large");
            using var document = JsonDocument.Parse(json);
            if (isMeterHeartbeat)
            {
                var heartbeat = SessionMeterHeartbeat.Normalize(document.RootElement, instance, DateTimeOffset.UtcNow);
                SnapshotStore.WriteAtomic(Path.Combine(_home, $"claude-session-meter-{instance}-latest.json"), heartbeat);
                await WriteBridgeResponse(response, 204, null, origin);
                return;
            }
            var refreshId = request.QueryString["refresh_id"];
            if (!string.IsNullOrEmpty(refreshId) && !Guid.TryParseExact(refreshId, "D", out _)) throw new InvalidDataException("Invalid refresh_id");
            var snapshot = ClaudeUsageContract.Normalize(document.RootElement, organizationId, DateTimeOffset.UtcNow, refreshId);
            SnapshotStore.WriteAtomic(Path.Combine(_home, $"claude-desktop-api-{organizationId}-latest.json"), snapshot);
            await WriteBridgeResponse(response, 204, null, origin);
        }
        catch (InvalidDataException error) { await WriteBridgeResponse(response, error.Message == "Payload too large" ? 413 : 400, $"{{\"error\":{JsonSerializer.Serialize(error.Message)}}}", request.Headers["Origin"]); }
        catch (JsonException) { await WriteBridgeResponse(response, 400, "{\"error\":\"Expected a Claude Desktop usage response\"}", request.Headers["Origin"]); }
        catch (Exception error) { TraceClaude($"Claude Desktop usage bridge handler failed={error.Message}"); await WriteBridgeResponse(response, 400, "{\"error\":\"Invalid request\"}", request.Headers["Origin"]); }
    }

    private static void AddCorsHeaders(HttpListenerResponse response, string origin)
    {
        response.Headers["Access-Control-Allow-Origin"] = origin;
        response.Headers["Access-Control-Allow-Methods"] = "POST, OPTIONS";
        response.Headers["Access-Control-Allow-Headers"] = "Content-Type";
        response.Headers["Vary"] = "Origin";
    }

    private static async Task WriteBridgeResponse(HttpListenerResponse response, int statusCode, string? value = null, string? origin = null)
    {
        if (origin is "https://claude.ai" or "https://www.claude.ai") AddCorsHeaders(response, origin);
        response.StatusCode = statusCode;
        if (value is not null)
        {
            var bytes = Encoding.UTF8.GetBytes(value);
            response.ContentType = "application/json";
            response.ContentLength64 = bytes.Length;
            await response.OutputStream.WriteAsync(bytes);
        }
        response.Close();
    }


    public void Dispose()
    {
        _bridgeCancellation.Cancel();
        if (_listener is not null)
        {
            try { _listener.Stop(); } catch { }
            _listener.Close();
        }
        _bridgeCancellation.Dispose();
    }
}
