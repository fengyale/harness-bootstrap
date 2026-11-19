$ErrorActionPreference = 'Stop'
$pkg  = Split-Path -Parent $PSScriptRoot
$proj = Join-Path $env:TEMP 'hb-install-test\proj2'
$fail = 0

function Step([string]$Name) { Write-Host ""; Write-Host "=== $Name ===" -ForegroundColor Cyan }

if (Test-Path $proj) { Remove-Item $proj -Recurse -Force }
New-Item -ItemType Directory -Force -Path "$proj\.harness\changes\demo" | Out-Null
Copy-Item "$pkg\assets\scripts" "$proj\scripts" -Recurse

# --- AGENTS.md: stages 3/5/7/8 execute the declared commands for real, and a
# missing row is BLOCKED (only a placeholder row is SKIP), so the fixture must
# declare a measured command for both purposes.
$agents = @'
# demo project

## 必跑命令

| 用途 | 命令 |
| --- | --- |
| 编译 / 类型检查 | exit 0 |
| 跑全部测试 | exit 0 |
'@
Set-Content -LiteralPath "$proj\AGENTS.md" -Value $agents -Encoding UTF8

# --- git repo so the hook checks have something real to inspect
Step 'git init + install hooks'
git -C $proj init -q
git -C $proj config user.email t@t.t
git -C $proj config user.name t
& powershell -NoProfile -ExecutionPolicy Bypass -File "$proj\scripts\install-git-hooks.ps1" -Root $proj | Out-Null
foreach ($h in @('pre-commit','post-commit','pre-merge-commit')) {
    if (Test-Path "$proj\.git\hooks\$h") { Write-Host "hook ok: $h" } else { Write-Host "HOOK MISSING: $h" -ForegroundColor Red; $script:fail++ }
}

# --- a passing scan event is what stage 4/7 read (no full scan is run)
New-Item -ItemType Directory -Force -Path "$proj\.harness\metrics" | Out-Null
$ts = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
Add-Content -LiteralPath "$proj\.harness\metrics\gate.jsonl" -Value ('{"event":"scan","ts":"' + $ts + '","blocked":0,"files":1,"hunks":1}') -Encoding UTF8

# --- fill the real template exactly as an agent would
Step 'fill summary from template'
$tpl = Get-Content "$pkg\assets\.harness\changes\_template\summary.md" -Raw -Encoding UTF8
$tpl = $tpl -replace 'YYYY-MM-DD', (Get-Date -Format 'yyyy-MM-dd')
$tpl = $tpl -replace '(?m)(?<![A-Za-z0-9_\-])impl_corrections:[^\r\n]*', 'impl_corrections: 0'
$tpl = $tpl -replace '(?m)(?<![A-Za-z0-9_\-])corrections:[^\r\n]*', 'corrections: 1'
$tpl = $tpl -replace '(?m)(?<![A-Za-z0-9_\-])loaded_skills:[^\r\n]*', 'loaded_skills: request-analysis, coding-skill'
$tpl = $tpl -replace '(?m)(?<![A-Za-z0-9_\-])load_skip_reason:[^\r\n]*', 'load_skip_reason: n/a'
$tpl = $tpl -replace '(?m)(?<![A-Za-z0-9_\-])touched_modules:[^\r\n]*', 'touched_modules: demo'
$tpl = $tpl -replace '(?m)(?<![A-Za-z0-9_\-])flow:[^\r\n]*', 'flow: L2'
$tpl = $tpl -replace '(?m)(?<![A-Za-z0-9_\-])lesson_id:[^\r\n]*', 'lesson_id: demo-lesson'
$tpl = $tpl -replace '(?m)(?<![A-Za-z0-9_\-])sql_review:[^\r\n]*', 'sql_review: no SQL change'
# A3+ needs a conclusion: fill the shortfall section (none markers are legal)
$tpl = $tpl -replace '(?m)^- 本次暴露的短板：[^\r\n]*', '- 本次暴露的短板：无'
$tpl = $tpl -replace '(?m)^- 已补的能力：[^\r\n]*', '- 已补的能力：无'
# initial checks the three content sections: a filled field block alone is not
# an analysis, so the fixture must fill them like a real one would.
$tpl = $tpl -replace '(?m)^\| F1 \|.*$', '| F1 | demo feature | returns 200 | no retries |'
$tpl = $tpl -replace '(?m)^- 受影响模块：.*$', '- 受影响模块：demo'
$tpl = $tpl -replace '(?m)^- 用户影响范围：.*$', '- 用户影响范围：none'
$tpl = $tpl -replace '(?m)^- 与已有特性的关系：.*$', '- 与已有特性的关系：none'
$tpl = $tpl -replace '(?m)^\| 1 \|.*$', '| 1 | write the code | - | 1h |'
Set-Content -LiteralPath "$proj\.harness\changes\demo\summary.md" -Value $tpl -Encoding UTF8

