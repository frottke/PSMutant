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

function Get-ActionPSMutantVersion {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$ActionPath)

    $manifestPath = Join-Path $ActionPath 'PSMutant.psd1'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "Missing PSMutant.psd1 in pinned action: $manifestPath"
    }
    $metadata = Import-PowerShellDataFile -Path $manifestPath
    $version = [string]$metadata.ModuleVersion
    if ($version -notmatch '^\d+\.\d+\.\d+(\.\d+)?$') {
        throw "Invalid ModuleVersion '$version' in pinned action manifest."
    }
    return $version
}

function Test-ActionPesterCompatibility {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [version]$Version,
        [Parameter(Mandatory)] [version]$PowerShellVersion
    )
    if ($PowerShellVersion -lt [version]'7.0' -or $Version -lt [version]'5.2.0') { return $false }
    # Pester 5.9+ and Pester 6 are supported with PowerShell 7.4+.
    if ($PowerShellVersion -lt [version]'7.4' -and $Version -ge [version]'5.9.0') { return $false }
    return $true
}

function Resolve-ActionPesterVersion {
    [CmdletBinding()]
    param(
        [AllowEmptyString()] [string]$RequestedVersion = '',
        [version]$PowerShellVersion = $PSVersionTable.PSVersion
    )
    if (-not [string]::IsNullOrWhiteSpace($RequestedVersion)) {
        if ($RequestedVersion -notmatch '^\d+\.\d+\.\d+$') {
            throw "pester-version requires an exact major.minor.patch version; got '$RequestedVersion'."
        }
        if (-not (Test-ActionPesterCompatibility -Version ([version]$RequestedVersion) -PowerShellVersion $PowerShellVersion)) {
            throw "Pester $RequestedVersion is not supported by this action on PowerShell $PowerShellVersion."
        }
        return $RequestedVersion
    }

    # Find-Module excludes prereleases unless AllowPrerelease is requested.
    $releases = @(Find-Module -Name Pester -AllVersions -Repository PSGallery -ErrorAction Stop)
    $compatible = @($releases | Where-Object {
            $candidate = [string]$_.Version
            if ($candidate -notmatch '^\d+\.\d+\.\d+(\.\d+)?$') { return $false }
            if (-not (Test-ActionPesterCompatibility -Version ([version]$candidate) -PowerShellVersion $PowerShellVersion)) {
                return $false
            }
            $minimum = [string]$_.PowerShellVersion
            return [string]::IsNullOrWhiteSpace($minimum) -or [version]$minimum -le $PowerShellVersion
        } | Sort-Object -Property Version -Descending)
    if ($compatible.Count -eq 0) {
        throw "PSGallery has no supported stable Pester release for PowerShell $PowerShellVersion."
    }
    return [string]$compatible[0].Version
}

function Save-ActionGalleryModule {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('PSMutant', 'Pester')] [string]$Name,
        [Parameter(Mandatory)] [string]$Version,
        [Parameter(Mandatory)] [string]$Destination
    )
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    Write-Host "Downloading $Name $Version from PSGallery."
    try {
        Save-Module -Name $Name -RequiredVersion $Version -Repository PSGallery -Path $Destination -Force -ErrorAction Stop
    }
    catch {
        throw "Cannot download $Name $Version from PSGallery. The version may not be published or the gallery may be unavailable. $($_.Exception.Message)"
    }
    $manifest = Join-Path $Destination "$Name/$Version/$Name.psd1"
    if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) {
        throw "PSGallery download did not contain the required $Name $Version manifest: $manifest"
    }
    return $manifest
}

function Import-ActionGalleryModule {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('PSMutant', 'Pester')] [string]$Name,
        [Parameter(Mandatory)] [string]$Version
    )
    if (-not $env:RUNNER_TEMP) { throw 'RUNNER_TEMP is missing.' }
    $stage = Join-Path $env:RUNNER_TEMP 'psmutant-dependencies'
    $manifest = Save-ActionGalleryModule -Name $Name -Version $Version -Destination $stage
    Import-Module -Name $manifest -Force -ErrorAction Stop
    $moduleBase = Split-Path -Parent $manifest
    $loaded = @(Get-Module -Name $Name | Where-Object {
            $_.Version -eq [version]$Version -and
            [System.IO.Path]::GetFullPath($_.ModuleBase) -eq [System.IO.Path]::GetFullPath($moduleBase)
        })
    if ($loaded.Count -ne 1) {
        throw "$Name $Version was not loaded from the expected PSGallery package directory."
    }
    Write-Host "Loaded $Name $Version from PSGallery."
}

function Write-ActionVersionSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$PSMutantVersion,
        [Parameter(Mandatory)] [string]$PesterVersion
    )
    $powerShellVersion = [string]$PSVersionTable.PSVersion
    Write-Host "Using PSMutant $PSMutantVersion (PSGallery), Pester $PesterVersion (PSGallery), PowerShell $powerShellVersion."
    if ($env:GITHUB_OUTPUT) {
        foreach ($entry in @(
                "psmutant-version=$PSMutantVersion",
                "pester-version=$PesterVersion",
                "powershell-version=$powerShellVersion"
            )) {
            Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value $entry -Encoding utf8
        }
    }
    if ($env:GITHUB_STEP_SUMMARY) {
        Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value @(
            '## Runtime versions'
            ''
            '| Component | Version | Source |'
            '| --- | --- | --- |'
            "| PSMutant | $PSMutantVersion | PSGallery |"
            "| Pester | $PesterVersion | PSGallery |"
            "| PowerShell | $powerShellVersion | Runner |"
            ''
        ) -Encoding utf8
    }
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

        $psmutantVersion = Get-ActionPSMutantVersion -ActionPath $env:GITHUB_ACTION_PATH
        $pesterVersion = Resolve-ActionPesterVersion -RequestedVersion $env:PSMUTANT_PESTER_VERSION
        Import-ActionGalleryModule -Name Pester -Version $pesterVersion
        Import-ActionGalleryModule -Name PSMutant -Version $psmutantVersion
        Write-ActionVersionSummary -PSMutantVersion $psmutantVersion -PesterVersion $pesterVersion
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
