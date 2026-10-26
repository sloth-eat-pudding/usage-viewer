# 指定資料夾的 Codex 帳號登入畫面實驗

2026-10-26 在 Windows Store `OpenAI.Codex` 26.1013.4894.0 實測：用全新資料夾啟動後，Desktop 顯示「歡迎回來／選擇帳戶以繼續使用 ChatGPT」，並提供「使用其他帳戶」及「用其他方式登入」。未自動進入原帳號的聊天。依本次使用者指定的標準，到達登入畫面即為測試成功；沒有點選帳號或繼續登入。

## 啟動

在 Usage Viewer 的 Settings 按 **Create / open Codex profile…**，指定完整資料夾路徑，再按「建立／開啟」。新帳號選新資料夾；重開同一個視窗則選原資料夾。程式會記住上次路徑，並自動選擇可用的本機埠。同一個 profile 會沿用已記錄的埠。

此入口已同時加入 EXE 與腳本版 Settings；EXE 內嵌啟動腳本，不需要另外下載專案。此入口是 Usage Viewer 的設定功能，實際開啟的是官方 Codex Desktop。

也可以在專案根目錄執行：

```powershell
.\Start-Codex-Account-Profile.cmd -ProfileRoot "D:\CodexProfiles\account-a" -Port 19336
```

第二個設定使用另一個資料夾與埠，例如 `account-b`、`19337`。同一組資料夾需使用固定的埠；重複執行會重用該 profile，啟動器不會關閉其他 Codex 程序。參數中的路徑可以包含空白。

指定目錄內建立：

| 目錄 | 用途 |
| --- | --- |
| `desktop` | 透過 `--user-data-dir` 與 `CODEX_ELECTRON_USER_DATA_PATH` 指定 Desktop 資料 |
| `codex` | 僅對新程序設定 `CODEX_HOME`，新設定明確使用 `cli_auth_credentials_store = "file"` |
| `usage` | 預留此 profile 的獨立 Usage Viewer 資料目錄 |
| `runtime` | 本次 CDP 埠、browser ID、程序身份等執行狀態 |

本次測試資料放在 worktree 的 `.tools/account-profile-login-a`；所有生成資料與截圖均不提交。

啟動器直接啟動已驗證來源的官方 Store 執行檔，藉此讓環境變數只作用於新程序；不修改使用者或系統的環境設定，不複製現有 `auth.json`，不登出原帳號。子程序移除已知的 API/access-token 環境覆寫，避免把目前 shell 的憑證帶入新 profile。已有的 profile 設定不會被覆寫；若它未明確使用 file 憑證儲存模式，啟動器會停止並說明。

## 已驗證與限制

- 新 profile 顯示登入／帳戶選擇畫面，無可見聊天輸入框。
- 原本的 Codex 視窗繼續執行，未呼叫 logout，也未改動原登入設定。
- 除錯埠只監聽 `127.0.0.1`，並核對官方執行檔及指定 Desktop profile 的程序身份；不會接管其他程式的埠。
- 登入畫面仍可能顯示系統記住的既有帳號。這不代表已自動登入，也表示目前不能宣稱所有系統層級的帳號發現／憑證資料都完全隔離。
- 本次雖未操作登入，Desktop 仍自行在新 `codex/auth.json` 寫入 token 欄位；驗證只記錄欄位存在與否，未輸出憑證。這表示 `CODEX_HOME` 加 file 儲存設定仍不足以證明 Desktop 的憑證來源完全隔離。畫面成功不能當成完整登入隔離已成功。
- 尚未完成兩個不同帳號登入後的同時使用、登出影響、更新後行為等驗證；本實驗不把登入畫面測試擴大宣稱為完整多帳號支援。
- 本入口僅驗證帳號啟動，不啟動共用 reader 或注入原生用量標籤，避免在未登入的新視窗顯示另一帳號的快照。登入後的每帳號 reader 與標籤整合尚未實作。

關閉此實例時請完整結束該 Codex 實例，確認對應除錯埠停止監聽；不要終止其他已登入的 Codex 程序。

依據：[官方登入／憑證儲存文件](https://learn.chatgpt.com/docs/auth)、[CODEX_HOME 環境變數](https://learn.chatgpt.com/docs/config-file/environment-variables)。
