<#
  sql-review-gate.ps1 -- refuse commits that touch SQL without a sql_review note

  WHY
    SQL performance cannot be judged by a regex, but "did the author evaluate it"
    is a checkable fact: a task summary must carry a sql_review line.

  BINDING (the note does NOT have to travel with the commit)
    1) a summary.md inside this commit           <- most accurate
    2) HARNESS_TASK=<feature>                    <- explicit override
    3) newest summary.md under .harness/changes  <- fallback; the path is printed
    Missing field -> a TODO placeholder is appended automatically, but the commit
    is still refused until the placeholder is replaced with a real result.

  SCOPE
    Only source extensions that carry SQL are inspected. The gate script itself and
    all .md files are skipped, so documenting a SQL example never triggers a block.

  ENCODING: pure ASCII (PS 5.1 reads .ps1 as ANSI without a BOM).

  USAGE
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\sql-review-gate.ps1 -DiffFile .git\harness-diff.tmp
#>
[CmdletBinding()]
param(
    [string]$Root = (Get-Location).Path,
    [string]$DiffFile
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path -LiteralPath $Root).Path

function Read-StagedDiff {
    param([string]$Path)
    $files = New-Object System.Collections.Generic.List[string]
    $added = New-Object System.Collections.Generic.List[object]
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{ Files = $files; Added = $added }
    }
    $cur = ''
    foreach ($l in [System.IO.File]::ReadAllLines($Path)) {
        if ($l.StartsWith('+++ ')) {
            $cur = $l.Substring(4).Trim()
            if ($cur -eq '/dev/null') {
                $cur = ''
            } else {
                $cur = $cur -replace '^[ab]/', ''
                if (-not $files.Contains($cur)) { $files.Add($cur) }
            }
            continue
        }
        if ($cur -and $l.StartsWith('+') -and -not $l.StartsWith('+++')) {
            $added.Add([pscustomobject]@{ Path = $cur; Line = $l.Substring(1) })
        }
    }
    return [pscustomobject]@{ Files = $files; Added = $added }
}

function Get-NoteValue {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $null }
    $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    $m = [regex]::Match($text, '(?m)^[^\r\n]*sql_review\b[^\r\n]*')
    if (-not $m.Success) { return $null }
    $v = $m.Value
    $i = $v.IndexOf('sql_review')
    if ($i -ge 0) { $v = $v.Substring($i + 10) }
    $fullColon = [char]0xFF1A
    return $v.TrimStart([char[]]@(':', '-', ' ', $fullColon)).Trim()
}

