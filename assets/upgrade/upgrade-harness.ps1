<#
  upgrade-harness.ps1 -- run the NEW package's upgrade from inside the package

  WHY
    scripts\update-harness.ps1 is installed into the project and therefore gets
    older with the project. Running the old copy against a new package can lack
    the merge rules the new package relies on. This bootstrap entry lives in the
    new package, so the upgrade always uses the new upgrader and only falls back
    to the project copy if the package one cannot be found -- which never happens
    because it is validated below.

  WHAT IT DOES
    validates the package (VERSION, assets\scripts\update-harness.ps1; the
    activation report is advisory and may be absent)
    runs <PackagePath>\assets\scripts\update-harness.ps1 -Root <Root> -PackagePath <PackagePath>
    forwards -Apply only when given, plus the skills/hooks/backup/verify switches
    after an APPLIED upgrade, runs <PackagePath>\assets\scripts\upgrade-report.ps1 -Root <Root>
    unless -SkipReport is given (a dry run prints "report skipped" instead: its
    pre-upgrade state would read like a failed upgrade)
    a missing upgrade-report.ps1 only warns; it is advisory

  USAGE
    powershell -NoProfile -ExecutionPolicy Bypass -File assets\upgrade\upgrade-harness.ps1 -Root D:\proj
    ... -Root D:\proj -Apply
    ... -Root D:\proj -Apply -MergeSkills
    ... -Root D:\proj -Apply -SkipVerify -SkipReport
    ... -SelfTest

  EXIT CODE
    0 = upgrade command succeeded; non-zero = same failure as the package updater

  NOTE
    Pure ASCII on purpose (PS 5.1 parses .ps1 as ANSI without a BOM).
