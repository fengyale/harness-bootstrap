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
    When the project declares modules (module cards or a module column in the
    AGENTS.md command table) and -Modules is empty, a warning names the risk:
    stage 3 may FAIL on touched_modules=none.
    Not a git repository: stage 1 still runs, but no marker is written (WARN).

  NOTE ON THE GATE
    requireTaskStart defaults to false on a fresh install and on an upgrade. A
    team turns it on after adopting this entry point; the pre-commit hook then
    checks the marker only for commits that land a summary.md.

  USAGE
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\harness-start.ps1 -Feature order-export -Requirement "export orders to excel"
    ... -Feature order-export -Flow L3 -Modules order,report -SkipPlan
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

function Invoke-Start {
    param(
        [string]$RootPath,
        [string]$FeatureName,
        [string]$RequirementText,
        [string]$FlowValue,
        [string]$ModulesText,
        [switch]$NoPlan
    )

    # ------------------------------------------------------------- 0 guards
    if ($FlowValue -eq 'L0') {
        Write-Host '[FAIL] -Flow L0 keeps no change record: skip harness-start for L0 work' -ForegroundColor Red
        return 1
    }
    if ($FlowValue -eq 'L1') {
        Write-Host '[WARN] -Flow L1 normally uses .harness/changes/_small.md, not summary.md; continuing because you asked for a full record' -ForegroundColor Yellow
    }
    $featureError = Test-FeatureName -FeatureName $FeatureName -RootPath $RootPath
    if ($featureError) {
        Write-Host ('[FAIL] ' + $featureError + ': ' + $FeatureName) -ForegroundColor Red
        return 1
    }

    Write-Host ('harness-start: ' + $FeatureName) -ForegroundColor Cyan

    # ---------------------------------------------------------- 1 context pack
    if (-not $NoPlan) {
        $planScript = Join-Path $RootPath 'scripts\harness-plan.ps1'
        if (Test-Path -LiteralPath $planScript) {
            if (-not $RequirementText -or $RequirementText.Trim() -eq '') {
                Write-Host '[INFO] plan skipped: pass -Requirement to print the context pack' -ForegroundColor DarkGray
            } else {
                Write-Host ''
                Write-Host '--- harness plan (read only) ---' -ForegroundColor Cyan
                & $PS -NoProfile -ExecutionPolicy Bypass -File $planScript -Root $RootPath -Requirement $RequirementText -Feature $FeatureName | Out-Host
                if ($LASTEXITCODE -ne 0) {
                    Write-Host '[WARN] harness-plan failed; continuing (the plan is an aid, not a gate)' -ForegroundColor Yellow
                }
                Write-Host '--- end of plan ---' -ForegroundColor Cyan
            }
        }
    }

    # --------------------------------------------------------- 2 change record
    $modulesValue = Get-ModulesValue $ModulesText
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
        $text = Set-SummaryPrefill -Text $text -FlowValue $FlowValue -ModulesValue $modulesValue
        $dir = Split-Path -Parent $summaryPath
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        [System.IO.File]::WriteAllText($summaryPath, $text, $Utf8NoBom)
        Write-Host ('[ADD] ' + $summaryPath) -ForegroundColor Green
        Write-Host ('      pre-filled flow: ' + $FlowValue + ' / touched_modules: ' + $modulesValue)
        Write-Host '      fill loaded_skills / acceptance / impact / tasks, then re-run this command'
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
        $mText = [System.IO.File]::ReadAllText($marker, [System.Text.Encoding]::UTF8)
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
        foreach ($d in @($tmp, $tmp2, $tmp3)) {
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
    Write-Host 'usage: harness-start.ps1 -Feature <name> [-Requirement "<raw request>"] [-Flow L0|L1|L2|L3] [-Modules a,b] [-Root <dir>] [-SkipPlan]' -ForegroundColor Red
    exit 1
}

$rootPath = $Root
try { $rootPath = (Resolve-Path -LiteralPath $Root).Path }
catch {
    Write-Host ('[FAIL] root not found: ' + $Root) -ForegroundColor Red
    exit 1
}

exit (Invoke-Start -RootPath $rootPath -FeatureName $Feature -RequirementText $Requirement -FlowValue $Flow -ModulesText $Modules -NoPlan:$SkipPlan)
