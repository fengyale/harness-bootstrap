<#
  package-zip.ps1 -- build dist\harness-bootstrap-<version>.zip

  WHY
    The release zip is the artifact another project consumes. Building it by hand
    let local-only folders in, and the meta-skill's own .trae\agents
    (harness-auditor) shipped with the package, where it looks like a fourth
    package-owned agent. Only templates\.trae\agents is installed into a project.
    This script keeps the include set in one place.

  WHAT GOES IN
    Every top-level item except:
      .git .idea .screenshots dist   local / IDE state, never shipped
      .trae                          the meta-skill's own audit agent
      .trae-html-share-packages      local share cache
      TODO-*.md                      internal notes
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

$skipDirs = @('.git', '.idea', '.screenshots', 'dist', '.trae', '.trae-html-share-packages')
# Root AGENTS.md is the maintainer's own copy; the product one is
# templates\AGENTS.md. Shipping both would install a stale duplicate.
$skipFiles = @('AGENTS.md')
$skipFilePattern = 'TODO-*.md'

if (-not $OutDir) { $OutDir = Join-Path $root 'dist' }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$zipPath = Join-Path $OutDir ('harness-bootstrap-' + $version + '.zip')

$stage = Join-Path ([System.IO.Path]::GetTempPath()) ('hb-pack-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$dst = Join-Path $stage 'harness-bootstrap'

try {
    New-Item -ItemType Directory -Force -Path $dst | Out-Null
    foreach ($item in @(Get-ChildItem -LiteralPath $root -Force)) {
        if ($item.PSIsContainer -and ($skipDirs -contains $item.Name)) { continue }
        if (-not $item.PSIsContainer -and ($skipFiles -contains $item.Name)) { continue }
        if (-not $item.PSIsContainer -and $item.Name -like $skipFilePattern) { continue }
        Copy-Item -LiteralPath $item.FullName -Destination $dst -Recurse -Force
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
    Write-Host ("excluded: " + (($skipDirs + $skipFiles) -join ', ') + ', ' + $skipFilePattern)
} finally {
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
}
