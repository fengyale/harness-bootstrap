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
New-Item -ItemType Directory -Force -Path "$proj\.harness\metrics" | Out-Null
Set-Content -LiteralPath "$proj\.harness\metrics\lessons.md" -Value @('# old lessons index', '| old-lesson | 1 |') -Encoding UTF8
Set-Content -LiteralPath "$proj\.harness\metrics\promoted.txt" -Value 'old-promoted' -Encoding UTF8

# Project-owned copy of the red-line summary. Rule names and a project-only row
# must survive; only the scripted-check cell of R5/R6 is framework-owned. The
# file is located by its R5 row so this test stays pure ASCII.
$redline = @(Get-ChildItem -LiteralPath "$proj\.harness\rules" -File | Where-Object {
    (Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8) -match '(?m)^\| R5 ' })[0].FullName
$redlineLines = @([System.IO.File]::ReadAllLines($redline, [System.Text.Encoding]::UTF8) | ForEach-Object {
    if ($_ -match '^\| R5 ') { '| R5 | project-tx-rule | old-check |' }
    elseif ($_ -match '^\| R6 ') { '| R6 | project-log-rule | old-log-check |' }
    else { $_ }
})
$redlineLines += '| R9 | project-only | custom-check |'
[System.IO.File]::WriteAllLines($redline, $redlineLines, (New-Object System.Text.UTF8Encoding($false)))

# A second project-owned rule that differs from the package: the upgrade must
# report it as MANUAL instead of silently keeping it.
$otherRule = @(Get-ChildItem -LiteralPath "$proj\.harness\rules" -File |
    Where-Object { $_.FullName -ne $redline })[0]
Add-Content -LiteralPath $otherRule.FullName -Value 'project-only-rule-line' -Encoding UTF8
$otherRuleRel = '.harness\rules\' + (Split-Path -Leaf $otherRule)

# Same idea for AGENTS.md: a project keeps its own red-line names, while the
# framework-owned check cell must be refreshed from the package.
$agentsLines = @([System.IO.File]::ReadAllLines("$proj\AGENTS.md", [System.Text.Encoding]::UTF8) | ForEach-Object {
    if ($_ -match '^\| R5 ') { '| R5 | project-agents-rule | old-agents-check |' }
    elseif ($_ -match '^\| R6 ') { '| R6 | project-agents-log | old-agents-log-check |' }
    else { $_ }
})
[System.IO.File]::WriteAllLines("$proj\AGENTS.md", $agentsLines, (New-Object System.Text.UTF8Encoding($false)))
# Simulate an older AGENTS.md: drop the record-association line so the merge
# has to insert it exactly once.
$agentsNoRecord = @([System.IO.File]::ReadAllLines("$proj\AGENTS.md", [System.Text.Encoding]::UTF8) |
    Where-Object { $_ -notmatch 'HARNESS_ALLOW_NO_RECORD' })
[System.IO.File]::WriteAllLines("$proj\AGENTS.md", $agentsNoRecord, (New-Object System.Text.UTF8Encoding($false)))

# One installed skill (the install keeps 3-5, not all 25 templates).
# Create the fixture contents explicitly instead of copying a template file:
# this keeps the test independent of the checked-out line endings and of
# whether the template skill happens to exist in the CI workspace.
New-Item -ItemType Directory -Force -Path "$proj\.harness\skills\main-dev\coding-skill" | Out-Null
Set-Content -LiteralPath "$proj\.harness\skills\README.md" -Value '# skill index' -Encoding UTF8
# Uncompiled copy: still carries a slot marker, so -UpdateSkills may replace it.
Set-Content -LiteralPath "$proj\.harness\skills\main-dev\coding-skill\SKILL.md" `
    -Value @('# installed skill', '', '<!-- slot:data.access -->', 'body') -Encoding UTF8
# Compiled copy: slots were replaced by project facts. -UpdateSkills must not
# overwrite it with the skeleton (that would lose the facts and fail grounding).
New-Item -ItemType Directory -Force -Path "$proj\.harness\skills\main-dev\compiled-skill" | Out-Null
Set-Content -LiteralPath "$proj\.harness\skills\main-dev\compiled-skill\SKILL.md" `
    -Value @('# compiled skill', '', 'Cache: RedisUtils') -Encoding UTF8

# Marker-based compiled skill: package text is package-owned, project blocks
# are project-owned. The description and the extra block simulate a compiled
# install; -MergeSkills must refresh the package text and keep both.
New-Item -ItemType Directory -Force -Path "$proj\.harness\skills\main-dev\merge-skill" | Out-Null
$mergeInstalled = @(
    '---',
    'name: merge-skill',
    'description: project-tuned description',
    '---',
    '',
    '# merge skill',
    '',
    '<!-- harness:package:begin mode -->',
    '## old package section',
    'old-package-line',
    '<!-- harness:package:end -->',
    '',
    '<!-- harness:project:begin bindings -->',
    '## Project bindings',
    '- cache: ProjectCache',
    '<!-- harness:project:end -->',
    '',
    '<!-- harness:project:begin extra -->',
    '## Project only',
    '- keep-me',
    '<!-- harness:project:end -->'
)
[System.IO.File]::WriteAllLines("$proj\.harness\skills\main-dev\merge-skill\SKILL.md", $mergeInstalled, (New-Object System.Text.UTF8Encoding($false)))

