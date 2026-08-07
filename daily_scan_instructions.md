# 每日宏觀風險掃描 — 無人值守執行規格

你正在無人值守（Windows工作排程器每日自動觸發）模式下執行，沒有使用者可即時回答問題。遇到不確定的情況，依本文件規則自行判斷並在報告中如實標註，不要停下來等待輸入。

## ⛔ 第零條規則：一律重新抓取，禁止跳過

**每一次執行，都必須實際重新搜尋全部17項指標並重新寫入三個檔案，沒有任何例外。**

明文禁止以下所有行為（這些都算執行失敗，不算「聰明地省下請求」）：

- 看到 `data/今天日期.json` 已經存在，就判斷「今天已經掃描過了」而跳過
- 看到檔案的修改時間很新（例如幾分鐘前），就判斷「資料還很新鮮、不需要重抓」而跳過
- 判斷「這些指標多為月度／週度資料，同一天內不會變」而決定不重抓
- 只讀取並「驗證」現有檔案內容正確，就回報任務完成
- 以「節省 API 請求」「避免浪費」為由減少搜尋次數

**理由**：使用者要的是「每次執行都拿到當下最新的真實讀數」。同一天內 VIX、Fear & Greed、Put/Call Ratio 這類短期指標本來就會盤中變動；更重要的是，若你跳過不抓卻回報「已完成」，使用者會誤以為看到的是最新資料，實際上是舊資料——這種靜默失敗比直接報錯還危險，是本專案最不能接受的失效模式。

**若當天檔案已存在**：直接覆蓋它們，不要新增第二筆、也不要跳過。

**完成後自我檢查**：確認你這次執行確實有呼叫 WebSearch 抓資料，且三個檔案都被實際寫入（而不是原封不動）。若因故完全沒有寫入任何檔案，必須在輸出中明確講「本次未寫入任何檔案」及原因，不可回報成功。

## 任務

比照以下17項指標，抓取「今天」的最新讀數，並將結果寫入三個地方：

1. `data/YYYY-MM-DD.json`（今天日期）— 結構化資料，schema 必須完全比照 `data/2026-08-07.json` 現有格式（short_term / mid_term / long_term / triggers / top_signal / data_conflicts）。每個指標物件用 `unit`（數值單位，沒有就空字串）＋可選的 `detail`（單一字串，放次要補充資訊，例如「月增7.9% · 年增51.5%」），不要自創其他額外欄位名稱。
   - **每個指標物件必須包含 `riskDir`**：`"up"` 代表數字越大風險越高（例如VIX、Margin Debt、CAPE），`"down"` 代表數字越小風險越高（例如殖利率曲線、LEI、Insider Buy/Sell Ratio、A/D Line淨家數）。判斷方式：對照該指標自己的 `threshold` 文字描述的方向，不要憑感覺猜——這個欄位決定前端箭頭顯示紅色還是綠色，錯了會直接誤導使用者判斷方向。
   - **每個 trigger 物件必須包含 `horizon`**：`vix_above_25`、`fear_greed_drop` 是 `"short"`，其餘5項（margin_debt_3mo_decline / hy_spread_above_450 / ad_line_divergence / bofa_bull_bear_above_8 / insider_below_017）是 `"mid"`，這個分類固定不變，不需要每次重新判斷。
2. `reports/YYYY-MM-DD.md` — 完整六部分文字報告（格式比照 `reports/2026-08-07.md`）
3. `dashboard.html` — **不要整份重寫**，只修改 `<script type="application/json" id="history-data">` 這個標籤裡的 JSON 陣列內容：
   - 讀取這個標籤目前的完整 JSON 陣列
   - 檢查陣列最後一筆的 `scan_date` 是否等於今天：**若相同就直接覆蓋（取代）那一筆，不要新增第二筆**；若不同才在陣列尾端新增今天這一筆
   - 新物件的結構、欄位名稱必須跟第1點的 `data/*.json` schema完全一致
   - **寫入前務必逐一檢查每個字串欄位**：只要內容中出現「`</`」這兩個字元連在一起（最常見於複製貼上的新聞標題、網頁片段），一律改成「`<\/`」再寫入，否則會提前結束 `</script>` 標籤，讓整頁變成空白
   - 其餘 HTML/CSS/JS（包括下面那個真正在執行的 `<script>` 邏輯區塊）一律不要動

