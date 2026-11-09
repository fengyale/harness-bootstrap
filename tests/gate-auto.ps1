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

# Harness scaffolding lands first, without any feature summary: the summary-order
# guard refuses a commit that adds a summary together with changes outside
# .harness/, so setup and the record must be separate commits.
git -C $proj add scripts AGENTS.md .harness/rules
git -C $proj commit -q -m scaffold
Expect 'commit of harness scaffolding' $LASTEXITCODE 0

# an initial-stage summary has no lesson_id / sql_review yet: it must commit
$s = Get-Content "$proj\.harness\changes\demo\summary.md" -Raw -Encoding UTF8
$s = ($s -split "`r?`n" | Where-Object { $_ -notmatch 'lesson_id:' -and $_ -notmatch 'sql_review:' }) -join "`r`n"
Set-Content -LiteralPath "$proj\.harness\changes\demo\summary.md" -Value $s -Encoding UTF8
git -C $proj add .harness/changes/demo/summary.md
git -C $proj commit -q -m 'docs: initial summary'
Expect 'commit of an initial summary (record only)' $LASTEXITCODE 0

Step 'a new summary cannot be committed together with code'
New-Item -ItemType Directory -Force -Path "$proj\.harness\changes\demo2" | Out-Null
Set-Content -LiteralPath "$proj\.harness\changes\demo2\summary.md" -Value $s -Encoding UTF8
Set-Content -LiteralPath "$proj\Late.java" -Value 'public class Late {}' -Encoding UTF8
git -C $proj add .harness/changes/demo2/summary.md Late.java
# Redirecting native stderr turns each line into an ErrorRecord; EAP=Stop would
# abort the suite before the assertion, so relax it for this capture only.
$savedEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$lateOut = (& git -C $proj commit -m late-summary 2>&1 | Out-String)
$lateCode = $LASTEXITCODE
$ErrorActionPreference = $savedEap
Expect 'commit that adds a summary together with code' $lateCode 1
if ($lateOut -match 'committed together with changes outside') { Write-Host 'ok: blocked by the summary-order guard' }
else { Write-Host 'BAD: late summary not reported by the order guard' -ForegroundColor Red; $fail++ }

# Keep the summary staged, unstage the code: the record alone is accepted, and
# the code commit after it is accepted too. (git reset --hard would delete the
# staged-but-uncommitted summary, so only the path is reset.)
git -C $proj reset -q HEAD -- Late.java
git -C $proj commit -q -m summary-first
Expect 'commit of a new summary alone' $LASTEXITCODE 0
git -C $proj add Late.java
git -C $proj commit -q -m code-after-summary
Expect 'commit of code after its summary' $LASTEXITCODE 0
git -C $proj reset --hard HEAD -q

Step 'order guard: allowed and exempt shapes'
# an EXISTING summary may be edited together with code; only a NEW summary is constrained
Add-Content -LiteralPath "$proj\.harness\changes\demo2\summary.md" -Value '- 评审备注：existing summary updated with code' -Encoding UTF8
Set-Content -LiteralPath "$proj\Late.java" -Value 'public class Late { int n; }' -Encoding UTF8
git -C $proj add .harness/changes/demo2/summary.md Late.java
git -C $proj commit -q -m 'final fields with code'
Expect 'existing summary edited together with code' $LASTEXITCODE 0

# the shipped template is excluded from the guard
New-Item -ItemType Directory -Force -Path "$proj\.harness\changes\_template" | Out-Null
Set-Content -LiteralPath "$proj\.harness\changes\_template\summary.md" -Value '# template' -Encoding UTF8
Set-Content -LiteralPath "$proj\TemplateCode.java" -Value 'public class TemplateCode {}' -Encoding UTF8
git -C $proj add .harness/changes/_template/summary.md TemplateCode.java
git -C $proj commit -q -m 'template plus code'
Expect '_template summary plus code' $LASTEXITCODE 0

