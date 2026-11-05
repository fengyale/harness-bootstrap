<#
  update-harness.ps1 -- upgrade an installed harness without reinstalling

  WHY
    Re-running step 0 uses Copy-Missing: it never overwrites, so an existing
    project keeps old gate scripts forever. An upgrade needs explicit rules:
    replace package-owned machinery, never touch project assets or history.

  WHAT IT DOES (prints a plan unless -Apply is given)
    scripts/*.ps1, *.py    ADD or UPDATE (the old file is backed up first)
    scripts/*.json         ADD if missing; otherwise MANUAL (project config)
    .harness/rules         ADD missing only (project-owned); the red-line summary
                           file also MERGEs known R5/R6 rows, other rows are kept
    .harness/wiki          ADD missing only
    .harness/modules       ADD missing only
    .harness/skills        README missing -> ADD; installed skill files -> MANUAL,
                           or UPDATE when -UpdateSkills is given. Uninstalled
                           template skills are never added (the install keeps 3-5).
    .harness/changes       _template and _small.md are added when missing; L2/L3
                           history is kept; old L1 summaries are COMPACTed to the
                           upgrade backup (deleted with it after verification)
    AGENTS.md              known framework lines MERGE; other lines are kept
    harness-required.json  known keys MERGE (required / requiredAnyOf / sqlGate)
    platform agents        ADD missing, MANUAL when different
    .harness/lessons.md    moved once from .harness/metrics/lessons.md;
    .harness/lessons-promoted.txt  moved once from .harness/metrics/promoted.txt
                           (both are now tracked team files)
    .gitignore             append missing .harness/metrics/ and .harness/upgrade/
                           lines on -Apply; never rewrite the rest of the file
    .harness/.installed-version   written on -Apply, with one audit line per upgrade
    post-apply             every planned ADD/UPDATE/MOVE must exist on disk, or
                           the upgrade exits 1; a missing verify-harness.ps1 is also
                           a failure (never "verification skipped" + UPDATE OK)
    post-verify            a clean run deletes .harness/upgrade/<stamp>; -KeepBackup
                           keeps it, -SkipVerify always keeps it. -PruneBackups
                           removes older backups after a clean run.

  USAGE
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\update-harness.ps1 `
      -PackagePath D:\path\to\new\harness-bootstrap
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\update-harness.ps1 `
      -PackagePath D:\path\to\new\harness-bootstrap -Apply
    ... -Apply -UpdateSkills
    ... -Apply -SkipHooks -SkipVerify
    ... -Apply -KeepBackup
    ... -Apply -PruneBackups
    ... -Apply -KeepL1          (keep old L1 summary directories)
    ... -Apply -NoMergeKnown    (print AGENTS/JSON deltas only, no known-line merge)

  EXIT CODE
    0 = dry-run completed, or apply finished and verification passed
    1 = invalid input, a copy failed, hook install failed, or verify failed

  NOTE
    Pure ASCII on purpose (PS 5.1 parses .ps1 as ANSI without a BOM).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PackagePath,
    [string]$Root = (Get-Location).Path,
    [switch]$Apply,
    [switch]$UpdateSkills,
    [switch]$SkipHooks,
    [switch]$SkipVerify,
    [switch]$KeepBackup,
    [switch]$PruneBackups,
    [switch]$NoMergeKnown,
    [switch]$KeepL1
)

$ErrorActionPreference = 'Stop'
$MergeKnown = -not $NoMergeKnown

$rootPath = (Resolve-Path -LiteralPath $Root).Path
$pkgPath = (Resolve-Path -LiteralPath $PackagePath).Path
$templates = Join-Path $pkgPath 'templates'

# ---------------------------------------------------------------- validate
$versionFile = Join-Path $pkgPath 'VERSION'
if (-not (Test-Path -LiteralPath $versionFile)) {
    Write-Host "not a harness package (VERSION missing): $pkgPath" -ForegroundColor Red
    exit 1
}
if (-not (Test-Path -LiteralPath (Join-Path $templates 'scripts\stage-gate.ps1'))) {
    Write-Host "not a harness package (templates\scripts missing): $pkgPath" -ForegroundColor Red
    exit 1
}
# The checker itself must be in the package. A truncated package used to result
# in "verification skipped" and UPDATE OK; fail before touching the project.
if (-not (Test-Path -LiteralPath (Join-Path $templates 'scripts\verify-harness.ps1'))) {
    Write-Host "package is incomplete: templates\scripts\verify-harness.ps1 missing" -ForegroundColor Red
    exit 1
}
# A project-level skill install places the package source under .trae/skills.
# Templates are not project assets; warn instead of silently moving/removing a
# directory the user may have committed deliberately.
$projectSkill = Join-Path $rootPath '.trae\skills\harness-bootstrap'
if (Test-Path -LiteralPath $projectSkill) {
    Write-Host '[INFO] project-level harness skill found; templates are package source, not project facts (scans exclude .trae).' -ForegroundColor Yellow
}

if (-not (Test-Path -LiteralPath (Join-Path $rootPath '.harness'))) {
    Write-Host "not an installed harness (.harness missing): $rootPath" -ForegroundColor Red
    exit 1
}

$PS = if (Get-Command powershell -ErrorAction SilentlyContinue) { 'powershell' } else { 'pwsh' }

function Read-Version {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $line = Get-Content -LiteralPath $Path -TotalCount 1 -Encoding UTF8
    if ($line -match '(\d+\.\d+\.\d+)') { return $matches[1] }
    return $null
}

function Get-Hash {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

$newVersion = Read-Version $versionFile
if (-not $newVersion) {
    Write-Host "cannot read a x.y.z version from $versionFile" -ForegroundColor Red
    exit 1
}

# The marker is new; older installs do not have it. Fall back to the skill copy
# in the project so the first upgrade can still name the old version.
$installedVersion = Read-Version (Join-Path $rootPath '.harness\.installed-version')
if (-not $installedVersion) {
    foreach ($p in @(
        (Join-Path $rootPath '.trae\skills\harness-bootstrap\VERSION'),
        (Join-Path $rootPath '.claude\skills\harness-bootstrap\VERSION')
    )) {
        $installedVersion = Read-Version $p
        if ($installedVersion) { break }
    }
}
if (-not $installedVersion) { $installedVersion = 'unknown' }

# --------------------------------------------------------------- plan model
$plan = New-Object System.Collections.Generic.List[object]
function Add-Plan {
    param([string]$Action, [string]$Rel, [string]$Source, [string]$Detail)
    $plan.Add([pscustomobject]@{
        Action = $Action
        Rel    = $Rel
        Source = $Source
        Detail = $Detail
    })
}

# JSON config is project-owned, so the upgrade never rewrites it. It must still
# tell the user WHAT to merge: a new required entry or the sqlGate flag that an
# old install does not have yet is otherwise invisible.
function Get-RequiredDelta {
    param([string]$SourcePath, [string]$DestPath)
    try {
        $src = (Get-Content -LiteralPath $SourcePath -Raw -Encoding UTF8) | ConvertFrom-Json
        $dst = (Get-Content -LiteralPath $DestPath -Raw -Encoding UTF8) | ConvertFrom-Json
        $parts = @()
        $missing = @($src.required | Where-Object { @($dst.required) -notcontains $_ })
        if ($missing.Count -gt 0) { $parts += ('add required: ' + ($missing -join ', ')) }
        $removed = @($dst.required | Where-Object { @($src.required) -notcontains $_ })
        if ($removed.Count -gt 0) { $parts += ('remove required: ' + ($removed -join ', ')) }
        $srcAnyOf = @()
        if (($src.PSObject.Properties.Name -contains 'requiredAnyOf') -and $src.requiredAnyOf) {
            $srcAnyOf = @($src.requiredAnyOf)
        }
        $dstHasAnyOf = (($dst.PSObject.Properties.Name -contains 'requiredAnyOf') -and $dst.requiredAnyOf)
        if ($srcAnyOf.Count -gt 0 -and -not $dstHasAnyOf) {
            $groups = @($srcAnyOf | ForEach-Object { '[' + (@($_ ) -join ' | ') + ']' })
            $parts += ('add requiredAnyOf: ' + ($groups -join ', '))
        }
        $srcHasFlag = ($src.PSObject.Properties.Name -contains 'sqlGate')
        $dstHasFlag = ($dst.PSObject.Properties.Name -contains 'sqlGate')
        if ($srcHasFlag -and -not $dstHasFlag) {
            $parts += ('add sqlGate: ' + [string]$src.sqlGate)
        } elseif ($srcHasFlag -and $dstHasFlag -and ([bool]$src.sqlGate -ne [bool]$dst.sqlGate)) {
            $parts += ('sqlGate differs: project=' + [string]$dst.sqlGate + ' package=' + [string]$src.sqlGate)
        }
        # Old projects that followed the previous "delete the rule" opt-out may
        # have left the gate scripts behind. Without this hint the new pair
        # contract would fail their next verify with no explanation.
        $dstRules = @(Get-ChildItem -LiteralPath (Join-Path $rootPath '.harness\rules') -Filter 'SQL*.md' -File -Force -ErrorAction SilentlyContinue)
        $dstGate = @(
            (Join-Path $rootPath 'scripts\sql-review-gate.ps1'),
            (Join-Path $rootPath 'scripts\sql-review-gate.py')
        ) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }
        if (-not $dstHasFlag -and $dstRules.Count -eq 0 -and @($dstGate).Count -gt 0) {
            $parts += 'legacy SQL opt-out left sql-review-gate.* behind: delete it or add "sqlGate": false'
        }
        return ($parts -join '; ')
    } catch {
        return ('delta unavailable: ' + $_.Exception.Message)
    }
}

# Merge only known framework lines into AGENTS.md; every other project line is
# kept. The markers are ASCII so this script stays pure ASCII.
function Replace-TableThirdCell {
    param([string]$Line, [string]$SourceLine)
    $dstCells = @($Line.Trim().Trim('|') -split '\|' | ForEach-Object { $_.Trim() })
    $srcCells = @($SourceLine.Trim().Trim('|') -split '\|' | ForEach-Object { $_.Trim() })
    if ($dstCells.Count -lt 3 -or $srcCells.Count -lt 3) { return $Line }
    return '| ' + $dstCells[0] + ' | ' + $dstCells[1] + ' | ' + $srcCells[2] + ' |'
}

function Merge-AgentsKnown {
    param([string]$Dst, [string]$Src)
    $srcLines = [System.IO.File]::ReadAllLines($Src, [System.Text.Encoding]::UTF8)
    $dstLines = [System.IO.File]::ReadAllLines($Dst, [System.Text.Encoding]::UTF8)
    $srcRed = @($srcLines | Where-Object { $_ -match 'red-line-scan\.ps1' -and $_ -match 'DiffFromStdin' })[0]
    $srcR5 = @($srcLines | Where-Object { $_ -match '^\| R5 ' })[0]
    $srcR6 = @($srcLines | Where-Object { $_ -match '^\| R6 ' })[0]
    $srcSummary = @($srcLines | Where-Object { $_ -match 'check-summary\.ps1' -and $_ -match '_small\.md' -and $_ -match 'Stage initial' })[0]
    $srcSql = @($srcLines | Where-Object { $_ -match 'sql_review' -and $_ -match '\.harness/rules/SQL' })[0]
    $srcTask = @($srcLines | Where-Object { $_ -match 'lesson_id' -and $_ -match 'pre-commit' })[0]

    $out = @()
    $changed = $false
    foreach ($line in $dstLines) {
        if ($srcRed -and $line -match '^\|' -and $line -match 'red-line-scan\.ps1' -and $line -match '-Files') {
            if ($line -ne $srcRed) { $changed = $true }
            $out += $srcRed; continue
        }
        if ($srcR5 -and $line -match '^\| R5 ') {
            $new = Replace-TableThirdCell $line $srcR5
            if ($new -ne $line) { $changed = $true }
            $out += $new; continue
        }
        if ($srcR6 -and $line -match '^\| R6 ') {
            $new = Replace-TableThirdCell $line $srcR6
            if ($new -ne $line) { $changed = $true }
            $out += $new; continue
        }
        if ($srcSummary -and $line -match 'check-summary\.ps1' -and $line -match 'Stage initial' -and $line -match 'summary\.md') {
            if ($line -ne $srcSummary) { $changed = $true }
            $out += $srcSummary; continue
        }
        if ($srcSql -and $line -match 'sql_review' -and $line -match 'pre-commit') {
            if ($line -ne $srcSql) { $changed = $true }
            $out += $srcSql; continue
        }
        if ($srcTask -and $line -match 'lesson_id' -and $line -match 'pre-commit') {
            if ($line -ne $srcTask) { $changed = $true }
            $out += $srcTask; continue
        }
        $out += $line
    }
    if ($changed) {
        [System.IO.File]::WriteAllText($Dst, (($out -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
    }
    return $changed
}

# Same known-row merge for the project's coding-rules red-line summary: only
# the scripted-check cell of R5/R6 is framework-owned, the rule names are kept.
# The target is identified by its R5/R6 table rows, not by file name, so this
# script can stay pure ASCII (the real file name is Chinese).
function Test-RedlineTable {
    param([string]$Path)
    $lines = [System.IO.File]::ReadAllLines($Path, [System.Text.Encoding]::UTF8)
    $r5 = @($lines | Where-Object { $_ -match '^\| R5 ' }).Count
    $r6 = @($lines | Where-Object { $_ -match '^\| R6 ' }).Count
    return ($r5 -gt 0 -and $r6 -gt 0)
}

function Merge-RedlineRows {
    param([string]$Dst, [string]$Src)
    $srcLines = [System.IO.File]::ReadAllLines($Src, [System.Text.Encoding]::UTF8)
    $dstLines = [System.IO.File]::ReadAllLines($Dst, [System.Text.Encoding]::UTF8)
    $srcR5 = @($srcLines | Where-Object { $_ -match '^\| R5 ' })[0]
    $srcR6 = @($srcLines | Where-Object { $_ -match '^\| R6 ' })[0]
    $out = @()
    $changed = $false
    foreach ($line in $dstLines) {
        if ($srcR5 -and $line -match '^\| R5 ') {
            $new = Replace-TableThirdCell $line $srcR5
            if ($new -ne $line) { $changed = $true }
            $out += $new; continue
        }
        if ($srcR6 -and $line -match '^\| R6 ') {
            $new = Replace-TableThirdCell $line $srcR6
            if ($new -ne $line) { $changed = $true }
            $out += $new; continue
        }
        $out += $line
    }
    if ($changed) {
        [System.IO.File]::WriteAllText($Dst, (($out -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
    }
    return $changed
}

# Merge known keys into scripts/harness-required.json; keep every project-owned
# key and value that is not part of the known set.
function Merge-RequiredJson {
    param([string]$Dst, [string]$Src)
    $src = (Get-Content -LiteralPath $Src -Raw -Encoding UTF8) | ConvertFrom-Json
    $dst = (Get-Content -LiteralPath $Dst -Raw -Encoding UTF8) | ConvertFrom-Json
    $req = @($dst.required)
    foreach ($r in @($src.required)) {
        if ($req -notcontains $r) { $req += $r }
    }
    # The scanner moved from required to requiredAnyOf in 1.25.
    $req = @($req | Where-Object { $_ -ne 'scripts/red-line-scan.ps1' })
    if ($dst.PSObject.Properties.Name -contains 'required') { $dst.required = $req }
    else { $dst | Add-Member -NotePropertyName required -NotePropertyValue $req }
    if (($src.PSObject.Properties.Name -contains 'requiredAnyOf') -and
        -not ($dst.PSObject.Properties.Name -contains 'requiredAnyOf')) {
        $dst | Add-Member -NotePropertyName requiredAnyOf -NotePropertyValue $src.requiredAnyOf
    }
    if (($src.PSObject.Properties.Name -contains 'sqlGate') -and
        -not ($dst.PSObject.Properties.Name -contains 'sqlGate')) {
        $dst | Add-Member -NotePropertyName sqlGate -NotePropertyValue $src.sqlGate
    }
    [System.IO.File]::WriteAllText($Dst, (($dst | ConvertTo-Json -Depth 10) + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
    return $true
}

# ------------------------------------------------------- scripts: machinery
# .ps1 is package-owned: replace it. *.json is project configuration (red
# lines, stage thresholds, required files), so it is never overwritten.
$srcScripts = Join-Path $templates 'scripts'
foreach ($src in Get-ChildItem -LiteralPath $srcScripts -File -Force) {
    $rel = 'scripts\' + $src.Name
    $dst = Join-Path $rootPath $rel
    if (-not (Test-Path -LiteralPath $dst)) {
        Add-Plan 'ADD' $rel $src.FullName 'new file'
        continue
    }
    $same = (Get-Hash $src.FullName) -eq (Get-Hash $dst)
    if ($same) { Add-Plan 'SAME' $rel $src.FullName ''; continue }
    if ($src.Extension -eq '.ps1' -or $src.Extension -eq '.py') {
        Add-Plan 'UPDATE' $rel $src.FullName 'package-owned script'
    } else {
        $mergeJson = ($MergeKnown -and $src.Name -eq 'harness-required.json')
        $detail = if ($mergeJson) { 'known keys merged automatically; other keys kept' } else { 'project config may be edited; merge new keys by hand' }
        if ($src.Name -eq 'harness-required.json') {
            $delta = Get-RequiredDelta $src.FullName $dst
            if ($delta) { $detail = $detail + '; ' + $delta }
        }
        $action = if ($mergeJson) { 'MERGE' } else { 'MANUAL' }
        Add-Plan $action $rel $src.FullName $detail
    }
}

# ------------------------------------------------- project assets: add only
foreach ($sub in @('rules', 'wiki', 'modules')) {
    $srcDir = Join-Path $templates ('.harness\' + $sub)
    if (-not (Test-Path -LiteralPath $srcDir)) { continue }
    # -Name returns paths relative to $srcDir. Building the relative path with
    # Substring(FullName, Length) breaks when the two forms use different short
    # (8.3) names, which is exactly what happens on GitHub Actions runners.
    foreach ($relPath in Get-ChildItem -LiteralPath $srcDir -Recurse -File -Force -Name) {
        $src = Join-Path $srcDir $relPath
        $rel = '.harness\' + $sub + '\' + $relPath
        $dst = Join-Path $rootPath $rel
        if (-not (Test-Path -LiteralPath $dst)) {
            Add-Plan 'ADD' $rel $src 'new project asset'
        } elseif ((Get-Hash $src) -eq (Get-Hash $dst)) {
            Add-Plan 'SAME' $rel $src ''
        } elseif ($MergeKnown -and $sub -eq 'rules' -and (Test-RedlineTable $src) -and
                  (Test-RedlineTable $dst)) {
            Add-Plan 'MERGE' $rel $src 'known red-line rows merged; other content kept'
        } else {
            Add-Plan 'SKIP' $rel $src 'project-owned; kept as-is'
        }
    }
}

# ------------------------------------------- skills: installed bodies only
# The install deliberately keeps 3-5 skills, so a missing template skill is
# NOT added here. Only files the project already has are compared; with
# -UpdateSkills they are replaced (old copies go to .harness/upgrade).
$srcSkills = Join-Path $templates '.harness\skills'
if (Test-Path -LiteralPath $srcSkills) {
    $readmeSrc = Join-Path $srcSkills 'README.md'
    $readmeRel = '.harness\skills\README.md'
    $readmeDst = Join-Path $rootPath $readmeRel
    if (Test-Path -LiteralPath $readmeSrc) {
        if (-not (Test-Path -LiteralPath $readmeDst)) {
            Add-Plan 'ADD' $readmeRel $readmeSrc 'skill index missing'
        } elseif ((Get-Hash $readmeSrc) -eq (Get-Hash $readmeDst)) {
            Add-Plan 'SAME' $readmeRel $readmeSrc ''
        } elseif ($UpdateSkills) {
            Add-Plan 'UPDATE' $readmeRel $readmeSrc 'skill index replaced (-UpdateSkills)'
        } else {
            Add-Plan 'MANUAL' $readmeRel $readmeSrc 'installed skill index differs; re-run with -UpdateSkills to replace'
        }
    }
    # -Name avoids the short/long path mismatch noted above.
    foreach ($relPath in Get-ChildItem -LiteralPath $srcSkills -Recurse -File -Force -Name) {
        if ($relPath -eq 'README.md') { continue }
        $src = Join-Path $srcSkills $relPath
        $rel = '.harness\skills\' + $relPath
        $dst = Join-Path $rootPath $rel
        if (-not (Test-Path -LiteralPath $dst)) { continue }
        if ((Get-Hash $src) -eq (Get-Hash $dst)) {
            Add-Plan 'SAME' $rel $src ''
        } elseif ($UpdateSkills) {
            Add-Plan 'UPDATE' $rel $src 'installed skill replaced (-UpdateSkills)'
        } else {
            Add-Plan 'MANUAL' $rel $src 'installed skill differs; review or re-run with -UpdateSkills'
        }
    }
}

# Only the change template is added; real change records are history.
$srcTpl = Join-Path $templates '.harness\changes\_template'
if (Test-Path -LiteralPath $srcTpl) {
    foreach ($relPath in Get-ChildItem -LiteralPath $srcTpl -Recurse -File -Force -Name) {
        $src = Join-Path $srcTpl $relPath
        $rel = '.harness\changes\_template\' + $relPath
        $dst = Join-Path $rootPath $rel
        if (-not (Test-Path -LiteralPath $dst)) {
            Add-Plan 'ADD' $rel $src 'missing change template'
        } else {
            Add-Plan 'SKIP' $rel $src 'template exists; kept'
        }
    }
}
# L1 rolling record: add the template only when the project has none; never
# touch an existing _small.md (it contains real records).
$srcSmall = Join-Path $templates '.harness\changes\_small.md'
if (Test-Path -LiteralPath $srcSmall) {
    $rel = '.harness\changes\_small.md'
    $dst = Join-Path $rootPath $rel
    if (-not (Test-Path -LiteralPath $dst)) {
        Add-Plan 'ADD' $rel $srcSmall 'missing L1 small-record template'
    } else {
        Add-Plan 'SKIP' $rel $srcSmall 'small-record file exists; kept'
    }
}
# Old L1 summaries were the pre-1.25 way of recording small changes. Move them
# into the upgrade backup; a verified upgrade then deletes that backup, which is
# the requested "default delete". -KeepL1 keeps them in place.
if (-not $KeepL1) {
    $changesRoot = Join-Path $rootPath '.harness\changes'
    if (Test-Path -LiteralPath $changesRoot) {
        Get-ChildItem -LiteralPath $changesRoot -Directory -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne '_template' } |
            ForEach-Object {
                $summary = Join-Path $_.FullName 'summary.md'
                if (-not (Test-Path -LiteralPath $summary)) { return }
                $text = [System.IO.File]::ReadAllText($summary, [System.Text.Encoding]::UTF8)
                if ($text -match '(?m)^[ \t]*(?:[-*][ \t]+)?(?:[^\r\n:\uFF1A]*?[:\uFF1A][ \t]*`?`?)?`?`?flow:\s*`?\s*L1\b') {
                    Add-Plan 'COMPACT' ('.harness\changes\' + $_.Name) $_.FullName 'old L1 summary; moved to upgrade backup and deleted with it after verification'
                }
            }
    }
}
Add-Plan 'KEEP' '.harness\changes' '' 'L2/L3 task history is never touched; old L1 summaries are compacted'
Add-Plan 'KEEP' '.harness\metrics' '' 'gate log is never touched; lessons/promoted files are migrated to .harness/'

# Durable team files moved out of the gitignored metrics directory so every
# clone sees the same lesson ids and promotion status. Migrate the old
# .harness/metrics copies once, then metrics.ps1 uses the tracked files.
$migrations = @(
    @{ Old = '.harness\metrics\lessons.md'; New = '.harness\lessons.md'; Label = 'lessons index' },
    @{ Old = '.harness\metrics\promoted.txt'; New = '.harness\lessons-promoted.txt'; Label = 'promoted lessons' }
)
foreach ($m in $migrations) {
    $old = Join-Path $rootPath $m.Old
    $new = Join-Path $rootPath $m.New
    if (Test-Path -LiteralPath $old) {
        if (-not (Test-Path -LiteralPath $new)) {
            Add-Plan 'MOVE' $m.New $old ('migrate ' + $m.Label + ' from .harness/metrics (now tracked)')
        } else {
            Add-Plan 'MANUAL' $m.New $old ('old metrics copy of ' + $m.Label + ' exists; tracked file kept')
        }
    }
}
# A project with no old metrics copy still needs the tracked promoted list.
$srcPromoted = Join-Path $templates '.harness\lessons-promoted.txt'
$newPromoted = Join-Path $rootPath '.harness\lessons-promoted.txt'
$oldPromoted = Join-Path $rootPath '.harness\metrics\promoted.txt'
if ((Test-Path -LiteralPath $srcPromoted) -and
    -not (Test-Path -LiteralPath $newPromoted) -and
    -not (Test-Path -LiteralPath $oldPromoted)) {
    Add-Plan 'ADD' '.harness\lessons-promoted.txt' $srcPromoted 'missing promoted-lesson list'
}

# ------------------------------------------------------------- AGENTS.md
$srcAgents = Join-Path $templates 'AGENTS.md'
$dstAgents = Join-Path $rootPath 'AGENTS.md'
if (Test-Path -LiteralPath $srcAgents) {
    if (-not (Test-Path -LiteralPath $dstAgents)) {
        Add-Plan 'ADD' 'AGENTS.md' $srcAgents 'entry file missing'
    } elseif ((Get-Hash $srcAgents) -eq (Get-Hash $dstAgents)) {
        Add-Plan 'SAME' 'AGENTS.md' $srcAgents ''
    } else {
        $action = if ($MergeKnown) { 'MERGE' } else { 'MANUAL' }
        Add-Plan $action 'AGENTS.md' $srcAgents 'known framework lines merged; other lines kept'
    }
}

# ------------------------------------------------------- platform agents
$agentRel = $null
if (Test-Path -LiteralPath (Join-Path $rootPath '.trae')) { $agentRel = '.trae\agents' }
elseif (Test-Path -LiteralPath (Join-Path $rootPath '.claude')) { $agentRel = '.claude\agents' }
$srcAgentsDir = Join-Path $templates '.trae\agents'
if (Test-Path -LiteralPath $srcAgentsDir) {
    if ($null -eq $agentRel) {
        Add-Plan 'MANUAL' '.trae/agents' $srcAgentsDir 'no platform dir found; copy agents by hand if needed'
    } else {
        foreach ($src in Get-ChildItem -LiteralPath $srcAgentsDir -File -Force) {
            $rel = $agentRel + '\' + $src.Name
            $dst = Join-Path $rootPath $rel
            if (-not (Test-Path -LiteralPath $dst)) {
                Add-Plan 'ADD' $rel $src.FullName 'new agent'
            } elseif ((Get-Hash $src.FullName) -eq (Get-Hash $dst)) {
                Add-Plan 'SAME' $rel $src.FullName ''
            } else {
                Add-Plan 'MANUAL' $rel $src.FullName 'may be edited by you; compare and merge'
            }
        }
    }
}

# ------------------------------------------------------------- .gitignore
$dstIgnore = Join-Path $rootPath '.gitignore'
$srcIgnore = Join-Path $templates '.gitignore'
if (-not (Test-Path -LiteralPath $dstIgnore)) {
    if (Test-Path -LiteralPath $srcIgnore) { Add-Plan 'ADD' '.gitignore' $srcIgnore 'missing file' }
} else {
    $lines = @([System.IO.File]::ReadAllLines($dstIgnore, [System.Text.Encoding]::UTF8) | ForEach-Object { $_.Trim() })
    $needed = @('.harness/metrics/', '.harness/upgrade/')
    $missingIgnore = @($needed | Where-Object { $lines -notcontains $_ })
    if ($missingIgnore.Count -eq 0) { Add-Plan 'SAME' '.gitignore' $srcIgnore '' }
    else { Add-Plan 'MANUAL' '.gitignore' $srcIgnore ('add by hand: ' + ($missingIgnore -join ', ')) }
}

# -------------------------------------------------------------------- print
Write-Host ''
Write-Host "update harness: $rootPath" -ForegroundColor Cyan
Write-Host "package:        $pkgPath"
Write-Host "version:        $installedVersion -> $newVersion"
Write-Host ("mode:           " + $(if ($Apply) { 'APPLY' } else { 'DRY-RUN (add -Apply to execute)' }))
Write-Host ('-' * 64)

$counts = @{ ADD = 0; UPDATE = 0; SAME = 0; SKIP = 0; MANUAL = 0; KEEP = 0; MERGE = 0; MOVE = 0; COMPACT = 0 }
foreach ($p in $plan) {
    if ($p.Action -eq 'SAME') { continue }
    $counts[$p.Action]++
    $color = switch ($p.Action) {
        'UPDATE' { 'Yellow' }
        'ADD'    { 'Green' }
        'MANUAL' { 'Magenta' }
        'KEEP'   { 'DarkGray' }
        default  { 'Gray' }
    }
    Write-Host ("[{0}] {1}" -f $p.Action.PadRight(6), $p.Rel) -ForegroundColor $color
    if ($p.Detail) { Write-Host ("         " + $p.Detail) -ForegroundColor DarkGray }
}
Write-Host ('-' * 64)
Write-Host ("add={0} update={1} merge={2} move={3} compact={4} skip={5} manual={6} keep={7} same={8}" -f `
    $counts.ADD, $counts.UPDATE, $counts.MERGE, $counts.MOVE, $counts.COMPACT,
    $counts.SKIP, $counts.MANUAL, $counts.KEEP,
    @($plan | Where-Object { $_.Action -eq 'SAME' }).Count)

if (-not $Apply) {
    Write-Host ''
    Write-Host 'No file changed. Re-run with -Apply to execute the plan.' -ForegroundColor Yellow
    exit 0
}

# -------------------------------------------------------------------- apply
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backupRoot = Join-Path $rootPath ('.harness\upgrade\' + $stamp)
New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null
$manifest = New-Object System.Collections.Generic.List[string]
$dirtyReplacements = @()

# A file with uncommitted changes may be the only copy of that change. The
# backup is then the only rollback point, so a verified upgrade must not delete
# it. Non-git projects are treated as "cannot tell" and keep the default
# delete-after-verify behaviour; use -KeepBackup there.
function Test-DirtyPath {
    param([string]$Rel)
    try {
        $inside = & git -C $rootPath rev-parse --is-inside-work-tree 2>$null
        if ($LASTEXITCODE -ne 0 -or ([string]$inside).Trim() -ne 'true') { return $false }
        $status = & git -C $rootPath status --porcelain -- $Rel 2>$null
        if ($LASTEXITCODE -ne 0) { return $true }
        return (@($status).Count -gt 0)
    } catch {
        return $false
    }
}
$failed = 0

foreach ($p in $plan) {
    if ($p.Action -eq 'ADD') {
        $dst = Join-Path $rootPath $p.Rel
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) | Out-Null
        try {
            Copy-Item -LiteralPath $p.Source -Destination $dst
            # A copy that returns without an error can still leave no destination
            # (locked file, external cleanup, truncated copy). Compare the hash,
            # not just existence, before claiming the upgrade is complete.
            if (-not (Test-Path -LiteralPath $dst -PathType Leaf)) { throw 'copy succeeded but destination is missing' }
            if ((Get-Hash $dst) -ne (Get-Hash $p.Source)) { throw 'copy hash mismatch (truncated or partial file)' }
            $manifest.Add(('ADD {0}' -f $p.Rel))
        } catch {
            Write-Host ("[FAIL] copy {0}: {1}" -f $p.Rel, $_.Exception.Message) -ForegroundColor Red
            $failed++
        }
    } elseif ($p.Action -eq 'UPDATE') {
        $dst = Join-Path $rootPath $p.Rel
        $bak = Join-Path $backupRoot $p.Rel
        if (Test-DirtyPath $p.Rel) { $dirtyReplacements += $p.Rel }
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $bak) | Out-Null
        try {
            Copy-Item -LiteralPath $dst -Destination $bak
            Copy-Item -LiteralPath $p.Source -Destination $dst -Force
            if (-not (Test-Path -LiteralPath $dst -PathType Leaf)) { throw 'update copy succeeded but destination is missing' }
            if ((Get-Hash $dst) -ne (Get-Hash $p.Source)) { throw 'update copy hash mismatch (truncated or partial file)' }
            $manifest.Add(('UPDATE {0} (old copy in backup)' -f $p.Rel))
        } catch {
            Write-Host ("[FAIL] update {0}: {1}" -f $p.Rel, $_.Exception.Message) -ForegroundColor Red
            $failed++
        }
    } elseif ($p.Action -eq 'MOVE') {
        $dst = Join-Path $rootPath $p.Rel
        try {
            if (Test-Path -LiteralPath $dst) { throw 'destination appeared after plan; refusing to overwrite' }
            Copy-Item -LiteralPath $p.Source -Destination $dst
            if (-not (Test-Path -LiteralPath $dst -PathType Leaf)) { throw 'migrated file is missing' }
            if ((Get-Hash $dst) -ne (Get-Hash $p.Source)) { throw 'migrated file hash mismatch' }
            Remove-Item -LiteralPath $p.Source -Force
            $manifest.Add(('MOVE {0} (from .harness/metrics; old removed)' -f $p.Rel))
        } catch {
            Write-Host ("[FAIL] move {0}: {1}" -f $p.Rel, $_.Exception.Message) -ForegroundColor Red
            $failed++
        }
    } elseif ($p.Action -eq 'MERGE') {
        $dst = Join-Path $rootPath $p.Rel
        $bak = Join-Path $backupRoot $p.Rel
        try {
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $bak) | Out-Null
            Copy-Item -LiteralPath $dst -Destination $bak
            if ($p.Rel -eq 'scripts\harness-required.json') {
                Merge-RequiredJson $dst $p.Source | Out-Null
                $manifest.Add(('MERGE {0} (known keys; old copy in backup)' -f $p.Rel))
            } elseif ($p.Rel -eq 'AGENTS.md') {
                $merged = Merge-AgentsKnown $dst $p.Source
                if ($merged) { $manifest.Add(('MERGE {0} (known lines; old copy in backup)' -f $p.Rel)) }
                else { $manifest.Add(('KEEP {0} (no known lines matched)' -f $p.Rel)) }
            } elseif (Test-RedlineTable $p.Source) {
                $merged = Merge-RedlineRows $dst $p.Source
                if ($merged) { $manifest.Add(('MERGE {0} (known red-line rows; old copy in backup)' -f $p.Rel)) }
                else { $manifest.Add(('KEEP {0} (R5/R6 already current)' -f $p.Rel)) }
            } else {
                throw 'no known-key merger for ' + $p.Rel
            }
        } catch {
            Write-Host ("[FAIL] merge {0}: {1}" -f $p.Rel, $_.Exception.Message) -ForegroundColor Red
            $failed++
        }
    } elseif ($p.Action -eq 'COMPACT') {
        $name = Split-Path -Leaf $p.Source
        $bakDir = Join-Path $backupRoot ('compact\' + $name)
        try {
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $bakDir) | Out-Null
            Move-Item -LiteralPath $p.Source -Destination $bakDir
            $manifest.Add(('COMPACT {0} (moved to backup)' -f $p.Rel))
        } catch {
            Write-Host ("[FAIL] compact {0}: {1}" -f $p.Rel, $_.Exception.Message) -ForegroundColor Red
            $failed++
        }
    }
}

if (-not $SkipHooks) {
    $hookScript = Join-Path $rootPath 'scripts\install-git-hooks.ps1'
    if (Test-Path -LiteralPath $hookScript) {
        Write-Host ''
        Write-Host 'reinstalling git hooks ...' -ForegroundColor Cyan
        & $PS -NoProfile -ExecutionPolicy Bypass -File $hookScript -Root $rootPath
        if ($LASTEXITCODE -ne 0) {
            Write-Host 'hook install failed' -ForegroundColor Red
            $failed++
        }
    } else {
        Write-Host 'scripts\install-git-hooks.ps1 is missing; hooks not reinstalled' -ForegroundColor Yellow
        $failed++
    }
}

$verifyRan = $false
if (-not $SkipVerify) {
    $verify = Join-Path $rootPath 'scripts\verify-harness.ps1'
    if (Test-Path -LiteralPath $verify) {
        $verifyRan = $true
        Write-Host ''
        Write-Host 'verify-harness ...' -ForegroundColor Cyan
        & $PS -NoProfile -ExecutionPolicy Bypass -File $verify -Root $rootPath
        if ($LASTEXITCODE -ne 0) {
            Write-Host 'verify-harness reported failures' -ForegroundColor Red
            $failed++
        }
    } else {
        Write-Host 'scripts\verify-harness.ps1 is missing; verification cannot run: upgrade is incomplete' -ForegroundColor Red
        $failed++
    }
}

# Add only the two runtime-state lines; never rewrite the rest of .gitignore.
function Ensure-Gitignore {
    $path = Join-Path $rootPath '.gitignore'
    if (-not (Test-Path -LiteralPath $path)) { return }
    try {
        $text = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
        $missing = @()
        foreach ($line in @('.harness/metrics/', '.harness/upgrade/')) {
            # Respect both an exact line and any negation under that directory:
            # "!.harness/metrics/" means the team wants that directory tracked.
            if ($text -match ('(?m)^[!]?' + [regex]::Escape($line) + '\s*$')) { continue }
            $neg = '(?m)^!' + [regex]::Escape($line.TrimEnd('/')) + '[\\/]'
            if ($text -match $neg) {
                Write-Host ("[WARN] .gitignore already negates {0}; not adding an ignore line." -f $line) -ForegroundColor Yellow
                continue
            }
            $missing += $line
        }
        if ($missing.Count -eq 0) { return }
        $append = [Environment]::NewLine + '# harness runtime state' + [Environment]::NewLine +
            ($missing -join [Environment]::NewLine) + [Environment]::NewLine
        [System.IO.File]::AppendAllText($path, $append, [System.Text.Encoding]::UTF8)
        Write-Host ("[FIX] .gitignore added: " + ($missing -join ', ')) -ForegroundColor Yellow
    } catch {
        Write-Host ("[WARN] could not update .gitignore: " + $_.Exception.Message) -ForegroundColor Yellow
    }
}

# The manifest records the whole attempt, including hook/verify failures. It
# must be written after those checks, not before.
$manifestPath = Join-Path $backupRoot 'manifest.txt'
$manifestLines = @(
    ('harness upgrade {0} -> {1}' -f $installedVersion, $newVersion),
    ('applied: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')),
    ('failed: {0}' -f $failed),
    ''
) + $manifest
# UTF-8, not ASCII: the manifest carries Chinese file names (rules, skills).
[System.IO.File]::WriteAllText($manifestPath, (($manifestLines -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))

Write-Host ''
if ($failed -gt 0) {
    Write-Host ("UPDATE FINISHED WITH {0} FAILURE(S); see messages above" -f $failed) -ForegroundColor Red
    Write-Host ("backup kept for rollback: {0}" -f $backupRoot) -ForegroundColor Yellow
    Write-Host 'version marker was NOT advanced; fix the failures and re-run the upgrade.' -ForegroundColor Yellow
    exit 1
}

Ensure-Gitignore
$dirtyReplacements = @($dirtyReplacements | Select-Object -Unique)
$unsafeBackup = ($dirtyReplacements.Count -gt 0)
if ($unsafeBackup) {
    Write-Host ("[WARN] backup kept: replaced files had uncommitted changes: " + ($dirtyReplacements -join ', ')) -ForegroundColor Yellow
}
if ($SkipVerify) {
    Write-Host '[WARN] verification skipped; backup kept and the version marker advanced without verification.' -ForegroundColor Yellow
}

# The marker lets the next upgrade name the version it starts from. Advance it
# only after every check passed; otherwise the next upgrade would believe this
# incomplete state is the new version. The third line is the audit trail that
# survives backup deletion.
$verifyState = if ($SkipVerify) { 'skipped' } elseif ($verifyRan) { 'PASS' } else { 'not run' }
$shouldDelete = (-not $KeepBackup -and -not $SkipVerify -and $verifyRan -and -not $unsafeBackup)
if ($KeepBackup) {
    $backupState = "kept: $backupRoot"
} elseif ($SkipVerify -or -not $verifyRan) {
    $backupState = "kept (verification not run): $backupRoot"
} elseif ($unsafeBackup) {
    $backupState = "kept (uncommitted changes: " + ($dirtyReplacements -join ', ') + ")"
} elseif ($shouldDelete) {
    try {
        Remove-Item -LiteralPath $backupRoot -Recurse -Force
        $backupState = 'deleted after verification'
        Write-Host ("backup removed after verification: {0}" -f $backupRoot) -ForegroundColor Green
    } catch {
        $backupState = "kept (delete failed): $backupRoot"
        Write-Host ("[WARN] could not remove backup {0}: {1}" -f $backupRoot, $_.Exception.Message) -ForegroundColor Yellow
    }
} else {
    $backupState = "kept: $backupRoot"
}

$marker = Join-Path $rootPath '.harness\.installed-version'
$markerLines = @(
    $newVersion,
    ('updated: ' + (Get-Date -Format 'yyyy-MM-dd')),
    ("upgraded: {0} -> {1}; verify: {2}; backup: {3}" -f $installedVersion, $newVersion, $verifyState, $backupState)
)
[System.IO.File]::WriteAllText($marker, (($markerLines -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))

if ($PruneBackups) {
    if ($SkipVerify -or -not $verifyRan) {
        Write-Host '[WARN] -PruneBackups ignored: verification was not run; older backups are kept.' -ForegroundColor Yellow
    } else {
        $upgradeDir = Join-Path $rootPath '.harness\upgrade'
        if (Test-Path -LiteralPath $upgradeDir) {
            Get-ChildItem -LiteralPath $upgradeDir -Directory -Force -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.Name -match '^\d{8}-\d{6}$' -and
                    $_.FullName -ne $backupRoot -and
                    -not ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
                } |
                ForEach-Object {
                    try { Remove-Item -LiteralPath $_.FullName -Recurse -Force }
                    catch { Write-Host ("[WARN] could not prune {0}" -f $_.FullName) -ForegroundColor Yellow }
                }
        }
    }
}

Write-Host ("UPDATE OK: {0} -> {1}; backup: {2}" -f $installedVersion, $newVersion, $backupState) -ForegroundColor Green
exit 0
