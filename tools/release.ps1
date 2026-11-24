<#
  release.ps1 -- one maintainer entry point from version bump to release notes

  WHY
    A release touches the same eight files every time: VERSION, releases.json,
    the HTML page, two case-study READMEs, two root READMEs and the quality
    table. Updating them by hand left stale counts behind (the package gate then
    failed), and the commit message was written with a BOM three times because
    Set-Content -Encoding UTF8 adds one. This script does the mechanical part
    once, verifies it once, and prints the git commands the human still owns.

  WHAT IT DOES (default)
    1. validate the new x.y.z and that the working tree is clean
    2. rewrite VERSION (header + a new changelog entry) and regenerate
       releases.json through tools/parse-changelog.py (never hand-edited)
    3. move the version markers in the HTML page and the two case-study READMEs
    4. sync the derived counts: .ps1 files, contracts, skill totals
    5. run tools/verify-package.ps1 (full), tests/run-all.ps1 once, then
       tools/package-zip.ps1
    6. write a BOM-free commit message and print the remaining git commands

    It never commits, tags, pushes or publishes unless -Commit / -Tag / -Publish
    is passed explicitly. On any failure the eight files are restored from an
    in-memory backup.

  USAGE
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\release.ps1 `
        -Version 1.32.0 -Title "some title" -Notes notes.txt
    ... -DryRun            print the plan, write nothing
    ... -SkipVerify        skip tools\verify-package.ps1
    ... -SkipTests         skip tests\run-all.ps1
    ... -SkipZip           skip tools\package-zip.ps1
    ... -AllowDirty        do not refuse a dirty working tree
    ... -Commit -Tag -Publish   also commit / tag / create the GitHub release
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\release.ps1 -SelfTest

  SELF TEST
    -SelfTest builds a minimal fixture in %TEMP%, runs the real script against
    it twice, and asserts insertion, idempotency, JSON regeneration, doc/count
    rewrites, BOM-free message and dirty-tree refusal. It never touches the repo
    and never runs verify-package, run-all or package-zip.

  EXIT CODE
    0 = success (or dry run / self test OK), 1 = refused or failed

  NOTE
    Pure ASCII on purpose (PS 5.1 reads a BOM-less .ps1 as ANSI). Chinese is
    only read from -Title and the -Notes file; the few Chinese phrases this
    script must find are built from code points.
#>
[CmdletBinding()]
param(
    [string]$Version = '',
    [string]$Title = '',
    [string]$Notes = '',
    [string]$Root = '',
    [switch]$DryRun,
    [switch]$SkipTests,
    [switch]$SkipVerify,
    [switch]$SkipZip,
    [switch]$AllowDirty,
    [switch]$AllowBranch,
    [switch]$Commit,
    [switch]$Tag,
    [switch]$Publish,
    [string]$CommitType = 'chore',
    [string]$CommitScope = 'release',
    [string]$CommitMessagePath = '',
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'

if (-not $Root) { $Root = Split-Path -Parent $PSScriptRoot }

$PS = if (Get-Command powershell -ErrorAction SilentlyContinue) { 'powershell' } else { 'pwsh' }

# Chinese phrases this script must locate. Built from code points so the file
# stays pure ASCII (PS 5.1 rule).
$ge = [string][char]0x4E2A                                     # ge
$gong = [string][char]0x5171                                   # gong
$hang = [string][char]0x884C                                   # hang
$mid = [string][char]0x00B7                                    # middle dot
$pingjun = -join ([char]0x5E73, [char]0x5747)                  # ping jun
$tiao = [string][char]0x6761                                   # tiao
$kuaWenJian = -join ([char]0x8DE8, [char]0x6587, [char]0x4EF6) # kua wen jian
$qiYue = -join ([char]0x5951, [char]0x7EA6)                    # qi yue
$csCn = -join ([char]0x5305, [char]0x672C, [char]0x8EAB, [char]0x5DF2, [char]0x8FED, [char]0x4EE3, [char]0x5230)  # package itself has iterated to
$qgName = (-join ([char]0x8D28, [char]0x91CF, [char]0x5206, [char]0x7EA7)) + '.md'                 # quality grading file

# --------------------------------------------------------------------- helpers

function Read-TextWithBom {
    param([string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    return [pscustomobject]@{ Text = $text; HasBom = $hasBom }
}

function Write-TextKeepBom {
    param([string]$Path, [string]$Text, [bool]$HasBom)
    $enc = New-Object System.Text.UTF8Encoding($HasBom)
    [System.IO.File]::WriteAllText($Path, $Text, $enc)
}

$script:BackupOrder = New-Object System.Collections.Generic.List[string]
$script:BackupBytes = @{}

function Backup-File {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    if ($script:BackupBytes.ContainsKey($Path)) { return }
    $script:BackupBytes[$Path] = [System.IO.File]::ReadAllBytes($Path)
    $script:BackupOrder.Add($Path)
}

function Restore-All {
    for ($i = $script:BackupOrder.Count - 1; $i -ge 0; $i--) {
        $p = $script:BackupOrder[$i]
        [System.IO.File]::WriteAllBytes($p, $script:BackupBytes[$p])
    }
}

function Get-NotesLines {
    param([string]$NotesPath)
    if (-not $NotesPath) { return @() }
    if (-not (Test-Path -LiteralPath $NotesPath)) { throw "notes file not found: $NotesPath" }
    $t = [System.IO.File]::ReadAllText($NotesPath, [System.Text.Encoding]::UTF8)
    $t = $t.Replace("`r`n", "`n")
    if ($t.EndsWith("`n")) { $t = $t.Substring(0, $t.Length - 1) }
    if ($t -eq '') { return @() }
    return @($t -split "`n")
}