# git mv into a new feature dir shows up as an add because the hook uses --no-renames
New-Item -ItemType Directory -Force -Path "$proj\.harness\changes\demo3" | Out-Null
git -C $proj mv .harness/changes/demo2/summary.md .harness/changes/demo3/summary.md
Set-Content -LiteralPath "$proj\Renamed.java" -Value 'public class Renamed {}' -Encoding UTF8
git -C $proj add .harness/changes/demo3/summary.md Renamed.java
git -C $proj commit -q -m renamed-summary-with-code
Expect 'renamed summary together with code' $LASTEXITCODE 1
git -C $proj reset --hard HEAD -q
Remove-Item -LiteralPath "$proj\.harness\changes\demo3" -Recurse -Force -ErrorAction SilentlyContinue

Step 'record association: source commits need a summary or _small.md'
$mainBranch = (& git -C $proj rev-parse --abbrev-ref HEAD).Trim()
git -C $proj checkout -q -b feature/assoc
Set-Content -LiteralPath "$proj\AssocCode.java" -Value 'public class AssocCode {}' -Encoding UTF8
git -C $proj add AssocCode.java
git -C $proj commit -q -m 'code without a record'
Expect 'feature branch code without any record' $LASTEXITCODE 1

# keep the code out of the record commit, otherwise the order guard blocks it
git -C $proj reset -q HEAD -- AssocCode.java
New-Item -ItemType Directory -Force -Path "$proj\.harness\changes\assoc" | Out-Null
Set-Content -LiteralPath "$proj\.harness\changes\assoc\summary.md" -Value $s -Encoding UTF8
git -C $proj add .harness/changes/assoc/summary.md
git -C $proj commit -q -m 'docs: assoc summary'
Expect 'record committed before the code' $LASTEXITCODE 0
git -C $proj add AssocCode.java
git -C $proj commit -q -m 'code after record'
Expect 'code after its record on a feature branch' $LASTEXITCODE 0

# L1 path: a _small.md row in the same commit replaces the summary
Set-Content -LiteralPath "$proj\AssocL1.java" -Value 'public class AssocL1 {}' -Encoding UTF8
Add-Content -LiteralPath "$proj\.harness\changes\_small.md" -Value '- 2026-11-09 | assoc-l1 | AssocL1.java | test | lesson: none' -Encoding UTF8
git -C $proj add AssocL1.java .harness/changes/_small.md
git -C $proj commit -q -m 'L1 record with code'
Expect '_small.md row allows code without a summary' $LASTEXITCODE 0

# explicit exception for L0 / one-off imports
Set-Content -LiteralPath "$proj\AssocL0.java" -Value 'public class AssocL0 {}' -Encoding UTF8
git -C $proj add AssocL0.java
$env:HARNESS_ALLOW_NO_RECORD = '1'
git -C $proj commit -q -m 'L0 exception'
$assocEscape = $LASTEXITCODE
Remove-Item Env:HARNESS_ALLOW_NO_RECORD -ErrorAction SilentlyContinue
Expect 'HARNESS_ALLOW_NO_RECORD escape' $assocEscape 0

git -C $proj checkout -q $mainBranch

