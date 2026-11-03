<#
  uninstall-harness.ps1 -- clean removal of an installed harness

  REMOVES (only harness machinery)
    - .trae/skills junctions that point into .harness/skills (never deletes the source)
    - .git/hooks/pre-commit, post-commit, pre-merge-commit ONLY IF each one
      was installed by install-git-hooks.ps1 (marker text is checked per hook)
    - optionally the whole .harness tree (asks first, -RemoveHarness to allow)

  NEVER REMOVES
    - AGENTS.md (you decide; it may hold hand written content)
    - .trae/agents/*.md (may be edited by you)
    - .gitignore (it belongs to you; the metrics line is only pointed out)
    - any source code, wiki content, or changes records unless -RemoveHarness

  USAGE  (no pwsh on 5.1; Bypass required by policy)
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\uninstall-harness.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\uninstall-harness.ps1 -WhatIf
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\uninstall-harness.ps1 -RemoveHarness

  NOTE
    Junctions are removed with rmdir so nothing behind them is touched.
    Pure ASCII on purpose (PS 5.1 encoding rule).
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$Root = (Get-Location).Path,
    [switch]$RemoveHarness
)

$ErrorActionPreference = 'Stop'

$rootPath = (Resolve-Path -LiteralPath $Root).Path
Write-Host ""
Write-Host "uninstall harness from: $rootPath" -ForegroundColor Cyan
Write-Host ("-" * 60)

$removed = 0
$kept = 0

# Hook directory: ask git for the EFFECTIVE hooks path. In a linked worktree
# --absolute-git-dir is .git/worktrees/<name> (never executed), and with
# core.hooksPath set the hooks may live elsewhere entirely. --git-path hooks
# answers both correctly; fall back to .git\hooks only when git is unavailable.
$hooksDir = $null
try { $hooksDir = (& git -C $rootPath rev-parse --git-path hooks 2>$null | Select-Object -First 1) } catch { $hooksDir = $null }
if ($hooksDir) {
    $hooksDir = ([string]$hooksDir).Trim()
    if (-not [System.IO.Path]::IsPathRooted($hooksDir)) {
        $hooksDir = [System.IO.Path]::GetFullPath((Join-Path $rootPath $hooksDir))
    }
}
if (-not $hooksDir) { $hooksDir = Join-Path $rootPath '.git\hooks' }

# ------------------------------------------------- 1 junction entries only
$linkRoot = Join-Path $rootPath '.trae\skills'
if (Test-Path -LiteralPath $linkRoot) {
    foreach ($e in Get-ChildItem -LiteralPath $linkRoot -Force -Directory) {
        $isLink = [bool]($e.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
        if ($isLink) {
            if ($PSCmdlet.ShouldProcess($e.FullName, 'remove junction')) {
                cmd /c rmdir "$($e.FullName)" | Out-Null
                Write-Host "  removed junction: $($e.Name)" -ForegroundColor Yellow
                $removed++
            }
        } else {
            Write-Host "  kept real directory: $($e.Name)" -ForegroundColor DarkGray
            $kept++
        }
    }
    $left = @(Get-ChildItem -LiteralPath $linkRoot -Force -ErrorAction SilentlyContinue).Count
    if ($left -eq 0) {
        if ($PSCmdlet.ShouldProcess($linkRoot, 'remove empty .trae\skills')) {
            Remove-Item -LiteralPath $linkRoot -Force -ErrorAction SilentlyContinue
            Write-Host "  removed empty: .trae\skills" -ForegroundColor Yellow
        }
    }
} else {
    Write-Host "  no .trae\skills" -ForegroundColor DarkGray
}

# ------------------------------------------------------------ 2 git hooks
# install-git-hooks.ps1 writes three hooks, so uninstall must remove the same
# three; deleting only pre-commit left post-commit (and pre-merge-commit) behind
# writing gate.jsonl forever. Each hook is removed only when its own marker is
# present, and a .bak-harness backup is restored when one exists.
$hookSpecs = @(
    @{ Name = 'pre-commit';       Marker = 'harness pre-commit gate' },
    @{ Name = 'post-commit';      Marker = 'harness post-commit' },
    @{ Name = 'pre-merge-commit'; Marker = 'harness pre-commit gate' }
)
foreach ($spec in $hookSpecs) {
    $hookPath = Join-Path $hooksDir $spec.Name
    if (-not $hookPath -or -not (Test-Path -LiteralPath $hookPath)) {
        Write-Host ("  no {0} hook" -f $spec.Name) -ForegroundColor DarkGray
        continue
    }
    $body = Get-Content -LiteralPath $hookPath -Raw -Encoding UTF8
    if ($body -notmatch [regex]::Escape($spec.Marker)) {
        Write-Host ("  kept {0} hook (not installed by this harness)" -f $spec.Name) -ForegroundColor DarkGray
        $kept++
        continue
    }
    if ($PSCmdlet.ShouldProcess($hookPath, "remove harness $($spec.Name) hook")) {
        Remove-Item -LiteralPath $hookPath -Force
        Write-Host ("  removed: {0}" -f $hookPath) -ForegroundColor Yellow
        $removed++
    }
    $backup = "$hookPath.bak-harness"
    if (Test-Path -LiteralPath $backup) {
        if ($PSCmdlet.ShouldProcess($backup, "restore previous $($spec.Name) hook")) {
            Move-Item -LiteralPath $backup -Destination $hookPath -Force
            Write-Host ("  restored previous {0} hook from backup" -f $spec.Name) -ForegroundColor Yellow
        }
    }
}

# ------------------------------------------------------------- 3 gitignore
# Nothing here rewrites .gitignore. install never adds a line to it (the template
# is copied only when the file is absent), so deleting a line would corrupt a
# file this harness does not own -- and rewriting it as UTF-8 without BOM breaks
# a GBK/CRLF .gitignore. Point at the line instead; the user decides.
$gitignore = Join-Path $rootPath '.gitignore'
if (Test-Path -LiteralPath $gitignore) {
    $hasMetrics = @([System.IO.File]::ReadAllLines($gitignore, [System.Text.Encoding]::UTF8) |
        Where-Object { $_.Trim() -eq '.harness/metrics/' }).Count -gt 0
    if ($hasMetrics) {
        Write-Host "  .gitignore kept as-is (it ignores .harness/metrics/; remove that line by hand if you want gate logs in git)" -ForegroundColor DarkGray
    }
}

# --------------------------------------------------- 4 optional .harness tree
$harness = Join-Path $rootPath '.harness'
if ($RemoveHarness -and (Test-Path -LiteralPath $harness)) {
    if ($PSCmdlet.ShouldProcess($harness, 'DELETE the whole .harness tree')) {
        Remove-Item -LiteralPath $harness -Recurse -Force
        Write-Host "  removed: .harness (rules, skills, wiki, changes)" -ForegroundColor Red
        $removed++
    }
} elseif (Test-Path -LiteralPath $harness) {
    Write-Host "  kept: .harness (pass -RemoveHarness to delete it)" -ForegroundColor DarkGray
    $kept++
}

Write-Host ("-" * 60)
Write-Host "removed: $removed   kept: $kept"

if (-not $RemoveHarness) {
    Write-Host ""
    Write-Host "Still on disk (delete manually if you want them gone):" -ForegroundColor Yellow
    Write-Host "  AGENTS.md            <- may contain your own notes"
    Write-Host "  .harness\            <- rules, skills source, wiki, changes"
    Write-Host "  .trae\agents\*.md    <- may be edited by you"
    Write-Host "  scripts\             <- scan/link/probe tooling"
    Write-Host "  .cursor\rules, .github\copilot-instructions.md (if created)"
}

Write-Host ""
Write-Host "Tip: after uninstalling, open a NEW conversation so the agent stops" -ForegroundColor Cyan
Write-Host "     seeing the old AGENTS.md / skills in its context."
exit 0
