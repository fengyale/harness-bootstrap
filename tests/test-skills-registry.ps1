<#
  test-skills-registry.ps1 -- a skill directory must be indexed and reachable

  WHY
    A project can drop a SKILL.md into .harness/skills and never see it again:
    the platform only scans its own discovery directory, and metrics counts
    loads from summaries. Without a registration check the new skill silently
    becomes a dead file, then looks like a "retire candidate" 28 days later.

  WHAT IT ASSERTS
    - a skill missing from .harness/skills/README.md and with no platform entry
      is reported as FAIL with both reasons
    - metrics reports it as "not registered", not as "never loaded"
    - listing it in the index and creating an entry turns the check green
    - removing only the entry reports "no platform entry", not "not listed"
    - .harness/skills/INDEX.md (index-only platforms) satisfies the entry side
    - a missing skills/README.md is one failure, not one per skill

  USAGE
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-skills-registry.ps1

  NOTE
    Pure ASCII on purpose (PS 5.1 parses .ps1 as ANSI without a BOM).
#>
$ErrorActionPreference = 'Stop'
$pkg  = Split-Path -Parent $PSScriptRoot
$proj = Join-Path $env:TEMP 'hb-install-test\proj4'
$fail = 0

function Step([string]$Name) { Write-Host ""; Write-Host "=== $Name ===" -ForegroundColor Cyan }
function Check([string]$Label, [bool]$Ok) {
    if ($Ok) { Write-Host "ok: $Label" }
    else { Write-Host "BAD: $Label" -ForegroundColor Red; $script:fail++ }
}
function RunVerify {
    return (& powershell -NoProfile -ExecutionPolicy Bypass -File "$proj\scripts\verify-harness.ps1" -Root $proj 2>&1 | Out-String)
}
function New-Skill([string]$Category, [string]$DirName, [string]$Name) {
    $dir = Join-Path $proj ".harness\skills\$Category\$DirName"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $body = @('---', "name: $Name", 'description: demo skill for the registry test', '---', '', '# demo')
    [System.IO.File]::WriteAllLines((Join-Path $dir 'SKILL.md'), $body, (New-Object System.Text.UTF8Encoding($false)))
    return $dir
}
function New-Entry([string]$EntryName, [string]$SourceDir) {
    $dest = Join-Path $proj ".trae\skills\$EntryName"
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    Copy-Item (Join-Path $SourceDir 'SKILL.md') $dest -Force
}

if (Test-Path $proj) { Remove-Item $proj -Recurse -Force }
Copy-Item "$pkg\assets\scripts" "$proj\scripts" -Recurse

$demoDir  = New-Skill 'main-dev' 'demo-skill' 'demo-skill'
$extraDir = New-Skill 'biz-dev' '99-extra-helper' 'extra-helper'

$indexPath = "$proj\.harness\skills\README.md"
Set-Content -LiteralPath $indexPath -Value @(
    '# skill index',
    '',
    '| skill | when |',
    '| --- | --- |',
    '| `demo-skill` | demo |'
) -Encoding UTF8

New-Entry 'demo-skill' $demoDir

Step 'unindexed and unreachable'
$out = RunVerify
Check 'registry FAIL is reported' ($out -match 'FAIL\] skills-registry')
Check 'failing skill is named' ($out -match 'biz-dev/99-extra-helper')
Check 'missing index is named' ($out -match 'not listed in \.harness/skills/README\.md')
Check 'missing entry is named' ($out -match 'no platform entry')
Check 'listed and linked skill is not flagged' (-not ($out -match 'main-dev/demo-skill:'))

Step 'metrics names the skill as unregistered'
$m = (& powershell -NoProfile -ExecutionPolicy Bypass -File "$proj\scripts\metrics.ps1" -Root $proj -Days 28 2>&1 | Out-String)
Check 'metrics reports the skill as not registered' ($m -match 'skill not registered: extra-helper')
# The retirement side is asserted at the end, where five tasks and an old skill
# make the verdict observable; a string check here would pass either way.

Step 'index + entry fixes it'
Add-Content -LiteralPath $indexPath -Value '| `extra-helper` | demo |' -Encoding UTF8
New-Entry 'extra-helper' $extraDir
$out = RunVerify
Check 'registry PASS after fixing both sides' ($out -match 'PASS\] skills-registry .*2 skill\(s\)')
Check 'no registry FAIL left' (-not ($out -match 'FAIL\] skills-registry'))

