<#
  red-line-scan.ps1 -- deterministic red-line scanner (gate for hooks / CI / pre-commit)

  WHY THIS EXISTS
    Rule files, skills and reviewer agents are all "advisory" -- no matter how well
    written, they cannot stop a violating commit. This script is the other half:
    "if it does not pass, you do not get through".

  ENCODING NOTE (important on Windows PowerShell 5.1)
    This script is intentionally pure ASCII. PS 5.1 reads .ps1 files as ANSI unless
    they carry a UTF-8 BOM, so any Chinese text in a script would break parsing.
    All non-ASCII content (rule names, hints) lives in red-line-rules.json instead,
    which this script reads explicitly as UTF-8.

  USAGE  (this machine has Windows PowerShell 5.1 and no pwsh; the execution policy
          blocks unsigned scripts, so -ExecutionPolicy Bypass is REQUIRED)
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\red-line-scan.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\red-line-scan.ps1 -Root D:\proj
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\red-line-scan.ps1 -Rules R1,R4
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\red-line-scan.ps1 -ListRules

  INCREMENTAL MODE (added lines only; this is what the git hook uses)
    powershell ... -File scripts\red-line-scan.ps1 -DiffFile .git\harness-diff.tmp
    git diff --cached -U0 --diff-filter=ACMR | powershell ... -File scripts\red-line-scan.ps1 -DiffFromStdin
    Only the added lines of the diff are scanned, so a legacy project with
    hundreds of historical violations still gets a usable gate ("block new only").

  WHOLE-FILE FILTER MODE (every line of the listed files is scanned)
    powershell ... -File scripts\red-line-scan.ps1 -Files a.java,b.kt
    git diff --cached --name-only --diff-filter=ACM | powershell ... -FilesFromStdin
    Use this for a deliberate full review of a few files, not for routine
    incremental checks: historical violations in those files will be reported.

  EXIT CODE
    0 = clean, 1 = violations found (usable as a gate)

  NOTE
    Dirs named .harness / .trae are excluded by default: the specification docs
    themselves contain counter-examples such as BigDecimal or RuntimeException.