# Legacy skill (no markers): adopted by heading, and a team-only section must
# be wrapped instead of dropped.
New-Item -ItemType Directory -Force -Path "$proj\.harness\skills\main-dev\merge-legacy" | Out-Null
$legacyInstalled = @(
    '---',
    'name: merge-legacy',
    'description: legacy tuned description',
    '---',
    '',
    '# legacy skill',
    '',
    '## Project bindings',
    '- cache: LegacyCache',
    '',
    '## Team notes',
    '- keep this'
)
[System.IO.File]::WriteAllLines("$proj\.harness\skills\main-dev\merge-legacy\SKILL.md", $legacyInstalled, (New-Object System.Text.UTF8Encoding($false)))

# Pending skill: the new template adds a project block with no heading on disk.
$pendingInstalled = @(
    '---',
    'name: merge-pending',
    'description: pending tuned description',
    '---',
    '',
    '<!-- harness:package:begin mode -->',
    'old-pending-package',
    '<!-- harness:package:end -->',
    '',
    '<!-- harness:project:begin bindings -->',
    '## Project bindings',
    '- cache: PendingCache',
    '<!-- harness:project:end -->'
)
New-Item -ItemType Directory -Force -Path "$proj\.harness\skills\main-dev\merge-pending" | Out-Null
[System.IO.File]::WriteAllLines("$proj\.harness\skills\main-dev\merge-pending\SKILL.md", $pendingInstalled, (New-Object System.Text.UTF8Encoding($false)))

# Over-budget skill: the merged result would exceed the 120-line hard limit.
New-Item -ItemType Directory -Force -Path "$proj\.harness\skills\main-dev\merge-big" | Out-Null
[System.IO.File]::WriteAllLines("$proj\.harness\skills\main-dev\merge-big\SKILL.md", @('# big skill', 'old-big-line'), (New-Object System.Text.UTF8Encoding($false)))

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
New-Item -ItemType Directory -Force -Path "$proj\.harness\changes\l1-demo" | Out-Null
Set-Content -LiteralPath "$proj\.harness\changes\l1-demo\summary.md" -Value @('# l1 demo', '', 'flow: L1') -Encoding UTF8

# A project-owned config that differs from the new package: must stay MANUAL.
# Keep the exact bytes so the apply phase can prove it was not overwritten.
Add-Content -LiteralPath "$proj\scripts\red-line-rules.json" -Value ' ' -Encoding UTF8
$jsonBefore = Get-Content -LiteralPath "$proj\scripts\red-line-rules.json" -Raw

# Deliberately old required list (no sqlGate, legacy ps1 entry): the upgrade
# must print a machine-readable delta so a human can merge the new entries and
# remove the ps1-only requirement in favour of requiredAnyOf.
Set-Content -LiteralPath "$proj\scripts\harness-required.json" -Value '{"_note":"old install","required":["AGENTS.md","scripts/red-line-scan.ps1"]}' -Encoding UTF8

# ------------------------------------------------------------ fake package
Set-Content -LiteralPath "$newPkg\VERSION" -Value 'HARNESS-BOOTSTRAP VERSION 9.9.9' -Encoding ASCII
# update-harness fails early when the package's checker is missing, so the fake
# package must carry it even though this test runs with -SkipVerify.
Copy-Item -LiteralPath "$pkg\templates\scripts\verify-harness.ps1" -Destination "$newPkg\templates\scripts\verify-harness.ps1"
Copy-Item -LiteralPath "$pkg\templates\scripts\stage-gate.ps1" -Destination "$newPkg\templates\scripts\stage-gate.ps1"
Add-Content -LiteralPath "$newPkg\templates\scripts\stage-gate.ps1" -Value '# upgrade-test-marker' -Encoding ASCII
Set-Content -LiteralPath "$newPkg\templates\scripts\new-tool.ps1" -Value '# new tool' -Encoding ASCII
# The new package must carry the config for the MANUAL branch to be exercised.
Copy-Item -LiteralPath "$pkg\templates\scripts\red-line-rules.json" -Destination "$newPkg\templates\scripts\red-line-rules.json"
Copy-Item -LiteralPath "$pkg\templates\scripts\harness-required.json" -Destination "$newPkg\templates\scripts\harness-required.json"
# Python scanners are package-owned machinery: they must be UPDATE, not MANUAL.
Copy-Item -LiteralPath "$pkg\templates\scripts\red-line-scan.py" -Destination "$newPkg\templates\scripts\red-line-scan.py"
Add-Content -LiteralPath "$newPkg\templates\scripts\red-line-scan.py" -Value '# upgrade-test-marker' -Encoding ASCII
# An installed skill that differs must be MANUAL unless -UpdateSkills is given.
# The uncompiled fixture keeps a slot marker; the compiled one has none.
New-Item -ItemType Directory -Force -Path "$newPkg\templates\.harness\skills" | Out-Null
Copy-Item -LiteralPath "$pkg\templates\.harness\skills\README.md" -Destination "$newPkg\templates\.harness\skills\README.md"
New-Item -ItemType Directory -Force -Path "$newPkg\templates\.harness\skills\main-dev\coding-skill" | Out-Null
Set-Content -LiteralPath "$newPkg\templates\.harness\skills\main-dev\coding-skill\SKILL.md" `
    -Value @('# installed skill', '', 'body', '<!-- upgraded-skill -->') -Encoding UTF8
New-Item -ItemType Directory -Force -Path "$newPkg\templates\.harness\skills\main-dev\compiled-skill" | Out-Null
Set-Content -LiteralPath "$newPkg\templates\.harness\skills\main-dev\compiled-skill\SKILL.md" `
    -Value @('# compiled skill', '', '<!-- slot:data.access -->', 'body', '<!-- upgraded-compiled -->') -Encoding UTF8
