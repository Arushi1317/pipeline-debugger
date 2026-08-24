<#
.SYNOPSIS
    Retrieves raw GitHub Actions job logs for a workflow run and extracts
    structured failure data from them.
.NOTES
    Only calls the GitHub REST API — never reads artifact files.
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$Owner,

    [Parameter(Mandatory = $true)]
    [string]$Repo,

    [Parameter(Mandatory = $true)]
    [string]$RunId,

    [Parameter(Mandatory = $true)]
    [string]$Token
)

$headers = @{
    'Authorization'        = "Bearer $Token"
    'Accept'               = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
}

$failedSteps = @()
$allJobsRaw  = ''

try {
    $jobsUrl      = "https://api.github.com/repos/$Owner/$Repo/actions/runs/$RunId/jobs"
    $jobsResponse = Invoke-RestMethod -Uri $jobsUrl -Headers $headers -Method Get

    foreach ($job in $jobsResponse.jobs) {
        $isFailedJob = $job.conclusion -in @('failure', 'cancelled', 'timed_out')
        if (-not $isFailedJob) { continue }

        $rawLog = ''
        try {
            $logsUrl = "https://api.github.com/repos/$Owner/$Repo/actions/jobs/$($job.id)/logs"
            # The logs endpoint returns a redirect; Invoke-RestMethod follows it automatically
            $rawLog = Invoke-RestMethod -Uri $logsUrl -Headers $headers -Method Get
        } catch {
            Write-Warning "Could not retrieve log for job '$($job.name)' (id $($job.id)): $_"
        }

        $allJobsRaw += $rawLog

        foreach ($step in $job.steps) {
            if ($step.conclusion -ne 'failure') { continue }

            $logLines      = $rawLog -split "`n"
            $errorPattern  = '##\[error\]|error MSB|MSBUILD : error|Build FAILED|Test Run Failed|' +
                             'pandoc not found|wkhtmltopdf not found|Could not load file or assembly|' +
                             'No test result files were found|chocolatey.*timeout|HTTP 503|' +
                             'connection refused|rate limit'
            $errorLines    = $logLines | Where-Object { $_ -match $errorPattern }
            $firstErrorLine = $errorLines | Select-Object -First 1

            $errorBlock = ''
            if ($firstErrorLine) {
                $idx   = [array]::IndexOf($logLines, $firstErrorLine)
                $start = [Math]::Max(0, $idx - 2)
                $end   = [Math]::Min($logLines.Count - 1, $idx + 20)
                $errorBlock = ($logLines[$start..$end]) -join "`n"
            }

            $failedSteps += [PSCustomObject]@{
                JobName        = $job.name
                JobId          = $job.id
                StepName       = $step.name
                StepNumber     = $step.number
                ExitCode       = 1
                FirstErrorLine = $firstErrorLine
                ErrorBlock     = $errorBlock
                RawLog         = $rawLog
            }
        }
    }
} catch {
    Write-Warning "Could not retrieve jobs for run '$RunId': $_"
}

return [PSCustomObject]@{
    RunId       = $RunId
    FailedSteps = $failedSteps
    AllJobsRaw  = $allJobsRaw
    HasFailures = ($failedSteps.Count -gt 0)
}