#>
[CmdletBinding()]
param(
    [string]$Root = (Get-Location).Path,
    [string]$RulesFile,
    [string[]]$Files,
    [switch]$FilesFromStdin,
    [switch]$DiffFromStdin,
    [string]$DiffFile,
    [string[]]$Include = @('*.java', '*.kt', '*.ts', '*.tsx', '*.js', '*.vue', '*.xml', '*.sql'),
    [string[]]$ExcludeDir = @('.git', 'node_modules', 'target', 'dist', 'build', 'out', 'coverage', '.harness', '.trae', '.idea'),
    [string[]]$Rules,
    [switch]$ListRules,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

# ---- locate the rule table -------------------------------------------------
if (-not $RulesFile) {
    $RulesFile = Join-Path $PSScriptRoot 'red-line-rules.json'
}
if (-not (Test-Path -LiteralPath $RulesFile)) {
    throw "Rule file not found: $RulesFile"
}

$raw = Get-Content -LiteralPath $RulesFile -Raw -Encoding UTF8
$config = $raw | ConvertFrom-Json

# IMPORTANT: PowerShell variable names are case-insensitive, so do NOT name this
# $rules -- that would silently overwrite the -Rules parameter.
$ruleSet = @($config.rules)

if (-not $ruleSet -or $ruleSet.Count -eq 0) { throw "No rules defined in $RulesFile" }

if ($ListRules) {
    $ruleSet | Select-Object id, name, include, hint | Format-Table -AutoSize -Wrap
    exit 0
}

if ($Rules) {
    # "-File script.ps1 -Rules R1,R4" binds as one string, so split it here
    $Rules = @($Rules | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
    $ruleSet = @($ruleSet | Where-Object { $Rules -contains $_.id })
    if ($ruleSet.Count -eq 0) { throw "No rule matched: $($Rules -join ', ')" }
}

$rootPath = (Resolve-Path -LiteralPath $Root).Path

# ---- helpers --------------------------------------------------------------
function Get-RelPath {
    param([string]$Full)
    if ($Full.StartsWith($rootPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $Full.Substring($rootPath.Length).TrimStart('\', '/')
    }
    return $Full
}

function Test-Selected {
    param([System.IO.FileInfo]$File)
    $name = $File.Name
    $extOk = $false
    foreach ($p in $Include) { if ($name -like $p) { $extOk = $true; break } }
    if (-not $extOk) { return $false }

    $rel = Get-RelPath $File.FullName
    $parts = $rel -split '[\\/]'
    foreach ($d in $parts) { if ($ExcludeDir -contains $d) { return $false } }
    return $true
}

# ---- collect files --------------------------------------------------------
function Read-StdinUtf8 {
    $reader = New-Object System.IO.StreamReader([Console]::OpenStandardInput(), (New-Object System.Text.UTF8Encoding($false)))
    return $reader.ReadToEnd()
}

# Parse "git diff -U0" into path -> set(new line numbers). Only added lines count.
function Get-AddedLines {
    param([string]$DiffText)
    $map = @{}
    $cur = $null
    foreach ($line in ($DiffText -split "`n")) {
        if ($line -match '^diff --git ') { $cur = $null; continue }
        if ($line -match '^\+\+\+ "b/(.+)"') {
            $cur = $matches[1].Trim()
            $map[$cur] = New-Object System.Collections.Generic.HashSet[int]
            continue
        }
        if ($line -match '^\+\+\+ b/(.+)') {
            $cur = $matches[1].Trim()
            $map[$cur] = New-Object System.Collections.Generic.HashSet[int]
            continue
        }
        if ($line -match '^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@') {
            if (-not $cur) { continue }
            $start = [int]$matches[1]
            $count = if ($matches[2]) { [int]$matches[2] } else { 1 }
            for ($i = 0; $i -lt $count; $i++) { [void]$map[$cur].Add($start + $i) }
        }
    }
    return $map
}

$addedLines = $null
$useIndex = $false
if ($DiffFromStdin -or $DiffFile) {
    $diffText = if ($DiffFile) {
        [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $DiffFile).Path, [System.Text.Encoding]::UTF8)
    } else {
        Read-StdinUtf8
    }
    $addedLines = Get-AddedLines $diffText
    $useIndex = $true
    if ($addedLines.Count -eq 0) {
        if (-not $Quiet) { Write-Host "[OK] red-line scan passed: no added line in diff" -ForegroundColor Green }
        exit 0
    }
    $Files = @($addedLines.Keys)
}

# In diff mode read the INDEX blob: hooks diff the index, so the working tree may
# already differ (git add -p). Line numbers must match the index or they mislead.
function Get-ScanText {
    param([string]$Rel, [string]$Full)
    if ($useIndex) {
        $gitRel = $Rel -replace '\\', '/'
        $out = & git -C $rootPath show (":" + $gitRel) 2>$null
        if ($LASTEXITCODE -eq 0) { return ($out -join "`n") }
    }
    return [System.IO.File]::ReadAllText($Full)
}

if ($FilesFromStdin) {
    $stdin = Read-StdinUtf8
    $Files = @($stdin -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
}

if ($Files -and $Files.Count -gt 0) {
    # Explicit list = whole-file filter. Missing paths are skipped on purpose --
    # a commit can legitimately contain deletions and renames. For added-lines
    # only, use -DiffFile / -DiffFromStdin above.

    $allFiles = @()
    foreach ($f in $Files) {
        $p = $f
        if (-not [System.IO.Path]::IsPathRooted($p)) { $p = Join-Path $rootPath $p }
        if (-not (Test-Path -LiteralPath $p)) { continue }
        $item = Get-Item -LiteralPath $p -ErrorAction SilentlyContinue
        if (-not $item -or $item.PSIsContainer) { continue }
        if (Test-Selected $item) { $allFiles += $item }
    }
} else {
    $allFiles = @(Get-ChildItem -LiteralPath $rootPath -Recurse -File -Force -ErrorAction SilentlyContinue |
        Where-Object { Test-Selected $_ })
}

# ---- scan -----------------------------------------------------------------
$violations = New-Object System.Collections.Generic.List[object]

function Add-Violation {
    param($Rule, [string]$Path, [int]$Line, [string]$Snippet)
    if ($Snippet.Length -gt 120) { $Snippet = $Snippet.Substring(0, 120) + '...' }
    $violations.Add([pscustomobject]@{
        Rule    = $Rule.id
        Name    = $Rule.name
        Path    = $Path
        Line    = $Line
        Snippet = $Snippet
        Hint    = $Rule.hint
    })
}

foreach ($file in $allFiles) {
    $rel = Get-RelPath $file.FullName

    # diff mode: only files touched by this change, and only their added lines
    $addedForFile = $null
    if ($addedLines) {
        $key = $rel -replace '\\', '/'
        if ($addedLines.ContainsKey($key)) { $addedForFile = $addedLines[$key] }
        if (-not $addedForFile) { continue }
    }

    $applicable = @()
    foreach ($rule in $ruleSet) {
        $ok = $false
        if (-not $rule.include -or $rule.include.Count -eq 0) { $ok = $true }
        else {
            foreach ($p in $rule.include) { if ($file.Name -like $p) { $ok = $true; break } }
        }
        # optional path filter: narrow a rule such as "no ${} in SQL" to mapper XML only
        if ($ok -and $rule.includePath) {
            $pathOk = $false
            $relSlash = $rel -replace '\\', '/'
            foreach ($p in $rule.includePath) { if ($relSlash -like $p) { $pathOk = $true; break } }
            if (-not $pathOk) { $ok = $false }
        }
        if ($ok) { $applicable += $rule }
    }
    if ($applicable.Count -eq 0) { continue }

    $lineRules  = @($applicable | Where-Object { -not $_.multiline })
    $multiRules = @($applicable | Where-Object { $_.multiline })

    $scanText = $null
    if ($lineRules.Count -gt 0 -or $multiRules.Count -gt 0) {
        $scanText = Get-ScanText $rel $file.FullName
    }

    if ($lineRules.Count -gt 0) {
        $lineNo = 0
        foreach ($line in ($scanText -split "`n")) {
            $lineNo++
            $line = $line.TrimEnd("`r")
            if ($addedForFile -and -not $addedForFile.Contains($lineNo)) { continue }
            foreach ($rule in $lineRules) {
                if ($line -notmatch $rule.pattern) { continue }
                if ($rule.requireAlso -and ($line -notmatch $rule.requireAlso)) { continue }
                Add-Violation $rule $rel $lineNo $line.Trim()
            }
        }
    }

    if ($multiRules.Count -gt 0) {
        $text = $scanText
        foreach ($rule in $multiRules) {
            foreach ($m in [regex]::Matches($text, $rule.pattern)) {
                if ($rule.requireAlso -and ($m.Value -notmatch $rule.requireAlso)) { continue }
                $startLine = ($text.Substring(0, $m.Index) -split "`n").Count
                if ($addedForFile) {
                    $span = ($m.Value -split "`n").Count
                    $touched = $false
                    for ($i = 0; $i -lt $span; $i++) { if ($addedForFile.Contains($startLine + $i)) { $touched = $true; break } }
                    if (-not $touched) { continue }
                }
                Add-Violation $rule $rel $startLine (($m.Value -replace '\s+', ' ').Trim())
            }
        }
    }
}

# ---- output ---------------------------------------------------------------
if ($violations.Count -eq 0) {
    if (-not $Quiet) {
        Write-Host "[OK] red-line scan passed: 0 violation ($($allFiles.Count) files scanned)" -ForegroundColor Green
    }
    exit 0
}

Write-Host "[FAIL] red-line scan found $($violations.Count) violation(s):" -ForegroundColor Red
Write-Host ""

foreach ($group in ($violations | Group-Object Rule)) {
    $first = $group.Group[0]
    Write-Host "[$($first.Rule)] $($first.Name)  -- $($group.Count) hit(s)" -ForegroundColor Yellow
    Write-Host "     hint: $($first.Hint)"
    foreach ($v in $group.Group) {
        Write-Host "     $($v.Path):$($v.Line)"
        if (-not $Quiet) { Write-Host "         $($v.Snippet)" -ForegroundColor DarkGray }
    }
    Write-Host ""
}

Write-Host "Red lines are zero-tolerance: STOP -> FIX -> re-verify from the affected stage." -ForegroundColor Red
Write-Host "(See AGENTS.md 'red lines' and the encoding spec's 'red line summary'.)"
exit 1
