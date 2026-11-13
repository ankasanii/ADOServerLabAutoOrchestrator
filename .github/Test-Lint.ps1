#requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path -Parent $PSScriptRoot
$tools = Join-Path ([IO.Path]::GetTempPath()) ('AdoServerLabAutoOrchestrator-Lint-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tools | Out-Null
try {
    $packages = @(
        @{
            Name = 'actionlint'
            Url = 'https://github.com/rhysd/actionlint/releases/download/v1.7.12/actionlint_1.7.12_windows_amd64.zip'
            Hash = '6e7241b51e6817ea6a047693d8e6fed13b31819c9a0dd6c5a726e1592d22f6e9'
        }
        @{
            Name = 'PSScriptAnalyzer'
            Url = 'https://github.com/PowerShell/PSScriptAnalyzer/releases/download/1.25.0/PSScriptAnalyzer.1.25.0.nupkg'
            Hash = '14e634c828eb98efb9f40b2918ba90f139ed5eccdf663a2a747736d996995d60'
        }
    )
    foreach ($package in $packages) {
        $archive = Join-Path $tools ($package.Name + '.zip')
        Invoke-WebRequest -UseBasicParsing -Uri $package.Url -OutFile $archive -TimeoutSec 120
        if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne $package.Hash) {
            throw "$($package.Name) download checksum mismatch."
        }
        Expand-Archive -LiteralPath $archive -DestinationPath (Join-Path $tools $package.Name)
    }
    Push-Location -LiteralPath $root
    try {
        & (Join-Path $tools 'actionlint\actionlint.exe') -color
        if ($LASTEXITCODE -ne 0) { throw "Workflow lint failed: $LASTEXITCODE" }
    }
    finally { Pop-Location }

    # A child process releases analyzer DLL locks before the temporary tools are removed.
    $analyze = {
        param([string]$Root, [string]$Module, [string]$Settings)
        $ErrorActionPreference = 'Stop'
        $ProgressPreference = 'SilentlyContinue'
        Set-StrictMode -Version Latest
        Import-Module -Name $Module -ErrorAction Stop
        $paths = @(& git -C $Root ls-files --cached --others --exclude-standard -- '*.ps1' '*.psm1' '*.psd1')
        if ($LASTEXITCODE -ne 0) { throw 'Could not enumerate repository PowerShell source files.' }
        if ($paths.Count -eq 0) { throw 'No PowerShell source files found to analyze.' }
        $diagnostics = @(
            foreach ($path in $paths) {
                Invoke-ScriptAnalyzer -Path (Join-Path $Root $path.Replace('/', '\')) -Settings $Settings
            }
        )
        if ($diagnostics.Count -gt 0) {
            $diagnostics | Format-Table ScriptName, Line, Column, RuleName, Severity, Message -Wrap | Out-Host
            throw ('PowerShell lint found {0} diagnostic(s).' -f $diagnostics.Count)
        }
        Write-Host ('PASS: PowerShell lint ({0} source files).' -f $paths.Count)
    }
    $arguments = @($root,
        (Join-Path $tools 'PSScriptAnalyzer\PSScriptAnalyzer.psd1'),
        (Join-Path $PSScriptRoot 'PSScriptAnalyzerSettings.psd1')) |
        ForEach-Object { "'" + $_.Replace("'", "''") + "'" }
    $command = '& {' + $analyze.ToString() + '} ' + ($arguments -join ' ')
    & powershell.exe -NoProfile -NonInteractive -OutputFormat Text -Command $command
    if ($LASTEXITCODE -ne 0) { throw "PowerShell lint failed: $LASTEXITCODE" }
    Write-Host 'PASS: workflow and PowerShell lint.'
}
finally { Remove-Item -LiteralPath $tools -Recurse -Force }
