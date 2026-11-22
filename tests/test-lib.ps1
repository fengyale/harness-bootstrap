# test-lib.ps1 -- run a harness script inside this process instead of spawning
# a new powershell.exe per call.
#
# The target scripts accept -NoExit: their Complete-Harness helper then throws
# "__HARNESS_EXIT__N" instead of calling exit, so the caller survives. This
# helper catches that marker, stores the code in $LASTEXITCODE (tests read it
# after the call), and rethrows any other exception so real failures stay loud.
#
# Pure ASCII on purpose (PS 5.1 parses a BOM-less .ps1 as ANSI).

function Invoke-Harness {
    param(
        [string]$Script,
        [hashtable]$Params = @{}
    )
    # The target runs in a child scope of this function. It must not read the
    # caller's variables: a CLI run would see $null, an in-process run would see
    # the test's values, and the two paths would drift.
    $p = @{}
    foreach ($k in $Params.Keys) { $p[$k] = $Params[$k] }
    $p['NoExit'] = $true
    $global:LASTEXITCODE = 0
    try {
        & $Script @p 6>&1 2>&1
    } catch {
        $m = [string]$_.Exception.Message
        if ($m -match '__HARNESS_EXIT__(\d+)') {
            $global:LASTEXITCODE = [int]$matches[1]
        } else {
            throw
        }
    }
}