Step 'check-summary initial / final'
& powershell -NoProfile -ExecutionPolicy Bypass -File "$proj\scripts\check-summary.ps1" -Root $proj -Feature demo -Stage initial
if ($LASTEXITCODE -ne 0) { Write-Host "INITIAL FAILED" -ForegroundColor Red; $script:fail++ }
& powershell -NoProfile -ExecutionPolicy Bypass -File "$proj\scripts\check-summary.ps1" -Root $proj -Feature demo -Stage final
if ($LASTEXITCODE -ne 0) { Write-Host "FINAL FAILED" -ForegroundColor Red; $script:fail++ }

Step 'initial validates content, not the close-out counts'
# The failure this guards: every field filled, the three content sections still
# templates. That summary used to pass and let coding start with no acceptance
# criteria at all.
$badDir = Join-Path $proj '.harness\changes\bad-content'
New-Item -ItemType Directory -Force -Path $badDir | Out-Null
$bad = Get-Content "$pkg\assets\.harness\changes\_template\summary.md" -Raw -Encoding UTF8
$bad = $bad -replace 'YYYY-MM-DD', (Get-Date -Format 'yyyy-MM-dd')
$bad = $bad -replace '(?m)(?<![A-Za-z0-9_\-])loaded_skills:[^\r\n]*', 'loaded_skills: request-analysis'
$bad = $bad -replace '(?m)(?<![A-Za-z0-9_\-])touched_modules:[^\r\n]*', 'touched_modules: demo'
$bad = $bad -replace '(?m)(?<![A-Za-z0-9_\-])flow:[^\r\n]*', 'flow: L2'
Set-Content -LiteralPath (Join-Path $badDir 'summary.md') -Value $bad -Encoding UTF8
& powershell -NoProfile -ExecutionPolicy Bypass -File "$proj\scripts\check-summary.ps1" -Root $proj -File (Join-Path $badDir 'summary.md') -Stage initial | Out-Null
if ($LASTEXITCODE -eq 0) { Write-Host "INITIAL ACCEPTED A SUMMARY WITH PLACEHOLDER CONTENT" -ForegroundColor Red; $script:fail++ }

# Corrections are only knowable at close-out, so their absence must not block
# the initial stage (it did before, which forced a fake "corrections: 0").
$noCounts = $tpl -replace '(?m)(?<![A-Za-z0-9_\-])corrections:[^\r\n]*', '' -replace '(?m)(?<![A-Za-z0-9_\-])impl_corrections:[^\r\n]*', ''
$countDir = Join-Path $proj '.harness\changes\no-counts'
New-Item -ItemType Directory -Force -Path $countDir | Out-Null
Set-Content -LiteralPath (Join-Path $countDir 'summary.md') -Value $noCounts -Encoding UTF8
& powershell -NoProfile -ExecutionPolicy Bypass -File "$proj\scripts\check-summary.ps1" -Root $proj -File (Join-Path $countDir 'summary.md') -Stage initial | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host "INITIAL REJECTED A SUMMARY WITHOUT CLOSE-OUT COUNTS" -ForegroundColor Red; $script:fail++ }
& powershell -NoProfile -ExecutionPolicy Bypass -File "$proj\scripts\check-summary.ps1" -Root $proj -File (Join-Path $countDir 'summary.md') -Stage final | Out-Null
if ($LASTEXITCODE -eq 0) { Write-Host "FINAL ACCEPTED A SUMMARY WITHOUT CLOSE-OUT COUNTS" -ForegroundColor Red; $script:fail++ }
# These two fixtures are probes, not tasks: leaving them in .harness/changes
# would add demo-lesson to the lesson counter and break stage 10 below.
Remove-Item -LiteralPath $badDir, $countDir -Recurse -Force

Step 'stage-gate -All'
& powershell -NoProfile -ExecutionPolicy Bypass -File "$proj\scripts\stage-gate.ps1" -Root $proj -All -Feature demo
if ($LASTEXITCODE -ne 0) { Write-Host "STAGE GATE FAILED" -ForegroundColor Red; $script:fail++ }

