<#
.SYNOPSIS
    Posts or updates a structured failure analysis comment on a GitHub PR.
    Never posts duplicates — identifies its own comment via a hidden HTML marker.
    Does nothing when confidence is NONE.
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$Owner,

    [Parameter(Mandatory = $true)]
    [string]$Repo,

    [Parameter(Mandatory = $true)]
    [int]$PrNumber,

    [Parameter(Mandatory = $true)]
    [string]$Token,

    [Parameter(Mandatory = $true)]
    [object]$Analysis,

    [Parameter(Mandatory = $true)]
    [object]$ChangedFileInfo,

    [Parameter(Mandatory = $true)]
    [string]$RecurrenceMessage
)

if ($Analysis.Confidence -eq 'NONE') {
    Write-Host "Confidence is NONE — skipping PR comment."
    return
}

$headers = @{
    'Authorization'        = "Bearer $Token"
    'Accept'               = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
    'Content-Type'         = 'application/json'
}

$marker = '<!-- pipeline-debugger-bot -->'

# ------------------------------------------------------------------
# Locate existing debugger comment (create vs update decision)
# ------------------------------------------------------------------
$existingCommentId = $null
try {
    $commentsUrl = "https://api.github.com/repos/$Owner/$Repo/issues/$PrNumber/comments"
    # Paginate up to 100 comments — sufficient for most PRs
    $comments = Invoke-RestMethod -Uri "${commentsUrl}?per_page=100" -Headers $headers -Method Get
    foreach ($c in $comments) {
        if ($c.body -match [regex]::Escape($marker)) {
            $existingCommentId = $c.id
            break
        }
    }
} catch {
    Write-Warning "Could not retrieve existing PR comments: $_"
}

# ------------------------------------------------------------------
# Build comment body
# ------------------------------------------------------------------
$confidenceBadge = switch ($Analysis.Confidence) {
    'HIGH'   { '✅ HIGH' }
    'MEDIUM' { '⚠️ MEDIUM' }
    'LOW'    { '🔶 LOW' }
    default  { '🚫 NONE' }
}

$severityBadge = switch ($Analysis.Severity) {
    'BLOCKER'  { '🔴 BLOCKER' }
    'PIPELINE' { '🟠 PIPELINE' }
    'FLAKY'    { '🟡 FLAKY' }
    default    { '⚪ UNKNOWN' }
}

$body = @"
## 🔍 Pipeline Failure Debugger — $confidenceBadge

> **Source:** raw GitHub Actions logs (independent of quality gate output)

| Field    | Value |
|----------|-------|
| Severity | $severityBadge |
| Phase    | ``$($Analysis.Phase)`` |
| Category | ``$($Analysis.Category)`` |

### Raw Evidence
``````
$($Analysis.RawEvidence)
``````

"@

if ($Analysis.Confidence -eq 'LOW') {
    $body += @"
> ⚠️ **Low confidence** — the failure pattern is ambiguous. Review the raw GitHub Actions log manually before applying any fix.

"@
} else {
    $body += @"
### Suggested Fix
$($Analysis.SuggestedFix)

"@
}

$body += @"
### Recurrence
$RecurrenceMessage

"@

$correlatedCause = $ChangedFileInfo.CorrelatedCause
if ($correlatedCause -and $correlatedCause -notin @('none', 'unknown', '')) {
    $body += @"
### Changed File Correlation
The following change types in this PR may be relevant to the failure: ``$correlatedCause``

"@
}

$body += "`n$marker"

# ------------------------------------------------------------------
# Post or update comment
# ------------------------------------------------------------------
$payload = @{ body = $body } | ConvertTo-Json -Depth 3 -Compress

try {
    if ($existingCommentId) {
        $patchUrl = "https://api.github.com/repos/$Owner/$Repo/issues/comments/$existingCommentId"
        Invoke-RestMethod -Uri $patchUrl -Headers $headers -Method Patch -Body $payload | Out-Null
        Write-Host "Updated existing debugger comment (ID: $existingCommentId) on PR #$PrNumber."
    } else {
        $postUrl = "https://api.github.com/repos/$Owner/$Repo/issues/$PrNumber/comments"
        Invoke-RestMethod -Uri $postUrl -Headers $headers -Method Post -Body $payload | Out-Null
        Write-Host "Posted new debugger comment on PR #$PrNumber."
    }
} catch {
    Write-Warning "Could not post/update PR comment: $_"
}
