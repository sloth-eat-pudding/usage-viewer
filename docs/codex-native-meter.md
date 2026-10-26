# Codex Desktop 原介面用量標籤：實驗紀錄

這個元件直接掛載到官方 Desktop 主頁 `app://-/index.html` 的 composer 容器，不是網頁分頁、iframe 或獨立浮窗。版本 `0.4.0` 依輸入框 React 元件上的目前聊天 ID，配對指定 `CODEX_HOME/sessions` 內唯一且 metadata ID 相符的本機紀錄。只把最小用量資料傳回 renderer，不讀取登入憑證或 renderer 的對話文字。無法配對、分割輸入框不唯一或 profile 沒有紀錄時顯示未知，絕不借用其他聊天或 profile 的數值。5h／7d 為該紀錄回報的帳號額度已使用百分比；資料超過五分鐘會標示較舊。

版本 `0.2.0` 也將聊天內容與輸入區的最大寬度放寬到各自容器的 100%，保留原生留白、側欄與分割區邊界。只調整已觀測到的 thread 欄寬 class，不修改整個應用程式的對話框或所有 `max-width`。新聊天與路由切換也會套用；關閉元件會一併移除樣式、還原原始寬度。

## 快取資料的可見範圍

版本 `0.4.0` 顯示目前聊天最近一次輸入的 cached input / input tokens，以及使用者要求的粗估倒數，例如「快取≈28:12（假設30m）」。只更新額度、但累計 token 沒有增加的事件，不會延長倒數；切換聊天時立即清除配對不符的資料。

實測 Desktop token-count 紀錄包含 `cached_input_tokens` 與 `cache_write_input_tokens`，但未提供 TTL 或 `expires_at`。針對 GPT-5.6 之後的模型，若該筆來源用量紀錄有快取讀／寫，粗估窗口採用 `observed_at + 30 分鐘`，每秒顯示倒數。輪詢與重開程式不會延長同一筆事件的窗口。模型不符合、沒有快取使用紀錄或時間不合理時顯示未知；沒有命中率資料時顯示 `—`，不當成零。

[OpenAI API 的 prompt caching 文件](https://developers.openai.com/api/docs/guides/prompt-caching)描述了 GPT-5.6 之後模型預設 30 分鐘的最低快取窗口及讀取刷新行為。這裡只是借用該預設值作假設，未驗證 Desktop 的實際設定、伺服器讀寫時刻或各 prefix 的生命週期。來源事件時間也可能晚於請求開始時間。歸零顯示「30m估算窗已過」，不宣稱快取已失效；正值也不保證下次命中。元件不發送保溫請求。

## 日常啟動與帳號

**Settings → Create / open Codex profile…** 建立的新視窗也會自動啟用全寬與標籤，watcher 明確指定該資料夾的 `codex` home。新資料夾在登入並產生本機用量紀錄前顯示未知。這不代表完整多帳號憑證隔離已驗證，詳見 [資料夾啟動](codex-account-profile.md)。

在專案根目錄雙擊 `Start-Codex-Session-Meter.cmd`。需要 Node.js 22+ 與目前 Windows 使用者已註冊的官方 Store Codex。啟動器自動找到最新安裝位置、使用 `.tools/codex-native-test-profile` 啟動或重用視窗、驗證 loopback 埠的程序與 profile 身份、取得當次 browser ID，再啟動 reader 與背景 watcher。重複啟動會替換同一個已驗證實例的 watcher，不強制關閉 Codex。按過 × 後再次雙擊啟動入口會重新啟用元件與全寬。

平常從官方 Codex 捷徑開啟的視窗不會自動附加元件。測試實例完整結束後，watcher 遇到斷線會退出；下次仍用上述入口啟動。執行紀錄與當次程序身份保存在 `.tools/codex-native-meter-*`，不提交版本控制。若第一次啟動失敗，錯誤會停留在命令視窗，不會關閉正常 Codex 或接管身份不明的埠。

這個入口沿用目前帳號的 Codex home／後端。開不同聊天、分頁或此測試視窗，**不等於不同帳號**。獨立 `--user-data-dir` 只隔開桌面瀏覽資料；不能視為帳號隔離。

同時使用不同帳號需另行驗證獨立的桌面 profile、`CODEX_HOME`／憑證儲存、CDP 埠與 reader snapshot 目錄。官方 [環境變數](https://learn.chatgpt.com/docs/config-file/environment-variables)列出 `CODEX_HOME` 涵蓋 config、auth、logs 與 sessions；[登入文件](https://learn.chatgpt.com/docs/auth)也說明憑證可能存在 auth.json 或系統憑證存放區。不能只換頁面或只換 UI profile 就承諾帳號完全分開。本版本尚未實測多帳號，請勿用它進行帳號隔離或在共用實例登出另一帳號。

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

不加 `--watch` 只更新一次；watch 每五秒配對目前聊天的本機 session。可加 `--codex-home <profile 的 codex 目錄>`，省略時使用程序的 CODEX_HOME 或預設目錄。只處理主介面的 `app://-/index.html`，不注入瀏覽器網頁、iframe、寵物輸入框或其他來源。若 composer 不唯一或結構不符合預期，元件不顯示。

## 成本估算

依 [OpenAI API 價格](https://developers.openai.com/api/docs/pricing)（2026-10-26）換算 GPT-6.1 Sol、GPT-6 Astra、GPT-6 Luna 與 GPT-5.6 Sol 的輸入、快取輸入及輸出 token。按事件當時的模型計算累計計數差額，避免重複加總；reasoning output 已包含在 output，不額外相加。GPT-6 三個模型的每次輸入超過 272K 時，輸入與快取輸入為短上下文價的 2 倍、輸出為 1.5 倍。

標籤明示「API標準價」，不是訂閱實付金額；不含子代理、工具費、Fast／Ultrafast 與區域加價。未知模型、累計計數倒退、紀錄不完整、無法確定的快取寫入費，以及未收錄價格的長上下文會顯示成本未知。未知不視為免費。輪詢不發送模型請求。

## 移除與還原

- 點標籤旁的 ×，該 renderer 的標籤、全寬樣式與 observer 立即移除；watch 不會推翻關閉動作。重載頁面後才會重新安裝。
- 或對同一個已驗證端點執行：

```powershell
node scripts/codex-native-meter.cjs --port 19335 --browser-id <verified-browser-id> --remove
```

- 停止 watcher 並關閉測試實例可關閉 CDP 埠；原本正常啟動的 Codex 不受影響。沒有安裝檔 patch 可還原。
- CDP 能控制整個測試實例，僅限本機不代表沒有權限；不要將埠轉發或暴露到外部。

這是非官方、依賴 Desktop DOM 的原型。更新 Codex 後必須重新驗證，不保證跨版本相容；目前採手動雙擊啟動，沒有加入開機自動執行。

## 參考

- [Newskin Windows 啟動方式](https://github.com/pjf6568/codex-newskin/blob/main/windows/scripts/start-newskin.ps1)：參考本機 CDP 啟動流程，未執行第三方安裝器。
- [Explodex](https://github.com/dan-dr/explodex)：參考原介面元件注入方向；該專案未宣稱支援 Windows。