function Get-CurrentVersion {
    param([string]$RootPath)
    $verPath = Join-Path $RootPath 'VERSION'
    if (-not (Test-Path -LiteralPath $verPath)) { throw "missing VERSION in $RootPath" }
    $first = @([System.IO.File]::ReadAllLines($verPath, [System.Text.Encoding]::UTF8) | Select-Object -First 1)[0]
    if ($first -match 'VERSION\s+(\d+\.\d+\.\d+)') { return $matches[1] }
    throw 'VERSION has no x.y.z header'
}

function Test-ChangelogEntry {
    param([string]$RootPath, [string]$Ver)
    $verPath = Join-Path $RootPath 'VERSION'
    $text = [System.IO.File]::ReadAllText($verPath, [System.Text.Encoding]::UTF8)
    return [regex]::IsMatch($text, ('(?m)^\s*' + [regex]::Escape($Ver) + '\s{2,}'))
}

function Update-VersionFile {
    param([string]$RootPath, [string]$NewVersion, [string]$TitleText, [string[]]$BodyLines)
    $verPath = Join-Path $RootPath 'VERSION'
    $read = Read-TextWithBom -Path $verPath
    $text = $read.Text
    $nl = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }

    $text = [regex]::Replace($text, '\A[^\r\n]*', ('HARNESS-LIFECYCLE VERSION ' + $NewVersion))

    $hasEntry = [regex]::IsMatch($text, ('(?m)^\s*' + [regex]::Escape($NewVersion) + '\s{2,}'))
    if (-not $hasEntry) {
        $endsWithNl = $text.EndsWith("`n")
        $lines = New-Object System.Collections.Generic.List[string]
        foreach ($l in ($text -split "\r?\n")) { $lines.Add($l) }
        if ($endsWithNl -and $lines.Count -gt 0 -and $lines[$lines.Count - 1] -eq '') {
            $lines.RemoveAt($lines.Count - 1)
        }
        $dashIdx = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^-{6,}[ \t]*$') { $dashIdx = $i; break }
        }
        if ($dashIdx -lt 0) { throw 'VERSION has no changelog separator (-----) line' }
        $insertAt = $dashIdx + 1
        $newLines = @(($NewVersion + '  (' + $TitleText + ')'))
        if ($BodyLines -and $BodyLines.Count -gt 0) { $newLines += $BodyLines }
        $newLines += ''
        for ($i = 0; $i -lt $newLines.Count; $i++) {
            $lines.Insert($insertAt + $i, $newLines[$i])
        }
        $text = ($lines -join $nl)
        if ($endsWithNl) { $text += $nl }
    }

    if ($text -ne $read.Text) {
        Backup-File -Path $verPath
        Write-TextKeepBom -Path $verPath -Text $text -HasBom $read.HasBom
    }
}

function Update-DocsVersions {
    param([string]$RootPath, [string]$NewVersion, [string]$TitleText)
    $targets = @(
        (Join-Path $RootPath 'docs\usage-and-mechanism.html'),
        (Join-Path $RootPath 'docs\case-study\README.md'),
        (Join-Path $RootPath 'docs\case-study\README.en.md')
    )
    foreach ($p in $targets) {
        if (-not (Test-Path -LiteralPath $p)) { continue }
        $read = Read-TextWithBom -Path $p
        $text = $read.Text
        $name = [System.IO.Path]::GetFileName($p)
        if ($name -eq 'usage-and-mechanism.html') {
            $text = [regex]::Replace($text, 'v\d+\.\d+\.\d+', ('v' + $NewVersion))
        } elseif ($p -like '*README.en.md') {
            $text = [regex]::Replace($text, 'The package itself is now v\d+\.\d+\.\d+', ('The package itself is now v' + $NewVersion))
        } else {
            $text = [regex]::Replace($text, ([regex]::Escape($csCn) + '\s*v\d+\.\d+\.\d+'), ($csCn + ' v' + $NewVersion))
        }
        if ($text -ne $read.Text) {
            Backup-File -Path $p
            Write-TextKeepBom -Path $p -Text $text -HasBom $read.HasBom
        }
    }
}

function Get-Ps1Count {
    param([string]$RootPath)
    $n = 0
    foreach ($d in @('assets\scripts', 'assets\upgrade', 'tools', 'tests')) {
        $dp = Join-Path $RootPath $d
        if (-not (Test-Path -LiteralPath $dp)) { continue }
        $n += @(Get-ChildItem -LiteralPath $dp -Filter *.ps1 -File -Force).Count
    }
    return $n
}

function Get-ContractCount {
    param([string]$RootPath)
    $jsonPath = Join-Path $RootPath 'tools\package-contract.json'
    if (-not (Test-Path -LiteralPath $jsonPath)) { return 0 }
    $obj = (Get-Content -LiteralPath $jsonPath -Raw -Encoding UTF8) | ConvertFrom-Json
    if (-not $obj -or -not $obj.contracts) { return 0 }
    return @($obj.contracts).Count
}

