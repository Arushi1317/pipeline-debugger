<#
.SYNOPSIS
    Accuracy test suite for memory_store.ps1.
    Exercises Read-DebuggerHistory, Write-DebuggerHistory, and
    Get-RecurrenceMessage using a temp directory — no filesystem side effects.

    Each functional assertion scores points toward an overall accuracy %.
    Exits with code 1 if overall accuracy < 85%.
    Prints "SCORE:<n>" as the final line so the CI workflow can capture it.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'

$repoRoot     = Resolve-Path (Join-Path $PSScriptRoot '../..')
$memoryScript = Join-Path $repoRoot 'scripts/debugger/memory_store.ps1'

Write-Host "=== memory_store Accuracy Tests ==="
Write-Host ""

$passed = 0
$total  = 0

function Assert-Equal {
    param($Label, $Got, $Expected)
    $script:total++
    if ($Got -eq $Expected) {
        Write-Host "  [PASS] $Label"
        $script:passed++
    } else {
        Write-Host "  [FAIL] $Label — got '$Got', want '$Expected'"
    }
}

function Assert-True {
    param($Label, [bool]$Value)
    $script:total++
    if ($Value) {
        Write-Host "  [PASS] $Label"
        $script:passed++
    } else {
        Write-Host "  [FAIL] $Label — got false"
    }
}

# ---------------------------------------------------------------------------
# Setup: run each test group in its own temp directory
# ---------------------------------------------------------------------------
function New-TempMemoryDir {
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) "debugger-test-$([System.Guid]::NewGuid())"
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    return $tmp
}

function Invoke-WithTempDir {
    param([scriptblock]$Block, [string]$TempDir)
    Push-Location $TempDir
    try { & $Block }
    finally { Pop-Location }
}

# ---------------------------------------------------------------------------
# Test group 1: Read-DebuggerHistory on missing file returns empty array
# ---------------------------------------------------------------------------
Write-Host "[Group 1] Read-DebuggerHistory — missing file"
$tmp1 = New-TempMemoryDir
Invoke-WithTempDir -TempDir $tmp1 -Block {
    . $memoryScript
    $history = Read-DebuggerHistory
    Assert-True  'Returns array type'   ($history -is [array] -or $history -is [object[]] -or $null -eq $history -or $history.Count -eq 0)
    Assert-Equal 'Returns empty result' $history.Count 0
}
Remove-Item -Recurse -Force $tmp1

# ---------------------------------------------------------------------------
# Test group 2: Write-DebuggerHistory creates file and stores entry
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "[Group 2] Write-DebuggerHistory — creates history file"
$tmp2 = New-TempMemoryDir
Invoke-WithTempDir -TempDir $tmp2 -Block {
    . $memoryScript
    Write-DebuggerHistory -Entry @{
        date      = '2024-03-15T09:00:00Z'
        runId     = 'run-001'
        branch    = 'feature/my-branch'
        category  = 'build-error'
        phase     = 'BUILD'
        pattern   = 'Build FAILED'
        fixApplied = $false
    }
    Assert-True  'History file created'           (Test-Path '.debugger-memory/history.json')
    $history = Read-DebuggerHistory
    Assert-Equal 'One entry written'              $history.Count 1
    Assert-Equal 'Category stored correctly'      $history[0].category 'build-error'
    Assert-Equal 'Branch stored correctly'        $history[0].branch 'feature/my-branch'
    Assert-Equal 'Recurrence is 1 (first time)'   $history[0].recurrence 1
}
Remove-Item -Recurse -Force $tmp2

# ---------------------------------------------------------------------------
# Test group 3: Recurrence increments on same category + branch
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "[Group 3] Write-DebuggerHistory — recurrence counting"
$tmp3 = New-TempMemoryDir
Invoke-WithTempDir -TempDir $tmp3 -Block {
    . $memoryScript
    $entry = @{
        date = '2024-03-15T09:00:00Z'; runId = 'run-001'
        branch = 'main'; category = 'infra'; phase = 'PIPELINE'
        pattern = 'chocolatey timed out'; fixApplied = $false
    }
    Write-DebuggerHistory -Entry $entry
    $entry.runId = 'run-002'
    $entry.date  = '2024-03-16T09:00:00Z'
    Write-DebuggerHistory -Entry $entry
    $entry.runId = 'run-003'
    $entry.date  = '2024-03-17T09:00:00Z'
    Write-DebuggerHistory -Entry $entry

    $history = Read-DebuggerHistory
    Assert-Equal 'Three entries total'                         $history.Count 3
    Assert-Equal 'First entry recurrence = 1'                 $history[0].recurrence 1
    Assert-Equal 'Second entry recurrence = 2'                $history[1].recurrence 2
    Assert-Equal 'Third entry recurrence = 3'                 $history[2].recurrence 3
}
Remove-Item -Recurse -Force $tmp3

# ---------------------------------------------------------------------------
# Test group 4: Different branch resets recurrence
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "[Group 4] Write-DebuggerHistory — different branch resets recurrence"
$tmp4 = New-TempMemoryDir
Invoke-WithTempDir -TempDir $tmp4 -Block {
    . $memoryScript
    Write-DebuggerHistory -Entry @{
        date = '2024-03-15T09:00:00Z'; runId = 'run-A'
        branch = 'main'; category = 'build-error'; phase = 'BUILD'
        pattern = 'Build FAILED'; fixApplied = $false
    }
    Write-DebuggerHistory -Entry @{
        date = '2024-03-16T09:00:00Z'; runId = 'run-B'
        branch = 'feature/other'; category = 'build-error'; phase = 'BUILD'
        pattern = 'Build FAILED'; fixApplied = $false
    }
    $history = Read-DebuggerHistory
    Assert-Equal 'Two entries total'                      $history.Count 2
    Assert-Equal 'main branch recurrence = 1'             $history[0].recurrence 1
    Assert-Equal 'feature branch recurrence = 1 (reset)'  $history[1].recurrence 1
}
Remove-Item -Recurse -Force $tmp4

# ---------------------------------------------------------------------------
# Test group 5: Get-RecurrenceMessage returns correct strings
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "[Group 5] Get-RecurrenceMessage — all cases"
$tmp5 = New-TempMemoryDir
Invoke-WithTempDir -TempDir $tmp5 -Block {
    . $memoryScript
    Assert-Equal 'n=1 message' (Get-RecurrenceMessage -RecurrenceCount 1) 'First time seeing this failure on this branch'
    Assert-Equal 'n=2 message' (Get-RecurrenceMessage -RecurrenceCount 2) 'This has failed the same way before — the previous fix was not applied'
    $msg3 = Get-RecurrenceMessage -RecurrenceCount 3
    Assert-True  'n=3 mentions count'    ($msg3 -match '3')
    Assert-True  'n=3 mentions recurring' ($msg3 -match 'Recurring')
    $msg5 = Get-RecurrenceMessage -RecurrenceCount 5
    Assert-True  'n=5 mentions 5'        ($msg5 -match '5')
}
Remove-Item -Recurse -Force $tmp5

# ---------------------------------------------------------------------------
# Results
# ---------------------------------------------------------------------------
Write-Host ""
$overallPct = if ($total -gt 0) { [math]::Round(($passed / $total) * 100) } else { 0 }

Write-Host "=== Summary ==="
Write-Host "Assertions : $passed / $total passed"
Write-Host "Accuracy   : $overallPct%"
Write-Host ""
Write-Host "SCORE:$overallPct"

if ($overallPct -lt 85) {
    Write-Error "Accuracy $overallPct% is below the 85% threshold."
    exit 1
}
exit 0
