param([string]$TestRoot = '')
$ErrorActionPreference = 'Stop'
if (-not $TestRoot) {
    $TestRoot = Join-Path $env:TEMP ('hb-tests-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '\regression')
}
$pkg  = Split-Path -Parent $PSScriptRoot
$proj = Join-Path $TestRoot 'proj2'
$fail = 0
. (Join-Path $PSScriptRoot 'test-lib.ps1')

function Step([string]$Name) { Write-Host ""; Write-Host "=== $Name ===" -ForegroundColor Cyan }

if (Test-Path -LiteralPath $TestRoot) { Remove-Item -LiteralPath $TestRoot -Recurse -Force }
New-Item -ItemType Directory -Force -Path $TestRoot | Out-Null
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

# --- the shipped template must not carry a stray garbage line. Read it as
# UTF-8 (the file has Chinese text) and assert the junk string is gone, so a
# bad edit cannot ride into a release again.
Step 'coding-skill template carries no stray garbage line'
$codingSkill = [System.IO.File]::ReadAllText("$pkg\assets\.harness\skills\main-dev\coding-skill\SKILL.md", [System.Text.Encoding]::UTF8)
if ($codingSkill.Contains('lk;l')) { Write-Host "CODING-SKILL TEMPLATE CONTAINS A STRAY 'lk;l' LINE" -ForegroundColor Red; $script:fail++ }

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
# The review ledger is strict on a fresh install: fill the reviewer, the six
# dimensions and replace the placeholder row with the no-issue row.
$tpl = $tpl -replace '(?m)^- 评审人：[^\r\n]*', '- 评审人：expert-reviewer'
$tpl = $tpl -replace '(?m)^- 六维结论：[^\r\n]*', '- 六维结论：结构 通过 / 红线 通过 / 性能 通过 / 安全 通过 / 一致性 通过 / 可测性 通过'
$tpl = $tpl -replace '(?m)^\| `<P0/P1/P2>` \|.*$', '| - | - | 不适用 | - | 本次评审未发现问题 | 六维结论见上 | - |'
# initial checks the three content sections: a filled field block alone is not
# an analysis, so the fixture must fill them like a real one would.
$tpl = $tpl -replace '(?m)^\| F1 \|.*$', '| F1 | demo feature | returns 200 | no retries |'
$tpl = $tpl -replace '(?m)^- 受影响模块：.*$', '- 受影响模块：demo'
$tpl = $tpl -replace '(?m)^- 用户影响范围：.*$', '- 用户影响范围：none'
$tpl = $tpl -replace '(?m)^- 与已有特性的关系：.*$', '- 与已有特性的关系：none'
$tpl = $tpl -replace '(?m)^\| 1 \|.*$', '| 1 | write the code | - | 1h |'
Set-Content -LiteralPath "$proj\.harness\changes\demo\summary.md" -Value $tpl -Encoding UTF8

Step 'check-summary initial / final'
# CLI parity: the first run keeps a real -File call, and the in-process run of
# the same input must agree on the exit code.
& powershell -NoProfile -ExecutionPolicy Bypass -File "$proj\scripts\check-summary.ps1" -Root $proj -Feature demo -Stage initial
if ($LASTEXITCODE -ne 0) { Write-Host "INITIAL FAILED" -ForegroundColor Red; $script:fail++ }
$cliInitialCode = $LASTEXITCODE
Invoke-Harness "$proj\scripts\check-summary.ps1" @{ Root = $proj; Feature = 'demo'; Stage = 'initial' } | Out-Null
if ($LASTEXITCODE -ne $cliInitialCode) { Write-Host "IN-PROCESS INITIAL DISAGREES WITH -File" -ForegroundColor Red; $script:fail++ }
Invoke-Harness "$proj\scripts\check-summary.ps1" @{ Root = $proj; Feature = 'demo'; Stage = 'final' } | Out-Null
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
Invoke-Harness "$proj\scripts\check-summary.ps1" @{ Root = $proj; File = (Join-Path $badDir 'summary.md'); Stage = 'initial' } | Out-Null
if ($LASTEXITCODE -eq 0) { Write-Host "INITIAL ACCEPTED A SUMMARY WITH PLACEHOLDER CONTENT" -ForegroundColor Red; $script:fail++ }

# Corrections are only knowable at close-out, so their absence must not block
# the initial stage (it did before, which forced a fake "corrections: 0").
$noCounts = $tpl -replace '(?m)(?<![A-Za-z0-9_\-])corrections:[^\r\n]*', '' -replace '(?m)(?<![A-Za-z0-9_\-])impl_corrections:[^\r\n]*', ''
$countDir = Join-Path $proj '.harness\changes\no-counts'
New-Item -ItemType Directory -Force -Path $countDir | Out-Null
Set-Content -LiteralPath (Join-Path $countDir 'summary.md') -Value $noCounts -Encoding UTF8
Invoke-Harness "$proj\scripts\check-summary.ps1" @{ Root = $proj; File = (Join-Path $countDir 'summary.md'); Stage = 'initial' } | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host "INITIAL REJECTED A SUMMARY WITHOUT CLOSE-OUT COUNTS" -ForegroundColor Red; $script:fail++ }
Invoke-Harness "$proj\scripts\check-summary.ps1" @{ Root = $proj; File = (Join-Path $countDir 'summary.md'); Stage = 'final' } | Out-Null
if ($LASTEXITCODE -eq 0) { Write-Host "FINAL ACCEPTED A SUMMARY WITHOUT CLOSE-OUT COUNTS" -ForegroundColor Red; $script:fail++ }
# These two fixtures are probes, not tasks: leaving them in .harness/changes
# would add demo-lesson to the lesson counter and break stage 10 below.
Remove-Item -LiteralPath $badDir, $countDir -Recurse -Force