#>
[CmdletBinding()]
param(
    [string]$Root = '',
    [string]$PackagePath = '',
    [switch]$Apply,
    [switch]$MergeSkills,
    [switch]$UpdateSkills,
    [switch]$ForceSkills,
    [switch]$SkipHooks,
    [switch]$KeepBackup,
    [switch]$PruneBackups,
    [switch]$KeepL1,
    [switch]$NoMergeKnown,
    [switch]$SkipVerify,
    [switch]$SkipReport,
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'

# $PSScriptRoot is not reliably bound inside param defaults on PS 5.1, so the
# package root is derived here: assets\upgrade -> package root.
if (-not $PackagePath -or $PackagePath.Trim() -eq '') {
    $PackagePath = Join-Path (Join-Path $PSScriptRoot '..') '..'
}

$PS = if (Get-Command powershell -ErrorAction SilentlyContinue) { 'powershell' } else { 'pwsh' }

function Invoke-UpgradeHarnessSelfTest {
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('hb-upgrade-harness-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $fails = New-Object System.Collections.Generic.List[string]
    $utf8 = New-Object System.Text.UTF8Encoding($false)

    function Assert-Case {
        param([string]$Name, [bool]$Ok)
        if ($Ok) { Write-Host ('ok: ' + $Name) }
        else { Write-Host ('[FAIL] ' + $Name) -ForegroundColor Red; $fails.Add($Name) }
    }
    function Write-Lines {
        param([string]$Path, [string[]]$Lines)
        $dir = Split-Path -Parent $Path
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        [System.IO.File]::WriteAllLines($Path, $Lines, $utf8)
    }
    function Invoke-UnderTest {
        param([string]$ProjRoot, [string]$PkgRoot, [string[]]$ExtraArgs)
        $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, '-Root', $ProjRoot, '-PackagePath', $PkgRoot) + $ExtraArgs
        $out = & $PS @argList 2>&1 | Out-String
        return [pscustomobject]@{ Code = $LASTEXITCODE; Text = $out }
    }
    function Read-Marker {
        param([string]$Path)
        if (-not (Test-Path -LiteralPath $Path)) { return '' }
        return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    }

    try {
        $pkg = Join-Path $tmp 'pkg'
        $proj = Join-Path $tmp 'proj'
        New-Item -ItemType Directory -Force -Path (Join-Path $pkg 'assets\scripts') | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $proj 'scripts') | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $pkg 'VERSION'), 'VERSION 9.9.9' + "`n", $utf8)

        Write-Lines (Join-Path $pkg 'assets\scripts\update-harness.ps1') @(
            'param(',
            '    [string]$Root,',
            '    [string]$PackagePath,',
            '    [switch]$Apply,',
            '    [switch]$MergeSkills,',
            '    [switch]$UpdateSkills,',
            '    [switch]$ForceSkills,',
            '    [switch]$SkipHooks,',
            '    [switch]$KeepBackup,',
            '    [switch]$PruneBackups,',
            '    [switch]$KeepL1,',
            '    [switch]$NoMergeKnown,',
            '    [switch]$SkipVerify',
            ')',
            '$flags = @()',
            'if ($Apply) { $flags += ''apply'' }',
            'if ($MergeSkills) { $flags += ''mergeskills'' }',
            'if ($UpdateSkills) { $flags += ''updateskills'' }',
            'if ($ForceSkills) { $flags += ''forceskills'' }',
            'if ($SkipHooks) { $flags += ''skiphooks'' }',
            'if ($KeepBackup) { $flags += ''keepbackup'' }',
            'if ($PruneBackups) { $flags += ''prunebackups'' }',
            'if ($KeepL1) { $flags += ''keepl1'' }',
            'if ($NoMergeKnown) { $flags += ''nomergeknown'' }',
            'if ($SkipVerify) { $flags += ''skipverify'' }',
            '[System.IO.File]::WriteAllText((Join-Path $Root ''new-updater-ran.txt''), (''flags='' + ($flags -join '','') + "`n"), (New-Object System.Text.UTF8Encoding($false)))',
            'exit 0'
        )
        Write-Lines (Join-Path $pkg 'assets\scripts\upgrade-report.ps1') @(
            'param([string]$Root)',
            '[System.IO.File]::WriteAllText((Join-Path $Root ''report-ran.txt''), "report`n", (New-Object System.Text.UTF8Encoding($false)))',
            'exit 0'
        )
        # The project's own (old) updater must never be touched by the bootstrap.
        Write-Lines (Join-Path $proj 'scripts\update-harness.ps1') @(
            'param([string]$Root = ''.'', [string]$PackagePath = '''')',
            '[System.IO.File]::WriteAllText((Join-Path $Root ''old-updater-ran.txt''), "old`n", (New-Object System.Text.UTF8Encoding($false)))',
            'exit 0'
        )

        $newMarker = Join-Path $proj 'new-updater-ran.txt'
        $oldMarker = Join-Path $proj 'old-updater-ran.txt'
        $reportMarker = Join-Path $proj 'report-ran.txt'

        $r = Invoke-UnderTest -ProjRoot $proj -PkgRoot $pkg -ExtraArgs @('-SkipReport')
        Assert-Case 'dry run exits 0' ($r.Code -eq 0)
        Assert-Case 'bootstrap says the project updater is bypassed' ($r.Text -match 'project updater bypassed')
        Assert-Case 'the new package updater ran' (Test-Path -LiteralPath $newMarker)
        Assert-Case 'the project old updater did not run' (-not (Test-Path -LiteralPath $oldMarker))
        Assert-Case 'dry run does not pass -Apply' ((Read-Marker $newMarker) -notmatch '(^|,|=)apply(,|$)')
        Assert-Case '-SkipReport suppresses the activation report' (-not (Test-Path -LiteralPath $reportMarker))

        Remove-Item -LiteralPath $newMarker -Force -ErrorAction SilentlyContinue
        $r = Invoke-UnderTest -ProjRoot $proj -PkgRoot $pkg -ExtraArgs @('-Apply', '-SkipReport')
        Assert-Case 'apply exits 0' ($r.Code -eq 0)
        Assert-Case 'apply passes -Apply to the new updater' ((Read-Marker $newMarker) -match '(^|,|=)apply(,|$)')
        Assert-Case 'apply still leaves the old updater untouched' (-not (Test-Path -LiteralPath $oldMarker))

        # A dry run must not show the report: its pre-upgrade state reads like a
        # failed upgrade to an operator who only asked for a plan.
        Remove-Item -LiteralPath $newMarker, $reportMarker -Force -ErrorAction SilentlyContinue
        $r = Invoke-UnderTest -ProjRoot $proj -PkgRoot $pkg -ExtraArgs @()
        Assert-Case 'dry run without -Apply exits 0' ($r.Code -eq 0)
        Assert-Case 'dry run prints that the report is skipped' ($r.Text -match 'report: dry run')
        Assert-Case 'dry run never runs the activation report' (-not (Test-Path -LiteralPath $reportMarker))

        Remove-Item -LiteralPath $newMarker, $reportMarker -Force -ErrorAction SilentlyContinue
        $r = Invoke-UnderTest -ProjRoot $proj -PkgRoot $pkg -ExtraArgs @('-Apply', '-PruneBackups')
        Assert-Case 'apply with report exits 0' ($r.Code -eq 0)
        Assert-Case 'the activation report runs after an applied upgrade' (Test-Path -LiteralPath $reportMarker)
        Assert-Case '-PruneBackups is forwarded to the new updater' ((Read-Marker $newMarker) -match 'prunebackups')

        # ---------------------------------------------------------- failures
        $failPkg = Join-Path $tmp 'pkgfail'
        New-Item -ItemType Directory -Force -Path (Join-Path $failPkg 'assets\scripts') | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $failPkg 'VERSION'), 'VERSION 9.9.9' + "`n", $utf8)
        Write-Lines (Join-Path $failPkg 'assets\scripts\update-harness.ps1') @(
            'param([string]$Root, [string]$PackagePath, [switch]$Apply, [switch]$PruneBackups, [switch]$SkipVerify)',
            'exit 7'
        )
        Write-Lines (Join-Path $failPkg 'assets\scripts\upgrade-report.ps1') @(
            'param([string]$Root)',
            '[System.IO.File]::WriteAllText((Join-Path $Root ''report-ran.txt''), "report`n", (New-Object System.Text.UTF8Encoding($false)))',
            'exit 0'
        )
        Remove-Item -LiteralPath $newMarker, $reportMarker -Force -ErrorAction SilentlyContinue
        $r = Invoke-UnderTest -ProjRoot $proj -PkgRoot $failPkg -ExtraArgs @('-Apply')
        Assert-Case 'a failing updater keeps its exit code' ($r.Code -eq 7)
        Assert-Case 'a failing updater never runs the report' (-not (Test-Path -LiteralPath $reportMarker))

        $emptyPkg = Join-Path $tmp 'emptypkg'
        New-Item -ItemType Directory -Force -Path $emptyPkg | Out-Null
        $r = Invoke-UnderTest -ProjRoot $proj -PkgRoot $emptyPkg -ExtraArgs @()
        Assert-Case 'an empty package directory exits 1' ($r.Code -eq 1)
        $r = Invoke-UnderTest -ProjRoot $proj -PkgRoot $proj -ExtraArgs @()
        Assert-Case 'a project root used as a package exits 1' ($r.Code -eq 1)

        # The report is advisory: a package without it still upgrades.
        $noReportPkg = Join-Path $tmp 'pkgnoreport'
        New-Item -ItemType Directory -Force -Path (Join-Path $noReportPkg 'assets\scripts') | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $noReportPkg 'VERSION'), 'VERSION 9.9.9' + "`n", $utf8)
        Write-Lines (Join-Path $noReportPkg 'assets\scripts\update-harness.ps1') @(
            'param([string]$Root, [string]$PackagePath, [switch]$Apply)',
            'exit 0'
        )
        $r = Invoke-UnderTest -ProjRoot $proj -PkgRoot $noReportPkg -ExtraArgs @('-Apply')
        Assert-Case 'a package without upgrade-report.ps1 still applies' ($r.Code -eq 0)
        Assert-Case 'a missing report script only warns' ($r.Text -match 'activation report will be skipped')
    } finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }

    if ($fails.Count -gt 0) {
        Write-Host ('UPGRADE-HARNESS SELFTEST FAILED: ' + $fails.Count + ' case(s)') -ForegroundColor Red
        return 1
    }
    Write-Host 'UPGRADE-HARNESS SELFTEST OK' -ForegroundColor Green
    return 0
}

if ($SelfTest) {
    exit (Invoke-UpgradeHarnessSelfTest)
}

if (-not $Root -or $Root.Trim() -eq '') {
    Write-Host 'usage: upgrade-harness.ps1 -Root <project> [-PackagePath <package>] [-Apply] [-MergeSkills] [-SkipReport]' -ForegroundColor Red
    exit 1
}

try {
    $rootFull = (Resolve-Path -LiteralPath $Root).Path
} catch {
    Write-Host ('project root not found: ' + $Root) -ForegroundColor Red
    exit 1
}
try {
    $pkgFull = (Resolve-Path -LiteralPath $PackagePath).Path
} catch {
    Write-Host ('package path not found: ' + $PackagePath) -ForegroundColor Red
    exit 1
}

$updater = Join-Path $pkgFull 'assets\scripts\update-harness.ps1'
$report = Join-Path $pkgFull 'assets\scripts\upgrade-report.ps1'
$versionFile = Join-Path $pkgFull 'VERSION'

if (-not (Test-Path -LiteralPath $versionFile -PathType Leaf)) {
    Write-Host ('not a harness package (VERSION missing): ' + $pkgFull) -ForegroundColor Red
    exit 1
}
if (-not (Test-Path -LiteralPath $updater -PathType Leaf)) {
    Write-Host ('not a harness package (assets\scripts\update-harness.ps1 missing): ' + $pkgFull) -ForegroundColor Red
    exit 1
}
# The activation report is advisory: a package that predates it still upgrades.
if (-not (Test-Path -LiteralPath $report -PathType Leaf)) {
    Write-Host ('[WARN] package has no assets\scripts\upgrade-report.ps1; the activation report will be skipped') -ForegroundColor Yellow
    $report = $null
}

Write-Host "bootstrap: running the new package's update-harness.ps1 (project updater bypassed)" -ForegroundColor Cyan

$argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $updater, '-Root', $rootFull, '-PackagePath', $pkgFull)
if ($Apply) { $argList += '-Apply' }
if ($MergeSkills) { $argList += '-MergeSkills' }
if ($UpdateSkills) { $argList += '-UpdateSkills' }
if ($ForceSkills) { $argList += '-ForceSkills' }
if ($SkipHooks) { $argList += '-SkipHooks' }
if ($KeepBackup) { $argList += '-KeepBackup' }
if ($PruneBackups) { $argList += '-PruneBackups' }
if ($KeepL1) { $argList += '-KeepL1' }
if ($NoMergeKnown) { $argList += '-NoMergeKnown' }
if ($SkipVerify) { $argList += '-SkipVerify' }

& $PS @argList
$upgradeCode = $LASTEXITCODE

if ($upgradeCode -ne 0) {
    Write-Host ('upgrade failed (exit ' + $upgradeCode + '); activation report skipped') -ForegroundColor Red
    exit $upgradeCode
}

if (-not $Apply) {
    if (-not $SkipReport) {
        Write-Host 'report: dry run (pre-upgrade state); skipped' -ForegroundColor Yellow
    }
    exit 0
}

if (-not $SkipReport -and $report) {
    Write-Host ''
    & $PS -NoProfile -ExecutionPolicy Bypass -File $report -Root $rootFull
    # The report is advisory: its exit code never changes the upgrade result.
}

exit 0