function Get-SkillTotals {
    param([string]$RootPath)
    $skillsDir = Join-Path $RootPath 'assets\.harness\skills'
    $count = 0
    $total = 0
    if (Test-Path -LiteralPath $skillsDir) {
        $skillFiles = @(Get-ChildItem -LiteralPath $skillsDir -Recurse -Filter 'SKILL.md' -File -Force)
        $count = $skillFiles.Count
        foreach ($sf in $skillFiles) {
            $total += @([System.IO.File]::ReadAllLines($sf.FullName, [System.Text.Encoding]::UTF8)).Count
        }
    }
    return [pscustomobject]@{ Count = $count; Lines = $total }
}

function Sync-Counts {
    param([string]$RootPath)
    $ps1N = Get-Ps1Count -RootPath $RootPath
    $contractN = Get-ContractCount -RootPath $RootPath
    $skillTotals = Get-SkillTotals -RootPath $RootPath

    foreach ($doc in @('README.md', 'README.en.md')) {
        $docPath = Join-Path $RootPath $doc
        if (-not (Test-Path -LiteralPath $docPath)) { continue }
        $read = Read-TextWithBom -Path $docPath
        $text = $read.Text
        $text = [regex]::Replace($text, '(?<![\d])\d+ \.ps1 file\(s\) parse', ("$ps1N" + ' .ps1 file(s) parse'))
        if ($contractN -gt 0) {
            $text = [regex]::Replace(
                $text,
                '(\d+)(\s+)(rule/script/doc contract|cross-file contracts)',
                ([string]$contractN + '${2}' + '${3}'))
            $cnRepl = [string]$contractN + '${2}' + $tiao + '${3}' + $qiYue
            $text = [regex]::Replace(
                $text,
                ('(\d+)(\s*)' + $tiao + '(' + $kuaWenJian + ')?' + $qiYue),
                $cnRepl)
        }
        if ($text -ne $read.Text) {
            Backup-File -Path $docPath
            Write-TextKeepBom -Path $docPath -Text $text -HasBom $read.HasBom
        }
    }

    $qgPath = Join-Path (Join-Path $RootPath 'references') $qgName
    if ((Test-Path -LiteralPath $qgPath) -and $skillTotals.Count -gt 0) {
        $read = Read-TextWithBom -Path $qgPath
        $text = $read.Text
        $avg = [int][math]::Round($skillTotals.Lines / $skillTotals.Count)
        $canon = [string]$skillTotals.Count + ' ' + $ge + ' ' + $mid + ' ' + $gong + ' ' +
                 [string]$skillTotals.Lines + ' ' + $hang + ' ' + $mid + ' ' + $pingjun + ' ' +
                 [string]$avg + ' ' + $hang
        $pattern = '\d+\s*' + [regex]::Escape($ge) + '\s*' + [regex]::Escape($mid) + '\s*' +
                   [regex]::Escape($gong) + '\s*\d+\s*' + [regex]::Escape($hang) + '\s*' +
                   [regex]::Escape($mid) + '\s*' + [regex]::Escape($pingjun) + '\s*\d+\s*' +
                   [regex]::Escape($hang)
        $text = [regex]::Replace($text, $pattern, $canon)
        if ($text -ne $read.Text) {
            Backup-File -Path $qgPath
            Write-TextKeepBom -Path $qgPath -Text $text -HasBom $read.HasBom
        }
    }

    # The HTML hero chip quotes the contract count too.
    $htmlPath = Join-Path $RootPath 'docs\usage-and-mechanism.html'
    if ((Test-Path -LiteralPath $htmlPath) -and $contractN -gt 0) {
        $read = Read-TextWithBom -Path $htmlPath
        $text = $read.Text
        $chipPattern = '<b>\d+</b>\s*' + [regex]::Escape($tiao + $kuaWenJian + $qiYue)
        $chipRepl = '<b>' + [string]$contractN + '</b> ' + $tiao + $kuaWenJian + $qiYue
        $text = [regex]::Replace($text, $chipPattern, $chipRepl)
        if ($text -ne $read.Text) {
            Backup-File -Path $htmlPath
            Write-TextKeepBom -Path $htmlPath -Text $text -HasBom $read.HasBom
        }
    }
}

