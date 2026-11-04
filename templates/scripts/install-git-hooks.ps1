<#
  install-git-hooks.ps1 -- install a git pre-commit gate that runs the red-line scan

  WHY THIS AND NOT ONLY .trae/hooks.json
    Tool-level hooks depend on that tool's schema (event names, match fields) and on
    you keeping the app open. A git pre-commit hook is tool-independent: it blocks the
    commit no matter whether the change came from TRAE, Claude Code, another IDE, or
    your own hands. That is what makes it a real gate.

    Recommended split:
      - git pre-commit hook  -> the reliable gate (this script)
      - .trae/hooks.json     -> fast feedback inside the editor

  ENCODING NOTE
    Pure ASCII on purpose (PS 5.1 reads .ps1 as ANSI without a BOM).
    The generated hook is a POSIX sh script with LF line endings, which is what
    Git for Windows expects.

  USAGE  (no pwsh here; execution policy blocks unsigned scripts)
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\install-git-hooks.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\install-git-hooks.ps1 -Root D:\proj
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$Root = (Get-Location).Path
)

$ErrorActionPreference = 'Stop'

$root = (Resolve-Path -LiteralPath $Root).Path

# Ask git for the EFFECTIVE hooks directory. In a linked worktree
# --absolute-git-dir points at .git/worktrees/<name>, whose hooks/ is never
# executed; the real one is the common <main>/.git/hooks. --git-path hooks
# answers with the directory git actually runs and honours core.hooksPath.
$repoDir = (& git -C $root rev-parse --absolute-git-dir 2>$null | Select-Object -First 1)
if (-not $repoDir -or -not (Test-Path -LiteralPath ([string]$repoDir).Trim())) {
    throw "Not a git repository at $root. Run 'git init' first, then re-run this script."
}
$hooksDir = (& git -C $root rev-parse --git-path hooks 2>$null | Select-Object -First 1)
if (-not $hooksDir) {
    throw "Cannot locate the hooks directory for $root. Check 'git rev-parse --git-path hooks'."
}
$hooksDir = ([string]$hooksDir).Trim()
if (-not [System.IO.Path]::IsPathRooted($hooksDir)) {
    $hooksDir = [System.IO.Path]::GetFullPath((Join-Path $root $hooksDir))
}
if (-not (Test-Path -LiteralPath $hooksDir)) {
    New-Item -ItemType Directory -Path $hooksDir -Force | Out-Null
}

# core.hooksPath is no longer a silent hole: the lookup above follows it, so the
# hooks land where git actually looks. State it plainly instead of warning.
$hooksOverride = (& git -C $root config --get core.hooksPath 2>$null | Select-Object -First 1)
if ($hooksOverride) {
    Write-Host "[INFO] core.hooksPath is set to '$hooksOverride'; installing into $hooksDir" -ForegroundColor DarkGray
}

$hookPath = Join-Path $hooksDir 'pre-commit'

# POSIX sh hook. LF only. Scans NEW CHANGES ONLY so that a legacy project with
# hundreds of historical violations still gets a usable gate.
$hookBody = @'
#!/bin/sh
# harness pre-commit gate: red-line scan of staged files only
# installed by scripts/install-git-hooks.ps1 -- edit that script, not this file
ROOT="$(git rev-parse --show-toplevel)"
GIT_DIR="$(git rev-parse --absolute-git-dir 2>/dev/null)"
if [ -z "$GIT_DIR" ]; then
  echo "[FAIL] cannot locate the git directory; commit refused." >&2
  exit 1
fi

if [ ! -f "$ROOT/scripts/red-line-scan.ps1" ] && [ ! -f "$ROOT/scripts/red-line-scan.py" ]; then
  echo "[FAIL] no red-line scanner in scripts/: the gate is misconfigured." >&2
  echo "       copy scripts/ into the project, then re-run install-git-hooks.ps1" >&2
  exit 1
fi

# fail-closed: --no-verify is the only explicit way past this gate, and it is
# counted as a bypass by scripts/metrics.ps1.
if command -v powershell >/dev/null 2>&1 && [ -f "$ROOT/scripts/red-line-scan.ps1" ]; then
  MODE=ps
elif command -v python3 >/dev/null 2>&1 && [ -f "$ROOT/scripts/red-line-scan.py" ]; then
  MODE=py3
