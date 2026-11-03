<#
  install-self-gate.ps1 -- put the package's own gate into its git hooks

  WHY
    The package sells "the gate is independent of the editor". It must obey the
    same rule: before every commit of harness-bootstrap itself, verify-package.ps1
    -Fast runs automatically. That is what turns "we reviewed it once" into
    "no commit can reintroduce the drift".

  WHAT IT WRITES
    <git-dir>/hooks/pre-commit  (POSIX sh, LF), marker: harness-bootstrap self gate
    An existing hook is backed up to pre-commit.bak-harness first and restored by -Remove.

  USAGE
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\install-self-gate.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\install-self-gate.ps1 -Remove

  NOTE
    Pure ASCII. The generated hook is POSIX sh with LF line endings, which is
    what Git for Windows expects. No commit is made by this script.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$Root = '',
    [switch]$Remove
)

$ErrorActionPreference = 'Stop'

# $PSScriptRoot is empty when used as a param default in PS 5.1, so resolve the
# package root in the body instead of in the signature.
if (-not $Root) { $Root = Split-Path -Parent $PSScriptRoot }
$rootPath = (Resolve-Path -LiteralPath $Root).Path

# This hook is package-only. If the package was copied under a host project
# (e.g. <host>/.trae/skills/harness-bootstrap), installing here would write a
# hook into the HOST repository that points at a tools/ path that does not exist
# there -- every host commit would be refused. So require the package to be the
# repository root, not just any directory inside one.
$top = $null
try { $top = (& git -C $rootPath rev-parse --show-toplevel 2>$null | Select-Object -First 1) } catch { $top = $null }
if (-not $top) { throw "Not a git repository at $rootPath. Run 'git init' first." }
$top = ([string]$top).Trim()
if ([System.IO.Path]::GetFullPath($top).TrimEnd('\', '/') -ne $rootPath.TrimEnd('\', '/')) {
    throw "install-self-gate.ps1 must run in the package repository itself (toplevel=$top, package=$rootPath)."
}

# Ask git for the effective hooks directory: --absolute-git-dir points at
# .git/worktrees/<name> in a linked worktree, whose hooks are never executed.
$hooksDir = $null
try { $hooksDir = (& git -C $rootPath rev-parse --git-path hooks 2>$null | Select-Object -First 1) } catch { $hooksDir = $null }
if (-not $hooksDir) { throw "Cannot locate the hooks directory for $rootPath." }
$hooksDir = ([string]$hooksDir).Trim()
if (-not [System.IO.Path]::IsPathRooted($hooksDir)) {
    $hooksDir = [System.IO.Path]::GetFullPath((Join-Path $rootPath $hooksDir))
}

$hookPath = Join-Path $hooksDir 'pre-commit'
$backup   = "$hookPath.bak-harness"
$marker   = 'harness-bootstrap self gate'

# --------------------------------------------------------------- remove
if ($Remove) {
    if (-not (Test-Path -LiteralPath $hookPath)) {
        Write-Host "no pre-commit hook at $hookPath" -ForegroundColor DarkGray
        exit 0
    }
    $body = [System.IO.File]::ReadAllText($hookPath, [System.Text.Encoding]::UTF8)
    if ($body -notmatch [regex]::Escape($marker)) {
        Write-Host "kept pre-commit: not installed by this package" -ForegroundColor DarkGray
        exit 0
    }
    if ($PSCmdlet.ShouldProcess($hookPath, 'remove self gate')) {
        Remove-Item -LiteralPath $hookPath -Force
        Write-Host "removed: $hookPath" -ForegroundColor Yellow
    }
    if (Test-Path -LiteralPath $backup) {
        if ($PSCmdlet.ShouldProcess($backup, 'restore previous pre-commit')) {
            Move-Item -LiteralPath $backup -Destination $hookPath -Force
            Write-Host "restored previous pre-commit from $backup" -ForegroundColor Yellow
        }
    }
    exit 0
}

# -------------------------------------------------------------- install
$hooksOverride = (& git -C $rootPath config --get core.hooksPath 2>$null | Select-Object -First 1)
if ($hooksOverride) {
    Write-Host "[WARN] core.hooksPath is set to '$hooksOverride'; the hook below will NOT run." -ForegroundColor Yellow
    Write-Host "       run: git config --unset core.hooksPath" -ForegroundColor Yellow
}

$hookBody = @'
#!/bin/sh
# harness-bootstrap self gate: verify the package before every commit
# installed by tools/install-self-gate.ps1 -- edit that script, not this file
ROOT="$(git rev-parse --show-toplevel)"
if command -v powershell >/dev/null 2>&1; then
  powershell -NoProfile -ExecutionPolicy Bypass -File "$ROOT/tools/verify-package.ps1" -Fast
elif command -v pwsh >/dev/null 2>&1; then
  pwsh -NoProfile -File "$ROOT/tools/verify-package.ps1" -Fast
else
  echo "[FAIL] neither powershell nor pwsh found: cannot verify the package, commit refused." >&2
  exit 1
fi
STATUS=$?
if [ $STATUS -ne 0 ]; then
  echo "harness-bootstrap package gate blocked: fix the FAIL rows above." >&2
fi
exit $STATUS
'@ -replace "`r`n", "`n"

if (Test-Path -LiteralPath $hookPath) {
    $existing = [System.IO.File]::ReadAllText($hookPath, [System.Text.Encoding]::UTF8)
    if ($existing -match [regex]::Escape($marker)) {
        Write-Host "self gate already present: $hookPath" -ForegroundColor DarkGray
    } elseif (-not (Test-Path -LiteralPath $backup)) {
        Copy-Item -LiteralPath $hookPath -Destination $backup
        Write-Host "existing pre-commit backed up to $backup"
    }
}

if ($PSCmdlet.ShouldProcess($hookPath, 'write self gate')) {
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($hookPath, $hookBody, $utf8NoBom)
    if (Get-Command chmod -ErrorAction SilentlyContinue) { & chmod +x $hookPath }
    Write-Host "installed: $hookPath" -ForegroundColor Green
    Write-Host "every commit now runs: tools\verify-package.ps1 -Fast"
    Write-Host "remove with: powershell -NoProfile -ExecutionPolicy Bypass -File tools\install-self-gate.ps1 -Remove"
}
exit 0
