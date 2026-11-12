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
Copy-Item "$pkg\templates\scripts" "$proj\scripts" -Recurse

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

Step 'metrics separates "not registered" from "never loaded"'
$m = (& powershell -NoProfile -ExecutionPolicy Bypass -File "$proj\scripts\metrics.ps1" -Root $proj -Days 28 2>&1 | Out-String)
Check 'metrics reports the skill as not registered' ($m -match 'skill not registered: extra-helper')
Check 'metrics says it is not a retirement signal' ($m -match 'not a retirement signal')

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

Write-Host ''
if ($fail -eq 0) { Write-Host 'SKILLS REGISTRY TEST OK' -ForegroundColor Green; exit 0 }
Write-Host "SKILLS REGISTRY TEST FAILED: $fail check(s)" -ForegroundColor Red
exit 1
