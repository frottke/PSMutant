# The action itself runs unmodified PSMutant; these tests pin the CI-specific decisions.
BeforeAll {
    . (Join-Path (Split-Path -Parent $PSScriptRoot) 'action' 'Invoke-Action.ps1')
}

Describe 'Get-ActionMode' {
    It 'selects changed files on a pull request' {
        Get-ActionMode -Mode auto -EventName pull_request | Should -Be 'changed'
    }
    It 'runs the full tree for a push' {
        Get-ActionMode -Mode auto -EventName push | Should -Be 'full'
    }
    It 'allows an explicit full run on a pull request' {
        Get-ActionMode -Mode full -EventName pull_request | Should -Be 'full'
    }
    It 'refuses changed mode outside a pull request' {
        { Get-ActionMode -Mode changed -EventName push } | Should -Throw '*requires a pull_request event*'
    }
}

Describe 'Get-ActionChangedFiles' {
    BeforeAll {
        $script:repo = Join-Path $TestDrive 'repo'
        New-Item -ItemType Directory -Path (Join-Path $script:repo 'package') -Force | Out-Null
        & git -C $script:repo init --quiet
        'before' | Set-Content (Join-Path $script:repo 'package/example.ps1')
        & git -C $script:repo add .
        & git -C $script:repo -c user.name=PSMutant -c user.email=psmutant@example.com commit --quiet -m base
        $script:base = (& git -C $script:repo rev-parse HEAD).Trim()
        'after' | Set-Content (Join-Path $script:repo 'package/example.ps1')
        'docs' | Set-Content (Join-Path $script:repo 'README.md')
        & git -C $script:repo add .
        & git -C $script:repo -c user.name=PSMutant -c user.email=psmutant@example.com commit --quiet -m change
        $script:eventPath = Join-Path $TestDrive 'event.json'
        @{ pull_request = @{ base = @{ sha = $script:base } } } |
            ConvertTo-Json -Depth 5 | Set-Content $script:eventPath
    }
    It 'returns paths relative to a nested source root' {
        $changed = @(Get-ActionChangedFiles -EventPath $script:eventPath -SourceRoot (Join-Path $script:repo 'package'))
        $changed.Count | Should -Be 1
        $changed[0] | Should -Be 'example.ps1'
    }
    It 'rejects a missing base commit, never treating it as an empty diff' {
        @{ pull_request = @{ base = @{ sha = ('0' * 40) } } } |
            ConvertTo-Json -Depth 5 | Set-Content $script:eventPath
        { Get-ActionChangedFiles -EventPath $script:eventPath -SourceRoot $script:repo } |
            Should -Throw '*base commit*unavailable*'
    }
}

Describe 'Write-ActionResult' {
    BeforeEach {
        $script:previousOutput = $env:GITHUB_OUTPUT
        $script:previousSummary = $env:GITHUB_STEP_SUMMARY
        $env:GITHUB_OUTPUT = Join-Path $TestDrive 'action-output.txt'
        $env:GITHUB_STEP_SUMMARY = Join-Path $TestDrive 'action-summary.md'
        Set-Content $env:GITHUB_OUTPUT ''
        Set-Content $env:GITHUB_STEP_SUMMARY ''
    }
    AfterEach {
        $env:GITHUB_OUTPUT = $script:previousOutput
        $env:GITHUB_STEP_SUMMARY = $script:previousSummary
    }
    It 'retains the failure reason and counts even when the gate fails' {
        Write-ActionResult -Result ([pscustomobject]@{
            Score = 50.5; Killed = 2; Survived = 2; Total = 4
            Mode = 'Full'; ExitCode = 1; FailureReason = 'BelowThreshold'
        })
        $output = Get-Content $env:GITHUB_OUTPUT -Raw
        $output | Should -Match 'score=50\.5'
        $output | Should -Match 'exit-code=1'
        $output | Should -Match 'failure-reason=BelowThreshold'
        (Get-Content $env:GITHUB_STEP_SUMMARY -Raw) | Should -Match 'Failed'
    }
    It 'does not manufacture a score for a skipped package' {
        Write-ActionResult -Skipped
        $output = Get-Content $env:GITHUB_OUTPUT -Raw
        $output | Should -Match 'skipped=true'
        $output | Should -Match '(?m)^score=\r?$'
        (Get-Content $env:GITHUB_STEP_SUMMARY -Raw) | Should -Match 'Skipped'
    }
}

Describe 'Gallery dependency contract' {
    It 'reads the exact module version from the pinned action manifest' {
        $folder = Join-Path $TestDrive 'fake-action'
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
        '@{ ModuleVersion = "1.2.3" }' | Set-Content (Join-Path $folder 'PSMutant.psd1')
        Get-ActionPSMutantVersion -ActionPath $folder | Should -Be '1.2.3'
    }

    It 'rejects a missing action manifest' {
        { Get-ActionPSMutantVersion -ActionPath $TestDrive } | Should -Throw '*Missing PSMutant.psd1*'
    }

    It 'selects the latest stable compatible Pester version' {
        Mock Find-Module {
            @(
                [pscustomobject]@{ Version = [version]'5.8.0'; PowerShellVersion = '5.1' }
                [pscustomobject]@{ Version = [version]'5.9.1'; PowerShellVersion = '5.1' }
                [pscustomobject]@{ Version = [version]'6.2.0'; PowerShellVersion = '5.1' }
            )
        }
        Resolve-ActionPesterVersion -PowerShellVersion ([version]'7.3') | Should -Be '5.8.0'
        Resolve-ActionPesterVersion -PowerShellVersion ([version]'7.4') | Should -Be '6.2.0'
        Should -Invoke Find-Module -Exactly -Times 2
    }

    It 'does not query versions when an explicit compatible Pester version was provided' {
        Mock Find-Module { throw 'unexpected query' }
        Resolve-ActionPesterVersion -RequestedVersion '5.8.0' -PowerShellVersion ([version]'7.4') | Should -Be '5.8.0'
        Should -Not -Invoke Find-Module
    }

    It 'rejects an incompatible Pester override' {
        { Resolve-ActionPesterVersion -RequestedVersion '6.2.0' -PowerShellVersion ([version]'7.3') } | Should -Throw '*not supported*'
    }

    It 'downloads exactly the manifest-derived version from PSGallery' {
        Mock Save-Module {
            $folder = Join-Path $Path "$Name/$RequiredVersion"
            New-Item -ItemType Directory -Path $folder -Force | Out-Null
            Set-Content -Path (Join-Path $folder "$Name.psd1") -Value '@{}'
        }
        $manifest = Save-ActionGalleryModule -Name PSMutant -Version '1.2.3' -Destination $TestDrive
        $manifest | Should -Be (Join-Path $TestDrive 'PSMutant/1.2.3/PSMutant.psd1')
        Should -Invoke Save-Module -Exactly -Times 1 -ParameterFilter {
            $Name -eq 'PSMutant' -and $RequiredVersion -eq '1.2.3' -and $Repository -eq 'PSGallery'
        }
    }

    It 'fails when the pinned module version is unavailable in PSGallery' {
        Mock Save-Module { throw 'not published' }
        { Save-ActionGalleryModule -Name PSMutant -Version '9.9.9' -Destination $TestDrive } | Should -Throw '*Cannot download PSMutant 9.9.9*'
    }
}