Step 'metrics -Days 14 -Compare'
& powershell -NoProfile -ExecutionPolicy Bypass -File "$proj\scripts\metrics.ps1" -Root $proj -Days 14 -Compare
if ($LASTEXITCODE -ne 0) { Write-Host "METRICS FAILED" -ForegroundColor Red; $script:fail++ }

Step '_small.md L1 row is counted and lessons.md is generated'
$smallDate = Get-Date -Format 'yyyy-MM-dd'
$small = @(
    '| 日期 | 特性 | 档位 | 加载技能 | 纠正 | 实现纠正 | 教训 | 触及模块 | 说明 |',
    '| --- | --- | --- | --- | --- | --- | --- | --- | --- |',
    ('| {0} | small-demo | L1 | none | 1 | 0 | small-lesson -- 小改 | demo | 小改 |' -f $smallDate)
) -join "`r`n"
Set-Content -LiteralPath "$proj\.harness\changes\_small.md" -Value $small -Encoding UTF8
$m = & powershell -NoProfile -ExecutionPolicy Bypass -File "$proj\scripts\metrics.ps1" -Root $proj -Days 14 -Json | Out-String
$j = $m | ConvertFrom-Json
if ($j.tasks -ne 2) { Write-Host "SMALL RECORD NOT COUNTED: tasks=$($j.tasks)" -ForegroundColor Red; $script:fail++ }
if (-not $j.lessons.'small-lesson') { Write-Host "SMALL LESSON NOT COUNTED" -ForegroundColor Red; $script:fail++ }
$idx = Get-Content "$proj\.harness\lessons.md" -Raw -Encoding UTF8
if ($idx -notmatch 'small-lesson') { Write-Host "LESSONS INDEX MISSING small-lesson" -ForegroundColor Red; $script:fail++ }

Step '_small.md malformed rows are reported, not silently dropped'
Add-Content -LiteralPath "$proj\.harness\changes\_small.md" -Value @(
    '| | broken | L1 | none | 1 | 0 | bad | demo | short |',
    '| 2026-11-05 | short | L1 | none | 1 | 0 |'
) -Encoding UTF8
$m2 = & powershell -NoProfile -ExecutionPolicy Bypass -File "$proj\scripts\metrics.ps1" -Root $proj -Days 14 -Json | Out-String
$j2 = $m2 | ConvertFrom-Json
if ($j2.smallRecordErrors -lt 1) { Write-Host "MALFORMED SMALL ROWS NOT REPORTED" -ForegroundColor Red; $script:fail++ }
if ($j2.tasks -ne 2) { Write-Host "MALFORMED SMALL ROWS CHANGED task count: $($j2.tasks)" -ForegroundColor Red; $script:fail++ }
if (($j2.verdict -join "`n") -notmatch 'malformed') { Write-Host "MALFORMED SMALL ROWS NOT IN VERDICT" -ForegroundColor Red; $script:fail++ }