# Marker-based template: the package block changed, the project block still has
# a slot in the template (the installed copy supplies the compiled body).
New-Item -ItemType Directory -Force -Path "$newPkg\templates\.harness\skills\main-dev\merge-skill" | Out-Null
Set-Content -LiteralPath "$newPkg\templates\.harness\skills\main-dev\merge-skill\SKILL.md" -Value @(
    '---',
    'name: merge-skill',
    'description: template description',
    '---',
    '',
    '# merge skill',
    '',
    '<!-- harness:package:begin mode -->',
    '## new package section',
    'new-package-line',
    '<!-- harness:package:end -->',
    '',
    '<!-- harness:project:begin bindings -->',
    '## Project bindings (fill at install)',
    '- cache: <!-- slot:cache.api -->',
    '<!-- harness:project:end -->'
) -Encoding UTF8
# Legacy template: the installed copy has no markers, so adoption is by heading.
New-Item -ItemType Directory -Force -Path "$newPkg\templates\.harness\skills\main-dev\merge-legacy" | Out-Null
Set-Content -LiteralPath "$newPkg\templates\.harness\skills\main-dev\merge-legacy\SKILL.md" -Value @(
    '---',
    'name: merge-legacy',
    'description: template description',
    '---',
    '',
    '# legacy skill',
    '',
    '<!-- harness:package:begin mode -->',
    '## Mode',
    'new-legacy-package',
    '<!-- harness:package:end -->',
    '',
    '<!-- harness:project:begin bindings -->',
    '## Project bindings (fill at install)',
    '- cache: <!-- slot:cache.api -->',
    '<!-- harness:project:end -->'
) -Encoding UTF8
# Pending template: the sandbox block has no counterpart on disk.
New-Item -ItemType Directory -Force -Path "$newPkg\templates\.harness\skills\main-dev\merge-pending" | Out-Null
Set-Content -LiteralPath "$newPkg\templates\.harness\skills\main-dev\merge-pending\SKILL.md" -Value @(
    '---',
    'name: merge-pending',
    'description: template description',
    '---',
    '',
    '<!-- harness:package:begin mode -->',
    'new-pending-package',
    '<!-- harness:package:end -->',
    '',
    '<!-- harness:project:begin bindings -->',
    '## Project bindings',
    '- cache: <!-- slot:cache.api -->',
    '<!-- harness:project:end -->',
    '',
    '<!-- harness:project:begin sandbox -->',
    '## Sandbox',
    '- path: <!-- slot:sandbox.path -->',
    '<!-- harness:project:end -->'
) -Encoding UTF8
# Over-budget template: 130 filler lines plus a package block.
New-Item -ItemType Directory -Force -Path "$newPkg\templates\.harness\skills\main-dev\merge-big" | Out-Null
$bigLines = @('---', 'name: merge-big', 'description: template description', '---', '', '# big skill', '<!-- harness:package:begin mode -->')
for ($i = 1; $i -le 130; $i++) { $bigLines += "filler-$i" }
$bigLines += '<!-- harness:package:end -->'
[System.IO.File]::WriteAllLines("$newPkg\templates\.harness\skills\main-dev\merge-big\SKILL.md", $bigLines, (New-Object System.Text.UTF8Encoding($false)))
# The change template is package-owned: a newer one must reach the project.
New-Item -ItemType Directory -Force -Path "$newPkg\templates\.harness\changes\_template" | Out-Null
Copy-Item -LiteralPath "$pkg\templates\.harness\changes\_template\summary.md" `
    -Destination "$newPkg\templates\.harness\changes\_template\summary.md"
Add-Content -LiteralPath "$newPkg\templates\.harness\changes\_template\summary.md" `
    -Value '<!-- template-upgrade-marker -->' -Encoding UTF8
