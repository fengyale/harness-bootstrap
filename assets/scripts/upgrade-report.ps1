<#
  upgrade-report.ps1 -- activation report after an upgrade

  WHY
    update-harness replaces machinery, but "the file is on disk" is not the same
    as "the new behaviour is switched on". Some pieces are package-owned (a file
    or a JSON key), others only become real after the project fills a block
    (AGENTS.md, the process spec). The operator needs to see the difference.

  ITEMS
    harness-start         scripts/harness-start.ps1 exists
    check-task-start      scripts/check-task-start.ps1 exists
    requireTaskStart      scripts/harness-required.json has the key and it is true
                          (false is the opt-in default: MANUAL, not ACTIVE)
    pre-commit-hook       the git hook calls check-task-start (only checked when a hook exists)
    agents-start-command  AGENTS.md carries a non-empty upgrade block id=start-command
    flow-start-command    the process spec carries a non-empty block (MANUAL when absent)
    summary-template      _template/summary.md has delivery_status / linked_records / the review section
    module-commands       stage-gate-rules.json has moduleCommands (MANUAL when absent)

  STATUS
    [ACTIVE]   switched on, evidence on disk
    [MANUAL]   the project still has to act (opt-in switch off, or a project-owned
               rule to fill); never a failure
    [MISSING]  a package-owned artifact is absent, empty or still a stub

  USAGE
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\upgrade-report.ps1
    ... -Root D:\proj
    ... -Root D:\proj -Json
    ... -Root D:\proj -Strict      (exit 1 when anything is MISSING)
    ... -SelfTest

  EXIT CODE
    0 = report printed; 1 = -Strict and at least one MISSING

  NOTE
    Pure ASCII on purpose (PS 5.1 parses .ps1 as ANSI without a BOM).
