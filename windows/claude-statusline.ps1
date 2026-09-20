# Claude Code statusline for Windows PowerShell
# - Shows model / context % / 5h % / 7d %
# - Highlights the model name in red when it is Fable
# - Pops a Windows toast notification once per threshold crossing
# No network access. No LLM calls. ASCII only on purpose (PS 5.1 misreads UTF-8 without BOM).
param([string]$Notify)

# ---- settings ----
$Thresholds   = @(50, 80, 95)          # percent
$ExpensiveRe  = 'fable'                # model names to highlight (regex, case-insensitive)
$Hysteresis   = 5                      # percent points a value must drop below the last threshold to re-arm
$StateFile    = Join-Path $HOME '.claude\statusline-alert-state.json'

# ---- notify mode: spawned by this script itself, shows a toast and exits ----
if ($Notify) {
    # A real toast, not a NotifyIcon balloon: Windows removes a balloon from the notification
    # center as soon as its tray icon is disposed, so it could not be reviewed later.
    # The WinRT types below load only in Windows PowerShell 5.1 (not pwsh 7).
    [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
    [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
    $aumid = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
    $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
    $xml.LoadXml('<toast><visual><binding template="ToastGeneric"><text>Claude usage</text><text>' +
        [System.Security.SecurityElement]::Escape($Notify) + '</text></binding></visual></toast>')
    $toast = New-Object Windows.UI.Notifications.ToastNotification $xml
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($aumid).Show($toast)
    exit
}

# ---- read JSON from Claude Code ----
[Console]::InputEncoding  = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
try { $d = [Console]::In.ReadToEnd() | ConvertFrom-Json } catch { Write-Output '[statusline: bad input]'; exit }

$model = $d.model.display_name
$ctx   = $d.context_window.used_percentage
$five  = $d.rate_limits.five_hour.used_percentage
$week  = $d.rate_limits.seven_day.used_percentage

# ---- threshold alerts (once per crossing; re-arms when the window resets) ----
$state = @{ five_hour = 0; seven_day = 0 }
if (Test-Path $StateFile) {
    try {
        $s = Get-Content $StateFile -Raw | ConvertFrom-Json
        $state.five_hour = [int]$s.five_hour
        $state.seven_day = [int]$s.seven_day
    } catch {}
}

function Test-Window([string]$key, [string]$label, $pct) {
    if ($null -eq $pct) { return }
    $last = $script:state[$key]
    if ($pct -lt ($last - $Hysteresis)) {
        # Real drop (window reset): re-arm silently to the highest threshold already passed.
        # Small dips (stale snapshots from other terminals) are ignored.
        $last = [int](($Thresholds | Where-Object { $_ -le $pct } | Measure-Object -Maximum).Maximum)
    }
    $hit = ($Thresholds | Where-Object { $_ -le $pct -and $_ -gt $last } | Measure-Object -Maximum).Maximum
    if ($hit) {
        $last = [int]$hit
        $msg = '{0} usage {1:N0}% (crossed {2}%)' -f $label, $pct, $hit
        if ($PSCommandPath) {
            Start-Process powershell -WindowStyle Hidden -ArgumentList @(
                '-NoProfile', '-File', ('"{0}"' -f $PSCommandPath), '-Notify', ('"{0}"' -f $msg))
        }
    }
    $script:state[$key] = $last
}

$before = '{0}/{1}' -f $state.five_hour, $state.seven_day
Test-Window 'five_hour' '5-hour' $five
Test-Window 'seven_day' 'Weekly' $week
if ($before -ne ('{0}/{1}' -f $state.five_hour, $state.seven_day)) {
    try { $state | ConvertTo-Json | Set-Content $StateFile -Encoding ASCII } catch {}
}

# ---- render ----
$e = [char]27
function Paint($text, $pct) {
    if ($null -eq $pct) { return $text }
    if ($pct -ge 80) { return "$e[31m$text$e[0m" }          # red
    if ($pct -ge 50) { return "$e[33m$text$e[0m" }          # yellow
    return $text
}
function Pct($v) { if ($null -eq $v) { '--' } else { '{0:N0}%' -f $v } }

$modelText = "[$model]"
if ($model -match $ExpensiveRe) { $modelText = "$e[1;31m[!! $model !!]$e[0m" }

$parts = @(
    $modelText,
    (Paint ("ctx " + (Pct $ctx))  $ctx),
    (Paint ("5h "  + (Pct $five)) $five),
    (Paint ("7d "  + (Pct $week)) $week)
)
Write-Output ($parts -join ' | ')
