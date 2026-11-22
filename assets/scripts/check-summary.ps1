<#
  check-summary.ps1 -- validate the countable fields of .harness/changes/<feature>/summary.md

  WHY
    metrics.ps1 can only report what the summary records. When loaded_skills /
    corrections / impl_corrections / lesson_id are missing or left as
    placeholders, A6 ("the user only confirms key decisions") and A7 ("the same
    mistake is not repeated") stop being measurable, and the "should have
    loaded but did not" failure stays invisible. This script turns the exit
    check into a machine decision.

    Presence of the fields is not the point by itself: the summary is the only
    place where acceptance criteria are written before code. So the initial
    stage checks the CONTENT that guides coding (acceptance criteria, impact,
    task breakdown), and the counts a reviewer needs are checked at close-out,
    where they are actually known.

  USAGE
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\check-summary.ps1 -Feature my-feature
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\check-summary.ps1 -Feature my-feature -Stage initial
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\check-summary.ps1 -File .harness\changes\my-feature\summary.md

  STAGES
    initial  task start  : flow / loaded_skills / touched_modules, plus real
                           content in acceptance criteria, impact and task
                           breakdown (a table of placeholders is not content)
    review   stage 6     : the review table under the review section only
                           (P0/P1/P2 rows, fingerprints, evidence); a row that
                           is not fixed yet is allowed here; nothing else runs
    final    task close  : the same, plus corrections / impl_corrections as real
                           numbers, lesson_id and sql_review

  REVIEW LEDGER
    The review conclusion table (7 columns) lives in harness-required.json as
    reviewLedger, because the enum values are Chinese and this file is ASCII.
    reviewLedgerStrict=true (fresh install) fails when the table is missing;
    false (upgraded project) only warns. A malformed table always fails.

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
    [ValidateSet('initial', 'final', 'review')]
    [string]$Stage = 'final',
    [switch]$OnlySqlReview,
    [switch]$Quiet,
    [switch]$NoExit
)

function Complete-Harness {
    param([int]$Code)
    if ($NoExit) { throw ('__HARNESS_EXIT__' + $Code) }
    exit $Code
}

$ErrorActionPreference = 'Stop'
$rootPath = (Resolve-Path -LiteralPath $Root).Path

if ($File) {
    $path = if ([System.IO.Path]::IsPathRooted($File)) { $File } else { Join-Path $rootPath $File }
} elseif ($Feature) {
    if ($Feature -eq '_template') {
        if (-not $Quiet) { Write-Host '[OK] _template skipped' }
        Complete-Harness 0
    }
    $path = Join-Path (Join-Path (Join-Path $rootPath '.harness') 'changes') (Join-Path $Feature 'summary.md')
} else {
    Write-Host '[FAIL] input: need -Feature or -File'
    Complete-Harness 1
}