Step 'stage-gate -All'
Invoke-Harness "$proj\scripts\stage-gate.ps1" @{ Root = $proj; All = $true; Feature = 'demo' } | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host "STAGE GATE FAILED" -ForegroundColor Red; $script:fail++ }

Step 'metrics -Days 14 -Compare'
Invoke-Harness "$proj\scripts\metrics.ps1" @{ Root = $proj; Days = 14; Compare = $true } | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host "METRICS FAILED" -ForegroundColor Red; $script:fail++ }

Step 'assoc_skip events are counted and the ignored case is called out'
# The pre-commit hook writes assoc_skip when a source commit cannot be tied to a
# record. Two reasons look identical in a raw log but mean opposite things:
# "not-committed" is the legal first adoption, "ignored" means the gate is off.
$gateLog = "$proj\.harness\metrics\gate.jsonl"
# Local time, no "Z": a UTC suffix shifts the date forward by the offset and the
# event falls outside today's exclusive window.
$tsNow = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
$evt = @(
    ('{"event":"assoc_skip","ts":"' + $tsNow + '","reason":"ignored"}'),
    ('{"event":"assoc_skip","ts":"' + $tsNow + '","reason":"not-committed"}')
) -join "`r`n"
[System.IO.File]::AppendAllText($gateLog, $evt + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
$mj = Invoke-Harness "$proj\scripts\metrics.ps1" @{ Root = $proj; Days = 14; Json = $true } | Out-String
$jj = $mj | ConvertFrom-Json
if ($jj.attributionSkipped -ne 2) { Write-Host "ASSOC SKIP NOT COUNTED: $($jj.attributionSkipped)" -ForegroundColor Red; $script:fail++ }
if ($jj.attributionSkippedIgnored -ne 1) { Write-Host "IGNORED SUBTYPE NOT COUNTED: $($jj.attributionSkippedIgnored)" -ForegroundColor Red; $script:fail++ }
$mt = Invoke-Harness "$proj\scripts\metrics.ps1" @{ Root = $proj; Days = 14 } | Out-String
if ($mt -notmatch 'attribution skipped: 2 \(ignored \.harness: 1\)') { Write-Host "ATTRIBUTION LINE MISSING" -ForegroundColor Red; $script:fail++ }
if ($mt -notmatch 'ignored: the gate is off by accident') { Write-Host "IGNORED VERDICT MISSING" -ForegroundColor Red; $script:fail++ }

Step '_small.md L1 row is counted and lessons.md is generated'
$smallDate = Get-Date -Format 'yyyy-MM-dd'
$small = @(
    '| 日期 | 特性 | 档位 | 加载技能 | 纠正 | 实现纠正 | 教训 | 触及模块 | 说明 |',
    '| --- | --- | --- | --- | --- | --- | --- | --- | --- |',
    ('| {0} | small-demo | L1 | none | 1 | 0 | small-lesson -- 小改 | demo | 小改 |' -f $smallDate)
) -join "`r`n"
Set-Content -LiteralPath "$proj\.harness\changes\_small.md" -Value $small -Encoding UTF8
$m = Invoke-Harness "$proj\scripts\metrics.ps1" @{ Root = $proj; Days = 14; Json = $true } | Out-String
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
$m2 = Invoke-Harness "$proj\scripts\metrics.ps1" @{ Root = $proj; Days = 14; Json = $true } | Out-String
$j2 = $m2 | ConvertFrom-Json
if ($j2.smallRecordErrors -lt 1) { Write-Host "MALFORMED SMALL ROWS NOT REPORTED" -ForegroundColor Red; $script:fail++ }
if ($j2.tasks -ne 2) { Write-Host "MALFORMED SMALL ROWS CHANGED task count: $($j2.tasks)" -ForegroundColor Red; $script:fail++ }
if (($j2.verdict -join "`n") -notmatch 'malformed') { Write-Host "MALFORMED SMALL ROWS NOT IN VERDICT" -ForegroundColor Red; $script:fail++ }

Step 'review ledger: severity, fingerprint and close-out rules'
# The review table is the machine-readable half of stage 6. Each probe rewrites
# the no-issue row of the filled template, so the rest of the summary stays valid.
$reviewDir = Join-Path $proj '.harness\changes\review-probe'
function Set-ReviewProbe {
    param([string]$Rows)
    New-Item -ItemType Directory -Force -Path $reviewDir | Out-Null
    $t = $tpl -replace '(?m)^\| - \| - \| 不适用 \|.*$', $Rows
    Set-Content -LiteralPath (Join-Path $reviewDir 'summary.md') -Value $t -Encoding UTF8
}
function Invoke-ReviewProbe {
    param([string]$ProbeStage)
    Invoke-Harness "$proj\scripts\check-summary.ps1" @{ Root = $proj; File = (Join-Path $reviewDir 'summary.md'); Stage = $ProbeStage } | Out-Null
    return $LASTEXITCODE
}

$okP1 = '| P1 | 本次 | 已修 | demo-review | demo issue | demo.java:1 | fixed |'
Set-ReviewProbe $okP1
if ((Invoke-ReviewProbe 'review') -ne 0) { Write-Host "REVIEW REJECTED A VALID P1 ROW" -ForegroundColor Red; $script:fail++ }
if ((Invoke-ReviewProbe 'final') -ne 0) { Write-Host "FINAL REJECTED A CLOSED P1 ROW" -ForegroundColor Red; $script:fail++ }

# P0 without a fingerprint is not actionable.
Set-ReviewProbe '| P0 | 本次 | 已修 | - | p0 without fingerprint | demo.java:2 | fixed |'
if ((Invoke-ReviewProbe 'review') -eq 0) { Write-Host "P0 WITHOUT A FINGERPRINT ACCEPTED" -ForegroundColor Red; $script:fail++ }

# 未修 is legal at review time, illegal at close-out.
Set-ReviewProbe '| P0 | 本次 | 未修 | demo-p0 | p0 open | demo.java:3 | pending |'
if ((Invoke-ReviewProbe 'review') -ne 0) { Write-Host "REVIEW REJECTED A NOT-YET-FIXED ROW" -ForegroundColor Red; $script:fail++ }
if ((Invoke-ReviewProbe 'final') -eq 0) { Write-Host "FINAL ACCEPTED A P0 THAT IS STILL OPEN" -ForegroundColor Red; $script:fail++ }

# A P0 cannot be deferred.
Set-ReviewProbe '| P0 | 本次 | 转待办 | demo-p0 | p0 deferred | demo.java:3 | later |'
if ((Invoke-ReviewProbe 'final') -eq 0) { Write-Host "FINAL ACCEPTED A DEFERRED P0" -ForegroundColor Red; $script:fail++ }

# P1 may be deferred, but only with a disposition.
Set-ReviewProbe '| P1 | 本次 | 转待办 | demo-p1 | p1 deferred | demo.java:4 |  |'
if ((Invoke-ReviewProbe 'final') -eq 0) { Write-Host "DEFERRED P1 WITHOUT A DISPOSITION ACCEPTED" -ForegroundColor Red; $script:fail++ }

# Unknown severity and a wrong column count are format errors, strict or not.
Set-ReviewProbe '| P9 | 本次 | 已修 | demo-p9 | bad severity | demo.java:5 | fixed |'
if ((Invoke-ReviewProbe 'review') -eq 0) { Write-Host "UNKNOWN SEVERITY ACCEPTED" -ForegroundColor Red; $script:fail++ }
Set-ReviewProbe '| P1 | 本次 | 已修 | demo-cols | six columns | demo.java:6 |'
if ((Invoke-ReviewProbe 'review') -eq 0) { Write-Host "SIX-COLUMN ROW ACCEPTED" -ForegroundColor Red; $script:fail++ }

# A row without a problem statement is not a finding; a blank no-issue row is
# the same self-report the table exists to prevent.
Set-ReviewProbe '| P1 | 本次 | 已修 | demo-empty-problem |  | demo.java:7 | fixed |'
if ((Invoke-ReviewProbe 'review') -eq 0) { Write-Host "EMPTY PROBLEM ACCEPTED" -ForegroundColor Red; $script:fail++ }
Set-ReviewProbe '| - | - | 不适用 | - |  |  | - |'
if ((Invoke-ReviewProbe 'review') -eq 0) { Write-Host "EMPTY NO-ISSUE ROW ACCEPTED" -ForegroundColor Red; $script:fail++ }

# Strict=true (fresh install) rejects a missing table; strict=false only warns.
$noTable = $tpl
$noTable = $noTable -replace '(?m)^\| 严重度 \| 范围 \|.*$', ''
$noTable = $noTable -replace '(?m)^\| --- \| --- \| --- \| --- \| --- \| --- \| --- \|$', ''
$noTable = $noTable -replace '(?m)^\| - \| - \| 不适用 \|.*$', ''
New-Item -ItemType Directory -Force -Path $reviewDir | Out-Null
Set-Content -LiteralPath (Join-Path $reviewDir 'summary.md') -Value $noTable -Encoding UTF8
if ((Invoke-ReviewProbe 'review') -eq 0) { Write-Host "STRICT MODE ACCEPTED A MISSING REVIEW TABLE" -ForegroundColor Red; $script:fail++ }

$cfgFile = "$proj\scripts\harness-required.json"
$cfgText = [System.IO.File]::ReadAllText($cfgFile, [System.Text.Encoding]::UTF8)
$cfgLoose = $cfgText | ConvertFrom-Json
$cfgLoose.reviewLedgerStrict = $false
[System.IO.File]::WriteAllText($cfgFile, (($cfgLoose | ConvertTo-Json -Depth 10) + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
$looseCode = Invoke-ReviewProbe 'review'
$looseOut = Invoke-Harness "$proj\scripts\check-summary.ps1" @{ Root = $proj; File = (Join-Path $reviewDir 'summary.md'); Stage = 'review' } | Out-String
$cfgLoose.reviewLedgerStrict = $true
[System.IO.File]::WriteAllText($cfgFile, (($cfgLoose | ConvertTo-Json -Depth 10) + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
if ($looseCode -ne 0) { Write-Host "NON-STRICT MODE REJECTED A MISSING REVIEW TABLE" -ForegroundColor Red; $script:fail++ }
if ($looseOut -notmatch '\[WARN\] review_ledger') { Write-Host "NON-STRICT MODE DID NOT WARN" -ForegroundColor Red; $script:fail++ }

# L1 has no summary; the review stage must skip it.
$l1Text = $noTable -replace '(?m)(?<![A-Za-z0-9_\-])flow:[^\r\n]*', 'flow: L1'
Set-Content -LiteralPath (Join-Path $reviewDir 'summary.md') -Value $l1Text -Encoding UTF8
if ((Invoke-ReviewProbe 'review') -ne 0) { Write-Host "L1 WAS NOT SKIPPED BY THE REVIEW STAGE" -ForegroundColor Red; $script:fail++ }
Remove-Item -LiteralPath $reviewDir -Recurse -Force

Step 'reviews.md aggregates the same fingerprint across tasks'
$aggRow = '| P1 | 本次 | 已修 | demo-recurring | repeated finding | demo.java:1 | fixed |'
foreach ($name in @('review-agg-a', 'review-agg-b')) {
    $d = Join-Path $proj ('.harness\changes\' + $name)
    New-Item -ItemType Directory -Force -Path $d | Out-Null
    $t = $tpl -replace '(?m)^\| - \| - \| 不适用 \|.*$', $aggRow
    Set-Content -LiteralPath (Join-Path $d 'summary.md') -Value $t -Encoding UTF8
}
$aggJson = Invoke-Harness "$proj\scripts\metrics.ps1" @{ Root = $proj; Days = 14; Json = $true } | Out-String
$aj = $aggJson | ConvertFrom-Json
if ($aj.reviewTotals.P1 -lt 2) { Write-Host "REVIEW TOTALS NOT COUNTED: $($aj.reviewTotals.P1)" -ForegroundColor Red; $script:fail++ }
$rv = Get-Content "$proj\.harness\reviews.md" -Raw -Encoding UTF8
if ($rv -notmatch 'demo-recurring') { Write-Host "REVIEWS INDEX MISSING THE FINGERPRINT" -ForegroundColor Red; $script:fail++ }
if ($rv -notmatch '\|\s*P1\s*\|\s*promote\s*\|\s*2\s*\|') { Write-Host "REVIEWS INDEX DID NOT MARK THE FINDING AS PROMOTE x2" -ForegroundColor Red; $script:fail++ }
Remove-Item -LiteralPath (Join-Path $proj '.harness\changes\review-agg-a'), (Join-Path $proj '.harness\changes\review-agg-b') -Recurse -Force

Step 'lesson gate: a repeated lesson must become a check'
Add-Content -LiteralPath "$proj\.harness\changes\_small.md" -Value @(
    ('| {0} | dup-a | L1 | none | 1 | 0 | dup-lesson -- first | demo | a |' -f $smallDate),
    ('| {0} | dup-b | L1 | none | 1 | 0 | dup-lesson -- second | demo | b |' -f $smallDate)
) -Encoding UTF8
Invoke-Harness "$proj\scripts\metrics.ps1" @{ Root = $proj; LessonGate = $true } | Out-Null
if ($LASTEXITCODE -eq 0) { Write-Host "LESSON GATE ACCEPTED A REPEATED LESSON WITHOUT A CHECK" -ForegroundColor Red; $script:fail++ }
# Existence is not relevance: the check file must name the lesson it covers.
Set-Content -LiteralPath "$proj\scripts\check-dup.ps1" -Value @('# lesson: dup-lesson', '# fails-when: a summary records the same lesson id twice and this suite must exit 1', 'exit 0') -Encoding ASCII
Add-Content -LiteralPath "$proj\.harness\lessons-promoted.txt" -Value 'dup-lesson :: check=scripts/check-dup.ps1::duplicate lesson blocked' -Encoding UTF8
Invoke-Harness "$proj\scripts\metrics.ps1" @{ Root = $proj; LessonGate = $true } | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host "LESSON GATE REJECTED A REGISTERED CHECK" -ForegroundColor Red; $script:fail++ }
# A check that never mentions the id is an unrelated script, not evidence.
$lp = Get-Content "$proj\.harness\lessons-promoted.txt" -Raw -Encoding UTF8
$lpWrong = $lp -replace 'check=scripts/check-dup\.ps1', 'check=scripts/red-line-scan.ps1'
Set-Content -LiteralPath "$proj\.harness\lessons-promoted.txt" -Value $lpWrong.TrimEnd() -Encoding UTF8
Invoke-Harness "$proj\scripts\metrics.ps1" @{ Root = $proj; LessonGate = $true } | Out-Null
if ($LASTEXITCODE -eq 0) { Write-Host "LESSON GATE ACCEPTED A CHECK THAT DOES NOT NAME THE LESSON" -ForegroundColor Red; $script:fail++ }
# Naming the lesson is not enough either: the check must declare what makes it red.
Set-Content -LiteralPath "$proj\scripts\check-dup.ps1" -Value @('# lesson: dup-lesson', 'exit 0') -Encoding ASCII
Invoke-Harness "$proj\scripts\metrics.ps1" @{ Root = $proj; LessonGate = $true } | Out-Null
if ($LASTEXITCODE -eq 0) { Write-Host "LESSON GATE ACCEPTED A CHECK WITHOUT fails-when" -ForegroundColor Red; $script:fail++ }
Set-Content -LiteralPath "$proj\scripts\check-dup.ps1" -Value @('# lesson: dup-lesson', '# fails-when: a summary records the same lesson id twice and this suite must exit 1', 'exit 0') -Encoding ASCII
# A promoted lesson that points at a file which does not exist is not evidence.
$lp = $lp -replace 'check=scripts/check-dup\.ps1', 'check=scripts/does-not-exist.ps1'
Set-Content -LiteralPath "$proj\.harness\lessons-promoted.txt" -Value $lp.TrimEnd() -Encoding UTF8
Invoke-Harness "$proj\scripts\metrics.ps1" @{ Root = $proj; LessonGate = $true } | Out-Null
if ($LASTEXITCODE -eq 0) { Write-Host "LESSON GATE ACCEPTED A MISSING CHECK FILE" -ForegroundColor Red; $script:fail++ }
# A doc or a directory proves nothing; only an executable check counts.
foreach ($bad in @('.harness/lessons.md', '.harness')) {
    $lp = $lp -replace 'check=scripts/check-dup\.ps1', ('check=' + $bad)
    Set-Content -LiteralPath "$proj\.harness\lessons-promoted.txt" -Value $lp.TrimEnd() -Encoding UTF8
    Invoke-Harness "$proj\scripts\metrics.ps1" @{ Root = $proj; LessonGate = $true } | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-Host ("LESSON GATE ACCEPTED A NON-EXECUTABLE CHECK: " + $bad) -ForegroundColor Red; $script:fail++ }
    $lp = $lp -replace ('check=' + [regex]::Escape($bad)), 'check=scripts/check-dup.ps1'
}
Set-Content -LiteralPath "$proj\.harness\lessons-promoted.txt" -Value $lp.TrimEnd() -Encoding UTF8

Step 'sql_review: a pass verdict cannot hide unverified layers'
$sumPath = "$proj\.harness\changes\demo\summary.md"
$sumOrig = Get-Content -LiteralPath $sumPath -Raw -Encoding UTF8
# A pass verdict now has to cite an artefact that exists on disk, so the fixture
# writes one where the template says it belongs.
$sqlEvDir = "$proj\.harness\changes\demo\sql-review"
New-Item -ItemType Directory -Force -Path $sqlEvDir | Out-Null
Set-Content -LiteralPath "$sqlEvDir\explain.txt" -Value 'INDEX RANGE SCAN' -Encoding ASCII
function Set-SqlReview {
    param([string]$Value)
    $t = $sumOrig -replace '(?m)(?<![A-Za-z0-9_\-])sql_review:[^\r\n]*', $Value
    Set-Content -LiteralPath $sumPath -Value $t -Encoding UTF8
}
Set-SqlReview 'sql_review: demo.t · 语法 未验证(no sandbox) · 结构 未验证 · 绑定 未验证 · 结果 未验证 · 计划 未跑 · 结论 通过'
Invoke-Harness "$proj\scripts\check-summary.ps1" @{ Root = $proj; Feature = 'demo'; Stage = 'final' } | Out-Null
if ($LASTEXITCODE -eq 0) { Write-Host "CONTRADICTORY SQL REVIEW ACCEPTED" -ForegroundColor Red; $script:fail++ }
Set-SqlReview 'sql_review: demo.t · 语法 OK · 结构 OK · 绑定 #{} · 结果 已验(.harness/changes/demo/sql-review/explain.txt) · 计划 type=ref · 结论 通过'
Invoke-Harness "$proj\scripts\check-summary.ps1" @{ Root = $proj; Feature = 'demo'; Stage = 'final' } | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host "CONSISTENT SQL REVIEW REJECTED" -ForegroundColor Red; $script:fail++ }
# "pass" written by hand with no locatable artefact is self-report, not evidence.
Set-SqlReview 'sql_review: demo.t · 语法 OK · 结构 OK · 绑定 #{} · 结果 已验 · 计划 type=ref · 结论 通过'
Invoke-Harness "$proj\scripts\check-summary.ps1" @{ Root = $proj; Feature = 'demo'; Stage = 'final' } | Out-Null
if ($LASTEXITCODE -eq 0) { Write-Host "SQL PASS WITHOUT AN EVIDENCE PATH ACCEPTED" -ForegroundColor Red; $script:fail++ }
# A cited evidence path is a claim: it must exist on disk.
Set-SqlReview 'sql_review: demo.t · 语法 OK · 结构 OK · 绑定 #{} · 结果 已验(.harness/changes/demo/sql-review/missing.txt) · 计划 未跑 · 结论 待 DBA'
Invoke-Harness "$proj\scripts\check-summary.ps1" @{ Root = $proj; Feature = 'demo'; Stage = 'final' } | Out-Null
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
Invoke-Harness "$proj\scripts\check-summary.ps1" @{ Root = $proj; Feature = 'demo'; Stage = 'final' } | Out-Null
if ($LASTEXITCODE -eq 0) { Write-Host "UNDECLARED DATA SOURCE ACCEPTED" -ForegroundColor Red; $script:fail++ }
$skillText2 = $skillText -replace 'oracle_main / his_mssql', 'oracle_main / his_mssql / THIRD_ORACLE'
Set-Content -LiteralPath "$skillDir\SKILL.md" -Value $skillText2 -Encoding UTF8
Invoke-Harness "$proj\scripts\check-summary.ps1" @{ Root = $proj; Feature = 'demo'; Stage = 'final' } | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host "DECLARED DATA SOURCE REJECTED" -ForegroundColor Red; $script:fail++ }
Remove-Item -LiteralPath $skillDir -Recurse -Force
Remove-Item -LiteralPath $sqlEvDir -Recurse -Force
Set-Content -LiteralPath $sumPath -Value $sumOrig -Encoding UTF8

Step 'shortfall failure lists the accepted none markers'
$sfSrc = Get-Content -LiteralPath $sumPath -Raw -Encoding UTF8
# Plain prose: no .harness/ or scripts/ path and none of the configured markers.
$sfProse = "## 待补短板" + "`r`n" + "需要补一个规则" + "`r`n" + "还在排期"
$sfText = $sfSrc -replace '(?ms)^## 待补短板\r?\n.*?(?=\r?\n## )', $sfProse
Set-Content -LiteralPath $sumPath -Value $sfText -Encoding UTF8
$sfOut = Invoke-Harness "$proj\scripts\stage-gate.ps1" @{ Root = $proj; Stage = '6'; Feature = 'demo' } | Out-String
if ($LASTEXITCODE -eq 0) { Write-Host "SHORTFALL PROSE ACCEPTED" -ForegroundColor Red; $script:fail++ }
if (($sfOut -notmatch 'none') -or ($sfOut -notmatch 'N/A') -or ($sfOut -notmatch '无')) { Write-Host "SHORTFALL DETAIL DOES NOT LIST THE CONFIGURED MARKERS" -ForegroundColor Red; $script:fail++ }
Set-Content -LiteralPath $sumPath -Value $sfSrc -Encoding UTF8

Step 'A3+ spoof must fail'
$s = Get-Content "$proj\.harness\changes\demo\summary.md" -Raw -Encoding UTF8
$s2 = $s -replace '(?ms)^## 待补短板\r?\n.*?(?=\r?\n## )', ''
$s2 = $s2 + "`r`n待补短板一节省略，结论已写在别处。`r`n"
Set-Content -LiteralPath "$proj\.harness\changes\demo\summary.md" -Value $s2 -Encoding UTF8
Invoke-Harness "$proj\scripts\stage-gate.ps1" @{ Root = $proj; Stage = '6'; Feature = 'demo' } | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host "spoof correctly rejected" } else { Write-Host "SPOOF ACCEPTED" -ForegroundColor Red; $script:fail++ }

Step 'red-line-scan -Files splits a comma list'
Set-Content -LiteralPath "$proj\a.java" -Value 'class A { void f() { throw new RuntimeException("x"); } }' -Encoding ASCII
Set-Content -LiteralPath "$proj\b.java" -Value 'class B { void f() { throw new RuntimeException("x"); } }' -Encoding ASCII
$rlBoth = Invoke-Harness "$proj\scripts\red-line-scan.ps1" @{ Root = $proj; Files = 'a.java,b.java' } | Out-String
if ($LASTEXITCODE -ne 1) { Write-Host "COMMA LIST DID NOT FAIL: exit $LASTEXITCODE" -ForegroundColor Red; $script:fail++ }
if (($rlBoth -notmatch 'a\.java') -or ($rlBoth -notmatch 'b\.java')) { Write-Host "COMMA LIST DID NOT SCAN BOTH FILES" -ForegroundColor Red; $script:fail++ }

Step 'red-line-scan fails closed on an explicit list with 0 files'
$rlNone = Invoke-Harness "$proj\scripts\red-line-scan.ps1" @{ Root = $proj; Files = 'missing1.java,missing2.java' } | Out-String
if ($LASTEXITCODE -ne 1) { Write-Host "0-FILE EXPLICIT LIST PASSED: exit $LASTEXITCODE" -ForegroundColor Red; $script:fail++ }
if ($rlNone -notmatch '\[FAIL\]') { Write-Host "0-FILE EXPLICIT LIST DID NOT PRINT [FAIL]" -ForegroundColor Red; $script:fail++ }
if ($rlNone -match '\[OK\]') { Write-Host "0-FILE EXPLICIT LIST STILL PRINTED [OK]" -ForegroundColor Red; $script:fail++ }

Step 'red-line-scan warns about missing paths but still scans the rest'
$rlPart = Invoke-Harness "$proj\scripts\red-line-scan.ps1" @{ Root = $proj; Files = 'a.java,missing.java' } | Out-String
if ($LASTEXITCODE -ne 1) { Write-Host "PARTIAL LIST DID NOT FAIL: exit $LASTEXITCODE" -ForegroundColor Red; $script:fail++ }
if ($rlPart -notmatch '\[WARN\]') { Write-Host "PARTIAL LIST DID NOT PRINT [WARN]" -ForegroundColor Red; $script:fail++ }
if ($rlPart -notmatch 'missing\.java') { Write-Host "PARTIAL LIST DID NOT NAME THE SKIPPED PATH" -ForegroundColor Red; $script:fail++ }
Remove-Item -LiteralPath "$proj\a.java", "$proj\b.java" -Force

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