Copy-Item -LiteralPath "$pkg\templates\AGENTS.md" -Destination "$newPkg\templates\AGENTS.md"
Add-Content -LiteralPath "$newPkg\templates\AGENTS.md" -Value '<!-- new template line -->' -Encoding UTF8
# The package ships the red-line summary; its R5/R6 check cells are the source
# of truth for the known-row merge.
New-Item -ItemType Directory -Force -Path "$newPkg\templates\.harness" | Out-Null
Copy-Item -LiteralPath "$pkg\templates\.harness\rules" -Destination "$newPkg\templates\.harness\rules" -Recurse
New-Item -ItemType Directory -Force -Path "$newPkg\templates\.trae\agents" | Out-Null
Set-Content -LiteralPath "$newPkg\templates\.trae\agents\new-agent.md" -Value '# agent' -Encoding UTF8

# ------------------------------------------------------------------ dry run
Write-Host ''
Write-Host '=== dry run ===' -ForegroundColor Cyan
$dry = & powershell -NoProfile -ExecutionPolicy Bypass -File "$proj\scripts\update-harness.ps1" -PackagePath $newPkg -Root $proj 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) { Write-Host 'DRY RUN FAILED' -ForegroundColor Red; $fail++ }
Write-Host $dry

Check 'fixture skill exists' (Test-Path -LiteralPath "$proj\.harness\skills\main-dev\coding-skill\SKILL.md")
Check 'new package skill exists' (Test-Path -LiteralPath "$newPkg\templates\.harness\skills\main-dev\coding-skill\SKILL.md")
Check 'dry-run plans stage-gate UPDATE' ($dry -match '\[UPDATE\]\s+scripts\\stage-gate\.ps1')
Check 'dry-run plans new-tool ADD'         ($dry -match '\[ADD\s*\]\s+scripts\\new-tool\.ps1')
Check 'dry-run marks AGENTS.md MERGE'      ($dry -match '\[MERGE\s*\]\s+AGENTS\.md')
# Build the relative path from the known layout, not with Substring: on CI the
# TEMP env var can be a short name (RUNNER~1) while Get-ChildItem returns long
# names (runneradmin), and the two lengths do not match.
$redlineRel = '.harness\rules\' + (Split-Path -Leaf $redline)
Check 'dry-run marks red-line MERGE'       ($dry -match ('\[MERGE\s*\]\s+' + [regex]::Escape($redlineRel)))
Check 'dry-run marks JSON config MANUAL'   ($dry -match '\[MANUAL\]\s+scripts\\red-line-rules\.json')
Check 'dry-run reports required delta'     ($dry -match 'add required:')
Check 'dry-run reports requiredAnyOf'      ($dry -match 'add requiredAnyOf:')
Check 'dry-run reports required removal'   ($dry -match 'remove required:.*scripts/red-line-scan\.ps1')
Check 'dry-run reports sqlGate delta'      ($dry -match 'add sqlGate: true')
Check 'dry-run plans .py UPDATE'           ($dry -match '\[UPDATE\]\s+scripts\\red-line-scan\.py')
Check 'dry-run plans lessons MOVE'         ($dry -match '\[MOVE\s*\]\s+\.harness\\lessons\.md')
Check 'dry-run plans promoted MOVE'        ($dry -match '\[MOVE\s*\]\s+\.harness\\lessons-promoted\.txt')
Check 'dry-run plans L1 COMPACT'           ($dry -match '\[COMPACT\s*\]\s+\.harness\\changes\\l1-demo')
Check 'dry-run marks installed skill MANUAL' ($dry -match '\[MANUAL\]\s+\.harness\\skills\\main-dev\\coding-skill\\SKILL\.md')
Check 'dry-run marks .gitignore MANUAL'    (($dry -match '\[MANUAL\]\s+\.gitignore') -and ($dry -match 'add by hand: \.harness/upgrade/'))
Check 'dry-run does not add uninstalled skills' ($dry -notmatch '\[ADD\s*\]\s+\.harness\\skills\\.*request-analysis')
Check 'dry-run keeps changes history'      ($dry -match '\[KEEP\s*\]\s+\.harness\\changes')
Check 'dry-run writes no version marker'   ((Get-Content -LiteralPath "$proj\.harness\.installed-version" -TotalCount 1) -eq '1.0.0')
Check 'dry-run plans template UPDATE'      ($dry -match ('\[UPDATE\]\s+' + [regex]::Escape('.harness\changes\_template\summary.md')))
Check 'dry-run marks project rule MANUAL'  ($dry -match ('\[MANUAL\]\s+' + [regex]::Escape($otherRuleRel)))

Write-Host ''
Write-Host '=== dry run with -UpdateSkills ===' -ForegroundColor Cyan
$drySkills = & powershell -NoProfile -ExecutionPolicy Bypass -File "$proj\scripts\update-harness.ps1" -PackagePath $newPkg -Root $proj -UpdateSkills 2>&1 | Out-String
Check 'dry-run: uncompiled skill UPDATE' ($drySkills -match '\[UPDATE\].*main-dev\\coding-skill\\SKILL\.md')
Check 'dry-run: compiled skill MANUAL' ((($drySkills -match '\[MANUAL\].*main-dev\\compiled-skill\\SKILL\.md') -and ($drySkills -match 'no slot markers')))
Check 'dry-run: skill index MANUAL' ($drySkills -match '\[MANUAL\].*\.harness\\skills\\README\.md')
$dryForce = & powershell -NoProfile -ExecutionPolicy Bypass -File "$proj\scripts\update-harness.ps1" -PackagePath $newPkg -Root $proj -UpdateSkills -ForceSkills 2>&1 | Out-String
Check 'dry-run warns that -ForceSkills resets skills' ($dryForce -match 'ForceSkills resets installed skills')

