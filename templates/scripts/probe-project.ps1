<#
  probe-project.ps1 -- collect the facts a harness needs before it is generated

  WHY
    Generating AGENTS.md / red lines / skills before looking at the project is
    guessing. This script produces a *baseline* the agent must read first, so the
    generated harness matches the real repository instead of a template fantasy.

  OUTPUT
    <out>\baseline.json   machine readable, the agent parses this
    <out>\baseline.md     human readable summary for the user to confirm

  USAGE  (no pwsh on 5.1 boxes; Bypass required by the execution policy)
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\probe-project.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\probe-project.ps1 -Root D:\proj
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\probe-project.ps1 -Out baseline

  NOTE
    Pure ASCII script; all Chinese text goes into the produced files through
    UTF-8 encoding, never into this file itself.
#>
[CmdletBinding()]
param(
    [string]$Root = (Get-Location).Path,
    [string]$Out = 'baseline'
)

$ErrorActionPreference = 'Stop'

$rootPath = (Resolve-Path -LiteralPath $Root).Path
$outDir   = Join-Path $rootPath $Out
if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

function Find-Files {
    param([string[]]$Names)
    $hits = @()
    foreach ($n in $Names) {
        # -LiteralPath treats '*.sln' as a literal name, so wildcard entries
        # silently never matched. Expand them with -Filter instead.
        if ($n -match '[*?]') {
            if (@(Get-ChildItem -LiteralPath $rootPath -Filter $n -File -Force -ErrorAction SilentlyContinue).Count -gt 0) {
                $hits += $n
            }
        } else {
            $p = Join-Path $rootPath $n
            if (Test-Path -LiteralPath $p) { $hits += $n }
        }
    }
    return $hits
}

function Read-Snippet {
    param([string]$Rel, [int]$Lines = 40)
    $p = Join-Path $rootPath $Rel
    if (-not (Test-Path -LiteralPath $p)) { return @() }
    return @([System.IO.File]::ReadAllLines($p, [System.Text.Encoding]::UTF8) | Select-Object -First $Lines)
}

# ------------------------------------------------------------ build / test
$buildFiles = Find-Files @(
    'pom.xml','build.gradle','build.gradle.kts','settings.gradle','settings.gradle.kts',
    'package.json','pnpm-lock.yaml','yarn.lock','package-lock.json',
    'pyproject.toml','requirements.txt','setup.py','go.mod','Cargo.toml',
    'Makefile','build.sbt','composer.json','mix.exs','*.sln','*.csproj'
)
$ciFiles = @()
foreach ($ci in @('.github\workflows','.gitlab-ci.yml','Jenkinsfile','azure-pipelines.yml','.circleci','bitbucket-pipelines.yml')) {
    if (Test-Path -LiteralPath (Join-Path $rootPath $ci)) { $ciFiles += $ci }
}

# ------------------------------------------------------------- source roots
$srcRoots = @()
foreach ($d in @('src','app','lib','internal','pkg','cmd','packages','apps','modules')) {
    if (Test-Path -LiteralPath (Join-Path $rootPath $d)) { $srcRoots += $d }
}

# --------------------------------------------------------------- test roots
$testRoots = @()
foreach ($d in @('src\test','test','tests','__tests__','spec','e2e','integration-tests')) {
    if (Test-Path -LiteralPath (Join-Path $rootPath $d)) { $testRoots += $d }
}

# ------------------------------------------------- multi-module roots
# A Maven/Gradle multi-module repo keeps code under <module>\src\main\java, so the
# top-level scan above reports "no source root" even though the code is right there.
# Probe one level down and add the precise roots; dedupe against the list above.
$skipDirs = @('.git','.harness','.trae','.claude','.idea','.vscode','node_modules','target','build','dist','out','bin','obj')
foreach ($moduleDir in Get-ChildItem -LiteralPath $rootPath -Directory -Force -ErrorAction SilentlyContinue) {
    if ($skipDirs -contains $moduleDir.Name) { continue }
    $mainPath = Join-Path $moduleDir.FullName 'src\main\java'
    $testPath = Join-Path $moduleDir.FullName 'src\test\java'
    if (Test-Path -LiteralPath $mainPath) {
        $rel = $moduleDir.Name + '\src\main\java'
        if ($srcRoots -notcontains $rel) { $srcRoots += $rel }
    }
    if (Test-Path -LiteralPath $testPath) {
        $rel = $moduleDir.Name + '\src\test\java'
        if ($testRoots -notcontains $rel) { $testRoots += $rel }
    }
}

