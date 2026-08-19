$ErrorActionPreference = "Continue"

# PowerShell 5.1 的 *> 重導向預設寫 UTF-16LE，會讓 log 中文變亂碼、grep 也抓不到。
$PSDefaultParameterValues['Out-File:Encoding'] = 'utf8'

# 這個是另一件事：控制 PowerShell「讀取外部程式 stdout」時要用什麼編碼解讀位元組。
# claude.exe 本身輸出 UTF-8，但沒設這個的話 PowerShell 會用系統主控台編碼（此機器是 Big5/950）
# 去解讀，解讀錯了之後才轉存成 UTF-8——結果檔案格式正確，內容卻是亂碼。
try { $OutputEncoding = [System.Text.UTF8Encoding]::new() } catch {}
try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new() } catch {}

$dir = "C:\Users\George\Desktop\CLAUDE other\宏觀風險掃描"
Set-Location $dir

$today = Get-Date -Format "yyyy-MM-dd"
$historyFile = Join-Path $dir "logs\run_history.log"

# ---------------------------------------------------------------------------
# 0. 今天是否已經成功跑過：這支腳本同時被兩個時間點的排程觸發（09:25 主跑、
#    13:30 補跑），13:30 那個原意只是「萬一早上沒開機才補跑」，但先前沒做
#    這個檢查，變成每天下午都無條件重跑一次完整掃描，重複消耗當天的
#    Claude 額度，導致下午幾乎每次都因為撞到 session 額度上限而失敗，
#    在桌面留下「掃描失敗」的假警報——即使早上其實已經成功。
#    這裡先檢查 run_history.log 裡今天是不是已經有 status=OK，有的話直接
#    結束，不要再跑。
# ---------------------------------------------------------------------------
if (Test-Path $historyFile) {
    $alreadyOk = Get-Content $historyFile -Encoding utf8 -ErrorAction SilentlyContinue |
        Where-Object { $_ -match "^$([regex]::Escape($today))_.*status=OK" }
    if ($alreadyOk) {
        # 靜默成功結束，不寫警示、不佔用額度。想看紀錄就翻 run_history.log。
        exit 0
    }
}

$claude = (Get-Command claude -ErrorAction SilentlyContinue).Source
if (-not $claude) {
    $claude = "$env:APPDATA\npm\claude.cmd"
}

$startTime = Get-Date
$stamp = Get-Date -Format "yyyy-MM-dd_HHmm"
$logFile = Join-Path $dir "logs\$stamp.log"
$alertFile = Join-Path ([Environment]::GetFolderPath("Desktop")) "⚠️宏觀掃描失敗.txt"

function Write-History($status, $publish, $exitCode) {
    $line = "$stamp  exit=$exitCode  status=$status  publish=$publish  log=$logFile"
    Add-Content -Path $historyFile -Encoding utf8 -Value $line
}

function Write-Log($text) {
    Add-Content -Path $logFile -Encoding utf8 -Value $text
}

# 外部命令（claude / git）的輸出一律用這個方式擷取：2>&1 合併串流成純文字陣列，
# 而不是用 *>> 直接導向檔案。後者在這台機器上會把 git 正常寫到 stderr 的進度訊息
# （例如 push 成功時的提示）包裝成看起來像致命錯誤的 NativeCommandError 格式，
# 即使該次操作其實成功，log 內容也會讓人誤判為失敗。用 2>&1 擷取成文字，
# 只靠 $LASTEXITCODE 判斷成敗，log 裡就只有純文字。
function Invoke-Logged($exePath, $exeArgs) {
    $output = & $exePath @exeArgs 2>&1 | ForEach-Object { $_.ToString() }
    $text = $output -join "`n"
    Write-Log $text
    return @{ Text = $text; ExitCode = $LASTEXITCODE }
}

function Raise-Alert($reason, $howToFix) {
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
# 1. 登入預檢
# ---------------------------------------------------------------------------
$authResult = Invoke-Logged $claude @("auth", "status")
Write-Log "=== auth precheck ===`n$($authResult.Text)"

if ($authResult.Text -notmatch '"loggedIn"\s*:\s*true') {
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
# 2. 執行掃描
#    - 一般失敗（例如單次網路問題）重試一次
#    - 額度限制（session limit）重試沒有意義，因為通常要 20-50 分鐘後才重置，
#      遠超過原本 120 秒的重試等待，直接標記為獨立的狀態、不重試、不用嚇人
#      的措辭發警示（這不是故障，是額度用完，等下次排程自然會恢復）
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
$sessionLimited = $false

while ($attempt -lt $maxAttempts) {
    $attempt++
    Write-Log "=== scan attempt $attempt / $maxAttempts  ($(Get-Date -Format 'HH:mm:ss')) ==="
    $scanResult = Invoke-Logged $claude $claudeArgs
    $exitCode = $scanResult.ExitCode

    if ($scanResult.Text -match "session limit|usage limit|rate limit") {
        $sessionLimited = $true
        Write-Log "偵測到額度限制，不再重試（重試也要等到額度重置才有用）。"
        break
    }

    $stale = Test-FilesUpdated
    if ($stale.Count -eq 0) { break }

    if ($scanResult.Text -match "OAuth|authenticate|credential") {
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

if ($sessionLimited) {
    Write-History "FAILED(SESSION_LIMIT)" "SKIPPED" $exitCode
    Raise-Alert "今天的 Claude 使用額度已用完，暫時無法掃描（非故障）。" @"
這不是需要你處理的錯誤，額度會在稍後自動重置。
下次排程觸發時會自動重新嘗試，通常不需要手動介入。
如果想現在立刻補跑：
   powershell -ExecutionPolicy Bypass -File "$dir\run_daily_scan.ps1"
"@
    exit 1
}

if ($stale.Count -eq 0) { $status = "OK" } else { $status = "FAILED(" + ($stale -join ",") + ")" }

# ---------------------------------------------------------------------------
# 3. 發布：只有確認檔案真的更新過才推
# ---------------------------------------------------------------------------
$publish = "SKIPPED"
if ($status -eq "OK") {
    try {
        $py = "C:\Users\George\AppData\Local\Programs\Python\Python311\python.exe"
        if (-not (Test-Path $py)) { $py = "python" }
        $buildResult = Invoke-Logged $py @((Join-Path $dir "build_shared_page.py"))
        if ($buildResult.ExitCode -ne 0) { throw "build_shared_page.py 失敗 (exit $($buildResult.ExitCode))" }

        $wt = Join-Path $dir ".worktree-gh-pages"
        if (-not (Test-Path (Join-Path $wt "index.html"))) { throw "index.html 未產生" }

        Push-Location $wt
        try {
            $env:GIT_TERMINAL_PROMPT = "0"

            Invoke-Logged "git" @("add", "index.html") | Out-Null
            $dirty = & git status --porcelain
            if ([string]::IsNullOrWhiteSpace($dirty)) {
                $publish = "NO_CHANGE"
            } else {
                $commitResult = Invoke-Logged "git" @(
                    "-c", "user.name=GeorgeK0113",
                    "-c", "user.email=okwong0113@gmail.com",
                    "commit", "--amend", "-q", "-m", "Dashboard update $($today -replace '-','')"
                )
                if ($commitResult.ExitCode -ne 0) { throw "git commit 失敗 (exit $($commitResult.ExitCode))" }

                $pushResult = Invoke-Logged "git" @("push", "-f", "origin", "gh-pages")
                if ($pushResult.ExitCode -ne 0) { throw "git push 失敗 (exit $($pushResult.ExitCode))" }
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
