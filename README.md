# Usage Viewer

Windows 桌面浮窗，用來查看 Claude 與 Codex 的 5 小時、7 天用量與重置時間。支援 Claude Desktop、Claude Code、Codex Desktop、Codex CLI，以及可選的遠端 Codex session 同步。

> 使用前請閱讀 [免責聲明與第三方服務合規說明](DISCLAIMER.md)。Usage Viewer 並非 Anthropic、OpenAI 或其關係企業的官方產品，亦未獲其認可或背書；顯示的資料僅供參考，不應作為任何決策的唯一依據。

## 執行模式

專案提供兩個彼此獨立的執行方式；兩者共用 `%USERPROFILE%\.usage-viewer` 的 snapshot 與顯示設定。

| 模式 | 入口 | Reader | 適用情境 |
| --- | --- | --- | --- |
| WPF 桌面程式 | `UsageViewer.exe` 或 `scripts\start-wpf-usage-viewer.cmd` | 內建 C# reader | 一般使用與 GitHub Release；self-contained exe 不需安裝 .NET 或 Node.js。 |
| PowerShell overlay | `scripts\start-usage-viewer.cmd` | Node.js readers + PowerShell overlay | 開發、除錯，或要直接使用腳本版浮窗時。 |

兩條路徑不會互相啟動；請一次只使用其中一種。`scripts\restart-usage-viewer.cmd` 用於重新啟動目前開發中的 PowerShell overlay、readers 與遠端同步器。

## 直接使用

從 [GitHub Releases](https://github.com/sloth-eat-pudding/usage-viewer/releases) 下載 `UsageViewer-vX.Y.Z-win-x64.zip`，解壓縮後直接執行 `UsageViewer.exe`。

exe 會在背景讀取本機 Claude/Codex session，並把資料寫入 `%USERPROFILE%\.usage-viewer`。右上角按鈕功能如下：

- `P`：釘選浮窗並讓其餘區域點擊穿透；按 `U` 解除。
- `Settings`：選擇要顯示的來源、群組與自訂 Claude history 檔案。
- `×`：結束 viewer 與它啟動的背景 reader。

## 來源與顯示設定

Claude 來源包括 Desktop、CLI 與可選的自訂 `plan-usage-history.json`；Codex 來源包括 Desktop、CLI 與遠端 SSH。每一個來源都可在 Settings 中設定為：

- `Group 1`、`Group 2` 或 `Group 3`：同一產品中相同群組的來源會合併成一行，並採用該群組最新的 snapshot。
- `Hidden`：不顯示該來源。

因此可表達 D+C、D+SSH、C+SSH、全部合併或全部分開。設定保存在 `%USERPROFILE%\.usage-viewer\display-settings.json`，兩種模式都會套用。自訂 Claude history 的路徑也會寫入 `%USERPROFILE%\.usage-viewer\claude-custom-source.json`，供 WPF reader 產生 `claude-custom-latest.json`。

## 資料檔案

所有 snapshot 都位於 `%USERPROFILE%\.usage-viewer`。主要檔案如下：

| 檔案 | 來源 |
| --- | --- |
| `claude-desktop-latest.json` | Claude Desktop session/history |
| `claude-statusline-latest.json` | Claude Code status line |
| `claude-custom-latest.json` | Settings 指定的 Claude history |
| `codex-desktop-latest.json` | Codex Desktop session |
| `codex-cli-latest.json` | Codex CLI session |
| `codex-remote-latest.json` | 同步到本機的遠端 Codex session |

每份 snapshot 都保留來源、觀測時間、5h/7d 百分比與重置時間。遠端 Codex snapshot 使用時間單調保護，避免同步到較舊 session 時覆寫較新的資料。

## Claude Code status line

將 [`config/settings.json`](config/settings.json) 的 `statusLine` 設定合併到 `%USERPROFILE%\.claude\settings.json`，並把 command 中的路徑改成此專案內 `src\readers\statusline-usage-capture.js` 的實際絕對路徑。

## Claude Desktop 精確重置時間（可選）

Usage Viewer 啟動時會在 `127.0.0.1:8765` 啟動一個只限本機的 bridge。它只接受 Claude Desktop DevTools 從 `https://claude.ai` 傳來的 usage 結果，並依 organization ID 分別保存使用百分比與 5h／7d 的重置時間；不會讀取或保存 Cookie、Authorization header 或完整 API 回應。

在 Claude Desktop 啟用 Developer Mode 後，於 DevTools Console 執行下列程式一次，將 `<org-id>` 換成 Network 中 usage request 的組織 ID：

```js
const orgIds = ['<first-org-id>', '<second-org-id>']
window.forwardClaudeDesktopUsage = async () => {
  await Promise.all(orgIds.map(async orgId => {
    const usage = await fetch(`/api/organizations/${orgId}/usage`).then(response => response.json())
    await fetch(`http://127.0.0.1:8765/claude-desktop-usage?org=${encodeURIComponent(orgId)}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(usage)
    })
  }))
}
window.forwardClaudeDesktopUsage()
window.usageBridgeTimer = setInterval(() => window.forwardClaudeDesktopUsage(), 60_000)
```

收到 bridge snapshot 後，Claude Desktop reader 會在五分鐘內優先採用其中精確的重置時間；超時後自動回退到本機 usage history 的推估值。

## 遠端 Codex 同步（可選）

複製 `config\remote.env.example` 為 `config\remote.env`，再填入你的 SSH 連線資訊：

```powershell
Copy-Item config\remote.env.example config\remote.env
```

支援 `REMOTE_USER`、`REMOTE_HOST`、`POLL_SECONDS`、`SSH_KEY_PATH`、`SSH_PORT` 與 `REMOTE_SESSIONS_PATH`。同步器只透過 SCP 複製遠端 `.codex/sessions` 到本機快取；遠端主機不需要安裝此專案。

`config\remote.env` 是個人機器設定，已加入 `.gitignore`。WPF publish 時若此檔存在，會一併帶到 publish 輸出，供 exe 的背景同步器讀取。

## 開發

```powershell
# 啟動腳本版 overlay + Node readers
.\scripts\start-usage-viewer.cmd

