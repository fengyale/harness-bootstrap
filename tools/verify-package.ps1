<#
  verify-package.ps1 -- harness-bootstrap checks itself before every commit

  WHY
    This package installs gates into other projects but had no gate of its own.
    Without one, every audit was a full scan, the same drift was found again and
    again, and "the doc says X but the script does Y" stayed invisible. This is
    the self-hosting counterpart: the package obeys the rule it sells.

  CHECKS
    1. parse      every .ps1 under templates/scripts and tools parses (PS 5.1 parser)
    2. encoding   each .ps1 is pure ASCII, or carries a UTF-8 BOM (PS 5.1 rule)
    3. json       every JSON config parses as JSON
    3b. version  VERSION and releases.json agree on the top version
    4. structure  required files exist; must-not-exist files are absent
    5. contracts  the same rule is not written differently in two places
                  (patterns and forbidden phrases live in tools/package-contract.json)
    5b. docs      counts quoted in the READMEs, the quality table and the HTML
                  page still match the files on disk
    6. smoke      install the hooks into a temp copy, run stage 4, uninstall again
                  (skipped by -Fast; the pre-commit hook uses -Fast)

  WHY -Fast EXISTS
    The pre-commit hook must stay fast enough that nobody reaches for --no-verify.
    Static checks (1-5) catch the drift that caused most of the review loops;
    the behavioural smoke (6) runs manually and before a release.

  USAGE
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\verify-package.ps1 -Fast
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\verify-package.ps1

  EXIT CODE
    0 = all checks passed, 1 = at least one FAIL

  NOTE
    Pure ASCII on purpose (PS 5.1 reads a BOM-less .ps1 as ANSI). Chinese lives in
    tools/package-contract.json and other data files, which are read as UTF-8.
#>
[CmdletBinding()]
param(
    [switch]$Fast
)

$ErrorActionPreference = 'Stop'

$packageRoot = Split-Path -Parent $PSScriptRoot
$contractPath = Join-Path $PSScriptRoot 'package-contract.json'
$results = New-Object System.Collections.Generic.List[object]

function Add-Result {
    param([string]$Check, [string]$Status, [string]$Detail)
    $results.Add([pscustomobject]@{ Check = $Check; Status = $Status; Detail = $Detail })
}

$PS = if (Get-Command powershell -ErrorAction SilentlyContinue) { 'powershell' } else { 'pwsh' }

# --------------------------------------------------------------- 0 contract file
if (-not (Test-Path -LiteralPath $contractPath)) {
    Add-Result 'structure' 'FAIL' 'missing: tools\package-contract.json'
    $contract = $null
} else {
    try {
        $contract = (Get-Content -LiteralPath $contractPath -Raw -Encoding UTF8) | ConvertFrom-Json
    } catch {
        Add-Result 'json' 'FAIL' "tools\package-contract.json is not valid JSON: $($_.Exception.Message)"
        $contract = $null
    }
}

# ---------------------------------------------------------------- 1 parse
$scriptFiles = @()
foreach ($dir in @('templates\scripts', 'tools', 'tests')) {
    $dp = Join-Path $packageRoot $dir
    if (-not (Test-Path -LiteralPath $dp)) { continue }
    $scriptFiles += @(Get-ChildItem -LiteralPath $dp -Filter *.ps1 -File -Force)
}

$parseBad = 0
foreach ($f in $scriptFiles) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) {
        $first = @($errors)[0]
        Add-Result 'parse' 'FAIL' ("{0}:{1}: {2}" -f $f.Name, $first.Extent.StartLineNumber, $first.Message)
        $parseBad++
    }
}
if ($parseBad -eq 0) { Add-Result 'parse' 'PASS' "$($scriptFiles.Count) .ps1 file(s) parse" }

