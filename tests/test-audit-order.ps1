<#
  test-audit-order.ps1 -- behaviour of assets\scripts\audit-order.ps1

  Builds a throw-away git repository and asserts the CI-side order audit:
  reverse order is caught, summary-first passes, a bundled new summary fails,
  [L0] is skipped, a _small.md row counts as the record, and the feature pointer
  is resolved from the record tree / commit trailer instead of a branch name.
  Every case runs on the default branch on purpose: the audit must never depend
  on what the branch is called.

  Pure ASCII; never writes into this repository.
#>
param([string]$TestRoot = '')
$ErrorActionPreference = 'Stop'
if (-not $TestRoot) {
    $TestRoot = Join-Path $env:TEMP ('hb-tests-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '\test-audit-order')
}
if (Test-Path -LiteralPath $TestRoot) { Remove-Item -LiteralPath $TestRoot -Recurse -Force }

$script = Join-Path (Split-Path $PSScriptRoot -Parent) 'assets\scripts\audit-order.ps1'
$proj = Join-Path $TestRoot ('audit-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
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
    # Pin the pointer sources so the host environment cannot change which
    # feature is audited (HARNESS_TASK is the only ambient source left).
    $oldTask = $env:HARNESS_TASK
    Remove-Item Env:HARNESS_TASK -ErrorAction SilentlyContinue
    try {
        $callArgs = @('-File', $script, '-Root', $proj, '-Base', $baseSha)
        if ($Feature) { $callArgs += @('-Feature', $Feature) }
        $out = & powershell -NoProfile -ExecutionPolicy Bypass @callArgs @Extra 2>&1 | Out-String
        return [pscustomobject]@{ Code = $LASTEXITCODE; Text = $out }
    } finally {
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

    Write-Host '=== default branch + one record: resolved from the tree, no branch name ===' -ForegroundColor Cyan
    Set-Content -LiteralPath "$proj\G.java" -Value 'public class G {}' -Encoding UTF8
    GitCmd -GitArgs @('add', 'G.java')
    GitCmd -GitArgs @('commit', '-q', '-m', 'feat: code on the default branch')
    $r = RunAudit -Feature ''
    Check 'default branch + single record is audited, not skipped' (($r.Code -eq 0) -and ($r.Text -notmatch '\[SKIP\]'))
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

    Write-Host '=== Harness-Task trailer picks the task without a branch name ===' -ForegroundColor Cyan
    Set-Content -LiteralPath "$proj\H.java" -Value 'public class H {}' -Encoding UTF8
    GitCmd -GitArgs @('add', 'H.java')
    GitCmd -GitArgs @('commit', '-q', '-m', 'feat: code with a trailer', '-m', 'Harness-Task: other')
    $r = RunAudit -Feature ''
    Check 'trailer attributes the commit when several records exist' (($r.Code -eq 0) -and ($r.Text -notmatch '\[SKIP\]'))
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

    Write-Host '=== several records and no pointer ===' -ForegroundColor Cyan
    GitCmd -GitArgs @('checkout', '-q', $mainBranch)
    $baseSha = HeadSha
    Set-Content -LiteralPath "$proj\F.java" -Value 'public class F {}' -Encoding UTF8
    GitCmd -GitArgs @('add', 'F.java')
    GitCmd -GitArgs @('commit', '-q', '-m', 'feat: no pointer')
    $r = RunAudit -Feature ''
    Check 'ambiguous records without a pointer are reported, not silently passed' (($r.Code -eq 0) -and ($r.Text -match 'could not be attributed'))

    Write-Host '=== missing base ===' -ForegroundColor Cyan
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $script -Root $proj -Feature demo 2>&1 | Out-String
    # Without origin/main the script must refuse instead of guessing a range.
    Check 'missing base exits 2 when it cannot derive one' (($LASTEXITCODE -eq 2) -or ($out -match '\[ERROR\]'))
} finally {
    Remove-Item -LiteralPath $TestRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host '=== ignored record directory ===' -ForegroundColor Cyan
# A .gitignore entry for .harness/changes used to look exactly like "first
# harness adoption", so the gate stayed green forever. It must now fail and
# name the cause, and an explicit recordsTracked=false must turn it into a skip.
$proj2 = Join-Path $TestRoot ('audit-ign-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
try {
    New-Item -ItemType Directory -Force -Path $proj2 | Out-Null
    & git -C $proj2 init -q
    & git -C $proj2 config user.email 'audit@test.local'
    & git -C $proj2 config user.name 'audit test'
    Set-Content -LiteralPath "$proj2\.gitignore" -Value '.harness/changes/' -Encoding UTF8
    Set-Content -LiteralPath "$proj2\Bootstrap.java" -Value 'class Bootstrap { }' -Encoding ASCII
    & git -C $proj2 add -A
    & git -C $proj2 commit -q -m 'chore: bootstrap'
    $b2 = ([string](& git -C $proj2 rev-parse HEAD | Select-Object -First 1)).Trim()
    Set-Content -LiteralPath "$proj2\A.java" -Value 'class A { }' -Encoding ASCII
    & git -C $proj2 add 'A.java'
    & git -C $proj2 commit -q -m 'feat: code without a tracked record'
    $oldTask2 = $env:HARNESS_TASK
    Remove-Item Env:HARNESS_TASK -ErrorAction SilentlyContinue
    try {
        $out2 = & powershell -NoProfile -ExecutionPolicy Bypass -File $script -Root $proj2 -Base $b2 -Feature demo 2>&1 | Out-String
        Check 'ignored changes directory fails instead of skipping' (($LASTEXITCODE -eq 1) -and ($out2 -match '\[FAIL\].*ignored'))
        New-Item -ItemType Directory -Force -Path "$proj2\scripts" | Out-Null
        Set-Content -LiteralPath "$proj2\scripts\harness-required.json" -Value '{"recordsTracked":false}' -Encoding UTF8
        $out2 = & powershell -NoProfile -ExecutionPolicy Bypass -File $script -Root $proj2 -Base $b2 -Feature demo 2>&1 | Out-String
        Check 'recordsTracked=false is an explicit skip' (($LASTEXITCODE -eq 0) -and ($out2 -match 'recordsTracked=false'))
    } finally {
        if ($oldTask2) { $env:HARNESS_TASK = $oldTask2 }
    }
} finally {
    Remove-Item -LiteralPath $TestRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host '=== no records and no ignore: still a first adoption ===' -ForegroundColor Cyan
# The fail-closed branch must not swallow a genuine first install: no .harness
# at all and no .gitignore entry still has to skip, not fail.
$proj3 = Join-Path $TestRoot ('audit-new-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
try {
    New-Item -ItemType Directory -Force -Path $proj3 | Out-Null
    & git -C $proj3 init -q
    & git -C $proj3 config user.email 'audit@test.local'
    & git -C $proj3 config user.name 'audit test'
    Set-Content -LiteralPath "$proj3\Bootstrap.java" -Value 'class Bootstrap { }' -Encoding ASCII
    & git -C $proj3 add -A
    & git -C $proj3 commit -q -m 'chore: bootstrap'
    $b3 = ([string](& git -C $proj3 rev-parse HEAD | Select-Object -First 1)).Trim()
    $out3 = & powershell -NoProfile -ExecutionPolicy Bypass -File $script -Root $proj3 -Base $b3 -Feature demo 2>&1 | Out-String
    Check 'a real first adoption still skips' (($LASTEXITCODE -eq 0) -and ($out3 -match 'first harness adoption'))
} finally {
    Remove-Item -LiteralPath $TestRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fail -gt 0) {
    Write-Host "AUDIT ORDER TEST FAILED ($fail)" -ForegroundColor Red
    exit 1
}
Write-Host 'AUDIT ORDER TEST OK' -ForegroundColor Green
exit 0
