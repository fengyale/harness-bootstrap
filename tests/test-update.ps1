<#
  test-update.ps1 -- behavioural test for scripts/update-harness.ps1

  WHY
    The upgrade path must not behave like Copy-Missing. This test proves the
    three promises: package-owned .ps1 files are replaced (with a backup),
    project config and history are kept, and the version marker is updated.

  FIXTURE
    A throw-away project built from assets/, plus a fake new package whose
    stage-gate.ps1 differs and adds one new script. Nothing is written into
    this repository.

  USAGE
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-update.ps1

  EXIT CODE
    0 = all assertions passed, 1 = at least one failed

  NOTE
    Pure ASCII. Skipped hooks/verify so the fixture does not need a git repo.
#>
param([string]$TestRoot = '')
$ErrorActionPreference = 'Stop'
if (-not $TestRoot) {
    $TestRoot = Join-Path $env:TEMP ('hb-tests-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '\test-update')
}

$pkg = Split-Path -Parent $PSScriptRoot
$base = $TestRoot
$proj = Join-Path $base 'proj'
$newPkg = Join-Path $base 'newpkg'
$fail = 0
. (Join-Path $PSScriptRoot 'test-lib.ps1')

function Check {
    param([string]$Name, [bool]$Condition)
    if ($Condition) { Write-Host "ok: $Name" -ForegroundColor DarkGray }
    else { Write-Host "FAIL: $Name" -ForegroundColor Red; $script:fail++ }
}

if (Test-Path -LiteralPath $base) { Remove-Item -LiteralPath $base -Recurse -Force }
New-Item -ItemType Directory -Force -Path "$proj\.harness" | Out-Null
New-Item -ItemType Directory -Force -Path "$newPkg\assets\scripts" | Out-Null

# ------------------------------------------------------------ old install
Copy-Item -LiteralPath "$pkg\assets\scripts" -Destination "$proj\scripts" -Recurse
foreach ($sub in @('rules', 'wiki', 'modules', 'changes')) {
    Copy-Item -LiteralPath "$pkg\assets\.harness\$sub" -Destination "$proj\.harness\$sub" -Recurse
}
Copy-Item -LiteralPath "$pkg\assets\AGENTS.md" -Destination "$proj\AGENTS.md"
Copy-Item -LiteralPath "$pkg\assets\.gitignore" -Destination "$proj\.gitignore"
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

# A rule file that carries BOTH a red-line table and an upgrade block. The block
# branch must win in the plan and in the apply phase alike; otherwise the dry run
# promises a red-line merge while the apply only replaces the block.
$combinedRel = '.harness\rules\combined-probe.md'
$combinedDst = Join-Path $proj $combinedRel
[System.IO.File]::WriteAllLines($combinedDst, @(
    '# combined probe',
    '<!-- harness:upgrade:begin id=probe-block -->',
    'old-probe-line',
    '<!-- harness:upgrade:end id=probe-block -->',
    '',
    '| R5 | probe-rule | old-check |',
    '| R6 | probe-log | old-log-check |'
), (New-Object System.Text.UTF8Encoding($false)))

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
# Same idea for the marked entry block: an install older than the marker carries
# the paragraph without it. Drop only the marker lines (the text stays, so the
# upgrade has to replace the unmarked copy instead of duplicating it) and add a
# project-only line that must survive.
$agentsNoBlock = @([System.IO.File]::ReadAllLines("$proj\AGENTS.md", [System.Text.Encoding]::UTF8) |
    Where-Object { $_ -notmatch 'harness:upgrade:(begin|end)\s+id=start-command' })
$agentsNoBlock += '> project-custom-agents-line'
[System.IO.File]::WriteAllLines("$proj\AGENTS.md", $agentsNoBlock, (New-Object System.Text.UTF8Encoding($false)))

# The process rules keep their own entry paragraph. Older installs have no
# flow-start-command block around it: the upgrade must report MANUAL and must not
# rewrite a hand-written rules file. Strip only the marker lines.
$flowRule = @(Get-ChildItem -LiteralPath "$proj\.harness\rules" -File | Where-Object {
    (Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8) -match 'harness:upgrade:begin\s+id=flow-start-command' })[0].FullName
$flowNoBlock = @([System.IO.File]::ReadAllLines($flowRule, [System.Text.Encoding]::UTF8) |
    Where-Object { $_ -notmatch 'harness:upgrade:(begin|end)\s+id=flow-start-command' })
[System.IO.File]::WriteAllLines($flowRule, $flowNoBlock, (New-Object System.Text.UTF8Encoding($false)))
$flowBefore = [System.IO.File]::ReadAllText($flowRule, [System.Text.Encoding]::UTF8)

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

# A skill compiled before 1.31.8 still carries the old description clause that
# told the model requirements were already clear (read as permission to skip
# request-analysis and summary.md). -MergeSkills must migrate that sentence while
# keeping every other project-tuned description untouched.
$staleDesc = -join @(
    [char]0x9700, [char]0x6C42, [char]0x5DF2, [char]0x660E, [char]0x786E, [char]0x3001,
    [char]0x9700, [char]0x8981, [char]0x5199, [char]0x6216, [char]0x6539, [char]0x4EE3,
    [char]0x7801, [char]0x65F6, [char]0x4F7F, [char]0x7528, [char]0x3002
)
New-Item -ItemType Directory -Force -Path "$proj\.harness\skills\main-dev\merge-stale" | Out-Null
$staleInstalled = @(
    '---',
    'name: merge-stale',
    ('description: project-tuned start ' + $staleDesc),
    '---',
    '',
    '<!-- harness:package:begin mode -->',
    'old-stale-package',
    '<!-- harness:package:end -->',
    '',
    '<!-- harness:project:begin bindings -->',
    '## Project bindings',
    '- cache: StaleCache',
    '<!-- harness:project:end -->'
)
[System.IO.File]::WriteAllLines("$proj\.harness\skills\main-dev\merge-stale\SKILL.md", $staleInstalled, (New-Object System.Text.UTF8Encoding($false)))

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

# Renamed skill: the project keeps the template skill under its own directory
# name (04-sql-review instead of 14-sql-review). Matching is by frontmatter name.
New-Item -ItemType Directory -Force -Path "$proj\.harness\skills\biz-dev\04-renamed-probe" | Out-Null
[System.IO.File]::WriteAllLines("$proj\.harness\skills\biz-dev\04-renamed-probe\SKILL.md", @(
    '---',
    'name: renamed-probe',
    'description: renamed tuned description',
    '---',
    '',
    '# renamed skill',
    '',
    '<!-- harness:package:begin mode -->',
    'old-renamed-package',
    '<!-- harness:package:end -->',
    '',
    '<!-- harness:project:begin bindings -->',
    '## Project bindings',
    '- cache: RenamedCache',
    '<!-- harness:project:end -->'
), (New-Object System.Text.UTF8Encoding($false)))

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

# agents-delta must accept the template's bold command-table label (the template
# uses "**...**", not a heading). When only markdown headings counted as
# sections, every freshly installed AGENTS.md reported [MISSING] and exited 1.
$deltaOut = & powershell -NoProfile -ExecutionPolicy Bypass -File "$proj\scripts\agents-delta.ps1" -Root $proj 2>&1 | Out-String
Check 'agents-delta accepts the bold command-table label' ($LASTEXITCODE -eq 0)

# Deliberately old required list (no sqlGate, legacy ps1 entry): the upgrade
# must print a machine-readable delta so a human can merge the new entries and
# remove the ps1-only requirement in favour of requiredAnyOf.
Set-Content -LiteralPath "$proj\scripts\harness-required.json" -Value '{"_note":"old install","required":["AGENTS.md","scripts/red-line-scan.ps1"]}' -Encoding UTF8
# ------------------------------------------------------------ fake package
Set-Content -LiteralPath "$newPkg\VERSION" -Value 'HARNESS-BOOTSTRAP VERSION 9.9.9' -Encoding ASCII
# update-harness fails early when the package's checker is missing, so the fake
# package must carry it even though this test runs with -SkipVerify.
Copy-Item -LiteralPath "$pkg\assets\scripts\verify-harness.ps1" -Destination "$newPkg\assets\scripts\verify-harness.ps1"
Copy-Item -LiteralPath "$pkg\assets\scripts\stage-gate.ps1" -Destination "$newPkg\assets\scripts\stage-gate.ps1"
Add-Content -LiteralPath "$newPkg\assets\scripts\stage-gate.ps1" -Value '# upgrade-test-marker' -Encoding ASCII
Set-Content -LiteralPath "$newPkg\assets\scripts\new-tool.ps1" -Value '# new tool' -Encoding ASCII
# The new package must carry the config for the MANUAL branch to be exercised.
Copy-Item -LiteralPath "$pkg\assets\scripts\red-line-rules.json" -Destination "$newPkg\assets\scripts\red-line-rules.json"
Copy-Item -LiteralPath "$pkg\assets\scripts\harness-required.json" -Destination "$newPkg\assets\scripts\harness-required.json"
# Simulate a future package key that this updater does not merge: the dry run
# must name it, otherwise the new script would read a missing key and skip its
# check without a word.
$npCfg = (Get-Content -LiteralPath "$newPkg\assets\scripts\harness-required.json" -Raw -Encoding UTF8) | ConvertFrom-Json
$npCfg | Add-Member -NotePropertyName futureBlock -NotePropertyValue ([pscustomobject]@{ enabled = $true }) -Force
[System.IO.File]::WriteAllText("$newPkg\assets\scripts\harness-required.json", (($npCfg | ConvertTo-Json -Depth 10) + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
# Python scanners are package-owned machinery: they must be UPDATE, not MANUAL.
Copy-Item -LiteralPath "$pkg\assets\scripts\red-line-scan.py" -Destination "$newPkg\assets\scripts\red-line-scan.py"
Add-Content -LiteralPath "$newPkg\assets\scripts\red-line-scan.py" -Value '# upgrade-test-marker' -Encoding ASCII
# An installed skill that differs must be MANUAL unless -UpdateSkills is given.
# The uncompiled fixture keeps a slot marker; the compiled one has none.
New-Item -ItemType Directory -Force -Path "$newPkg\assets\.harness\skills" | Out-Null
Copy-Item -LiteralPath "$pkg\assets\.harness\skills\README.md" -Destination "$newPkg\assets\.harness\skills\README.md"
New-Item -ItemType Directory -Force -Path "$newPkg\assets\.harness\skills\main-dev\coding-skill" | Out-Null
Set-Content -LiteralPath "$newPkg\assets\.harness\skills\main-dev\coding-skill\SKILL.md" `
    -Value @('# installed skill', '', 'body', '<!-- upgraded-skill -->') -Encoding UTF8
New-Item -ItemType Directory -Force -Path "$newPkg\assets\.harness\skills\main-dev\compiled-skill" | Out-Null
Set-Content -LiteralPath "$newPkg\assets\.harness\skills\main-dev\compiled-skill\SKILL.md" `
    -Value @('# compiled skill', '', '<!-- slot:data.access -->', 'body', '<!-- upgraded-compiled -->') -Encoding UTF8
# Marker-based template: the package block changed, the project block still has
# a slot in the template (the installed copy supplies the compiled body).
New-Item -ItemType Directory -Force -Path "$newPkg\assets\.harness\skills\main-dev\merge-skill" | Out-Null
Set-Content -LiteralPath "$newPkg\assets\.harness\skills\main-dev\merge-skill\SKILL.md" -Value @(
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
# Template for the stale-description fixture: the installed copy carries the
# pre-1.31.8 clause, the package carries the current description.
New-Item -ItemType Directory -Force -Path "$newPkg\assets\.harness\skills\main-dev\merge-stale" | Out-Null
Set-Content -LiteralPath "$newPkg\assets\.harness\skills\main-dev\merge-stale\SKILL.md" -Value @(
    '---',
    'name: merge-stale',
    'description: template description',
    '---',
    '',
    '# stale skill',
    '',
    '<!-- harness:package:begin mode -->',
    '## new package section',
    'new-stale-package',
    '<!-- harness:package:end -->',
    '',
    '<!-- harness:project:begin bindings -->',
    '## Project bindings (fill at install)',
    '- cache: <!-- slot:cache.api -->',
    '<!-- harness:project:end -->'
) -Encoding UTF8
# Legacy template: the installed copy has no markers, so adoption is by heading.
New-Item -ItemType Directory -Force -Path "$newPkg\assets\.harness\skills\main-dev\merge-legacy" | Out-Null
Set-Content -LiteralPath "$newPkg\assets\.harness\skills\main-dev\merge-legacy\SKILL.md" -Value @(
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
New-Item -ItemType Directory -Force -Path "$newPkg\assets\.harness\skills\main-dev\merge-pending" | Out-Null
Set-Content -LiteralPath "$newPkg\assets\.harness\skills\main-dev\merge-pending\SKILL.md" -Value @(
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
# Long-merged template: 130 filler lines plus a package block. The 120-line cap
# was removed because a skill is loaded on demand; this fixture now proves the
# merge still happens above that length (a re-added cap would turn it MANUAL).
New-Item -ItemType Directory -Force -Path "$newPkg\assets\.harness\skills\main-dev\merge-big" | Out-Null
$bigLines = @('---', 'name: merge-big', 'description: template description', '---', '', '# big skill', '<!-- harness:package:begin mode -->')
for ($i = 1; $i -le 130; $i++) { $bigLines += "filler-$i" }
$bigLines += '<!-- harness:package:end -->'
[System.IO.File]::WriteAllLines("$newPkg\assets\.harness\skills\main-dev\merge-big\SKILL.md", $bigLines, (New-Object System.Text.UTF8Encoding($false)))

# Same skill in the template under the canonical directory name.
New-Item -ItemType Directory -Force -Path "$newPkg\assets\.harness\skills\biz-dev\14-renamed-probe" | Out-Null
Set-Content -LiteralPath "$newPkg\assets\.harness\skills\biz-dev\14-renamed-probe\SKILL.md" -Value @(
    '---',
    'name: renamed-probe',
    'description: template description',
    '---',
    '',
    '# renamed skill',
    '',
    '<!-- harness:package:begin mode -->',
    'new-renamed-package',
    '<!-- harness:package:end -->',
    '',
    '<!-- harness:project:begin bindings -->',
    '## Project bindings (fill at install)',
    '- cache: <!-- slot:cache.api -->',
    '<!-- harness:project:end -->'
) -Encoding UTF8
# The change template is package-owned: a newer one must reach the project.
New-Item -ItemType Directory -Force -Path "$newPkg\assets\.harness\changes\_template" | Out-Null
Copy-Item -LiteralPath "$pkg\assets\.harness\changes\_template\summary.md" `
    -Destination "$newPkg\assets\.harness\changes\_template\summary.md"
Add-Content -LiteralPath "$newPkg\assets\.harness\changes\_template\summary.md" `
    -Value '<!-- template-upgrade-marker -->' -Encoding UTF8
Copy-Item -LiteralPath "$pkg\assets\AGENTS.md" -Destination "$newPkg\assets\AGENTS.md"
Add-Content -LiteralPath "$newPkg\assets\AGENTS.md" -Value '<!-- new template line -->' -Encoding UTF8
# The package ships the red-line summary; its R5/R6 check cells are the source
# of truth for the known-row merge.
New-Item -ItemType Directory -Force -Path "$newPkg\assets\.harness" | Out-Null
Copy-Item -LiteralPath "$pkg\assets\.harness\rules" -Destination "$newPkg\assets\.harness\rules" -Recurse
[System.IO.File]::WriteAllLines((Join-Path $newPkg 'assets\.harness\rules\combined-probe.md'), @(
    '# combined probe',
    '<!-- harness:upgrade:begin id=probe-block -->',
    'new-probe-line',
    '<!-- harness:upgrade:end id=probe-block -->',
    '',
    '| R5 | probe-rule | new-check |',
    '| R6 | probe-log | new-log-check |'
), (New-Object System.Text.UTF8Encoding($false)))
New-Item -ItemType Directory -Force -Path "$newPkg\assets\.trae\agents" | Out-Null
Set-Content -LiteralPath "$newPkg\assets\.trae\agents\new-agent.md" -Value '# agent' -Encoding UTF8

# ------------------------------------------------------------------ dry run
Write-Host ''
Write-Host '=== dry run ===' -ForegroundColor Cyan
# CLI parity: the first dry run stays a real -File call; the same input through
# the in-process path must return the same exit code.
$dry = & powershell -NoProfile -ExecutionPolicy Bypass -File "$proj\scripts\update-harness.ps1" -PackagePath $newPkg -Root $proj 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) { Write-Host 'DRY RUN FAILED' -ForegroundColor Red; $fail++ }
$dryCliCode = $LASTEXITCODE
$null = Invoke-Harness "$proj\scripts\update-harness.ps1" @{ PackagePath = $newPkg; Root = $proj } | Out-String
Check 'in-process dry run agrees with -File' ($LASTEXITCODE -eq $dryCliCode)
Write-Host $dry

Check 'fixture skill exists' (Test-Path -LiteralPath "$proj\.harness\skills\main-dev\coding-skill\SKILL.md")
Check 'new package skill exists' (Test-Path -LiteralPath "$newPkg\assets\.harness\skills\main-dev\coding-skill\SKILL.md")
Check 'dry-run plans stage-gate UPDATE' ($dry -match '\[UPDATE\]\s+scripts\\stage-gate\.ps1')
Check 'dry-run plans new-tool ADD'         ($dry -match '\[ADD\s*\]\s+scripts\\new-tool\.ps1')
Check 'dry-run marks AGENTS.md MERGE'      ($dry -match '\[MERGE\s*\]\s+AGENTS\.md')
# Build the relative path from the known layout, not with Substring: on CI the
# TEMP env var can be a short name (RUNNER~1) while Get-ChildItem returns long
# names (runneradmin), and the two lengths do not match.
$redlineRel = '.harness\rules\' + (Split-Path -Leaf $redline)
Check 'dry-run marks red-line MERGE'       ($dry -match '\[MERGE\s*\].*\.harness\\rules\\.*\.md')
Check 'dry-run marks JSON config MANUAL'   ($dry -match '\[MANUAL\]\s+scripts\\red-line-rules\.json')
Check 'dry-run reports required delta'     ($dry -match 'add required:')
Check 'dry-run reports requiredAnyOf'      ($dry -match 'add requiredAnyOf:')
Check 'dry-run reports required removal'   ($dry -match 'remove required:.*scripts/red-line-scan\.ps1')
Check 'dry-run reports sqlGate delta'      ($dry -match 'add sqlGate: true')
Check 'dry-run reports new config blocks'  (($dry -match 'add sqlReview') -and ($dry -match 'add summaryContent') -and ($dry -match 'add recordsTracked') -and ($dry -match 'add reviewLedger'))
Check 'dry-run reports the strict migration default' ($dry -match 'add groundingStrict: false')
Check 'dry-run reports the review ledger migration default' ($dry -match 'add reviewLedgerStrict: false')
Check 'dry-run reports the delivery config' ($dry -match 'add deliveryStatus')
Check 'dry-run reports the delivery strict default' ($dry -match 'add deliveryStatusStrict: false')
# The task-start gate is an adoption switch: the upgrade must offer it as false
# so an existing project's commits are not blocked before it runs harness-start.
Check 'dry-run reports the task-start migration default' ($dry -match 'add requireTaskStart: false')
Check 'dry-run reports the task-start config note' ($dry -match 'add _requireTaskStart')
Check 'dry-run names keys outside the merge whitelist' (($dry -match 'by hand \(not in the merge whitelist\)') -and ($dry -match 'futureBlock'))
Check 'a merged key is not reported as manual' ($dry -notmatch 'merge whitelist[^;]*sqlGate')
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
Check 'dry-run marks project rule MANUAL'  ($dry -match '\[MANUAL\]\s+\.harness\\rules\\.*SQL.*\.md')
# The marked AGENTS block must be planned as an insert, and the rules file whose
# block is missing must be MANUAL (never rewritten automatically).
Check 'dry-run plans the start-command block insert' (($dry -match '\[MERGE\s*\]\s+AGENTS\.md') -and ($dry -match 'start-command block inserted; other lines kept'))
Check 'dry-run marks flow rules MANUAL' (($dry -match '\[MANUAL\s*\]\s+\.harness\\rules\\') -and ($dry -match 'flow-start-command block missing; copy from package'))
# Plan/apply branch order: a rule file with both a red-line table and a block is
# handled as a block merge in the plan, exactly like the apply phase does.
Check 'dry-run merges a combined rule file by block' ($dry -match 'combined-probe\.md\s*\r?\n\s+probe-block block replaced; other lines kept')
Check 'dry-run does not promise a red-line merge for it' (-not ($dry -match 'combined-probe\.md\s*\r?\n\s+known red-line rows merged'))

Write-Host ''
Write-Host '=== dry run with -UpdateSkills ===' -ForegroundColor Cyan
$drySkills = Invoke-Harness "$proj\scripts\update-harness.ps1" @{ PackagePath = $newPkg; Root = $proj; UpdateSkills = $true } | Out-String
Check 'dry-run: uncompiled skill UPDATE' ($drySkills -match '\[UPDATE\].*main-dev\\coding-skill\\SKILL\.md')
Check 'dry-run: compiled skill MANUAL' ((($drySkills -match '\[MANUAL\].*main-dev\\compiled-skill\\SKILL\.md') -and ($drySkills -match 'no slot markers')))
Check 'dry-run: skill index MANUAL' ($drySkills -match '\[MANUAL\].*\.harness\\skills\\README\.md')
$dryForce = Invoke-Harness "$proj\scripts\update-harness.ps1" @{ PackagePath = $newPkg; Root = $proj; UpdateSkills = $true; ForceSkills = $true } | Out-String
Check 'dry-run warns that -ForceSkills resets skills' ($dryForce -match 'ForceSkills resets installed skills')

Write-Host ''
Write-Host '=== dry run with -MergeSkills ===' -ForegroundColor Cyan
$dryMerge = Invoke-Harness "$proj\scripts\update-harness.ps1" @{ PackagePath = $newPkg; Root = $proj; MergeSkills = $true } | Out-String
Check 'dry-run: marker skill MERGE' ($dryMerge -match '\[MERGE\s*\].*main-dev\\merge-skill\\SKILL\.md')
Check 'dry-run: legacy skill MERGE' ($dryMerge -match '\[MERGE\s*\].*main-dev\\merge-legacy\\SKILL\.md')
Check 'dry-run: missing project block PENDING' ($dryMerge -match '\[PENDING\s*\].*main-dev\\merge-pending\\SKILL\.md')
Check 'dry-run: long merged skill MERGE (no line cap)' ($dryMerge -match '\[MERGE\s*\].*main-dev\\merge-big\\SKILL\.md')
Check 'dry-run: renamed skill MERGE' ($dryMerge -match '\[MERGE\s*\].*biz-dev\\04-renamed-probe\\SKILL\.md')
Check 'dry-run: stale description migration is named' (($dryMerge -match '\[MERGE\s*\].*main-dev\\merge-stale\\SKILL\.md') -and ($dryMerge -match 'stale pre-1.31.8 description clause replaced'))
Check 'dry-run: renamed match is explained' ($dryMerge -match 'matched by frontmatter name')
Check 'dry-run: no line-limit reason' ($dryMerge -notmatch 'hard limit 120')

# -------------------------------------------------------------------- apply
Write-Host ''
Write-Host '=== apply ===' -ForegroundColor Cyan
Invoke-Harness "$proj\scripts\update-harness.ps1" @{ PackagePath = $newPkg; Root = $proj; Apply = $true; SkipHooks = $true; SkipVerify = $true } | Out-String
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
# The content checks read these two blocks. An upgraded project that only got the
# new script but not the config would run check-summary with the content gate
# silently disabled, so the merge must add them.
Check 'required JSON merged: sqlReview added' ($mergedConfig.PSObject.Properties.Name -contains 'sqlReview')
Check 'required JSON merged: summaryContent added' ($mergedConfig.PSObject.Properties.Name -contains 'summaryContent')
Check 'required JSON merged: recordsTracked added' ($mergedConfig.PSObject.Properties.Name -contains 'recordsTracked')
# Strict mode is a migration default: an upgraded project must keep WARN until
# its older skills are re-anchored, otherwise the first verify goes red.
Check 'required JSON merged: groundingStrict is false on upgrade' ($mergedConfig.PSObject.Properties.Name -contains 'groundingStrict' -and $mergedConfig.groundingStrict -eq $false)
# The review ledger block is copied; strict is the same migration default so an
# upgraded project without a review table only warns on its first run.
Check 'required JSON merged: reviewLedger added' ($mergedConfig.PSObject.Properties.Name -contains 'reviewLedger')
Check 'required JSON merged: reviewLedgerStrict is false on upgrade' ($mergedConfig.PSObject.Properties.Name -contains 'reviewLedgerStrict' -and $mergedConfig.reviewLedgerStrict -eq $false)
Check 'required JSON merged: deliveryStatus added' ($mergedConfig.PSObject.Properties.Name -contains 'deliveryStatus')
Check 'required JSON merged: deliveryStatusStrict is false on upgrade' ($mergedConfig.PSObject.Properties.Name -contains 'deliveryStatusStrict' -and $mergedConfig.deliveryStatusStrict -eq $false)
# The task-start gate is merged as false: it is off by default on a fresh install
# too, and the team turns it on after adopting the entry point.
Check 'required JSON merged: requireTaskStart is false on upgrade' ($mergedConfig.PSObject.Properties.Name -contains 'requireTaskStart' -and $mergedConfig.requireTaskStart -eq $false)
# The explanatory note travels with the switch, otherwise the merged key is a
# bare false with no guidance for the team that adopts harness-start.
$noteName = @($mergedConfig.PSObject.Properties.Name | Where-Object { $_.StartsWith('_requireTaskStart') })
Check 'required JSON merged: the task-start note follows the key' ($noteName.Count -eq 1)
Check 'summaryContent keeps the acceptance needles' (@($mergedConfig.summaryContent.acceptance).Count -gt 0)
Check 'required JSON merged: project note kept' ($mergedConfig._note -eq 'old install')
Check 'required JSON merged: legacy ps1 entry removed' (-not (@($mergedConfig.required) -contains 'scripts/red-line-scan.ps1'))
Check 'required JSON merged: package entries added' (@($mergedConfig.required) -contains 'scripts/stage-gate.ps1')
Check 'no @{...} junk file left in the package root' (@(Get-ChildItem -LiteralPath $pkg -Force -Filter '@{*' -ErrorAction SilentlyContinue).Count -eq 0)
Check 'AGENTS.md untouched' ((Get-Content -LiteralPath "$proj\AGENTS.md" -Raw) -notmatch 'new template line')

# R5/R6 check cells and the record-association line are copied into the project
# by the known-line merge. If the template wraps that prose in <...>, every
# upgraded project fails verify-harness with "template placeholder left".
# Read as UTF-8 explicitly: PS 5.1 Select-String would decode a BOM-less file as
# ANSI. The Chinese assertion text is built from code points because this file
# must stay pure ASCII (a .ps1 without a BOM is parsed as ANSI).
$agentsMerged = [System.IO.File]::ReadAllLines("$proj\AGENTS.md", [System.Text.Encoding]::UTF8)
$r5Line = @($agentsMerged | Where-Object { $_ -match '^\| R5 ' })[0]
$r6Line = @($agentsMerged | Where-Object { $_ -match '^\| R6 ' })[0]
$recordLine = @($agentsMerged | Where-Object { $_ -match 'HARNESS_ALLOW_NO_RECORD' })[0]
$manualReview = -join @([char]0x4EBA, [char]0x5DE5, [char]0x590D, [char]0x6838)
Check 'merged R5 line found' ($null -ne $r5Line)
Check 'merged R5 cell has no template angle brackets' (($null -ne $r5Line) -and ($r5Line -notmatch '<[^<>]+>'))
Check 'merged R6 cell has no template angle brackets' (($null -ne $r6Line) -and ($r6Line -notmatch '<[^<>]+>'))
Check 'merged R5 cell keeps the scoped wording' (($null -ne $r5Line) -and ($r5Line -match $manualReview))
Check 'merged record line found' ($null -ne $recordLine)
Check 'merged record line has no template angle brackets' (($null -ne $recordLine) -and ($recordLine -notmatch '<[^<>]+>'))
Check '.py scanner replaced' ((Select-String -LiteralPath "$proj\scripts\red-line-scan.py" -Pattern 'upgrade-test-marker' -Quiet))
Check 'installed skill untouched by default' ((Get-Content -LiteralPath "$proj\.harness\skills\main-dev\coding-skill\SKILL.md" -Raw) -notmatch 'upgraded-skill')
Check 'change template replaced' ((Get-Content -LiteralPath "$proj\.harness\changes\_template\summary.md" -Raw -Encoding UTF8) -match 'template-upgrade-marker')
Check 'project rule untouched' ((Get-Content -LiteralPath $otherRule.FullName -Raw -Encoding UTF8) -match 'project-only-rule-line')

# Known-row merge: only the R5/R6 check cell is framework-owned.
$srcR5 = @([System.IO.File]::ReadAllLines((Join-Path $newPkg ('assets\' + $redlineRel)), [System.Text.Encoding]::UTF8) |
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

# The combined file proves the apply phase took the block branch, not the
# red-line branch: the block content changed, the R5 check cell did not.
$combinedAfter = [System.IO.File]::ReadAllLines($combinedDst, [System.Text.Encoding]::UTF8)
Check 'combined rule: block replaced' (@($combinedAfter | Where-Object { $_ -eq 'new-probe-line' }).Count -eq 1)
Check 'combined rule: old block gone' (@($combinedAfter | Where-Object { $_ -eq 'old-probe-line' }).Count -eq 0)
Check 'combined rule: red-line row left to the project' (@($combinedAfter | Where-Object { $_ -match '^\| R5 \| probe-rule \| old-check \|' }).Count -eq 1)

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

# Marked block merge: inserted once after the title, the older unmarked copy is
# replaced (not duplicated), and the project-only line survives.
$startBegin = @($agentsFinal | Where-Object { $_ -match 'harness:upgrade:begin\s+id=start-command' })
$startEnd = @($agentsFinal | Where-Object { $_ -match 'harness:upgrade:end\s+id=start-command' })
$startCmd = @($agentsFinal | Where-Object { $_ -match 'powershell -NoProfile -ExecutionPolicy Bypass -File scripts\\harness-start\.ps1 -Feature' })
$customLine = @($agentsFinal | Where-Object { $_ -match 'project-custom-agents-line' })
Check 'AGENTS start-command block inserted' (($startBegin.Count -eq 1) -and ($startEnd.Count -eq 1))
Check 'AGENTS start command appears once' ($startCmd.Count -eq 1)
Check 'AGENTS project-only line kept' ($customLine.Count -eq 1)
Check 'AGENTS block markers are paired in order' (($startBegin.Count -eq 1) -and ($startEnd.Count -eq 1) -and
    ([array]::IndexOf($agentsFinal, $startBegin[0]) -lt [array]::IndexOf($agentsFinal, $startEnd[0])))
Check 'flow rules file left untouched (MANUAL)' ([System.IO.File]::ReadAllText($flowRule, [System.Text.Encoding]::UTF8) -eq $flowBefore)
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
Invoke-Harness "$proj\scripts\update-harness.ps1" @{ PackagePath = $newPkg; Root = $proj; Apply = $true; UpdateSkills = $true; SkipHooks = $true; SkipVerify = $true; PruneBackups = $true } | Out-String
if ($LASTEXITCODE -ne 0) { Write-Host 'SKILL APPLY FAILED' -ForegroundColor Red; $fail++ }

Check 'installed skill replaced with -UpdateSkills' ((Get-Content -LiteralPath "$proj\.harness\skills\main-dev\coding-skill\SKILL.md" -Raw) -match 'upgraded-skill')
# A second upgrade must not insert the marked block again.
$agentsRepeat = @([System.IO.File]::ReadAllLines("$proj\AGENTS.md", [System.Text.Encoding]::UTF8))
Check 'AGENTS block stays single after a repeat upgrade' (
    (@($agentsRepeat | Where-Object { $_ -match 'harness:upgrade:begin\s+id=start-command' }).Count -eq 1) -and
    (@($agentsRepeat | Where-Object { $_ -match 'harness:upgrade:end\s+id=start-command' }).Count -eq 1) -and
    (@($agentsRepeat | Where-Object { $_ -match 'project-custom-agents-line' }).Count -eq 1))
# Once the block is current the plan must not keep advertising a block change.
$dryRepeat = Invoke-Harness "$proj\scripts\update-harness.ps1" @{ PackagePath = $newPkg; Root = $proj } | Out-String
Check 'dry-run omits the block note when the block is current' ($dryRepeat -notmatch 'start-command block (inserted|replaced)')
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
Invoke-Harness "$proj\scripts\update-harness.ps1" @{ PackagePath = $newPkg; Root = $proj; Apply = $true; MergeSkills = $true; SkipHooks = $true; SkipVerify = $true } | Out-String
if ($LASTEXITCODE -ne 0) { Write-Host 'MERGE APPLY FAILED' -ForegroundColor Red; $fail++ }

$mergeAfter = [System.IO.File]::ReadAllText("$proj\.harness\skills\main-dev\merge-skill\SKILL.md", [System.Text.Encoding]::UTF8)
Check 'merge: package text refreshed' ($mergeAfter -match 'new-package-line')
Check 'merge: old package text gone' ($mergeAfter -notmatch 'old-package-line')
Check 'merge: project block kept' ($mergeAfter -match 'ProjectCache')
Check 'merge: project-only block kept' ($mergeAfter -match 'keep-me')
Check 'merge: project description kept' ($mergeAfter -match 'description: project-tuned description')

# The stale clause is the only frontmatter text -MergeSkills may rewrite; the
# project prefix must survive.
$newClause = -join @(
    [char]0x52A8, [char]0x4EE3, [char]0x7801, [char]0x524D, [char]0x4F7F, [char]0x7528,
    [char]0xFF0C, [char]0x5148, [char]0x6309, [char]0x7B2C, ' 0 ',
    [char]0x6B65, [char]0x786E, [char]0x8BA4, [char]0x53D8, [char]0x66F4,
    [char]0x8BB0, [char]0x5F55, [char]0x5DF2, [char]0x843D, [char]0x76D8, [char]0x3002
)
$staleAfter = [System.IO.File]::ReadAllText("$proj\.harness\skills\main-dev\merge-stale\SKILL.md", [System.Text.Encoding]::UTF8)
Check 'stale: package text refreshed' ($staleAfter -match 'new-stale-package')
Check 'stale: description migrated to the new clause' ($staleAfter.Contains($newClause))
Check 'stale: project prefix kept' ($staleAfter -match 'description: project-tuned start ')
Check 'stale: old clause gone' ($staleAfter -notmatch [regex]::Escape($staleDesc))
Check 'stale: project binding kept' ($staleAfter -match 'StaleCache')

# A skill installed under a project-chosen directory name must still be found.
$renamedAfter = [System.IO.File]::ReadAllText("$proj\.harness\skills\biz-dev\04-renamed-probe\SKILL.md", [System.Text.Encoding]::UTF8)
Check 'renamed: package text refreshed' ($renamedAfter -match 'new-renamed-package')
Check 'renamed: old package text gone' ($renamedAfter -notmatch 'old-renamed-package')
Check 'renamed: project binding kept' ($renamedAfter -match 'RenamedCache')
Check 'renamed: template slot did not leak' ($renamedAfter -notmatch '<!--\s*slot:')
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
# The 120-line cap is gone: a long merge must be written, not skipped.
$bigAfter = [System.IO.File]::ReadAllText($bigFile, [System.Text.Encoding]::UTF8)
Check 'big: merged above the old cap' (($bigAfter -ne $bigBefore) -and ($bigAfter -match 'filler-130'))

$mergeStable = [System.IO.File]::ReadAllText("$proj\.harness\skills\main-dev\merge-skill\SKILL.md", [System.Text.Encoding]::UTF8)
$legacyStable = [System.IO.File]::ReadAllText("$proj\.harness\skills\main-dev\merge-legacy\SKILL.md", [System.Text.Encoding]::UTF8)
Invoke-Harness "$proj\scripts\update-harness.ps1" @{ PackagePath = $newPkg; Root = $proj; Apply = $true; MergeSkills = $true; SkipHooks = $true; SkipVerify = $true } | Out-String
if ($LASTEXITCODE -ne 0) { Write-Host 'MERGE REPEAT FAILED' -ForegroundColor Red; $fail++ }
Check 'merge second run is idempotent' ([System.IO.File]::ReadAllText("$proj\.harness\skills\main-dev\merge-skill\SKILL.md", [System.Text.Encoding]::UTF8) -eq $mergeStable)
Check 'legacy second run is idempotent' ([System.IO.File]::ReadAllText("$proj\.harness\skills\main-dev\merge-legacy\SKILL.md", [System.Text.Encoding]::UTF8) -eq $legacyStable)

# PENDING is not a failure, but an upgrade that left a skill on its old package
# text must be visible afterwards: the audit line carries the count.
$markerAfterMerge = Get-Content -LiteralPath "$proj\.harness\.installed-version" -Raw -Encoding UTF8
Check 'audit line records the pending count' ($markerAfterMerge -match 'pending: 1')

Write-Host ''
Write-Host '=== apply with -ForceSkills ===' -ForegroundColor Cyan
Invoke-Harness "$proj\scripts\update-harness.ps1" @{ PackagePath = $newPkg; Root = $proj; Apply = $true; UpdateSkills = $true; ForceSkills = $true; SkipHooks = $true; SkipVerify = $true } | Out-String
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
Set-Content -LiteralPath "$newPkg\assets\scripts\verify-harness.ps1" -Value 'exit 0' -Encoding ASCII
Invoke-Harness "$proj\scripts\update-harness.ps1" @{ PackagePath = $newPkg; Root = $proj; Apply = $true; SkipHooks = $true; PruneBackups = $true } | Out-String
if ($LASTEXITCODE -ne 0) { Write-Host 'VERIFIED APPLY FAILED' -ForegroundColor Red; $fail++ }
$upgradeDirs = @(Get-ChildItem -LiteralPath "$proj\.harness\upgrade" -Directory -Force -ErrorAction SilentlyContinue)
Check 'verified upgrade prunes backups' ($upgradeDirs.Count -eq 0)
$marker = Get-Content -LiteralPath "$proj\.harness\.installed-version" -Raw -Encoding UTF8
Check 'audit records backup deletion' ($marker -match 'backup: deleted after verification')

Write-Host ''
Write-Host '=== bootstrap from the new package ===' -ForegroundColor Cyan
# A-path entry: assets\upgrade\upgrade-harness.ps1 must upgrade with the NEW
# package's updater. The project's own (old) copy is replaced by a decoy that
# leaves a sentinel, so "the old updater ran" is observable.
$bootstrap = Join-Path $pkg 'assets\upgrade\upgrade-harness.ps1'
if (Test-Path -LiteralPath $bootstrap) {
    $bproj = Join-Path $base 'bootstrap-proj'
    if (Test-Path -LiteralPath $bproj) { Remove-Item -LiteralPath $bproj -Recurse -Force }
    New-Item -ItemType Directory -Force -Path "$bproj\.harness" | Out-Null
    Copy-Item -LiteralPath "$pkg\assets\scripts" -Destination "$bproj\scripts" -Recurse
    foreach ($sub in @('rules', 'wiki', 'modules', 'changes')) {
        Copy-Item -LiteralPath "$pkg\assets\.harness\$sub" -Destination "$bproj\.harness\$sub" -Recurse
    }
    Copy-Item -LiteralPath "$pkg\assets\AGENTS.md" -Destination "$bproj\AGENTS.md"
    Copy-Item -LiteralPath "$pkg\assets\.gitignore" -Destination "$bproj\.gitignore"
    Set-Content -LiteralPath "$bproj\.harness\.installed-version" -Value '1.0.0' -Encoding ASCII
    # Older install: no marked block, plus a project-only line.
    $bAgents = @([System.IO.File]::ReadAllLines("$bproj\AGENTS.md", [System.Text.Encoding]::UTF8) |
        Where-Object { $_ -notmatch 'harness:upgrade:(begin|end)\s+id=start-command' })
    $bAgents += '> bootstrap-custom-line'
    [System.IO.File]::WriteAllLines("$bproj\AGENTS.md", $bAgents, (New-Object System.Text.UTF8Encoding($false)))
    Set-Content -LiteralPath "$bproj\scripts\update-harness.ps1" -Encoding ASCII -Value @(
        'param([string]$Root = ''.'', [string]$PackagePath = '''')',
        '[System.IO.File]::WriteAllText((Join-Path $Root ''old-updater-ran.txt''), ''old'', (New-Object System.Text.UTF8Encoding($false)))',
        'exit 1'
    )
    & powershell -NoProfile -ExecutionPolicy Bypass -File $bootstrap -Root $bproj -PackagePath $pkg `
        -Apply -MergeSkills -SkipHooks -SkipVerify -SkipReport | Out-Null
    Check 'bootstrap upgrade exits 0' ($LASTEXITCODE -eq 0)
    Check 'bootstrap did not run the project old updater' (-not (Test-Path -LiteralPath "$bproj\old-updater-ran.txt"))
    $bAfter = @([System.IO.File]::ReadAllLines("$bproj\AGENTS.md", [System.Text.Encoding]::UTF8))
    Check 'bootstrap inserted the start-command block' (
        (@($bAfter | Where-Object { $_ -match 'harness:upgrade:begin\s+id=start-command' }).Count -eq 1) -and
        (@($bAfter | Where-Object { $_ -match 'harness:upgrade:end\s+id=start-command' }).Count -eq 1))
    Check 'bootstrap kept the project-only line' (@($bAfter | Where-Object { $_ -match 'bootstrap-custom-line' }).Count -eq 1)
} else {
    Write-Host 'FAIL: bootstrap entry missing (assets\upgrade\upgrade-harness.ps1); the core integration case could not run' -ForegroundColor Red
    $fail++
}

Write-Host ''
Write-Host '=== install layout: real sql-review template ===' -ForegroundColor Cyan
$repoRoot = Split-Path -Parent $PSScriptRoot
$realSkillPath = Join-Path $repoRoot 'assets\.harness\skills\biz-dev\14-sql-review\SKILL.md'
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

# Every shipped template must be structurally mergeable, not only sql-review.
# A template with no project block can never be compiled for a real project, and
# a slot outside a project block would be replaced by the next -MergeSkills.
$tplRoot = Join-Path $repoRoot 'assets\.harness\skills'
$tplFiles = @(Get-ChildItem -LiteralPath $tplRoot -Recurse -Filter 'SKILL.md' -File)
$noPrj = 0
$slotOut = 0
foreach ($tf in $tplFiles) {
    $txt = [System.IO.File]::ReadAllText($tf.FullName, [System.Text.Encoding]::UTF8)
    if ($txt -notmatch '<!--\s*harness:project:begin') { $noPrj++; Write-Host ("  no project block: " + $tf.Directory.Name) -ForegroundColor Red }
    $out2 = [regex]::Replace($txt, $prjPat, '')
    if ($out2 -match '<!--\s*slot:') { $slotOut++; Write-Host ("  slot outside a project block: " + $tf.Directory.Name) -ForegroundColor Red }
}
Check ("all {0} templates declare a project block" -f $tplFiles.Count) ($noPrj -eq 0)
Check 'no template leaves a slot outside a project block' ($slotOut -eq 0)

Write-Host ''
Write-Host '=== legacy package layout is still readable ===' -ForegroundColor Cyan
# 1.30.0 and earlier shipped the payload under templates/. The new script must
# read it instead of failing with "not a harness package", otherwise the first
# upgrade after the rename would need a hand-written command.
$legacyPkg = Join-Path $base 'legacypkg'
if (Test-Path -LiteralPath $legacyPkg) { Remove-Item -LiteralPath $legacyPkg -Recurse -Force }
Copy-Item -LiteralPath $newPkg -Destination $legacyPkg -Recurse
Rename-Item -LiteralPath (Join-Path $legacyPkg 'assets') -NewName 'templates'
$outLegacy = Invoke-Harness "$proj\scripts\update-harness.ps1" @{ PackagePath = $legacyPkg; Root = $proj } | Out-String
Check 'legacy templates/ layout accepted' ($LASTEXITCODE -eq 0)
Check 'legacy layout is reported' ($outLegacy -match 'legacy package layout')

Write-Host ''
Write-Host '=== real legacy installs (1.31.20 / 1.31.22) ===' -ForegroundColor Cyan
# The fixtures under tests\fixtures are exact tag snapshots (AGENTS.md, the
# process rules, the change template, harness-required.json, one skill). They
# prove the real upgrade path, not just a synthetic old/new pair.
# The rules file name is Chinese; this test must stay pure ASCII.
$cnFlow = (-join @([char]0x5F00, [char]0x53D1, [char]0x6D41, [char]0x7A0B, [char]0x89C4, [char]0x8303)) + '.md'
# Banner of the start paragraph; the discipline bullets below also mention the
# command, so counting the command alone would count them too.
$cnBanner = -join @([char]0x5F00, [char]0x5DE5, [char]0x7B2C, [char]0x4E00, [char]0x4EF6, [char]0x4E8B)
function New-LegacyProject {
    param([string]$VersionTag, [string]$Dest)
    $fx = Join-Path $PSScriptRoot ('fixtures\legacy-' + $VersionTag)
    if (-not (Test-Path -LiteralPath $fx)) { return $false }
    if (Test-Path -LiteralPath $Dest) { Remove-Item -LiteralPath $Dest -Recurse -Force }
    Copy-Item -LiteralPath $fx -Destination $Dest -Recurse
    New-Item -ItemType Directory -Force -Path "$Dest\scripts" | Out-Null
    New-Item -ItemType Directory -Force -Path "$Dest\.harness\rules" | Out-Null
    New-Item -ItemType Directory -Force -Path "$Dest\.harness\changes" | Out-Null
    New-Item -ItemType Directory -Force -Path "$Dest\.harness\skills\main-dev" | Out-Null
    Move-Item -LiteralPath (Join-Path "$Dest\rules" $cnFlow) -Destination (Join-Path "$Dest\.harness\rules" $cnFlow)
    Move-Item -LiteralPath "$Dest\changes\_template" -Destination "$Dest\.harness\changes\_template"
    Move-Item -LiteralPath "$Dest\skills\coding-skill" -Destination "$Dest\.harness\skills\main-dev\coding-skill"
    Move-Item -LiteralPath "$Dest\harness-required.json" -Destination "$Dest\scripts\harness-required.json"
    Remove-Item -LiteralPath "$Dest\rules", "$Dest\changes", "$Dest\skills" -Recurse -Force
    # Compile the one installed skill: -MergeSkills must be able to locate it,
    # and a remaining slot would make the merge PENDING instead of a write.
    $skillPath = "$Dest\.harness\skills\main-dev\coding-skill\SKILL.md"
    $skillText = [System.IO.File]::ReadAllText($skillPath, [System.Text.Encoding]::UTF8)
    $skillText = [regex]::Replace($skillText, '<!--\s*slot:[^>]*-->', 'PROJECT-FACT')
    $at = $skillText.IndexOf('<!-- harness:project:end -->')
    if ($at -ge 0) {
        $skillText = $skillText.Substring(0, $at) + "- project-marker: keep-me`r`n" + $skillText.Substring($at)
    }
    [System.IO.File]::WriteAllText($skillPath, $skillText, (New-Object System.Text.UTF8Encoding($false)))
    return $true
}

$bootstrapScript = Join-Path $pkg 'assets\upgrade\upgrade-harness.ps1'
$pkgSkillText = [System.IO.File]::ReadAllText((Join-Path $pkg 'assets\.harness\skills\main-dev\coding-skill\SKILL.md'), [System.Text.Encoding]::UTF8)
$skillBlockPat = '(?s)<!--\s*harness:package:begin\s+[A-Za-z0-9-]+\s*-->.*?<!--\s*harness:package:end\s*-->'
$pkgSkillBlocks = (@([regex]::Matches($pkgSkillText, $skillBlockPat)) | ForEach-Object { $_.Value }) -join "`n"

foreach ($ver in @('1.31.20', '1.31.22')) {
    $dst = Join-Path $base ('legacy-' + ($ver -replace '\.', '-'))
    $built = New-LegacyProject -VersionTag $ver -Dest $dst
    Check ("real " + $ver + " fixture present") $built
    if (-not $built) { continue }
    $flowPath = Join-Path "$dst\.harness\rules" $cnFlow
    $flowBefore = [System.IO.File]::ReadAllText($flowPath, [System.Text.Encoding]::UTF8)
    $outReal = & powershell -NoProfile -ExecutionPolicy Bypass -File $bootstrapScript -Root $dst -PackagePath $pkg `
        -Apply -MergeSkills -SkipHooks -SkipVerify 2>&1 | Out-String -Width 4096
    $codeReal = $LASTEXITCODE
    Write-Host $outReal
    Check ("real " + $ver + " upgrade exits 0") ($codeReal -eq 0)

    $agentsReal = @([System.IO.File]::ReadAllLines("$dst\AGENTS.md", [System.Text.Encoding]::UTF8))
    Check ("real " + $ver + " start-command block inserted once") (
        (@($agentsReal | Where-Object { $_ -match 'harness:upgrade:begin\s+id=start-command' }).Count -eq 1) -and
        (@($agentsReal | Where-Object { $_ -match 'harness:upgrade:end\s+id=start-command' }).Count -eq 1))
    # 1.31.22 carries the same paragraph without markers; an exact-match dedupe
    # must leave one copy of the banner, not two.
    Check ("real " + $ver + " start banner appears once") (
        @($agentsReal | Where-Object { $_ -match ('^> \*\*' + [regex]::Escape($cnBanner)) }).Count -eq 1)

    $cfgReal = (Get-Content -LiteralPath "$dst\scripts\harness-required.json" -Raw -Encoding UTF8) | ConvertFrom-Json
    Check ("real " + $ver + " config gains summaryContent") ($cfgReal.PSObject.Properties.Name -contains 'summaryContent')
    Check ("real " + $ver + " config gains recordsTracked") ($cfgReal.PSObject.Properties.Name -contains 'recordsTracked')
    Check ("real " + $ver + " config gains sqlGate") ($cfgReal.PSObject.Properties.Name -contains 'sqlGate')
    Check ("real " + $ver + " requireTaskStart stays false") (
        ($cfgReal.PSObject.Properties.Name -contains 'requireTaskStart') -and ($cfgReal.requireTaskStart -eq $false))

    $tplReal = [System.IO.File]::ReadAllText("$dst\.harness\changes\_template\summary.md", [System.Text.Encoding]::UTF8)
    Check ("real " + $ver + " template refreshed") ($tplReal -match 'Gate result: BLOCKED')
    Check ("real " + $ver + " flow rules left untouched (MANUAL)") (
        [System.IO.File]::ReadAllText($flowPath, [System.Text.Encoding]::UTF8) -eq $flowBefore)
    Check ("real " + $ver + " report marks agents-start-command ACTIVE") ($outReal -match '\[ACTIVE\]\s+agents-start-command')
    Check ("real " + $ver + " report marks summary-template ACTIVE") ($outReal -match '\[ACTIVE\]\s+summary-template')
    Check ("real " + $ver + " report marks flow-start-command MANUAL") ($outReal -match '\[MANUAL\]\s+flow-start-command')

    $skillReal = [System.IO.File]::ReadAllText("$dst\.harness\skills\main-dev\coding-skill\SKILL.md", [System.Text.Encoding]::UTF8)
    Check ("real " + $ver + " skill project binding kept") ($skillReal -match 'project-marker: keep-me')
    Check ("real " + $ver + " skill package block matches the new package") (
        ((@([regex]::Matches($skillReal, $skillBlockPat)) | ForEach-Object { $_.Value }) -join "`n") -eq $pkgSkillBlocks)
}

Write-Host ''
Write-Host '=== workspace manifest (multi-repo) ===' -ForegroundColor Cyan
$ws = Join-Path $base 'ws'
if (Test-Path -LiteralPath $ws) { Remove-Item -LiteralPath $ws -Recurse -Force }
New-Item -ItemType Directory -Force -Path $ws | Out-Null
$wsBackend = Join-Path $ws 'backend'
$null = New-LegacyProject -VersionTag '1.31.20' -Dest $wsBackend
$wsWeb = Join-Path $ws 'web'
New-Item -ItemType Directory -Force -Path $wsWeb | Out-Null
$wsManifest = @'
{
  "repos": [
    { "name": "backend", "path": "backend", "role": "record-owner" },
    { "name": "web", "path": "web", "role": "consumer" }
  ]
}
'@
Set-Content -LiteralPath (Join-Path $ws 'harness.workspace.json') -Value $wsManifest -Encoding UTF8
$wsScript = Join-Path $pkg 'assets\upgrade\upgrade-workspace.ps1'
Check 'workspace script present' (Test-Path -LiteralPath $wsScript)
$wsOut = & powershell -NoProfile -ExecutionPolicy Bypass -File $wsScript -Root $ws -Install -Apply -MergeSkills -SkipHooks -SkipVerify -SkipReport 2>&1 | Out-String -Width 4096
$wsCode = $LASTEXITCODE
Write-Host $wsOut
Check 'workspace run exits 0' ($wsCode -eq 0)
Check 'workspace upgraded the installed repo' (
    (@([System.IO.File]::ReadAllLines("$wsBackend\AGENTS.md", [System.Text.Encoding]::UTF8) |
        Where-Object { $_ -match 'id=start-command' }).Count -ge 1))
Check 'workspace installed the missing repo' (
    (Test-Path -LiteralPath "$wsWeb\AGENTS.md") -and (Test-Path -LiteralPath "$wsWeb\.harness\.installed-version"))
Check 'workspace summary names both repos' (($wsOut -match 'backend') -and ($wsOut -match 'web'))
$wsVerA = @([System.IO.File]::ReadAllLines("$wsBackend\.harness\.installed-version", [System.Text.Encoding]::UTF8))[0].Trim()
$wsVerB = @([System.IO.File]::ReadAllLines("$wsWeb\.harness\.installed-version", [System.Text.Encoding]::UTF8))[0].Trim()
Check 'workspace leaves both repos on one version' ($wsVerA -eq $wsVerB)
# Version drift is a real multi-repo failure: -Strict must refuse it.
Set-Content -LiteralPath "$wsWeb\.harness\.installed-version" -Value '0.0.1' -Encoding ASCII
$null = & powershell -NoProfile -ExecutionPolicy Bypass -File $wsScript -Root $ws -Strict -SkipHooks -SkipVerify -SkipReport 2>&1 | Out-String -Width 4096
Check 'workspace -Strict fails on a version mismatch' ($LASTEXITCODE -ne 0)
# A manifest pointing at a missing directory must fail even without -Strict.
Set-Content -LiteralPath (Join-Path $ws 'harness.workspace.json') -Value '{"repos":[{"name":"gone","path":"missing-repo"}]}' -Encoding UTF8
$null = & powershell -NoProfile -ExecutionPolicy Bypass -File $wsScript -Root $ws -SkipReport 2>&1 | Out-String -Width 4096
Check 'workspace fails on a missing repository' ($LASTEXITCODE -ne 0)

Write-Host ''
if ($fail -eq 0) { Write-Host 'UPDATE TEST OK' -ForegroundColor Green; exit 0 }
Write-Host ("UPDATE TEST FAILURES: {0}" -f $fail) -ForegroundColor Red
exit 1