elif command -v python >/dev/null 2>&1 && [ -f "$ROOT/scripts/red-line-scan.py" ]; then
  MODE=py
elif command -v pwsh >/dev/null 2>&1 && [ -f "$ROOT/scripts/red-line-scan.ps1" ]; then
  MODE=pwsh
else
  echo "[FAIL] neither PowerShell nor python found: cannot verify red lines, commit refused." >&2
  echo "       install python3, or bypass explicitly with: git commit --no-verify" >&2
  exit 1
fi

DIFF_FILE="$GIT_DIR/harness-diff.tmp"
if ! git -c core.quotepath=false diff --cached -U0 --diff-filter=ACMR --no-color > "$DIFF_FILE" 2>"$GIT_DIR/harness-diff.err"; then
  echo "[FAIL] cannot generate the staged diff; commit refused." >&2
  echo "       see $GIT_DIR/harness-diff.err" >&2
  exit 1
fi
FILES_N=$(git -c core.quotepath=false diff --cached --name-only --diff-filter=ACMR | wc -l | tr -d ' ')
HUNKS_N=$(grep -c '^@@' "$DIFF_FILE" 2>/dev/null || true)
# staged paths are reused by the summary field check below
CHANGED_FILES=$(git -c core.quotepath=false diff --cached --name-only --diff-filter=ACMR)

mkdir -p "$ROOT/.harness/metrics" 2>/dev/null

# ------------------------------------------------------------------
# Fail-closed checks that do NOT depend on the diff. They must run before
# the empty-diff early exit: a pure-deletion commit (git rm rule / gate /
# check-summary) produces no diff and used to skip every check below.
# ------------------------------------------------------------------
gate_fail() {
  printf '{"event":"scan","ts":"%s","blocked":1,"files":%s,"hunks":%s}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$FILES_N" "$HUNKS_N" >> "$ROOT/.harness/metrics/gate.jsonl" 2>/dev/null
  echo "" >&2
  echo "harness gate blocked: $1" >&2
  echo "(--no-verify bypasses this gate; the bypass is counted by scripts/metrics.ps1.)" >&2
  rm -f "$DIFF_FILE"
  exit 1
}

# The hook executes the worktree copy of each gate. A local edit that is not
# staged must not be able to replace a real gate with a no-op. Untracked tools
# are allowed (the harness may not be committed yet); tracked tools must match
# the index. git diff --quiet handles CRLF/autocrlf correctly.
assert_tool_in_sync() {
  t="$1"
  if git cat-file -e ":$t" 2>/dev/null; then
    if ! git diff --quiet -- "$t"; then
      gate_fail "worktree copy of $t differs from the index; stage it or revert it"
    fi
  fi
}

# check-summary.ps1 is a required gate. A commit that deletes it from the
# tracked tree must fail even if a worktree copy is still lying around.
if git cat-file -e HEAD:scripts/check-summary.ps1 2>/dev/null && ! git cat-file -e :scripts/check-summary.ps1 2>/dev/null; then
  gate_fail 'scripts/check-summary.ps1 was deleted in this commit'
fi
if [ ! -f "$ROOT/scripts/check-summary.ps1" ]; then
  gate_fail 'scripts/check-summary.ps1 is missing'
fi

# The commit must leave at least one tracked scanner. Deleting one of two
# runtimes is allowed; deleting the last tracked one is not.
HAD_PS=0; HAD_PY=0; HAS_PS=0; HAS_PY=0
git cat-file -e HEAD:scripts/red-line-scan.ps1 2>/dev/null && HAD_PS=1
git cat-file -e HEAD:scripts/red-line-scan.py 2>/dev/null && HAD_PY=1
git cat-file -e :scripts/red-line-scan.ps1 2>/dev/null && HAS_PS=1
git cat-file -e :scripts/red-line-scan.py 2>/dev/null && HAS_PY=1
if { [ "$HAD_PS" = 1 ] || [ "$HAD_PY" = 1 ]; } && [ "$HAS_PS" = 0 ] && [ "$HAS_PY" = 0 ]; then
  gate_fail 'the commit removes the last tracked red-line scanner'
fi

# The rule table is the scanner's input; a local edit or deletion must not
# weaken the scan while the committed table still has the rule.
if git cat-file -e HEAD:scripts/red-line-rules.json 2>/dev/null && ! git cat-file -e :scripts/red-line-rules.json 2>/dev/null; then
  gate_fail 'scripts/red-line-rules.json was deleted in this commit'
