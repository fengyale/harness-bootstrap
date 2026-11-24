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
    [switch]$ListStages,
    [switch]$NoExit
)

function Complete-Harness {
    param([int]$Code)
    if ($NoExit) { throw ('__HARNESS_EXIT__' + $Code) }
    exit $Code
}

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

# Module-aware run-command config. A rules file from an older install may not
# carry moduleCommands; without a fallback the module column silently stopped
# being recognised. The built-in names are ASCII except the Chinese header
# words, which are assembled from code points (this file must stay parseable
# without a BOM on PS 5.1).
$script:moduleConfigFallback = $false

function New-DefaultModuleMessages {
    return [pscustomobject]@{
        missingModuleRow    = 'no compile/test command for module {0}; add a row or *; check the name against .harness/modules/ cards'
        singleCommandWarn   = 'single command; add a module column to cover: {0}'
        emptyTouchedModules = 'table has a module column but touched_modules is empty/none; list the touched modules in summary.md (or add a * row)'
    }
}

function Get-ModuleCommandConfig {
    $defaults = [pscustomobject]@{
        moduleHeader  = @(([string][char]0x6A21 + [char]0x5757), 'module')
        commandHeader = @(([string][char]0x547D + [char]0x4EE4), 'command')
        purposeHeader = @(([string][char]0x7528 + [char]0x9014), 'purpose')
        allModules    = @('*', 'all', ([string][char]0x5168 + [char]0x90E8))
        noneMarkers   = @('none', '-', ([string][char]0x65E0), ([string][char]0x4E0D + [char]0x9002 + [char]0x7528))
        messages      = (New-DefaultModuleMessages)
    }
    $mc = $RULES.moduleCommands
    if (-not $mc) {
        $script:moduleConfigFallback = $true
        return $defaults
    }
    $cfg = [pscustomobject]@{
        moduleHeader  = $defaults.moduleHeader
        commandHeader = $defaults.commandHeader
        purposeHeader = $defaults.purposeHeader
        allModules    = $defaults.allModules
        noneMarkers   = $defaults.noneMarkers
        messages      = $defaults.messages
    }
    if ($mc.moduleHeader)  { $cfg.moduleHeader  = @($mc.moduleHeader) }
    if ($mc.commandHeader) { $cfg.commandHeader = @($mc.commandHeader) }
    if ($mc.purposeHeader) { $cfg.purposeHeader = @($mc.purposeHeader) }
    if ($mc.allModules)    { $cfg.allModules    = @($mc.allModules) }
    if ($mc.noneMarkers)   { $cfg.noneMarkers   = @($mc.noneMarkers) }
    if ($mc.messages) {
        $msg = $defaults.messages
        foreach ($p in $mc.messages.PSObject.Properties) {
            if (-not $p.Value) { continue }
            # A future rules key must not crash the gate under
            # $ErrorActionPreference='Stop'; add it when unknown.
            if ($msg.PSObject.Properties.Name -contains $p.Name) {
                $msg.($p.Name) = [string]$p.Value
            } else {
                $msg | Add-Member -NotePropertyName $p.Name -NotePropertyValue ([string]$p.Value) -Force
            }
        }
        $cfg.messages = $msg
    }
    return $cfg
}

$MC = Get-ModuleCommandConfig

function Get-McMessage {
    param([string]$Name, [string]$Default)
    $v = [string]$MC.messages.$Name
    if ($v) { return $v }
    return $Default
}

function New-Stage {
    param([string]$Key, [string]$Name, [array]$Criteria)
    return [pscustomobject]@{ Key = $Key; Name = $Name; Criteria = $Criteria }
}

