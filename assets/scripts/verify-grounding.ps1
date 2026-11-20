<#
  verify-grounding.ps1 -- reference integrity and evidence-anchor check

  WHY
    A skill that cites a path nobody can open is worse than no skill: the agent
    follows it, fails, and then "improvises". This script checks what the agent
    cannot check for itself -- that every harness-internal path it mentions
    actually exists, and that project-specific claims carry evidence anchors.

  CHECKS
    1. references   paths under .harness / .trae / scripts (and AGENTS.md) exist
    2. anchors      [E2] anchor targets exist; [E1] anchors are not empty;
                    [E0] confirmations are legal only in new-project mode
    3. grounded     every skill carries at least one [E1]/[E2] anchor
                    (new project: [E0] counts but stays a WARN)
    4. size         a very long skill body is reported as WARN; there is no
                    hard line limit (a skill costs context only when triggered).
                    Skill count is unlimited by default, pass -MaxGrounded N
                    only during cold start
    5. stale        code behind an [E2] anchor changed after the skill was verified
                    ("- verified: YYYY-MM-DD" resets the clock). FAIL when the skill
                    was loaded in the last 14 days, WARN otherwise
    6. coverage     a filled project must not keep the template's placeholder rows:
                    a placeholder structure tree is FAIL, a wiki table that is
                    still a template is WARN (needs .harness\stack.json)
    7. fill-depth   a filled project must not keep "<...>" in rules/wiki prose;
                    a TODO(...) marker is legal, fenced and inline code are skipped

  NEW PROJECT MODE
    Detected by .harness/project-brief.md. There is no code to cite yet, so a
    skill may carry [E0] confirm:<who> <YYYY-MM-DD> :: <what> instead of E1/E2.
    Outside this mode [E0] is a FAIL: user confirmation is not evidence once code
    exists.

  USAGE
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify-grounding.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify-grounding.ps1 -Root D:\proj
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify-grounding.ps1 -Quiet

  EXIT CODE
    0 = no FAIL, 1 = at least one FAIL

  NOTE
    Pure ASCII on purpose (PS 5.1 parses .ps1 as ANSI unless it has a UTF-8 BOM).
    Chinese lives in the markdown it reads, decoded explicitly as UTF-8.
    Anchor format is defined in references/grounding protocol (see the package doc).
