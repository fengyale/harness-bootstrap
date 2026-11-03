<#
  update-harness.ps1 -- upgrade an installed harness without reinstalling

  WHY
    Re-running step 0 uses Copy-Missing: it never overwrites, so an existing
    project keeps old gate scripts forever. An upgrade needs explicit rules:
    replace package-owned machinery, never touch project assets or history.

  WHAT IT DOES (prints a plan unless -Apply is given)
    scripts/*.ps1, *.py    ADD or UPDATE (the old file is backed up first)
    scripts/*.json         ADD if missing; otherwise MANUAL (project config)
    .harness/rules         ADD missing only (project-owned)
    .harness/wiki          ADD missing only
    .harness/modules       ADD missing only
    .harness/skills        README missing -> ADD; installed skill files -> MANUAL,
                           or UPDATE when -UpdateSkills is given. Uninstalled
                           template skills are never added (the install keeps 3-5).
    .harness/changes       only _template is added when missing; history is kept
    AGENTS.md              MANUAL when it differs; never overwritten
    platform agents        ADD missing, MANUAL when different
    .gitignore             MANUAL when .harness/metrics/ or .harness/upgrade/ is absent
    .harness/.installed-version   written on -Apply

  USAGE
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\update-harness.ps1 `
      -PackagePath D:\path\to\new\harness-bootstrap
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\update-harness.ps1 `
      -PackagePath D:\path\to\new\harness-bootstrap -Apply
    ... -Apply -UpdateSkills
    ... -Apply -SkipHooks -SkipVerify

  EXIT CODE
    0 = dry-run completed, or apply finished and verification passed
    1 = invalid input, a copy failed, hook install failed, or verify failed

  NOTE
    Pure ASCII on purpose (PS 5.1 parses .ps1 as ANSI without a BOM).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PackagePath,
    [string]$Root = (Get-Location).Path,
    [switch]$Apply,
    [switch]$UpdateSkills,
    [switch]$SkipHooks,
    [switch]$SkipVerify
)

$ErrorActionPreference = 'Stop'

$rootPath = (Resolve-Path -LiteralPath $Root).Path
$pkgPath = (Resolve-Path -LiteralPath $PackagePath).Path
$templates = Join-Path $pkgPath 'templates'

# ---------------------------------------------------------------- validate
$versionFile = Join-Path $pkgPath 'VERSION'
if (-not (Test-Path -LiteralPath $versionFile)) {
    Write-Host "not a harness package (VERSION missing): $pkgPath" -ForegroundColor Red
    exit 1
}
if (-not (Test-Path -LiteralPath (Join-Path $templates 'scripts\stage-gate.ps1'))) {
    Write-Host "not a harness package (templates\scripts missing): $pkgPath" -ForegroundColor Red
    exit 1
}
if (-not (Test-Path -LiteralPath (Join-Path $rootPath '.harness'))) {
    Write-Host "not an installed harness (.harness missing): $rootPath" -ForegroundColor Red
    exit 1
}

$PS = if (Get-Command powershell -ErrorAction SilentlyContinue) { 'powershell' } else { 'pwsh' }

function Read-Version {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $line = Get-Content -LiteralPath $Path -TotalCount 1 -Encoding UTF8
    if ($line -match '(\d+\.\d+\.\d+)') { return $matches[1] }
    return $null
}

function Get-Hash {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

$newVersion = Read-Version $versionFile
if (-not $newVersion) {
    Write-Host "cannot read a x.y.z version from $versionFile" -ForegroundColor Red
    exit 1
}

# The marker is new; older installs do not have it. Fall back to the skill copy
# in the project so the first upgrade can still name the old version.
$installedVersion = Read-Version (Join-Path $rootPath '.harness\.installed-version')
if (-not $installedVersion) {
    foreach ($p in @(
        (Join-Path $rootPath '.trae\skills\harness-bootstrap\VERSION'),
        (Join-Path $rootPath '.claude\skills\harness-bootstrap\VERSION')
    )) {
        $installedVersion = Read-Version $p
        if ($installedVersion) { break }
    }
}
if (-not $installedVersion) { $installedVersion = 'unknown' }

# --------------------------------------------------------------- plan model
$plan = New-Object System.Collections.Generic.List[object]
function Add-Plan {
    param([string]$Action, [string]$Rel, [string]$Source, [string]$Detail)
    $plan.Add([pscustomobject]@{
        Action = $Action
        Rel    = $Rel
        Source = $Source
        Detail = $Detail
    })
}

# ------------------------------------------------------- scripts: machinery
# .ps1 is package-owned: replace it. *.json is project configuration (red
# lines, stage thresholds, required files), so it is never overwritten.
$srcScripts = Join-Path $templates 'scripts'
foreach ($src in Get-ChildItem -LiteralPath $srcScripts -File -Force) {
    $rel = 'scripts\' + $src.Name
    $dst = Join-Path $rootPath $rel
    if (-not (Test-Path -LiteralPath $dst)) {
        Add-Plan 'ADD' $rel $src.FullName 'new file'
        continue
    }
    $same = (Get-Hash $src.FullName) -eq (Get-Hash $dst)
    if ($same) { Add-Plan 'SAME' $rel $src.FullName ''; continue }
    if ($src.Extension -eq '.ps1' -or $src.Extension -eq '.py') {
        Add-Plan 'UPDATE' $rel $src.FullName 'package-owned script'
    } else {
        Add-Plan 'MANUAL' $rel $src.FullName 'project config may be edited; merge new keys by hand'
    }
}

# ------------------------------------------------- project assets: add only
foreach ($sub in @('rules', 'wiki', 'modules')) {
    $srcDir = Join-Path $templates ('.harness\' + $sub)
    if (-not (Test-Path -LiteralPath $srcDir)) { continue }
    # -Name returns paths relative to $srcDir. Building the relative path with
    # Substring(FullName, Length) breaks when the two forms use different short
    # (8.3) names, which is exactly what happens on GitHub Actions runners.
    foreach ($relPath in Get-ChildItem -LiteralPath $srcDir -Recurse -File -Force -Name) {
        $src = Join-Path $srcDir $relPath
        $rel = '.harness\' + $sub + '\' + $relPath
        $dst = Join-Path $rootPath $rel
        if (-not (Test-Path -LiteralPath $dst)) {
            Add-Plan 'ADD' $rel $src 'new project asset'
        } else {
            Add-Plan 'SKIP' $rel $src 'project-owned; kept as-is'
        }
    }
}

# ------------------------------------------- skills: installed bodies only
# The install deliberately keeps 3-5 skills, so a missing template skill is
# NOT added here. Only files the project already has are compared; with
# -UpdateSkills they are replaced (old copies go to .harness/upgrade).
$srcSkills = Join-Path $templates '.harness\skills'
if (Test-Path -LiteralPath $srcSkills) {
    $readmeSrc = Join-Path $srcSkills 'README.md'
    $readmeRel = '.harness\skills\README.md'
    $readmeDst = Join-Path $rootPath $readmeRel
    if (Test-Path -LiteralPath $readmeSrc) {
        if (-not (Test-Path -LiteralPath $readmeDst)) {
            Add-Plan 'ADD' $readmeRel $readmeSrc 'skill index missing'
        } elseif ((Get-Hash $readmeSrc) -eq (Get-Hash $readmeDst)) {
            Add-Plan 'SAME' $readmeRel $readmeSrc ''
        } elseif ($UpdateSkills) {
            Add-Plan 'UPDATE' $readmeRel $readmeSrc 'skill index replaced (-UpdateSkills)'
        } else {
            Add-Plan 'MANUAL' $readmeRel $readmeSrc 'installed skill index differs; re-run with -UpdateSkills to replace'
        }
    }
    # -Name avoids the short/long path mismatch noted above.
    foreach ($relPath in Get-ChildItem -LiteralPath $srcSkills -Recurse -File -Force -Name) {
        if ($relPath -eq 'README.md') { continue }
        $src = Join-Path $srcSkills $relPath
        $rel = '.harness\skills\' + $relPath
        $dst = Join-Path $rootPath $rel
        if (-not (Test-Path -LiteralPath $dst)) { continue }
        if ((Get-Hash $src) -eq (Get-Hash $dst)) {
            Add-Plan 'SAME' $rel $src ''
        } elseif ($UpdateSkills) {
            Add-Plan 'UPDATE' $rel $src 'installed skill replaced (-UpdateSkills)'
        } else {
            Add-Plan 'MANUAL' $rel $src 'installed skill differs; review or re-run with -UpdateSkills'
        }
    }
}

# Only the change template is added; real change records are history.
$srcTpl = Join-Path $templates '.harness\changes\_template'
if (Test-Path -LiteralPath $srcTpl) {
    foreach ($relPath in Get-ChildItem -LiteralPath $srcTpl -Recurse -File -Force -Name) {
        $src = Join-Path $srcTpl $relPath
        $rel = '.harness\changes\_template\' + $relPath
        $dst = Join-Path $rootPath $rel
        if (-not (Test-Path -LiteralPath $dst)) {
            Add-Plan 'ADD' $rel $src 'missing change template'
        } else {
            Add-Plan 'SKIP' $rel $src 'template exists; kept'
        }
    }
}
Add-Plan 'KEEP' '.harness\changes' '' 'task history is never touched'
Add-Plan 'KEEP' '.harness\metrics' '' 'gate log and promotion history are never touched'

# ------------------------------------------------------------- AGENTS.md
$srcAgents = Join-Path $templates 'AGENTS.md'
$dstAgents = Join-Path $rootPath 'AGENTS.md'
if (Test-Path -LiteralPath $srcAgents) {
    if (-not (Test-Path -LiteralPath $dstAgents)) {
        Add-Plan 'ADD' 'AGENTS.md' $srcAgents 'entry file missing'
    } elseif ((Get-Hash $srcAgents) -eq (Get-Hash $dstAgents)) {
        Add-Plan 'SAME' 'AGENTS.md' $srcAgents ''
    } else {
        Add-Plan 'MANUAL' 'AGENTS.md' $srcAgents 'merge new rows/sections by hand; never overwrite'
    }
}

# ------------------------------------------------------- platform agents
$agentRel = $null
if (Test-Path -LiteralPath (Join-Path $rootPath '.trae')) { $agentRel = '.trae\agents' }
elseif (Test-Path -LiteralPath (Join-Path $rootPath '.claude')) { $agentRel = '.claude\agents' }
$srcAgentsDir = Join-Path $templates '.trae\agents'
if (Test-Path -LiteralPath $srcAgentsDir) {
    if ($null -eq $agentRel) {
        Add-Plan 'MANUAL' '.trae/agents' $srcAgentsDir 'no platform dir found; copy agents by hand if needed'
    } else {
        foreach ($src in Get-ChildItem -LiteralPath $srcAgentsDir -File -Force) {
            $rel = $agentRel + '\' + $src.Name
            $dst = Join-Path $rootPath $rel
            if (-not (Test-Path -LiteralPath $dst)) {
                Add-Plan 'ADD' $rel $src.FullName 'new agent'
            } elseif ((Get-Hash $src.FullName) -eq (Get-Hash $dst)) {
                Add-Plan 'SAME' $rel $src.FullName ''
            } else {
                Add-Plan 'MANUAL' $rel $src.FullName 'may be edited by you; compare and merge'
            }
        }
    }
}

# ------------------------------------------------------------- .gitignore
$dstIgnore = Join-Path $rootPath '.gitignore'
$srcIgnore = Join-Path $templates '.gitignore'
if (-not (Test-Path -LiteralPath $dstIgnore)) {
    if (Test-Path -LiteralPath $srcIgnore) { Add-Plan 'ADD' '.gitignore' $srcIgnore 'missing file' }
} else {
    $lines = @([System.IO.File]::ReadAllLines($dstIgnore, [System.Text.Encoding]::UTF8) | ForEach-Object { $_.Trim() })
    $needed = @('.harness/metrics/', '.harness/upgrade/')
    $missingIgnore = @($needed | Where-Object { $lines -notcontains $_ })
    if ($missingIgnore.Count -eq 0) { Add-Plan 'SAME' '.gitignore' $srcIgnore '' }
    else { Add-Plan 'MANUAL' '.gitignore' $srcIgnore ('add by hand: ' + ($missingIgnore -join ', ')) }
}

# -------------------------------------------------------------------- print
Write-Host ''
Write-Host "update harness: $rootPath" -ForegroundColor Cyan
Write-Host "package:        $pkgPath"
Write-Host "version:        $installedVersion -> $newVersion"
Write-Host ("mode:           " + $(if ($Apply) { 'APPLY' } else { 'DRY-RUN (add -Apply to execute)' }))
Write-Host ('-' * 64)

$counts = @{ ADD = 0; UPDATE = 0; SAME = 0; SKIP = 0; MANUAL = 0; KEEP = 0 }
foreach ($p in $plan) {
    if ($p.Action -eq 'SAME') { continue }
    $counts[$p.Action]++
    $color = switch ($p.Action) {
        'UPDATE' { 'Yellow' }
        'ADD'    { 'Green' }
        'MANUAL' { 'Magenta' }
        'KEEP'   { 'DarkGray' }
        default  { 'Gray' }
    }
    Write-Host ("[{0}] {1}" -f $p.Action.PadRight(6), $p.Rel) -ForegroundColor $color
    if ($p.Detail) { Write-Host ("         " + $p.Detail) -ForegroundColor DarkGray }
}
Write-Host ('-' * 64)
Write-Host ("add={0} update={1} skip={2} manual={3} keep={4} same={5}" -f `
    $counts.ADD, $counts.UPDATE, $counts.SKIP, $counts.MANUAL, $counts.KEEP,
    @($plan | Where-Object { $_.Action -eq 'SAME' }).Count)

if (-not $Apply) {
    Write-Host ''
    Write-Host 'No file changed. Re-run with -Apply to execute the plan.' -ForegroundColor Yellow
    exit 0
}

# -------------------------------------------------------------------- apply
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backupRoot = Join-Path $rootPath ('.harness\upgrade\' + $stamp)
New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null
$manifest = New-Object System.Collections.Generic.List[string]
$failed = 0

foreach ($p in $plan) {
    if ($p.Action -eq 'ADD') {
        $dst = Join-Path $rootPath $p.Rel
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) | Out-Null
        try {
            Copy-Item -LiteralPath $p.Source -Destination $dst
            $manifest.Add(('ADD {0}' -f $p.Rel))
        } catch {
            Write-Host ("[FAIL] copy {0}: {1}" -f $p.Rel, $_.Exception.Message) -ForegroundColor Red
            $failed++
        }
    } elseif ($p.Action -eq 'UPDATE') {
        $dst = Join-Path $rootPath $p.Rel
        $bak = Join-Path $backupRoot $p.Rel
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $bak) | Out-Null
        try {
            Copy-Item -LiteralPath $dst -Destination $bak
            Copy-Item -LiteralPath $p.Source -Destination $dst -Force
            $manifest.Add(('UPDATE {0} (old copy in backup)' -f $p.Rel))
        } catch {
            Write-Host ("[FAIL] update {0}: {1}" -f $p.Rel, $_.Exception.Message) -ForegroundColor Red
            $failed++
        }
    }
}

$manifestPath = Join-Path $backupRoot 'manifest.txt'
$manifestLines = @(
    ('harness upgrade {0} -> {1}' -f $installedVersion, $newVersion),
    ('applied: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')),
    ''
) + $manifest
Set-Content -LiteralPath $manifestPath -Value $manifestLines -Encoding ASCII

# The marker lets the next upgrade name the version it starts from.
$marker = Join-Path $rootPath '.harness\.installed-version'
Set-Content -LiteralPath $marker -Value @(
    $newVersion,
    ('updated: ' + (Get-Date -Format 'yyyy-MM-dd'))
) -Encoding ASCII

if (-not $SkipHooks) {
    $hookScript = Join-Path $rootPath 'scripts\install-git-hooks.ps1'
    if (Test-Path -LiteralPath $hookScript) {
        Write-Host ''
        Write-Host 'reinstalling git hooks ...' -ForegroundColor Cyan
        & $PS -NoProfile -ExecutionPolicy Bypass -File $hookScript -Root $rootPath
        if ($LASTEXITCODE -ne 0) {
            Write-Host 'hook install failed' -ForegroundColor Red
            $failed++
        }
    } else {
        Write-Host 'scripts\install-git-hooks.ps1 is missing; hooks not reinstalled' -ForegroundColor Yellow
        $failed++
    }
}

if (-not $SkipVerify) {
    $verify = Join-Path $rootPath 'scripts\verify-harness.ps1'
    if (Test-Path -LiteralPath $verify) {
        Write-Host ''
        Write-Host 'verify-harness ...' -ForegroundColor Cyan
        & $PS -NoProfile -ExecutionPolicy Bypass -File $verify -Root $rootPath
        if ($LASTEXITCODE -ne 0) {
            Write-Host 'verify-harness reported failures' -ForegroundColor Red
            $failed++
        }
    } else {
        Write-Host 'scripts\verify-harness.ps1 is missing; verification skipped' -ForegroundColor Yellow
    }
}

Write-Host ''
if ($failed -gt 0) {
    Write-Host ("UPDATE FINISHED WITH {0} FAILURE(S); see messages above" -f $failed) -ForegroundColor Red
    exit 1
}
Write-Host ("UPDATE OK: {0} -> {1}; backup: {2}" -f $installedVersion, $newVersion, $backupRoot) -ForegroundColor Green
exit 0
