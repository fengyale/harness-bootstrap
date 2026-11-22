<#
  run-all.ps1 -- run every behavioural test of harness-bootstrap

  WHY
    verify-package.ps1 -Fast catches static drift before a commit, but the
    contract checks cannot prove that the gate actually blocks the wrong thing.
    These tests install the scripts into throw-away projects and assert the
    real exit codes: tri-state command checks, summary field split, hook
    install/uninstall, stage-gate -All, metrics, A3+ spoof rejection.

  WHAT RUNS
    gate-auto.ps1   stage-gate AUTO behaviour and pre-commit field scope
    regression.ps1  install -> fill summary -> stage-gate -All -> metrics -> uninstall
    test-update.ps1 upgrade plan: replace .ps1, keep JSON/history, backup, version marker
    test-audit-order.ps1  CI-side summary-order audit over a commit range
    test-skills-registry.ps1  a new skill must be indexed and reachable, or it is a dead file
    test-probe.ps1  draft facts extracted by probe-project.ps1

  USAGE
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-all.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-all.ps1 -Suite test-update
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-all.ps1 -Changed
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-all.ps1 -Throttle 1

  SCHEDULING
    Each suite gets its own -TestRoot under %TEMP%\hb-tests-<guid>\<suite>, so
    no two suites share (or delete) a fixture directory. Suites therefore run
    in parallel by default and the wall time is max(end) - min(start), not the
    sum. Use -Throttle 1 (or -Serial) to reproduce the old serial output, and
    -Changed to run only the suites that cover the files you touched.

  EXIT CODE
    0 = every test passed, 1 = at least one failed
#>
[CmdletBinding()]
param(
    # One suite (file name or prefix). Everything else is skipped.
    [string]$Suite = '',
    # Map changed files to the suites that cover them (development loop).
    [switch]$Changed,
    # Root for this run. Default: %TEMP%\hb-tests-<guid8>.
    [string]$TestRoot = '',
    # Max concurrent suites. 0 = min(6, ProcessorCount).
    [int]$Throttle = 0,
    # Equivalent to -Throttle 1.
    [switch]$Serial,
    # Keep the run root when a suite fails.
    [switch]$KeepArtifacts,
    # Print the plan and exit without starting anything.
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$PkgRoot = Split-Path -Parent $PSScriptRoot
$PS = if (Get-Command powershell -ErrorAction SilentlyContinue) { 'powershell' } else { 'pwsh' }

# Reporting keeps the historical suite order; launching uses the measured
# duration order so the slowest suite starts first and dominates the wall.
$allSuites = @('gate-auto.ps1', 'regression.ps1', 'test-update.ps1', 'test-audit-order.ps1', 'test-skills-registry.ps1', 'test-probe.ps1')
$launchOrder = @('gate-auto.ps1', 'test-skills-registry.ps1', 'test-update.ps1', 'regression.ps1', 'test-audit-order.ps1', 'test-probe.ps1')

function Get-GitPathList {
    # git writes warnings to stderr; with EAP=Stop a native stderr line would
    # abort the script, so relax it for the duration of the calls.
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $paths = New-Object System.Collections.Generic.List[string]
        $status = @(& git -C $PkgRoot status --porcelain 2>$null)
        if ($LASTEXITCODE -ne 0) { return $null }
        foreach ($line in $status) {
            if ($null -eq $line) { continue }
            $text = [string]$line
            if ($text.Length -le 3) { continue }
            $p = $text.Substring(3).Trim()
            if ($p -match '^\S+ -> (.+)$') { $p = $Matches[1] }
            $paths.Add(($p.Trim('"')))
        }
        $diff = @(& git -C $PkgRoot diff --name-only HEAD 2>$null)
        if ($LASTEXITCODE -ne 0) { return $null }
        foreach ($line in $diff) {
            if ($null -eq $line) { continue }
            $p = ([string]$line).Trim()
            if ($p) { $paths.Add($p) }
        }
        return @($paths | Sort-Object -Unique)
    } finally {
        $ErrorActionPreference = $saved
    }
}

