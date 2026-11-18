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
    - The feature pointer comes from -Feature, HARNESS_TASK, GITHUB_HEAD_REF,
      or a feature|fix|hotfix|bugfix branch (last path segment). Without a
      pointer the audit cannot attribute code and skips with a clear message.

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

if (-not $Feature) { $Feature = $env:HARNESS_TASK }
if (-not $Feature -and $env:GITHUB_HEAD_REF) {
    if ($env:GITHUB_HEAD_REF -match '^(feature|fix|hotfix|bugfix)/(.+)$') {
        $Feature = ($Matches[2] -split '/')[-1]
    }
}
if (-not $Feature) {
    $branch = FirstLine -GitArgs @('rev-parse', '--abbrev-ref', 'HEAD')
    if ($branch -match '^(feature|fix|hotfix|bugfix)/(.+)$') {
        $Feature = ($Matches[2] -split '/')[-1]
    }
}
if (-not $Feature) {
    Write-Host '[SKIP] no feature pointer (use -Feature, HARNESS_TASK, GITHUB_HEAD_REF or a feature/fix branch)' -ForegroundColor Yellow
    exit 0
}

# First harness adoption: nothing to attribute against.
# --quiet keeps a missing path from writing to stderr (which PS 5.1 turns into
# a terminating NativeCommandError under $ErrorActionPreference = 'Stop').
$baseTree = FirstLine -GitArgs @('rev-parse', '--verify', '--quiet', "${Base}:.harness/changes")
if (-not $baseTree) {
    Write-Host "[SKIP] .harness/changes does not exist at base $Base; first harness adoption" -ForegroundColor Yellow
    exit 0
}

# Keep in sync with install-git-hooks.ps1 (package contract guards the marker).
$sourceRe = '\.(java|kt|kts|scala|groovy|sql|xml|py|js|mjs|cjs|ts|tsx|jsx|vue|svelte|cs|go|rs|php|rb|swift|m|mm|dart|lua|c|h|cc|cpp|cxx|hpp|html|css|scss|less|json|yml|yaml|properties|toml|ini)$'
$excludeRe = '^(\.harness|\.trae|\.claude|scripts|docs|node_modules|dist|build|target)/'

$commits = @(GitCmd -GitArgs @('rev-list', '--reverse', '--no-merges', "$Base..$Head") | Where-Object { $_ })
$violations = @()
$audited = 0

foreach ($sha in $commits) {
    $message = (@(GitCmd -GitArgs @('log', '-1', '--format=%B', $sha)) -join "`n")
    if ($message -match '\[L0\]') { continue }

    $files = @(GitCmd -GitArgs @('diff-tree', '--no-commit-id', '--name-only', '--no-renames', '-r', $sha) | Where-Object { $_ })
    $source = @($files | Where-Object { $_ -match $sourceRe -and $_ -notmatch $excludeRe })
    if ($source.Count -eq 0) { continue }
    $audited++

    $addsSummary = @($files | Where-Object {
        $_ -match '^\.harness/changes/[^/]+/summary\.md$' -and $_ -notmatch '^\.harness/changes/_template/'
    }).Count -gt 0
    $touchesSmall = @($files | Where-Object { $_ -eq '.harness/changes/_small.md' }).Count -gt 0

    $hasSummary = (FirstLine -GitArgs @('rev-parse', '--verify', '--quiet', "${sha}:.harness/changes/$Feature/summary.md")).Length -gt 0

    $reason = $null
    if ($addsSummary) {
        $reason = 'a new summary is bundled with source changes in one commit'
    } elseif (-not ($touchesSmall -or $hasSummary)) {
        $reason = "no summary for feature '$Feature' exists before this source commit"
    }
    if ($reason) {
        $violations += [pscustomobject]@{
            sha     = $sha.Substring(0, [Math]::Min(7, $sha.Length))
            reason  = $reason
            sources = $source.Count
            message = (($message -split "`n")[0]).Trim()
        }
    }
}

if ($Json) {
    [pscustomobject]@{
        feature    = $Feature
        base       = $Base
        head       = $Head
        audited    = $audited
        violations = @($violations)
    } | ConvertTo-Json -Depth 4
    if ($violations.Count -gt 0) { exit 1 }
    exit 0
}

if ($violations.Count -eq 0) {
    Write-Host "[PASS] $audited source commit(s) audited for feature '$Feature': no order violation" -ForegroundColor Green
    exit 0
}

Write-Host "[FAIL] summary-order violations for feature '$Feature':" -ForegroundColor Red
foreach ($v in $violations) {
    Write-Host ("  {0}  {1}  ({2} source file(s))  {3}" -f $v.sha, $v.reason, $v.sources, $v.message) -ForegroundColor Red
}
Write-Host 'Fix: land the summary first, or mark comment/typo/format commits with [L0].' -ForegroundColor Yellow
exit 1
