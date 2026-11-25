<#
  suggest-flow.ps1 -- suggest an L0-L3 flow level from the current diff (read only)

  WHY
    Picking a flow level by feel is where "a small change" turns into an L3 after
    the fact. This script reads what actually changed and prints the level plus
    the two summary fields that are hardest to fill by hand:

        flow: L2
        touched_modules: order, cart

    It also drafts the change-list block of summary.md, grouped into
    database / backend / cache / messaging / frontend / other.

  INPUT
    -Root <dir>       project root (default: current directory)
    -Feature <name>   scope the diff to this feature's touched_modules (default:
                      the .git/harness-current-task pointer written by check-summary)
    (default)         working tree: git status --porcelain + git diff HEAD
    -DiffFromStdin    read a unified diff from stdin
    -Files a,b        explicit changed files (comma list or an array)

  RULES (mirrors .harness/rules/ flow rules section 1.1)
    L0  docs / comments / formatting only
    L1  exactly 1 file, <= 30 changed lines, no public layer / DB / config /
        interface, no SQL
    L2  everything else (SQL without DDL still needs sql-review)
    L3  >= 2 backend modules, public layer, SQL that changes the data shape
        (DDL / migration), a config switch, or a release -- the last one cannot
        be seen in a diff, so add it yourself when the task ships

  OUTPUT
    flow / touched_modules / draft change list / the evidence behind them.
    READ ONLY: no file is written and no git command changes state.

  USAGE
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\suggest-flow.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\suggest-flow.ps1 -Feature order-export
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\suggest-flow.ps1 -Root D:\proj
    git diff | powershell -NoProfile -ExecutionPolicy Bypass -File scripts\suggest-flow.ps1 -DiffFromStdin
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\suggest-flow.ps1 -Files src\a.cs,b.sql
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\suggest-flow.ps1 -SelfTest

  Pure ASCII on purpose: PS 5.1 parses a BOM-less .ps1 as ANSI.
#>
[CmdletBinding()]
param(
    [string]$Root = (Get-Location).Path,
    [string]$Feature = '',
    [switch]$DiffFromStdin,
    [string[]]$Files = @(),
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'

$DocExt    = @('.md', '.txt', '.rst', '.adoc', '.mdx')
$FeExt     = @('.vue', '.jsx', '.tsx', '.css', '.scss', '.sass', '.less', '.html', '.htm')
$FeSeg     = @('frontend', 'front', 'web', 'client', 'ui', 'views', 'pages', 'components', 'static')
$LayerSeg  = @('controller', 'controllers', 'service', 'services', 'impl', 'repository', 'repositories',
               'mapper', 'dao', 'model', 'models', 'entity', 'entities', 'dto', 'vo', 'po', 'util', 'utils')
$PublicSeg = @('common', 'shared', 'core', 'framework', 'infra', 'infrastructure', 'base', 'platform',
               'util', 'utils', 'middleware')
$CfgSeg    = @('config', 'configs', 'conf', 'configuration')
$IfaceSeg  = @('controller', 'controllers', 'api', 'interface', 'interfaces', 'contract', 'contracts',
               'endpoint', 'endpoints')
$MigSeg    = @('migration', 'migrations', 'flyway', 'liquibase')
$ScanExt   = @('.sql', '.java', '.kt', '.cs', '.py', '.js', '.ts', '.vue', '.go', '.xml',
               '.properties', '.yml', '.yaml', '.json')
$SqlDdlRe  = '(?i)\b(CREATE\s+(UNIQUE\s+)?(TABLE|INDEX|VIEW|DATABASE|SCHEMA)|CREATE\s+(PROCEDURE|TRIGGER|FUNCTION)|ALTER\s+(TABLE|INDEX|VIEW)|DROP\s+(TABLE|INDEX|VIEW|DATABASE|COLUMN)|TRUNCATE\s+TABLE|RENAME\s+TABLE)\b'
# Build artifacts and archives are not part of a feature diff. They are skipped
# only in git-status mode; an explicit -Files list is always honoured.
$IgnoreRe  = '(?i)(^|/)(node_modules|target|build|dist|out|\.git|\.idea|\.vscode|logs?)/|\.(zip|jar|war|class|log|tmp)$'
$NoneMarker = [string][char]0x65E0

function New-Cn {
    param([int[]]$Codes)
    $s = ''
    foreach ($c in $Codes) { $s += [char]$c }
    return $s
}

function Read-StdinUtf8 {
    $reader = New-Object System.IO.StreamReader([Console]::OpenStandardInput(), (New-Object System.Text.UTF8Encoding($false)))
    return $reader.ReadToEnd()
}

# "-File script.ps1 -Files a,b" binds the list as ONE string (the shell does not
# split commas), so normalize every element here.
function Split-FileList {
    param([string[]]$Raw)
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($item in @($Raw)) {
        if ($null -eq $item) { continue }
        foreach ($piece in ($item -split ',')) {
            $p = $piece.Trim()
            if ($p) { $out.Add(($p -replace '\\', '/')) }
        }
    }
    return $out.ToArray()
}

function Invoke-Git {
    param([string]$RootPath, [string[]]$ArgList)
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return @() }
    # core.quotepath=false keeps non-ASCII paths unescaped, so a path from
    # "status" matches the same path in "diff --numstat". ErrorActionPreference
    # must drop to Continue for the duration of the call: under 'Stop' a native
    # stderr line (git's "LF will be replaced by CRLF" warning) becomes a
    # terminating error and the whole diff is silently lost.
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $out = @()
    try { $out = @(& git -C $RootPath -c core.quotepath=false @ArgList 2>$null) }
    catch { $out = @() }
    finally { $ErrorActionPreference = $prevEap }
    if ($LASTEXITCODE -ne 0) { return @() }
    return $out
}

