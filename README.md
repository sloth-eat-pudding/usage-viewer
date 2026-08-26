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

- `start-usage-viewer.cmd`：獨立的 PowerShell overlay + readers 入口
- `start-wpf-usage-viewer.cmd`：獨立啟動已 publish 的 WPF `UsageViewer.exe`
- `start-overlay.cmd`：只啟動浮窗
- `start-claude-desktop-reader.cmd` / `start-codex-reader.cmd`：只啟動 reader
- `stop-readers.cmd`：停止 Claude 與 Codex reader

兩個入口互不依賴，但共用 `%USERPROFILE%\.usage-viewer` 內的 usage snapshot；overlay 入口不會啟動或檢查 WPF `.exe`。

## 開發修改後的驗證流程

修改 reader、overlay 或 WPF Viewer 後，需同步確認兩種執行路徑：Node/C# reader 都要寫入相同的 Desktop、CLI、SSH snapshot；PowerShell overlay 與 WPF Viewer 都要使用相同的 Combined/Separate 顯示規則。完成檢查後，重新執行 `scripts\restart-usage-viewer.cmd`，讓目前使用者直接看到最新結果。Overlay 的顯示選項由右上角 `Settings` 設定。

也可以直接執行 `scripts\restart-usage-viewer.cmd`；它會重新啟動使用量 viewer，方便在修改完成後立即查看最新畫面。

重啟腳本 `restart-usage-viewer.ps1` 會清理所有舊程序，並直接啟動最新的 overlay、readers 與 SSH synchronizer，不依賴 `start-usage-viewer.vbs` 的啟動鏈，避免多個舊 overlay 殘留造成看到舊畫面。

PowerShell overlay 另有具名 mutex 單一執行個體鎖；即使啟動器被重複執行，也只允許一個 Usage Viewer 顯示器存在。

Overlay 高度會依主內容與重置時間的實際行數自動調整，並保留字型下緣與視窗底部 padding，避免最後一行重置時間被裁切。

SSH snapshot 採用單調時間保護：只有 `observed_at` 不早於目前 `codex-remote-latest.json` 的候選資料才能覆寫。SCP 同步期間若暫時只看到舊 session，Node 與 C# reader 都會保留上一份較新的有效 snapshot，避免 SSH 用量在不同歷史 session 間跳動。

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

Codex usage 會依來源分開寫入 `%USERPROFILE%\.usage-viewer`：`codex-desktop-latest.json`、`codex-cli-latest.json`、`codex-remote-latest.json`。三者都包含獨立的 `observed_at`、`percentages.five_hour_used`、`percentages.seven_day_used`、`resets_at.five_hour_epoch_seconds` 與 `resets_at.seven_day_epoch_seconds`，不會把 Desktop、CLI、SSH 的使用量混在一起。`codex-app-latest.json` 保留為相容輸出，代表最新的本機 Desktop/CLI 資料，不包含 SSH。

目前兩種執行方式都會同步產生上述檔案：直接執行 `src\readers\codex-usage-read.js` 的 Node reader，以及 Usage Viewer 內建的 C#/WPF reader。Desktop 與 CLI 視為同一個本機 Codex；`Combined` 顯示合併後的本機 Codex，`Separate` 則顯示本機與遠端兩行，遠端來源只在該行最末尾標示 `(SSH)`。每個 Codex 行固定顯示 `7d` 與 `5h`，資料缺失時顯示 `-`。

`scripts\start-usage-viewer.cmd` 是獨立的 PowerShell overlay 入口，不依賴也不會啟動 `dist\UsageViewer.exe`。WPF 桌面程式是另一條獨立路徑，使用 `scripts\start-wpf-usage-viewer.cmd` 啟動；兩者共用 snapshot，但不互相依賴。

Overlay 右上角的 `Settings` 會開啟自由來源群組設定頁。Claude Desktop/CLI 與 Codex Desktop/CLI/remote（SSH）各自可指定 `Group 1`、`Group 2`、`Group 3` 或 `Hidden`；同一產品中指定到相同 Group 的來源會合併，不同 Group 各自顯示。這可表達 D+C、D+SSH、C+SSH、全部合併或全部分開。設定保存到 `%USERPROFILE%\.usage-viewer\display-settings.json`，重啟後自動套用。

設定頁採用與主 overlay 一致的深色無框、扁平按鈕與右上角關閉鍵風格。

可使用 `scripts\sync-codex-remote.ps1` 自動同步。腳本目前已設定連線到 `jerry@192.168.2.57`，只會透過 SCP 複製遠端 `~/.codex/sessions`，遠端不需要安裝 Python、Node.js 或本專案。

Usage Viewer 啟動時會自動在背景啟動這個同步器，關閉 Viewer 時也會一併停止；不需要另外手動執行 PowerShell。重新啟動 Viewer 後即可套用設定。

SSH 私鑰與連接埠是選填參數：`SshKeyPath` 預設為空，會使用 SSH 預設認證方式；`SshPort` 預設為 `22`，只有改成其他數字時才會加上 `-P` 參數。若兩者維持預設值，就不會額外啟用任何 SSH 選項。

連線參數直接放在 repo 的 `config\remote.env`，程式啟動的同步器會讀取它，設定值會覆蓋腳本預設值。請先複製 `config\remote.env.example` 為 `config\remote.env` 再修改。支援 `REMOTE_USER`、`REMOTE_HOST`、`POLL_SECONDS`、`SSH_KEY_PATH`、`SSH_PORT` 與 `REMOTE_SESSIONS_PATH`；未設定的項目會保留預設值。`config\remote.env` 已加入 `.gitignore`，不會被追蹤。
