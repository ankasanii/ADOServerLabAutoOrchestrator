#requires -Version 5.1
[CmdletBinding()]
param([string]$Version = ([DateTime]::UtcNow.ToString('yyyy.MM.dd') + '.0'))
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$numericVersion = $null
if ($Version -notmatch '^\d{1,5}(?:\.\d{1,5}){3}$' -or
    -not [version]::TryParse($Version, [ref]$numericVersion) -or
    @($numericVersion.Major, $numericVersion.Minor, $numericVersion.Build, $numericVersion.Revision |
        Where-Object { $_ -gt 65534 }).Count) {
    throw 'Build version must have four numeric components between 0 and 65534, for example 2026.11.13.5.'
}
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
$versionSource = Join-Path $output 'BuildInfo.cs'
@"
using System.Reflection;
[assembly: AssemblyTitle("AdoServerLabAutoOrchestrator")]
[assembly: AssemblyProduct("AdoServerLabAutoOrchestrator")]
[assembly: AssemblyVersion("$numericVersion")]
[assembly: AssemblyFileVersion("$Version")]
[assembly: AssemblyInformationalVersion("$Version")]
"@ | Set-Content -LiteralPath $versionSource -Encoding UTF8
$manifestPath = Join-Path $output 'app.manifest'
$manifest = [xml](Get-Content -LiteralPath (Join-Path $PSScriptRoot 'app.manifest') -Raw)
$manifest.assembly.assemblyIdentity.version = $numericVersion.ToString()
$manifest.Save($manifestPath)
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
    "/out:$(Join-Path $output 'AdoServerLabAutoOrchestrator.exe')", "/win32manifest:$manifestPath",
    "/win32icon:$icon", "/resource:$icon,AdoServerLabAutoOrchestrator.AppIcon.ico")
$arguments += @($references | ForEach-Object { "/reference:$_" })
$arguments += Join-Path $PSScriptRoot 'SetupUI.cs'
$arguments += $versionSource
& $compiler @arguments
if ($LASTEXITCODE -ne 0) { throw "C# compilation failed: $LASTEXITCODE" }
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'SetupBridge.ps1') -Destination $output -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'README.md') -Destination $output -Force
Copy-Item -LiteralPath (Join-Path $root 'LICENSE') -Destination $output -Force
foreach ($name in $required) { Copy-Item -LiteralPath (Join-Path $root "GuestSetup\$name") -Destination (Join-Path $output 'GuestSetup') -Force }
$archive = Join-Path $PSScriptRoot 'AdoServerLabAutoOrchestrator.zip'
$packageFiles = @('AdoServerLabAutoOrchestrator.exe', 'SetupBridge.ps1', 'README.md', 'LICENSE', 'GuestSetup')
Compress-Archive -Path @($packageFiles | ForEach-Object { Join-Path $output $_ }) -DestinationPath $archive -Force
$checksum = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
"$checksum  $([IO.Path]::GetFileName($archive))" | Set-Content -LiteralPath "$archive.sha256" -Encoding ASCII
Write-Host "Version: $Version"
Write-Host "Built: $(Join-Path $output 'AdoServerLabAutoOrchestrator.exe')"
Write-Host "Distribution: $archive"
Write-Host "Checksum: $archive.sha256"
