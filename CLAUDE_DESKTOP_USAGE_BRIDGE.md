# Claude Desktop 精確用量與重置時間 Bridge

本文件說明如何讓 Usage Viewer 取得 Claude Desktop 顯示的精確 5 小時與 7 天使用率／重置時間。

Usage Viewer 只會把 Claude Desktop API 的使用率與重置時間保存於本機；不會讀取、傳送或記錄 Cookie、Authorization header 或完整 API 回應。

## 適用條件

- 已啟動最新版 Usage Viewer。它會在本機開啟 `http://127.0.0.1:8765` 的 bridge。
- 已登入 Claude Desktop。
- 可在 Claude Desktop 看到 usage 資訊。
- Claude Desktop 已啟用 Developer Mode。

## 重要安全說明

Usage Viewer 預設會在 bridge 資料過期時自動把以下等效 JavaScript 鍵入 Claude Desktop 自己的 Developer Tools Console。手動執行時，**不要**在 Windows CMD、PowerShell 或不受信任的網站執行。

程式會使用 Claude Desktop 既有登入狀態呼叫 Claude API，並把結果送到同一台電腦的 `127.0.0.1:8765`。程式不會傳送 Cookie 或憑證到外網。

## 啟用 Claude Desktop Developer Tools

1. 開啟 Claude Desktop。
2. 選擇 `Help` → `Troubleshooting` → `Enable Developer Mode`。
3. 確認啟用。
4. 自動同步不需要手動開啟 Developer Tools。要除錯時可按 `Ctrl + Alt + I` 開啟。
5. 切到 `Console` 分頁。

如果 Console 顯示「Don't paste code into the DevTools Console」警告，請在 Console 輸入列中**手動逐字鍵入** `allow pasting`，按 Enter 後才能貼上程式碼。

## 自動同步

先手動執行一次 `scripts\configure-claude-desktop-auto-bridge.ps1`。它會在確認 Claude Developer Mode 已啟用後，將使用者層 `CLAUDE_DEV_TOOLS` 設定為 `undocked` 並通知 Windows 環境已變更。目前已在執行的 Claude 不會被強制關閉；設定會從下一次 Claude 啟動生效。之後 Usage Viewer 啟動的背景 injector 會監看 Claude 視窗與 bridge 快照；快照過期時，它會：

1. 從 Claude 的 `plan-usage-history.json` 取得 organization ID。
2. 等待鍵鼠至少閒置 2.5 秒。
3. 使用 Claude 啟動時自動開啟的 Console，以 Unicode 鍵盤事件輸入同步程式；不使用或讀取剪貼簿。
4. 立即呼叫一次 usage API，之後每 60 秒更新。
5. 關閉 DevTools 並恢復先前的前景視窗。

若注入失敗，會使用漸進退避重試，最多連續四次，避免反覆打斷操作。診斷記錄位於 `%USERPROFILE%\.usage-viewer\claude-desktop-usage-injector.log`。設定環境變數 `CLAUDE_DESKTOP_AUTO_BRIDGE=0` 可停用 injector；執行 `scripts\configure-claude-desktop-auto-bridge.ps1 -Disable` 可還原由設定腳本建立的 `CLAUDE_DEV_TOOLS`。

正式版 Claude 會驗證 Anthropic 簽章並拒絕一般 `--remote-debugging-port`／`--remote-debugging-pipe`，所以自動同步不會嘗試繞過該保護，也不會讀程序記憶體或登入憑證。

## 手動找到 organization ID

1. 在 Developer Tools 開啟 `Network`。
2. 點 Claude Desktop 的 usage ring，或等待應用程式重新整理用量。
3. 找到類似以下的 request：

   ```text
   https://claude.ai/api/organizations/<org-id>/usage
   ```

4. URL 中 `<org-id>` 就是這個帳號要使用的 organization ID。

不要分享或保存 request 的 Cookie、Authorization header 或「Copy as cURL」內容。

## 手動啟動單一帳號同步

請在該帳號的 Claude Desktop Developer Tools Console 貼上以下程式，將 `<org-id>` 改為該帳號自己的 ID：

```js
clearInterval(window.usageBridgeTimer)

window.forwardClaudeDesktopUsage = async () => {
  const orgId = '<org-id>'
  const response = await fetch(`/api/organizations/${orgId}/usage`)

  if (!response.ok) {
    console.warn('Desktop API:', response.status)
    return
  }

  const usage = await response.json()
  const bridge = await fetch(
    `http://127.0.0.1:8765/claude-desktop-usage?org=${orgId}`,
    {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(usage)
    }
  )

  console.log('Usage Viewer bridge:', bridge.status)
}

window.forwardClaudeDesktopUsage().catch(console.error)
window.usageBridgeTimer = setInterval(
  () => window.forwardClaudeDesktopUsage().catch(console.error),
  60_000
)
```

成功時 Console 會顯示：

```text
Usage Viewer bridge: 204
```

## 有多個帳號時

每個 Claude Desktop 登入 session 只能存取它自己的 organization。因此必須：

1. 切換到帳號 A 的 Claude Desktop 視窗，在它的 DevTools Console 執行一次上方程式，填入帳號 A 的 organization ID。
2. 切換到帳號 B 的 Claude Desktop 視窗，在它的 DevTools Console 再執行一次相同程式，填入帳號 B 的 organization ID。

不要在同一個 Console 同時查兩個 organization ID；另一個帳號通常會回傳 `404`。Usage Viewer 會依 organization ID 分開保存快照，兩個帳號的資料不會互相覆寫。

## 驗證結果

Usage Viewer 顯示的 Claude 行應更新為 API 回傳的使用率與重置時間。例如：

```text
Claude  7d 63%  |  5h 26%  (D+C)
Claude  Fri 07:00 | 14:20  (D+C)
```

若 API 的 `five_hour.resets_at` 為 `null`，代表伺服器目前沒有提供該帳號的 5 小時重置時間；Usage Viewer 會保留空白，而不是猜測不可靠的時間。

Bridge 快照在五分鐘內未收到更新時會失效，Usage Viewer 會回退到本機歷史用量的推估值。自動 injector 會偵測這個狀態並重新注入；停用自動注入時才需要手動重新執行同步程式。

## 停止同步

在對應帳號的 Developer Tools Console 執行：

```js
clearInterval(window.usageBridgeTimer)
```

## 常見問題

### `Desktop API: 404`

目前 Claude Desktop session 沒有該 organization 的存取權。切換到正確帳號／Desktop profile，再使用該帳號的 organization ID。

### `Usage Viewer bridge: 400`

通常是前一步 API request 已回傳 `404` 或其他錯誤，卻仍把錯誤內容送進 bridge。使用本文件的單帳號程式，它會在 API 非成功回應時停止，不會送出錯誤內容。

### 看起來沒有更新

確認 Usage Viewer 正在執行，並檢查 `claude-desktop-usage-injector.log` 是否出現 `bridge snapshot refreshed successfully`。若顯示找不到 DevTools 視窗，請確認 Developer Mode 已啟用且 DevTools 使用 undocked 模式。
