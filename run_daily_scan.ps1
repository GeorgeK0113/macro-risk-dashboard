$ErrorActionPreference = "Continue"
$dir = "C:\Users\George\Desktop\CLAUDE other\宏觀風險掃描"
Set-Location $dir

$claude = (Get-Command claude -ErrorAction SilentlyContinue).Source
if (-not $claude) {
    $claude = "$env:APPDATA\npm\claude.cmd"
}

$startTime = Get-Date
$stamp = Get-Date -Format "yyyy-MM-dd_HHmm"
$logFile = Join-Path $dir "logs\$stamp.log"

$prompt = "請讀取並嚴格依照 daily_scan_instructions.md 的規格，執行今天（實際系統日期）的宏觀風險掃描，把結果寫入 data/、reports/ 與 dashboard.html。注意該檔案第零條規則：一律重新抓取全部17項指標，禁止因為當天檔案已存在或資料看起來很新就跳過。"

# 用陣列組參數，避免反引號續行在不同編碼/換行下失效
$claudeArgs = @(
    "-p", $prompt,
    "--allowedTools", "WebSearch WebFetch Read Write Edit Glob Grep",
    "--output-format", "text",
    "--no-session-persistence"
)

& $claude @claudeArgs *> $logFile

$exitCode = $LASTEXITCODE

# 驗證掃描是否真的有寫入檔案：只認「執行開始之後才被修改」的檔案，
# 避免 agent 判斷「今天已掃描過」而跳過、卻回報成功的靜默失敗。
$today = Get-Date -Format "yyyy-MM-dd"
$targets = @(
    (Join-Path $dir "data\$today.json"),
    (Join-Path $dir "reports\$today.md"),
    (Join-Path $dir "dashboard.html")
)
$stale = @()
foreach ($f in $targets) {
    if (-not (Test-Path $f)) {
        $stale += "MISSING:$(Split-Path $f -Leaf)"
        continue
    }
    if ((Get-Item $f).LastWriteTime -lt $startTime) {
        $stale += "NOT_UPDATED:$(Split-Path $f -Leaf)"
    }
}

if ($stale.Count -eq 0) {
    $status = "OK"
} else {
    $status = "FAILED(" + ($stale -join ",") + ")"
}

$line = "$stamp  exit=$exitCode  status=$status  log=$logFile"
Add-Content -Path (Join-Path $dir "logs\run_history.log") -Encoding utf8 -Value $line
