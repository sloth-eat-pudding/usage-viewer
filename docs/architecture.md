# 架構與回歸測試

WPF 與 PowerShell overlay 仍是兩個獨立入口，共用既有 JSON 檔名與設定格式。

## WPF 元件

| 元件 | 職責 |
| --- | --- |
| `UsageReaderService` | 每兩秒協調 reader 更新，避免重疊更新，管理元件生命週期。 |
| `Readers/ClaudeUsageReader` | Claude history、statusline、CLI 精確重置時間及來源選擇。 |
| `Readers/ClaudeDesktopApiUsage` | 依 organization 讀取 bridge snapshot，檢查來源與五分鐘有效期限。 |
| `Readers/CodexUsageReader` | 本機／遠端 session 掃描、Desktop／CLI 分類、事件時間排序，以及 watcher 與定期重掃。 |
| `Integration/ClaudeDesktopUsageBridge` | 只限本機的 HTTP 接收、來源與請求驗證。 |
| `Integration/ClaudeUsageContract` | 純資料正規化：新舊 Claude API 格式、用量有效範圍、重置時間。 |
| `Integration/BackgroundProcesses` | 啟動與關閉自有的遠端同步器與 injector 子程序。 |
| `Storage/SnapshotStore` | JSON 儲存、原子替換、來源設定讀取與遠端 snapshot 時間保護。 |
| `Settings/DisplaySettings`、`DisplayGroups` | 設定模型、舊格式相容與群組代碼。 |
| `Settings/DisplaySettingsStore` | 設定檔讀寫與提供背景 reader 的來源設定檔。 |
| `Settings/SettingsDialog` | 設定視窗、來源編輯與環境開啟操作；回傳儲存結果給主視窗。 |
| `MainWindow` | 浮窗、用量呈現、釘選、位置與視窗互動。 |

Reader 建構時不啟動背景程序。測試可指定獨立的 snapshot 目錄、Claude history 清單及 Codex session 目錄。主服務停止時會先等待正在執行的更新結束，再釋放資源。

## C# 與 JavaScript 的資料契約

為保留不需 Node.js 的 EXE 發布方式，兩種執行模式仍各有實作。JavaScript 的正規化邏輯位於 `src/readers/claude-usage-contract.js`，載入它不會啟動 HTTP server。

兩種正規化實作必須通過 `tests/fixtures/claude-usage.json` 的相同案例，包括新舊 API 格式、0%／100%、canonical 欄位優先、逐欄位回退、數字字串與無效用量。修改支援的 API 格式時，同時更新兩種實作與這份 fixture。

## 執行檢查

```powershell
.\scripts\test-usage-viewer.ps1
```

需要 Windows、Node.js 與 .NET 7 SDK。此入口不會重啟 viewer；修改完成後仍須執行 `scripts\restart-usage-viewer.cmd`。

C# 回歸程式直接編譯正式元件，不需要額外的測試套件，涵蓋多帳號隔離、來源選擇、過期／損毀 snapshot、Codex 事件順序與空目錄、遠端時間保護、設定相容，以及並行原子寫入。既有 injector 測試只載入純函式並編譯原生 helper，不呼叫其鍵盤／視窗操作；HTTP 測試啟動獨立的測試 bridge。

## 後續整理邊界

這輪保留 overlay 和 injector 的操作流程。後續可在目前回歸測試基礎上，將 injector 的視窗操作、profile 探索與重試流程分開；其桌面互動行為應另做實機驗證。