function Get-PathFlags {
    param([string]$Path)
    $p = ($Path -replace '\\', '/')
    $seg = @($p.ToLower() -split '/')
    $name = $seg[$seg.Count - 1]
    $ext = [System.IO.Path]::GetExtension($p).ToLower()
    $isDoc = ($DocExt -contains $ext)
    $isFe = ($FeExt -contains $ext)
    if (-not $isFe) {
        foreach ($s in $seg) { if ($FeSeg -contains $s) { $isFe = $true; break } }
    }
    $sqlFile = ($ext -eq '.sql')
    $migDir = $false
    foreach ($s in $seg) { if ($MigSeg -contains $s) { $migDir = $true; break } }
    if ($name -match '(?i)^(db-migrations|rollback)\.sql$') { $migDir = $true }
    $cfgFile = ($name -match '(?i)^(application|bootstrap|app|config|settings)[^/]*\.(yml|yaml|properties|json|ini|toml|conf)$') -or ($name -match '(?i)(^|\.)env(\.|$)')
    $cfgCode = $false
    foreach ($s in $seg) { if ($CfgSeg -contains $s) { $cfgCode = $true; break } }
    $iface = ($name -match '(?i)(controller|api|resource|endpoint)s?\.(java|kt|cs|py|ts|js)$')
    if (-not $iface) { foreach ($s in $seg) { if ($IfaceSeg -contains $s) { $iface = $true; break } } }
    $pub = $false
    foreach ($s in $seg) { if ($PublicSeg -contains $s) { $pub = $true; break } }
    return [pscustomobject]@{
        Doc = $isDoc; Frontend = $isFe; SqlFile = $sqlFile; Migration = $migDir
        ConfigFile = $cfgFile; ConfigCode = $cfgCode; Interface = $iface; Public = $pub
        Ext = $ext; Name = $name; Segments = $seg
    }
}

# Module name for a changed path: a card file name wins, otherwise guess from the
# path (labeled "heuristic" in the report -- never presented as project truth).
function Get-ModuleGuess {
    param([string]$Path, [string[]]$CardNames)
    $seg = @((($Path -replace '\\', '/')).ToLower() -split '/')
    foreach ($card in @($CardNames)) {
        if ($seg -contains $card.ToLower()) { return [pscustomobject]@{ Name = $card; Source = 'card' } }
    }
    $javaIdx = -1
    for ($i = 0; $i -lt $seg.Count - 1; $i++) {
        if ($seg[$i] -eq 'java' -or $seg[$i] -eq 'kotlin' -or $seg[$i] -eq 'scala') { $javaIdx = $i; break }
    }
    if ($javaIdx -ge 0) {
        $rest = @()
        for ($i = $javaIdx + 1; $i -lt $seg.Count - 1; $i++) { $rest += $seg[$i] }
        $keep = @($rest | Where-Object { $LayerSeg -notcontains $_ })
        if ($keep.Count -gt 0) { return [pscustomobject]@{ Name = $keep[$keep.Count - 1]; Source = 'heuristic' } }
    }
    if ($seg.Count -ge 2 -and ($seg[0] -eq 'src' -or $seg[0] -eq 'app' -or $seg[0] -eq 'apps' -or $seg[0] -eq 'packages')) {
        return [pscustomobject]@{ Name = $seg[1]; Source = 'heuristic' }
    }
    return [pscustomobject]@{ Name = $seg[0]; Source = 'heuristic' }
}

