<#
.SYNOPSIS
    Retrieves the list of files changed in a PR and correlates them with
    potential failure causes.
.OUTPUTS
    PSCustomObject with fields: ChangedFiles, CorrelatedCause,
    IsCodeRelated, IsInfraRelated
#>
param(
    [string]  $Owner,
    [string]  $Repo,
    [int]     $PrNumber,
    [string]  $Token,

    # Supply mock file objects (each with a .filename property) to bypass
    # the GitHub API — used by accuracy tests.
    [object[]] $MockFiles = $null
)

$headers = @{
    'Authorization'        = "Bearer $Token"
    'Accept'               = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
}

$changedFiles = @()

if ($null -ne $MockFiles) {
    $changedFiles = @($MockFiles | ForEach-Object {
        if ($_ -is [string]) { $_ } else { $_.filename }
    })
} else {
    try {
        $url     = "https://api.github.com/repos/$Owner/$Repo/pulls/$PrNumber/files"
        $response = Invoke-RestMethod -Uri $url -Headers $headers -Method Get
        $changedFiles = @($response | ForEach-Object { $_.filename })
    } catch {
        Write-Warning "Could not retrieve changed files for PR #$PrNumber : $_"
        return [PSCustomObject]@{
            ChangedFiles    = @()
            CorrelatedCause = 'unknown'
            IsCodeRelated   = $false
            IsInfraRelated  = $false
        }
    }
}

$reasons        = [System.Collections.Generic.List[string]]::new()
$isCodeRelated  = $false
$isInfraRelated = $false

foreach ($file in $changedFiles) {
    switch -Regex ($file) {
        '\.csproj$' {
            $reasons.Add('csproj-changed')
            $isCodeRelated = $true
        }
        '^tests/.+\.cs$' {
            $reasons.Add('test-code-changed')
            $isCodeRelated = $true
        }
        'scripts/run_quality_gate\.ps1$' {
            $reasons.Add('pipeline-script-changed')
            $isInfraRelated = $true
        }
        'config/quality-gate\..+\.json$' {
            $reasons.Add('config-changed')
            $isInfraRelated = $true
        }
        '^\.github/workflows/.+\.yml$' {
            $reasons.Add('workflow-changed')
            $isInfraRelated = $true
        }
        'Program\.cs$|Startup\.cs$' {
            $reasons.Add('entrypoint-changed')
            $isCodeRelated = $true
        }
    }
}

# Deduplicate reasons
$uniqueReasons   = $reasons | Select-Object -Unique
$correlatedCause = if ($uniqueReasons.Count -gt 0) {
    $uniqueReasons -join ', '
} else {
    'none'
}

return [PSCustomObject]@{
    ChangedFiles    = $changedFiles
    CorrelatedCause = $correlatedCause
    IsCodeRelated   = $isCodeRelated
    IsInfraRelated  = $isInfraRelated
}