#>
[CmdletBinding()]
param(
    [string]$Root = (Get-Location).Path,
    [int]$WarnSkillLines = 250,
    [int]$MaxGrounded = 0,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

$rootPath = (Resolve-Path -LiteralPath $Root).Path
$results  = New-Object System.Collections.Generic.List[object]

function Add-Result {
    param([string]$Check, [string]$Status, [string]$Detail)
    $results.Add([pscustomobject]@{ Check = $Check; Status = $Status; Detail = $Detail })
}

# harness-internal prefixes: these must resolve inside the project
$InternalPrefixes = @('.harness', '.trae', 'scripts')

function Test-InternalPath {
    param([string]$Token)
    $rel = $Token -replace '/', '\'
    $full = Join-Path $rootPath $rel
    return (Test-Path -LiteralPath $full)
}

# ------------------------------------------------- config + detected stack
$cfgPath = Join-Path $PSScriptRoot 'harness-required.json'
$cfg = $null
if (Test-Path -LiteralPath $cfgPath) {
    $cfg = (Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8) | ConvertFrom-Json
}
$stackPath = Join-Path $rootPath '.harness\stack.json'
$stack = $null
if (Test-Path -LiteralPath $stackPath) {
    try { $stack = (Get-Content -LiteralPath $stackPath -Raw -Encoding UTF8) | ConvertFrom-Json } catch { $stack = $null }
}
$compileFail = 0
# Strict mode: a fresh install treats a missing anchor as a defect; an upgraded
# project is merged with false so its older skills do not fail on day one.
$groundingStrict = $false
if ($cfg -and ($cfg.PSObject.Properties.Name -contains 'groundingStrict')) {
    # A hand-written "false" in JSON must not become true through a cast.
    $raw = $cfg.groundingStrict
    $groundingStrict = if ($raw -is [string]) { $raw.Trim().ToLowerInvariant() -eq 'true' } else { [bool]$raw }
}

# new-project mode: the only state where a user confirmation can stand in for
# code evidence, because there is no code to point at yet.
$newProject = Test-Path -LiteralPath (Join-Path $rootPath '.harness\project-brief.md')
$codeExists = $false
# probe-project.ps1 writes its default "-Out baseline" into the repository root,
# while some installs keep it under .harness\baseline. Both layouts are legal:
# checking only one of them leaves $codeExists false forever, so an E0 anchor
# never gets flagged for upgrade even after the code base arrived.
$baselineCandidates = @(
    (Join-Path $rootPath 'baseline\baseline.json'),
    (Join-Path $rootPath '.harness\baseline\baseline.json')
)
foreach ($bp in $baselineCandidates) {
    if (-not (Test-Path -LiteralPath $bp)) { continue }
    try {
        $bl = (Get-Content -LiteralPath $bp -Raw -Encoding UTF8) | ConvertFrom-Json
        # probe-project records a root because the DIRECTORY exists, so an empty
        # src/ still lands in srcRoots. Counting that as "code exists" flipped a
        # brand-new scaffold out of new-project mode and failed every [E0] anchor.
        # A root only proves code when at least one real file lives under it.
        $roots = @(@($bl.srcRoots) + @($bl.testRoots))
        foreach ($r in $roots) {
            if (-not $r) { continue }
            $rp = Join-Path $rootPath ([string]$r -replace '/', '\')
            if (-not (Test-Path -LiteralPath $rp)) { continue }
            if (@(Get-ChildItem -LiteralPath $rp -Recurse -File -Force -ErrorAction SilentlyContinue |
                    Select-Object -First 1).Count -gt 0) {
                $codeExists = $true
                break
            }
        }
        if ($codeExists) { break }
    } catch { }
}
# No baseline yet but an obvious source tree is present: the project is not a
# greenfield brief anymore, so E0 must not be treated as a long-term pass.
# This probe must also run in new-project mode: a brief alone does not prove the
# code is still absent, and skipping it there let [E0] count as grounded forever.
if (-not $codeExists) {
    # Mirror the probe's source-root list: Go (cmd/internal/pkg), Python packages
    # and multi-module repos also carry code here, and the old four-name list made
    # "no code detected" look true for those layouts.
    foreach ($d in @('src', 'app', 'lib', 'source', 'cmd', 'pkg', 'internal', 'packages', 'apps', 'modules')) {
        $dp = Join-Path $rootPath $d
        if (Test-Path -LiteralPath $dp) {
            if (@(Get-ChildItem -LiteralPath $dp -Recurse -File -Force -ErrorAction SilentlyContinue |
                    Select-Object -First 1).Count -gt 0) { $codeExists = $true; break }
        }
    }
}

# E0 stands in for evidence only while the brief is the only artifact: once code
# exists, a user confirmation is not evidence any more. Both the skill checks and
# the document scan below key off this single flag so they cannot disagree.
$allowE0 = $newProject -and (-not $codeExists)

# A brief is the license for [E0]: a stub brief (template slots, no confirmation
# date) would make every confirmation anchor unfounded, so existence alone is not
# enough. The date is the one ASCII-checkable proof; the rest is free-form prose.
if ($newProject) {
    $briefPath = Join-Path $rootPath '.harness\project-brief.md'
    $briefText = [System.IO.File]::ReadAllText($briefPath, [System.Text.Encoding]::UTF8)
    if ($briefText -notmatch '\d{4}-\d{2}-\d{2}') {
        Add-Result 'brief' 'FAIL' 'project-brief.md carries no confirmation date (YYYY-MM-DD): [E0] anchors are unfounded'
    }
}

# ------------------------------------------------------------ collect skills
$skillsRoot = Join-Path $rootPath '.harness\skills'
$skillFiles = @()
if (Test-Path -LiteralPath $skillsRoot) {
    Get-ChildItem -LiteralPath $skillsRoot -Directory -Force | ForEach-Object {
        $cat = $_.Name
        Get-ChildItem -LiteralPath $_.FullName -Directory -Force | ForEach-Object {
            $f = Join-Path $_.FullName 'SKILL.md'
            if (Test-Path -LiteralPath $f) {
                $skillFiles += [pscustomobject]@{ Category = $cat; Name = $_.Name; Path = $f }
            } else {
                Add-Result 'references' 'FAIL' "no SKILL.md in $cat/$($_.Name)"
            }
        }
    }
} else {
    Add-Result 'references' 'FAIL' 'missing: .harness\skills'
}

# A missing stack.json used to skip the technology-misuse check without a word:
# "no violation" and "never checked" looked identical. Declare the gap instead.
if (-not $stack -and $skillFiles.Count -gt 0) {
    Add-Result 'compile' 'WARN' 'no .harness\stack.json: technology misuse is not checked (run scripts\probe-stack.ps1)'
}

# --------------------------------------------------- 1 references / 2 anchors
$pathFail   = 0
$pathWarn   = 0
$anchorFail = 0
$anchorWarn = 0

# basenames that exist inside the installed harness; a doc path carrying one of
# these under a different (usually mistyped) directory is a stale reference
$harnessBasenames = @{}
foreach ($base in @('.harness', 'scripts')) {
    $bp = Join-Path $rootPath $base
    if (Test-Path -LiteralPath $bp) {
        # Upgrade backups are not live harness files. Including them would let a
        # stale or mistyped reference look valid because a deleted file exists
        # only in .harness/upgrade/<timestamp>/.
        Get-ChildItem -LiteralPath $bp -Recurse -File -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '[\\/][.]harness[\\/]upgrade[\\/]' } |
            ForEach-Object { $harnessBasenames[$_.Name] = $true }
    }
}

# A skill that was loaded in the last two weeks is actively guiding work, so a
# stale anchor is not a note any more: it is about to teach the wrong shape.
function Get-RecentlyLoadedSkills {
    param([int]$Days = 14)
    $set = @{}
    $changes = Join-Path $rootPath '.harness\changes'
    if (-not (Test-Path -LiteralPath $changes)) { return $set }
    $cut = (Get-Date).AddDays(-$Days)
    foreach ($f in @(Get-ChildItem -LiteralPath $changes -Recurse -Filter summary.md -File -ErrorAction SilentlyContinue)) {
        if ($f.LastWriteTime -lt $cut) { continue }
        $txt = [System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8)
        # The summary template wraps the field in a Chinese label and backticks;
        # match the field name anywhere on the line.
        $m = [regex]::Match($txt, '(?m)^\s*-\s*[^\r\n]*?\bloaded_skills:\s*`?([^`\r\n]*)')
        if (-not $m.Success) { continue }
        foreach ($n in ($m.Groups[1].Value -split '[,;]+')) {
            $n = $n.Trim().Trim('`').Trim()
            if ($n.Length -eq 0) { continue }
            if ($n -match '^(none|n/a|-|no)$') { continue }
            # "biz-dev/04-sql-review" and "04-sql-review" must match the skill
            # name used by the files: keep the last segment, drop the number.
            $n = ($n -replace '\\', '/')
            $n = ($n -split '/')[-1]
            $n = ($n -replace '^\d+-', '')
            $set[$n.ToLowerInvariant()] = $true
        }
    }
    return $set
}
$recentlyLoaded = Get-RecentlyLoadedSkills

foreach ($s in $skillFiles) {
    $lines = [System.IO.File]::ReadAllLines($s.Path, [System.Text.Encoding]::UTF8)
    $seen  = @{}
    $e12   = 0
    $e0    = 0
    $e2Targets = @()

    # --- compilation contract: no unfilled slot, no out-of-stack technology
    $skillText = [System.IO.File]::ReadAllText($s.Path, [System.Text.Encoding]::UTF8)
    if ($skillText -match '<!--\s*slot:') {
        Add-Result 'compile' 'FAIL' "$($s.Category)/$($s.Name): unfilled slot marker"
        $compileFail++
    }

    # --- block markers: package blocks are replaced on upgrade, project blocks
    #     keep project facts. Slots and evidence belong to the project side only;
    #     a slot left in a package block would be copied into every other project.
    $markerStack = New-Object System.Collections.Generic.List[string]
    $markerIds   = @{}
    $markerSeen  = 0
    $markerFail  = 0
    $slotInPkg   = 0
    $anchorInPkg = 0
    $inFence     = $false
    foreach ($line in $lines) {
        if ($line -match '^\s*(```|~~~)') { $inFence = -not $inFence; continue }
        if ($inFence) { continue }
        if ($line -match '<!--\s*harness:(package|project):begin\s+([A-Za-z0-9][A-Za-z0-9-]*)\s*-->') {
            $markerSeen++
            $kind = $matches[1]
            $id   = $matches[2]
            if ($markerStack.Count -gt 0) {
                Add-Result 'markers' 'FAIL' "$($s.Category)/$($s.Name): nested marker $kind/$id"
                $markerFail++
            }
            $key = $kind + '/' + $id
            if ($markerIds.ContainsKey($key)) {
                Add-Result 'markers' 'FAIL' "$($s.Category)/$($s.Name): duplicate marker id $key"
                $markerFail++
            } else {
                $markerIds[$key] = $true
            }
            $markerStack.Add($key)
            continue
        }
        if ($line -match '<!--\s*harness:(package|project):end\s*-->') {
            $markerSeen++
            $kind = $matches[1]
            if ($markerStack.Count -eq 0) {
                Add-Result 'markers' 'FAIL' "$($s.Category)/$($s.Name): $kind end without begin"
                $markerFail++
            } else {
                $top = $markerStack[$markerStack.Count - 1]
                if (-not $top.StartsWith($kind + '/')) {
                    Add-Result 'markers' 'FAIL' "$($s.Category)/$($s.Name): $kind end closes $top"
                    $markerFail++
                }
                $markerStack.RemoveAt($markerStack.Count - 1)
            }
            continue
        }
        if ($markerStack.Count -gt 0 -and $markerStack[$markerStack.Count - 1].StartsWith('package/')) {
            if ($line -match '<!--\s*slot:') { $slotInPkg++ }
            if ($line -match '^\s*-\s*\[(E0|E1|E2)\]') { $anchorInPkg++ }
        }
    }
    if ($markerStack.Count -gt 0) {
        Add-Result 'markers' 'FAIL' "$($s.Category)/$($s.Name): $($markerStack.Count) block marker(s) not closed"
        $markerFail++
    }
    if ($slotInPkg -gt 0) {
        Add-Result 'markers' 'FAIL' "$($s.Category)/$($s.Name): $slotInPkg slot line(s) inside a package block; slots belong in a project block"
        $markerFail++
    }
    if ($anchorInPkg -gt 0) {
        Add-Result 'markers' 'FAIL' "$($s.Category)/$($s.Name): $anchorInPkg evidence anchor(s) inside a package block; move them to a project block"
        $markerFail++
    }
    if ($markerSeen -gt 0 -and $markerFail -eq 0) {
        Add-Result 'markers' 'PASS' "$($s.Category)/$($s.Name): block markers balanced ($($markerIds.Count) id(s))"
    }
    if ($stack -and $cfg.stackTermRules) {
        $negWords = @($cfg.negationWords)
        foreach ($tr in @($cfg.stackTermRules)) {
            $fieldVal = $stack.($tr.field)
            # A missing/null stack field means "probe did not detect it". Comparing
            # it against whenNotEquals would make every new project that picks its
            # own technology look like a violation, so skip undetected fields.
            if ($null -eq $fieldVal) { continue }
            $val = [string]$fieldVal
            if ($val.Trim().Length -eq 0) { continue }
            if ($val -eq [string]$tr.whenNotEquals) { continue }
            $bad = $null
            foreach ($term in @($tr.forbid)) {
                foreach ($line in ($skillText -split "`n")) {
                    if ($line -match [regex]::Escape([string]$term)) {
                        $neg = $false
                        foreach ($w in $negWords) { if ($line.Contains([string]$w)) { $neg = $true; break } }
                        if (-not $neg) { $bad = $term; break }
                    }
                }
                if ($bad) { break }
            }
            if ($bad) {
                Add-Result 'compile' 'FAIL' "$($s.Category)/$($s.Name): mentions '$bad' but stack.$($tr.field)=$val"
                $compileFail++
            }
        }
    }

    # --- anchors: [E0] confirm:<who> <date> :: why  /  [E1] cmd: ...  /  [E2] path#Lx-Ly
    #     [E3] doc claim (legal, never counts as grounded)  /  [E4] no evidence
    foreach ($line in $lines) {
        if ($line -notmatch '^\s*-\s*\[(E0|E1|E2|E3|E4)\]\s*(.+)$') { continue }
        $level = $matches[1]
        $body  = $matches[2].Trim()
        if ($body.Length -eq 0) {
            Add-Result 'anchors' 'FAIL' "$($s.Category)/$($s.Name): empty [$level] anchor"
            $anchorFail++
            continue
        }
        if ($level -eq 'E0') {
            if (-not $newProject) {
                # This branch only fires when the brief is absent; "code exists"
                # is handled below as a WARN (new project that has started landing code).
                Add-Result 'anchors' 'FAIL' "$($s.Name): [E0] is only legal in new-project mode (.harness/project-brief.md is missing)"
                $anchorFail++
                continue
            }
            # the confirmer may be a real name with spaces (e.g. "Li Si")
            if ($body -notmatch '^confirm:.+?\s+\d{4}-\d{2}-\d{2}\s+::\s+\S') {
                Add-Result 'anchors' 'FAIL' "$($s.Name): [E0] must be 'confirm:<who> <YYYY-MM-DD> :: <what>'"
                $anchorFail++
                continue
            }
            if ($codeExists) {
                # brief still around but source has landed: keep the anchor honest
                Add-Result 'anchors' 'WARN' "$($s.Name): [E0] left in place after code landed -- upgrade to [E1]/[E2]"
                $anchorWarn++
            } else {
                $e0++
            }
            continue
        }
        if ($level -eq 'E3') {
            # a README or a comment is a claim, not proof; never count as grounded
            Add-Result 'anchors' 'WARN' "$($s.Name): [E3] is a document claim -- cite the source file and verify it against code"
            $anchorWarn++
            continue
        }
        if ($level -eq 'E4') {
            $anchorWarn++
            continue
        }
        if ($level -eq 'E1') {
            $e12++
            if ($body -notmatch '^cmd:\s*\S') {
                Add-Result 'anchors' 'WARN' "$($s.Name): [E1] should start with 'cmd: <command>'"
            }
            continue
        }
        # E2
        $e12++
        $target = ($body -split ' :: ')[0].Trim()
        $target = $target -replace '#L\d+(-L\d+)?$', ''
        $target = $target -replace '/', '\'
        if ($target -match '[<>*$%]') {
            Add-Result 'anchors' 'WARN' "$($s.Name): [E2] anchor uses a placeholder: $target"
            $anchorWarn++
            continue
        }
        if (-not (Test-Path -LiteralPath (Join-Path $rootPath $target))) {
            Add-Result 'anchors' 'FAIL' "$($s.Name): [E2] target missing: $target"
            $anchorFail++
        } else {
            $e2Targets += $target
        }
    }

    if ($e12 -eq 0) {
        $strictNow = ($groundingStrict -and $codeExists -and -not $newProject)
        if ($e0 -gt 0) {
            if ($codeExists) {
                if ($strictNow) {
                    Add-Result 'grounded' 'FAIL' "$($s.Category)/$($s.Name): code exists but only [E0] confirmations; add [E1]/[E2] (groundingStrict=true)"
                } else {
                    Add-Result 'grounded' 'WARN' "$($s.Category)/$($s.Name): code exists -- replace [E0] confirmations with [E1]/[E2]"
                }
            } else {
                Add-Result 'grounded' 'WARN' "$($s.Category)/$($s.Name): new project without code -- [E0] confirmations only; upgrade to [E1]/[E2] once code exists"
            }
        } else {
            if ($strictNow) {
                Add-Result 'grounded' 'FAIL' "$($s.Category)/$($s.Name): no [E1]/[E2] anchor (groundingStrict=true; set it false in scripts/harness-required.json to downgrade)"
            } else {
                Add-Result 'grounded' 'WARN' "$($s.Category)/$($s.Name): no [E1]/[E2] anchor (ungrounded skill)"
            }
        }
    }

    # --- staleness: watched code changed after the skill was last verified.
    # "- verified: YYYY-MM-DD" resets the clock after a human re-reads the skill;
    # without it the skill file's own mtime is used.
    $verified = $null
    foreach ($line in $lines) {
        if ($line -match '^\s*-\s*verified:\s*(\d{4}-\d{2}-\d{2})') {
            try { $verified = [datetime]::ParseExact($matches[1], 'yyyy-MM-dd', $null) } catch { $verified = $null }
            break
        }
    }
    if (-not $verified) { $verified = (Get-Item -LiteralPath $s.Path).LastWriteTime.Date }
    $staleList = @()
    foreach ($t in ($e2Targets | Select-Object -Unique)) {
        $full = Join-Path $rootPath $t
        $m = (Get-Item -LiteralPath $full).LastWriteTime.Date
        if ($m -gt $verified) { $staleList += ($t + ' (' + $m.ToString('yyyy-MM-dd') + ')') }
    }
    if ($staleList.Count -gt 0) {
        $shown = @($staleList | Select-Object -First 3)
        $detail = "$($s.Name): $($staleList.Count) watched file(s) changed after verified $($verified.ToString('yyyy-MM-dd')): $($shown -join '; ')"
        $skillKey = ($s.Name -replace '^\d+-', '').ToLowerInvariant()
        if ($recentlyLoaded.ContainsKey($skillKey)) {
            Add-Result 'stale' 'FAIL' ($detail + '; loaded in the last 14 days, so re-read the code and refresh the skill')
        } else {
            Add-Result 'stale' 'WARN' $detail
        }
    }

    # --- inline `path` tokens that point at installed harness assets
    foreach ($line in $lines) {
        foreach ($m in [regex]::Matches($line, '`([^`\r\n]+)`')) {
            $tok = $m.Groups[1].Value.Trim()
            if ($tok.Length -eq 0) { continue }
            if ($tok -match '[<>*$%]') { continue }
            if ($tok -match 'Xxx|xxx|\d{8}') { continue }
            $first = ($tok -split '[\\/]')[0]
            $isInternal = ($InternalPrefixes -contains $first) -or ($tok -eq 'AGENTS.md')
            $isStaleHarness = $false
            if (-not $isInternal -and $first.StartsWith('.') -and ($tok -split '[\\/]').Count -gt 1) {
                $leaf = ($tok -split '[\\/]')[-1]
                $isStaleHarness = $harnessBasenames.ContainsKey($leaf)
            }
            if (-not $isInternal -and -not $isStaleHarness) { continue }
            if ($seen.ContainsKey($tok)) { continue }
            $seen[$tok] = $true
            if (-not (Test-InternalPath $tok)) {
                Add-Result 'references' 'FAIL' "$($s.Category)/$($s.Name): path not found: $tok"
                $pathFail++
            }
        }
    }

    # --- 4 size: a skill body is paid for only when the skill is triggered, so
    #     length itself is not a defect -- a complex skill is legitimately long.
    #     A very long body is still worth a look, hence WARN instead of FAIL:
    #     the fix is to move examples into an attached file, not to cut content.
    if ($lines.Count -gt $WarnSkillLines) {
        Add-Result 'size' 'WARN' "$($s.Category)/$($s.Name): $($lines.Count) lines; consider moving examples to an attached file"
    }
}

if ($pathFail -eq 0 -and $pathWarn -eq 0 -and $skillFiles.Count -gt 0) {
    Add-Result 'references' 'PASS' "all harness-internal paths in $($skillFiles.Count) skill(s) resolve"
}

# [E0] outside the skill tree used to be invisible: a rule, wiki page, module
# card or summary could carry a user confirmation and no check would ever see it.
# Once code exists E0 is not evidence: FAIL when the project never had a brief,
# WARN while the brief is still around (the same grace period skills get).
if (-not $allowE0) {
    $docFiles = @()
    $agentsDoc = Join-Path $rootPath 'AGENTS.md'
    if (Test-Path -LiteralPath $agentsDoc) { $docFiles += $agentsDoc }
    foreach ($docDir in @('.harness\rules', '.harness\wiki', '.harness\modules', '.harness\changes')) {
        $dp = Join-Path $rootPath ($docDir -replace '/', '\')
        if (-not (Test-Path -LiteralPath $dp)) { continue }
        Get-ChildItem -LiteralPath $dp -Recurse -Filter *.md -File -Force -ErrorAction SilentlyContinue |
            ForEach-Object { $docFiles += $_.FullName }
    }
    foreach ($doc in ($docFiles | Select-Object -Unique)) {
        $docText = [System.IO.File]::ReadAllText($doc, [System.Text.Encoding]::UTF8)
        if ($docText -notmatch '(?m)^\s*-\s*\[E0\]') { continue }
        $rel = $doc.Substring($rootPath.Length).TrimStart('\', '/') -replace '\\', '/'
        if ($newProject) {
            Add-Result 'anchors' 'WARN' "${rel}: carries [E0] after code landed -- upgrade to [E1]/[E2]"
            $anchorWarn++
        } else {
            Add-Result 'anchors' 'FAIL' "${rel}: carries [E0]; user confirmation is not evidence once the project has code"
            $anchorFail++
        }
    }
}

# ---------------------------------------------------------------- 3 grounded
$groundedCount = 0
# $allowE0 was computed next to $codeExists so the document scan above sees the
# same state; E0 counts as grounded only while no code exists.
$groundPattern = if ($allowE0) { '(?m)^\s*-\s*\[(E0|E1|E2)\]' } else { '(?m)^\s*-\s*\[(E1|E2)\]' }
foreach ($s in $skillFiles) {
    $text = [System.IO.File]::ReadAllText($s.Path, [System.Text.Encoding]::UTF8)
    if ($text -match $groundPattern) { $groundedCount++ }
}
if ($MaxGrounded -gt 0 -and $groundedCount -gt $MaxGrounded) {
    Add-Result 'grounded' 'WARN' "$groundedCount grounded skill(s) exceed the cold-start budget $MaxGrounded"
} elseif ($groundedCount -eq 0 -and $skillFiles.Count -gt 0 -and $groundingStrict -and $codeExists -and -not $newProject) {
    Add-Result 'grounded' 'FAIL' "no skill carries an [E1]/[E2] anchor; groundingStrict=true (set it false in scripts/harness-required.json to downgrade)"
} elseif ($groundedCount -gt 0) {
    Add-Result 'grounded' 'PASS' "$groundedCount grounded skill(s)"
}

# ---------------------------------------------------------------- 4 coverage
# A wiki page can be long and still be the template: the >=5-line check in
# verify-harness cannot see that. probe output is the cheap witness of "what the
# project actually has", so this check is gated on it and stays advisory (WARN)
# except for the structure tree -- a fenced tree line that still starts with "<"
# unambiguously means the tree was never copied from the real repository.
# probe-project does NOT count entities / topics / endpoints, so there is no
# numeric reconciliation here on purpose: a count check would reward padding.
function Chars { param([int[]]$Codes) -join ($Codes | ForEach-Object { [char]$_ }) }
function Test-PlaceholderCell {
    param([string]$Cell)
    # template slots are usually wrapped in backticks; strip them before the
    # "<...>" test can see the token.
    $t = $Cell.Trim().Trim([char]0x60).Trim()
    if ($t.Length -eq 0) { return $true }
    # a cell that IS one angle-bracket token is a template slot. A java type in
    # prose (List<String>) must stay real, hence the CJK requirement below.
    if ($t -match '^<[^<>]*>$') { return $true }
    if (($t -match '<[^<>]*>') -and ($t -match '[\u4e00-\u9fa5]')) { return $true }
    if ($t -match '\bTODO\b') { return $true }
    if ($t -eq '...' -or $t -eq '-' -or $t -eq ([string][char]0x2026) -or $t -eq ([string][char]0x2014)) { return $true }
    return $false
}
function Test-RealTableRow {
    param([string]$Line)
    if ($Line -notmatch '^\s*\|') { return $false }
    if ($Line -match '^\s*\|[\s:|-]+\|\s*$') { return $false }
    $cells = @($Line.Trim().Trim('|').Split('|'))
    if ($cells.Count -lt 2) { return $false }
    # the first cell is an ID/label column and is never a placeholder, so only
    # the remaining cells decide whether the row carries real content.
    foreach ($c in @($cells | Select-Object -Skip 1)) {
        if (-not (Test-PlaceholderCell $c)) { return $true }
    }
    return $false
}
function Get-SectionTableRows {
    param([string[]]$Lines, [string]$HeadingPattern)
    $in = $false
    $inFence = $false
    $seenSep = $false
    $rows = New-Object System.Collections.Generic.List[string]
    foreach ($l in $Lines) {
        if ($l -match '^\s*```') { $inFence = -not $inFence; continue }
        if ($inFence) { continue }
        if (-not $in) {
            if ($l -match $HeadingPattern) { $in = $true }
            continue
        }
        # only a level-2 heading ends the section: level-3 entries are content.
        if ($l -match '^##\s') { break }
        if ($l -notmatch '^\s*\|') { continue }
        if ($l -match '^\s*\|[\s:|-]+\|\s*$') { $seenSep = $true; continue }
        $rows.Add($l)
    }
    # The header row carries column names, not data. Counting it as real is how a
    # table that was never filled looked populated (caught in review, 1.31.5).
    if ($seenSep -and $rows.Count -gt 0) { return @($rows | Select-Object -Skip 1) }
    return $rows
}
function Get-SectionSubHeadings {
    param([string[]]$Lines, [string]$HeadingPattern)
    $in = $false
    $inFence = $false
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($l in $Lines) {
        if ($l -match '^\s*```') { $inFence = -not $inFence; continue }
        if ($inFence) { continue }
        if ($l -match '^##\s') { $in = ($l -match $HeadingPattern); continue }
        if ($in -and $l -match '^###\s') { $out.Add($l) }
    }
    return $out
}

if ($newProject -and -not $codeExists) {
    Add-Result 'coverage' 'PASS' 'new project without code: wiki coverage deferred'
} else {
    $rulesDir = Join-Path $rootPath '.harness\rules'
    $wikiDir  = Join-Path $rootPath '.harness\wiki'
    $structFile = Join-Path $rulesDir ((Chars 0x5DE5,0x7A0B,0x7ED3,0x6784) + '.md')
    $agentsDoc2 = Join-Path $rootPath 'AGENTS.md'
    $agentsFilled = $false
    if (Test-Path -LiteralPath $agentsDoc2) {
        $agentsFilled = ([System.IO.File]::ReadAllText($agentsDoc2, [System.Text.Encoding]::UTF8) -notmatch '<[^<>\r\n]+>')
    }

    # (a) structure tree: deterministic, but only once the resident file says
    #     "filled" -- otherwise the project is mid-compile and verify-harness
    #     already reports the placeholders in AGENTS.md.
    if ($codeExists -and $agentsFilled -and (Test-Path -LiteralPath $structFile)) {
        $inFence = $false
        $bad = New-Object System.Collections.Generic.List[string]
        # tree glyphs (vertical / branch / last / horizontal) built from code
        # points so this file stays pure ASCII for PS 5.1.
        $glyphs = '[' + ([char]0x2502) + ([char]0x251C) + ([char]0x2514) + ([char]0x2500) + ']'
        foreach ($l in [System.IO.File]::ReadAllLines($structFile, [System.Text.Encoding]::UTF8)) {
            if ($l -match '^\s*```') { $inFence = -not $inFence; continue }
            if (-not $inFence) { continue }
            $x = ($l -replace $glyphs, '').Trim()
            if ($x.StartsWith('<')) { $bad.Add($x) }
        }
        if ($bad.Count -gt 0) {
            Add-Result 'coverage' 'FAIL' ("structure tree still has {0} placeholder path(s), first: {1}" -f $bad.Count, $bad[0])
        }
    }

    # (b) capability vs wiki: advisory, and only for capabilities probe detected.
    if ($null -eq $stack) {
        Add-Result 'coverage' 'WARN' 'no .harness\stack.json: coverage cannot be reconciled (run scripts\probe-stack.ps1)'
    } else {
        $bizFile  = Join-Path $wikiDir ((Chars 0x4E1A,0x52A1,0x6A21,0x578B) + '.md')
        $dataFile = Join-Path $wikiDir ((Chars 0x6570,0x636E,0x6A21,0x578B) + '.md')
        $msgHead   = '^##\s*' + (Chars 0x6D88,0x606F,0x62D3,0x6251)
        $cacheHead = '^##\s*' + (Chars 0x7F13,0x5B58,0x7B56,0x7565)
        $entHead   = '^##\s*' + (Chars 0x5B9E,0x4F53,0x6982,0x89C8)
        $tblHead   = '^##\s*' + (Chars 0x8868,0x7ED3,0x6784,0x5B9A,0x4E49)
        if ($stack.orm -and (Test-Path -LiteralPath $dataFile)) {
            $dl = [System.IO.File]::ReadAllLines($dataFile, [System.Text.Encoding]::UTF8)
            $real = @(Get-SectionSubHeadings $dl $tblHead | Where-Object {
                ($_ -notmatch '^###\s*<') -and ($_ -notmatch '\bTODO\b')
            })
            if ($real.Count -eq 0) {
                Add-Result 'coverage' 'WARN' "data model: orm=$($stack.orm) but no real table section yet"
            }
        }
        if (Test-Path -LiteralPath $bizFile) {
            $bl2 = [System.IO.File]::ReadAllLines($bizFile, [System.Text.Encoding]::UTF8)
            if ($stack.orm) {
                $real = @(Get-SectionTableRows $bl2 $entHead | Where-Object { Test-RealTableRow $_ })
                if ($real.Count -eq 0) { Add-Result 'coverage' 'WARN' 'business model: orm detected but the entity table has no real row' }
            }
            if ($stack.mq) {
                $real = @(Get-SectionTableRows $bl2 $msgHead | Where-Object { Test-RealTableRow $_ })
                if ($real.Count -eq 0) { Add-Result 'coverage' 'WARN' 'business model: MQ detected but the message table has no real row' }
            }
            if ($stack.cache) {
                $real = @(Get-SectionTableRows $bl2 $cacheHead | Where-Object { Test-RealTableRow $_ })
                if ($real.Count -eq 0) { Add-Result 'coverage' 'WARN' 'business model: cache detected but the cache table has no real row' }
            }
        }
    }
}

# ----------------------------------------------------------------- 5 fill-depth
# A rule or wiki page that still carries "<...>" is a template, not a fact: the
# >=5-line check cannot see that, so a project could pass with the skeleton.
# "TODO(...)" is the protocol's explicit deferral and stays legal. Fenced code
# and inline code are skipped, and identifier-shaped tokens (<T>, <String>) are
# code names rather than slots -- otherwise every generic would be a failure.
function Test-ProsePlaceholder {
    param([string]$Line)
    # html comments and autolinks are ordinary markdown, not slots
    $probe = $Line -replace '<!--.*?-->', ''
    $probe = $probe -replace '`[^`]*`', ''
    foreach ($m in [regex]::Matches($probe, '<([^<>]*)>')) {
        $inner = $m.Groups[1].Value.Trim()
        if ($inner -match '^[a-z][a-z0-9+.-]*:') { continue }
        # generic parameters (<T>, <K>, <String>) and inline html tags are code
        if ($inner -match '^[A-Z][A-Za-z0-9_]*$') { continue }
        if ($inner -match '^(br|hr|b|i|em|strong|code|a|img|span|div|p|sup|sub)$') { continue }
        return $true
    }
    return $false
}
if ($codeExists) {
    $agentsDoc3 = Join-Path $rootPath 'AGENTS.md'
    $agentsFilled3 = $false
    if (Test-Path -LiteralPath $agentsDoc3) {
        $agentsFilled3 = $true
        $inFenceA = $false
        foreach ($l in [System.IO.File]::ReadAllLines($agentsDoc3, [System.Text.Encoding]::UTF8)) {
            if ($l -match '^\s*(```|~~~)') { $inFenceA = -not $inFenceA; continue }
            if ($inFenceA) { continue }
            # Same placeholder test as the files below: a bare "<br>" or a
            # generic must not make the whole check silently skip.
            if (Test-ProsePlaceholder $l) { $agentsFilled3 = $false; break }
        }
    }
    if ($agentsFilled3) {
        $hits = New-Object System.Collections.Generic.List[string]
        foreach ($docDir in @('.harness\rules', '.harness\wiki')) {
            $dp = Join-Path $rootPath ($docDir -replace '/', '\')
            if (-not (Test-Path -LiteralPath $dp)) { continue }
            foreach ($doc in @(Get-ChildItem -LiteralPath $dp -Filter *.md -File -Force -ErrorAction SilentlyContinue)) {
                $inFence = $false
                $ln = 0
                foreach ($l in [System.IO.File]::ReadAllLines($doc.FullName, [System.Text.Encoding]::UTF8)) {
                    $ln++
                    if ($l -match '^\s*(```|~~~)') { $inFence = -not $inFence; continue }
                    if ($inFence) { continue }
                    if (Test-ProsePlaceholder $l) { $hits.Add(($doc.Name + ':' + $ln)) }
                }
            }
        }
        if ($hits.Count -gt 0) {
            $shown = @($hits | Select-Object -First 3)
            Add-Result 'fill-depth' 'FAIL' ("{0} placeholder line(s) left in rules/wiki, first: {1}" -f $hits.Count, ($shown -join ', '))
        } else {
            Add-Result 'fill-depth' 'PASS' 'no template placeholders left in rules/wiki'
        }
    }
}

# -------------------------------------------------------------------- summary
$failCount = @($results | Where-Object { $_.Status -eq 'FAIL' }).Count
$warnCount = @($results | Where-Object { $_.Status -eq 'WARN' }).Count
$passCount = @($results | Where-Object { $_.Status -eq 'PASS' }).Count

if (-not $Quiet) {
    Write-Host ""
    Write-Host "grounding verification -- $rootPath" -ForegroundColor Cyan
    Write-Host ("-" * 70)
    foreach ($r in $results) {
        $color = switch ($r.Status) {
            'PASS' { 'Green' }
            'WARN' { 'Yellow' }
            default { 'Red' }
        }
        Write-Host ("  [{0}] {1,-11} {2}" -f $r.Status, $r.Check, $r.Detail) -ForegroundColor $color
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

exit 0
