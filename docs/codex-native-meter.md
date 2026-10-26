# Codex Desktop 原介面用量標籤：實驗紀錄

這個元件直接掛載到官方 Desktop 主頁 `app://-/index.html` 的 composer 容器，不是網頁分頁、iframe 或獨立浮窗。它顯示本機 `codex-desktop-latest.json` 的 5h／7d **已使用**百分比，資料超過五分鐘、時間異常或缺失時標示較舊／未知。來源可能是其他 Desktop 聊天；它不是目前聊天的專屬額度。

版本 `0.2.0` 也將聊天內容與輸入區的最大寬度放寬到各自容器的 100%，保留原生留白、側欄與分割區邊界。只調整已觀測到的 thread 欄寬 class，不修改整個應用程式的對話框或所有 `max-width`。新聊天與路由切換也會套用；關閉元件會一併移除樣式、還原原始寬度。

## 快取資料的可見範圍

標籤顯示「來源快取命中」與「期限未知」。命中率採用本機 reader 快照的 `percentages.cached_input`，也就是來源最近一次輸入的 cached input / input tokens；不是快取剩餘時間，也不是目前畫面聊天的專屬數值。

實測 Desktop token-count 紀錄包含 `cached_input_tokens` 與 `cache_write_input_tokens`，但未提供 TTL 或 `expires_at`，因此目前沒有可靠的精確到期倒數。沒有命中率資料時顯示 `—`，不當成零。

[OpenAI API 的 prompt caching 文件](https://developers.openai.com/api/docs/guides/prompt-caching)描述了不同模型與設定下的快取保留行為；API 的預設值不能直接當成這次 Codex Desktop 請求的實際設定或精確到期時間。元件不猜測固定 5m／30m／1h，也不發送保溫請求。

## 已實測環境

- 日期：2026-10-26。
- Windows Store 套件：`OpenAI.Codex_26.1013.4894.0_x64__2p2nqsd0c76g0`。
- `owl-app.ini` 應用版本：`26.1013.40934`。
- CDP 回報：Chrome `155.0.8059.80`，Protocol `1.3`。
- 用獨立 `--user-data-dir` 啟動官方執行檔，未關閉原本聊天、未複製憑證、未修改安裝檔或使用者設定。
- 官方 Store 啟動後可連到本機 CDP；本機測試的 PowerShell `Get-NetTCPConnection` 沒有可靠反映結果，以 HTTP `/json/version` 與 `netstat -ano -p tcp` 交叉確認。

獨立 Electron profile 仍會使用同一帳號的 Codex 後端與專案；它不是帳號或檔案權限隔離環境。啟動測試實例會暫時開啟額外的應用程序。

## 注入入口

`scripts/codex-native-meter.cjs` 只連線到 `127.0.0.1`，且必須提供剛剛驗證的 browser ID。呼叫前，須用 `netstat` 確認 CDP listener 的 PID 屬於本次啟動的官方 Codex，位址只能是本機回環。`browser-id` 是 `/json/version` 回傳的 WebSocket URL 最後一段，不能跨重啟沿用。

```powershell
node scripts/codex-native-meter.cjs --port 19335 --browser-id <verified-browser-id> --watch
```

不加 `--watch` 只更新一次；watch 每五秒讀取本機快照。只處理主介面的 `app://-/index.html`，不注入瀏覽器網頁、iframe、寵物輸入框或其他來源。資料從 driver 傳入，不從 renderer 讀取 auth、對話文字或呼叫內部 API。若 composer 不唯一或結構不符合預期，元件不顯示。

## 移除與還原

- 點標籤旁的 ×，該 renderer 的標籤、全寬樣式與 observer 立即移除；watch 不會推翻關閉動作。重載頁面後才會重新安裝。
- 或對同一個已驗證端點執行：

```powershell
node scripts/codex-native-meter.cjs --port 19335 --browser-id <verified-browser-id> --remove
```

- 停止 watcher 並關閉測試實例可關閉 CDP 埠；原本正常啟動的 Codex 不受影響。沒有安裝檔 patch 可還原。
- CDP 能控制整個測試實例，僅限本機不代表沒有權限；不要將埠轉發或暴露到外部。

這是非官方、依賴 Desktop DOM 的原型。更新 Codex 後必須重新驗證，不保證跨版本相容，也尚未設定為日常自動啟動。

## 參考

- [Newskin Windows 啟動方式](https://github.com/pjf6568/codex-newskin/blob/main/windows/scripts/start-newskin.ps1)：參考本機 CDP 啟動流程，未執行第三方安裝器。
- [Explodex](https://github.com/dan-dr/explodex)：參考原介面元件注入方向；該專案未宣稱支援 Windows。
