# Usage Viewer

Windows 使用量浮窗，支援 Claude Code、Claude Desktop 與 Codex。現在已開始提供具備獨立工作列身份的 `UsageViewer.exe`，並準備 MSIX 封裝流程。

## 專案結構

```text
assets/                 視窗圖示
config/                 Claude Code 設定範例
scripts/                Windows CMD / VBS 啟動器
src/overlay/             PowerShell 浮窗
src/readers/             Claude / Codex 資料 reader 與 statusline
packaging/               MSIX manifest、圖示與封裝腳本
```

## 啟動

從 `scripts` 資料夾執行：

- `start-usage-viewer.cmd`：主要入口，啟動內建 reader 與 UsageViewer App
- `start-overlay.cmd`：只啟動浮窗
- `start-claude-desktop-reader.cmd` / `start-codex-reader.cmd`：只啟動 reader
- `stop-readers.cmd`：停止 Claude 與 Codex reader

`start-usage-viewer.cmd` 會優先啟動 `dist\\UsageViewer.exe`；尚未 publish 時才回退到 PowerShell overlay。已 publish 的 App 內建 Claude/Codex reader，不需要 Node.js。

## 直接下載

沒有 .NET SDK 或編譯環境的使用者，請從 [GitHub Releases](https://github.com/sloth-eat-pudding/usage-viewer/releases) 下載 `UsageViewer-vX.Y.Z-win-x64.zip`，解壓縮後直接執行 `UsageViewer.exe`。Release 內的 EXE 是 self-contained 版本，不需要另外安裝 .NET 或 Node.js。

## 發布版本

推送以 `v` 開頭的 tag 時，GitHub Actions 會自動建置 Windows x64 self-contained EXE、壓縮成 ZIP，並建立或更新該 tag 的 GitHub Release：

```powershell
git tag v1.0.0
git push origin v1.0.0
```

建置結果也會保留在該次 Actions run 的 Artifacts 中。

## 建置桌面 App

```powershell
dotnet publish src\\UsageViewer\\UsageViewer.csproj -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:EnableCompressionInSingleFile=true -p:SatelliteResourceLanguages=en -o dist
```

MSIX 封裝需要 Windows SDK 的 `makeappx.exe`：

```powershell
powershell -ExecutionPolicy Bypass -File packaging\\build-msix.ps1
```

資料會寫入 `%USERPROFILE%\.usage-viewer`。若要讓 Claude Code 寫入 usage，將 `config/settings.json` 的設定合併到 `%USERPROFILE%\.claude\settings.json`，並確認路徑指向本專案的 `src\readers\statusline-usage-capture.js`。

若 Codex 使用遠端 session，請將遠端產生的最新 usage snapshot 同步到 `%USERPROFILE%\.usage-viewer\codex-remote-latest.json`。Viewer 會比較 snapshot 的 `observed_at`，自動顯示本機或遠端較新的資料。檔案格式沿用 `codex-app-latest.json`，至少需要包含 `observed_at`（ISO 8601）、`percentages`、`resets_at` 三個欄位。

可使用 `scripts\sync-codex-remote.ps1` 自動同步。腳本目前已設定連線到 `jerry@192.168.2.57`，只會透過 SCP 複製遠端 `~/.codex/sessions`，遠端不需要安裝 Python、Node.js 或本專案。

Usage Viewer 啟動時會自動在背景啟動這個同步器，關閉 Viewer 時也會一併停止；不需要另外手動執行 PowerShell。重新啟動 Viewer 後即可套用設定。

SSH 私鑰與連接埠是選填參數：`SshKeyPath` 預設為空，會使用 SSH 預設認證方式；`SshPort` 預設為 `22`，只有改成其他數字時才會加上 `-P` 參數。若兩者維持預設值，就不會額外啟用任何 SSH 選項。

連線參數直接放在 repo 的 `config\remote.env`，程式啟動的同步器會讀取它，設定值會覆蓋腳本預設值。請先複製 `config\remote.env.example` 為 `config\remote.env` 再修改。支援 `REMOTE_USER`、`REMOTE_HOST`、`POLL_SECONDS`、`SSH_KEY_PATH`、`SSH_PORT` 與 `REMOTE_SESSIONS_PATH`；未設定的項目會保留預設值。`config\remote.env` 已加入 `.gitignore`，不會被追蹤。
