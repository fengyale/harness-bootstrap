<#
  audit-order.ps1 -- CI-side audit for "summary first, code second".

  WHY
    The local pre-commit hook sees one commit at a time: it can reject "a new
    summary bundled with code", but it cannot prove whether a summary was
    created before the code was edited. Over a commit range the order becomes
    observable, so this script is the CI complement to install-git-hooks.ps1.

  RULE
    Every commit that changes source files must either:
      - already have .harness/changes/<feature>/summary.md in its tree, or
      - stage a summary in the same commit, or
      - stage a _small.md update in the same commit (L1).
    A commit that ADDS a summary and changes source in the same commit is
    always a violation (same rule as the hook).
    Commits whose message contains [L0] are skipped (comment/typo/format).

  SCOPE
    - Merge commits are skipped: replaying a branch is not "code before doc".
    - Repositories without .harness/changes at the base commit are skipped
      (first harness adoption / legacy import).
    - The feature pointer comes from -Feature or HARNESS_TASK, then from a
      "Harness-Task: <name>" trailer in each commit, then from the record tree
      (exactly one record added by the range, or exactly one record at HEAD).
      The branch name is NOT used: a branch is only a label, and main/dev carry
      no task identity. A commit whose pointer cannot be resolved is reported
      as unattributed instead of being silently skipped.

  USAGE
    powershell -File scripts\audit-order.ps1 -Root . -Base <merge-base-sha>
    powershell -File scripts\audit-order.ps1 -Root . -Base <sha> -Feature login
    powershell -File scripts\audit-order.ps1 -Root . -Base <sha> -Json

  EXIT CODE
    0 = no violation or intentionally skipped, 1 = violation, 2 = bad usage

  NOTE
    Pure ASCII: Windows PowerShell 5.1 reads .ps1 as ANSI unless it has a BOM.
#>
[CmdletBinding()]
param(
    [string]$Root = (Get-Location).Path,
    [string]$Base = '',
    [string]$Head = 'HEAD',
    [string]$Feature = '',
    [switch]$Json
)

$ErrorActionPreference = 'Stop'

function GitCmd {
    param([string[]]$GitArgs)
    & git -C $rootPath @GitArgs 2>$null
}

# A failing git command produces no pipeline output; casting that to [string]
# can yield $null, so every single-value read goes through this helper.
function FirstLine {
    param([string[]]$GitArgs)
    $out = @(GitCmd -GitArgs $GitArgs)
    if ($out.Count -eq 0) { return '' }
    return ([string]$out[0]).Trim()
}

$rootPath = $Root
$top = FirstLine -GitArgs @('rev-parse', '--show-toplevel')
if (-not $top) {
    Write-Host '[SKIP] not a git repository' -ForegroundColor Yellow
    exit 0
}
$rootPath = $top

# The summary-order gate is only real while .harness/changes is tracked. A
# project that ignores the directory can never satisfy it, yet a missing tree
# looked exactly like "first harness adoption" -- so the gate silently never
# fired. recordsTracked=false is the one explicit way to opt out.
function Get-RecordsTracked {
    foreach ($p in @((Join-Path $rootPath 'scripts\harness-required.json'),
                     (Join-Path $PSScriptRoot 'harness-required.json'))) {
        if (-not (Test-Path -LiteralPath $p)) { continue }
        try {
            $cfg = (Get-Content -LiteralPath $p -Raw -Encoding UTF8) | ConvertFrom-Json
            if ($cfg.PSObject.Properties.Name -contains 'recordsTracked') {
                return [bool]$cfg.recordsTracked
            }
            return $true
        } catch { return $true }
    }
    return $true
}
function Test-GitIgnored {
    param([string]$Rel)
    # exit 0 = ignored, 1 = not ignored, anything else = cannot tell. Under
    # 'Stop' an exit code of 1 would surface as a terminating error, so the
    # preference is relaxed around the call.
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & git -C $rootPath check-ignore -q -- $Rel 2>$null
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    } finally {
        $ErrorActionPreference = $prev
    }
}
$recordsTracked = Get-RecordsTracked
# The opt-out applies to the whole audit, not only to the ignored-directory
# case: a project that keeps no records has nothing to attribute either way.
if (-not $recordsTracked) {
    Write-Host '[SKIP] recordsTracked=false: the summary-order audit is off by declaration' -ForegroundColor Yellow
    exit 0
}

