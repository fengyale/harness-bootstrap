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
New-Item -ItemType Directory -Force -Path "$proj\.harness\rules" | Out-Null
Copy-Item "$pkg\templates\scripts" "$proj\scripts" -Recurse
# The template harness-required.json ships sqlGate=true. The hook is fail-closed
# when the rule is missing, so the fixture must carry a rule for the normal
# summary commits below to pass.
Set-Content -LiteralPath "$proj\.harness\rules\SQL-review.md" -Value @(
    '# SQL review',
    '',
    '- evaluate tables',
    '- estimate rows',
    '- check the access path'
) -Encoding UTF8

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

Step 'worktree check-summary replacement is rejected'
Set-Content -LiteralPath "$proj\scripts\check-summary.ps1" -Value '' -Encoding ASCII
$toolSum = Get-Content -LiteralPath "$proj\.harness\changes\demo\summary.md" -Raw -Encoding UTF8
$toolSum = ($toolSum -split "`r?`n" | Where-Object { $_ -notmatch '(?<![A-Za-z0-9_\-])corrections:' }) -join "`r`n"
Set-Content -LiteralPath "$proj\.harness\changes\demo\summary.md" -Value $toolSum -Encoding UTF8
git -C $proj add .harness/changes/demo/summary.md
git -C $proj commit -q -m local-empty-check-summary
Expect 'commit with worktree check-summary replaced' $LASTEXITCODE 1
git -C $proj reset --hard HEAD -q

Step 'worktree red-line scanner replacement is rejected'
Set-Content -LiteralPath "$proj\scripts\red-line-scan.ps1" -Value '' -Encoding ASCII
Set-Content -LiteralPath "$proj\A.java" -Value 'public class A { void f() { throw new RuntimeException(); } }' -Encoding UTF8
git -C $proj add A.java
git -C $proj commit -q -m local-empty-redline
Expect 'commit with worktree red-line scanner replaced' $LASTEXITCODE 1
git -C $proj reset --hard HEAD -q
Remove-Item -LiteralPath "$proj\A.java" -Force -ErrorAction SilentlyContinue

Step 'worktree SQL gate replacement is rejected'
Set-Content -LiteralPath "$proj\scripts\sql-review-gate.ps1" -Value '' -Encoding ASCII
$toolSum = Get-Content -LiteralPath "$proj\.harness\changes\demo\summary.md" -Raw -Encoding UTF8
$toolSum = ($toolSum -split "`r?`n" | Where-Object { $_ -notmatch 'sql_review:' }) -join "`r`n"
Set-Content -LiteralPath "$proj\.harness\changes\demo\summary.md" -Value $toolSum -Encoding UTF8
Set-Content -LiteralPath "$proj\SqlDemo.sql" -Value 'select * from t' -Encoding UTF8
git -C $proj add .harness/changes/demo/summary.md SqlDemo.sql
git -C $proj commit -q -m local-empty-sql-gate
Expect 'commit with worktree SQL gate replaced' $LASTEXITCODE 1
git -C $proj reset --hard HEAD -q
Remove-Item -LiteralPath "$proj\SqlDemo.sql" -Force -ErrorAction SilentlyContinue

Step 'worktree red-line-rules replacement is rejected'
Set-Content -LiteralPath "$proj\scripts\red-line-rules.json" -Value '{"rules":[{"id":"R1","name":"x","pattern":"__never__","include":["*.java"]}]}' -Encoding UTF8
Set-Content -LiteralPath "$proj\A.java" -Value 'public class A { void f() { throw new RuntimeException(); } }' -Encoding UTF8
git -C $proj add A.java
git -C $proj commit -q -m local-weakened-rules
Expect 'commit with worktree red-line rules replaced' $LASTEXITCODE 1
git -C $proj reset --hard HEAD -q
Remove-Item -LiteralPath "$proj\A.java" -Force -ErrorAction SilentlyContinue

Step 'deleting red-line-rules.json alone is blocked'
git -C $proj reset --hard HEAD -q
git -C $proj rm -q scripts/red-line-rules.json
git -C $proj commit -q -m rm-rules-json
Expect 'commit with only red-line-rules.json deleted' $LASTEXITCODE 1
git -C $proj reset --hard HEAD -q

# removing a basic field must still be blocked by the hook
$s2 = ($s -split "`r?`n" | Where-Object { $_ -notmatch '(?<![A-Za-z0-9_\-])corrections:' }) -join "`r`n"
Set-Content -LiteralPath "$proj\.harness\changes\demo\summary.md" -Value $s2 -Encoding UTF8
git -C $proj add -A
git -C $proj commit -q -m missing-field
Expect 'commit without corrections field' $LASTEXITCODE 1