fi
if [ ! -f "$ROOT/scripts/red-line-rules.json" ]; then
  gate_fail 'scripts/red-line-rules.json is missing'
fi

# All tracked gate tools must be byte-identical to the index. This is the
# worktree-vs-index trust boundary: without it, an unstaged empty script
# silently disables the red-line scan, the SQL gate or the summary check.
assert_tool_in_sync scripts/check-summary.ps1
assert_tool_in_sync scripts/red-line-rules.json
assert_tool_in_sync scripts/red-line-scan.ps1
assert_tool_in_sync scripts/red-line-scan.py
assert_tool_in_sync scripts/sql-review-gate.ps1
assert_tool_in_sync scripts/sql-review-gate.py

# Read sqlGate from the index first, then HEAD. Do NOT read the worktree for
# this key: an unstaged edit to false must not be able to switch the gate off.
# An untracked config is treated as legacy (rule presence decides the policy).
SQL_CFG=""
if git cat-file -e :scripts/harness-required.json 2>/dev/null; then
  SQL_CFG=$(git show :scripts/harness-required.json 2>/dev/null)
elif git cat-file -e HEAD:scripts/harness-required.json 2>/dev/null; then
  SQL_CFG=$(git show HEAD:scripts/harness-required.json 2>/dev/null)
fi
SQL_CFG_NORM=$(printf '%s' "$SQL_CFG" | tr -d '[:space:]')
SQL_POLICY=legacy
case "$SQL_CFG_NORM" in
  *'"sqlGate":true'*)  SQL_POLICY=on ;;
  *'"sqlGate":false'*) SQL_POLICY=off ;;
  *'"sqlGate"'*)       SQL_POLICY=on ;;   # unrecognized value: fail closed
esac

# Rule presence: index > HEAD > untracked worktree. If it is tracked in HEAD
# but absent from the index, this commit is deleting it -> treat as missing.
SQL_RULE=0
INDEX_RULE=$(git ls-files -- '.harness/rules/SQL*.md' 2>/dev/null | head -n 1)
HEAD_RULE=$(git ls-tree -r --name-only HEAD -- .harness/rules 2>/dev/null | grep -E 'SQL.*\.md' | head -n 1 || true)
if [ -n "$INDEX_RULE" ]; then
  SQL_RULE=1
elif [ -n "$HEAD_RULE" ]; then
  SQL_RULE=0
else
  for f in "$ROOT"/.harness/rules/SQL*.md; do
    if [ -e "$f" ]; then SQL_RULE=1; break; fi
  done
fi

# Gate presence: index or untracked worktree. A file tracked in HEAD but
# deleted in this commit does not count as available.
SQL_GATE_PS=0
SQL_GATE_PY=0
for p in scripts/sql-review-gate.ps1 scripts/sql-review-gate.py; do
  state=missing
  if git cat-file -e ":$p" 2>/dev/null; then state=index
  elif git cat-file -e "HEAD:$p" 2>/dev/null; then state=head
  elif [ -f "$ROOT/$p" ]; then state=worktree
  fi
  if [ "$state" = "index" ] || [ "$state" = "worktree" ]; then
    case "$p" in
      *.ps1) SQL_GATE_PS=1 ;;
      *.py)  SQL_GATE_PY=1 ;;
    esac
  fi
done

SQL_STATUS=0
SQL_RUN=0
if [ "$SQL_POLICY" = "off" ]; then
  if [ "$SQL_RULE" = "1" ] || [ "$SQL_GATE_PS" = "1" ] || [ "$SQL_GATE_PY" = "1" ]; then
    echo "[FAIL] sqlGate=false but SQL rule/gate artifacts are still present." >&2
    echo "       delete them, or set sqlGate=true." >&2
    SQL_STATUS=1
  fi
elif [ "$SQL_POLICY" = "on" ] && [ "$SQL_RULE" = "0" ]; then
  echo "[FAIL] sqlGate is enabled but .harness/rules/SQL*.md is missing." >&2
  echo "       restore the rule, or set sqlGate=false and remove the gate artifacts." >&2
  SQL_STATUS=1
