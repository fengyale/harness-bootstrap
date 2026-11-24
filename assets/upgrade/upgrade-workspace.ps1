<#
  upgrade-workspace.ps1 -- one upgrade across every repository in a workspace

  WHY
    A product with a backend and a frontend installs the harness per repository.
    Upgrading only the repository the operator remembered leaves the other one on
    old rules, old scripts and a different .installed-version. The manifest makes
    the set explicit, and this script drives the same new-package bootstrap for
    every entry so no repository is silently skipped.

  INPUT
    harness.workspace.json (default: <Root>\harness.workspace.json)
      {
        "repos": [
          { "name": "backend", "path": ".", "role": "record-owner" },
          { "name": "web", "path": "..\\product-web", "role": "consumer" }
        ]
      }
    path is resolved relative to the manifest file. role is informational.

  WHAT IT DOES
    - a repository without .harness is SKIPPED, or receives the template copy
      when -Install is given (AGENTS.md and skills still need compiling)
    - a repository with .harness runs the new package's upgrade-harness.ps1;
      -Apply only when given, and -MergeSkills / -SkipHooks / -SkipVerify /
      -SkipReport are forwarded unchanged
    - prints one summary row per repository and compares .installed-version

  STRICT
    exit 1 when any repository fails, when -Apply left a report [MISSING], or
    when the repositories end up on different installed versions. MANUAL rows do
    not fail: they are project-owned steps, same as upgrade-report.ps1.

  USAGE
    powershell -NoProfile -ExecutionPolicy Bypass -File assets\upgrade\upgrade-workspace.ps1 -Root .
    ... -Root . -Install -Apply -MergeSkills -Strict
    ... -Root . -Manifest D:\ws\harness.workspace.json

  EXIT CODE
    0 = every repository processed; 1 = failure, missing artifact or drift

  NOTE
    Pure ASCII on purpose (PS 5.1 parses a BOM-less .ps1 as ANSI).
#>
[CmdletBinding()]
param(
    [string]$Root = (Get-Location).Path,
    [string]$Manifest = '',
    [string]$PackagePath = '',
    [switch]$Apply,
    [switch]$MergeSkills,
    [switch]$Install,
    [switch]$Strict,
    [switch]$SkipHooks,
    [switch]$SkipVerify,
    [switch]$SkipReport
)

$ErrorActionPreference = 'Stop'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$PS = if (Get-Command powershell -ErrorAction SilentlyContinue) { 'powershell' } else { 'pwsh' }

if (-not $PackagePath -or $PackagePath.Trim() -eq '') {
    $PackagePath = Join-Path (Join-Path $PSScriptRoot '..') '..'
}
$PackagePath = (Resolve-Path -LiteralPath $PackagePath).Path
$bootstrap = Join-Path $PackagePath 'assets\upgrade\upgrade-harness.ps1'
if (-not (Test-Path -LiteralPath $bootstrap)) {
    Write-Host ('[FAIL] missing ' + $bootstrap + ' (run this script from a current package)') -ForegroundColor Red
    exit 1
}

try { $rootPath = (Resolve-Path -LiteralPath $Root).Path }
catch {
    Write-Host ('[FAIL] workspace root not found: ' + $Root) -ForegroundColor Red
    exit 1
}
if (-not $Manifest) { $Manifest = Join-Path $rootPath 'harness.workspace.json' }
if (-not (Test-Path -LiteralPath $Manifest)) {
    Write-Host ('[FAIL] workspace manifest not found: ' + $Manifest) -ForegroundColor Red
    Write-Host ('       create one from assets\upgrade\harness.workspace.example.json') -ForegroundColor Yellow
    exit 1
}
$manifestPath = (Resolve-Path -LiteralPath $Manifest).Path
$wsDir = Split-Path -Parent $manifestPath
try { $cfg = (Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8) | ConvertFrom-Json }
catch {
    Write-Host ('[FAIL] manifest is not valid JSON: ' + $manifestPath) -ForegroundColor Red
    exit 1
}
$repos = @($cfg.repos)
if ($repos.Count -eq 0) {
    Write-Host ('[FAIL] manifest has no repos: ' + $manifestPath) -ForegroundColor Red
    exit 1
}

# Copy only what is missing: an existing project file is never overwritten by an
# install, so a half-installed repository can be completed without data loss.
function Copy-MissingTree {
    param([string]$SrcPath, [string]$DstPath)
    if (-not (Test-Path -LiteralPath $SrcPath)) { return }
    if (-not (Test-Path -LiteralPath $DstPath)) { New-Item -ItemType Directory -Force -Path $DstPath | Out-Null }
    foreach ($item in @(Get-ChildItem -LiteralPath $SrcPath -Force)) {
        $target = Join-Path $DstPath $item.Name
        if ($item.PSIsContainer) { Copy-MissingTree -SrcPath $item.FullName -DstPath $target }
        elseif (-not (Test-Path -LiteralPath $target)) { Copy-Item -LiteralPath $item.FullName -Destination $target }
    }
}

