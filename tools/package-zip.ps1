<#
  package-zip.ps1 -- build dist\harness-bootstrap-<version>.zip

  WHY
    The release zip is the artifact another project consumes. Building it by hand
    let local-only folders in, and the meta-skill's own .trae\agents
    (harness-auditor) shipped with the package, where it looks like a fourth
    package-owned agent. Only assets\.trae\agents is installed into a project.
    This script keeps the include set in one place.

  WHAT GOES IN
    An allowlist, because a package is what another project installs, not a
    copy of this repository:
      SKILL.md, VERSION, LICENSE   the entry skill, its version, the license
      references/                  documents SKILL.md points at
      assets/                   scripts / rules / wiki / skills / agents
    Everything else stays in the repo: docs/ (site + 3.4 MB mermaid vendor),
    tests/ and tools/ (maintainer-only), .github/, README*, CONTRIBUTING.md,
    releases.json, the root .gitignore and the "why" essay. Humans who want
    those use the GitHub source archive.
    The zip root is harness-bootstrap\ and entry names use / (not \), so the
    archive unpacks correctly on non-Windows machines too.

  USAGE
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\package-zip.ps1
    ... -OutDir D:\somewhere\else

  EXIT CODE
    0 = zip written, 1 = VERSION unreadable or a copy/zip step failed

  NOTE
    Pure ASCII on purpose (PS 5.1 reads a BOM-less .ps1 as ANSI).
#>
param(
    [string]$OutDir = ''
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$versionLine = Get-Content -LiteralPath (Join-Path $root 'VERSION') -TotalCount 1 -Encoding UTF8
if ($versionLine -notmatch '(\d+\.\d+\.\d+)') {
    Write-Host "cannot read a x.y.z version from $root\VERSION" -ForegroundColor Red
    exit 1
}
$version = $matches[1]

$includeFiles = @('SKILL.md', 'VERSION', 'LICENSE')
$includeDirs = @('references', 'assets')

if (-not $OutDir) { $OutDir = Join-Path $root 'dist' }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$zipPath = Join-Path $OutDir ('harness-bootstrap-' + $version + '.zip')

$stage = Join-Path ([System.IO.Path]::GetTempPath()) ('hb-pack-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$dst = Join-Path $stage 'harness-bootstrap'

try {
    New-Item -ItemType Directory -Force -Path $dst | Out-Null
    foreach ($f in $includeFiles) {
        $src = Join-Path $root $f
        if (-not (Test-Path -LiteralPath $src -PathType Leaf)) {
            Write-Host "package input missing: $src" -ForegroundColor Red
            exit 1
        }
        Copy-Item -LiteralPath $src -Destination (Join-Path $dst $f)
    }
    foreach ($d in $includeDirs) {
        $src = Join-Path $root $d
        if (-not (Test-Path -LiteralPath $src -PathType Container)) {
            Write-Host "package input missing: $src" -ForegroundColor Red
            exit 1
        }
        Copy-Item -LiteralPath $src -Destination $dst -Recurse -Force
    }

    # Fail closed: a renamed SKILL.md or an accidental new top-level folder must
    # break the build here, not surface as a package that installs nothing.
    $allowed = @($includeFiles + $includeDirs)
    $extra = @(Get-ChildItem -LiteralPath $dst -Force | Where-Object { $allowed -notcontains $_.Name })
    if ($extra.Count -gt 0) {
        Write-Host ("unexpected top-level item in the package: " + (($extra | ForEach-Object { $_.Name }) -join ', ')) -ForegroundColor Red
        exit 1
    }

    if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
    Add-Type -AssemblyName System.IO.Compression
    $files = @(Get-ChildItem -LiteralPath $dst -Recurse -File -Force)
    $fs = [System.IO.File]::Open($zipPath, [System.IO.FileMode]::CreateNew)
    $zip = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($f in $files) {
            $rel = 'harness-bootstrap/' + $f.FullName.Substring($dst.Length + 1).Replace('\', '/')
            $entry = $zip.CreateEntry($rel, [System.IO.Compression.CompressionLevel]::Optimal)
            $out = $entry.Open()
            try {
                $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
                $out.Write($bytes, 0, $bytes.Length)
            } finally {
                $out.Dispose()
            }
        }
    } finally {
        $zip.Dispose()
        $fs.Dispose()
    }

    $size = (Get-Item -LiteralPath $zipPath).Length
    Write-Host "zip:      $zipPath"
    Write-Host "version:  $version"
    Write-Host "files:    $($files.Count)"
    Write-Host "size:     $size bytes"
    Write-Host ("included: " + (($includeFiles + ($includeDirs | ForEach-Object { $_ + '/' })) -join ', '))
} finally {
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
}