## 17項指標清單

### 短期（天－週）
1. VIX — cboe.com / fred.stlouisfed.org/series/VIXCLS
2. CNN Fear & Greed Index — cnn.com/markets/fear-and-greed
3. AAII Investor Sentiment Survey（Bullish % / Bearish % / 多空差）— aaii.com/sentimentsurvey
4. CBOE Equity Put/Call Ratio — cboe.com/markets/us/options/market-statistics/daily/
5. NAAIM Exposure Index — naaim.org/programs/naaim-exposure-index（注意：2026-08起為訂閱制，免費資料可能滯後，滯後就照實標註，不要編數字）

### 中期（週－月）
6. FINRA Margin Debt（最新月度值＋年增率＋月增方向）
7. Margin Debt / GDP 比率（gurufocus.com）
8. Renaissance IPO 發行量（當季數量＋募資總額）— renaissancecapital.com/IPO-Center/Stats
9. Insider Buy/Sell Ratio（GuruFocus USA Overall Market）
10. BofA Bull & Bear Indicator（最新讀數，搜尋 "BofA Bull Bear Indicator" + 當前月份）
11. ICE BofA US High Yield OAS Spread — fred.stlouisfed.org/series/BAMLH0A0HYM2
12. NYSE Advance/Decline Line（是否與S&P 500頂背離）

### 長期（月－年）
13. Buffett Indicator（currentmarketvaluation.com / gurufocus.com）
14. Shiller CAPE / PE10 — multpl.com/shiller-pe
15. 10Y-2Y Treasury Yield Curve — fred.stlouisfed.org/series/T10Y2Y
16. Conference Board US LEI（最新月度值＋6個月變化率）
17. AAII 家庭股票配置比 — aaii.com/assetallocationsurvey

## 紅線規則（不可違反）

1. **不編數字**。搜尋不到當日資料就明確標「數據滯後至[日期]」或「未找到」，絕不用訓練資料或猜測值填充，也不要因為找到兩筆矛盾數字就自己選一個看起來合理的——兩筆都列出來，寫進 `data_conflicts`。
2. 短期指標必須是 T-1 以內的資料；長期指標（Buffett/CAPE/LEI）允許週度或月度。
3. 警戒閾值固定不變，禁止因市場情緒動態調整判斷標準。
4. 觸發狀態嚴格按閾值判斷（見下方7項硬閾值），不加「但是」「不過」等軟化語言。
5. **對比前一天**：讀取 `dashboard.html` 裡 `<script type="application/json" id="history-data">` 標籤內 JSON 陣列的最後一筆（即前一次掃描），計算每項指標的方向作為 `signal` 與數值比較基礎（前端 JS 會自動算箭頭，你只需確保新物件的 `value` 欄位可以跟前一筆比較，格式一致、單位一致）。
6. 每項指標的 `signal` 欄位固定用 `"green"` / `"yellow"` / `"red"` 三選一（對應🟢🟡🔴），判斷標準比照下方硬閾值與 `data/2026-08-07.json` 中既有的分級邏輯。

## 7項賣出硬閾值（triggers 物件固定用這7個 key）

| key | 條件 |
|---|---|
| vix_above_25 | VIX > 25 且站穩 |
| margin_debt_3mo_decline | Margin Debt 連續3個月月減 |
| hy_spread_above_450 | HY Spread > 4.5%（450bps） |
| fear_greed_drop | Fear & Greed 從 >75 跌回 <50 |
| ad_line_divergence | S&P 新高但 A/D Line 不創新高 |
| bofa_bull_bear_above_8 | BofA Bull & Bear > 8.0 |
| insider_below_017 | Insider Buy/Sell < 0.17 |

`hit` 欄位用 `"yes"` / `"no"` / `"warn"` 三選一。若同時觸發 ≥3項 `"yes"`，`data_conflicts` 之外另外在 `top_signal` 開頭加註「🚨 警戒升級」字樣。

## 完成後

不需要通知任何人、不需要開瀏覽器、不需要 git commit。純粹把三個檔案寫好即結束。若任一資料源完全抓不到（例如網站改版、被擋爬蟲），照實在對應欄位寫「未找到」，並在 `data_conflicts` 列出，不要讓整個流程中斷——其餘16項照常完成。
