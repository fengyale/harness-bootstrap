<#
  harness-plan.ps1 -- one task, one context pack (read only)

  WHY
    "harness plan <requirement>" should hand the agent everything the task needs
    before it starts: which module cards to read, which skills to load, which
    gates will stop it, and which tables / interfaces are in scope. Without it
    the agent guesses, and guesses are exactly what .harness/ exists to replace.

  INPUT
    -Root <dir>              project root (default: current directory)
    -Requirement "<text>"    required; the raw request, in the user's words
    -Feature <name>          optional record name (.harness/changes/<name>/)

  OUTPUT (read only, nothing is written)
    module cards / required skills / expected gates / tables and interfaces /
    a flow-level hint. Anything that cannot be matched is listed as a choice or
    marked "not matched, confirm by hand" -- never invented.

  USAGE
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\harness-plan.ps1 -Requirement "order export"
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\harness-plan.ps1 -Root D:\proj -Requirement "..." -Feature order-export
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\harness-plan.ps1 -SelfTest

  Pure ASCII on purpose: PS 5.1 parses a BOM-less .ps1 as ANSI.
#>
[CmdletBinding()]
param(
    [string]$Root = (Get-Location).Path,
    [string]$Requirement = '',
    [string]$Feature = '',
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'

$CoreSkills = @('request-analysis', 'coding-skill', 'expert-reviewer')
$StopWords = @('the', 'and', 'for', 'with', 'from', 'that', 'this', 'when', 'into', 'use', 'new', 'add', 'all', 'any')
# Generic CJK grams that appear in nearly every description; keeping them turns
# "add an export feature" into a match against half the skill index.
$CnStop = @(
    (-join ([char]0x529F, [char]0x80FD)),   # feature / function
    (-join ([char]0x4F7F, [char]0x7528)),   # use
    (-join ([char]0x9700, [char]0x8981)),   # need
    (-join ([char]0x5B9E, [char]0x73B0)),   # implement
    (-join ([char]0x652F, [char]0x6301)),   # support
    (-join ([char]0x5F00, [char]0x53D1)),   # develop
    (-join ([char]0x6280, [char]0x80FD))    # skill
)

function New-Cn {
    param([int[]]$Codes)
    $s = ''
    foreach ($c in $Codes) { $s += [char]$c }
    return $s
}

function Read-Utf8Text {
    param([string]$PathToFile)
    try { return [System.IO.File]::ReadAllText($PathToFile, [System.Text.Encoding]::UTF8) }
    catch { return '' }
}

# Requirement -> search terms. Latin words plus CJK runs: a full run up to 6
# chars, and every 2-char gram (Chinese has no spaces, so grams are the cheapest
# segmenter that still hits "order export" style requests).
function Get-Terms {
    param([string]$Text)
    $terms = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($m in [regex]::Matches($Text, '[A-Za-z][A-Za-z0-9_\-]{2,}')) {
        $w = $m.Value.ToLower()
        if ($StopWords -contains $w) { continue }
        [void]$terms.Add($w)
    }
    foreach ($m in [regex]::Matches($Text, '[\u4e00-\u9fff]{2,}')) {
        $run = $m.Value
        if ($run.Length -le 6 -and -not ($CnStop -contains $run)) { [void]$terms.Add($run) }
        for ($i = 0; $i -le $run.Length - 2; $i++) {
            $gram = $run.Substring($i, 2)
            if ($CnStop -contains $gram) { continue }
            [void]$terms.Add($gram)
        }
    }
    return @($terms)
}

function Get-Score {
    param([string]$Haystack, [string[]]$Terms)
    if (-not $Haystack) { return 0 }
    $h = $Haystack.ToLower()
    $score = 0
    foreach ($t in @($Terms)) {
        if ($t -and $h.Contains($t.ToLower())) { $score++ }
    }
    return $score
}

function Get-TableCandidates {
    param([string]$PathToFile, [string[]]$Terms)
    $hits = New-Object System.Collections.Generic.List[string]
    if (-not (Test-Path -LiteralPath $PathToFile)) { return $hits.ToArray() }
    foreach ($line in @([System.IO.File]::ReadAllLines($PathToFile, [System.Text.Encoding]::UTF8))) {
        $cand = $null
        $m = [regex]::Match($line, '^###\s+`?([A-Za-z0-9_.\-]+)`?')
        if ($m.Success) { $cand = $m.Groups[1].Value }
        if (-not $cand) {
            $m2 = [regex]::Match($line, '^\|\s*`([A-Za-z0-9_.\-]+)`\s*\|')
            if ($m2.Success) { $cand = $m2.Groups[1].Value }
        }
        if (-not $cand) { continue }
        if ($cand -eq 'Column' -or $cand -eq '---') { continue }
        if ($cand -match '[<>]') { continue }
        if ((Get-Score -Haystack $line -Terms $Terms) -gt 0 -and -not ($hits -contains $cand)) {
            [void]$hits.Add($cand)
        }
    }
    return $hits.ToArray()
}

function Get-InterfaceCandidates {
    param([string]$PathToFile, [string[]]$Terms)
    $hits = New-Object System.Collections.Generic.List[string]
    if (-not (Test-Path -LiteralPath $PathToFile)) { return $hits.ToArray() }
    foreach ($line in @([System.IO.File]::ReadAllLines($PathToFile, [System.Text.Encoding]::UTF8))) {
        $m = [regex]::Match($line, '^\s*[-*]\s+\*\*(GET|POST|PUT|DELETE|PATCH)\*\*\s+`([^`]+)`')
        if (-not $m.Success) { continue }
        if ($m.Groups[2].Value -match '[<>]') { continue }
        if ((Get-Score -Haystack $line -Terms $Terms) -le 0) { continue }
        $entry = ('{0} {1}' -f $m.Groups[1].Value, $m.Groups[2].Value)
        if (-not ($hits -contains $entry)) { [void]$hits.Add($entry) }
    }
    return $hits.ToArray()
}

function Invoke-Plan {
    param([string]$RootPath, [string]$Text, [string]$FeatureName)

    $terms = @(Get-Terms -Text $Text)
    $lines = New-Object System.Collections.Generic.List[string]
    $notes = New-Object System.Collections.Generic.List[string]

    $cnNoMatch = New-Cn @(0x672A, 0x5339, 0x914D, 0xFF0C, 0x9700, 0x4EBA, 0x5DE5, 0x786E, 0x8BA4)

    # ---------------------------------------------------------- module cards
    $cardRows = New-Object System.Collections.Generic.List[object]
    $modulesDir = Join-Path $RootPath '.harness\modules'
    if (Test-Path -LiteralPath $modulesDir) {
        foreach ($f in @(Get-ChildItem -LiteralPath $modulesDir -Filter '*.md' -File -Force -ErrorAction SilentlyContinue)) {
            $base = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
            if ($base -eq 'README' -or $base -eq '_template') { continue }
            $cardText = Read-Utf8Text $f.FullName
            $title = ''
            $tm = [regex]::Match($cardText, '(?m)^#\s+(.+)$')
            if ($tm.Success) { $title = $tm.Groups[1].Value.Trim() }
            $score = Get-Score -Haystack ($base + ' ' + $title + ' ' + $cardText) -Terms $terms
            $cardRows.Add([pscustomobject]@{ Name = $base; File = $f.Name; Title = $title; Score = $score })
        }
    }
    # .ToArray() first: PS 5.1 throws "Argument types do not match" when @() is
    # applied directly to a List[object].
    $cardHits = @($cardRows.ToArray() | Where-Object { $_.Score -gt 0 } | Sort-Object @{ Expression = 'Score'; Descending = $true }, @{ Expression = 'Name' })
    $allCards = @($cardRows.ToArray() | ForEach-Object { $_.Name } | Sort-Object)

    # -------------------------------------------------------------- skills
    $skillRows = New-Object System.Collections.Generic.List[object]
    $seenSkill = New-Object 'System.Collections.Generic.HashSet[string]'
    $skillIndex = Join-Path (Join-Path (Join-Path $RootPath '.harness') 'skills') 'README.md'
    if (Test-Path -LiteralPath $skillIndex) {
        $skillText = Read-Utf8Text $skillIndex
        # Prefer the generated index block: the per-category tables repeat every
        # skill and their first column is a number, not a category.
        $bm = $skillText.IndexOf('<!-- skills-index:begin -->')
        $em = $skillText.IndexOf('<!-- skills-index:end -->')
        if ($bm -ge 0 -and $em -gt $bm) { $skillText = $skillText.Substring($bm, $em - $bm) }
        foreach ($line in @($skillText -split "`r?`n")) {
            if ($line -notmatch '^\s*\|') { continue }
            $cells = @($line.Trim().Trim('|') -split '\|')
            if ($cells.Count -lt 3) { continue }
            if ($cells[1] -notmatch '`([^`]+)`') { continue }
            $name = $matches[1].Trim()
            $desc = $cells[2].Trim()
            if ($name -eq '' -or $name -eq '---') { continue }
            if (-not $seenSkill.Add($name)) { continue }
            $score = Get-Score -Haystack ($name + ' ' + $desc) -Terms $terms
            $skillRows.Add([pscustomobject]@{ Category = $cells[0].Trim(); Name = $name; Score = $score })
        }
    }
    $skillHits = @($skillRows.ToArray() | Where-Object { $_.Score -gt 0 } | Sort-Object @{ Expression = 'Score'; Descending = $true }, @{ Expression = 'Name' })
    $matchedSkillNames = @($skillHits | ForEach-Object { $_.Name })

    # ------------------------------------------------- tables / interfaces
    $wikiDir = Join-Path $RootPath '.harness\wiki'
    $dataModelName = (New-Cn @(0x6570, 0x636E, 0x6A21, 0x578B)) + '.md'
    $apiName = (New-Cn @(0x63A5, 0x53E3, 0x534F, 0x8BAE)) + '.md'
    $tables = @()
    $interfaces = @()
    if (Test-Path -LiteralPath $wikiDir) {
        $tables = @(Get-TableCandidates -PathToFile (Join-Path $wikiDir $dataModelName) -Terms $terms)
        $interfaces = @(Get-InterfaceCandidates -PathToFile (Join-Path $wikiDir $apiName) -Terms $terms)
    }

    # ----------------------------------------------------- SQL / DDL signals
    $lower = $Text.ToLower()
    $cnSql = @(
        (New-Cn @(0x8FC1, 0x79FB)),             # migration
        (New-Cn @(0x8868, 0x7ED3, 0x6784)),     # table structure
        (New-Cn @(0x7D22, 0x5F15))              # index
    )
    $cnRelease = @((New-Cn @(0x4E0A, 0x7EBF)))  # go live
    $ddlWords = @('ddl', 'migration', 'migrate', 'schema', 'flyway', 'liquibase', 'table structure', 'alter table') + @($cnSql)
    $sqlWords = @('sql', 'query', 'select', 'insert', 'delete', 'join') + @($cnSql)
    $isDdl = $false
    foreach ($w in $ddlWords) { if ($w -and $lower.Contains($w)) { $isDdl = $true; break } }
    $isSql = $isDdl
    if (-not $isSql) { foreach ($w in $sqlWords) { if ($w -and $lower.Contains($w)) { $isSql = $true; break } } }
    $isRelease = $false
    foreach ($w in $cnRelease) { if ($w -and $lower.Contains($w)) { $isRelease = $true; break } }

    # ---------------------------------------------------------- level hint
    $strongCards = @($cardHits | Where-Object { $_.Score -ge 2 })
    $levelHint = 'L2'
    $levelWhy = 'default for a single-module functional change'
    if ($isDdl -or $isRelease) { $levelHint = 'L3'; $levelWhy = $(if ($isDdl) { 'requirement mentions SQL DDL / migration' } else { 'requirement mentions a production rollout' }) }
    elseif ($strongCards.Count -ge 2) {
        $levelHint = 'L3'
        $levelWhy = ('requirement points at {0} modules: {1}' -f $strongCards.Count, ((@($strongCards) | ForEach-Object { $_.Name }) -join ', '))
    }

    # ------------------------------------------------------------ gates
    $gates = New-Object System.Collections.Generic.List[string]
    $gates.Add('stage 1   request-analysis   summary fields + real acceptance / impact / task content   (scripts\stage-gate.ps1 -Stage 1 -Feature <feature>)')
    $gates.Add('stage 3   coding-skill       build command from AGENTS.md must exist and exit 0          (scripts\stage-gate.ps1 -Stage 3)')
    $gates.Add('stage 4   pre-commit         red-line scan on the staged diff (automatic, nothing to run)')
    $gates.Add('stage 5   unit-test-write    full test command from AGENTS.md must exit 0                (scripts\stage-gate.ps1 -Stage 5)')
    $gates.Add('stage 6   expert-reviewer    review ledger: P0 fixed, P1 has a disposition              (scripts\stage-gate.ps1 -Stage 6)')
    $gates.Add('stage 10  sediment          counters + lesson + review closure                          (scripts\stage-gate.ps1 -Stage 10)')
    if ($isSql) {
        $gates.Add('+ skill   14-sql-review     sql_review in summary.md; pre-commit runs sql-review-gate')
        $gates.Add('+ stage 10 SQL check        a "pass / rewritten" conclusion must cite a real evidence file')
    }
    if ($isDdl) {
        $gates.Add('+ stage 8  deploy-verify     db-migrations.sql and rollback.sql must be a pair')
        $gates.Add('+ skill   09-db-migration   extend -> migrate -> contract, with a rollback path')
    }
    if ($isRelease) {
        $gates.Add('+ stage 8  deploy-readiness  production rollout; fill delivery_status=deployed and the deployment record')
    }

    # ------------------------------------------------------------ report
    $lines.Add('harness plan (read only, nothing was written)')
    $lines.Add(('  root        : {0}' -f $RootPath))
    $lines.Add(('  requirement : {0}' -f $Text))
    if ($FeatureName) { $lines.Add(('  feature     : {0}  ->  .harness/changes/{0}/summary.md' -f $FeatureName)) }
    else { $lines.Add('  feature     : (not set; pass -Feature to pin the record directory)') }
    $lines.Add(('  level hint  : {0} -- {1}' -f $levelHint, $levelWhy))
    $lines.Add('  level check : run scripts\suggest-flow.ps1 once the diff exists (diff based, authoritative)')
    $lines.Add('')

    $lines.Add('module cards (read these first; one card covers one place where things break):')
    if ($cardHits.Count -gt 0) {
        foreach ($c in $cardHits) {
            $lines.Add(('  - {0}  (score {1})  [.harness/modules/{2}]' -f $c.Name, $c.Score, $c.File))
        }
    } elseif ($allCards.Count -gt 0) {
        $lines.Add(('  - {0}' -f $cnNoMatch))
        $lines.Add(('  - available cards: {0}' -f ($allCards -join ', ')))
    } else {
        $lines.Add('  - no .harness/modules cards found; generate the 3-5 highest-frequency modules first')
    }
    $lines.Add('')

    $lines.Add('required skills (load only the ones whose trigger fires):')
    $listed = New-Object System.Collections.Generic.List[string]
    foreach ($s in $CoreSkills) {
        if ($skillRows.Count -gt 0) {
            $row = @($skillRows | Where-Object { $_.Name -eq $s } | Select-Object -First 1)
            if ($row.Count -gt 0) { $lines.Add(('  - {0}  [{1}]  (core)' -f $s, $row[0].Category)) }
            else { $lines.Add(('  - {0}  (core; not in .harness/skills/README.md)' -f $s)) }
        } else {
            $lines.Add(('  - {0}  (core)' -f $s))
        }
        $listed.Add($s)
    }
    foreach ($row in $skillHits) {
        if ($listed -contains $row.Name) { continue }
        $lines.Add(('  - {0}  [{1}]  (matched)' -f $row.Name, $row.Category))
        $listed.Add($row.Name)
    }
    if ($skillRows.Count -eq 0) {
        $lines.Add('  - no .harness/skills/README.md index; fall back to .harness/rules/ and say so')
    }
    $lines.Add('')

    $lines.Add('expected gates (stage 1/3/4/5/6/10; SQL and DDL add their own):')
    foreach ($g in $gates) { $lines.Add(('  - {0}' -f $g)) }
    $lines.Add('  - note: an L1 result from suggest-flow skips the summary gates (write .harness/changes/_small.md)')
    $lines.Add('')

    $lines.Add('tables / interfaces in scope:')
    if ($tables.Count -gt 0) { $lines.Add(('  tables     : {0}' -f ($tables -join ', '))) }
    else { $lines.Add('  tables     : ' + $cnNoMatch) }
    if ($interfaces.Count -gt 0) { $lines.Add(('  interfaces : {0}' -f ($interfaces -join ', '))) }
    else { $lines.Add('  interfaces : ' + $cnNoMatch) }
    if ($tables.Count -eq 0 -and $interfaces.Count -eq 0) {
        $lines.Add(('  ({0}: .harness/wiki has no matching row; read the code, then fill the wiki)' -f $cnNoMatch))
    }

    return [pscustomobject]@{
        Report = $lines.ToArray()
        Terms = $terms
        ModuleHits = @($cardHits | ForEach-Object { $_.Name })
        AvailableCards = $allCards
        SkillHits = $matchedSkillNames
        Tables = $tables
        Interfaces = $interfaces
        Gates = $gates.ToArray()
        LevelHint = $levelHint
        IsSql = $isSql
        IsDdl = $isDdl
        NoMatchText = $cnNoMatch
    }
}

function Invoke-PlanSelfTest {
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('hb-plan-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $fails = New-Object System.Collections.Generic.List[string]
    $utf8 = New-Object System.Text.UTF8Encoding($false)

    function Assert-Case {
        param([string]$Name, [bool]$Ok)
        if ($Ok) { Write-Host ('ok: ' + $Name) }
        else { Write-Host ('[FAIL] ' + $Name) -ForegroundColor Red; $fails.Add($Name) }
    }

    $cnOrderExport = New-Cn @(0x8BA2, 0x5355, 0x5BFC, 0x51FA)
    $cnBatch = New-Cn @(0x6279, 0x91CF)
    $cnWhen = New-Cn @(0x65F6, 0x4F7F, 0x7528)
    $cnTableHeader = New-Cn @(0x6570, 0x636E, 0x6A21, 0x578B)
    $cnApiHeader = New-Cn @(0x63A5, 0x53E3, 0x534F, 0x8BAE)

    try {
        $h = Join-Path $tmp '.harness'
        New-Item -ItemType Directory -Force -Path (Join-Path $h 'modules') | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $h 'skills') | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $h 'wiki') | Out-Null

        [System.IO.File]::WriteAllText((Join-Path $h 'modules\order.md'),
            ('# {0} (module card)' + "`n## responsibility`n" + $cnOrderExport) -f $cnOrderExport, $utf8)

        $skillMd = '# skills' + "`n" +
                   '| category | skill | description |' + "`n" +
                   '| --- | --- | --- |' + "`n" +
                   ('| biz-dev | `excel-import-export` | {0} {1} {2} |' -f $cnOrderExport, $cnBatch, $cnWhen) + "`n"
        [System.IO.File]::WriteAllText((Join-Path $h 'skills\README.md'), $skillMd, $utf8)

        $tableMd = ('# {0}' -f $cnTableHeader) + "`n" +
                   ('### `demo_order` ({0})' -f $cnOrderExport) + "`n" +
                   ('### `other_table` (unrelated)') + "`n"
        [System.IO.File]::WriteAllText((Join-Path $h ('wiki\' + $cnTableHeader + '.md')), $tableMd, $utf8)

        $apiMd = ('# {0}' -f $cnApiHeader) + "`n" +
                 ('### `{0}`' -f $cnOrderExport) + "`n" +
                 ('- **GET** `/api/order/export` -- {0}' -f $cnOrderExport) + "`n" +
                 ('- **POST** `/api/unrelated` -- something else') + "`n"
        [System.IO.File]::WriteAllText((Join-Path $h ('wiki\' + $cnApiHeader + '.md')), $apiMd, $utf8)

        $plan = Invoke-Plan -RootPath $tmp -Text ($cnOrderExport + ' excel') -FeatureName 'order-export'
        $rep = @($plan.Report) -join "`n"
        Assert-Case 'plan matches the module card' ($rep -match '\[\.harness/modules/order\.md\]')
        Assert-Case 'plan matches the skill index' ($rep -match 'excel-import-export')
        Assert-Case 'plan matches the table' ($rep -match 'demo_order')
        Assert-Case 'plan matches the interface' ($rep -match '/api/order/export')
        Assert-Case 'plan lists the fixed gates' ($rep -match 'stage 1' -and $rep -match 'stage 10')
        Assert-Case 'plan shows the feature directory' ($rep -match 'order-export/summary\.md')
        Assert-Case 'plan without SQL adds no sql-review line' (-not ($rep -match '14-sql-review'))

        $plan2 = Invoke-Plan -RootPath $tmp -Text ('ddl ' + $cnOrderExport) -FeatureName ''
        $rep2 = @($plan2.Report) -join "`n"
        Assert-Case 'DDL requirement switches the hint to L3' ($plan2.LevelHint -eq 'L3')
        Assert-Case 'DDL requirement adds sql-review' ($rep2 -match '14-sql-review')
        Assert-Case 'DDL requirement adds the migration pair' ($rep2 -match 'db-migrations\.sql')
        Assert-Case 'DDL requirement adds stage 8' ($rep2 -match 'stage 8')

        $empty = Join-Path $tmp 'empty'
        New-Item -ItemType Directory -Force -Path $empty | Out-Null
        $plan3 = Invoke-Plan -RootPath $empty -Text $cnOrderExport -FeatureName ''
        $rep3 = @($plan3.Report) -join "`n"
        Assert-Case 'empty project marks tables as not matched' ($rep3.Contains($plan3.NoMatchText))
        Assert-Case 'empty project has no invented card' (@($plan3.ModuleHits).Count -eq 0)
    } finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }

    if ($fails.Count -gt 0) {
        Write-Host ('PLAN SELFTEST FAILED: {0} case(s)' -f $fails.Count) -ForegroundColor Red
        return 1
    }
    Write-Host 'PLAN SELFTEST OK' -ForegroundColor Green
    return 0
}

if ($SelfTest) {
    exit (Invoke-PlanSelfTest)
}

if (-not $Requirement -or $Requirement.Trim() -eq '') {
    Write-Host 'usage: harness-plan.ps1 -Requirement "<one-line request>" [-Root <dir>] [-Feature <name>]' -ForegroundColor Red
    exit 1
}

$rootPath = $Root
try { $rootPath = (Resolve-Path -LiteralPath $Root).Path }
catch {
    Write-Host ('root not found: ' + $Root) -ForegroundColor Red
    exit 1
}

$plan = Invoke-Plan -RootPath $rootPath -Text $Requirement -FeatureName $Feature
foreach ($line in @($plan.Report)) { Write-Host $line }
exit 0