# 重新啟動腳本版 viewer（修改後使用）
.\scripts\restart-usage-viewer.cmd

# 停止腳本版 readers
.\scripts\stop-readers.cmd
```

修改 reader、overlay、WPF UI 或設定後，先做適當的語法／建置檢查，再執行 `scripts\restart-usage-viewer.cmd`。WPF 與腳本 reader 都必須維持相同的 snapshot 格式與來源分組語意。

## 建置與發布

本機 publish：

```powershell
dotnet publish src\UsageViewer\UsageViewer.csproj -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:EnableCompressionInSingleFile=true -p:SatelliteResourceLanguages=en -o dist
```

之後可使用 `scripts\start-wpf-usage-viewer.cmd` 啟動 `dist\UsageViewer.exe`。

如需 MSIX，先完成 publish 並安裝 Windows SDK，再執行：

```powershell
powershell -ExecutionPolicy Bypass -File packaging\build-msix.ps1
```

推送 `v` 開頭的 tag 會觸發 GitHub Actions，產生 Windows x64 self-contained exe 的 ZIP、上傳 artifact，並建立或更新 GitHub Release：

```powershell
git tag v0.0.10
git push origin v0.0.10
```

## 專案結構

```text
src/UsageViewer/       WPF exe 與內建 C# reader
src/overlay/           PowerShell overlay
src/readers/           Node.js readers 與 Claude Code status line capture
scripts/               啟動、停止、重啟與 SSH 同步腳本
config/                Claude Code 範例與機器專屬遠端設定範本
packaging/             MSIX manifest、資產與封裝腳本
.github/workflows/     tag 觸發的 Windows release build
```
