# Static checks for every script and the sources manifest. Run with: Invoke-Pester ./tests

BeforeDiscovery {
    $script:ScriptFiles = Get-ChildItem -Path (Join-Path $PSScriptRoot '..\scripts') -Filter '*.ps1' -Recurse |
        ForEach-Object { @{ Name = $_.Name; Path = $_.FullName } }
}

Describe 'Script <Name>' -ForEach $script:ScriptFiles {
    It 'parses without syntax errors' {
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errors)
        $errors | Should -BeNullOrEmpty
    }

    It 'has comment-based help' {
        $help = Get-Help -Name $Path
        $help.Synopsis | Should -Not -BeNullOrEmpty
    }

    It 'contains no company-specific names or secrets' {
        Get-Content -LiteralPath $Path -Raw | Should -Not -Match '(?i)ersg|tenantid|client_?secret|password\s*='
    }
}

Describe 'HPSupportAssistant.Sources.json' {
    BeforeAll {
        $script:Manifest = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot '..\scripts\hp-support-assistant\HPSupportAssistant.Sources.json') | ConvertFrom-Json
    }

    It 'has the fields the installer needs' {
        foreach ($field in 'softPaqName', 'category', 'fallbackSoftPaqNumber', 'fallbackDownloadUri', 'fallbackVersion', 'expectedSigner', 'allowedHosts') {
            $script:Manifest.$field | Should -Not -BeNullOrEmpty -Because "$field is required"
        }
    }

    It 'only allows HTTPS downloads from an allowed host' {
        $uri = [Uri]$script:Manifest.fallbackDownloadUri
        $uri.Scheme | Should -Be 'https'
        $script:Manifest.allowedHosts | Should -Contain $uri.Host
    }

    It 'has a valid fallback version' {
        { [version]$script:Manifest.fallbackVersion } | Should -Not -Throw
    }
}
