# Smoke tests for the detection script. Run with: Invoke-Pester ./tests
# On a clean runner HP Support Assistant is not installed, so "not detected" is expected.

BeforeAll {
    $script:Script = Join-Path $PSScriptRoot '..\scripts\hp-support-assistant\Detect-HPSupportAssistant.ps1'
    $script:LogDir = Join-Path ([IO.Path]::GetTempPath()) ("hpsa-test-" + [guid]::NewGuid())
}

AfterAll {
    Remove-Item -LiteralPath $script:LogDir -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Detect-HPSupportAssistant.ps1' {
    It 'parses without syntax errors' {
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($script:Script, [ref]$null, [ref]$errors)
        $errors | Should -BeNullOrEmpty
    }

    It 'exits 1 with no STDOUT when the app is not installed' {
        $out = & pwsh -NoProfile -File $script:Script -LogDir $script:LogDir
        $LASTEXITCODE | Should -Be 1
        $out | Should -BeNullOrEmpty
    }

    It 'writes a log file' {
        Test-Path (Join-Path $script:LogDir 'Detection.log') | Should -BeTrue
    }

    It 'also behaves the same under Windows PowerShell 5.1' -Skip:(-not (Get-Command powershell.exe -ErrorAction SilentlyContinue)) {
        $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script:Script -LogDir $script:LogDir
        $LASTEXITCODE | Should -Be 1
        $out | Should -BeNullOrEmpty
    }
}
