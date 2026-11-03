<#
  test-update.ps1 -- behavioural test for scripts/update-harness.ps1

  WHY
    The upgrade path must not behave like Copy-Missing. This test proves the
    three promises: package-owned .ps1 files are replaced (with a backup),
    project config and history are kept, and the version marker is updated.

  FIXTURE
    A throw-away project built from templates/, plus a fake new package whose
    stage-gate.ps1 differs and adds one new script. Nothing is written into
    this repository.

  USAGE
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-update.ps1

  EXIT CODE
    0 = all assertions passed, 1 = at least one failed

  NOTE
    Pure ASCII. Skipped hooks/verify so the fixture does not need a git repo.
#>
$ErrorActionPreference = 'Stop'

$pkg = Split-Path -Parent $PSScriptRoot
$base = Join-Path $env:TEMP 'hb-update-test'
$proj = Join-Path $base 'proj'
$newPkg = Join-Path $base 'newpkg'
$fail = 0

function Check {
    param([string]$Name, [bool]$Condition)
    if ($Condition) { Write-Host "ok: $Name" -ForegroundColor DarkGray }
    else { Write-Host "FAIL: $Name" -ForegroundColor Red; $script:fail++ }
}

if (Test-Path -LiteralPath $base) { Remove-Item -LiteralPath $base -Recurse -Force }
New-Item -ItemType Directory -Force -Path "$proj\.harness" | Out-Null
New-Item -ItemType Directory -Force -Path "$newPkg\templates\scripts" | Out-Null

# ------------------------------------------------------------ old install
Copy-Item -LiteralPath "$pkg\templates\scripts" -Destination "$proj\scripts" -Recurse
foreach ($sub in @('rules', 'wiki', 'modules', 'changes')) {
    Copy-Item -LiteralPath "$pkg\templates\.harness\$sub" -Destination "$proj\.harness\$sub" -Recurse
}
Copy-Item -LiteralPath "$pkg\templates\AGENTS.md" -Destination "$proj\AGENTS.md"
Copy-Item -LiteralPath "$pkg\templates\.gitignore" -Destination "$proj\.gitignore"
Set-Content -LiteralPath "$proj\.harness\.installed-version" -Value '1.0.0' -Encoding ASCII

