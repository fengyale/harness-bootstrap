<#
  stage-gate.ps1 -- pipeline stage readiness check (stateless, computed on demand)

  WHY
    The pipeline is a protocol, not a machine: nothing physically stops an agent from
    skipping stage 4 and jumping to stage 5. This script gives it teeth without
    becoming a state machine -- it recomputes readiness from evidence on disk.

    Principle: "if the gate does not pass, you do not move on."

  CRITERIA KINDS
    AUTO  - machine verifiable (file exists, scan clean, command exits 0)
    HUMAN - cannot be verified from disk; reported but never blocks

  SKIP
    A declared command row that is still a placeholder or marked not-applicable
    prints [SKIP] and does not block. A missing row is a FAIL, not a SKIP: "declared
    but not measured" and "not declared at all" are different gaps. The SKIP count
    is printed separately so "not checked" never looks like "passed".

  USAGE  (no pwsh on Windows PS 5.1; Bypass required by execution policy)
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\stage-gate.ps1 -ListStages
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\stage-gate.ps1 -Stage 4 -Feature <name>
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\stage-gate.ps1 -All -Feature <name>

  EXIT CODE  0 = ready (HUMAN items may remain) / 1 = not ready

  NOTE  Pure ASCII. Chinese match strings live in stage-gate-rules.json (read as UTF-8).
#>
[CmdletBinding()]
param(
    [string]$Stage = '',
    [string]$Feature = '',
    [string]$Root = (Get-Location).Path,
    [switch]$All,
    [switch]$ListStages
)

$ErrorActionPreference = 'Stop'
$rootPath    = (Resolve-Path -LiteralPath $Root).Path
$changesRoot = Join-Path $rootPath '.harness\changes'

$rulesPath = Join-Path $PSScriptRoot 'stage-gate-rules.json'
if (-not (Test-Path -LiteralPath $rulesPath)) { throw "Rule file not found: $rulesPath" }
$RULES = (Get-Content -LiteralPath $rulesPath -Raw -Encoding UTF8) | ConvertFrom-Json

# Delegate to the PowerShell that exists on this machine: Windows ships
# powershell.exe, a POSIX/pwsh-only box has pwsh. Hardcoding one name made the
# gate crash instead of reporting a failed criterion.
$PS = if (Get-Command powershell -ErrorAction SilentlyContinue) { 'powershell' } else { 'pwsh' }

function New-Stage {
    param([string]$Key, [string]$Name, [array]$Criteria)
    return [pscustomobject]@{ Key = $Key; Name = $Name; Criteria = $Criteria }
}