Step 'lesson gate: a repeated lesson must become a check'
Add-Content -LiteralPath "$proj\.harness\changes\_small.md" -Value @(
    ('| {0} | dup-a | L1 | none | 1 | 0 | dup-lesson -- first | demo | a |' -f $smallDate),
    ('| {0} | dup-b | L1 | none | 1 | 0 | dup-lesson -- second | demo | b |' -f $smallDate)
) -Encoding UTF8
& powershell -NoProfile -ExecutionPolicy Bypass -File "$proj\scripts\metrics.ps1" -Root $proj -LessonGate | Out-Null
if ($LASTEXITCODE -eq 0) { Write-Host "LESSON GATE ACCEPTED A REPEATED LESSON WITHOUT A CHECK" -ForegroundColor Red; $script:fail++ }
# Existence is not relevance: the check file must name the lesson it covers.
Set-Content -LiteralPath "$proj\scripts\check-dup.ps1" -Value @('# lesson: dup-lesson', '# fails-when: a summary records the same lesson id twice and this suite must exit 1', 'exit 0') -Encoding ASCII
Add-Content -LiteralPath "$proj\.harness\lessons-promoted.txt" -Value 'dup-lesson :: check=scripts/check-dup.ps1::duplicate lesson blocked' -Encoding UTF8
& powershell -NoProfile -ExecutionPolicy Bypass -File "$proj\scripts\metrics.ps1" -Root $proj -LessonGate | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host "LESSON GATE REJECTED A REGISTERED CHECK" -ForegroundColor Red; $script:fail++ }
# A check that never mentions the id is an unrelated script, not evidence.
$lp = Get-Content "$proj\.harness\lessons-promoted.txt" -Raw -Encoding UTF8
$lpWrong = $lp -replace 'check=scripts/check-dup\.ps1', 'check=scripts/red-line-scan.ps1'
Set-Content -LiteralPath "$proj\.harness\lessons-promoted.txt" -Value $lpWrong.TrimEnd() -Encoding UTF8
& powershell -NoProfile -ExecutionPolicy Bypass -File "$proj\scripts\metrics.ps1" -Root $proj -LessonGate | Out-Null
if ($LASTEXITCODE -eq 0) { Write-Host "LESSON GATE ACCEPTED A CHECK THAT DOES NOT NAME THE LESSON" -ForegroundColor Red; $script:fail++ }
# Naming the lesson is not enough either: the check must declare what makes it red.
Set-Content -LiteralPath "$proj\scripts\check-dup.ps1" -Value @('# lesson: dup-lesson', 'exit 0') -Encoding ASCII
& powershell -NoProfile -ExecutionPolicy Bypass -File "$proj\scripts\metrics.ps1" -Root $proj -LessonGate | Out-Null
if ($LASTEXITCODE -eq 0) { Write-Host "LESSON GATE ACCEPTED A CHECK WITHOUT fails-when" -ForegroundColor Red; $script:fail++ }
Set-Content -LiteralPath "$proj\scripts\check-dup.ps1" -Value @('# lesson: dup-lesson', '# fails-when: a summary records the same lesson id twice and this suite must exit 1', 'exit 0') -Encoding ASCII
# A promoted lesson that points at a file which does not exist is not evidence.
$lp = $lp -replace 'check=scripts/check-dup\.ps1', 'check=scripts/does-not-exist.ps1'
Set-Content -LiteralPath "$proj\.harness\lessons-promoted.txt" -Value $lp.TrimEnd() -Encoding UTF8
& powershell -NoProfile -ExecutionPolicy Bypass -File "$proj\scripts\metrics.ps1" -Root $proj -LessonGate | Out-Null
if ($LASTEXITCODE -eq 0) { Write-Host "LESSON GATE ACCEPTED A MISSING CHECK FILE" -ForegroundColor Red; $script:fail++ }
# A doc or a directory proves nothing; only an executable check counts.
foreach ($bad in @('.harness/lessons.md', '.harness')) {
    $lp = $lp -replace 'check=scripts/check-dup\.ps1', ('check=' + $bad)
    Set-Content -LiteralPath "$proj\.harness\lessons-promoted.txt" -Value $lp.TrimEnd() -Encoding UTF8
    & powershell -NoProfile -ExecutionPolicy Bypass -File "$proj\scripts\metrics.ps1" -Root $proj -LessonGate | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-Host ("LESSON GATE ACCEPTED A NON-EXECUTABLE CHECK: " + $bad) -ForegroundColor Red; $script:fail++ }
    $lp = $lp -replace ('check=' + [regex]::Escape($bad)), 'check=scripts/check-dup.ps1'
}
Set-Content -LiteralPath "$proj\.harness\lessons-promoted.txt" -Value $lp.TrimEnd() -Encoding UTF8

