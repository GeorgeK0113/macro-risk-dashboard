# -*- coding: utf-8 -*-
"""
把本機 dashboard.html 轉成可分享的網頁版 (shared_dashboard.html)。

差異只有四點，資料與判斷邏輯完全不動：
  1. 去掉 <!DOCTYPE>/<html>/<head>/<body> 外殼（發布平台會自己包）
  2. 補上 :root[data-theme=...] 覆寫，讓觀看者的深/淺色切換鈕真的有效
  3. 數字欄位加上等寬對齊 (tabular-nums)
  4. 把「請檢查排程/手動執行腳本」這類只有你能做的提示，改成給朋友看的說法

用法： python build_shared_page.py
"""
import re
import sys
import io
from pathlib import Path

BASE = Path(__file__).resolve().parent
SRC = BASE / "dashboard.html"
OUT = BASE / "shared_dashboard.html"

html = SRC.read_text(encoding="utf-8")

# --- 1. 抽出 <style>、<body> 內容與兩個 script 區塊 -------------------------
style = re.search(r"<style>(.*?)</style>", html, re.S)
body = re.search(r"<body>(.*?)</body>", html, re.S)
if not style or not body:
    sys.exit("找不到 <style> 或 <body>，dashboard.html 結構可能被改過")

style_css = style.group(1)
body_html = body.group(1)

# --- 2. 深/淺色主題 token 覆寫 --------------------------------------------
# 觀看者按主題切換鈕時，平台會在根元素蓋上 data-theme，必須比 media query 更強勢
dark_tokens = """
    --bg:#111417; --card:#1b1f24; --text:#e8e9ec; --sub:#9aa1ad; --border:#2b2f37;
    --green:#4caf6a; --green-bg:#123420;
    --yellow:#e0b33d; --yellow-bg:#3a2f10;
    --red:#e0605d; --red-bg:#3a1616;
    --accent:#e8873f;
    --grid-line: rgba(255,255,255,0.045);
    --blob-green: rgba(76,175,106,0.14);
    --blob-yellow: rgba(224,179,61,0.13);
    --blob-red: rgba(224,96,93,0.13);
    --grain-opacity: 0.08;
"""
light_tokens = """
    --bg:#eef1f0; --card:#fffdf8; --text:#1a1d23; --sub:#5b6270; --border:#e3e1d8;
    --green:#1e8e3e; --green-bg:#e6f4ea;
    --yellow:#a5690a; --yellow-bg:#fff3d6;
    --red:#c62828; --red-bg:#fdecea;
    --accent:#c25a1e;
    --grid-line: rgba(60,55,45,0.06);
    --blob-green: rgba(30,142,62,0.16);
    --blob-yellow: rgba(214,150,20,0.18);
    --blob-red: rgba(198,40,40,0.14);
    --grain-opacity: 0.05;
"""

style_css += f"""
  /* 觀看者手動切換主題時，必須蓋過 prefers-color-scheme */
  :root[data-theme="dark"]{{{dark_tokens}}}
  :root[data-theme="light"]{{{light_tokens}}}
  /* 數字欄位對齊 */
  td, .card .num{{ font-variant-numeric: tabular-nums; }}
  @media (prefers-reduced-motion: reduce){{
    body::before{{ animation: none; }}
    *{{ transition: none !important; }}
  }}
"""

# --- 3. 改寫只有本機擁有者能執行的提示文字 --------------------------------
body_html = body_html.replace(
    "本頁為本機審查用儀表板，資料不會上傳。每日排程掃描完成後將新增一筆記錄至下拉選單以便比對。",
    "本頁為某一次掃描結果的靜態快照，不會自動更新；資料來源皆為公開市場數據。"
    "本頁內容僅供參考，不構成投資建議。",
)

# staleness 提示：朋友看不到你的 log、也不能執行你的腳本
body_html = body_html.replace(
    '● 最新資料已經 ${diffDays} 天沒更新！排程可能失敗，請檢查 logs/run_history.log 或手動執行 run_daily_scan.ps1',
    '● 這份快照的資料為 ${diffDays} 天前，僅供參考',
)
body_html = body_html.replace(
    '● 最新資料為 ${diffDays} 天前（如遇連假屬正常，超過3天請檢查排程）',
    '● 這份快照的資料為 ${diffDays} 天前',
)

# --- 4. 組出發布用檔案（不含 doctype/html/head/body） ----------------------
out = f"<title>宏觀風險掃描儀表板</title>\n<style>{style_css}</style>\n{body_html}"

OUT.write_text(out, encoding="utf-8")

# --- 5. 基本自我檢查 -------------------------------------------------------
problems = []
for tag in ("<!DOCTYPE", "<html", "<head>", "<body>"):
    if tag.lower() in out.lower():
        problems.append(f"殘留外殼標籤 {tag}")
if out.count("<script") != out.count("</script>"):
    problems.append("script 標籤數量不成對")
if "history-data" not in out:
    problems.append("找不到 history-data 資料區塊")

print(f"已產生 {OUT.name} ({len(out):,} 字元)")
if problems:
    print("⚠️ 檢查發現問題：")
    for p in problems:
        print("   -", p)
    sys.exit(1)
print("自我檢查通過")
