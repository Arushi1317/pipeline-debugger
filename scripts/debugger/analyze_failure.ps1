<#
.SYNOPSIS
    Classifies pipeline failures by pattern-matching raw log text produced by
    the gatetesting2 quality-gate pipeline.
.OUTPUTS
    PSCustomObject with fields: Severity, Category, Phase, Confidence,
    RawEvidence, SuggestedFix
#>
param(
    [Parameter(Mandatory = $true)]
    [object]$LogData
)

# Ordered list — first match wins for primary classification.
$knownPatterns = @(
    [PSCustomObject]@{
        Regex       = 'pandoc not found|wkhtmltopdf not found'
        Severity    = 'PIPELINE'
        Category    = 'tool-missing'
        Phase       = 'PIPELINE'
        SuggestedFix = 'Install the missing PDF tool in the setup phase: add ' +
                       '`choco install pandoc` and/or `choco install wkhtmltopdf` ' +
                       'before the PDF-generation step in the workflow.'
    },
    [PSCustomObject]@{
        Regex       = 'MSBUILD : error|Build FAILED'
        Severity    = 'BLOCKER'
        Category    = 'build-error'
        Phase       = 'BUILD'
        SuggestedFix = 'Fix the MSBuild compilation error shown in the raw evidence. ' +
                       'Common causes: missing NuGet package, syntax error, or incompatible ' +
                       'TargetFramework. Run `dotnet build` locally to reproduce.'
    },
    [PSCustomObject]@{
        Regex       = 'Test Run Failed|failed.*\.trx'
        Severity    = 'BLOCKER'
        Category    = 'test-failure'
        Phase       = 'TEST'
        SuggestedFix = 'Fix the failing unit tests. Run `dotnet test --verbosity normal` ' +
                       'locally to reproduce. Open the .trx results file for specific ' +
                       'assertion failure details.'
    },
    [PSCustomObject]@{
        Regex       = 'No test result files were found'
        Severity    = 'PIPELINE'
        Category    = 'evidence-missing'
        Phase       = 'TEST'
        SuggestedFix = 'The test runner produced no .trx output. Verify the test project ' +
                       'compiles successfully and that the `--results-directory` path pattern ' +
                       'in the workflow matches your actual project layout.'
    },
    [PSCustomObject]@{
        Regex       = '(?i)chocolatey.*(timeout|timed out|http error|connection timed out)'
        Severity    = 'FLAKY'
        Category    = 'infra'
        Phase       = 'PIPELINE'
        SuggestedFix = 'Chocolatey package install timed out — this is a transient ' +
                       'infrastructure issue. Re-run the workflow. If it recurs, pin the ' +
                       'package version or mirror the package to an internal feed.'
    },
    [PSCustomObject]@{
        Regex       = 'HTTP 503|connection refused|rate limit'
        Severity    = 'FLAKY'
        Category    = 'network'
        Phase       = 'PIPELINE'
        SuggestedFix = 'Transient network error detected. Re-run the workflow. ' +
                       'If rate limits are the cause, add exponential-backoff retry logic ' +
                       'or stagger API calls in the pipeline.'
    },
    [PSCustomObject]@{
        Regex       = 'Could not load file or assembly'
        Severity    = 'BLOCKER'
        Category    = 'dependency'
        Phase       = 'BUILD'
        SuggestedFix = 'A required assembly could not be loaded at runtime. Run ' +
                       '`dotnet restore` locally and verify all NuGet package references ' +
                       'are consistent. Check for version conflicts with `dotnet list package --outdated`.'
    }
)

# Combine all raw log text for analysis
$combinedLog = ''
if ($LogData.AllJobsRaw) {
    $combinedLog = $LogData.AllJobsRaw
}
if ($LogData.FailedSteps) {
    foreach ($step in $LogData.FailedSteps) {
        if ($step.RawLog) { $combinedLog += "`n" + $step.RawLog }
    }
}

$matchedPatterns = @()
foreach ($p in $knownPatterns) {
    if ($combinedLog -match $p.Regex) {
        $matchedLine = ($combinedLog -split "`n" |
            Where-Object { $_ -match $p.Regex } |
            Select-Object -First 1)
        $matchedPatterns += [PSCustomObject]@{
            Pattern     = $p
            MatchedLine = $matchedLine.Trim()
        }
    }
}

if ($matchedPatterns.Count -eq 0) {
    return [PSCustomObject]@{
        Severity     = $null
        Category     = $null
        Phase        = $null
        Confidence   = 'NONE'
        RawEvidence  = $null
        SuggestedFix = $null
    }
}

$primary = $matchedPatterns[0]

$confidence = switch ($matchedPatterns.Count) {
    1       { 'HIGH' }
    2       { 'MEDIUM' }
    default { 'LOW' }
}

return [PSCustomObject]@{
    Severity     = $primary.Pattern.Severity
    Category     = $primary.Pattern.Category
    Phase        = $primary.Pattern.Phase
    Confidence   = $confidence
    RawEvidence  = $primary.MatchedLine
    SuggestedFix = $primary.Pattern.SuggestedFix
}