Step 'entry removed, index kept'
Remove-Item -LiteralPath "$proj\.trae\skills\extra-helper" -Recurse -Force
$out = RunVerify
Check 'missing entry is reported' ($out -match '99-extra-helper.*no platform entry')
Check 'indexed name is not reported as unlisted' (-not ($out -match '99-extra-helper: not listed'))

Step 'index-only platform satisfies the entry side'
Set-Content -LiteralPath "$proj\.harness\skills\INDEX.md" -Value '# index mode' -Encoding UTF8
$out = RunVerify
Check 'INDEX.md turns the registry check green' ($out -match 'PASS\] skills-registry')

Step 'metrics: unregistered is not a retirement candidate'
# An old, unregistered skill plus five tasks: the retirement loop only runs with
# >= 5 tasks, and the age gate only passes after 28 days. Without the explicit
# skip, this skill would be reported as a retire candidate even though no
# platform could ever have loaded it.
$orphanDir = New-Skill 'biz-dev' '98-orphan-helper' 'orphan-helper'
foreach ($p in @($demoDir, $orphanDir)) {
    $f = Join-Path $p 'SKILL.md'
    [System.IO.File]::SetCreationTime($f, (Get-Date).AddDays(-40))
    [System.IO.File]::SetLastWriteTime($f, (Get-Date).AddDays(-40))
}
$tpl = [System.IO.File]::ReadAllText("$pkg\assets\.harness\changes\_template\summary.md", [System.Text.Encoding]::UTF8)
$tpl = $tpl -replace 'YYYY-MM-DD', (Get-Date -Format 'yyyy-MM-dd')
$tpl = $tpl -replace '(?m)(?<![A-Za-z0-9_\-])impl_corrections:[^\r\n]*', 'impl_corrections: 0'
$tpl = $tpl -replace '(?m)(?<![A-Za-z0-9_\-])corrections:[^\r\n]*', 'corrections: 0'
$tpl = $tpl -replace '(?m)(?<![A-Za-z0-9_\-])loaded_skills:[^\r\n]*', 'loaded_skills: none'
$tpl = $tpl -replace '(?m)(?<![A-Za-z0-9_\-])load_skip_reason:[^\r\n]*', 'load_skip_reason: n/a'
$tpl = $tpl -replace '(?m)(?<![A-Za-z0-9_\-])touched_modules:[^\r\n]*', 'touched_modules: demo'
$tpl = $tpl -replace '(?m)(?<![A-Za-z0-9_\-])flow:[^\r\n]*', 'flow: L2'
$tpl = $tpl -replace '(?m)(?<![A-Za-z0-9_\-])lesson_id:[^\r\n]*', 'lesson_id: -'
$tpl = $tpl -replace '(?m)(?<![A-Za-z0-9_\-])sql_review:[^\r\n]*', 'sql_review: no SQL change'
for ($i = 1; $i -le 5; $i++) {
    $d = Join-Path $proj ".harness\changes\task$i"
    New-Item -ItemType Directory -Force -Path $d | Out-Null
    Set-Content -LiteralPath (Join-Path $d 'summary.md') -Value $tpl -Encoding UTF8
}
$m = (& powershell -NoProfile -ExecutionPolicy Bypass -File "$proj\scripts\metrics.ps1" -Root $proj -Days 28 2>&1 | Out-String)
Check 'metrics reports the skill as not registered' ($m -match 'skill not registered: orphan-helper')
Check 'unregistered skill is not a retire candidate' (-not ($m -match 'orphan-helper.*retire candidate'))
Check 'registered but never loaded is still a retire candidate' ($m -match 'demo-skill.*retire candidate')

Step 'a long skill body is a WARN, not a failure'
# The 120-line cap was removed: a skill is loaded on demand, so a complex skill
# is legitimately long. Re-adding a hard limit would make this fixture FAIL.
$longDir = New-Skill 'main-dev' 'long-skill' 'long-skill'
$longFile = Join-Path $longDir 'SKILL.md'
$longLines = @([System.IO.File]::ReadAllLines($longFile))
for ($i = 1; $i -le 260; $i++) { $longLines += "filler-$i" }
[System.IO.File]::WriteAllLines($longFile, $longLines, (New-Object System.Text.UTF8Encoding($false)))
Add-Content -LiteralPath $indexPath -Value '| `long-skill` | demo |' -Encoding UTF8
New-Entry 'long-skill' $longDir
$g = & powershell -NoProfile -ExecutionPolicy Bypass -File "$proj\scripts\verify-grounding.ps1" -Root $proj 2>&1 | Out-String
$gCode = $LASTEXITCODE
Check 'long skill: verify-grounding still exits 0' ($gCode -eq 0)
Check 'long skill: reported as a size WARN' ($g -match 'consider moving examples')

