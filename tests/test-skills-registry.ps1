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
param([string]$TestRoot = '')
$ErrorActionPreference = 'Stop'
if (-not $TestRoot) {
    $TestRoot = Join-Path $env:TEMP ('hb-tests-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '\test-skills-registry')
}
. (Join-Path $PSScriptRoot 'test-lib.ps1')
$pkg  = Split-Path -Parent $PSScriptRoot
$proj = Join-Path $TestRoot 'proj4'
$fail = 0

function Step([string]$Name) { Write-Host ""; Write-Host "=== $Name ===" -ForegroundColor Cyan }
function Check([string]$Label, [bool]$Ok) {
    if ($Ok) { Write-Host "ok: $Label" }
    else { Write-Host "BAD: $Label" -ForegroundColor Red; $script:fail++ }
}
function RunVerify {
    return (Invoke-Harness "$proj\scripts\verify-harness.ps1" @{ Root = $proj } | Out-String)
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

if (Test-Path -LiteralPath $TestRoot) { Remove-Item -LiteralPath $TestRoot -Recurse -Force }
New-Item -ItemType Directory -Force -Path $TestRoot | Out-Null
Copy-Item "$pkg\assets\scripts" "$proj\scripts" -Recurse
# The fixture skills have no [E1]/[E2] anchors, and a package install is strict.
# Keep this fixture on the upgrade behaviour (WARN) so the registry assertions
# are about registration, not about grounding; the strict switch gets its own
# case at the end.
$fixtureCfgPath = "$proj\scripts\harness-required.json"
$fixtureCfg = (Get-Content -LiteralPath $fixtureCfgPath -Raw -Encoding UTF8) | ConvertFrom-Json
$fixtureCfg.groundingStrict = $false
[System.IO.File]::WriteAllText($fixtureCfgPath, (($fixtureCfg | ConvertTo-Json -Depth 10) + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))

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

Step 'in-process vs -File parity'
# One deliberate CLI run keeps the exit-code contract honest: a regression in
# Complete-Harness or -NoExit must show up here even though the rest is in-process.
$out = RunVerify
$codeIn = $LASTEXITCODE
$outCli = (& powershell -NoProfile -ExecutionPolicy Bypass -File "$proj\scripts\verify-harness.ps1" -Root $proj 2>&1 | Out-String)
$codeCli = $LASTEXITCODE
Check 'parity: exit codes agree' ($codeIn -eq $codeCli)
Check 'parity: both report the same registry failure' (($out -match 'FAIL\] skills-registry') -eq ($outCli -match 'FAIL\] skills-registry'))

Step 'unindexed and unreachable'
$out = RunVerify
Check 'registry FAIL is reported' ($out -match 'FAIL\] skills-registry')
Check 'failing skill is named' ($out -match 'biz-dev/99-extra-helper')
Check 'missing index is named' ($out -match 'not listed in \.harness/skills/README\.md')
Check 'missing entry is named' ($out -match 'no platform entry')
Check 'listed and linked skill is not flagged' (-not ($out -match 'main-dev/demo-skill:'))

Step 'metrics names the skill as unregistered'
$m = (Invoke-Harness "$proj\scripts\metrics.ps1" @{ Root = $proj; Days = 28 } | Out-String)
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
$m = (Invoke-Harness "$proj\scripts\metrics.ps1" @{ Root = $proj; Days = 28 } | Out-String)
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
$g = Invoke-Harness "$proj\scripts\verify-grounding.ps1" @{ Root = $proj } | Out-String
$gCode = $LASTEXITCODE
Check 'long skill: verify-grounding still exits 0' ($gCode -eq 0)
Check 'long skill: reported as a size WARN' ($g -match 'consider moving examples')

Step 'grounding: Chinese stand-in words are not missing paths'
# A real project writes "the record lives in .harness/changes/<feature>/" as a
# bare Chinese word, not as an openable path. It must not FAIL the reference
# check; a genuinely missing harness path still must.
$phSkillDir = New-Skill 'main-dev' 'placeholder-probe' 'placeholder-probe'
$phSkillFile = Join-Path $phSkillDir 'SKILL.md'
$wFeature = (-join ([char]0x7279, [char]0x6027, [char]0x540D))
$wModule  = (-join ([char]0x6A21, [char]0x5757, [char]0x540D))
$phBody = @(
    '---',
    'name: placeholder-probe',
    'description: demo skill whose body names a feature and a module',
    '---',
    '',
    '# placeholder probe',
    '',
    ('- record: `.harness/changes/' + $wFeature + '/summary.md`'),
    ('- card: `.harness/modules/' + $wModule + '.md`'),
    '- real: `.harness/skills/README.md`'
)
[System.IO.File]::WriteAllLines($phSkillFile, $phBody, (New-Object System.Text.UTF8Encoding($false)))
$g = Invoke-Harness "$proj\scripts\verify-grounding.ps1" @{ Root = $proj } | Out-String
Check 'stand-in words do not fail the reference check' (($LASTEXITCODE -eq 0) -and (-not ($g -match 'FAIL\]\s+references')))
Add-Content -LiteralPath $phSkillFile -Value '- broken: `.harness/rules/does-not-exist.md`' -Encoding UTF8
$g = Invoke-Harness "$proj\scripts\verify-grounding.ps1" @{ Root = $proj } | Out-String
Check 'a real missing harness path still fails' (($LASTEXITCODE -eq 1) -and ($g -match 'does-not-exist\.md'))
$keptPh = @([System.IO.File]::ReadAllLines($phSkillFile, [System.Text.Encoding]::UTF8) |
    Where-Object { $_ -notmatch 'does-not-exist' })
[System.IO.File]::WriteAllLines($phSkillFile, $keptPh, (New-Object System.Text.UTF8Encoding($false)))
$g = Invoke-Harness "$proj\scripts\verify-grounding.ps1" @{ Root = $proj } | Out-String
Check 'removing the missing path clears the failure' ($LASTEXITCODE -eq 0)
# Only real template slots are skipped: a genuine Chinese file name that is
# missing must still be reported, or the stand-in list would hide a broken link.
$wRule = (-join ([char]0x7F16, [char]0x7801, [char]0x89C4, [char]0x8303)) + '.md'
Add-Content -LiteralPath $phSkillFile -Value ('- broken zh: `.harness/rules/' + $wRule + '`') -Encoding UTF8
$g = Invoke-Harness "$proj\scripts\verify-grounding.ps1" @{ Root = $proj } | Out-String
Check 'a real Chinese path that is missing still fails' (($LASTEXITCODE -eq 1) -and ($g -match [regex]::Escape($wRule)))
$keptPh = @([System.IO.File]::ReadAllLines($phSkillFile, [System.Text.Encoding]::UTF8) |
    Where-Object { $_ -notmatch 'broken zh' })
[System.IO.File]::WriteAllLines($phSkillFile, $keptPh, (New-Object System.Text.UTF8Encoding($false)))
$g = Invoke-Harness "$proj\scripts\verify-grounding.ps1" @{ Root = $proj } | Out-String
Check 'removing the Chinese path clears the failure' ($LASTEXITCODE -eq 0)

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
# A real AGENTS.md keeps the skills-index marker pair. Those comments used to
# count as "<...>" placeholders, so agentsFilled stayed false and this check
# never ran -- a placeholder tree passed silently.
[System.IO.File]::WriteAllLines("$proj\AGENTS.md", @(
    '# demo project',
    '',
    '<!-- skills-index:begin -->',
    '| cat | skill |',
    '<!-- skills-index:end -->',
    ''
), (New-Object System.Text.UTF8Encoding($false)))
New-Item -ItemType Directory -Force -Path "$proj\src" | Out-Null
Set-Content -LiteralPath "$proj\src\Main.java" -Value 'class Main { }' -Encoding ASCII
New-Item -ItemType Directory -Force -Path "$proj\baseline" | Out-Null
Set-Content -LiteralPath "$proj\baseline\baseline.json" -Value '{"srcRoots":["src"],"testRoots":[]}' -Encoding UTF8
$g = Invoke-Harness "$proj\scripts\verify-grounding.ps1" @{ Root = $proj } | Out-String
$gCode = $LASTEXITCODE
Check 'placeholder tree fails coverage' ($gCode -eq 1)
Check 'failure names the structure tree' ($g -match 'coverage.*structure tree')
[System.IO.File]::WriteAllLines($structPath, @(
    '# structure', '', '```text', 'demo/', '+-- src/', '```', ''
), (New-Object System.Text.UTF8Encoding($false)))
$g = Invoke-Harness "$proj\scripts\verify-grounding.ps1" @{ Root = $proj } | Out-String
Check 'filled tree clears the failure' ($LASTEXITCODE -eq 0)

Step 'coverage: an unfilled wiki table is a warning'
# The tree is filled now. A wiki page copied from the template must be reported
# as "no real row" but stay a WARN: probe cannot count entities, so a hard
# failure here would punish projects whose table is legitimately short.
New-Item -ItemType Directory -Force -Path "$proj\.harness\wiki" | Out-Null
$bizName = (-join ([char]0x4E1A, [char]0x52A1, [char]0x6A21, [char]0x578B)) + '.md'
Copy-Item -LiteralPath (Join-Path $pkg "assets\.harness\wiki\$bizName") -Destination (Join-Path "$proj\.harness\wiki" $bizName) -Force
Set-Content -LiteralPath "$proj\.harness\stack.json" -Value '{"orm":"mybatis","cache":"redis","mq":"present"}' -Encoding UTF8
$g = Invoke-Harness "$proj\scripts\verify-grounding.ps1" @{ Root = $proj } | Out-String
Check 'template wiki table is reported as a warning' ($g -match 'WARN.*no real row')
Check 'coverage warning does not fail the run' ($LASTEXITCODE -eq 0)

Step 'fill-depth: a placeholder left in a rule fails'
# rules/wiki are only scanned once the project claims to be filled (AGENTS.md
# has no "<...>" and code exists). A leftover slot is a template, not a fact;
# fenced code and inline code must stay legal so generics are not flagged.
$phLine = '- name: <' + [char]0x5982 + ' PascalCase>'
Add-Content -LiteralPath $structPath -Value $phLine -Encoding UTF8
$g = Invoke-Harness "$proj\scripts\verify-grounding.ps1" @{ Root = $proj } | Out-String
Check 'leftover placeholder fails fill-depth' (($LASTEXITCODE -eq 1) -and ($g -match '\[FAIL\]\s+fill-depth'))
$kept = @([System.IO.File]::ReadAllLines($structPath, [System.Text.Encoding]::UTF8) | Where-Object { $_ -ne $phLine })
[System.IO.File]::WriteAllLines($structPath, $kept, (New-Object System.Text.UTF8Encoding($false)))
$g = Invoke-Harness "$proj\scripts\verify-grounding.ps1" @{ Root = $proj } | Out-String
Check 'real content passes fill-depth' ($LASTEXITCODE -eq 0)
Add-Content -LiteralPath $structPath -Value ('| a | `List<String>` | `' + [char]0x2026 + '` |') -Encoding UTF8
$g = Invoke-Harness "$proj\scripts\verify-grounding.ps1" @{ Root = $proj } | Out-String
Check 'inline code is not a placeholder' ($LASTEXITCODE -eq 0)

Step 'skills index: the directory is the only source of truth'
# The per-category table used to be maintained by hand in .harness/skills/README.md
# and AGENTS.md, so it drifted whenever a skill was added. Both shipped files now
# carry a marker pair; the fixture has different skills, so the shipped table must
# register as drift, and -Write must bring it back in sync.
Copy-Item -LiteralPath "$pkg\assets\.harness\skills\README.md" -Destination $indexPath -Force
Copy-Item -LiteralPath "$pkg\assets\AGENTS.md" -Destination "$proj\AGENTS.md" -Force
$syncScript = "$proj\scripts\sync-skills-index.ps1"
$si = (Invoke-Harness $syncScript @{ Root = $proj; Check = $true } | Out-String)
$siCode = $LASTEXITCODE
Check 'shipped table is stale for this fixture' ($siCode -eq 1)
Check 'drift is reported under the skills-index name' ($si -match 'skills-index: drift')
Check 'drift names the file it came from' ($si -match 'drift in \.harness/skills/README\.md')
$null = New-Skill 'biz-dev' '97-index-helper' 'index-helper'
$si = (Invoke-Harness $syncScript @{ Root = $proj; Check = $true } | Out-String)
Check 'adding a skill still fails the check' ($LASTEXITCODE -eq 1)
$si = (Invoke-Harness $syncScript @{ Root = $proj; Write = $true } | Out-String)
Check 'write succeeds' ($LASTEXITCODE -eq 0)
$si = (Invoke-Harness $syncScript @{ Root = $proj; Check = $true } | Out-String)
Check 'check passes after write' ($LASTEXITCODE -eq 0)
$written = [System.IO.File]::ReadAllText($indexPath, [System.Text.Encoding]::UTF8)
Check 'the written table lists the new skill' ($written -match '\| biz-dev \| `index-helper` \|')
$out = RunVerify
Check 'verify-harness no longer fails skills-index' (-not ($out -match 'FAIL\]\s+skills-index'))
Check 'verify-harness reports skills-index PASS' ($out -match '\[PASS\]\s+skills-index')

Step 'stale: a recently loaded skill whose evidence changed fails'
# The template puts loaded_skills behind a Chinese label and backticks, and the
# skill key may carry a numeric prefix. Both used to make the FAIL never fire.
$staleDir = New-Skill 'main-dev' 'stale-probe' 'stale-probe'
$staleFile = Join-Path $staleDir 'SKILL.md'
Add-Content -LiteralPath $staleFile -Value @('- verified: 2020-01-01', '- [E2] src/Main.java :: proves a watched file') -Encoding UTF8
New-Item -ItemType Directory -Force -Path "$proj\.harness\changes\t-stale" | Out-Null
$lbl = (-join ([char]0x52A0, [char]0x8F7D, [char]0x6280, [char]0x80FD)) + [char]0xFF1A
$staleSummary = @('# stale probe', '', ('- ' + $lbl + '`loaded_skills: stale-probe`'))
[System.IO.File]::WriteAllLines("$proj\.harness\changes\t-stale\summary.md", $staleSummary, (New-Object System.Text.UTF8Encoding($false)))
$g = Invoke-Harness "$proj\scripts\verify-grounding.ps1" @{ Root = $proj } | Out-String
Check 'loaded + drifted skill fails the stale check' (($LASTEXITCODE -eq 1) -and ($g -match '\[FAIL\]\s+stale'))
$fixed = @([System.IO.File]::ReadAllLines($staleFile, [System.Text.Encoding]::UTF8) |
    ForEach-Object { if ($_ -match '^- verified:') { '- verified: ' + (Get-Date -Format 'yyyy-MM-dd') } else { $_ } })
[System.IO.File]::WriteAllLines($staleFile, $fixed, (New-Object System.Text.UTF8Encoding($false)))
$g = Invoke-Harness "$proj\scripts\verify-grounding.ps1" @{ Root = $proj } | Out-String
Check 're-verifying clears the stale failure' ($LASTEXITCODE -eq 0)

Step 'groundingStrict: an ungrounded skill fails only when switched on'
$strictCfg = (Get-Content -LiteralPath $fixtureCfgPath -Raw -Encoding UTF8) | ConvertFrom-Json
$strictCfg.groundingStrict = $true
[System.IO.File]::WriteAllText($fixtureCfgPath, (($strictCfg | ConvertTo-Json -Depth 10) + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
$g = Invoke-Harness "$proj\scripts\verify-grounding.ps1" @{ Root = $proj } | Out-String
Check 'strict mode fails an ungrounded skill' (($LASTEXITCODE -eq 1) -and ($g -match 'groundingStrict=true'))
$strictCfg.groundingStrict = $false
[System.IO.File]::WriteAllText($fixtureCfgPath, (($strictCfg | ConvertTo-Json -Depth 10) + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
$g = Invoke-Harness "$proj\scripts\verify-grounding.ps1" @{ Root = $proj } | Out-String
Check 'upgrade behaviour keeps it a warning' ($LASTEXITCODE -eq 0)

Step 'an empty project block fails even without strict grounding'
# Deleting the slot markers used to make a skeleton look compiled: no slot, no
# anchor, nothing to fill -- and only a WARN. The project block must carry at
# least one real line, independent of groundingStrict.
$emptyDir = New-Skill 'main-dev' 'empty-probe' 'empty-probe'
$emptyFile = Join-Path $emptyDir 'SKILL.md'
[System.IO.File]::WriteAllLines($emptyFile, @(
    '---',
    'name: empty-probe',
    'description: demo skill whose project block carries no fact',
    '---',
    '',
    '# empty probe',
    '',
    '<!-- harness:package:begin body -->',
    '## when',
    'demo',
    '<!-- harness:package:end -->',
    '',
    '<!-- harness:project:begin bindings -->',
    '## bindings',
    '<!-- harness:project:end -->'
), (New-Object System.Text.UTF8Encoding($false)))
Add-Content -LiteralPath $indexPath -Value '| `empty-probe` | demo |' -Encoding UTF8
New-Entry 'empty-probe' $emptyDir
$g = Invoke-Harness "$proj\scripts\verify-grounding.ps1" @{ Root = $proj } | Out-String
Check 'empty project block fails' (($LASTEXITCODE -eq 1) -and ($g -match 'carry no project fact'))
$filled = @([System.IO.File]::ReadAllLines($emptyFile, [System.Text.Encoding]::UTF8) | ForEach-Object {
    if ($_ -match '^## bindings$') { '## bindings'; '- entry: DemoService#get' } else { $_ }
})
[System.IO.File]::WriteAllLines($emptyFile, $filled, (New-Object System.Text.UTF8Encoding($false)))
$g = Invoke-Harness "$proj\scripts\verify-grounding.ps1" @{ Root = $proj } | Out-String
Check 'one project fact clears it' ($LASTEXITCODE -eq 0)

Step 'missing README is reported once'
Remove-Item -LiteralPath $indexPath -Force
$out = RunVerify
Check 'missing index file is reported' ($out -match 'missing \.harness/skills/README\.md')
Check 'one message instead of one per skill' (-not ($out -match 'not listed in \.harness/skills/README\.md'))

# A copied agent template with an unfilled project path points at a directory
# that does not exist. The package now ships neutral wording, but an upgrade
# never overwrites an existing agent file, so the stale copy must surface.
Step 'agent definitions: template placeholders are a WARN'
$agentDir = "$proj\.trae\agents"
New-Item -ItemType Directory -Force -Path $agentDir | Out-Null
$agentFile = "$agentDir\code-reviewer.md"
[System.IO.File]::WriteAllLines($agentFile, @(
    '---',
    'name: code-reviewer',
    'description: demo reviewer',
    '---',
    '',
    '# demo',
    '',
    '| doc | authority |',
    '| --- | --- |',
    '| interfaces | <interface dir> |'
), (New-Object System.Text.UTF8Encoding($false)))
$out = RunVerify
Check 'placeholder agent is a WARN' (($out -match 'WARN\]\s+agents.*placeholders') -and ($out -match 'code-reviewer\.md'))
$fixed = @([System.IO.File]::ReadAllLines($agentFile, [System.Text.Encoding]::UTF8) | ForEach-Object { $_ -replace '<interface dir>', 'src/main/java' })
[System.IO.File]::WriteAllLines($agentFile, $fixed, (New-Object System.Text.UTF8Encoding($false)))
$out = RunVerify
Check 'filling the placeholder clears the warn' (-not ($out -match 'placeholders'))

Step 'AGENTS.md: an html comment is not a placeholder'
# The skills-index marker pair is a comment, not a slot. A filled AGENTS.md that
# keeps it must not be read as a template; a real <category>/<name> slot still must.
$agentsKeep = [System.IO.File]::ReadAllText("$proj\AGENTS.md", [System.Text.Encoding]::UTF8)
[System.IO.File]::WriteAllLines("$proj\AGENTS.md", @(
    '# demo project',
    '',
    '<!-- skills-index:begin -->',
    '| cat | skill |',
    '<!-- skills-index:end -->',
    ''
), (New-Object System.Text.UTF8Encoding($false)))
$out = RunVerify
Check 'the skills-index comment is not a placeholder' (-not ($out -match 'template placeholder left in AGENTS\.md'))
$slotWord = (-join ([char]0x5206, [char]0x7C7B))
$nameWord = [char]0x540D
[System.IO.File]::AppendAllText("$proj\AGENTS.md", ('# <' + $slotWord + '>/<' + $nameWord + '>' + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
$out = RunVerify
Check 'a real slot is still a placeholder' ($out -match 'template placeholder left in AGENTS\.md')
[System.IO.File]::WriteAllText("$proj\AGENTS.md", $agentsKeep, (New-Object System.Text.UTF8Encoding($false)))

Step 'tracked: ignored core files warn, tracked ones do not'
# .harness can be git-ignored (or never added) and the harness still works on one
# machine -- but its records and gate history never leave it. WARN, not FAIL.
$out = RunVerify
Check 'not a git repo: the tracked check is skipped' ($out -match 'not a git work tree')
$tr = Join-Path $TestRoot 'tracked'
New-Item -ItemType Directory -Force -Path $tr | Out-Null
Copy-Item "$pkg\assets\scripts" "$tr\scripts" -Recurse
New-Item -ItemType Directory -Force -Path "$tr\.harness\rules" | Out-Null
New-Item -ItemType Directory -Force -Path "$tr\.harness\changes" | Out-Null
$flowName = (-join ([char]0x5F00, [char]0x53D1, [char]0x6D41, [char]0x7A0B, [char]0x89C4, [char]0x8303)) + '.md'
Set-Content -LiteralPath "$tr\AGENTS.md" -Value '# tracked probe' -Encoding UTF8
Set-Content -LiteralPath (Join-Path "$tr\.harness\rules" $flowName) -Value '# flow' -Encoding UTF8
Set-Content -LiteralPath "$tr\.harness\changes\README.md" -Value '# changes' -Encoding UTF8
git -C $tr init -q
git -C $tr config user.email t@t.t
git -C $tr config user.name t
# Keep the add quiet: a "LF will be replaced by CRLF" warning reaches stderr and,
# under EAP=Stop, aborts the suite as a NativeCommandError.
git -C $tr config core.autocrlf false
Add-Content -LiteralPath "$tr\.gitignore" -Value '.harness/' -Encoding ASCII
$null = & git -C $tr add -A 2>$null
$out = Invoke-Harness "$tr\scripts\verify-harness.ps1" @{ Root = $tr } | Out-String
Check 'an ignored harness tree is reported as untracked' ($out -match 'harness core files are not tracked')
$null = & git -C $tr add -f .harness 2>$null
$out = Invoke-Harness "$tr\scripts\verify-harness.ps1" @{ Root = $tr } | Out-String
Check 'a tracked harness tree is not reported' (-not ($out -match 'harness core files are not tracked'))
Check 'the tracked check passes when every core file is tracked' ($out -match '\[PASS\]\s+tracked')

Step 'productivity: four proxies, unknown is not a pass'
# This fixture has no gate.jsonl and is not a git repository, so every
# productivity metric must degrade to n/a / unknown. Crediting those tasks as
# first-pass would make the metric useless exactly where evidence is missing.
$pj = (Invoke-Harness "$proj\scripts\metrics.ps1" @{ Root = $proj; Days = 28; Json = $true } | Out-String)
$j = $null
try { $j = ($pj | ConvertFrom-Json) } catch { $j = $null }
Check 'metrics -Json carries the four productivity fields' ($null -ne $j -and
    $null -ne $j.PSObject.Properties['firstPassRate'] -and
    $null -ne $j.PSObject.Properties['gateRoundTrips'] -and
    $null -ne $j.PSObject.Properties['leadTime'] -and
    $null -ne $j.PSObject.Properties['reuseRate'])
Check 'no gate log: first pass rate is n/a' ($null -ne $j -and $null -eq $j.firstPassRate)
Check 'tasks without gate events are unknown, not passes' ($null -ne $j -and $j.gateRoundTrips.unknown -eq $j.tasks)
Check 'no commits: lead time is unknown' ($null -ne $j -and $j.leadTime.measured -eq 0 -and $null -eq $j.leadTime.averageDays)
Check 'no repeated skill: reuse is n/a' ($null -ne $j -and $j.reuseRate.pairs -eq 0 -and $null -eq $j.reuseRate.rate)
$pc = (Invoke-Harness "$proj\scripts\metrics.ps1" @{ Root = $proj; Days = 28 } | Out-String)
Check 'console prints the productivity section' ($pc -match 'productivity:')
Check 'console prints n/a for the unmeasurable metrics' (($pc -match 'first pass rate: n/a') -and ($pc -match 'lead time: n/a'))

Write-Host ''
if ($fail -eq 0) { Write-Host 'SKILLS REGISTRY TEST OK' -ForegroundColor Green; exit 0 }
Write-Host "SKILLS REGISTRY TEST FAILED: $fail check(s)" -ForegroundColor Red
exit 1
