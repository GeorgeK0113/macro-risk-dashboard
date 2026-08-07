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

# 只有掃描確實更新了檔案，才發布到 GitHub Pages；
# 否則會把舊資料重推一次，讓線上頁面看起來「有更新」而其實沒有。
$publish = "SKIPPED"
if ($status -eq "OK") {
    try {
        $py = "C:\Users\George\AppData\Local\Programs\Python\Python311\python.exe"
        if (-not (Test-Path $py)) { $py = "python" }
        & $py (Join-Path $dir "build_shared_page.py") *>> $logFile
        if ($LASTEXITCODE -ne 0) { throw "build_shared_page.py 失敗 (exit $LASTEXITCODE)" }

        $wt = Join-Path $dir ".worktree-gh-pages"
        if (-not (Test-Path (Join-Path $wt "index.html"))) { throw "index.html 未產生" }

        Push-Location $wt
        try {
            git add index.html *>> $logFile
            $dirty = git status --porcelain
            if ([string]::IsNullOrWhiteSpace($dirty)) {
                $publish = "NO_CHANGE"
            } else {
                # 沿用每日 amend 策略：歷史只保留一筆，repo 不會隨天數膨脹
                git -c user.name="GeorgeK0113" -c user.email="okwong0113@gmail.com" `
                    commit --amend -q -m "Dashboard update $($today -replace '-','')" *>> $logFile
                git push -f origin gh-pages *>> $logFile
                if ($LASTEXITCODE -ne 0) { throw "git push 失敗 (exit $LASTEXITCODE)" }
                $publish = "PUSHED"
            }
        } finally {
            Pop-Location
        }
    } catch {
        $publish = "FAILED($($_.Exception.Message))"
        Add-Content -Path $logFile -Encoding utf8 -Value "PUBLISH ERROR: $($_.Exception.Message)"
    }
}

$line = "$stamp  exit=$exitCode  status=$status  publish=$publish  log=$logFile"
Add-Content -Path (Join-Path $dir "logs\run_history.log") -Encoding utf8 -Value $line