# ------------------------------------------------------------------ reading
$readme = @()
foreach ($r in @('README.md','README.zh.md','README_CN.md','README.txt')) {
    if (Test-Path -LiteralPath (Join-Path $rootPath $r)) { $readme = Read-Snippet $r 60; break }
}

# --------------------------------------------------------- existing harness
$existingAgents = @()
foreach ($a in @('AGENTS.md','CLAUDE.md','.trae\rules','.cursor\rules','.github\copilot-instructions.md')) {
    if (Test-Path -LiteralPath (Join-Path $rootPath $a)) { $existingAgents += $a }
}
$existingSkills = 0
$existingSkillDirs = @()
foreach ($d in @('.trae\skills', '.claude\skills', '.agents\skills', '.codebuddy\skills')) {
    $p = Join-Path $rootPath $d
    if (-not (Test-Path -LiteralPath $p)) { continue }
    $n = @(Get-ChildItem -LiteralPath $p -Force).Count
    $existingSkillDirs += ("$d ($n)")
    if ($n -gt $existingSkills) { $existingSkills = $n }
}

# ------------------------------------------------------------- stack detect
$stack = New-Object System.Collections.Generic.List[string]
if (Test-Path -LiteralPath (Join-Path $rootPath 'pom.xml'))         { $stack.Add('java-maven') }
if (Test-Path -LiteralPath (Join-Path $rootPath 'build.gradle'))    { $stack.Add('java-gradle') }
if (Test-Path -LiteralPath (Join-Path $rootPath 'go.mod'))          { $stack.Add('go') }
if (Test-Path -LiteralPath (Join-Path $rootPath 'pyproject.toml'))  { $stack.Add('python') }
if (Test-Path -LiteralPath (Join-Path $rootPath 'package.json'))    { $stack.Add('node') }
if (Test-Path -LiteralPath (Join-Path $rootPath 'Cargo.toml'))      { $stack.Add('rust') }
if (Test-Path -LiteralPath (Join-Path $rootPath 'composer.json'))   { $stack.Add('php') }
if (@(Get-ChildItem -LiteralPath $rootPath -Filter '*.sln' -File -Force -ErrorAction SilentlyContinue).Count -gt 0) { $stack.Add('dotnet') }
if ($stack.Count -eq 0) { $stack.Add('unknown') }

# ------------------------------------------------------- dependency signals
$pkgSignals = @()
$pkgPath = Join-Path $rootPath 'package.json'
if (Test-Path -LiteralPath $pkgPath) {
    try {
        $pkg = (Get-Content -LiteralPath $pkgPath -Raw -Encoding UTF8) | ConvertFrom-Json
        foreach ($bag in @($pkg.dependencies, $pkg.devDependencies)) {
            if ($bag) { $pkgSignals += @($bag.PSObject.Properties.Name) }
        }
    } catch { }
}
$pomSignals = @()
$pomPath = Join-Path $rootPath 'pom.xml'
if (Test-Path -LiteralPath $pomPath) {
    $pomSignals = @(Select-String -LiteralPath $pomPath -Pattern '<artifactId>([^<]+)</artifactId>' -Encoding UTF8 |
        ForEach-Object { $_.Matches[0].Groups[1].Value } | Sort-Object -Unique | Select-Object -First 200)
}

# --------------------------------------------------------------- git facts
$isGit = Test-Path -LiteralPath (Join-Path $rootPath '.git')
$branch = ''
$recentCommits = @()
$dirty = $null
if ($isGit) {
    try {
        $branch = (& git -C $rootPath rev-parse --abbrev-ref HEAD 2>$null)
        $recentCommits = @(& git -C $rootPath log --oneline -20 2>$null)
        $dirty = -not [string]::IsNullOrWhiteSpace((& git -C $rootPath status --porcelain 2>$null))
    } catch { }
}