function Get-ChangedSuites {
    $paths = Get-GitPathList
    if ($null -eq $paths) {
        # Not a git checkout, or git failed: a silent "nothing changed" would be
        # a false green. Fall back to the full run.
        return [pscustomobject]@{ Suites = @(); DocsOnly = $false; Unknown = $true; Files = @() }
    }
    $suites = New-Object System.Collections.Generic.List[string]
    $docsOnly = $false
    $unknown = $false
    function Add-Suite([string[]]$Names) {
        foreach ($n in $Names) { if (-not $suites.Contains($n)) { $suites.Add($n) } }
    }
    foreach ($raw in $paths) {
        $p = ($raw -replace '\\', '/')
        if ($p -eq 'tests/run-all.ps1') { Add-Suite $allSuites; continue }
        if ($p -eq 'tests/test-lib.ps1') { Add-Suite @('gate-auto.ps1', 'regression.ps1', 'test-update.ps1', 'test-skills-registry.ps1'); continue }
        if ($p -match '^tests/') {
            $leaf = Split-Path $p -Leaf
            if ($allSuites -contains $leaf) { Add-Suite @($leaf) }
            else { $unknown = $true }
            continue
        }
        if ($p -match '^assets/scripts/(check-summary|stage-gate|install-git-hooks|red-line-scan|sql-review-gate)\.(ps1|py)$') {
            Add-Suite @('gate-auto.ps1', 'regression.ps1'); continue
        }
        if ($p -match '^assets/scripts/(metrics|verify-harness|verify-grounding|sync-skills-index)\.ps1$') {
            Add-Suite @('regression.ps1', 'test-skills-registry.ps1', 'test-probe.ps1'); continue
        }
        if ($p -match '^assets/scripts/(suggest-flow|harness-plan)\.ps1$') {
            Add-Suite @('test-probe.ps1'); continue
        }
        if ($p -match '^assets/\.harness/skills/') {
            Add-Suite @('regression.ps1', 'test-skills-registry.ps1'); continue
        }
        if ($p -match '^assets/\.trae/agents/') {
            Add-Suite @('regression.ps1', 'test-skills-registry.ps1'); continue
        }
        if ($p -eq 'assets/scripts/update-harness.ps1') { Add-Suite @('test-update.ps1'); continue }
        if ($p -match '^assets/\.harness/changes/_template/') { Add-Suite @('gate-auto.ps1', 'regression.ps1', 'test-update.ps1'); continue }
        if ($p -eq 'assets/scripts/harness-required.json') { Add-Suite @('test-update.ps1'); continue }
        if ($p -eq 'assets/scripts/audit-order.ps1') { Add-Suite @('test-audit-order.ps1'); continue }
        if ($p -match '^assets/scripts/probe-[^/]*\.ps1$') { Add-Suite @('test-probe.ps1'); continue }
        # Local-only / ignored paths must not turn every -Changed run into a full
        # run. They are not part of the shipped package.
        if ($p -match '^(\.trae/|dist/|\.screenshots/|\.vscode/|\.idea/|TODO-[^/]*\.md$)') { continue }
        if ($p -eq 'tools/release.ps1') { Add-Suite @('test-probe.ps1'); continue }
        if ($p -match '^(tools/|references/|\.github/)') { $docsOnly = $true; continue }
        if ($p -match '^(docs/|README|VERSION$|releases\.json$)') { $docsOnly = $true; continue }
        # Anything outside the map (tools/, references/, workflows, ...) is
        # conservatively treated as a full run.
        $unknown = $true
    }
    return [pscustomobject]@{ Suites = @($suites); DocsOnly = $docsOnly; Unknown = $unknown; Files = $paths }
}

if ($Suite -and $Changed) {
    Write-Host '-Suite and -Changed cannot be used together' -ForegroundColor Red
    exit 1
}

$changedInfo = $null
$selected = $allSuites
if ($Changed) {
    $changedInfo = Get-ChangedSuites
    if ($changedInfo.Unknown) {
        Write-Host 'changed files outside the known map; running every suite' -ForegroundColor Yellow
        $selected = $allSuites
    } else {
        $selected = @($changedInfo.Suites)
    }
}

if ($Suite) {
    # exact name first; a prefix is accepted only when it picks exactly one suite,
    # otherwise '-Suite test' would silently run several of them.
    $exact = @($allSuites | Where-Object { $_ -eq $Suite })
    if ($exact.Count -eq 1) {
        $selected = $exact
    } else {
        $selected = @($allSuites | Where-Object { $_ -like ($Suite + '*') })
        if ($selected.Count -ne 1) {
            Write-Host "suite '$Suite' is ambiguous or unknown" -ForegroundColor Red
            Write-Host ("available: " + ($allSuites -join ', '))
            exit 1
        }
    }
}

if ($DryRun) {
    if ($Changed) {
        Write-Host 'changed files:' -ForegroundColor Cyan
        if ($changedInfo.Files.Count -eq 0) { Write-Host '  (none)' }
        foreach ($f in $changedInfo.Files) { Write-Host "  $f" }
        if ($changedInfo.Unknown) { Write-Host 'map: unknown path -> full run (conservative)' -ForegroundColor Yellow }
        elseif ($changedInfo.DocsOnly -and $selected.Count -eq 0) { Write-Host 'map: docs-only change -> no behaviour suite' -ForegroundColor Yellow }
    }
    Write-Host ''
    Write-Host 'would run:' -ForegroundColor Cyan
    if ($selected.Count -eq 0) { Write-Host '  (none)' }
    foreach ($n in $selected) { Write-Host "  $n" }
    exit 0
}

