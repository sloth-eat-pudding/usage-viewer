# Usage Viewer

Windows 透明置頂使用量顯示器，可在同一個畫面顯示 Claude Code 與 Codex 的 usage。

不需要 npm install，也不需要 build。需要：

- Windows
- Node.js
- PowerShell

確認 Node.js：

```powershell
node --version
```

## 檔案

```text
statusline-usage-capture.js   Claude Code statusLine usage 擷取器
codex-usage-read.js            Codex session JSONL usage 讀取器
UsageOverlay.ps1              透明 overlay
build-exe.cmd                 建置 UsageViewer.exe
start-overlay.cmd             啟動 overlay
start-overlay.vbs             隱藏 console 啟動 overlay
start-codex-overlay.cmd        啟動 Codex reader + overlay
start-codex-reader.cmd         只啟動 Codex reader
stop-codex-reader.cmd          停止背景 Codex reader
settings.json                 Claude Code 設定範例
```

## 輸出檔案

預設資料夾：

```text
C:\Users\user\.usage-viewer
```

主要輸出：

```text
claude-latest.json   Claude Code 最新 usage
codex-latest.json    Codex 最新 usage
latest.json          相容舊版的最新 usage，可能被任一 reader 覆蓋
history.jsonl        Claude Code 歷史紀錄
codex-history.jsonl  Codex 歷史紀錄
window-state.json    overlay 上次的位置與視窗大小
```

overlay 預設同時讀：

```text
C:\Users\user\.usage-viewer\claude-latest.json
C:\Users\user\.usage-viewer\codex-latest.json
```

## Claude Code 設定

Claude Code 設定檔建議放在：

```text
C:\Users\user\.claude\settings.json
```

需要加入：

```json
{
  "statusLine": {
    "type": "command",
    "command": "node \"C:\\Users\\user\\Documents\\usage_viewer\\statusline-usage-capture.js\""
  }
}
```

如果你已經有自己的 `settings.json`，只要合併或替換 `statusLine` 這段即可。

## 啟動

建置 exe：

```text
C:\Users\user\Documents\usage_viewer\build-exe.cmd
```

只開 overlay：

```text
C:\Users\user\Documents\usage_viewer\start-overlay.cmd
```

啟動 Codex reader 並開 overlay：

```text
C:\Users\user\Documents\usage_viewer\start-codex-overlay.cmd
```

停止背景 Codex reader：

```text
C:\Users\user\Documents\usage_viewer\stop-codex-reader.cmd
```

`start-overlay.cmd` 會優先啟動：

```text
C:\Users\user\Documents\usage_viewer\UsageViewer.exe
```

如果還沒有建置 exe，才會退回使用 `UsageOverlay.ps1`。

## Overlay 操作

- 左鍵拖曳內容區：移動視窗
- 拖曳邊界或角落：調整大小
- 點右上角 `R`：重設視窗大小
- 點右上角 `X`：關閉

overlay 無標頭、透明、置頂，且會顯示在 Windows 工具列。

## 工具列圖示

overlay 的工具列圖示放在：

```text
C:\Users\user\Documents\usage_viewer\assets\usage-viewer.ico
```

`UsageOverlay.ps1` 啟動時會自動讀取這個 `.ico` 並設定成視窗 icon。若要替換圖示，請用同名 `.ico` 覆蓋這個檔案後重新啟動 overlay。

如果工具列仍顯示 PowerShell 圖示，請先關閉舊的 overlay 再重新啟動。Windows 有時會暫存工作列圖示或沿用舊視窗分組。

## 畫面欄位

overlay 現在只顯示 usage，不顯示 token/cost 細節：

```text
Claude 12s ago | Codex 2s ago
Claude 5h 12.34%   week 3.21%
Codex  week 6.00%
```

欄位意思：

- `Claude 5h`: Claude Code 五小時 rate limit 使用百分比
- `Claude week`: Claude Code 七天 rate limit 使用百分比
- `Codex week`: Codex primary rate limit 使用百分比；目前你的 Codex 是七天視窗

Codex CLI 目前沒有支援自訂 header/status line，所以本專案不嘗試把 usage 塞進 Codex CLI 內部畫面。

## Codex 資料來源

Codex reader 讀取：

```text
C:\Users\user\.codex\sessions\...\*.jsonl
```

使用的事件：

```text
event_msg / token_count
```

預設讀全部 Codex session 的最新 usage，也就是總 usage：

```text
CODEX_USAGE_SOURCE=any
```

可選值：

```text
cli      只讀 codex-tui / Codex CLI
desktop  只讀 Codex Desktop
any      不分來源，讀最新 token_count
```

重要欄位：

```json
{
  "source": "codex-session-jsonl",
  "tokens": {
    "total_input": "last turn input tokens",
    "cache_read_input": "cached input tokens",
    "output": "output tokens",
    "reasoning_output": "reasoning output tokens",
    "session_total": "session total tokens"
  },
  "percentages": {
    "context_used": "context window 使用百分比",
    "cached_input": "cached input 佔比",
    "seven_day_used": "七天使用量，當 primary window 是 10080 分鐘時",
    "primary_limit_used": "Codex primary limit 使用量"
  },
  "rate_limits": {
    "primary": {
      "used_percent": "primary limit 使用百分比",
      "window_minutes": "10080 代表七天",
      "resets_at_epoch_seconds": "重設時間"
    }
  }
}
```

## 常見問題

如果 Claude 顯示 waiting：

- 檢查 `C:\Users\user\.claude\settings.json`
- 重開 Claude Code 或開新 session
- 確認 `claude-latest.json` 是否產生

如果 Codex 顯示 waiting：

- 先執行 `start-codex-reader.cmd`
- 確認 `codex-latest.json` 是否產生
- 確認 `C:\Users\user\.codex\sessions` 裡有 `.jsonl`