Step 'sql_review: a pass verdict cannot hide unverified layers'
$sumPath = "$proj\.harness\changes\demo\summary.md"
$sumOrig = Get-Content -LiteralPath $sumPath -Raw -Encoding UTF8
function Set-SqlReview {
    param([string]$Value)
    $t = $sumOrig -replace '(?m)(?<![A-Za-z0-9_\-])sql_review:[^\r\n]*', $Value
    Set-Content -LiteralPath $sumPath -Value $t -Encoding UTF8
}
Set-SqlReview 'sql_review: demo.t · 语法 未验证(no sandbox) · 结构 未验证 · 绑定 未验证 · 结果 未验证 · 计划 未跑 · 结论 通过'
& powershell -NoProfile -ExecutionPolicy Bypass -File "$proj\scripts\check-summary.ps1" -Root $proj -Feature demo -Stage final | Out-Null
if ($LASTEXITCODE -eq 0) { Write-Host "CONTRADICTORY SQL REVIEW ACCEPTED" -ForegroundColor Red; $script:fail++ }
Set-SqlReview 'sql_review: demo.t · 语法 OK · 结构 OK · 绑定 #{} · 结果 已验(fixture) · 计划 type=ref · 结论 通过'
& powershell -NoProfile -ExecutionPolicy Bypass -File "$proj\scripts\check-summary.ps1" -Root $proj -Feature demo -Stage final | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host "CONSISTENT SQL REVIEW REJECTED" -ForegroundColor Red; $script:fail++ }
# A cited evidence path is a claim: it must exist on disk.
Set-SqlReview 'sql_review: demo.t · 语法 OK · 结构 OK · 绑定 #{} · 结果 已验(.harness/changes/demo/sql-review/missing.txt) · 计划 未跑 · 结论 待 DBA'
& powershell -NoProfile -ExecutionPolicy Bypass -File "$proj\scripts\check-summary.ps1" -Root $proj -Feature demo -Stage final | Out-Null
if ($LASTEXITCODE -eq 0) { Write-Host "MISSING SQL EVIDENCE ACCEPTED" -ForegroundColor Red; $script:fail++ }
# The review may only use data sources the compiled skill declares.
$skillDir = "$proj\.harness\skills\biz-dev\14-sql-review"
New-Item -ItemType Directory -Force -Path $skillDir | Out-Null
$skillText = @(
    '---', 'name: sql-review', 'description: fixture', '---', '',
    '# sql', '',
    '- 数据源与方言（Oracle / MySQL）：oracle_main / his_mssql'
) -join "`r`n"
Set-Content -LiteralPath "$skillDir\SKILL.md" -Value $skillText -Encoding UTF8
Set-SqlReview 'sql_review: THIRD_ORACLE.v_mz_hzcfxx · 语法 OK · 结构 OK · 绑定 #{} · 结果 已验(fixture) · 计划 未跑 · 结论 待 DBA'
& powershell -NoProfile -ExecutionPolicy Bypass -File "$proj\scripts\check-summary.ps1" -Root $proj -Feature demo -Stage final | Out-Null
if ($LASTEXITCODE -eq 0) { Write-Host "UNDECLARED DATA SOURCE ACCEPTED" -ForegroundColor Red; $script:fail++ }
$skillText2 = $skillText -replace 'oracle_main / his_mssql', 'oracle_main / his_mssql / THIRD_ORACLE'
Set-Content -LiteralPath "$skillDir\SKILL.md" -Value $skillText2 -Encoding UTF8
& powershell -NoProfile -ExecutionPolicy Bypass -File "$proj\scripts\check-summary.ps1" -Root $proj -Feature demo -Stage final | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host "DECLARED DATA SOURCE REJECTED" -ForegroundColor Red; $script:fail++ }
Remove-Item -LiteralPath $skillDir -Recurse -Force
Set-Content -LiteralPath $sumPath -Value $sumOrig -Encoding UTF8

Step 'A3+ spoof must fail'
$s = Get-Content "$proj\.harness\changes\demo\summary.md" -Raw -Encoding UTF8
$s2 = $s -replace '(?ms)^## 待补短板\r?\n.*?(?=\r?\n## )', ''
$s2 = $s2 + "`r`n待补短板一节省略，结论已写在别处。`r`n"
Set-Content -LiteralPath "$proj\.harness\changes\demo\summary.md" -Value $s2 -Encoding UTF8
& powershell -NoProfile -ExecutionPolicy Bypass -File "$proj\scripts\stage-gate.ps1" -Root $proj -Stage 6 -Feature demo | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host "spoof correctly rejected" } else { Write-Host "SPOOF ACCEPTED" -ForegroundColor Red; $script:fail++ }

Step 'uninstall removes all three hooks'
& powershell -NoProfile -ExecutionPolicy Bypass -File "$proj\scripts\uninstall-harness.ps1" -Root $proj | Out-Null
foreach ($h in @('pre-commit','post-commit','pre-merge-commit')) {
    if (Test-Path "$proj\.git\hooks\$h") { Write-Host "NOT REMOVED: $h" -ForegroundColor Red; $script:fail++ }
    else { Write-Host "removed ok: $h" }
}

Write-Host ""
if ($fail -eq 0) { Write-Host "REGRESSION OK" -ForegroundColor Green; exit 0 }
Write-Host "REGRESSION FAILURES: $fail" -ForegroundColor Red
exit 1