if ($Changed -and -not $changedInfo.Unknown -and $selected.Count -eq 0) {
    if ($changedInfo.DocsOnly) {
        Write-Host 'docs-only change: run tools\verify-package.ps1 -Fast'
    } else {
        Write-Host 'no changed files matched a behaviour suite; nothing to run' -ForegroundColor Yellow
    }
    exit 0
}

$autoRoot = -not [bool]$TestRoot
$runRoot = if ($TestRoot) { $TestRoot } else { Join-Path $env:TEMP ('hb-tests-' + [guid]::NewGuid().ToString('N').Substring(0, 8)) }
$tempPrefix = Join-Path $env:TEMP 'hb-tests-'
$isTempRoot = $runRoot.StartsWith($tempPrefix, [System.StringComparison]::OrdinalIgnoreCase)
$logsDir = Join-Path $runRoot '_logs'
New-Item -ItemType Directory -Force -Path $logsDir | Out-Null

$launchList = @($launchOrder | Where-Object { $selected -contains $_ })
foreach ($n in $selected) { if ($launchList -notcontains $n) { $launchList += $n } }

$max = if ($Serial) { 1 } elseif ($Throttle -gt 0) { $Throttle } else { [math]::Min(6, [Environment]::ProcessorCount) }
if ($max -lt 1) { $max = 1 }

$jobs = New-Object System.Collections.Generic.List[object]
$failed = 0
$keepRoot = $false
$scriptFailed = $false

function Update-JobState {
    foreach ($j in $jobs) {
        if ($j.Ended) { continue }
        if ($null -eq $j.Proc) { $j.End = Get-Date; $j.ExitCode = 1; $j.Ended = $true; continue }
        if ($j.Proc.HasExited) {
            $j.End = Get-Date
            # A Process object created through .NET keeps its exit code. The
            # Start-Process -PassThru object reports a null ExitCode unless
            # -Wait is used, and -Wait would serialize every suite.
            $j.ExitCode = $j.Proc.ExitCode
            $j.OutText = [string]$j.OutTask.Result
            $j.ErrText = [string]$j.ErrTask.Result
            [System.IO.File]::WriteAllText($j.Out, $j.OutText, (New-Object System.Text.UTF8Encoding($false)))
            [System.IO.File]::WriteAllText($j.Err, $j.ErrText, (New-Object System.Text.UTF8Encoding($false)))
            $j.Ended = $true
        }
    }
}

