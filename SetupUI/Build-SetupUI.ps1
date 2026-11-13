#requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path -Parent $PSScriptRoot
$output = Join-Path $PSScriptRoot 'dist'
$framework = Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319'
$compiler = Join-Path $framework 'csc.exe'
$icon = Join-Path $PSScriptRoot 'Assets\AzureDevOps.ico'
$required = @('Setup-Server.ps1', 'Resume-Setup.ps1', 'Setup-Releases.psm1', 'Setup-State.psm1', 'Setup-Monitoring.psm1', 'Monitor-Setup.ps1', 'Test-GuestSetup.ps1', 'README.md')
foreach ($name in $required) {
    if (-not (Test-Path -LiteralPath (Join-Path $root "GuestSetup\$name") -PathType Leaf)) { throw "Missing GuestSetup dependency: $name" }
}
if (-not (Test-Path -LiteralPath $compiler -PathType Leaf)) { throw '.NET Framework 4.x C# compiler is required to build this UI.' }
if (-not (Test-Path -LiteralPath $icon -PathType Leaf)) { throw "Missing application icon: $icon" }
New-Item -ItemType Directory -Path (Join-Path $output 'GuestSetup') -Force | Out-Null
$references = @(
    (Join-Path $framework 'System.dll'), (Join-Path $framework 'System.Core.dll'),
    (Join-Path $framework 'System.Web.Extensions.dll'),
    (Join-Path $framework 'WPF\WindowsBase.dll'), (Join-Path $framework 'WPF\PresentationCore.dll'),
    (Join-Path $framework 'WPF\PresentationFramework.dll'), (Join-Path $framework 'System.Xaml.dll')
)
foreach ($reference in $references) {
    if (-not (Test-Path -LiteralPath $reference -PathType Leaf)) { throw "Missing .NET Framework reference: $reference" }
}
$arguments = @('/nologo', '/target:winexe', '/platform:x64', '/optimize+',
    "/out:$(Join-Path $output 'AdoServerLabAutoOrchestrator.exe')", "/win32manifest:$(Join-Path $PSScriptRoot 'app.manifest')",
    "/win32icon:$icon", "/resource:$icon,AdoServerLabAutoOrchestrator.AppIcon.ico")
$arguments += @($references | ForEach-Object { "/reference:$_" })
$arguments += Join-Path $PSScriptRoot 'SetupUI.cs'
& $compiler @arguments
if ($LASTEXITCODE -ne 0) { throw "C# compilation failed: $LASTEXITCODE" }
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'SetupBridge.ps1') -Destination $output -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'README.md') -Destination $output -Force
foreach ($name in $required) { Copy-Item -LiteralPath (Join-Path $root "GuestSetup\$name") -Destination (Join-Path $output 'GuestSetup') -Force }
$archive = Join-Path $PSScriptRoot 'AdoServerLabAutoOrchestrator.zip'
$packageFiles = @('AdoServerLabAutoOrchestrator.exe', 'SetupBridge.ps1', 'README.md', 'GuestSetup')
Compress-Archive -Path @($packageFiles | ForEach-Object { Join-Path $output $_ }) -DestinationPath $archive -Force
Write-Host "Built: $(Join-Path $output 'AdoServerLabAutoOrchestrator.exe')"
Write-Host "Distribution: $archive"
