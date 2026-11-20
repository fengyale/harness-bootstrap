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
$ErrorActionPreference = 'Stop'

$script = Join-Path (Split-Path $PSScriptRoot -Parent) 'assets\scripts\probe-project.ps1'
$proj   = Join-Path $env:TEMP ('hb-probe-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$empty  = Join-Path $env:TEMP ('hb-probe-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '-empty')
$absOut = Join-Path $env:TEMP ('hb-probe-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '-out')
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
    foreach ($d in @($proj, $empty, $absOut)) {
        if (Test-Path -LiteralPath $d) { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

if ($fail -gt 0) {
    Write-Host "FAILED: $fail check(s)" -ForegroundColor Red
    exit 1
}
Write-Host 'ALL PROBE CHECKS PASSED' -ForegroundColor Green
exit 0