if (-not $Base) {
    GitCmd -GitArgs @('rev-parse', '--verify', '--quiet', 'origin/main') | Out-Null
    if ($LASTEXITCODE -eq 0) {
        $Base = FirstLine -GitArgs @('merge-base', 'origin/main', $Head)
    }
}
if (-not $Base) {
    Write-Host '[ERROR] -Base is required (pass the merge-base or PR base sha)' -ForegroundColor Red
    exit 2
}

# Feature pointer resolution. The branch name is deliberately NOT consulted: a
# branch is only a label, and main/dev carry no task identity. The record tree
# already holds the answer, so the pointer comes from explicit input or from it.
if (-not $Feature) { $Feature = $env:HARNESS_TASK }
if (-not $Feature) {
    # Local pointer written by check-summary.ps1 when a task starts. A CI runner
    # has a fresh .git, so this normally resolves only for local runs.
    $ptrRel = FirstLine -GitArgs @('rev-parse', '--git-path', 'harness-current-task')
    if ($ptrRel) {
        $ptr = if ([System.IO.Path]::IsPathRooted($ptrRel)) { $ptrRel } else { Join-Path $top $ptrRel }
        if (Test-Path -LiteralPath $ptr) {
            $line = @([System.IO.File]::ReadAllLines($ptr, [System.Text.Encoding]::UTF8)) |
                    Where-Object { $_.Trim() } | Select-Object -First 1
            if ($line) { $Feature = ([string]$line).Trim() }
        }
    }
}

# First harness adoption: nothing to attribute against.
# --quiet keeps a missing path from writing to stderr (which PS 5.1 turns into
# a terminating NativeCommandError under $ErrorActionPreference = 'Stop').
$baseTree = FirstLine -GitArgs @('rev-parse', '--verify', '--quiet', "${Base}:.harness/changes")
if (-not $baseTree) {
    # Distinguish "not adopted yet" from "adopted but invisible to git": an
    # ignored directory looks identical to a first install, which is how this
    # gate stayed green forever.
    if (Test-GitIgnored '.harness/changes/__probe__') {
        Write-Host '[FAIL] .harness/changes is ignored by .gitignore: the summary-order gate can never fire.' -ForegroundColor Red
        Write-Host '       Remove the ignore pattern; the changes directory must be tracked for this audit to work.' -ForegroundColor Yellow
        Write-Host '       If the project really does not keep records, declare "recordsTracked": false in' -ForegroundColor Yellow
        Write-Host '       scripts/harness-required.json -- that skips the audit explicitly instead of silently.' -ForegroundColor Yellow
        exit 1
    }
    Write-Host "[SKIP] .harness/changes does not exist at base $Base; first harness adoption" -ForegroundColor Yellow
    exit 0
}

# Keep in sync with install-git-hooks.ps1 (package contract guards the marker).
$sourceRe = '\.(java|kt|kts|scala|groovy|sql|xml|py|js|mjs|cjs|ts|tsx|jsx|vue|svelte|cs|go|rs|php|rb|swift|m|mm|dart|lua|c|h|cc|cpp|cxx|hpp|html|css|scss|less|json|yml|yaml|properties|toml|ini)$'
$excludeRe = '^(\.harness|\.trae|\.claude|scripts|docs|node_modules|dist|build|target)/'

# Records that exist at HEAD, and records first added inside the audited range.
# Both are repo facts; neither depends on a branch name. When the range adds
# exactly one record it names itself; otherwise a lone record at HEAD does.
$recordDirs = @(GitCmd -GitArgs @('ls-tree', '-d', '--name-only', "${Head}:.harness/changes") |
                Where-Object { $_ -and $_ -ne '_template' })
$addedRecords = @(GitCmd -GitArgs @('diff', '--name-only', '--diff-filter=A', $Base, $Head, '--', '.harness/changes') |
                  Where-Object { $_ -match '^\.harness/changes/[^/]+/summary\.md$' } |
                  ForEach-Object { ($_ -split '/')[2] } | Select-Object -Unique)

