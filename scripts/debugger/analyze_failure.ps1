<#
.SYNOPSIS
    Classifies pipeline failures by pattern-matching raw log text.
    Supports .NET/dotnet and Python stacks.
.OUTPUTS
    PSCustomObject: Severity, Category, Phase, Confidence, RawEvidence,
                    SuggestedFix (ImmediateFix/PermanentFix/DocsLink), Language
#>
param(
    [Parameter(Mandatory = $true)]
    [object]$LogData
)

function Detect-RepoLanguage {
    <#
    .SYNOPSIS
        Infers the primary tech stack from raw log text signals.
    #>
    param([string]$LogText)
    $hasDotnet = $LogText -match 'dotnet|msbuild|\.csproj|nuget'
    $hasPython = $LogText -match 'pytest|\bpip\b|\bpython\b|\.py\b'
    if ($hasDotnet -and $hasPython) { return 'mixed' }
    if ($hasDotnet)                 { return 'dotnet' }
    if ($hasPython)                 { return 'python' }
    return 'unknown'
}

# Concise constructor for 3-part fix objects
function New-Fix {
    param([string]$Immediate, [string]$Permanent, [string]$Docs)
    [PSCustomObject]@{ ImmediateFix = $Immediate; PermanentFix = $Permanent; DocsLink = $Docs }
}

