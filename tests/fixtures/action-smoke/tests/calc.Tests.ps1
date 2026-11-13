BeforeAll { . (Join-Path (Split-Path -Parent $PSScriptRoot) 'src' 'calc.ps1') }
Describe 'Get-Sign' {
    It 'is positive for positive input' { Get-Sign 5 | Should -Be 'pos' }
    It 'is negative for negative input' { Get-Sign -5 | Should -Be 'neg' }
}
Describe 'Test-Flag' {
    It 'runs for a truthy input' { { Test-Flag $true } | Should -Not -Throw }
}