function Add-Placeholder {
    param([string]$Path)
    $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    if ($text -match 'sql_review') { return $false }
    $line = '- sql_review: TODO(evaluate tables / estimated rows / access path)'
    $nl = if ($text.EndsWith("`n")) { '' } else { "`r`n" }
    [System.IO.File]::WriteAllText($Path, $text + $nl + $line + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
    return $true
}

$diff = Read-StagedDiff -Path $DiffFile
if ($diff.Added.Count -eq 0) { Write-Host '[SKIP] no added lines to inspect'; exit 0 }

$sqlExt = @('.java', '.sql', '.xml', '.kt', '.py', '.js', '.ts', '.vue', '.cs')
$sqlLines = New-Object System.Collections.Generic.List[object]
$hot = New-Object System.Collections.Generic.List[string]
foreach ($a in $diff.Added) {
    $ext = [System.IO.Path]::GetExtension($a.Path).ToLowerInvariant()
    if ($sqlExt -notcontains $ext) { continue }
    if ($a.Path -match '(?i)scripts/sql-review-gate\.') { continue }
    $l = $a.Line
    $isSql = $false
    if ($l -match '(?i)\bselect\b.+?\bfrom\b') { $isSql = $true }
    elseif ($l -match '(?i)\binsert\b.+?\binto\b') { $isSql = $true }
    elseif ($l -match '(?i)\b(update|delete)\b.+?\b(where|set|from)\b') { $isSql = $true }
    if (-not $isSql) { continue }
    $sqlLines.Add($a)
    if ($l -match '(?i)\bselect\s+\*') { $hot.Add('select *') }
    if ($l -match '(?i)\bnot\s+in\s*\(') { $hot.Add('not in') }
    if ($l -match "(?i)like\s*'?\s*%") { $hot.Add("like '%...") }
}

if ($sqlLines.Count -eq 0) { Write-Host '[SKIP] no SQL detected in the staged source lines'; exit 0 }

# ---- candidates: this commit -> HARNESS_TASK -> newest on disk
$candidates = New-Object System.Collections.Generic.List[string]
$inCommit = @{}
foreach ($f in $diff.Files) {
    $m = [regex]::Match($f, '(?i)^\.harness/changes/([^/]+)/summary\.md$')
    if (-not $m.Success) { continue }
    if ($m.Groups[1].Value -eq '_template') { continue }
    $p = Join-Path $root ($f -replace '/', '\')
    if (-not $candidates.Contains($p)) { $candidates.Add($p); $inCommit[$p] = $true }
}
if ($env:HARNESS_TASK) {
    $escape = Join-Path $root (".harness\changes\{0}\summary.md" -f $env:HARNESS_TASK)
    if ((Test-Path -LiteralPath $escape) -and -not $candidates.Contains($escape)) { $candidates.Add($escape) }
}
if ($candidates.Count -eq 0) {
    $changes = Join-Path $root '.harness\changes'
    if (Test-Path -LiteralPath $changes) {
        $all = Get-ChildItem -LiteralPath $changes -Recurse -Filter summary.md -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Directory.Name -ne '_template' } |
            Sort-Object LastWriteTime -Descending
        foreach ($s in $all) { $candidates.Add($s.FullName) }
    }
}

# ---- evaluate
$note = ''
$noteFrom = ''
foreach ($c in $candidates) {
    $v = Get-NoteValue -Path $c
    if ($null -eq $v) { continue }
    if ($v.Length -lt 4 -or $v -match '(?i)^todo') { continue }
    # prefer the most detailed note when several summaries are candidates
    if ($v.Length -gt $note.Length) { $note = $v; $noteFrom = $c }
}

Write-Host ("[INFO] SQL lines in staged source: {0}" -f $sqlLines.Count)
foreach ($h in ($hot | Select-Object -Unique)) {
    Write-Host ("[WARN] hot SQL pattern: {0} (see .harness/rules/SQL review rules)" -f $h)
    Write-Host '       load the 14-sql-review skill and evaluate: tables / estimated rows / access path'
}

if ($note) {
    $label = Split-Path -Leaf (Split-Path -Parent $noteFrom)
    $where = if ($inCommit.ContainsKey($noteFrom)) { 'in this commit' } else { 'on disk, not in this commit' }
    Write-Host ("[PASS] sql_review ({0}, {1}): {2}" -f $label, $where, $note)
    exit 0
}

# ---- no usable note: append a placeholder once, then refuse
if ($candidates.Count -eq 0) {
    Write-Host '[FAIL] SQL changed but no summary.md exists under .harness/changes/.'
    Write-Host '       create .harness/changes/<feature>/summary.md from the template, then fill:'
    Write-Host '       sql_review: <tables, estimated rows, access path / explain result>'
    exit 1
}

$target = $candidates[0]
$appended = Add-Placeholder -Path $target
if ($appended) {
    Write-Host ("[INFO] appended a placeholder to {0}" -f $target)
}
Write-Host '[FAIL] sql_review is missing or still a TODO.'
Write-Host ("       edit {0}:" -f $target)
Write-Host '       sql_review: <tables, estimated rows, access path / explain result>'
Write-Host '       load the 14-sql-review skill, evaluate with MCP (count / index / explain), then commit again.'
exit 1