$stageDefs = @(
    New-Stage '1' 'requirement analysis' @(
        @{ Id='summary-exists';       Kind='AUTO';  Text='summary.md exists under .harness/changes/<feature>/' },
        @{ Id='summary-sections';     Kind='AUTO';  Text='summary.md has what / why sections' },
        @{ Id='summary-fields-initial'; Kind='AUTO'; Text='summary.md records loaded_skills / flow / corrections / impl_corrections' },
        @{ Id='acceptance-checkable'; Kind='HUMAN'; Text='every acceptance criterion is verifiable' }
    )
    New-Stage '2' 'solution design' @(
        @{ Id='tech-impact';   Kind='AUTO';  Text='summary.md has an impact section (modules / interfaces / tables)' },
        @{ Id='risks-listed';  Kind='AUTO';  Text='summary.md writes the main risk' },
        @{ Id='tasks-listed';  Kind='AUTO';  Text='summary.md breaks the work into tasks (<= 4h each)' },
        @{ Id='plan-reviewed'; Kind='HUMAN'; Text='the user confirmed the design direction' }
    )
    New-Stage '3' 'coding' @(
        @{ Id='summary-exists'; Kind='AUTO';  Text='summary.md exists (stage 1 product)' },
        @{ Id='compiles';       Kind='AUTO';  Text='compile / type-check command from AGENTS.md exits 0 (placeholder row -> SKIP, missing row -> BLOCKED)' },
        @{ Id='change-size';    Kind='HUMAN'; Text='change size <= 40% of touched files' }
    )
    New-Stage '4' 'static check' @(
        @{ Id='red-lines';   Kind='AUTO'; Text='last pre-commit scan passed and the last commit was scanned' },
        @{ Id='gate-proven'; Kind='AUTO'; Text='pre-commit and pre-merge-commit are harness hooks calling red-line-scan' }
    )
    New-Stage '5' 'test (unit + integration)' @(
        @{ Id='compiles';              Kind='AUTO';  Text='compile / type-check command from AGENTS.md exits 0 (placeholder row -> SKIP, missing row -> BLOCKED)' },
        @{ Id='verification-recorded'; Kind='AUTO';  Text='summary.md records how the change was verified' },
        @{ Id='tests-green';           Kind='AUTO';  Text='test command from AGENTS.md exits 0, 0 tests allowed (placeholder row -> SKIP, missing row -> BLOCKED)' },
        @{ Id='coverage';              Kind='HUMAN'; Text='key logic coverage meets the project bar' },
        @{ Id='integration';           Kind='HUMAN'; Text='integration path verified, or the skip reason is recorded' }
    )
    New-Stage '6' 'code review' @(
        @{ Id='review-recorded'; Kind='AUTO';  Text='summary.md has a review conclusion' },
        @{ Id='shortfall-listed'; Kind='AUTO'; Text='summary.md states which missing capability was added (A3+)' },
        @{ Id='review-report';   Kind='HUMAN'; Text='no open RED issue' },
        @{ Id='six-dimensions';  Kind='HUMAN'; Text='all review dimensions were concluded' }
    )
    New-Stage '7' 'merge (quality gate)' @(
        @{ Id='compiles';    Kind='AUTO';  Text='compile / type-check command from AGENTS.md exits 0 (placeholder row -> SKIP, missing row -> BLOCKED)' },
        @{ Id='tests-green'; Kind='AUTO';  Text='test command from AGENTS.md exits 0 (placeholder row -> SKIP, missing row -> BLOCKED)' },
        @{ Id='red-lines';   Kind='AUTO'; Text='last pre-commit scan passed and the last commit was scanned' },
        @{ Id='gate-proven'; Kind='AUTO'; Text='pre-commit and pre-merge-commit are harness hooks calling red-line-scan' }
    )
    New-Stage '8' 'deploy (conditional)' @(
        @{ Id='compiles';          Kind='AUTO';  Text='compile / type-check command from AGENTS.md exits 0 before deploy (placeholder row -> SKIP, missing row -> BLOCKED)' },
        @{ Id='migrations-paired'; Kind='AUTO'; Text='db-migrations.sql and rollback.sql are paired' }
    )
    New-Stage '9' 'verify (conditional)' @(
        @{ Id='rollback-ready'; Kind='AUTO';  Text='rollback plan recorded in summary.md' },
        @{ Id='smoke-done';     Kind='HUMAN'; Text='key interfaces return code=0, no new ERROR in logs' }
    )
    New-Stage '10' 'distill' @(
        @{ Id='distill-recorded'; Kind='AUTO';  Text='summary.md has a distill / lesson section' },
        @{ Id='summary-fields-final'; Kind='AUTO'; Text='summary.md fields are complete and valid' },
        @{ Id='metrics-normal';   Kind='HUMAN'; Text='no new error type left unrecorded' }
    )
)

function Get-SummaryText {
    param([string]$FeatureName)
    if (-not $FeatureName) { return $null }
    $f = Join-Path $changesRoot "$FeatureName\summary.md"
    if (-not (Test-Path -LiteralPath $f)) { return $null }
    return (Get-Content -LiteralPath $f -Raw -Encoding UTF8)
}