# ------------------------------------------------------------- 2 encoding
# PS 5.1 reads a .ps1 without a BOM as ANSI, so non-ASCII text in such a file is
# parsed as different bytes than the author saw. A BOM is the only legal way to
# carry non-ASCII in a .ps1; otherwise the file must be pure ASCII.
$encBad = 0
foreach ($f in $scriptFiles) {
    $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    if ($hasBom) { continue }
    $nonAscii = 0
    foreach ($b in $bytes) { if ($b -gt 127) { $nonAscii++ } }
    if ($nonAscii -gt 0) {
        Add-Result 'encoding' 'FAIL' "$($f.Name): $nonAscii non-ASCII byte(s) without a UTF-8 BOM"
        $encBad++
    }
}
if ($encBad -eq 0) { Add-Result 'encoding' 'PASS' 'ASCII without BOM, or UTF-8 with BOM' }

# ----------------------------------------------------------------- 3 json
$jsonFiles = @()
foreach ($dir in @('templates\scripts', 'tools')) {
    $dp = Join-Path $packageRoot $dir
    if (-not (Test-Path -LiteralPath $dp)) { continue }
    $jsonFiles += @(Get-ChildItem -LiteralPath $dp -Filter *.json -File -Force)
}
$jsonBad = 0
foreach ($f in $jsonFiles) {
    try {
        $null = (Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8) | ConvertFrom-Json
    } catch {
        Add-Result 'json' 'FAIL' "$($f.Name) is not valid JSON: $($_.Exception.Message)"
        $jsonBad++
    }
}
if ($jsonBad -eq 0) { Add-Result 'json' 'PASS' "$($jsonFiles.Count) JSON file(s) parse" }

# ------------------------------------------------------------- 3b version
# VERSION is the changelog source; releases.json is generated from it for the
# release tool. Two copies drift, so compare the top entries here instead of
# trusting a human to update both.
$verPath = Join-Path $packageRoot 'VERSION'
$relPath = Join-Path $packageRoot 'releases.json'
if ((Test-Path -LiteralPath $verPath) -and (Test-Path -LiteralPath $relPath)) {
    try {
        $verLine = @([System.IO.File]::ReadAllLines($verPath, [System.Text.Encoding]::UTF8) | Select-Object -First 1)[0]
        $ver = if ($verLine -match 'VERSION\s+(\d+\.\d+\.\d+)') { $matches[1] } else { $null }
        # Do not wrap in @(): PS 5.1 returns the JSON array as one Object[], and
        # @(...)[0] would then be the whole array (all versions joined by spaces).
        $rels = (Get-Content -LiteralPath $relPath -Raw -Encoding UTF8) | ConvertFrom-Json
        $top = if ($rels -and @($rels).Count -gt 0) { [string](@($rels) | Select-Object -First 1).version } else { $null }
        if (-not $ver) {
            Add-Result 'version' 'FAIL' 'VERSION has no x.y.z header'
        } elseif ($top -ne $ver) {
            Add-Result 'version' 'FAIL' "releases.json top version $top != VERSION $ver (run tools\parse-changelog.py)"
        } else {
            Add-Result 'version' 'PASS' "VERSION and releases.json both say $ver"
        }
    } catch {
        Add-Result 'version' 'FAIL' "cannot compare VERSION with releases.json: $($_.Exception.Message)"
    }
}

