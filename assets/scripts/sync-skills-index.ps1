<#
  sync-skills-index.ps1 -- render the skill index from the directory tree

  WHY
    "which skills exist" is written in two hand-maintained places: the skills
    index (.harness/skills/README.md) and the resident AGENTS.md. Every added or
    removed skill makes both drift. The directory is the only source of truth;
    this script renders the same table into both files between fixed markers and
    fails a check when either copy is stale.

  CONTRACT
    - scans .harness/skills/<category>/<skill>/SKILL.md
    - reads frontmatter name + description; groups by category (alphabetical),
      sorts skills by directory name inside a category
    - the rendered block is:

        <!-- skills-index:begin -->
        | <category> | <skill> | <purpose> |
        | --- | --- | --- |
        | biz-dev | `crud-scaffold` | ... |
        <!-- skills-index:end -->

      The purpose cell is the first sentence of description (cut at the first
      full stop / semicolon), backticks removed, truncated to 40 characters
      with an ellipsis.
    - both files must carry EXACTLY one marker pair. A missing or duplicated
      pair is an error with a hint; this script never guesses a position.
    - -Write replaces only the lines between the markers. Everything outside is
      byte-identical, and the file keeps its own line endings (CRLF/LF) and BOM
      state.

  USAGE
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\sync-skills-index.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\sync-skills-index.ps1 -Check
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\sync-skills-index.ps1 -Write
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\sync-skills-index.ps1 -Root D:\proj

  EXIT CODE
    0 = in sync (check) or the write succeeded; 1 = drift / missing markers / write error

  NOTE
    Pure ASCII on purpose: PS 5.1 reads a BOM-less .ps1 as ANSI. Chinese header
    words and section hints are built from code points.
#>
[CmdletBinding()]
param(
    [string]$Root = (Get-Location).Path,
    [switch]$Write,
    [switch]$Check,
    [switch]$NoExit
)

function Complete-Harness {
    param([int]$Code)
    if ($NoExit) { throw ('__HARNESS_EXIT__' + $Code) }
    exit $Code
}

$ErrorActionPreference = 'Stop'

# Chinese literals built from code points (this file stays pure ASCII).
$hCat    = -join ([char]0x5206, [char]0x7C7B)                                           # category
$hSkill  = -join ([char]0x6280, [char]0x80FD)                                           # skill
$hUse    = -join ([char]0x7528, [char]0x9014)                                           # purpose
$hFirst  = -join ([char]0x9996, [char]0x53E5)                                           # first sentence
$lp      = [char]0xFF08                                                                 # (
$rp      = [char]0xFF09                                                                 # )
$comma   = [char]0xFF0C                                                                 # ,
$le40    = [char]0x2264                                                                 # <=
$hChar   = [char]0x5B57                                                                 # character
$kJuHao  = [char]0x3002                                                                 # full stop
$kFenHao = [char]0xFF1B                                                                 # full-width semicolon
$ellip   = [char]0x2026                                                                 # ellipsis
$secSkills = -join ([char]0x6280, [char]0x80FD, [char]0xFF08, [char]0x6309, [char]0x9700, [char]0x52A0, [char]0x8F7D, [char]0xFF09)
$secMatrix = -join ([char]0x6280, [char]0x80FD, [char]0x77E9, [char]0x9635, [char]0x603B, [char]0x89C8)

$BeginMarker = '<!-- skills-index:begin -->'
$EndMarker   = '<!-- skills-index:end -->'
$TableHeader = '| ' + $hCat + ' | ' + $hSkill + ' | ' + $hUse + $lp + 'description ' + $hFirst + $comma + $le40 + '40 ' + $hChar + $rp + ' |'
$TableRule   = '| --- | --- | --- |'

$rootPath   = (Resolve-Path -LiteralPath $Root).Path
$skillsRoot = Join-Path $rootPath '.harness\skills'

function Get-CleanValue {
    param([string]$Value)
    $v = ([string]$Value).Trim()
    if ($v.Length -ge 2 -and $v.StartsWith('"') -and $v.EndsWith('"')) { $v = $v.Substring(1, $v.Length - 2).Trim() }
    elseif ($v.Length -ge 2 -and $v.StartsWith("'") -and $v.EndsWith("'")) { $v = $v.Substring(1, $v.Length - 2).Trim() }
    return $v
}

