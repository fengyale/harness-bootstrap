<#
  record-skill.ps1 -- append one Skill invocation to the project evidence log

  WHY
    loaded_skills in summary.md is self-reported: a summary can claim a Skill
    was used without any call having happened. This script is the missing half:
    the agent calls it at the moment it actually invokes a Skill, and
    check-summary cross-checks the summary claim against this append-only log.
    It is structured reporting, not platform telemetry: nothing observes the
    model, but an honest record becomes cheap and an empty claim becomes visible.

  INPUT
    -Skill <name>     skill name as written in loaded_skills (frontmatter name)
    -Feature <name>   task directory under .harness/changes; defaults to the
                      .git/harness-current-task pointer written by check-summary
    -Root <dir>       project root (default: current directory)

  OUTPUT
    .harness/metrics/skill-calls.jsonl (one JSON object per line, UTF-8 no BOM)
      {"ts":"...","skill":"sql-review","feature":"order-export"}
    The log path is configurable via skillEvidence.log in harness-required.json.

  EXIT CODE
    0 = recorded (or -SelfTest passed) / 1 = bad input or write failure

  NOTE  Pure ASCII (PS 5.1 reads a BOM-less .ps1 as ANSI).
#>
[CmdletBinding()]
param(
    [string]$Root = (Get-Location).Path,
    [string]$Skill = '',
    [string]$Feature = '',
    [string]$LogRel = '',
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Get-SkillEvidenceCfg {
    $p = Join-Path $PSScriptRoot 'harness-required.json'
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    try { return (Get-Content -LiteralPath $p -Raw -Encoding UTF8) | ConvertFrom-Json } catch { return $null }
}

function Resolve-LogRel {
    param($Cfg, [string]$Override)
    if ($Override) { return $Override }
    if ($Cfg -and $Cfg.skillEvidence -and $Cfg.skillEvidence.log) {
        return [string]$Cfg.skillEvidence.log
    }
    return '.harness/metrics/skill-calls.jsonl'
}

function Get-CurrentFeature {
    param([string]$RootPath)
    try {
        $rel = @(& git -C $RootPath rev-parse --git-path harness-current-task 2>$null | Select-Object -First 1)
        if ($rel.Count -gt 0 -and $rel[0]) {
            $p = ([string]$rel[0]).Trim()
            if (-not [System.IO.Path]::IsPathRooted($p)) { $p = Join-Path $RootPath $p }
            if (Test-Path -LiteralPath $p) {
                return ([System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8)).Trim()
            }
        }
    } catch { }
    return ''
}

function Add-SkillCall {
    param([string]$RootPath, [string]$Log, [string]$SkillName, [string]$FeatureName)
    $full = if ([System.IO.Path]::IsPathRooted($Log)) { $Log } else { Join-Path $RootPath ($Log -replace '/', '\') }
    $dir = Split-Path -Parent $full
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $ts = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $line = '{"ts":"' + $ts + '","skill":"' + $SkillName + '","feature":"' + $FeatureName + '"}'
    # StreamWriter with an explicit no-BOM UTF-8 keeps the first line parseable;
    # Add-Content -Encoding UTF8 writes a BOM on PS 5.1 when the file is new.
    $sw = New-Object System.IO.StreamWriter($full, $true, $Utf8NoBom)
    try { $sw.WriteLine($line) } finally { $sw.Dispose() }
    return $full
}

function Invoke-SelfTest {
    $tmp = Join-Path $env:TEMP ('hb-record-skill-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $fails = 0
    try {
        New-Item -ItemType Directory -Force -Path $tmp | Out-Null
        $log = '.harness\metrics\skill-calls.jsonl'
        $full = Add-SkillCall -RootPath $tmp -Log $log -SkillName 'sql-review' -FeatureName 'demo'
        Add-SkillCall -RootPath $tmp -Log $log -SkillName 'sql-review' -FeatureName 'demo' | Out-Null
        $lines = @(Get-Content -LiteralPath $full -Encoding UTF8)
        if ($lines.Count -ne 2) { Write-Host '[FAIL] selftest: expected 2 lines'; $fails++ }
        $first = $lines[0] | ConvertFrom-Json
        if ($first.skill -ne 'sql-review' -or $first.feature -ne 'demo') {
            Write-Host '[FAIL] selftest: JSON fields wrong'; $fails++
        }
        if (-not ($first.ts -match '^\d{4}-\d{2}-\d{2}T')) { Write-Host '[FAIL] selftest: ts wrong'; $fails++ }
        if ($fails -eq 0) { Write-Host '[OK] record-skill selftest passed' }
    } finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
    }
    if ($fails -gt 0) { exit 1 }
    exit 0
}

if ($SelfTest) { Invoke-SelfTest }

if (-not $Skill) {
    Write-Host '[FAIL] -Skill is required (use the frontmatter name, e.g. sql-review)'
    exit 1
}
if ($Skill -notmatch '^[A-Za-z0-9._-]+$') {
    Write-Host '[FAIL] -Skill must match ^[A-Za-z0-9._-]+$'
    exit 1
}

$rootPath = (Resolve-Path -LiteralPath $Root).Path
$cfg = Get-SkillEvidenceCfg
$log = Resolve-LogRel -Cfg $cfg -Override $LogRel
$feat = $Feature
if (-not $feat) { $feat = Get-CurrentFeature -RootPath $rootPath }
if (-not $feat) {
    Write-Host '[WARN] no -Feature and no harness-current-task pointer; recording feature=none' -ForegroundColor Yellow
    $feat = 'none'
}

try {
    $full = Add-SkillCall -RootPath $rootPath -Log $log -SkillName $Skill -FeatureName $feat
    Write-Host ('[OK] skill call recorded: ' + $Skill + ' (' + $feat + ') -> ' + $full)
    exit 0
} catch {
    Write-Host ('[FAIL] could not write skill call log: ' + $_.Exception.Message)
    exit 1
}
