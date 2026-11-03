<#
  agents-delta.ps1 -- read-only delta report for the resident file (AGENTS.md)

  WHY
    Re-installing on a project that already has AGENTS.md is the risky path: a
    full rewrite makes it thinner over time, while a blind append only adds a
    footer. This script tells you, before touching anything, which of the fixed
    sections exist, how much real content each has, and whether template
    placeholders are still around.

  USAGE
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\agents-delta.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\agents-delta.ps1 -Root D:\proj

  EXIT CODE
    0 = all required sections present, 1 = at least one section missing

  NOTE
    Pure ASCII. Section names come from harness-required.json (UTF-8).
#>
[CmdletBinding()]
param(
    [string]$Root = (Get-Location).Path
)

$ErrorActionPreference = 'Stop'

$rootPath  = (Resolve-Path -LiteralPath $Root).Path
$agentsPath = Join-Path $rootPath 'AGENTS.md'
$cfgPath   = Join-Path $PSScriptRoot 'harness-required.json'

if (-not (Test-Path -LiteralPath $cfgPath)) {
    Write-Host "[FAIL] missing harness-required.json next to this script" -ForegroundColor Red
    exit 1
}
$cfg = (Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8) | ConvertFrom-Json
$sections = @($cfg.agentsSections)

if (-not (Test-Path -LiteralPath $agentsPath)) {
    Write-Host "[FAIL] missing AGENTS.md at $rootPath" -ForegroundColor Red
    exit 1
}

$text  = [System.IO.File]::ReadAllText($agentsPath, [System.Text.Encoding]::UTF8)
$lines = $text -split "`n"

function Get-Body {
    param([string]$Name)
    $out = @()
    $inside = $false
    $level = 0
    foreach ($line in $lines) {
        if ($line -match '^(#{1,6})\s') {
            $hLevel = $matches[1].Length
            if ($inside) {
                # stop only at the same or a higher level; deeper headings belong to this section
                if ($hLevel -le $level) { break }
                $out += $line
                continue
            }
            if ($line -match [regex]::Escape($Name)) {
                $inside = $true
                $level = $hLevel
            }
            continue
        }
        if ($inside) { $out += $line }
    }
    return $out
}

Write-Host ""
Write-Host "AGENTS.md delta -- $agentsPath" -ForegroundColor Cyan
Write-Host ("-" * 70)
$missing = 0
$hollow  = 0
foreach ($name in $sections) {
    $hasHeading = $false
    foreach ($line in $lines) {
        if (($line -match '^#{1,6}\s') -and ($line -match [regex]::Escape($name))) { $hasHeading = $true; break }
    }
    $body  = @(Get-Body $name)
    $nonEmpty = @($body | Where-Object { $_.Trim().Length -gt 0 }).Count
    if (-not $hasHeading) {
        Write-Host ("  [MISSING] {0}" -f $name) -ForegroundColor Red
        $missing++
    } elseif ($nonEmpty -lt 2) {
        Write-Host ("  [HOLLOW ] {0}  ({1} non-empty line(s))" -f $name, $nonEmpty) -ForegroundColor Yellow
        $hollow++
    } else {
        Write-Host ("  [OK     ] {0}  ({1} non-empty line(s))" -f $name, $nonEmpty) -ForegroundColor Green
    }
}

$ruleRows = @($text -split "`n" | Where-Object { $_ -match '^\|\s*R\d+\s*\|' }).Count
$cmdRows  = @($text -split "`n" | Where-Object { $_ -match '^\|.*`[^`]+`' }).Count
Write-Host ("-" * 70)
Write-Host ("red-line rows: {0}   command rows with backticks: {1}" -f $ruleRows, $cmdRows)
Write-Host ""

if ($missing -gt 0 -or $hollow -gt 0) {
    Write-Host "Merge only what is MISSING or HOLLOW; keep existing paragraphs untouched." -ForegroundColor Yellow
    exit 1
}
Write-Host "All required sections present. Re-install should be a delta, not a rewrite." -ForegroundColor Green
exit 0
