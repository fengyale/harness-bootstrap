<#
  check-task-start.ps1 -- refuse a change record that was committed without a task start

  WHY
    scripts\harness-start.ps1 records "this task has a record and passed stage 1"
    in .git/harness-task-started. Without a check the marker is advice. This
    script is the opt-in teeth: when requireTaskStart is on, the pre-commit hook
    calls it for a commit that lands a .harness/changes/<feature>/summary.md.

  WHERE THE FLAG COMES FROM
    The hook reads requireTaskStart from the INDEX (then HEAD) and passes it as
    -Require, because an unstaged edit to the worktree config must not be able to
    switch the gate off. A manual run without -Require falls back to the worktree
    config.

  POLICY
    requireTaskStart false (default for a fresh install and for an upgrade) ->
    exit 0.
    requireTaskStart true ->
      .git/harness-task-started must exist;
      its feature= must equal -Feature when -Feature is given;
      its at= must be later than the last commit (git log -1 --format=%ct),
      otherwise the marker belongs to an earlier task.

  USAGE
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\check-task-start.ps1 -Root .
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\check-task-start.ps1 -Root . -Require 1 -Feature my-feature

  EXIT CODE
    0 = marker not required, or present, matching and current
    1 = required but missing / stale / inconsistent, or not a git repository

  NOTE
    Pure ASCII on purpose (PS 5.1 parses a BOM-less .ps1 as ANSI).
#>
[CmdletBinding()]
param(
    [string]$Root = (Get-Location).Path,
    [int]$Require = -1,
    [string]$Feature = ''
)

$ErrorActionPreference = 'Stop'

function Fail-TaskStart {
    param([string]$Reason, [string]$FeatureName)
    Write-Host ('[FAIL] ' + $Reason)
    if (-not $FeatureName) { $FeatureName = 'name' }
    Write-Host ('[FAIL] run scripts\harness-start.ps1 -Feature ' + $FeatureName + ' before committing the summary')
    exit 1
}

$rootPath = $Root
try { $rootPath = (Resolve-Path -LiteralPath $Root).Path }
catch { Fail-TaskStart ('root not found: ' + $Root) $Feature }

# -Require wins when given (the hook always passes it). Only a manual run reads
# the worktree config, and a broken config is treated as "not required": the
# other gates already report the broken config, and masking it as this failure
# would send the reader to the wrong place.
$requireFlag = $false
if ($PSBoundParameters.ContainsKey('Require')) {
    $requireFlag = ($Require -ne 0)
} else {
    $cfgPath = Join-Path $rootPath 'scripts\harness-required.json'
    if (Test-Path -LiteralPath $cfgPath) {
        try {
            $cfg = (Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8) | ConvertFrom-Json
            if ($cfg.PSObject.Properties['requireTaskStart']) { $requireFlag = [bool]$cfg.requireTaskStart }
        } catch { $requireFlag = $false }
    }
}
if (-not $requireFlag) {
    Write-Host '[OK] task-start marker not required'
    exit 0
}

$gitDir = $null
try { $gitDir = (& git -C $rootPath rev-parse --absolute-git-dir 2>$null | Select-Object -First 1) } catch { $gitDir = $null }
if ($gitDir) {
    $gitDir = ([string]$gitDir).Trim()
    if (-not [System.IO.Path]::IsPathRooted($gitDir)) { $gitDir = [System.IO.Path]::GetFullPath((Join-Path $rootPath $gitDir)) }
} else {
    $fallback = Join-Path $rootPath '.git'
    if (Test-Path -LiteralPath $fallback) { $gitDir = $fallback }
}
if (-not $gitDir -or -not (Test-Path -LiteralPath $gitDir)) {
    Fail-TaskStart 'requireTaskStart is on but no git directory was found' $Feature
}

$marker = Join-Path $gitDir 'harness-task-started'
if (-not (Test-Path -LiteralPath $marker)) {
    Fail-TaskStart 'task-start marker missing (.git/harness-task-started)' $Feature
}

$markerFeature = ''
$markerAt = ''
foreach ($line in [System.IO.File]::ReadAllLines($marker, [System.Text.Encoding]::UTF8)) {
    if ($line -match '^\s*feature=(.+?)\s*$') { $markerFeature = $matches[1] }
    elseif ($line -match '^\s*at=(.+?)\s*$') { $markerAt = $matches[1] }
}
if (-not $markerFeature) { Fail-TaskStart 'task-start marker has no feature= line' $Feature }
if ($Feature -and ($markerFeature -ne $Feature)) {
    Fail-TaskStart ('task-start marker says ' + $markerFeature + ' but this summary is ' + $Feature) $Feature
}

if (-not $markerAt) { Fail-TaskStart 'task-start marker has no at= timestamp' $markerFeature }
# The marker must belong to this task, not to a previous one. HEAD's committer
# time is the cut-off: a marker written before the last commit is stale.
# Epoch seconds are computed by subtraction instead of ToUnixTimeSeconds(), which
# is missing on older .NET Framework builds that PS 5.1 may still be running on.
$epochBase = New-Object DateTimeOffset(1970, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
$markerEpoch = -1
try { $markerEpoch = [int64][math]::Floor((([DateTimeOffset]::Parse($markerAt)).ToUniversalTime() - $epochBase).TotalSeconds) } catch { $markerEpoch = -1 }
if ($markerEpoch -lt 0) { Fail-TaskStart ('task-start marker at= is not a valid timestamp: ' + $markerAt) $markerFeature }
# Do not gate this on $LASTEXITCODE: inside a pipeline its value is not the git
# exit code here, and a missed HEAD timestamp silently disabled the stale check.
$headEpoch = 0
try {
    $raw = (& git -C $rootPath log -1 --format=%ct 2>$null | Select-Object -First 1)
    if ($raw) {
        $parsed = [int64]0
        if ([int64]::TryParse(([string]$raw).Trim(), [ref]$parsed)) { $headEpoch = $parsed }
    }
} catch { $headEpoch = 0 }
if ($headEpoch -gt 0 -and $markerEpoch -le $headEpoch) {
    Fail-TaskStart 'task-start marker is older than the last commit; re-run harness-start for this feature' $markerFeature
}

Write-Host ('[OK] task start marker is current for ' + $markerFeature)
exit 0