Write-Host ''
Write-Host '=== dry run with -MergeSkills ===' -ForegroundColor Cyan
$dryMerge = & powershell -NoProfile -ExecutionPolicy Bypass -File "$proj\scripts\update-harness.ps1" -PackagePath $newPkg -Root $proj -MergeSkills 2>&1 | Out-String
Check 'dry-run: marker skill MERGE' ($dryMerge -match '\[MERGE\s*\].*main-dev\\merge-skill\\SKILL\.md')
Check 'dry-run: legacy skill MERGE' ($dryMerge -match '\[MERGE\s*\].*main-dev\\merge-legacy\\SKILL\.md')
Check 'dry-run: missing project block PENDING' ($dryMerge -match '\[PENDING\s*\].*main-dev\\merge-pending\\SKILL\.md')
Check 'dry-run: over-budget skill MANUAL' ($dryMerge -match '\[MANUAL\s*\].*main-dev\\merge-big\\SKILL\.md')
Check 'dry-run: over-budget reason names the limit' ($dryMerge -match 'hard limit 120')

# -------------------------------------------------------------------- apply
Write-Host ''
Write-Host '=== apply ===' -ForegroundColor Cyan
& powershell -NoProfile -ExecutionPolicy Bypass -File "$proj\scripts\update-harness.ps1" -PackagePath $newPkg -Root $proj -Apply -SkipHooks -SkipVerify 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) { Write-Host 'APPLY FAILED' -ForegroundColor Red; $fail++ }

Check 'stage-gate replaced' ((Select-String -LiteralPath "$proj\scripts\stage-gate.ps1" -Pattern 'upgrade-test-marker' -Quiet))
Check 'new-tool added'      (Test-Path -LiteralPath "$proj\scripts\new-tool.ps1")
Check 'old lessons moved to tracked path' ((Test-Path -LiteralPath "$proj\.harness\lessons.md") -and -not (Test-Path -LiteralPath "$proj\.harness\metrics\lessons.md"))
Check 'old promoted moved to tracked path' ((Test-Path -LiteralPath "$proj\.harness\lessons-promoted.txt") -and -not (Test-Path -LiteralPath "$proj\.harness\metrics\promoted.txt"))
Check 'version marker updated' ((Get-Content -LiteralPath "$proj\.harness\.installed-version" -TotalCount 1) -eq '9.9.9')
Check 'history preserved' ((Get-Content -LiteralPath "$proj\.harness\changes\demo\summary.md") -eq 'history-record')
Check 'project JSON untouched' ((Get-Content -LiteralPath "$proj\scripts\red-line-rules.json" -Raw) -eq $jsonBefore)

# The MERGE branch once lost the destination path (a local $dst overwrote the
# $Dst parameter), so the project config was never merged and a junk file named
# @{...} appeared in the process working directory.
$mergedConfig = (Get-Content -LiteralPath "$proj\scripts\harness-required.json" -Raw -Encoding UTF8) | ConvertFrom-Json
Check 'required JSON merged: sqlGate added' ($mergedConfig.PSObject.Properties.Name -contains 'sqlGate')
Check 'required JSON merged: requiredAnyOf added' ($mergedConfig.PSObject.Properties.Name -contains 'requiredAnyOf')
Check 'required JSON merged: project note kept' ($mergedConfig._note -eq 'old install')
Check 'required JSON merged: legacy ps1 entry removed' (-not (@($mergedConfig.required) -contains 'scripts/red-line-scan.ps1'))
Check 'required JSON merged: package entries added' (@($mergedConfig.required) -contains 'scripts/stage-gate.ps1')
Check 'no @{...} junk file left in the package root' (@(Get-ChildItem -LiteralPath $pkg -Force -Filter '@{*' -ErrorAction SilentlyContinue).Count -eq 0)
Check 'AGENTS.md untouched' ((Get-Content -LiteralPath "$proj\AGENTS.md" -Raw) -notmatch 'new template line')
Check '.py scanner replaced' ((Select-String -LiteralPath "$proj\scripts\red-line-scan.py" -Pattern 'upgrade-test-marker' -Quiet))
Check 'installed skill untouched by default' ((Get-Content -LiteralPath "$proj\.harness\skills\main-dev\coding-skill\SKILL.md" -Raw) -notmatch 'upgraded-skill')
Check 'change template replaced' ((Get-Content -LiteralPath "$proj\.harness\changes\_template\summary.md" -Raw -Encoding UTF8) -match 'template-upgrade-marker')
Check 'project rule untouched' ((Get-Content -LiteralPath $otherRule.FullName -Raw -Encoding UTF8) -match 'project-only-rule-line')