function Get-SkillFrontMatter {
    param([string]$Path)
    $name = ''
    $desc = ''
    $lines = @([System.IO.File]::ReadAllLines($Path, [System.Text.Encoding]::UTF8))
    if ($lines.Count -lt 2 -or $lines[0].Trim() -ne '---') {
        return [pscustomobject]@{ Name = ''; Description = '' }
    }
    for ($i = 1; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($line.Trim() -eq '---') { break }
        if ($line -match '^name:\s*(.+)$') { $name = Get-CleanValue $matches[1] }
        elseif ($line -match '^description:\s*(.+)$') { $desc = Get-CleanValue $matches[1] }
    }
    return [pscustomobject]@{ Name = $name; Description = $desc }
}

function Get-Purpose {
    param([string]$Description)
    # Backticks and pipes would break the table cell; a pipe inside a cell needs
    # escaping in markdown tables, and a raw one silently adds a column.
    $d = ([string]$Description).Replace('`', '').Replace('|', '/').Trim()
    if (-not $d) { return '' }
    $cut = -1
    foreach ($ch in @($kJuHao, $kFenHao, [char]0x3B, [char]0x2E)) {
        $i = $d.IndexOf($ch)
        if ($i -ge 0 -and ($cut -lt 0 -or $i -lt $cut)) { $cut = $i }
    }
    if ($cut -gt 0) { $d = $d.Substring(0, $cut) }
    $d = $d.Trim()
    if ($d.Length -gt 40) { $d = $d.Substring(0, 39) + $ellip }
    return $d
}

function Get-SkillRows {
    param([string]$SkillsPath)
    $rows = New-Object System.Collections.Generic.List[string]
    if (-not (Test-Path -LiteralPath $SkillsPath)) { return $rows }
    $cats = @(Get-ChildItem -LiteralPath $SkillsPath -Directory -Force | Sort-Object Name)
    foreach ($catDir in $cats) {
        $skills = @(Get-ChildItem -LiteralPath $catDir.FullName -Directory -Force | Sort-Object Name)
        foreach ($skillDir in $skills) {
            $skillFile = Join-Path $skillDir.FullName 'SKILL.md'
            if (-not (Test-Path -LiteralPath $skillFile -PathType Leaf)) { continue }
            $fm = Get-SkillFrontMatter $skillFile
            $name = $fm.Name
            if (-not $name) { $name = $skillDir.Name -replace '^\d+-', '' }
            $purpose = Get-Purpose $fm.Description
            $rows.Add('| ' + $catDir.Name + ' | `' + $name + '` | ' + $purpose + ' |')
        }
    }
    return $rows
}

function Get-ExpectedBlock {
    param($Rows)
    $block = New-Object System.Collections.Generic.List[string]
    $block.Add($BeginMarker)
    $block.Add($TableHeader)
    $block.Add($TableRule)
    foreach ($r in $Rows) { $block.Add($r) }
    $block.Add($EndMarker)
    return $block
}

