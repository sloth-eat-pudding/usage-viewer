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
