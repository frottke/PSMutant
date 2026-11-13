# GitHub Actions integration for the module checked out at GITHUB_ACTION_PATH.
# This file can be dot-sourced by unit tests without starting a mutation run.

function Get-ActionMode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('auto', 'full', 'changed')] [string]$Mode,
        [string]$EventName
    )
    if ($Mode -eq 'auto') {
        return $EventName -eq 'pull_request' ? 'changed' : 'full'
    }
    if ($Mode -eq 'changed' -and $EventName -ne 'pull_request') {
        throw "mode 'changed' requires a pull_request event. Use 'full' for other events."
    }
    return $Mode
}

function Get-ActionChangedFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$EventPath,
        [Parameter(Mandatory)] [string]$SourceRoot
    )
    if (-not (Test-Path -LiteralPath $EventPath -PathType Leaf)) {
        throw "Pull request event file is missing: $EventPath"
    }
    $eventData = Get-Content -LiteralPath $EventPath -Raw | ConvertFrom-Json
    $base = [string]$eventData.pull_request.base.sha
    if ($base -notmatch '^[0-9a-fA-F]{40}$') {
        throw 'Pull request event does not contain a valid base commit SHA.'
    }

    # Verify the base is present. An unfetched base must never look like an empty diff.
    & git -C $SourceRoot cat-file -e "$base^{commit}" 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "Pull request base commit $base is unavailable. Use actions/checkout with fetch-depth: 0."
    }

    # The unscoped diff establishes that the comparison was meaningful. The second diff
    # makes paths relative to source-root and can legitimately be empty in a monorepo.
    $all = @(& git -C $SourceRoot -c core.quotepath=false diff --no-ext-diff --name-only "$base...HEAD" --)
    if ($LASTEXITCODE -ne 0 -or $all.Count -eq 0) {
        throw 'Pull request diff returned no files (or failed). Refusing to report an unmeasured success.'
    }
    $relative = @(& git -C $SourceRoot -c core.quotepath=false diff --no-ext-diff --relative --name-only "$base...HEAD" --)
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to compute the pull request diff relative to source-root.'
    }
    return $relative
}

function Import-ActionPester {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Version)

    if ($Version -notmatch '^\d+\.\d+\.\d+$') {
        throw "pester-version must be an exact major.minor.patch version, got '$Version'."
    }
    $wanted = [version]$Version
    if ($wanted -lt [version]'5.2.0') {
        throw 'PSMutant requires Pester 5.2.0 or later.'
    }
    if ($PSVersionTable.PSVersion -lt [version]'7.4' -and $wanted.Major -ge 6) {
        throw 'On PowerShell 7.0 through 7.3, select Pester 5.x (for example 5.7.1).'
    }
    $loaded = Get-Module -Name Pester
    if ($loaded -and $loaded.Version -ne $wanted) {
        throw "Pester $($loaded.Version) is already loaded; cannot safely load $Version in the same process."
    }

    $available = Get-Module -ListAvailable -Name Pester |
        Where-Object { $_.Version -eq $wanted } | Select-Object -First 1
    if ($available) {
        Import-Module -Name $available.Path -ErrorAction Stop
    }
    else {
        # Action-local install avoids admin rights, CurrentUser module paths, and version clashes.
        $stage = Join-Path $env:RUNNER_TEMP 'psmutant-dependencies'
        New-Item -ItemType Directory -Path $stage -Force | Out-Null
        Write-Host "Downloading Pester $Version into $stage"
        Save-Module -Name Pester -RequiredVersion $Version -Path $stage -Force -ErrorAction Stop
        $manifest = Join-Path $stage "Pester/$Version/Pester.psd1"
        if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) {
            throw "Pester $Version was downloaded but $manifest is missing."
        }
        Import-Module -Name $manifest -ErrorAction Stop
    }

    $actual = Get-Module -Name Pester
    if (-not $actual -or $actual.Version -ne $wanted) {
        throw "Pester $Version was not loaded successfully."
    }
    Write-Host "Using Pester $($actual.Version)"
}

