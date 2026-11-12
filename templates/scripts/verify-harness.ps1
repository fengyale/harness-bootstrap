<#
  verify-harness.ps1 -- mechanism-level self check for an installed harness

  WHY
    "agent says it is installed" is not evidence. This script checks the artifacts
    on disk and the gate's actual behaviour, then exits non-zero if anything is off.
    It is the mechanism counterpart of the rule "do not trust self-reports".

  CHECKS
    1. structure    required files exist
    2. frontmatter  every SKILL.md has valid name/description and name matches dir
    3. links        .trae/skills entries resolve to .harness/skills sources
    4. red lines    IDs identical in AGENTS.md, the spec file and red-line-rules.json
    5. gate         git pre-commit / pre-merge-commit hooks installed and call the scanner
    6. runnable     red-line-scan.ps1 actually runs and returns a clean result
    7. resident     AGENTS.md stays under the size budget
    8. grounding    skill paths and evidence anchors (delegates to verify-grounding.ps1)
    9. agents       AGENTS.md contains the fixed information architecture
    10. metrics      task summaries exist (field validity is check 12)
    11. modules      .harness/modules cards have sections and evidence
    12. summary      task summaries pass scripts/check-summary.ps1 (same rules as the gates)
    13. sql-gate     sqlGate policy: rule + runnable gate + hook wiring, or explicit opt-out

  USAGE  (no pwsh on Windows PowerShell 5.1 boxes; Bypass is required by policy)
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify-harness.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify-harness.ps1 -Root D:\proj
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify-harness.ps1 -Quiet

  EXIT CODE
    0 = all checks passed, 1 = at least one FAIL

  NOTE
    Pure ASCII on purpose: PS 5.1 reads .ps1 as ANSI unless it carries a UTF-8 BOM,
    so non-ASCII text inside a script would break parsing. Chinese text lives in data
    files (JSON) which this script reads explicitly as UTF-8.
#>
[CmdletBinding()]
param(
    [string]$Root = (Get-Location).Path,
    [int]$MaxAgentsLines = 150,
    [switch]$Quiet,
    [switch]$IgnoreHooks
)

$ErrorActionPreference = 'Stop'

$rootPath = (Resolve-Path -LiteralPath $Root).Path
$results  = New-Object System.Collections.Generic.List[object]

# Use the PowerShell that exists here: Windows has powershell.exe, a pwsh-only
# box has pwsh. A hardcoded name turned the delegated check into a crash.
$PS = if (Get-Command powershell -ErrorAction SilentlyContinue) { 'powershell' } else { 'pwsh' }

function Add-Result {
    param([string]$Check, [string]$Status, [string]$Detail)
    $results.Add([pscustomobject]@{ Check = $Check; Status = $Status; Detail = $Detail })
}

function Test-RelativePath {
    param([string]$Rel, [string]$Kind)
    $full = Join-Path $rootPath $Rel
    if (Test-Path -LiteralPath $full -PathType Leaf) {
        Add-Result $Kind 'PASS' $Rel
        return $true
    }
    Add-Result $Kind 'FAIL' "missing: $Rel"
    return $false
}

# ---------------------------------------------------------------- 1 structure
# The list of required files lives in harness-required.json: this script must
# stay pure ASCII (PS 5.1 parses .ps1 as ANSI without a BOM), while the file
# names are Chinese. Edit the JSON, not this script, to trim the checklist.
# Prefer the target project's config. A package copy of verify-harness.ps1 is
# often run with -Root D:\proj; reading only $PSScriptRoot would then apply the
# package's sqlGate policy to a different project.
$requiredPath = Join-Path $rootPath 'scripts\harness-required.json'
if (-not (Test-Path -LiteralPath $requiredPath)) {
    $requiredPath = Join-Path $PSScriptRoot 'harness-required.json'
}
$required = @()
$cfg = $null
if (Test-Path -LiteralPath $requiredPath) {
    try {
        $cfg = (Get-Content -LiteralPath $requiredPath -Raw -Encoding UTF8) | ConvertFrom-Json
        $required = @($cfg.required)
    } catch {
        Add-Result 'structure' 'FAIL' 'harness-required.json is not valid JSON'
    }
} else {
    Add-Result 'structure' 'FAIL' 'missing: scripts\harness-required.json'
}