# Ordered pattern list — first match wins for primary classification.
# MaxConfidence caps the confidence even when only one pattern matches.
$knownPatterns = @(

    # ── Existing patterns (regexes unchanged; fixes enriched) ─────────────────

    [PSCustomObject]@{
        Regex = 'pandoc not found|wkhtmltopdf not found'
        Severity = 'PIPELINE'; Category = 'tool-missing'; Phase = 'PIPELINE'; MaxConfidence = 'HIGH'
        SuggestedFix = New-Fix `
            'Set generate_pdf: false in your quality-gate config to unblock this PR immediately.' `
            'Add `choco install pandoc wkhtmltopdf` to the workflow setup phase and cache the binaries with actions/cache.' `
            'https://pandoc.org/installing.html'
    },

    [PSCustomObject]@{
        Regex = 'MSBUILD : error|Build FAILED'
        Severity = 'BLOCKER'; Category = 'build-error'; Phase = 'BUILD'; MaxConfidence = 'HIGH'
        SuggestedFix = New-Fix `
            'Check the MSBuild error code above — usually a missing project reference or syntax error in a .cs file.' `
            'Run `dotnet build` locally to reproduce. Check for missing PackageReferences in your .csproj.' `
            'https://learn.microsoft.com/en-us/visualstudio/msbuild/msbuild-errors'
    },

    [PSCustomObject]@{
        Regex = 'Test Run Failed|failed.*\.trx'
        Severity = 'BLOCKER'; Category = 'test-failure'; Phase = 'TEST'; MaxConfidence = 'HIGH'
        SuggestedFix = New-Fix `
            'One or more unit tests are failing. Run `dotnet test` locally and check the failing test names above.' `
            'Fix the failing tests. Open the .trx results file for specific assertion failure details.' `
            'https://learn.microsoft.com/en-us/dotnet/core/testing/'
    },

    [PSCustomObject]@{
        Regex = 'No test result files were found'
        Severity = 'PIPELINE'; Category = 'evidence-missing'; Phase = 'TEST'; MaxConfidence = 'HIGH'
        SuggestedFix = New-Fix `
            'Add `--logger trx` to your dotnet test command to generate .trx output.' `
            'Verify the `--results-directory` path pattern in the workflow matches your project layout.' `
            'https://learn.microsoft.com/en-us/dotnet/core/tools/dotnet-test'
    },

    [PSCustomObject]@{
        Regex = '(?i)chocolatey.*(timeout|timed out|http error|connection timed out)'
        Severity = 'FLAKY'; Category = 'infra'; Phase = 'PIPELINE'; MaxConfidence = 'HIGH'
        SuggestedFix = New-Fix `
            'Chocolatey had a network issue — simply rerun the pipeline; this is not your code.' `
            'Pin the Chocolatey package version or mirror the package to an internal feed to prevent recurrence.' `
            'https://docs.chocolatey.org/en-us/troubleshooting/'
    },

    [PSCustomObject]@{
        Regex = 'HTTP 503|connection refused|rate limit'
        Severity = 'FLAKY'; Category = 'network'; Phase = 'PIPELINE'; MaxConfidence = 'HIGH'
        SuggestedFix = New-Fix `
            'Transient network error — re-run the workflow.' `
            'Add exponential-backoff retry logic or stagger API calls to avoid rate limits.' `
            'https://docs.github.com/en-us/rest/using-the-rest-api/rate-limits-for-the-rest-api'
    },

    [PSCustomObject]@{
        Regex = 'Could not load file or assembly'
        Severity = 'BLOCKER'; Category = 'dependency'; Phase = 'BUILD'; MaxConfidence = 'HIGH'
        SuggestedFix = New-Fix `
            'Run `dotnet restore` locally and verify all NuGet package references are consistent.' `
            'Check for version conflicts with `dotnet list package --outdated` and pin conflicting packages.' `
            'https://learn.microsoft.com/en-us/dotnet/core/dependency-loading/overview'
    },

    # ── New .NET compiler patterns ─────────────────────────────────────────────

    [PSCustomObject]@{
        Regex = 'error CS[0-9]+'
        Severity = 'BLOCKER'; Category = 'build-error'; Phase = 'BUILD'; MaxConfidence = 'HIGH'
        SuggestedFix = New-Fix `
            'C# compiler error. The CS error code above tells you exactly what line to fix.' `
            'Run `dotnet build --verbosity detailed` locally. The output includes file name and line number.' `
            'https://learn.microsoft.com/en-us/dotnet/csharp/language-reference/compiler-messages/'
    },

    [PSCustomObject]@{
        Regex = 'The type or namespace.*could not be found'
        Severity = 'BLOCKER'; Category = 'build-error'; Phase = 'BUILD'; MaxConfidence = 'HIGH'
        SuggestedFix = New-Fix `
            'Missing using statement or PackageReference. Add the correct NuGet package to your .csproj.' `
            'Run `dotnet add package <PackageName>` or verify the using directive is present in the source file.' `
            'https://learn.microsoft.com/en-us/dotnet/csharp/language-reference/compiler-messages/cs0246'
    },

    [PSCustomObject]@{
        Regex = 'Duplicate.*attribute'
        Severity = 'BLOCKER'; Category = 'build-error'; Phase = 'BUILD'; MaxConfidence = 'MEDIUM'
        SuggestedFix = New-Fix `
            'You have a duplicate attribute or property. Check AssemblyInfo.cs and your .csproj for duplicates.' `
            'In SDK-style projects, remove AssemblyInfo.cs or set `<GenerateAssemblyInfo>false</GenerateAssemblyInfo>` in your .csproj.' `
            'https://learn.microsoft.com/en-us/dotnet/core/project-sdk/msbuild-props#generateassemblyinfo'
    },

    [PSCustomObject]@{
        Regex = 'ambiguous reference'
        Severity = 'BLOCKER'; Category = 'build-error'; Phase = 'BUILD'; MaxConfidence = 'MEDIUM'
        SuggestedFix = New-Fix `
            'Two packages define the same type. Add a fully qualified namespace or remove the conflicting package.' `
            'Use a using alias: `using Alias = Full.Namespace.Type;` to resolve the ambiguity.' `
            'https://learn.microsoft.com/en-us/dotnet/csharp/language-reference/compiler-messages/cs0104'
    },

    # ── New .NET test-failure patterns ─────────────────────────────────────────

    [PSCustomObject]@{
        Regex = 'failed.*Assert'
        Severity = 'BLOCKER'; Category = 'test-failure'; Phase = 'TEST'; MaxConfidence = 'HIGH'
        SuggestedFix = New-Fix `
            'An assertion failed in a test. The expected vs actual values are shown in the log above.' `
            'Run `dotnet test --filter "FullyQualifiedName~FailingTestName"` locally to isolate and fix the test.' `
            'https://learn.microsoft.com/en-us/dotnet/core/testing/unit-testing-best-practices'
    },

    [PSCustomObject]@{
        Regex = 'System\.NullReferenceException'
        Severity = 'BLOCKER'; Category = 'runtime-crash'; Phase = 'TEST'; MaxConfidence = 'HIGH'
        SuggestedFix = New-Fix `
            'A null reference exception in a test. Check for uninitialized objects in your test setup or the code under test.' `
            'Use null-conditional operators (`?.`) and add null guards in the code changed by this PR.' `
            'https://learn.microsoft.com/en-us/dotnet/api/system.nullreferenceexception'
    },

    [PSCustomObject]@{
        Regex = 'System\.ArgumentException'
        Severity = 'BLOCKER'; Category = 'runtime-crash'; Phase = 'TEST'; MaxConfidence = 'MEDIUM'
        SuggestedFix = New-Fix `
            'An invalid argument was passed. Check method parameters in the code changed by this PR.' `
            'Add parameter validation with `ArgumentNullException.ThrowIfNull()` and `ArgumentOutOfRangeException.ThrowIfNegative()`.' `
            'https://learn.microsoft.com/en-us/dotnet/api/system.argumentexception'
    },

    [PSCustomObject]@{
        Regex = 'System\.InvalidOperationException'
        Severity = 'BLOCKER'; Category = 'runtime-crash'; Phase = 'TEST'; MaxConfidence = 'MEDIUM'
        SuggestedFix = New-Fix `
            'Invalid operation — often caused by calling a method on an object in the wrong state.' `
            'Review the object lifecycle in the code changed by this PR. Add precondition checks before calling the method.' `
            'https://learn.microsoft.com/en-us/dotnet/api/system.invalidoperationexception'
    },

    [PSCustomObject]@{
        Regex = '(?i)no tests ran'
        Severity = 'PIPELINE'; Category = 'evidence-missing'; Phase = 'TEST'; MaxConfidence = 'MEDIUM'
        SuggestedFix = New-Fix `
            'Test discovery failed. Ensure test methods are marked with [Fact] or [Test] and the test project is referenced.' `
            'Run `dotnet test --list-tests` locally to verify test discovery is working.' `
            'https://learn.microsoft.com/en-us/dotnet/core/tools/dotnet-test'
    },

    [PSCustomObject]@{
        Regex = '(?i)xunit.*could not be found'
        Severity = 'BLOCKER'; Category = 'dependency'; Phase = 'BUILD'; MaxConfidence = 'HIGH'
        SuggestedFix = New-Fix `
            'xUnit package missing. Add `<PackageReference Include="xunit" />` to your test .csproj.' `
            'Run `dotnet add package xunit && dotnet add package xunit.runner.visualstudio`.' `
            'https://xunit.net/docs/getting-started/netcore/cmdline'
    },

    # ── New .NET coverage patterns ─────────────────────────────────────────────

    [PSCustomObject]@{
        Regex = '(?i)coverlet.*not found'
        Severity = 'PIPELINE'; Category = 'tool-missing'; Phase = 'PIPELINE'; MaxConfidence = 'HIGH'
        SuggestedFix = New-Fix `
            'Add coverlet.collector PackageReference to your test .csproj.' `
            'Add a dotnet restore verification step to your workflow to catch missing packages early.' `
            'https://learn.microsoft.com/en-us/dotnet/core/testing/unit-testing-code-coverage'
    },

    [PSCustomObject]@{
        Regex = '(?i)coverage.*not generated'
        Severity = 'PIPELINE'; Category = 'evidence-missing'; Phase = 'TEST'; MaxConfidence = 'MEDIUM'
        SuggestedFix = New-Fix `
            'Add `--collect:"XPlat Code Coverage"` to your dotnet test command.' `
            'Ensure coverlet.collector is installed and add a restore step before running tests.' `
            'https://learn.microsoft.com/en-us/dotnet/core/testing/unit-testing-code-coverage'
    },

    # ── New .NET infrastructure patterns ──────────────────────────────────────

    [PSCustomObject]@{
        Regex = '(?i)dotnet.*restore.*failed'
        Severity = 'BLOCKER'; Category = 'dependency'; Phase = 'BUILD'; MaxConfidence = 'HIGH'
        SuggestedFix = New-Fix `
            'NuGet restore failed. Check your package sources and that all PackageReference versions exist on NuGet.org.' `
            'Add `dotnet nuget list source` to your workflow to verify feed configuration on each run.' `
            'https://learn.microsoft.com/en-us/dotnet/core/tools/dotnet-restore'
    },

    [PSCustomObject]@{
        Regex = 'NuGet.*(401|403)'
        Severity = 'PIPELINE'; Category = 'permissions'; Phase = 'PIPELINE'; MaxConfidence = 'HIGH'
        SuggestedFix = New-Fix `
            'NuGet authentication failed. Check that your NuGet feed credentials or PAT are correctly configured in the workflow.' `
            'Store feed credentials as GitHub Secrets and pass them via the `NUGET_AUTH_TOKEN` environment variable.' `
            'https://learn.microsoft.com/en-us/nuget/consume-packages/consuming-packages-authenticated-feeds'
    },

    [PSCustomObject]@{
        Regex = '(?i)SDK.*not found'
        Severity = 'PIPELINE'; Category = 'tool-missing'; Phase = 'PIPELINE'; MaxConfidence = 'HIGH'
        SuggestedFix = New-Fix `
            'The .NET SDK version specified in global.json is not installed on the runner. Update the `dotnet-version` in your setup-dotnet step.' `
            'Pin your SDK version in global.json and keep the workflow `dotnet-version` value in sync.' `
            'https://learn.microsoft.com/en-us/dotnet/core/tools/global-json'
    },

    # ── Python — environment / dependency patterns ─────────────────────────────

    [PSCustomObject]@{
        Regex = 'ModuleNotFoundError: No module named'
        Severity = 'BLOCKER'; Category = 'dependency'; Phase = 'BUILD'; MaxConfidence = 'HIGH'
        SuggestedFix = New-Fix `
            'A Python package is missing. Add it to requirements.txt and ensure `pip install -r requirements.txt` runs before your tests.' `
            'Pin the package version in requirements.txt and add a CI step to verify the virtual environment.' `
            'https://docs.python.org/3/library/exceptions.html#ModuleNotFoundError'
    },

    [PSCustomObject]@{
        Regex = '\bImportError\b'
        Severity = 'BLOCKER'; Category = 'dependency'; Phase = 'BUILD'; MaxConfidence = 'HIGH'
        SuggestedFix = New-Fix `
            'A module failed to import. Check that the package is in requirements.txt and is compatible with your Python version.' `
            'Run `pip install -r requirements.txt` locally using the same Python version as the runner.' `
            'https://docs.python.org/3/library/exceptions.html#ImportError'
    },

    [PSCustomObject]@{
        Regex = '\bSyntaxError\b'
        Severity = 'BLOCKER'; Category = 'syntax-error'; Phase = 'BUILD'; MaxConfidence = 'HIGH'
        SuggestedFix = New-Fix `
            'Python syntax error. Run `python -m py_compile yourfile.py` locally to find the exact line.' `
            'Add a linting step (`flake8` or `ruff`) to your CI workflow to catch syntax errors before they reach the test phase.' `
            'https://docs.python.org/3/library/exceptions.html#SyntaxError'
    },

    [PSCustomObject]@{
        Regex = '\bIndentationError\b'
        Severity = 'BLOCKER'; Category = 'syntax-error'; Phase = 'BUILD'; MaxConfidence = 'HIGH'
        SuggestedFix = New-Fix `
            'Python indentation error. Check for mixed tabs and spaces in the file shown above.' `
            'Configure your editor to use spaces only and add `ruff check --select E1` to your CI workflow.' `
            'https://docs.python.org/3/library/exceptions.html#IndentationError'
    },

    [PSCustomObject]@{
        Regex = '(?i)pip.*ERROR'
        Severity = 'PIPELINE'; Category = 'dependency'; Phase = 'PIPELINE'; MaxConfidence = 'HIGH'
        SuggestedFix = New-Fix `
            'pip failed to install a package. Check the package name and version in requirements.txt.' `
            'Pin all package versions using `pip freeze > requirements.txt` from a known-good environment.' `
            'https://pip.pypa.io/en/stable/topics/dependency-resolution/'
    },

    [PSCustomObject]@{
        Regex = '(?i)pip.*could not find a version'
        Severity = 'BLOCKER'; Category = 'dependency'; Phase = 'BUILD'; MaxConfidence = 'HIGH'
        SuggestedFix = New-Fix `
            'Package version not found on PyPI. Check the exact version number in requirements.txt.' `
            'Run `pip index versions <packagename>` to see available versions and update requirements.txt accordingly.' `
            'https://pip.pypa.io/en/stable/topics/dependency-resolution/'
    },

    [PSCustomObject]@{
        Regex = '(?i)python.*not found'
        Severity = 'PIPELINE'; Category = 'tool-missing'; Phase = 'PIPELINE'; MaxConfidence = 'HIGH'
        SuggestedFix = New-Fix `
            'Python is not available on the runner. Add an `actions/setup-python` step to your workflow.' `
            'Pin the Python version in `actions/setup-python` and add a `.python-version` file to the repo.' `
            'https://docs.github.com/en-us/actions/use-cases-and-examples/building-and-testing/building-and-testing-python'
    },

    [PSCustomObject]@{
        Regex = '(?i)virtualenv.*error'
        Severity = 'PIPELINE'; Category = 'environment'; Phase = 'PIPELINE'; MaxConfidence = 'MEDIUM'
        SuggestedFix = New-Fix `
            'Virtual environment setup failed. Check your Python version compatibility.' `
            'Use `actions/setup-python` with `cache: pip` instead of managing virtualenv manually in CI.' `
            'https://virtualenv.pypa.io/en/latest/'
    },

    # ── Python — test-failure patterns ────────────────────────────────────────

    [PSCustomObject]@{
        Regex = 'FAILED tests/'
        Severity = 'BLOCKER'; Category = 'test-failure'; Phase = 'TEST'; MaxConfidence = 'HIGH'
        SuggestedFix = New-Fix `
            'pytest test failed. Run `pytest -v` locally to see the full failure output.' `
            'Fix the failing test. Check the pytest output above for the test name and full traceback.' `
            'https://docs.pytest.org/en/stable/how-to/output.html'
    },

    [PSCustomObject]@{
        Regex = '(?i)pytest.*error'
        Severity = 'BLOCKER'; Category = 'test-failure'; Phase = 'TEST'; MaxConfidence = 'HIGH'
        SuggestedFix = New-Fix `
            'pytest encountered an error. Check the traceback above for the exact line that failed.' `
            'Run `pytest --tb=long` locally to see the full traceback for all failures.' `
            'https://docs.pytest.org/en/stable/reference/exit-codes.html'
    },

    [PSCustomObject]@{
        Regex = '\bAssertionError\b'
        Severity = 'BLOCKER'; Category = 'test-failure'; Phase = 'TEST'; MaxConfidence = 'HIGH'
        SuggestedFix = New-Fix `
            'A test assertion failed. The expected vs actual values are shown in the traceback above.' `
            'Run `pytest -v -s` locally for full output. Use `pytest.approx()` for floating-point comparisons.' `
            'https://docs.pytest.org/en/stable/how-to/assert.html'
    },

    [PSCustomObject]@{
        Regex = 'E   assert'
        Severity = 'BLOCKER'; Category = 'test-failure'; Phase = 'TEST'; MaxConfidence = 'HIGH'
        SuggestedFix = New-Fix `
            'pytest assertion failed. Review the assert statement in the test shown above.' `
            'Run `pytest --tb=short` locally to get a concise view of all failing assertions.' `
            'https://docs.pytest.org/en/stable/how-to/assert.html'
    },

    [PSCustomObject]@{
        Regex = 'collected 0 items'
        Severity = 'PIPELINE'; Category = 'evidence-missing'; Phase = 'TEST'; MaxConfidence = 'HIGH'
        SuggestedFix = New-Fix `
            'pytest found no tests to run. Check that test files are named `test_*.py` or `*_test.py` and are in the correct directory.' `
            'Add `testpaths` to your `pytest.ini` or `pyproject.toml` to explicitly point pytest at your test directory.' `
            'https://docs.pytest.org/en/stable/reference/ini-options.html#testpaths'
    },

    [PSCustomObject]@{
        Regex = '\bTypeError\b'
        Severity = 'BLOCKER'; Category = 'runtime-crash'; Phase = 'TEST'; MaxConfidence = 'MEDIUM'
        SuggestedFix = New-Fix `
            'A TypeError occurred in a test. Usually caused by passing wrong types to a function — check the traceback.' `
            'Add type hints and run `mypy` locally to catch type mismatches before they reach CI.' `
            'https://docs.python.org/3/library/exceptions.html#TypeError'
    },

    [PSCustomObject]@{
        Regex = '\bAttributeError\b'
        Severity = 'BLOCKER'; Category = 'runtime-crash'; Phase = 'TEST'; MaxConfidence = 'MEDIUM'
        SuggestedFix = New-Fix `
            'An attribute that does not exist was accessed. Check that the object type is correct in the code changed by this PR.' `
            'Add `hasattr()` guards or use type hints with `mypy` to catch attribute errors before CI.' `
            'https://docs.python.org/3/library/exceptions.html#AttributeError'
    },

    # ── Python — coverage patterns ─────────────────────────────────────────────

    [PSCustomObject]@{
        Regex = '(?i)coverage.*no data'
        Severity = 'PIPELINE'; Category = 'evidence-missing'; Phase = 'TEST'; MaxConfidence = 'MEDIUM'
        SuggestedFix = New-Fix `
            'Coverage data was not collected. Add `--cov=.` to your pytest command and ensure pytest-cov is in requirements.txt.' `
            'Add `pytest-cov` to requirements.txt and configure `[tool.pytest.ini_options]` in pyproject.toml.' `
            'https://coverage.readthedocs.io/en/latest/'
    },

    [PSCustomObject]@{
        Regex = 'CoverageWarning'
        Severity = 'PIPELINE'; Category = 'evidence-missing'; Phase = 'TEST'; MaxConfidence = 'LOW'
        SuggestedFix = New-Fix `
            'Coverage collection had a warning. Check your .coveragerc configuration.' `
            'Review your .coveragerc or pyproject.toml `[tool.coverage]` section for misconfiguration.' `
            'https://coverage.readthedocs.io/en/latest/warnings.html'
    }
)

# ------------------------------------------------------------------
# Combine all raw log text for analysis
# ------------------------------------------------------------------
$combinedLog = ''
if ($LogData.AllJobsRaw) {
    $combinedLog = $LogData.AllJobsRaw
}
if ($LogData.FailedSteps) {
    foreach ($step in $LogData.FailedSteps) {
        if ($step.RawLog) { $combinedLog += "`n" + $step.RawLog }
    }
}