# One installed skill (the install keeps 3-5, not all 25 templates).
New-Item -ItemType Directory -Force -Path "$proj\.harness\skills\main-dev\coding-skill" | Out-Null
Copy-Item -LiteralPath "$pkg\templates\.harness\skills\README.md" -Destination "$proj\.harness\skills\README.md"
Copy-Item -LiteralPath "$pkg\templates\.harness\skills\main-dev\coding-skill\SKILL.md" `
    -Destination "$proj\.harness\skills\main-dev\coding-skill\SKILL.md"

# Remove the new ignore line so the MANUAL branch for .gitignore is exercised.
# Use .NET UTF-8 explicitly: PS 5.1 Get-Content/Set-Content on a UTF-8 file
# without BOM decodes the Chinese comments as ANSI and corrupts the file.
$ignorePath = Join-Path $proj '.gitignore'
$ignoreLines = @([System.IO.File]::ReadAllLines($ignorePath, [System.Text.Encoding]::UTF8) |
    Where-Object { $_.Trim() -ne '.harness/upgrade/' })
[System.IO.File]::WriteAllLines($ignorePath, $ignoreLines, (New-Object System.Text.UTF8Encoding($false)))
$ignoreBefore = [System.IO.File]::ReadAllText($ignorePath, [System.Text.Encoding]::UTF8)

New-Item -ItemType Directory -Force -Path "$proj\.harness\changes\demo" | Out-Null
Set-Content -LiteralPath "$proj\.harness\changes\demo\summary.md" -Value 'history-record' -Encoding UTF8

# A project-owned config that differs from the new package: must stay MANUAL.
# Keep the exact bytes so the apply phase can prove it was not overwritten.
Add-Content -LiteralPath "$proj\scripts\red-line-rules.json" -Value ' ' -Encoding UTF8
$jsonBefore = Get-Content -LiteralPath "$proj\scripts\red-line-rules.json" -Raw

# ------------------------------------------------------------ fake package
Set-Content -LiteralPath "$newPkg\VERSION" -Value 'HARNESS-BOOTSTRAP VERSION 9.9.9' -Encoding ASCII
Copy-Item -LiteralPath "$pkg\templates\scripts\stage-gate.ps1" -Destination "$newPkg\templates\scripts\stage-gate.ps1"
Add-Content -LiteralPath "$newPkg\templates\scripts\stage-gate.ps1" -Value '# upgrade-test-marker' -Encoding ASCII
Set-Content -LiteralPath "$newPkg\templates\scripts\new-tool.ps1" -Value '# new tool' -Encoding ASCII
# The new package must carry the config for the MANUAL branch to be exercised.
Copy-Item -LiteralPath "$pkg\templates\scripts\red-line-rules.json" -Destination "$newPkg\templates\scripts\red-line-rules.json"
# Python scanners are package-owned machinery: they must be UPDATE, not MANUAL.
Copy-Item -LiteralPath "$pkg\templates\scripts\red-line-scan.py" -Destination "$newPkg\templates\scripts\red-line-scan.py"
Add-Content -LiteralPath "$newPkg\templates\scripts\red-line-scan.py" -Value '# upgrade-test-marker' -Encoding ASCII
# An installed skill that differs must be MANUAL unless -UpdateSkills is given.
New-Item -ItemType Directory -Force -Path "$newPkg\templates\.harness\skills\main-dev\coding-skill" | Out-Null
Copy-Item -LiteralPath "$pkg\templates\.harness\skills\main-dev\coding-skill\SKILL.md" `
    -Destination "$newPkg\templates\.harness\skills\main-dev\coding-skill\SKILL.md"
