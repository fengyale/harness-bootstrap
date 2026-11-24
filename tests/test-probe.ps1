<#
  test-probe.ps1 -- behaviour of assets\scripts\probe-project.ps1 draft facts

  Builds a throw-away Java-ish project under %TEMP% and asserts the five draft
  fact classes (entities / controllers / topics / cache keys / tables) are
  extracted, that mappings and table names are exact, that the JSON parses, that
  the 60-per-class cap flips truncated and keeps 60 rows, that an empty tree
  yields empty arrays instead of an error, and that -Out may point outside the
  project root.

  Pure ASCII; never writes into this repository.
#>
param([string]$TestRoot = '')
$ErrorActionPreference = 'Stop'
if (-not $TestRoot) {
    $TestRoot = Join-Path $env:TEMP ('hb-tests-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '\test-probe')
}
if (Test-Path -LiteralPath $TestRoot) { Remove-Item -LiteralPath $TestRoot -Recurse -Force }

$script = Join-Path (Split-Path $PSScriptRoot -Parent) 'assets\scripts\probe-project.ps1'
$proj   = Join-Path $TestRoot 'proj'
$empty  = Join-Path $TestRoot 'empty'
$absOut = Join-Path $TestRoot 'out'
$fail = 0

function Check {
    param([string]$Name, [bool]$Ok)
    if ($Ok) {
        Write-Host "ok: $Name"
    } else {
        Write-Host "BAD: $Name" -ForegroundColor Red
        $script:fail++
    }
}
function Put-File {
    param([string]$Path, [string[]]$Lines)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [System.IO.File]::WriteAllLines($Path, $Lines, (New-Object System.Text.UTF8Encoding($false)))
}
function Run-Probe {
    param([string]$TargetRoot, [string]$OutArg)
    $text = & powershell -NoProfile -ExecutionPolicy Bypass -File $script -Root $TargetRoot -Out $OutArg 2>&1 | Out-String
    return [pscustomobject]@{ Code = $LASTEXITCODE; Text = $text }
}
function Read-Facts {
    param([string]$Path)
    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8) | ConvertFrom-Json
}

