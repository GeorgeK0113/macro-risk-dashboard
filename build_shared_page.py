# -*- coding: utf-8 -*-
"""
從本機 dashboard.html 產生兩個對外版本：

  1. shared_dashboard.html          → 給 Claude Artifact 用（平台會自己包外殼，所以要去掉 doctype/html/head/body）
  2. .worktree-gh-pages/index.html  → 給 GitHub Pages 用（必須是完整可獨立開啟的網頁）

兩者的資料與判斷邏輯完全相同，只差在外殼與少數對外文案。

用法： python build_shared_page.py
"""
import re
import sys
from pathlib import Path

BASE = Path(__file__).resolve().parent
SRC = BASE / "dashboard.html"
OUT_ARTIFACT = BASE / "shared_dashboard.html"
OUT_PAGES = BASE / ".worktree-gh-pages" / "index.html"

html = SRC.read_text(encoding="utf-8")

style_m = re.search(r"<style>(.*?)</style>", html, re.S)
body_m = re.search(r"<body>(.*?)</body>", html, re.S)
if not style_m or not body_m:
    sys.exit("找不到 <style> 或 <body>，dashboard.html 結構可能被改過")

style_css = style_m.group(1)
body_html = body_m.group(1)

# ---------------------------------------------------------------------------
# 1. 對外共用的樣式補強
# ---------------------------------------------------------------------------
DARK_TOKENS = """
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
LIGHT_TOKENS = """
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
  /* 手動切換主題時必須蓋過 prefers-color-scheme */
  :root[data-theme="dark"]{{{DARK_TOKENS}}}
  :root[data-theme="light"]{{{LIGHT_TOKENS}}}
  td, .card .num{{ font-variant-numeric: tabular-nums; }}
  .theme-toggle{{
    background:var(--card); color:var(--text); border:1px solid var(--border);
    border-radius:8px; padding:6px 10px; font-size:0.9rem; cursor:pointer; line-height:1;
    transition:border-color .15s ease;
  }}
  .theme-toggle:hover{{ border-color:var(--accent); }}
  .theme-toggle:focus-visible{{ outline:2px solid var(--accent); outline-offset:2px; }}
  @media (prefers-reduced-motion: reduce){{
    body::before{{ animation:none; }}
    *{{ transition:none !important; }}
  }}
"""

# ---------------------------------------------------------------------------
# 2. 對外文案：拿掉只有本機擁有者才做得到的指示
# ---------------------------------------------------------------------------
body_html = body_html.replace(
    "本頁為本機審查用儀表板，資料不會上傳。每日排程掃描完成後將新增一筆記錄至下拉選單以便比對。",
    "本頁每個交易日自動更新（台北時間約 09:25）。資料來源皆為公開市場數據，"
    "內容僅供參考，不構成投資建議。",
)
body_html = body_html.replace(
    '● 最新資料已經 ${diffDays} 天沒更新！排程可能失敗，請檢查 logs/run_history.log 或手動執行 run_daily_scan.ps1',
    '● 最新資料為 ${diffDays} 天前（可能遇到假日或更新中斷）',
)
body_html = body_html.replace(
    '● 最新資料為 ${diffDays} 天前（如遇連假屬正常，超過3天請檢查排程）',
    '● 最新資料為 ${diffDays} 天前（如遇連假屬正常）',
)

# ---------------------------------------------------------------------------
# 3. Artifact 版：不含外殼
# ---------------------------------------------------------------------------
artifact_out = (
    "<title>宏觀風險掃描儀表板</title>\n"
    f"<style>{style_css}</style>\n"
    f"{body_html}"
)
OUT_ARTIFACT.write_text(artifact_out, encoding="utf-8")

# ---------------------------------------------------------------------------
# 4. GitHub Pages 版：完整獨立網頁 + 主題切換鈕
# ---------------------------------------------------------------------------
# GitHub Pages 沒有平台級的主題切換，必須自己給一顆按鈕，data-theme 的樣式才有意義
pages_body = body_html.replace(
    '<span class="meta" id="staleNote"></span>',
    '<span class="meta" id="staleNote"></span>\n'
    '      <button type="button" class="theme-toggle" id="themeToggle" '
    'title="切換深色／淺色" aria-label="切換深色／淺色">🌓</button>',
)

theme_script = """
<script>
(function(){
  var root = document.documentElement;
  var btn = document.getElementById("themeToggle");
  function current(){
    return root.getAttribute("data-theme") ||
      (window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light");
  }
  function apply(mode){
    root.setAttribute("data-theme", mode);
    btn.textContent = mode === "dark" ? "☀️" : "🌙";
    try { localStorage.setItem("macroRiskTheme", mode); } catch (e) {}
  }
  try {
    var saved = localStorage.getItem("macroRiskTheme");
    if (saved) { apply(saved); } else { btn.textContent = current() === "dark" ? "☀️" : "🌙"; }
  } catch (e) { btn.textContent = "🌙"; }
  btn.addEventListener("click", function(){
    apply(current() === "dark" ? "light" : "dark");
  });
})();
</script>
"""

pages_out = f"""<!DOCTYPE html>
<html lang="zh-Hant">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>宏觀風險掃描儀表板</title>
<meta name="description" content="17項美股宏觀風險指標每日掃描，含短中長期白話解讀與賣出觸發追蹤。僅供參考，不構成投資建議。">
<meta property="og:title" content="宏觀風險掃描儀表板">
<meta property="og:description" content="17項美股宏觀風險指標每日掃描，含短中長期白話解讀與賣出觸發追蹤。">
<meta property="og:type" content="website">
<style>{style_css}</style>
</head>
<body>
{pages_body}
{theme_script}
</body>
</html>
"""

if OUT_PAGES.parent.exists():
    OUT_PAGES.write_text(pages_out, encoding="utf-8")
    pages_status = f"已寫入 {OUT_PAGES.relative_to(BASE)} ({len(pages_out):,} 字元)"
else:
    pages_status = "略過 GitHub Pages 版（.worktree-gh-pages 尚未建立）"

# ---------------------------------------------------------------------------
# 5. 自我檢查
# ---------------------------------------------------------------------------
problems = []

for tag in ("<!doctype", "<html", "<head>", "<body>"):
    if tag in artifact_out.lower():
        problems.append(f"Artifact 版殘留外殼標籤 {tag}")

if artifact_out.count("<script") != artifact_out.count("</script>"):
    problems.append("Artifact 版 script 標籤不成對")
if pages_out.count("<script") != pages_out.count("</script>"):
    problems.append("Pages 版 script 標籤不成對")

for name, blob in (("Artifact", artifact_out), ("Pages", pages_out)):
    if "history-data" not in blob:
        problems.append(f"{name} 版找不到 history-data 資料區塊")
    m = re.search(r'<script type="application/json" id="history-data">(.*?)</script>', blob, re.S)
    if m:
        import json
        try:
            json.loads(m.group(1))
        except Exception as e:
            problems.append(f"{name} 版 JSON 無法解析：{e}")

if 'id="themeToggle"' not in pages_out:
    problems.append("Pages 版缺少主題切換鈕")

print(f"已寫入 {OUT_ARTIFACT.name} ({len(artifact_out):,} 字元)")
print(pages_status)
if problems:
    print("⚠️ 檢查發現問題：")
    for p in problems:
        print("   -", p)
    sys.exit(1)
print("自我檢查通過")