elif [ "$SQL_RULE" = "1" ] && [ "$SQL_GATE_PS" = "0" ] && [ "$SQL_GATE_PY" = "0" ]; then
  echo "[FAIL] SQL rule present but no sql-review-gate (ps1/py) is tracked or present." >&2
  SQL_STATUS=1
elif [ "$SQL_RULE" = "0" ] && { [ "$SQL_GATE_PS" = "1" ] || [ "$SQL_GATE_PY" = "1" ]; }; then
  echo "[FAIL] sql-review-gate is present but .harness/rules/SQL*.md is missing." >&2
  echo "       restore the rule, or delete the leftover gate scripts." >&2
  SQL_STATUS=1
elif [ "$SQL_RULE" = "1" ]; then
  SQL_RUN=1
fi

if [ "$SQL_STATUS" -ne 0 ]; then
  gate_fail 'SQL gate configuration is inconsistent'
fi

if [ ! -s "$DIFF_FILE" ]; then
  printf '{"event":"scan","ts":"%s","blocked":0,"files":%s,"hunks":0}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$FILES_N" >> "$ROOT/.harness/metrics/gate.jsonl" 2>/dev/null
  git write-tree > "$GIT_DIR/harness-gate-ok" 2>/dev/null
  rm -f "$DIFF_FILE"
  exit 0
fi

if [ "$MODE" = "ps" ]; then
  powershell -NoProfile -ExecutionPolicy Bypass -File "$ROOT/scripts/red-line-scan.ps1" -Root "$ROOT" -DiffFile "$DIFF_FILE"
  STATUS=$?
elif [ "$MODE" = "pwsh" ]; then
  pwsh -NoProfile -File "$ROOT/scripts/red-line-scan.ps1" -Root "$ROOT" -DiffFile "$DIFF_FILE"
  STATUS=$?
elif [ "$MODE" = "py3" ]; then
  python3 "$ROOT/scripts/red-line-scan.py" --root "$ROOT" --diff-file "$DIFF_FILE"
  STATUS=$?
else
  python "$ROOT/scripts/red-line-scan.py" --root "$ROOT" --diff-file "$DIFF_FILE"
  STATUS=$?
fi

# SQL gate run. The policy/presence checks above decided SQL_RUN; only the
# actual enforcement is deferred until the added lines are known.
if [ "$SQL_RUN" = "1" ]; then
  # Pick the runtime independently of MODE: the red-line scanner may only have
  # PowerShell while the SQL gate ships a .py, and vice versa.
  if [ "$SQL_GATE_PS" = "1" ] && [ -f "$ROOT/scripts/sql-review-gate.ps1" ] && command -v powershell >/dev/null 2>&1; then
    powershell -NoProfile -ExecutionPolicy Bypass -File "$ROOT/scripts/sql-review-gate.ps1" -Root "$ROOT" -DiffFile "$DIFF_FILE"
    SQL_STATUS=$?
  elif [ "$SQL_GATE_PS" = "1" ] && [ -f "$ROOT/scripts/sql-review-gate.ps1" ] && command -v pwsh >/dev/null 2>&1; then
    pwsh -NoProfile -File "$ROOT/scripts/sql-review-gate.ps1" -Root "$ROOT" -DiffFile "$DIFF_FILE"
    SQL_STATUS=$?
  elif [ "$SQL_GATE_PY" = "1" ] && [ -f "$ROOT/scripts/sql-review-gate.py" ] && command -v python3 >/dev/null 2>&1; then
    python3 "$ROOT/scripts/sql-review-gate.py" --root "$ROOT" --diff-file "$DIFF_FILE"
    SQL_STATUS=$?
  elif [ "$SQL_GATE_PY" = "1" ] && [ -f "$ROOT/scripts/sql-review-gate.py" ] && command -v python >/dev/null 2>&1; then
    python "$ROOT/scripts/sql-review-gate.py" --root "$ROOT" --diff-file "$DIFF_FILE"
    SQL_STATUS=$?
  else
    echo "[FAIL] SQL gate is present but no runnable sql-review-gate (ps1/py) is available on this machine." >&2
    echo "       install PowerShell or python, or set sqlGate=false and remove the SQL artifacts." >&2
    SQL_STATUS=1
  fi
fi

