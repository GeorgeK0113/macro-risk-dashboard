$ErrorActionPreference = "Continue"

# PowerShell 5.1 的 *> 重導向預設寫 UTF-16LE，會讓 log 中文變亂碼、grep 也抓不到。
# 這行讓所有重導向改用 UTF-8（>、>>、*> 內部都是走 Out-File）。
$PSDefaultParameterValues['Out-File:Encoding'] = 'utf8'

$dir = "C:\Users\George\Desktop\CLAUDE other\宏觀風險掃描"
Set-Location $dir

$claude = (Get-Command claude -ErrorAction SilentlyContinue).Source
if (-not $claude) {
    $claude = "$env:APPDATA\npm\claude.cmd"
}

$startTime = Get-Date
$stamp = Get-Date -Format "yyyy-MM-dd_HHmm"
$today = Get-Date -Format "yyyy-MM-dd"
$logFile = Join-Path $dir "logs\$stamp.log"
$historyFile = Join-Path $dir "logs\run_history.log"
$alertFile = Join-Path ([Environment]::GetFolderPath("Desktop")) "⚠️宏觀掃描失敗.txt"

function Write-History($status, $publish, $exitCode) {
    $line = "$stamp  exit=$exitCode  status=$status  publish=$publish  log=$logFile"
    Add-Content -Path $historyFile -Encoding utf8 -Value $line
}

function Write-Log($text) {
    Add-Content -Path $logFile -Encoding utf8 -Value $text
}

# 連續失敗時在桌面留下一個看得到的檔案；成功就把它刪掉。
function Raise-Alert($reason, $howToFix) {
    $recent = @()
    if (Test-Path $historyFile) {
        $recent = @(Get-Content $historyFile -Encoding utf8 -ErrorAction SilentlyContinue |
                    Select-Object -Last 5 | Where-Object { $_ -match "status=FAILED" })
    }
    $body = @"
宏觀風險掃描失敗

時間：$(Get-Date -Format 'yyyy-MM-dd HH:mm')
原因：$reason

怎麼修：
$howToFix

詳細記錄：$logFile

（這個檔案會在下次掃描成功時自動消失）
"@
    Set-Content -Path $alertFile -Encoding utf8 -Value $body
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $n = New-Object System.Windows.Forms.NotifyIcon
        $n.Icon = [System.Drawing.SystemIcons]::Warning
        $n.Visible = $true
        $n.ShowBalloonTip(20000, "宏觀風險掃描失敗", $reason, [System.Windows.Forms.ToolTipIcon]::Warning)
        Start-Sleep -Seconds 6
        $n.Dispose()
    } catch { }
}

function Clear-Alert {
    if (Test-Path $alertFile) { Remove-Item $alertFile -Force -ErrorAction SilentlyContinue }
}

# ---------------------------------------------------------------------------
# 0. 登入預檢：憑證過期是最常見的失效原因，先驗明正身再跑，
#    否則 log 只會留下一堆「檔案未產生」，看不出真正病因。
# ---------------------------------------------------------------------------
$authOut = ""
try {
    $authOut = (& $claude auth status 2>&1 | Out-String)
} catch {
    $authOut = "auth status 執行失敗：$($_.Exception.Message)"
}
Write-Log "=== auth precheck ===`n$authOut"

if ($authOut -notmatch '"loggedIn"\s*:\s*true') {
    Write-Log "登入預檢未通過，本次不執行掃描。"
    Write-History "FAILED(AUTH_EXPIRED)" "SKIPPED" 1
    Raise-Alert "Claude CLI 登入已過期，掃描無法執行。" @"
1. 打開一個新的終端機（PowerShell 或 CMD）
2. 執行：claude auth login
3. 依畫面完成登入
4. 想立刻補跑就執行：
   powershell -ExecutionPolicy Bypass -File "$dir\run_daily_scan.ps1"
"@
    exit 1
}

