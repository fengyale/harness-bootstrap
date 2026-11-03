$ErrorActionPreference = 'Stop'
$pkg  = Split-Path -Parent $PSScriptRoot
$proj = Join-Path $env:TEMP 'hb-install-test\proj3'
$fail = 0

function Step([string]$Name) { Write-Host ""; Write-Host "=== $Name ===" -ForegroundColor Cyan }
function Expect([string]$Label, [int]$Code, [int]$Want) {
    if ($Code -eq $Want) { Write-Host ("ok: {0} (exit {1})" -f $Label, $Code) }
    else { Write-Host ("BAD: {0} exit={1} want={2}" -f $Label, $Code, $Want) -ForegroundColor Red; $script:fail++ }
}

if (Test-Path $proj) { Remove-Item $proj -Recurse -Force }
New-Item -ItemType Directory -Force -Path "$proj\.harness\changes\demo" | Out-Null
Copy-Item "$pkg\templates\scripts" "$proj\scripts" -Recurse

Step 'flow value with a trailing note'
$tpl = Get-Content "$pkg\templates\.harness\changes\_template\summary.md" -Raw -Encoding UTF8
$tpl = $tpl -replace 'YYYY-MM-DD', (Get-Date -Format 'yyyy-MM-dd')
$tpl = $tpl -replace '(?m)(?<![A-Za-z0-9_\-])impl_corrections:[^\r\n]*', 'impl_corrections: 0'
$tpl = $tpl -replace '(?m)(?<![A-Za-z0-9_\-])corrections:[^\r\n]*', 'corrections: 0'
$tpl = $tpl -replace '(?m)(?<![A-Za-z0-9_\-])loaded_skills:[^\r\n]*', 'loaded_skills: request-analysis'
$tpl = $tpl -replace '(?m)(?<![A-Za-z0-9_\-])load_skip_reason:[^\r\n]*', 'load_skip_reason: n/a'
$tpl = $tpl -replace '(?m)(?<![A-Za-z0-9_\-])touched_modules:[^\r\n]*', 'touched_modules: demo'
$tpl = $tpl -replace '(?m)(?<![A-Za-z0-9_\-])lesson_id:[^\r\n]*', 'lesson_id: -'
$tpl = $tpl -replace '(?m)(?<![A-Za-z0-9_\-])sql_review:[^\r\n]*', 'sql_review: no SQL change'
$tpl = $tpl -replace '(?m)^- 本次暴露的短板：[^\r\n]*', '- 本次暴露的短板：无'
$tpl = $tpl -replace '(?m)^- 已补的能力：[^\r\n]*', '- 已补的能力：无'
$tpl = $tpl -replace '(?m)(?<![A-Za-z0-9_\-])flow:[^\r\n]*', 'flow: L2 (standard)'
Set-Content -LiteralPath "$proj\.harness\changes\demo\summary.md" -Value $tpl -Encoding UTF8

& powershell -NoProfile -ExecutionPolicy Bypass -File "$proj\scripts\check-summary.ps1" -Root $proj -Feature demo -Stage initial -Quiet
Expect 'flow "L2 (standard)"' $LASTEXITCODE 0

# full-width parens are built from a code point so this .ps1 can stay readable
$fw = 'flow: L2' + [char]0xFF08 + 'standard' + [char]0xFF09
$t2 = (Get-Content "$proj\.harness\changes\demo\summary.md" -Raw -Encoding UTF8) -replace 'flow: L2 \(standard\)', $fw
Set-Content -LiteralPath "$proj\.harness\changes\demo\summary.md" -Value $t2 -Encoding UTF8
& powershell -NoProfile -ExecutionPolicy Bypass -File "$proj\scripts\check-summary.ps1" -Root $proj -Feature demo -Stage final -Quiet
Expect 'flow with full-width parens' $LASTEXITCODE 0

Step 'compiles / tests-green are machine checked'
$agents = @'
# demo project

## 技术栈

| 层级 | 技术 |
| --- | --- |
| 语言 | demo |
| 数据库 | demo |
| 前端 | demo |

## 必跑命令

| 用途 | 命令 |
| --- | --- |
| 编译 / 类型检查 | `exit 1` |
| 跑全部测试 | `exit 0` |
'@
[System.IO.File]::WriteAllText("$proj\AGENTS.md", $agents, (New-Object System.Text.UTF8Encoding($true)))
New-Item -ItemType Directory -Force -Path "$proj\.harness\metrics" | Out-Null
$ts = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
Add-Content -LiteralPath "$proj\.harness\metrics\gate.jsonl" -Value ('{"event":"scan","ts":"' + $ts + '","blocked":0,"files":1,"hunks":1}') -Encoding UTF8

& powershell -NoProfile -ExecutionPolicy Bypass -File "$proj\scripts\stage-gate.ps1" -Root $proj -Stage 3 -Feature demo | Out-Null
Expect 'stage 3 with failing compile' $LASTEXITCODE 1

