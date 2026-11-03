<#
  setup-links.ps1 -- mount every skill under .harness/skills into .trae/skills

  TRUE SOURCE   .harness/skills/<category>/<skill>/SKILL.md
  PLATFORM ENTRY .trae/skills/<skill>        <- directory junction (just another name)

  WHY
    .trae/skills/ is scanned one level deep, so every skill needs a directory
    directly under it. Junctions do not travel with git, so run this once per
    machine / per fresh clone. Nothing is copied: the junction is an alias.

  ENCODING NOTE
    Pure ASCII on purpose. Windows PowerShell 5.1 reads .ps1 as ANSI unless it has
    a UTF-8 BOM, so Chinese text inside a script would break parsing.

  USAGE  (no pwsh on this machine; execution policy blocks unsigned scripts,
          so -ExecutionPolicy Bypass is REQUIRED)
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\setup-links.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\setup-links.ps1 -WhatIf
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\setup-links.ps1 -Root D:\proj

  NON-WINDOWS
    Replace the "cmd /c mklink /J" call with "ln -s"; the rest is the same.
    Or skip links entirely and use index-only mode (.harness/skills/INDEX.md).

  PLATFORM
    -Dest selects the discovery directory of the platform:
      TRAE         -> .trae\skills   (default)
      Claude Code  -> .claude\skills
      others       -> skip this script and generate .harness\skills\INDEX.md instead
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$Root = (Get-Location).Path,
    [string]$Dest = '.trae/skills',
    [ValidateSet('auto', 'junction', 'copy')]
    [string]$Mode = 'auto'
)

$ErrorActionPreference = 'Stop'

$root    = (Resolve-Path -LiteralPath $Root).Path
$srcRoot = Join-Path $root '.harness\skills'
$dstRoot = Join-Path $root $Dest

if (-not (Test-Path -LiteralPath $srcRoot)) {
    throw "Skill source directory not found: $srcRoot"
}
if (-not (Test-Path -LiteralPath $dstRoot)) {
    New-Item -ItemType Directory -Path $dstRoot -Force | Out-Null
    Write-Host "created $dstRoot"
}

# collect skills: .harness/skills/<category>/<skill>/
$skills = New-Object System.Collections.Generic.List[object]
Get-ChildItem -LiteralPath $srcRoot -Directory -Force | ForEach-Object {
    $category = $_.Name
    Get-ChildItem -LiteralPath $_.FullName -Directory -Force | ForEach-Object {
        $skills.Add([pscustomobject]@{
            Category = $category
            Name     = $_.Name
            Source   = $_.FullName
            HasSkill = (Test-Path -LiteralPath (Join-Path $_.FullName 'SKILL.md'))
        })
    }
}

if ($skills.Count -eq 0) {
    Write-Host "No skill directory found under $srcRoot (expected <category>/<skill>/SKILL.md)." -ForegroundColor Yellow
    return
}

# duplicate check: .trae/skills is scanned one level deep, so names must be unique
$dupes = $skills | Group-Object Name | Where-Object { $_.Count -gt 1 }
if ($dupes) {
    Write-Host ""
    Write-Host "ERROR: duplicate skill names (platform scans one level, names must be unique):" -ForegroundColor Red
    foreach ($d in $dupes) {
        $paths = ($d.Group | ForEach-Object { "$($_.Category)/$($_.Name)" }) -join ' , '
        Write-Host "   $($d.Name)  <= $paths" -ForegroundColor Red
    }
    throw "Rename them first: entries would overwrite each other."
}

$changed = 0
$skipped = 0

# Windows: directory junction via mklink /J. Unix (pwsh 7): plain symlink.
$isWindowsHost = $true
if (Get-Variable -Name IsWindows -ErrorAction SilentlyContinue) { $isWindowsHost = $IsWindows }

function Remove-Link {
    param([string]$Path)
    if ($isWindowsHost) { cmd /c rmdir "$Path" | Out-Null }
    else { & rm -f "$Path" 2>$null }
    return $LASTEXITCODE
}