# Resolve the feature scope. An explicit -Feature wins; otherwise use the
# .git/harness-current-task pointer that check-summary.ps1 writes after a
# summary validates. No pointer means no filter (the caller may still pass one).
function Get-FeatureScope {
    param([string]$RootPath, [string]$FeatureName)
    $name = $FeatureName
    $source = 'explicit'
    if (-not $name) {
        $ptrRel = @(Invoke-Git -RootPath $RootPath -ArgList @('rev-parse', '--git-path', 'harness-current-task')) | Select-Object -First 1
        if ($ptrRel) {
            $ptr = ([string]$ptrRel).Trim()
            if ($ptr) {
                if (-not [System.IO.Path]::IsPathRooted($ptr)) { $ptr = Join-Path $RootPath $ptr }
                if (Test-Path -LiteralPath $ptr) {
                    $name = (([System.IO.File]::ReadAllText($ptr, [System.Text.Encoding]::UTF8)).Trim())
                    $source = 'current-task pointer'
                }
            }
        }
    }
    if (-not $name) { return [pscustomobject]@{ Name=''; Modules=@(); Source='none' } }
    $summaryPath = Join-Path $RootPath ('.harness\changes\' + $name + '\summary.md')
    if (-not (Test-Path -LiteralPath $summaryPath)) {
        return [pscustomobject]@{ Name=$name; Modules=@(); Source=($source + ', summary missing') }
    }
    $text = [System.IO.File]::ReadAllText($summaryPath, [System.Text.Encoding]::UTF8)
    $modules = New-Object System.Collections.Generic.List[string]
    $m = [regex]::Match($text, '(?m)^[ \t]*(?:[-*][ \t]+)?[^\r\n:]*touched_modules:\s*`?([^\r\n`]*)')
    if ($m.Success) {
        foreach ($piece in ($m.Groups[1].Value -split ',')) {
            $v = $piece.Trim()
            if (-not $v) { continue }
            if ($v -match '(?i)^(none|-)$') { continue }
            if ($v -eq $NoneMarker) { continue }
            $modules.Add($v)
        }
    }
    return [pscustomobject]@{ Name=$name; Modules=@($modules.ToArray() | Sort-Object -Unique); Source=$source }
}

# Keep only records that belong to a touched module (or to the feature name when
# touched_modules is empty). If nothing matches, keep the full workspace and say
# so: a silent empty diff is worse than a noisy one.
function Filter-ChangeSet {
    param([string]$RootPath, $ChangeSet, $Scope)
    $records = @($ChangeSet.Records)
    if (-not $Scope -or -not $Scope.Name) {
        return [pscustomobject]@{ ChangeSet=$ChangeSet; Applied=$false; Kept=$records.Count; Ignored=0; Note='feature filter not applied (pass -Feature to scope the diff)' }
    }
    $kept = New-Object System.Collections.Generic.List[object]
    $ignored = 0
    $mods = @($Scope.Modules)
    foreach ($r in $records) {
        $p = ([string]$r.Path).ToLower()
        $hit = $false
        foreach ($mod in $mods) {
            $m = ([string]$mod).ToLower()
            if (-not $m) { continue }
            if (($p -eq $m) -or $p.StartsWith($m + '/') -or $p.Contains('/' + $m + '/') -or $p.EndsWith('/' + $m)) { $hit = $true; break }
        }
        if (-not $hit -and $mods.Count -eq 0) {
            $f = ([string]$Scope.Name).ToLower()
            if ($f -and $p.Contains($f)) { $hit = $true }
        }
        if ($hit) { $kept.Add($r) } else { $ignored++ }
    }
    if ($kept.Count -eq 0) {
        return [pscustomobject]@{ ChangeSet=$ChangeSet; Applied=$false; Kept=$records.Count; Ignored=0; Note=('no changed files match feature ' + $Scope.Name + '; showing the full workspace') }
    }
    $filtered = [pscustomobject]@{
        Mode = $ChangeSet.Mode
        Records = $kept.ToArray()
        AddedText = $ChangeSet.AddedText
        RemovedText = $ChangeSet.RemovedText
        LinesKnown = $ChangeSet.LinesKnown
        Notes = $ChangeSet.Notes
    }
    # Re-read the diff for the kept paths so unrelated SQL/DDL text cannot raise
    # the level. stdin / explicit file modes keep their supplied text.
    if ($ChangeSet.Mode -eq 'git') {
        $paths = @($kept.ToArray() | ForEach-Object { [string]$_.Path })
        $diffText = @(Invoke-Git -RootPath $RootPath -ArgList (@('diff', 'HEAD', '-U0', '--') + $paths))
        $add = New-Object System.Collections.Generic.List[string]
        $rem = New-Object System.Collections.Generic.List[string]
        foreach ($l in $diffText) {
            if ($l -like '+*' -and $l -notlike '+++*') { $add.Add($l.Substring(1)) }
            elseif ($l -like '-*' -and $l -notlike '---*') { $rem.Add($l.Substring(1)) }
        }
        $filtered.AddedText = $add.ToArray()
        $filtered.RemovedText = $rem.ToArray()
    }
    return [pscustomobject]@{ ChangeSet=$filtered; Applied=$true; Kept=$kept.Count; Ignored=$ignored; Note=('filtered to feature ' + $Scope.Name + ' (' + $Scope.Source + ')') }
}

function New-Record {
    param([string]$Path, [int]$Added, [int]$Removed)
    return [pscustomobject]@{ Path = ($Path -replace '\\', '/'); Added = $Added; Removed = $Removed }
}

function Get-ScannableLines {
    param([string[]]$Lines)
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($l in @($Lines)) {
        if ($null -eq $l) { continue }
        $t = $l.Trim()
        if ($t -eq '') { continue }
        if ($t -match '^(//|#|/\*|\*|<!--|-->)') { continue }
        if ($t -match '^--\s') { continue }
        $out.Add($l)
    }
    return $out.ToArray()
}

function Read-TextFileLines {
    param([string]$PathToFile)
    try { return @([System.IO.File]::ReadAllLines($PathToFile, [System.Text.Encoding]::UTF8)) }
    catch { return @() }
}

function Get-ChangeSet {
    param(
        [string]$RootPath,
        [bool]$FromStdin,
        [string[]]$FileList,
        [string]$StdinText
    )
    $records = New-Object System.Collections.Generic.List[object]
    $addedText = New-Object System.Collections.Generic.List[string]
    $removedText = New-Object System.Collections.Generic.List[string]
    $notes = New-Object System.Collections.Generic.List[string]
    $statOnly = New-Object System.Collections.Generic.List[string]
    $mode = 'files'
    $linesKnown = $true

    if ($FromStdin) {
        $mode = 'stdin'
        $cur = ''
        $hasCur = $false
        $add = 0
        $rem = 0
        foreach ($line in ($StdinText -split "`r?`n")) {
            if ($line -match '^diff --git a/(.+?) b/(.+)$') {
                if ($hasCur) { $records.Add((New-Record $cur $add $rem)) }
                $cur = $matches[2]; $add = 0; $rem = 0; $hasCur = $true
                continue
            }
            if ($line -match '^\+\+\+ b/(.+)$') {
                if (-not $hasCur) { $cur = $matches[1]; $hasCur = $true }
                continue
            }
            if ($line -match '^--- a/(.+)$') {
                if (-not $hasCur) { $cur = $matches[1]; $hasCur = $true }
                continue
            }
            if ($line -match '^\+\+\+ /dev/null' -or $line -match '^--- /dev/null') { continue }
            if ($line -like '+*') { $add++; $addedText.Add($line.Substring(1)); continue }
            if ($line -like '-*') { $rem++; $removedText.Add($line.Substring(1)); continue }
        }
        if ($hasCur) { $records.Add((New-Record $cur $add $rem)) }
        return [pscustomobject]@{
            Mode = $mode; Records = $records.ToArray(); AddedText = $addedText.ToArray()
            RemovedText = $removedText.ToArray(); LinesKnown = $true; Notes = $notes.ToArray()
        }
    }

    $numMap = @{}
    $numLines = @(Invoke-Git -RootPath $RootPath -ArgList @('diff', '--numstat', 'HEAD'))
    foreach ($l in $numLines) {
        if ($l -match '^(\d+|-)\t(\d+|-)\t(.+)$') {
            $a = 0; $r = 0
            if ($matches[1] -ne '-') { $a = [int]$matches[1] }
            if ($matches[2] -ne '-') { $r = [int]$matches[2] }
            $numMap[((($matches[3] -replace '\\', '/')).Trim('"'))] = @($a, $r)
        }
    }

    if ($FileList.Count -gt 0) {
        $mode = 'files'
        foreach ($f in $FileList) {
            $full = if ([System.IO.Path]::IsPathRooted($f)) { $f } else { Join-Path $RootPath $f }
            $a = 0; $r = 0
            $known = $false
            if ($numMap.ContainsKey($f)) { $a = $numMap[$f][0]; $r = $numMap[$f][1]; $known = $true }
            elseif (Test-Path -LiteralPath $full -PathType Leaf) {
                $a = @(Read-TextFileLines $full).Count
                $known = $true
            }
            if (-not $known) {
                $linesKnown = $false
                $notes.Add(('line count unavailable for: ' + $f))
            }
            $records.Add((New-Record $f $a $r))
            if ((Test-Path -LiteralPath $full -PathType Leaf) -and ($ScanExt -contains ([System.IO.Path]::GetExtension($f).ToLower()))) {
                foreach ($l in @(Read-TextFileLines $full)) { $addedText.Add($l) }
            }
        }
        return [pscustomobject]@{
            Mode = $mode; Records = $records.ToArray(); AddedText = $addedText.ToArray()
            RemovedText = $removedText.ToArray(); LinesKnown = $linesKnown; Notes = $notes.ToArray()
        }
    }

    $mode = 'git'
    # -uall: without it an untracked directory is reported as one "?? dir/" entry,
    # which has no line counts and would flip linesKnown to false.
    $status = @(Invoke-Git -RootPath $RootPath -ArgList @('status', '--porcelain', '-uall'))
    $ignoredArtifacts = 0
    if ($status.Count -eq 0) {
        return [pscustomobject]@{
            Mode = $mode; Records = @(); AddedText = @(); RemovedText = @()
            LinesKnown = $true; Notes = $notes.ToArray(); IgnoredCount = 0
        }
    }
    $diffText = @(Invoke-Git -RootPath $RootPath -ArgList @('diff', 'HEAD', '-U0'))
    foreach ($l in $diffText) {
        if ($l -like '+*' -and $l -notlike '+++*') { $addedText.Add($l.Substring(1)) }
        elseif ($l -like '-*' -and $l -notlike '---*') { $removedText.Add($l.Substring(1)) }
    }
    foreach ($line in $status) {
        if ($line.Length -lt 4) { continue }
        $code = $line.Substring(0, 2)
        $rest = $line.Substring(3).Trim()
        if ($rest -match ' -> ') { $rest = ($rest -split ' -> ')[-1] }
        $rest = $rest.Trim('"')
        $p = $rest -replace '\\', '/'
        if ($p -match $IgnoreRe) { $ignoredArtifacts++; continue }
        $a = 0; $r = 0
        $known = $false
        if ($numMap.ContainsKey($p)) { $a = $numMap[$p][0]; $r = $numMap[$p][1]; $known = $true }
        elseif ($code -match '(\?|A)') {
            $full = Join-Path $RootPath $p
            if (Test-Path -LiteralPath $full -PathType Leaf) {
                $a = @(Read-TextFileLines $full).Count
                $known = $true
                $ext = [System.IO.Path]::GetExtension($p).ToLower()
                if ($ScanExt -contains $ext) { foreach ($l in @(Read-TextFileLines $full)) { $addedText.Add($l) } }
            }
        } else {
            # status says modified but the diff is empty: a stat-only entry (mtime
            # refresh without a content change). 0 added / 0 removed is the truth.
            $known = $true
            $statOnly.Add($p)
        }
        if (-not $known) {
            $linesKnown = $false
            $notes.Add(('line count unavailable for: ' + $p))
        }
        $records.Add((New-Record $p $a $r))
    }
    if ($statOnly.Count -gt 0) {
        $notes.Add(('no textual diff for {0} file(s): {1}' -f $statOnly.Count, ($statOnly.ToArray() -join ', ')))
    }
    if ($ignoredArtifacts -gt 0) {
        $notes.Add(('ignored {0} build/archive file(s) in git status' -f $ignoredArtifacts))
    }
    return [pscustomobject]@{
        Mode = $mode; Records = $records.ToArray(); AddedText = $addedText.ToArray()
        RemovedText = $removedText.ToArray(); LinesKnown = $linesKnown; Notes = $notes.ToArray()
        IgnoredCount = $ignoredArtifacts
    }
}

function Invoke-Analyze {
    param(
        [string]$RootPath,
        [bool]$FromStdin,
        [string[]]$FileList,
        [string]$StdinText,
        [string]$FeatureName = ''
    )
    $set = Get-ChangeSet -RootPath $RootPath -FromStdin $FromStdin -FileList $FileList -StdinText $StdinText
    $scope = Get-FeatureScope -RootPath $RootPath -FeatureName $FeatureName
    $filter = Filter-ChangeSet -RootPath $RootPath -ChangeSet $set -Scope $scope
    $set = $filter.ChangeSet
    $records = @($set.Records)
    $notes = New-Object System.Collections.Generic.List[string]
    foreach ($n in @($set.Notes)) { $notes.Add($n) }
    if ($filter.Note -and ($FeatureName -or $scope.Name)) { $notes.Add($filter.Note) }

    $added = 0
    $removed = 0
    foreach ($r in $records) { $added += $r.Added; $removed += $r.Removed }

    $cardNames = @()
    $modulesDir = Join-Path $RootPath '.harness\modules'
    if (Test-Path -LiteralPath $modulesDir) {
        foreach ($f in @(Get-ChildItem -LiteralPath $modulesDir -Filter '*.md' -File -Force -ErrorAction SilentlyContinue)) {
            $base = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
            if ($base -eq 'README' -or $base -eq '_template') { continue }
            $cardNames += $base
        }
    }

    $docsOnly = $records.Count -gt 0
    $sqlHit = $false
    $ddlHit = $false
    $sqlPaths = @()
    $pubPaths = @()
    $cfgFilePaths = @()
    $cfgPaths = @()
    $ifacePaths = @()
    $fePaths = @()
    $docPaths = @()
    $backendModules = @()
    $feModules = @()
    $heuristicUsed = $false

    foreach ($r in $records) {
        $fl = Get-PathFlags $r.Path
        if (-not $fl.Doc) { $docsOnly = $false }
        if ($fl.Doc) { $docPaths += $r.Path; continue }
        if ($fl.SqlFile) { $sqlHit = $true; $sqlPaths += $r.Path }
        if ($r.Path -match '(?i)(mapper|mappers|sql).*\.xml$') { $sqlHit = $true; $sqlPaths += $r.Path }
        if ($fl.Migration) { $sqlHit = $true; $ddlHit = $true; $sqlPaths += $r.Path }
        if ($fl.Public) { $pubPaths += $r.Path }
        if ($fl.ConfigFile) { $cfgFilePaths += $r.Path }
        if ($fl.ConfigCode) { $cfgPaths += $r.Path }
        if ($fl.Interface) { $ifacePaths += $r.Path }
        $guess = Get-ModuleGuess -Path $r.Path -CardNames $cardNames
        if ($guess.Source -eq 'heuristic') { $heuristicUsed = $true }
        if ($fl.Frontend) { $feModules += $guess.Name; $fePaths += $r.Path }
        else { $backendModules += $guess.Name }
    }

    $scanLines = @(Get-ScannableLines -Lines $set.AddedText)
    foreach ($l in $scanLines) {
        if ($l -match $SqlDdlRe) { $ddlHit = $true; $sqlHit = $true; break }
        if ($l -match '(?i)\b(SELECT|INSERT|UPDATE|DELETE)\b.*\b(FROM|INTO|WHERE|SET|VALUES|JOIN)\b') { $sqlHit = $true }
    }

    $allText = @($set.AddedText) + @($set.RemovedText)
    $commentOnly = $allText.Count -gt 0
    foreach ($l in $allText) {
        if ($null -eq $l) { continue }
        $t = $l.Trim()
        if ($t -eq '') { continue }
        if ($t -match '^(//|#|/\*|\*|<!--|-->)') { continue }
        if ($t -match '^--\s') { continue }
        $commentOnly = $false
        break
    }

    $uniqBackend = @($backendModules | Sort-Object -Unique)
    $uniqFe = @($feModules | Sort-Object -Unique)
    $allModules = @(@($uniqBackend) + @($uniqFe) | Where-Object { $_ } | Sort-Object -Unique)

    $reasons = New-Object System.Collections.Generic.List[string]
    $level = 'L2'
    if ($records.Count -eq 0) {
        $level = 'L0'
        $reasons.Add('no changed files detected')
    } elseif ($docsOnly) {
        $level = 'L0'
        $reasons.Add('every changed file is documentation / text')
    } elseif ($commentOnly) {
        $level = 'L0'
        $reasons.Add('every diff line is a comment or blank')
    } elseif ($ddlHit) {
        $level = 'L3'
        $reasons.Add('DDL / migration changes the data shape')
    } elseif ($uniqBackend.Count -ge 2) {
        $level = 'L3'
        $reasons.Add(('{0} backend modules touched: {1}' -f $uniqBackend.Count, ($uniqBackend -join ', ')))
    } elseif ($pubPaths.Count -gt 0) {
        $level = 'L3'
        $reasons.Add('public / shared layer touched')
    } elseif ($cfgFilePaths.Count -gt 0) {
        $level = 'L3'
        $reasons.Add('config switch touched')
    } elseif ($sqlHit) {
        $level = 'L2'
        $reasons.Add('SQL touched without DDL: sql-review is still required')
    } elseif ($records.Count -eq 1 -and $set.LinesKnown -and ($added + $removed) -le 30 -and
              $ifacePaths.Count -eq 0 -and $cfgPaths.Count -eq 0) {
        $level = 'L1'
        $reasons.Add('1 file, <= 30 changed lines, no public layer / DB / config / interface')
    } else {
        $level = 'L2'
        if ($records.Count -ne 1) { $reasons.Add(('{0} files changed' -f $records.Count)) }
        if (-not $set.LinesKnown) { $reasons.Add('line counts unknown (not a git work tree): L1 cannot be proven') }
        elseif (($added + $removed) -gt 30) { $reasons.Add(('{0} changed lines > 30' -f ($added + $removed))) }
        if ($ifacePaths.Count -gt 0) { $reasons.Add('interface layer touched') }
        if ($cfgPaths.Count -gt 0) { $reasons.Add('config code touched') }
    }
    if ($level -ne 'L0') {
        $notes.Add('a release / production rollout is an L3 trigger a diff cannot show; raise it by hand')
    }
    if ($heuristicUsed) {
        $notes.Add('module names marked (heuristic) come from path segments; no .harness/modules card matched')
    }

    $dbPaths = @($sqlPaths)
    $cachePaths = @($records | Where-Object { $_.Path -match '(?i)(cache|redis)' } | ForEach-Object { $_.Path })
    $mqPaths = @($records | Where-Object { $_.Path -match '(?i)(mq|kafka|rabbit|rocket|listener|consumer|producer)' } | ForEach-Object { $_.Path })
    $otherPaths = @($records | Where-Object { $_.Path -match '(?i)\.(json|xml|yml|yaml|properties|txt|sh|ps1|bat)$' } | ForEach-Object { $_.Path })
    $backendPaths = @($records | Where-Object {
        $pp = $_.Path
        ($pp -notmatch '(?i)\.(md|sql|json|xml|yml|yaml|properties|txt|sh|ps1|bat|vue|jsx|tsx|css|scss|less|html)$') -and
        ($pp -notmatch '(?i)(^|/)(frontend|front|web|client|ui|views|pages|components|static)/')
    } | ForEach-Object { $_.Path })

    return [pscustomobject]@{
        Mode = $set.Mode
        Records = $records
        Added = $added
        Removed = $removed
        LinesKnown = $set.LinesKnown
        Scope = $scope
        FilterApplied = $filter.Applied
        FilterKept = $filter.Kept
        FilterIgnored = $filter.Ignored
        FilterNote = $filter.Note
        Level = $level
        Reasons = $reasons.ToArray()
        Notes = $notes.ToArray()
        Sql = $sqlHit
        Ddl = $ddlHit
        SqlPaths = $sqlPaths
        PublicPaths = $pubPaths
        ConfigPaths = @(@($cfgFilePaths) + @($cfgPaths))
        InterfacePaths = $ifacePaths
        Modules = $allModules
        BackendModules = $uniqBackend
        ModulesHeuristic = $heuristicUsed
        CardMode = ($cardNames.Count -gt 0)
        DatabasePaths = $dbPaths
        BackendPaths = $backendPaths
        CachePaths = $cachePaths
        MessagingPaths = $mqPaths
        FrontendPaths = $fePaths
        DocPaths = $docPaths
        OtherPaths = $otherPaths
    }
}

function Format-Report {
    param($Result)
    $lines = New-Object System.Collections.Generic.List[string]
    $moduleText = 'none'
    if (@($Result.Modules).Count -gt 0) { $moduleText = (@($Result.Modules) -join ', ') }
    $lines.Add(('flow: {0}' -f $Result.Level))
    $lines.Add(('touched_modules: {0}' -f $moduleText))
    $lines.Add('')
    $lines.Add('--- suggest-flow (read only, nothing was written) ---')
    $lines.Add(('mode        : {0}' -f $Result.Mode))
    if ($Result.Scope -and $Result.Scope.Name) {
        $mods = if (@($Result.Scope.Modules).Count -gt 0) { @($Result.Scope.Modules) -join ', ' } else { 'none' }
        $lines.Add(('feature     : {0} ({1}; touched_modules: {2})' -f $Result.Scope.Name, $Result.Scope.Source, $mods))
    }
    if ($Result.FilterApplied) {
        $lines.Add(('filtered    : {0} file(s), ignored {1} unrelated' -f $Result.FilterKept, $Result.FilterIgnored))
    }
    $lines.Add(('files       : {0}' -f @($Result.Records).Count))
    $lines.Add(('lines       : {0}' -f $(if ($Result.LinesKnown) { '+{0} -{1}' -f $Result.Added, $Result.Removed } else { 'unknown' })))
    if ($Result.Ddl) { $lines.Add('sql         : yes (DDL / migration)') }
    elseif ($Result.Sql) { $lines.Add('sql         : yes (no DDL)') }
    else { $lines.Add('sql         : not detected') }
    $lines.Add(('public      : {0}' -f $(if (@($Result.PublicPaths).Count -gt 0) { @($Result.PublicPaths) -join ', ' } else { 'no' })))
    $lines.Add(('config      : {0}' -f $(if (@($Result.ConfigPaths).Count -gt 0) { @($Result.ConfigPaths) -join ', ' } else { 'no' })))
    $lines.Add(('interface   : {0}' -f $(if (@($Result.InterfacePaths).Count -gt 0) { @($Result.InterfacePaths) -join ', ' } else { 'no' })))
    $lines.Add(('modules     : {0}' -f $(if ($Result.ModulesHeuristic) { 'path heuristic' } elseif ($Result.CardMode) { '.harness/modules cards' } else { 'path heuristic' })))
    foreach ($why in @($Result.Reasons)) { $lines.Add(('why         : {0}' -f $why)) }
    foreach ($n in @($Result.Notes)) { $lines.Add(('note        : {0}' -f $n)) }

    $cnDraft = New-Cn @(0x53D8, 0x66F4, 0x6E05, 0x5355)
    $cnDb = New-Cn @(0x6570, 0x636E, 0x5E93)
    $cnBackend = New-Cn @(0x540E, 0x7AEF)
    $cnCache = New-Cn @(0x7F13, 0x5B58)
    $cnMq = New-Cn @(0x6D88, 0x606F)
    $cnFe = New-Cn @(0x524D, 0x7AEF)
    $cnOther = New-Cn @(0x5176, 0x4ED6)
    $lines.Add('')
    $lines.Add(('--- {0} draft ---' -f $cnDraft))
    $lines.Add(('{0}:' -f $cnDb))
    foreach ($p in @($Result.DatabasePaths)) { $lines.Add(('  - {0}' -f $p)) }
    $lines.Add(('{0}:' -f $cnBackend))
    foreach ($p in @($Result.BackendPaths)) { $lines.Add(('  - {0}' -f $p)) }
    $lines.Add(('{0}:' -f $cnCache))
    foreach ($p in @($Result.CachePaths)) { $lines.Add(('  - {0}' -f $p)) }
    $lines.Add(('{0}:' -f $cnMq))
    foreach ($p in @($Result.MessagingPaths)) { $lines.Add(('  - {0}' -f $p)) }
    $lines.Add(('{0}:' -f $cnFe))
    foreach ($p in @($Result.FrontendPaths)) { $lines.Add(('  - {0}' -f $p)) }
    $lines.Add(('{0}:' -f $cnOther))
    foreach ($p in @($Result.OtherPaths)) { $lines.Add(('  - {0}' -f $p)) }
    return $lines.ToArray()
}

function Invoke-SuggestSelfTest {
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('hb-suggest-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $fails = New-Object System.Collections.Generic.List[string]
    $utf8 = New-Object System.Text.UTF8Encoding($false)

    function Assert-Case {
        param([string]$Name, [bool]$Ok)
        if ($Ok) { Write-Host ('ok: ' + $Name) }
        else { Write-Host ('[FAIL] ' + $Name) -ForegroundColor Red; $fails.Add($Name) }
    }

    function New-FakeDiff {
        param([string]$Path, [int]$Count, [string]$Text)
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.AppendLine(('diff --git a/{0} b/{0}' -f $Path))
        [void]$sb.AppendLine(('--- a/{0}' -f $Path))
        [void]$sb.AppendLine(('+++ b/{0}' -f $Path))
        [void]$sb.AppendLine(('@@ -0,0 +1,{0} @@' -f $Count))
        for ($i = 1; $i -le $Count; $i++) { [void]$sb.AppendLine('+' + $Text + $i) }
        return $sb.ToString()
    }

    try {
        New-Item -ItemType Directory -Force -Path (Join-Path $tmp '.harness\modules') | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $tmp '.harness\modules\order.md'), "# order`n", $utf8)
        [System.IO.File]::WriteAllText((Join-Path $tmp '.harness\modules\cart.md'), "# cart`n", $utf8)

        $docs = New-FakeDiff 'docs/readme.md' 3 '# note'
        $r = Invoke-Analyze -RootPath $tmp -FromStdin $true -FileList @() -StdinText $docs
        $rep = (Format-Report -Result $r) -join "`n"
        Assert-Case 'docs only -> L0' ($r.Level -eq 'L0')
        Assert-Case 'docs only -> touched_modules none' ($rep -match '(?m)^touched_modules: none$')

        $comments = New-FakeDiff 'src/main/java/com/demo/order/OrderService.java' 3 '// note '
        $r = Invoke-Analyze -RootPath $tmp -FromStdin $true -FileList @() -StdinText $comments
        Assert-Case 'comment only -> L0' ($r.Level -eq 'L0')

        $small = New-FakeDiff 'src/main/java/com/demo/order/OrderService.java' 10 'public int x = '
        $r = Invoke-Analyze -RootPath $tmp -FromStdin $true -FileList @() -StdinText $small
        $rep = (Format-Report -Result $r) -join "`n"
        Assert-Case 'one small file -> L1' ($r.Level -eq 'L1')
        Assert-Case 'L1 report has flow: L1' ($rep -match '(?m)^flow: L1$')
        Assert-Case 'L1 prefills card module order' ($rep -match '(?m)^touched_modules: order$')

        $big = New-FakeDiff 'src/main/java/com/demo/order/OrderService.java' 40 'public int x = '
        $r = Invoke-Analyze -RootPath $tmp -FromStdin $true -FileList @() -StdinText $big
        Assert-Case 'one file over 30 lines -> L2' ($r.Level -eq 'L2')

        $twoMods = (New-FakeDiff 'src/main/java/com/demo/order/OrderService.java' 4 'int a = ') +
                   (New-FakeDiff 'src/main/java/com/demo/cart/CartService.java' 4 'int b = ')
        $r = Invoke-Analyze -RootPath $tmp -FromStdin $true -FileList @() -StdinText $twoMods
        $rep = (Format-Report -Result $r) -join "`n"
        Assert-Case 'two backend modules -> L3' ($r.Level -eq 'L3')
        Assert-Case 'two modules prefilled' ($rep -match '(?m)^touched_modules: cart, order$')

        # A feature scope keeps the touched module and drops the rest. The same
        # mixed diff without -Feature must still see both modules.
        New-Item -ItemType Directory -Force -Path (Join-Path $tmp '.harness\changes\order-export') | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $tmp '.harness\changes\order-export\summary.md'), "touched_modules: order`n", $utf8)
        $r = Invoke-Analyze -RootPath $tmp -FromStdin $true -FileList @() -StdinText $twoMods -FeatureName 'order-export'
        $rep = (Format-Report -Result $r) -join "`n"
        Assert-Case 'feature scope keeps one record' (@($r.Records).Count -eq 1)
        Assert-Case 'feature scope sets the flag' ($r.FilterApplied -eq $true)
        Assert-Case 'feature scope is reported' ($rep -match '(?m)^feature     : order-export')
        Assert-Case 'feature scope keeps only order' ($rep -match '(?m)^touched_modules: order$')

        $rAll = Invoke-Analyze -RootPath $tmp -FromStdin $true -FileList @() -StdinText $twoMods
        Assert-Case 'no feature keeps both records' (@($rAll.Records).Count -eq 2)

        $ddl = New-FakeDiff 'db/migration/V2__order.sql' 5 'ALTER TABLE demo_order ADD COLUMN x INT;'
        $r = Invoke-Analyze -RootPath $tmp -FromStdin $true -FileList @() -StdinText $ddl
        $rep = (Format-Report -Result $r) -join "`n"
        Assert-Case 'DDL -> L3' ($r.Level -eq 'L3')
        Assert-Case 'DDL sets the sql flag' ($r.Sql -eq $true)
        Assert-Case 'DDL sets the ddl flag' ($r.Ddl -eq $true)
        Assert-Case 'DDL draft lists the sql file' ($rep -match 'db/migration/V2__order\.sql')

        $pub = New-FakeDiff 'src/main/java/com/demo/common/DateUtil.java' 5 'public int d = '
        $r = Invoke-Analyze -RootPath $tmp -FromStdin $true -FileList @() -StdinText $pub
        Assert-Case 'public layer -> L3' ($r.Level -eq 'L3')

        $cfg = New-FakeDiff 'src/main/resources/application.yml' 3 'key: value'
        $r = Invoke-Analyze -RootPath $tmp -FromStdin $true -FileList @() -StdinText $cfg
        Assert-Case 'config switch -> L3' ($r.Level -eq 'L3')

        $iface = New-FakeDiff 'src/main/java/com/demo/order/controller/OrderController.java' 8 'public int c = '
        $r = Invoke-Analyze -RootPath $tmp -FromStdin $true -FileList @() -StdinText $iface
        Assert-Case 'interface layer blocks L1 -> L2' ($r.Level -eq 'L2')

        $r = Invoke-Analyze -RootPath $tmp -FromStdin $false -FileList @('docs/readme.md') -StdinText ''
        Assert-Case 'explicit -Files docs -> L0' ($r.Level -eq 'L0')
        Assert-Case 'explicit -Files mode is reported' ($r.Mode -eq 'files')
    } finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }

    if ($fails.Count -gt 0) {
        Write-Host ('SUGGEST-FLOW SELFTEST FAILED: {0} case(s)' -f $fails.Count) -ForegroundColor Red
        return 1
    }
    Write-Host 'SUGGEST-FLOW SELFTEST OK' -ForegroundColor Green
    return 0
}