$stageDefs = @(
    New-Stage '1' 'requirement analysis' @(
        @{ Id='summary-exists';       Kind='AUTO';  Text='summary.md exists under .harness/changes/<feature>/' },
        @{ Id='summary-sections';     Kind='AUTO';  Text='summary.md has what / why sections' },
        @{ Id='summary-fields-initial'; Kind='AUTO'; Text='summary.md records flow / loaded_skills / touched_modules and real acceptance, impact and task content' },
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
        @{ Id='review-ledger';   Kind='AUTO';  Text='summary.md review table is well-formed (P0/P1 have fingerprints and evidence)' },
        @{ Id='shortfall-listed'; Kind='AUTO'; Text='summary.md names the harness capability added (business-code work writes a none marker)' },
        @{ Id='review-report';   Kind='HUMAN'; Text='no open P0 issue' },
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
        @{ Id='lessons-asserted'; Kind='AUTO';  Text='every repeated lesson is promoted into a check' },
        @{ Id='corrections-attributed'; Kind='AUTO'; Text='corrections carry a lesson_id so they can be promoted' },
        @{ Id='summary-fields-final'; Kind='AUTO'; Text='summary.md fields are complete and valid' },
        @{ Id='checks-really-fail'; Kind='HUMAN'; Text='opened every promoted lesson check and confirmed it fails when that lesson is reintroduced' },
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

# Split one markdown table line into raw cells. An escaped pipe (\|) belongs to
# the command, not to the table: Split('|') silently truncated it and ran a
# different command.
function Split-TableLine {
    param([string]$Line)
    $raw = @([regex]::Split($Line.Trim().Trim('|'), '(?<!\\)\|'))
    $out = @()
    foreach ($c in $raw) { $out += ($c.Trim() -replace '\\\|', '|') }
    return ,$out
}

function Test-SeparatorCells {
    param([string[]]$Cells)
    if ($Cells.Count -eq 0) { return $false }
    foreach ($c in $Cells) { if (($c.Trim()) -notmatch '^:?-{2,}:?$') { return $false } }
    return $true
}

# Finds a header cell by its exact text first, then by a unique substring.
# Searching for a substring alone used to pick a data-like header cell (one that
# merely contains the word) over the real command column. When several cells
# match a substring the header is ambiguous, so -1 is returned instead of
# guessing.
function Find-HeaderIndex {
    param([string[]]$Cells, [string[]]$Needles)
    if (-not $Cells -or -not $Needles) { return -1 }
    for ($c = 0; $c -lt $Cells.Count; $c++) {
        $cell = ([string]$Cells[$c]).Trim()
        foreach ($n in $Needles) {
            if ($n -and ($cell -ieq ([string]$n).Trim())) { return $c }
        }
    }
    $hits = @()
    for ($c = 0; $c -lt $Cells.Count; $c++) {
        $cell = ([string]$Cells[$c]).Trim()
        $hit = $false
        foreach ($n in $Needles) {
            if (-not $n) { continue }
            if ($cell.IndexOf(([string]$n), [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { $hit = $true; break }
        }
        if ($hit) { $hits += $c }
    }
    if ($hits.Count -eq 1) { return $hits[0] }
    return -1
}

# Purpose cells are short labels, not commands: a compile label is compile,
# while a test label with a parenthetical note mentioning compile is still only
# a test row, because the segment after dropping the parenthetical must equal a
# keyword. Whole-segment equality stops a keyword that merely appears inside a
# free-text cell from selecting that row.
function Test-PurposeMatch {
    param([string]$Purpose, [string[]]$Keywords)
    if (-not $Purpose) { return $false }
    $segments = @($Purpose -split '[/\uFF0F]')
    foreach ($s in $segments) {
        $t = $s.Trim()
        $t = ($t -replace '\s*[\uFF08(][^\uFF09)]*[\uFF09)]\s*$', '').Trim()
        if (-not $t) { continue }
        foreach ($k in $Keywords) {
            if ($k -and ($t -ieq ([string]$k).Trim())) { return $true }
        }
    }
    return $false
}

# Same marker semantics as Test-RunCommand, exposed so row selection can tell a
# placeholder from a real command before deciding whether to fall back to *.
function Test-PlaceholderCommand {
    param([object]$RawCell, [string[]]$SkipMarkers, [string[]]$SkipExact)
    if ($null -eq $RawCell) { return $true }
    $cmd = ([string]$RawCell).Trim().Trim('`').Trim()
    if ($cmd -eq '') { return $true }
    if ($cmd -match '<') { return $true }
    foreach ($e in @($SkipExact)) { if ($e -and ($cmd -eq [string]$e)) { return $true } }
    foreach ($m in @($SkipMarkers)) { if ($m -and ($cmd -match [regex]::Escape([string]$m))) { return $true } }
    return $false
}

# Parses the run-commands table. Two header shapes are accepted:
#   | purpose | command |
#   | purpose | module | command |
# The command / module / purpose columns are identified by their header text
# (keywords live in stage-gate-rules.json). A table without a header falls back
# to the second column for the command, which matches the old template wording.
# Parsing stops at a blank line so a second table in the same section cannot be
# merged into this one.
function Get-AgentsCommandTable {
    param([string]$ProjectRoot, [string[]]$SectionNames)
    $agents = Join-Path $ProjectRoot 'AGENTS.md'
    if (-not (Test-Path -LiteralPath $agents)) { return $null }
    $lines = [System.IO.File]::ReadAllLines($agents, [System.Text.Encoding]::UTF8)

    # Only rows inside the run-commands section count. Scanning every table used
    # to execute a cell from the red-line table whenever that row happened to
    # contain a keyword such as "compile".
    $start = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        # The template labels this section in bold rather than as a heading, so
        # both forms count as a section marker.
        $isSectionLine = ($lines[$i] -match '^#{2,6}[ \t]*') -or ($lines[$i] -match '^\*\*')
        if ($isSectionLine -and (Test-HasAny -Text $lines[$i] -Needles $SectionNames)) {
            $start = $i
            break
        }
    }
    if ($start -lt 0) { return $null }

    $tableIdx = @()
    for ($i = $start + 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^#{2,6}[ \t]*') { break }
        if ($lines[$i].Trim() -eq '') {
            if ($tableIdx.Count -gt 0) { break }
            continue
        }
        if ($lines[$i] -match '^\|') { $tableIdx += $i } else { if ($tableIdx.Count -gt 0) { break } }
    }
    if ($tableIdx.Count -eq 0) { return $null }

    $cfg = $MC
    $headerCells = $null
    $cmdIdx = -1
    $modIdx = -1
    $purposeIdx = 0
    $hasHeader = $false
    $dataFrom = $tableIdx[0]

    # A header exists only when the second table line is a separator row.
    if ($tableIdx.Count -ge 2) {
        $second = Split-TableLine $lines[$tableIdx[1]]
        if (Test-SeparatorCells -Cells $second) { $hasHeader = $true; $dataFrom = $tableIdx[1] + 1 }
    }

    $ambiguous = $false
    $purposeMissing = $false
    if ($hasHeader) {
        $headerCells = Split-TableLine $lines[$tableIdx[0]]
        $cmdIdx = Find-HeaderIndex -Cells $headerCells -Needles $cfg.commandHeader
        $modIdx = Find-HeaderIndex -Cells $headerCells -Needles $cfg.moduleHeader
        $pi = Find-HeaderIndex -Cells $headerCells -Needles $cfg.purposeHeader
        if ($pi -ge 0) { $purposeIdx = $pi } else { $purposeMissing = $true }
        if ($cmdIdx -ge 0 -and $modIdx -ge 0 -and $cmdIdx -eq $modIdx) {
            # One cell cannot be both the module and the command; keep the
            # command and stop pretending the table has a module column.
            $modIdx = -1
            $ambiguous = $true
        }
    }

    $rows = New-Object System.Collections.Generic.List[object]
    $started = $false
    for ($i = $dataFrom; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^#{2,6}[ \t]*') { break }
        if ($lines[$i].Trim() -eq '') { if ($started) { break } else { continue } }
        if ($lines[$i] -notmatch '^\|') { if ($started) { break } else { continue } }
        $started = $true
        $cells = Split-TableLine $lines[$i]
        if (Test-SeparatorCells -Cells $cells) { continue }
        $ci = $cmdIdx
        if ($ci -lt 0) { $ci = if ($cells.Count -ge 2) { 1 } else { $cells.Count - 1 } }
        if ($ci -ge $cells.Count) { $ci = $cells.Count - 1 }
        $cmd = $cells[$ci]
        $mod = ''
        if ($hasHeader -and $modIdx -ge 0 -and $modIdx -ne $ci -and $modIdx -lt $cells.Count) {
            $mod = ([string]$cells[$modIdx]).Trim().Trim('`').Trim()
        }
        $purpose = ''
        if ($purposeIdx -ge 0 -and $purposeIdx -lt $cells.Count) { $purpose = $cells[$purposeIdx] }
        $rows.Add([pscustomobject]@{ Line = $lines[$i]; Cells = $cells; Module = $mod; Command = $cmd; Purpose = $purpose })
    }

    $hasModule = ($hasHeader -and $modIdx -ge 0)
    return [pscustomobject]@{
        HasHeader       = $hasHeader
        HasModuleColumn = $hasModule
        HeaderAmbiguous = $ambiguous
        PurposeMissing  = $purposeMissing
        CommandIndex    = $cmdIdx
        ModuleIndex     = $modIdx
        PurposeIndex    = $purposeIdx
        HeaderCells     = $headerCells
        Rows            = $rows
    }
}

function Test-IsAllModule {
    param([string]$Module)
    if (-not $Module) { return $false }
    $v = $Module.Trim()
    foreach ($a in $MC.allModules) { if ($v -eq [string]$a) { return $true } }
    return $false
}

# Reads touched_modules from summary.md. Only a field line counts: after an
# optional list bullet the line must start with the field itself (English name
# or the configured Chinese label), so a prose sentence that merely mentions
# the word is not treated as the declaration. Accepted shapes: the bare field,
# the Chinese label, the backticked field, and the template's labelled bullet
# that repeats the English field after the Chinese label.
# Every token drops a trailing parenthetical note and a trailing dot, so an
# annotated or punctuated module name still resolves to the module. A none
# marker means "no module"; names keep their case and dashes.
function Get-TouchedModules {
    param([string]$FeatureName)
    $text = Get-SummaryText -FeatureName $FeatureName
    if (-not $text) { return @() }
    $rx = '(?m)^[ \t]*(?:[-*][ \t]+)?(?:\u89E6\u53CA\u6A21\u5757[ \t]*[:\uFF1A][ \t]*`?touched_modules`?[ \t]*[:\uFF1A]|`?touched_modules`?[ \t]*[:\uFF1A]|\u89E6\u53CA\u6A21\u5757[ \t]*[:\uFF1A])[ \t]*([^\r\n]*)'
    $m = [regex]::Match($text, $rx)
    if (-not $m.Success) { return @() }
    $tokens = @($m.Groups[1].Value -split '[,\uFF0C\u3001\s]+' | ForEach-Object { $_.Trim().Trim('`').Trim() } | Where-Object { $_ })
    $out = @()
    foreach ($t in $tokens) {
        $name = ($t -replace '\s*[\uFF08(][^\uFF09)]*[\uFF09)]\s*$', '').Trim()
        $name = $name -replace '\.$', ''
        $name = $name.Trim()
        if (-not $name) { continue }
        $isNone = $false
        foreach ($n in $MC.noneMarkers) { if ($name -eq [string]$n) { $isNone = $true; break } }
        if (-not $isNone) { $out += $name }
    }
    return $out
}

# Copies a cached command result before decorating its detail: Test-RunCommand
# hands back the same hashtable for a repeated command, and a hint appended in
# place would leak into the next criterion that reuses that command.
function Copy-RunResult {
    param($Result)
    return @{ Ok = $Result.Ok; Ran = $Result.Ran; Found = $Result.Found; Detail = [string]$Result.Detail }
}

# Adds the configuration / header hints to a detail string. A gate that quietly
# fell back to built-in header names looks identical to a correctly configured
# one; naming it is what makes the drift visible.
function Add-TableHints {
    param($Result, $Table)
    $extra = @()
    if ($script:moduleConfigFallback) { $extra += '[HINT] moduleCommands config missing; built-in header names used' }
    if ($Table -and $Table.HeaderAmbiguous) {
        $extra += '[HINT] header ambiguity: module and command columns resolved to the same cell; the module column is ignored'
    }
    if ($Table -and $Table.PurposeMissing) {
        $col = [int]$Table.PurposeIndex + 1
        $extra += ('[HINT] purpose column not found; used column ' + $col)
    }
    if ($extra.Count -gt 0) {
        $d = [string]$Result.Detail
        if ($d) { $Result.Detail = $d + ' ; ' + ($extra -join ' ; ') } else { $Result.Detail = ($extra -join ' ; ') }
    }
    return $Result
}

# Runs the compile / test command set for the touched modules.
#   no matching row                 -> FAIL (missing row)
#   table has a module column       -> per-module row or *; a module without one -> FAIL
#   module column, no touched items -> * rows only; without one the declaration is
#                                      empty, which is a gap, not a default module
#   table without a module column   -> first row (old behaviour), plus a WARN in
#                                      the detail when modules are touched (still Ok)
# A selected placeholder / not-applicable row makes the whole set a SKIP: one
# module left unmeasured must never be summarised as PASS. Commands are cached
# so -All does not run the same command twice, and rows sharing a command are
# deduplicated with every benefiting module named in the label.
function Test-RunCommandSet {
    param([string]$ProjectRoot, [string]$FeatureName, [string[]]$Keywords, [string[]]$SkipMarkers, [string[]]$SkipExact)
    $table = Get-AgentsCommandTable -ProjectRoot $ProjectRoot -SectionNames $RULES.agentsCommandSection
    $matched = @()
    if ($table) { $matched = @($table.Rows | Where-Object { Test-PurposeMatch -Purpose $_.Purpose -Keywords $Keywords }) }
    if ($matched.Count -eq 0) {
        $noRow = @{ Ok=$false; Ran=$false; Found=$false; Detail='AGENTS.md run-commands table has no such row (add a measured command, or mark it not-applicable)' }
        return (Add-TableHints -Result $noRow -Table $table)
    }
    $touched = @(Get-TouchedModules -FeatureName $FeatureName)

    if (-not $table.HasModuleColumn) {
        $r = Copy-RunResult (Test-RunCommand -RawCell $matched[0].Command -SkipMarkers $SkipMarkers -SkipExact $SkipExact)
        if ($touched.Count -gt 0) {
            $warn = [string]::Format([string](Get-McMessage 'singleCommandWarn' 'single command; add a module column to cover: {0}'), ($touched -join ', '))
            $r.Detail = ((('' + $r.Detail) + ' ; ' + $warn))
        }
        return (Add-TableHints -Result $r -Table $table)
    }

    $starRows = @($matched | Where-Object { Test-IsAllModule $_.Module })
    $selected = New-Object System.Collections.Generic.List[object]
    if ($touched.Count -eq 0) {
        if ($starRows.Count -gt 0) {
            foreach ($row in $starRows) { $selected.Add($row) }
        } else {
            # No touched module and no default row: running the first module row
            # would compile module-a only and call a module-b change PASS.
            $msg = Get-McMessage 'emptyTouchedModules' 'table has a module column but touched_modules is empty/none; list the touched modules in summary.md (or add a * row)'
            return (Add-TableHints -Result @{ Ok=$false; Ran=$true; Found=$true; Detail=$msg } -Table $table)
        }
    } else {
        $missing = @()
        foreach ($mod in $touched) {
            $hit = @($matched | Where-Object { $_.Module -and (($_.Module.Trim()) -eq $mod) })
            if ($hit.Count -gt 0) {
                $row = $hit[0]
                # A placeholder exact row must not shadow a real * row: the
                # module would look covered while nothing ran for it.
                if ((Test-PlaceholderCommand -RawCell $row.Command -SkipMarkers $SkipMarkers -SkipExact $SkipExact) -and $starRows.Count -gt 0) {
                    $selected.Add($starRows[0])
                } else {
                    $selected.Add($row)
                }
                continue
            }
            if ($starRows.Count -gt 0) { $selected.Add($starRows[0]); continue }
            $missing += $mod
        }
        if ($missing.Count -gt 0) {
            $tmpl = Get-McMessage 'missingModuleRow' 'no compile/test command for module {0}; add a row or *; check the name against .harness/modules/ cards'
            $details = @($missing | ForEach-Object { [string]::Format([string]$tmpl, $_) }) -join '; '
            return (Add-TableHints -Result @{ Ok=$false; Ran=$true; Found=$true; Detail=$details } -Table $table)
        }
    }

    # The same command declared for two modules must run once, and its label must
    # name every module it covers.
    $groups = New-Object System.Collections.Generic.List[object]
    $byCommand = @{}
    foreach ($row in $selected) {
        $key = [string]$row.Command
        $mod = if ($row.Module) { $row.Module.Trim() } else { '' }
        if ($byCommand.ContainsKey($key)) {
            $g = $byCommand[$key]
            if ($mod -and ($g.Modules -notcontains $mod)) { $g.Modules.Add($mod) }
            continue
        }
        $g = [pscustomobject]@{ Command = $key; Modules = (New-Object System.Collections.Generic.List[string]) }
        if ($mod) { $g.Modules.Add($mod) }
        $byCommand[$key] = $g
        $groups.Add($g)
    }

    $labels = @()
    $failed = $null
    $hasSkip = $false
    foreach ($g in $groups) {
        $label = if ($g.Modules.Count -gt 0) { (($g.Modules -join '+') + ': ' + $g.Command) } else { [string]$g.Command }
        $r = Test-RunCommand -RawCell $g.Command -SkipMarkers $SkipMarkers -SkipExact $SkipExact
        if ($r.Ran -eq $false -and $r.Found -eq $true) {
            $hasSkip = $true
            $labels += ('SKIP ' + $label)
            continue
        }
        if (-not $r.Ok) { $failed = ($label + ' -> ' + $r.Detail); break }
        $labels += $label
    }
    if ($failed) {
        return (Add-TableHints -Result @{ Ok=$false; Ran=$true; Found=$true; Detail=('module command failed: ' + $failed) } -Table $table)
    }
    if ($hasSkip) {
        return (Add-TableHints -Result @{ Ok=$false; Ran=$false; Found=$true; Detail=('placeholder or not-applicable marker: ' + ($labels -join ', ')) } -Table $table)
    }
    return (Add-TableHints -Result @{ Ok=$true; Ran=$true; Found=$true; Detail=('modules ok: ' + ($labels -join ', ')) } -Table $table)
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
    # Marker semantics live in Test-PlaceholderCommand so row selection and
    # execution cannot disagree about what counts as a placeholder.
    if (Test-PlaceholderCommand -RawCell $RawCell -SkipMarkers $SkipMarkers -SkipExact $SkipExact) {
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

# A read-only investigation is declared by record_kind + flow L1. It has no
# change to describe, so the change-oriented stage 2 criteria are satisfied by
# the declaration itself; any other summary still has to write them.
function Test-InvestigationSummary {
    param([string]$Text)
    if (-not $Text) { return $false }
    $kind = [regex]::Match($Text, '(?m)(?<![A-Za-z0-9_\-])record_kind:\s*`?([A-Za-z][A-Za-z-]*)')
    if (-not $kind.Success -or $kind.Groups[1].Value -ine 'investigation') { return $false }
    $flow = [regex]::Match($Text, '(?m)(?<![A-Za-z0-9_\-])flow:\s*`?\s*(L[0-3])')
    return ($flow.Success -and $flow.Groups[1].Value -eq 'L1')
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
            if (Test-InvestigationSummary -Text $summary) { return @{ Ok=$true; Detail='investigation record: change list not required' } }
            if (Test-SectionHeading -Text $summary -Needles $S.techImpact) { return @{ Ok=$true; Detail=$M.present } }
            return @{ Ok=$false; Detail='no technical change list' }
        }
        'risks-listed' {
            if (-not $summary) { return @{ Ok=$false; Detail='no summary.md' } }
            if (Test-InvestigationSummary -Text $summary) { return @{ Ok=$true; Detail='investigation record: risk section not required' } }
            if (Test-SectionHeading -Text $summary -Needles $S.risk) { return @{ Ok=$true; Detail=$M.present } }
            return @{ Ok=$false; Detail='no risk section' }
        }
        'tasks-listed' {
            if (-not $summary) { return @{ Ok=$false; Detail='no summary.md' } }
            if (Test-InvestigationSummary -Text $summary) { return @{ Ok=$true; Detail='investigation record: task breakdown not required' } }
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
        'review-ledger' {
            # Delegated to check-summary -Stage review: the review stage allows a
            # row that is not fixed yet, final decides whether every P0/P1 closes.
            return Test-SummaryFields -FeatureName $FeatureName -ProjectRoot $ProjectRoot -GateStage 'review'
        }
        'shortfall-listed' {
            if (-not $summary) { return @{ Ok=$false; Detail='no summary.md' } }
            # A3+ is an acceptance criterion, so it needs a machine-readable resting
            # place. The section is about harness assets only: a rule / gate / skill
            # path, or a none marker when business code had nothing to add. A plain
            # business source path is not a harness capability and stays a failure.
            $body = Get-SectionBody -Text $summary -Needles $S.shortfall
            if ($null -eq $body) { return @{ Ok=$false; Detail='no shortfall section (state the harness capability added, or write a none marker)' } }
            if (Test-HasAny -Text $body -Needles $RULES.noneMarkers) { return @{ Ok=$true; Detail=$M.present } }
            if ($body -match '(\.harness|scripts)[\\/]') { return @{ Ok=$true; Detail=$M.present } }
            # List the configured markers instead of "a none marker": the failure
            # is only actionable if it says what would have been accepted.
            $markerList = @($RULES.noneMarkers | Where-Object { $_ } | ForEach-Object { [string]$_ }) -join ' / '
            return @{ Ok=$false; Detail=("shortfall section must name a harness capability (.harness/ or scripts/ path); business-code changes need no harness asset, so a none marker is enough. Accepted: " + $markerList) }
        }
        'distill-recorded' {
            if (-not $summary) { return @{ Ok=$false; Detail='no summary.md' } }
            if (Test-SectionHeading -Text $summary -Needles $S.distill) { return @{ Ok=$true; Detail=$M.present } }
            return @{ Ok=$false; Detail='no distill / lesson section' }
        }
        'lessons-asserted' {
            # Delegated to metrics.ps1 so the count and the gate cannot drift.
            $mp = Join-Path $ProjectRoot 'scripts\metrics.ps1'
            if (-not (Test-Path -LiteralPath $mp)) { return @{ Ok=$false; Detail='missing scripts\metrics.ps1' } }
            # -LessonGate is side-effect free on purpose, so the tracked indexes
            # are refreshed here first; otherwise stage 10 closes while
            # lessons.md / reviews.md still describe the previous task.
            & powershell -NoProfile -ExecutionPolicy Bypass -File $mp -Root $ProjectRoot 2>&1 | Out-Null
            $lg = & powershell -NoProfile -ExecutionPolicy Bypass -File $mp -Root $ProjectRoot -LessonGate 2>&1
            if ($LASTEXITCODE -eq 0) { return @{ Ok=$true; Detail='repeated lessons have checks' } }
            $first = @($lg | Where-Object { $_ -match '\[FAIL\]' } | Select-Object -First 1)
            return @{ Ok=$false; Detail=("repeated lesson without a check: " + $first) }
        }
        'corrections-attributed' {
            # Accepted shapes: a bare "corrections: 3" and the template's
            # labelled "- <label>:`corrections: 3`". The old anchored regex only
            # matched the bare shape, so every summary copied from the template
            # silently skipped this gate. The pattern below is the same one
            # check-summary.ps1 uses (Get-FieldRaw), so the two cannot diverge.
            if (-not $summary) { return @{ Ok=$false; Detail='no summary.md' } }
            $rx = '(?m)^[ \t]*(?:[-*][ \t]+)?(?:[^\r\n:\uFF1A]*?[:\uFF1A][ \t]*`?`?)?`?`?(?<![A-Za-z0-9_\-])corrections:\s*([^\r\n]*)'
            $cm = [regex]::Match($summary, $rx)
            if (-not $cm.Success) { return @{ Ok=$true; Detail='no corrections field' } }
            $raw = $cm.Groups[1].Value.Trim()
            $parts = @($raw -split '`' | ForEach-Object { $_.Trim() } | Where-Object { $_.Length -gt 0 })
            $val = if ($parts.Count -gt 0) { $parts[0] } else { $raw }
            if ($val -notmatch '^(\d+)') { return @{ Ok=$true; Detail='corrections value is not numeric yet' } }
            if ([int]$matches[1] -le 0) { return @{ Ok=$true; Detail='no corrections to attribute' } }
            $lr = '(?m)^[ \t]*(?:[-*][ \t]+)?(?:[^\r\n:\uFF1A]*?[:\uFF1A][ \t]*`?`?)?`?`?(?<![A-Za-z0-9_\-])lesson_id:\s*`?\s*([^`\r\n]+)'
            $lm = [regex]::Match($summary, $lr)
            $lid = if ($lm.Success) { $lm.Groups[1].Value.Trim() } else { '' }
            if ($lid -match '^[A-Za-z0-9]') {
                return @{ Ok=$true; Detail='corrections attributed to a lesson id' }
            }
            return @{ Ok=$false; Detail='corrections > 0 but no lesson_id; attribute it so the lesson can be promoted' }
        }
        'compiles' {
            return Test-RunCommandSet -ProjectRoot $ProjectRoot -FeatureName $FeatureName -Keywords $RULES.agentsCommandPurpose.compile -SkipMarkers $RULES.commandSkipMarkers -SkipExact $RULES.commandSkipExact
        }
        'tests-green' {
            return Test-RunCommandSet -ProjectRoot $ProjectRoot -FeatureName $FeatureName -Keywords $RULES.agentsCommandPurpose.test -SkipMarkers $RULES.commandSkipMarkers -SkipExact $RULES.commandSkipExact
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
            # The summary-order guard is part of the gate. Without it, "code
            # first, summary later" is undetectable; report the stale hook here
            # too so stage 4/7 and verify-harness never disagree.
            if (($preBody -notmatch 'LATE_SUMMARY') -or ($preBody -notmatch 'REPLAY_CONTEXT') -or ($preBody -notmatch 'ASSOC_MISS')) {
                return @{ Ok=$false; Detail='pre-commit predates the summary-order guard (re-run install-git-hooks.ps1)' }
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
            if (($mergeBody -notmatch 'LATE_SUMMARY') -or ($mergeBody -notmatch 'REPLAY_CONTEXT') -or ($mergeBody -notmatch 'ASSOC_MISS')) {
                return @{ Ok=$false; Detail='pre-merge-commit predates the summary-order guard (re-run install-git-hooks.ps1)' }
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
    Complete-Harness 0
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
    $stageHints = @()
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
            if ($c.Id -eq 'summary-exists') { $stageHints += 'no-summary' }
        }
    }

    # "no summary.md" used to be a dead end: the agent saw a FAIL row and started
    # coding anyway. The failure text is the only message it is guaranteed to
    # read, so name the skill and the exact four steps here.
    if ($stageHints -contains 'no-summary') {
        $featLabel = if ($Feature) { $Feature } else { '<feature>' }
        Write-Host "  [HINT]   the change record is missing; load skill 'request-analysis' first, then:" -ForegroundColor Yellow
        Write-Host ("           1) copy .harness/changes/_template/summary.md to .harness/changes/{0}/summary.md" -f $featLabel) -ForegroundColor Yellow
        Write-Host "           2) fill requirement / impact / tasks with real content (placeholders do not count)" -ForegroundColor Yellow
        # A summary with only the three sections still fails check-summary: the
        # flow / loaded_skills / touched_modules fields are mandatory at -Stage
        # initial. Naming them here is what makes step 3 pass on the first try.
        Write-Host "           2b) also fill flow (L1/L2/L3), loaded_skills and touched_modules (write none when empty)" -ForegroundColor Yellow
        Write-Host ("           3) run scripts\check-summary.ps1 -Feature {0} -Stage initial" -f $featLabel) -ForegroundColor Yellow
        Write-Host "           4) commit that record on its own, then start coding" -ForegroundColor Yellow
        # Step 5 removes the "which command now?" guesswork that made the first
        # OPEN take four invocations.
        Write-Host ("           5) re-run this command: scripts\stage-gate.ps1 -Stage 1 -Feature {0}" -f $featLabel) -ForegroundColor Yellow
    }

    Write-Host ("-" * 70)
    if ($autoFail -gt 0) {
        $anyFail = $true
        Write-Host ("  RESULT: NOT READY  (auto pass={0} fail={1} skip={2}, manual={3})" -f $autoPass, $autoFail, $skipCount, $humanCount) -ForegroundColor Red
        Write-Host ("  Cannot move past stage {0} until the FAIL rows are fixed." -f $d.Key) -ForegroundColor Red
    } else {
        Write-Host ("  RESULT: READY  (auto pass={0} skip={1}, manual={2} to confirm yourself)" -f $autoPass, $skipCount, $humanCount) -ForegroundColor Green
        # One paste-ready line: the agent must echo it before touching code, so a
        # skipped stage 0 becomes visible in the conversation instead of silent.
        if ($Feature -and ($d.Key -eq '1' -or $d.Key -eq '3')) {
            $flowVal = '?'
            $smText = Get-SummaryText -FeatureName $Feature
            if ($smText) {
                # The template writes "flow: L2 (standard)" inside a labelled
                # bullet and backticks, so match anywhere in the line.
                $fm = [regex]::Match($smText, 'flow:\s*`?([A-Za-z][A-Za-z0-9]*)')
                if ($fm.Success) { $flowVal = $fm.Groups[1].Value }
            }
            $nextStage = if ($d.Key -eq '1') { '2' } else { '4' }
            Write-Host ("  DECLARE: record=.harness/changes/{0}/summary.md | flow={1} | next=scripts\stage-gate.ps1 -Stage {2} -Feature {0}" -f $Feature, $flowVal, $nextStage) -ForegroundColor Cyan
        }
    }
}

Write-Host ""
if ($anyFail) { Write-Host "Gate result: BLOCKED" -ForegroundColor Red; Complete-Harness 1 }
Write-Host "Gate result: OPEN" -ForegroundColor Green
Complete-Harness 0