Add-Content -LiteralPath "$newPkg\templates\.harness\skills\main-dev\coding-skill\SKILL.md" `
    -Value '<!-- upgraded-skill -->' -Encoding UTF8
Copy-Item -LiteralPath "$pkg\templates\AGENTS.md" -Destination "$newPkg\templates\AGENTS.md"
Add-Content -LiteralPath "$newPkg\templates\AGENTS.md" -Value '<!-- new template line -->' -Encoding UTF8
New-Item -ItemType Directory -Force -Path "$newPkg\templates\.trae\agents" | Out-Null
Set-Content -LiteralPath "$newPkg\templates\.trae\agents\new-agent.md" -Value '# agent' -Encoding UTF8

# ------------------------------------------------------------------ dry run
Write-Host ''
Write-Host '=== dry run ===' -ForegroundColor Cyan
$dry = & powershell -NoProfile -ExecutionPolicy Bypass -File "$proj\scripts\update-harness.ps1" -PackagePath $newPkg -Root $proj 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) { Write-Host 'DRY RUN FAILED' -ForegroundColor Red; $fail++ }
Write-Host $dry

Check 'dry-run plans stage-gate UPDATE' ($dry -match '\[UPDATE\]\s+scripts\\stage-gate\.ps1')
Check 'dry-run plans new-tool ADD'         ($dry -match '\[ADD\s*\]\s+scripts\\new-tool\.ps1')
Check 'dry-run marks AGENTS.md MANUAL'     ($dry -match '\[MANUAL\]\s+AGENTS\.md')
Check 'dry-run marks JSON config MANUAL'   ($dry -match '\[MANUAL\]\s+scripts\\red-line-rules\.json')
Check 'dry-run plans .py UPDATE'           ($dry -match '\[UPDATE\]\s+scripts\\red-line-scan\.py')
Check 'dry-run marks installed skill MANUAL' ($dry -match '\[MANUAL\]\s+\.harness\\skills\\main-dev\\coding-skill\\SKILL\.md')
Check 'dry-run marks .gitignore MANUAL'    (($dry -match '\[MANUAL\]\s+\.gitignore') -and ($dry -match 'add by hand: \.harness/upgrade/'))
Check 'dry-run does not add uninstalled skills' ($dry -notmatch '\[ADD\s*\]\s+\.harness\\skills\\.*request-analysis')
Check 'dry-run keeps changes history'      ($dry -match '\[KEEP\s*\]\s+\.harness\\changes')
Check 'dry-run writes no version marker'   ((Get-Content -LiteralPath "$proj\.harness\.installed-version" -TotalCount 1) -eq '1.0.0')

# -------------------------------------------------------------------- apply
Write-Host ''
Write-Host '=== apply ===' -ForegroundColor Cyan
& powershell -NoProfile -ExecutionPolicy Bypass -File "$proj\scripts\update-harness.ps1" -PackagePath $newPkg -Root $proj -Apply -SkipHooks -SkipVerify 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) { Write-Host 'APPLY FAILED' -ForegroundColor Red; $fail++ }

Check 'stage-gate replaced' ((Select-String -LiteralPath "$proj\scripts\stage-gate.ps1" -Pattern 'upgrade-test-marker' -Quiet))
Check 'new-tool added'      (Test-Path -LiteralPath "$proj\scripts\new-tool.ps1")
Check 'version marker updated' ((Get-Content -LiteralPath "$proj\.harness\.installed-version" -TotalCount 1) -eq '9.9.9')
Check 'history preserved' ((Get-Content -LiteralPath "$proj\.harness\changes\demo\summary.md") -eq 'history-record')
Check 'project JSON untouched' ((Get-Content -LiteralPath "$proj\scripts\red-line-rules.json" -Raw) -eq $jsonBefore)
Check 'AGENTS.md untouched' ((Get-Content -LiteralPath "$proj\AGENTS.md" -Raw) -notmatch 'new template line')
Check '.py scanner replaced' ((Select-String -LiteralPath "$proj\scripts\red-line-scan.py" -Pattern 'upgrade-test-marker' -Quiet))
Check 'installed skill untouched by default' ((Get-Content -LiteralPath "$proj\.harness\skills\main-dev\coding-skill\SKILL.md" -Raw) -notmatch 'upgraded-skill')
Check '.gitignore untouched' ([System.IO.File]::ReadAllText("$proj\.gitignore", [System.Text.Encoding]::UTF8) -eq $ignoreBefore)

$backup = Get-ChildItem -LiteralPath "$proj\.harness\upgrade" -Directory | Select-Object -First 1
Check 'backup directory created' ($null -ne $backup)
Check 'old stage-gate backed up' (Test-Path -LiteralPath (Join-Path $backup.FullName 'scripts\stage-gate.ps1'))
Check 'manifest written' (Test-Path -LiteralPath (Join-Path $backup.FullName 'manifest.txt'))

# ------------------------------------------------------------------ skills
Write-Host ''
Write-Host '=== apply with -UpdateSkills ===' -ForegroundColor Cyan
& powershell -NoProfile -ExecutionPolicy Bypass -File "$proj\scripts\update-harness.ps1" -PackagePath $newPkg -Root $proj -Apply -UpdateSkills -SkipHooks -SkipVerify 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) { Write-Host 'SKILL APPLY FAILED' -ForegroundColor Red; $fail++ }

Check 'installed skill replaced with -UpdateSkills' ((Get-Content -LiteralPath "$proj\.harness\skills\main-dev\coding-skill\SKILL.md" -Raw) -match 'upgraded-skill')
$skillBackup = @(Get-ChildItem -LiteralPath "$proj\.harness\upgrade" -Recurse -File -Filter 'SKILL.md' |
    Where-Object { $_.FullName -match 'main-dev\\coding-skill' })
Check 'old skill backed up' ($skillBackup.Count -gt 0)

Write-Host ''
if ($fail -eq 0) { Write-Host 'UPDATE TEST OK' -ForegroundColor Green; exit 0 }
Write-Host ("UPDATE TEST FAILURES: {0}" -f $fail) -ForegroundColor Red
exit 1