Step 'sqlGate=true: an unstaged sqlGate=false must not bypass the gate'
# Reset the failed staged summary so the fixture is clean before the next probe.
git -C $proj reset --hard HEAD -q
$req = Get-Content -LiteralPath "$proj\scripts\harness-required.json" -Raw -Encoding UTF8
$req = $req -replace '"sqlGate"\s*:\s*true', '"sqlGate": false'
Set-Content -LiteralPath "$proj\scripts\harness-required.json" -Value $req -Encoding UTF8
# The summary is staged without sql_review; the config edit stays unstaged.
$sum = Get-Content -LiteralPath "$proj\.harness\changes\demo\summary.md" -Raw -Encoding UTF8
$sum = ($sum -split "`r?`n" | Where-Object { $_ -notmatch 'sql_review:' }) -join "`r`n"
Set-Content -LiteralPath "$proj\.harness\changes\demo\summary.md" -Value $sum -Encoding UTF8
Set-Content -LiteralPath "$proj\SqlDemo.sql" -Value 'select * from t' -Encoding UTF8
git -C $proj add .harness/changes/demo/summary.md SqlDemo.sql
git -C $proj commit -q -m workspace-config-bypass
Expect 'commit with unstaged sqlGate=false and SQL change' $LASTEXITCODE 1

Step 'sqlGate=true: deleting only the rule blocks the empty-diff path'
git -C $proj reset --hard HEAD -q
git -C $proj rm -q .harness/rules/SQL-review.md
git -C $proj commit -q -m rm-rule-only
Expect 'commit with only the SQL rule deleted' $LASTEXITCODE 1

Step 'sqlGate=true: deleting the rule and adding source blocks the commit'
git -C $proj reset --hard HEAD -q
Remove-Item -LiteralPath "$proj\.harness\rules\SQL-review.md" -Force
Set-Content -LiteralPath "$proj\Demo.java" -Value 'public class Demo {}' -Encoding UTF8
git -C $proj add -A
git -C $proj commit -q -m no-sql-rule
Expect 'commit with sqlGate=true and no rule' $LASTEXITCODE 1

Step 'sqlGate=false: explicit opt-out is respected'
$reqPath = "$proj\scripts\harness-required.json"
$req = Get-Content -LiteralPath $reqPath -Raw -Encoding UTF8
$req = $req -replace '"sqlGate"\s*:\s*true', '"sqlGate": false'
Set-Content -LiteralPath $reqPath -Value $req -Encoding UTF8
Remove-Item -LiteralPath "$proj\scripts\sql-review-gate.ps1" -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath "$proj\scripts\sql-review-gate.py" -Force -ErrorAction SilentlyContinue
git -C $proj add -A
git -C $proj commit -q -m sql-off
Expect 'commit with sqlGate=false' $LASTEXITCODE 0

Step 'sqlGate=false with leftover SQL artifacts is rejected'
git -C $proj reset --hard HEAD -q
Set-Content -LiteralPath "$proj\.harness\rules\SQL-review.md" -Value '# SQL review' -Encoding UTF8
Set-Content -LiteralPath "$proj\scripts\sql-review-gate.ps1" -Value '# leftover gate' -Encoding ASCII
git -C $proj add -A
git -C $proj commit -q -m false-with-artifacts
Expect 'commit with sqlGate=false and leftover artifacts' $LASTEXITCODE 1

Step 'legacy gate-only state is rejected'
git -C $proj reset --hard HEAD -q
$req = Get-Content -LiteralPath "$proj\scripts\harness-required.json" -Raw -Encoding UTF8
$req = $req -replace '(?m)^\s*"sqlGate"\s*:\s*false,\s*\r?\n', ''
Set-Content -LiteralPath "$proj\scripts\harness-required.json" -Value $req -Encoding UTF8
Set-Content -LiteralPath "$proj\scripts\sql-review-gate.ps1" -Value '# leftover gate' -Encoding ASCII
git -C $proj add -A
git -C $proj commit -q -m legacy-gate-only
Expect 'commit with legacy gate-only state' $LASTEXITCODE 1

Step 'deleting check-summary.ps1 alone is blocked even with an empty diff'
git -C $proj reset --hard HEAD -q
git -C $proj rm -q scripts/check-summary.ps1
git -C $proj commit -q -m rm-summary-check
Expect 'commit with only check-summary.ps1 deleted' $LASTEXITCODE 1

Step 'deleting the last tracked scanner is blocked'
git -C $proj reset --hard HEAD -q
# --cached leaves the worktree copies, so the hook reaches the tracked-scanner
# check instead of failing earlier on "no scanner in the worktree".
git -C $proj rm --cached -q scripts/red-line-scan.ps1 scripts/red-line-scan.py
git -C $proj commit -q -m rm-last-scanner
Expect 'commit that removes the last tracked scanner' $LASTEXITCODE 1
git -C $proj reset --hard HEAD -q

Write-Host ""
if ($fail -eq 0) { Write-Host 'GATE-AUTO OK' -ForegroundColor Green; exit 0 }
Write-Host "GATE-AUTO FAILURES: $fail" -ForegroundColor Red
exit 1