# Known-row merge: only the R5/R6 check cell is framework-owned.
$srcR5 = @([System.IO.File]::ReadAllLines((Join-Path $newPkg ('templates\' + $redlineRel)), [System.Text.Encoding]::UTF8) |
    Where-Object { $_ -match '^\| R5 ' })[0]
$redlineAfter = [System.IO.File]::ReadAllLines($redline, [System.Text.Encoding]::UTF8)
$dstR5 = @($redlineAfter | Where-Object { $_ -match '^\| R5 ' })[0]
$dstR6 = @($redlineAfter | Where-Object { $_ -match '^\| R6 ' })[0]
$srcCells = @($srcR5.Trim().Trim('|') -split '\|' | ForEach-Object { $_.Trim() })
$dstCells = @($dstR5.Trim().Trim('|') -split '\|' | ForEach-Object { $_.Trim() })
Check 'red-line R5 rule name kept'  ($dstCells[1] -eq 'project-tx-rule')
Check 'red-line R5 check merged'    ($dstCells[2] -eq $srcCells[2])
Check 'red-line R6 rule name kept'  ($dstR6 -match '^\| R6 \| project-log-rule \|')
Check 'red-line R6 check merged'    ($dstR6 -notmatch 'old-log-check')
Check 'red-line project row kept'   (@($redlineAfter | Where-Object { $_ -match '^\| R9 ' }).Count -eq 1)

# AGENTS.md known-line merge keeps the project's rule names.
$agentsAfter = [System.IO.File]::ReadAllLines("$proj\AGENTS.md", [System.Text.Encoding]::UTF8)
$agentsR5 = @($agentsAfter | Where-Object { $_ -match '^\| R5 ' })[0]
$agentsR6 = @($agentsAfter | Where-Object { $_ -match '^\| R6 ' })[0]
Check 'AGENTS R5 rule name kept' ($agentsR5 -match '^\| R5 \| project-agents-rule \|')
Check 'AGENTS R5 check merged'   ($agentsR5 -notmatch 'old-agents-check')
Check 'AGENTS R6 rule name kept' ($agentsR6 -match '^\| R6 \| project-agents-log \|')
Check 'AGENTS R6 check merged'   ($agentsR6 -notmatch 'old-agents-log-check')
$agentsFinal = [System.IO.File]::ReadAllLines("$proj\AGENTS.md", [System.Text.Encoding]::UTF8)
$recordLines = @($agentsFinal | Where-Object { $_ -match 'HARNESS_ALLOW_NO_RECORD' })
# The file-index row for lessons.md also mentions lesson_id; require the
# discipline-line anchors so the table row is not counted as the task line.
$taskLines = @($agentsFinal | Where-Object { $_ -match 'lesson_id' -and $_ -match 'pre-commit' -and $_ -match 'check-summary\.ps1' })
$sqlLines = @($agentsFinal | Where-Object { $_ -match 'sql_review:' })
Check 'AGENTS record line inserted once' ($recordLines.Count -eq 1)
Check 'AGENTS task line kept once' ($taskLines.Count -eq 1)
Check 'AGENTS SQL line kept once' ($sqlLines.Count -eq 1)
$taskIdx = if ($taskLines.Count -gt 0) { [array]::IndexOf($agentsFinal, $taskLines[0]) } else { -1 }
Check 'record line follows the task line' (($taskIdx -ge 0) -and ($taskIdx + 1 -lt $agentsFinal.Count) -and ($agentsFinal[$taskIdx + 1] -match 'HARNESS_ALLOW_NO_RECORD'))
$ignoreAfter = [System.IO.File]::ReadAllText("$proj\.gitignore", [System.Text.Encoding]::UTF8)
Check '.gitignore original lines preserved' ($ignoreAfter.StartsWith($ignoreBefore))
Check '.gitignore upgrade line added'       ($ignoreAfter -match '(?m)^\.harness/upgrade/\s*$')

$backup = Get-ChildItem -LiteralPath "$proj\.harness\upgrade" -Directory | Select-Object -First 1
Check 'backup directory created' ($null -ne $backup)
Check 'old stage-gate backed up' (Test-Path -LiteralPath (Join-Path $backup.FullName 'scripts\stage-gate.ps1'))
Check 'old red-line file backed up' (@(Get-ChildItem -LiteralPath (Join-Path $backup.FullName '.harness\rules') -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -eq (Split-Path -Leaf $redline) }).Count -eq 1)
Check 'old template backed up' (Test-Path -LiteralPath (Join-Path $backup.FullName '.harness\changes\_template\summary.md'))
Check 'L1 summary compacted' ((Test-Path -LiteralPath (Join-Path $backup.FullName 'compact\l1-demo')) -and -not (Test-Path -LiteralPath "$proj\.harness\changes\l1-demo"))
Check 'manifest written' (Test-Path -LiteralPath (Join-Path $backup.FullName 'manifest.txt'))

# ------------------------------------------------------------------ skills
Write-Host ''
Write-Host '=== apply with -UpdateSkills ===' -ForegroundColor Cyan
& powershell -NoProfile -ExecutionPolicy Bypass -File "$proj\scripts\update-harness.ps1" -PackagePath $newPkg -Root $proj -Apply -UpdateSkills -SkipHooks -SkipVerify -PruneBackups 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) { Write-Host 'SKILL APPLY FAILED' -ForegroundColor Red; $fail++ }

Check 'installed skill replaced with -UpdateSkills' ((Get-Content -LiteralPath "$proj\.harness\skills\main-dev\coding-skill\SKILL.md" -Raw) -match 'upgraded-skill')
Check 'compiled skill untouched by -UpdateSkills' ((Get-Content -LiteralPath "$proj\.harness\skills\main-dev\compiled-skill\SKILL.md" -Raw) -notmatch 'upgraded-compiled')
Check 'skill index untouched by -UpdateSkills' ((Get-Content -LiteralPath "$proj\.harness\skills\README.md" -Raw) -match 'skill index')
$skillBackup = @(Get-ChildItem -LiteralPath "$proj\.harness\upgrade" -Recurse -File -Filter 'SKILL.md' |
    Where-Object { $_.FullName -match 'main-dev\\coding-skill' })
Check 'old skill backed up' ($skillBackup.Count -gt 0)
Check 'skip-verify prune kept old backups' (Test-Path -LiteralPath $backup.FullName)

Write-Host ''
Write-Host '=== apply with -MergeSkills ===' -ForegroundColor Cyan
$pendingFile = "$proj\.harness\skills\main-dev\merge-pending\SKILL.md"
$bigFile = "$proj\.harness\skills\main-dev\merge-big\SKILL.md"
$pendingBefore = [System.IO.File]::ReadAllText($pendingFile, [System.Text.Encoding]::UTF8)
$bigBefore = [System.IO.File]::ReadAllText($bigFile, [System.Text.Encoding]::UTF8)
& powershell -NoProfile -ExecutionPolicy Bypass -File "$proj\scripts\update-harness.ps1" -PackagePath $newPkg -Root $proj -Apply -MergeSkills -SkipHooks -SkipVerify 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) { Write-Host 'MERGE APPLY FAILED' -ForegroundColor Red; $fail++ }