if ($SelfTest) {
    exit (Invoke-SuggestSelfTest)
}

$rootPath = $Root
try { $rootPath = (Resolve-Path -LiteralPath $Root).Path }
catch {
    Write-Host ('root not found: ' + $Root) -ForegroundColor Red
    exit 1
}

$stdinText = ''
$fileList = @()
if ($DiffFromStdin) {
    $stdinText = Read-StdinUtf8
} else {
    $fileList = @(Split-FileList -Raw $Files)
}
if ($DiffFromStdin -and [string]::IsNullOrWhiteSpace($stdinText)) {
    Write-Host '[FAIL] empty diff on stdin; pass the actual diff' -ForegroundColor Red
    exit 1
}
if (-not $DiffFromStdin -and $fileList.Count -eq 0) {
    $inside = @(Invoke-Git -RootPath $rootPath -ArgList @('rev-parse', '--is-inside-work-tree'))
    if ($inside.Count -eq 0 -or (($inside -join '').Trim() -ne 'true')) {
        Write-Host '[FAIL] not a git work tree; pass -Files or -DiffFromStdin' -ForegroundColor Red
        exit 1
    }
}

$result = Invoke-Analyze -RootPath $rootPath -FromStdin ([bool]$DiffFromStdin) -FileList $fileList -StdinText $stdinText -FeatureName $Feature
foreach ($line in @(Format-Report -Result $result)) { Write-Host $line }
exit 0
