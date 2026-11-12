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

  USAGE
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\metrics.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\metrics.ps1 -Json
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\metrics.ps1 -Days 14
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\metrics.ps1 -Days 28 -SkillMinAgeDays 28
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\metrics.ps1 -Days 14 -Compare

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
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
$rootPath = (Resolve-Path -LiteralPath $Root).Path

$changesRoot = Join-Path $rootPath '.harness\changes'
$logPath = Join-Path $rootPath '.harness\metrics\gate.jsonl'
# Durable team knowledge, not local machine state: keep the promoted list next
# to the lessons index so every clone sees the same "already promoted" status.
$promotedPath = Join-Path $rootPath '.harness\lessons-promoted.txt'
$skillsRoot = Join-Path $rootPath '.harness\skills'
$smallBad = 0

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
            HasCorrections = ($null -ne $corr)
            HasImpl = ($null -ne $impl)
            HasSkills = $true
            HasRealSkill = ($skills.Count -gt 0)
        }
    }
    return $out
}

function Get-GateEvents {
    $out = @()
    if (-not (Test-Path -LiteralPath $logPath)) { return $out }
    foreach ($line in [System.IO.File]::ReadLines($logPath)) {
        if ($line.Trim().Length -eq 0) { continue }
        try { $e = $line | ConvertFrom-Json } catch {
            # A malformed gate line still counts as an un-dateable event so the
            # "skipped" number in the report cannot hide a broken log.
            $out += [pscustomobject]@{ Event = 'invalid'; Date = $null; Blocked = '0'; Scanned = '' }
            continue
        }
        $evtDate = $null
        if ($e.ts) { try { $evtDate = ([datetime]$e.ts).Date } catch { $evtDate = $null } }
        $out += [pscustomobject]@{
            Event = $e.event
            Date = $evtDate
            Blocked = "$($e.blocked)"
            Scanned = "$($e.scanned)"
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

# lessons already promoted stop nagging (but keep being counted)
$promoted = @()
if (Test-Path -LiteralPath $promotedPath) {
    $promoted = @(Get-Content -LiteralPath $promotedPath -Encoding UTF8 |
        ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' -and -not $_.StartsWith('#') })
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
        $verdict += "skill load rate = $skillRate% (< 50%): skills are probably not triggering"
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
        skillLoadRate = $skillRate
        skills = $skillCounts
        skillAges = @($installed | ForEach-Object {
            [pscustomobject]@{ name = $_.Name; ageDays = $_.AgeDays; source = $_.AgeSource }
        })
        lessons = $lessonCounts
        promoted = $promoted
        lessonIndex = $lessonsPath
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
    exit 0
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
    Write-Host ("skill load rate: {0}%" -f $(if ($null -eq $skillRate) { 'n/a' } else { $skillRate }))
    if ($Compare -and $null -ne $prevStats) {
        $prevRate = if ($null -eq $prevStats.SkillRate) { 'n/a' } else { "$($prevStats.SkillRate)%" }
        Write-Host ("previous window: tasks {0}   avg corrections {1}   avg impl {2}   skill rate {3}   blocked {4}" -f `
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
    Write-Host ("-" * 70)
    foreach ($v in $verdict) { Write-Host ("  - " + $v) }
    Write-Host ""
}
exit 0
