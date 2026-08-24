<#
.SYNOPSIS
    Orchestrates the pipeline failure debugger: fetch logs → check changed files →
    analyze failure → update memory → post PR comment.
.NOTES
    Never throws — all errors are caught and logged as warnings so this script
    can never crash the calling workflow.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'

$token    = $env:GITHUB_TOKEN
$runId    = $env:TARGET_RUN_ID
$fullRepo = $env:TARGET_REPO   # expected format: owner/repo
$prNumber = [int]($env:PR_NUMBER -replace '[^0-9]', '0')
$targetRef = $env:TARGET_REF

if (-not $token -or -not $runId -or -not $fullRepo) {
    Write-Warning "[Debugger] Missing required environment variables: GITHUB_TOKEN, TARGET_RUN_ID, TARGET_REPO. Exiting."
    exit 0
}

$repoParts = $fullRepo -split '/', 2
if ($repoParts.Count -lt 2) {
    Write-Warning "[Debugger] TARGET_REPO must be in 'owner/repo' format. Got: $fullRepo"
    exit 0
}
$owner = $repoParts[0]
$repo  = $repoParts[1]

$scriptRoot = $PSScriptRoot

Write-Host "=== Pipeline Failure Debugger ==="
Write-Host "Target repo : $fullRepo"
Write-Host "Run ID      : $runId"
Write-Host "PR number   : $prNumber"
Write-Host "Ref         : $targetRef"
Write-Host ""

# ---------------------------------------------------------------------------
# Step 1: Fetch CI logs
# ---------------------------------------------------------------------------
$logData = $null
try {
    Write-Host "[1/5] Fetching CI logs from GitHub Actions API..."
    $logData = & "$scriptRoot/get_ci_logs.ps1" `
        -Owner $owner -Repo $repo -RunId $runId -Token $token

    $failCount = if ($logData.FailedSteps) { $logData.FailedSteps.Count } else { 0 }
    Write-Host "      -> $failCount failed step(s) found."
} catch {
    Write-Warning "[Debugger] get_ci_logs.ps1 failed: $_"
    exit 0
}

# ---------------------------------------------------------------------------
# Step 2: Check changed files
# ---------------------------------------------------------------------------
$changedFileInfo = @{
    ChangedFiles    = @()
    CorrelatedCause = 'none'
    IsCodeRelated   = $false
    IsInfraRelated  = $false
}
try {
    Write-Host "[2/5] Checking PR changed files..."
    if ($prNumber -gt 0) {
        $changedFileInfo = & "$scriptRoot/check_changed_files.ps1" `
            -Owner $owner -Repo $repo -PrNumber $prNumber -Token $token
        $fileCount = if ($changedFileInfo.ChangedFiles) { $changedFileInfo.ChangedFiles.Count } else { 0 }
        Write-Host "      -> $fileCount changed file(s). Correlated cause: $($changedFileInfo.CorrelatedCause)"
    } else {
        Write-Host "      -> No PR number provided — skipping changed-file check."
    }
} catch {
    Write-Warning "[Debugger] check_changed_files.ps1 failed: $_"
}

# ---------------------------------------------------------------------------
# Step 3: Analyze failure
# ---------------------------------------------------------------------------
$analysis = $null
try {
    Write-Host "[3/5] Analyzing failure patterns..."
    $analysis = & "$scriptRoot/analyze_failure.ps1" -LogData $logData
    Write-Host "      -> Severity: $($analysis.Severity) | Category: $($analysis.Category) | Confidence: $($analysis.Confidence)"
} catch {
    Write-Warning "[Debugger] analyze_failure.ps1 failed: $_"
    exit 0
}

if ($analysis.Confidence -eq 'NONE') {
    Write-Host "      -> Confidence is NONE — no actionable failure pattern found. Exiting without posting comment."
    exit 0
}

# ---------------------------------------------------------------------------
# Step 4: Update memory store
# ---------------------------------------------------------------------------
$recurrenceMessage = 'First time seeing this failure on this branch'
try {
    Write-Host "[4/5] Updating debugger memory store..."
    . "$scriptRoot/memory_store.ps1"

    $entry = @{
        date       = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssZ')
        runId      = $runId
        branch     = $targetRef
        category   = $analysis.Category
        phase      = $analysis.Phase
        pattern    = $analysis.RawEvidence
        fixApplied = $false
    }
    Write-DebuggerHistory -Entry $entry

    $history         = Read-DebuggerHistory
    $matchingEntries = @($history | Where-Object {
        $_.category -eq $analysis.Category -and $_.branch -eq $targetRef
    })
    $recurrenceCount   = $matchingEntries.Count
    $recurrenceMessage = Get-RecurrenceMessage -RecurrenceCount $recurrenceCount
    Write-Host "      -> Recurrence count for '$($analysis.Category)' on '$targetRef': $recurrenceCount"
} catch {
    Write-Warning "[Debugger] memory_store.ps1 failed: $_"
}

# ---------------------------------------------------------------------------
# Step 5: Post PR comment
# ---------------------------------------------------------------------------
try {
    Write-Host "[5/5] Posting PR comment..."
    if ($prNumber -gt 0) {
        & "$scriptRoot/post_pr_comment.ps1" `
            -Owner            $owner `
            -Repo             $repo `
            -PrNumber         $prNumber `
            -Token            $token `
            -Analysis         $analysis `
            -ChangedFileInfo  $changedFileInfo `
            -RecurrenceMessage $recurrenceMessage
    } else {
        Write-Host "      -> No PR number provided — skipping comment post."
    }
} catch {
    Write-Warning "[Debugger] post_pr_comment.ps1 failed: $_"
}

Write-Host ""
Write-Host "=== Pipeline Failure Debugger complete ==="