if (-not (Test-Path -LiteralPath $path)) {
    Write-Host "[FAIL] summary: not found at $path"
    Complete-Harness 1
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

# Labels whose name itself is Chinese (reviewer / six dimensions) have no ASCII
# field name, so the Chinese label is followed by a full-width or ASCII colon.
# Same backtick handling as Get-FieldRaw: only the first non-empty piece counts.
function Get-LabelRaw {
    param([string]$Name)
    $n = [regex]::Escape($Name)
    $rx = '(?m)^[ \t]*(?:[-*][ \t]+)?' + $n + '[ \t]*[:\uFF1A][ \t]*(.*)$'
    $m = [regex]::Match($script:text, $rx)
    if (-not $m.Success) { return $null }
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

# ------------------------------------------------------------- content sections
# A summary whose "acceptance criteria" table is still the template's placeholder
# row is a file, not an analysis: the agent can fill every count field and still
# start coding without deciding what "done" means. Section names live in
# harness-required.json so this script stays pure ASCII.
$script:contentCfg = $null
$cfgPath = Join-Path $PSScriptRoot 'harness-required.json'
if (Test-Path -LiteralPath $cfgPath) {
    try {
        $cfgAll = (Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8) | ConvertFrom-Json
        if ($cfgAll.PSObject.Properties['summaryContent']) { $script:contentCfg = $cfgAll.summaryContent }
    } catch { }
}

function Get-ContentNeedles {
    param([string]$Name)
    if (-not $script:contentCfg) { return @() }
    $p = $script:contentCfg.PSObject.Properties[$Name]
    if (-not $p) { return @() }
    return @($p.Value | ForEach-Object { [string]$_ } | Where-Object { $_.Length -gt 0 })
}

# Body of a "## heading" section: from the matching heading to the next heading
# of the same or a higher level. Returns $null when no heading matches.
function Get-SectionLines {
    param([string[]]$Needles)
    $lines = $script:text -split "\r?\n"
    $start = -1
    $level = 0
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $m = [regex]::Match($lines[$i], '^(#{2,3})\s+')
        if (-not $m.Success) { continue }
        foreach ($n in $Needles) {
            if ($lines[$i] -match ('^#{2,3}\s+' + [regex]::Escape($n))) {
                $start = $i
                $level = $m.Groups[1].Length
                break
            }
        }
        if ($start -ge 0) { break }
    }
    if ($start -lt 0) { return $null }
    $body = @()
    for ($i = $start + 1; $i -lt $lines.Count; $i++) {
        $h = [regex]::Match($lines[$i], '^(#+)\s')
        if ($h.Success -and $h.Groups[1].Length -le $level) { break }
        $body += $lines[$i]
    }
    return $body
}

# A section counts as filled when it holds at least one line that is neither a
# heading, a table separator, a header cell nor a leftover template slot.
# -RequireTableRow is used for the two tables; the impact section may be bullets.
function Test-RealContent {
    param([string[]]$Needles, [switch]$RequireTableRow)
    if ($null -eq $Needles -or $Needles.Count -eq 0) { return $true }
    $body = Get-SectionLines -Needles $Needles
    if ($null -eq $body) { return $false }
    $afterSeparator = $false
    foreach ($line in $body) {
        $t = $line.Trim()
        if ($t.Length -eq 0) { continue }
        if ($t -match '^#{1,6}\s') { continue }
        if ($t -match '^\|?\s*:?-{2,}') { $afterSeparator = $true; continue }
        if ($t -match '^\|') {
            # A row before the separator is the header row (field names only).
            if (-not $afterSeparator) { continue }
            $cells = @($t.Trim('|').Split('|') | ForEach-Object { ($_ -replace '`', '').Trim() } | Where-Object { $_.Length -gt 0 })
            if ($cells.Count -eq 0) { continue }
            # Every cell must be real: the ID cell ("F1") is never a placeholder,
            # so "any real cell" would count the untouched template row.
            $allReal = $true
            foreach ($c in $cells) { if (Test-Placeholder $c) { $allReal = $false; break } }
            if ($allReal) { return $true }
            continue
        }
        if ($RequireTableRow) { continue }
        $clean = ($t -replace '^[-*]\s+', '') -replace '`', ''
        if (-not (Test-Placeholder $clean)) { return $true }
    }
    return $false
}


# Presence alone made "syntax unverified / structure unverified / ... / verdict
# pass" a valid review: the field was non-empty, so every gate said OK. The
# conclusion template and the rules already forbid that combination, so check it
# here instead of trusting prose. Field names and markers live in
# harness-required.json to keep this file pure ASCII.
$script:sqlCfg = $null
$cfgPath = Join-Path $PSScriptRoot 'harness-required.json'
if (Test-Path -LiteralPath $cfgPath) {
    try {
        $cfgAll = (Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8) | ConvertFrom-Json
        if ($cfgAll.PSObject.Properties['sqlReview']) { $script:sqlCfg = $cfgAll.sqlReview }
    } catch { }
}

function Get-SqlCfg {
    param([string]$Name)
    if (-not $script:sqlCfg) { return $null }
    $p = $script:sqlCfg.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

# The review table is the machine-readable form of the review conclusion. Its
# enum values are Chinese, so they live in harness-required.json and the script
# only compares strings.
$script:reviewCfg = $null
$script:reviewStrict = $true
if (Test-Path -LiteralPath $cfgPath) {
    try {
        $cfgAll = (Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8) | ConvertFrom-Json
        if ($cfgAll.PSObject.Properties['reviewLedger']) { $script:reviewCfg = $cfgAll.reviewLedger }
        if ($cfgAll.PSObject.Properties['reviewLedgerStrict']) { $script:reviewStrict = [bool]$cfgAll.reviewLedgerStrict }
    } catch { }
}

function Get-ReviewCfg {
    param([string]$Name)
    if (-not $script:reviewCfg) { return $null }
    $p = $script:reviewCfg.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

function Get-ReviewList {
    param([string]$Name)
    $v = Get-ReviewCfg $Name
    if ($null -eq $v) { return @() }
    return @($v | ForEach-Object { [string]$_ })
}

function Assert-SqlReview {
    $sql = Get-FieldRaw 'sql_review'
    if (Test-Placeholder $sql) {
        Add-Fail 'sql_review' 'missing (write the review, or a "no SQL change" marker)'
        return
    }
    if (-not $script:sqlCfg) { return }

    foreach ($m in @(Get-SqlCfg 'noneMarkers')) {
        if ($m -and $sql.Contains([string]$m)) { return }
    }

    $keys = Get-SqlCfg 'keys'
    $unknown = @(Get-SqlCfg 'unknownMarkers')
    $passVerdicts = @(Get-SqlCfg 'passVerdicts')
    if (-not $keys) { return }

    # A pass verdict is a claim about work that was done: it must point at an
    # artefact a reviewer can open. Record the .harness/... references once, so
    # the verdict check and the existence check below cannot disagree.
    $evidenceMatches = @([regex]::Matches($sql, '\.harness[\\/][^\s\u00B7,;:()\[\]]+'))
    $hasEvidence = ($evidenceMatches.Count -gt 0)

    # The conclusion template separates the parts with a middle dot.
    $segs = @($sql -split '[\u00B7|]' | ForEach-Object { $_.Trim() } | Where-Object { $_.Length -gt 0 })
    $vals = @{}
    foreach ($name in @('syntax', 'structure', 'binding', 'result', 'plan', 'verdict')) {
        $word = [string]$keys.$name
        if (-not $word) { continue }
        foreach ($s in $segs) {
            if ($s.StartsWith($word)) { $vals[$name] = $s.Substring($word.Length).Trim(); break }
        }
    }

    $verdict = [string]$vals['verdict']
    $verdictIsPass = $false
    if ($verdict) {
        $isPass = $false
        foreach ($p in $passVerdicts) { if ($p -and $verdict.Contains([string]$p)) { $isPass = $true; break } }
        $verdictIsPass = $isPass
        if ($isPass) {
            foreach ($name in @('syntax', 'structure', 'binding', 'result', 'plan')) {
                $v = [string]$vals[$name]
                if (-not $v) { continue }
                foreach ($u in $unknown) {
                    if ($u -and $v.Contains([string]$u)) {
                        Add-Fail 'sql_review' ("verdict claims a pass but '$name' says '$v'; a layer that was not verified cannot end in a pass")
                    }
                }
            }
        }
    }

    # "pass" written by hand is self-report, not evidence. The EXPLAIN output or
    # the query-result summary belongs under the feature's sql-review/ folder,
    # and the review must cite it; a non-pass verdict (e.g. pending DBA) is not
    # required to cite anything.
    if ($verdictIsPass -and -not $hasEvidence) {
        Add-Fail 'sql_review' 'verdict claims a pass but cites no .harness evidence path; write the EXPLAIN / query result summary under .harness/changes/<feature>/sql-review/ and reference it'
    }

    # A referenced path is a claim: the evidence must actually be on disk.
    $rootFull = $rootPath.TrimEnd('\')
    foreach ($m in $evidenceMatches) {
        $rel = $m.Value -replace '/', '\'
        if (-not (Test-Path -LiteralPath (Join-Path $rootFull $rel))) {
            Add-Fail 'sql_review' ("references a missing evidence path: " + $m.Value)
        }
    }

    # Every data source named by the review must be declared in the compiled
    # sql-review binding. A binding that lists four sources while the SQL runs on
    # a fifth is how "verified" turns into a production surprise.
    $dsLabel = [string](Get-SqlCfg 'datasourceLabel')
    $tokPat = [string](Get-SqlCfg 'sourceTokenPattern')
    if ($dsLabel -and $tokPat) {
        $sqlSkill = $null
        $skillsRoot = Join-Path $rootPath '.harness\skills'
        foreach ($cat in @(Get-ChildItem -LiteralPath $skillsRoot -Directory -ErrorAction SilentlyContinue)) {
            foreach ($sk in @(Get-ChildItem -LiteralPath $cat.FullName -Directory -ErrorAction SilentlyContinue)) {
                $f = Join-Path $sk.FullName 'SKILL.md'
                if (-not (Test-Path -LiteralPath $f)) { continue }
                $t = [System.IO.File]::ReadAllText($f, [System.Text.Encoding]::UTF8)
                if ($t -match '(?m)^name:\s*sql-review\s*$') { $sqlSkill = $t; break }
            }
            if ($sqlSkill) { break }
        }
        if ($sqlSkill) {
            $bindingLine = ''
            foreach ($line in ($sqlSkill -split "`n")) {
                if ($line.Contains($dsLabel)) { $bindingLine = $line; break }
            }
            if ($bindingLine) {
                $head = ($sql -split '[\u00B7|]')[0]
                foreach ($m in [regex]::Matches($head, $tokPat)) {
                    if (-not $bindingLine.Contains($m.Value)) {
                        Add-Fail 'sql_review' ("names data source '$($m.Value)' that the compiled sql-review binding does not list; add it to the datasource line")
                    }
                }
            }
        }
    }
}

# The review conclusion table is the machine-readable half of stage 6. A free
# text conclusion could say "no problems" while the diff carried a P0; a fixed
# table cannot, because the severity, fingerprint and evidence columns are
# checked. L1 has no summary, so it is skipped; every other flow must carry a
# well-formed table. Missing table follows reviewLedgerStrict (fresh install
# fails, upgraded project warns); a malformed table always fails.
function Assert-ReviewLedger {
    param([string]$Mode)

    $flowVal = Get-FieldRaw 'flow'
    if ($flowVal -and $flowVal -match '^L1(\s|$|[\(\uFF08])') { return }

    if (-not $script:reviewCfg) {
        if ($script:reviewStrict) {
            Add-Fail 'review_ledger' 'config missing (reviewLedger block absent from harness-required.json)'
        } else {
            Write-Host '[WARN] review_ledger: config missing; review table not checked' -ForegroundColor Yellow
        }
        return
    }

    $needles = @(Get-ReviewList 'section')
    $body = $null
    if ($needles.Count -gt 0) { $body = Get-SectionLines -Needles $needles }

    $rows = @()
    if ($null -ne $body) {
        $afterSep = $false
        foreach ($line in $body) {
            $t = $line.Trim()
            if ($t.Length -eq 0) { continue }
            if ($t -notmatch '^\|') { continue }
            if ($t -match '^\|?\s*:?-{2,}') { $afterSep = $true; continue }
            # A row before the separator is the header row.
            if (-not $afterSep) { continue }
            $rows += $t
        }
    }

    if ($rows.Count -eq 0) {
        if ($script:reviewStrict) {
            Add-Fail 'review_ledger' 'review table missing (add the 7-column table under the review section)'
        } else {
            Write-Host '[WARN] review_ledger: review table missing; skipped (reviewLedgerStrict=false)' -ForegroundColor Yellow
        }
        return
    }

    $reviewer = Get-LabelRaw ([string](Get-ReviewCfg 'reviewerField'))
    if (Test-Placeholder $reviewer) {
        Add-Fail 'review_ledger' 'reviewer field is empty or a placeholder'
    }
    $dimensions = Get-LabelRaw ([string](Get-ReviewCfg 'dimensionsField'))
    if (Test-Placeholder $dimensions) {
        Add-Fail 'review_ledger' 'six-dimension conclusion is empty or a placeholder'
    }

    $sevList = @(Get-ReviewList 'severities')
    $scopeList = @(Get-ReviewList 'scopes')
    $statusList = @(Get-ReviewList 'statuses')
    $noSev = [string](Get-ReviewCfg 'noIssueSeverity')
    $noScope = [string](Get-ReviewCfg 'noIssueScope')
    $noStatus = [string](Get-ReviewCfg 'noIssueStatus')
    $fpPattern = [string](Get-ReviewCfg 'fingerprintPattern')
    $expectedCols = @(Get-ReviewList 'columns').Count
    if ($expectedCols -le 0) { $expectedCols = 7 }

    $findingCount = 0
    $noIssueCount = 0
    foreach ($row in $rows) {
        # Escaped pipes (\|) belong to the cell text, so split with a lookbehind.
        $cells = @([regex]::Split($row.Trim().Trim('|'), '(?<!\\)\|'))
        if ($cells.Count -ne $expectedCols) {
            Add-Fail 'review_ledger' ("a review row has $($cells.Count) column(s); expected $expectedCols")
            continue
        }
        $vals = @()
        foreach ($c in $cells) { $vals += (($c -replace '`', '').Trim()) }

        $isPlaceholder = $false
        foreach ($v in $vals) { if ($v.StartsWith('<')) { $isPlaceholder = $true; break } }
        if ($isPlaceholder) {
            Add-Fail 'review_ledger' 'table still has a template placeholder row'
            continue
        }

        $sev = $vals[0]
        $scope = $vals[1]
        $status = $vals[2]
        $fp = $vals[3]
        $problem = $vals[4]
        $evidence = $vals[5]
        $disposition = $vals[6]

        if ($sev -eq $noSev) {
            $noIssueCount++
            if ($scope -ne $noScope) { Add-Fail 'review_ledger' "no-issue row must use scope '$noScope'" }
            if ($status -ne $noStatus) { Add-Fail 'review_ledger' "no-issue row must use status '$noStatus'" }
            if ($fp -ne '-') { Add-Fail 'review_ledger' 'no-issue row must use - as the fingerprint' }
            if (Test-Placeholder $problem) { Add-Fail 'review_ledger' 'no-issue row needs a problem statement (e.g. none found)' }
            if (Test-Placeholder $evidence) { Add-Fail 'review_ledger' 'no-issue row needs evidence / a six-dimension reference' }
            continue
        }

        $findingCount++
        if (Test-Placeholder $problem) { Add-Fail 'review_ledger' 'a review row needs a problem statement' }
        if ($sevList -notcontains $sev) { Add-Fail 'review_ledger' ("severity '$sev' is not one of: " + ($sevList -join ', ')) }
        if ($scopeList -notcontains $scope) { Add-Fail 'review_ledger' ("scope '$scope' is not one of: " + ($scopeList -join ', ')) }
        if ($statusList -notcontains $status) { Add-Fail 'review_ledger' ("status '$status' is not one of: " + ($statusList -join ', ')) }

        if ($sev -eq 'P0' -or $sev -eq 'P1') {
            # Parenthesize the command call: Test-Placeholder $fp -or ... would
            # bind -or as a parameter name and silently skip the check.
            if ((Test-Placeholder $fp) -or ($fpPattern -and $fp -notmatch $fpPattern)) {
                Add-Fail 'review_ledger' "$sev requires a kebab-case fingerprint"
            }
            if (Test-Placeholder $evidence) {
                Add-Fail 'review_ledger' "$sev requires evidence (file:line or a command)"
            }
        }

        if ($Mode -eq 'final') {
            $finalList = @()
            if ($sev -eq 'P0') { $finalList = @(Get-ReviewList 'p0FinalStatuses') }
            elseif ($sev -eq 'P1') { $finalList = @(Get-ReviewList 'p1FinalStatuses') }
            elseif ($sev -eq 'P2') { $finalList = @(Get-ReviewList 'p2FinalStatuses') }
            if ($finalList.Count -gt 0 -and $finalList -notcontains $status) {
                Add-Fail 'review_ledger' ("$sev cannot end as '$status'; allowed: " + ($finalList -join ', '))
            }
            if (Test-Placeholder $disposition) {
                Add-Fail 'review_ledger' 'every finding needs a disposition at close-out (fixed / where it moved / why accepted)'
            }
        }
    }

    if ($noIssueCount -gt 1) { Add-Fail 'review_ledger' 'the no-issue row appears more than once' }
    if ($noIssueCount -gt 0 -and $findingCount -gt 0) {
        Add-Fail 'review_ledger' 'a no-issue row cannot coexist with findings'
    }
}

if ($OnlySqlReview) {
    Assert-SqlReview
    if ($fails.Count -gt 0) {
        foreach ($f in $fails) { Write-Host "[FAIL] $f" }
        Write-Host "check-summary: $($fails.Count) fail(s)"
        Complete-Harness 1
    }
    if (-not $Quiet) { Write-Host '[OK] sql_review content valid' }
    Complete-Harness 0
}

if ($Stage -eq 'review') {
    Assert-ReviewLedger -Mode 'review'
    if ($fails.Count -gt 0) {
        foreach ($f in $fails) { Write-Host "[FAIL] $f" }
        Write-Host "check-summary: $($fails.Count) fail(s)"
        Complete-Harness 1
    }
    if (-not $Quiet) { Write-Host '[OK] review ledger valid' }
    Complete-Harness 0
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

# ------------------------------------------------------------ content (before code)
# These three sections are what makes the summary useful while coding: they say
# what "done" means, what the change touches and how the work is split. A summary
# with a complete field block and a template table full of <slots> passes every
# count check and still guides nothing, so the content is checked here.
if (-not (Test-RealContent -Needles (Get-ContentNeedles 'acceptance') -RequireTableRow)) {
    Add-Fail 'acceptance' 'feature table has no real row (fill every acceptance criterion, not the template slot)'
}
if (-not (Test-RealContent -Needles (Get-ContentNeedles 'impact'))) {
    Add-Fail 'impact' 'impact section is empty (modules / interfaces / tables, or an explicit "none")'
}
if (-not (Test-RealContent -Needles (Get-ContentNeedles 'tasks') -RequireTableRow)) {
    Add-Fail 'tasks' 'task table has no real row (split the work into tasks, each <= 4h)'
}

$modules = Get-FieldRaw 'touched_modules'
if (Test-Placeholder $modules) {
    Add-Fail 'touched_modules' 'missing or placeholder (write none when nothing was touched)'
}

# ---------------------------------------------------------------- final only
if ($Stage -eq 'final') {
    # Counts are only known once the work is done. Asking for them at task start
    # forced a fake "corrections: 0" that was then edited later, so the number a
    # reviewer trusted was written before the review happened.
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

    Assert-SqlReview
    Assert-ReviewLedger -Mode 'final'
}

# --------------------------------------------------------------------- report
if ($fails.Count -gt 0) {
    foreach ($f in $fails) { Write-Host "[FAIL] $f" }
    Write-Host "check-summary: $($fails.Count) fail(s)"
    Complete-Harness 1
}

if (-not $Quiet) { Write-Host '[OK] summary fields valid' }

# Remember the task locally, but only after the summary validated: a typo in
# -Feature must not become the pointer the hook later trusts. The file lives in
# the git dir (never committed, no merge conflicts, no .gitignore entry), and it
# is what lets the pre-commit hook attribute code without reading a branch name.
if ($Feature -and -not $File) {
    try {
        $ptrRel = (& git -C $rootPath rev-parse --git-path harness-current-task 2>$null | Select-Object -First 1)
        if ($ptrRel) {
            $ptrPath = ([string]$ptrRel).Trim()
            if (-not [System.IO.Path]::IsPathRooted($ptrPath)) { $ptrPath = Join-Path $rootPath $ptrPath }
            [System.IO.File]::WriteAllText($ptrPath, $Feature + "`n", (New-Object System.Text.UTF8Encoding($false)))
        }
    } catch { }
}
Complete-Harness 0