function Write-ActionResult {
    [CmdletBinding()]
    param(
        $Result,
        [switch]$Skipped
    )
    $values = [ordered]@{
        score            = ''
        killed           = ''
        survived         = ''
        total            = ''
        mode             = 'Changed'
        'exit-code'      = '0'
        'failure-reason' = 'None'
        skipped          = $Skipped.IsPresent.ToString().ToLowerInvariant()
    }
    if (-not $Skipped) {
        $values.score = ([double]$Result.Score).ToString('0.##', [cultureinfo]::InvariantCulture)
        $values.killed = [string]$Result.Killed
        $values.survived = [string]$Result.Survived
        $values.total = [string]$Result.Total
        $values.mode = [string]$Result.Mode
        $values['exit-code'] = [string]$Result.ExitCode
        $values['failure-reason'] = [string]$Result.FailureReason
    }
    if ($env:GITHUB_OUTPUT) {
        foreach ($name in $values.Keys) {
            Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "$name=$($values[$name])" -Encoding utf8
        }
    }
    $status = if ($Skipped) { 'Skipped: no changed files under source-root' }
    elseif ($Result.ExitCode -ne 0) { 'Failed' }
    else { 'Passed' }
    $summary = @(
        '# PSMutant'
        ''
        "**Status:** $status"
        ''
        '| Mode | Score | Killed | Survived | Total | Failure reason |'
        '| --- | ---: | ---: | ---: | ---: | --- |'
        "| $($values.mode) | $($values.score) | $($values.killed) | $($values.survived) | $($values.total) | $($values['failure-reason']) |"
    )
    if ($env:GITHUB_STEP_SUMMARY) {
        Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value ($summary -join [Environment]::NewLine) -Encoding utf8
    }
}

function Invoke-Action {
    [CmdletBinding()]
    param()
    $ErrorActionPreference = 'Stop'
    $wroteResult = $false
    try {
        if ($env:PSMUTANT_QUIET -notin @('true', 'false')) {
            throw "quiet must be 'true' or 'false'."
        }
        if (-not $env:GITHUB_WORKSPACE -or -not $env:GITHUB_ACTION_PATH) {
            throw 'This script must be run by the PSMutant GitHub composite action.'
        }
        $workspace = (Resolve-Path -LiteralPath $env:GITHUB_WORKSPACE).Path
        $rootInput = $env:PSMUTANT_SOURCE_ROOT
        $rootPath = if ([System.IO.Path]::IsPathRooted($rootInput)) { $rootInput }
        else { Join-Path $workspace $rootInput }
        $sourceRoot = (Resolve-Path -LiteralPath $rootPath -ErrorAction Stop).Path
        if (-not (Test-Path -LiteralPath $sourceRoot -PathType Container)) {
            throw "source-root is not a directory: $sourceRoot"
        }

        $configInput = $env:PSMUTANT_CONFIG_FILE
        $configPath = if ([System.IO.Path]::IsPathRooted($configInput)) { $configInput }
        else { Join-Path $workspace $configInput }
        if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
            throw "PSMutant config file not found: $configPath"
        }
        $mode = Get-ActionMode -Mode $env:PSMUTANT_MODE -EventName $env:GITHUB_EVENT_NAME
        $run = @{
            ConfigFile = $configPath
            SourceRoot = $sourceRoot
            Quiet = ($env:PSMUTANT_QUIET -eq 'true')
        }
        if ($mode -eq 'changed') {
            $changed = @(Get-ActionChangedFiles -EventPath $env:GITHUB_EVENT_PATH -SourceRoot $sourceRoot)
            if ($changed.Count -eq 0) {
                # Only possible after validating a nonempty repo-wide PR diff: the change is
                # outside this package. Do not invent a score or touch the full report.
                Write-ActionResult -Skipped
                $wroteResult = $true
                Write-Host 'No pull request changes under source-root; mutation run skipped.'
                return
            }
            $run.ChangedFile = $changed
        }

        Import-ActionPester -Version $env:PSMUTANT_PESTER_VERSION
        Import-Module -Name (Join-Path $env:GITHUB_ACTION_PATH 'PSMutant.psd1') -Force -ErrorAction Stop
        $result = Invoke-PSMutation @run
        Write-ActionResult -Result $result
        $wroteResult = $true
        if ($result.ExitCode -ne 0) {
            Write-Host "Mutation gate verdict: $($result.FailureReason) (score $($result.Score)%, $($result.Killed)/$($result.Total) killed)."
        }
    }
    catch {
        if (-not $wroteResult -and $env:GITHUB_STEP_SUMMARY) {
            Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value "PSMutant failed before returning a mutation result: $($_.Exception.Message)" -Encoding utf8
        }
        throw
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-Action
}
