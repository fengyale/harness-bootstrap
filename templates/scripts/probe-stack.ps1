<#
  probe-stack.ps1 -- detect the project's capability stack (machine readable)

  WHY
    Template skills describe patterns in one technology. Compiling them for a
    project needs facts, not guesses: which ORM, which cache API, is there an MQ,
    is there a frontend. Output feeds .harness/stack.json, which verify-grounding
    uses to reject skills that mention technologies the project does not have.

  USAGE
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\probe-stack.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\probe-stack.ps1 -Root D:\proj

  OUTPUT
    .harness\stack.json  (UTF-8, no BOM)

  NOTE  Pure ASCII. Values are lowercase identifiers, never display names.
#>
[CmdletBinding()]
param(
    [string]$Root = (Get-Location).Path,
    [string]$Out = '.harness\stack.json'
)

$ErrorActionPreference = 'Stop'

$rootPath = (Resolve-Path -LiteralPath $Root).Path
$outPath  = if ([System.IO.Path]::IsPathRooted($Out)) { $Out } else { Join-Path $rootPath $Out }

function Test-AnyFile {
    param([string[]]$Names)
    foreach ($n in $Names) {
        if (Test-Path -LiteralPath (Join-Path $rootPath $n)) { return $true }
    }
    return $false
}

function Find-Marker {
    param([string[]]$Patterns, [string[]]$Includes)
    foreach ($pat in $Patterns) {
        $hit = Get-ChildItem -LiteralPath $rootPath -Recurse -File -Force -ErrorAction SilentlyContinue |
            Where-Object { $ext = $_.Extension.ToLower(); $Includes -contains $ext } |
            Select-String -Pattern $pat -SimpleMatch -List -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($hit) { return $hit.Path }
    }
    return $null
}

# ---------------------------------------------------------------- build tool
$buildTool = 'unknown'
$modules = 0
if (Test-Path -LiteralPath (Join-Path $rootPath 'pom.xml')) {
    $buildTool = 'maven'
    $pom = Get-Content -LiteralPath (Join-Path $rootPath 'pom.xml') -Raw -ErrorAction SilentlyContinue
    if ($pom) { $modules = ([regex]::Matches($pom, '<module>')).Count }
} elseif ((Test-Path -LiteralPath (Join-Path $rootPath 'build.gradle')) -or (Test-Path -LiteralPath (Join-Path $rootPath 'build.gradle.kts'))) {
    $buildTool = 'gradle'
} elseif (Test-Path -LiteralPath (Join-Path $rootPath 'package.json')) {
    $buildTool = 'npm'
}

# ----------------------------------------------------------------- language
$language = 'unknown'
$codeExts = @()
if (Test-AnyFile @('pom.xml', 'build.gradle')) { $language = 'java'; $codeExts = @('.java', '.kt') }
elseif (Test-Path -LiteralPath (Join-Path $rootPath 'go.mod')) { $language = 'go'; $codeExts = @('.go') }
elseif (Test-Path -LiteralPath (Join-Path $rootPath 'package.json')) { $language = 'javascript'; $codeExts = @('.ts', '.tsx', '.js', '.vue') }
elseif (Test-AnyFile @('pyproject.toml', 'requirements.txt')) { $language = 'python'; $codeExts = @('.py') }

# ---------------------------------------------------------------------- ORM
$orm = $null
$ormHit = $null
if ($codeExts.Count -gt 0) {
    $ormHit = Find-Marker @('com.jfinal', 'Db.use(', 'extends Model') $codeExts
    if ($ormHit) { $orm = 'jfinal' }
    if (-not $orm) {
        $ormHit = Find-Marker @('org.apache.ibatis', '@Mapper') $codeExts
        if ($ormHit) { $orm = 'mybatis' }
    }
    if (-not $orm) {
        $ormHit = Find-Marker @('javax.persistence', 'jakarta.persistence', '@Entity') $codeExts
        if ($ormHit) { $orm = 'jpa' }
    }
}

# -------------------------------------------------------------------- cache
$cache = $null
$cacheApi = $null
$cacheHit = $null
if ($codeExts.Count -gt 0) {
    $cacheHit = Find-Marker @('RedisUtils', 'redisTemplate', 'StringRedisTemplate', 'Jedis') $codeExts
    if ($cacheHit) { $cache = 'redis' }
    if ($cacheHit) {
        $apiHit = Find-Marker @('RedisUtils') $codeExts
        if ($apiHit) { $cacheApi = 'RedisUtils' }
    }
}

# ----------------------------------------------------------------------- mq
$mq = $null
$mqHit = $null
if ($codeExts.Count -gt 0) {
    $mqHit = Find-Marker @('rocketmq', 'RocketMQ', 'KafkaTemplate', 'rabbitmq', 'RabbitTemplate', '@RabbitListener', 'amqp') $codeExts
    if ($mqHit) { $mq = 'present' }
}

# --------------------------------------------------------------------- test
$testFiles = @(Get-ChildItem -LiteralPath $rootPath -Recurse -File -Filter '*Test.*' -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.Extension -in @('.java', '.kt', '.ts', '.js', '.py', '.go') })

# ----------------------------------------------------------------- frontend
$frontend = $null
if (Test-Path -LiteralPath (Join-Path $rootPath 'package.json')) {
    $pkg = Get-Content -LiteralPath (Join-Path $rootPath 'package.json') -Raw -ErrorAction SilentlyContinue
    if ($pkg -match '"vue"') { $frontend = 'vue' }
    elseif ($pkg -match '"react"') { $frontend = 'react' }
    else { $frontend = 'node' }
}

$stack = [pscustomobject]@{
    generatedAt = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
    root        = $rootPath
    language    = $language
    buildTool   = $buildTool
    modules     = $modules
    orm         = $orm
    ormEvidence = $ormHit
    cache       = $cache
    cacheApi    = $cacheApi
    cacheEvidence = $cacheHit
    mq          = $mq
    mqEvidence  = $mqHit
    testFiles   = $testFiles.Count
    frontend    = $frontend
}

$dir = Split-Path -Parent $outPath
if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
$json = $stack | ConvertTo-Json -Depth 5
[System.IO.File]::WriteAllText($outPath, $json, (New-Object System.Text.UTF8Encoding($false)))

Write-Host ""
Write-Host "stack detected -- $outPath" -ForegroundColor Cyan
Write-Host ("  language={0} build={1} modules={2}" -f $stack.language, $stack.buildTool, $stack.modules)
Write-Host ("  orm={0} cache={1} mq={2} tests={3} frontend={4}" -f `
    $(if ($stack.orm) { $stack.orm } else { 'none' }), `
    $(if ($stack.cache) { $stack.cache } else { 'none' }), `
    $(if ($stack.mq) { $stack.mq } else { 'none' }), `
    $stack.testFiles, `
    $(if ($stack.frontend) { $stack.frontend } else { 'none' }))
Write-Host ""
exit 0
