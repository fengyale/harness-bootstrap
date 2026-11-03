$ErrorActionPreference = 'Stop'
$pkg  = Split-Path -Parent $PSScriptRoot
$proj = Join-Path $env:TEMP 'hb-install-test\proj2'
$fail = 0

function Step([string]$Name) { Write-Host ""; Write-Host "=== $Name ===" -ForegroundColor Cyan }

if (Test-Path $proj) { Remove-Item $proj -Recurse -Force }
New-Item -ItemType Directory -Force -Path "$proj\.harness\changes\demo" | Out-Null
Copy-Item "$pkg\templates\scripts" "$proj\scripts" -Recurse

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
$tpl = Get-Content "$pkg\templates\.harness\changes\_template\summary.md" -Raw -Encoding UTF8
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
Set-Content -LiteralPath "$proj\.harness\changes\demo\summary.md" -Value $tpl -Encoding UTF8

Step 'check-summary initial / final'
& powershell -NoProfile -ExecutionPolicy Bypass -File "$proj\scripts\check-summary.ps1" -Root $proj -Feature demo -Stage initial
if ($LASTEXITCODE -ne 0) { Write-Host "INITIAL FAILED" -ForegroundColor Red; $script:fail++ }
& powershell -NoProfile -ExecutionPolicy Bypass -File "$proj\scripts\check-summary.ps1" -Root $proj -Feature demo -Stage final
if ($LASTEXITCODE -ne 0) { Write-Host "FINAL FAILED" -ForegroundColor Red; $script:fail++ }

Step 'stage-gate -All'
& powershell -NoProfile -ExecutionPolicy Bypass -File "$proj\scripts\stage-gate.ps1" -Root $proj -All -Feature demo
if ($LASTEXITCODE -ne 0) { Write-Host "STAGE GATE FAILED" -ForegroundColor Red; $script:fail++ }

Step 'metrics -Days 14 -Compare'
& powershell -NoProfile -ExecutionPolicy Bypass -File "$proj\scripts\metrics.ps1" -Root $proj -Days 14 -Compare
if ($LASTEXITCODE -ne 0) { Write-Host "METRICS FAILED" -ForegroundColor Red; $script:fail++ }

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