# Summary field check: only summaries that are part of THIS commit are checked,
# so an old unfinished task never blocks an unrelated commit. The template is
# skipped on purpose (it ships placeholders). A missing check-summary.ps1 is a
# misconfiguration (FAIL); only a missing PowerShell host is a WARN, because the
# script is shipped and required but the runtime is a machine limitation.
#
# Stage=initial on purpose. The hook fires on every commit, including WIP ones;
# demanding lesson_id / sql_review at that point turns the gate into a nuisance
# and invites --no-verify (which pollutes the bypass rate). Close-out fields are
# enforced where closing actually happens: stage-gate stage 10 (-Stage final).
#
# The staged blob is read with `git show :path`, not the working tree: editing a
# good file after `git add` used to satisfy the gate while the bad version was
# what actually got committed.
SUMMARY_STATUS=0
SUMMARY_LIST=$(printf '%s\n' "$CHANGED_FILES" | grep -E '^\.harness/changes/[^/]+/summary\.md$' | grep -v '^\.harness/changes/_template/' || true)
if [ -n "$SUMMARY_LIST" ]; then
  if [ ! -f "$ROOT/scripts/check-summary.ps1" ]; then
    echo "[FAIL] summary field check is misconfigured: scripts/check-summary.ps1 is missing." >&2
    SUMMARY_STATUS=1
  elif command -v powershell >/dev/null 2>&1; then
    SUMMARY_TMP="$GIT_DIR/harness-summary-check.tmp"
    while IFS= read -r s; do
      [ -z "$s" ] && continue
      if ! git show ":$s" > "$SUMMARY_TMP" 2>/dev/null; then
        echo "[FAIL] cannot read staged summary: $s" >&2
        SUMMARY_STATUS=1
        continue
      fi
      powershell -NoProfile -ExecutionPolicy Bypass -File "$ROOT/scripts/check-summary.ps1" -Root "$ROOT" -File "$SUMMARY_TMP" -Stage initial
      if [ $? -ne 0 ]; then SUMMARY_STATUS=1; fi
    done <<EOF
$SUMMARY_LIST
EOF
    rm -f "$SUMMARY_TMP"
  elif command -v pwsh >/dev/null 2>&1; then
    SUMMARY_TMP="$GIT_DIR/harness-summary-check.tmp"
    while IFS= read -r s; do
      [ -z "$s" ] && continue
      if ! git show ":$s" > "$SUMMARY_TMP" 2>/dev/null; then
        echo "[FAIL] cannot read staged summary: $s" >&2
        SUMMARY_STATUS=1
        continue
      fi
      pwsh -NoProfile -File "$ROOT/scripts/check-summary.ps1" -Root "$ROOT" -File "$SUMMARY_TMP" -Stage initial
      if [ $? -ne 0 ]; then SUMMARY_STATUS=1; fi
    done <<EOF
$SUMMARY_LIST
EOF
    rm -f "$SUMMARY_TMP"
  else
    echo "[WARN] summary field check skipped: no PowerShell host." >&2
  fi
fi
rm -f "$DIFF_FILE"

if [ $STATUS -ne 0 ] || [ $SQL_STATUS -ne 0 ] || [ $SUMMARY_STATUS -ne 0 ]; then
  printf '{"event":"scan","ts":"%s","blocked":1,"files":%s,"hunks":%s}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$FILES_N" "$HUNKS_N" >> "$ROOT/.harness/metrics/gate.jsonl" 2>/dev/null
  echo ""
  echo "harness gate blocked: fix red lines, complete the summary fields, or add a sql_review note for SQL changes."
  echo "(--no-verify bypasses this gate; the bypass is counted by scripts/metrics.ps1.)"
  exit 1
fi

printf '{"event":"scan","ts":"%s","blocked":0,"files":%s,"hunks":%s}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$FILES_N" "$HUNKS_N" >> "$ROOT/.harness/metrics/gate.jsonl" 2>/dev/null
git write-tree > "$GIT_DIR/harness-gate-ok" 2>/dev/null
exit 0
'@ -replace "`r`n", "`n"

if (Test-Path -LiteralPath $hookPath) {
    $backup = "$hookPath.bak-harness"
    # -WhatIf must not write anything, including the backup. The backup is part
    # of the change, so it sits under the same ShouldProcess gate as the hook.
    if (-not (Test-Path -LiteralPath $backup) -and $PSCmdlet.ShouldProcess($backup, 'back up the existing pre-commit hook')) {
        Copy-Item -LiteralPath $hookPath -Destination $backup
        Write-Host "existing pre-commit backed up to $backup"
    }
}

