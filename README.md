# Usage Viewer

Windows 桌面浮窗，用來查看 Claude 與 Codex 的 5 小時、7 天用量與重置時間。支援 Claude Desktop、Claude Code、Codex Desktop、Codex CLI，以及可選的遠端 Codex session 同步。

浮窗以公司名稱首字母顯示產品：`A` 代表 Anthropic（Claude），`O` 代表 OpenAI（Codex）。括號內仍保留來源與分組標籤。

> 使用前請閱讀 [免責聲明與第三方服務合規說明](DISCLAIMER.md)。Usage Viewer 並非 Anthropic、OpenAI 或其關係企業的官方產品，亦未獲其認可或背書；顯示的資料僅供參考，不應作為任何決策的唯一依據。

## 執行模式

專案提供兩個彼此獨立的執行方式；兩者共用 `%USERPROFILE%\.usage-viewer` 的 snapshot 與顯示設定。

| 模式 | 入口 | Reader | 適用情境 |
| --- | --- | --- | --- |
| WPF 桌面程式 | `UsageViewer.exe` 或 `scripts\start-wpf-usage-viewer.cmd` | 內建 C# reader | 一般使用與 GitHub Release；使用 Windows 10/11 內建的 .NET Framework 4.8，不需另外安裝 .NET 或 Node.js。 |
| PowerShell overlay | `scripts\start-usage-viewer.cmd` | Node.js readers + PowerShell overlay | 開發、除錯，或要直接使用腳本版浮窗時。 |

兩條路徑不會互相啟動；請一次只使用其中一種。`scripts\restart-usage-viewer.cmd` 用於重新啟動目前開發中的 PowerShell overlay、readers 與遠端同步器。

## 直接使用