# stage 5 depends on the same compile row, so fix it before testing the test row
$fixed = $agents.Replace('`exit 1`', '`exit 0`').Replace('| 跑全部测试 | `exit 0` |', '| 跑全部测试 | `exit 1` |')
[System.IO.File]::WriteAllText("$proj\AGENTS.md", $fixed, (New-Object System.Text.UTF8Encoding($true)))
& powershell -NoProfile -ExecutionPolicy Bypass -File "$proj\scripts\stage-gate.ps1" -Root $proj -Stage 5 -Feature demo | Out-Null
Expect 'stage 5 with failing tests' $LASTEXITCODE 1

$fixed2 = $fixed.Replace('| 跑全部测试 | `exit 1` |', '| 跑全部测试 | `exit 0` |')
[System.IO.File]::WriteAllText("$proj\AGENTS.md", $fixed2, (New-Object System.Text.UTF8Encoding($true)))
& powershell -NoProfile -ExecutionPolicy Bypass -File "$proj\scripts\stage-gate.ps1" -Root $proj -Stage 5 -Feature demo | Out-Null
Expect 'stage 5 with passing tests' $LASTEXITCODE 0

& powershell -NoProfile -ExecutionPolicy Bypass -File "$proj\scripts\stage-gate.ps1" -Root $proj -Stage 3 -Feature demo | Out-Null
Expect 'stage 3 with passing compile' $LASTEXITCODE 0

# no compile row at all -> FAIL/BLOCKED (declared-but-empty is SKIP; absent is a gap)
$noCmd = ($fixed2 -split "`r?`n" | Where-Object { $_ -notmatch '编译 / 类型检查' }) -join "`r`n"
[System.IO.File]::WriteAllText("$proj\AGENTS.md", $noCmd, (New-Object System.Text.UTF8Encoding($true)))
$out = & powershell -NoProfile -ExecutionPolicy Bypass -File "$proj\scripts\stage-gate.ps1" -Root $proj -Stage 3 -Feature demo 2>&1 | Out-String
Expect 'stage 3 without a compile row' $LASTEXITCODE 1
if ($out -match '\[FAIL\].*compiles') { Write-Host 'ok: missing command row is reported as FAIL' }
else { Write-Host 'BAD: missing row not reported as FAIL' -ForegroundColor Red; $fail++ }

# a declared but unfilled row -> SKIP, exit 0, never counted as PASS
$ph = ($fixed2 -split "`r?`n" | ForEach-Object {
    if ($_ -match '编译 / 类型检查') { '| 编译 / 类型检查 | `<待实测>` |' } else { $_ }
}) -join "`r`n"
[System.IO.File]::WriteAllText("$proj\AGENTS.md", $ph, (New-Object System.Text.UTF8Encoding($true)))
$out = & powershell -NoProfile -ExecutionPolicy Bypass -File "$proj\scripts\stage-gate.ps1" -Root $proj -Stage 3 -Feature demo 2>&1 | Out-String
Expect 'stage 3 with a placeholder compile row' $LASTEXITCODE 0
if ($out -match '\[SKIP\].*compiles') { Write-Host 'ok: placeholder row is reported as SKIP' }
else { Write-Host 'BAD: placehold row not reported as SKIP' -ForegroundColor Red; $fail++ }

Step 'pre-commit checks basic fields only'
git -C $proj init -q
git -C $proj config user.email t@t.t
git -C $proj config user.name t
& powershell -NoProfile -ExecutionPolicy Bypass -File "$proj\scripts\install-git-hooks.ps1" -Root $proj | Out-Null

# an initial-stage summary has no lesson_id / sql_review yet: it must commit
$s = Get-Content "$proj\.harness\changes\demo\summary.md" -Raw -Encoding UTF8
$s = ($s -split "`r?`n" | Where-Object { $_ -notmatch 'lesson_id:' -and $_ -notmatch 'sql_review:' }) -join "`r`n"
Set-Content -LiteralPath "$proj\.harness\changes\demo\summary.md" -Value $s -Encoding UTF8
git -C $proj add -A
git -C $proj commit -q -m init
Expect 'commit of an initial summary' $LASTEXITCODE 0

# removing a basic field must still be blocked by the hook
$s2 = ($s -split "`r?`n" | Where-Object { $_ -notmatch '(?<![A-Za-z0-9_\-])corrections:' }) -join "`r`n"
Set-Content -LiteralPath "$proj\.harness\changes\demo\summary.md" -Value $s2 -Encoding UTF8
git -C $proj add -A
git -C $proj commit -q -m missing-field
Expect 'commit without corrections field' $LASTEXITCODE 1

Write-Host ""
if ($fail -eq 0) { Write-Host 'GATE-AUTO OK' -ForegroundColor Green; exit 0 }
Write-Host "GATE-AUTO FAILURES: $fail" -ForegroundColor Red
exit 1