function New-Link {
    param([string]$Path, [string]$Target)
    if ($isWindowsHost) { cmd /c mklink /J "$Path" "$Target" | Out-Null }
    else { & ln -s "$Target" "$Path" 2>$null }
    return $LASTEXITCODE
}

function Test-BadLinkTarget {
    param([string]$Path)
    # A junction created inside a virtualised shell records the sandbox mirror
    # path and stops resolving once the command exits. Detect and reject it.
    try {
        $t = (Get-Item -LiteralPath $Path -Force).Target
        if ($t -is [array]) { $t = $t[0] }
        return (([string]$t) -match 'sandbox-storage|unified-cache')
    } catch {
        return $true
    }
}

function Copy-Skill {
    param([string]$Path, [string]$Source)
    if (Test-Path -LiteralPath $Path) {
        $item = Get-Item -LiteralPath $Path -Force
        $isLink = [bool]($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
        if ($isLink) { Remove-Link $Path | Out-Null }
        else { Remove-Item -LiteralPath $Path -Recurse -Force }
    }
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $Source '*') -Destination $Path -Recurse -Force
    # marker: a real directory carrying this file is OUR copy, safe to refresh
    Set-Content -LiteralPath (Join-Path $Path '.harness-copy') -Value $Source -Encoding UTF8 -NoNewline
}

function Mount-Skill {
    param([string]$Path, [string]$Source)
    if ($Mode -eq 'copy') { Copy-Skill $Path $Source; return 'copy' }
    $rc = New-Link $Path $Source
    if ($rc -eq 0 -and -not (Test-BadLinkTarget $Path)) { return 'link' }
    if (Test-Path -LiteralPath $Path) { Remove-Link $Path | Out-Null }
    Copy-Skill $Path $Source
    return 'copy'
}

foreach ($s in $skills) {
    if (-not $s.HasSkill) {
        Write-Host "skip $($s.Category)/$($s.Name): no SKILL.md (not a skill)" -ForegroundColor Yellow
        $skipped++
        continue
    }

    $link = Join-Path $dstRoot $s.Name

    if (Test-Path -LiteralPath $link) {
        $item   = Get-Item -LiteralPath $link -Force
        $isLink = [bool]($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
        # healthy junction: leave it alone (no churn on every run)
        if ($isLink -and (Test-Path -LiteralPath (Join-Path $link 'SKILL.md'))) { continue }
        $isOurCopy = (Test-Path -LiteralPath (Join-Path $link '.harness-copy'))
        if (-not $isLink -and -not $isOurCopy) {
            Write-Host "skip $($s.Name): $link is a real directory that this script did not create (refusing to overwrite)" -ForegroundColor Yellow
            $skipped++
            continue
        }
        if ($PSCmdlet.ShouldProcess($link, 'rebuild entry')) {
            if ($isLink) {
                $rc = Remove-Link $link
                if ($rc -ne 0) {
                    Write-Host "failed: cannot remove old link $($s.Name) (exit $rc)" -ForegroundColor Red
                    $skipped++
                    continue
                }
            }
            $kind = Mount-Skill $link $s.Source
            Write-Host "rebuilt: $($s.Name)  ->  $($s.Category)/$($s.Name)  [$kind]" -ForegroundColor Green
            $changed++
        }
        continue
    }

    if ($PSCmdlet.ShouldProcess($link, 'create entry')) {
        $kind = Mount-Skill $link $s.Source
        Write-Host "created: $($s.Name)  ->  $($s.Category)/$($s.Name)  [$kind]" -ForegroundColor Green
        $changed++
    }
}

Write-Host ""
Write-Host "done: $changed created/rebuilt, $skipped skipped."
Write-Host "next: restart TRAE, confirm the skills appear in its skill list, then send a"
Write-Host "      sentence that matches a skill description to verify auto-triggering."
