#requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Resume-Setup.ps1')

function Test-GuestSetupOffline {
    param([string]$Folder)
    & {
        Import-Module (Join-Path $Folder 'Setup-Monitoring.psm1') -Force -ErrorAction Stop
        $monitorModule = (Get-Command Get-SetupMonitoringLogs).Module
        $root = Join-Path $env:TEMP ('AdoServerLabAutoOrchestratorMonitoringTest-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $root 'Logs') -Force | Out-Null
        $oldProgramData = $env:ProgramData
        $oldProgramFiles = $env:ProgramFiles
        try {
            $env:ProgramData = Join-Path $root 'ProgramData'
            $env:ProgramFiles = Join-Path $root 'ProgramFiles'
            $since = (Get-Date).AddHours(-1)
            Set-Content -LiteralPath (Join-Path $root 'progress.log') -Value "$($since.ToString('o')) Starting DevOps"
            $bundle = Join-Path $root 'dd_devops_server_20261110120104.log'
            Set-Content -LiteralPath $bundle -Value 'BUNDLE_DOWNLOAD_ACTIVITY'
            (Get-Item -LiteralPath $bundle).LastWriteTime = $since.AddMinutes(51)
            foreach ($number in 1..4) {
                $component = Join-Path $root "dd_devops_server_20261110120104_00${number}_component.log"
                Set-Content -LiteralPath $component -Value "COMPONENT_ACTIVITY_$number"
                (Get-Item -LiteralPath $component).LastWriteTime = $since.AddMinutes(55 + $number)
            }
            $stale = Join-Path $root 'dd_devops_server_20261109120104.log'
            Set-Content -LiteralPath $stale -Value 'STALE_INSTALLER_ACTIVITY'
            (Get-Item -LiteralPath $stale).LastWriteTime = $since.AddMinutes(-1)
            Set-Content -LiteralPath (Join-Path $root 'unrelated.log') -Value 'UNRELATED_ACTIVITY'
            Set-Content -LiteralPath (Join-Path $root 'Logs\setup-fixture.log') -Value 'WORKER_TRANSCRIPT_ACTIVITY'
            & $monitorModule {
                param($fixtureRoot, [datetime]$fixtureSince)
                function Get-SetupTempFolders { return $fixtureRoot }
                function Get-SetupSteps { param($Plan) return 'DevOps' }
                function Get-Date { return $fixtureSince.AddHours(1) }
                $text = Get-SetupMonitoringLogs -Work $fixtureRoot -Plan ([pscustomobject]@{ StageIndex = 0 }) -TailLines 5
                foreach ($expected in @('BUNDLE_DOWNLOAD_ACTIVITY', 'COMPONENT_ACTIVITY_2', 'COMPONENT_ACTIVITY_3',
                    'COMPONENT_ACTIVITY_4', 'WORKER_TRANSCRIPT_ACTIVITY')) {
                    if ($text -notmatch $expected) { throw "Monitoring omitted $expected." }
                }
                if ($text -match 'STALE_INSTALLER_ACTIVITY|UNRELATED_ACTIVITY|COMPONENT_ACTIVITY_1') {
                    throw 'Monitoring must filter old/unrelated logs and bound component log count.'
                }
                Remove-Item -LiteralPath (Join-Path $fixtureRoot 'dd_devops_server_20261110120104.log')
                $text = Get-SetupMonitoringLogs -Work $fixtureRoot -Plan ([pscustomobject]@{ StageIndex = 0 }) -TailLines 5
                if ($text -notmatch 'COMPONENT_ACTIVITY_4') { throw 'Monitoring must work without a bundle log.' }
                $txtBundle = Join-Path $fixtureRoot 'dd_devops_server_20261110120104.txt'
                Set-Content -LiteralPath $txtBundle -Value 'TXT_BUNDLE_DOWNLOAD_ACTIVITY'
                (Get-Item -LiteralPath $txtBundle).LastWriteTime = $fixtureSince.AddMinutes(52)
                $olderBundle = Join-Path $fixtureRoot 'dd_devops_server_20261110110104.log'
                Set-Content -LiteralPath $olderBundle -Value 'OLDER_BUNDLE_ACTIVITY'
                (Get-Item -LiteralPath $olderBundle).LastWriteTime = $fixtureSince.AddMinutes(51)
                Set-Content -LiteralPath (Join-Path $fixtureRoot 'dd_devops_server_payload.cab') -Value 'CAB_PAYLOAD_NOT_LOG_OUTPUT'
                $text = Get-SetupMonitoringLogs -Work $fixtureRoot -Plan ([pscustomobject]@{ StageIndex = 0 }) -TailLines 5
                if ($text -notmatch 'TXT_BUNDLE_DOWNLOAD_ACTIVITY' -or
                    $text -match 'OLDER_BUNDLE_ACTIVITY|COMPONENT_ACTIVITY_1|CAB_PAYLOAD_NOT_LOG_OUTPUT' -or
                    [regex]::Matches($text, 'COMPONENT_ACTIVITY_').Count -ne 3) {
                    throw 'Monitoring must retain the newest recent .txt bundle plus only three component tails, without reading CAB payloads.'
                }
                if ((Get-SetupMonitoringLogs -Work $fixtureRoot -Plan ([pscustomobject]@{ StageIndex = 0 }) -TailLines 5) -cne $text) {
                    throw 'Multi-source monitoring refreshes must not accumulate duplicate output.'
                }
                Get-ChildItem -LiteralPath $fixtureRoot -File |
                    Where-Object { $_.Name -like 'dd_*' } | Remove-Item -Force
                $boundaryLog = Join-Path $fixtureRoot 'dd_devops_server_20261110120104.txt'
                Set-Content -LiteralPath $boundaryLog -Value @(1..12 | ForEach-Object { 'INSTALLER_LINE_{0:d2}' -f $_ })
                (Get-Item -LiteralPath $boundaryLog).LastWriteTime = $fixtureSince.AddMinutes(50)
                $progressLog = Join-Path $fixtureRoot 'progress.log'
                Set-Content -LiteralPath $progressLog -Value @(
                    "$($fixtureSince.ToString('o')) Starting DevOps"
                    1..12 | ForEach-Object { "SCRIPT_PROGRESS_$_" }
                )
                $transcript = Join-Path $fixtureRoot 'Logs\setup-fixture.log'
                Set-Content -LiteralPath $transcript -Value @(1..12 | ForEach-Object { "SCRIPT_TRANSCRIPT_$_" })
                (Get-Item -LiteralPath $progressLog).LastWriteTime = $fixtureSince.AddMinutes(30)
                (Get-Item -LiteralPath $transcript).LastWriteTime = $fixtureSince.AddMinutes(30)
                $contentsBefore = [IO.File]::ReadAllText($boundaryLog)
                $text = Get-SetupMonitoringLogs -Work $fixtureRoot -Plan ([pscustomobject]@{ StageIndex = 0 }) -TailLines 40
                if ([regex]::Matches($text, '(?m)^INSTALLER_LINE_\d+\r?$').Count -ne 10 -or
                    $text -match 'INSTALLER_LINE_01|INSTALLER_LINE_02' -or
                    $text -notmatch 'INSTALLER_LINE_03' -or $text -notmatch 'INSTALLER_LINE_12' -or
                    $text -notmatch 'SCRIPT_PROGRESS_1\r?\n' -or $text -notmatch 'SCRIPT_TRANSCRIPT_1\r?\n' -or
                    $text.IndexOf('SCRIPT_TRANSCRIPT_12') -ge $text.IndexOf('--- Installer details:')) {
                    throw 'Files at exactly 10 minutes must show only their last 10 lines, after script output that remains visible even when 30 minutes old.'
                }
                $text = Get-SetupMonitoringLogs -Work $fixtureRoot -Plan ([pscustomobject]@{ StageIndex = 0 }) -TailLines 2
                if ([regex]::Matches($text, '(?m)^INSTALLER_LINE_\d+\r?$').Count -ne 2) {
                    throw 'Smaller console tail limits must still be respected for installer details.'
                }
                (Get-Item -LiteralPath $boundaryLog).LastWriteTime = $fixtureSince.AddMinutes(50).AddMilliseconds(-1)
                $text = Get-SetupMonitoringLogs -Work $fixtureRoot -Plan ([pscustomobject]@{ StageIndex = 0 }) -TailLines 40
                if ($text -match 'INSTALLER_LINE_|--- Installer details:' -or $text -notmatch 'SCRIPT_TRANSCRIPT_1\r?\n' -or
                    $text -notmatch 'No recent installer log activity \(last 10 minutes\). Setup may still be downloading or working.' -or
                    [IO.File]::ReadAllText($boundaryLog) -cne $contentsBefore) {
                    throw 'Installer files older than 10 minutes must be hidden without changing them or hiding script output; quiet activity must not be reported as a failure.'
                }
                $payloadFolder = Join-Path $env:ProgramData 'Package Cache\{83EFDEA7-9524-342B-96AC-545985AB4631}v20.0.37715\packages\DevOpsServer\Core'
                New-Item -ItemType Directory -Path $payloadFolder -Force | Out-Null
                $payload = Join-Path $payloadFolder 'cab1.cab'
                [IO.File]::WriteAllBytes($payload, [byte[]](0..31))
                (Get-Item -LiteralPath $payload).LastWriteTime = $fixtureSince.AddMinutes(50)
                $activity = @(Get-SetupDevOpsPayloadActivity -Since $fixtureSince.AddMinutes(50))
                if ($activity.Count -ne 1 -or $activity[0] -notlike '*Core:*cab1.cab*Size: 32 bytes; Last updated:*') {
                    throw 'Payload metadata must include exactly the newest Core file with its path, byte count and time at the inclusive 10-minute boundary.'
                }
                (Get-Item -LiteralPath $payload).LastWriteTime = $fixtureSince.AddMinutes(50).AddMilliseconds(-1)
                if (@(Get-SetupDevOpsPayloadActivity -Since $fixtureSince.AddMinutes(50)).Count) {
                    throw 'Payload metadata older than the 10-minute boundary must be excluded.'
                }
                (Get-Item -LiteralPath $payload).LastWriteTime = $fixtureSince.AddMinutes(55)
                if (@(Get-SetupDevOpsPayloadActivity -Since $fixtureSince.AddMinutes(58)).Count) {
                    throw 'Recent payload files from before the current stage started must be excluded.'
                }
                Remove-Item -LiteralPath $payload -Force
                foreach ($fixtureStage in @('DevOps', 'Patch', 'Sql', 'Ssms')) {
                    function Get-SetupSteps { param($Plan) return $fixtureStage }
                    Set-Content -LiteralPath (Join-Path $fixtureRoot 'progress.log') -Value "$($fixtureSince.ToString('o')) Starting $fixtureStage"
                    Set-Content -LiteralPath (Join-Path $fixtureRoot 'Logs\setup-fixture.log') -Value @(
                        'PREVIOUS_TRANSCRIPT_STAGE',
                        "$($fixtureSince.ToString('o')) Starting $fixtureStage",
                        'CURRENT_TRANSCRIPT_STAGE'
                    )
                    $text = Get-SetupMonitoringLogs -Work $fixtureRoot -Plan ([pscustomobject]@{ StageIndex = 0; Version = '25H2' }) -TailLines 5
                    if ($text -notmatch 'CURRENT_TRANSCRIPT_STAGE' -or $text -match 'PREVIOUS_TRANSCRIPT_STAGE' -or
                        $text -notmatch 'No recent installer log activity') {
                        throw 'Installer stages with no TEMP logs must still show the current transcript and explain missing logs.'
                    }
                }
            } $root $since
        }
        finally {
            $env:ProgramData = $oldProgramData
            $env:ProgramFiles = $oldProgramFiles
            Remove-Item -LiteralPath $root -Recurse -Force
        }
    }
    $module = (Get-Command Get-SetupRelease -ErrorAction Stop).Module
    $expectedExports = @('Assert-SetupOperatingSystem', 'Get-SetupPatchCatalog', 'Get-SetupRelease')
    if ($null -eq $module -or $module.Path -ne (Join-Path $Folder 'Setup-Releases.psm1') -or
        (@($module.ExportedFunctions.Keys | Sort-Object) -join ',') -ne ($expectedExports -join ',') -or
        $module.ExportedVariables.Count -or $module.ExportedAliases.Count) {
        throw 'Release module must load from this script folder and export only its three public functions.'
    }
    $stateModule = (Get-Command Assert-SetupPlan -ErrorAction Stop).Module
    & {
        $rc = Get-SetupRelease -Version '26H2-RC'
        if ($rc.DevOpsUrl -ne 'https://go.microsoft.com/fwlink/?LinkId=2383605' -or
            $rc.SqlMajor -ne 17 -or $rc.SqlYear -ne 2025 -or $rc.ApiVersion -ne '7.0' -or
            $rc.LatestPatchNumber -ne 'Skip' -or @(Get-SetupPatchCatalog -Version '26H2-RC').Count) {
            throw '26H2 RC must use separate media, SQL 2025 and no stable-release patches.'
        }
        foreach ($choice in @('Latest', 'Skip')) {
            if ((Resolve-SetupPatchChoice -Version '26H2-RC' -Choice $choice) -ne 'Skip') { throw 'RC Latest/Skip must resolve to Skip.' }
        }
        foreach ($choice in @('1', '9', '12', '', '0')) {
            $rejected = $false
            try { Resolve-SetupPatchChoice -Version '26H2-RC' -Choice $choice | Out-Null }
            catch { if ($_.Exception.Message -notlike 'Invalid patch*') { throw }; $rejected = $true }
            if (-not $rejected) { throw 'RC must reject numeric patches from other releases.' }
        }
        foreach ($components in @('Both', 'SqlOnly', 'DevOpsOnly')) {
            foreach ($email in @('None', 'Capture')) {
                if ($components -eq 'SqlOnly' -and $email -eq 'Capture') { continue }
                $plan = [pscustomobject]@{
                    SchemaVersion = 6; Version = '26H2-RC'; Components = $components; Email = $email
                    DomainName = 'WORKGROUP'; ComputerName = 'labserver'; SqlInstance = 'localhost'
                    JoinMode = 'Workgroup'; DnsHostName = 'labserver'; AllowUnsupportedOs = $false
                    SetupAccount = 'labserver\labadmin'; SetupSid = 'S-1-5-21-1-2-3-1000'
                    StageIndex = 0; Status = 'Pending'; LastError = ''; CertificateThumbprint = ''
                    RebootAfter = ''; PatchSelection = 'Skip'; Ports = $null
                }
                Assert-SetupPlan -Plan ($plan | ConvertTo-Json | ConvertFrom-Json)
                $steps = @(Get-SetupSteps -Plan $plan)
                if ($steps -contains 'Patch' -or $null -ne (Get-SelectedSetupPatch -Plan $plan)) { throw 'RC stage plan must never install or verify a stable patch.' }
                foreach ($step in $steps) { Complete-SetupStage -State $plan -RebootRequired ($step -eq 'Sql'); Assert-SetupPlan -Plan $plan }
                $plan.Status = 'Completed'; Assert-SetupPlan -Plan $plan
            }
        }
        foreach ($case in @(
            @{ Type = 3; Build = 20348; Allowed = $true },
            @{ Type = 3; Build = 26100; Allowed = $true },
            @{ Type = 1; Build = 26100; Allowed = $true },
            @{ Type = 1; Build = 26300; Allowed = $false },
            @{ Type = 3; Build = 17763; Allowed = $false },
            @{ Type = 2; Build = 20348; Allowed = $false }
        )) {
            $rejected = $false
            try { Assert-SetupOperatingSystem -Version '26H2-RC' -ProcessorArchitecture AMD64 -Os ([pscustomobject]@{
                ProductType = $case.Type; BuildNumber = $case.Build; OperatingSystemSKU = 48; OSArchitecture = '64-bit'
            }) }
            catch [NotSupportedException] { $rejected = $true }
            if ($rejected -eq $case.Allowed) { throw 'RC OS matrix must match the selected current-server pairing.' }
        }
    }
    $updateOne = Get-SetupRelease -Version '2022.1'
    $updateTwo = Get-SetupRelease -Version '2022'
    if ($updateOne.DevOpsUrl -ne 'https://go.microsoft.com/fwlink/?LinkId=2245669' -or
        $updateOne.SqlMajor -ne 16 -or $updateOne.LatestPatchNumber -ne '4' -or
        $updateTwo.DevOpsUrl -ne 'https://go.microsoft.com/fwlink/?LinkId=2269844' -or
        $updateTwo.LatestPatchNumber -ne '12') {
        throw 'Update 1 and Update 2 must retain distinct installation media and patch defaults.'
    }
    foreach ($patchEntry in @(Get-SetupPatchCatalog -Version '2022.1')) {
        if ($patchEntry.Url -ne "https://aka.ms/devops2022.1patch$($patchEntry.Number)" -or
            @(Get-SetupPatchCatalog -Version '2022' | Where-Object Hash -eq $patchEntry.Hash).Count) {
            throw 'Update 1 patches must not reuse Update 2 URLs or hashes.'
        }
    }
    $stateExports = @('Assert-SetupPlan', 'Complete-SetupStage', 'Get-SelectedSetupPatch', 'Get-SetupAllowUnsupportedOs', 'Get-SetupHostName', 'Get-SetupJoinMode', 'Get-SetupSteps',
        'Read-SetupState', 'Resolve-SetupPatchChoice', 'Save-SetupState', 'Update-SetupStateSchema')
    if ($null -eq $stateModule -or $stateModule.Path -ne (Join-Path $Folder 'Setup-State.psm1') -or
        (@($stateModule.ExportedFunctions.Keys | Sort-Object) -join ',') -ne ($stateExports -join ',') -or
        $stateModule.ExportedVariables.Count -or $stateModule.ExportedAliases.Count) {
        throw 'State module must load from this script folder and export only its eleven public functions.'
    }
    & {
        function Assert-MembershipRejection {
            param([scriptblock]$Action, [string]$Pattern)
            $rejected = $false
            try { & $Action | Out-Null }
            catch {
                if ($_.Exception.Message -notlike $Pattern) { throw }
                $rejected = $true
            }
            if (-not $rejected) { throw "Expected membership validation failure: $Pattern" }
        }
        $plan = [pscustomobject]@{
            SchemaVersion = 5; JoinMode = 'Workgroup'; DnsHostName = 'labserver'; DomainName = 'WORKGROUP'
            ComputerName = 'labserver'; SetupAccount = 'labserver\labadmin'; SetupSid = 'S-1-5-21-1-2-3-1000'
            Version = '2022'; Components = 'Both'; Email = 'Capture'; SqlInstance = 'localhost'
            StageIndex = 0; Status = 'Pending'; LastError = ''; CertificateThumbprint = ''; RebootAfter = ''
            PatchSelection = 'Skip'; Ports = [pscustomobject]@{ Https = 8443; Ssh = 2222; Smtp = 2525; MailUi = 5001 }
        }
        foreach ($version in @('2020', '2022.1', '2022', '25H2')) {
            $plan.Version = $version
            foreach ($mode in @('Domain', 'Workgroup')) {
                $plan.JoinMode = $mode
                $plan.DomainName = if ($mode -eq 'Domain') { 'ak.com' } else { 'WORKGROUP' }
                $plan.SetupAccount = if ($mode -eq 'Domain') { 'AK\labadmin' } else { 'labserver\labadmin' }
                $plan.DnsHostName = if ($mode -eq 'Domain') { 'labserver.ak.com' } else { 'labserver' }
                Assert-SetupPlan -Plan $plan
                Assert-SetupPlan -Plan ($plan | ConvertTo-Json -Depth 5 | ConvertFrom-Json)
                $computer = [pscustomobject]@{
                    Name = 'labserver'; Domain = $plan.DomainName; PartOfDomain = ($mode -eq 'Domain'); DomainRole = 3
                }
                Assert-SetupMachineIdentity -Plan $plan -Computer $computer
                $computer.PartOfDomain = -not $computer.PartOfDomain
                Assert-MembershipRejection { Assert-SetupMachineIdentity -Plan $plan -Computer $computer } '*identity no longer matches*'
                $computer.PartOfDomain = ($mode -eq 'Domain'); $computer.DomainRole = 4
                Assert-MembershipRejection { Assert-SetupMachineIdentity -Plan $plan -Computer $computer } '*identity no longer matches*'
                if ((Get-SetupDevOpsUrl -Plan $plan) -ne "https://$($plan.DnsHostName):8443/tfs") { throw 'Membership hostname must be used in the public URL.' }
            }
        }
        $plan.JoinMode = 'Workgroup'; $plan.DomainName = 'WORKGROUP'; $plan.SetupAccount = 'labserver\labadmin'
        foreach ($invalid in @('127.0.0.1', '::1', 'localhost', '*.lab.example.com', 'https://lab.example.com', 'bad/name', 'bad..example.com')) {
            $plan.DnsHostName = $invalid
            Assert-MembershipRejection { Assert-SetupPlan -Plan $plan } '*DNS hostname must*'
        }
        $plan.DnsHostName = 'devops.lab.example.com'
        Assert-SetupPlan -Plan $plan
        $plan.SetupAccount = 'AK\labadmin'
        Assert-MembershipRejection { Assert-SetupPlan -Plan $plan } '*local Windows account*'
        $plan.SetupAccount = 'labserver\labadmin'
        $dnsAddress = '192.0.2.10'
        $networkCategory = 'Private'
        function Resolve-DnsName {
            [CmdletBinding()] param($Name, $Type, [switch]$DnsOnly)
            if ($Name -ne 'devops.lab.example.com' -or $Type -ne 'A_AAAA' -or -not $DnsOnly) { throw 'Custom name must be queried through DNS.' }
            [pscustomobject]@{ IPAddress = $dnsAddress }
        }
        function Get-NetIPAddress { [CmdletBinding()] param() [pscustomobject]@{ IPAddress = '192.0.2.10' } }
        function Get-NetConnectionProfile { [CmdletBinding()] param() [pscustomobject]@{ NetworkCategory = $networkCategory } }
        Assert-SetupHostResolution -Plan $plan
        $dnsAddress = '192.0.2.11'
        Assert-MembershipRejection { Assert-SetupHostResolution -Plan $plan } '*must resolve only to this VM*'
        $dnsAddress = '127.0.0.1'
        Assert-MembershipRejection { Assert-SetupHostResolution -Plan $plan } '*must resolve only to this VM*'
        if ((Get-SetupFirewallProfile -Plan $plan) -ne 'Private') { throw 'Workgroup rules require Private profile.' }
        $networkCategory = 'Public'
        Assert-MembershipRejection { Get-SetupFirewallProfile -Plan $plan } '*trusted Private network*'
        $plan.DnsHostName = 'labserver'
        function Resolve-DnsName { throw 'Default computer hostname must not require a custom DNS record.' }
        Assert-SetupHostResolution -Plan $plan
        $plan.JoinMode = 'Domain'; $plan.DomainName = 'ak.com'; $plan.DnsHostName = 'labserver.ak.com'; $plan.SetupAccount = 'AK\labadmin'
        if ((Get-SetupFirewallProfile -Plan $plan) -ne 'Domain') { throw 'Legacy/domain rules must retain Domain profile.' }
        Assert-SetupHostResolution -Plan $plan
    }
    & {
        $trace = New-Object 'System.Collections.Generic.List[string]'
        $realNewObject = Get-Command New-Object -CommandType Cmdlet
        $rsa = [Security.Cryptography.RSA]::Create()
        $request = [Security.Cryptography.X509Certificates.CertificateRequest]::new(
            'CN=OfflineTest', $rsa, [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
        $fixtureCertificate = $request.CreateSelfSigned([datetimeoffset]::Now.AddMinutes(-1), [datetimeoffset]::Now.AddDays(1))
        $emptyDatabases = New-Object Data.DataTable
        $emptyDatabases.Columns.Add('name', [string]) | Out-Null
        $iniTemplate = (@('InstallSqlExpress','SqlInstance','StartTrial','ConfigureSearch','CreateInitialCollection',
            'CollectionName','UrlHostNameAlias','WebSiteVDirName','PublicUrl','EnableSshService','SshPort',
            'SmtpEmailEnabled','SiteBindings','SmtpServer','SmtpPort','SmtpEmailFromAddress') |
            ForEach-Object { "$_=old" }) -join "`r`n"
        function Assert-ExistingSql { param($Plan) }
        function Invoke-SetupSql { param($Plan, $Query) return ,$emptyDatabases }
        function Assert-SetupPortsAvailable { param($Plan, $Names) }
        function Get-SetupTfsConfig { return 'mock-tfsconfig.exe' }
        function Invoke-SetupTfsConfig { param($Tool, $Arguments) }
        function Test-Path { param($LiteralPath) return $false }
        function Get-Content { param($LiteralPath, [switch]$Raw) return $iniTemplate }
        function Set-Content {
            [CmdletBinding()] param($LiteralPath, $Encoding, [Parameter(ValueFromPipeline)]$Value)
            process { $trace.Add("INI:$Value") }
        }
        function Save-SetupState { param($State, $Path) Assert-SetupPlan -Plan $State }
        function New-SelfSignedCertificate {
            param($DnsName, $CertStoreLocation, $NotAfter)
            $trace.Add("Certificate:$DnsName")
            return $fixtureCertificate
        }
        function Get-Item {
            [CmdletBinding()] param($LiteralPath)
            if ($LiteralPath -like 'Cert:\*') { return $fixtureCertificate }
            $key = [pscustomobject]@{}
            $key | Add-Member ScriptMethod GetValueNames { return @('BackConnectionHostNames') }
            $key | Add-Member ScriptMethod GetValueKind { param($Name) return [Microsoft.Win32.RegistryValueKind]::MultiString }
            $key | Add-Member ScriptMethod GetValue { param($Name) return @('existing.lab.example.com') }
            return $key
        }
        function New-ItemProperty {
            [CmdletBinding()] param($LiteralPath, $Name, $PropertyType, $Value, [switch]$Force)
            if ($Name -ne 'BackConnectionHostNames' -or $PropertyType -ne 'MultiString' -or
                ($Value -join ',') -ne 'existing.lab.example.com,devops.lab.example.com') { throw 'Only the exact custom hostname can be added; preserve existing loopback aliases.' }
            $trace.Add("Loopback:$Name")
        }
        function New-Object {
            param($TypeName, $ArgumentList)
            if ($TypeName -eq 'Security.Cryptography.X509Certificates.X509Store') {
                $store = [pscustomobject]@{}
                $store | Add-Member ScriptMethod Open { param($Mode) }
                $store | Add-Member ScriptMethod Add { param($Certificate) }
                $store | Add-Member ScriptMethod Close {}
                return $store
            }
            & $realNewObject -TypeName $TypeName -ArgumentList $ArgumentList
        }
        function Resolve-DnsName {
            [CmdletBinding()] param($Name, $Type, [switch]$DnsOnly)
            [pscustomobject]@{ IPAddress = '192.0.2.10' }
        }
        function Get-NetIPAddress { [CmdletBinding()] param() [pscustomobject]@{ IPAddress = '192.0.2.10' } }
        function Get-NetConnectionProfile { [CmdletBinding()] param() [pscustomobject]@{ NetworkCategory = 'Private' } }
        function Get-NetFirewallRule { param($Name, $ErrorAction) return $null }
        function New-NetFirewallRule {
            param($Name, $DisplayName, $Direction, $Protocol, $LocalPort, $Profile, $RemoteAddress, $Action)
            if ($Profile -notin @('Domain', 'Private') -or $RemoteAddress -ne 'LocalSubnet') { throw 'Firewall must not broaden access to Public or any remote address.' }
            $trace.Add("Firewall:$Profile")
        }
        try {
            foreach ($mode in @('Domain', 'Workgroup')) {
                foreach ($hostChoice in @('Default', 'Custom')) {
                    if ($mode -eq 'Domain' -and $hostChoice -eq 'Custom') { continue }
                    $trace.Clear()
                    $name = if ($mode -eq 'Domain') { 'labserver.ak.com' } elseif ($hostChoice -eq 'Default') { 'labserver' } else { 'devops.lab.example.com' }
                    $plan = [pscustomobject]@{
                        SchemaVersion = 5; JoinMode = $mode; DnsHostName = $name
                        DomainName = $(if ($mode -eq 'Domain') { 'ak.com' } else { 'WORKGROUP' })
                        SetupAccount = $(if ($mode -eq 'Domain') { 'AK\labadmin' } else { 'labserver\labadmin' })
                        ComputerName = 'labserver'; SetupSid = 'S-1-5-21-1-2-3-1000'
                        Version = '2022'; Components = 'Both'; Email = 'Capture'; SqlInstance = 'localhost'
                        StageIndex = 0; Status = 'Pending'; LastError = ''; CertificateThumbprint = ''; RebootAfter = ''
                        PatchSelection = 'Skip'; Ports = [pscustomobject]@{ Https = 8443; Ssh = 2222; Smtp = 2525; MailUi = 5001 }
                    }
                    $reboot = Configure-GuestDevOps -Plan $plan -Work 'C:\Mock' -Path 'C:\Mock\state.json'
                    if ($trace -notcontains "Certificate:$name") { throw 'Certificate SAN must match saved DNS hostname.' }
                    $profile = if ($mode -eq 'Domain') { 'Domain' } else { 'Private' }
                    if (@($trace | Where-Object { $_ -eq "Firewall:$profile" }).Count -ne 2) { throw 'Both HTTPS and SSH must use the saved membership firewall profile.' }
                    $custom = $mode -eq 'Workgroup' -and $hostChoice -eq 'Custom'
                    if ($reboot -ne $custom -or ($trace -contains 'Loopback:BackConnectionHostNames') -ne $custom) { throw 'Custom workgroup alias must use a scoped loopback name and complete a reboot after configuration.' }
                    $ini = ($trace | Where-Object { $_.StartsWith('INI:') }) -replace '^INI:', ''
                    foreach ($line in @("UrlHostNameAlias=$name", "PublicUrl=https://${name}:8443/tfs",
                        "SiteBindings=https:*:8443:${name}:My:$($fixtureCertificate.Thumbprint)")) {
                        if (($ini -split '\r?\n') -notcontains $line) { throw "Hostname not consistently wired to configuration: $line" }
                    }
                }
                }
        }
        finally { $fixtureCertificate.Dispose(); $rsa.Dispose() }
    }
    foreach ($version in @('2020', '2022.1', '2022', '25H2')) {
        foreach ($build in @(14393, 17134, 17763, 18362, 18363, 19041, 19042, 19043, 19044, 19045, 22000, 22631, 20348, 26100, 26200, 30000)) {
            foreach ($productType in @(1, 2, 3)) {
                $allowed = if ($productType -eq 1) {
                    if ($version -eq '2020') { $build -in @(17763, 18362, 18363, 19041, 19042, 19043, 19044, 19045) }
                    else { $build -eq 26100 }
                }
                else { $productType -eq 3 -and $(switch ($version) {
                    '2020' { $build -eq 17763 }
                    '2022' { $build -eq 20348 }
                    '2022.1' { $build -eq 20348 }
                    '25H2' { $build -in @(20348, 26100) }
                }) }
                $rejected = $false
                try { Assert-SetupOperatingSystem -Version $version -ProcessorArchitecture AMD64 -Os ([pscustomobject]@{
                    BuildNumber = [string]$build; ProductType = $productType; OperatingSystemSKU = 48; OSArchitecture = '64-bit'
                }) }
                catch [NotSupportedException] { $rejected = $true }
                if ($allowed -eq $rejected) { throw 'Operating system guard must match the documented version pairing.' }
            }
        }
    }
    foreach ($case in @(
        @{ Version = '2020'; Build = 17134; Sku = 4; Allowed = $true },
        @{ Version = '2020'; Build = 17134; Sku = 27; Allowed = $true },
        @{ Version = '2020'; Build = 17134; Sku = 48; Allowed = $false },
        @{ Version = '2020'; Build = 17763; Sku = 125; Allowed = $true },
        @{ Version = '2020'; Build = 19045; Sku = 101; Allowed = $false },
        @{ Version = '2020'; Build = 19045; Sku = 121; Allowed = $false },
        @{ Version = '2022'; Build = 26100; Sku = 101; Allowed = $false },
        @{ Version = '2022.1'; Build = 26100; Sku = 121; Allowed = $true },
        @{ Version = '25H2'; Build = 26100; Sku = 4; Allowed = $true },
        @{ Version = '25H2'; Build = 26100; Sku = 125; Allowed = $false }
    )) {
        $fixtureOs = [pscustomobject]@{ ProductType = 1; BuildNumber = $case.Build; OperatingSystemSKU = $case.Sku; OSArchitecture = '64-bit' }
        $rejected = $false
        try { Assert-SetupOperatingSystem -Version $case.Version -Os $fixtureOs -ProcessorArchitecture AMD64 }
        catch [NotSupportedException] { $rejected = $true }
        if ($rejected -eq $case.Allowed) { throw "Incorrect client edition/build validation: $($case | Out-String)" }
        foreach ($architecture in @('x86', 'ARM64')) {
            $rejected = $false
            try { Assert-SetupOperatingSystem -Version $case.Version -Os $fixtureOs -ProcessorArchitecture $architecture }
            catch [NotSupportedException] { $rejected = $true }
            if (-not $rejected) { throw 'x86/ARM processes must be rejected.' }
        }
        & {
            foreach ($case in @(
                @{ Version = '25H2'; Type = 1; Build = 26300; Sku = 4; Architecture = 'AMD64'; Allowed = $true },
                @{ Version = '2020'; Type = 1; Build = 26300; Sku = 48; Architecture = 'AMD64'; Allowed = $true },
                @{ Version = '2022'; Type = 1; Build = 19045; Sku = 48; Architecture = 'AMD64'; Allowed = $true },
                @{ Version = '2022'; Type = 3; Build = 17763; Sku = 7; Architecture = 'AMD64'; Allowed = $true },
                @{ Version = '25H2'; Type = 3; Build = 30000; Sku = 7; Architecture = 'AMD64'; Allowed = $true },
                @{ Version = '25H2'; Type = 2; Build = 26300; Sku = 7; Architecture = 'AMD64'; Allowed = $false },
                @{ Version = '25H2'; Type = 1; Build = 26300; Sku = 101; Architecture = 'AMD64'; Allowed = $false },
                @{ Version = '25H2'; Type = 1; Build = 26300; Sku = 125; Architecture = 'AMD64'; Allowed = $false },
                @{ Version = '2020'; Type = 1; Build = 26300; Sku = 121; Architecture = 'AMD64'; Allowed = $false },
                @{ Version = '25H2'; Type = 1; Build = 26300; Sku = 4; Architecture = 'ARM64'; Allowed = $false },
                @{ Version = '25H2'; Type = 1; Build = 26300; Sku = 4; Architecture = 'x86'; Allowed = $false }
            )) {
                $fixtureOs = [pscustomobject]@{ ProductType = $case.Type; BuildNumber = $case.Build; OperatingSystemSKU = $case.Sku; OSArchitecture = '64-bit' }
                $rejected = $false
                $warnings = @()
                try { Assert-SetupOperatingSystem -Version $case.Version -Os $fixtureOs -ProcessorArchitecture $case.Architecture -AllowUnsupportedOs -WarningVariable warnings -WarningAction SilentlyContinue }
                catch [NotSupportedException] { $rejected = $true }
                if ($rejected -eq $case.Allowed) { throw 'Lab override must bypass only OS version/build checks, not hard prerequisites.' }
                if ($case.Allowed -and ($warnings.Count -ne 1 -or [string]$warnings[0] -notlike 'LAB OVERRIDE:*')) {
                    throw 'Bypassing unsupported OS version/build must emit an explicit lab warning.'
                }
            }
        }
    }
    & {
        $fixtureOs = [pscustomobject]@{ ProductType = 1; BuildNumber = 19045 }
        $rejected = $false
        try { Assert-SetupClientOptions -Os $fixtureOs -Plan ([pscustomobject]@{ Email = 'Capture' }) }
        catch { if ($_.Exception.Message -notlike 'SMTP capture uses .NET 10*') { throw }; $rejected = $true }
        if (-not $rejected) { throw 'Windows 10 must not install an unsupported SMTP runtime.' }
        Assert-SetupClientOptions -Os $fixtureOs -Plan ([pscustomobject]@{ Email = 'None' })
        $fixtureOs.BuildNumber = 26100
        Assert-SetupClientOptions -Os $fixtureOs -Plan ([pscustomobject]@{ Email = 'Capture' })
    }
    & {
        $fixtureOs = [pscustomobject]@{ ProductType = 1 }
        $featureState = 'Disabled'
        $restart = $true
        $missing = $false
        $failure = $false
        function Write-SetupProgress { param($Message, $Work) }
        function Get-WindowsOptionalFeature {
            [CmdletBinding()] param([switch]$Online)
            foreach ($name in @('IIS-WebServerRole', 'IIS-DefaultDocument', 'IIS-StaticContent', 'IIS-HttpErrors',
                'IIS-HttpLogging', 'IIS-RequestFiltering', 'IIS-WindowsAuthentication', 'IIS-ASPNET45',
                'IIS-ISAPIExtensions', 'IIS-ISAPIFilter', 'IIS-ManagementConsole')) {
                if ($missing -and $name -eq 'IIS-WindowsAuthentication') { continue }
                [pscustomobject]@{ FeatureName = $name; State = $featureState }
            }
        }
        function Enable-WindowsOptionalFeature {
            [CmdletBinding()] param([switch]$Online, $FeatureName, [switch]$All, [switch]$NoRestart)
            if ($failure) { throw 'Mock feature source failure.' }
            if (-not $All -or -not $NoRestart -or $FeatureName -notcontains 'IIS-WindowsAuthentication') { throw 'Client IIS must enable dependencies without triggering an unsaved reboot.' }
            $script:iisEnabled = $true
            [pscustomobject]@{ RestartNeeded = $restart }
        }
        $script:iisEnabled = $false
        if (-not (Initialize-SetupClientIis -Os $fixtureOs -Work 'C:\Mock') -or -not $script:iisEnabled) { throw 'IIS prerequisites must propagate reboot-required.' }
        $featureState = 'EnablePending'; $script:iisEnabled = $false
        if (-not (Initialize-SetupClientIis -Os $fixtureOs -Work 'C:\Mock') -or $script:iisEnabled) { throw 'Pending IIS changes must reboot without repeating feature installation.' }
        $featureState = 'Enabled'
        if (Initialize-SetupClientIis -Os $fixtureOs -Work 'C:\Mock') { throw 'Enabled IIS prerequisites must be idempotent.' }
        $featureState = 'Disabled'; $restart = $false
        $rejected = $false
        try { Initialize-SetupClientIis -Os $fixtureOs -Work 'C:\Mock' | Out-Null }
        catch { if ($_.Exception.Message -notlike 'Client IIS prerequisites were not enabled*') { throw }; $rejected = $true }
        if (-not $rejected) { throw 'Feature installation success must be verified.' }
        $failure = $true; $rejected = $false
        try { Initialize-SetupClientIis -Os $fixtureOs -Work 'C:\Mock' | Out-Null }
        catch { if ($_.Exception.Message -ne 'Mock feature source failure.') { throw }; $rejected = $true }
        if (-not $rejected) { throw 'Feature source errors must propagate.' }
        $missing = $true; $rejected = $false
        try { Get-SetupClientIisFeatures -Os $fixtureOs | Out-Null }
        catch [NotSupportedException] { $rejected = $true }
        if (-not $rejected) { throw 'Missing Windows Authentication must fail preflight.' }
        function Get-WindowsOptionalFeature { throw 'Server installations must not use client feature APIs.' }
        if (Initialize-SetupClientIis -Os ([pscustomobject]@{ ProductType = 3 }) -Work 'C:\Mock') { throw 'Server prerequisites must retain existing behavior.' }
        Remove-Variable -Name iisEnabled -Scope Script
    }
    & {
        $root = Join-Path $env:TEMP ('AdoServerLabAutoOrchestratorWorkerFilesTest-' + [guid]::NewGuid().ToString('N'))
        $source = Join-Path $root 'source'
        $work = Join-Path $root 'work'
        $fixtureStatePath = Join-Path $root 'state.json'
        $names = @('Resume-Setup.ps1', 'Setup-Releases.psm1', 'Setup-State.psm1')
        New-Item -ItemType Directory -Path $source -Force | Out-Null
        New-Item -ItemType Directory -Path $work -Force | Out-Null
        # PSScriptRoot expands short TEMP paths when the deployed worker imports modules.
        $work = (Get-Item -LiteralPath $work -ErrorAction Stop).FullName
        try {
            Copy-Item -LiteralPath (Join-Path $Folder 'Resume-Setup.ps1') -Destination (Join-Path $source 'Resume-Setup.ps1')
            $rejected = $false
            try { Copy-SetupWorkerFiles -SourceFolder $source -Work $work }
            catch { if ($_.Exception.Message -notlike 'Required setup file is missing:*') { throw }; $rejected = $true }
            if (-not $rejected -or @(Get-ChildItem -LiteralPath $work -File).Count) {
                throw 'Missing release helper must fail before deploying any worker files.'
            }
            Copy-Item -LiteralPath (Join-Path $Folder 'Setup-Releases.psm1') -Destination (Join-Path $source 'Setup-Releases.psm1')
            $rejected = $false
            try { Copy-SetupWorkerFiles -SourceFolder $source -Work $work }
            catch { if ($_.Exception.Message -notlike 'Required setup file is missing:*Setup-State.psm1') { throw }; $rejected = $true }
            if (-not $rejected -or @(Get-ChildItem -LiteralPath $work -File).Count) {
                throw 'Missing state module must fail before deploying any worker files.'
            }
            Copy-Item -LiteralPath (Join-Path $Folder 'Setup-State.psm1') -Destination (Join-Path $source 'Setup-State.psm1')
            Copy-SetupWorkerFiles -SourceFolder $source -Work $work
            foreach ($name in $names) {
                if ((Get-FileHash -LiteralPath (Join-Path $source $name)).Hash -ne (Get-FileHash -LiteralPath (Join-Path $work $name)).Hash) {
                    throw 'Deployment must copy the matching helper and worker unchanged.'
                }
            }
            if (@(Get-ChildItem -LiteralPath $work -File).Count -ne 3) { throw 'Automatic resume must deploy both modules, without depending on launcher, monitor or test files.' }
            Copy-SetupWorkerFiles -SourceFolder $work -Work $work
            & {
                . (Join-Path $work 'Resume-Setup.ps1') -StatePath $fixtureStatePath
                if ((Get-SetupRelease -Version '2020').SqlYear -ne 2019) { throw 'Deployed worker must load its deployed release helper.' }
                if ((Get-Command Get-SetupRelease).Module.Path -ne (Join-Path $work 'Setup-Releases.psm1')) {
                    throw 'Deployed worker must import its own module, not reuse a cached source module.'
                }
                if ((Get-Command Assert-SetupPlan).Module.Path -ne (Join-Path $work 'Setup-State.psm1')) {
                    throw 'Deployed worker must import its own state module, not reuse a cached source module.'
                }
                foreach ($schema in @(1, 2, 3, 4, 5, 6)) {
                    $state = [pscustomobject]@{
                        SchemaVersion = $schema; Version = '2022'; Components = 'Both'; DomainName = 'ak.com'
                        ComputerName = 'labserver'; SqlInstance = 'localhost'; Email = 'None'
                        SetupAccount = 'AK\labadmin'; SetupSid = 'S-1-5-21-1-2-3-1000'
                        StageIndex = 0; Status = 'Failed'; LastError = 'Offline state fixture'
                        CertificateThumbprint = ''; RebootAfter = ''; PatchSelection = '12'; Ports = $null
                        JoinMode = 'Domain'; DnsHostName = 'labserver.ak.com'
                        AllowUnsupportedOs = $false
                    }
                    Save-SetupState -State $state -Path $fixtureStatePath
                    $restored = Read-SetupState -Path $fixtureStatePath
                    if ($restored.SchemaVersion -ne 6 -or (Get-SetupAllowUnsupportedOs -Plan $restored) -or $restored.JoinMode -ne 'Domain' -or $restored.DnsHostName -ne 'labserver.ak.com' -or $restored.StageIndex -ne 0 -or
                        $restored.PatchSelection -ne '12' -or $restored.Status -ne 'Failed' -or
                        $restored.LastError -ne 'Offline state fixture') {
                        throw 'State module must read, migrate and preserve actual saved JSON from every supported schema.'
                    }
                    Save-SetupState -State $restored -Path $fixtureStatePath
                    if ((Get-Content -LiteralPath $fixtureStatePath -Raw | ConvertFrom-Json).SchemaVersion -ne 6 -or
                        (Test-Path -LiteralPath "$fixtureStatePath.tmp")) {
                        throw 'Migrated state must persist without leaving an unfinished temporary file.'
                    }
                }
                $restored.AllowUnsupportedOs = $true
                Save-SetupState -State $restored -Path $fixtureStatePath
                if (-not (Get-SetupAllowUnsupportedOs -Plan (Read-SetupState -Path $fixtureStatePath))) { throw 'Explicit OS acknowledgement must survive a JSON round trip.' }
                $restored.AllowUnsupportedOs = 'true'
                $rejected = $false
                try { Assert-SetupPlan -Plan $restored }
                catch { if ($_.Exception.Message -ne 'Saved AllowUnsupportedOs must be a Boolean acknowledgement.') { throw }; $rejected = $true }
                if (-not $rejected) { throw 'String values must not silently enable an OS override.' }
                $restored.SchemaVersion = 5; $restored.AllowUnsupportedOs = $true
                Update-SetupStateSchema -State $restored
                if (Get-SetupAllowUnsupportedOs -Plan $restored) { throw 'Legacy schema migration must never grant an OS override.' }
            }
        }
        finally {
            foreach ($file in @($fixtureStatePath, "$fixtureStatePath.tmp")) {
                if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }
            }
            foreach ($directory in @($source, $work)) {
                foreach ($name in $names) {
                    $file = Join-Path $directory $name
                    if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }
                }
                Remove-Item -LiteralPath $directory -Force
            }
            Remove-Item -LiteralPath $root -Force
        }
    }
    & {
        $testPassword = New-Object Security.SecureString
        $testPassword.AppendChar('x')
        function Read-Host {
            param([string]$Prompt, [switch]$AsSecureString)
            if (-not $AsSecureString -or $Prompt -ne 'Password for AK\labadmin') {
                throw 'Credential entry must be an explicit masked console prompt for the setup account.'
            }
            $script:credentialPromptTestCalled = $true
            return $testPassword
        }
        $script:credentialPromptTestCalled = $false
        $credential = Read-SetupCredential -AccountName 'AK\labadmin'
        if (-not $script:credentialPromptTestCalled -or $credential.UserName -ne 'AK\labadmin' -or
            $credential.Password -ne $testPassword) { throw 'Console credential prompt must preserve the account and SecureString.' }
        $testPassword = New-Object Security.SecureString
        $rejected = $false
        try { Read-SetupCredential -AccountName 'AK\labadmin' | Out-Null }
        catch { if ($_.Exception.Message -notlike 'No password was entered.*') { throw }; $rejected = $true }
        if (-not $rejected) { throw 'Empty console passwords must be rejected before task registration.' }
        $testPassword = $null
        $rejected = $false
        try { Read-SetupCredential -AccountName 'AK\labadmin' | Out-Null }
        catch { if ($_.Exception.Message -notlike 'No password was entered.*') { throw }; $rejected = $true }
        if (-not $rejected) { throw 'Cancelled credential input must be rejected before task registration.' }
        Remove-Variable -Name credentialPromptTestCalled -Scope Script
    }
    $databaseDetails = New-Object Data.DataTable
    $databaseDetails.Columns.Add('name', [string]) | Out-Null
    $databaseDetails.Columns.Add('state_desc', [string]) | Out-Null
    foreach ($prefix in @('AzureDevOps', 'Tfs')) {
        $databaseDetails.Clear()
        $databaseDetails.Rows.Add("${prefix}_Configuration", 'ONLINE') | Out-Null
        $databaseDetails.Rows.Add("${prefix}_DefaultCollection", 'ONLINE') | Out-Null
        Assert-GuestDevOpsDatabases -Databases $databaseDetails
        $databaseDetails.Rows[1].state_desc = 'OFFLINE'
        $rejected = $false
        try { Assert-GuestDevOpsDatabases -Databases $databaseDetails }
        catch { if ($_.Exception.Message -notlike 'Expected exactly one matching*') { throw }; $rejected = $true }
        if (-not $rejected) { throw 'Offline DevOps databases must be rejected.' }
    }
    $databaseDetails.Rows[1].state_desc = 'ONLINE'
    $databaseDetails.Rows[1].name = 'AzureDevOps_DefaultCollection'
    $rejected = $false
    try { Assert-GuestDevOpsDatabases -Databases $databaseDetails }
    catch { if ($_.Exception.Message -notlike 'Expected exactly one matching*') { throw }; $rejected = $true }
    if (-not $rejected) { throw 'Mixed DevOps database prefixes must be rejected.' }
    foreach ($file in Get-ChildItem -LiteralPath $Folder -File | Where-Object { $_.Extension -in @('.ps1', '.psm1') }) {
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
        if ($errors.Count) { throw "$($file.Name): $($errors.Message -join '; ')" }
        $commands = $ast.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $true)
        foreach ($command in $commands) {
            if ($command.GetCommandName() -in @('az', 'Initialize-Disk', 'New-Partition', 'Format-Volume', 'Add-Computer', 'Install-ADDSForest')) {
                throw 'Guest-only scripts must not provision Azure, create/join AD, or format data disks.'
            }
            if ($file.Name -eq 'Test-GuestSetup.ps1') {
                $syntaxLoops = @($ast.FindAll({
                    param($node)
                    $node -is [Management.Automation.Language.ForEachStatementAst] -and
                    $node.Condition.Extent.Text.Contains('Get-ChildItem -LiteralPath $Folder')
                }, $true))
                $nestedPatchTests = @($syntaxLoops | ForEach-Object {
                    $_.Body.Statements | Where-Object { $_.Extent.Text.StartsWith('& {') -and $_.Extent.Text.Contains('AdoServerLabAutoOrchestratorPatchTest-') }
                })
                if ($syntaxLoops.Count -ne 1 -or $nestedPatchTests.Count) {
                    throw 'Patch tests must run once, outside the per-file syntax-check loop.'
                }
            }
        }
    }
    & {
        $patchWork = Join-Path $env:TEMP ('AdoServerLabAutoOrchestratorPatchTest-' + [guid]::NewGuid().ToString('N'))
        $marker = Join-Path $patchWork 'patch.sha256'
        New-Item -ItemType Directory -Path $patchWork | Out-Null
        $patchTrace = New-Object 'System.Collections.Generic.List[string]'
        function Write-SetupProgress { param($Message, $Work) }
        function Get-SetupDownload {
            param($Url, $Path, $Hash, [switch]$MicrosoftSigned)
            if ($Url -ne $expectedPatch.Url -or $Hash -ne $expectedPatch.Hash -or
                $Path -ne (Join-Path $patchWork 'DevOpsPatch.exe') -or -not $MicrosoftSigned) {
                throw 'Patch download must use the selected version-specific URL/hash and signature validation.'
            }
            $patchTrace.Add('Download')
        }
        function Invoke-SetupInstaller {
            param($Path, $Arguments)
            if ($Arguments -ne 'Patch -force -nowait') { throw 'Patch tool switches must remain noninteractive.' }
            $patchTrace.Add('Install')
            return $true
        }
        try {
            foreach ($version in @('2020', '2022.1', '2022', '25H2')) {
                $catalog = @(Get-SetupPatchCatalog -Version $version)
                $latest = (Get-SetupRelease -Version $version).LatestPatchNumber
                if ($catalog.Count -ne [int]$latest -or ($catalog.Number | Select-Object -Unique).Count -ne $catalog.Count) {
                    throw 'Patch catalog must contain every released number exactly once.'
                }
                if ((Resolve-SetupPatchChoice -Version $version -Choice 'Latest') -ne $latest -or
                    (Resolve-SetupPatchChoice -Version $version -Choice 'Skip') -ne 'Skip') {
                    throw 'Latest/Skip selection resolution failed.'
                }
                foreach ($invalid in @('', '0', '01', '-1', 'Patch 1', ([string]([int]$latest + 1)))) {
                    $rejected = $false
                    try { Resolve-SetupPatchChoice -Version $version -Choice $invalid | Out-Null }
                    catch { if ($_.Exception.Message -notlike 'Invalid patch*') { throw }; $rejected = $true }
                    if (-not $rejected) { throw 'Invalid version-specific patch must be rejected.' }
                }
                foreach ($components in @('Both', 'DevOpsOnly', 'SqlOnly')) {
                    $plan = [pscustomobject]@{
                        SchemaVersion = 3; Version = $version; Components = $components; DomainName = 'ak.com'
                        ComputerName = 'labserver'; SqlInstance = 'localhost'; Email = 'None'
                        SetupAccount = 'AK\labadmin'; SetupSid = 'S-1-5-21-1-2-3-1000'
                        StageIndex = 0; Status = 'Pending'; PatchSelection = 'Skip'
                        LastError = ''; CertificateThumbprint = ''; RebootAfter = ''
                    }
                    Assert-SetupPlan -Plan $plan
                    Assert-SetupPlan -Plan ($plan | ConvertTo-Json | ConvertFrom-Json)
                    if (@(Get-SetupSteps -Plan $plan) -contains 'Patch') { throw 'Skip must omit patch execution.' }
                    Assert-SelectedPatchCompletion -Plan $plan -Work $patchWork
                    if ($patchTrace.Count -or (Test-Path -LiteralPath $marker)) { throw 'Skip must not download, install or require a marker.' }
                }
                $plan.Components = 'Both'
                foreach ($expectedPatch in $catalog) {
                    if (-not $expectedPatch.Installable) {
                        $rejected = $false
                        try { Resolve-SetupPatchChoice -Version $version -Choice $expectedPatch.Number | Out-Null }
                        catch { if ($_.Exception.Message -notlike '*requires manual pipeline task uploads*') { throw }; $rejected = $true }
                        if (-not $rejected -or $version -ne '2020' -or $expectedPatch.Number -ne '10') {
                            throw 'Task-only Patch 10 must be listed but cannot be selected as a server installer.'
                        }
                        continue
                    }
                    $plan.PatchSelection = $expectedPatch.Number
                    Assert-SetupPlan -Plan $plan
                    if ($expectedPatch.Hash -notmatch '^[A-F0-9]{64}$' -or $expectedPatch.Url -notmatch '^https://aka.ms/(?:devops|azdev)') {
                        throw 'Every patch requires a valid pinned SHA256 and official HTTPS URL.'
                    }
                    if (@(Get-SetupSteps -Plan $plan) -notcontains 'Patch' -or
                        (Get-SelectedSetupPatch -Plan $plan).Hash -ne $expectedPatch.Hash) {
                        throw 'Selected patch must drive both stage inclusion and installer metadata.'
                    }
                    if (-not (Install-GuestPatch -Plan $plan -Work $patchWork)) { throw 'Patch installer must propagate reboot-required.' }
                    Assert-SelectedPatchCompletion -Plan $plan -Work $patchWork
                    if (Install-GuestPatch -Plan $plan -Work $patchWork) { throw 'Completed patch must not request another reboot.' }
                    if (($patchTrace -join ',') -ne 'Download,Install') { throw 'Matching marker must prevent repeat patch installation.' }
                    'incorrect' | Set-Content -LiteralPath $marker -Encoding ASCII
                    $rejected = $false
                    try { Assert-SelectedPatchCompletion -Plan $plan -Work $patchWork }
                    catch { if ($_.Exception.Message -notlike 'Selected * did not complete.') { throw }; $rejected = $true }
                    if (-not $rejected) { throw 'Selected patch verification must reject a different hash.' }
                    $rejected = $false
                    try { Install-GuestPatch -Plan $plan -Work $patchWork | Out-Null }
                    catch { if ($_.Exception.Message -notlike 'A different patch completion marker*') { throw }; $rejected = $true }
                    if (-not $rejected -or $patchTrace.Count -ne 2) { throw 'Patch switching must fail without running another installer.' }
                    Remove-Item -LiteralPath $marker -Force
                    $patchTrace.Clear()
                }
            }
        }
        finally {
            if (Test-Path -LiteralPath $marker) { Remove-Item -LiteralPath $marker -Force }
            Remove-Item -LiteralPath $patchWork -Force
        }
    }
    foreach ($version in @('2020', '2022.1', '2022', '25H2')) {
        foreach ($components in @('Both', 'SqlOnly', 'DevOpsOnly')) {
            foreach ($email in @('None', 'Capture')) {
                if ($components -eq 'SqlOnly' -and $email -eq 'Capture') { continue }
                $plan = [pscustomobject]@{
                    SchemaVersion = 2; Version = $version; Components = $components; DomainName = 'ak.com'
                    ComputerName = 'labserver'; SqlInstance = 'localhost'; Email = $email
                    SetupAccount = 'AK\labadmin'; SetupSid = 'S-1-5-21-1-2-3-1000'
                    StageIndex = 0; Status = 'Pending'; LastError = ''; CertificateThumbprint = ''; RebootAfter = ''
                }
                Assert-SetupPlan -Plan $plan
                Assert-SetupPlan -Plan ($plan | ConvertTo-Json | ConvertFrom-Json)
                $steps = @(Get-SetupSteps -Plan $plan)
                if ($steps[-1] -ne 'Verify') { throw 'All plans must verify before completion.' }
                if ($components -eq 'DevOpsOnly' -and $steps -contains 'Sql') { throw 'DevOpsOnly must not install SQL.' }
                if ($components -eq 'SqlOnly' -and ($steps -contains 'DevOps' -or $steps -contains 'Configure')) { throw 'SqlOnly must not configure DevOps.' }
                if (($steps -contains 'Smtp') -ne ($email -eq 'Capture')) { throw 'SMTP step must match selection.' }
                if (($steps -contains 'Ssms') -ne ($components -ne 'DevOpsOnly')) { throw 'SQL-install selections must include SSMS.' }
                $legacy = $plan | ConvertTo-Json | ConvertFrom-Json
                $legacy.SchemaVersion = 1
                $legacySteps = @(Get-SetupSteps -Plan $legacy)
                for ($legacyIndex = 0; $legacyIndex -le $legacySteps.Count; $legacyIndex++) {
                    $legacy.StageIndex = $legacyIndex
                    $legacy.SchemaVersion = 1
                    Update-SetupStateSchema -State $legacy
                    $expectedIndex = if ($components -ne 'DevOpsOnly' -and $legacyIndex -eq $legacySteps.Count) { $legacyIndex + 1 } else { $legacyIndex }
                    if ($legacy.StageIndex -ne $expectedIndex) { throw 'Legacy stage migration must not skip or repeat SQL/DevOps configuration.' }
                    if ($legacy.SchemaVersion -ne 6 -or (Get-SetupAllowUnsupportedOs -Plan $legacy) -or $legacy.JoinMode -ne 'Domain' -or $legacy.DnsHostName -ne 'labserver.ak.com' -or $null -ne $legacy.Ports -or $legacy.PatchSelection -ne
                        $(if ($components -eq 'SqlOnly') { 'Skip' } elseif ($version -eq '2020') { '19' } elseif ($version -eq '2022.1') { '4' } elseif ($version -eq '2022') { '12' } else { '9' })) {
                        throw 'Legacy migration must retain the original pinned patch intent.'
                    }
                    if ($legacyIndex -eq $legacySteps.Count -and $legacy.StageIndex -ne @(Get-SetupSteps -Plan $legacy).Count) {
                        throw 'Completed legacy plans must remain completed.'
                    }
                }
                $schemaTwo = $plan | ConvertTo-Json | ConvertFrom-Json
                for ($savedIndex = 0; $savedIndex -le $steps.Count; $savedIndex++) {
                    $schemaTwo.SchemaVersion = 2; $schemaTwo.StageIndex = $savedIndex
                    Update-SetupStateSchema -State $schemaTwo
                    if ($schemaTwo.StageIndex -ne $savedIndex -or (@(Get-SetupSteps -Plan $schemaTwo) -join ',') -ne ($steps -join ',')) {
                        throw 'Schema-2 migration must preserve every saved stage including Patch.'
                    }
                }
                for ($index = 0; $index -lt $steps.Count; $index++) {
                    Complete-SetupStage -State $plan -RebootRequired ($index -eq 0)
                    Assert-SetupPlan -Plan $plan
                    if ($plan.StageIndex -ne ($index + 1)) { throw 'Resume index did not advance exactly once.' }
                    if ($index -eq 0 -and $plan.Status -ne 'RebootPending') { throw 'Reboot must preserve the next stage.' }
                }
                $plan.Status = 'Completed'
                Assert-SetupPlan -Plan $plan
                $plan.SqlInstance = 'localhost\SQLTEST'
                $plan.Components = 'DevOpsOnly'; $plan.StageIndex = 0; $plan.Status = 'Pending'
                Assert-SetupPlan -Plan $plan
                foreach ($invalid in @('remote\SQL', 'localhost;Password=x', 'localhost" /Q')) {
                    $plan.SqlInstance = $invalid
                    $rejected = $false
                    try { Assert-SetupPlan -Plan $plan }
                    catch { if ($_.Exception.Message -notlike 'SQL must be a local*') { throw }; $rejected = $true }
                    if (-not $rejected) { throw 'Invalid SQL instance was accepted.' }
                }
            }
        }
        $release = Get-SetupRelease -Version $version
        $expected = switch ($version) { '2020' { 15 }; '2022.1' { 16 }; '2022' { 16 }; '25H2' { 17 } }
        if ($release.SqlMajor -ne $expected) { throw 'SQL version pairing failed.' }
        $expectedApi = if ($version -eq '2020') { '6.0' } else { '7.0' }
        if ($release.ApiVersion -ne $expectedApi) { throw 'DevOps API verification must match the selected release.' }
        $details = New-Object Data.DataTable
        foreach ($column in @('Major', 'FullText', 'SysAdmin')) { $details.Columns.Add($column, [int]) | Out-Null }
        foreach ($column in @('Collation', 'Edition')) { $details.Columns.Add($column, [string]) | Out-Null }
        $details.Rows.Add($expected, 1, 1, 'SQL_Latin1_General_CP1_CI_AS', 'Enterprise Developer Edition') | Out-Null
        Assert-SqlDetails -Details $details -Release $release
        foreach ($invalid in @(
            @{ Field = 'Major'; Value = (33 - $expected) },
            @{ Field = 'FullText'; Value = 0 },
            @{ Field = 'SysAdmin'; Value = 0 },
            @{ Field = 'Collation'; Value = 'Latin1_General_CS_AS' }
        )) {
            $old = $details.Rows[0][$invalid.Field]
            $details.Rows[0][$invalid.Field] = $invalid.Value
            $rejected = $false
            try { Assert-SqlDetails -Details $details -Release $release }
            catch { if ($_.Exception.Message -notlike 'Require SQL*') { throw }; $rejected = $true }
            if (-not $rejected) { throw 'Incompatible SQL details were accepted.' }
            $details.Rows[0][$invalid.Field] = $old
        }
    }
    $updated = Set-SetupIniValue -Text "SqlInstance=old`r`n;SqlInstance=comment" -Names @('SqlInstance') -Value 'localhost\SQL$TEST'
    if (-not $updated.Contains('SqlInstance=localhost\SQL$TEST') -or -not $updated.Contains(';SqlInstance=comment')) { throw 'INI literal replacement failed.' }
    & {
        $busy = @(443, 8443, 22, 2222, 25, 5000)
        $probed = New-Object 'System.Collections.Generic.List[int]'
        function Get-SetupPortProbe {
            param($Port, $AllowedProcessPath)
            $probed.Add($Port)
            return [pscustomobject]@{ Available = $busy -notcontains $Port; Reason = 'Mock port conflict.' }
        }
        foreach ($version in @('2020', '2022.1', '2022', '25H2')) {
            $plan = [pscustomobject]@{
                SchemaVersion = 4; Ports = $null; Version = $version; Components = 'Both'; DomainName = 'ak.com'
                ComputerName = 'labserver'; SqlInstance = 'localhost'; Email = 'Capture'; PatchSelection = 'Skip'
                SetupAccount = 'AK\labadmin'; SetupSid = 'S-1-5-21-1-2-3-1000'
                StageIndex = 0; Status = 'Pending'; LastError = ''; CertificateThumbprint = ''; RebootAfter = ''
            }
            Initialize-SetupPorts -Plan $plan
            Assert-SetupPlan -Plan $plan
            $roundTrip = $plan | ConvertTo-Json -Depth 5 | ConvertFrom-Json
            Assert-SetupPlan -Plan $roundTrip
            if ($plan.Ports.Https -ne 8444 -or $plan.Ports.Ssh -ne 2223 -or
                $plan.Ports.Smtp -ne 2525 -or $plan.Ports.MailUi -ne 5001) {
                throw 'First setup must skip conflicting ports and persist free alternate ports.'
            }
            $count = $probed.Count
            Initialize-SetupPorts -Plan $roundTrip
            if ($probed.Count -ne $count -or (Get-SetupDevOpsUrl -Plan $roundTrip) -ne 'https://labserver.ak.com:8444/tfs') {
                throw 'Resume must preserve saved ports, and URLs must include alternate HTTPS ports.'
            }
            $text = (@('InstallSqlExpress','SqlInstance','StartTrial','ConfigureSearch','CreateInitialCollection',
                'CollectionName','UrlHostNameAlias','WebSiteVDirName','PublicUrl','EnableSshService','SshPort',
                'SmtpEmailEnabled','SiteBindings','SmtpServer','SmtpPort','SmtpEmailFromAddress') |
                ForEach-Object { "$_=old" }) -join "`r`n"
            $ini = Get-SetupDevOpsIniText -Text $text -Plan $plan -Thumbprint 'MOCK'
            foreach ($line in @('PublicUrl=https://labserver.ak.com:8444/tfs', 'SshPort=2223', 'EnableSshService=True',
                'SmtpPort=2525', 'SiteBindings=https:*:8444:labserver.ak.com:My:MOCK')) {
                if (($ini -split '\r?\n') -notcontains $line) { throw "Alternate port was not wired to INI: $line" }
            }
            $probed.Clear()
            $plan.Ports = $null
            $plan.StageIndex = [array]::IndexOf(@(Get-SetupSteps -Plan $plan), 'Configure')
            Initialize-SetupPorts -Plan $plan
            if ($probed -contains 25 -or $probed -contains 5000 -or $plan.Ports.Smtp -ne 25 -or $plan.Ports.MailUi -ne 5000) {
                throw 'Legacy resume at Configure must preserve already-configured SMTP ports.'
            }
            $probed.Clear()
            $plan.Ports = $null
            $plan.StageIndex++
            Initialize-SetupPorts -Plan $plan
            if ($probed.Count -or $plan.Ports.Https -ne 443 -or $plan.Ports.Ssh -ne 2222) {
                throw 'Legacy resume after Configure must not change deployed endpoint ports.'
            }
            $busy += 8444
            $plan.Ports.Https = 8444
            $rejected = $false
            try { Assert-SetupPortsAvailable -Plan $plan -Names @('Https') }
            catch { if ($_.Exception.Message -notlike 'Saved Https TCP port 8444 is now unavailable*') { throw }; $rejected = $true }
            if (-not $rejected -or $plan.Ports.Https -ne 8444) { throw 'Late conflicts must fail without changing saved ports.' }
            $busy = @(443, 8443, 22, 2222, 25, 5000)
            $probed.Clear()
            $plan.Components = 'SqlOnly'; $plan.Email = 'None'; $plan.Ports = $null; $plan.StageIndex = 0
            Initialize-SetupPorts -Plan $plan
            if ($probed.Count) { throw 'SqlOnly uses local SQL protocols and must not reserve DevOps/SMTP TCP ports.' }
            $plan.Components = 'Both'; $plan.Ports = $null
            Initialize-SetupPorts -Plan $plan
            if ($probed -contains 25 -or $probed -contains 5000) { throw 'Email None must not reserve capture ports.' }
            foreach ($invalid in @(0, 65536, '443', 2222)) {
                $plan.Ports.Https = $invalid
                $plan.Ports.Ssh = 2222
                $rejected = $false
                try { Assert-SetupPlan -Plan $plan }
                catch { if ($_.Exception.Message -notlike 'Saved ports must be distinct*') { throw }; $rejected = $true }
                if (-not $rejected) { throw 'Invalid or duplicate saved ports must be rejected.' }
            }
        }
        $plan.Ports = $null; $plan.StageIndex = 0
        $busy = @()
        Initialize-SetupPorts -Plan $plan
        if ($plan.Ports.Ssh -ne 22) { throw 'Fresh setup must prefer standard SSH port 22 when available.' }
        $plan.Ports = $null
        $busy = @(443) + @(8443..8452)
        $rejected = $false
        try { Initialize-SetupPorts -Plan $plan }
        catch { if ($_.Exception.Message -notlike 'No free Https TCP port*') { throw }; $rejected = $true }
        if (-not $rejected -or $null -ne $plan.Ports) { throw 'Exhausted candidates must fail without saving a partial port selection.' }
    }
    & {
        function Get-NetTCPConnection { return @() }
        $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
        $listener.Start()
        try {
            $port = $listener.LocalEndpoint.Port
            $probe = Get-SetupPortProbe -Port $port
            if ($probe.Available) { throw 'Exclusive bind probe must detect an occupied real TCP port.' }
        }
        finally { $listener.Stop() }
        if (-not (Get-SetupPortProbe -Port $port).Available) { throw 'Port probe must release its own sockets.' }
    }
    & {
        $sshMessages = New-Object 'System.Collections.Generic.List[string]'
        $sshSleeps = New-Object 'System.Collections.Generic.List[int]'
        $sshPlan = [pscustomobject]@{ SchemaVersion = 4; Ports = [pscustomobject]@{ Ssh = 2223 } }
        function Get-Date { return $script:sshTestNow }
        function Start-Sleep {
            param([int]$Milliseconds)
            $sshSleeps.Add($Milliseconds)
            $script:sshTestNow = $script:sshTestNow.AddMilliseconds($Milliseconds)
        }
        function Write-SetupProgress {
            param($Work, $Message)
            if ($Work -ne 'C:\Mock') { throw 'SSH test logging must not use a live setup folder.' }
            $sshMessages.Add($Message)
        }
        function Get-NetTCPConnection {
            param($ErrorAction)
            if ($ErrorAction -ne 'Stop') { throw 'SSH query errors must propagate, not appear as readiness delays.' }
            $script:sshTestPolls++
            if ($script:sshTestPolls -eq 1) { $script:sshTestNow = $script:sshTestNow.AddMilliseconds($sshInitialQueryDelay) }
            if ($sshQueryFailure) { throw 'Mock SSH listener query failure.' }
            if ($script:sshTestPolls -ge $sshReadyAt) {
                return [pscustomobject]@{ State = 'Listen'; LocalPort = 2223 }
            }
            return @(
                [pscustomobject]@{ State = 'Listen'; LocalPort = 22 },
                [pscustomobject]@{ State = 'Established'; LocalPort = 2223 }
            )
        }
        try {
            foreach ($sshReadyAt in @(1, 3)) {
                $script:sshTestNow = [datetime]'2026-11-06T04:00:00Z'
                $script:sshTestPolls = 0; $sshQueryFailure = $false
                $sshInitialQueryDelay = 0
                $sshMessages.Clear(); $sshSleeps.Clear()
                Wait-GuestSsh -Plan $sshPlan -Work 'C:\Mock'
                if ($script:sshTestPolls -ne $sshReadyAt -or $sshSleeps.Count -ne ($sshReadyAt - 1) -or
                    @($sshSleeps | Where-Object { $_ -ne 15000 }).Count -or
                    $sshMessages[-1] -ne 'DevOps Git SSH is listening on TCP port 2223.') {
                    throw 'SSH verification must accept immediate/delayed readiness only on the saved listening port.'
                }
            }
            $script:sshTestNow = [datetime]'2026-11-06T04:00:00Z'
            $script:sshTestPolls = 0; $sshReadyAt = [int]::MaxValue
            $sshMessages.Clear(); $sshSleeps.Clear()
            $rejected = $false
            try { Wait-GuestSsh -Plan $sshPlan -Work 'C:\Mock' }
            catch {
                if ($_.Exception.Message -notlike 'DevOps Git SSH did not start listening on TCP port 2223 within 10 minutes.*') { throw }
                $rejected = $true
            }
            if (-not $rejected -or $script:sshTestPolls -ne 41 -or $sshSleeps.Count -ne 40 -or
                ($sshSleeps | Measure-Object -Sum).Sum -ne 600000) {
                throw 'SSH readiness must fail explicitly after a bounded ten-minute wait.'
            }
            $script:sshTestNow = [datetime]'2026-11-06T04:00:00Z'
            $script:sshTestPolls = 0; $sshInitialQueryDelay = 590000
            $sshSleeps.Clear()
            $rejected = $false
            try { Wait-GuestSsh -Plan $sshPlan -Work 'C:\Mock' }
            catch {
                if ($_.Exception.Message -notlike 'DevOps Git SSH did not start listening on TCP port 2223 within 10 minutes.*') { throw }
                $rejected = $true
            }
            if (-not $rejected -or $sshSleeps.Count -ne 1 -or $sshSleeps[0] -ne 10000 -or $script:sshTestPolls -ne 2) {
                throw 'The final SSH retry sleep must be capped to the remaining deadline.'
            }
            $script:sshTestNow = [datetime]'2026-11-06T04:00:00Z'
            $script:sshTestPolls = 0; $sshQueryFailure = $true
            $sshInitialQueryDelay = 0
            $sshSleeps.Clear()
            $rejected = $false
            try { Wait-GuestSsh -Plan $sshPlan -Work 'C:\Mock' }
            catch { if ($_.Exception.Message -ne 'Mock SSH listener query failure.') { throw }; $rejected = $true }
            if (-not $rejected -or $sshSleeps.Count) { throw 'SSH query failures must surface immediately, without silent retry.' }
        }
        finally { Remove-Variable -Name sshTestNow,sshTestPolls -Scope Script }
    }
    & {
        $httpCalls = New-Object 'System.Collections.Generic.List[string]'
        $sshCalls = New-Object 'System.Collections.Generic.List[int]'
        $databases = [Data.DataTable]::new()
        $databases.Columns.Add('name', [string]) | Out-Null
        $databases.Columns.Add('state_desc', [string]) | Out-Null
        $databases.Rows.Add('Tfs_Configuration', 'ONLINE') | Out-Null
        $databases.Rows.Add('Tfs_DefaultCollection', 'ONLINE') | Out-Null
        function Assert-ExistingSql { param($Plan) }
        function Assert-GuestSsms {}
        function Assert-SelectedPatchCompletion { param($Plan, $Work) }
        function Wait-GuestSsh { param($Plan, $Work) $sshCalls.Add((Get-SetupPorts -Plan $Plan).Ssh) }
        function Invoke-SetupSql { param($Plan, $Query) return ,$databases }
        function Wait-GuestHttp {
            param($Url, [switch]$Json)
            $httpCalls.Add($Url)
            if ($Json) { return [pscustomobject]@{ count = 0; value = @() } }
            return [pscustomobject]@{ StatusCode = 200 }
        }
        function New-Object {
            param($TypeName, $ArgumentList)
            if ($TypeName -eq 'Net.Mail.SmtpClient') {
                if ($ArgumentList[0] -ne 'localhost' -or $ArgumentList[1] -ne 2525) {
                    throw 'Final SMTP verification must connect to the saved capture port.'
                }
                $client = [pscustomobject]@{}
                $client | Add-Member -MemberType ScriptMethod -Name Send -Value { param($Message) } 
                $client | Add-Member -MemberType ScriptMethod -Name Dispose -Value {}
                return $client
            }
            if ($TypeName -eq 'Net.Mail.MailMessage') {
                $message = [pscustomobject]@{ Subject = ''; Body = '' }
                $message | Add-Member -MemberType ScriptMethod -Name Dispose -Value {}
                return $message
            }
            throw "Unexpected real object creation during port verification test: $TypeName"
        }
        foreach ($version in @('2020', '2022.1', '2022', '25H2')) {
            $httpCalls.Clear()
            $sshCalls.Clear()
            Test-GuestInstallation -Work 'C:\Mock' -Plan ([pscustomobject]@{
                SchemaVersion = 4; Version = $version; Components = 'Both'; ComputerName = 'labserver'; DomainName = 'ak.com'; Email = 'Capture'
                Ports = [pscustomobject]@{ Https = 8444; Ssh = 2223; Smtp = 2525; MailUi = 5001 }
            })
            $expectedApi = if ($version -eq '2020') { '6.0' } else { '7.0' }
            if (($httpCalls -join ',') -ne "https://labserver.ak.com:8444/tfs/DefaultCollection/_apis/projects?api-version=$expectedApi,http://localhost:5001") {
                throw 'Final DevOps API and mail UI verification must use saved ports and release-specific API versions.'
            }
            if ($sshCalls.Count -ne 1 -or $sshCalls[0] -ne 2223) { throw 'Every DevOps release must wait for SSH on its saved port during final verification.' }
        }
        $sshCalls.Clear()
        Test-GuestInstallation -Work 'C:\Mock' -Plan ([pscustomobject]@{ Components = 'SqlOnly' })
        if ($sshCalls.Count) { throw 'SqlOnly must not wait for a DevOps SSH service.' }
    }
    & {
        $work = Join-Path $env:TEMP ('AdoServerLabAutoOrchestratorMediaTest-' + [guid]::NewGuid().ToString('N'))
        $smtpFolder = Join-Path $work 'smtp4dev'
        $zip = Join-Path $work 'smtp4dev.zip'
        $sourceExe = Join-Path $work 'Rnwood.Smtp4dev.exe'
        $isoFiles = @('2019', '2022', '2025') | ForEach-Object { Join-Path $work "SQLServer$_.iso" }
        $files = @($isoFiles) + @($zip, $sourceExe, (Join-Path $smtpFolder 'Rnwood.Smtp4dev.exe'), (Join-Path $smtpFolder 'appsettings.json'))
        $trace = New-Object 'System.Collections.Generic.List[string]'
        function Get-Service { param($Name) return $null }
        function Get-PSDrive { param($Name) return [pscustomobject]@{ Free = 100GB } }
        function Get-GuestSqlMedia { param($Release, $Work) return $iso }
        function Mount-DiskImage { param($ImagePath, [switch]$PassThru) return [pscustomobject]@{ ImagePath = $ImagePath } }
        function Get-Volume { return [pscustomobject]@{ DriveLetter = 'Z' } }
        function Assert-MicrosoftSignature { param($Path) }
        function Write-SetupProgress { param($Message, $Work) }
        function Assert-SetupPortsAvailable { param($Plan, $Names, $AllowedProcessPath) }
        function Dismount-DiskImage {
            param($ImagePath)
            if ($ImagePath -ne $iso) { throw 'SQL must unmount only its own ISO.' }
            $trace.Add('Unmount')
        }
        function Invoke-SetupInstaller {
            param($Path, $Arguments)
            $trace.Add('Install')
            if ($sqlOutcome -eq 'Failure') { throw 'Mock SQL installation failure.' }
            return $sqlOutcome -eq 'Reboot'
        }
        function Get-SetupDownload {
            param($Url, $Path, $Hash)
            if ($Path -ne $zip) { throw 'SMTP media retention test must not download other media.' }
        }
        function New-ScheduledTaskAction { return [pscustomobject]@{ Mock = 'Action' } }
        function New-ScheduledTaskTrigger { return [pscustomobject]@{ Mock = 'Trigger' } }
        function New-ScheduledTaskPrincipal { return [pscustomobject]@{ Mock = 'Principal' } }
        function New-ScheduledTaskSettingsSet { return [pscustomobject]@{ Mock = 'Settings' } }
        function Register-ScheduledTask { $trace.Add('RegisterCapture') }
        function Get-NetFirewallRule { return [pscustomobject]@{ Mock = 'ExistingFirewallRule' } }
        function Start-ScheduledTask { $trace.Add('StartCapture') }
        New-Item -ItemType Directory -Path $work | Out-Null
        try {
            foreach ($version in @('2020', '2022.1', '2022', '25H2')) {
                $iso = switch ($version) { '2020' { $isoFiles[0] }; '2022.1' { $isoFiles[1] }; '2022' { $isoFiles[1] }; '25H2' { $isoFiles[2] } }
                'offline ISO fixture' | Set-Content -LiteralPath $iso -Encoding ASCII
                $plan = [pscustomobject]@{ Version = $version; SqlInstance = 'localhost'; SetupAccount = 'AK\labadmin' }
                foreach ($sqlOutcome in @('Success', 'Reboot', 'Failure')) {
                    $trace.Clear()
                    $failed = $false
                    $reboot = $false
                    try { $reboot = Install-GuestSql -Plan $plan -Work $work }
                    catch {
                        if ($sqlOutcome -ne 'Failure' -or $_.Exception.Message -ne 'Mock SQL installation failure.') { throw }
                        $failed = $true
                    }
                    if ($failed -ne ($sqlOutcome -eq 'Failure') -or $reboot -ne ($sqlOutcome -eq 'Reboot') -or
                        ($trace -join ',') -ne 'Install,Unmount' -or
                        (Get-Content -LiteralPath $iso -Raw).Trim() -ne 'offline ISO fixture') {
                        throw 'All SQL releases must retain unchanged media, unmount it and preserve installer outcomes.'
                    }
                }
            }
            $trace.Clear()
            'offline SMTP fixture; never execute' | Set-Content -LiteralPath $sourceExe -Encoding ASCII
            Compress-Archive -LiteralPath $sourceExe -DestinationPath $zip
            $zipHash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
            Install-GuestSmtp -Work $work -Plan ([pscustomobject]@{
                SchemaVersion = 4; Ports = [pscustomobject]@{ Https = 8443; Ssh = 2223; Smtp = 2525; MailUi = 5001 }
            })
            $smtpConfig = Get-Content -LiteralPath (Join-Path $smtpFolder 'appsettings.json') -Raw | ConvertFrom-Json
            if ($smtpConfig.ServerOptions.Port -ne 2525 -or $smtpConfig.ServerOptions.Urls -ne 'http://localhost:5001') {
                throw 'SMTP capture and UI must use the persisted alternate ports.'
            }
            if ((Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash -ne $zipHash -or
                -not (Test-Path -LiteralPath (Join-Path $smtpFolder 'Rnwood.Smtp4dev.exe')) -or
                ($trace -join ',') -ne 'RegisterCapture,StartCapture') {
                throw 'SMTP extraction must retain the unchanged ZIP and continue capture configuration.'
            }
        }
        finally {
            foreach ($file in $files) {
                if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }
            }
            if (Test-Path -LiteralPath $smtpFolder) { Remove-Item -LiteralPath $smtpFolder -Force }
            Remove-Item -LiteralPath $work -Force
        }
    }
    & {
        $fixtureOs = [pscustomobject]@{ ProductType = 1; BuildNumber = 19045 }
        function Get-CimInstance { [CmdletBinding()] param($ClassName) return $fixtureOs }
        if ((Get-GuestSsmsMajor) -ne 20) { throw 'Windows 10 must select SSMS 20.' }
        $fixtureOs.BuildNumber = 26100
        if ((Get-GuestSsmsMajor) -ne 22) { throw 'Windows 11 must retain SSMS 22.' }
        $fixtureOs.ProductType = 3; $fixtureOs.BuildNumber = 17763
        if ((Get-GuestSsmsMajor) -ne 22) { throw 'Windows Server 2019 must retain SSMS 22.' }
    }
    & {
        function Get-GuestSsmsMajor { return 20 }
        function Test-Path { param($LiteralPath) return $true }
        $fixtureBuild = 37
        function Get-Item {
            param($LiteralPath)
            [pscustomobject]@{ VersionInfo = [pscustomobject]@{
                ProductMajorPart = 20; ProductMinorPart = 2; ProductBuildPart = $fixtureBuild; ProductPrivatePart = 0
            } }
        }
        if ((Get-GuestSsmsPath) -ne (Join-Path ${env:ProgramFiles(x86)} 'Microsoft SQL Server Management Studio 20')) {
            throw 'SSMS 20 discovery must use its own installation path, not SSMS 22.'
        }
        Assert-GuestSsms
        $fixtureBuild = 30; $rejected = $false
        try { Assert-GuestSsms }
        catch { if ($_.Exception.Message -notlike 'SSMS 20.2.1*') { throw }; $rejected = $true }
        if (-not $rejected) { throw 'Older SSMS 20 builds must fail verification.' }
        function Test-Path { param($LiteralPath) return $false }
        if ($null -ne (Get-GuestSsmsPath)) { throw 'Absent SSMS 20 must not return an installation path.' }
    }
    & {
        $ssmsArguments = ''
        $ssmsExisting = $null
        $ssmsReboot = $false
        $ssmsVerified = $false
        $ssmsMajor = 22
        function Get-GuestSsmsMajor { return $ssmsMajor }
        function Write-SetupProgress { param($Message, $Work) }
        function Get-SetupDownload {
            param($Url, $Path, [switch]$MicrosoftSigned)
            $expectedUrl = if ($ssmsMajor -eq 20) { 'https://go.microsoft.com/fwlink/?linkid=2313753&clcid=0x409' } else { 'https://aka.ms/ssms/22/release/vs_SSMS.exe' }
            if ($Url -ne $expectedUrl -or -not $MicrosoftSigned) {
                throw 'SSMS must use the signed stable release bootstrap.'
            }
        }
        function Get-GuestSsmsPath { return $ssmsExisting }
        function Invoke-SetupInstaller { param($Path, $Arguments) $script:ssmsTestArguments = $Arguments; return $ssmsReboot }
        function Assert-GuestSsms { $script:ssmsTestVerified = $true }
        $script:ssmsTestVerified = $false
        Install-GuestSsms -Work 'C:\Mock' | Out-Null
        if ($script:ssmsTestArguments -ne '--quiet --wait --norestart' -or -not $script:ssmsTestVerified) {
            throw 'SSMS fresh installation must wait and verify completion.'
        }
        $ssmsExisting = 'C:\Program Files\SSMS 22'
        $ssmsReboot = $true
        $script:ssmsTestVerified = $false
        if (-not (Install-GuestSsms -Work 'C:\Mock') -or $script:ssmsTestVerified -or
            $script:ssmsTestArguments -ne 'update --installPath "C:\Program Files\SSMS 22" --quiet --wait --norestart') {
            throw 'SSMS update must target only its own instance and propagate reboot-required.'
        }
        $ssmsMajor = 20; $ssmsReboot = $false
        $script:ssmsTestVerified = $false
        if ((Install-GuestSsms -Work 'C:\Mock') -or -not $script:ssmsTestVerified -or
            $script:ssmsTestArguments -ne '/install /quiet /norestart') { throw 'Windows 10 must use signed archived SSMS 20.2.1 with legacy bootstrap switches and verification.' }
        $ssmsReboot = $true; $script:ssmsTestVerified = $false
        if (-not (Install-GuestSsms -Work 'C:\Mock') -or $script:ssmsTestVerified) { throw 'SSMS 20 must propagate reboot-required before verification.' }
        Remove-Variable -Name ssmsTestArguments,ssmsTestVerified -Scope Script
    }
    & {
        $mediaTrace = New-Object 'System.Collections.Generic.List[string]'
        function New-Item { param($ItemType, $Path, [switch]$Force) }
        function Write-SetupProgress { param($Message, $Work) }
        function Invoke-WebRequest {
            param([switch]$UseBasicParsing, $Uri, $OutFile, $TimeoutSec)
            $mediaTrace.Add("ISO:$Uri")
            if ($TimeoutSec -ne 7200) { throw 'Direct media download requires a bounded timeout.' }
        }
        function Get-Item { param($LiteralPath) return [pscustomobject]@{ Length = 1163053056 } }
        function Get-SetupDownload {
            param($Url, $Path, [switch]$MicrosoftSigned)
            if (-not $MicrosoftSigned) { throw 'Bootstrap signature verification is required.' }
            $mediaTrace.Add('Bootstrap')
        }
        function Invoke-SetupInstaller { param($Path, $Arguments) $mediaTrace.Add('Downloader'); return $false }
        function Get-ChildItem { param($LiteralPath, $Filter) return [pscustomobject]@{ FullName = 'C:\Mock\SqlMedia\sql.iso' } }
        $iso = Get-GuestSqlMedia -Release (Get-SetupRelease -Version '2022') -Work 'C:\Mock'
        if ($mediaTrace.Count -ne 1 -or $mediaTrace[0] -notlike 'ISO:https://download.microsoft.com/*' -or
            $iso -ne 'C:\Mock\SqlMedia\SQLServer2022-Developer.iso') { throw 'SQL 2022 must bypass the unsupported bootstrap.' }
        $mediaTrace.Clear()
        Get-GuestSqlMedia -Release (Get-SetupRelease -Version '2020') -Work 'C:\Mock' | Out-Null
        if (($mediaTrace -join ',') -ne 'Bootstrap,Downloader') { throw 'SQL 2019 must use its signed Developer bootstrap.' }
        $mediaTrace.Clear()
        Get-GuestSqlMedia -Release (Get-SetupRelease -Version '25H2') -Work 'C:\Mock' | Out-Null
        if (($mediaTrace -join ',') -ne 'Bootstrap,Downloader') { throw 'SQL 2025 bootstrap selection must be preserved.' }
    }
    & {
        function Start-Process {
            param($FilePath, $ArgumentList, [switch]$Wait, [switch]$PassThru)
            [pscustomobject]@{ ExitCode = $testExit }
        }
        $testExit = 0
        if (Invoke-SetupInstaller -Path 'mock.exe' -Arguments '') { throw 'Exit 0 must not request a reboot.' }
        $testExit = 3010
        if (-not (Invoke-SetupInstaller -Path 'mock.exe' -Arguments '')) { throw 'Exit 3010 must request a reboot.' }
        $testExit = 42
        $rejected = $false
        try { Invoke-SetupInstaller -Path 'mock.exe' -Arguments '' | Out-Null }
        catch { if ($_.Exception.Message -notlike 'Installer failed with exit code 42*') { throw }; $rejected = $true }
        if (-not $rejected) { throw 'Installer errors must propagate.' }
    }
    & {
        $testState = [pscustomobject]@{
            SchemaVersion = 2; Version = '25H2'; Components = 'Both'; DomainName = 'ak.com'
            ComputerName = 'labserver'; SqlInstance = 'localhost'; Email = 'Capture'
            SetupAccount = 'AK\labadmin'; SetupSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
            StageIndex = 0; Status = 'Pending'; LastError = ''; CertificateThumbprint = ''; RebootAfter = ''
        }
        $trace = New-Object 'System.Collections.Generic.List[string]'
        $testReboot = $true
        $testFailVerify = $false
        $testJoinMode = 'Domain'
        $testConfigureReboot = $false
        $testBoot = [datetime]'2026-11-05T08:00:00Z'
        $testWorkerBuild = 20348
        function Read-SetupState { param($Path) return $testState }
        function Save-SetupState { param($State, $Path) Assert-SetupPlan -Plan $State }
        function Get-CimInstance {
            param($ClassName)
            if ($ClassName -eq 'Win32_OperatingSystem') { return [pscustomobject]@{
                LastBootUpTime = $testBoot; ProductType = 3; BuildNumber = $testWorkerBuild; OSArchitecture = '64-bit'; OperatingSystemSKU = 7
            } }
            return [pscustomobject]@{
                Name = 'labserver'; PartOfDomain = ($testJoinMode -eq 'Domain')
                Domain = $(if ($testJoinMode -eq 'Domain') { 'ak.com' } else { 'WORKGROUP' }); DomainRole = 3
            }
        }
        function New-Item { param($ItemType, $Path, [switch]$Force) }
        function Start-Transcript { param($Path) }
        function Stop-Transcript {}
        function Write-SetupProgress { param($Message, $Work) }
        function Restart-Computer { param([switch]$Force) $trace.Add('Restart') }
        function Disable-ScheduledTask { param($TaskName) $trace.Add('Disabled') }
        function Unregister-ScheduledTask { param($TaskName, [switch]$Confirm) $trace.Add('Removed') }
        function Assert-ExistingSql { param($Plan) }
        $testIisReboot = $false
        function Initialize-SetupClientIis { param($Os, $Work) return $testIisReboot }
        function Install-GuestSql { param($Plan, $Work) $trace.Add('Sql'); return $testReboot }
        function Install-GuestDevOps { param($Plan, $Work) $trace.Add('DevOps'); return $false }
        function Install-GuestSmtp { param($Work, $Plan) $trace.Add('Smtp') }
        function Configure-GuestDevOps { param($Plan, $Work, $Path) $trace.Add('Configure'); return $testConfigureReboot }
        function Install-GuestPatch { param($Plan, $Work) $trace.Add('Patch'); return $false }
        function Install-GuestSsms { param($Work) $trace.Add('Ssms'); return $false }
        function Test-GuestInstallation {
            param($Plan, $Work)
            $trace.Add('Verify')
            if ($testFailVerify) { throw 'Mock verification failure.' }
        }
        $path = Join-Path $env:ProgramData 'AdoServerLabAutoOrchestrator\state.json'
        Invoke-GuestSetup -Path $path
        if ($testState.StageIndex -ne 1 -or $testState.Status -ne 'RebootPending' -or
            ($trace -join ',') -ne 'Sql,Restart') { throw 'Worker must save the next stage and stop at reboot.' }
        $testState.Status = 'Pending'
        Invoke-GuestSetup -Path $path
        if ($trace[-1] -ne 'Restart' -or $testState.StageIndex -ne 1) { throw 'Retry must not skip a requested reboot that did not happen.' }
        $testBoot = $testBoot.AddMinutes(5)
        Invoke-GuestSetup -Path $path
        if ($testState.Status -ne 'Completed' -or ($trace -join ',') -ne 'Sql,Restart,Restart,DevOps,Smtp,Configure,Patch,Ssms,Verify,Removed') {
            throw 'After a reboot, resume must skip SQL and run through verification before removing the task.'
        }
        $trace.Clear()
        $testState.StageIndex = @(Get-SetupSteps -Plan $testState).Count - 1
        $testState.Status = 'Pending'
        $testFailVerify = $true
        $rejected = $false
        try { Invoke-GuestSetup -Path $path }
        catch { if ($_.Exception.Message -ne 'Mock verification failure.') { throw }; $rejected = $true }
        if (-not $rejected -or $testState.Status -ne 'Failed' -or $trace[-1] -ne 'Disabled' -or
            $testState.LastError -ne 'Mock verification failure.') { throw 'Worker failures must persist the error and disable automatic retries.' }
        $trace.Clear()
        $testState.SchemaVersion = 3
        $testState | Add-Member -NotePropertyName PatchSelection -NotePropertyValue 'Skip'
        $testState.StageIndex = 0; $testState.Status = 'Pending'; $testState.LastError = ''
        $testReboot = $false; $testFailVerify = $false
        Invoke-GuestSetup -Path $path
        if ($testState.Status -ne 'Completed' -or ($trace -join ',') -ne 'Sql,DevOps,Smtp,Configure,Ssms,Verify,Removed') {
            throw 'Actual Skip worker path must complete all other stages without running the patch installer.'
        }
        $trace.Clear()
        $testState.SchemaVersion = 5
        $testState | Add-Member -NotePropertyName JoinMode -NotePropertyValue 'Workgroup'
        $testState | Add-Member -NotePropertyName DnsHostName -NotePropertyValue 'devops.lab.example.com'
        $testState | Add-Member -NotePropertyName Ports -NotePropertyValue $null
        $testState.DomainName = 'WORKGROUP'; $testState.SetupAccount = 'labserver\labadmin'
        $testState.StageIndex = [array]::IndexOf(@(Get-SetupSteps -Plan $testState), 'Configure')
        $testState.Status = 'Pending'; $testState.RebootAfter = ''
        $testJoinMode = 'Workgroup'; $testConfigureReboot = $true
        Invoke-GuestSetup -Path $path
        if ($testState.Status -ne 'RebootPending' -or ($trace -join ',') -ne 'Configure,Restart') {
            throw 'Custom workgroup configuration must save the next stage and request a reboot.'
        }
        $testBoot = $testBoot.AddMinutes(5)
        Invoke-GuestSetup -Path $path
        if ($testState.Status -ne 'Completed' -or ($trace -join ',') -ne 'Configure,Restart,Ssms,Verify,Removed') {
            throw 'Workgroup resume must preserve hostname/membership and never repeat configuration after its reboot.'
        }
        $trace.Clear()
        $testState.StageIndex = 0; $testState.Status = 'Pending'; $testState.RebootAfter = ''
        $testIisReboot = $true; $testConfigureReboot = $false
        Invoke-GuestSetup -Path $path
        if ($testState.Status -ne 'RebootPending' -or $testState.StageIndex -ne 0 -or ($trace -join ',') -ne 'Restart') {
            throw 'IIS prerequisite reboot must persist boot time without advancing/skipping any installation stage.'
        }
        $testBoot = $testBoot.AddMinutes(5); $testIisReboot = $false
        Invoke-GuestSetup -Path $path
        if ($testState.Status -ne 'Completed' -or ($trace -join ',') -ne 'Restart,Sql,DevOps,Smtp,Configure,Ssms,Verify,Removed') {
            throw 'IIS prerequisite resume must run all saved stages after the reboot.'
        }
        $trace.Clear()
        $testWorkerBuild = 30000
        $testState.SchemaVersion = 6
        $testState | Add-Member -NotePropertyName AllowUnsupportedOs -NotePropertyValue $false
        $testState.StageIndex = 0; $testState.Status = 'Pending'; $testState.RebootAfter = ''
        $rejected = $false
        try { Invoke-GuestSetup -Path $path }
        catch [NotSupportedException] { $rejected = $true }
        if (-not $rejected -or $testState.Status -ne 'Failed' -or ($trace -join ',') -ne 'Disabled') {
            throw 'Unsupported saved plans must fail before installing unless an OS acknowledgement was saved.'
        }
        $trace.Clear()
        $testState.AllowUnsupportedOs = $true; $testState.Status = 'Pending'; $testState.LastError = ''
        $testReboot = $true
        Invoke-GuestSetup -Path $path -WarningAction SilentlyContinue
        if ($testState.StageIndex -ne 1 -or $testState.Status -ne 'RebootPending' -or ($trace -join ',') -ne 'Sql,Restart') {
            throw 'An acknowledged unsupported OS must run the same saved reboot workflow.'
        }
        $testBoot = $testBoot.AddMinutes(5)
        Invoke-GuestSetup -Path $path -WarningAction SilentlyContinue
        if ($testState.Status -ne 'Completed' -or -not $testState.AllowUnsupportedOs -or
            ($trace -join ',') -ne 'Sql,Restart,DevOps,Smtp,Configure,Ssms,Verify,Removed') {
            throw 'Automatic resume must retain the saved OS acknowledgement and finish all stages.'
        }
    }
    Write-Host 'PASS: guest scripts parse; client/server OS matrix, IIS prerequisites, SSMS 20/22, ports, media, version/component/email/patch combinations, resume transitions and SQL guards passed offline.'
    Write-Host 'No software installed, disks changed, tasks registered, reboots requested, or Azure resources created.'
}

if ($MyInvocation.InvocationName -ne '.') { Test-GuestSetupOffline -Folder $PSScriptRoot }