#>
[CmdletBinding()]
param(
    [string]$Root = (Get-Location).Path,
    [switch]$Json,
    [switch]$Strict,
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'

# Chinese literals are built from code points so this file stays pure ASCII.
function New-Cn {
    param([int[]]$CodePoints)
    return (-join ($CodePoints | ForEach-Object { [char]$_ }))
}

# The upgrade blocks are marker-delimited so an upgrade can replace them without
# touching project text. A missing end marker means the block never started.
function Get-UpgradeBlock {
    param([string]$Text, [string]$Id)
    $pattern = '(?is)<!--\s*harness:upgrade:begin\s+id\s*=\s*' + [regex]::Escape($Id) +
               '\s*-->(.*?)<!--\s*harness:upgrade:end(?:\s+id\s*=\s*' + [regex]::Escape($Id) + ')?\s*-->'
    $m = [regex]::Match($Text, $pattern)
    if (-not $m.Success) { return $null }
    return $m.Groups[1].Value
}

function Get-ReportItems {
    param([string]$RootPath)

    $items = New-Object System.Collections.Generic.List[object]
    function Add-Item {
        param([string]$Id, [string]$Status, [string]$Evidence)
        $items.Add([pscustomobject]@{ id = $Id; status = $Status; evidence = $Evidence })
    }

    # ---------------------------------------------------- 1/2 start scripts
    foreach ($pair in @(
        @{ Id = 'harness-start'; Rel = 'scripts/harness-start.ps1' },
        @{ Id = 'check-task-start'; Rel = 'scripts/check-task-start.ps1' }
    )) {
        $full = Join-Path $RootPath ($pair.Rel -replace '/', '\')
        if (Test-Path -LiteralPath $full -PathType Leaf) {
            Add-Item $pair.Id 'ACTIVE' $pair.Rel
        } else {
            Add-Item $pair.Id 'MISSING' ('missing: ' + $pair.Rel)
        }
    }

    # --------------------------------------------------- 3 requireTaskStart
    $cfgPath = Join-Path $RootPath 'scripts\harness-required.json'
    $cfg = $null
    if (Test-Path -LiteralPath $cfgPath) {
        try { $cfg = (Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8) | ConvertFrom-Json } catch { $cfg = $null }
    }
    if ($null -eq $cfg) {
        Add-Item 'requireTaskStart' 'MISSING' 'missing or unreadable: scripts/harness-required.json'
    } elseif ($cfg.PSObject.Properties.Name -contains 'requireTaskStart') {
        if ([bool]$cfg.requireTaskStart) {
            Add-Item 'requireTaskStart' 'ACTIVE' 'scripts/harness-required.json: requireTaskStart=true'
        } else {
            # The switch ships false on purpose (adoption opt-in). Reporting it
            # ACTIVE would make a clean upgrade look fully armed while the gate
            # is still open.
            Add-Item 'requireTaskStart' 'MANUAL' 'requireTaskStart=false (opt-in; set true after adoption)'
        }
    } else {
        Add-Item 'requireTaskStart' 'MISSING' 'scripts/harness-required.json: requireTaskStart key absent'
    }

    # ------------------------------------------------------ 4 pre-commit hook
    $hooksDir = $null
    if (Get-Command git -ErrorAction SilentlyContinue) {
        $savedEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $gitOut = @(& git -C $RootPath rev-parse --git-path hooks 2>&1)
            $firstGit = if ($gitOut.Count -gt 0) { ([string]$gitOut[0]).Trim() } else { '' }
            if ($LASTEXITCODE -eq 0 -and $firstGit) {
                if ([System.IO.Path]::IsPathRooted($firstGit)) {
                    $hooksDir = $firstGit
                } else {
                    $hooksDir = [System.IO.Path]::GetFullPath((Join-Path $RootPath $firstGit))
                }
            }
        } catch {
            $hooksDir = $null
        } finally {
            $ErrorActionPreference = $savedEap
        }
    }
    if (-not $hooksDir) { $hooksDir = Join-Path $RootPath '.git\hooks' }
    $hookPath = Join-Path $hooksDir 'pre-commit'
    if (-not (Test-Path -LiteralPath $hookPath -PathType Leaf)) {
        Add-Item 'pre-commit-hook' 'MANUAL' 'no pre-commit hook (run scripts\install-git-hooks.ps1 to switch the task-start guard on)'
    } else {
        $hookBody = [System.IO.File]::ReadAllText($hookPath, [System.Text.Encoding]::UTF8)
        if ($hookBody -match 'check-task-start') {
            Add-Item 'pre-commit-hook' 'ACTIVE' 'pre-commit hook calls check-task-start'
        } else {
            Add-Item 'pre-commit-hook' 'MANUAL' 'pre-commit hook has no check-task-start line (re-run scripts\install-git-hooks.ps1)'
        }
    }

    # ------------------------------------------------ 5 AGENTS.md start block
    $agentsPath = Join-Path $RootPath 'AGENTS.md'
    if (-not (Test-Path -LiteralPath $agentsPath)) {
        Add-Item 'agents-start-command' 'MISSING' 'missing: AGENTS.md'
    } else {
        $agentsText = [System.IO.File]::ReadAllText($agentsPath, [System.Text.Encoding]::UTF8)
        $block = Get-UpgradeBlock $agentsText 'start-command'
        if ($null -eq $block) {
            Add-Item 'agents-start-command' 'MISSING' 'AGENTS.md has no upgrade block id=start-command'
        } elseif ($block.Trim().Length -eq 0) {
            # Package-owned block: an empty one is the same as not switched on.
            Add-Item 'agents-start-command' 'MISSING' 'AGENTS.md block id=start-command is empty'
        } else {
            Add-Item 'agents-start-command' 'ACTIVE' 'AGENTS.md block id=start-command has content'
        }
    }

    # ---------------------------------------------- 6 process spec flow block
    $flowName = (New-Cn @(0x5F00, 0x53D1, 0x6D41, 0x7A0B, 0x89C4, 0x8303)) + '.md'
    $flowPath = Join-Path (Join-Path $RootPath '.harness\rules') $flowName
    $flowStatus = 'MANUAL'
    $flowEvidence = '.harness/rules/' + $flowName + ' block id=flow-start-command absent (project-owned rule; fill it by hand)'
    if (Test-Path -LiteralPath $flowPath) {
        $flowText = [System.IO.File]::ReadAllText($flowPath, [System.Text.Encoding]::UTF8)
        $flowBlock = Get-UpgradeBlock $flowText 'flow-start-command'
        if ($null -ne $flowBlock -and $flowBlock.Trim().Length -gt 0) {
            $flowStatus = 'ACTIVE'
            $flowEvidence = '.harness/rules/' + $flowName + ' block id=flow-start-command has content'
        }
    }
    Add-Item 'flow-start-command' $flowStatus $flowEvidence

    # ---------------------------------------------------- 7 summary template
    $sumPath = Join-Path $RootPath '.harness\changes\_template\summary.md'
    if (-not (Test-Path -LiteralPath $sumPath)) {
        Add-Item 'summary-template' 'MISSING' 'missing: .harness/changes/_template/summary.md'
    } else {
        $sumText = [System.IO.File]::ReadAllText($sumPath, [System.Text.Encoding]::UTF8)
        $reviewSection = New-Cn @(0x8BC4, 0x5BA1, 0x7ED3, 0x8BBA)
        $missingFields = @()
        if ($sumText -notmatch 'delivery_status') { $missingFields += 'delivery_status' }
        if ($sumText -notmatch 'linked_records') { $missingFields += 'linked_records' }
        if ($sumText -notmatch [regex]::Escape($reviewSection)) { $missingFields += $reviewSection }
        if ($missingFields.Count -eq 0) {
            Add-Item 'summary-template' 'ACTIVE' '.harness/changes/_template/summary.md has delivery_status / linked_records / review section'
        } else {
            # The template is package-owned: a missing field is a stale copy,
            # not a project task.
            Add-Item 'summary-template' 'MISSING' ('.harness/changes/_template/summary.md is missing: ' + ($missingFields -join ', '))
        }
    }

    # ------------------------------------------------------ 8 moduleCommands
    $sgrPath = Join-Path $RootPath 'scripts\stage-gate-rules.json'
    $hasModuleCommands = $false
    if (Test-Path -LiteralPath $sgrPath) {
        try {
            $sgr = (Get-Content -LiteralPath $sgrPath -Raw -Encoding UTF8) | ConvertFrom-Json
            if ($null -ne $sgr -and ($sgr.PSObject.Properties.Name -contains 'moduleCommands')) { $hasModuleCommands = $true }
        } catch {
            $hasModuleCommands = $false
        }
    }
    if ($hasModuleCommands) {
        Add-Item 'module-commands' 'ACTIVE' 'scripts/stage-gate-rules.json: moduleCommands present'
    } else {
        Add-Item 'module-commands' 'MANUAL' 'scripts/stage-gate-rules.json: moduleCommands absent (module-aware gates stay off)'
    }

    return $items
}

function Invoke-UpgradeReportSelfTest {
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('hb-upgrade-report-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $fails = New-Object System.Collections.Generic.List[string]
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $psHost = if (Get-Command powershell -ErrorAction SilentlyContinue) { 'powershell' } else { 'pwsh' }

    function Assert-Case {
        param([string]$Name, [bool]$Ok)
        if ($Ok) { Write-Host ('ok: ' + $Name) }
        else { Write-Host ('[FAIL] ' + $Name) -ForegroundColor Red; $fails.Add($Name) }
    }

    function Get-Statuses {
        param([string]$ProjRoot)
        $map = @{}
        $raw = @(& $psHost -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Root $ProjRoot -Json 2>&1)
        $text = ($raw | Out-String)
        $s = $text.IndexOf('{')
        $e = $text.LastIndexOf('}')
        if ($s -lt 0 -or $e -le $s) { return $map }
        $j = $null
        try { $j = ($text.Substring($s, $e - $s + 1) | ConvertFrom-Json) } catch { return $map }
        foreach ($it in @($j.items)) { $map[[string]$it.id] = [string]$it.status }
        return $map
    }

    function Invoke-Strict {
        param([string]$ProjRoot)
        $null = & $psHost -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Root $ProjRoot -Strict 2>&1
        return $LASTEXITCODE
    }

    try {
        $proj = Join-Path $tmp 'proj'
        New-Item -ItemType Directory -Force -Path (Join-Path $proj 'scripts') | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $proj '.git\hooks') | Out-Null

        $stat = Get-Statuses $proj
        Assert-Case 'missing fixture: harness-start is MISSING' ($stat['harness-start'] -eq 'MISSING')
        Assert-Case 'missing fixture: check-task-start is MISSING' ($stat['check-task-start'] -eq 'MISSING')
        Assert-Case 'missing fixture: requireTaskStart is MISSING' ($stat['requireTaskStart'] -eq 'MISSING')
        Assert-Case 'missing fixture: start-command block is MISSING' ($stat['agents-start-command'] -eq 'MISSING')
        Assert-Case 'missing fixture: summary template is MISSING' ($stat['summary-template'] -eq 'MISSING')
        Assert-Case 'missing fixture: flow block defaults to MANUAL' ($stat['flow-start-command'] -eq 'MANUAL')
        Assert-Case 'missing fixture: moduleCommands defaults to MANUAL' ($stat['module-commands'] -eq 'MANUAL')
        Assert-Case 'missing fixture: -Strict exits 1' ((Invoke-Strict $proj) -eq 1)

        # Fill every package-owned artifact and both marker blocks.
        [System.IO.File]::WriteAllText((Join-Path $proj 'scripts\harness-start.ps1'), '# selftest' + "`n", $utf8)
        [System.IO.File]::WriteAllText((Join-Path $proj 'scripts\check-task-start.ps1'), '# selftest' + "`n", $utf8)
        [System.IO.File]::WriteAllText((Join-Path $proj 'scripts\harness-required.json'), '{"requireTaskStart": true}' + "`n", $utf8)
        [System.IO.File]::WriteAllText((Join-Path $proj 'scripts\stage-gate-rules.json'), '{"moduleCommands": {}}' + "`n", $utf8)
        [System.IO.File]::WriteAllText((Join-Path $proj '.git\hooks\pre-commit'), 'powershell -File scripts\check-task-start.ps1' + "`n", $utf8)

        $agents = @(
            '# demo project',
            '',
            '<!-- harness:upgrade:begin id=start-command -->',
            'powershell -File scripts\harness-start.ps1 -Feature demo',
            '<!-- harness:upgrade:end id=start-command -->',
            ''
        ) -join "`n"
        [System.IO.File]::WriteAllText((Join-Path $proj 'AGENTS.md'), $agents, $utf8)

        $flowDir = Join-Path $proj ('.harness\rules')
        New-Item -ItemType Directory -Force -Path $flowDir | Out-Null
        $flowName = (New-Cn @(0x5F00, 0x53D1, 0x6D41, 0x7A0B, 0x89C4, 0x8303)) + '.md'
        $flowBody = @(
            '# process spec',
            '',
            '<!-- harness:upgrade:begin id=flow-start-command -->',
            'run scripts\harness-start.ps1 first',
            '<!-- harness:upgrade:end id=flow-start-command -->',
            ''
        ) -join "`n"
        [System.IO.File]::WriteAllText((Join-Path $flowDir $flowName), $flowBody, $utf8)

        $sumDir = Join-Path $proj '.harness\changes\_template'
        New-Item -ItemType Directory -Force -Path $sumDir | Out-Null
        $reviewSection = New-Cn @(0x8BC4, 0x5BA1, 0x7ED3, 0x8BBA)
        $sumBody = @(
            '# summary',
            '',
            '- delivery_status: ' + (New-Cn @(0x5DF2, 0x4EA4, 0x4ED8, 0x672A, 0x63D0, 0x4EA4)),
            '- linked_records: -',
            '',
            '## ' + $reviewSection,
            ''
        ) -join "`n"
        [System.IO.File]::WriteAllText((Join-Path $sumDir 'summary.md'), $sumBody, $utf8)

        $stat = Get-Statuses $proj
        foreach ($id in @('harness-start', 'check-task-start', 'requireTaskStart', 'pre-commit-hook', 'agents-start-command', 'flow-start-command', 'summary-template', 'module-commands')) {
            Assert-Case ('filled fixture: ' + $id + ' is ACTIVE') ($stat[$id] -eq 'ACTIVE')
        }
        Assert-Case 'filled fixture: -Strict exits 0' ((Invoke-Strict $proj) -eq 0)
    } finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }

    if ($fails.Count -gt 0) {
        Write-Host ('UPGRADE-REPORT SELFTEST FAILED: ' + $fails.Count + ' case(s)') -ForegroundColor Red
        return 1
    }
    Write-Host 'UPGRADE-REPORT SELFTEST OK' -ForegroundColor Green
    return 0
}

if ($SelfTest) {
    exit (Invoke-UpgradeReportSelfTest)
}

$rootPath = (Resolve-Path -LiteralPath $Root).Path
$items = @(Get-ReportItems -RootPath $rootPath)
$active = @($items | Where-Object { $_.status -eq 'ACTIVE' }).Count
$manual = @($items | Where-Object { $_.status -eq 'MANUAL' }).Count
$missing = @($items | Where-Object { $_.status -eq 'MISSING' }).Count

if ($Json) {
    $obj = [pscustomobject]@{
        root    = $rootPath
        active  = $active
        manual  = $manual
        missing = $missing
        items   = $items
    }
    $obj | ConvertTo-Json -Depth 6
} else {
    foreach ($it in $items) {
        $color = switch ($it.status) {
            'ACTIVE' { 'Green' }
            'MANUAL' { 'Yellow' }
            default { 'Red' }
        }
        Write-Host ('[{0}] {1}: {2}' -f $it.status, $it.id, $it.evidence) -ForegroundColor $color
    }
    Write-Host ''
    Write-Host ('upgrade report: {0} active, {1} manual, {2} missing' -f $active, $manual, $missing)
}

if ($Strict -and $missing -gt 0) { exit 1 }
exit 0
