<#
  promote-pattern.ps1 -- turn a project-local lesson into a package-ready candidate

  WHY
    Project lessons die where they were learned. L3 promotion is the only way a
    template gets better, but it must be evidence-based: at least two independent
    projects, a minimal counter-example, and no project names or class names.

  INPUT   .harness\patterns\<id>.md   (one candidate per file)
  OUTPUT  .harness\patterns\outbox\<id>.md  (human-reviewed, then copied into the package)
  RULES   candidates must declare id / stack / symptom / projects >= 2 and contain
          the sections "pattern", "counter-example", "evidence"

  USAGE
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\promote-pattern.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\promote-pattern.ps1 -Root D:\proj

  EXIT CODE  0 = all candidates promotable, 1 = at least one rejected

  NOTE  Pure ASCII. Chinese section titles come from this script's own literals?
        No: they are matched by regex on UTF-8 content, which is safe because the
        file is read explicitly as UTF-8. The literals live in harness-required.json
        under patternSections to keep this script ASCII.
#>
[CmdletBinding()]
param(
    [string]$Root = (Get-Location).Path,
    [string]$Candidates = '.harness\patterns',
    [string]$Out = '.harness\patterns\outbox',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$rootPath = (Resolve-Path -LiteralPath $Root).Path

$cfgPath = Join-Path $PSScriptRoot 'harness-required.json'
$cfg = $null
if (Test-Path -LiteralPath $cfgPath) {
    $cfg = (Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8) | ConvertFrom-Json
}
$sections = @()
if ($cfg -and $cfg.patternSections) { $sections = @($cfg.patternSections) }
if ($sections.Count -eq 0) {
    Write-Host "[FAIL] harness-required.json is missing patternSections" -ForegroundColor Red
    exit 1
}

$candDir = Join-Path $rootPath $Candidates
$outDir  = Join-Path $rootPath $Out

if (-not (Test-Path -LiteralPath $candDir)) {
    Write-Host "[OK] no patterns directory yet: nothing to promote ($candDir)" -ForegroundColor Green
    exit 0
}

$files = @(Get-ChildItem -LiteralPath $candDir -File -Filter '*.md' -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notlike '_*' -and $_.Name -ne 'README.md' })
if ($files.Count -eq 0) {
    Write-Host "[OK] no candidate yet (drop <id>.md into $candDir)" -ForegroundColor Green
    exit 0
}

if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

$rejected = 0
foreach ($f in $files) {
    $text = [System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8)
    # only the header block (before the first heading) may declare fields
    $head = $text
    $hm = [regex]::Match($text, '(?m)^#{1,6}\s')
    if ($hm.Success) { $head = $text.Substring(0, $hm.Index) }

    $problems = @()

    foreach ($key in @('id', 'stack', 'symptom')) {
        if ($head -notmatch ("(?m)^" + $key + ":\s*\S")) { $problems += "missing field: $key" }
    }

    $idVal = ''
    if ($head -match '(?m)^id:\s*(\S+)') { $idVal = $matches[1].Trim() }
    if ($idVal -and $idVal -ne $f.BaseName) { $problems += "id '$idVal' does not match file name '$($f.BaseName)'" }

    $projects = 0
    if ($head -match '(?m)^projects:\s*(\d+)') { $projects = [int]$matches[1] }
    if ($projects -lt 2) { $problems += "projects=$projects (< 2): not promotable yet" }

    foreach ($sec in $sections) {
        if ($text -notmatch ('(?m)^#{1,6}\s.*' + [regex]::Escape([string]$sec))) {
            $problems += "missing section: $sec"
        }
    }

    $target = Join-Path $outDir $f.Name
    if ((Test-Path -LiteralPath $target) -and -not $Force) {
        $problems += "outbox already has $($f.Name) (use -Force to overwrite)"
    }

    if ($problems.Count -gt 0) {
        Write-Host ("[FAIL] {0}" -f $f.Name) -ForegroundColor Red
        foreach ($p in $problems) { Write-Host ("       - " + $p) }
        $rejected++
    } else {
        Copy-Item -LiteralPath $f.FullName -Destination $target -Force
        Write-Host ("[PASS] {0} -> {1}" -f $f.Name, $Out) -ForegroundColor Green
    }
}

Write-Host ""
if ($rejected -gt 0) {
    Write-Host "$rejected candidate(s) rejected; fix fields or wait for the second project." -ForegroundColor Yellow
    exit 1
}
Write-Host "All candidates are package-ready. Review outbox/, then copy into templates/patterns/." -ForegroundColor Green
exit 0
