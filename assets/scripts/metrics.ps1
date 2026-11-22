<#
  metrics.ps1 -- collect the numbers that make "A7: no repeated mistake" measurable

  WHY
    summary.md has carried corrections: / loaded_skills: for a while, but nothing
    ever read them, so the two-week review depended on memory. This script turns
    those fields plus the gate log into counts and a verdict.

  SOURCES
    .harness/changes/<feature>/summary.md   corrections: N   impl_corrections: N
                                            loaded_skills: a,b   lesson_id: id
    .harness/metrics/gate.jsonl             {"ts":"...","blocked":1}  (written by pre-commit)

  LESSON IDS
    lesson_id makes "persist on the second occurrence" machine-checkable. Each
    correction may carry its own id; all ids in a summary are collected (deduped
    per task). When the same id appears in >= 2 tasks the verdict says to promote
    it into a rule, a gate or a skill. No semantics needed.

  COMPARE
    -Compare splits the history into the current -Days window and the window
    immediately before it, then prints IMPROVING / REGRESSING / FLAT /
    INSUFFICIENT DATA. This is the project-level half of A6: task-level
    impl_corrections can be zero while the trend still gets worse. -Compare
    needs -Days N (N > 0); with -Days 0 there is no previous window.

  PRODUCTIVITY
    Four proxies, all computed from the sources above; nothing is invented:
    1. first pass rate -- a task "passes" when the gate scan events attributed
       to it contain no blocked=1 event. A task with no attributed event is
       UNKNOWN, never a pass; the denominator is the tasks that own an event.
    2. gate round trips -- blocked=1 scan events per task, averaged over the
       tasks that own an event, plus the 0 / 1 / 2+ distribution.
    3. lead time -- summary date -> last commit touching
       .harness/changes/<feature>, in days. The record directory is the only
       anchor a summary offers (it does not record source paths), and the
       summary date is day-granular, so a same-day task reads as about 1 day.
       No commit or no date line means unknown.
    4. reuse -- for a skill loaded by >= 2 tasks, does the second task
       (ordered by date) show fewer corrections OR fewer round trips than the
       first? Each pair is measured only on the dimensions both tasks
       recorded; a skill seen once is n/a and stays out of the denominator.

  ATTRIBUTION
    gate.jsonl has no task key (pre-commit writes only ts / blocked / files), so
    per-task attribution is a proxy: the events from one day before the first
    commit that touched .harness/changes/<feature> up to its last commit (a
    blocked attempt creates no commit, hence the lookback). A task with no
    commit falls back to its summary date, [D, D+1). An event is claimed by at
    most one task; overlapping (concurrent) features can therefore under-count,
    and those tasks stay unknown instead of being credited as first-pass.

  USAGE
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\metrics.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\metrics.ps1 -Json
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\metrics.ps1 -Days 14
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\metrics.ps1 -Days 28 -SkillMinAgeDays 28
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\metrics.ps1 -Days 14 -Compare
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\metrics.ps1 -SelfTest

  RETIREMENT
    A skill is only a retirement candidate when the observation window is at
    least 28 days AND the skill itself is at least -SkillMinAgeDays old. A skill
    added yesterday cannot have been loaded in the last 28 days; listing it as
    "candidate for deletion" is a false signal. Age comes from the first git
    commit that added the skill directory, with file timestamps as a fallback.

  EXIT CODE
    0 always (report only). Use the printed verdict during the biweekly review.

  NOTE  Pure ASCII. -Days counts tasks by the first ISO date near the top of
        summary.md; a summary without one falls back to file mtime and is
        listed as "undated". Gate events without a parsable ts are skipped
        and counted, never silently dropped.
#>
[CmdletBinding()]
param(
    [string]$Root = (Get-Location).Path,
    [int]$Days = 0,
    [int]$SkillMinAgeDays = 28,
    [switch]$Compare,
    [switch]$Json,
    [switch]$Quiet,
    [switch]$LessonGate,
    [switch]$SelfTest,
    [switch]$NoExit
)

function Complete-Harness {
    param([int]$Code)
    if ($NoExit) { throw ('__HARNESS_EXIT__' + $Code) }
    exit $Code
}