function Read-FileState {
    param([string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $bom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    if ($bom) { $text = $text.Substring(1) }
    return [pscustomobject]@{ Text = $text; Bom = $bom }
}

function Split-TextLines {
    param([string]$Text)
    $nl = if ($Text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $endsNl = $Text.EndsWith("`n")
    $body = $Text
    if ($endsNl) {
        $body = $body.Substring(0, $body.Length - 1)
        if ($body.EndsWith("`r")) { $body = $body.Substring(0, $body.Length - 1) }
    }
    $lines = @()
    if ($body.Length -gt 0) { $lines = @($body -split "`r`n|`n|`r") }
    return [pscustomobject]@{ Lines = $lines; NewLine = $nl; EndsWithNewLine = $endsNl }
}

function Save-TextLines {
    param([string]$Path, [string[]]$Lines, [string]$NewLine, [bool]$EndsWithNewLine, [bool]$Bom)
    $text = ($Lines -join $NewLine)
    if ($EndsWithNewLine) { $text += $NewLine }
    $enc = New-Object System.Text.UTF8Encoding($Bom)
    [System.IO.File]::WriteAllText($Path, $text, $enc)
}

function Get-MarkerRange {
    param([string[]]$Lines)
    $beginAt = New-Object System.Collections.Generic.List[int]
    $endAt = New-Object System.Collections.Generic.List[int]
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $t = $Lines[$i].Trim()
        if ($t -eq $BeginMarker) { $beginAt.Add($i) }
        elseif ($t -eq $EndMarker) { $endAt.Add($i) }
    }
    return [pscustomobject]@{ Begin = $beginAt; End = $endAt }
}

$rows = Get-SkillRows $skillsRoot
$expected = @(Get-ExpectedBlock $rows)

$targets = @(
    [pscustomobject]@{ Rel = '.harness\skills\README.md'; Hint = ('under the skills matrix overview section (' + $secMatrix + ')') },
    [pscustomobject]@{ Rel = 'AGENTS.md'; Hint = ('under the skills section (' + $secSkills + ')') }
)

$bad = 0
$wrote = 0
foreach ($target in $targets) {
    $path = Join-Path $rootPath $target.Rel
    $rel = $target.Rel -replace '\\', '/'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Write-Output ("skills-index: missing file {0}; create it from the package template before syncing" -f $rel)
        $bad++
        continue
    }

    $state = Read-FileState $path
    $parsed = Split-TextLines $state.Text
    $lines = @($parsed.Lines)
    $range = Get-MarkerRange $lines

    if ($range.Begin.Count -eq 0 -and $range.End.Count -eq 0) {
        Write-Output ("skills-index: {0} has no marker pair; add {1} ... {2} {3}" -f $rel, $BeginMarker, $EndMarker, $target.Hint)
        $bad++
        continue
    }
    if ($range.Begin.Count -gt 1 -or $range.End.Count -gt 1) {
        Write-Output ("skills-index: {0} has {1} begin and {2} end markers; exactly one pair is required" -f $rel, $range.Begin.Count, $range.End.Count)
        $bad++
        continue
    }
    if ($range.Begin.Count -eq 0 -or $range.End.Count -eq 0) {
        Write-Output ("skills-index: {0} has an unpaired marker; add the missing {1} or {2} {3}" -f $rel, $BeginMarker, $EndMarker, $target.Hint)
        $bad++
        continue
    }
    $beginIdx = $range.Begin[0]
    $endIdx = $range.End[0]
    if ($endIdx -lt $beginIdx) {
        Write-Output ("skills-index: {0} closes the block before it opens; fix the marker order" -f $rel)
        $bad++
        continue
    }

    $actual = @($lines[$beginIdx..$endIdx])
    $drift = $false
    if ($actual.Count -ne $expected.Count) {
        $drift = $true
    } else {
        for ($i = 0; $i -lt $expected.Count; $i++) {
            if ($actual[$i] -ne $expected[$i]) { $drift = $true; break }
        }
    }

    if ($Write) {
        $merged = New-Object System.Collections.Generic.List[string]
        for ($i = 0; $i -lt $beginIdx; $i++) { $merged.Add($lines[$i]) }
        foreach ($l in $expected) { $merged.Add($l) }
        for ($i = $endIdx + 1; $i -lt $lines.Count; $i++) { $merged.Add($lines[$i]) }
        try {
            Save-TextLines $path @($merged) $parsed.NewLine $parsed.EndsWithNewLine $state.Bom
            Write-Output ("skills-index: updated {0} ({1} skill(s))" -f $rel, $rows.Count)
            $wrote++
        } catch {
            Write-Output ("skills-index: cannot write {0}: {1}" -f $rel, $_.Exception.Message)
            $bad++
        }
        continue
    }

    if ($drift) {
        Write-Output ("skills-index: drift in {0}" -f $rel)
        $limit = [Math]::Min($actual.Count, $expected.Count)
        for ($i = 0; $i -lt $limit; $i++) {
            if ($actual[$i] -ne $expected[$i]) {
                Write-Output ("  line {0}: expected '{1}' but found '{2}'" -f ($beginIdx + $i + 1), $expected[$i], $actual[$i])
                break
            }
        }
        if ($actual.Count -ne $expected.Count) {
            Write-Output ("  block has {0} line(s); expected {1} (a skill was added or removed)" -f $actual.Count, $expected.Count)
        }
        Write-Output '  regenerate it with: scripts\sync-skills-index.ps1 -Write'
        $bad++
    }
}

if ($Write) {
    if ($bad -gt 0) { Complete-Harness 1 }
    if ($wrote -eq 0) { Write-Output 'skills-index: nothing to update' }
    Complete-Harness 0
}

if ($bad -gt 0) {
    Complete-Harness 1
}
Write-Output ("skills-index: in sync ({0} skill(s) in {1} file(s))" -f $rows.Count, $targets.Count)
Complete-Harness 0
