<#
  run-all.ps1 -- run every behavioural test of harness-bootstrap

  WHY
    verify-package.ps1 -Fast catches static drift before a commit, but the
    contract checks cannot prove that the gate actually blocks the wrong thing.
    These tests install the scripts into throw-away projects and assert the
    real exit codes: tri-state command checks, summary field split, hook
    install/uninstall, stage-gate -All, metrics, A3+ spoof rejection.

  WHAT RUNS
    gate-auto.ps1   stage-gate AUTO behaviour and pre-commit field scope
    regression.ps1  install -> fill summary -> stage-gate -All -> metrics -> uninstall
    test-update.ps1 upgrade plan: replace .ps1, keep JSON/history, backup, version marker
    test-audit-order.ps1  CI-side summary-order audit over a commit range
    test-skills-registry.ps1  a new skill must be indexed and reachable, or it is a dead file

  USAGE
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-all.ps1

  EXIT CODE
    0 = every test passed, 1 = at least one failed

  NOTE
    Pure ASCII. Each test builds its own fixture under %TEMP% and never writes
    into this repository.
#>
$ErrorActionPreference = 'Stop'

$PS = if (Get-Command powershell -ErrorAction SilentlyContinue) { 'powershell' } else { 'pwsh' }
$failed = 0

foreach ($name in @('gate-auto.ps1', 'regression.ps1', 'test-update.ps1', 'test-audit-order.ps1', 'test-skills-registry.ps1')) {
    Write-Host ""
    Write-Host "=== $name ===" -ForegroundColor Cyan
    & $PS -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot $name)
    if ($LASTEXITCODE -ne 0) {
        Write-Host "FAILED: $name (exit $LASTEXITCODE)" -ForegroundColor Red
        $failed++
    }
}

Write-Host ""
if ($failed -gt 0) {
    Write-Host "TESTS FAILED: $failed suite(s)" -ForegroundColor Red
    exit 1
}
Write-Host 'ALL TESTS PASSED' -ForegroundColor Green
exit 0