$mergeAfter = [System.IO.File]::ReadAllText("$proj\.harness\skills\main-dev\merge-skill\SKILL.md", [System.Text.Encoding]::UTF8)
Check 'merge: package text refreshed' ($mergeAfter -match 'new-package-line')
Check 'merge: old package text gone' ($mergeAfter -notmatch 'old-package-line')
Check 'merge: project block kept' ($mergeAfter -match 'ProjectCache')
Check 'merge: project-only block kept' ($mergeAfter -match 'keep-me')
Check 'merge: project description kept' ($mergeAfter -match 'description: project-tuned description')
Check 'merge: markers kept' (($mergeAfter -match 'harness:package:begin mode') -and ($mergeAfter -match 'harness:project:begin bindings'))
Check 'merge: template slot did not leak' ($mergeAfter -notmatch '<!--\s*slot:')

$legacyAfter = [System.IO.File]::ReadAllText("$proj\.harness\skills\main-dev\merge-legacy\SKILL.md", [System.Text.Encoding]::UTF8)
Check 'legacy: package text added' ($legacyAfter -match 'new-legacy-package')
Check 'legacy: adopted by heading' ($legacyAfter -match 'LegacyCache')
Check 'legacy: team section wrapped' ($legacyAfter -match 'harness:project:begin legacy-1')
Check 'legacy: team section kept' ($legacyAfter -match 'keep this')
Check 'legacy: project description kept' ($legacyAfter -match 'description: legacy tuned description')
Check 'legacy: markers present after adoption' ($legacyAfter -match 'harness:project:begin bindings')

Check 'pending: file not written' ([System.IO.File]::ReadAllText($pendingFile, [System.Text.Encoding]::UTF8) -eq $pendingBefore)
Check 'big: file not written' ([System.IO.File]::ReadAllText($bigFile, [System.Text.Encoding]::UTF8) -eq $bigBefore)

$mergeStable = [System.IO.File]::ReadAllText("$proj\.harness\skills\main-dev\merge-skill\SKILL.md", [System.Text.Encoding]::UTF8)
$legacyStable = [System.IO.File]::ReadAllText("$proj\.harness\skills\main-dev\merge-legacy\SKILL.md", [System.Text.Encoding]::UTF8)
& powershell -NoProfile -ExecutionPolicy Bypass -File "$proj\scripts\update-harness.ps1" -PackagePath $newPkg -Root $proj -Apply -MergeSkills -SkipHooks -SkipVerify 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) { Write-Host 'MERGE REPEAT FAILED' -ForegroundColor Red; $fail++ }
Check 'merge second run is idempotent' ([System.IO.File]::ReadAllText("$proj\.harness\skills\main-dev\merge-skill\SKILL.md", [System.Text.Encoding]::UTF8) -eq $mergeStable)
Check 'legacy second run is idempotent' ([System.IO.File]::ReadAllText("$proj\.harness\skills\main-dev\merge-legacy\SKILL.md", [System.Text.Encoding]::UTF8) -eq $legacyStable)