$missing = 0
foreach ($rel in $required) {
    $rel = ($rel -replace '/', '\')
    if (-not (Test-RelativePath $rel 'structure')) { $missing++ }
}
if ($missing -gt 0) { Add-Result 'structure' 'FAIL' "$missing required file(s) missing" }

# Any-of groups: at least one runtime per capability. The scanner ships as
# .ps1 + .py; a project may keep only one. Both missing is still a FAIL.
$anyGroups = @()
if ($cfg -and $cfg.requiredAnyOf) { $anyGroups = @($cfg.requiredAnyOf) }
$anyMiss = 0
foreach ($group in $anyGroups) {
    $rels = @($group | ForEach-Object { ([string]$_ -replace '/', '\') })
    $found = $false
    foreach ($rel in $rels) {
        if (Test-Path -LiteralPath (Join-Path $rootPath $rel) -PathType Leaf) { $found = $true; break }
    }
    if (-not $found) {
        Add-Result 'structure' 'FAIL' ('missing: at least one of ' + ($rels -join ' | '))
        $anyMiss++
    }
}
if ($anyGroups.Count -gt 0 -and $anyMiss -eq 0) {
    Add-Result 'structure' 'PASS' "$($anyGroups.Count) any-of group(s) satisfied"
}

# Hollow files: a required file that exists but is empty passes the "does it
# exist" check while its content is silently gone. A truncated handbook is worse
# than a missing one -- the agent trusts it and finds nothing. Rules and wiki are
# the load-bearing docs, so they must carry real content.
$hollow = 0
$scanned = 0
foreach ($hd in @('.harness\rules', '.harness\wiki')) {
    $dp = Join-Path $rootPath $hd
    if (-not (Test-Path -LiteralPath $dp)) { continue }
    foreach ($f in Get-ChildItem -LiteralPath $dp -Filter *.md -File -Force -ErrorAction SilentlyContinue) {
        $scanned++
        $n = ([System.IO.File]::ReadAllLines($f.FullName, [System.Text.Encoding]::UTF8)).Count
        if ($n -lt 5) {
            Add-Result 'structure' 'FAIL' ('hollow file: {0}\{1} has {2} line(s)' -f $hd, $f.Name, $n)
            $hollow++
        }
    }
}
if ($hollow -eq 0 -and $scanned -gt 0) {
    Add-Result 'structure' 'PASS' "rules/wiki files carry content ($scanned file(s), >=5 lines)"
} elseif ($scanned -eq 0) {
    Add-Result 'structure' 'WARN' 'no rules/wiki file found to inspect (structure check above should have failed)'
}

# platform entry: at least one agent dir with a .md file (any platform), otherwise
# the project is expected to run in checklist mode -- legal, but must be declared.
$agentDirs = @()
if ($cfg -and $cfg.platformEntries -and $cfg.platformEntries.agentDirs) { $agentDirs = @($cfg.platformEntries.agentDirs) }
$agentOk = $false
foreach ($d in $agentDirs) {
    $p = Join-Path $rootPath ($d -replace '/', '\')
    if ((Test-Path -LiteralPath $p) -and (@(Get-ChildItem -LiteralPath $p -Filter *.md -File -ErrorAction SilentlyContinue).Count -gt 0)) {
        $agentOk = $true
        break
    }
}
if ($agentOk) {
    Add-Result 'platform' 'PASS' 'agent entry present'
} else {
    Add-Result 'platform' 'WARN' 'no agent entry: run in checklist mode (see references/platform adapters)'
}

# -------------------------------------------------------------- 2 frontmatter
$skillsRoot = Join-Path $rootPath '.harness\skills'
$skillDirs = @()
if (Test-Path -LiteralPath $skillsRoot) {
    Get-ChildItem -LiteralPath $skillsRoot -Directory -Force | ForEach-Object {
        $cat = $_.Name
        Get-ChildItem -LiteralPath $_.FullName -Directory -Force | ForEach-Object {
            $skillDirs += [pscustomobject]@{ Category = $cat; Name = $_.Name; Dir = $_.FullName }
        }
    }
}

$fmBad = 0
foreach ($s in $skillDirs) {
    $skillFile = Join-Path $s.Dir 'SKILL.md'
    if (-not (Test-Path -LiteralPath $skillFile)) {
        Add-Result 'frontmatter' 'FAIL' "no SKILL.md in $($s.Category)/$($s.Name)"
        $fmBad++
        continue
    }
    $lines = [System.IO.File]::ReadAllLines($skillFile, [System.Text.Encoding]::UTF8)
    if ($lines.Count -lt 4) { Add-Result 'frontmatter' 'FAIL' "$($s.Name): too short"; $fmBad++; continue }
    $ok = ($lines[0].Trim() -eq '---') -and
          ($lines[1] -match '^name:\s*\S') -and
          ($lines[2] -match '^description:\s*\S') -and
          ($lines[3].Trim() -eq '---')
    $declared = if ($lines[1] -match '^name:\s*(\S+)') { $matches[1].Trim() } else { '' }
    $expected = $s.Name -replace '^\d+-', ''
    if (-not $ok) { Add-Result 'frontmatter' 'FAIL' "$($s.Name): malformed frontmatter"; $fmBad++ }
    elseif ($declared -ne $expected) {
        Add-Result 'frontmatter' 'FAIL' "$($s.Name): name '$declared' != dir '$expected'"
        $fmBad++
    }
}
if ($fmBad -eq 0) {
    Add-Result 'frontmatter' 'PASS' "$($skillDirs.Count) skill(s) valid"
}

# -------------------------------------------------------------------- 3 links
# Platform-neutral: any configured discovery dir counts; an index-only setup is
# legal on platforms without auto-discovery.
$discoveryDirs = @()
if ($cfg -and $cfg.platformEntries -and $cfg.platformEntries.skillDirs) { $discoveryDirs = @($cfg.platformEntries.skillDirs) }
# Older installs carry only .trae/.claude in their project-owned config; append
# the known platform dirs so a Codex/CodeBuddy entry is still recognised without
# editing a MANUAL file.
foreach ($builtin in @('.trae/skills', '.claude/skills', '.agents/skills', '.codebuddy/skills')) {
    if ($discoveryDirs -notcontains $builtin) { $discoveryDirs += $builtin }
}

# Prefer a directory that actually holds entries: a platform tool may create an
# empty skills/ dir on first run, and that must not hide a populated sibling.
$foundRoot = $null
$emptyRoot = $null
foreach ($d in $discoveryDirs) {
    $p = Join-Path $rootPath ($d -replace '/', '\')
    if (-not (Test-Path -LiteralPath $p)) { continue }
    if (@(Get-ChildItem -LiteralPath $p -Force -Directory).Count -gt 0) { $foundRoot = $p; break }
    if (-not $emptyRoot) { $emptyRoot = $p }
}
if (-not $foundRoot) { $foundRoot = $emptyRoot }

if ($foundRoot) {
    $linkCount = 0
    $linkBad = 0
    foreach ($entry in Get-ChildItem -LiteralPath $foundRoot -Force -Directory) {
        $linkCount++
        $targetSkill = Join-Path $entry.FullName 'SKILL.md'
        if (-not (Test-Path -LiteralPath $targetSkill)) {
            Add-Result 'links' 'FAIL' "$($entry.Name): no SKILL.md behind it (broken or empty entry)"
            $linkBad++
        }
    }
    if ($linkBad -eq 0) {
        $rootName = Split-Path -Leaf $foundRoot
        Add-Result 'links' 'PASS' "$linkCount skill entr(y/ies) resolve under $rootName"
    }
} else {
    $indexPath = Join-Path $rootPath '.harness\skills\INDEX.md'
    if (Test-Path -LiteralPath $indexPath) {
        Add-Result 'links' 'PASS' 'index-only mode: no discovery dir, .harness\skills\INDEX.md present'
    } else {
        Add-Result 'links' 'WARN' 'no discovery dir and no .harness\skills\INDEX.md: skills will not be found'
    }
}

# ------------------------------------------------- 3b skills registration
# A skill directory that is absent from .harness/skills/README.md and has no
# platform entry is a dead file: nothing discovers it, no summary can record a
# load, and metrics would later mistake "never wired up" for "never used".
$registryBad = 0
$entryNames = @()
foreach ($d in $discoveryDirs) {
    $p = Join-Path $rootPath ($d -replace '/', '\')
    if (-not (Test-Path -LiteralPath $p)) { continue }
    foreach ($e in Get-ChildItem -LiteralPath $p -Force -Directory -ErrorAction SilentlyContinue) {
        $entryNames += $e.Name
    }
}
$indexMode = Test-Path -LiteralPath (Join-Path $skillsRoot 'INDEX.md')
# Without any discovery mechanism (no entry, no INDEX.md) the links check above
# already warns; do not turn every skill into a second failure. The index listing
# is still checked: an unlisted skill is unreadable no matter how it is found.
$entrySideApplies = $indexMode -or ($entryNames.Count -gt 0)
$registryText = ''
$registryPath = Join-Path $skillsRoot 'README.md'
if (Test-Path -LiteralPath $registryPath) {
    $registryText = [System.IO.File]::ReadAllText($registryPath, [System.Text.Encoding]::UTF8)
}
$registryMissing = ($skillDirs.Count -gt 0 -and -not $registryText)
if ($registryMissing) {
    # One failure instead of one per skill: without the index no skill is readable.
    Add-Result 'skills-registry' 'FAIL' 'missing .harness/skills/README.md: copy templates/.harness/skills/README.md and list every skill'
    $registryBad++
}
foreach ($s in $skillDirs) {
    if ($registryMissing) { continue }
    $plain = $s.Name -replace '^\d+-', ''
    $listed = $false
    if ($registryText) {
        foreach ($n in @($s.Name, $plain)) {
            if ($registryText -match ('(?i)(?<![A-Za-z0-9_-])' + [regex]::Escape($n) + '(?![A-Za-z0-9_-])')) { $listed = $true; break }
        }
    }
    $hasEntry = $indexMode
    if (-not $hasEntry -and $entrySideApplies) {
        foreach ($n in @($s.Name, $plain)) {
            if ($entryNames -contains $n) { $hasEntry = $true; break }
        }
    } elseif (-not $entrySideApplies) {
        $hasEntry = $true
    }
    $missing = @()
    if (-not $listed) { $missing += 'not listed in .harness/skills/README.md' }
    if (-not $hasEntry) { $missing += 'no platform entry (run scripts/setup-links.ps1, or add .harness/skills/INDEX.md)' }
    if ($missing.Count -gt 0) {
        Add-Result 'skills-registry' 'FAIL' "$($s.Category)/$($s.Name): $($missing -join '; ')"
        $registryBad++
    }
}
if ($registryBad -eq 0 -and $skillDirs.Count -gt 0) {
    if ($entrySideApplies) {
        Add-Result 'skills-registry' 'PASS' "$($skillDirs.Count) skill(s) listed in the index and reachable from a discovery entry"
    } else {
        Add-Result 'skills-registry' 'PASS' "$($skillDirs.Count) skill(s) listed in the index (no discovery entry yet; see the links warning)"
    }
}

# ---------------------------------------------------------------- 4 red lines
$jsonPath = Join-Path $rootPath 'scripts\red-line-rules.json'
$agentsPath = Join-Path $rootPath 'AGENTS.md'

$jsonIds = @()
if (Test-Path -LiteralPath $jsonPath) {
    try {
        # separate variable: $cfg holds harness-required.json and must not be clobbered
        $rulesCfg = (Get-Content -LiteralPath $jsonPath -Raw -Encoding UTF8) | ConvertFrom-Json
        $jsonIds = @($rulesCfg.rules | ForEach-Object { $_.id })
    } catch {
        Add-Result 'red-lines' 'FAIL' "red-line-rules.json is not valid JSON"
    }
}

$agentsIds = @()
if (Test-Path -LiteralPath $agentsPath) {
    $agentsIds = @(Select-String -LiteralPath $agentsPath -Pattern '^\|\s*(R\d+)\s*\|' -Encoding UTF8 |
        ForEach-Object { $_.Matches[0].Groups[1].Value })
}

# Third copy: the "red-line summary" table in .harness\rules\<encoding spec>.md.
# The header of this check always promised three identical lists, but only two
# were compared -- an edited spec table could drift without any signal.
# The spec file name is Chinese; PS 5.1 parses this file as ANSI, so build the
# name from code points instead of embedding UTF-8 bytes (the same idea as the
# POSIX hook matching the ASCII prefix "SQL").
$specName = ([char]0x7F16) + ([char]0x7801) + ([char]0x89C4) + ([char]0x8303) + '.md'
$specPath = Join-Path (Join-Path $rootPath '.harness\rules') $specName
$specIds = @()
$specTableMissing = $false
if (Test-Path -LiteralPath $specPath) {
    $specIds = @(Select-String -LiteralPath $specPath -Pattern '^\|\s*(R\d+)\s*\|' -Encoding UTF8 |
        ForEach-Object { $_.Matches[0].Groups[1].Value })
    if ($specIds.Count -eq 0) { $specTableMissing = $true }
}

if ($jsonIds.Count -gt 0) {
    $onlyJson = @($jsonIds | Where-Object { $agentsIds -notcontains $_ })
    $onlyAgents = @($agentsIds | Where-Object { $jsonIds -notcontains $_ })
    $onlySpec = @($specIds | Where-Object { $jsonIds -notcontains $_ })
    $missingSpec = @($jsonIds | Where-Object { $specIds -notcontains $_ })
    if ($onlyJson.Count -eq 0 -and $onlyAgents.Count -eq 0 -and $onlySpec.Count -eq 0 -and $missingSpec.Count -eq 0) {
        Add-Result 'red-lines' 'PASS' "$($jsonIds.Count) rule id(s) identical in JSON, AGENTS.md and the rules spec"
    } else {
        $msg = @()
        if ($onlyJson.Count -gt 0)    { $msg += "only in JSON: $($onlyJson -join ',')" }
        if ($onlyAgents.Count -gt 0)  { $msg += "only in AGENTS.md: $($onlyAgents -join ',')" }
        if ($onlySpec.Count -gt 0)    { $msg += "only in the rules spec: $($onlySpec -join ',')" }
        if ($missingSpec.Count -gt 0) { $msg += "missing from the rules spec: $($missingSpec -join ',')" }
        Add-Result 'red-lines' 'FAIL' ($msg -join '; ')
    }
    if ($specTableMissing) {
        Add-Result 'red-lines' 'WARN' 'the rules spec has no red-line summary table (cannot compare the third copy)'
    }
}

# --------------------------------------------------------------------- 5 gate
# Ask git for the EFFECTIVE hooks directory. In a linked worktree
# --absolute-git-dir is .git/worktrees/<name> (git never runs its hooks/);
# --git-path hooks returns the common directory and honours core.hooksPath.
$gitDir = $null
try { $gitDir = (& git -C $rootPath rev-parse --absolute-git-dir 2>$null | Select-Object -First 1) } catch { $gitDir = $null }
if ($gitDir) { $gitDir = ([string]$gitDir).Trim() }

$hooksDir = $null
try { $hooksDir = (& git -C $rootPath rev-parse --git-path hooks 2>$null | Select-Object -First 1) } catch { $hooksDir = $null }
if ($hooksDir) {
    $hooksDir = ([string]$hooksDir).Trim()
    if (-not [System.IO.Path]::IsPathRooted($hooksDir)) {
        $hooksDir = [System.IO.Path]::GetFullPath((Join-Path $rootPath $hooksDir))
    }
}
if (-not $hooksDir) { $hooksDir = Join-Path $rootPath '.git\hooks' }

$hookPath  = Join-Path $hooksDir 'pre-commit'
$mergePath = Join-Path $hooksDir 'pre-merge-commit'
if ($IgnoreHooks) {
    # update-harness -SkipHooks deliberately leaves the old hook in place; the
    # upgrade must not fail on a check the user explicitly opted out of.
    Add-Result 'gate' 'WARN' 'hook check skipped (-IgnoreHooks; reinstall with install-git-hooks.ps1)'
} elseif (-not $gitDir) {
    Add-Result 'gate' 'FAIL' 'no git repository: the gate cannot exist (run git init, then install-git-hooks)'
} elseif (Test-Path -LiteralPath $hookPath) {
    $hookBody = Get-Content -LiteralPath $hookPath -Raw -Encoding UTF8
    # the marker is what separates "our gate" from a hook that merely mentions
    # red-line-scan in a comment; stage-gate gate-proven uses the same marker
    if ($hookBody -match 'red-line-scan' -and $hookBody -match 'harness pre-commit gate') {
        # Git on Unix silently ignores a hook without the executable bit.
        $execOk = $true
        $unixHost = $false
        if (Get-Variable -Name IsLinux -ErrorAction SilentlyContinue) { $unixHost = ($IsLinux -or $IsMacOS) }
        if ($unixHost) {
            try {
                $mode = [System.IO.File]::GetUnixFileMode($hookPath)
                $execOk = (($mode -band [System.IO.UnixFileMode]::UserExecute) -ne 0)
            } catch {
                $execOk = $true
            }
        }
        if (-not $execOk) {
            Add-Result 'gate' 'FAIL' 'pre-commit hook is not executable (chmod +x .git/hooks/pre-commit)'
        } elseif (($hookBody -notmatch 'LATE_SUMMARY') -or ($hookBody -notmatch 'REPLAY_CONTEXT') -or ($hookBody -notmatch 'ASSOC_MISS')) {
            # A hook installed before the summary-order guard existed still looks
            # like the harness gate, so report exactly one FAIL instead of a PASS
            # plus a FAIL for the same hook.
            Add-Result 'gate' 'FAIL' 'pre-commit hook predates the summary-order guard; re-run install-git-hooks.ps1'
        } else {
            Add-Result 'gate' 'PASS' 'git pre-commit hook calls red-line-scan and enforces summary order'
        }
    } else {
        Add-Result 'gate' 'FAIL' 'pre-commit hook exists but is not the harness gate (marker or scanner missing; re-run install-git-hooks.ps1)'
    }
} else {
    Add-Result 'gate' 'FAIL' 'no git pre-commit hook (run scripts\install-git-hooks.ps1)'
}

$postHook = Join-Path $hooksDir 'post-commit'
if ($gitDir -and -not (Test-Path -LiteralPath $postHook)) {
    Add-Result 'gate' 'WARN' 'post-commit missing: bypass rate cannot be measured (re-run install-git-hooks.ps1)'
}

# A merge commit never fires pre-commit; git runs pre-merge-commit instead.
# Missing or foreign merge hook == merges land with no red-line scan at all,
# which is a hole in the same contract the pre-commit hook exists to enforce.
if ($gitDir) {
    if (-not (Test-Path -LiteralPath $mergePath)) {
        Add-Result 'gate' 'FAIL' 'pre-merge-commit missing: merge commits bypass the gate (re-run install-git-hooks.ps1)'
    } else {
        $mergeBody = [System.IO.File]::ReadAllText($mergePath, [System.Text.Encoding]::UTF8)
        # FAIL, not WARN: stage-gate already treats a foreign merge hook as a
        # blocked merge, so verify-harness must not call the same state PASS-ish.
        if ($mergeBody -notmatch 'red-line-scan' -or $mergeBody -notmatch 'harness pre-commit gate') {
            Add-Result 'gate' 'FAIL' 'pre-merge-commit exists but is not the harness gate: merge commits are not scanned (re-run install-git-hooks.ps1)'
        } elseif (($mergeBody -notmatch 'LATE_SUMMARY') -or ($mergeBody -notmatch 'REPLAY_CONTEXT') -or ($mergeBody -notmatch 'ASSOC_MISS')) {
            # Same body, so a stale merge hook means a half-updated installation.
            Add-Result 'gate' 'FAIL' 'pre-merge-commit predates the summary-order guard; re-run install-git-hooks.ps1'
        } else {
            Add-Result 'gate' 'PASS' 'pre-merge-commit hook is the harness gate calling red-line-scan'
        }
    }
}

# ----------------------------------------------------------------- 6 runnable
# The scanner must actually run HERE. Prefer PowerShell, fall back to the python
# twin -- otherwise "0 FAIL" would just mean "this check never executed".
$scanPs = Join-Path $rootPath 'scripts\red-line-scan.ps1'
$scanPy = Join-Path $rootPath 'scripts\red-line-scan.py'
$psHost = $null
if (Get-Command powershell -ErrorAction SilentlyContinue) { $psHost = 'powershell' }
elseif (Get-Command pwsh -ErrorAction SilentlyContinue) { $psHost = 'pwsh' }
$pyHost = $null
if (Get-Command python3 -ErrorAction SilentlyContinue) { $pyHost = 'python3' }
elseif (Get-Command python -ErrorAction SilentlyContinue) { $pyHost = 'python' }

$scanOut = $null
$scanCode = $null
if ((Test-Path -LiteralPath $scanPs) -and $psHost) {
    if ($psHost -eq 'powershell') {
        $scanOut = & powershell -NoProfile -ExecutionPolicy Bypass -File $scanPs -Root $rootPath 2>&1
    } else {
        $scanOut = & pwsh -NoProfile -File $scanPs -Root $rootPath 2>&1
    }
    $scanCode = $LASTEXITCODE
} elseif ((Test-Path -LiteralPath $scanPy) -and $pyHost) {
    $scanOut = & $pyHost $scanPy --root $rootPath 2>&1
    $scanCode = $LASTEXITCODE
}

if ($null -eq $scanCode) {
    Add-Result 'runnable' 'FAIL' 'no runnable scanner (need powershell/pwsh or python3, plus scripts/red-line-scan.*)'
} elseif ($scanCode -eq 0) {
    Add-Result 'runnable' 'PASS' 'red-line-scan runs and reports clean'
} else {
    # exit 1 = the scanner RAN and found violations. On a legacy project that is
    # expected: the gate is incremental (staged diff only). Only a run with no
    # recognisable scan output counts as "did not run".
    $ranLine = @($scanOut | Where-Object { $_ -match 'red-line scan found|red-line scan passed' } | Select-Object -First 1)
    if ($ranLine) {
        Add-Result 'runnable' 'PASS' "scanner runs; legacy violations present, incremental gate only checks new changes: $ranLine"
    } else {
        Add-Result 'runnable' 'FAIL' "scanner crashed (exit $scanCode): $(@($scanOut)[0])"
    }
}

# --------------------------------------------------------------- 6b sql gate
# Three states, because "no rule" used to be indistinguishable from "the rule
# was deleted":
#   sqlGate=true   -> rule + runtime + hook wiring + a real run are all required
#   sqlGate=false  -> the project opted out; the artifacts must be gone as well
#   no sqlGate key -> legacy install: rule and gate must appear as a pair
# A runnability probe is part of the gate: a shipped script that cannot execute
# on this host is the same silent hole as a missing script.
# Rule file names are Chinese, so match the ASCII prefix "SQL" -- the same trick
# the POSIX hook uses.
$sqlGateFlag = $null
$hasSqlFlag = $false
$sqlGateInvalid = $false
if ($cfg -and $cfg.PSObject.Properties.Name -contains 'sqlGate') {
    $hasSqlFlag = $true
    if ($cfg.sqlGate -is [bool]) {
        $sqlGateFlag = [bool]$cfg.sqlGate
    } else {
        # [bool]"false" is True in PowerShell; accepting a string here would
        # silently invert the policy. A non-boolean value is a config error.
        $sqlGateInvalid = $true
    }
}

# Run the gate against a throw-away root. The empty diff must pass (0); a diff
# with SQL but no summary must FAIL (1). Exit 0 on the positive probe means the
# script is a no-op stub that would let every SQL change through.
function Invoke-SqlGateProbe {
    param([string]$GatePs, [string]$GatePy, [string]$ProbeRoot, [string]$DiffPath)
    $code = $null
    if ((Test-Path -LiteralPath $GatePs -PathType Leaf) -and $psHost) {
        if ($psHost -eq 'powershell') {
            $null = & powershell -NoProfile -ExecutionPolicy Bypass -File $GatePs -Root $ProbeRoot -DiffFile $DiffPath 2>&1
        } else {
            $null = & pwsh -NoProfile -File $GatePs -Root $ProbeRoot -DiffFile $DiffPath 2>&1
        }
        $code = $LASTEXITCODE
    } elseif ((Test-Path -LiteralPath $GatePy -PathType Leaf) -and $pyHost) {
        $null = & $pyHost $GatePy --root $ProbeRoot --diff-file $DiffPath 2>&1
        $code = $LASTEXITCODE
    }
    return $code
}

$rulesDir = Join-Path $rootPath '.harness\rules'
$sqlRules = @()
if (Test-Path -LiteralPath $rulesDir) {
    $sqlRules = @(Get-ChildItem -LiteralPath $rulesDir -Filter 'SQL*.md' -File -Force -ErrorAction SilentlyContinue)
}
$sqlPs = Join-Path $rootPath 'scripts\sql-review-gate.ps1'
$sqlPy = Join-Path $rootPath 'scripts\sql-review-gate.py'
$sqlGateShipped = (Test-Path -LiteralPath $sqlPs -PathType Leaf) -or (Test-Path -LiteralPath $sqlPy -PathType Leaf)

if ($sqlGateInvalid) {
    Add-Result 'sql-gate' 'FAIL' 'sqlGate must be a JSON boolean (true/false); a string/null value is not accepted'
} elseif ($hasSqlFlag -and -not $sqlGateFlag) {
    if ($sqlRules.Count -gt 0 -or $sqlGateShipped) {
        Add-Result 'sql-gate' 'FAIL' 'sqlGate=false but SQL rule/gate artifacts are still present; delete them or set sqlGate=true'
    } else {
        Add-Result 'sql-gate' 'PASS' 'SQL gate disabled by project config (sqlGate=false)'
    }
} elseif ($sqlRules.Count -eq 0 -and -not $sqlGateShipped -and -not ($hasSqlFlag -and $sqlGateFlag)) {
    Add-Result 'sql-gate' 'PASS' 'no SQL rule and no SQL gate (legacy project: SQL gate intentionally off)'
} elseif ($sqlRules.Count -eq 0) {
    Add-Result 'sql-gate' 'FAIL' 'SQL gate is required/enabled but .harness/rules/SQL*.md is missing'
} elseif (-not $sqlGateShipped) {
    Add-Result 'sql-gate' 'FAIL' 'SQL rule present but scripts\sql-review-gate.ps1|.py is missing (the rule cannot be enforced)'
} else {
    $gateFile = if (Test-Path -LiteralPath $sqlPs -PathType Leaf) { $sqlPs } else { $sqlPy }
    $gateText = [System.IO.File]::ReadAllText($gateFile, [System.Text.Encoding]::UTF8)
    $gateUsable = $true
    if ($gateText.Length -lt 200 -or $gateText -notmatch 'sql_review') {
        Add-Result 'sql-gate' 'FAIL' "gate file looks hollow or truncated (no sql_review logic): $gateFile"
        $gateUsable = $false
    }

    if ($gateUsable) {
        $probeRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('hb-sql-probe-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $emptyDiff = [System.IO.Path]::GetTempFileName()
        $sqlDiff = [System.IO.Path]::GetTempFileName()
        try {
            New-Item -ItemType Directory -Path $probeRoot -Force | Out-Null
            Set-Content -LiteralPath $emptyDiff -Value '' -Encoding ASCII
            Set-Content -LiteralPath $sqlDiff -Value @(
                'diff --git a/probe.sql b/probe.sql',
                'new file mode 100644',
                'index 0000000..1111111',
                '--- /dev/null',
                '+++ b/probe.sql',
                '@@ -0,0 +1 @@',
                '+select * from t'
            ) -Encoding ASCII
            $emptyCode = Invoke-SqlGateProbe $sqlPs $sqlPy $probeRoot $emptyDiff
            $sqlCode = Invoke-SqlGateProbe $sqlPs $sqlPy $probeRoot $sqlDiff
            if ($null -eq $emptyCode -or $null -eq $sqlCode) {
                Add-Result 'sql-gate' 'FAIL' 'sql-review-gate exists but no PowerShell/Python host can run it on this machine'
            } elseif ($emptyCode -ne 0) {
                Add-Result 'sql-gate' 'FAIL' "sql-review-gate exited $emptyCode on an empty diff (the gate itself is broken)"
            } elseif ($sqlCode -ne 1) {
                Add-Result 'sql-gate' 'FAIL' "sql-review-gate exited $sqlCode on SQL without a summary (expected 1; the gate is not enforcing)"
            } else {
                Add-Result 'sql-gate' 'PASS' 'SQL rule present; gate runs and rejects SQL without a summary (empty-diff + positive probe)'
            }
        } finally {
            Remove-Item -LiteralPath $probeRoot -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $emptyDiff, $sqlDiff -Force -ErrorAction SilentlyContinue
        }
    }

    $sqlHook = $hookPath
    if (Test-Path -LiteralPath $sqlHook) {
        $sqlHookText = [System.IO.File]::ReadAllText($sqlHook, [System.Text.Encoding]::UTF8)
        if ($sqlHookText -notmatch 'sql-review-gate') {
            Add-Result 'sql-gate' 'FAIL' 'pre-commit hook does not call sql-review-gate (re-run install-git-hooks.ps1)'
        } elseif ($hasSqlFlag -and $sqlGateFlag -and $sqlHookText -notmatch 'SQL_POLICY') {
            Add-Result 'sql-gate' 'FAIL' 'pre-commit hook predates the sqlGate policy; re-run install-git-hooks.ps1'
        } elseif ($sqlHookText -notmatch 'SQL_POLICY') {
            Add-Result 'sql-gate' 'WARN' 'legacy hook does not honor sqlGate; re-run install-git-hooks.ps1 for full fail-closed'
        }
    }
}

# ------------------------------------------------------------------ 7 resident
if (Test-Path -LiteralPath $agentsPath) {
    $lineCount = ([System.IO.File]::ReadAllLines($agentsPath, [System.Text.Encoding]::UTF8)).Count
    if ($lineCount -le $MaxAgentsLines) {
        Add-Result 'resident' 'PASS' "AGENTS.md $lineCount line(s) (budget $MaxAgentsLines)"
    } else {
        Add-Result 'resident' 'WARN' "AGENTS.md $lineCount line(s) exceeds budget $MaxAgentsLines"
    }
}

# --------------------------------------------------------------- 8 grounding
$groundingPath = Join-Path $rootPath 'scripts\verify-grounding.ps1'
if (Test-Path -LiteralPath $groundingPath) {
    $gOut  = & $PS -NoProfile -ExecutionPolicy Bypass -File $groundingPath -Root $rootPath -Quiet 2>&1
    $gCode = $LASTEXITCODE
    if ($gCode -eq 0) {
        Add-Result 'grounding' 'PASS' (($gOut | Select-Object -Last 1) -join '')
    } else {
        $first = ($gOut | Where-Object { $_ -match 'FAIL' } | Select-Object -First 1)
        Add-Result 'grounding' 'FAIL' "verify-grounding returns $gCode : $first"
    }
} else {
    Add-Result 'grounding' 'WARN' 'missing: scripts\verify-grounding.ps1'
}

# ------------------------------------------------------ 9 agents structure
# The resident file has a fixed information architecture. Without this check the
# installer can "merge" by appending one small section and still pass -- which is
# exactly how a thin AGENTS.md happens.
$agentsSections = @()
if ($cfg -and $cfg.agentsSections) { $agentsSections = @($cfg.agentsSections) }
if ($agentsSections.Count -gt 0 -and (Test-Path -LiteralPath $agentsPath)) {
    $agentsText = [System.IO.File]::ReadAllText($agentsPath, [System.Text.Encoding]::UTF8)
    $missingSec = @()
    foreach ($sec in $agentsSections) {
        if ($agentsText -notmatch [regex]::Escape([string]$sec)) { $missingSec += $sec }
    }
    if ($missingSec.Count -eq 0) {
        Add-Result 'agents' 'PASS' "$($agentsSections.Count) required section(s) present"
    } else {
        Add-Result 'agents' 'FAIL' ("missing section(s): " + ($missingSec -join ', '))
    }
    # template residue: any "<...>" slot must be replaced by facts or TODO.
    # Matching only the ASCII example prefix let a "# <project>" title survive.
    if ($agentsText -match '<[^<>\r\n]+>') {
        Add-Result 'agents' 'FAIL' 'template placeholder left in AGENTS.md (replace every <...> with project facts or TODO)'
    }

    # depth: headings alone are "hollow". Check that the load-bearing sections
    # actually contain rows / rules, otherwise the file only looks complete.
    # A section may be a markdown heading or a bold label (the template uses a
    # bold label for the command table), so both shapes start a section.
    function Get-SectionBody {
        param([string]$Text, [string]$Name)
        $out = @()
        $inside = $false
        $level = 0
        foreach ($line in ($Text -split "`n")) {
            if ($line -match '^(#{1,6})\s') {
                $hLevel = $matches[1].Length
                if ($inside) {
                    if ($hLevel -le $level) { break }
                    $out += $line
                    continue
                }
                if ($line -match [regex]::Escape($Name)) { $inside = $true; $level = $hLevel }
                continue
            }
            if (-not $inside -and $line -match ('^\*\*' + [regex]::Escape($Name) + '\*\*')) {
                $inside = $true
                $level = 2
                continue
            }
            if ($inside) { $out += $line }
        }
        return $out
    }

    $cmdBody = Get-SectionBody $agentsText ([string]$agentsSections[1])
    $cmdRows = @($cmdBody | Where-Object { $_ -match '^\|.*`[^`]+`' })
    if ($cmdRows.Count -ge 2) {
        Add-Result 'agents' 'PASS' "$($cmdRows.Count) runnable command row(s)"
    } else {
        Add-Result 'agents' 'FAIL' "run commands section is hollow ($($cmdRows.Count) row(s) with a backticked command)"
    }

    $rlBody = Get-SectionBody $agentsText ([string]$agentsSections[2])
    $rlRows = @($rlBody | Where-Object { $_ -match '^\|\s*R\d+\s*\|' })
    if ($rlRows.Count -ge 1) {
        Add-Result 'agents' 'PASS' "$($rlRows.Count) red-line row(s)"
    } else {
        Add-Result 'agents' 'FAIL' 'red lines section has no R-numbered row'
    }

    $tsBody = Get-SectionBody $agentsText ([string]$agentsSections[0])
    $tsRows = @($tsBody | Where-Object { $_ -match '^\|\s*[^|\-]+\s*\|' })
    if ($tsRows.Count -lt 3) {
        Add-Result 'agents' 'WARN' "tech stack table has only $($tsRows.Count) row(s)"
    }
}

# ----------------------------------------------------------------- 10 metrics
$changesRoot = Join-Path $rootPath '.harness\changes'
if (Test-Path -LiteralPath $changesRoot) {
    $sumCount = 0
    Get-ChildItem -LiteralPath $changesRoot -Directory -Force | Where-Object { $_.Name -ne '_template' } | ForEach-Object {
        $sf = Join-Path $_.FullName 'summary.md'
        if (-not (Test-Path -LiteralPath $sf)) { return }
        $sumCount++
    }
    # Field-level validity is judged once, by check-summary.ps1 in check 12; a
    # second regex here is exactly how the checks drifted apart before.
    if ($sumCount -eq 0) {
        Add-Result 'metrics' 'WARN' 'no task summary yet (record one real task, then run metrics.ps1)'
    } else {
        Add-Result 'metrics' 'PASS' "$sumCount summary file(s) present (fields checked by summary-fields)"
    }

    # lesson promotion signal: without this, nobody runs metrics and the
    # "same mistake twice" rule never fires. WARN only -- it asks for a decision.
    $metricsPs = Join-Path $rootPath 'scripts\metrics.ps1'
    if ((Test-Path -LiteralPath $metricsPs) -and $psHost) {
        if ($psHost -eq 'powershell') {
            $mOut = & powershell -NoProfile -ExecutionPolicy Bypass -File $metricsPs -Root $rootPath -Json 2>&1
        } else {
            $mOut = & pwsh -NoProfile -File $metricsPs -Root $rootPath -Json 2>&1
        }
        try {
            $mJson = ($mOut -join "`n") | ConvertFrom-Json
            if ($mJson.lessons) {
                foreach ($p in $mJson.lessons.PSObject.Properties) {
                    if ([int]$p.Value -ge 2 -and @($mJson.promoted) -notcontains $p.Name) {
                        Add-Result 'lessons' 'WARN' "lesson repeated $($p.Value)x: $($p.Name) -> promote into a rule, a gate or a skill"
                    }
                }
            }
        } catch {
            Add-Result 'lessons' 'WARN' 'metrics.ps1 -Json could not be parsed (lesson promotion check skipped)'
        }
    }
}

# ------------------------------------------------------------ 10b summary fields
# metrics.ps1 can only count what is present. This check reuses the same validator
# as stage-gate and pre-commit so the three cannot drift. WARN only: historical
# summaries may predate a field, and a FAIL here would block an otherwise sound
# install. New tasks are forced to comply by the gates, not by this report.
$checkSummaryPs = Join-Path $rootPath 'scripts\check-summary.ps1'
if (Test-Path -LiteralPath $changesRoot) {
    if (-not (Test-Path -LiteralPath $checkSummaryPs)) {
        Add-Result 'summary-fields' 'WARN' 'missing: scripts\check-summary.ps1 (field validation skipped)'
    } elseif (-not $psHost) {
        Add-Result 'summary-fields' 'WARN' 'no PowerShell host: summary field validation skipped'
    } else {
        $sfCount = 0
        $sfBad = 0
        $sfFirst = ''
        Get-ChildItem -LiteralPath $changesRoot -Directory -Force | Where-Object { $_.Name -ne '_template' } | ForEach-Object {
            $sf = Join-Path $_.FullName 'summary.md'
            if (-not (Test-Path -LiteralPath $sf)) { return }
            $sfCount++
            if ($psHost -eq 'powershell') {
                $sfOut = & powershell -NoProfile -ExecutionPolicy Bypass -File $checkSummaryPs -Root $rootPath -File $sf -Stage final 2>&1
            } else {
                $sfOut = & pwsh -NoProfile -File $checkSummaryPs -Root $rootPath -File $sf -Stage final 2>&1
            }
            if ($LASTEXITCODE -ne 0) {
                $sfBad++
                if (-not $sfFirst) {
                    $firstLine = @($sfOut | Where-Object { $_ -match '\[FAIL\]' } | Select-Object -First 1)
                    $sfFirst = "$($_.Name): $firstLine"
                }
            }
        }
        if ($sfCount -gt 0) {
            if ($sfBad -eq 0) {
                Add-Result 'summary-fields' 'PASS' "$sfCount summary file(s) pass the field check"
            } else {
                Add-Result 'summary-fields' 'WARN' "$sfBad of $sfCount summary file(s) incomplete ($sfFirst)"
            }
        }
    }
}

# ---------------------------------------------------------------- 11 modules
# Module cards hold "what breaks here". A card without evidence is a rumour, and
# a card missing sections is a stub -- both are caught here.
$modulesRoot = Join-Path $rootPath '.harness\modules'
if (-not (Test-Path -LiteralPath $modulesRoot)) {
    Add-Result 'modules' 'WARN' 'no .harness\modules directory (module pitfalls have no home)'
} else {
    $cards = @(Get-ChildItem -LiteralPath $modulesRoot -File -Filter '*.md' -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notin @('README.md') -and $_.Name -notlike '_*' })
    if ($cards.Count -eq 0) {
        Add-Result 'modules' 'WARN' 'no module card yet (create 3-5 high-traffic ones)'
    } else {
        $sections = @()
        if ($cfg -and $cfg.moduleSections) { $sections = @($cfg.moduleSections) }
        $bad = 0
        $noEvidence = 0
        foreach ($c in $cards) {
            $t = [System.IO.File]::ReadAllText($c.FullName, [System.Text.Encoding]::UTF8)
            $miss = @()
            foreach ($s in $sections) {
                if ($t -notmatch ('(?m)^#{1,6}\s.*' + [regex]::Escape([string]$s))) { $miss += $s }
            }
            if ($miss.Count -gt 0) { Add-Result 'modules' 'WARN' "$($c.BaseName): missing section(s): $($miss -join ',')"; $bad++ }
            if ($t -notmatch '(?m)^\s*-\s*\[E[12]\]') { Add-Result 'modules' 'FAIL' "$($c.BaseName): no [E1]/[E2] anchor"; $noEvidence++ }
        }
        if ($cards.Count -gt 0 -and $bad -eq 0 -and $noEvidence -eq 0) {
            Add-Result 'modules' 'PASS' "$($cards.Count) module card(s) complete"
        }
    }
}

# -------------------------------------------------------------------- summary
$failCount = @($results | Where-Object { $_.Status -eq 'FAIL' }).Count
$warnCount = @($results | Where-Object { $_.Status -eq 'WARN' }).Count
$passCount = @($results | Where-Object { $_.Status -eq 'PASS' }).Count

if (-not $Quiet) {
    Write-Host ""
    Write-Host "harness verification -- $rootPath" -ForegroundColor Cyan
    Write-Host ("-" * 70)
    foreach ($r in $results) {
        $color = switch ($r.Status) {
            'PASS' { 'Green' }
            'WARN' { 'Yellow' }
            default { 'Red' }
        }
        Write-Host ("  [{0}] {1,-12} {2}" -f $r.Status, $r.Check, $r.Detail) -ForegroundColor $color
    }
    Write-Host ("-" * 70)
}

Write-Host ("RESULT pass={0} warn={1} fail={2}" -f $passCount, $warnCount, $failCount) `
    -ForegroundColor $(if ($failCount -gt 0) { 'Red' } elseif ($warnCount -gt 0) { 'Yellow' } else { 'Green' })

if ($failCount -gt 0) {
    Write-Host ""
    Write-Host "Fix the FAIL rows above, then re-run this script." -ForegroundColor Red
    exit 1
}

if ($warnCount -gt 0) {
    Write-Host ""
Write-Host "No blockers. WARN rows are optional hardening (see references/ on landing strategy)." -ForegroundColor Yellow
}

exit 0