# ------------------------------------------------------------ 4 structure
if ($contract) {
    $miss = 0
    foreach ($rel in @($contract.requiredFiles)) {
        $full = Join-Path $packageRoot ($rel -replace '/', '\')
        if (-not (Test-Path -LiteralPath $full)) {
            Add-Result 'structure' 'FAIL' "missing: $rel"
            $miss++
        }
    }
    foreach ($rel in @($contract.mustNotExist)) {
        $full = Join-Path $packageRoot ($rel -replace '/', '\')
        if (Test-Path -LiteralPath $full) {
            Add-Result 'structure' 'FAIL' "must not ship: $rel"
            $miss++
        }
    }
    if ($miss -eq 0) { Add-Result 'structure' 'PASS' 'required files present, package-only files absent' }
}

# ------------------------------------------------------------ 5 contracts
# Each contract pins one sentence of the same rule to the files that carry it.
# Without this, a fix in the script leaves the doc describing the old behaviour,
# and the next agent follows the doc instead of the script.
if ($contract) {
    $contractBad = 0
    foreach ($c in @($contract.contracts)) {
        $full = Join-Path $packageRoot ([string]$c.file -replace '/', '\')
        if (-not (Test-Path -LiteralPath $full)) {
            Add-Result 'contract' 'FAIL' "$($c.id): missing $($c.file)"
            $contractBad++
            continue
        }
        $text = [System.IO.File]::ReadAllText($full, [System.Text.Encoding]::UTF8)
        $patterns = @()
        if ($c.pattern)  { $patterns = @($c.pattern) }
        if ($c.patterns) { $patterns = @($c.patterns) }
        # A typo in the key ("patern") used to make the entry pass silently:
        # every contract must assert something.
        if ($patterns.Count -eq 0 -and -not $c.forbid) {
            Add-Result 'contract' 'FAIL' "$($c.id): entry has no pattern/patterns/forbid"
            $contractBad++
            continue
        }
        foreach ($p in $patterns) {
            if (-not [regex]::IsMatch($text, [string]$p)) {
                Add-Result 'contract' 'FAIL' "$($c.id): $($c.file) no longer matches the contract"
                $contractBad++
            }
        }
        if ($c.forbid -and [regex]::IsMatch($text, [string]$c.forbid)) {
            Add-Result 'contract' 'FAIL' "$($c.id): $($c.file) still contains the retired wording"
            $contractBad++
        }
    }
    # The READMEs quote the count in the sample output; adding a contract without
    # updating them is exactly the drift this package exists to prevent.
    $contractN = @($contract.contracts).Count
    $repoRoot = Split-Path $PSScriptRoot -Parent
    foreach ($doc in @('README.md', 'README.en.md')) {
        $docPath = Join-Path $repoRoot $doc
        if (-not (Test-Path -LiteralPath $docPath)) { continue }
        $docText = Get-Content -LiteralPath $docPath -Raw -Encoding UTF8
        if ($docText -notmatch ("{0} rule/script/doc contract" -f $contractN)) {
            Add-Result 'contract' 'FAIL' "$doc quotes a stale contract count; expected '$contractN rule/script/doc contract(s)'"
            $contractBad++
        }
    }
    if ($contractBad -eq 0) { Add-Result 'contract' 'PASS' "$contractN rule/script/doc contract(s) hold" }
}

# ---------------------------------------------------------------- 5b docs
# Counts quoted in README.md, README.en.md, the quality table and the HTML
# page are derived from files on disk. Updating them by hand is what let
# "21 .ps1" and "26 contracts" survive several releases, so assert them.
# Non-ASCII file names and phrases are built from code points: this script must
# stay pure ASCII for PS 5.1.
$docsBad = 0
$repoRoot = Split-Path $PSScriptRoot -Parent
$ps1N = $scriptFiles.Count
$contractTotal = if ($contract) { @($contract.contracts).Count } else { 0 }
# Chinese phrases used by the assertions below, built from code points.
$tiao = [string][char]0x6761
$kuaWenJian = -join ([char]0x8DE8, [char]0x6587, [char]0x4EF6)
$qiYue = -join ([char]0x5951, [char]0x7EA6)

foreach ($doc in @('README.md', 'README.en.md')) {
    $docPath = Join-Path $repoRoot $doc
    if (-not (Test-Path -LiteralPath $docPath)) { continue }
    $docText = Get-Content -LiteralPath $docPath -Raw -Encoding UTF8
    if ($docText -notmatch ('(?<![\d]){0} \.ps1 file\(s\) parse' -f $ps1N)) {
        Add-Result 'docs' 'FAIL' "$doc quotes a stale .ps1 count; expected '$ps1N .ps1 file(s) parse'"
        $docsBad++
    }
    if ($contractTotal -gt 0) {
        foreach ($m in [regex]::Matches($docText, '(\d+)\s+(?:rule/script/doc contract|cross-file contracts)')) {
            if ([int]$m.Groups[1].Value -ne $contractTotal) {
                Add-Result 'docs' 'FAIL' "$doc says '$($m.Value)' but the package has $contractTotal contracts"
                $docsBad++
            }
        }
        # Chinese wording for the count, built from the code points above.
        $cnPattern = '(\d+)\s*' + $tiao + '(' + $kuaWenJian + ')?' + $qiYue
        foreach ($m in [regex]::Matches($docText, $cnPattern)) {
            if ([int]$m.Groups[1].Value -ne $contractTotal) {
                Add-Result 'docs' 'FAIL' "$doc says '$($m.Value)' but the package has $contractTotal contracts"
                $docsBad++
            }
        }
    }
}

# Quality table: skill totals plus one entry per shipped gate script.
$qgName = (-join ([char]0x8D28, [char]0x91CF, [char]0x5206, [char]0x7EA7)) + '.md'
$qgPath = Join-Path (Join-Path $repoRoot 'references') $qgName
if (Test-Path -LiteralPath $qgPath) {
    $qgText = Get-Content -LiteralPath $qgPath -Raw -Encoding UTF8
    $skillFiles = @(Get-ChildItem -LiteralPath (Join-Path $packageRoot 'templates\.harness\skills') -Recurse -Filter 'SKILL.md' -File -Force)
    $skillLines = 0
    foreach ($sf in $skillFiles) { $skillLines += ([System.IO.File]::ReadAllLines($sf.FullName)).Count }
    $ge = [string][char]0x4E2A
    $gong = [string][char]0x5171
    $hang = [string][char]0x884C
    $mid = [string][char]0x00B7
    $expect = "$($skillFiles.Count) $ge $mid $gong $skillLines $hang"
    if ($qgText -notmatch [regex]::Escape($expect)) {
        Add-Result 'docs' 'FAIL' "references\$qgName quotes stale skill totals; expected '$expect'"
        $docsBad++
    }
    foreach ($sf in @(Get-ChildItem -LiteralPath (Join-Path $packageRoot 'templates\scripts') -File -Force)) {
        if ($sf.Extension -notin @('.ps1', '.py')) { continue }
        $base = [System.IO.Path]::GetFileNameWithoutExtension($sf.Name)
        if ($qgText -notmatch [regex]::Escape('`scripts/' + $base)) {
            Add-Result 'docs' 'FAIL' "references\$qgName has no row for scripts\$($sf.Name)"
            $docsBad++
        }
    }
}

# HTML page: every version string must be the current VERSION.
$htmlPath = Join-Path (Join-Path $repoRoot 'docs') 'usage-and-mechanism.html'
if (Test-Path -LiteralPath $htmlPath) {
    $verNow = ''
    if (Test-Path -LiteralPath $verPath) {
        $first = @([System.IO.File]::ReadAllLines($verPath, [System.Text.Encoding]::UTF8) | Select-Object -First 1)[0]
        if ($first -match 'VERSION\s+(\d+\.\d+\.\d+)') { $verNow = $matches[1] }
    }
    if ($verNow) {
        $html = Get-Content -LiteralPath $htmlPath -Raw -Encoding UTF8
        $versionHits = @([regex]::Matches($html, 'v(\d+\.\d+\.\d+)'))
        if ($versionHits.Count -eq 0) {
            Add-Result 'docs' 'FAIL' 'docs\usage-and-mechanism.html has no version marker'
            $docsBad++
        }
        foreach ($h in $versionHits) {
            if ($h.Groups[1].Value -ne $verNow) {
                Add-Result 'docs' 'FAIL' "docs\usage-and-mechanism.html says $($h.Value); expected v$verNow"
                $docsBad++
                break
            }
        }
        if ($contractTotal -gt 0) {
            # The hero chip "<b>52</b> ... " quotes the contract count; the version
            # check alone let a stale "26" survive there.
            $chipPattern = '<b>(\d+)</b>\s*' + $tiao + $kuaWenJian + $qiYue
            $chips = @([regex]::Matches($html, $chipPattern))
            if ($chips.Count -eq 0) {
                Add-Result 'docs' 'FAIL' 'docs\usage-and-mechanism.html has no contract-count chip'
                $docsBad++
            }
            foreach ($c in $chips) {
                if ([int]$c.Groups[1].Value -ne $contractTotal) {
                    Add-Result 'docs' 'FAIL' "docs\usage-and-mechanism.html chip says $($c.Groups[1].Value) contracts; expected $contractTotal"
                    $docsBad++
                }
            }
        }
    }
}

if ($docsBad -eq 0) {
    Add-Result 'docs' 'PASS' 'README counts, reference numbers and page version match the files'
}

# --------------------------------------------------------------- 6 smoke
if (-not $Fast) {
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('hb-self-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $smokeBad = 0
    try {
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $packageRoot 'templates\scripts') -Destination (Join-Path $tmp 'scripts') -Recurse
        New-Item -ItemType Directory -Force -Path (Join-Path $tmp '.harness\metrics') | Out-Null
        $ts = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        $line = '{"event":"scan","ts":"' + $ts + '","blocked":0,"files":1,"hunks":1}'
        Set-Content -LiteralPath (Join-Path $tmp '.harness\metrics\gate.jsonl') -Value $line -Encoding UTF8

        & git -C $tmp init -q | Out-Null
        if ($LASTEXITCODE -ne 0) { Add-Result 'smoke' 'FAIL' 'git init failed'; $smokeBad++ }

        if ($smokeBad -eq 0) {
            & $PS -NoProfile -ExecutionPolicy Bypass -File (Join-Path $tmp 'scripts\install-git-hooks.ps1') -Root $tmp | Out-Null
            if ($LASTEXITCODE -ne 0) { Add-Result 'smoke' 'FAIL' 'install-git-hooks.ps1 failed'; $smokeBad++ }
            foreach ($h in @('pre-commit', 'post-commit', 'pre-merge-commit')) {
                if (-not (Test-Path -LiteralPath (Join-Path $tmp ('.git\hooks\' + $h)))) {
                    Add-Result 'smoke' 'FAIL' "hook not installed: $h"
                    $smokeBad++
                }
            }
        }

        if ($smokeBad -eq 0) {
            & $PS -NoProfile -ExecutionPolicy Bypass -File (Join-Path $tmp 'scripts\stage-gate.ps1') -Root $tmp -Stage 4 | Out-Null
            if ($LASTEXITCODE -ne 0) { Add-Result 'smoke' 'FAIL' 'stage-gate -Stage 4 is not OPEN with both hooks installed'; $smokeBad++ }
        }

        # Negative probe: the untouched summary template must be REJECTED. The
        # earlier smoke only proved a happy path, so a broken check-summary could
        # still pass the package gate.
        if ($smokeBad -eq 0) {
            New-Item -ItemType Directory -Force -Path (Join-Path $tmp '.harness\changes\demo') | Out-Null
            Copy-Item -LiteralPath (Join-Path $packageRoot 'templates\.harness\changes\_template\summary.md') -Destination (Join-Path $tmp '.harness\changes\demo\summary.md')
            & $PS -NoProfile -ExecutionPolicy Bypass -File (Join-Path $tmp 'scripts\check-summary.ps1') -Root $tmp -Feature demo -Stage initial | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Add-Result 'smoke' 'FAIL' 'check-summary accepted the unfilled summary template'
                $smokeBad++
            }
        }

        # Negative probe: sqlGate=true + a SQL rule with no gate runtime must be
        # a FAIL. This is the fail-open that used to leave the SQL gate silently
        # disabled when the script was deleted.
        if ($smokeBad -eq 0) {
            New-Item -ItemType Directory -Force -Path (Join-Path $tmp '.harness\rules') | Out-Null
            # ASCII file name: this script is pure ASCII by design (PS 5.1 rule);
            # the hook/verify matcher only needs the "SQL*.md" prefix.
            Set-Content -LiteralPath (Join-Path $tmp '.harness\rules\SQL-review.md') -Value @(
                '# SQL review',
                '',
                '- evaluate tables',
                '- estimate rows',
                '- check the access path'
            ) -Encoding UTF8
            Remove-Item -LiteralPath (Join-Path $tmp 'scripts\sql-review-gate.ps1') -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath (Join-Path $tmp 'scripts\sql-review-gate.py') -Force -ErrorAction SilentlyContinue
            $sqlOut = & $PS -NoProfile -ExecutionPolicy Bypass -File (Join-Path $tmp 'scripts\verify-harness.ps1') -Root $tmp 2>&1 | Out-String
            if ($LASTEXITCODE -eq 0 -or $sqlOut -notmatch '\[FAIL\]\s+sql-gate') {
                Add-Result 'smoke' 'FAIL' 'verify-harness did not FAIL sql-gate when the gate runtime was missing'
                $smokeBad++
            }
        }

        # Negative probe: a hollow gate (0 bytes) must not pass the runnability
        # check just because PowerShell can execute an empty script.
        if ($smokeBad -eq 0) {
            Set-Content -LiteralPath (Join-Path $tmp 'scripts\sql-review-gate.ps1') -Value '' -Encoding ASCII
            $hollowOut = & $PS -NoProfile -ExecutionPolicy Bypass -File (Join-Path $tmp 'scripts\verify-harness.ps1') -Root $tmp 2>&1 | Out-String
            if ($LASTEXITCODE -eq 0 -or $hollowOut -notmatch '\[FAIL\]\s+sql-gate') {
                Add-Result 'smoke' 'FAIL' 'verify-harness accepted an empty sql-review-gate.ps1'
                $smokeBad++
            }
        }

        # Negative probe: a no-op gate with a sql_review comment passes the
        # content check but lets SQL through. The positive probe must catch it.
        if ($smokeBad -eq 0) {
            $noop = '# sql_review' + ("`n# padding line" * 200)
            Set-Content -LiteralPath (Join-Path $tmp 'scripts\sql-review-gate.ps1') -Value $noop -Encoding ASCII
            $noopOut = & $PS -NoProfile -ExecutionPolicy Bypass -File (Join-Path $tmp 'scripts\verify-harness.ps1') -Root $tmp 2>&1 | Out-String
            if ($LASTEXITCODE -eq 0 -or $noopOut -notmatch '\[FAIL\]\s+sql-gate') {
                Add-Result 'smoke' 'FAIL' 'verify-harness accepted a no-op sql-review-gate.ps1'
                $smokeBad++
            }
        }

        if ($smokeBad -eq 0) {
            & $PS -NoProfile -ExecutionPolicy Bypass -File (Join-Path $tmp 'scripts\uninstall-harness.ps1') -Root $tmp | Out-Null
            if ($LASTEXITCODE -ne 0) { Add-Result 'smoke' 'FAIL' 'uninstall-harness.ps1 failed'; $smokeBad++ }
            foreach ($h in @('pre-commit', 'post-commit', 'pre-merge-commit')) {
                if (Test-Path -LiteralPath (Join-Path $tmp ('.git\hooks\' + $h))) {
                    Add-Result 'smoke' 'FAIL' "hook not removed: $h"
                    $smokeBad++
                }
            }
        }

        if ($smokeBad -eq 0) { Add-Result 'smoke' 'PASS' 'install -> stage 4 -> unfilled summary rejected -> SQL missing/hollow/no-op probes -> uninstall, in a temp copy' }
    } catch {
        Add-Result 'smoke' 'FAIL' $_.Exception.Message
        $smokeBad++
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
} else {
    Add-Result 'smoke' 'SKIP' 'behavioural smoke skipped by -Fast (run without -Fast before a release)'
}

# --------------------------------------------------------------------- report
$fail = 0
foreach ($r in $results) {
    $color = switch ($r.Status) {
        'PASS' { 'Green' }
        'SKIP' { 'Yellow' }
        default { 'Red' }
    }
    Write-Host ("[{0}] {1,-10} {2}" -f $r.Status, $r.Check, $r.Detail) -ForegroundColor $color
    if ($r.Status -eq 'FAIL') { $fail++ }
}

Write-Host ""
if ($fail -gt 0) {
    Write-Host "package gate: BLOCKED ($fail fail(s))" -ForegroundColor Red
    exit 1
}
Write-Host 'package gate: OPEN' -ForegroundColor Green
exit 0
