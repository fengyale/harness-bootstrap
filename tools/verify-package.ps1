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
    4. structure  required files exist; must-not-exist files are absent
    5. contracts  the same rule is not written differently in two places
                  (patterns and forbidden phrases live in tools/package-contract.json)
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
    if ($contractBad -eq 0) { Add-Result 'contract' 'PASS' "$(@($contract.contracts).Count) rule/script/doc contract(s) hold" }
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

        if ($smokeBad -eq 0) { Add-Result 'smoke' 'PASS' 'install -> stage 4 -> unfilled summary rejected -> uninstall, in a temp copy' }
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