# Returns the raw command cell of the first matching row, or $null when the
# table has no such row. Returning the raw cell (not a cleaned command) lets the
# caller tell "row declared but not yet measured" (placeholder) apart from
# "row missing" (AGENTS.md is incomplete) -- those are different failures.
function Get-AgentsCommandRow {
    param([string]$ProjectRoot, [string[]]$Keywords, [string[]]$SectionNames)
    $agents = Join-Path $ProjectRoot 'AGENTS.md'
    if (-not (Test-Path -LiteralPath $agents)) { return $null }
    $lines = [System.IO.File]::ReadAllLines($agents, [System.Text.Encoding]::UTF8)

    # Only rows inside the run-commands section count. Scanning every table used
    # to execute a cell from the red-line table whenever that row happened to
    # contain a keyword such as "compile".
    $start = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        # The template labels this section in bold (**run commands**) rather than
        # as a heading, so both forms count as a section marker.
        $isSectionLine = ($lines[$i] -match '^#{2,6}[ \t]*') -or ($lines[$i] -match '^\*\*')
        if ($isSectionLine -and (Test-HasAny -Text $lines[$i] -Needles $SectionNames)) {
            $start = $i
            break
        }
    }
    if ($start -lt 0) { return $null }

    for ($i = $start + 1; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($line -match '^#{2,6}[ \t]*') { break }
        if ($line -notmatch '^\|') { continue }
        foreach ($kw in $Keywords) {
            if ($line -match [regex]::Escape($kw)) {
                # An escaped pipe (\|) belongs to the command, not to the table:
                # Split('|') silently truncated it and ran a different command.
                $cells = [regex]::Split($line.Trim().Trim('|'), '(?<!\\)\|')
                if ($cells.Count -ge 2) {
                    return ($cells[1].Trim() -replace '\\\|', '|')
                }
            }
        }
    }
    return $null
}

