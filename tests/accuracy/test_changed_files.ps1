<#
.SYNOPSIS
    Accuracy test suite for check_changed_files.ps1.
    Tests the file-to-cause correlation logic using mock file lists
    (no GitHub API calls are made).

    Each test case scores out of 100:
      CorrelatedCause exact match = 40 pts
      IsCodeRelated correct       = 30 pts
      IsInfraRelated correct      = 30 pts

    Exits with code 1 if overall accuracy < 85%.
    Prints "SCORE:<n>" as the final line so the CI workflow can capture it.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'

$repoRoot      = Resolve-Path (Join-Path $PSScriptRoot '../..')
$checkScript   = Join-Path $repoRoot 'scripts/debugger/check_changed_files.ps1'

Write-Host "=== check_changed_files Accuracy Tests ==="
Write-Host ""

$testCases = @(
    @{
        Id              = 'cf-01'
        Name            = 'csproj changed — code related'
        Files           = @('src/QualityGate.Core/QualityGate.Core.csproj')
        ExpectedCause   = 'csproj-changed'
        ExpectedCode    = $true
        ExpectedInfra   = $false
    },
    @{
        Id              = 'cf-02'
        Name            = 'test cs file changed — code related'
        Files           = @('tests/MetricsCollectorTests.cs')
        ExpectedCause   = 'test-code-changed'
        ExpectedCode    = $true
        ExpectedInfra   = $false
    },
    @{
        Id              = 'cf-03'
        Name            = 'workflow yml changed — infra related'
        Files           = @('.github/workflows/company-quality-gate.yml')
        ExpectedCause   = 'workflow-changed'
        ExpectedCode    = $false
        ExpectedInfra   = $true
    },
    @{
        Id              = 'cf-04'
        Name            = 'quality gate script changed — infra related'
        Files           = @('scripts/run_quality_gate.ps1')
        ExpectedCause   = 'pipeline-script-changed'
        ExpectedCode    = $false
        ExpectedInfra   = $true
    },
    @{
        Id              = 'cf-05'
        Name            = 'config JSON changed — infra related'
        Files           = @('config/quality-gate.prod.json')
        ExpectedCause   = 'config-changed'
        ExpectedCode    = $false
        ExpectedInfra   = $true
    },
    @{
        Id              = 'cf-06'
        Name            = 'Program.cs changed — code related'
        Files           = @('src/QualityGate.Runner/Program.cs')
        ExpectedCause   = 'entrypoint-changed'
        ExpectedCode    = $true
        ExpectedInfra   = $false
    },
    @{
        Id              = 'cf-07'
        Name            = 'no relevant files changed — none'
        Files           = @('README.md', 'docs/architecture.md')
        ExpectedCause   = 'none'
        ExpectedCode    = $false
        ExpectedInfra   = $false
    },
    @{
        Id              = 'cf-08'
        Name            = 'csproj + test file — code related, two reasons'
        Files           = @('src/QualityGate.Core/QualityGate.Core.csproj', 'tests/EvidenceBuilderTests.cs')
        ExpectedCause   = 'csproj-changed, test-code-changed'
        ExpectedCode    = $true
        ExpectedInfra   = $false
    },
    @{
        Id              = 'cf-09'
        Name            = 'workflow + config — infra only, two reasons'
        Files           = @('.github/workflows/company-quality-gate.yml', 'config/quality-gate.staging.json')
        ExpectedCause   = 'workflow-changed, config-changed'
        ExpectedCode    = $false
        ExpectedInfra   = $true
    },
    @{
        Id              = 'cf-10'
        Name            = 'csproj + workflow — code and infra'
        Files           = @('src/QualityGate.Core/QualityGate.Core.csproj', '.github/workflows/company-quality-gate.yml')
        ExpectedCause   = 'csproj-changed, workflow-changed'
        ExpectedCode    = $true
        ExpectedInfra   = $true
    }
)

$totalPoints  = 0
$earnedPoints = 0
$caseCount    = 0

foreach ($case in $testCases) {
    $caseCount++

    $result = $null
    try {
        $result = & $checkScript -MockFiles $case.Files
    } catch {
        Write-Warning "check_changed_files.ps1 threw for case $($case.Id): $_"
        $result = [PSCustomObject]@{
            ChangedFiles = @(); CorrelatedCause = 'unknown'
            IsCodeRelated = $false; IsInfraRelated = $false
        }
    }

    $casePossible = 100
    $caseEarned   = 0
    $breakdown    = @()

    # CorrelatedCause (40 pts) — order-insensitive comparison
    $gotParts      = ($result.CorrelatedCause -split ', ' | Sort-Object)
    $wantParts     = ($case.ExpectedCause     -split ', ' | Sort-Object)
    $causeCorrect  = (($gotParts -join ',') -eq ($wantParts -join ','))
    if ($causeCorrect) { $caseEarned += 40; $breakdown += 'Cause=OK(40)' }
    else               { $breakdown += "Cause=FAIL(0) got='$($result.CorrelatedCause)' want='$($case.ExpectedCause)'" }

    # IsCodeRelated (30 pts)
    $codeCorrect = ($result.IsCodeRelated -eq $case.ExpectedCode)
    if ($codeCorrect) { $caseEarned += 30; $breakdown += 'CodeRelated=OK(30)' }
    else              { $breakdown += "CodeRelated=FAIL(0) got=$($result.IsCodeRelated) want=$($case.ExpectedCode)" }

    # IsInfraRelated (30 pts)
    $infraCorrect = ($result.IsInfraRelated -eq $case.ExpectedInfra)
    if ($infraCorrect) { $caseEarned += 30; $breakdown += 'InfraRelated=OK(30)' }
    else               { $breakdown += "InfraRelated=FAIL(0) got=$($result.IsInfraRelated) want=$($case.ExpectedInfra)" }

    $totalPoints  += $casePossible
    $earnedPoints += $caseEarned
    $pct           = [math]::Round(($caseEarned / $casePossible) * 100)

    $status = if ($caseEarned -eq $casePossible) { 'PASS' } else { 'FAIL' }
    Write-Host "[$status] $($case.Id) — $($case.Name)"
    Write-Host "       Score: $caseEarned/$casePossible ($pct%)"
    Write-Host "       $($breakdown -join ' | ')"
    Write-Host ""
}

$overallPct = if ($totalPoints -gt 0) {
    [math]::Round(($earnedPoints / $totalPoints) * 100)
} else { 0 }

Write-Host "=== Summary ==="
Write-Host "Cases run    : $caseCount"
Write-Host "Total points : $earnedPoints / $totalPoints"
Write-Host "Accuracy     : $overallPct%"
Write-Host ""
Write-Host "SCORE:$overallPct"

if ($overallPct -lt 85) {
    Write-Error "Accuracy $overallPct% is below the 85% threshold."
    exit 1
}
exit 0