# SelfTest builds a throwaway project under %TEMP% (a git repo with two dated
# summaries, a third without a commit, and a gate log with one blocked scan) and
# runs this same script on it, so the four productivity proxies are asserted
# against known inputs instead of whatever the real history happens to hold.
function Invoke-MetricsSelfTest {
    $bad = 0
    function Add-SelfCheck {
        param([ref]$Bad, [string]$Label, [bool]$Ok)
        if ($Ok) { Write-Host ("ok: " + $Label) } else { Write-Host ("[FAIL] " + $Label) -ForegroundColor Red; $Bad.Value++ }
    }
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('hb-metrics-selftest-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    try {
        $changes = Join-Path $tmp '.harness\changes'
        $metricsDir = Join-Path $tmp '.harness\metrics'
        New-Item -ItemType Directory -Force -Path $changes | Out-Null
        New-Item -ItemType Directory -Force -Path $metricsDir | Out-Null

        foreach ($spec in @(
            @{ Name = 'alpha'; Date = '2026-03-01'; Corr = 3; Skills = 'demo-skill' },
            @{ Name = 'beta'; Date = '2026-03-05'; Corr = 1; Skills = 'demo-skill' },
            @{ Name = 'gamma'; Date = '2026-03-10'; Corr = 0; Skills = 'other-skill' }
        )) {
            $dir = Join-Path $changes $spec.Name
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
            $body = @(
                ('# ' + $spec.Name + ' change'),
                '',
                ('- date: ' + $spec.Date),
                ('- corrections: ' + $spec.Corr),
                '- impl_corrections: 0',
                ('- loaded_skills: ' + $spec.Skills),
                ''
            )
            [System.IO.File]::WriteAllText((Join-Path $dir 'summary.md'), (($body -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
        }

        $gateLines = @(
            '{"event":"scan","ts":"2026-03-01T14:00:00Z","blocked":1,"files":1,"hunks":1}',
            '{"event":"scan","ts":"2026-03-01T15:00:00Z","blocked":0,"files":1,"hunks":0}',
            '{"event":"commit","ts":"2026-03-02T12:00:00Z","hash":"aaaaaaa","scanned":1}',
            '{"event":"scan","ts":"2026-03-05T14:00:00Z","blocked":0,"files":1,"hunks":0}',
            '{"event":"commit","ts":"2026-03-06T12:00:00Z","hash":"bbbbbbb","scanned":1}'
        )
        [System.IO.File]::WriteAllText((Join-Path $metricsDir 'gate.jsonl'), (($gateLines -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))

        $hasGit = $null -ne (Get-Command git -ErrorAction SilentlyContinue)
        if ($hasGit) {
            & git -C $tmp init -q 2>$null | Out-Null
            # One commit per record directory with a fixed committer date: the
            # lead time then has a known answer instead of "whenever it ran".
            foreach ($c in @(
                @{ Date = '2026-03-02T12:00:00+0000'; Path = '.harness/changes/alpha/summary.md' },
                @{ Date = '2026-03-06T12:00:00+0000'; Path = '.harness/changes/beta/summary.md' }
            )) {
                & git -C $tmp add -- $c.Path 2>$null | Out-Null
                $env:GIT_AUTHOR_DATE = $c.Date
                $env:GIT_COMMITTER_DATE = $c.Date
                & git -C $tmp -c 'user.email=s@example.com' -c 'user.name=selftest' -c 'commit.gpgsign=false' commit -q -m ('add ' + $c.Path) 2>$null | Out-Null
            }
            $env:GIT_AUTHOR_DATE = $null
            $env:GIT_COMMITTER_DATE = $null
        }

        $psHost = if (Get-Command powershell -ErrorAction SilentlyContinue) { 'powershell' } else { 'pwsh' }
        $raw = @(& $psHost -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Root $tmp -Json 2>&1)
        $text = ($raw | Out-String)
        $j = $null
        $startIdx = $text.IndexOf('{')
        $endIdx = $text.LastIndexOf('}')
        if ($startIdx -ge 0 -and $endIdx -gt $startIdx) {
            try { $j = ($text.Substring($startIdx, $endIdx - $startIdx + 1) | ConvertFrom-Json) } catch { $j = $null }
        }
        Add-SelfCheck ([ref]$bad) 'json output is parsable' ($null -ne $j)
        if ($null -ne $j) {
            Add-SelfCheck ([ref]$bad) 'first pass rate = 50% (one blocked task, one clean task)' ($j.firstPassRate -eq 50)
            Add-SelfCheck ([ref]$bad) 'task without a gate event is unknown, not a pass' ($j.gateRoundTrips.unknown -eq 1)
            Add-SelfCheck ([ref]$bad) 'round trips: average 0.5, distribution 0/1/2+ = 1/1/0' `
                ($j.gateRoundTrips.average -eq 0.5 -and $j.gateRoundTrips.zero -eq 1 -and $j.gateRoundTrips.one -eq 1 -and $j.gateRoundTrips.twoPlus -eq 0)
            Add-SelfCheck ([ref]$bad) 'reuse: one pair, corrections 3 -> 1 counts as improved' `
                ($j.reuseRate.pairs -eq 1 -and $j.reuseRate.improved -eq 1 -and $j.reuseRate.rate -eq 100)
            Add-SelfCheck ([ref]$bad) 'a skill seen once stays n/a' (@($j.reuseRate.singleTaskSkills) -contains 'other-skill')
            if ($hasGit) {
                Add-SelfCheck ([ref]$bad) 'lead time measured for the two committed tasks' `
                    ($j.leadTime.measured -eq 2 -and $j.leadTime.unknown -eq 1)
                Add-SelfCheck ([ref]$bad) 'lead time is a positive number of days' `
                    ($null -ne $j.leadTime.averageDays -and $j.leadTime.averageDays -gt 0.9 -and $j.leadTime.averageDays -lt 2.6)
            } else {
                Write-Host '[SKIP] git not found: lead time assertions skipped' -ForegroundColor Yellow
            }
        }
    } finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }
    if ($bad -eq 0) {
        Write-Host 'METRICS SELFTEST OK' -ForegroundColor Green
    } else {
        Write-Host ("METRICS SELFTEST FAILED: " + $bad + " check(s)") -ForegroundColor Red
    }
    return $bad
}

$ErrorActionPreference = 'Stop'
if ($SelfTest) {
    $selfBad = Invoke-MetricsSelfTest
    if ($selfBad -gt 0) { Complete-Harness 1 }
    Complete-Harness 0
}
$rootPath = (Resolve-Path -LiteralPath $Root).Path

$changesRoot = Join-Path $rootPath '.harness\changes'
$logPath = Join-Path $rootPath '.harness\metrics\gate.jsonl'
# Durable team knowledge, not local machine state: keep the promoted list next
# to the lessons index so every clone sees the same "already promoted" status.
$promotedPath = Join-Path $rootPath '.harness\lessons-promoted.txt'
$skillsRoot = Join-Path $rootPath '.harness\skills'
$smallBad = 0

# The review table's enum values are Chinese, so they live in
# harness-required.json and this script only compares strings.
$script:reviewCfg = $null
$cfgPath = Join-Path $PSScriptRoot 'harness-required.json'
if (Test-Path -LiteralPath $cfgPath) {
    try {
        $cfgAll = (Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8) | ConvertFrom-Json
        if ($cfgAll.PSObject.Properties['reviewLedger']) { $script:reviewCfg = $cfgAll.reviewLedger }
    } catch { }
}

function Get-ReviewCfgList {
    param([string]$Name)
    if (-not $script:reviewCfg) { return @() }
    $p = $script:reviewCfg.PSObject.Properties[$Name]
    if (-not $p) { return @() }
    return @($p.Value | ForEach-Object { [string]$_ })
}

# Body of a "## heading" section, up to the next heading of the same or a
# higher level. Returns $null when no heading matches.
function Get-SectionBodyLines {
    param([string]$Text, [string[]]$Needles)
    $lines = $Text -split "\r?\n"
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

# Review rows that are real findings: header, separator, template slots and the
# no-issue row are skipped. check-summary decides validity; metrics only counts.
function Get-ReviewRows {
    param([string]$Text)
    $rows = @()
    if (-not $script:reviewCfg) { return $rows }
    # L1 has no summary; a stray one must not contribute review rows.
    if ($Text -match '(?m)^[ \t]*(?:[-*][ \t]+)?(?:[^\r\n:\uFF1A]*?[:\uFF1A][ \t]*`?`?)?`?`?(?<![A-Za-z0-9_\-])flow:\s*`?\s*L1([ \t`]|$|[\(\uFF08])') { return $rows }
    $needles = @(Get-ReviewCfgList 'section')
    if ($needles.Count -eq 0) { return $rows }
    $body = Get-SectionBodyLines -Text $Text -Needles $needles
    if ($null -eq $body) { return $rows }
    $noSev = '-'
    $p = $script:reviewCfg.PSObject.Properties['noIssueSeverity']
    if ($p) { $noSev = [string]$p.Value }
    $sevList = @(Get-ReviewCfgList 'severities')
    $afterSep = $false
    foreach ($line in $body) {
        $t = $line.Trim()
        if ($t.Length -eq 0) { continue }
        if ($t -notmatch '^\|') { continue }
        if ($t -match '^\|?\s*:?-{2,}') { $afterSep = $true; continue }
        if (-not $afterSep) { continue }
        $cells = @([regex]::Split($t.Trim().Trim('|'), '(?<!\\)\|'))
        if ($cells.Count -ne 7) { continue }
        $vals = @()
        foreach ($c in $cells) { $vals += (($c -replace '`', '').Trim()) }
        $skip = $false
        foreach ($v in $vals) { if ($v.StartsWith('<')) { $skip = $true; break } }
        if ($skip) { continue }
        if ($vals[0] -eq $noSev) { continue }
        # A malformed summary is the gate's problem; the report must not turn an
        # unknown severity into a bogus fingerprint row.
        if ($sevList.Count -gt 0 -and $sevList -notcontains $vals[0]) { continue }
        $rows += [pscustomobject]@{
            Severity = $vals[0]
            Scope = $vals[1]
            Status = $vals[2]
            Fingerprint = $vals[3]
            Problem = $vals[4]
            Evidence = $vals[5]
            Disposition = $vals[6]
        }
    }
    return $rows
}

# ------------------------------------------------------------- read once, filter later
# Skill names appear in two shapes: "04-sql-review" in a summary and
# "biz-dev/04-sql-review" in a path or index. Compare on the last path segment
# with the numeric prefix removed, or a loaded skill looks "never loaded".
function Get-SkillKey {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return '' }
    $n = $Name.Trim() -replace '\\', '/'
    $n = ($n -split '/')[-1]
    return ($n -replace '^\d+-', '')
}

# A retirement decision needs the skill's own age, not only the observation
# window: a skill added yesterday cannot have been loaded in the last 28 days.
# Prefer the first git commit that added the directory; fall back to file
# timestamps when the project is not a git repo or the skill is untracked.
function Get-SkillInfo {
    param([string]$Root, [string]$Category, [string]$Name, [string]$Dir)
    $rel = '.harness/skills/' + $Category + '/' + $Name
    $age = $null
    $source = 'unknown'
    try {
        # ACR covers add / copy / rename: a skill that was renamed still gets its
        # original add commit instead of looking brand new.
        $dateText = (& git -C $Root log --diff-filter=ACR --format=%cs --reverse -- $rel 2>$null | Select-Object -First 1)
        if ($dateText) {
            $d = [datetime]::ParseExact(([string]$dateText).Trim(), 'yyyy-MM-dd', $null)
            # Clamp negative values (future commit dates / clock skew) to 0.
            $age = [Math]::Max(0, ((Get-Date).Date - $d.Date).Days)
            $source = 'git-first-commit'
        }
    } catch { }
    if ($null -eq $age) {
        # Clone / shallow-clone fallback is conservative: the timestamp may be
        # the copy date, which makes the skill look younger than it is.
        $skillFile = Join-Path $Dir 'SKILL.md'
        foreach ($prop in @('CreationTime', 'LastWriteTime')) {
            try {
                $d = (Get-Item -LiteralPath $skillFile).$prop.Date
                $age = [Math]::Max(0, ((Get-Date).Date - $d.Date).Days)
                $source = $prop.ToLowerInvariant()
                break
            } catch { }
        }
    }
    return [pscustomobject]@{
        Name = (Get-SkillKey $Name)
        RawName = $Name
        AgeDays = $age
        AgeSource = $source
    }
}

# Parsing is split from windowing so that -Compare can reuse the same task and
# event objects for two windows instead of parsing the files twice (and drifting).
function Get-SummaryTasks {
    $out = @()
    if (-not (Test-Path -LiteralPath $changesRoot)) { return $out }
    Get-ChildItem -LiteralPath $changesRoot -Directory -Force | Where-Object { $_.Name -ne '_template' } | ForEach-Object {
        $summary = Join-Path $_.FullName 'summary.md'
        if (-not (Test-Path -LiteralPath $summary)) { return }
        $text = [System.IO.File]::ReadAllText($summary, [System.Text.Encoding]::UTF8)

        # the date lives on a header line; take the first ISO date in the top
        # of the file (ASCII-only: no Chinese label needed in the script)
        $taskDate = $null
        $head = (($text -split "\r?\n") | Select-Object -First 15) -join "`n"
        if ($head -match '(\d{4}-\d{2}-\d{2})') {
            try { $taskDate = [datetime]::ParseExact($matches[1], 'yyyy-MM-dd', $null) } catch { $taskDate = $null }
        }
        $dated = ($null -ne $taskDate)
        if (-not $dated) { $taskDate = (Get-Item -LiteralPath $summary).LastWriteTime.Date }

        $corr = $null
        # Field lines use the same shape check-summary.ps1 validates: a bare field,
        # a list item, or a labelled list item. A prose mention must not become data.
        # The lookbehind keeps "impl_corrections:" from satisfying "corrections:".
        # U+FF1A is written as \uFF1A so this file stays pure ASCII for PS 5.1.
        if ($text -match '(?m)^[ \t]*(?:[-*][ \t]+)?(?:[^\r\n:\uFF1A]*?[:\uFF1A][ \t]*`?`?)?`?`?(?<![A-Za-z0-9_\-])corrections:\s*`?\s*(\d+)') { $corr = [int]$matches[1] }
        $impl = $null
        if ($text -match '(?m)^[ \t]*(?:[-*][ \t]+)?(?:[^\r\n:\uFF1A]*?[:\uFF1A][ \t]*`?`?)?`?`?(?<![A-Za-z0-9_\-])impl_corrections:\s*`?\s*(\d+)') { $impl = [int]$matches[1] }

        $skills = @()
        $hasSkillsField = $false
        if ($text -match '(?m)^[ \t]*(?:[-*][ \t]+)?(?:[^\r\n:\uFF1A]*?[:\uFF1A][ \t]*`?`?)?`?`?loaded_skills:\s*([^\r\n]+)') {
            $hasSkillsField = $true
            # each comma item starts with an optional backtick then the name;
            # anything after the name (prose, "<...>", CLOSE) is ignored
            $skills = @()
            foreach ($part in $matches[1].Split(',')) {
                # Accept both "04-sql-review" and "biz-dev/04-sql-review"; the key
                # is normalized so the loaded name and the installed name compare.
                $m = [regex]::Match($part, '^\s*`?\s*([A-Za-z0-9][A-Za-z0-9_.\-/\\]*)')
                if ($m.Success) {
                    $name = Get-SkillKey $m.Groups[1].Value
                    if ($name -and $name.ToLower() -ne 'none') { $skills += $name }
                }
            }
        }
        # one lesson_id per correction: collect ALL of them, dedupe within the task
        # (the same lesson twice in one task is still one task, not two occurrences)
        # The optional "-- note" is the one-line summary used by lessons.md.
        $lessons = @()
        $lessonNotes = @{}
        foreach ($m in [regex]::Matches($text, '(?m)^[ \t]*(?:[-*][ \t]+)?(?:[^\r\n:\uFF1A]*?[:\uFF1A][ \t]*`?`?)?`?`?lesson_id:\s*`?\s*([A-Za-z0-9][A-Za-z0-9_.\-]*)(?:\s*(?:--|\|)\s*([^\r\n`]*))?')) {
            $id = $m.Groups[1].Value
            if ($lessons -notcontains $id) { $lessons += $id }
            $note = $m.Groups[2].Value.Trim()
            if ($note -and -not $lessonNotes.ContainsKey($id)) { $lessonNotes[$id] = $note }
        }
        $out += [pscustomobject]@{
            Feature = $_.Name
            Date = $taskDate
            Dated = $dated
            Corrections = $corr
            ImplCorrections = $impl
            Skills = $skills
            Lessons = $lessons
            LessonNotes = $lessonNotes
            ReviewRows = @(Get-ReviewRows $text)
            HasCorrections = ($null -ne $corr)
            HasImpl = ($null -ne $impl)
            HasSkills = $hasSkillsField
            HasRealSkill = ($skills.Count -gt 0)
        }
    }
    return $out
}

function Get-SmallTasks {
    $out = @()
    $smallPath = Join-Path $changesRoot '_small.md'
    if (-not (Test-Path -LiteralPath $smallPath)) { return $out }
    $text = [System.IO.File]::ReadAllText($smallPath, [System.Text.Encoding]::UTF8)
    $fileDate = (Get-Item -LiteralPath $smallPath).LastWriteTime.Date
    foreach ($line in ($text -split "`r?`n")) {
        $trim = $line.Trim()
        if (-not $trim.StartsWith('|')) { continue }
        $cols = @($trim.Trim('|') -split '\|' | ForEach-Object { $_.Trim() })
        # A data row must have exactly 9 columns. Short rows are almost always a
        # missed field; silently dropping them would make the L1 task invisible.
        if ($cols.Count -ne 9) {
            $script:smallBad++
            continue
        }
        $dateText = $cols[0].Trim().Trim('`')
        # Header, separator and the template placeholder are not data rows.
        if ($dateText -match '^<') { continue }
        if ($dateText -match '^-{2,}$') { continue }
        if ($dateText -notmatch '\d{4}-\d{2}-\d{2}') {
            # The localized header is the only non-ASCII non-date first cell.
            if ($dateText -match '[^\x00-\x7F]') { continue }
            $script:smallBad++
            continue
        }
        $taskDate = $null
        $dated = $false
        try { $taskDate = [datetime]::ParseExact($dateText, 'yyyy-MM-dd', $null); $dated = $true } catch { }
        if (-not $dated) {
            $script:smallBad++
            $taskDate = $fileDate
        }
        $feature = $cols[1].Trim().Trim('`')
        if ($feature -match '^<') { continue }
        if (-not $feature) {
            $script:smallBad++
            continue
        }
        if ($cols[2].Trim() -notmatch '^L1\b') {
            $script:smallBad++
            continue
        }

        $skills = @()
        $rawSkills = $cols[3].Trim().Trim('`')
        if ($rawSkills -and $rawSkills.ToLower() -ne 'none') {
            foreach ($part in $rawSkills.Split(',')) {
                $m = [regex]::Match($part, '^\s*`?\s*([A-Za-z0-9][A-Za-z0-9_.\-/\\]*)')
                if ($m.Success) {
                    $name = Get-SkillKey $m.Groups[1].Value
                    if ($name -and $name.ToLower() -ne 'none') { $skills += $name }
                }
            }
        }

        $corr = -1
        if ($cols[4].Trim() -match '^(\d+)$') { $corr = [int]$matches[1] } else {
            $script:smallBad++
            continue
        }
        $impl = -1
        if ($cols[5].Trim() -match '^(\d+)$') { $impl = [int]$matches[1] } else {
            $script:smallBad++
            continue
        }
        if ($impl -gt $corr) {
            $script:smallBad++
            continue
        }

        $lessons = @()
        $lessonNotes = @{}
        $rawLessons = $cols[6].Trim().Trim('`')
        if ($rawLessons -and $rawLessons -ne '-') {
            foreach ($part in $rawLessons.Split(';')) {
                $part = $part.Trim().Trim('`')
                if (-not $part -or $part -eq '-') { continue }
                $m = [regex]::Match($part, '^([A-Za-z0-9][A-Za-z0-9_.\-]*)(?:\s*(?:--|\|)\s*(.*))?$')
                if (-not $m.Success) {
                    $script:smallBad++
                    continue
                }
                $id = $m.Groups[1].Value
                if ($id -eq 'none') {
                    $script:smallBad++
                    continue
                }
                if ($lessons -notcontains $id) { $lessons += $id }
                $note = $m.Groups[2].Value.Trim().Trim('`')
                if ($note -and -not $lessonNotes.ContainsKey($id)) { $lessonNotes[$id] = $note }
            }
        }

        $out += [pscustomobject]@{
            Feature = $feature
            Date = $taskDate
            Dated = $dated
            Corrections = $corr
            ImplCorrections = $impl
            Skills = $skills
            Lessons = $lessons
            LessonNotes = $lessonNotes
            Flow = 'L1'
            ReviewRows = @()
            HasCorrections = ($null -ne $corr)
            HasImpl = ($null -ne $impl)
            HasSkills = $true
            HasRealSkill = ($skills.Count -gt 0)
        }
    }
    return $out
}

# Committer timestamps of every commit that touched the record directory of one
# feature. This is the only per-task anchor available: gate.jsonl has no feature
# column and summary.md does not record source paths.
function Get-TaskGitRange {
    param([string]$Root, [string]$Feature)
    $times = @()
    $rel = '.harness/changes/' + $Feature
    try {
        if (Get-Command git -ErrorAction SilentlyContinue) {
            $raw = @(& git -C $Root log '--format=%ct' '--reverse' '--' $rel 2>$null)
            foreach ($line in $raw) {
                $t = ([string]$line).Trim()
                if ($t -match '^\d+$') { $times += [long]$t }
            }
        }
    } catch {
        # A missing git binary or a non-repository root means "unknown", not
        # "zero days": the metric must not turn a failed lookup into a pass.
        $times = @()
    }
    if ($times.Count -eq 0) { return [pscustomobject]@{ Count = 0; First = $null; Last = $null } }
    return [pscustomobject]@{ Count = $times.Count; First = $times[0]; Last = $times[$times.Count - 1] }
}

function Get-GateEvents {
    $out = @()
    if (-not (Test-Path -LiteralPath $logPath)) { return $out }
    foreach ($line in [System.IO.File]::ReadLines($logPath)) {
        if ($line.Trim().Length -eq 0) { continue }
        try { $e = $line | ConvertFrom-Json } catch {
            # A malformed gate line still counts as an un-dateable event so the
            # "skipped" number in the report cannot hide a broken log.
            $out += [pscustomobject]@{ Event = 'invalid'; Date = $null; Ts = $null; Blocked = '0'; Scanned = ''; Reason = '' }
            continue
        }
        $evtDate = $null
        $evtTs = $null
        if ($e.ts) { try { $evtTs = [datetime]$e.ts } catch { $evtTs = $null } }
        if ($null -ne $evtTs) { $evtDate = $evtTs.Date }
        $out += [pscustomobject]@{
            Event = $e.event
            Date = $evtDate
            # Ts keeps the wall-clock time: the productivity attribution needs a
            # range, not just a day, to tell two same-day attempts apart.
            Ts = $evtTs
            Blocked = "$($e.blocked)"
            Scanned = "$($e.scanned)"
            # assoc_skip carries why attribution was skipped; without it the
            # "gate is off" and "first adoption" cases look identical here.
            Reason = "$($e.reason)"
        }
    }
    return $out
}

# Window is [From, To): From inclusive, To exclusive. Undated tasks are kept
# (and counted) so the denominator never shrinks silently.
function Select-Window {
    param($Tasks, $Events, [datetime]$From, [datetime]$To)
    $t = @($Tasks | Where-Object { $_.Date -ge $From -and $_.Date -lt $To })
    $e = @($Events | Where-Object { $null -ne $_.Date -and $_.Date -ge $From -and $_.Date -lt $To })
    return [pscustomobject]@{ Tasks = $t; Events = $e }
}

function Get-WindowStats {
    param($Window)
    $tasks = @($Window.Tasks)
    $withCorr = @($tasks | Where-Object { $_.HasCorrections })
    $withImpl = @($tasks | Where-Object { $_.HasImpl })
    $withSkills = @($tasks | Where-Object { $_.HasRealSkill })

    $totalCorr = 0
    foreach ($t in $withCorr) { $totalCorr += $t.Corrections }
    $totalImpl = 0
    foreach ($t in $withImpl) { $totalImpl += $t.ImplCorrections }

    $avgCorr = if ($withCorr.Count -gt 0) { [math]::Round($totalCorr / $withCorr.Count, 2) } else { 0 }
    $avgImpl = if ($withImpl.Count -gt 0) { [math]::Round($totalImpl / $withImpl.Count, 2) } else { 0 }
    $skillRate = if ($tasks.Count -gt 0) { [math]::Round($withSkills.Count * 100.0 / $tasks.Count, 1) } else { $null }

    $scans = 0
    $blocked = 0
    $commits = 0
    $bypass = 0
    $orderAudits = 0
    $assocSkip = 0
    $assocIgnored = 0
    foreach ($e in $Window.Events) {
        if ($e.Event -eq 'scan') {
            $scans++
            if ($e.Blocked -eq '1') { $blocked++ }
        } elseif ($e.Event -eq 'commit') {
            $commits++
            # scanned=0 means no passing scan preceded this commit (e.g. --no-verify);
            # missing field is unknown, not a bypass
            if ($e.Scanned -eq '0') { $bypass++ }
        } elseif ($e.Event -eq 'summary_order') {
            # post-commit found a commit that bundled a new summary with code
            # (usually via --amend); it cannot un-commit, so it reports here.
            $orderAudits++
        } elseif ($e.Event -eq 'assoc_skip') {
            # Source commits that could not be tied to a change record. "ignored"
            # means .harness/changes is in .gitignore, i.e. the gate is off by
            # accident; "not-committed" is the legal first-adoption case.
            $assocSkip++
            if ($e.Reason -eq 'ignored') { $assocIgnored++ }
        }
    }
    $bypassRate = if ($commits -gt 0) { [math]::Round($bypass * 100.0 / $commits, 1) } else { $null }

    return [pscustomobject]@{
        Tasks = $tasks
        WithCorr = $withCorr
        WithImpl = $withImpl
        WithSkills = $withSkills
        TotalCorr = $totalCorr
        TotalImpl = $totalImpl
        AvgCorr = $avgCorr
        AvgImpl = $avgImpl
        SkillRate = $skillRate
        Scans = $scans
        Commits = $commits
        Blocked = $blocked
        Bypass = $bypass
        BypassRate = $bypassRate
        OrderAudits = $orderAudits
        AssocSkip = $assocSkip
        AssocIgnored = $assocIgnored
    }
}

# ---------------------------------------------------------------------- windows
# The current window is N calendar days INCLUDING today: [today-(N-1), today+1).
# Using -N with today+1 made the window N+1 days while the previous one stayed N,
# so -Days 1 compared 2 days against 1.
$cutoff = if ($Days -gt 0) { (Get-Date).Date.AddDays(-($Days - 1)) } else { $null }
$now = (Get-Date).Date.AddDays(1)   # "today" belongs to the current window
$allTasks = @(Get-SummaryTasks) + @(Get-SmallTasks)
$allEvents = @(Get-GateEvents)

$curWindow = if ($Days -gt 0) {
    Select-Window -Tasks $allTasks -Events $allEvents -From $cutoff -To $now
} else {
    [pscustomobject]@{ Tasks = $allTasks; Events = $allEvents }
}
$stats = Get-WindowStats -Window $curWindow

# -Compare needs a previous window of the same length, so it needs -Days N.
$prevStats = $null
$trendVerdict = $null
if ($Compare) {
    if ($Days -le 0) {
        $trendVerdict = 'compare needs -Days N (N > 0): there is no previous window with -Days 0'
    } else {
        $prevFrom = $cutoff.AddDays(-$Days)
        $prevWindow = Select-Window -Tasks $allTasks -Events $allEvents -From $prevFrom -To $cutoff
        $prevStats = Get-WindowStats -Window $prevWindow
    }
}

$undatedTasks = @($stats.Tasks | Where-Object { -not $_.Dated } | ForEach-Object { $_.Feature })
# Windowed events are already date-filtered, so count the unparsable ones from
# the full history; they belong to no window and are reported, never dropped.
$undatedEvents = @($allEvents | Where-Object { $null -eq $_.Date }).Count

# ------------------------------------------------------------------ aggregate
$tasks = @($stats.Tasks)
$withCorr = @($stats.WithCorr)
$totalCorr = $stats.TotalCorr
$avgCorr = $stats.AvgCorr
$totalImpl = $stats.TotalImpl
$avgImpl = $stats.AvgImpl

$skillCounts = @{}
foreach ($t in $tasks) {
    foreach ($s in $t.Skills) {
        $key = Get-SkillKey $s
        if (-not $key) { continue }
        if (-not $skillCounts.ContainsKey($key)) { $skillCounts[$key] = 0 }
        $skillCounts[$key] = $skillCounts[$key] + 1
    }
}

# -------------------------------------------------------------- productivity
# See the header: every number below is a documented proxy, and a task with no
# usable evidence is unknown / n/a instead of being counted as a success.
$prodWindows = @()
$evtList = @($curWindow.Events)
$claimedIdx = New-Object 'bool[]' ([Math]::Max(1, $evtList.Count))
$seq = 0
foreach ($t in $tasks) {
    $seq++
    $git = Get-TaskGitRange -Root $rootPath -Feature $t.Feature
    $from = $null
    $to = $null
    $anchor = 'none'
    if ($git.Count -gt 0) {
        # A blocked attempt writes no commit, so the first commit is the end of
        # the task, not its start: look one day back to claim the blocked scans.
        $from = ([System.DateTimeOffset]::FromUnixTimeSeconds($git.First)).LocalDateTime.AddDays(-1)
        $to = ([System.DateTimeOffset]::FromUnixTimeSeconds($git.Last)).LocalDateTime.AddSeconds(1)
        if ($git.Count -le 1) {
            # With only the summary commit, blocked scans after it fall outside
            # the old window. Extend one day so same-day retries are counted.
            $to = ([System.DateTimeOffset]::FromUnixTimeSeconds($git.Last)).LocalDateTime.AddDays(1)
        }
        $anchor = 'git-record'
    } elseif ($t.Dated) {
        $from = $t.Date
        $to = $t.Date.AddDays(1)
        $anchor = 'summary-date'
    }
    $prodWindows += [pscustomobject]@{
        Task = $t
        From = $from
        To = $to
        Anchor = $anchor
        Git = $git
        Order = $seq
        Events = @()
        Scans = 0
        Blocked = $null
        FirstPass = $null
        LeadDays = $null
    }
}

# An event belongs to at most one task: the earliest window in start order wins.
# Concurrent features share gate.jsonl with no key, so a collision would double
# count; the loser stays unknown instead of inflating its first-pass credit.
$byStart = @($prodWindows | Sort-Object @{Expression = { if ($null -ne $_.From) { $_.From } else { [datetime]::MaxValue } }}, @{Expression = { $_.Order }})
foreach ($w in $byStart) {
    if ($null -eq $w.From) { continue }
    for ($i = 0; $i -lt $evtList.Count; $i++) {
        if ($claimedIdx[$i]) { continue }
        $e = $evtList[$i]
        if ($null -eq $e.Ts) { continue }
        if ($e.Ts -lt $w.From -or $e.Ts -ge $w.To) { continue }
        $claimedIdx[$i] = $true
        $w.Events = @($w.Events) + $e
    }
}
foreach ($w in $prodWindows) {
    $scans = @($w.Events | Where-Object { $_.Event -eq 'scan' })
    $w.Scans = $scans.Count
    if ($scans.Count -gt 0) {
        $b = @($scans | Where-Object { $_.Blocked -eq '1' }).Count
        $w.Blocked = $b
        $w.FirstPass = ($b -eq 0)
    }
    if ($w.Git.Count -gt 0 -and $w.Task.Dated) {
        $lastCommit = ([System.DateTimeOffset]::FromUnixTimeSeconds($w.Git.Last)).LocalDateTime
        $w.LeadDays = [math]::Max(0, [math]::Round(($lastCommit - $w.Task.Date).TotalDays, 2))
    }
}

$fpMeasured = @($prodWindows | Where-Object { $null -ne $_.FirstPass })
$fpPassed = @($fpMeasured | Where-Object { $_.FirstPass })
$fpRate = if ($fpMeasured.Count -gt 0) { [math]::Round($fpPassed.Count * 100.0 / $fpMeasured.Count, 1) } else { $null }

$rtMeasured = $fpMeasured
$rtSum = 0
foreach ($w in $rtMeasured) { $rtSum += $w.Blocked }
$rtAvg = if ($rtMeasured.Count -gt 0) { [math]::Round($rtSum / $rtMeasured.Count, 2) } else { $null }
$rtZero = @($rtMeasured | Where-Object { $_.Blocked -eq 0 }).Count
$rtOne = @($rtMeasured | Where-Object { $_.Blocked -eq 1 }).Count
$rtTwo = @($rtMeasured | Where-Object { $_.Blocked -ge 2 }).Count
$rtUnknown = $prodWindows.Count - $rtMeasured.Count

$leadMeasured = @($prodWindows | Where-Object { $null -ne $_.LeadDays })
$leadAvg = if ($leadMeasured.Count -gt 0) {
    [math]::Round((@($leadMeasured | Measure-Object -Property LeadDays -Sum)[0].Sum) / $leadMeasured.Count, 2)
} else { $null }
$leadUnknown = $prodWindows.Count - $leadMeasured.Count

# Reuse: one pair per skill, first task vs the next task that loaded it. A pair
# counts as improved when corrections or round trips went down; it is unknown
# when neither dimension was recorded on both sides.
$skillTaskMap = @{}
foreach ($w in $prodWindows) {
    foreach ($s in @($w.Task.Skills)) {
        $k = Get-SkillKey $s
        if (-not $k) { continue }
        if (-not $skillTaskMap.ContainsKey($k)) { $skillTaskMap[$k] = @() }
        $skillTaskMap[$k] = @($skillTaskMap[$k]) + $w
    }
}
$reusePairs = @()
$reuseMeasured = 0
$reuseImproved = 0
$reuseUnknown = 0
$singleTaskSkills = @()
foreach ($k in ($skillTaskMap.Keys | Sort-Object)) {
    $list = @($skillTaskMap[$k] | Sort-Object @{Expression = { if ($_.Task.Dated) { $_.Task.Date } else { [datetime]::MaxValue } }}, @{Expression = { $_.Task.Feature }})
    if ($list.Count -lt 2) { $singleTaskSkills += $k; continue }
    $a = $list[0]
    $b = $list[1]
    $signals = @()
    if ($a.Task.HasCorrections -and $b.Task.HasCorrections) { $signals += ($b.Task.Corrections -lt $a.Task.Corrections) }
    if ($null -ne $a.Blocked -and $null -ne $b.Blocked) { $signals += ($b.Blocked -lt $a.Blocked) }
    $state = 'unknown'
    if ($signals.Count -gt 0) {
        $reuseMeasured++
        if ($signals -contains $true) { $state = 'improved'; $reuseImproved++ } else { $state = 'not-improved' }
    } else {
        $reuseUnknown++
    }
    $reusePairs += [pscustomobject]@{
        skill = $k
        first = $a.Task.Feature
        second = $b.Task.Feature
        firstCorrections = $(if ($a.Task.HasCorrections) { $a.Task.Corrections } else { $null })
        secondCorrections = $(if ($b.Task.HasCorrections) { $b.Task.Corrections } else { $null })
        firstBlocked = $a.Blocked
        secondBlocked = $b.Blocked
        state = $state
    }
}
$reuseRate = if ($reuseMeasured -gt 0) { [math]::Round($reuseImproved * 100.0 / $reuseMeasured, 1) } else { $null }

# Console text helpers: a null metric must print as n/a, never as 0.
function Format-MetricText {
    param($Value, [string]$Suffix)
    if ($null -eq $Value) { return 'n/a' }
    return ([string]$Value + $Suffix)
}

# Lesson promotion is cumulative across sessions: count all summaries and small
# records, not only the current -Days window. The generated table is the lookup
# aid the model uses before writing a new lesson_id.
$lessonCounts = @{}
$lessonFirst = @{}
$lessonLast = @{}
$lessonNotes = @{}
$lessonNoteDate = @{}
foreach ($t in $allTasks) {
    foreach ($id in @($t.Lessons)) {
        if (-not $lessonCounts.ContainsKey($id)) {
            $lessonCounts[$id] = 0
            $lessonFirst[$id] = $null
            $lessonLast[$id] = $null
            $lessonNotes[$id] = ''
        }
        $lessonCounts[$id] = $lessonCounts[$id] + 1
        if ($null -ne $t.Date) {
            if ($null -eq $lessonFirst[$id] -or $t.Date -lt $lessonFirst[$id]) { $lessonFirst[$id] = $t.Date }
            if ($null -eq $lessonLast[$id] -or $t.Date -gt $lessonLast[$id]) { $lessonLast[$id] = $t.Date }
        }
        if ($t.LessonNotes -and $t.LessonNotes.ContainsKey($id) -and $t.LessonNotes[$id]) {
            $newer = ($null -eq $lessonNoteDate[$id]) -or ($null -ne $t.Date -and $t.Date -gt $lessonNoteDate[$id])
            if (-not $lessonNotes[$id] -or $newer) {
                $lessonNotes[$id] = $t.LessonNotes[$id]
                $lessonNoteDate[$id] = $t.Date
            }
        }
    }
}

# lessons already promoted stop nagging (but keep being counted).
# Two line shapes are accepted:
#   lesson-id
#   lesson-id :: check=<path relative to the project root>::<what the check proves>
# Only the second turns a lesson into something that can fail again; -LessonGate
# refuses the first for any lesson that repeated.
$promoted = @()
$promotedChecks = @{}
if (Test-Path -LiteralPath $promotedPath) {
    foreach ($raw in (Get-Content -LiteralPath $promotedPath -Encoding UTF8)) {
        $line = $raw.Trim()
        if (-not $line -or $line.StartsWith('#')) { continue }
        $id = $line
        $checkPath = ''
        $checkLabel = ''
        $m = [regex]::Match($line, '^([A-Za-z0-9][A-Za-z0-9_.\-]*)\s*::\s*check=(.+?)::(.*)$')
        if ($m.Success) {
            $id = $m.Groups[1].Value
            $checkPath = $m.Groups[2].Value.Trim()
            $checkLabel = $m.Groups[3].Value.Trim()
        }
        if ($promoted -notcontains $id) { $promoted += $id }
        $promotedChecks[$id] = [pscustomobject]@{ Path = $checkPath; Label = $checkLabel }
    }
}

# -LessonGate: the only mechanically enforceable part of "persist on the second
# occurrence". A repeated lesson whose promotion has no check path is still just
# a note -- it will be forgotten again.
if ($LessonGate) {
    $bad = @()
    foreach ($k in ($lessonCounts.Keys | Sort-Object)) {
        if ($lessonCounts[$k] -lt 2) { continue }
        $c = $promotedChecks[$k]
        if (-not $c) {
            $bad += "$k repeated $($lessonCounts[$k])x and is not promoted"
        } elseif (-not $c.Path) {
            $bad += "$k is promoted without a check (add ':: check=<file>::<label>')"
        } elseif ($c.Path -match '\.\.' -or $c.Path -match '^[A-Za-z]:') {
            $bad += "$k check path escapes the project root: $($c.Path)"
        } elseif ($c.Path -notmatch '\.(ps1|py)$') {
            # A doc or a directory proves nothing: the check has to be something
            # that can fail. Gate and test scripts are the only executable forms.
            $bad += "$k check must be a .ps1/.py check, not '$($c.Path)'"
        } else {
            $full = Join-Path $rootPath ($c.Path -replace '/', '\')
            if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
                $bad += "$k points at a missing check file: $($c.Path)"
            } else {
                # Existence is not relevance. Requiring the id inside the check
                # file turns "this test covers that lesson" into something a
                # reader (human or reviewer agent) can audit, and a mis-wired
                # path fails instead of silently pointing at an unrelated script.
                $checkText = [System.IO.File]::ReadAllText($full, [System.Text.Encoding]::UTF8)
                if ($checkText -notmatch [regex]::Escape($k)) {
                    $bad += "$k check file does not mention the lesson id: $($c.Path) (add the id as a comment, e.g. '# lesson: $k')"
                } elseif ($checkText -notmatch '(?m)^\s*#\s*fails-when:\s*\S') {
                    # Naming the mutation is the cheapest auditable claim: the
                    # reviewer can reproduce it instead of trusting a comment.
                    $bad += "$k check file does not declare when it fails (add '# fails-when: <what makes this check red>')"
                }
            }
        }
    }
    if ($Json) {
        $payload = [ordered]@{ lessonGateOk = ($bad.Count -eq 0); violations = @($bad) }
        Write-Output ($payload | ConvertTo-Json -Depth 4)
    } else {
        foreach ($b in $bad) { Write-Host ("[FAIL] lesson gate: " + $b) -ForegroundColor Red }
        if ($bad.Count -gt 0) {
            Write-Host 'A repeated lesson must become a check that can fail; see .harness/lessons-promoted.txt' -ForegroundColor Yellow
        } else {
            Write-Host 'lesson gate: every repeated lesson has a registered check' -ForegroundColor Green
        }
    }
    if ($bad.Count -gt 0) { Complete-Harness 1 }
    Complete-Harness 0
}

# Write the lessons lookup table. The script stays pure ASCII; the note values
# may be Chinese and are written with UTF-8 without BOM. The index is tracked
# (.harness/lessons.md), not hidden under the gitignored metrics directory: a
# team must be able to share the lesson ids across clones.
$lessonsPath = Join-Path $rootPath '.harness\lessons.md'
$lessonsDir = Split-Path -Parent $lessonsPath
if (-not (Test-Path -LiteralPath $lessonsDir)) {
    New-Item -ItemType Directory -Force -Path $lessonsDir | Out-Null
}
$lessonRows = @()
foreach ($id in $lessonCounts.Keys) {
    $status = if ($promoted -contains $id) { 'promoted' } elseif ($lessonCounts[$id] -ge 2) { 'promote' } else { 'watch' }
    $first = if ($null -ne $lessonFirst[$id]) { $lessonFirst[$id].ToString('yyyy-MM-dd') } else { '-' }
    $last = if ($null -ne $lessonLast[$id]) { $lessonLast[$id].ToString('yyyy-MM-dd') } else { '-' }
    $note = if ($lessonNotes[$id]) { $lessonNotes[$id] -replace '\|', '/' } else { '-' }
    $lessonRows += [pscustomobject]@{
        Id = $id
        Note = $note
        Count = $lessonCounts[$id]
        First = $first
        Last = $last
        Status = $status
    }
}
$lessonRows = @($lessonRows | Sort-Object @{Expression = { $_.Count }; Descending = $true }, @{Expression = { $_.Id }; Descending = $false })
$lessonLines = @(
    '# Lessons index (generated by metrics.ps1)',
    '',
    '> Count = number of summaries + _small.md rows, not the number of corrections.',
    '> Reuse the id when the same pit appears; write the one-line note after -- in lesson_id.',
    '',
    '| id | summary | tasks | first | last | status |',
    '| --- | --- | --- | --- | --- | --- |'
)
foreach ($row in $lessonRows) {
    $lessonLines += ('| {0} | {1} | {2} | {3} | {4} | {5} |' -f $row.Id, $row.Note, $row.Count, $row.First, $row.Last, $row.Status)
}
try {
    [System.IO.File]::WriteAllText($lessonsPath, (($lessonLines -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
} catch {
    Write-Host ("[WARN] could not write lessons index {0}: {1}" -f $lessonsPath, $_.Exception.Message) -ForegroundColor Yellow
}

# Review findings are cumulative across sessions, like lessons: the fingerprint
# is how a repeated finding is recognised. -LessonGate returns before this, so
# the gate path stays side-effect free.
$reviewStatuses = @(Get-ReviewCfgList 'openStatuses')
$reviewTotals = [ordered]@{ P0 = 0; P1 = 0; P2 = 0 }
$reviewMap = @{}
foreach ($t in $allTasks) {
    $seen = @{}
    foreach ($r in @($t.ReviewRows)) {
        if ($reviewTotals.Contains($r.Severity)) { $reviewTotals[$r.Severity] = $reviewTotals[$r.Severity] + 1 }
        $fp = $r.Fingerprint
        if (-not $fp -or $fp -eq '-') { continue }
        if ($seen.ContainsKey($fp)) { continue }
        $seen[$fp] = $true
        if (-not $reviewMap.ContainsKey($fp)) {
            $reviewMap[$fp] = [pscustomobject]@{
                Fingerprint = $fp
                Severity = $r.Severity
                Tasks = 0
                First = $null
                Last = $null
                Open = $false
                Example = $r.Problem
                ExampleDate = $null
            }
        }
        $e = $reviewMap[$fp]
        $e.Tasks = $e.Tasks + 1
        if ($reviewStatuses -contains $r.Status) { $e.Open = $true }
        if ($r.Severity -eq 'P0') { $e.Severity = 'P0' }
        elseif ($r.Severity -eq 'P1' -and $e.Severity -ne 'P0') { $e.Severity = 'P1' }
        elseif ($r.Severity -eq 'P2' -and -not $e.Severity) { $e.Severity = 'P2' }
        if ($null -ne $t.Date) {
            if ($null -eq $e.First -or $t.Date -lt $e.First) { $e.First = $t.Date }
            if ($null -eq $e.Last -or $t.Date -gt $e.Last) { $e.Last = $t.Date }
        }
        if ($r.Problem -and ($null -eq $e.ExampleDate -or ($null -ne $t.Date -and $t.Date -ge $e.ExampleDate))) {
            $e.Example = $r.Problem
            $e.ExampleDate = $t.Date
        }
    }
}

$reviewRows = @()
foreach ($fp in $reviewMap.Keys) {
    $e = $reviewMap[$fp]
    $status = if ($e.Tasks -ge 2) { 'promote' } elseif ($e.Open) { 'open' } else { 'watch' }
    $first = if ($null -ne $e.First) { $e.First.ToString('yyyy-MM-dd') } else { '-' }
    $last = if ($null -ne $e.Last) { $e.Last.ToString('yyyy-MM-dd') } else { '-' }
    $example = if ($e.Example) { $e.Example -replace '\|', '/' } else { '-' }
    $reviewRows += [pscustomobject]@{
        Fingerprint = $fp
        Severity = $e.Severity
        Status = $status
        Tasks = $e.Tasks
        First = $first
        Last = $last
        Example = $example
    }
}
$reviewRows = @($reviewRows | Sort-Object @{Expression = { $_.Tasks }; Descending = $true }, @{Expression = { $_.Fingerprint }; Descending = $false })

# The index is tracked (.harness/reviews.md) so a team shares one fingerprint
# vocabulary; writing it is best-effort and must never block the report.
$reviewsPath = Join-Path $rootPath '.harness\reviews.md'
$reviewLines = @(
    '# Review findings index (generated by metrics.ps1)',
    '',
    '> Reuse the fingerprint when the same finding appears again; status=promote means it appeared in >= 2 tasks.',
    '',
    '| fingerprint | severity | status | tasks | first | last | example |',
    '| --- | --- | --- | --- | --- | --- | --- |'
)
if ($reviewRows.Count -eq 0) {
    $reviewLines += '| - | - | - | 0 | - | - | no review findings recorded yet |'
}
foreach ($row in $reviewRows) {
    $reviewLines += ('| {0} | {1} | {2} | {3} | {4} | {5} | {6} |' -f $row.Fingerprint, $row.Severity, $row.Status, $row.Tasks, $row.First, $row.Last, $row.Example)
}
try {
    [System.IO.File]::WriteAllText($reviewsPath, (($reviewLines -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
} catch {
    Write-Host ("[WARN] could not write review index {0}: {1}" -f $reviewsPath, $_.Exception.Message) -ForegroundColor Yellow
}
$reviewRecurring = @($reviewRows | Where-Object { $_.Tasks -ge 2 })

# installed skills (for the "never loaded" signal that drives retirement)
# Keep the age with each skill: the retirement verdict needs both the
# observation window and the age of the skill itself.
$installed = @()
if (Test-Path -LiteralPath $skillsRoot) {
    Get-ChildItem -LiteralPath $skillsRoot -Directory -Force | ForEach-Object {
        $category = $_.Name
        Get-ChildItem -LiteralPath $_.FullName -Directory -Force | ForEach-Object {
            $skillDir = $_.FullName
            if (Test-Path -LiteralPath (Join-Path $skillDir 'SKILL.md')) {
                $installed += Get-SkillInfo -Root $rootPath -Category $category -Name $_.Name -Dir $skillDir
            }
        }
    }
}

$skillRate = $stats.SkillRate
# Same normalized name in two categories would be merged into one count; flag it
# instead of silently making one skill vouch for the other.
$duplicateSkillNames = @($installed | Group-Object Name | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
# A skill directory that was never listed in .harness/skills/README.md was never
# reachable from the platform index either, so zero loads means "not wired up",
# not "unused". Diagnose it separately instead of offering it for retirement.
$skillIndexText = ''
$skillIndexPath = Join-Path $skillsRoot 'README.md'
if (Test-Path -LiteralPath $skillIndexPath) {
    $skillIndexText = [System.IO.File]::ReadAllText($skillIndexPath, [System.Text.Encoding]::UTF8)
}
$unregistered = @()
foreach ($skill in $installed) {
    $hit = $false
    if ($skillIndexText) {
        $probe = '(?i)(?<![A-Za-z0-9_-])' + [regex]::Escape($skill.Name) + '(?![A-Za-z0-9_-])'
        $hit = ($skillIndexText -match $probe)
    }
    if (-not $hit) { $unregistered += $skill.Name }
}
# Report each field separately: "7 files missing all three fields" is false when
# the real gap is only impl_corrections, and it sends the reader to the wrong fix.
$missingCorr = @($tasks | Where-Object { -not $_.HasCorrections }).Count
$missingImpl = @($tasks | Where-Object { -not $_.HasImpl }).Count
$missingSkills = @($tasks | Where-Object { -not $_.HasSkills }).Count

# ------------------------------------------------------------------- trend
# A6 has two halves: task-level (impl_corrections must be 0) and project-level
# (is the trend going down?). A single good task cannot prove the harness works.
if ($Compare -and $null -ne $prevStats) {
    $enough = ($stats.Tasks.Count -ge 2 -and $prevStats.Tasks.Count -ge 2)
    if (-not $enough) {
        $trendVerdict = 'INSUFFICIENT DATA (need >= 2 tasks in each window)'
    } else {
        $curCorr = $stats.AvgCorr
        $prevCorr = $prevStats.AvgCorr
        $regress = $false
        $improve = $false

        # human corrections: 20% or more is treated as a real move, not noise
        if ($prevCorr -gt 0) {
            if ($curCorr -le ($prevCorr * 0.8)) { $improve = $true }
            if ($curCorr -ge ($prevCorr * 1.2)) { $regress = $true }
        } elseif ($curCorr -gt 0) {
            $regress = $true
        }

        # implementation-level corrections must not appear at all
        if ($stats.AvgImpl -gt $prevStats.AvgImpl) { $regress = $true }

        # loading the right skill must not get worse while corrections drop
        if ($null -ne $stats.SkillRate -and $null -ne $prevStats.SkillRate) {
            if ($stats.SkillRate -lt $prevStats.SkillRate) { $improve = $false }
        }

        # a rising bypass rate means the gate is being routed around
        if ($null -ne $stats.BypassRate -and $stats.BypassRate -gt 10) { $regress = $true }

        if ($improve -and -not $regress) { $trendVerdict = 'IMPROVING' }
        elseif ($regress) { $trendVerdict = 'REGRESSING' }
        else { $trendVerdict = 'FLAT' }
    }
}

# ------------------------------------------------------------------- verdict
$verdict = @()
foreach ($u in $unregistered) {
    $verdict += "skill not registered: $u (missing from .harness/skills/README.md; add it and run setup-links -- zero loads here is not a retirement signal)"
}
if ($Days -gt 0) {
    $verdict += "window: last $Days day(s), since $($cutoff.ToString('yyyy-MM-dd'))"
    if ($undatedTasks.Count -gt 0) {
        $verdict += "$($undatedTasks.Count) task(s) had no date line (mtime used): $($undatedTasks -join ', ')"
    }
}
if ($tasks.Count -eq 0) {
    $verdict += 'no task summary yet: record at least one real task before judging A7'
} else {
    $fieldParts = @()
    if ($missingCorr -gt 0) { $fieldParts += "$missingCorr missing corrections" }
    if ($missingImpl -gt 0) { $fieldParts += "$missingImpl missing impl_corrections" }
    if ($missingSkills -gt 0) { $fieldParts += "$missingSkills missing loaded_skills" }
    if ($fieldParts.Count -gt 0) {
        $verdict += "$($tasks.Count) summary file(s) checked; $($fieldParts -join '; ')"
    }
    if ($duplicateSkillNames.Count -gt 0) {
        $verdict += "duplicate skill name(s) across categories: $($duplicateSkillNames -join ', ') (loaded and never-loaded counts may be merged)"
    }
    if ($avgCorr -gt 2) {
        $verdict += "avg corrections per task = $avgCorr (target <= 2): harness is not carrying enough weight"
    } else {
        $verdict += "avg corrections per task = $avgCorr (within budget)"
    }
    if ($stats.WithImpl.Count -eq 0) {
        $verdict += "impl_corrections not recorded in any summary: A6 cannot be judged (fill the field)"
    } elseif ($avgImpl -gt 0) {
        $verdict += "avg implementation-level corrections per task = $avgImpl (target 0): the gate is not absorbing the mechanical mistakes"
    } else {
        $verdict += "avg implementation-level corrections per task = 0 (target met)"
    }
    # A6 is judged per task as well: an average can look healthy while a single
    # task needed many corrections. List the offenders instead of hiding them.
    $overBudget = @($tasks | Where-Object {
        ($_.HasCorrections -and $_.Corrections -gt 2) -or ($_.HasImpl -and $_.ImplCorrections -gt 0)
    })
    if ($overBudget.Count -gt 0) {
        $names = @($overBudget | ForEach-Object { $_.Feature }) -join ', '
        $verdict += "$($overBudget.Count) task(s) over the A6 budget (corrections > 2 or impl_corrections > 0): $names"
    }
    if ($skillRate -ne $null -and $skillRate -lt 50 -and $tasks.Count -ge 5) {
        $verdict += "skill load rate = $skillRate% (self-reported, < 50%): skills are probably not triggering"
    }
    if ($tasks.Count -ge 5) {
        # The skill must have existed for the whole observation window; otherwise
        # "-Days 90" would call a 30-day-old skill "never loaded in 90 days".
        $requiredAge = if ($Days -gt 0) { [Math]::Max($SkillMinAgeDays, $Days) } else { $SkillMinAgeDays }
        foreach ($skill in $installed) {
            if ($skillCounts.ContainsKey($skill.Name)) { continue }
            if ($unregistered -contains $skill.Name) { continue }
            if ($Days -lt 28) {
                $verdict += "skill never loaded in this window: $($skill.Name) (extend -Days to 28 or more before judging retirement)"
            } elseif ($null -eq $skill.AgeDays) {
                $verdict += "skill never loaded in this window: $($skill.Name) (age unknown; confirm the creation date before retiring)"
            } elseif ($skill.AgeDays -lt $requiredAge) {
                $verdict += "skill never loaded in this window: $($skill.Name) (added $($skill.AgeDays) day(s) ago; wait until it is $requiredAge day(s) old)"
            } else {
                $verdict += "skill never loaded in last $Days day(s): $($skill.Name) (retire candidate -- confirm with a human before deleting)"
            }
        }
    }
    foreach ($k in ($lessonCounts.Keys | Sort-Object)) {
        if ($lessonCounts[$k] -ge 2 -and $promoted -notcontains $k) {
            $verdict += "lesson repeated $($lessonCounts[$k])x: $k (promote it into a rule, a gate or a skill)"
        }
    }
    # The two-week review also has to say which skills have drifted from the code.
    # verify-grounding already computes that (anchor file newer than "- verified:"),
    # so reuse its verdict instead of maintaining a second mtime comparison.
    $vgPath = Join-Path $rootPath 'scripts\verify-grounding.ps1'
    if (-not $Quiet -and (Test-Path -LiteralPath $vgPath)) {
        try {
            $psHost = if (Get-Command powershell -ErrorAction SilentlyContinue) { 'powershell' } else { 'pwsh' }
            $vgOut = & $psHost -NoProfile -ExecutionPolicy Bypass -File $vgPath -Root $rootPath 2>&1
            foreach ($line in @($vgOut)) {
                if ($line -match '\[(WARN|FAIL)\]\s+stale\s+(.+)$') {
                    $verdict += ('stale skill (' + $matches[1].ToLower() + '): ' + $matches[2])
                }
            }
        } catch { }
    }
}
# Bad small rows are reported even when the window has no valid task; otherwise
# a typo in _small.md would look like "no tasks" with no explanation.
if ($smallBad -gt 0) {
    $verdict += "$smallBad small-record row(s) malformed; fix .harness/changes/_small.md"
}
if ($Compare) { $verdict += "trend: $trendVerdict" }

# gate health is reported even when no task summary exists yet
if (-not (Test-Path -LiteralPath $logPath)) {
    $verdict += 'gate log missing: install-git-hooks was not run, or no commit happened yet'
} elseif ($stats.Commits -eq 0) {
    $verdict += "$($stats.Scans) scan event(s), no commit event yet (post-commit not installed or no commit)"
} else {
    $verdict += "$($stats.Commits) commit(s), $($stats.Scans) scan(s), $($stats.Blocked) blocked"
    if ($null -ne $stats.BypassRate -and $stats.BypassRate -gt 10) {
        $verdict += "bypass rate = $($stats.BypassRate)% (> 10%): the gate is being skipped, fix the friction or the rules"
    } else {
        $verdict += "bypass rate = $($stats.BypassRate)% (ok)"
    }
    if ($stats.OrderAudits -gt 0) {
        $verdict += "$($stats.OrderAudits) summary-order audit event(s): a commit bundled a new summary with code (usually amended); split it before the next release"
    }
}
# Attribution skips are reported even when no commit event was parsed: a project
# whose hook never ran still has source commits that no record covers.
if ($stats.AssocIgnored -gt 0) {
    $verdict += "$($stats.AssocIgnored) source commit(s) skipped attribution because .harness/changes is ignored: the gate is off by accident; remove the ignore rule or set recordsTracked=false"
} elseif ($stats.AssocSkip -gt 0) {
    $verdict += "$($stats.AssocSkip) source commit(s) were not attributed (no pointer / record not committed yet); pass -Feature or add a Harness-Task trailer"
}

if ($Json) {
    $out = [pscustomobject]@{
        tasks = $tasks.Count
        tasksWithFields = $withCorr.Count
        totalCorrections = $totalCorr
        avgCorrections = $avgCorr
        totalImplCorrections = $totalImpl
        avgImplCorrections = $avgImpl
        scans = $stats.Scans
        commits = $stats.Commits
        blockedCommits = $stats.Blocked
        bypassCommits = $stats.Bypass
        bypassRate = $stats.BypassRate
        summaryOrderAudits = $stats.OrderAudits
        attributionSkipped = $stats.AssocSkip
        attributionSkippedIgnored = $stats.AssocIgnored
        skillLoadRate = $skillRate
        firstPassRate = $fpRate
        gateRoundTrips = [pscustomobject]@{
            average = $rtAvg
            zero = $rtZero
            one = $rtOne
            twoPlus = $rtTwo
            measured = $rtMeasured.Count
            unknown = $rtUnknown
        }
        leadTime = [pscustomobject]@{
            averageDays = $leadAvg
            measured = $leadMeasured.Count
            unknown = $leadUnknown
            source = 'last-commit-of-record-dir'
        }
        reuseRate = [pscustomobject]@{
            rate = $reuseRate
            pairs = $reuseMeasured
            improved = $reuseImproved
            unknown = $reuseUnknown
            singleTaskSkills = @($singleTaskSkills)
        }
        reusePairs = @($reusePairs)
        productivityTasks = @($prodWindows | ForEach-Object {
            [pscustomobject]@{
                feature = $_.Task.Feature
                anchor = $_.Anchor
                scans = $_.Scans
                blocked = $_.Blocked
                firstPass = $_.FirstPass
                leadDays = $_.LeadDays
            }
        })
        skills = $skillCounts
        skillAges = @($installed | ForEach-Object {
            [pscustomobject]@{ name = $_.Name; ageDays = $_.AgeDays; source = $_.AgeSource }
        })
        lessons = $lessonCounts
        promoted = $promoted
        lessonIndex = $lessonsPath
        reviewTotals = $reviewTotals
        reviewRecurring = @($reviewRecurring | ForEach-Object {
            [pscustomobject]@{ fingerprint = $_.Fingerprint; severity = $_.Severity; status = $_.Status; tasks = $_.Tasks }
        })
        reviewIndex = $reviewsPath
        smallRecordErrors = $smallBad
        days = $Days
        cutoff = $(if ($Days -gt 0) { $cutoff.ToString('yyyy-MM-dd') } else { $null })
        undatedTasks = @($undatedTasks)
        undatedGateEvents = $undatedEvents
        trend = $(if ($Compare) {
            [pscustomobject]@{
                verdict = $trendVerdict
                current = $(if ($null -ne $prevStats) {
                    [pscustomobject]@{ tasks = $tasks.Count; avgCorrections = $stats.AvgCorr; avgImplCorrections = $stats.AvgImpl; skillLoadRate = $stats.SkillRate; blocked = $stats.Blocked; bypassRate = $stats.BypassRate }
                } else { $null })
                previous = $(if ($null -ne $prevStats) {
                    [pscustomobject]@{ tasks = $prevStats.Tasks.Count; avgCorrections = $prevStats.AvgCorr; avgImplCorrections = $prevStats.AvgImpl; skillLoadRate = $prevStats.SkillRate; blocked = $prevStats.Blocked; bypassRate = $prevStats.BypassRate }
                } else { $null })
            }
        } else { $null })
        verdict = $verdict
    }
    $out | ConvertTo-Json -Depth 6
    Complete-Harness 0
}

if (-not $Quiet) {
    Write-Host ""
    Write-Host "harness metrics -- $rootPath" -ForegroundColor Cyan
    Write-Host ("window: {0}" -f $(if ($Days -gt 0) { "last $Days day(s), since $($cutoff.ToString('yyyy-MM-dd'))" } else { 'all history' }))
    if ($Days -gt 0 -and $undatedTasks.Count -gt 0) {
        Write-Host ("undated tasks (date from mtime): {0}" -f ($undatedTasks -join ', ')) -ForegroundColor Yellow
    }
    if ($Days -gt 0 -and $undatedEvents -gt 0) {
        Write-Host ("gate events skipped (no parsable ts): {0}" -f $undatedEvents) -ForegroundColor Yellow
    }
    Write-Host ("-" * 70)
    Write-Host ("tasks: {0}   with fields: {1}   total corrections: {2}   avg: {3}" -f `
        $tasks.Count, $withCorr.Count, $totalCorr, $avgCorr)
    Write-Host ("impl-level corrections: total {0}   avg {1} (target 0)" -f $totalImpl, $avgImpl)
    Write-Host ("scans: {0}   commits: {1}   blocked: {2}   bypass: {3} ({4}%)   summary-order audits: {5}" -f `
        $stats.Scans, $stats.Commits, $stats.Blocked, $stats.Bypass, $(if ($null -eq $stats.BypassRate) { 'n/a' } else { $stats.BypassRate }), $stats.OrderAudits)
    Write-Host ("attribution skipped: {0} (ignored .harness: {1})" -f $stats.AssocSkip, $stats.AssocIgnored)
    # The number comes from summary.md, so it measures what the agent wrote, not
    # what it read. The label says so; otherwise it looks like telemetry.
    Write-Host ("skill load rate (self-reported): {0}%" -f $(if ($null -eq $skillRate) { 'n/a' } else { $skillRate }))
    # Productivity proxies. "unknown" is printed next to every number: a task
    # without gate events or commits must not look like a clean pass.
    Write-Host "productivity:"
    Write-Host ("  first pass rate: {0} ({1}/{2} task(s) with gate events; {3} unknown)" -f `
        (Format-MetricText $fpRate '%'), $fpPassed.Count, $fpMeasured.Count, $rtUnknown)
    Write-Host ("  gate round trips: avg {0} per task (0: {1}   1: {2}   2+: {3}; {4} unknown)" -f `
        (Format-MetricText $rtAvg ''), $rtZero, $rtOne, $rtTwo, $rtUnknown)
    Write-Host ("  lead time: {0} (summary date -> last commit of the record dir; {1} measured, {2} unknown)" -f `
        (Format-MetricText $leadAvg ' day(s)'), $leadMeasured.Count, $leadUnknown)
    Write-Host ("  reuse: {0} ({1}/{2} skill pair(s) improved; {3} unknown; {4} skill(s) seen once -> n/a)" -f `
        (Format-MetricText $reuseRate '%'), $reuseImproved, $reuseMeasured, $reuseUnknown, $singleTaskSkills.Count)
    if ($Compare -and $null -ne $prevStats) {
        $prevRate = if ($null -eq $prevStats.SkillRate) { 'n/a' } else { "$($prevStats.SkillRate)%" }
        Write-Host ("previous window: tasks {0}   avg corrections {1}   avg impl {2}   skill rate {3} (self-reported)   blocked {4}" -f `
            $prevStats.Tasks.Count, $prevStats.AvgCorr, $prevStats.AvgImpl, $prevRate, $prevStats.Blocked)
        Write-Host ("trend: {0}" -f $trendVerdict) -ForegroundColor $(switch ($trendVerdict) { 'IMPROVING' { 'Green' } 'REGRESSING' { 'Red' } default { 'Yellow' } })
    }
    if ($skillCounts.Count -gt 0) {
        Write-Host "skills loaded:"
        foreach ($k in ($skillCounts.Keys | Sort-Object)) {
            Write-Host ("  {0,-24} {1}" -f $k, $skillCounts[$k])
        }
    } else {
        Write-Host "skills loaded: (none recorded)"
    }
    if ($lessonCounts.Count -gt 0) {
        Write-Host "lessons recorded:"
        foreach ($k in ($lessonCounts.Keys | Sort-Object)) {
            $mark = if ($promoted -contains $k) { '  (promoted)' } elseif ($lessonCounts[$k] -ge 2) { '  <- promote' } else { '' }
            Write-Host ("  {0,-32} {1}{2}" -f $k, $lessonCounts[$k], $mark)
        }
    }
    Write-Host ("review findings: P0={0} P1={1} P2={2}" -f $reviewTotals['P0'], $reviewTotals['P1'], $reviewTotals['P2'])
    if ($reviewRecurring.Count -gt 0) {
        Write-Host "recurring review findings (>=2 tasks):"
        foreach ($r in $reviewRecurring) {
            Write-Host ("  {0,-36} {1}  ({2})" -f $r.Fingerprint, $r.Tasks, $r.Status)
        }
    }
    Write-Host ("-" * 70)
    foreach ($v in $verdict) { Write-Host ("  - " + $v) }
    Write-Host ""
}
Complete-Harness 0
