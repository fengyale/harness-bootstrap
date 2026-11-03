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
    4. size         per-file line budget; skill count is unlimited by default,
                    pass -MaxGrounded N only during cold start
    5. stale        code behind an [E2] anchor changed after the skill was verified
                    ("- verified: YYYY-MM-DD" resets the clock; WARN only)

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
    [int]$MaxSkillLines = 120,
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
    foreach ($d in @('src', 'app', 'lib', 'source')) {
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
        Get-ChildItem -LiteralPath $bp -Recurse -File -Force -ErrorAction SilentlyContinue |
            ForEach-Object { $harnessBasenames[$_.Name] = $true }
    }
}

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
        if ($e0 -gt 0) {
            if ($codeExists) {
                Add-Result 'grounded' 'WARN' "$($s.Category)/$($s.Name): code exists -- replace [E0] confirmations with [E1]/[E2]"
            } else {
                Add-Result 'grounded' 'WARN' "$($s.Category)/$($s.Name): new project without code -- [E0] confirmations only; upgrade to [E1]/[E2] once code exists"
            }
        } else {
            Add-Result 'grounded' 'WARN' "$($s.Category)/$($s.Name): no [E1]/[E2] anchor (ungrounded skill)"
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
        Add-Result 'stale' 'WARN' "$($s.Name): $($staleList.Count) watched file(s) changed after verified $($verified.ToString('yyyy-MM-dd')): $($shown -join '; ')"
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

    # --- 4 quota: per-file size. The budget in the docs is a hard limit
    #     (<= 80 target, 120 max), so over-budget must FAIL; a WARN let every
    #     install drift past the number that keeps progressive loading cheap.
    if ($lines.Count -gt $MaxSkillLines) {
        Add-Result 'quota' 'FAIL' "$($s.Category)/$($s.Name): $($lines.Count) lines (hard limit $MaxSkillLines; target <= 80)"
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
} elseif ($groundedCount -gt 0) {
    Add-Result 'grounded' 'PASS' "$groundedCount grounded skill(s)"
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