function Install-Template {
    param([string]$RepoPath)
    Copy-MissingTree -SrcPath (Join-Path $PackagePath 'assets\scripts') -DstPath (Join-Path $RepoPath 'scripts')
    foreach ($d in @('rules', 'wiki', 'modules', 'changes')) {
        Copy-MissingTree -SrcPath (Join-Path $PackagePath ('assets\.harness\' + $d)) `
            -DstPath (Join-Path $RepoPath ('.harness\' + $d))
    }
    $srcReadme = Join-Path $PackagePath 'assets\.harness\skills\README.md'
    $dstReadme = Join-Path $RepoPath '.harness\skills\README.md'
    if ((Test-Path -LiteralPath $srcReadme) -and -not (Test-Path -LiteralPath $dstReadme)) {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dstReadme) | Out-Null
        Copy-Item -LiteralPath $srcReadme -Destination $dstReadme
    }
    foreach ($f in @('AGENTS.md', '.gitignore')) {
        $srcFile = Join-Path $PackagePath ('assets\' + $f)
        $dstFile = Join-Path $RepoPath $f
        if ((Test-Path -LiteralPath $srcFile) -and -not (Test-Path -LiteralPath $dstFile)) {
            Copy-Item -LiteralPath $srcFile -Destination $dstFile
        }
    }
    $verLine = @(Get-Content -LiteralPath (Join-Path $PackagePath 'VERSION') -TotalCount 1 -Encoding UTF8)[0]
    $ver = ([string]$verLine -replace '^.*VERSION\s+', '').Trim()
    $marker = Join-Path $RepoPath '.harness\.installed-version'
    if (-not (Test-Path -LiteralPath $marker)) {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $marker) | Out-Null
        [System.IO.File]::WriteAllText($marker, ($ver + "`n"), $Utf8NoBom)
    }
}

$failed = $false
$summaries = New-Object System.Collections.Generic.List[object]
$versionRows = New-Object System.Collections.Generic.List[object]

foreach ($repo in $repos) {
    $name = [string]$repo.name
    $rel = [string]$repo.path
    if (-not $rel) {
        Write-Host '[FAIL] manifest entry without path' -ForegroundColor Red
        $failed = $true
        continue
    }
    if (-not $name) { $name = $rel }
    $repoPath = if ([System.IO.Path]::IsPathRooted($rel)) { $rel } else { [System.IO.Path]::GetFullPath((Join-Path $wsDir $rel)) }
    if (-not (Test-Path -LiteralPath $repoPath -PathType Container)) {
        Write-Host ('[FAIL] ' + $name + ': not a directory: ' + $repoPath) -ForegroundColor Red
        $failed = $true
        continue
    }

    Write-Host ''
    Write-Host ('=== ' + $name + ' (' + $repoPath + ') ===') -ForegroundColor Cyan
    $action = 'skip'
    $code = 0
    $out = @()
    $hasHarness = Test-Path -LiteralPath (Join-Path $repoPath '.harness')

    if (-not $hasHarness -and $Install) {
        Install-Template -RepoPath $repoPath
        $action = 'install'
        Write-Host '[INSTALL] template copied; compile AGENTS.md and skills before the first task' -ForegroundColor Yellow
    } elseif (-not $hasHarness) {
        $action = 'skip'
        Write-Host '[SKIP] no .harness yet; pass -Install to copy the template' -ForegroundColor Yellow
    } else {
        $argList = @('-Root', $repoPath, '-PackagePath', $PackagePath)
        if ($Apply) { $argList += '-Apply' }
        if ($MergeSkills) { $argList += '-MergeSkills' }
        if ($SkipHooks) { $argList += '-SkipHooks' }
        if ($SkipVerify) { $argList += '-SkipVerify' }
        if ($SkipReport) { $argList += '-SkipReport' }
        $out = @(& $PS -NoProfile -ExecutionPolicy Bypass -File $bootstrap @argList 2>&1 | ForEach-Object { "$_" })
        $code = $LASTEXITCODE
        $out | Out-Host
        $action = if ($Apply) { 'upgrade' } else { 'dry-run' }
    }

    $active = @($out | Where-Object { $_ -match '\[ACTIVE\]' }).Count
    $manual = @($out | Where-Object { $_ -match '\[MANUAL\]' }).Count
    $missing = @($out | Where-Object { $_ -match '\[MISSING\]' }).Count
    if ($code -ne 0) { $failed = $true }
    if ($Strict -and $missing -gt 0) { $failed = $true }

    $installed = ''
    $marker = Join-Path $repoPath '.harness\.installed-version'
    if (Test-Path -LiteralPath $marker) {
        $lines = @([System.IO.File]::ReadAllLines($marker, [System.Text.Encoding]::UTF8))
        if ($lines.Count -gt 0) { $installed = $lines[0].Trim() }
    }
    if ($installed) { $versionRows.Add([pscustomobject]@{ Name = $name; Version = $installed }) }

    $summaries.Add([pscustomobject]@{
        Name = $name; Action = $action; Code = $code
        Active = $active; Manual = $manual; Missing = $missing; Version = $installed
    })
}

Write-Host ''
Write-Host '=== workspace summary ===' -ForegroundColor Cyan
foreach ($s in $summaries) {
    $line = '  {0,-14} {1,-8} exit={2}' -f $s.Name, $s.Action, $s.Code
    if (($s.Active + $s.Manual + $s.Missing) -gt 0) {
        $line += ('  report: {0} ACTIVE / {1} MANUAL / {2} MISSING' -f $s.Active, $s.Manual, $s.Missing)
    }
    if ($s.Version) { $line += ('  installed=' + $s.Version) }
    Write-Host $line
}

$distinct = @($versionRows.ToArray() | ForEach-Object { $_.Version } | Sort-Object -Unique)
if ($distinct.Count -gt 1) {
    Write-Host ('[WARN] repositories are on different harness versions: ' + ($distinct -join ', ')) -ForegroundColor Yellow
    if ($Strict) { $failed = $true }
}

if ($failed) {
    Write-Host 'workspace: FAILED' -ForegroundColor Red
    exit 1
}
Write-Host 'workspace: OK' -ForegroundColor Green
exit 0