Step 'order guard: merge and squash are exempt'
$mainBranch = (& git -C $proj rev-parse --abbrev-ref HEAD).Trim()
git -C $proj checkout -q -b feat-merge
New-Item -ItemType Directory -Force -Path "$proj\.harness\changes\feat-merge" | Out-Null
Set-Content -LiteralPath "$proj\.harness\changes\feat-merge\summary.md" -Value $s -Encoding UTF8
Set-Content -LiteralPath "$proj\MergeCode.java" -Value 'public class MergeCode {}' -Encoding UTF8
# stage only the feature files: tracking .harness/metrics/gate.jsonl would make
# every later hook append a local change and block the checkout below
git -C $proj add .harness/changes/feat-merge/summary.md MergeCode.java
# --no-verify stands in for a branch created before the gate was installed.
# post-commit still runs, so count only from here: that commit is audited (it
# really is a late summary) and must not be attributed to the merge below.
git -C $proj commit -q --no-verify -m 'branch work'
git -C $proj checkout -q $mainBranch
$beforeMerge = @(Select-String -LiteralPath "$proj\.harness\metrics\gate.jsonl" -Pattern '"event":"summary_order"' -ErrorAction SilentlyContinue).Count
git -C $proj merge --no-ff -q -m 'merge feature branch' feat-merge
Expect 'merge --no-ff that brings a summary and code' $LASTEXITCODE 0
if (Test-Path -LiteralPath "$proj\MergeCode.java") { Write-Host 'ok: the merge really landed on the main branch' }
else { Write-Host 'BAD: merge did not land (stale branch state)' -ForegroundColor Red; $fail++ }
$afterMerge = @(Select-String -LiteralPath "$proj\.harness\metrics\gate.jsonl" -Pattern '"event":"summary_order"' -ErrorAction SilentlyContinue).Count
if ($afterMerge -eq $beforeMerge) { Write-Host 'ok: merge produced no summary_order audit event' }
else { Write-Host 'BAD: merge was flagged by the post-commit audit' -ForegroundColor Red; $fail++ }

git -C $proj checkout -q -b feat-squash
New-Item -ItemType Directory -Force -Path "$proj\.harness\changes\feat-squash" | Out-Null
Set-Content -LiteralPath "$proj\.harness\changes\feat-squash\summary.md" -Value $s -Encoding UTF8
Set-Content -LiteralPath "$proj\SquashCode.java" -Value 'public class SquashCode {}' -Encoding UTF8
git -C $proj add .harness/changes/feat-squash/summary.md SquashCode.java
git -C $proj commit -q --no-verify -m 'branch work'
git -C $proj checkout -q $mainBranch
$beforeSquash = @(Select-String -LiteralPath "$proj\.harness\metrics\gate.jsonl" -Pattern '"event":"summary_order"' -ErrorAction SilentlyContinue).Count
git -C $proj merge --squash -q feat-squash
git -C $proj commit -q -m 'squash feature branch'
Expect 'squash commit that brings a summary and code' $LASTEXITCODE 0
if (Test-Path -LiteralPath "$proj\SquashCode.java") { Write-Host 'ok: the squash really landed on the main branch' }
else { Write-Host 'BAD: squash did not land (stale branch state)' -ForegroundColor Red; $fail++ }
$afterSquash = @(Select-String -LiteralPath "$proj\.harness\metrics\gate.jsonl" -Pattern '"event":"summary_order"' -ErrorAction SilentlyContinue).Count
if ($afterSquash -eq $beforeSquash) { Write-Host 'ok: squash produced no summary_order audit event' }
else { Write-Host 'BAD: squash was flagged by the post-commit audit' -ForegroundColor Red; $fail++ }

Step 'order guard: --amend is audited after the commit'
$beforeAmend = @(Select-String -LiteralPath "$proj\.harness\metrics\gate.jsonl" -Pattern '"event":"summary_order"' -ErrorAction SilentlyContinue).Count
Set-Content -LiteralPath "$proj\AmendCode.java" -Value 'public class AmendCode {}' -Encoding UTF8
git -C $proj add AmendCode.java
git -C $proj commit -q -m 'code only'
New-Item -ItemType Directory -Force -Path "$proj\.harness\changes\amend" | Out-Null
Set-Content -LiteralPath "$proj\.harness\changes\amend\summary.md" -Value $s -Encoding UTF8
git -C $proj add .harness/changes/amend/summary.md
git -C $proj commit -q --amend --no-edit
Expect 'amend that adds a late summary' $LASTEXITCODE 0
$afterAmend = @(Select-String -LiteralPath "$proj\.harness\metrics\gate.jsonl" -Pattern '"event":"summary_order"' -ErrorAction SilentlyContinue).Count
$headShort = (& git -C $proj rev-parse --short HEAD).Trim()
$lastEvent = @(Select-String -LiteralPath "$proj\.harness\metrics\gate.jsonl" -Pattern '"event":"summary_order"' -ErrorAction SilentlyContinue) | Select-Object -Last 1
if (($afterAmend -eq ($beforeAmend + 1)) -and ($lastEvent.Line -match [regex]::Escape($headShort))) {
    Write-Host 'ok: the amended commit is the one recorded by post-commit'
}
else { Write-Host 'BAD: amend audit event missing or not tied to HEAD' -ForegroundColor Red; $fail++ }