try {
    Write-Host ("run root: {0}" -f $runRoot) -ForegroundColor DarkGray
    Write-Host ("concurrency: {0}" -f $max) -ForegroundColor DarkGray

    foreach ($name in $launchList) {
        while (@($jobs | Where-Object { -not $_.Ended }).Count -ge $max) {
            Start-Sleep -Milliseconds 200
            Update-JobState
        }
        $suiteRoot = Join-Path $runRoot ($name -replace '\.ps1$', '')
        $outLog = Join-Path $logsDir ($name + '.out.log')
        $errLog = Join-Path $logsDir ($name + '.err.log')
        $path = Join-Path $PSScriptRoot $name
        Write-Host ("starting {0}" -f $name) -ForegroundColor Cyan
        try {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $PS
            $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $path + '" -TestRoot "' + $suiteRoot + '"'
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.StandardOutputEncoding = [System.Text.Encoding]::Default
            $psi.StandardErrorEncoding = [System.Text.Encoding]::Default
            $proc = New-Object System.Diagnostics.Process
            $proc.StartInfo = $psi
            [void]$proc.Start()
            # Read both pipes asynchronously: waiting first would deadlock once
            # a suite writes more than the pipe buffer.
            $outTask = $proc.StandardOutput.ReadToEndAsync()
            $errTask = $proc.StandardError.ReadToEndAsync()
            $jobs.Add([pscustomobject]@{
                Name = $name; Proc = $proc; Out = $outLog; Err = $errLog
                OutTask = $outTask; ErrTask = $errTask; OutText = ''; ErrText = ''
                Start = (Get-Date); End = $null; ExitCode = $null; Ended = $false
            })
        } catch {
            Write-Host ("FAILED: {0} could not start: {1}" -f $name, $_.Exception.Message) -ForegroundColor Red
            $now = Get-Date
            $jobs.Add([pscustomobject]@{
                Name = $name; Proc = $null; Out = $outLog; Err = $errLog
                OutTask = $null; ErrTask = $null; OutText = ''; ErrText = ''
                Start = $now; End = $now; ExitCode = 1; Ended = $true
            })
        }
    }

    while (@($jobs | Where-Object { -not $_.Ended }).Count -gt 0) {
        Start-Sleep -Milliseconds 200
        Update-JobState
    }

    # Original suite order, whether the suites ran serially or in parallel.
    $reportOrder = @($allSuites | Where-Object { $selected -contains $_ })
    foreach ($name in $reportOrder) {
        $job = @($jobs | Where-Object { $_.Name -eq $name })[0]
        Write-Host ""
        Write-Host "=== $name ===" -ForegroundColor Cyan
        Write-Host ("{0} finished in {1:N1}s (exit {2})" -f $name, (($job.End - $job.Start).TotalSeconds), $job.ExitCode) -ForegroundColor DarkGray
        foreach ($line in ($job.OutText -split "`r?`n")) { Write-Host $line }
        foreach ($line in ($job.ErrText -split "`r?`n")) {
            if ("$line".Length -gt 0) { Write-Host $line -ForegroundColor DarkYellow }
        }
    }

    foreach ($job in $jobs) {
        if ($job.ExitCode -eq 0) { continue }
        $failed++
        Write-Host ""
        Write-Host ("FAILED: {0} (exit {1})" -f $job.Name, $job.ExitCode) -ForegroundColor Red
        $logLines = @(($job.OutText -split "`r?`n")) + @(($job.ErrText -split "`r?`n"))
        $misses = @($logLines | Where-Object { $_ -match '^(FAIL|not ok|GATE-AUTO FAILURES|REGRESSION FAILURES|UPDATE TEST FAILURES|SKILLS REGISTRY TEST FAILED|AUDIT ORDER TEST FAILED|FAILED:)' })
        # Every failing assertion, not just the first three: one cause usually
        # trips several checks and the tail ones identify the step.
        $detail = if ($misses.Count -gt 0) { ($misses -join ' | ') } else { 'no FAIL line; run this suite locally' }
        $detail = $detail -replace '[\r\n]+', ' '
        if ($detail.Length -gt 900) { $detail = $detail.Substring(0, 900) }
        Write-Host ("::error title=$($job.Name) failed::$detail")
    }

    Write-Host ""
    Write-Host 'per-suite timing' -ForegroundColor Cyan
    $sumSeconds = 0
    $minStart = $null
    $maxEnd = $null
    foreach ($name in $reportOrder) {
        $job = @($jobs | Where-Object { $_.Name -eq $name })[0]
        $secs = ($job.End - $job.Start).TotalSeconds
        $sumSeconds += $secs
        if ($null -eq $minStart -or $job.Start -lt $minStart) { $minStart = $job.Start }
        if ($null -eq $maxEnd -or $job.End -gt $maxEnd) { $maxEnd = $job.End }
        Write-Host ("  {0,-24} exit {1,-3} {2,7:N1}s" -f $name, $job.ExitCode, $secs)
    }
    $wallSeconds = if ($null -ne $minStart -and $null -ne $maxEnd) { ($maxEnd - $minStart).TotalSeconds } else { 0 }
    Write-Host ("  {0,-24}          {1,7:N1}s" -f 'sum', $sumSeconds)
    Write-Host ("  {0,-24}          {1,7:N1}s" -f 'total wall', $wallSeconds)

    if ($KeepArtifacts -and $failed -gt 0) { $keepRoot = $true }
} catch {
    $scriptFailed = $true
    if ($KeepArtifacts) { $keepRoot = $true }
    throw
} finally {
    if ($KeepArtifacts -and ($failed -gt 0 -or $scriptFailed)) { $keepRoot = $true }
    if (-not $keepRoot) {
        if ($autoRoot -or $isTempRoot) {
            if (Test-Path -LiteralPath $runRoot) { Remove-Item -LiteralPath $runRoot -Recurse -Force -ErrorAction SilentlyContinue }
        } else {
            Write-Host ("custom -TestRoot kept: {0}" -f $runRoot) -ForegroundColor Yellow
        }
    }
}

if ($keepRoot) {
    Write-Host ""
    Write-Host ("artifacts kept: {0}" -f $runRoot) -ForegroundColor Yellow
}

Write-Host ""
if ($failed -gt 0) {
    Write-Host "TESTS FAILED: $failed suite(s)" -ForegroundColor Red
    exit 1
}
Write-Host 'ALL TESTS PASSED' -ForegroundColor Green
exit 0