Step 'coverage: a placeholder structure tree is a failure'
# verify-grounding cannot see that a long wiki page is still the template, so the
# coverage check reads the structure tree: a fenced line that still starts with
# "<" means the tree was never copied from the real repository.
New-Item -ItemType Directory -Force -Path "$proj\.harness\rules" | Out-Null
$structName = (-join ([char]0x5DE5, [char]0x7A0B, [char]0x7ED3, [char]0x6784)) + '.md'
$structPath = Join-Path "$proj\.harness\rules" $structName
[System.IO.File]::WriteAllLines($structPath, @(
    '# structure', '', '```text', '<project>/', '+-- src/', '```', ''
), (New-Object System.Text.UTF8Encoding($false)))
Set-Content -LiteralPath "$proj\AGENTS.md" -Value '# demo project', 'no placeholders here' -Encoding UTF8
New-Item -ItemType Directory -Force -Path "$proj\src" | Out-Null
Set-Content -LiteralPath "$proj\src\Main.java" -Value 'class Main { }' -Encoding ASCII
New-Item -ItemType Directory -Force -Path "$proj\baseline" | Out-Null
Set-Content -LiteralPath "$proj\baseline\baseline.json" -Value '{"srcRoots":["src"],"testRoots":[]}' -Encoding UTF8
$g = & powershell -NoProfile -ExecutionPolicy Bypass -File "$proj\scripts\verify-grounding.ps1" -Root $proj 2>&1 | Out-String
$gCode = $LASTEXITCODE
Check 'placeholder tree fails coverage' ($gCode -eq 1)
Check 'failure names the structure tree' ($g -match 'coverage.*structure tree')
[System.IO.File]::WriteAllLines($structPath, @(
    '# structure', '', '```text', 'demo/', '+-- src/', '```', ''
), (New-Object System.Text.UTF8Encoding($false)))
$g = & powershell -NoProfile -ExecutionPolicy Bypass -File "$proj\scripts\verify-grounding.ps1" -Root $proj 2>&1 | Out-String
Check 'filled tree clears the failure' ($LASTEXITCODE -eq 0)

Step 'coverage: an unfilled wiki table is a warning'
# The tree is filled now. A wiki page copied from the template must be reported
# as "no real row" but stay a WARN: probe cannot count entities, so a hard
# failure here would punish projects whose table is legitimately short.
New-Item -ItemType Directory -Force -Path "$proj\.harness\wiki" | Out-Null
$bizName = (-join ([char]0x4E1A, [char]0x52A1, [char]0x6A21, [char]0x578B)) + '.md'
Copy-Item -LiteralPath (Join-Path $pkg "assets\.harness\wiki\$bizName") -Destination (Join-Path "$proj\.harness\wiki" $bizName) -Force
Set-Content -LiteralPath "$proj\.harness\stack.json" -Value '{"orm":"mybatis","cache":"redis","mq":"present"}' -Encoding UTF8
$g = & powershell -NoProfile -ExecutionPolicy Bypass -File "$proj\scripts\verify-grounding.ps1" -Root $proj 2>&1 | Out-String
Check 'template wiki table is reported as a warning' ($g -match 'WARN.*no real row')
Check 'coverage warning does not fail the run' ($LASTEXITCODE -eq 0)

Step 'missing README is reported once'
Remove-Item -LiteralPath $indexPath -Force
$out = RunVerify
Check 'missing index file is reported' ($out -match 'missing \.harness/skills/README\.md')
Check 'one message instead of one per skill' (-not ($out -match 'not listed in \.harness/skills/README\.md'))

Write-Host ''
if ($fail -eq 0) { Write-Host 'SKILLS REGISTRY TEST OK' -ForegroundColor Green; exit 0 }
Write-Host "SKILLS REGISTRY TEST FAILED: $fail check(s)" -ForegroundColor Red
exit 1