Step 'order guard: cherry-pick replay is not flagged'
git -C $proj checkout -q -b cp-feat
New-Item -ItemType Directory -Force -Path "$proj\.harness\changes\cp-feat" | Out-Null
Set-Content -LiteralPath "$proj\.harness\changes\cp-feat\summary.md" -Value $s -Encoding UTF8
Set-Content -LiteralPath "$proj\CpCode.java" -Value 'public class CpCode {}' -Encoding UTF8
git -C $proj add .harness/changes/cp-feat/summary.md CpCode.java
git -C $proj commit -q --no-verify -m 'branch work for cherry-pick'
$cpSha = (& git -C $proj rev-parse HEAD).Trim()
git -C $proj checkout -q $mainBranch
# count after the --no-verify branch commit: post-commit runs even with --no-verify
$beforeCp = @(Select-String -LiteralPath "$proj\.harness\metrics\gate.jsonl" -Pattern '"event":"summary_order"' -ErrorAction SilentlyContinue).Count
git -C $proj cherry-pick $cpSha
Expect 'non-conflict cherry-pick replay' $LASTEXITCODE 0
$afterCp = @(Select-String -LiteralPath "$proj\.harness\metrics\gate.jsonl" -Pattern '"event":"summary_order"' -ErrorAction SilentlyContinue).Count
if ($afterCp -eq $beforeCp) { Write-Host 'ok: cherry-pick produced no summary_order audit event' }
else { Write-Host 'BAD: cherry-pick was flagged by the post-commit audit' -ForegroundColor Red; $fail++ }

Step 'order guard: stale replay state does not exempt an unrelated commit'
# cherry-pick --no-commit leaves CHERRY_PICK_HEAD; a path-level reset keeps it.
# An unrelated new summary must still be blocked by the order guard.
git -C $proj checkout -q -b cp-stale
New-Item -ItemType Directory -Force -Path "$proj\.harness\changes\cp-stale" | Out-Null
Set-Content -LiteralPath "$proj\.harness\changes\cp-stale\summary.md" -Value $s -Encoding UTF8
Set-Content -LiteralPath "$proj\StaleCode.java" -Value 'public class StaleCode {}' -Encoding UTF8
git -C $proj add .harness/changes/cp-stale/summary.md StaleCode.java
git -C $proj commit -q --no-verify -m 'branch work for stale state'
$staleSha = (& git -C $proj rev-parse HEAD).Trim()
git -C $proj checkout -q $mainBranch
git -C $proj cherry-pick --no-commit $staleSha | Out-Null
git -C $proj reset -q HEAD -- .
New-Item -ItemType Directory -Force -Path "$proj\.harness\changes\unrelated" | Out-Null
Set-Content -LiteralPath "$proj\.harness\changes\unrelated\summary.md" -Value $s -Encoding UTF8
Set-Content -LiteralPath "$proj\Unrelated.java" -Value 'public class Unrelated {}' -Encoding UTF8
git -C $proj add .harness/changes/unrelated/summary.md Unrelated.java
git -C $proj commit -q -m 'unrelated late summary'
Expect 'stale CHERRY_PICK_HEAD must not exempt another feature' $LASTEXITCODE 1
git -C $proj reset -q --hard HEAD
git -C $proj cherry-pick --quit 2>$null
# reset --hard keeps untracked files; drop them or a later `git add -A` would
# stage a new summary plus code and trip the guard in an unrelated test.
Remove-Item -LiteralPath "$proj\.harness\changes\cp-stale" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath "$proj\.harness\changes\unrelated" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath "$proj\StaleCode.java" -Force -ErrorAction SilentlyContinue

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