Write-Host ''
Write-Host '=== apply with -ForceSkills ===' -ForegroundColor Cyan
& powershell -NoProfile -ExecutionPolicy Bypass -File "$proj\scripts\update-harness.ps1" -PackagePath $newPkg -Root $proj -Apply -UpdateSkills -ForceSkills -SkipHooks -SkipVerify 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) { Write-Host 'FORCE SKILL APPLY FAILED' -ForegroundColor Red; $fail++ }
Check 'compiled skill replaced with -ForceSkills' ((Get-Content -LiteralPath "$proj\.harness\skills\main-dev\compiled-skill\SKILL.md" -Raw) -match 'upgraded-compiled')
# The reset must leave slot markers behind: that is why verify-grounding will
# fail until the skills are recompiled (the WARN and docs say the same).
Check '-ForceSkills leaves the skeleton uncompiled' ((Get-Content -LiteralPath "$proj\.harness\skills\main-dev\compiled-skill\SKILL.md" -Raw) -match '<!--\s*slot:')
$agentsIdem = @([System.IO.File]::ReadAllLines("$proj\AGENTS.md", [System.Text.Encoding]::UTF8) |
    Where-Object { $_ -match 'HARNESS_ALLOW_NO_RECORD' })
Check 'AGENTS record line stays single after repeated upgrades' ($agentsIdem.Count -eq 1)

Write-Host ''
Write-Host '=== apply with verification deletes the backup ===' -ForegroundColor Cyan
# A no-op verifier lets this fixture exercise the delete-after-verify branch
# without needing a full installed harness.
Set-Content -LiteralPath "$newPkg\templates\scripts\verify-harness.ps1" -Value 'exit 0' -Encoding ASCII
& powershell -NoProfile -ExecutionPolicy Bypass -File "$proj\scripts\update-harness.ps1" -PackagePath $newPkg -Root $proj -Apply -SkipHooks -PruneBackups 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) { Write-Host 'VERIFIED APPLY FAILED' -ForegroundColor Red; $fail++ }
$upgradeDirs = @(Get-ChildItem -LiteralPath "$proj\.harness\upgrade" -Directory -Force -ErrorAction SilentlyContinue)
Check 'verified upgrade prunes backups' ($upgradeDirs.Count -eq 0)
$marker = Get-Content -LiteralPath "$proj\.harness\.installed-version" -Raw -Encoding UTF8
Check 'audit records backup deletion' ($marker -match 'backup: deleted after verification')

Write-Host ''
Write-Host '=== install layout: real sql-review template ===' -ForegroundColor Cyan
$repoRoot = Split-Path -Parent $PSScriptRoot
$realSkillPath = Join-Path $repoRoot 'templates\.harness\skills\biz-dev\14-sql-review\SKILL.md'
$realSkill = [System.IO.File]::ReadAllText($realSkillPath, [System.Text.Encoding]::UTF8)
Check 'install: template carries package and project markers' (($realSkill -match 'harness:package:begin') -and ($realSkill -match 'harness:project:begin'))
# A slot-only compile: every slot is replaced, nothing else changes.
$compiled = [regex]::Replace($realSkill, '<!--\s*slot:[^>]*-->', 'PROJECT-FACT')
Check 'install: compile leaves no slot marker' ($compiled -notmatch '<!--\s*slot:')
Check 'install: project fact landed' ($compiled -match 'PROJECT-FACT')
Check 'install: markers survive compile' (([regex]::Matches($compiled, 'harness:(package|project):begin').Count -eq [regex]::Matches($realSkill, 'harness:(package|project):begin').Count) -and ([regex]::Matches($compiled, 'harness:(package|project):end').Count -eq [regex]::Matches($realSkill, 'harness:(package|project):end').Count))
$pkgPat = '(?s)<!--\s*harness:package:begin\s+[A-Za-z0-9-]+\s*-->.*?<!--\s*harness:package:end\s*-->'
$pkgBefore = (@([regex]::Matches($realSkill, $pkgPat)) | ForEach-Object { $_.Value }) -join "`n"
$pkgAfter = (@([regex]::Matches($compiled, $pkgPat)) | ForEach-Object { $_.Value }) -join "`n"
Check 'install: compile does not touch package text' ($pkgBefore -eq $pkgAfter)
$prjPat = '(?s)<!--\s*harness:project:begin\s+[A-Za-z0-9-]+\s*-->.*?<!--\s*harness:project:end\s*-->'
Check 'install: every slot sits in a project block' ((@([regex]::Matches($realSkill, $prjPat)) | ForEach-Object { $_.Value }) -join "`n" -match 'slot:')
$outsidePrj = [regex]::Replace($realSkill, $prjPat, '')
Check 'install: no slot outside a project block' ($outsidePrj -notmatch '<!--\s*slot:')

Write-Host ''
if ($fail -eq 0) { Write-Host 'UPDATE TEST OK' -ForegroundColor Green; exit 0 }
Write-Host ("UPDATE TEST FAILURES: {0}" -f $fail) -ForegroundColor Red
exit 1