$autoFeature = $Feature
if (-not $autoFeature -and $addedRecords.Count -eq 1) { $autoFeature = $addedRecords[0] }
if (-not $autoFeature -and $recordDirs.Count -eq 1)   { $autoFeature = $recordDirs[0] }

$commits = @(GitCmd -GitArgs @('rev-list', '--reverse', '--no-merges', "$Base..$Head") | Where-Object { $_ })
$violations = @()
$unattributed = @()
$audited = 0

foreach ($sha in $commits) {
    $message = (@(GitCmd -GitArgs @('log', '-1', '--format=%B', $sha)) -join "`n")
    if ($message -match '\[L0\]') { continue }

    $files = @(GitCmd -GitArgs @('diff-tree', '--no-commit-id', '--name-only', '--no-renames', '-r', $sha) | Where-Object { $_ })
    $source = @($files | Where-Object { $_ -match $sourceRe -and $_ -notmatch $excludeRe })
    if ($source.Count -eq 0) { continue }
    $audited++

    # A per-commit trailer beats the range-wide pointer, so several tasks inside
    # one range stay separable without renaming the branch.
    $commitFeature = $autoFeature
    if (-not $commitFeature) {
        $t = [regex]::Match($message, '(?im)^[ \t]*harness-task[ \t]*:[ \t]*(\S[^\r\n]*?)[ \t]*$')
        if ($t.Success) { $commitFeature = $t.Groups[1].Value.Trim() }
    }
    if (-not $commitFeature) { $unattributed += $sha; continue }

    $addsSummary = @($files | Where-Object {
        $_ -match '^\.harness/changes/[^/]+/summary\.md$' -and $_ -notmatch '^\.harness/changes/_template/'
    }).Count -gt 0
    $touchesSmall = @($files | Where-Object { $_ -eq '.harness/changes/_small.md' }).Count -gt 0

    $hasSummary = (FirstLine -GitArgs @('rev-parse', '--verify', '--quiet', "${sha}:.harness/changes/$commitFeature/summary.md")).Length -gt 0

    $reason = $null
    if ($addsSummary) {
        $reason = 'a new summary is bundled with source changes in one commit'
    } elseif (-not ($touchesSmall -or $hasSummary)) {
        $reason = "no summary for feature '$commitFeature' exists before this source commit"
    }
    if ($reason) {
        $violations += [pscustomobject]@{
            sha     = $sha.Substring(0, [Math]::Min(7, $sha.Length))
            feature = $commitFeature
            reason  = $reason
            sources = $source.Count
            message = (($message -split "`n")[0]).Trim()
        }
    }
}

$featureLabel = if ($autoFeature) { $autoFeature } else { 'per-commit trailer' }

if ($Json) {
    [pscustomobject]@{
        feature      = $autoFeature
        base         = $Base
        head         = $Head
        audited      = $audited
        unattributed = @($unattributed)
        violations   = @($violations)
    } | ConvertTo-Json -Depth 4
    if ($violations.Count -gt 0) { exit 1 }
    exit 0
}

if ($violations.Count -eq 0) {
    if ($unattributed.Count -gt 0) {
        Write-Host "[SKIP] $($unattributed.Count) of $audited source commit(s) could not be attributed:" -ForegroundColor Yellow
        Write-Host "       no -Feature / HARNESS_TASK / 'Harness-Task:' trailer, and $($recordDirs.Count) record(s) exist at HEAD." -ForegroundColor Yellow
        Write-Host '       pass -Feature NAME, or add a "Harness-Task: NAME" trailer to the commit.' -ForegroundColor Yellow
        exit 0
    }
    Write-Host ("[PASS] {0} source commit(s) audited for {1}: no order violation" -f $audited, $featureLabel) -ForegroundColor Green
    exit 0
}

Write-Host ("[FAIL] summary-order violations ({0}):" -f $featureLabel) -ForegroundColor Red
foreach ($v in $violations) {
    Write-Host ("  {0}  {1}  ({2} source file(s))  {3}" -f $v.sha, $v.reason, $v.sources, $v.message) -ForegroundColor Red
}
Write-Host 'Fix: land the summary first, or mark comment/typo/format commits with [L0].' -ForegroundColor Yellow
exit 1
