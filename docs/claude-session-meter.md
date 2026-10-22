# Claude Desktop session 顯示元件

顯示位置是 Desktop Code 的模型選擇器左側，不修改 Claude 安裝檔。此功能使用現有 Developer Mode 注入流程，屬於非官方介面增強；Claude 更新內部介面或 DOM 時可能需要調整。

## 顯示內容

- `快取 1h≈52:17`：從紀錄中觀測到 1 小時 cache，依最後一次 cache 使用時間推估剩餘時間。5 分鐘／1 小時的混合紀錄會分別顯示；未回報 TTL 時顯示未知。
- `命中 97.1%`：此 session 主對話及已配對子代理的 cache read tokens／全部輸入 tokens。這是 session 累計命中率，不是 context window 的剩餘容量。
- `US$6.38 回報`：最近完成回合的 `total_cost_usd` 累計回報。多個回合的累計數字不再相加。若偵測到累計值下降，標示「本段」。
- `≈US$...`：沒有引擎費用回報時，依官方 API 單價推估可見紀錄成本。未知模型、TTL 分類或價格修正因素會顯示費用未提供，不填入零。

偵測到 Agent／Task 呼叫時，費用預設顯示主對話與已配對子代理的 API 成本估算合計。主對話的累計費用回報不會再與子代理估算相加，避免回報已含子代理時重複計價。快取倒數維持主對話的狀態。

點擊這一列，可查看主對話／子代理費用分項、輸入／輸出、cache read／write、5m／1h write token 數及來源說明。再次點擊收起。

倒數是推估，不是伺服器提供的到期保證。快取可能因 prefix 或設定改變而提前無法命中。元件不呼叫 warmSession、不發送訊息、不自動保持快取有效。費用回報是引擎會計數字，不等於 Pro／Max 等訂閱方案的實際扣款；進行中回合未必已包含在回報中。

## 啟用與移除

日常使用方式：

1. 開啟要使用的 Claude Desktop。兩個帳號／profile 可同時開著。
2. 雙擊專案根目錄的 `Start-Claude-Session-Meter.cmd`。它會呼叫既有的 `scripts\restart-usage-viewer.cmd`，啟動 viewer、bridge 與背景檢查。
3. 暫停操作鍵鼠，讓背景檢查依序將元件加入兩個視窗。安裝時會短暫開啟 DevTools，完成後自行收起。已有健康回報的視窗不重複操作。

每個 Desktop 必須已有 Developer Mode／DevTools 可用。背景檢查以實際 Claude 視窗為單位，與帳號 usage history 是否存在、用量是否過期分開。相同帳號的第二個視窗也會分別處理；之後才開啟的視窗會由同一個背景程序補上，不必啟動第二份 viewer。

每個視窗每 20 秒向本機 bridge 回報自己的 process/window 識別、元件版本與此次注入識別，不傳 session 內容。頁面重新載入後若 75 秒沒有回報，背景檢查會在鍵鼠閒置後重試。失敗會以有上限的延遲重試，不能保證每次 DevTools 操作都立即成功。

腳本模式的 `New-InjectionScript` 可獨立載入 meter，保留原有的帳號用量計時器。WPF EXE 將此 JS 嵌入資源，啟動 injector 前解出到同一個工作目錄；使用舊版下載的 EXE 不會自動取得目前原始碼的新功能，開發期間請用上述專案啟動檔。

立即載入時，在 Claude 已啟用的 DevTools Console 執行 `src/desktop-addon/claude-session-meter.js` 的完整內容。重複載入會先清除上一份元件的 observer、timer、事件監聽及標記，不累積第二份元件。

暫時移除本頁元件：

```js
window.__usageViewerSessionMeter?.dispose()
```

這只清除本元件建立的 UI 與訂閱，保留 Claude 的原有介面及既有用量 bridge。頁面重新載入後，下一次完整注入仍會依目前設定重新加入。

## 資料與適用範圍

只使用已觀測的 `/epitaxy/local_<UUID>` 路徑以及 `claude.web.LocalSessions.getSession`、`getTranscript`、`onOnEvent`。每次資料讀取都核對目前 session ID；切換 session 後，舊非同步回應不能覆寫新資料。紀錄只在本機程序中用來計算彙總，不將對話內容上傳到其他服務，也不新增對話內容檔；視窗與版本中繼資料另行回報給本機 bridge，子代理的計價欄位由同一個 bridge 唯讀提供。

目前支援 Desktop Code，包含該介面已能讀取 transcript 的 SSH session。一般 Chat、Cowork，以及存在多個模型選擇器的分割畫面不顯示。若應用程式標記 transcript 不完整，明細會提示統計可能只涵蓋部分紀錄。子代理紀錄透過本機 bridge 的 `/claude-subagent-usage?session=<engine UUID>` 讀取：只在 `.claude/projects` 找相符主對話，並以 Agent／Task 的工具呼叫 ID、`.meta.json` 的 `toolUseId`、子紀錄的 session／agent ID 交叉核對。支援同目錄及 `<session>/subagents` 位置，沿已配對呼叫納入下一層子代理，檔名或時間接近不足以配對。bridge 只回傳計價所需的 token、模型與請求識別欄位，不回傳對話內容或路徑，也不另存 transcript。來源缺失、無法唯一配對、格式損壞或 bridge 失效時顯示「部分」，不能把缺失當作零；不支援的模型／計價因素仍顯示費用未提供。

每秒更新倒數，每 15 秒重新讀取統計；收到既有 session 事件時以一秒節流更新。不同串流區塊的同一個 assistant message 會去重。Claude 的 `<synthetic>` 系統訊息若明確回報所有 token 與工具使用量為零，會排除於請求計數與計價之外，避免用量上限錯誤訊息使整個 session 的費用變成未知；缺少用量欄位或非零用量仍保留未知判定。

## 測試與價格來源

```powershell
node --test tests/claude-session-meter.test.js
.\scripts\test-usage-viewer.ps1
```

測試涵蓋串流去重、累計費用、費用段重置、cache read 延長推估、混合 TTL、未知 TTL／模型／計價因素、跨 session 非同步回應，以及重複安裝的資源清理。完整檢查另外驗證注入 payload 內含此元件，並編譯 WPF 資源。

Fallback 價格表記錄日期為 2026-10-21，單位 USD／百萬 tokens；實際回報優先於這份價格表。新增模型應依 [Claude 官方價格](https://platform.claude.com/docs/en/about-claude/pricing) 更新並加入測試。[官方 prompt caching 說明](https://platform.claude.com/docs/en/build-with-claude/prompt-caching) 說明 TTL、cache read 更新期限與用量欄位。
