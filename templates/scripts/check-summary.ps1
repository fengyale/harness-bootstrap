<#
  check-summary.ps1 -- validate the countable fields of .harness/changes/<feature>/summary.md

  WHY
    metrics.ps1 can only report what the summary records. When loaded_skills /
    corrections / impl_corrections / lesson_id are missing or left as
    placeholders, A6 ("the user only confirms key decisions") and A7 ("the same
    mistake is not repeated") stop being measurable, and the "should have
    loaded but did not" failure stays invisible. This script turns the exit
    check into a machine decision.

  USAGE
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\check-summary.ps1 -Feature my-feature
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\check-summary.ps1 -Feature my-feature -Stage initial
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\check-summary.ps1 -File .harness\changes\my-feature\summary.md

  STAGES
    initial  task start  : loaded_skills / flow / corrections / impl_corrections / touched_modules
    final    task close  : the above plus lesson_id and sql_review

  EXIT CODE
    0 = all required fields valid / 1 = at least one field invalid

  NOTE
    Pure ASCII. The summary itself is UTF-8; only the ASCII field names are
    matched. The value after a field name wins, and when it is wrapped in
    backticks only the first backtick pair is used -- prose after the closing
    backtick is ignored.
#>
[CmdletBinding()]
param(
    [string]$Root = (Get-Location).Path,
    [string]$Feature = '',
    [string]$File = '',
    [ValidateSet('initial', 'final')]
    [string]$Stage = 'final',
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
$rootPath = (Resolve-Path -LiteralPath $Root).Path

if ($File) {
    $path = if ([System.IO.Path]::IsPathRooted($File)) { $File } else { Join-Path $rootPath $File }
} elseif ($Feature) {
    if ($Feature -eq '_template') {
        if (-not $Quiet) { Write-Host '[OK] _template skipped' }
        exit 0
    }
    $path = Join-Path (Join-Path (Join-Path $rootPath '.harness') 'changes') (Join-Path $Feature 'summary.md')
} else {
    Write-Host '[FAIL] input: need -Feature or -File'
    exit 1
}

if (-not (Test-Path -LiteralPath $path)) {
    Write-Host "[FAIL] summary: not found at $path"
    exit 1
}

$text = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
$fails = New-Object System.Collections.Generic.List[string]

function Add-Fail {
    param([string]$Field, [string]$Reason)
    $script:fails.Add("$Field : $Reason")
}

# Return the value that follows "<name>:" in the countable-field block.
# Fields are written as list items (the template wraps the field name in backticks
# after a short label), so only a list item or a line that starts with the field
# name qualifies. Matching anywhere in the file let a body sentence such as
# "flow: L2 by hand" stand in for a missing header field, which made the gate
# spoofable by prose.
function Get-FieldRaw {
    param([string]$Name)
    $n = [regex]::Escape($Name)
    # Accepted shapes: a bare field line, a list item, or the template's labelled
    # list item ("- <label>:`flow: L2`"). Prose such as "- three corrections: 3"
    # carries no colon label, so it no longer spoofs a missing field.
    # The negative lookbehind keeps "impl_corrections:" from answering "corrections:".
    # U+FF1A is the full-width colon used by Chinese labels. Written as \uFF1A so
    # this file stays pure ASCII (PS 5.1 reads BOM-less .ps1 as ANSI).
    $rx = '(?m)^[ \t]*(?:[-*][ \t]+)?(?:[^\r\n:\uFF1A]*?[:\uFF1A][ \t]*`?`?)?`?`?(?<![A-Za-z0-9_\-])' + $n + ':\s*([^\r\n]*)'
    $m = [regex]::Match($script:text, $rx)
    if (-not $m.Success) { return $null }
    # Two shapes occur in real summaries:
    #   `field: value`   -> the opening backtick sits before the name, so the
    #                       captured raw starts with the value and ends with `
    #   field: `value`   -> the captured raw starts with `
    # Split on backticks and take the first non-empty piece covers both.
    $raw = $m.Groups[1].Value.Trim()
    $parts = @($raw -split '`' | ForEach-Object { $_.Trim() } | Where-Object { $_.Length -gt 0 })
    if ($parts.Count -gt 0) { return $parts[0] }
    return $raw
}

# lesson_id is not a single field: the header carries one and every correction
# item may carry its own. Collect all of them instead of trusting the first
# match (which may sit inside a correction item). Only list items count, so a
# sentence that merely mentions the field name cannot satisfy the gate.
function Get-AllLessonIds {
    $out = @()
    $rx = '(?m)^[ \t]*(?:[-*][ \t]+)?(?:[^\r\n:\uFF1A]*?[:\uFF1A][ \t]*`?`?)?`?`?(?<![A-Za-z0-9_\-])lesson_id:\s*`?\s*([^`\r\n]+)'
    foreach ($m in [regex]::Matches($script:text, $rx)) {
        $v = $m.Groups[1].Value.Trim()
        if ($v.Length -gt 0 -and ($out -notcontains $v)) { $out += $v }
    }
    return $out
}

function Test-Placeholder {
    param([string]$Value)
    if ($null -eq $Value) { return $true }
    $v = $Value.Trim()
    if ($v.Length -eq 0) { return $true }
    if ($v -match 'TODO') { return $true }
    # Template slots look like <module1> / <kebab-case, ...>; a real value may
    # legitimately contain ">" (e.g. "3 rows > estimate"), so only a leading "<"
    # counts as an unfilled slot.
    if ($v -match '^\s*<') { return $true }
    return $false
}

# ---------------------------------------------------------------- required now
$loaded = Get-FieldRaw 'loaded_skills'
if ($null -eq $loaded) {
    Add-Fail 'loaded_skills' 'missing (write the skills you actually loaded, or none)'
} elseif (Test-Placeholder $loaded) {
    Add-Fail 'loaded_skills' 'empty or placeholder'
} elseif ($loaded -match '(?i)^none\b') {
    # "none" alone is only acceptable with a reason on the same file
    if ($loaded -match '(?i)^none$') {
        $reason = Get-FieldRaw 'load_skip_reason'
        if (Test-Placeholder $reason) {
            Add-Fail 'load_skip_reason' 'required when loaded_skills is none'
        }
    }
    # "none, because ..." already carries the reason inline
}

$flow = Get-FieldRaw 'flow'
if ($null -eq $flow) { Add-Fail 'flow' 'missing' }
elseif (Test-Placeholder $flow) { Add-Fail 'flow' 'empty or placeholder' }
# L2 is often written with a trailing note: "L2 (standard)" or the same note in
# full-width parentheses. Only the leading level is contractual; the note is not
# an error. U+FF08 is written as \uFF08 so this file stays pure ASCII.
elseif ($flow -notmatch '^L[123]([ \t]|$|[\(\uFF08])') { Add-Fail 'flow' 'must be L1, L2 or L3' }

$corr = Get-FieldRaw 'corrections'
$corrValue = -1
if ($null -eq $corr) { Add-Fail 'corrections' 'missing' }
elseif ($corr -notmatch '^(\d+)') { Add-Fail 'corrections' 'must be a non-negative integer' }
else { $corrValue = [int]$matches[1] }

$impl = Get-FieldRaw 'impl_corrections'
$implValue = -1
if ($null -eq $impl) { Add-Fail 'impl_corrections' 'missing (fill 0 when there was none)' }
elseif ($impl -notmatch '^(\d+)') { Add-Fail 'impl_corrections' 'must be a non-negative integer' }
else { $implValue = [int]$matches[1] }

if ($corrValue -ge 0 -and $implValue -ge 0 -and $implValue -gt $corrValue) {
    Add-Fail 'impl_corrections' 'cannot exceed corrections'
}

$modules = Get-FieldRaw 'touched_modules'
if (Test-Placeholder $modules) {
    Add-Fail 'touched_modules' 'missing or placeholder (write none when nothing was touched)'
}

# ---------------------------------------------------------------- final only
if ($Stage -eq 'final') {
    $lessons = @(Get-AllLessonIds)
    if ($lessons.Count -eq 0) {
        Add-Fail 'lesson_id' 'missing (one kebab-case id per lesson, or - when there is none)'
    } else {
        # Take the first token so "cache-key - because ..." still validates; the
        # rest is prose. "none" is not a valid id (use - when nothing was learned).
        $tokens = @()
        foreach ($id in $lessons) {
            if (Test-Placeholder $id) {
                Add-Fail 'lesson_id' 'placeholder in one lesson_id'
                continue
            }
            $token = ($id -split '\s+')[0]
            $tokens += $token
            if ($token -eq 'none') {
                Add-Fail 'lesson_id' 'use - when there is no lesson, not none'
            } elseif ($token -ne '-' -and $token -cnotmatch '^[a-z0-9]+(-[a-z0-9]+)*$') {
                Add-Fail 'lesson_id' "not kebab-case: $token"
            }
        }
        # corrections > 0 means a real lesson exists, so at least one id must be
        # more than the "-" placeholder
        $realLessons = @($tokens | Where-Object { $_ -ne '-' })
        if ($corrValue -gt 0 -and $realLessons.Count -eq 0) {
            Add-Fail 'lesson_id' 'required when corrections > 0'
        }
    }

    $sql = Get-FieldRaw 'sql_review'
    if (Test-Placeholder $sql) {
        Add-Fail 'sql_review' 'missing (write the review, or "no SQL change")'
    }
}

# --------------------------------------------------------------------- report
if ($fails.Count -gt 0) {
    foreach ($f in $fails) { Write-Host "[FAIL] $f" }
    Write-Host "check-summary: $($fails.Count) fail(s)"
    exit 1
}

if (-not $Quiet) { Write-Host '[OK] summary fields valid' }
exit 0