function Get-ReleaseFiles {
    param([string]$RootPath)
    $files = @(
        'VERSION',
        'releases.json',
        'README.md',
        'README.en.md',
        'docs/usage-and-mechanism.html',
        'docs/case-study/README.md',
        'docs/case-study/README.en.md',
        ('references/' + $qgName)
    )
    $out = @()
    foreach ($f in $files) {
        if (Test-Path -LiteralPath (Join-Path $RootPath ($f -replace '/', '\'))) { $out += $f }
    }
    return $out
}

function Write-CommitMessage {
    param([string]$NewVersion, [string]$TitleText, [string[]]$BodyLines, [string]$Path = '')
    $msgPath = if ($Path) { $Path } else {
        Join-Path ([System.IO.Path]::GetTempPath()) ('harness-release-' + $NewVersion + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.txt')
    }
    $header = $CommitType + '(' + $CommitScope + '): ' + $TitleText
    $content = $header + "`n"
    if ($BodyLines -and $BodyLines.Count -gt 0) {
        $content += "`n" + ($BodyLines -join "`n") + "`n"
    }
    [System.IO.File]::WriteAllText($msgPath, $content, (New-Object System.Text.UTF8Encoding($false)))
    return $msgPath
}

function Write-FailureLine {
    param([string]$Text)
    $hit = @($Text -split "\r?\n" | Where-Object { $_ -match '^\[FAIL\]' } | Select-Object -First 1)
    if ($hit.Count -gt 0) { Write-Host $hit[0] -ForegroundColor Red }
}

function Show-Plan {
    param([string]$RootPath, [string]$NewVersion, [string]$TitleText, [string]$CurrentVersion, [string]$MsgPath, [string]$BranchName)
    $rel = Get-ReleaseFiles -RootPath $RootPath
    Write-Host 'release plan' -ForegroundColor Cyan
    Write-Host ("  root:      " + $RootPath)
    Write-Host ("  branch:    " + $BranchName)
    Write-Host ("  version:   " + $CurrentVersion + ' -> ' + $NewVersion)
    Write-Host ("  title:     " + $TitleText)
    foreach ($f in $rel) { Write-Host ("  edit:      " + $f) }
    Write-Host '  then run:'
    Write-Host '    python tools\parse-changelog.py VERSION releases.json'
    if (-not $SkipVerify) { Write-Host '    powershell -File tools\verify-package.ps1' }
    if (-not $SkipTests)  { Write-Host '    powershell -File tests\run-all.ps1' }
    if (-not $SkipZip)    { Write-Host '    powershell -File tools\package-zip.ps1' }
    Write-Host ("  commit message file: " + $MsgPath)
    Write-Host '  after that:'
    Write-Host ("    git add " + (($rel -join ' ')))
    Write-Host ("    git commit -F " + $MsgPath)
    Write-Host ("    git tag v" + $NewVersion)
    Write-Host ('    git push origin ' + $BranchName)
    Write-Host ("    git push origin v" + $NewVersion)
    Write-Host ("    GITHUB_TOKEN=... python tools\publish-releases.py --from " + $NewVersion)
}

# --------------------------------------------------------------------- self test

function Assert-True {
    param([bool]$Condition, [string]$Message, $Failures)
    if (-not $Condition) {
        $Failures.Add($Message)
        Write-Host ("[FAIL] " + $Message) -ForegroundColor Red
    }
}

function Invoke-ReleaseSelfTest {
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('hb-release-selftest-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $scriptPath = $PSCommandPath
    if (-not $scriptPath) { $scriptPath = $MyInvocation.MyCommand.Path }
    $fails = New-Object System.Collections.Generic.List[string]
    $nl = "`n"

    try {
        New-Item -ItemType Directory -Force -Path $tmp | Out-Null

        # VERSION fixture
        $verText = 'HARNESS-LIFECYCLE VERSION 1.0.0' + $nl + $nl + 'changelog' + $nl + '---------' + $nl +
                   '1.0.0  (fixture baseline)' + $nl + '- baseline note' + $nl
        [System.IO.File]::WriteAllText((Join-Path $tmp 'VERSION'), $verText, (New-Object System.Text.UTF8Encoding($false)))

        # releases.json fixture (stale on purpose; regenerated by the script)
        $relJson = '[{"version":"1.0.0","title":"fixture baseline","body":["- baseline note"]}]'
        [System.IO.File]::WriteAllText((Join-Path $tmp 'releases.json'), $relJson, (New-Object System.Text.UTF8Encoding($false)))

        # README fixtures with stale counts (27 ps1 / 67 contracts)
        $readmeText = 'sample output' + $nl +
                      '[PASS] parse      27 .ps1 file(s) parse' + $nl +
                      '[PASS] contract   67 rule/script/doc contract(s) hold' + $nl +
                      'the package has 67 ' + $tiao + $qiYue + ' and more' + $nl
        [System.IO.File]::WriteAllText((Join-Path $tmp 'README.md'), $readmeText, (New-Object System.Text.UTF8Encoding($false)))
        $readmeEn = 'sample output' + $nl +
                    '[PASS] parse      27 .ps1 file(s) parse' + $nl +
                    '[PASS] contract   67 rule/script/doc contract(s) hold' + $nl +
                    'This repository has 67 cross-file contracts.' + $nl
        [System.IO.File]::WriteAllText((Join-Path $tmp 'README.en.md'), $readmeEn, (New-Object System.Text.UTF8Encoding($false)))

        # docs fixtures
        New-Item -ItemType Directory -Force -Path (Join-Path $tmp 'docs\case-study') | Out-Null
        $htmlText = '<div class="eyebrow">harness-lifecycle ' + $mid + ' v1.0.0</div>' + $nl +
                    'built from v1.0.0 code' + $nl
        [System.IO.File]::WriteAllText((Join-Path $tmp 'docs\usage-and-mechanism.html'), $htmlText, (New-Object System.Text.UTF8Encoding($false)))
        $csText = 'quote;' + $csCn + ' v1.0.0,' + $nl + 'record date v0.9.0 stays' + $nl
        [System.IO.File]::WriteAllText((Join-Path $tmp 'docs\case-study\README.md'), $csText, (New-Object System.Text.UTF8Encoding($false)))
        $csEn = 'quote; The package itself is now v1.0.0;' + $nl + 'record date v0.9.0 stays' + $nl
        [System.IO.File]::WriteAllText((Join-Path $tmp 'docs\case-study\README.en.md'), $csEn, (New-Object System.Text.UTF8Encoding($false)))

        # quality table fixture (stale totals)
        New-Item -ItemType Directory -Force -Path (Join-Path $tmp 'references') | Out-Null
        $qgText = '## 2. skills (25 ' + $ge + ' ' + $mid + ' ' + $gong + ' 100 ' + $hang + ' ' + $mid + ' ' + $pingjun + ' 50 ' + $hang + ')' + $nl
        [System.IO.File]::WriteAllText((Join-Path $tmp ('references\' + $qgName)), $qgText, (New-Object System.Text.UTF8Encoding($false)))

        # tools / scripts / skills fixtures
        New-Item -ItemType Directory -Force -Path (Join-Path $tmp 'tools') | Out-Null
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'parse-changelog.py') -Destination (Join-Path $tmp 'tools\parse-changelog.py')
        $contractJson = '{"contracts":[{"id":"a"},{"id":"b"},{"id":"c"}]}'
        [System.IO.File]::WriteAllText((Join-Path $tmp 'tools\package-contract.json'), $contractJson, (New-Object System.Text.UTF8Encoding($false)))

        New-Item -ItemType Directory -Force -Path (Join-Path $tmp 'assets\scripts') | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $tmp 'assets\scripts\a.ps1'), 'exit 0' + $nl, (New-Object System.Text.UTF8Encoding($false)))
        [System.IO.File]::WriteAllText((Join-Path $tmp 'assets\scripts\b.ps1'), 'exit 0' + $nl, (New-Object System.Text.UTF8Encoding($false)))
        New-Item -ItemType Directory -Force -Path (Join-Path $tmp 'tests') | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $tmp 'tests\c.ps1'), 'exit 0' + $nl, (New-Object System.Text.UTF8Encoding($false)))

        New-Item -ItemType Directory -Force -Path (Join-Path $tmp 'assets\.harness\skills\cat\skill-one') | Out-Null
        $skillBody = '# skill one' + $nl + 'line 2' + $nl + 'line 3' + $nl + 'line 4' + $nl + 'line 5' + $nl
        [System.IO.File]::WriteAllText((Join-Path $tmp 'assets\.harness\skills\cat\skill-one\SKILL.md'), $skillBody, (New-Object System.Text.UTF8Encoding($false)))

        # git fixture
        & git -C $tmp init -q | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'self test: git init failed' }
        & git -C $tmp config core.autocrlf false | Out-Null
        & git -C $tmp -c user.email=selftest@example.com -c user.name=selftest add . | Out-Null
        & git -C $tmp -c user.email=selftest@example.com -c user.name=selftest commit -q -m baseline | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'self test: git commit failed' }

        $notesPath = Join-Path $tmp 'notes.txt'
        [System.IO.File]::WriteAllText($notesPath, '- added line one' + $nl + '- added line two' + $nl, (New-Object System.Text.UTF8Encoding($false)))

        function Invoke-Child {
            param([string[]]$Extra)
            $childArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath, '-Root', $tmp, '-SkipVerify', '-SkipTests', '-SkipZip') + $Extra
            $out = & $PS @childArgs 2>&1 | Out-String
            return [pscustomobject]@{ Output = $out; Code = $LASTEXITCODE }
        }

        # run 1
        $msgPath = Join-Path $tmp ('commit-msg-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.txt')
        $run1 = Invoke-Child -Extra @('-Version', '2.0.0', '-Title', 'fixture release', '-Notes', $notesPath, '-AllowDirty', '-AllowBranch', '-CommitMessagePath', $msgPath)
        Assert-True ($run1.Code -eq 0) ('run 1 exited ' + $run1.Code + ': ' + ($run1.Output.Trim())) $fails

        $verAfter = [System.IO.File]::ReadAllText((Join-Path $tmp 'VERSION'), [System.Text.Encoding]::UTF8)
        $verLines = $verAfter -split "\r?\n"
        Assert-True ($verLines[0] -eq 'HARNESS-LIFECYCLE VERSION 2.0.0') ('VERSION header is: ' + $verLines[0]) $fails
        Assert-True ([regex]::IsMatch($verAfter, '(?m)^2\.0\.0\s{2,}\(fixture release\)$')) 'new changelog entry missing or malformed' $fails
        Assert-True ($verAfter.Contains('- added line one') -and $verAfter.Contains('- added line two')) 'notes not inserted into VERSION' $fails

        $rels = (Get-Content -LiteralPath (Join-Path $tmp 'releases.json') -Raw -Encoding UTF8) | ConvertFrom-Json
        Assert-True ($null -ne $rels) 'releases.json is not valid JSON' $fails
        $topVer = [string](@($rels) | Select-Object -First 1).version
        Assert-True ($topVer -eq '2.0.0') ('releases.json top version is ' + $topVer) $fails

        $htmlAfter = [System.IO.File]::ReadAllText((Join-Path $tmp 'docs\usage-and-mechanism.html'), [System.Text.Encoding]::UTF8)
        Assert-True ($htmlAfter.Contains('v2.0.0') -and -not $htmlAfter.Contains('v1.0.0')) 'HTML version marker not rewritten' $fails
        $csAfter = [System.IO.File]::ReadAllText((Join-Path $tmp 'docs\case-study\README.md'), [System.Text.Encoding]::UTF8)
        Assert-True ($csAfter.Contains($csCn + ' v2.0.0')) 'Chinese case-study version not rewritten' $fails
        Assert-True (-not $csAfter.Contains('v1.0.0')) 'Chinese case-study still says v1.0.0' $fails
        $csEnAfter = [System.IO.File]::ReadAllText((Join-Path $tmp 'docs\case-study\README.en.md'), [System.Text.Encoding]::UTF8)
        Assert-True ($csEnAfter.Contains('The package itself is now v2.0.0')) 'English case-study version not rewritten' $fails

        $readmeAfter = [System.IO.File]::ReadAllText((Join-Path $tmp 'README.md'), [System.Text.Encoding]::UTF8)
        Assert-True ($readmeAfter.Contains('3 .ps1 file(s) parse')) '.ps1 count not synced to 3' $fails
        Assert-True ($readmeAfter.Contains('3 rule/script/doc contract')) 'contract count not synced to 3' $fails
        Assert-True ($readmeAfter.Contains('3 ' + $tiao + $qiYue)) 'Chinese contract count not synced to 3' $fails
        $readmeEnAfter = [System.IO.File]::ReadAllText((Join-Path $tmp 'README.en.md'), [System.Text.Encoding]::UTF8)
        Assert-True ($readmeEnAfter.Contains('3 cross-file contracts')) 'English cross-file contract count not synced to 3' $fails

        $qgAfter = [System.IO.File]::ReadAllText((Join-Path $tmp ('references\' + $qgName)), [System.Text.Encoding]::UTF8)
        $expectQg = '1 ' + $ge + ' ' + $mid + ' ' + $gong + ' 5 ' + $hang + ' ' + $mid + ' ' + $pingjun + ' 5 ' + $hang
        Assert-True ($qgAfter.Contains($expectQg)) ('quality totals not synced; expected: ' + $expectQg) $fails

        Assert-True (Test-Path -LiteralPath $msgPath) 'commit message file not written' $fails
        if (Test-Path -LiteralPath $msgPath) {
            $msgBytes = [System.IO.File]::ReadAllBytes($msgPath)
            $hasBom = ($msgBytes.Length -ge 3 -and $msgBytes[0] -eq 0xEF -and $msgBytes[1] -eq 0xBB -and $msgBytes[2] -eq 0xBF)
            Assert-True (-not $hasBom) 'commit message file starts with a BOM' $fails
            $msgText = [System.IO.File]::ReadAllText($msgPath, [System.Text.Encoding]::UTF8)
            Assert-True ($msgText.StartsWith('chore(release): fixture release')) ('message header is: ' + ($msgText -split "`n")[0]) $fails
            Assert-True ($msgText.Contains('- added line one')) 'message body missing notes' $fails
        }

        # idempotency: snapshot then rerun the same version
        $snap = @{}
        foreach ($f in (Get-ReleaseFiles -RootPath $tmp)) {
            $snap[$f] = [System.IO.File]::ReadAllText((Join-Path $tmp ($f -replace '/', '\')), [System.Text.Encoding]::UTF8)
        }
        $run2 = Invoke-Child -Extra @('-Version', '2.0.0', '-Title', 'fixture release', '-Notes', $notesPath, '-AllowDirty', '-AllowBranch', '-CommitMessagePath', $msgPath)
        Assert-True ($run2.Code -eq 0) ('rerun exited ' + $run2.Code + ': ' + ($run2.Output.Trim())) $fails
        foreach ($f in $snap.Keys) {
            $now = [System.IO.File]::ReadAllText((Join-Path $tmp ($f -replace '/', '\')), [System.Text.Encoding]::UTF8)
            Assert-True ($now -eq $snap[$f]) ('rerun changed ' + $f + ' (not idempotent)') $fails
        }
        Assert-True ([regex]::Matches($verAfter, '(?m)^2\.0\.0\s{2,}').Count -ge 1) 'sanity: version entry missing' $fails
        $verNow = [System.IO.File]::ReadAllText((Join-Path $tmp 'VERSION'), [System.Text.Encoding]::UTF8)
        Assert-True ([regex]::Matches($verNow, '(?m)^2\.0\.0\s{2,}').Count -eq 1) 'duplicate version entry after rerun' $fails

        # dirty tree refusal: exit 1 and no file was touched
        [System.IO.File]::WriteAllText((Join-Path $tmp 'dirty.txt'), 'dirty' + $nl, (New-Object System.Text.UTF8Encoding($false)))
        $runDirty = Invoke-Child -Extra @('-Version', '2.0.1', '-Title', 'dirty probe', '-Notes', $notesPath)
        Assert-True ($runDirty.Code -eq 1) ('dirty run exited ' + $runDirty.Code + ' (expected 1)') $fails
        $verDirty = [System.IO.File]::ReadAllText((Join-Path $tmp 'VERSION'), [System.Text.Encoding]::UTF8)
        Assert-True ($verDirty -eq $verNow) 'dirty run modified VERSION before refusing' $fails
        Remove-Item -LiteralPath (Join-Path $tmp 'dirty.txt') -Force
    } catch {
        $fails.Add($_.Exception.Message)
        Write-Host ('[FAIL] ' + $_.Exception.Message) -ForegroundColor Red
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }

    if ($fails.Count -gt 0) {
        Write-Host ("RELEASE SELFTEST FAILED (" + $fails.Count + ' failure(s))') -ForegroundColor Red
        return 1
    }
    Write-Host 'RELEASE SELFTEST OK' -ForegroundColor Green
    return 0
}

if ($SelfTest) {
    exit (Invoke-ReleaseSelfTest)
}

# ------------------------------------------------------------------ validation

if (-not $Version) {
    Write-Host '[FAIL] -Version x.y.z is required' -ForegroundColor Red
    exit 1
}
if ($Version -notmatch '^\d+\.\d+\.\d+$') {
    Write-Host ("[FAIL] -Version must match x.y.z, got: " + $Version) -ForegroundColor Red
    exit 1
}
if (-not $Title) {
    Write-Host '[FAIL] -Title is required' -ForegroundColor Red
    exit 1
}

$bodyLines = @()
try {
    $bodyLines = @(Get-NotesLines -NotesPath $Notes)
} catch {
    Write-Host ('[FAIL] ' + $_.Exception.Message) -ForegroundColor Red
    exit 1
}

$currentVersion = ''
try {
    $currentVersion = Get-CurrentVersion -RootPath $Root
} catch {
    Write-Host ('[FAIL] ' + $_.Exception.Message) -ForegroundColor Red
    exit 1
}

if ($Version -eq $currentVersion) {
    if (-not (Test-ChangelogEntry -RootPath $Root -Ver $Version)) {
        Write-Host ("[FAIL] new version must differ from the current version " + $currentVersion) -ForegroundColor Red
        exit 1
    }
    Write-Host ("[WARN] releasing " + $Version + " again (entry already exists); resuming idempotently") -ForegroundColor Yellow
} elseif ([version]$Version -lt [version]$currentVersion) {
    Write-Host ("[WARN] " + $Version + " is lower than the current version " + $currentVersion) -ForegroundColor Yellow
}

# Dirty tree: refuse before any write. A dry run writes nothing, so it only warns.
$gitOut = & git -C $Root status --porcelain 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host ("[FAIL] git status failed in " + $Root) -ForegroundColor Red
    exit 1
}
$dirtyLines = @($gitOut | Where-Object { $_ -ne $null -and ([string]$_).Trim() -ne '' })
if ($dirtyLines.Count -gt 0) {
    if ($DryRun) {
        Write-Host '[WARN] working tree is dirty (ignored by -DryRun)' -ForegroundColor Yellow
    } elseif (-not $AllowDirty) {
        Write-Host '[FAIL] working tree is dirty; commit or pass -AllowDirty' -ForegroundColor Red
        exit 1
    }
}

# Branch check: a release commit must not land on a feature branch by accident.
$branchOut = & git -C $Root rev-parse --abbrev-ref HEAD 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host ('[FAIL] cannot read the current branch in ' + $Root) -ForegroundColor Red
    exit 1
}
$branch = ([string]($branchOut | Select-Object -First 1)).Trim()
if ($branch -ne 'main' -and -not $AllowBranch) {
    Write-Host ('[FAIL] release must run on main (current: ' + $branch + '); pass -AllowBranch to override') -ForegroundColor Red
    exit 1
}

# --------------------------------------------------------------------- dry run

$msgPathPreview = if ($CommitMessagePath) { $CommitMessagePath } else {
    Join-Path ([System.IO.Path]::GetTempPath()) ('harness-release-' + $Version + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.txt')
}
if ($DryRun) {
    Show-Plan -RootPath $Root -NewVersion $Version -TitleText $Title -CurrentVersion $currentVersion -MsgPath $msgPathPreview -BranchName $branch
    Write-Host 'dry run: nothing written' -ForegroundColor Green
    exit 0
}

# ------------------------------------------------------------------ apply phase

try {
    $relPath = Join-Path $Root 'releases.json'
    $verPath = Join-Path $Root 'VERSION'
    $htmlPath = Join-Path $Root 'docs\usage-and-mechanism.html'
    $csZhPath = Join-Path $Root 'docs\case-study\README.md'
    $csEnPath = Join-Path $Root 'docs\case-study\README.en.md'
    $readmePath = Join-Path $Root 'README.md'
    $readmeEnPath = Join-Path $Root 'README.en.md'
    $qgPath = Join-Path (Join-Path $Root 'references') $qgName

    foreach ($p in @($verPath, $relPath, $htmlPath, $csZhPath, $csEnPath, $readmePath, $readmeEnPath, $qgPath)) {
        if (Test-Path -LiteralPath $p) { Backup-File -Path $p }
    }

    Update-VersionFile -RootPath $Root -NewVersion $Version -TitleText $Title -BodyLines $bodyLines

    $pyExe = $null
    foreach ($candidate in @('python', 'python3')) {
        $cmd = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($cmd) { $pyExe = $cmd.Source; break }
    }
    if (-not $pyExe) { throw 'python is not available; cannot regenerate releases.json' }

    $parseScript = Join-Path $Root 'tools\parse-changelog.py'
    if (-not (Test-Path -LiteralPath $parseScript)) { throw ('missing ' + $parseScript) }
    $parseOut = & $pyExe $parseScript $verPath $relPath 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw ('parse-changelog.py failed: ' + $parseOut.Trim()) }
    $rels = (Get-Content -LiteralPath $relPath -Raw -Encoding UTF8) | ConvertFrom-Json
    $top = if ($rels -and @($rels).Count -gt 0) { [string](@($rels) | Select-Object -First 1).version } else { $null }
    if ($top -ne $Version) { throw ('releases.json top version is ' + $top + ', expected ' + $Version) }

    Update-DocsVersions -RootPath $Root -NewVersion $Version -TitleText $Title
    Sync-Counts -RootPath $Root

    if (-not $SkipVerify) {
        $vp = Join-Path $Root 'tools\verify-package.ps1'
        if (-not (Test-Path -LiteralPath $vp)) { throw ('missing ' + $vp) }
        Write-Host 'running tools\verify-package.ps1 ...' -ForegroundColor Cyan
        $vpOut = & $PS -NoProfile -ExecutionPolicy Bypass -File $vp 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
            Write-FailureLine -Text $vpOut
            throw ('tools\verify-package.ps1 failed (exit ' + $LASTEXITCODE + ')')
        }
        Write-Host 'verify-package: OPEN' -ForegroundColor Green
    }

    if (-not $SkipTests) {
        $runAll = Join-Path $Root 'tests\run-all.ps1'
        if (-not (Test-Path -LiteralPath $runAll)) { throw ('missing ' + $runAll) }
        Write-Host 'running tests\run-all.ps1 (full suite, this takes a while) ...' -ForegroundColor Cyan
        $testsOut = & $PS -NoProfile -ExecutionPolicy Bypass -File $runAll 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
            Write-FailureLine -Text $testsOut
            throw ('tests\run-all.ps1 failed (exit ' + $LASTEXITCODE + ')')
        }
        Write-Host 'run-all: ALL TESTS PASSED' -ForegroundColor Green
    }

    if (-not $SkipZip) {
        $zipScript = Join-Path $Root 'tools\package-zip.ps1'
        if (-not (Test-Path -LiteralPath $zipScript)) { throw ('missing ' + $zipScript) }
        Write-Host 'running tools\package-zip.ps1 ...' -ForegroundColor Cyan
        $zipOut = & $PS -NoProfile -ExecutionPolicy Bypass -File $zipScript 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
            Write-FailureLine -Text $zipOut
            throw ('tools\package-zip.ps1 failed (exit ' + $LASTEXITCODE + ')')
        }
        Write-Host $zipOut.Trim()
    }
} catch {
    Write-Host ('[FAIL] ' + $_.Exception.Message) -ForegroundColor Red
    Restore-All
    Write-Host 'release: ROLLED BACK' -ForegroundColor Yellow
    exit 1
}

# ------------------------------------------------------------- next steps / git

$msgPath = Write-CommitMessage -NewVersion $Version -TitleText $Title -BodyLines $bodyLines -Path $CommitMessagePath
$relFiles = @(Get-ReleaseFiles -RootPath $Root)

Write-Host ''
Write-Host 'release files updated; next commands:' -ForegroundColor Cyan
Write-Host ("  git add " + ($relFiles -join ' '))
Write-Host ("  git commit -F " + $msgPath)
Write-Host ("  git tag v" + $Version)
Write-Host ('  git push origin ' + $branch)
Write-Host ("  git push origin v" + $Version)
Write-Host ("  GITHUB_TOKEN=... python tools\publish-releases.py --from " + $Version)

if ($Commit) {
    Write-Host 'committing ...' -ForegroundColor Cyan
    $addOut = & git -C $Root add @relFiles 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        Write-Host ('[FAIL] git add failed: ' + $addOut.Trim()) -ForegroundColor Red
        exit 1
    }
    $commitOut = & git -C $Root commit -F $msgPath 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        Write-Host ('[FAIL] git commit failed: ' + $commitOut.Trim()) -ForegroundColor Red
        exit 1
    }
    Write-Host 'commit: OK (not pushed)' -ForegroundColor Green
}

if ($Tag) {
    # The tag must point at a commit that already contains the version bump.
    $headVerOut = & git -C $Root show 'HEAD:VERSION' 2>$null
    if ($LASTEXITCODE -ne 0 -or (([string](@($headVerOut) -join "`n")) -notmatch [regex]::Escape($Version))) {
        Write-Host ('[FAIL] HEAD:VERSION does not contain ' + $Version + '; commit the release files first (or pass -Commit)') -ForegroundColor Red
        exit 1
    }
    Write-Host ('tagging v' + $Version + ' ...') -ForegroundColor Cyan
    $tagOut = & git -C $Root tag ('v' + $Version) 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        Write-Host ('[FAIL] git tag failed: ' + $tagOut.Trim()) -ForegroundColor Red
        exit 1
    }
    Write-Host 'tag: OK (not pushed)' -ForegroundColor Green
}

if ($Publish) {
    # A Release for a tag that exists only locally makes GitHub create the tag
    # from the default branch HEAD, which may be older than this release. Refuse
    # until the pushed tag points at the release commit.
    $tagRef = 'refs/tags/v' + $Version
    $remoteOut = & git -C $Root ls-remote --tags origin $tagRef 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $remoteOut) {
        Write-Host ('[FAIL] remote tag ' + $tagRef + ' not found; push the commit and tag before -Publish') -ForegroundColor Red
        exit 1
    }
    $remoteSha = (([string](@($remoteOut)[0])) -split '\s+')[0]
    $headSha = ([string](& git -C $Root rev-parse HEAD)).Trim()
    if ($remoteSha -ne $headSha) {
        Write-Host ('[FAIL] remote tag ' + $tagRef + ' points to ' + $remoteSha + ', HEAD is ' + $headSha + '; push the release commit and tag first') -ForegroundColor Red
        exit 1
    }
    Write-Host 'publishing GitHub release ...' -ForegroundColor Cyan
    $publishScript = Join-Path $Root 'tools\publish-releases.py'
    if (-not (Test-Path -LiteralPath $publishScript)) {
        Write-Host ('[FAIL] missing ' + $publishScript) -ForegroundColor Red
        exit 1
    }
    $pyForPublish = $null
    foreach ($candidate in @('python', 'python3')) {
        $cmd = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($cmd) { $pyForPublish = $cmd.Source; break }
    }
    if (-not $pyForPublish) {
        Write-Host '[FAIL] python is not available; cannot publish' -ForegroundColor Red
        exit 1
    }
    $pubOut = & $pyForPublish $publishScript '--from' $Version 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        Write-Host ('[FAIL] publish failed (files are NOT rolled back): ' + $pubOut.Trim()) -ForegroundColor Red
        exit 1
    }
    Write-Host 'publish: OK' -ForegroundColor Green
}

Write-Host ''
Write-Host ('release ' + $Version + ': READY') -ForegroundColor Green
exit 0