if ($PSCmdlet.ShouldProcess($hookPath, 'write pre-commit hook')) {
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($hookPath, $hookBody, $utf8NoBom)
    # Git on Unix ignores a hook that is not executable; chmod does not exist on Windows.
    if (Get-Command chmod -ErrorAction SilentlyContinue) { & chmod +x $hookPath }
    Write-Host "installed: $hookPath" -ForegroundColor Green
}

# post-commit: records a commit event. metrics.ps1 compares commit events with
# scan events to compute the bypass rate (--no-verify leaves no scan event).
$postPath = Join-Path $hooksDir 'post-commit'
$postBody = @'
#!/bin/sh
# harness post-commit: records whether this commit was covered by the gate.
# pre-commit drops .git/harness-gate-ok on a passing scan; --no-verify leaves none.
ROOT="$(git rev-parse --show-toplevel)"
GIT_DIR="$(git rev-parse --absolute-git-dir 2>/dev/null)"
MARK="$GIT_DIR/harness-gate-ok"
SCANNED=0
if [ -f "$MARK" ]; then
  MT=$(cat "$MARK" 2>/dev/null)
  TREE=$(git rev-parse "HEAD^{tree}" 2>/dev/null)
  if [ -n "$MT" ] && [ "$MT" = "$TREE" ]; then SCANNED=1; fi
  rm -f "$MARK"
fi
mkdir -p "$ROOT/.harness/metrics" 2>/dev/null
printf '{"event":"commit","ts":"%s","hash":"%s","scanned":%s}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(git rev-parse --short HEAD)" "$SCANNED" >> "$ROOT/.harness/metrics/gate.jsonl" 2>/dev/null
exit 0
'@ -replace "`r`n", "`n"

if (Test-Path -LiteralPath $postPath) {
    $postBackup = "$postPath.bak-harness"
    if (-not (Test-Path -LiteralPath $postBackup) -and $PSCmdlet.ShouldProcess($postBackup, 'back up the existing post-commit hook')) {
        Copy-Item -LiteralPath $postPath -Destination $postBackup
    }
}

if ($PSCmdlet.ShouldProcess($postPath, 'write post-commit hook')) {
    $utf8NoBom2 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($postPath, $postBody, $utf8NoBom2)
    if (Get-Command chmod -ErrorAction SilentlyContinue) { & chmod +x $postPath }
    Write-Host "installed: $postPath" -ForegroundColor Green
}

# merge commits bypass pre-commit entirely; git runs pre-merge-commit instead.
$mergePath = Join-Path $hooksDir 'pre-merge-commit'
# Same backup rule as pre-commit: a project may already run its own merge hook,
# and uninstall-harness.ps1 restores .bak-harness for every hook it removes.
if (Test-Path -LiteralPath $mergePath) {
    $mergeBackup = "$mergePath.bak-harness"
    if (-not (Test-Path -LiteralPath $mergeBackup) -and $PSCmdlet.ShouldProcess($mergeBackup, 'back up the existing pre-merge-commit hook')) {
        Copy-Item -LiteralPath $mergePath -Destination $mergeBackup
        Write-Host "existing pre-merge-commit backed up to $mergeBackup"
    }
}
if ($PSCmdlet.ShouldProcess($mergePath, 'write pre-merge-commit hook')) {
    $utf8NoBom3 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($mergePath, $hookBody, $utf8NoBom3)
    if (Get-Command chmod -ErrorAction SilentlyContinue) { & chmod +x $mergePath }
    Write-Host "installed: $mergePath" -ForegroundColor Green
}

Write-Host ""
Write-Host "verify it works:"
Write-Host "  1) introduce a violation on purpose, e.g. add a line containing 'throw new RuntimeException();' to a .java file"
Write-Host "  2) git add -A; git commit -m test   -> the commit must be blocked"
Write-Host "  3) remove the violation and commit again -> it must pass"
Write-Host ""
Write-Host "to remove the gate: run scripts\uninstall-harness.ps1, or delete the three hooks in $hooksDir"
Write-Host "(a .bak-harness copy of any pre-existing hook is restored by uninstall)"
