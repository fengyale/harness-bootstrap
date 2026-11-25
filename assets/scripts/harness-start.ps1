<#
  harness-start.ps1 -- one command to open a task (plan + record + stage 1 + marker)

  WHY
    Starting a task used to be four manual steps: read the plan, copy the summary
    template, fill the countable fields, run stage 1 -- and the marker used by the
    optional pre-commit task-start gate was written by hand or forgotten. One
    command keeps those steps in sync, so "started coding without a record" stops
    being something an agent can do by accident.

  WHAT IT DOES
    1. prints the read-only context pack (scripts\harness-plan.ps1) when present.
       The plan is an aid: a failure prints a warning and the start continues.
    2. creates .harness/changes/<feature>/summary.md from the template when it is
       missing, pre-filling flow and touched_modules. An existing record is never
       overwritten (only stage 1 and the marker run).
    3. runs scripts\stage-gate.ps1 -Stage 1
         OPEN    -> writes .git/harness-task-started (feature / at / flow), exit 0
         BLOCKED -> prints the missing fields, writes no marker, exit 1

  GUARDS
    -Feature is validated: no path separators, no .., no whitespace or reserved
    characters, and the resolved directory must sit under .harness/changes.
    -Flow L0 is refused (L0 keeps no record); -Flow L1 warns that L1 normally
    uses .harness/changes/_small.md.
    The plan's flow hint and matched module cards pre-fill flow / touched_modules
    when -Flow / -Modules are not passed; an explicit argument always wins.
    When the project declares modules (module cards or a module column in the
    AGENTS.md command table) and neither -Modules nor the plan names one, a
    warning names the risk: stage 3 may FAIL on touched_modules=none.
    Not a git repository: stage 1 still runs, but no marker is written (WARN).

  NOTE ON THE GATE
    requireTaskStart defaults to false on a fresh install and on an upgrade. A
    team turns it on after adopting this entry point; the pre-commit hook then
    checks the marker only for commits that land a summary.md.

  USAGE
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\harness-start.ps1 -Feature order-export -Requirement "export orders to excel"
    ... -Feature order-export -Flow L3 -Modules order,report -SkipPlan
    ... -Feature probe -Requirement "why does export drop rows" -Investigation
    ... -SelfTest

  NOTE
    Pure ASCII on purpose (PS 5.1 parses a BOM-less .ps1 as ANSI).