function Test-RunCommand {
    # [object], not [string]: PowerShell coerces "no output" ($null) to '' when
    # binding to [string], which made a MISSING table row look like an EMPTY
    # cell and turned the promised FAIL into a SKIP.
    param([object]$RawCell, [string[]]$SkipMarkers, [string[]]$SkipExact)
    # Tri-state, not boolean:
    #   Found=$false              -> the table has no such row: FAIL (declare it)
    #   Found=$true, Ran=$false   -> placeholder / not-applicable marker: SKIP
    #   Ran=$true                 -> the command really ran; exit code decides
    # SKIP is printed as SKIP and counted separately, so "not checked" never looks
    # like "passed"; a missing row is a configuration gap, not a free pass.
    if ($null -eq $RawCell) {
        return @{ Ok = $false; Ran = $false; Found = $false; Detail = 'AGENTS.md run-commands table has no such row (add a measured command, or mark it not-applicable)' }
    }
    $cmd = ([string]$RawCell).Trim().Trim('`').Trim()
    # Two marker styles: phrases that announce themselves anywhere in the cell
    # ("pending measurement", "TBD") and bare words that are a marker only when they are the
    # whole cell ("none", "n/a", "-"). Substring matching for the latter turned a
    # real command containing "none" into a silent SKIP.
    $exact = @()
    if ($SkipExact) { $exact = @($SkipExact) }
    $isExactMarker = @($exact | Where-Object { $_ -and ($cmd -eq [string]$_) }).Count -gt 0
    if (($cmd -eq '') -or ($cmd -match '<') -or $isExactMarker -or (Test-HasAny -Text $cmd -Needles $SkipMarkers)) {
        return @{ Ok = $false; Ran = $false; Found = $true; Detail = "row is a placeholder or not-applicable marker: $RawCell" }
    }
    # Same command, same answer: -All would otherwise compile and test four times.
    if ($script:cmdCache.ContainsKey($cmd)) { return $script:cmdCache[$cmd] }
    # The command belongs to the project, so it must run in the project root;
    # without this, -Root <path> ran the build in the caller's directory.
    Push-Location -LiteralPath $rootPath
    try {
        $out  = & $PS -NoProfile -ExecutionPolicy Bypass -Command $cmd 2>&1 | Out-String
        $code = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    if ($code -eq 0) {
        $res = @{ Ok = $true; Ran = $true; Found = $true; Detail = "$cmd -> exit 0" }
    } else {
        $tail = ($out -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 2) -join ' / '
        $res = @{ Ok = $false; Ran = $true; Found = $true; Detail = "$cmd -> exit $code ; $tail" }
    }
    $script:cmdCache[$cmd] = $res
    return $res
}

$script:cmdCache = @{}

# Field-level exit check. Kept in its own script so stage-gate, pre-commit and
# verify-harness all use the same rules instead of three drifting regexes.
function Test-SummaryFields {
    param([string]$FeatureName, [string]$ProjectRoot, [string]$GateStage)
    if (-not $FeatureName) { return @{ Ok = $false; Detail = 'no -Feature given' } }
    $check = Join-Path $ProjectRoot 'scripts\check-summary.ps1'
    if (-not (Test-Path -LiteralPath $check)) {
        return @{ Ok = $false; Detail = 'missing scripts\check-summary.ps1' }
    }
    $out = & $PS -NoProfile -ExecutionPolicy Bypass -File $check -Root $ProjectRoot -Feature $FeatureName -Stage $GateStage 2>&1
    $code = $LASTEXITCODE
    if ($code -eq 0) { return @{ Ok = $true; Detail = (@($out) | Select-Object -Last 1) } }
    $first = @($out | Where-Object { $_ -match 'FAIL' } | Select-Object -First 1)
    return @{ Ok = $false; Detail = [string]$first }
}

function Test-HasAny {
    param([string]$Text, [string[]]$Needles)
    foreach ($n in $Needles) { if ($Text -match [regex]::Escape($n)) { return $true } }
    return $false
}

# A section counts only when it exists as a heading. A passing mention in prose
# ("risk: low", "reviewed already") used to satisfy the gate without the section
# being written. Body truth is the reviewer's job; structure is this gate's job.
function Test-SectionHeading {
    param([string]$Text, [string[]]$Needles)
    foreach ($n in $Needles) {
        if ($Text -match ('(?m)^#{2,6}[ \t]*' + [regex]::Escape($n))) { return $true }
    }
    return $false
}

# Body of a heading section, up to the next heading. Needed where the section
# must carry a conclusion, not just a title.
function Get-SectionBody {
    param([string]$Text, [string[]]$Needles)
    foreach ($n in $Needles) {
        $rx = '(?ms)^#{2,6}[ \t]*' + [regex]::Escape($n) + '[ \t]*\r?\n(.*?)(?=\r?\n#{2,6}[ \t]|\z)'
        $m = [regex]::Match($Text, $rx)
        if ($m.Success) { return $m.Groups[1].Value }
    }
    return $null
}

function Test-Criterion {
    param($Criterion, [string]$FeatureName, [string]$ProjectRoot)

    $summary = Get-SummaryText -FeatureName $FeatureName
    $S = $RULES.summarySections
    $M = $RULES.messages

    switch ($Criterion.Id) {
        'summary-exists' {
            if (-not $FeatureName) { return @{ Ok=$false; Detail=$M.noFeature } }
            if ($summary) { return @{ Ok=$true; Detail=$M.summaryFound } }
            return @{ Ok=$false; Detail="missing .harness/changes/$FeatureName/summary.md" }
        }
        'summary-sections' {
            if (-not $summary) { return @{ Ok=$false; Detail='no summary.md' } }
            # Keywords for one criterion are OR-ed (stage-gate-rules.json). Requiring
            # both requirement keywords blocked a summary that states the why inside
            # the overview paragraph, which the template explicitly allows.
            if (Test-HasAny -Text $summary -Needles $S.requirement) { return @{ Ok=$true; Detail=$M.present } }
            return @{ Ok=$false; Detail="$($M.missingSections): $($S.requirement -join ', ')" }
        }
        'summary-fields-initial' {
            return Test-SummaryFields -FeatureName $FeatureName -ProjectRoot $ProjectRoot -GateStage 'initial'
        }
        'summary-fields-final' {
            return Test-SummaryFields -FeatureName $FeatureName -ProjectRoot $ProjectRoot -GateStage 'final'
        }
        'tech-impact' {
            if (-not $summary) { return @{ Ok=$false; Detail='no summary.md' } }
            if (Test-SectionHeading -Text $summary -Needles $S.techImpact) { return @{ Ok=$true; Detail=$M.present } }
            return @{ Ok=$false; Detail='no technical change list' }
        }
        'risks-listed' {
            if (-not $summary) { return @{ Ok=$false; Detail='no summary.md' } }
            if (Test-SectionHeading -Text $summary -Needles $S.risk) { return @{ Ok=$true; Detail=$M.present } }
            return @{ Ok=$false; Detail='no risk section' }
        }
        'tasks-listed' {
            if (-not $summary) { return @{ Ok=$false; Detail='no summary.md' } }
            if (Test-SectionHeading -Text $summary -Needles $S.tasks) { return @{ Ok=$true; Detail=$M.present } }
            return @{ Ok=$false; Detail='no task breakdown table' }
        }
        'rollback-ready' {
            if (-not $summary) { return @{ Ok=$false; Detail='no summary.md' } }
            if (Test-SectionHeading -Text $summary -Needles $S.rollback) { return @{ Ok=$true; Detail=$M.present } }
            return @{ Ok=$false; Detail='no rollback section' }
        }
        'verification-recorded' {
            if (-not $summary) { return @{ Ok=$false; Detail='no summary.md' } }
            if (Test-SectionHeading -Text $summary -Needles $S.verification) { return @{ Ok=$true; Detail=$M.present } }
            return @{ Ok=$false; Detail='no verification section (how was it verified)' }
        }
        'review-recorded' {
            if (-not $summary) { return @{ Ok=$false; Detail='no summary.md' } }
            if (Test-SectionHeading -Text $summary -Needles $S.review) { return @{ Ok=$true; Detail=$M.present } }
            return @{ Ok=$false; Detail='no review conclusion section' }
        }
        'shortfall-listed' {
            if (-not $summary) { return @{ Ok=$false; Detail='no summary.md' } }
            # A3+ is an acceptance criterion, so it needs a machine-readable resting
            # place. The section must either conclude "none" or name the capability
            # that was actually added (a rule / script / skill path).
            $body = Get-SectionBody -Text $summary -Needles $S.shortfall
            if ($null -eq $body) { return @{ Ok=$false; Detail='no shortfall section (which missing capability was added)' } }
            if (Test-HasAny -Text $body -Needles $RULES.noneMarkers) { return @{ Ok=$true; Detail=$M.present } }
            if ($body -match '(\.harness|scripts)[\\/]') { return @{ Ok=$true; Detail=$M.present } }
            return @{ Ok=$false; Detail='shortfall section does not name the added capability (write its path, or a none marker)' }
        }
        'distill-recorded' {
            if (-not $summary) { return @{ Ok=$false; Detail='no summary.md' } }
            if (Test-SectionHeading -Text $summary -Needles $S.distill) { return @{ Ok=$true; Detail=$M.present } }
            return @{ Ok=$false; Detail='no distill / lesson section' }
        }
        'compiles' {
            return Test-RunCommand -RawCell (Get-AgentsCommandRow -ProjectRoot $ProjectRoot -Keywords $RULES.agentsCommandPurpose.compile -SectionNames $RULES.agentsCommandSection) -SkipMarkers $RULES.commandSkipMarkers -SkipExact $RULES.commandSkipExact
        }
        'tests-green' {
            return Test-RunCommand -RawCell (Get-AgentsCommandRow -ProjectRoot $ProjectRoot -Keywords $RULES.agentsCommandPurpose.test -SectionNames $RULES.agentsCommandSection) -SkipMarkers $RULES.commandSkipMarkers -SkipExact $RULES.commandSkipExact
        }
        'red-lines' {
            # Read the last pre-commit scan instead of running a full scan: a legacy
            # project carries hundreds of historical violations, so a full scan would
            # always FAIL and this gate would be permanently blocked.
            $log = Join-Path $ProjectRoot '.harness\metrics\gate.jsonl'
            if (-not (Test-Path -LiteralPath $log)) {
                return @{ Ok=$false; Detail='no scan record yet: commit once through the hook' }
            }
            $last = @(Get-Content -LiteralPath $log -Tail 200 -ErrorAction SilentlyContinue |
                      Where-Object { $_ -match '"event"\s*:\s*"scan"' }) | Select-Object -Last 1
            if (-not $last) { return @{ Ok=$false; Detail='no scan event in gate.jsonl' } }
            if ($last -match '"blocked"\s*:\s*1') {
                return @{ Ok=$false; Detail='the last scan was blocked: fix red lines first' }
            }
            # A passing scan from an older commit proves nothing about this one.
            # post-commit records scanned:0 when --no-verify skipped the gate; if
            # such a commit exists after the scan, stage 7 must not open on it.
            $lastCommit = @(Get-Content -LiteralPath $log -Tail 200 -ErrorAction SilentlyContinue |
                            Where-Object { $_ -match '"event"\s*:\s*"commit"' }) | Select-Object -Last 1
            if ($lastCommit -and $lastCommit -match '"scanned"\s*:\s*0') {
                return @{ Ok=$false; Detail='the last commit bypassed the gate (--no-verify): commit through the hook once' }
            }
            return @{ Ok=$true; Detail='the last scan passed (new lines only)' }
        }
        'gate-proven' {
            # Hooks live in the COMMON git dir. In a linked worktree
            # --absolute-git-dir points at .git/worktrees/<name>, while git
            # actually runs <main>/.git/hooks. --git-path hooks answers with the
            # effective directory and also honours core.hooksPath.
            $hooksDir = $null
            try { $hooksDir = (& git -C $ProjectRoot rev-parse --git-path hooks 2>$null | Select-Object -First 1) } catch { $hooksDir = $null }
            if ($hooksDir) {
                $hooksDir = ([string]$hooksDir).Trim()
                if (-not [System.IO.Path]::IsPathRooted($hooksDir)) {
                    $hooksDir = [System.IO.Path]::GetFullPath((Join-Path $ProjectRoot $hooksDir))
                }
            }
            if (-not $hooksDir) { $hooksDir = Join-Path $ProjectRoot '.git\hooks' }
            $pre   = Join-Path $hooksDir 'pre-commit'
            $merge = Join-Path $hooksDir 'pre-merge-commit'
            if (-not (Test-Path -LiteralPath $pre)) { return @{ Ok=$false; Detail='no pre-commit hook' } }
            # The install marker matters: a hook that merely mentions
            # red-line-scan in a comment proves a string, not a gate. The marker
            # is written by install-git-hooks.ps1 into every hook it owns.
            $marker = 'harness pre-commit gate'
            $preBody = Get-Content -LiteralPath $pre -Raw -Encoding UTF8
            if ($preBody -notmatch 'red-line-scan' -or $preBody -notmatch [regex]::Escape($marker)) {
                return @{ Ok=$false; Detail='pre-commit is not the harness gate (marker or scanner missing)' }
            }
            # a merge commit never fires pre-commit; without the merge hook the
            # gate is only half installed
            if (-not (Test-Path -LiteralPath $merge)) {
                return @{ Ok=$false; Detail='no pre-merge-commit hook: merges bypass the gate' }
            }
            $mergeBody = Get-Content -LiteralPath $merge -Raw -Encoding UTF8
            if ($mergeBody -notmatch 'red-line-scan' -or $mergeBody -notmatch [regex]::Escape($marker)) {
                return @{ Ok=$false; Detail='pre-merge-commit is not the harness gate (marker or scanner missing)' }
            }
            return @{ Ok=$true; Detail='pre-commit and pre-merge-commit are harness hooks calling red-line-scan' }
        }
        'migrations-paired' {
            if (-not $FeatureName) { return @{ Ok=$true; Detail='no feature given, nothing to check' } }
            $dir    = Join-Path $changesRoot $FeatureName
            $hasMig = Test-Path -LiteralPath (Join-Path $dir 'db-migrations.sql')
            $hasRb  = Test-Path -LiteralPath (Join-Path $dir 'rollback.sql')
            if (-not $hasMig -and -not $hasRb) { return @{ Ok=$true; Detail=$M.noDdl } }
            if ($hasMig -and $hasRb) { return @{ Ok=$true; Detail=$M.paired } }
            if ($hasMig) { return @{ Ok=$false; Detail=$M.notPaired } }
            return @{ Ok=$false; Detail=$M.reverseNotPaired }
        }
        default {
            return @{ Ok=$false; Detail="criterion not implemented: $($Criterion.Id)" }
        }
    }
}

if ($ListStages) {
    foreach ($d in $stageDefs) {
        Write-Host ""
        Write-Host "Stage $($d.Key) - $($d.Name)" -ForegroundColor Cyan
        foreach ($c in $d.Criteria) {
            $tag = if ($c.Kind -eq 'AUTO') { '[AUTO ]' } else { '[HUMAN]' }
            Write-Host ("  {0} {1,-20} {2}" -f $tag, $c.Id, $c.Text)
        }
    }
    Write-Host ""
    exit 0
}

$targets = @()
if ($All) {
    $targets = @($stageDefs)
} elseif ($Stage -ne '') {
    $one = @($stageDefs | Where-Object { $_.Key -eq $Stage })
    if ($one.Count -eq 0) { throw "Stage '$Stage' is not defined. Use -ListStages." }
    $targets = $one
} else {
    throw "Specify -Stage <n> or -All. Use -ListStages to see the definitions."
}

$anyFail = $false

foreach ($d in $targets) {
    Write-Host ""
    Write-Host "Stage $($d.Key) - $($d.Name)" -ForegroundColor Cyan
    Write-Host ("-" * 70)

    $autoFail = 0; $autoPass = 0; $humanCount = 0; $skipCount = 0
    foreach ($c in $d.Criteria) {
        if ($c.Kind -eq 'HUMAN') {
            $humanCount++
            Write-Host ("  [MANUAL] {0,-20} {1}" -f $c.Id, $c.Text) -ForegroundColor DarkGray
            continue
        }
        $r = Test-Criterion -Criterion $c -FeatureName $Feature -ProjectRoot $rootPath
        # A declared row that is not filled in yet: report the gap, do not block.
        if ($r.Ran -eq $false -and $r.Found -eq $true) {
            $skipCount++
            Write-Host ("  [SKIP]   {0,-20} {1}" -f $c.Id, $r.Detail) -ForegroundColor Yellow
            continue
        }
        if ($r.Ok) {
            $autoPass++
            Write-Host ("  [PASS]   {0,-20} {1}" -f $c.Id, $r.Detail) -ForegroundColor Green
        } else {
            $autoFail++
            Write-Host ("  [FAIL]   {0,-20} {1}" -f $c.Id, $r.Detail) -ForegroundColor Red
        }
    }

    Write-Host ("-" * 70)
    if ($autoFail -gt 0) {
        $anyFail = $true
        Write-Host ("  RESULT: NOT READY  (auto pass={0} fail={1} skip={2}, manual={3})" -f $autoPass, $autoFail, $skipCount, $humanCount) -ForegroundColor Red
        Write-Host ("  Cannot move past stage {0} until the FAIL rows are fixed." -f $d.Key) -ForegroundColor Red
    } else {
        Write-Host ("  RESULT: READY  (auto pass={0} skip={1}, manual={2} to confirm yourself)" -f $autoPass, $skipCount, $humanCount) -ForegroundColor Green
    }
}

Write-Host ""
if ($anyFail) { Write-Host "Gate result: BLOCKED" -ForegroundColor Red; exit 1 }
Write-Host "Gate result: OPEN" -ForegroundColor Green
exit 0