try {
    # ------------------------------------------------------------ fixture
    $java = Join-Path $proj 'src\main\java\com\demo'
    Put-File (Join-Path $java 'model\entity\CartEntity.java') @(
        'package com.demo.model.entity;',
        'public class CartEntity { public Long id; }'
    )
    Put-File (Join-Path $java 'model\entity\OrderEntity.java') @(
        'package com.demo.model.entity;',
        'public class OrderEntity { public Long id; }'
    )
    Put-File (Join-Path $java 'controller\CartController.java') @(
        'package com.demo.controller;',
        'import org.springframework.web.bind.annotation.*;',
        '@RestController',
        '@RequestMapping("/api/v1/cart")',
        'public class CartController {',
        '    @GetMapping("/items")',
        '    public String items() { return "ok"; }',
        '}'
    )
    Put-File (Join-Path $java 'mq\OrderConsumer.java') @(
        'package com.demo.mq;',
        'import org.springframework.kafka.annotation.KafkaListener;',
        'public class OrderConsumer {',
        '    @KafkaListener(topic = "demo-order-created")',
        '    public void onMessage(String payload) { }',
        '}'
    )
    Put-File (Join-Path $java 'cache\CartCacheService.java') @(
        'package com.demo.cache;',
        'public class CartCacheService {',
        '    private static final String CART_KEY = "demo:cart:{userId}";',
        '}'
    )
    Put-File (Join-Path $proj 'db\schema.sql') @(
        'CREATE TABLE IF NOT EXISTS demo_cart (',
        '    id BIGINT PRIMARY KEY,',
        '    user_id BIGINT NOT NULL',
        ');'
    )

    # ------------------------------------------------------------ main run
    Write-Host '=== five fact classes ===' -ForegroundColor Cyan
    $r = Run-Probe -TargetRoot $proj -OutArg 'baseline'
    Check 'probe exits 0' ($r.Code -eq 0)
    $factsPath = Join-Path $proj 'baseline\probe-facts.json'
    Check 'probe-facts.json is written next to baseline.json' (Test-Path -LiteralPath $factsPath)

    $facts = $null
    try { $facts = Read-Facts $factsPath } catch { }
    Check 'probe-facts.json parses' ($null -ne $facts)
    if ($facts) {
        Check 'entities has 2 rows' (@($facts.entities).Count -eq 2)
        $entityNames = @($facts.entities | ForEach-Object { $_.name })
        Check 'CartEntity captured' ($entityNames -contains 'CartEntity')
        Check 'OrderEntity captured' ($entityNames -contains 'OrderEntity')

        Check 'controllers has 1 row' (@($facts.controllers).Count -eq 1)
        Check 'controller name captured' (@($facts.controllers)[0].name -eq 'CartController')
        Check 'controller mapping is the class mapping' (@($facts.controllers)[0].mapping -eq '/api/v1/cart')

        Check 'topics has 1 row' (@($facts.topics).Count -eq 1)
        Check 'topic value captured' (@($facts.topics)[0].topic -eq 'demo-order-created')

        Check 'cacheKeys has 1 row' (@($facts.cacheKeys).Count -eq 1)
        Check 'cache key keeps its colon' (@($facts.cacheKeys)[0].key -eq 'demo:cart:{userId}')

        Check 'tables has 1 row' (@($facts.tables).Count -eq 1)
        Check 'table name captured' (@($facts.tables)[0].table -eq 'demo_cart')

        Check 'truncated is false on a small tree' ($facts.truncated -eq $false)
        Check 'paths use forward slashes only' (
            ($facts.entities[0].path -notmatch '\\') -and ($facts.tables[0].path -notmatch '\\'))
    }

    $baselinePath = Join-Path $proj 'baseline\baseline.json'
    $baseline = (Get-Content -LiteralPath $baselinePath -Raw -Encoding UTF8) | ConvertFrom-Json
    $notes = @($baseline.notes) -join "`n"
    Check 'baseline notes count the draft facts' ($notes -match 'probe-facts: 2 entities / 1 controllers / 1 topics / 1 keys / 1 tables')
    Check 'baseline notes name the draft file' ($notes -match 'baseline/probe-facts\.json')

    # ------------------------------------------------------- truncation run
    Write-Host '=== 60-per-class cap ===' -ForegroundColor Cyan
    for ($i = 1; $i -le 65; $i++) {
        $n = $i.ToString('00')
        Put-File (Join-Path $java ("model\entity\Bulk${n}Entity.java")) @(
            'package com.demo.model.entity;',
            "public class Bulk${n}Entity { }"
        )
    }
    $r = Run-Probe -TargetRoot $proj -OutArg 'baseline'
    Check 'probe still exits 0 with many entities' ($r.Code -eq 0)
    $facts = Read-Facts (Join-Path $proj 'baseline\probe-facts.json')
    Check 'truncated is true past 60 entities' ($facts.truncated -eq $true)
    Check 'entities are capped at 60' (@($facts.entities).Count -eq 60)

    # ------------------------------------------------ empty tree + abs -Out
    Write-Host '=== empty tree, -Out outside the root ===' -ForegroundColor Cyan
    New-Item -ItemType Directory -Force -Path $empty | Out-Null
    $r = Run-Probe -TargetRoot $empty -OutArg $absOut
    Check 'empty tree exits 0' ($r.Code -eq 0)
    Check 'absolute -Out receives baseline.json' (Test-Path -LiteralPath (Join-Path $absOut 'baseline.json'))
    $factsEmpty = $null
    try { $factsEmpty = Read-Facts (Join-Path $absOut 'probe-facts.json') } catch { }
    Check 'absolute -Out receives probe-facts.json' ($null -ne $factsEmpty)
    if ($factsEmpty) {
        Check 'empty tree: entities is empty' (@($factsEmpty.entities).Count -eq 0)
        Check 'empty tree: controllers is empty' (@($factsEmpty.controllers).Count -eq 0)
        Check 'empty tree: topics is empty' (@($factsEmpty.topics).Count -eq 0)
        Check 'empty tree: cacheKeys is empty' (@($factsEmpty.cacheKeys).Count -eq 0)
        Check 'empty tree: tables is empty' (@($factsEmpty.tables).Count -eq 0)
        Check 'empty tree: not truncated' ($factsEmpty.truncated -eq $false)
    }
    Write-Host '=== a second run does not count its own output ===' -ForegroundColor Cyan
    # The draft and the baseline land in the repository. If that directory is not
    # skipped, run two reports .json files as project content and the extension
    # histogram (plus codeExists) drifts on every run.
    $first = Read-Facts (Join-Path $proj 'baseline\probe-facts.json')
    $firstJson = (Get-Content -LiteralPath (Join-Path $proj 'baseline\baseline.json') -Raw -Encoding UTF8) | ConvertFrom-Json
    $null = Run-Probe -TargetRoot $proj -OutArg 'baseline'
    $second = Read-Facts (Join-Path $proj 'baseline\probe-facts.json')
    $secondJson = (Get-Content -LiteralPath (Join-Path $proj 'baseline\baseline.json') -Raw -Encoding UTF8) | ConvertFrom-Json
    Check 'second run keeps the entity count' (@($second.entities).Count -eq @($first.entities).Count)
    $ext1 = @($firstJson.fileTypes | ForEach-Object { $_.ext })
    $ext2 = @($secondJson.fileTypes | ForEach-Object { $_.ext })
    Check 'second run adds no .json from its own draft' (-not ($ext2 -contains '.json'))
    Check 'extension histogram is stable' (((@($ext1 | Sort-Object) -join ',')) -eq ((@($ext2 | Sort-Object) -join ',')))

} finally {
    if (Test-Path -LiteralPath $TestRoot) { Remove-Item -LiteralPath $TestRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host '=== release.ps1 self test ===' -ForegroundColor Cyan
$relScript = Join-Path (Split-Path $PSScriptRoot -Parent) 'tools\release.ps1'
$relOut = & powershell -NoProfile -ExecutionPolicy Bypass -File $relScript -SelfTest 2>&1 | Out-String
Check 'release.ps1 self test exits 0' ($LASTEXITCODE -eq 0)
Check 'release.ps1 self test reports OK' ($relOut -match 'RELEASE SELFTEST OK')

Write-Host '=== suggest-flow.ps1 self test ===' -ForegroundColor Cyan
$sfScript = Join-Path (Split-Path $PSScriptRoot -Parent) 'assets\scripts\suggest-flow.ps1'
$sfOut = & powershell -NoProfile -ExecutionPolicy Bypass -File $sfScript -SelfTest 2>&1 | Out-String
Check 'suggest-flow.ps1 self test exits 0' ($LASTEXITCODE -eq 0)
Check 'suggest-flow.ps1 self test reports OK' ($sfOut -match 'SUGGEST-FLOW SELFTEST OK')

Write-Host '=== harness-plan.ps1 self test ===' -ForegroundColor Cyan
$hpScript = Join-Path (Split-Path $PSScriptRoot -Parent) 'assets\scripts\harness-plan.ps1'
$hpOut = & powershell -NoProfile -ExecutionPolicy Bypass -File $hpScript -SelfTest 2>&1 | Out-String
Check 'harness-plan.ps1 self test exits 0' ($LASTEXITCODE -eq 0)
Check 'harness-plan.ps1 self test reports OK' ($hpOut -match 'PLAN SELFTEST OK')

Write-Host '=== harness-start.ps1 self test ===' -ForegroundColor Cyan
$hsScript = Join-Path (Split-Path $PSScriptRoot -Parent) 'assets\scripts\harness-start.ps1'
$hsOut = & powershell -NoProfile -ExecutionPolicy Bypass -File $hsScript -SelfTest 2>&1 | Out-String
Check 'harness-start.ps1 self test exits 0' ($LASTEXITCODE -eq 0)
Check 'harness-start.ps1 self test reports OK' ($hsOut -match 'START SELFTEST OK')

Write-Host '=== check-task-start.ps1 gate ===' -ForegroundColor Cyan
$ctsScript = Join-Path (Split-Path $PSScriptRoot -Parent) 'assets\scripts\check-task-start.ps1'
$ctsRoot = Join-Path $env:TEMP ('hb-cts-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$ctsNoGit = Join-Path $env:TEMP ('hb-cts-nogit-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$ctsUtf8 = New-Object System.Text.UTF8Encoding($false)
function Invoke-Cts {
    param([string]$TargetRoot, [string[]]$ExtraArgs)
    # Not $args: that is an automatic variable.
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ctsScript, '-Root', $TargetRoot) + $ExtraArgs
    $out = & powershell @argList | Out-String
    return [pscustomobject]@{ Code = $LASTEXITCODE; Text = $out }
}
try {
    New-Item -ItemType Directory -Force -Path (Join-Path $ctsRoot 'scripts') | Out-Null
    & git -C $ctsRoot init -q
    & git -C $ctsRoot config user.email t@t.t
    & git -C $ctsRoot config user.name t
    $ctsCfg = Join-Path $ctsRoot 'scripts\harness-required.json'
    $ctsMarker = Join-Path $ctsRoot '.git\harness-task-started'
    [System.IO.File]::WriteAllText($ctsCfg, '{"requireTaskStart": true}', $ctsUtf8)
    [System.IO.File]::WriteAllText((Join-Path $ctsRoot 'seed.txt'), "seed`n", $ctsUtf8)
    & git -C $ctsRoot add -A
    & git -C $ctsRoot commit -q -m seed
    $seedOk = ($LASTEXITCODE -eq 0)

    $r = Invoke-Cts -TargetRoot $ctsRoot -ExtraArgs @('-Require', '1')
    Check 'check-task-start refuses a missing marker' ($seedOk -and $r.Code -eq 1)
    Check 'check-task-start names harness-start' ($r.Text -match 'harness-start\.ps1')
    $r = Invoke-Cts -TargetRoot $ctsRoot -ExtraArgs @('-Require', '0')
    Check 'check-task-start exits 0 when -Require is 0' ($r.Code -eq 0)
    $r = Invoke-Cts -TargetRoot $ctsRoot -ExtraArgs @()
    Check 'a manual run reads the config fallback (true here)' ($r.Code -eq 1)

    Start-Sleep -Seconds 2
    $nowIso = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    [System.IO.File]::WriteAllText($ctsMarker, ("feature=demo`nat=" + $nowIso + "`nflow=L2`n"), $ctsUtf8)
    $r = Invoke-Cts -TargetRoot $ctsRoot -ExtraArgs @('-Require', '1', '-Feature', 'demo')
    Check 'a current marker for the matching feature passes' ($r.Code -eq 0)
    $r = Invoke-Cts -TargetRoot $ctsRoot -ExtraArgs @('-Require', '1', '-Feature', 'other')
    Check 'a marker for another feature is refused' ($r.Code -eq 1)

    [System.IO.File]::WriteAllText($ctsMarker, ("feature=demo`nat=2000-01-01T00:00:00Z`nflow=L2`n"), $ctsUtf8)
    $r = Invoke-Cts -TargetRoot $ctsRoot -ExtraArgs @('-Require', '1', '-Feature', 'demo')
    Check 'a marker older than the last commit is refused' ($r.Code -eq 1)

    New-Item -ItemType Directory -Force -Path $ctsNoGit | Out-Null
    $r = Invoke-Cts -TargetRoot $ctsNoGit -ExtraArgs @('-Require', '1')
    Check 'a non-git project fails safely when required' ($r.Code -eq 1)
} finally {
    foreach ($d in @($ctsRoot, $ctsNoGit)) {
        if (Test-Path -LiteralPath $d) { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Write-Host '=== metrics.ps1 self test ===' -ForegroundColor Cyan
$metScript = Join-Path (Split-Path $PSScriptRoot -Parent) 'assets\scripts\metrics.ps1'
$metOut = & powershell -NoProfile -ExecutionPolicy Bypass -File $metScript -SelfTest 2>&1 | Out-String
Check 'metrics.ps1 self test exits 0' ($LASTEXITCODE -eq 0)
Check 'metrics.ps1 self test reports OK' ($metOut -match 'METRICS SELFTEST OK')

Write-Host '=== upgrade-report.ps1 self test ===' -ForegroundColor Cyan
$urScript = Join-Path (Split-Path $PSScriptRoot -Parent) 'assets\scripts\upgrade-report.ps1'
$urOut = & powershell -NoProfile -ExecutionPolicy Bypass -File $urScript -SelfTest 2>&1 | Out-String
Check 'upgrade-report.ps1 self test exits 0' ($LASTEXITCODE -eq 0)
Check 'upgrade-report.ps1 self test reports OK' ($urOut -match 'UPGRADE-REPORT SELFTEST OK')

Write-Host '=== upgrade-harness.ps1 self test ===' -ForegroundColor Cyan
$uhScript = Join-Path (Split-Path $PSScriptRoot -Parent) 'assets\upgrade\upgrade-harness.ps1'
$uhOut = & powershell -NoProfile -ExecutionPolicy Bypass -File $uhScript -SelfTest 2>&1 | Out-String
Check 'upgrade-harness.ps1 self test exits 0' ($LASTEXITCODE -eq 0)
Check 'upgrade-harness.ps1 self test reports OK' ($uhOut -match 'UPGRADE-HARNESS SELFTEST OK')

Write-Host '=== upgrade-report.ps1 edge cases ===' -ForegroundColor Cyan
$urEdge = Join-Path $env:TEMP ('hb-ur-edge-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$urUtf8 = New-Object System.Text.UTF8Encoding($false)
$urCnReview = -join @([char]0x8BC4, [char]0x5BA1, [char]0x7ED3, [char]0x8BBA)
function Invoke-Report {
    param([string]$TargetRoot, [string[]]$ExtraArgs)
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $urScript, '-Root', $TargetRoot) + $ExtraArgs
    $out = & powershell @argList 2>&1 | Out-String
    return [pscustomobject]@{ Code = $LASTEXITCODE; Text = $out }
}
function Get-ReportMap {
    param([string]$Text)
    $map = @{}
    $s = $Text.IndexOf('{')
    $e = $Text.LastIndexOf('}')
    if ($s -lt 0 -or $e -le $s) { return $map }
    try { $j = ($Text.Substring($s, $e - $s + 1) | ConvertFrom-Json) } catch { return $map }
    foreach ($it in @($j.items)) { $map[[string]$it.id] = [string]$it.status }
    return $map
}
try {
    # broken config, a begin marker without an end marker, a foreign hook
    $r1 = Join-Path $urEdge 'r1'
    New-Item -ItemType Directory -Force -Path (Join-Path $r1 'scripts') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $r1 '.git\hooks') | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $r1 'scripts\harness-required.json'), '{ this is not json', $urUtf8)
    [System.IO.File]::WriteAllText((Join-Path $r1 'AGENTS.md'),
        ('# demo' + "`n" + '<!-- harness:upgrade:begin id=start-command -->' + "`n" + 'run it' + "`n"), $urUtf8)
    [System.IO.File]::WriteAllText((Join-Path $r1 '.git\hooks\pre-commit'), '#!/bin/sh' + "`n", $urUtf8)
    $res = Invoke-Report -TargetRoot $r1 -ExtraArgs @('-Json')
    $map = Get-ReportMap $res.Text
    Check 'broken config makes requireTaskStart MISSING' ($map['requireTaskStart'] -eq 'MISSING')
    Check 'a begin marker without an end marker is MISSING' ($map['agents-start-command'] -eq 'MISSING')
    Check 'a hook without check-task-start is MANUAL' ($map['pre-commit-hook'] -eq 'MANUAL')
    Check 'MISSING rows do not fail the default exit code' ($res.Code -eq 0)

    # every row ACTIVE or MANUAL -> -Strict must stay 0
    $r2 = Join-Path $urEdge 'r2'
    New-Item -ItemType Directory -Force -Path (Join-Path $r2 'scripts') | Out-Null
    Put-File (Join-Path $r2 'scripts\harness-start.ps1') @('# demo')
    Put-File (Join-Path $r2 'scripts\check-task-start.ps1') @('# demo')
    Put-File (Join-Path $r2 'scripts\harness-required.json') @('{"requireTaskStart": false}')
    Put-File (Join-Path $r2 'AGENTS.md') @(
        '# demo',
        '<!-- harness:upgrade:begin id=start-command -->',
        'run scripts\harness-start.ps1',
        '<!-- harness:upgrade:end id=start-command -->'
    )
    Put-File (Join-Path $r2 '.harness\changes\_template\summary.md') @(
        '# summary',
        '- delivery_status: todo',
        '- linked_records: -',
        ('## ' + $urCnReview)
    )
    $res = Invoke-Report -TargetRoot $r2 -ExtraArgs @('-Json')
    $map = Get-ReportMap $res.Text
    Check 'requireTaskStart=false is MANUAL' ($map['requireTaskStart'] -eq 'MANUAL')
    Check 'an absent hook is MANUAL' ($map['pre-commit-hook'] -eq 'MANUAL')
    Check 'an absent flow block is MANUAL' ($map['flow-start-command'] -eq 'MANUAL')
    Check 'an absent moduleCommands is MANUAL' ($map['module-commands'] -eq 'MANUAL')
    Check 'the summary template is ACTIVE when complete' ($map['summary-template'] -eq 'ACTIVE')
    $res = Invoke-Report -TargetRoot $r2 -ExtraArgs @('-Strict')
    Check '-Strict exits 0 when no row is MISSING' ($res.Code -eq 0)
} finally {
    if (Test-Path -LiteralPath $urEdge) { Remove-Item -LiteralPath $urEdge -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host '=== verify-harness -UpgradeReport delegation ===' -ForegroundColor Cyan
$vhScript = Join-Path (Split-Path $PSScriptRoot -Parent) 'assets\scripts\verify-harness.ps1'
$vhRoot = Join-Path $env:TEMP ('hb-vh-report-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
try {
    New-Item -ItemType Directory -Force -Path (Join-Path $vhRoot 'scripts') | Out-Null
    $called = Join-Path $vhRoot 'report-called.txt'
    $vhReport = Join-Path $vhRoot 'scripts\upgrade-report.ps1'
    Put-File $vhReport @(
        'param([string]$Root)',
        '[System.IO.File]::WriteAllText((Join-Path $Root ''report-called.txt''), "called", (New-Object System.Text.UTF8Encoding($false)))',
        'exit 0'
    )
    $null = & powershell -NoProfile -ExecutionPolicy Bypass -File $vhScript -Root $vhRoot 2>&1
    $noCode = $LASTEXITCODE
    $null = & powershell -NoProfile -ExecutionPolicy Bypass -File $vhScript -Root $vhRoot -UpgradeReport 2>&1
    $withCode = $LASTEXITCODE
    Check 'verify-harness -UpgradeReport keeps the main exit code' ($withCode -eq $noCode)
    Check 'verify-harness -UpgradeReport calls the report' (Test-Path -LiteralPath $called)

    Remove-Item -LiteralPath $called, $vhReport -Force -ErrorAction SilentlyContinue
    $missingOut = & powershell -NoProfile -ExecutionPolicy Bypass -File $vhScript -Root $vhRoot -UpgradeReport 2>&1 | Out-String
    $missingCode = $LASTEXITCODE
    Check 'a missing report script keeps the main exit code' ($missingCode -eq $noCode)
    Check 'a missing report script is reported as MISSING' ($missingOut -match [regex]::Escape('[MISSING] scripts\upgrade-report.ps1'))
} finally {
    if (Test-Path -LiteralPath $vhRoot) { Remove-Item -LiteralPath $vhRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

if ($fail -gt 0) {
    Write-Host "FAILED: $fail check(s)" -ForegroundColor Red
    exit 1
}
Write-Host 'ALL PROBE CHECKS PASSED' -ForegroundColor Green
exit 0