# ---------------------------------------------------------------------------
# 1. 執行掃描（失敗時重試一次；認證類錯誤不重試，重試也沒用）
# ---------------------------------------------------------------------------
$prompt = "請讀取並嚴格依照 daily_scan_instructions.md 的規格，執行今天（實際系統日期）的宏觀風險掃描，把結果寫入 data/、reports/ 與 dashboard.html。注意該檔案第零條規則：一律重新抓取全部17項指標，禁止因為當天檔案已存在或資料看起來很新就跳過。"

$claudeArgs = @(
    "-p", $prompt,
    "--allowedTools", "WebSearch WebFetch Read Write Edit Glob Grep",
    "--output-format", "text",
    "--no-session-persistence"
)

function Test-FilesUpdated {
    $targets = @(
        (Join-Path $dir "data\$today.json"),
        (Join-Path $dir "reports\$today.md"),
        (Join-Path $dir "dashboard.html")
    )
    $bad = @()
    foreach ($f in $targets) {
        if (-not (Test-Path $f)) { $bad += "MISSING:$(Split-Path $f -Leaf)"; continue }
        if ((Get-Item $f).LastWriteTime -lt $startTime) { $bad += "NOT_UPDATED:$(Split-Path $f -Leaf)" }
    }
    return $bad
}

$attempt = 0
$maxAttempts = 2
$exitCode = 1
$stale = @("(未執行)")

while ($attempt -lt $maxAttempts) {
    $attempt++
    Write-Log "=== scan attempt $attempt / $maxAttempts  ($(Get-Date -Format 'HH:mm:ss')) ==="
    & $claude @claudeArgs *>> $logFile
    $exitCode = $LASTEXITCODE

    $stale = Test-FilesUpdated
    if ($stale.Count -eq 0) { break }

    $tail = ""
    if (Test-Path $logFile) {
        $tail = (Get-Content $logFile -Encoding utf8 -Tail 20 -ErrorAction SilentlyContinue) -join "`n"
    }
    if ($tail -match "OAuth|authenticate|login|credential") {
        Write-Log "偵測到認證類錯誤，不再重試。"
        Write-History "FAILED(AUTH_EXPIRED)" "SKIPPED" $exitCode
        Raise-Alert "Claude CLI 認證失效，掃描中止。" @"
1. 打開終端機執行：claude auth login
2. 補跑：powershell -ExecutionPolicy Bypass -File "$dir\run_daily_scan.ps1"
"@
        exit 1
    }

    if ($attempt -lt $maxAttempts) {
        Write-Log "第 $attempt 次未產生檔案（$($stale -join ',')），120 秒後重試。"
        Start-Sleep -Seconds 120
    }
}

if ($stale.Count -eq 0) { $status = "OK" } else { $status = "FAILED(" + ($stale -join ",") + ")" }

# ---------------------------------------------------------------------------
# 2. 發布：只有確認檔案真的更新過才推，避免把舊資料重推一次假裝有更新
# ---------------------------------------------------------------------------
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
                git -c user.name="GeorgeK0113" -c user.email="okwong0113@gmail.com" commit --amend -q -m "Dashboard update $($today -replace '-','')" *>> $logFile
                $env:GIT_TERMINAL_PROMPT = "0"   # 憑證有問題時要立刻失敗，不可卡在互動提示
                git push -f origin gh-pages *>> $logFile
                if ($LASTEXITCODE -ne 0) { throw "git push 失敗 (exit $LASTEXITCODE)" }
                $publish = "PUSHED"
            }
        } finally {
            Pop-Location
        }
    } catch {
        $publish = "FAILED($($_.Exception.Message))"
        Write-Log "PUBLISH ERROR: $($_.Exception.Message)"
    }
}

Write-History $status $publish $exitCode

if ($status -eq "OK" -and $publish -in @("PUSHED", "NO_CHANGE")) {
    Clear-Alert
} else {
    Raise-Alert "掃描或發布未完成：status=$status, publish=$publish" @"
請查看 $logFile 了解細節。
手動補跑：powershell -ExecutionPolicy Bypass -File "$dir\run_daily_scan.ps1"
"@
}