從 [GitHub Releases](https://github.com/sloth-eat-pudding/usage-viewer/releases) 下載 `UsageViewer-vX.Y.Z-win-x64.zip`（約 0.6 MB），解壓縮到任一資料夾後直接執行 `UsageViewer.exe`。資料夾內的 `.dll`、`UsageViewer.exe.config` 與 `scripts` 需與 exe 放在一起。

程式使用 Windows 10/11 內建的 .NET Framework 4.8，不需安裝其他 runtime。

exe 會在背景讀取本機 Claude/Codex session，並把資料寫入 `%USERPROFILE%\.usage-viewer`。右上角按鈕功能如下：

- `P`：釘選浮窗並讓其餘區域點擊穿透；按 `U` 解除。
- `Settings`：選擇版面（兩列欄位或逐行堆疊）、來源群組、自訂 Claude history、SSH 來源、Codex 帳號視窗與 Claude Desktop bridge 設定。
- `×`：結束 viewer 與它啟動的背景 reader。
- `Ctrl+Alt+P`：切換釘選。

exe 與腳本版共用相同的讀取來源與顯示規則：沒有偵測到 Claude Desktop profile 時顯示 `claude-desktop-latest.json`；沒有設定 SSH 來源時，顯示舊的遠端 Codex 快取（SSH 同步已停用，資料不會再更新）。exe 同時只會執行一個；本機 bridge 埠被占用時，每 15 秒重試一次。

## 來源與顯示設定

Claude 來源包括 Desktop、CLI 與可選的自訂 `plan-usage-history.json`；Codex 來源包括 Desktop、CLI 與遠端 SSH。每一個來源都可在 Settings 中設定為：

- `Group 1`、`Group 2` 或 `Group 3`：同一產品中相同群組的來源會合併成一行，並採用該群組最新的 snapshot。
- `Hidden`：不顯示該來源，也停止取得該來源的使用量；改回群組後會在下一次輪詢恢復取得。

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

Usage Viewer 的 CMD overlay 與 EXE 都會在 `127.0.0.1:8765` 啟動一個只限本機的 bridge。它只接受 Claude Desktop DevTools 從 `https://claude.ai` 傳來的 usage 結果，並依 organization ID 分別保存使用百分比與 5h／7d 的重置時間；不會讀取或保存 Cookie、Authorization header 或完整 API 回應。

在 Claude Desktop 啟用 Developer Mode 後，先執行一次 `scripts\configure-claude-desktop-auto-bridge.ps1`（exe 使用者可改按 Settings →「Claude Desktop usage bridge」→「Enable automatic bridge」）。它會設定 Claude 官方支援的 `CLAUDE_DEV_TOOLS=undocked` 使用者環境變數，讓下一次 Claude 啟動時自動開啟 DevTools。Usage Viewer 會從本機 `plan-usage-history.json` 找出 organization ID，等待鍵鼠閒置後以 Unicode 鍵盤輸入下列等效同步程式，再關閉 DevTools 並恢復原本的前景視窗。Claude 之後每次重啟都會自動再次注入；目前已在執行的 Claude 不會被強制關閉。

正式版 Claude 會拒絕一般的 remote-debugging/CDP 參數，因此這個流程使用 Claude 自己的 Developer Mode；不會修改 Claude 安裝檔、讀取程序記憶體、Cookie 或 Authorization header。執行 `scripts\configure-claude-desktop-auto-bridge.ps1 -Disable` 可還原由本專案建立的環境設定；`CLAUDE_DESKTOP_AUTO_BRIDGE=0` 可只停用 injector。若某個 profile 的 `plan-usage-history.json` 已不存在，可在 `config\claude-profile-organizations.json`（exe 也會讀取 `%USERPROFILE%\.usage-viewer\claude-profile-organizations.json` 或 exe 旁的 `config` 資料夾）明確對應路徑與 organization ID，讓它繼續使用 bridge 的用量。手動診斷時仍可於 DevTools Console 執行：

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

## Claude Desktop 模型旁的 session 顯示

既有 Developer Mode 注入流程也會載入 `src/desktop-addon/claude-session-meter.js`，在 Desktop **Code session（含 SSH）** 的模型按鈕旁顯示快取剩餘時間推估、cache 命中率與 session 費用。點擊數字可查看 token 明細與資料限制。

日常啟動可直接雙擊專案根目錄的 `Start-Claude-Session-Meter.cmd`。同時開啟兩個 Claude Desktop／profile 時，只需啟動一次；背景程序會依序檢查各視窗，鍵鼠閒置後自動加入顯示，後開的視窗也會納入。

它透過 Desktop 已有的唯讀 session 介面取得目前對話紀錄，不會發送模型請求來保溫。費用優先顯示引擎回報的累計值；缺少回報時才依已知模型與 cache 分類推估 API 成本，兩者皆不是訂閱方案的實際帳單。一般 Chat／Cowork 與多個模型選擇器的分割畫面目前不顯示，避免配對錯誤。詳細說明見 [session 顯示元件](docs/claude-session-meter.md)。

腳本版的啟動與重新啟動入口都會執行 `scripts\watch-claude-desktop-usage-bridge.ps1`，每 15 秒檢查本機 bridge，未啟動或停止回應時自動恢復。啟動紀錄與標準錯誤保存在 `%USERPROFILE%\.usage-viewer\claude-desktop-usage-bridge-watch.log` 與 `claude-desktop-usage-bridge.stderr.log`。

## Codex Desktop 原介面用量標籤（實驗）

在 Usage Viewer 的 **Settings → Codex account windows** 選帳號按 **Open**，即可建立或重開官方 Codex 視窗。初始只有原本帳號 `Codex`（名稱可自訂）；要新增時在 **Manage accounts… → 新增帳號** 註冊名稱與資料夾，保存後不用每次重選。程式自動管理本機埠，並啟用全寬、目前聊天的快取命中率／粗估倒數及 API 標準價成本估算（需 Node.js 22+）。指令入口為 `Start-Codex-Account-Profile.cmd -ProfileRoot "D:\CodexProfiles\account-a" -Port 19336`。沒有此 profile 的本機用量紀錄時顯示未知。完整多帳號憑證隔離尚未驗證，詳細範圍見 [帳號資料夾實驗](docs/codex-account-profile.md)。

雙擊 `Start-Codex-Session-Meter.cmd`，即可啟動附有全寬與用量標籤的官方 Codex 測試視窗。標籤顯示 5h／7d 已使用百分比、來源快取命中率，以及基於 API 預設 30 分鐘假設的粗估倒數；不是伺服器實際到期時間。每五秒讀取本機快照，按 × 可移除並還原欄寬；不修改安裝檔。此入口沿用目前帳號，尚未實測多帳號隔離。詳細環境、操作限制及還原方式見 [原介面用量標籤實驗](docs/codex-native-meter.md)。

## 遠端 Codex 同步已停用

Usage Viewer 不再透過 SSH/SCP 複製遠端 .codex/sessions，啟動與重啟也不會啟動同步器。舊的同步腳本僅保留為相容入口，執行時直接結束。既有遠端快取與 SSH 設定保留，但 SSH 用量不再自動更新；畫面上可能仍顯示舊快取資料。

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

完整本機檢查（需 Node.js 與 .NET 8 以上 SDK）：

```powershell
.\scripts\test-usage-viewer.ps1
```

這個入口會檢查腳本語法、執行兩種 bridge 共用的格式案例、Claude injector／HTTP bridge 測試、C# reader／設定回歸測試，以及 WPF Release 建置。測試使用獨立暫存資料，不會啟動桌面注入。可用 `-DotNetPath` 指定 SDK 的 `dotnet.exe`；元件職責與後續修改原則見 [架構與回歸測試](docs/architecture.md)。

## 建置與發布

本機 publish：

```powershell
dotnet publish src\UsageViewer\UsageViewer.csproj -c Release -o dist
```

之後可使用 `scripts\start-wpf-usage-viewer.cmd` 啟動 `dist\UsageViewer.exe`。專案已設定 `EnableWindowsTargeting`，在 Linux／macOS 上也能用同一個指令建置 Windows 版本。

如需 MSIX，先完成 publish 並安裝 Windows SDK，再執行：

```powershell
powershell -ExecutionPolicy Bypass -File packaging\build-msix.ps1
```

推送 `v` 開頭的 tag 會觸發 GitHub Actions，執行 C# 回歸測試，產生可攜式 Windows 程式的 ZIP、上傳 artifact，並建立或更新 GitHub Release：

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
