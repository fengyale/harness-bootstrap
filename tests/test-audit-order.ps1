<#
  test-audit-order.ps1 -- behaviour of templates\scripts\audit-order.ps1

  Builds a throw-away git repository and asserts the CI-side order audit:
  reverse order is caught, summary-first passes, a bundled new summary fails,
  [L0] is skipped, a _small.md row counts as the record, and a missing feature
  pointer skips instead of guessing.

  Pure ASCII; never writes into this repository.
#>
$ErrorActionPreference = 'Stop'

$script = Join-Path (Split-Path $PSScriptRoot -Parent) 'templates\scripts\audit-order.ps1'
$proj = Join-Path $env:TEMP ('hb-audit-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$fail = 0

function Check {
    param([string]$Name, [bool]$Ok)
    if ($Ok) {
        Write-Host "ok: $Name"
    } else {
        Write-Host "BAD: $Name" -ForegroundColor Red
        $script:fail++
    }
}
function GitCmd {
    param([string[]]$GitArgs)
    & git -C $proj @GitArgs 2>$null
}
function RunAudit {
    param([string[]]$Extra = @(), [string]$Feature = 'demo')
    # The script falls back to GITHUB_HEAD_REF / HARNESS_TASK / the branch name.
    # On a PR runner GITHUB_HEAD_REF is set, which would silently change which
    # feature is audited; pin it here instead of inheriting the environment.
    $oldHead = $env:GITHUB_HEAD_REF
    $oldTask = $env:HARNESS_TASK
    Remove-Item Env:GITHUB_HEAD_REF -ErrorAction SilentlyContinue
    Remove-Item Env:HARNESS_TASK -ErrorAction SilentlyContinue
    try {
        $callArgs = @('-File', $script, '-Root', $proj, '-Base', $baseSha)
        if ($Feature) { $callArgs += @('-Feature', $Feature) }
        $out = & powershell -NoProfile -ExecutionPolicy Bypass @callArgs @Extra 2>&1 | Out-String
        return [pscustomobject]@{ Code = $LASTEXITCODE; Text = $out }
    } finally {
        if ($oldHead) { $env:GITHUB_HEAD_REF = $oldHead }
        if ($oldTask) { $env:HARNESS_TASK = $oldTask }
    }
}
function HeadSha {
    return ([string](GitCmd -GitArgs @('rev-parse', 'HEAD') | Select-Object -First 1)).Trim()
}

try {
    New-Item -ItemType Directory -Force -Path $proj | Out-Null
    GitCmd -GitArgs @('init', '-q')
    GitCmd -GitArgs @('config', 'user.email', 'audit@test.local')
    GitCmd -GitArgs @('config', 'user.name', 'audit test')

    New-Item -ItemType Directory -Force -Path "$proj\.harness\changes" | Out-Null
    Set-Content -LiteralPath "$proj\.harness\changes\README.md" -Value '# changes' -Encoding UTF8
    GitCmd -GitArgs @('add', '.harness/changes/README.md')
    GitCmd -GitArgs @('commit', '-q', '-m', 'chore: bootstrap')
    $baseSha = ([string](GitCmd -GitArgs @('rev-parse', 'HEAD') | Select-Object -First 1)).Trim()
    $mainBranch = ([string](GitCmd -GitArgs @('rev-parse', '--abbrev-ref', 'HEAD') | Select-Object -First 1)).Trim()
    GitCmd -GitArgs @('checkout', '-q', '-b', 'feature/demo')

    Write-Host '=== reverse order (code first) ===' -ForegroundColor Cyan
    Set-Content -LiteralPath "$proj\A.java" -Value 'public class A {}' -Encoding UTF8
    GitCmd -GitArgs @('add', 'A.java')
    GitCmd -GitArgs @('commit', '-q', '-m', 'feat: code before the record')
    $r = RunAudit
    Check 'code before summary is rejected' ($r.Code -eq 1)
    $baseSha = HeadSha

    Write-Host '=== summary first, then code ===' -ForegroundColor Cyan
    New-Item -ItemType Directory -Force -Path "$proj\.harness\changes\demo" | Out-Null
    Set-Content -LiteralPath "$proj\.harness\changes\demo\summary.md" -Value '# demo' -Encoding UTF8
    GitCmd -GitArgs @('add', '.harness/changes/demo/summary.md')
    GitCmd -GitArgs @('commit', '-q', '-m', 'docs: demo summary')
    Set-Content -LiteralPath "$proj\B.java" -Value 'public class B {}' -Encoding UTF8
    GitCmd -GitArgs @('add', 'B.java')
    GitCmd -GitArgs @('commit', '-q', '-m', 'feat: code after the record')
    $r = RunAudit
    Check 'code after its summary passes' ($r.Code -eq 0)
    $baseSha = HeadSha

    Write-Host '=== new summary bundled with code ===' -ForegroundColor Cyan
    New-Item -ItemType Directory -Force -Path "$proj\.harness\changes\other" | Out-Null
    Set-Content -LiteralPath "$proj\.harness\changes\other\summary.md" -Value '# other' -Encoding UTF8
    Set-Content -LiteralPath "$proj\C.java" -Value 'public class C {}' -Encoding UTF8
    GitCmd -GitArgs @('add', '.harness/changes/other/summary.md', 'C.java')
    GitCmd -GitArgs @('commit', '-q', '-m', 'feat: bundled summary and code')
    $r = RunAudit
    Check 'bundled new summary is rejected' ($r.Code -eq 1)
    $baseSha = HeadSha

    Write-Host '=== [L0] marker ===' -ForegroundColor Cyan
    Set-Content -LiteralPath "$proj\D.java" -Value 'public class D {}' -Encoding UTF8
    GitCmd -GitArgs @('add', 'D.java')
    GitCmd -GitArgs @('commit', '-q', '-m', 'fix: comment typo [L0]')
    $r = RunAudit
    Check '[L0] commits are skipped' ($r.Code -eq 0)
    $baseSha = HeadSha

    Write-Host '=== _small.md row as the record ===' -ForegroundColor Cyan
    Set-Content -LiteralPath "$proj\.harness\changes\_small.md" -Value @('# small', '- 2026-11-11 | demo-l1 | E.java | test | lesson: none') -Encoding UTF8
    Set-Content -LiteralPath "$proj\E.java" -Value 'public class E {}' -Encoding UTF8
    GitCmd -GitArgs @('add', '.harness/changes/_small.md', 'E.java')
    GitCmd -GitArgs @('commit', '-q', '-m', 'feat: L1 record with code')
    $r = RunAudit
    Check '_small.md row counts as a record' ($r.Code -eq 0)

    Write-Host '=== no feature pointer ===' -ForegroundColor Cyan
    GitCmd -GitArgs @('checkout', '-q', $mainBranch)
    $baseSha = HeadSha
    Set-Content -LiteralPath "$proj\F.java" -Value 'public class F {}' -Encoding UTF8
    GitCmd -GitArgs @('add', 'F.java')
    GitCmd -GitArgs @('commit', '-q', '-m', 'feat: no pointer')
    $r = RunAudit -Feature ''
    Check 'missing feature pointer skips' (($r.Code -eq 0) -and ($r.Text -match 'no feature pointer'))

    Write-Host '=== missing base ===' -ForegroundColor Cyan
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $script -Root $proj -Feature demo 2>&1 | Out-String
    # Without origin/main the script must refuse instead of guessing a range.
    Check 'missing base exits 2 when it cannot derive one' (($LASTEXITCODE -eq 2) -or ($out -match '\[ERROR\]'))
} finally {
    Remove-Item -LiteralPath $proj -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fail -gt 0) {
    Write-Host "AUDIT ORDER TEST FAILED ($fail)" -ForegroundColor Red
    exit 1
}
Write-Host 'AUDIT ORDER TEST OK' -ForegroundColor Green
exit 0