# ------------------------------------------------------ file type histogram
$hist = @{}
$skip = @('.git','node_modules','target','build','dist','out','coverage','.harness','.trae','vendor','.idea')
Get-ChildItem -LiteralPath $rootPath -Recurse -File -Force -ErrorAction SilentlyContinue |
    Where-Object {
        $rel = $_.FullName.Substring($rootPath.Length).TrimStart('\','/')
        $parts = $rel -split '[\\/]'
        -not ($parts | Where-Object { $skip -contains $_ })
    } |
    ForEach-Object {
        $ext = if ($_.Extension) { $_.Extension.ToLower() } else { '(none)' }
        if ($hist.ContainsKey($ext)) { $hist[$ext]++ } else { $hist[$ext] = 1 }
    }
$topExt = @($hist.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 12 |
    ForEach-Object { [pscustomobject]@{ ext = $_.Key; count = $_.Value } })

# --------------------------------------------------------------- write json
$baseline = [ordered]@{
    generatedAt  = (Get-Date).ToString('s')
    root         = $rootPath
    stack        = @($stack)
    buildFiles   = @($buildFiles)
    ciFiles      = @($ciFiles)
    srcRoots     = @($srcRoots)
    testRoots    = @($testRoots)
    existingRuleFiles = @($existingAgents)
    existingSkillCount = $existingSkills
    packageSignals = @($pkgSignals | Select-Object -First 120)
    mavenSignals   = @($pomSignals)
    git = [ordered]@{ isRepo = $isGit; branch = $branch; dirty = $dirty; recentCommits = @($recentCommits) }
    fileTypes = @($topExt)
    readmeHead = @($readme)
    notes = @(
        'baseline.json is evidence, not a plan. Read it, then propose what to create.',
        'Commands (build/test/lint) MUST be discovered by actually running them; this probe does not guess them.',
        'Anything not present here must be marked TODO(pending) rather than invented.'
    )
}
# ------------------------------------------------------------ recommendations
# Turn raw facts into decidable suggestions. The agent still decides, but it no
# longer starts from a blank page: it starts from "here is the likely plan".
$recSkills = New-Object System.Collections.Generic.List[string]
$recRedLines = New-Object System.Collections.Generic.List[string]
$recNotes = New-Object System.Collections.Generic.List[string]

# Always-on core three
$recSkills.Add('request-analysis')
$recSkills.Add('coding-skill')
$recSkills.Add('expert-reviewer')

# Pick the single highest-value biz-dev topic from dependency signals
$sigText = (@($pkgSignals) + @($pomSignals)) -join '|'
if ($sigText -match '(?i)redis|lettuce|jedis|cache')      { $recSkills.Add('redis-cache') }
elseif ($sigText -match '(?i)rocketmq|kafka|rabbitmq|amqp|mq') { $recSkills.Add('mq-messaging') }
elseif ($sigText -match '(?i)mybatis|jpa|hibernate|jdbc|sqlalchemy|prisma|typeorm') { $recSkills.Add('crud-scaffold') }
elseif ($sigText -match '(?i)excel|poi|easyexcel|xlsx')   { $recSkills.Add('excel-import-export') }

if (-not ($recSkills -contains 'crud-scaffold') -and -not ($recSkills -contains 'redis-cache') -and
    -not ($recSkills -contains 'mq-messaging') -and -not ($recSkills -contains 'excel-import-export')) {
    $recSkills.Add('crud-scaffold')
    $recNotes.Add('no dependency signal matched a biz-dev topic; crud-scaffold is the safest default -- confirm with the user')
}

# Troubleshooting: only if the stack has a database worth optimising
if ($sigText -match '(?i)mysql|postgres|oracle|sqlserver|mariadb') { $recSkills.Add('slow-sql') }

# Red line candidates by stack
if ($stack -contains 'java-maven' -or $stack -contains 'java-gradle') {
    $recRedLines.Add('U1/U2 log+secret hygiene')
    $recRedLines.Add('J1 money as integer minor units')
    $recRedLines.Add('J2 no field injection')
    $recRedLines.Add('J3 @Transactional must declare rollbackFor')
    $recRedLines.Add('J4 no raw exception to API layer')
    if ($sigText -match '(?i)redis') { $recRedLines.Add('J6 redis key prefix constant') }
    if ($sigText -match '(?i)rocketmq|kafka|rabbitmq') { $recRedLines.Add('J5 consumer idempotency (review-level)') }
    if ($sigText -match '(?i)mybatis') { $recRedLines.Add('J7 no ${} in mapper xml') }
}
if ($stack -contains 'node') {
    $recRedLines.Add('U1/U2 log+secret hygiene')
    $recRedLines.Add('N3 no raw http client inside components')
    $recRedLines.Add('N4 no token in localStorage')
    $recRedLines.Add('N2 no float arithmetic on money')
}
if ($stack -contains 'python') {
    $recRedLines.Add('U1/U2 log+secret hygiene')
    $recRedLines.Add('P1 no bare except')
    $recRedLines.Add('P2 no eval/exec/pickle.loads')
    $recRedLines.Add('P4 no sql string concat')
}
if ($stack -contains 'go') {
    $recRedLines.Add('U1/U2 log+secret hygiene')
    $recRedLines.Add('G2 no float64 for money')
    $recRedLines.Add('G4 no sql string concat')
}
if ($recRedLines.Count -eq 0) {
    $recRedLines.Add('U1/U2 log+secret hygiene')
    $recNotes.Add('stack not recognised; start with the universal red lines only and add stack-specific ones after reading the code')
}

# Gate mode: existing repo with history must start in "new-code only" mode
$gateMode = 'full'
if ($isGit -and $recentCommits.Count -ge 20) { $gateMode = 'new-code-only' }
if ($gateMode -eq 'new-code-only') {
    $recNotes.Add('repo has >=20 commits: start the gate in "new-code-only" mode, otherwise the first scan will report hundreds of legacy violations and the user will turn the gate off')
}
if (-not $isGit) {
    $recNotes.Add('not a git repo: there is no rollback safety net and no pre-commit gate; suggest git init first')
}

# Existing artifacts that change the plan
if ($existingAgents.Count -gt 0) {
    $recNotes.Add("existing rule files found ($($existingAgents -join ', ')): merge into them, never overwrite")
}
if ($existingSkills -gt 0) {
    $recNotes.Add("skill entries already exist ($($existingSkillDirs -join ', ')): diff before linking, do not clobber")
}
if ($testRoots.Count -eq 0) {
    $recNotes.Add('no test root detected: unit-test-write may not be worth installing until tests exist')
}
if ($buildFiles.Count -eq 0) {
    $recNotes.Add('no build file detected: the project layout is unusual, verify with the user before generating')
}

$recommendations = [ordered]@{
    suggestedSkills = @($recSkills)
    skillCount      = $recSkills.Count
    redLineCandidates = @($recRedLines)
    gateMode        = $gateMode
    notes           = @($recNotes)
}

$baseline['recommendations'] = $recommendations

$jsonOut = Join-Path $outDir 'baseline.json'
$jsonText = $baseline | ConvertTo-Json -Depth 6
[System.IO.File]::WriteAllText($jsonOut, $jsonText, (New-Object System.Text.UTF8Encoding($false)))

# --------------------------------------------------------------- write md
$md = New-Object System.Text.StringBuilder
[void]$md.AppendLine('# Project baseline (generated by probe-project.ps1)')
[void]$md.AppendLine('')
[void]$md.AppendLine("Generated: $((Get-Date).ToString('yyyy-MM-dd HH:mm'))")
[void]$md.AppendLine("Root: $rootPath")
[void]$md.AppendLine('')
[void]$md.AppendLine('> This file is the evidence the harness is generated from.')
[void]$md.AppendLine('> Part 1 is a *suggestion*; Part 2 is the *facts* behind it.')
[void]$md.AppendLine('> Confirm Part 1 with the user, then generate. Never invent what Part 2 does not show.')
[void]$md.AppendLine('')
[void]$md.AppendLine('## Part 1 - Suggested plan (confirm before acting)')
[void]$md.AppendLine('')
[void]$md.AppendLine('### Recommended skill set')
[void]$md.AppendLine('')
[void]$md.AppendLine("Proposed: **$($recSkills.Count) skills** (core 3 + highest-value topics for this stack).")
[void]$md.AppendLine('')
foreach ($s in $recSkills) { [void]$md.AppendLine("- ``$s``") }
[void]$md.AppendLine('')
[void]$md.AppendLine('> Everything else in templates/skills can stay unbuilt until a real task needs it.')
[void]$md.AppendLine('> Same correction appearing twice = the signal to add one more skill.')
[void]$md.AppendLine('')
[void]$md.AppendLine('### Suggested red-line candidates')
[void]$md.AppendLine('')
[void]$md.AppendLine('Pick **5-8** from these. Each must be machine-checkable and actually likely in this codebase.')
[void]$md.AppendLine('')
foreach ($r in $recRedLines) { [void]$md.AppendLine("- $r") }
[void]$md.AppendLine('')
[void]$md.AppendLine('### Gate mode')
[void]$md.AppendLine('')
[void]$md.AppendLine("- **$gateMode**")
if ($gateMode -eq 'new-code-only') {
    [void]$md.AppendLine('  - start by blocking new violations only; pay down legacy debt in categories afterwards')
} else {
    [void]$md.AppendLine('  - full scan from the start is acceptable here')
}
[void]$md.AppendLine('')
if ($recNotes.Count) {
    [void]$md.AppendLine('### Things that will change the plan')
    [void]$md.AppendLine('')
    foreach ($n in $recNotes) { [void]$md.AppendLine("- $n") }
    [void]$md.AppendLine('')
}
[void]$md.AppendLine('---')
[void]$md.AppendLine('')
[void]$md.AppendLine('## Part 2 - Facts (evidence)')
[void]$md.AppendLine('')
[void]$md.AppendLine('## Stack')
[void]$md.AppendLine('')
foreach ($s in $stack) { [void]$md.AppendLine("- $s") }
[void]$md.AppendLine('')
[void]$md.AppendLine('## Build / CI files')
[void]$md.AppendLine('')
if ($buildFiles.Count) { foreach ($b in $buildFiles) { [void]$md.AppendLine("- $b") } } else { [void]$md.AppendLine('- (none found)') }
if ($ciFiles.Count) { foreach ($c in $ciFiles) { [void]$md.AppendLine("- CI: $c") } }
[void]$md.AppendLine('')
[void]$md.AppendLine('## Layout')
[void]$md.AppendLine('')
[void]$md.AppendLine("- source roots: " + $(if ($srcRoots.Count) { $srcRoots -join ', ' } else { '(none detected)' }))
[void]$md.AppendLine("- test roots: " + $(if ($testRoots.Count) { $testRoots -join ', ' } else { '(none detected)' }))
[void]$md.AppendLine('')
[void]$md.AppendLine('## Top file types')
[void]$md.AppendLine('')
[void]$md.AppendLine('| ext | files |')
[void]$md.AppendLine('| --- | --- |')
foreach ($e in $topExt) { [void]$md.AppendLine("| $($e.ext) | $($e.count) |") }
[void]$md.AppendLine('')
[void]$md.AppendLine('## Existing harness artifacts (must not be overwritten)')
[void]$md.AppendLine('')
if ($existingAgents.Count) { foreach ($a in $existingAgents) { [void]$md.AppendLine("- $a") } } else { [void]$md.AppendLine('- none') }
[void]$md.AppendLine("- .trae/skills entries: $existingSkills")
[void]$md.AppendLine('')
[void]$md.AppendLine('## Git')
[void]$md.AppendLine('')
[void]$md.AppendLine("- is repo: $isGit")
[void]$md.AppendLine("- branch: $branch")
[void]$md.AppendLine("- dirty: $dirty")
if ($recentCommits.Count) {
    [void]$md.AppendLine('')
    [void]$md.AppendLine('Recent commits:')
    [void]$md.AppendLine('')
    [void]$md.AppendLine('```')
    foreach ($c in $recentCommits) { [void]$md.AppendLine($c) }
    [void]$md.AppendLine('```')
}
[void]$md.AppendLine('')
[void]$md.AppendLine('## Still unknown (must be discovered by running commands, not guessed)')
[void]$md.AppendLine('')
[void]$md.AppendLine('- build command')
[void]$md.AppendLine('- full test command')
[void]$md.AppendLine('- single test command')
[void]$md.AppendLine('- lint / format command')
[void]$md.AppendLine('- local run command')
[void]$md.AppendLine('- real red-line candidates for this codebase')
[void]$md.AppendLine('')

$mdOut = Join-Path $outDir 'baseline.md'
[System.IO.File]::WriteAllText($mdOut, $md.ToString(), (New-Object System.Text.UTF8Encoding($false)))

Write-Host ""
Write-Host "probe complete" -ForegroundColor Green
Write-Host "  stack        : $($stack -join ', ')"
Write-Host "  build files  : $(if ($buildFiles.Count) { $buildFiles -join ', ' } else { '(none)' })"
Write-Host "  src roots    : $(if ($srcRoots.Count) { $srcRoots -join ', ' } else { '(none)' })"
Write-Host "  test roots   : $(if ($testRoots.Count) { $testRoots -join ', ' } else { '(none)' })"
Write-Host "  existing rules: $(if ($existingAgents.Count) { $existingAgents -join ', ' } else { '(none)' })"
Write-Host "  git          : repo=$isGit branch=$branch dirty=$dirty"
Write-Host ""
Write-Host "  written: $jsonOut"
Write-Host "  written: $mdOut"
Write-Host ""
Write-Host "NEXT: read baseline.md, confirm with the user, then generate the harness."
Write-Host "      Commands still unknown must be discovered by running them."
exit 0
