# Claude 使用量更新流程

更新由 `scripts/claude-desktop-usage-injector.ps1` 管理。它利用 Claude 已登入的工作階段取得使用量，不讀取或複製登入 cookie。

## 帳號與視窗

1. 讀取預設 Claude、MSIX Claude，以及 `claude-custom-source.json` 中的使用量歷史檔。
2. 從各檔案最新的 sample 取得 organization ID，保留其 profile 對應關係。
3. 讀取 Claude 主程序的 `--user-data-dir`，以完整 profile 路徑配對。Self 的 organization 只送給 Self 的視窗，排除 renderer 子程序。
4. 若自訂 profile 只剩背景程序，重新啟動同一個 `Claude.exe --user-data-dir="..."`，讓 Electron 恢復既有工作階段的視窗。這不會終止 Claude。

## 一次視窗操作

1. 使用 Win32 `EnumWindows` 找到 Claude 視窗，以 `GetWindowThreadProcessId` 確認所屬程序。一般模式等到使用者至少 2.5 秒沒有鍵盤或滑鼠輸入再開始。
2. 先確認 `http://127.0.0.1:8765/health` 正常，再啟動獨立的 PowerShell worker。主管程序保存已有的 DevTools handle，供逾時清理時辨識。
3. worker 使用 `ShowWindow(..., 9)` 還原 Claude 視窗，再用 `BringWindowToTop`、`SetForegroundWindow` 等 Win32 呼叫切換焦點。
4. 送出 `Ctrl+Alt+I` 開啟 DevTools，最多等 5 秒。以視窗標題及同一個 Claude process ID 辨認獨立的 DevTools 視窗。如果使用者原本已開啟 DevTools，這次操作會延後，不改動使用者的 console。
5. 聚焦 DevTools，送出 `Ctrl+Shift+P`，貼上 `Show Console` 後按 Enter，再送出 `Ctrl+\`` 開啟 console drawer。
6. 將完整 JavaScript 放入剪貼簿，送出 `Ctrl+V` 一次貼上，確認焦點仍在該 DevTools 後按 Enter 執行。Console 指令也直接貼上，不逐字輸入。已有 Developer Mode 與允許貼上的 Claude console 可直接執行；若 DevTools 的貼上保護擋住脚本，操作不會收到確認資料，因此不會誤判成功。
7. 如果原本剪貼簿含文字，結束時會恢復該文字；若使用者中途複製了新內容則保留新內容。不讀取或還原圖片等其他格式，worker 被強制終止時也可能來不及恢復文字。剪貼簿操作同樣受 worker 的 45 秒總逾時限制。worker 在 `finally` 中以 `WM_CLOSE` 關閉自己開啟的 DevTools。Claude 主視窗不會被關閉。操作結束與逾時清理均不主動恢復原本的前景視窗。既有 DevTools 不會被關閉；診斷環境變數 `CLAUDE_DESKTOP_AUTO_BRIDGE_KEEP_DEVTOOLS=1` 可保留本次 DevTools。
8. worker 最多執行 45 秒，逾時由主管程序終止 worker 並補做 DevTools 清理。若 worker 成功送出指令，主管再等最多 15 秒，必須讀到該 organization 在此次操作開始之後的新、有效 `observed_at`，並配對此次產生的 `refresh_id`，才判定更新成功。舊計時器送來的資料不能冒充這次腳本的確認回覆。

視窗是否就緒仍依賴 Claude/Electron 的快捷鍵與 DevTools 介面。不能保證每一次 UI 操作都成功，所以提交字串與取得資料是兩個不同階段。

## JavaScript 執行後

腳本在 Claude 頁面內立即呼叫 `/api/organizations/{id}/usage`，使用該頁面的登入工作階段。取得 JSON 後，POST 到本機 bridge；bridge 只儲存 organization、使用百分比及重置時間。

腳本在頁面內每 60 秒重做一次。關閉 DevTools 後，頁面的計時器仍會繼續；重新載入頁面、關閉 Claude 或切換工作階段可能使計時器消失。新的腳本會清除相同頁面的舊計時器，避免累積。

每輪請求共用 10 秒的 AbortController 逾時，同一腳本不允許重疊請求。HTTP 404、登入失效或本機 bridge 錯誤會記錄於 DevTools console，並在下一輪重試；404 不會永久移除 organization。

## 恢復與成功判定

主管以 JSON 內的 `observed_at` 判斷新鮮度，不使用檔案修改時間。缺檔、損壞 JSON、錯誤 organization、空百分比、超出 0–100 的百分比、超前超過 30 秒的時間都不視為有效資料。超過 150 秒沒有有效觀測便啟動恢復。

重試狀態依 profile 和 organization 分開，失敗後等待 30、60、180、600 秒，之後維持每 600 秒重試。成功後歸零。一個帳號的失敗不會讓另一個帳號進入相同的冷卻時間。bridge 不健康時不操作視窗，由既有 bridge watchdog 負責恢復。

程序紀錄位於 `%USERPROFILE%\.usage-viewer\claude-desktop-usage-injector.log`，可區分視窗找不到、console 開啟失敗、輸入被中斷、worker 逾時、沒有新的有效 API 資料，以及下一次重試時間。顯示端既有的 5 分鐘資料期限維持不變；過期資料不能拿來宣稱已取得新使用量。

## 驗證

執行 `powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\test-claude-usage.ps1`。

測試不會操作視窗，涵蓋 snapshot 驗證、profile 精確配對、重試上限、Win32 helper 編譯，以及 mock fetch 的空值拒絕、404 後恢復、逾時後恢復及請求重疊防護。實際桌面流程仍須透過新 API observation 與程序紀錄驗證。