$language = Detect-RepoLanguage -LogText $combinedLog

# ------------------------------------------------------------------
# Match patterns against combined log text
# ------------------------------------------------------------------
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
        Language     = $language
    }
}

$primary = $matchedPatterns[0]

# 1 match → HIGH; 2+ matches → MEDIUM (3+ no longer degrades to LOW)
$countConfidence = if ($matchedPatterns.Count -eq 1) { 'HIGH' } else { 'MEDIUM' }

# Apply per-pattern maximum confidence cap
$confidence = switch ($primary.Pattern.MaxConfidence) {
    'LOW'    { 'LOW' }
    'MEDIUM' { if ($countConfidence -eq 'HIGH') { 'MEDIUM' } else { $countConfidence } }
    default  { $countConfidence }
}

# For multiple matches, join all matched lines as evidence
$rawEvidence = if ($matchedPatterns.Count -eq 1) {
    $primary.MatchedLine
} else {
    ($matchedPatterns | ForEach-Object { $_.MatchedLine }) -join ' | '
}

return [PSCustomObject]@{
    Severity     = $primary.Pattern.Severity
    Category     = $primary.Pattern.Category
    Phase        = $primary.Pattern.Phase
    Confidence   = $confidence
    RawEvidence  = $rawEvidence
    SuggestedFix = $primary.Pattern.SuggestedFix
    Language     = $language
}
