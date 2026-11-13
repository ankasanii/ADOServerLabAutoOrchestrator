#requires -Version 5.1
[CmdletBinding()]
param([string]$ExpectedVersion)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path -Parent $PSScriptRoot
$exe = Join-Path $PSScriptRoot 'dist\AdoServerLabAutoOrchestrator.exe'
if (-not (Test-Path -LiteralPath $exe)) { throw 'Run Build-SetupUI.ps1 first.' }
foreach ($name in @('SetupBridge.ps1', 'Build-SetupUI.ps1')) {
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $name), [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw ($errors.Message -join '; ') }
}
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml, System.Drawing, System.IO.Compression.FileSystem
$assembly = [Reflection.Assembly]::LoadFrom($exe)
$versionInfo = [Diagnostics.FileVersionInfo]::GetVersionInfo($exe)
if (-not $ExpectedVersion) { $ExpectedVersion = $versionInfo.ProductVersion }
if ($ExpectedVersion -notmatch '^\d+(?:\.\d+){3}$' -or
    $versionInfo.ProductVersion -cne $ExpectedVersion -or [version]$versionInfo.FileVersion -ne [version]$ExpectedVersion -or
    $assembly.GetName().Version -ne [version]$ExpectedVersion -or $versionInfo.ProductName -cne 'AdoServerLabAutoOrchestrator') {
    throw 'EXE product, file and assembly metadata must match the requested release version.'
}
$buildManifest = [xml](Get-Content -LiteralPath (Join-Path $PSScriptRoot 'dist\app.manifest') -Raw)
if ([version]$buildManifest.assembly.assemblyIdentity.version -ne [version]$ExpectedVersion) {
    throw 'The compiled application manifest must use the requested release version.'
}
foreach ($invalid in @('1.2.3', '1.2.3.65535', '65535.0.0.0', '1.2.3.-1', '1.2.3.4"')) {
    $rejected = $false
    try { & (Join-Path $PSScriptRoot 'Build-SetupUI.ps1') -Version $invalid }
    catch { if ($_.Exception.Message -notlike 'Build version must have four numeric components*') { throw }; $rejected = $true }
    if (-not $rejected) { throw 'Invalid build versions must fail before generating or compiling files.' }
}
$archivePath = Join-Path $PSScriptRoot 'AdoServerLabAutoOrchestrator.zip'
$checksum = (Get-Content -LiteralPath "$archivePath.sha256" -Raw).Trim()
$expectedChecksum = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant() + '  AdoServerLabAutoOrchestrator.zip'
if ($checksum -cne $expectedChecksum) { throw 'The SHA-256 sidecar must match the exact archive bytes and filename.' }
$archive = [IO.Compression.ZipFile]::OpenRead($archivePath)
try {
    $files = @($archive.Entries | Where-Object Name | ForEach-Object { $_.FullName.Replace('\', '/') })
    $expectedFiles = @('AdoServerLabAutoOrchestrator.exe', 'SetupBridge.ps1', 'README.md', 'LICENSE',
        'GuestSetup/Setup-Server.ps1', 'GuestSetup/Resume-Setup.ps1', 'GuestSetup/Setup-Releases.psm1',
        'GuestSetup/Setup-State.psm1', 'GuestSetup/Setup-Monitoring.psm1', 'GuestSetup/Monitor-Setup.ps1',
        'GuestSetup/Test-GuestSetup.ps1', 'GuestSetup/README.md')
    if ((($files | Sort-Object) -join ',') -cne (($expectedFiles | Sort-Object) -join ',')) {
        throw 'The release ZIP must contain only the required application, license, documentation and guest files.'
    }
}
finally { $archive.Dispose() }
& {
    $stream = $assembly.GetManifestResourceStream('AdoServerLabAutoOrchestrator.AppIcon.ico')
    if ($null -eq $stream) { throw 'The EXE must embed the application icon.' }
    try {
        $decoder = [Windows.Media.Imaging.IconBitmapDecoder]::new($stream,
            [Windows.Media.Imaging.BitmapCreateOptions]::PreservePixelFormat, [Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
        if ((@($decoder.Frames | ForEach-Object PixelWidth | Sort-Object) -join ',') -ne '16,24,32,48,64,128,256' -or
            @($decoder.Frames | Where-Object { $_.PixelWidth -ne $_.PixelHeight }).Count) {
            throw 'The embedded icon must have square frames for common Windows/DPI sizes.'
        }
        $stream.Position = 0
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            $embeddedHash = [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '')
            if ($embeddedHash -ne (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'Assets\AzureDevOps.ico')).Hash) {
                throw 'The embedded icon must match the authorized source asset.'
            }
        }
        finally { $sha.Dispose() }
    }
    finally { $stream.Dispose() }
    $nativeIcon = [Drawing.Icon]::ExtractAssociatedIcon($exe)
    if ($null -eq $nativeIcon) { throw 'Windows must be able to extract the EXE icon.' }
    $nativeIcon.Dispose()
}
$quote = $assembly.GetType('AdoServerLabAutoOrchestrator.SetupWindow').GetMethod('Quote')
$encode = $assembly.GetType('AdoServerLabAutoOrchestrator.SetupWindow').GetMethod('Encode')
$unsafe = "C:\Engineer O'Brien\script'; Write-Error 'unexpected.ps1"
$quoted = $quote.Invoke($null, @($unsafe))
$decoded = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($encode.Invoke($null, @($quoted))))
if ($decoded -cne $quoted) { throw 'Command encoding must round-trip exactly.' }
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($quoted, [ref]$tokens, [ref]$errors)
$strings = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.StringConstantExpressionAst] }, $true))
if ($errors.Count -or $strings.Count -ne 1 -or $strings[0].Value -cne $unsafe) { throw 'User-entered paths/options must remain a single literal, not executable commands.' }
& {
    $type = $assembly.GetType('AdoServerLabAutoOrchestrator.SetupWindow')
    $flags = [Reflection.BindingFlags]'Instance,NonPublic'
    $window = [Activator]::CreateInstance($type)
    try {
        if ($null -eq $window.Icon -or $window.Icon.Width -ne 256 -or $window.Icon.Height -ne 256) {
            throw 'The window/taskbar icon must use the embedded high-resolution application icon.'
        }
        $modes = $type.GetField('joinMode', $flags).GetValue($window)
        $domainControl = $type.GetField('domain', $flags).GetValue($window)
        if ($modes.IsEnabled -or $modes.SelectedIndex -ne -1 -or -not $domainControl.IsReadOnly) {
            throw 'Membership must remain unselected and locked before detection, and the domain field must be read-only.'
        }
        $release = New-Object 'System.Collections.Generic.Dictionary[string,object]'
        $release.Add('Supported', $true); $release.Add('Patches', @()); $release.Add('CanOverrideOs', $false)
        $release.Add('OverrideBlockedReason', 'Fixture hard restriction.')
        $type.GetField('releases', $flags).GetValue($window).Add('2022', $release)
        foreach ($name in @('metadataReady','serverAllowed','snapshotReady')) { $type.GetField($name, $flags).SetValue($window, $true) }
        $type.GetField('computerName', $flags).SetValue($window, 'labserver')
        $type.GetField('detectedDomain', $flags).SetValue($window, 'WORKGROUP')
        if ($window.Title -cne 'AdoServerLabAutoOrchestrator') { throw 'The window title must match the application name.' }
        $export = $type.GetField('export', $flags).GetValue($window)
        if ($export.Content -ne 'Export diagnostics' -or -not $export.IsEnabled) { throw 'Diagnostic export must be available independently of installation eligibility.' }
        $type.GetField('exporting', $flags).SetValue($window, $true)
        $type.GetMethod('UpdateButtons', $flags).Invoke($window, @()) | Out-Null
        if ($export.IsEnabled) { throw 'A second diagnostic export must not start while one is already active.' }
        $type.GetField('exporting', $flags).SetValue($window, $false)
        $choice = [Activator]::CreateInstance($assembly.GetType('AdoServerLabAutoOrchestrator.Choice'), @('2022', 'DevOps 2022 / SQL 2022'))
        $versions = $type.GetField('version', $flags).GetValue($window)
        $versions.Items.Add($choice) | Out-Null; $versions.SelectedIndex = 0
        $type.GetMethod('UpdateMembership', $flags).Invoke($window, @()) | Out-Null
        $type.GetField('license', $flags).GetValue($window).IsChecked = $true
        $start = $type.GetField('start', $flags).GetValue($window)
        if ($modes.SelectedItem.Value -ne 'Workgroup' -or $modes.IsEnabled -or
            $domainControl.IsEnabled -or $domainControl.Text -ne '' -or -not $domainControl.IsReadOnly) {
            throw 'A standalone VM must automatically select locked Workgroup mode and disable its empty AD-domain field.'
        }
        $notesControl = $type.GetField('notes', $flags).GetValue($window)
        function Get-NoticeText {
            return ([Windows.Documents.TextRange]::new($notesControl.ContentStart, $notesControl.ContentEnd)).Text
        }
        if ((Get-NoticeText) -notlike '*WARNING - Workgroup account requirements*local administrator*not a PIN*Microsoft Entra ID/AzureAD*password-based Task Scheduler logon*' -or
            (Get-NoticeText) -like '*WARNING - Domain membership required*') {
            throw 'Workgroup mode must warn about unsupported company accounts and password-based resume before setup starts.'
        }
        $dns = $type.GetField('dnsHostName', $flags).GetValue($window)
        if (-not $start.IsEnabled -or $dns.Text -ne 'labserver' -or -not $dns.IsEnabled) { throw 'Detected Workgroup mode must use an editable VM hostname on a standalone server.' }
        $dns.Text = 'devops.lab.example.com'
        $type.GetMethod('UpdateOptions', $flags).Invoke($window, @()) | Out-Null
        if ($dns.Text -ne 'devops.lab.example.com') { throw 'Refreshing options must preserve custom DNS input.' }
        $type.GetField('joinedDomain', $flags).SetValue($window, $true)
        $type.GetMethod('UpdateButtons', $flags).Invoke($window, @()) | Out-Null
        if ($start.IsEnabled) { throw 'Workgroup mode cannot start on an AD-joined VM.' }
        $type.GetField('detectedDomain', $flags).SetValue($window, 'ak.com')
        $type.GetMethod('UpdateMembership', $flags).Invoke($window, @()) | Out-Null
        if ($modes.SelectedItem.Value -ne 'Domain' -or $modes.IsEnabled -or -not $start.IsEnabled -or
            $dns.IsEnabled -or $dns.Text -ne 'labserver.ak.com' -or
            $domainControl.Text -ne 'ak.com' -or -not $domainControl.IsReadOnly) {
            throw 'An AD-joined VM must automatically select locked Domain mode and show the detected domain/hostname without allowing edits.'
        }
        if ((Get-NoticeText) -like '*WARNING - Workgroup account requirements*' -or
            (Get-NoticeText) -like '*WARNING - Domain membership required*') {
            throw 'Account/membership warnings must clear when valid Domain mode is selected.'
        }
        $type.GetField('clientOs', $flags).SetValue($window, $true)
        $type.GetField('legacySsms', $flags).SetValue($window, $true)
        $type.GetMethod('UpdateOptions', $flags).Invoke($window, @()) | Out-Null
        $emailControl = $type.GetField('email', $flags).GetValue($window)
        if (-not $start.IsEnabled -or $emailControl.IsEnabled -or $emailControl.SelectedIndex -ne 1 -or
            (Get-NoticeText) -notlike '*SSMS 20.2.1*' -or (Get-NoticeText) -notlike '*evaluation/personal use only*') {
            throw 'Client Windows must show lab/legacy SSMS restrictions and disable unsupported Windows 10 SMTP capture.'
        }
        $release['Supported'] = $false
        $release.Add('UnsupportedReason', 'Fixture OS pairing rejected.')
        $type.GetMethod('UpdateOptions', $flags).Invoke($window, @()) | Out-Null
        if ($start.IsEnabled -or (Get-NoticeText) -notlike '*Fixture OS pairing rejected.*') { throw 'Unsupported client releases must be disabled with a visible reason.' }
        $strictOs = $type.GetField('strictOs', $flags).GetValue($window)
        $unsupportedOs = $type.GetField('unsupportedOs', $flags).GetValue($window)
        if ($unsupportedOs.IsEnabled -or $unsupportedOs.IsChecked -or -not $strictOs.IsChecked) { throw 'Hard OS restrictions must not offer an override; strict mode is the default.' }
        $release['CanOverrideOs'] = $true
        $type.GetMethod('UpdateButtons', $flags).Invoke($window, @()) | Out-Null
        if ($start.IsEnabled -or -not $unsupportedOs.IsEnabled) { throw 'Offering an override must not enable installation without explicit acknowledgement.' }
        $unsupportedOs.IsChecked = $true
        if (-not $start.IsEnabled -or (Get-NoticeText) -notlike '*Installation may fail or be unsupported*') { throw 'Explicit lab override must enable eligible OS builds with visible warnings.' }
        $headings = @($notesControl.Inlines | Where-Object {
            $_ -is [Windows.Documents.Run] -and $_.FontWeight -eq [Windows.FontWeights]::SemiBold
        })
        if ($headings.Count -lt 3 -or $headings[0].Text -ne 'WARNING - Unsupported OS override' -or
            @($headings | ForEach-Object { $_.Foreground.ToString() } | Select-Object -Unique).Count -lt 3) {
            throw 'Notices must have prioritized, bold, color-coded warning/caution/information headings.'
        }
        if ($notesControl.Parent -isnot [Windows.Controls.Border] -or $notesControl.Parent.Padding.Left -lt 10) {
            throw 'Notices must appear in a padded, bordered panel rather than an unformatted text block.'
        }
        $rootPanel = $window.Content
        $optionsScroll = @($rootPanel.Children | Where-Object { $_ -is [Windows.Controls.ScrollViewer] })
        if ($optionsScroll.Count -ne 1 -or $optionsScroll[0].VerticalScrollBarVisibility -ne 'Auto' -or
            $optionsScroll[0].HorizontalScrollBarVisibility -ne 'Disabled') {
            throw 'Setup options must scroll vertically and wrap to the available width.'
        }
        $logControl = $type.GetField('logs', $flags).GetValue($window)
        $extraNotice = [Windows.Documents.Run]::new(("`r`nAdditional unsupported OS and prerequisite warning for a lab installation." * 12))
        try {
            $notesControl.Inlines.Add($extraNotice)
            foreach ($size in @(@(764, 704), @(944, 844))) {
                $available = New-Object Windows.Size($size[0], $size[1])
                $rootPanel.Measure($available)
                $rootPanel.Arrange((New-Object Windows.Rect(0, 0, $size[0], $size[1])))
                $rootPanel.UpdateLayout()
                if ($logControl.ActualHeight -lt 120 -or
                    $optionsScroll[0].ViewportHeight -le 0 -or
                    $optionsScroll[0].ExtentHeight -le $optionsScroll[0].ViewportHeight) {
                    throw 'At minimum/default window sizes, long warnings must scroll while preserving at least 120 DIPs of visible logs.'
                }
                $bottom = $logControl.TranslatePoint((New-Object Windows.Point(0, $logControl.ActualHeight)), $rootPanel)
                if ($bottom.Y -gt ($size[1] + 1)) { throw 'The reserved log panel must remain inside the visible client area.' }
            }
        }
        finally { $notesControl.Inlines.Remove($extraNotice) }
        $type.GetField('domain', $flags).GetValue($window).Text = 'ak.com'
        $buildCommand = $type.GetMethod('BuildLauncherCommand', $flags)
        $command = $buildCommand.Invoke($window, @($false))
        if ($command -notlike '* -AllowUnsupportedOs *') { throw 'UI must pass an acknowledged override to the actual launcher command.' }
        $retryCommand = $buildCommand.Invoke($window, @($true))
        if ($retryCommand -notlike '* -Resume *' -or $retryCommand -like '*AllowUnsupportedOs*') { throw 'Resume command must use the saved OS acknowledgement, not supply a replacement.' }
        $strictOs.IsChecked = $true
        if ($start.IsEnabled -or $buildCommand.Invoke($window, @($false)) -like '*AllowUnsupportedOs*') { throw 'Strict mode must block unsupported OS and omit the override switch.' }
        $unsupportedOs.IsChecked = $true
        $release['CanOverrideOs'] = $false
        $type.GetMethod('UpdateButtons', $flags).Invoke($window, @()) | Out-Null
        if ($start.IsEnabled -or $unsupportedOs.IsChecked -or $unsupportedOs.IsEnabled) { throw 'Changing to a hard restriction must clear and disable a previous override.' }
        $release['CanOverrideOs'] = $true; $unsupportedOs.IsChecked = $true
        $type.GetField('hasState', $flags).SetValue($window, $true)
        $type.GetMethod('UpdateButtons', $flags).Invoke($window, @()) | Out-Null
        if ($strictOs.IsEnabled -or $unsupportedOs.IsEnabled -or $start.IsEnabled) { throw 'Saved plans must lock both OS validation choices.' }
        $type.GetField('hasState', $flags).SetValue($window, $false)
        $rcRelease = New-Object 'System.Collections.Generic.Dictionary[string,object]'
        $rcRelease.Add('Supported', $true); $rcRelease.Add('CanOverrideOs', $false); $rcRelease.Add('Patches', @())
        $type.GetField('releases', $flags).GetValue($window).Add('26H2-RC', $rcRelease)
        $versions.Items.Add([Activator]::CreateInstance($assembly.GetType('AdoServerLabAutoOrchestrator.Choice'), @('26H2-RC', 'DevOps 26H2 RC / SQL 2025'))) | Out-Null
        $versions.SelectedIndex = 1
        $patchControl = $type.GetField('patch', $flags).GetValue($window)
        if ($patchControl.IsEnabled -or $patchControl.Items.Count -ne 1 -or $patchControl.SelectedItem.Value -ne 'Skip' -or
            (Get-NoticeText) -notlike '*26H2 Release Candidate*' -or -not $start.IsEnabled) {
            throw 'RC UI must show a prerelease warning and only a disabled Skip patch choice.'
        }
        $rcCommand = $buildCommand.Invoke($window, @($false))
        if ($rcCommand -notlike "* -Version '26H2-RC'*" -or $rcCommand -notlike "* -Patch 'Skip'*") { throw 'RC launch command must preserve the separate release and Skip patch.' }
        $type.GetField('components', $flags).GetValue($window).SelectedIndex = 1
        if ($patchControl.SelectedIndex -ne 0 -or $patchControl.SelectedItem.Value -ne 'Skip') { throw 'RC SQL-only must keep its single valid patch selection.' }
    }
    finally { $window.Close() }
}
& {
    if ($PSVersionTable.PSEdition -ne 'Desktop') {
        Write-Host 'SKIP: live polling/bridge integration requires the EXE .NET Framework runtime; run this test in Windows PowerShell 5.1.'
        return
    }
    $type = $assembly.GetType('AdoServerLabAutoOrchestrator.SetupWindow')
    $flags = [Reflection.BindingFlags]'Instance,NonPublic'
    $pollFixture = Join-Path $env:TEMP ('SetupUiPolling-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $pollFixture -Force | Out-Null
    $window = $null
    $oldContext = [Threading.SynchronizationContext]::Current
    try {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'dist\GuestSetup') -Destination $pollFixture -Recurse
        Set-Content -LiteralPath (Join-Path $pollFixture 'SetupBridge.ps1') -Value @'
param([string]$Mode)
$ErrorActionPreference = 'Stop'
[IO.File]::AppendAllText((Join-Path $PSScriptRoot 'calls.txt'), "$Mode`r`n")
Get-Content -LiteralPath (Join-Path $PSScriptRoot "$Mode.json") -Raw
'@
        @{
            ServerAllowed = $true; ClientOs = $false; LegacySsms = $false; JoinedDomain = $false
            Domain = 'WORKGROUP'; ComputerName = 'labserver'; Os = 'Fixture Windows'; Account = 'labserver\labadmin'
            Releases = @(@{ Version = '2022'; SqlYear = '2022'; Supported = $true; CanOverrideOs = $false; Patches = @() })
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $pollFixture 'Metadata.json')
        $data = @{
            HasState = $false; Status = 'NotStarted'; Summary = 'Fixture fresh setup'; CanResume = $false
            Progress = 0; Logs = ''; Error = ''; Version = '2022'; Components = 'Both'
            JoinMode = 'Workgroup'; PatchSelection = 'Skip'; Email = 'None'; DomainName = 'WORKGROUP'
            DnsHostName = 'labserver'; AllowUnsupportedOs = $false
        }
        $snapshotPath = Join-Path $pollFixture 'Snapshot.json'
        $data | ConvertTo-Json | Set-Content -LiteralPath $snapshotPath
        [Threading.SynchronizationContext]::SetSynchronizationContext([Windows.Threading.DispatcherSynchronizationContext]::new())
        $window = [Activator]::CreateInstance($type)
        $type.GetField('folder', $flags).SetValue($window, $pollFixture)
        $pollTimer = $type.GetField('timer', $flags).GetValue($window)
        $refreshButton = $type.GetField('refresh', $flags).GetValue($window)
        $refreshNote = $type.GetField('refreshNote', $flags).GetValue($window)
        function Wait-UiCondition {
            param([scriptblock]$Condition)
            $frame = [Windows.Threading.DispatcherFrame]::new()
            $pulse = [Windows.Threading.DispatcherTimer]::new()
            $pulse.Interval = [timespan]::FromMilliseconds(25)
            $watch = [Diagnostics.Stopwatch]::StartNew()
            $pulse.Add_Tick({
                if ((& $Condition) -or $watch.Elapsed.TotalSeconds -ge 30) { $frame.Continue = $false }
            })
            try {
                $pulse.Start()
                [Windows.Threading.Dispatcher]::PushFrame($frame)
                if (-not (& $Condition)) {
                    throw "Timed out waiting for the UI: $($type.GetField('errors', $flags).GetValue($window).Text)"
                }
            }
            finally { $pulse.Stop() }
        }
        function Invoke-ManualRefresh {
            $refreshButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
            Wait-UiCondition { -not $type.GetField('refreshing', $flags).GetValue($window) }
        }
        $window.Show()
        Wait-UiCondition {
            $type.GetField('snapshotReady', $flags).GetValue($window) -and
                -not $type.GetField('refreshing', $flags).GetValue($window)
        }
        $membershipControl = $type.GetField('joinMode', $flags).GetValue($window)
        $domainControl = $type.GetField('domain', $flags).GetValue($window)
        $dnsControl = $type.GetField('dnsHostName', $flags).GetValue($window)
        if ($membershipControl.SelectedItem.Value -ne 'Workgroup' -or $membershipControl.IsEnabled -or
            $domainControl.IsEnabled -or $domainControl.Text -ne '' -or -not $domainControl.IsReadOnly -or
            $dnsControl.Text -ne 'labserver' -or -not $dnsControl.IsEnabled) {
            throw 'Live metadata must automatically select Workgroup on a standalone VM without asking for an AD domain.'
        }
        $dnsControl.Text = 'devops.lab.example.com'
        Invoke-ManualRefresh
        if ($dnsControl.Text -ne 'devops.lab.example.com') { throw 'Refreshing a fresh setup must preserve custom Workgroup DNS input.' }
        $data.HasState = $true; $data.Status = 'Completed'; $data.Progress = 100; $data.Logs = 'FINAL_LOG_OUTPUT'
        $data.DnsHostName = 'devops.lab.example.com'
        $data | ConvertTo-Json | Set-Content -LiteralPath $snapshotPath
        Invoke-ManualRefresh
        if ($membershipControl.SelectedItem.Value -ne 'Workgroup' -or $membershipControl.IsEnabled -or
            $domainControl.Text -ne 'WORKGROUP' -or $dnsControl.Text -ne 'devops.lab.example.com' -or $dnsControl.IsEnabled) {
            throw 'A saved Workgroup plan must preserve its membership and custom hostname and lock the fields.'
        }
        $data.JoinMode = 'Domain'; $data.DomainName = 'ak.com'; $data.DnsHostName = 'labserver.ak.com'
        $data | ConvertTo-Json | Set-Content -LiteralPath $snapshotPath
        Invoke-ManualRefresh
        $type.GetMethod('UpdateMembership', $flags).Invoke($window, @()) | Out-Null
        if ($membershipControl.SelectedItem.Value -ne 'Domain' -or $membershipControl.IsEnabled -or
            $domainControl.Text -ne 'ak.com' -or $dnsControl.Text -ne 'labserver.ak.com' -or
            $type.GetField('errors', $flags).GetValue($window).Text -notlike '*Saved setup membership does not match this VM*') {
            throw 'A mismatched saved Domain plan must remain unchanged and show an explicit membership error.'
        }
        $data.JoinMode = 'Workgroup'; $data.DomainName = 'WORKGROUP'; $data.DnsHostName = 'devops.lab.example.com'
        $data | ConvertTo-Json | Set-Content -LiteralPath $snapshotPath
        Invoke-ManualRefresh
        if ($pollTimer.IsEnabled -or -not $refreshButton.IsEnabled -or
            $refreshNote.Text -notlike '*Setup completed*Automatic refresh stopped*' -or
            $type.GetField('logs', $flags).GetValue($window).Text -ne 'FINAL_LOG_OUTPUT') {
            throw 'Opening an already-completed setup must retain final logs, stop polling and keep manual Refresh enabled.'
        }
        $callsBefore = [IO.File]::ReadAllText((Join-Path $pollFixture 'calls.txt'))
        $pollTimer.Interval = [timespan]::FromMilliseconds(100)
        $quietWatch = [Diagnostics.Stopwatch]::StartNew()
        Wait-UiCondition { $quietWatch.ElapsedMilliseconds -ge 350 }
        if ([IO.File]::ReadAllText((Join-Path $pollFixture 'calls.txt')) -cne $callsBefore) {
            throw 'Completed setup must not continue making automatic bridge requests.'
        }
        $pollTimer.Interval = [timespan]::FromSeconds(10)
        $data.Status = 'Running'; $data.Progress = 40; $data.Logs = 'RUNNING_LOG_OUTPUT'
        $data | ConvertTo-Json | Set-Content -LiteralPath $snapshotPath
        Invoke-ManualRefresh
        if (-not $pollTimer.IsEnabled -or $refreshNote.Text -notlike '*Refreshes every 10 seconds*' -or
            $type.GetField('logs', $flags).GetValue($window).Text -ne 'RUNNING_LOG_OUTPUT') {
            throw 'Manual Refresh finding a non-completed state must read fresh logs and restart automatic monitoring.'
        }
        Set-Content -LiteralPath $snapshotPath -Value '{invalid json'
        Invoke-ManualRefresh
        if (-not $pollTimer.IsEnabled -or -not $refreshButton.IsEnabled -or
            $type.GetField('snapshotReady', $flags).GetValue($window) -or
            $type.GetField('errors', $flags).GetValue($window).Text -notlike 'Monitoring failed*') {
            throw 'Monitoring errors during active polling must remain explicit and allow automatic/manual retry.'
        }
        $data.Status = 'Failed'
        $data | ConvertTo-Json | Set-Content -LiteralPath $snapshotPath
        Invoke-ManualRefresh
        if (-not $pollTimer.IsEnabled) { throw 'A failed plan must continue polling so an external retry can be observed.' }
        $data.Status = 'Completed'; $data.Progress = 100; $data.Logs = 'FINAL_LOG_OUTPUT'
        $data | ConvertTo-Json | Set-Content -LiteralPath $snapshotPath
        Invoke-ManualRefresh
        if ($pollTimer.IsEnabled -or -not $refreshButton.IsEnabled) { throw 'Transitioning from active polling to Completed must stop the timer but not manual Refresh.' }
        @{ Report = 'DIAGNOSTIC_PREVIEW_FIXTURE' } | ConvertTo-Json |
            Set-Content -LiteralPath (Join-Path $pollFixture 'Diagnostics.json')
        $exportButton = $type.GetField('export', $flags).GetValue($window)
        $previewResult = @{ Seen = $false; Editable = $false; Versioned = $false; Disabled = $false }
        $previewPulse = [Windows.Threading.DispatcherTimer]::new()
        $previewPulse.Interval = [timespan]::FromMilliseconds(25)
        $previewPulse.Add_Tick({
            foreach ($owned in @($window.OwnedWindows)) {
                if ($owned.Title -ne 'Review diagnostics before saving') { continue }
                $previewResult.Seen = $true
                $previewResult.Disabled = -not $exportButton.IsEnabled
                $editor = @($owned.Content.Children | Where-Object { $_ -is [Windows.Controls.TextBox] })[0]
                $previewResult.Versioned = $editor.Text -like "Application version: *`r`nDIAGNOSTIC_PREVIEW_FIXTURE"
                $editor.Text = 'REVIEWED_DIAGNOSTIC_FIXTURE'
                $previewResult.Editable = -not $editor.IsReadOnly -and $editor.Text -eq 'REVIEWED_DIAGNOSTIC_FIXTURE'
                $previewPulse.Stop()
                $owned.Close()
            }
        })
        try {
            $previewPulse.Start()
            $exportButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
            Wait-UiCondition { -not $type.GetField('exporting', $flags).GetValue($window) }
            if (-not $previewResult.Seen -or -not $previewResult.Editable -or
                -not $previewResult.Versioned -or -not $previewResult.Disabled -or -not $exportButton.IsEnabled) {
                throw 'Diagnostics must open an editable, versioned preview, prevent duplicate exports, and allow cancellation.'
            }
        }
        finally { $previewPulse.Stop() }
        Set-Content -LiteralPath $snapshotPath -Value '{invalid json'
        Invoke-ManualRefresh
        if ($pollTimer.IsEnabled -or -not $refreshButton.IsEnabled -or $type.GetField('snapshotReady', $flags).GetValue($window)) {
            throw 'A failed manual check after completion must not silently restart automatic polling.'
        }
        $data.Status = 'Running'
        $data | ConvertTo-Json | Set-Content -LiteralPath $snapshotPath
        $refreshButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
        $window.Close()
        Wait-UiCondition { -not $type.GetField('refreshing', $flags).GetValue($window) }
        if ($pollTimer.IsEnabled) { throw 'A pending snapshot must not restart polling after the window closes.' }
    }
    finally {
        if ($null -ne $window) { $window.Close() }
        [Threading.SynchronizationContext]::SetSynchronizationContext($oldContext)
        Remove-Item -LiteralPath $pollFixture -Recurse -Force
    }
}
foreach ($name in @('Setup-Server.ps1', 'Resume-Setup.ps1', 'Setup-Releases.psm1', 'Setup-State.psm1', 'Setup-Monitoring.psm1', 'Monitor-Setup.ps1')) {
    if ((Get-FileHash -LiteralPath (Join-Path $root "GuestSetup\$name")).Hash -ne
        (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot "dist\GuestSetup\$name")).Hash) {
        throw "Bundled guest file does not match source: $name"
    }
}
& {
    foreach ($case in @(
        @{ Build = 17134; Sku = 4; Type = 1; Expected = '2020' },
        @{ Build = 17134; Sku = 48; Type = 1; Expected = '' },
        @{ Build = 19045; Sku = 48; Type = 1; Expected = '2020' },
        @{ Build = 26100; Sku = 48; Type = 1; Expected = '2022.1,2022,26H2-RC,25H2' },
        @{ Build = 26300; Sku = 4; Type = 1; Expected = '' },
        @{ Build = 26100; Sku = 101; Type = 1; Expected = '' },
        @{ Build = 26100; Sku = 7; Type = 3; Expected = '26H2-RC,25H2' },
        @{ Build = 20348; Sku = 7; Type = 2; Expected = '' }
    )) {
        function Get-CimInstance {
            [CmdletBinding()] param($ClassName)
            if ($ClassName -eq 'Win32_OperatingSystem') {
                return [pscustomobject]@{
                    ProductType = $case.Type; BuildNumber = $case.Build; OperatingSystemSKU = $case.Sku
                    OSArchitecture = '64-bit'; Caption = 'Fixture Windows'
                }
            }
            [pscustomobject]@{
                Name = 'labserver'; Domain = 'WORKGROUP'; PartOfDomain = $false
                DomainRole = $(if ($case.Type -eq 2) { 5 } else { 0 })
            }
        }
        $data = & (Join-Path $PSScriptRoot 'dist\SetupBridge.ps1') -Mode Metadata | ConvertFrom-Json
        if ($data.Releases.Count -ne 5 -or $data.Releases[-1].Version -ne '25H2' -or
            @($data.Releases | Where-Object Version -eq '26H2-RC')[0].Patches.Count) {
            throw 'Five UI releases must retain stable-last default selection and an empty RC patch catalog.'
        }
        if ((@($data.Releases | Where-Object Supported | ForEach-Object Version) -join ',') -ne $case.Expected -or
            $data.ServerAllowed -ne ($case.Type -ne 2) -or $data.ClientOs -ne ($case.Type -eq 1) -or
            $data.LegacySsms -ne ($case.Type -eq 1 -and $case.Build -lt 22000)) {
            throw 'Bundled UI bridge must use shared client/server OS validation and expose correct client restrictions.'
        }
        foreach ($release in @($data.Releases | Where-Object { -not $_.Supported })) {
            if ([string]::IsNullOrWhiteSpace($release.UnsupportedReason)) { throw 'Every unsupported OS pairing must expose its validation error.' }
            if ($release.CanOverrideOs -ne ($case.Type -ne 2 -and $case.Sku -ne 101)) { throw 'Only OS version/build restrictions may be bypassed in UI metadata.' }
            if (-not $release.CanOverrideOs -and [string]::IsNullOrWhiteSpace($release.OverrideBlockedReason)) { throw 'Hard override restrictions must have a reason.' }
        }
    }
}
. (Join-Path $root 'GuestSetup\Resume-Setup.ps1')
Import-Module (Join-Path $root 'GuestSetup\Setup-Monitoring.psm1') -Force -ErrorAction Stop
$tokens = $null; $errors = $null
$bridge = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'SetupBridge.ps1'), [ref]$tokens, [ref]$errors)
foreach ($functionName in @('Get-UiSnapshot', 'ConvertTo-UiDiagnosticText', 'Get-UiDiagnostics')) {
    $function = $bridge.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName }, $true)
    if ($null -eq $function) { throw "Missing UI bridge function: $functionName" }
    . ([scriptblock]::Create($function.Extent.Text))
}
& {
    $sample = @'
MSI1603: installation failed
Password="fake-test-password"
SQLSVCPASSWORD=fake-sql-password
Authorization: Bearer fake-test-bearer
{"api_key":"fake-test-key","other":"omitted"}
<Password>fake-xml-password</Password>
https://fakeuser:fakepassword@example.invalid/log?sig=fake-signature&code=fake-code
Contact fake.person@example.invalid from 192.0.2.12 and [2001:db8::12] or ::1
S-1-5-21-1-2-3-1000 C:\Users\Fake User\logs\setup.log
AK\labadmin labserver ak.com hostaaa hostbbb
'@
    $redacted = ConvertTo-UiDiagnosticText -Text $sample -SensitiveValues @('AK\labadmin', 'labserver', 'ak.com', 'hostaaa', 'hostbbb')
    foreach ($value in @('fake-test-password', 'fake-sql-password', 'fake-test-bearer', 'fake-test-key', 'fake-xml-password',
        'fakeuser', 'fakepassword', 'fake-signature', 'fake-code', 'fake.person@example.invalid', '192.0.2.12',
        '2001:db8::12', '::1', 'S-1-5-21-1-2-3-1000', 'Fake User', 'AK\labadmin', 'labserver', 'ak.com', 'hostaaa', 'hostbbb')) {
        if ($redacted.Contains($value)) { throw "Diagnostic redaction missed fixture value: $value" }
    }
    if (-not $redacted.Contains('MSI1603: installation failed')) { throw 'Diagnostic redaction must retain useful error identifiers.' }
}
$fixture = Join-Path $env:TEMP ('SetupUiTest-' + [guid]::NewGuid().ToString('N'))
$oldProgramData = $env:ProgramData
$work = Join-Path $fixture 'AdoServerLabAutoOrchestrator'
New-Item -ItemType Directory -Path $work -Force | Out-Null
$env:ProgramData = $fixture
try {
    & {
        $taskState = 'Ready'
        function Get-ScheduledTask {
            [CmdletBinding()] param()
            [pscustomobject]@{ TaskName = 'AdoServerLabAutoOrchestrator-Resume'; TaskPath = '\'; State = $taskState }
        }
        $snapshot = Get-UiSnapshot
        if ($snapshot.HasState -or $snapshot.CanResume -or $snapshot.Status -ne 'NotStarted') { throw 'No-state snapshot must not permit resume.' }
        if ((Get-UiDiagnostics).Report -notlike '*Status: NotStarted*') { throw 'Diagnostics must support a VM without saved setup.' }
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $plan = [pscustomobject]@{
            SchemaVersion = 4; Version = '2022'; Components = 'Both'; Email = 'Capture'
            DomainName = 'ak.com'; ComputerName = 'labserver'; SqlInstance = 'localhost'
            SetupAccount = $identity.Name; SetupSid = $identity.User.Value; StageIndex = 0
            Status = 'Failed'; LastError = 'Fixture installer failure'; CertificateThumbprint = ''
            RebootAfter = ''; PatchSelection = 'Skip'; Ports = $null
        }
        $path = Join-Path $work 'state.json'
        Save-SetupState -State $plan -Path $path
        $before = (Get-FileHash -LiteralPath $path).Hash
        $snapshot = Get-UiSnapshot
        if (-not $snapshot.HasState -or -not $snapshot.CanResume -or $snapshot.Error -ne $plan.LastError -or $snapshot.AllowUnsupportedOs) { throw 'Failed idle plan must expose error/resume and default legacy OS validation to strict.' }
        & {
            function Get-SetupMonitoringLogs {
                param($Work, $Plan, $TailLines)
                return "MSI1603: fixture failure`r`nPassword=fake-diagnostic-password`r`n$($plan.SetupAccount) $($plan.SetupSid) labserver.ak.com"
            }
            $report = (Get-UiDiagnostics).Report
            if ($report -notlike '*Status: Failed*' -or $report -notlike '*MSI1603*' -or
                $report.Contains('fake-diagnostic-password') -or $report.Contains($plan.SetupAccount) -or
                $report.Contains($plan.SetupSid) -or $report.Contains('labserver.ak.com') -or
                (Get-FileHash -LiteralPath $path).Hash -ne $before) {
                throw 'Diagnostic generation must preserve state, include the selected error/log tail, and redact saved identities and credentials.'
            }
        }
        $taskState = 'Running'
        if ((Get-UiSnapshot).CanResume) { throw 'Running task cannot be resumed by the UI.' }
        $plan.StageIndex = @(Get-SetupSteps -Plan $plan).Count; $plan.Status = 'Completed'; $plan.LastError = ''
        Save-SetupState -State $plan -Path $path
        $before = (Get-FileHash -LiteralPath $path).Hash
        function Get-ScheduledTask { throw 'Completed snapshots must not require the removed resume task.' }
        $snapshot = Get-UiSnapshot
        if ($snapshot.CanResume -or $snapshot.Progress -ne 100 -or $snapshot.Status -ne 'Completed') { throw 'Completed plan must show 100% without reopening it.' }
        if ((Get-FileHash -LiteralPath $path).Hash -ne $before) { throw 'Monitoring must not write state.' }
        $plan.SchemaVersion = 5
        $plan | Add-Member -NotePropertyName JoinMode -NotePropertyValue 'Workgroup'
        $plan | Add-Member -NotePropertyName DnsHostName -NotePropertyValue 'devops.lab.example.com'
        $plan.DomainName = 'WORKGROUP'; $plan.SetupAccount = 'labserver\labadmin'
        Save-SetupState -State $plan -Path $path
        $before = (Get-FileHash -LiteralPath $path).Hash
        $snapshot = Get-UiSnapshot
        if ($snapshot.JoinMode -ne 'Workgroup' -or $snapshot.DnsHostName -ne 'devops.lab.example.com' -or
            $snapshot.Summary -notlike '*https://devops.lab.example.com/tfs*' -or $snapshot.CanResume) {
            throw 'Workgroup snapshot must expose the saved hostname/mode and preserve completion.'
        }
        if ((Get-FileHash -LiteralPath $path).Hash -ne $before) { throw 'Workgroup monitoring must not write state.' }
        $plan.Version = '2022.1'; $plan.PatchSelection = '4'
        $plan.StageIndex = @(Get-SetupSteps -Plan $plan).Count
        Save-SetupState -State $plan -Path $path
        $snapshot = Get-UiSnapshot
        if ($snapshot.Version -ne '2022.1' -or $snapshot.PatchSelection -ne '4') {
            throw 'UI snapshots must preserve Update 1 as a distinct release with its own saved patch.'
        }
        $plan.Version = '26H2-RC'; $plan.PatchSelection = 'Skip'
        $plan.StageIndex = @(Get-SetupSteps -Plan $plan).Count
        Save-SetupState -State $plan -Path $path
        $snapshot = Get-UiSnapshot
        if ($snapshot.Version -ne '26H2-RC' -or $snapshot.PatchSelection -ne 'Skip' -or
            $snapshot.Summary -notlike '*RELEASE CANDIDATE*' -or $snapshot.Progress -ne 100) {
            throw 'Saved RC snapshots must preserve release identity, completion and prerelease warning.'
        }
        $plan.SchemaVersion = 6
        $plan | Add-Member -NotePropertyName AllowUnsupportedOs -NotePropertyValue $true
        Save-SetupState -State $plan -Path $path
        $before = (Get-FileHash -LiteralPath $path).Hash
        $snapshot = Get-UiSnapshot
        if (-not $snapshot.AllowUnsupportedOs -or $snapshot.Summary -notlike '*LAB OVERRIDE SAVED*' -or $snapshot.CanResume) { throw 'Saved OS acknowledgement must be visible without reopening completed setup.' }
        if ((Get-FileHash -LiteralPath $path).Hash -ne $before) { throw 'Monitoring the OS acknowledgement must not write state.' }
    }
    & {
        $logFixture = Join-Path $fixture 'LogSources'
        $oldTemp = $env:TEMP; $oldSystemRoot = $env:SystemRoot; $oldProgramFiles = $env:ProgramFiles
        $fixtureProgramData = $env:ProgramData
        try {
            $env:ProgramData = Join-Path $logFixture 'ProgramData'
            $env:TEMP = Join-Path $logFixture 'UserTemp'
            $env:SystemRoot = Join-Path $logFixture 'Windows'
            $env:ProgramFiles = Join-Path $logFixture 'ProgramFiles'
            $logWork = Join-Path $env:ProgramData 'AdoServerLabAutoOrchestrator'
            $windowsTemp = Join-Path $env:SystemRoot 'Temp'
            $ssmsTemp = Join-Path $env:TEMP 'SSMS\nested'
            $productLogs = Join-Path $env:ProgramData 'Microsoft\Azure DevOps\Server Configuration\Logs'
            $sqlLogs = Join-Path $env:ProgramFiles 'Microsoft SQL Server\170\Setup Bootstrap\Log'
            $sqlRun = Join-Path $sqlLogs '20261110_172800'
            foreach ($folder in @($logWork, (Join-Path $logWork 'Logs'), $env:TEMP, $windowsTemp, $ssmsTemp, $productLogs, $sqlRun)) {
                New-Item -ItemType Directory -Path $folder -Force | Out-Null
            }
            $start = (Get-Date).AddMinutes(-5)
            $progressPath = Join-Path $logWork 'progress.log'
            $plan = [pscustomobject]@{
                SchemaVersion = 6; Version = '26H2-RC'; Components = 'Both'; Email = 'None'
                DomainName = 'WORKGROUP'; ComputerName = 'labserver'; SqlInstance = 'localhost'
                JoinMode = 'Workgroup'; DnsHostName = 'labserver'; AllowUnsupportedOs = $false
                SetupAccount = 'labserver\labadmin'; SetupSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
                StageIndex = 0; Status = 'Failed'; LastError = 'Fixture error'; CertificateThumbprint = ''
                RebootAfter = ''; PatchSelection = 'Skip'; Ports = $null
            }
            function Set-LogFixture {
                param([string]$Path, [string[]]$Lines, [datetime]$Time = (Get-Date))
                $Lines | Set-Content -LiteralPath $Path -Encoding UTF8
                (Get-Item -LiteralPath $Path).LastWriteTime = $Time
            }
            function Set-StageFixture {
                param([string]$Stage)
                $plan.StageIndex = [array]::IndexOf(@(Get-SetupSteps -Plan $plan), $Stage)
                Set-LogFixture -Path $progressPath -Lines @(
                    "$($start.AddMinutes(-20).ToString('o')) Starting $Stage",
                    'OLD_RETRY_OUTPUT',
                    "$($start.ToString('o')) Starting $Stage",
                    'CURRENT_STAGE_OUTPUT'
                )
            }
            function Get-ScheduledTask {
                [CmdletBinding()] param()
                [pscustomobject]@{ TaskName = 'AdoServerLabAutoOrchestrator-Resume'; TaskPath = '\'; State = 'Ready' }
            }
            Set-LogFixture -Path (Join-Path $env:TEMP 'azuredevops-install.log') -Lines 'DEVOPS_TEMP_OUTPUT'
            Set-LogFixture -Path (Join-Path $env:TEMP 'unrelated.log') -Lines 'UNRELATED_OUTPUT'
            Set-StageFixture -Stage 'DevOps'
            $text = Get-SetupMonitoringLogs -Work $logWork -Plan $plan
            if ($text -notlike '*DEVOPS_TEMP_OUTPUT*' -or $text -like '*OLD_RETRY_OUTPUT*' -or $text -like '*UNRELATED_OUTPUT*') {
                throw 'DevOps monitoring must select matching current TEMP logs and hide previous retries/unrelated files.'
            }
            $rootTemp = $env:TEMP
            $sessionTemp = Join-Path $rootTemp '2'
            $otherSessionTemp = Join-Path $rootTemp '3'
            $arbitraryFolder = Join-Path $rootTemp 'Unrelated'
            foreach ($folder in @($sessionTemp, $otherSessionTemp, $arbitraryFolder)) {
                New-Item -ItemType Directory -Path $folder -Force | Out-Null
            }
            $txtLog = Join-Path $rootTemp 'dd_devops_server_20261110120104.txt'
            Set-LogFixture -Path $txtLog -Lines 'DEVOPS_TXT_OUTPUT' -Time (Get-Date).AddSeconds(3)
            Set-LogFixture -Path (Join-Path $rootTemp 'dd_devops_server_old.txt') -Lines 'STALE_TXT_OUTPUT' -Time $start.AddMinutes(-1)
            Set-LogFixture -Path (Join-Path $arbitraryFolder 'dd_devops_server.txt') -Lines 'OUT_OF_SCOPE_OUTPUT' -Time (Get-Date).AddMinutes(1)
            $env:TEMP = $sessionTemp
            Save-SetupState -State $plan -Path (Join-Path $logWork 'state.json')
            $snapshot = Get-UiSnapshot
            if ($snapshot.Logs -notlike '*DEVOPS_TXT_OUTPUT*' -or $snapshot.Logs -like '*STALE_TXT_OUTPUT*' -or
                $snapshot.Logs -like '*OUT_OF_SCOPE_OUTPUT*') {
                throw 'The UI must discover screenshot-style .txt logs in the parent TEMP of an interactive numbered session without scanning arbitrary subfolders.'
            }
            Set-LogFixture -Path (Join-Path $otherSessionTemp 'dd_devops_server_component.txt') -Lines 'SESSION_TXT_OUTPUT' -Time (Get-Date).AddSeconds(5)
            $text = Get-SetupMonitoringLogs -Work $logWork -Plan $plan
            if ($text -notlike '*SESSION_TXT_OUTPUT*') { throw 'Numbered sibling TEMP session directories must be checked for installer text logs.' }
            $env:TEMP = $rootTemp
            if ((Get-SetupMonitoringLogs -Work $logWork -Plan $plan) -notlike '*SESSION_TXT_OUTPUT*') {
                throw 'A non-session TEMP root must also discover numbered session subdirectories.'
            }
            $env:TEMP = $otherSessionTemp
            $text = Get-SetupMonitoringLogs -Work $logWork -Plan $plan
            if ([regex]::Matches($text, 'SESSION_TXT_OUTPUT').Count -ne 1) { throw 'Overlapping TEMP root/session searches must not duplicate a selected file.' }
            $env:TEMP = $rootTemp
            Set-LogFixture -Path (Join-Path $windowsTemp 'dd_devops_server.txt') -Lines 'WINDOWS_TEMP_TXT_OUTPUT' -Time (Get-Date).AddSeconds(6)
            if ((Get-SetupMonitoringLogs -Work $logWork -Plan $plan) -notlike '*WINDOWS_TEMP_TXT_OUTPUT*') {
                throw 'Windows TEMP must support .txt installer logs as well as .log.'
            }
            Set-StageFixture -Stage 'Ssms'
            Set-LogFixture -Path (Join-Path $windowsTemp 'dd_ssms.log') -Lines @('SSMS_FIRST', 'SSMS_SECOND', 'SSMS_LAST')
            Set-LogFixture -Path (Join-Path $env:TEMP 'dd_vcredist.log') -Lines 'VCREDIST_OUTPUT'
            Set-LogFixture -Path (Join-Path $ssmsTemp 'detail.txt') -Lines 'SSMS_NESTED_OUTPUT'
            Set-LogFixture -Path (Join-Path $env:TEMP 'SSMS20-Setup.log') -Lines 'STALE_SETUP_OUTPUT' -Time $start.AddMinutes(-1)
            $text = Get-SetupMonitoringLogs -Work $logWork -Plan $plan -TailLines 2
            if ($text -notlike '*SSMS_SECOND*SSMS_LAST*' -or $text -notlike '*SSMS_NESTED_OUTPUT*' -or
                $text -like '*SSMS_FIRST*' -or $text -like '*DEVOPS_TEMP_OUTPUT*' -or $text -like '*VCREDIST_OUTPUT*' -or $text -like '*STALE_SETUP_OUTPUT*') {
                throw 'SSMS monitoring must include Windows TEMP and nested SSMS logs with bounded tails, stage filtering and stale-log exclusion.'
            }
            $statePathFixture = Join-Path $logWork 'state.json'
            Save-SetupState -State $plan -Path $statePathFixture
            $before = [IO.File]::ReadAllText($statePathFixture)
            $snapshot = Get-UiSnapshot
            if ($snapshot.Logs -notlike '*SSMS_NESTED_OUTPUT*' -or $snapshot.Logs -notlike '*SSMS_FIRST*' -or $snapshot.Error -ne 'Fixture error') {
                throw 'UI snapshots must include detailed current-stage installer tails and preserve saved errors.'
            }
            if ((Get-UiSnapshot).Logs -cne $snapshot.Logs -or [IO.File]::ReadAllText($statePathFixture) -cne $before) {
                throw 'Repeated UI refreshes must return the same snapshot without appending duplicates or writing state.'
            }
            $lockedLog = [IO.File]::Open((Join-Path $windowsTemp 'dd_ssms.log'), [IO.FileMode]::Open,
                [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            try {
                $rejected = $false
                try { Get-UiSnapshot | Out-Null }
                catch [IO.IOException] { $rejected = $true }
                if (-not $rejected) { throw 'An unreadable installer log must surface an error rather than a success-shaped empty snapshot.' }
            }
            finally { $lockedLog.Dispose() }
            $console = (& (Join-Path $root 'GuestSetup\Monitor-Setup.ps1') -Once -TailLines 40 6>&1 | Out-String)
            if ($console -notlike '*SSMS_NESTED_OUTPUT*' -or $console -notlike '*SSMS_FIRST*') { throw 'Console and UI must use the same detailed log selection.' }
            Set-LogFixture -Path (Join-Path $env:TEMP 'SSMS20-Setup.log') -Lines 'LEGACY_SSMS_OUTPUT' -Time (Get-Date).AddSeconds(2)
            if ((Get-SetupMonitoringLogs -Work $logWork -Plan $plan) -notlike '*LEGACY_SSMS_OUTPUT*') { throw 'Legacy SSMS20 TEMP logs must also be selected.' }
            Set-StageFixture -Stage 'Configure'
            Set-LogFixture -Path (Join-Path $productLogs 'TFS_config.log') -Lines 'CONFIGURE_OUTPUT'
            Set-LogFixture -Path (Join-Path $logWork 'Logs\setup-fixture.log') -Lines @(
                'PREVIOUS_TRANSCRIPT_STAGE',
                "$($start.ToString('o')) Starting Configure",
                'CURRENT_TRANSCRIPT_STAGE'
            )
            $text = Get-SetupMonitoringLogs -Work $logWork -Plan $plan
            if ($text -notlike '*CONFIGURE_OUTPUT*' -or $text -notlike '*CURRENT_TRANSCRIPT_STAGE*' -or $text -like '*PREVIOUS_TRANSCRIPT_STAGE*') {
                throw 'Configuration monitoring must include product logs and trim the previous transcript stage.'
            }
            $plan.Version = '25H2'; $plan.PatchSelection = '9'
            Set-StageFixture -Stage 'Patch'
            Set-LogFixture -Path (Join-Path $productLogs 'Patch_fixture.log') -Lines 'PATCH_PRODUCT_OUTPUT'
            Set-LogFixture -Path (Join-Path $windowsTemp 'devops-patch.log') -Lines 'PATCH_TEMP_OUTPUT' -Time (Get-Date).AddSeconds(10)
            $text = Get-SetupMonitoringLogs -Work $logWork -Plan $plan
            if ($text -notlike '*PATCH_PRODUCT_OUTPUT*' -or $text -notlike '*PATCH_TEMP_OUTPUT*' -or $text -like '*CONFIGURE_OUTPUT*') {
                throw 'Patch monitoring must select current product and TEMP patch logs only.'
            }
            Set-StageFixture -Stage 'Sql'
            Set-LogFixture -Path (Join-Path $sqlLogs 'Summary.txt') -Lines 'SQL_SUMMARY_OUTPUT'
            Set-LogFixture -Path (Join-Path $sqlRun 'Detail.txt') -Lines 'SQL_DETAIL_OUTPUT'
            Set-LogFixture -Path (Join-Path $sqlRun 'component.log') -Lines 'SQL_COMPONENT_OUTPUT'
            Set-LogFixture -Path (Join-Path $env:TEMP 'SQL2025-SSEI.log') -Lines 'SQL_BOOTSTRAP_TEMP_OUTPUT'
            $text = Get-SetupMonitoringLogs -Work $logWork -Plan $plan
            foreach ($expected in @('SQL_SUMMARY_OUTPUT', 'SQL_DETAIL_OUTPUT', 'SQL_COMPONENT_OUTPUT', 'SQL_BOOTSTRAP_TEMP_OUTPUT')) {
                if ($text -notlike "*$expected*") { throw "Missing SQL monitoring source: $expected" }
            }
            $start = (Get-Date).AddHours(-1)
            Set-StageFixture -Stage 'Sql'
            $sqlSources = @(
                (Join-Path $sqlLogs 'Summary.txt'), (Join-Path $sqlRun 'Detail.txt'),
                (Join-Path $sqlRun 'component.log'), (Join-Path $env:TEMP 'SQL2025-SSEI.log')
            )
            for ($source = 0; $source -lt $sqlSources.Count; $source++) {
                Set-LogFixture -Path $sqlSources[$source] -Lines @(1..15 | ForEach-Object { "SQL_CAP_${source}_$_" }) -Time (Get-Date).AddMinutes(-9)
            }
            Add-Content -LiteralPath $progressPath -Value @(1..30 | ForEach-Object { "SCRIPT_PROGRESS_$_" })
            (Get-Item -LiteralPath $progressPath).LastWriteTime = (Get-Date).AddMinutes(-30)
            Set-LogFixture -Path (Join-Path $logWork 'Logs\setup-fixture.log') -Lines @(
                "$($start.ToString('o')) Starting Sql"
                'CURRENT_TRANSCRIPT_STAGE'
                1..30 | ForEach-Object { "SCRIPT_TRANSCRIPT_$_" }
            ) -Time (Get-Date).AddMinutes(-30)
            Save-SetupState -State $plan -Path $statePathFixture
            $snapshot = Get-UiSnapshot
            for ($source = 0; $source -lt $sqlSources.Count; $source++) {
                if ([regex]::Matches($snapshot.Logs, "(?m)^SQL_CAP_${source}_\d+\r?$").Count -ne 10 -or
                    $snapshot.Logs -notlike "*SQL_CAP_${source}_6*" -or $snapshot.Logs -notlike "*SQL_CAP_${source}_15*") {
                    throw 'UI SQL installer sources must each be capped at their last 10 lines.'
                }
            }
            if ($snapshot.Logs -notmatch 'SCRIPT_PROGRESS_1\r?\n' -or $snapshot.Logs -notmatch 'SCRIPT_TRANSCRIPT_1\r?\n' -or
                $snapshot.Logs.IndexOf('SCRIPT_TRANSCRIPT_30') -ge $snapshot.Logs.IndexOf('--- Installer details:')) {
                throw 'UI script progress/transcript must remain primary and retain 40-line tails without the installer freshness limit.'
            }
            foreach ($path in $sqlSources) { (Get-Item -LiteralPath $path).LastWriteTime = (Get-Date).AddMinutes(-11) }
            $snapshot = Get-UiSnapshot
            if ($snapshot.Logs -like '*SQL_CAP_*' -or $snapshot.Logs -notlike '*No recent installer log activity*' -or
                $snapshot.Logs -notlike '*SCRIPT_TRANSCRIPT_30*') {
                throw 'UI SQL Summary, Detail, component and TEMP logs must all respect the 10-minute freshness limit while script output remains visible.'
            }
            Set-StageFixture -Stage 'Configure'
            (Get-Item -LiteralPath (Join-Path $productLogs 'TFS_config.log')).LastWriteTime = (Get-Date).AddMinutes(-11)
            $text = Get-SetupMonitoringLogs -Work $logWork -Plan $plan
            if ($text -like '*CONFIGURE_OUTPUT*' -or $text -notlike '*No recent installer log activity*') {
                throw 'DevOps product logs must also respect the installer freshness limit.'
            }
            Set-StageFixture -Stage 'Ssms'
            foreach ($path in @((Join-Path $windowsTemp 'dd_ssms.log'), (Join-Path $ssmsTemp 'detail.txt'), (Join-Path $env:TEMP 'SSMS20-Setup.log'))) {
                (Get-Item -LiteralPath $path).LastWriteTime = (Get-Date).AddMinutes(-11)
            }
            $text = Get-SetupMonitoringLogs -Work $logWork -Plan $plan
            if ($text -like '*SSMS_NESTED_OUTPUT*' -or $text -like '*SSMS_LAST*' -or $text -like '*LEGACY_SSMS_OUTPUT*' -or
                $text -notlike '*No recent installer log activity*') {
                throw 'Nested, legacy and Windows TEMP SSMS logs must all respect the freshness limit.'
            }
            (Get-Item -LiteralPath (Join-Path $ssmsTemp 'detail.txt')).LastWriteTime = (Get-Date).AddMinutes(-9)
            $text = Get-SetupMonitoringLogs -Work $logWork -Plan $plan
            if ($text -notlike '*SSMS_NESTED_OUTPUT*' -or $text -like '*No recent installer log activity*') {
                throw 'A recent nested SSMS log must suppress the quiet-activity message even when top-level TEMP logs are old.'
            }
            $cache = Join-Path $env:ProgramData 'Package Cache'
            $core = Join-Path $cache '{BE64CD0C-C736-3B1A-A002-405B70719515}v20.0.37715\packages\DevOpsServer\Core'
            $web = Join-Path $cache '{83EFDEA7-9524-342B-96AC-545985AB4631}v20.0.37715\packages\DevOpsServer\Web'
            $otherCore = Join-Path $cache '{11111111-2222-3333-4444-555555555555}v21.1\packages\DevOpsServer\Core'
            $otherProduct = Join-Path $cache '{11111111-2222-3333-4444-555555555555}v21.1\packages\OtherProduct\Core'
            $invalidCache = Join-Path $cache 'Unrelated\packages\DevOpsServer\Core'
            foreach ($folder in @($core, $web, $otherCore, $otherProduct, $invalidCache, (Join-Path $core 'nested'))) {
                New-Item -ItemType Directory -Path $folder -Force | Out-Null
            }
            $coreCab = Join-Path $core 'core-latest.cab'
            $webMsi = Join-Path $web 'devOps_serverWeb.msi'
            Set-LogFixture -Path $coreCab -Lines 'PAYLOAD_CONTENT_MUST_NOT_BE_SHOWN' -Time (Get-Date).AddMinutes(-1)
            Set-LogFixture -Path (Join-Path $core 'core-older.cab') -Lines 'PAYLOAD_CONTENT_MUST_NOT_BE_SHOWN' -Time (Get-Date).AddMinutes(-2)
            Set-LogFixture -Path $webMsi -Lines 'PAYLOAD_CONTENT_MUST_NOT_BE_SHOWN' -Time (Get-Date).AddMinutes(-3)
            Set-LogFixture -Path (Join-Path $otherCore 'alternate-core.cab') -Lines 'PAYLOAD_CONTENT_MUST_NOT_BE_SHOWN' -Time (Get-Date).AddMinutes(-4)
            foreach ($path in @(
                (Join-Path $core 'not-a-payload.txt'), (Join-Path $core 'nested\nested.cab'),
                (Join-Path $otherProduct 'unrelated-product.cab'), (Join-Path $invalidCache 'invalid-cache.cab')
            )) { Set-LogFixture -Path $path -Lines 'PAYLOAD_CONTENT_MUST_NOT_BE_SHOWN' }
            Set-StageFixture -Stage 'DevOps'
            Save-SetupState -State $plan -Path $statePathFixture
            $stateBefore = [IO.File]::ReadAllText($statePathFixture)
            $payloadBefore = [IO.File]::ReadAllBytes($coreCab)
            $payloadTime = (Get-Item -LiteralPath $coreCab).LastWriteTime
            $lockedPayload = [IO.File]::Open($coreCab, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            try { $snapshot = Get-UiSnapshot }
            finally { $lockedPayload.Dispose() }
            if ($snapshot.Logs -notlike '*Installer payload activity*Core:*core-latest.cab*Web:*devOps_serverWeb.msi*' -or
                $snapshot.Logs -notlike "*Size: $((Get-Item -LiteralPath $coreCab).Length) bytes; Last updated:*" -or
                $snapshot.Logs -notlike "*Last updated: $($payloadTime.ToString('yyyy-MM-dd HH:mm:ss'))*" -or
                $snapshot.Logs -match 'core-older.cab|alternate-core.cab|not-a-payload.txt|nested.cab|unrelated-product.cab|invalid-cache.cab|PAYLOAD_CONTENT_MUST_NOT_BE_SHOWN') {
                throw 'UI payload activity must show only the latest CAB/MSI metadata per Core/Web component from valid versioned caches, without reading payload contents.'
            }
            if ($snapshot.Logs.IndexOf('SCRIPT_TRANSCRIPT_30') -ge $snapshot.Logs.IndexOf('--- Installer payload activity') -or
                ($snapshot.Logs -like '*--- Installer details:*' -and
                    $snapshot.Logs.IndexOf('--- Installer payload activity') -ge $snapshot.Logs.IndexOf('--- Installer details:'))) {
                throw 'Payload metadata must appear after script output and before detailed installer logs.'
            }
            if ((Get-UiSnapshot).Logs -cne $snapshot.Logs -or [IO.File]::ReadAllText($statePathFixture) -cne $stateBefore -or
                [Convert]::ToBase64String([IO.File]::ReadAllBytes($coreCab)) -cne [Convert]::ToBase64String($payloadBefore) -or
                (Get-Item -LiteralPath $coreCab).LastWriteTime -ne $payloadTime) {
                throw 'Refreshing payload metadata must not append duplicates or modify setup state, payload bytes or modified times.'
            }
            $console = (& (Join-Path $root 'GuestSetup\Monitor-Setup.ps1') -Once -TailLines 40 6>&1 | Out-String)
            if ($console -notlike '*Installer payload activity*core-latest.cab*devOps_serverWeb.msi*') {
                throw 'The console monitor must share the same payload activity summary as the UI.'
            }
            foreach ($stage in @('Sql', 'Ssms', 'Configure', 'Verify')) {
                Set-StageFixture -Stage $stage
                if ((Get-SetupMonitoringLogs -Work $logWork -Plan $plan) -like '*Installer payload activity*') {
                    throw 'DevOps cache activity must be hidden during unrelated stages.'
                }
            }
            Set-StageFixture -Stage 'Patch'
            if ((Get-SetupMonitoringLogs -Work $logWork -Plan $plan) -notlike '*Installer payload activity*core-latest.cab*') {
                throw 'DevOps patch monitoring must also show recent matching cache payload activity.'
            }
            $start = (Get-Date).AddSeconds(-30)
            Set-StageFixture -Stage 'DevOps'
            if ((Get-SetupMonitoringLogs -Work $logWork -Plan $plan) -like '*Installer payload activity*') {
                throw 'Payload files from before the current stage/retry must not be shown.'
            }
            $start = (Get-Date).AddHours(-1)
            Set-StageFixture -Stage 'DevOps'
            foreach ($path in @($coreCab, (Join-Path $core 'core-older.cab'), $webMsi, (Join-Path $otherCore 'alternate-core.cab'))) {
                (Get-Item -LiteralPath $path).LastWriteTime = (Get-Date).AddMinutes(-11)
            }
            if ((Get-SetupMonitoringLogs -Work $logWork -Plan $plan) -like '*Installer payload activity*') {
                throw 'Payload activity older than 10 minutes must disappear even while the DevOps stage is active.'
            }
            $plan.StageIndex = [array]::IndexOf(@(Get-SetupSteps -Plan $plan), 'Verify')
            if ((Get-SetupMonitoringLogs -Work $logWork -Plan $plan) -notlike 'Waiting for the current stage*') {
                throw 'A stage with no start marker must not show stale installer output.'
            }
            $plan.StageIndex = @(Get-SetupSteps -Plan $plan).Count; $plan.Status = 'Completed'
            $text = Get-SetupMonitoringLogs -Work $logWork -Plan $plan
            if ($text -like '*SQL_COMPONENT_OUTPUT*' -or $text -notlike '*CURRENT_TRANSCRIPT_STAGE*') {
                throw 'Completed setup must retain final progress/transcript without unrelated TEMP discovery.'
            }
        }
        finally {
            $env:TEMP = $oldTemp; $env:SystemRoot = $oldSystemRoot; $env:ProgramFiles = $oldProgramFiles
            $env:ProgramData = $fixtureProgramData
            if (Test-Path -LiteralPath $logFixture) { Remove-Item -LiteralPath $logFixture -Recurse -Force }
        }
    }
}
finally {
    $env:ProgramData = $oldProgramData
    $path = Join-Path $work 'state.json'
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    Remove-Item -LiteralPath $work -Force
    Remove-Item -LiteralPath $fixture -Force
}
Write-Host 'PASS: UI command quoting/encoding, version metadata, checksum/package integrity, editable diagnostic preview/redaction, snapshots, resume gates, shared log tails and read-only monitoring.'
