<#
.SYNOPSIS
    Accuracy test suite for analyze_failure.ps1.
    Loads each truth-table case, feeds the fixture log into analyze_failure,
    compares the result to expected values, and scores up to 105 pts per case.

    Scoring per case:
      Severity correct       = 30 pts
      Category correct       = 25 pts
      Phase correct          = 20 pts
      Confidence correct     = 15 pts
      shouldPostComment      = 10 pts
      Language correct       =  5 pts  (bonus)
                               ─────
      Maximum per case       = 105 pts

    Exits with code 1 if overall accuracy < 85%.
    Prints "SCORE:<n>" as the final line so the CI workflow can capture it.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'

$repoRoot    = Resolve-Path (Join-Path $PSScriptRoot '../..')
$fixturesDir = Join-Path $repoRoot 'tests/fixtures'
$truthFile   = Join-Path $repoRoot 'tests/truth-table.json'
$analyzeScript = Join-Path $repoRoot 'scripts/debugger/analyze_failure.ps1'

Write-Host "=== analyze_failure Accuracy Tests ==="
Write-Host ""

$truthTable = Get-Content $truthFile -Raw | ConvertFrom-Json

$totalPoints  = 0
$earnedPoints = 0
$caseCount    = 0

foreach ($case in $truthTable) {
    $caseCount++
    $fixturePath = Join-Path $fixturesDir $case.fixtureLog

    if (-not (Test-Path $fixturePath)) {
        Write-Warning "Fixture not found: $fixturePath — skipping case $($case.id)"
        continue
    }

    $rawLog = Get-Content $fixturePath -Raw

    # Build a mock LogData object matching what get_ci_logs.ps1 would produce
    $mockLogData = [PSCustomObject]@{
        RunId       = 'test-run-000'
        AllJobsRaw  = $rawLog
        FailedSteps = @(
            [PSCustomObject]@{
                JobName        = 'quality-gate'
                JobId          = 0
                StepName       = 'Run quality gate'
                StepNumber     = 1
                ExitCode       = 1
                FirstErrorLine = ($rawLog -split "`n" | Where-Object { $_ -match '##\[error\]' } | Select-Object -First 1)
                ErrorBlock     = $rawLog
                RawLog         = $rawLog
            }
        )
        HasFailures = $true
    }

    $result = $null
    try {
        $result = & $analyzeScript -LogData $mockLogData
    } catch {
        Write-Warning "analyze_failure.ps1 threw for case $($case.id): $_"
        $result = [PSCustomObject]@{
            Severity = $null; Category = $null; Phase = $null
            Confidence = 'NONE'; RawEvidence = $null; SuggestedFix = $null
            Language = 'unknown'
        }
    }

    # Score this case
    $casePossible = 105
    $caseEarned   = 0
    $breakdown    = @()

    # Severity (30 pts) — both null counts as correct
    $sevCorrect = ($result.Severity -eq $case.expectedSeverity)
    if ($sevCorrect) { $caseEarned += 30; $breakdown += 'Severity=OK(30)' }
    else             { $breakdown += "Severity=FAIL(0) got='$($result.Severity)' want='$($case.expectedSeverity)'" }

    # Category (25 pts)
    $catCorrect = ($result.Category -eq $case.expectedCategory)
    if ($catCorrect) { $caseEarned += 25; $breakdown += 'Category=OK(25)' }
    else             { $breakdown += "Category=FAIL(0) got='$($result.Category)' want='$($case.expectedCategory)'" }

    # Phase (20 pts)
    $phaseCorrect = ($result.Phase -eq $case.expectedPhase)
    if ($phaseCorrect) { $caseEarned += 20; $breakdown += 'Phase=OK(20)' }
    else               { $breakdown += "Phase=FAIL(0) got='$($result.Phase)' want='$($case.expectedPhase)'" }

    # Confidence (15 pts)
    $confCorrect = ($result.Confidence -eq $case.expectedConfidence)
    if ($confCorrect) { $caseEarned += 15; $breakdown += 'Confidence=OK(15)' }
    else              { $breakdown += "Confidence=FAIL(0) got='$($result.Confidence)' want='$($case.expectedConfidence)'" }

    # shouldPostComment (10 pts) — NONE confidence means no comment
    $wouldPost        = ($result.Confidence -ne 'NONE')
    $postCorrect      = ($wouldPost -eq [bool]$case.shouldPostComment)
    if ($postCorrect) { $caseEarned += 10; $breakdown += 'PostComment=OK(10)' }
    else              { $breakdown += "PostComment=FAIL(0) got=$wouldPost want=$($case.shouldPostComment)" }

    # Language (5 bonus pts)
    $langCorrect = ($result.Language -eq $case.expectedLanguage)
    if ($langCorrect) { $caseEarned += 5; $breakdown += 'Language=OK(5)' }
    else              { $breakdown += "Language=FAIL(0) got='$($result.Language)' want='$($case.expectedLanguage)'" }

    $totalPoints  += $casePossible
    $earnedPoints += $caseEarned
    $pct           = [math]::Round(($caseEarned / $casePossible) * 100)

    $status = if ($caseEarned -eq $casePossible) { 'PASS' } else { 'FAIL' }
    Write-Host "[$status] $($case.id) — $($case.name)"
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

# Required output token for CI workflow to capture
Write-Host "SCORE:$overallPct"

if ($overallPct -lt 85) {
    Write-Error "Accuracy $overallPct% is below the 85% threshold."
    exit 1
}
exit 0
