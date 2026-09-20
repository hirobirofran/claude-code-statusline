# Scenario test for the threshold-alert (re-arm) logic in claude-statusline.ps1.
#
# Why this exists:
#   The alert logic is the only stateful part of the script, and the only part that has had a
#   real bug: a small dip such as 81% -> 79% used to reset the state and re-fire the 50% alert.
#   Run this after touching Test-Window, $Thresholds or $Hysteresis.
#   Everything else (how the toast looks, colors) is checked by eye, not here.
#   Not wired to any CI on purpose; run it by hand.
#
# Usage:
#   powershell -NoProfile -File windows\test-rearm.ps1        (pwsh works too)
#   powershell -NoProfile -File windows\test-rearm.ps1 -Src path\to\another\claude-statusline.ps1
#   Exit code: 0 = every scenario passed, 1 = a scenario failed.
#
# How it stays safe:
#   It never runs the real script. It patches a temp copy so that
#     - the state file lives in a temp folder (the real ~/.claude state is untouched)
#     - the notification spawn is replaced by a log line (no toasts pop up)
#   If either patch target is missing (the script was refactored), it refuses to run rather
#   than silently testing against the real state file. Update $stateExpr / $spawn below then.
#
# The patched copy always runs under Windows PowerShell 5.1, which is what settings.json uses.
# ASCII only, same as the script under test.
param([string]$Src = (Join-Path $PSScriptRoot 'claude-statusline.ps1'))

$ErrorActionPreference = 'Stop'

# Each step: @(percent fed as the 5-hour usage, threshold expected to fire; 0 = silent).
$scenarios = @(
    @{ Name  = 'dips, window resets and re-crossings'
       Steps = @(@(81, 80), @(79, 0), @(80, 0), @(49, 0), @(58, 50), @(96, 95), @(3, 0), @(52, 50)) },
    @{ Name  = 'hysteresis boundary: a 5-point dip is ignored, 6 points re-arms silently'
       Steps = @(@(81, 80), @(75, 0), @(74, 0), @(80, 80)) },
    @{ Name  = 'jumping over several thresholds fires only the highest'
       Steps = @(@(10, 0), @(97, 95)) }
)

$work  = Join-Path ([IO.Path]::GetTempPath()) ('statusline-test-' + [guid]::NewGuid().ToString('N'))
$copy  = Join-Path $work 'statusline-under-test.ps1'
$state = Join-Path $work 'state.json'
$log   = Join-Path $work 'notify.log'
New-Item -ItemType Directory -Path $work | Out-Null

$failed = 0
try {
    $code      = Get-Content $Src -Raw
    $stateExpr = "Join-Path `$HOME '.claude\statusline-alert-state.json'"
    $spawn     = 'Start-Process powershell -WindowStyle Hidden -ArgumentList @('
    if (-not $code.Contains($stateExpr)) { throw 'state file expression not found in the script; refusing to run' }
    if (-not $code.Contains($spawn))     { throw 'notification spawn not found in the script; refusing to run' }
    $code = $code.Replace($stateExpr, "'$state'").Replace($spawn, "Add-Content -Path '$log' -Value @(")
    Set-Content -Path $copy -Value $code -Encoding ASCII -NoNewline

    foreach ($sc in $scenarios) {
        Remove-Item $state, $log -ErrorAction SilentlyContinue
        ''
        '== {0}' -f $sc.Name
        foreach ($step in $sc.Steps) {
            $pct, $expected = $step
            $before = @(if (Test-Path $log) { Get-Content $log | Where-Object { $_ -match 'crossed' } }).Count
            $json = '{"model":{"display_name":"Sonnet 5"},"context_window":{"used_percentage":10},' +
                    '"rate_limits":{"five_hour":{"used_percentage":' + $pct + '}}}'
            $null = $json | powershell -NoProfile -File $copy
            $lines = @(if (Test-Path $log) { Get-Content $log | Where-Object { $_ -match 'crossed' } })
            $fired = 0
            if ($lines.Count -gt $before -and ([string]$lines[-1]) -match 'crossed (\d+)%') { $fired = [int]$Matches[1] }
            $ok = ($fired -eq $expected)
            if (-not $ok) { $failed++ }
            '{0}  {1,3}% -> fired {2,2}  (expected {3,2})' -f $(if ($ok) { 'ok  ' } else { 'FAIL' }), $pct, $fired, $expected
        }
    }
} finally {
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}

''
if ($failed) { "FAILED: $failed step(s) did not match"; exit 1 }
'PASSED: all scenarios'