#>
[CmdletBinding()]
param(
    [string]$Root = (Get-Location).Path,
    [string]$Feature = '',
    [string]$Requirement = '',
    [ValidateSet('L0', 'L1', 'L2', 'L3')]
    [string]$Flow = 'L2',
    [string]$Modules = '',
    [switch]$SkipPlan,
    [switch]$SkipPreflight,
    [switch]$Investigation,
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'

$PS = if (Get-Command powershell -ErrorAction SilentlyContinue) { 'powershell' } else { 'pwsh' }
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# Same resolution order as stage-gate / the hook: the effective git dir, then the
# conventional .git directory. $null means "not a repository".
function Get-GitDir {
    param([string]$RootPath)
    $dir = $null
    try { $dir = (& git -C $RootPath rev-parse --absolute-git-dir 2>$null | Select-Object -First 1) } catch { $dir = $null }
    if ($dir) {
        $dir = ([string]$dir).Trim()
        if ([System.IO.Path]::IsPathRooted($dir)) { return $dir }
        return [System.IO.Path]::GetFullPath((Join-Path $RootPath $dir))
    }
    $fallback = Join-Path $RootPath '.git'
    if (Test-Path -LiteralPath $fallback) { return $fallback }
    return $null
}

# Replace only the template slots, never the surrounding prose.
function Set-SummaryPrefill {
    param([string]$Text, [string]$FlowValue, [string]$ModulesValue)
    $t = $Text -replace '(?m)(?<![A-Za-z0-9_\-])flow:\s*<[^>\r\n]*>', ('flow: ' + $FlowValue)
    $t = $t -replace '(?m)(?<![A-Za-z0-9_\-])touched_modules:\s*<[^>\r\n]*>', ('touched_modules: ' + $ModulesValue)
    return $t
}

function Get-ModulesValue {
    param([string]$ModulesText)
    if (-not $ModulesText -or $ModulesText.Trim() -eq '') { return 'none' }
    $items = @($ModulesText -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($items.Count -eq 0) { return 'none' }
    return ($items -join ', ')
}

# A feature name becomes a directory name, so it must stay inside
# .harness/changes. An unchecked value such as ..\..\x would write the record
# outside the project and the marker would name a feature no gate can find.
function Test-FeatureName {
    param([string]$FeatureName, [string]$RootPath)
    if (-not $FeatureName -or $FeatureName.Trim() -eq '') { return 'Feature is empty' }
    if ($FeatureName -match '[\\/:*?"<>|\s]') {
        return 'Feature must not contain path separators, whitespace or reserved characters'
    }
    if ($FeatureName.Contains('..')) { return 'Feature must not contain ..' }
    $changes = Join-Path $RootPath '.harness\changes'
    $changesFull = [System.IO.Path]::GetFullPath($changes).TrimEnd('\')
    $targetFull = [System.IO.Path]::GetFullPath((Join-Path $changes $FeatureName)).TrimEnd('\')
    if ($targetFull -eq $changesFull) { return 'Feature must name a directory under .harness/changes' }
    if (-not $targetFull.StartsWith($changesFull + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
        return 'Feature resolves outside .harness/changes'
    }
    return $null
}

function Test-HasModuleCards {
    param([string]$RootPath)
    $dir = Join-Path $RootPath '.harness\modules'
    if (-not (Test-Path -LiteralPath $dir)) { return $false }
    $cards = @(Get-ChildItem -LiteralPath $dir -Filter '*.md' -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.BaseName -ne 'README' -and $_.BaseName -ne '_template' })
    return ($cards.Count -gt 0)
}

# True when the run-commands table in AGENTS.md has a module column. Section and
# column names are Chinese; they are built from code points so this file stays
# pure ASCII.
function Test-HasModuleColumn {
    param([string]$RootPath)
    $agents = Join-Path $RootPath 'AGENTS.md'
    if (-not (Test-Path -LiteralPath $agents)) { return $false }
    $cnModule = -join ([char]0x6A21, [char]0x5757)
    $cnSection = -join ([char]0x5FC5, [char]0x8DD1, [char]0x547D, [char]0x4EE4)
    $lines = [System.IO.File]::ReadAllLines($agents, [System.Text.Encoding]::UTF8)
    $start = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $isSection = ($lines[$i] -match '^#{2,6}[ \t]*') -or ($lines[$i] -match '^\*\*')
        if ($isSection -and $lines[$i].Contains($cnSection)) { $start = $i; break }
    }
    if ($start -lt 0) { return $false }
    for ($i = $start + 1; $i -lt $lines.Count; $i++) {
        $t = $lines[$i].Trim()
        if ($t -eq '') { if ($i -gt $start + 1) { break } else { continue } }
        if ($t -match '^#{2,6}') { break }
        if ($t -notmatch '^\|') { continue }
        foreach ($c in @($t.Trim('|') -split '\|')) {
            $cell = $c.Trim().Trim('`').Trim()
            if ($cell -eq $cnModule -or $cell -ieq 'module') { return $true }
        }
    }
    return $false
}

# Requirement -> a few literal search terms for history / lesson matching. Same
# idea as harness-plan (Latin words plus CJK runs), capped so git log is not run
# dozens of times per start.
function Get-StartTerms {
    param([string]$Text)
    # A List keeps the insertion order: Latin words first, then CJK runs and
    # 2-grams. A HashSet made the first-10 selection depend on bucket order, so
    # generic terms could crowd out the one that matters.
    $terms = New-Object System.Collections.Generic.List[string]
    if ($Text) {
        foreach ($m in [regex]::Matches($Text, '[A-Za-z][A-Za-z0-9_\-]{2,}')) {
            if (-not $terms.Contains($m.Value)) { $terms.Add($m.Value) }
        }
        foreach ($m in [regex]::Matches($Text, '[\u4e00-\u9fff]{2,}')) {
            $run = $m.Value
            if ($run.Length -le 6 -and -not $terms.Contains($run)) { $terms.Add($run) }
            for ($i = 0; $i -le $run.Length - 2 -and $terms.Count -lt 16; $i++) {
                $t = $run.Substring($i, 2)
                if (-not $terms.Contains($t)) { $terms.Add($t) }
            }
        }
    }
    return @($terms | Select-Object -First 10)
}

# Native stderr becomes a terminating error under $ErrorActionPreference='Stop'
# in PS 5.1, even with 2>$null. Every read-only git call in this file goes
# through here so a harmless CRLF warning cannot kill the start.
function Invoke-GitLines {
    param([string]$RootPath, [string[]]$Arguments)
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { return @(& git -C $RootPath @Arguments 2>$null | ForEach-Object { "$_" }) }
    finally { $ErrorActionPreference = $saved }
}

# Read-only pre-flight: working tree, diff against HEAD, recent commits, and
# whether the requirement terms already appear in history. It never writes and
# never blocks; duplicate work is the most expensive mistake this can prevent.
function Invoke-Preflight {
    param([string]$RootPath, [string]$RequirementText, [string]$FeatureName)
    Write-Host ''
    Write-Host '--- pre-flight (read only) ---' -ForegroundColor Cyan
    $gitDir = Get-GitDir $RootPath
    if (-not $gitDir) {
        Write-Host '[preflight] not a git repository: working tree and history checks skipped' -ForegroundColor Yellow
        Write-Host '--- end of pre-flight ---' -ForegroundColor Cyan
        return
    }
    $status = @(Invoke-GitLines -RootPath $RootPath -Arguments @('status', '--short'))
    if ($status.Count -eq 0) {
        Write-Host '[preflight] working tree clean'
    } else {
        Write-Host ('[WARN] uncommitted changes (' + $status.Count + '):') -ForegroundColor Yellow
        foreach ($s in @($status | Select-Object -First 15)) { Write-Host ('  ' + $s) -ForegroundColor Yellow }
    }
    $diff = @(Invoke-GitLines -RootPath $RootPath -Arguments @('--no-pager', 'diff', '--stat', 'HEAD'))
    if ($diff.Count -eq 0) {
        Write-Host '[preflight] no diff vs HEAD'
    } else {
        Write-Host '[preflight] diff vs HEAD:'
        foreach ($d in @($diff | Select-Object -Last 10)) { Write-Host ('  ' + $d) }
    }
    $recent = @(Invoke-GitLines -RootPath $RootPath -Arguments @('--no-pager', 'log', '--oneline', '-8'))
    if ($recent.Count -gt 0) {
        Write-Host '[preflight] recent commits:'
        foreach ($l in $recent) { Write-Host ('  ' + $l) }
    }
    $terms = @(Get-StartTerms ($RequirementText + ' ' + $FeatureName))
    if ($terms.Count -gt 0) {
        # Collect by commit hash so one commit matched by several terms is shown
        # once. Keep the date and the matched terms, then sort by date: term
        # order used to let generic words fill the five visible slots.
        $hits = @{}
        foreach ($t in $terms) {
            if (-not $t) { continue }
            $found = @(Invoke-GitLines -RootPath $RootPath -Arguments @(
                '--no-pager', 'log', '-n', '3', '-i', '--date=short',
                '--format=%h%x1f%ad%x1f%s',
                ('--grep=' + [regex]::Escape($t))))
            foreach ($f in $found) {
                if (-not $f) { continue }
                $parts = @($f -split ([string][char]0x1f))
                if ($parts.Count -lt 3) { continue }
                $key = $parts[0]
                if (-not $hits.ContainsKey($key)) {
                    $hits[$key] = [pscustomobject]@{
                        Hash    = $parts[0]
                        Date    = $parts[1]
                        Subject = $parts[2]
                        Terms   = (New-Object System.Collections.Generic.List[string])
                    }
                }
                if (-not $hits[$key].Terms.Contains($t)) { $hits[$key].Terms.Add($t) }
            }
        }
        if ($hits.Count -gt 0) {
            # A subject match is only a keyword hit. Add the files the commit
            # touched and label whether any of them matches the requirement /
            # feature terms: path evidence is stronger than a word in a title.
            $needles = New-Object System.Collections.Generic.List[string]
            foreach ($t in @($terms)) { if ($t) { $needles.Add([string]$t) } }
            if ($FeatureName) { $needles.Add([string]$FeatureName) }
            foreach ($h in @($hits.Values)) {
                $files = @(Invoke-GitLines -RootPath $RootPath -Arguments @(
                    '--no-pager', 'show', '--name-only', '--format=', $h.Hash) |
                    Where-Object { $_ -and $_.Trim() })
                $pathHit = $false
                foreach ($f in $files) {
                    $fl = ([string]$f).ToLower()
                    foreach ($n in $needles) {
                        $nl = ([string]$n).ToLower()
                        if ($nl -and $fl.Contains($nl)) { $pathHit = $true; break }
                    }
                    if ($pathHit) { break }
                }
                $h | Add-Member -NotePropertyName Files -NotePropertyValue @($files) -Force
                $h | Add-Member -NotePropertyName PathMatch -NotePropertyValue $pathHit -Force
            }
            Write-Host '[WARN] possible duplicate work (keyword hits; confirm against the listed files):' -ForegroundColor Yellow
            $ordered = @($hits.Values | Sort-Object -Property `
                @{ Expression = 'PathMatch'; Descending = $true }, `
                @{ Expression = 'Date'; Descending = $true }, `
                @{ Expression = 'Hash'; Descending = $true })
            foreach ($h in @($ordered | Select-Object -First 5)) {
                $tag = if ($h.PathMatch) { 'path-match' } else { 'keyword-only' }
                $line = '  [' + $tag + '] ' + $h.Hash + ' ' + $h.Date + ' ' + $h.Subject + '  [' + ($h.Terms -join ',') + ']'
                if (@($h.Files).Count -gt 0) {
                    $line += '  files: ' + ((@($h.Files) | Select-Object -First 3) -join ', ')
                }
                Write-Host $line -ForegroundColor Yellow
            }
            Write-Host '       confirm this is not duplicate work; path-match entries are stronger evidence' -ForegroundColor Yellow
        } else {
            Write-Host '[preflight] no commit message matches the requirement terms'
        }
    }
    Write-Host '--- end of pre-flight ---' -ForegroundColor Cyan
}

# Read the tracked lesson index at task start. Writing it without reading it was
# the reason the same pit was hit twice; the hit is a prompt, not a gate.
function Show-Lessons {
    param([string]$RootPath, [string]$RequirementText, [string]$FeatureName)
    $path = Join-Path $RootPath '.harness\lessons.md'
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Host '[lessons] .harness/lessons.md not found; run scripts\metrics.ps1 once to build it' -ForegroundColor DarkGray
        return
    }
    $terms = @(Get-StartTerms ($RequirementText + ' ' + $FeatureName))
    if ($terms.Count -eq 0) { return }
    $rows = New-Object System.Collections.Generic.List[string]
    foreach ($line in [System.IO.File]::ReadAllLines($path, [System.Text.Encoding]::UTF8)) {
        if ($line -notmatch '^\|\s*`?([A-Za-z0-9][A-Za-z0-9_.\-]*)`?\s*\|') { continue }
        if ($matches[1] -eq 'id') { continue }
        foreach ($t in $terms) {
            if ($t -and $line.IndexOf($t, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                $rows.Add($line)
                break
            }
        }
    }
    if ($rows.Count -eq 0) {
        Write-Host '[lessons] no matching entry for this requirement' -ForegroundColor DarkGray
        return
    }
    Write-Host '[lessons] entries close to this requirement (respond in the summary: lesson_id / shortfall):' -ForegroundColor Yellow
    foreach ($r in @($rows | Select-Object -First 5)) { Write-Host ('  ' + $r) -ForegroundColor Yellow }
}

# Environment probe driven by mcpProbe.entries in harness-required.json. A tool
# registered but unreachable (MCP server, DB, remote) used to surface only when
# the task already depended on it; a cheap reachability check at task start
# turns that into a WARN before any code is written.
function Invoke-EnvProbe {
    param([string]$RootPath)
    $cfgPath = Join-Path $RootPath 'scripts\harness-required.json'
    if (-not (Test-Path -LiteralPath $cfgPath)) { return }
    $cfg = $null
    try { $cfg = (Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8) | ConvertFrom-Json } catch { return }
    if (-not $cfg -or -not $cfg.PSObject.Properties['mcpProbe']) { return }
    $probe = $cfg.mcpProbe
    $entries = @()
    if ($probe.PSObject.Properties['entries'] -and $probe.entries) { $entries = @($probe.entries) }
    if ($entries.Count -eq 0) { return }
    Write-Host '[env-probe] checking declared tools (mcpProbe.entries)...' -ForegroundColor Cyan
    foreach ($e in $entries) {
        $name = if ($e.PSObject.Properties['name']) { [string]$e.name } else { '' }
        $cmd  = if ($e.PSObject.Properties['command']) { [string]$e.command } else { '' }
        if (-not $cmd) { continue }
        $ok = $false
        try {
            Push-Location -LiteralPath $RootPath
            try {
                # Run in-process (not a child powershell): the self test captures
                # stream 6, and a child's output would bypass that capture. A
                # failing command surfaces as a non-zero LASTEXITCODE or a
                # thrown error; both count as unreachable.
                $prevEap = $ErrorActionPreference
                $ErrorActionPreference = 'Continue'
                Invoke-Expression -Command $cmd *> $null
                $ErrorActionPreference = $prevEap
                $ok = ($LASTEXITCODE -eq 0)
            } catch { $ok = $false } finally { Pop-Location }
        } catch { $ok = $false }
        if ($ok) {
            Write-Host ('[env-probe] ok: ' + $name) -ForegroundColor DarkGray
        } else {
            $hint = ''
            if ($probe.PSObject.Properties['unreachableHint']) { $hint = [string]$probe.unreachableHint }
            Write-Host ('[WARN] env-probe unreachable: ' + $name + ' (exit code nonzero or error)' + $(if ($hint) { '; hint: ' + $hint })) -ForegroundColor Yellow
        }
    }
}

# Investigation records keep flow L1 but carry a machine-readable kind, so the
# content checks can skip the change-oriented sections instead of forcing prose
# that nobody believes.
function Add-InvestigationFields {
    param([string]$Text)
    $notApplicable = -join @([char]0x4E0D, [char]0x9002, [char]0x7528)
    $t = $Text -replace '(?m)(?<![A-Za-z0-9_\-])flow:(\s*L1[^\r\n]*)', ('flow:$1' + "`r`n" + '- record_kind: investigation')
    $t = $t -replace '(?m)(?<![A-Za-z0-9_\-])delivery_status:[^\r\n]*', ('delivery_status: ' + $notApplicable)
    return $t
}

function Invoke-Start {
    param(
        [string]$RootPath,
        [string]$FeatureName,
        [string]$RequirementText,
        [string]$FlowValue,
        [string]$ModulesText,
        [bool]$FlowExplicit = $true,
        [bool]$ModulesExplicit = $true,
        [switch]$NoPlan,
        [switch]$NoPreflight,
        [switch]$Investigation
    )

    # ------------------------------------------------------------- 0 guards
    if ($FlowValue -eq 'L0') {
        Write-Host '[FAIL] -Flow L0 keeps no change record: skip harness-start for L0 work' -ForegroundColor Red
        return 1
    }
    if ($Investigation -and $FlowValue -ne 'L1') {
        if ($FlowExplicit) {
            Write-Host '[FAIL] -Investigation records use -Flow L1 (read only, no code change)' -ForegroundColor Red
            return 1
        }
        $FlowValue = 'L1'
    }
    if ($FlowValue -eq 'L1' -and -not $Investigation) {
        Write-Host '[WARN] -Flow L1 normally uses .harness/changes/_small.md, not summary.md; continuing because you asked for a full record' -ForegroundColor Yellow
    }
    if ($Investigation) {
        Write-Host '[INFO] investigation record: flow L1, no code change expected; acceptance / impact / tasks are not required' -ForegroundColor DarkGray
    }
    $featureError = Test-FeatureName -FeatureName $FeatureName -RootPath $RootPath
    if ($featureError) {
        Write-Host ('[FAIL] ' + $featureError + ': ' + $FeatureName) -ForegroundColor Red
        return 1
    }

    Write-Host ('harness-start: ' + $FeatureName) -ForegroundColor Cyan

    if (-not $NoPreflight) {
        Invoke-Preflight -RootPath $RootPath -RequirementText $RequirementText -FeatureName $FeatureName
    }
    # The env probe is independent of the pre-flight: a caller that skips the
    # read-only history scan still gets the environment health check.
    Invoke-EnvProbe -RootPath $RootPath
    Show-Lessons -RootPath $RootPath -RequirementText $RequirementText -FeatureName $FeatureName

    # ---------------------------------------------------------- 1 context pack
    # The plan also carries a flow hint and the module cards it matched. They are
    # read only when the caller did not pass -Flow / -Modules: an explicit
    # argument always wins, so a re-run cannot silently move the declaration.
    $hintFlow = ''
    $hintModules = @()
    $moduleCandidates = @()
    if (-not $NoPlan) {
        $planScript = Join-Path $RootPath 'scripts\harness-plan.ps1'
        if (Test-Path -LiteralPath $planScript) {
            if (-not $RequirementText -or $RequirementText.Trim() -eq '') {
                Write-Host '[INFO] plan skipped: pass -Requirement to print the context pack' -ForegroundColor DarkGray
            } else {
                Write-Host ''
                Write-Host '--- harness plan (read only) ---' -ForegroundColor Cyan
                # Captured, then printed unchanged: the same lines feed the hint
                # below, so the console and the pre-fill cannot disagree.
                $planLines = @(& $PS -NoProfile -ExecutionPolicy Bypass -File $planScript -Root $RootPath -Requirement $RequirementText -Feature $FeatureName 2>&1 | ForEach-Object { "$_" })
                $planExit = $LASTEXITCODE
                $planLines | Out-Host
                if ($planExit -ne 0) {
                    Write-Host '[WARN] harness-plan failed; continuing (the plan is an aid, not a gate)' -ForegroundColor Yellow
                }
                foreach ($line in $planLines) {
                    $fm = [regex]::Match($line, 'level hint\s*:\s*(L[0-3])')
                    if ($fm.Success) { $hintFlow = $fm.Groups[1].Value }
                    $mm = [regex]::Match($line, '^\s*-\s+(\S+)\s+\(score\s+(\d+)\)\s+\[\.harness/modules/')
                    if ($mm.Success) {
                        $candName = $mm.Groups[1].Value
                        $candScore = [int]$mm.Groups[2].Value
                        if (-not ($moduleCandidates -contains $candName)) { $moduleCandidates += $candName }
                        # Only a strong match is written: a score-1 card usually
                        # shares one common word and would send stage 3/5/7/8 to
                        # the wrong module.
                        if ($candScore -ge 2 -and -not ($hintModules -contains $candName)) {
                            $hintModules += $candName
                        }
                    }
                }
                $weakCandidates = @($moduleCandidates | Where-Object { $hintModules -notcontains $_ })
                if (@($hintModules).Count -eq 0 -and $weakCandidates.Count -gt 0) {
                    Write-Host ('[INFO] module candidates not written: ' + ($weakCandidates -join ', ') + '; confirm and pass -Modules if one is real') -ForegroundColor DarkGray
                } elseif ($weakCandidates.Count -gt 0) {
                    Write-Host ('[INFO] weaker module candidates: ' + ($weakCandidates -join ', ')) -ForegroundColor DarkGray
                }
                Write-Host '--- end of plan ---' -ForegroundColor Cyan
            }
        }
    }

    # --------------------------------------------------------- 2 change record
    $effectiveFlow = $FlowValue
    $flowSource = 'argument'
    if (-not $FlowExplicit -and $hintFlow) { $effectiveFlow = $hintFlow; $flowSource = 'plan hint' }
    if ($Investigation) { $effectiveFlow = 'L1'; $flowSource = 'investigation' }
    if (-not $Investigation -and $FlowExplicit -and $hintFlow -and $hintFlow -ne $FlowValue) {
        Write-Host ('[INFO] the plan suggests ' + $hintFlow + '; keeping explicit -Flow ' + $FlowValue) -ForegroundColor DarkGray
    }
    # One line that names the winning value and where it came from. Three places
    # record the level (marker, template, plan); without this, a plan-suggested
    # L3 could silently differ from an explicit L2 and nobody could tell which
    # one the gate will read.
    Write-Host ('[INFO] effective flow: ' + $effectiveFlow + ' (source: ' + $flowSource + ')') -ForegroundColor DarkGray
    $effectiveModules = $ModulesText
    $modulesSource = 'argument'
    if (-not $ModulesExplicit -and @($hintModules).Count -gt 0) {
        $effectiveModules = ($hintModules -join ',')
        $modulesSource = 'plan hint'
    }
    $modulesValue = Get-ModulesValue $effectiveModules
    if ($modulesValue -eq 'none' -and ((Test-HasModuleCards $RootPath) -or (Test-HasModuleColumn $RootPath))) {
        Write-Host '[WARN] touched_modules=none but this project declares modules; pass -Modules a,b or stage 3 may FAIL' -ForegroundColor Yellow
    }

    $changesRoot = Join-Path $RootPath '.harness\changes'
    $summaryPath = Join-Path (Join-Path $changesRoot $FeatureName) 'summary.md'
    if (-not (Test-Path -LiteralPath $summaryPath)) {
        $template = Join-Path $changesRoot '_template\summary.md'
        if (-not (Test-Path -LiteralPath $template)) {
            Write-Host ('[FAIL] summary template not found: ' + $template) -ForegroundColor Red
            return 1
        }
        $text = [System.IO.File]::ReadAllText($template, [System.Text.Encoding]::UTF8)
        $text = Set-SummaryPrefill -Text $text -FlowValue $effectiveFlow -ModulesValue $modulesValue
        if ($Investigation) { $text = Add-InvestigationFields -Text $text }
        $dir = Split-Path -Parent $summaryPath
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        [System.IO.File]::WriteAllText($summaryPath, $text, $Utf8NoBom)
        Write-Host ('[ADD] ' + $summaryPath) -ForegroundColor Green
        $sourceNote = ''
        if ($flowSource -eq 'plan hint' -or $modulesSource -eq 'plan hint') {
            $sourceNote = '  (from the plan hint; adjust before committing)'
        }
        Write-Host ('      pre-filled flow: ' + $effectiveFlow + ' / touched_modules: ' + $modulesValue + $sourceNote)
        if ($Investigation) {
            Write-Host '      fill loaded_skills and the conclusion; acceptance / impact / tasks are not required'
        } else {
            Write-Host '      fill loaded_skills / acceptance / impact / tasks, then re-run this command'
        }
    } else {
        Write-Host ('[KEEP] existing record not overwritten: ' + $summaryPath) -ForegroundColor DarkGray
    }

    # ------------------------------------------------------------- 3 stage 1
    $gate = Join-Path $RootPath 'scripts\stage-gate.ps1'
    if (-not (Test-Path -LiteralPath $gate)) {
        Write-Host ('[FAIL] stage gate not found: ' + $gate) -ForegroundColor Red
        return 1
    }
    Write-Host ''
    Write-Host '--- stage 1 (requirement analysis) ---' -ForegroundColor Cyan
    # Out-Host keeps the gate's output off this function's return value: the
    # caller receives only the exit code, not the child process text.
    & $PS -NoProfile -ExecutionPolicy Bypass -File $gate -Root $RootPath -Feature $FeatureName -Stage 1 | Out-Host
    if ($LASTEXITCODE -ne 0) {
        Write-Host ''
        Write-Host '[FAIL] stage 1 is not ready: fix the FAIL rows above, then re-run harness-start' -ForegroundColor Red
        Write-Host '       no .git/harness-task-started marker was written' -ForegroundColor Red
        return 1
    }

    # ------------------------------------------------------------- 4 marker
    $gitDir = Get-GitDir $RootPath
    if (-not $gitDir) {
        Write-Host '[WARN] not a git repository: .git/harness-task-started was not written (run git init to enforce the task-start gate)' -ForegroundColor Yellow
        return 0
    }
    # The record is the truth for the flow level: a re-run with the default -Flow
    # must not overwrite an L3 record's declaration in the marker.
    $flowForMarker = $FlowValue
    $smText = [System.IO.File]::ReadAllText($summaryPath, [System.Text.Encoding]::UTF8)
    $fm = [regex]::Match($smText, '(?m)(?<![A-Za-z0-9_\-])flow:\s*`?\s*(L[0-3])')
    if ($fm.Success) { $flowForMarker = $fm.Groups[1].Value }

    $marker = Join-Path $gitDir 'harness-task-started'
    $iso = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    # Each element is parenthesised on purpose: the comma operator binds tighter
    # than +, so an unparenthesised list would collapse into one space-joined
    # string and the marker would carry no line breaks.
    $lines = @(
        ('feature=' + $FeatureName),
        ('at=' + $iso),
        ('flow=' + $flowForMarker)
    )
    [System.IO.File]::WriteAllText($marker, (($lines -join "`n") + "`n"), $Utf8NoBom)

    Write-Host ''
    Write-Host ('[OK] task start recorded: ' + $marker) -ForegroundColor Green
    Write-Host ('     feature=' + $FeatureName + ' flow=' + $flowForMarker)
    Write-Host '     next: write the code; pre-commit checks this marker when a summary is committed'
    return 0
}

function Invoke-StartSelfTest {
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('hb-start-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $fails = New-Object System.Collections.Generic.List[string]

    function Assert-Case {
        param([string]$Name, [bool]$Ok)
        if ($Ok) { Write-Host ('ok: ' + $Name) }
        else { Write-Host ('[FAIL] ' + $Name) -ForegroundColor Red; $fails.Add($Name) }
    }

    # Fill the countable content of a created summary so stage 1 can pass.
    function Set-SummaryContent {
        param([string]$Path)
        if (-not (Test-Path -LiteralPath $Path)) { return }
        $t = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
        $t = $t -replace '(?m)(?<![A-Za-z0-9_\-])loaded_skills:[^\r\n]*', 'loaded_skills: request-analysis'
        $t = $t -replace '(?m)^\| F1 \|.*$', '| F1 | demo feature | returns 200 | no retries |'
        $t = $t -replace '(?m)^- \u6A21\u5757\uFF1A.*$', '- module: demo'
        $t = $t -replace '(?m)^\| 1 \|.*$', '| 1 | code | - | 1h |'
        [System.IO.File]::WriteAllText($Path, $t, $Utf8NoBom)
    }

    function New-Fixture {
        param([string]$Path, [switch]$WithGit, [switch]$WithTemplate)
        New-Item -ItemType Directory -Force -Path (Join-Path $Path 'scripts') | Out-Null
        Copy-Item -Path (Join-Path $PSScriptRoot '*') -Destination (Join-Path $Path 'scripts') -Recurse -Force
        if ($WithTemplate) {
            $tplDir = Join-Path $Path '.harness\changes\_template'
            New-Item -ItemType Directory -Force -Path $tplDir | Out-Null
            Copy-Item -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) '.harness\changes\_template\summary.md') -Destination (Join-Path $tplDir 'summary.md')
        }
        if ($WithGit) {
            & git -C $Path init -q
            if ($LASTEXITCODE -ne 0) { throw 'git init failed in the fixture' }
        }
    }

    try {
        $sp = Join-Path $tmp '.harness\changes\demo\summary.md'
        $marker = Join-Path $tmp '.git\harness-task-started'
        New-Fixture -Path $tmp -WithGit -WithTemplate

        # --- a fresh start creates the record but fails stage 1 (placeholder text)
        $code = Invoke-Start -RootPath $tmp -FeatureName 'demo' -FlowValue 'L2' -ModulesText 'a,b' -NoPlan
        Assert-Case 'fresh start exits 1 while the content is a placeholder' ($code -eq 1)
        Assert-Case 'summary.md is created' (Test-Path -LiteralPath $sp)
        $text = ''
        if (Test-Path -LiteralPath $sp) { $text = [System.IO.File]::ReadAllText($sp, [System.Text.Encoding]::UTF8) }
        Assert-Case 'flow is pre-filled from -Flow' ($text -match '(?m)(?<![A-Za-z0-9_\-])flow: L2')
        Assert-Case 'touched_modules is pre-filled from -Modules' ($text -match '(?m)(?<![A-Za-z0-9_\-])touched_modules: a, b')
        Assert-Case 'no marker after a failed stage 1' (-not (Test-Path -LiteralPath $marker))

        # --- L1 warns that the small-record file is the normal home
        $linesL1 = @(Invoke-Start -RootPath $tmp -FeatureName 'demo-l1' -FlowValue 'L1' -NoPlan 6>&1)
        $codeL1 = [int]($linesL1[-1])
        $logL1 = ($linesL1 | ForEach-Object { "$_" }) -join "`n"
        Assert-Case 'L1 warns about _small.md' ($codeL1 -eq 1 -and $logL1 -match '_small\.md')

        # --- a module card makes an empty -Modules a named risk
        New-Item -ItemType Directory -Force -Path (Join-Path $tmp '.harness\modules') | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $tmp '.harness\modules\core.md'), "# core`n", $Utf8NoBom)
        $linesB = @(Invoke-Start -RootPath $tmp -FeatureName 'demo-defaults' -FlowValue 'L2' -NoPlan 6>&1)
        $codeB = [int]($linesB[-1])
        $logB = ($linesB | ForEach-Object { "$_" }) -join "`n"
        $sp2 = Join-Path $tmp '.harness\changes\demo-defaults\summary.md'
        $text2 = ''
        if (Test-Path -LiteralPath $sp2) { $text2 = [System.IO.File]::ReadAllText($sp2, [System.Text.Encoding]::UTF8) }
        Assert-Case 'default touched_modules is none' ($codeB -eq 1 -and $text2 -match '(?m)(?<![A-Za-z0-9_\-])touched_modules: none')
        Assert-Case 'a multi-module project warns when -Modules is empty' ($logB -match 'touched_modules=none' -and $logB -match 'stage 3')

        # --- the plan's own hint pre-fills flow / touched_modules when the caller
        # does not pass them. This guards the contradiction where the plan prints
        # L3 while the template is pre-filled L2 / none.
        $tmp4 = Join-Path ([System.IO.Path]::GetTempPath()) ('hb-start-hint-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Fixture -Path $tmp4 -WithTemplate
        $stubPlan = @(
            "Write-Host 'harness plan (stub)'",
            "Write-Host '  level hint  : L3 -- stub hint'",
            "Write-Host '  - core  (score 2)  [.harness/modules/core.md]'",
            "Write-Host '  - weak  (score 1)  [.harness/modules/weak.md]'",
            'exit 0'
        ) -join "`r`n"
        [System.IO.File]::WriteAllText((Join-Path $tmp4 'scripts\harness-plan.ps1'), ($stubPlan + "`r`n"), $Utf8NoBom)
        $linesP = @(Invoke-Start -RootPath $tmp4 -FeatureName 'hinted' -RequirementText 'demo request' -FlowValue 'L2' -ModulesText '' -FlowExplicit $false -ModulesExplicit $false 6>&1)
        $codeP = [int]($linesP[-1])
        $logP = ($linesP | ForEach-Object { "$_" }) -join "`n"
        $spP = Join-Path $tmp4 '.harness\changes\hinted\summary.md'
        $textP = ''
        if (Test-Path -LiteralPath $spP) { $textP = [System.IO.File]::ReadAllText($spP, [System.Text.Encoding]::UTF8) }
        Assert-Case 'plan hint fills flow when -Flow is not passed' ($textP -match '(?m)(?<![A-Za-z0-9_\-])flow: L3')
        Assert-Case 'plan hint fills touched_modules when -Modules is not passed' ($textP -match '(?m)(?<![A-Za-z0-9_\-])touched_modules: core')
        Assert-Case 'pre-fill names the plan as its source' ($logP -match 'plan hint')
        Assert-Case 'weak module candidates are not pre-filled' (($textP -match '(?m)(?<![A-Za-z0-9_\-])touched_modules: core') -and ($textP -notmatch 'touched_modules:[^\r\n]*weak'))
        Assert-Case 'weak module candidates are listed for confirmation' (($logP -match 'weaker module candidates|module candidates not written') -and ($logP -match 'weak'))
        Assert-Case 'a plan-hinted start still blocks on placeholder content' ($codeP -eq 1)

        # --- an explicit argument wins over the hint (and says so)
        $linesE = @(Invoke-Start -RootPath $tmp4 -FeatureName 'explicit' -RequirementText 'demo request' -FlowValue 'L2' -ModulesText 'manual' 6>&1)
        $logE = ($linesE | ForEach-Object { "$_" }) -join "`n"
        $spE = Join-Path $tmp4 '.harness\changes\explicit\summary.md'
        $textE = ''
        if (Test-Path -LiteralPath $spE) { $textE = [System.IO.File]::ReadAllText($spE, [System.Text.Encoding]::UTF8) }
        Assert-Case 'explicit -Flow wins over the plan hint' ($textE -match '(?m)(?<![A-Za-z0-9_\-])flow: L2')
        Assert-Case 'explicit -Modules wins over the plan hint' ($textE -match '(?m)(?<![A-Za-z0-9_\-])touched_modules: manual')
        Assert-Case 'a conflicting explicit flow is reported' ($logE -match 'keeping explicit -Flow L2')

        # --- pre-flight, lesson echo and the investigation record
        $tmp5 = Join-Path ([System.IO.Path]::GetTempPath()) ('hb-start-pre-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Fixture -Path $tmp5 -WithGit -WithTemplate
        & git -C $tmp5 config user.email 't@t.t'
        & git -C $tmp5 config user.name 't'
        [System.IO.File]::WriteAllText((Join-Path $tmp5 'widget.txt'), 'x', $Utf8NoBom)
        [System.IO.File]::WriteAllText((Join-Path $tmp5 '.harness\lessons.md'), (@(
            '# Lessons index (generated by metrics.ps1)',
            '',
            '| id | summary | tasks | first | last | status |',
            '| --- | --- | --- | --- | --- | --- |',
            '| widget-export-lesson | widget export missed a case | 2 | 2026-01-01 | 2026-01-02 | promote |'
        ) -join "`r`n"), $Utf8NoBom)
        # Keep git's CRLF warnings off stderr: a caller with
        # $ErrorActionPreference='Stop' turns any stderr byte into a terminating
        # NativeCommandError (the same trap the CI workflow documents).
        $savedEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        & git -C $tmp5 add . 2>$null
        & git -C $tmp5 commit -q -m 'widget-export already implemented' 2>$null
        $ErrorActionPreference = $savedEap
        $linesX = @(Invoke-Start -RootPath $tmp5 -FeatureName 'probe' -RequirementText 'widget export drops rows' -FlowValue 'L1' -ModulesText 'none' -Investigation $true 6>&1)
        $codeX = [int]($linesX[-1])
        $logX = ($linesX | ForEach-Object { "$_" }) -join "`n"
        $spX = Join-Path $tmp5 '.harness\changes\probe\summary.md'
        $textX = ''
        if (Test-Path -LiteralPath $spX) { $textX = [System.IO.File]::ReadAllText($spX, [System.Text.Encoding]::UTF8) }
        Assert-Case 'pre-flight sees the requirement in history' ($logX -match 'possible duplicate work' -and $logX -match 'widget-export')
        Assert-Case 'pre-flight labels path evidence' ($logX -match '\[path-match\].*widget-export')
        Assert-Case 'pre-flight reports a clean tree' ($logX -match 'working tree clean')
        Assert-Case 'lessons index is echoed at start' ($logX -match 'widget-export-lesson' -and $logX -match 'respond in the summary')
        Assert-Case 'investigation pre-fills flow L1' ($textX -match '(?m)(?<![A-Za-z0-9_\-])flow: L1')
        Assert-Case 'investigation pre-fills record_kind' ($textX -match '(?m)(?<![A-Za-z0-9_\-])record_kind: investigation')
        $cnNotApplicable = -join @([char]0x4E0D, [char]0x9002, [char]0x7528)
        Assert-Case 'investigation pre-fills delivery_status' ($textX.Contains('delivery_status: ' + $cnNotApplicable))
        $textX2 = $textX -replace '(?m)(?<![A-Za-z0-9_\-])loaded_skills:[^\r\n]*', 'loaded_skills: request-analysis'
        [System.IO.File]::WriteAllText($spX, $textX2, $Utf8NoBom)
        $codeX2 = Invoke-Start -RootPath $tmp5 -FeatureName 'probe' -RequirementText 'widget export drops rows' -FlowValue 'L1' -ModulesText 'none' -Investigation $true -NoPreflight
        Assert-Case 'investigation record passes stage 1 without the change sections' ($codeX2 -eq 0)

        # --- env probe: a configured unreachable tool warns at task start, an
        # empty entries list stays silent. The record at this point has an empty
        # loaded_skills (filled only later), so pre-fill it for stage 1 to pass.
        $cfgPath5 = Join-Path $tmp5 'scripts\harness-required.json'
        $cfgText5 = [System.IO.File]::ReadAllText($cfgPath5, [System.Text.Encoding]::UTF8)
        $cfgText5 = $cfgText5 -replace '"entries": \[\]', '"entries": [{"name":"db","command":"powershell -NoProfile -Command exit 3"}]'
        # Replace the trailing empty hint too: ConvertFrom-Json keeps the LAST
        # occurrence of a duplicated key, so a hint before "entries" would lose.
        $cfgText5 = $cfgText5 -replace '"unreachableHint": ""', ('"unreachableHint": "reconnect ' + 'mcp' + '"')
        [System.IO.File]::WriteAllText($cfgPath5, $cfgText5, (New-Object System.Text.UTF8Encoding($false)))
        $textX3 = $textX2 -replace '(?m)^flow: L1$', 'flow: L2'
        [System.IO.File]::WriteAllText($spX, $textX3, $Utf8NoBom)
        $linesPr = @(Invoke-Start -RootPath $tmp5 -FeatureName 'probe' -RequirementText 'widget export drops rows' -FlowValue 'L2' -ModulesText 'none' -NoPlan -NoPreflight 6>&1)
        $logProbe = ($linesPr | ForEach-Object { "$_" }) -join "`n"
        Assert-Case 'env probe warns on unreachable tool' ($logProbe -match '\[WARN\] env-probe unreachable: db')
        Assert-Case 'env probe prints the configured hint' ($logProbe -match 'reconnect mcp')
        $cfgText5b = $cfgText5 -replace '"entries": \[\{"name":"db"[^\r\n]*\]', '"entries": []'
        [System.IO.File]::WriteAllText($cfgPath5, $cfgText5b, (New-Object System.Text.UTF8Encoding($false)))
        $linesPr2 = @(Invoke-Start -RootPath $tmp5 -FeatureName 'probe' -RequirementText 'widget export drops rows' -FlowValue 'L2' -ModulesText 'none' -NoPlan -NoPreflight 6>&1)
        $logProbe2 = ($linesPr2 | ForEach-Object { "$_" }) -join "`n"
        Assert-Case 'env probe stays silent without entries' ($logProbe2 -notmatch 'env-probe')

        # --- effective flow is named with its source
        Assert-Case 'effective flow line is printed' ($logProbe2 -match '\[INFO\] effective flow: L2 \(source: argument\)')

        # --- fill the countable content and pass stage 1
        Set-SummaryContent -Path $sp
        $code = Invoke-Start -RootPath $tmp -FeatureName 'demo' -FlowValue 'L2' -ModulesText 'a,b' -NoPlan
        Assert-Case 'a filled record passes stage 1 and exits 0' ($code -eq 0)
        Assert-Case 'marker is written after stage 1 passes' (Test-Path -LiteralPath $marker)
        $mText = ''
        if (Test-Path -LiteralPath $marker) { $mText = [System.IO.File]::ReadAllText($marker, [System.Text.Encoding]::UTF8) }
        Assert-Case 'marker records the feature' ($mText -match '(?m)^feature=demo$')
        Assert-Case 'marker records the flow' ($mText -match '(?m)^flow=L2$')
        Assert-Case 'marker records a timestamp' ($mText -match '(?m)^at=\d{4}-\d{2}-\d{2}T')

        # --- an existing record is never overwritten; the marker follows the record
        [System.IO.File]::AppendAllText($sp, "- keep-me`n", $Utf8NoBom)
        $before = [System.IO.File]::ReadAllText($sp, [System.Text.Encoding]::UTF8)
        $code = Invoke-Start -RootPath $tmp -FeatureName 'demo' -FlowValue 'L3' -NoPlan
        $after = [System.IO.File]::ReadAllText($sp, [System.Text.Encoding]::UTF8)
        Assert-Case 'existing record is not overwritten' ($code -eq 0 -and $before -eq $after)
        # A stage-1 failure leaves no marker. Read it defensively so the self test
        # reports that failure instead of throwing FileNotFoundException.
        $mText = ''
        if (Test-Path -LiteralPath $marker) {
            $mText = [System.IO.File]::ReadAllText($marker, [System.Text.Encoding]::UTF8)
        }
        Assert-Case 'marker flow follows the record, not -Flow' ($mText -match '(?m)^flow=L2$')

        # --- L0 and path traversal are refused before anything is written
        $code = Invoke-Start -RootPath $tmp -FeatureName 'demo-l0' -FlowValue 'L0' -NoPlan
        Assert-Case 'L0 is refused' ($code -eq 1 -and -not (Test-Path -LiteralPath (Join-Path $tmp '.harness\changes\demo-l0')))
        $code = Invoke-Start -RootPath $tmp -FeatureName '..\..\evil' -FlowValue 'L2' -NoPlan
        Assert-Case 'path traversal is refused' ($code -eq 1)
        $code = Invoke-Start -RootPath $tmp -FeatureName 'a/b' -FlowValue 'L2' -NoPlan
        Assert-Case 'a path separator is refused' ($code -eq 1)

        # --- a missing template is a hard failure
        $tmp2 = Join-Path ([System.IO.Path]::GetTempPath()) ('hb-start-notpl-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Fixture -Path $tmp2 -WithGit
        $linesG = @(Invoke-Start -RootPath $tmp2 -FeatureName 'demo' -FlowValue 'L2' -NoPlan 6>&1)
        $codeG = [int]($linesG[-1])
        $logG = ($linesG | ForEach-Object { "$_" }) -join "`n"
        Assert-Case 'missing template fails' ($codeG -eq 1 -and $logG -match 'template not found')

        # --- not a repository: stage 1 runs, no marker is written (WARN only)
        $tmp3 = Join-Path ([System.IO.Path]::GetTempPath()) ('hb-start-nogit-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Fixture -Path $tmp3 -WithTemplate
        $sp3 = Join-Path $tmp3 '.harness\changes\demo\summary.md'
        $null = Invoke-Start -RootPath $tmp3 -FeatureName 'demo' -FlowValue 'L2' -ModulesText 'a' -NoPlan
        Set-SummaryContent -Path $sp3
        $linesH = @(Invoke-Start -RootPath $tmp3 -FeatureName 'demo' -FlowValue 'L2' -ModulesText 'a' -NoPlan 6>&1)
        $codeH = [int]($linesH[-1])
        $logH = ($linesH | ForEach-Object { "$_" }) -join "`n"
        Assert-Case 'a non-git start exits 0 with a warning' ($codeH -eq 0 -and $logH -match 'not a git repository')
        Assert-Case 'a non-git start writes no marker' (-not (Test-Path -LiteralPath (Join-Path $tmp3 '.git\harness-task-started')))
    } finally {
        foreach ($d in @($tmp, $tmp2, $tmp3, $tmp4, $tmp5)) {
            if ($d -and (Test-Path -LiteralPath $d)) { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    if ($fails.Count -gt 0) {
        Write-Host ('START SELFTEST FAILED: ' + $fails.Count + ' case(s)') -ForegroundColor Red
        return 1
    }
    Write-Host 'START SELFTEST OK' -ForegroundColor Green
    return 0
}

if ($SelfTest) {
    exit (Invoke-StartSelfTest)
}

if (-not $Feature -or $Feature.Trim() -eq '') {
    Write-Host 'usage: harness-start.ps1 -Feature <name> [-Requirement "<raw request>"] [-Flow L0|L1|L2|L3] [-Modules a,b] [-Root <dir>] [-SkipPlan] [-SkipPreflight] [-Investigation]' -ForegroundColor Red
    exit 1
}

$rootPath = $Root
try { $rootPath = (Resolve-Path -LiteralPath $Root).Path }
catch {
    Write-Host ('[FAIL] root not found: ' + $Root) -ForegroundColor Red
    exit 1
}

$flowExplicit = $PSBoundParameters.ContainsKey('Flow')
$modulesExplicit = $PSBoundParameters.ContainsKey('Modules')

exit (Invoke-Start -RootPath $rootPath -FeatureName $Feature -RequirementText $Requirement -FlowValue $Flow -ModulesText $Modules -FlowExplicit $flowExplicit -ModulesExplicit $modulesExplicit -NoPlan:$SkipPlan -NoPreflight:$SkipPreflight -Investigation:$Investigation)
