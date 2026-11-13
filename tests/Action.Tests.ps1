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
        $output | Should -Match '(?m)^score=$'
        (Get-Content $env:GITHUB_STEP_SUMMARY -Raw) | Should -Match 'Skipped'
    }
}
