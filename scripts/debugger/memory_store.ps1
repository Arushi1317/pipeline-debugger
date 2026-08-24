<#
.SYNOPSIS
    Persistent memory store for the pipeline failure debugger.
    Tracks failure history per branch so recurrence can be reported.
.NOTES
    Dot-source this file to get Read-DebuggerHistory, Write-DebuggerHistory,
    and Get-RecurrenceMessage.
#>

$script:MemoryDir  = '.debugger-memory'
$script:MemoryFile = "$script:MemoryDir/history.json"

function Read-DebuggerHistory {
    <#
    .SYNOPSIS
        Loads the history array from disk. Returns an empty array when the
        file does not exist or cannot be parsed.
    #>
    if (-not (Test-Path $script:MemoryFile)) {
        return @()
    }
    try {
        $raw = Get-Content $script:MemoryFile -Raw -Encoding UTF8
        $parsed = $raw | ConvertFrom-Json
        # ConvertFrom-Json returns a single object when the JSON is a 1-element
        # array, so always wrap in @() to guarantee an array.
        return @($parsed)
    } catch {
        Write-Warning "Could not read debugger history from '$script:MemoryFile': $_"
        return @()
    }
}

function Write-DebuggerHistory {
    <#
    .SYNOPSIS
        Appends a new entry to the history file. Increments the recurrence
        counter when the same category and branch have been seen before.
    .PARAMETER Entry
        Hashtable with fields: date, runId, branch, category, phase, pattern,
        fixApplied. Any missing fields are defaulted.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Entry
    )

    if (-not (Test-Path $script:MemoryDir)) {
        New-Item -ItemType Directory -Path $script:MemoryDir -Force | Out-Null
    }

    $history = Read-DebuggerHistory

    $prior = @($history | Where-Object {
        $_.category -eq $Entry['category'] -and $_.branch -eq $Entry['branch']
    })
    $Entry['recurrence'] = $prior.Count + 1

    if (-not $Entry.ContainsKey('date') -or -not $Entry['date']) {
        $Entry['date'] = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssZ')
    }
    if (-not $Entry.ContainsKey('fixApplied')) {
        $Entry['fixApplied'] = $false
    }

    $newHistory = @($history) + @([PSCustomObject]$Entry)
    $newHistory | ConvertTo-Json -Depth 5 | Set-Content $script:MemoryFile -Encoding UTF8
}

function Get-RecurrenceMessage {
    <#
    .SYNOPSIS
        Returns a human-readable recurrence summary for the PR comment.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [int]$RecurrenceCount
    )

    switch ($RecurrenceCount) {
        1       { return 'First time seeing this failure on this branch' }
        2       { return 'This has failed the same way before — the previous fix was not applied' }
        default { return "Recurring pattern detected ($RecurrenceCount times) — recommend permanent fix not a workaround" }
    }
}
