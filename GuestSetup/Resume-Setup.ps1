#requires -Version 5.1
[CmdletBinding()]
param([string]$StatePath = (Join-Path $env:ProgramData 'AdoServerLabAutoOrchestrator\state.json'))

Import-Module -Name (Join-Path $PSScriptRoot 'Setup-Releases.psm1') -Force -DisableNameChecking -ErrorAction Stop
Import-Module -Name (Join-Path $PSScriptRoot 'Setup-State.psm1') -Force -DisableNameChecking -ErrorAction Stop

function Copy-SetupWorkerFiles {
    param([string]$SourceFolder, [string]$Work)
    $names = @('Setup-Releases.psm1', 'Setup-State.psm1', 'Resume-Setup.ps1')
    foreach ($name in $names) {
        $source = Join-Path $SourceFolder $name
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Required setup file is missing: $source" }
    }
    foreach ($name in $names) {
        $source = Join-Path $SourceFolder $name
        $destination = Join-Path $Work $name
        if ([IO.Path]::GetFullPath($source) -ne [IO.Path]::GetFullPath($destination)) {
            Copy-Item -LiteralPath $source -Destination $destination -Force -ErrorAction Stop
        }
    }
}

function Read-SetupChoice {
    param([string]$Prompt, [string[]]$Choices, [string]$Default)
    do {
        $answer = Read-Host "$Prompt [$Default]"
        if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
        if ($Choices -contains $answer.Trim()) { return $answer.Trim() }
        Write-Warning "Choose one of: $($Choices -join ', ')."
    } while ($true)
}

function Read-SetupCredential {
    param([string]$AccountName)
    if ([string]::IsNullOrWhiteSpace($AccountName)) { throw 'A setup account is required for the password prompt.' }
    Write-Host "Automatic resume will run as $AccountName. Enter this account's Windows password, not a PIN."
    $password = Read-Host -Prompt "Password for $AccountName" -AsSecureString
    if ($null -eq $password -or $password.Length -eq 0) {
        throw 'No password was entered. Rerun setup and enter the setup account password, or supply -Credential as a PSCredential.'
    }
    return [Management.Automation.PSCredential]::new($AccountName, $password)
}

function Get-SetupPorts {
    param([psobject]$Plan)
    if ($Plan.SchemaVersion -ge 4 -and $null -ne $Plan.Ports) { return $Plan.Ports }
    return [pscustomobject]@{ Https = 443; Ssh = 2222; Smtp = 25; MailUi = 5000 }
}

function Get-SetupPortProbe {
    param([int]$Port, [string]$AllowedProcessPath)
    $listeners = @(Get-NetTCPConnection -ErrorAction Stop | Where-Object { $_.State -eq 'Listen' -and $_.LocalPort -eq $Port })
    if ($listeners.Count) {
        if ($AllowedProcessPath) {
            $other = @($listeners | Where-Object {
                $process = Get-CimInstance Win32_Process -Filter "ProcessId=$($_.OwningProcess)" -ErrorAction Stop
                $null -eq $process -or $process.ExecutablePath -ne $AllowedProcessPath
            })
            if ($other.Count -eq 0) { return [pscustomobject]@{ Available = $true; Reason = 'Already owned by this setup component.' } }
        }
        return [pscustomobject]@{ Available = $false; Reason = "TCP listener PID(s): $(($listeners.OwningProcess | Select-Object -Unique) -join ', ')." }
    }
    $iisConfig = Join-Path $env:SystemRoot 'System32\inetsrv\config\applicationHost.config'
    if (Test-Path -LiteralPath $iisConfig) {
        $iis = [xml](Get-Content -LiteralPath $iisConfig -Raw -ErrorAction Stop)
        foreach ($binding in $iis.SelectNodes('/configuration/system.applicationHost/sites/site/bindings/binding')) {
            if ($binding.GetAttribute('bindingInformation') -match (':' + $Port + ':')) {
                return [pscustomobject]@{ Available = $false; Reason = "Reserved by IIS site '$($binding.ParentNode.ParentNode.GetAttribute('name'))'." }
            }
        }
    }
    $sockets = @()
    try {
        $addresses = @([Net.IPAddress]::Any)
        if ([Net.Sockets.Socket]::OSSupportsIPv6) { $addresses += [Net.IPAddress]::IPv6Any }
        foreach ($address in $addresses) {
            $socket = [Net.Sockets.TcpListener]::new($address, $Port)
            $sockets += $socket
            $socket.ExclusiveAddressUse = $true
            if ($address.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetworkV6) {
                $socket.Server.DualMode = $false
            }
            $socket.Start()
        }
        return [pscustomobject]@{ Available = $true; Reason = '' }
    }
    catch [Net.Sockets.SocketException] {
        if ($_.Exception.SocketErrorCode -notin @([Net.Sockets.SocketError]::AddressAlreadyInUse, [Net.Sockets.SocketError]::AccessDenied)) { throw }
        return [pscustomobject]@{ Available = $false; Reason = "Cannot bind TCP port: $($_.Exception.SocketErrorCode)." }
    }
    finally { foreach ($socket in $sockets) { $socket.Stop() } }
}

function Initialize-SetupPorts {
    param([psobject]$Plan)
    if ($Plan.SchemaVersion -lt 4 -or $null -ne $Plan.Ports) { return }
    $ports = Get-SetupPorts -Plan $Plan
    $steps = @(Get-SetupSteps -Plan $Plan)
    $candidates = [ordered]@{}
    if ($Plan.Components -ne 'SqlOnly' -and $Plan.StageIndex -le [array]::IndexOf($steps, 'Configure')) {
        $candidates.Https = @(443) + @(8443..8452)
        $candidates.Ssh = @(22) + @(2222..2232)
    }
    if ($Plan.Email -eq 'Capture' -and $Plan.StageIndex -le [array]::IndexOf($steps, 'Smtp')) {
        $candidates.Smtp = @(25) + @(2525..2534)
        $candidates.MailUi = @(5000..5010)
    }
    foreach ($name in $candidates.Keys) {
        $selected = $false
        foreach ($candidate in $candidates[$name]) {
            $probe = Get-SetupPortProbe -Port $candidate
            if (-not $probe.Available) {
                Write-Warning "$name TCP port $candidate is unavailable: $($probe.Reason) Trying an alternate."
                continue
            }
            $ports.$name = $candidate
            $selected = $true
            break
        }
        if (-not $selected) { throw "No free $name TCP port in the setup candidate range. No existing services were stopped." }
    }
    $Plan.Ports = $ports
}

function Assert-SetupPortsAvailable {
    param([psobject]$Plan, [string[]]$Names, [string]$AllowedProcessPath)
    $ports = Get-SetupPorts -Plan $Plan
    foreach ($name in $Names) {
        $probe = Get-SetupPortProbe -Port $ports.$name -AllowedProcessPath $AllowedProcessPath
        if (-not $probe.Available) {
            throw "Saved $name TCP port $($ports.$name) is now unavailable: $($probe.Reason) Setup will not change saved ports or stop existing services. Resolve the conflict before resuming."
        }
    }
}

function Get-SetupDevOpsUrl {
    param([psobject]$Plan)
    $ports = Get-SetupPorts -Plan $Plan
    $authority = Get-SetupHostName -Plan $Plan
    if ($ports.Https -ne 443) { $authority += ":$($ports.Https)" }
    return "https://$authority/tfs"
}

function Assert-SetupMachineIdentity {
    param([psobject]$Plan, [psobject]$Computer)
    $domainMode = (Get-SetupJoinMode -Plan $Plan) -eq 'Domain'
    if ($Computer.Name -ne $Plan.ComputerName -or $Computer.DomainRole -ge 4 -or
        [bool]$Computer.PartOfDomain -ne $domainMode -or $Computer.Domain -ne $Plan.DomainName) {
        throw 'Saved computer/domain/workgroup identity no longer matches. Setup never joins or changes domains.'
    }
}

function Assert-SetupHostResolution {
    param([psobject]$Plan)
    if ((Get-SetupJoinMode -Plan $Plan) -ne 'Workgroup') { return }
    $name = Get-SetupHostName -Plan $Plan
    if ($name -eq $Plan.ComputerName) { return }
    $records = @(Resolve-DnsName -Name $name -Type A_AAAA -DnsOnly -ErrorAction Stop |
        Where-Object { $_.PSObject.Properties['IPAddress'] })
    $local = @(Get-NetIPAddress -ErrorAction Stop | ForEach-Object { [Net.IPAddress]::Parse($_.IPAddress) } |
        Where-Object { -not [Net.IPAddress]::IsLoopback($_) })
    if (-not $records.Count -or @($records | Where-Object { $local -notcontains [Net.IPAddress]::Parse($_.IPAddress) }).Count) {
        throw "Custom DNS hostname '$name' must resolve only to this VM's non-loopback IP addresses. Create/fix the DNS record first."
    }
}

function Get-SetupFirewallProfile {
    param([psobject]$Plan)
    if ((Get-SetupJoinMode -Plan $Plan) -eq 'Domain') { return 'Domain' }
    if (-not @(Get-NetConnectionProfile -ErrorAction Stop | Where-Object NetworkCategory -eq 'Private').Count) {
        throw 'Workgroup DevOps requires a trusted Private network profile. Review/set the intended interface to Private before setup; Public access is never opened automatically.'
    }
    return 'Private'
}

function Get-SetupMailDomain {
    param([psobject]$Plan)
    if ((Get-SetupJoinMode -Plan $Plan) -eq 'Workgroup') { return Get-SetupHostName -Plan $Plan }
    return $Plan.DomainName
}

function Set-SetupLoopbackHost {
    param([psobject]$Plan)
    if ((Get-SetupJoinMode -Plan $Plan) -ne 'Workgroup') { return }
    $name = Get-SetupHostName -Plan $Plan
    if ($name -eq $Plan.ComputerName) { return }
    $path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\MSV1_0'
    $key = Get-Item -LiteralPath $path -ErrorAction Stop
    $existing = @()
    if ($key.GetValueNames() -contains 'BackConnectionHostNames') {
        if ($key.GetValueKind('BackConnectionHostNames') -ne [Microsoft.Win32.RegistryValueKind]::MultiString) {
            throw 'BackConnectionHostNames must be REG_MULTI_SZ. Review the existing registry setting before setup.'
        }
        $existing = @($key.GetValue('BackConnectionHostNames'))
    }
    if ($existing -notcontains $name) {
        New-ItemProperty -LiteralPath $path -Name 'BackConnectionHostNames' -PropertyType MultiString `
            -Value @($existing + $name) -Force -ErrorAction Stop | Out-Null
    }
}

function Get-SqlServiceName {
    param([string]$Instance)
    if ($Instance.Contains('\')) { return 'MSSQL$' + $Instance.Split('\')[1] }
    return 'MSSQLSERVER'
}

function Invoke-SetupSql {
    param([psobject]$Plan, [string]$Query)
    $builder = [System.Data.SqlClient.SqlConnectionStringBuilder]::new()
    $builder['Data Source'] = $Plan.SqlInstance
    $builder['Initial Catalog'] = 'master'
    $builder['Integrated Security'] = $true
    $builder['Encrypt'] = $true
    $builder['TrustServerCertificate'] = $true
    $connection = New-Object Data.SqlClient.SqlConnection($builder.ConnectionString)
    try {
        $connection.Open()
        $command = $connection.CreateCommand()
        $command.CommandText = $Query
        $command.CommandTimeout = 120
        $table = New-Object Data.DataTable
        $reader = $command.ExecuteReader()
        try { $table.Load($reader) } finally { $reader.Dispose() }
        return ,$table
    }
    finally { $connection.Dispose() }
}

function Assert-SqlDetails {
    param([Data.DataTable]$Details, [psobject]$Release)
    if ($Details.Rows.Count -ne 1 -or $Details.Rows[0].Major -ne $Release.SqlMajor -or
        $Details.Rows[0].FullText -ne 1 -or $Details.Rows[0].SysAdmin -ne 1 -or
        $Details.Rows[0].Collation -ne 'SQL_Latin1_General_CP1_CI_AS' -or
        $Details.Rows[0].Edition -notmatch 'Developer|Standard|Enterprise') {
        throw "Require SQL $($Release.SqlYear), Full-Text, SQL_Latin1_General_CP1_CI_AS collation and SQL sysadmin rights for the setup account. Existing SQL is never upgraded or reconfigured."
    }
}

function Assert-ExistingSql {
    param([psobject]$Plan)
    $service = Get-Service -Name (Get-SqlServiceName -Instance $Plan.SqlInstance)
    $service.WaitForStatus('Running', [TimeSpan]::FromMinutes(5))
    $details = Invoke-SetupSql -Plan $Plan -Query @'
SELECT CONVERT(int, SERVERPROPERTY('ProductMajorVersion')) AS Major,
       CONVERT(int, SERVERPROPERTY('IsFullTextInstalled')) AS FullText,
       CONVERT(nvarchar(128), SERVERPROPERTY('Edition')) AS Edition,
       CONVERT(nvarchar(128), SERVERPROPERTY('Collation')) AS Collation,
       IS_SRVROLEMEMBER('sysadmin') AS SysAdmin
'@
    Assert-SqlDetails -Details $details -Release (Get-SetupRelease -Version $Plan.Version)
}

function Get-InstalledDevOpsTools {
    return ,@(Get-ChildItem -LiteralPath $env:ProgramFiles -Directory -Filter 'Azure DevOps Server*' |
        ForEach-Object { Join-Path $_.FullName 'Tools\TfsConfig.exe' } |
        Where-Object { Test-Path -LiteralPath $_ })
}

function Get-SetupTfsConfig {
    $tools = Get-InstalledDevOpsTools
    if ($tools.Count -ne 1) { throw "Expected exactly one DevOps installation; found $($tools.Count)." }
    return $tools[0]
}

function Assert-MicrosoftSignature {
    param([string]$Path)
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation(?:,|$)') {
        throw "A valid Microsoft signature is required: $Path"
    }
}

function Get-SetupDownload {
    param([string]$Url, [string]$Path, [string]$Hash, [switch]$MicrosoftSigned)
    if (([uri]$Url).Scheme -ne 'https' -or (-not $Hash -and -not $MicrosoftSigned)) {
        throw 'Downloads require HTTPS plus a pinned digest or Microsoft signature.'
    }
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $Path -TimeoutSec 7200
    if ($Hash -and (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ne $Hash) {
        Remove-Item -LiteralPath $Path -Force
        throw "SHA-256 mismatch: $Url. Review release notes; do not disable validation."
    }
    if ($MicrosoftSigned) { Assert-MicrosoftSignature -Path $Path }
}

function Write-SetupProgress {
    param([string]$Message, [string]$Work)
    $line = "$((Get-Date).ToString('o')) $Message"
    Add-Content -LiteralPath (Join-Path $Work 'progress.log') -Value $line -Encoding UTF8
    Write-Host $line
}

function Get-GuestSqlMedia {
    param([psobject]$Release, [string]$Work)
    $media = Join-Path $Work 'SqlMedia'
    New-Item -ItemType Directory -Path $media -Force | Out-Null
    if ($Release.SqlIsoUrl) {
        $url = [uri]$Release.SqlIsoUrl
        if ($url.Scheme -ne 'https' -or $url.Host -ne 'download.microsoft.com' -or
            -not $url.AbsolutePath.EndsWith('.iso', [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Direct SQL media must be an HTTPS ISO on download.microsoft.com.'
        }
        $iso = Join-Path $media "SQLServer$($Release.SqlYear)-Developer.iso"
        Write-SetupProgress -Work $Work -Message "Downloading SQL $($Release.SqlYear) Developer ISO directly from Microsoft; this may take several minutes."
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -UseBasicParsing -Uri $url.AbsoluteUri -OutFile $iso -TimeoutSec 7200
        Write-SetupProgress -Work $Work -Message "SQL ISO download completed: $((Get-Item -LiteralPath $iso).Length) bytes. SQL setup signature will be verified before execution."
        return $iso
    }
    $bootstrap = Join-Path $Work "SQL$($Release.SqlYear)-Developer.exe"
    Write-SetupProgress -Work $Work -Message "Downloading SQL $($Release.SqlYear) bootstrap."
    Get-SetupDownload -Url $Release.SqlUrl -Path $bootstrap -MicrosoftSigned
    Write-SetupProgress -Work $Work -Message 'Starting SQL bootstrap media download.'
    $downloadReboot = Invoke-SetupInstaller -Path $bootstrap -Arguments "/ACTION=Download /MEDIATYPE=ISO /MEDIAPATH=`"$media`" /QUIET"
    if ($downloadReboot) { throw 'SQL media downloader unexpectedly requested a reboot. No SQL installation was attempted; inspect its logs.' }
    $isos = @(Get-ChildItem -LiteralPath $media -Filter '*.iso')
    if ($isos.Count -ne 1) { throw 'Expected exactly one SQL ISO.' }
    return $isos[0].FullName
}

function Invoke-SetupInstaller {
    param([string]$Path, [string]$Arguments)
    $process = Start-Process -FilePath $Path -ArgumentList $Arguments -Wait -PassThru
    if ($process.ExitCode -notin @(0, 3010)) { throw "Installer failed with exit code $($process.ExitCode): $Path" }
    return ($process.ExitCode -eq 3010)
}

function Invoke-SetupTfsConfig {
    param([string]$Tool, [string[]]$Arguments)
    & $Tool @Arguments | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "TfsConfig failed with exit code $LASTEXITCODE. Review its setup logs." }
}

function Set-SetupIniValue {
    param([string]$Text, [string[]]$Names, [string]$Value)
    foreach ($name in $Names) {
        $pattern = '(?m)^' + [regex]::Escape($name) + '=.*$'
        if ([regex]::IsMatch($Text, $pattern)) {
            return [regex]::Replace($Text, $pattern, [Text.RegularExpressions.MatchEvaluator]{ param($match) "$name=$Value" })
        }
    }
    throw "The generated DevOps INI does not expose $($Names -join '/'). Inspect devops.ini; no schema keys were guessed."
}

function Install-GuestSql {
    param([psobject]$Plan, [string]$Work)
    if (Get-Service -Name (Get-SqlServiceName -Instance $Plan.SqlInstance) -ErrorAction SilentlyContinue) {
        Assert-ExistingSql -Plan $Plan
        Write-Host 'Supported existing SQL preserved.'
        return $false
    }
    $release = Get-SetupRelease -Version $Plan.Version
    if ((Get-PSDrive -Name C).Free -lt 35GB) { throw 'At least 35 GB free on C: is required for SQL media, software and initial lab data.' }
    $iso = Get-GuestSqlMedia -Release $release -Work $Work
    $image = Mount-DiskImage -ImagePath $iso -PassThru
    try {
        $drive = ($image | Get-Volume).DriveLetter
        $setup = "${drive}:\setup.exe"
        Assert-MicrosoftSignature -Path $setup
        Write-SetupProgress -Work $Work -Message "Installing SQL $($release.SqlYear) Database Engine and Full-Text."
        $arguments = '/Q /ACTION=Install /FEATURES=SQLENGINE,FULLTEXT /INSTANCENAME=MSSQLSERVER ' +
            '/IACCEPTSQLSERVERLICENSETERMS /SQLCOLLATION=SQL_Latin1_General_CP1_CI_AS ' +
            "/SQLSYSADMINACCOUNTS=`"$($Plan.SetupAccount)`" " +
            '/SQLSVCACCOUNT="NT Service\MSSQLSERVER" /SQLSVCSTARTUPTYPE=Automatic ' +
            '/AGTSVCACCOUNT="NT Service\SQLSERVERAGENT" /AGTSVCSTARTUPTYPE=Automatic ' +
            '/SQLMAXMEMORY=4096 /TCPENABLED=0 /NPENABLED=0 /UpdateEnabled=True'
        $reboot = Invoke-SetupInstaller -Path $setup -Arguments $arguments
    }
    finally { Dismount-DiskImage -ImagePath $iso | Out-Null }
    return [bool]$reboot
}

function Install-GuestDevOps {
    param([psobject]$Plan, [string]$Work)
    if ((Get-InstalledDevOpsTools).Count -gt 0) {
        Get-SetupTfsConfig | Out-Null
        Write-Host 'DevOps binaries installed by an earlier attempt are present; configuration is a separate stage.'
        return $false
    }
    $installer = Join-Path $Work 'DevOpsSetup.exe'
    Get-SetupDownload -Url (Get-SetupRelease -Version $Plan.Version).DevOpsUrl -Path $installer -MicrosoftSigned
    $reboot = Invoke-SetupInstaller -Path $installer -Arguments '/Quiet /NoRestart'
    Get-SetupTfsConfig | Out-Null
    return $reboot
}

function Get-SetupClientIisFeatures {
    param([psobject]$Os)
    if ($Os.ProductType -ne 1) { return }
    $required = @('IIS-WebServerRole', 'IIS-DefaultDocument', 'IIS-StaticContent', 'IIS-HttpErrors',
        'IIS-HttpLogging', 'IIS-RequestFiltering', 'IIS-WindowsAuthentication', 'IIS-ASPNET45',
        'IIS-ISAPIExtensions', 'IIS-ISAPIFilter', 'IIS-ManagementConsole')
    $features = @(Get-WindowsOptionalFeature -Online -ErrorAction Stop)
    foreach ($name in $required) {
        $feature = @($features | Where-Object FeatureName -eq $name)
        if ($feature.Count -ne 1 -or [string]$feature[0].State -notin @('Enabled', 'Disabled', 'DisabledWithPayloadRemoved', 'EnablePending', 'DisablePending')) {
            throw [NotSupportedException]::new("Required client Windows feature is unavailable: $name. Use a supported Pro/Enterprise/Education edition with IIS Windows Authentication.")
        }
        $feature[0]
    }
}

function Assert-SetupClientOptions {
    param([psobject]$Plan, [psobject]$Os)
    if ($Os.ProductType -eq 1 -and [int]$Os.BuildNumber -lt 22000 -and $Plan.Email -eq 'Capture') {
        throw 'SMTP capture uses .NET 10, which does not support every documented Windows 10 lab version. Choose -Email None on Windows 10; configure any external test mail service separately.'
    }
}

function Initialize-SetupClientIis {
    param([psobject]$Os, [string]$Work)
    $features = @(Get-SetupClientIisFeatures -Os $Os)
    if (@($features | Where-Object { [string]$_.State -in @('EnablePending', 'DisablePending') }).Count) {
        return $true
    }
    $disabled = @($features | Where-Object { [string]$_.State -ne 'Enabled' })
    if (-not $disabled.Count) { return $false }
    Write-SetupProgress -Work $Work -Message 'Enabling client Windows IIS prerequisites, including Windows Authentication and ASP.NET 4.x.'
    $result = Enable-WindowsOptionalFeature -Online -FeatureName @($disabled.FeatureName) -All -NoRestart -ErrorAction Stop
    if ($null -eq $result -or $null -eq $result.RestartNeeded) { throw 'Windows feature servicing returned no restart status.' }
    if ($result.RestartNeeded) { return $true }
    if (@(Get-SetupClientIisFeatures -Os $Os | Where-Object { [string]$_.State -ne 'Enabled' }).Count) {
        throw 'Client IIS prerequisites were not enabled. Review DISM/CBS logs and repair the Windows feature source.'
    }
    return $false
}

function Get-GuestSsmsMajor {
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    if ($os.ProductType -eq 1 -and [int]$os.BuildNumber -lt 22000) { return 20 }
    return 22
}

function Get-GuestSsmsPath {
    if ((Get-GuestSsmsMajor) -eq 20) {
        $path = Join-Path ${env:ProgramFiles(x86)} 'Microsoft SQL Server Management Studio 20'
        if (Test-Path -LiteralPath (Join-Path $path 'Common7\IDE\Ssms.exe')) { return $path }
        return $null
    }
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path -LiteralPath $vswhere)) { return $null }
    $paths = @(& $vswhere -products Microsoft.VisualStudio.Product.SSMS -version '[22.0,23.0)' -latest -property installationPath)
    if ($LASTEXITCODE -ne 0) { throw "SSMS discovery failed with exit code $LASTEXITCODE." }
    if ($paths.Count -gt 1) { throw 'SSMS discovery returned multiple installation paths.' }
    if ($paths.Count -eq 1) { return $paths[0] }
    return $null
}

function Assert-GuestSsms {
    $path = Get-GuestSsmsPath
    if (-not $path -or -not (Test-Path -LiteralPath (Join-Path $path 'Common7\IDE\Ssms.exe'))) {
        throw "SSMS $(Get-GuestSsmsMajor) installation was not verified. Review its installer logs."
    }
    if ((Get-GuestSsmsMajor) -eq 20) {
        $version = (Get-Item -LiteralPath (Join-Path $path 'Common7\IDE\Ssms.exe')).VersionInfo
        if ($version.ProductMajorPart -ne 20 -or
            [version]("$($version.ProductMajorPart).$($version.ProductMinorPart).$($version.ProductBuildPart).$($version.ProductPrivatePart)") -lt [version]'20.2.37.0') {
            throw 'SSMS 20.2.1 (20.2.37.0) or a later 20.x build is required for this Windows 10 lab.'
        }
    }
}

function Install-GuestSsms {
    param([string]$Work)
    if ((Get-GuestSsmsMajor) -eq 20) {
        $installer = Join-Path $Work 'SSMS20-Setup.exe'
        Write-SetupProgress -Work $Work -Message 'Windows 10 lab: installing archived SSMS 20.2.1; this is not the latest SSMS. Review lifecycle/security requirements.'
        Get-SetupDownload -Url 'https://go.microsoft.com/fwlink/?linkid=2313753&clcid=0x409' -Path $installer -MicrosoftSigned
        $reboot = Invoke-SetupInstaller -Path $installer -Arguments '/install /quiet /norestart'
        if (-not $reboot) { Assert-GuestSsms }
        return $reboot
    }
    $installer = Join-Path $Work 'vs_SSMS.exe'
    Write-SetupProgress -Work $Work -Message 'Downloading latest stable SSMS 22 installer from Microsoft.'
    Get-SetupDownload -Url 'https://aka.ms/ssms/22/release/vs_SSMS.exe' -Path $installer -MicrosoftSigned
    $existing = Get-GuestSsmsPath
    $arguments = '--quiet --wait --norestart'
    if ($existing) {
        if ($existing -match '["\r\n]') { throw 'Invalid discovered SSMS installation path.' }
        $arguments = "update --installPath `"$existing`" $arguments"
        Write-SetupProgress -Work $Work -Message 'Updating existing SSMS 22 to the current stable release.'
    }
    else { Write-SetupProgress -Work $Work -Message 'Installing SSMS 22 alongside any older SSMS versions.' }
    $reboot = Invoke-SetupInstaller -Path $installer -Arguments $arguments
    if (-not $reboot) { Assert-GuestSsms }
    return $reboot
}

function Install-GuestSmtp {
    param([string]$Work, [psobject]$Plan)
    $path = Join-Path $Work 'smtp4dev'
    $ports = Get-SetupPorts -Plan $Plan
    Assert-SetupPortsAvailable -Plan $Plan -Names @('Smtp', 'MailUi') -AllowedProcessPath "$path\Rnwood.Smtp4dev.exe"
    if (-not (Test-Path "$path\Rnwood.Smtp4dev.exe")) {
        $zip = Join-Path $Work 'smtp4dev.zip'
        Get-SetupDownload -Url 'https://github.com/rnwood/smtp4dev/releases/download/3.15.0/Rnwood.Smtp4dev-win-x64-3.15.0.zip' `
            -Path $zip -Hash '9ed061316772445d54f09b4bd69b97dc79e830312c8f32a8c1717c24fd7068dc'
        Expand-Archive -LiteralPath $zip -DestinationPath $path -Force
    }
    @{
        ServerOptions = @{
            Urls = "http://localhost:$($ports.MailUi)"; Port = $ports.Smtp; AllowRemoteConnections = $false
            Database = (Join-Path $path 'messages.db'); LockSettings = $true
            ImapPort = $null; Pop3Port = $null
        }
        RelayOptions = @{ SmtpServer = ''; AutomaticEmails = @(); AutomaticRelayExpression = '' }
    } | ConvertTo-Json -Depth 5 | Set-Content "$path\appsettings.json" -Encoding UTF8
    $action = New-ScheduledTaskAction -Execute "$path\Rnwood.Smtp4dev.exe" -WorkingDirectory $path
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $taskSettings = New-ScheduledTaskSettingsSet -RestartCount 5 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero)
    Register-ScheduledTask -TaskName 'AdoServerLabAutoOrchestrator-SmtpCapture' -Action $action -Trigger $trigger `
        -Principal $principal -Settings $taskSettings -Force | Out-Null
    if (-not (Get-NetFirewallRule -Name 'AdoServerLabAutoOrchestrator-NoRelay' -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -Name 'AdoServerLabAutoOrchestrator-NoRelay' -DisplayName 'Block lab SMTP relay to Internet' `
            -Direction Outbound -Program "$path\Rnwood.Smtp4dev.exe" -RemoteAddress Internet -Action Block | Out-Null
    }
    Start-ScheduledTask -TaskName 'AdoServerLabAutoOrchestrator-SmtpCapture'
}

function Configure-GuestDevOps {
    param([psobject]$Plan, [string]$Work, [string]$Path)
    Assert-ExistingSql -Plan $Plan
    $databases = Invoke-SetupSql -Plan $Plan -Query "SELECT name FROM sys.databases WHERE name LIKE 'Tfs[_]%' OR name LIKE 'AzureDevOps[_]%'"
    if ($databases.Rows.Count -gt 0) {
        throw 'DevOps databases already exist. Refusing to overwrite or repeat a partially completed configuration. Review the DevOps logs; this script is not a database recovery tool.'
    }
    $ports = Get-SetupPorts -Plan $Plan
    Assert-SetupPortsAvailable -Plan $Plan -Names @('Https', 'Ssh')
    $tool = Get-SetupTfsConfig
    $ini = Join-Path $Work 'devops.ini'
    if (Test-Path -LiteralPath $ini) { Remove-Item -LiteralPath $ini -Force }
    $emailEnabled = if ($Plan.Email -eq 'Capture') { 'True' } else { 'False' }
    Invoke-SetupTfsConfig -Tool $tool -Arguments @(
        'unattend', '/create', '/type:NewServerBasic', "/unattendfile:$ini", "/inputs:SmtpEmailEnabled=$emailEnabled")
    $text = Get-Content -LiteralPath $ini -Raw
    $fqdn = Get-SetupHostName -Plan $Plan
    Assert-SetupHostResolution -Plan $Plan
    $firewallProfile = Get-SetupFirewallProfile -Plan $Plan
    if (-not $Plan.CertificateThumbprint) {
        $certificate = New-SelfSignedCertificate -DnsName $fqdn -CertStoreLocation 'Cert:\LocalMachine\My' -NotAfter (Get-Date).AddYears(1)
        $Plan.CertificateThumbprint = $certificate.Thumbprint
        Save-SetupState -State $Plan -Path $Path
    }
    $certificate = Get-Item -LiteralPath "Cert:\LocalMachine\My\$($Plan.CertificateThumbprint)"
    $root = New-Object Security.Cryptography.X509Certificates.X509Store('Root', 'LocalMachine')
    try {
        $root.Open('ReadWrite')
        $root.Add([Security.Cryptography.X509Certificates.X509Certificate2]::new($certificate.RawData))
    }
    finally { $root.Close() }
    $text = Get-SetupDevOpsIniText -Text $text -Plan $Plan -Thumbprint $certificate.Thumbprint
    $text | Set-Content -LiteralPath $ini -Encoding UTF8
    Set-SetupLoopbackHost -Plan $Plan
    Invoke-SetupTfsConfig -Tool $tool -Arguments @('unattend', '/configure', "/unattendfile:$ini", '/verify')
    Invoke-SetupTfsConfig -Tool $tool -Arguments @('unattend', '/configure', "/unattendfile:$ini")
    if (-not (Get-NetFirewallRule -Name 'AdoServerLabAutoOrchestrator-Https' -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -Name 'AdoServerLabAutoOrchestrator-Https' -DisplayName "Lab DevOps HTTPS - $firewallProfile local subnet" `
            -Direction Inbound -Protocol TCP -LocalPort $ports.Https -Profile $firewallProfile -RemoteAddress LocalSubnet -Action Allow | Out-Null
    }
    else { Set-NetFirewallRule -Name 'AdoServerLabAutoOrchestrator-Https' -Protocol TCP -LocalPort $ports.Https -Profile $firewallProfile -RemoteAddress LocalSubnet -ErrorAction Stop | Out-Null }
    if (-not (Get-NetFirewallRule -Name 'AdoServerLabAutoOrchestrator-Ssh' -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -Name 'AdoServerLabAutoOrchestrator-Ssh' -DisplayName "Lab DevOps Git SSH - $firewallProfile local subnet" `
            -Direction Inbound -Protocol TCP -LocalPort $ports.Ssh -Profile $firewallProfile -RemoteAddress LocalSubnet -Action Allow | Out-Null
    }
    else { Set-NetFirewallRule -Name 'AdoServerLabAutoOrchestrator-Ssh' -Protocol TCP -LocalPort $ports.Ssh -Profile $firewallProfile -RemoteAddress LocalSubnet -ErrorAction Stop | Out-Null }
    return ((Get-SetupJoinMode -Plan $Plan) -eq 'Workgroup' -and (Get-SetupHostName -Plan $Plan) -ne $Plan.ComputerName)
}

function Get-SetupDevOpsIniText {
    param([string]$Text, [psobject]$Plan, [string]$Thumbprint)
    $ports = Get-SetupPorts -Plan $Plan
    $fqdn = Get-SetupHostName -Plan $Plan
    $values = [ordered]@{
        InstallSqlExpress = 'False'; SqlInstance = $Plan.SqlInstance; StartTrial = 'True'
        ConfigureSearch = 'False'; CreateInitialCollection = 'True'; CollectionName = 'DefaultCollection'
        UrlHostNameAlias = $fqdn; WebSiteVDirName = 'tfs'; PublicUrl = (Get-SetupDevOpsUrl -Plan $Plan)
        EnableSshService = 'True'; SshPort = [string]$ports.Ssh
        SmtpEmailEnabled = $(if ($Plan.Email -eq 'Capture') { 'True' } else { 'False' })
        SiteBindings = "https:*:$($ports.Https):${fqdn}:My:$Thumbprint"
    }
    foreach ($entry in $values.GetEnumerator()) { $Text = Set-SetupIniValue -Text $Text -Names @($entry.Key) -Value $entry.Value }
    if ($Plan.Email -eq 'Capture') {
        $Text = Set-SetupIniValue -Text $Text -Names @('SmtpServer', 'SmtpServerName') -Value 'localhost'
        $Text = Set-SetupIniValue -Text $Text -Names @('SmtpPort', 'SmtpServerPort') -Value ([string]$ports.Smtp)
        $Text = Set-SetupIniValue -Text $Text -Names @('SmtpEmailFromAddress', 'SmtpFromAddress', 'SmtpEmailAddress') -Value "devops@$(Get-SetupMailDomain -Plan $Plan)"
    }
    return $Text
}

function Install-GuestPatch {
    param([psobject]$Plan, [string]$Work)
    $selected = Get-SelectedSetupPatch -Plan $Plan
    if ($null -eq $selected) { throw 'Patch installation was called despite a saved Skip choice.' }
    $marker = Join-Path $Work 'patch.sha256'
    if (Test-Path -LiteralPath $marker) {
        if ((Get-Content $marker -Raw).Trim() -eq $selected.Hash) { return $false }
        throw 'A different patch completion marker already exists. This setup does not switch or downgrade patches on an existing deployment.'
    }
    $patch = Join-Path $Work 'DevOpsPatch.exe'
    Write-SetupProgress -Work $Work -Message "Installing $($Plan.Version) Patch $($selected.Number)."
    Get-SetupDownload -Url $selected.Url -Path $patch -Hash $selected.Hash -MicrosoftSigned
    $reboot = Invoke-SetupInstaller -Path $patch -Arguments 'Patch -force -nowait'
    $selected.Hash | Set-Content -LiteralPath $marker -Encoding ASCII
    return $reboot
}

function Assert-SelectedPatchCompletion {
    param([psobject]$Plan, [string]$Work)
    $selected = Get-SelectedSetupPatch -Plan $Plan
    if ($null -eq $selected) { return }
    if ((Get-Content (Join-Path $Work 'patch.sha256') -Raw).Trim() -ne $selected.Hash) {
        throw "Selected $($Plan.Version) Patch $($selected.Number) did not complete."
    }
}

function Wait-GuestHttp {
    param([string]$Url, [switch]$Json)
    $deadline = (Get-Date).AddMinutes(10)
    do {
        try {
            if ($Json) { return Invoke-RestMethod -Uri $Url -UseDefaultCredentials -TimeoutSec 30 }
            return Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 30
        }
        catch [Net.WebException] {
            if ((Get-Date) -ge $deadline) { throw }
            Write-Warning "HTTP service not ready: $($_.Exception.Message). Retrying."
            Start-Sleep -Seconds 15
        }
    } while ($true)
}

function Wait-GuestSsh {
    param([psobject]$Plan, [string]$Work)
    $port = (Get-SetupPorts -Plan $Plan).Ssh
    $deadline = (Get-Date).AddMinutes(10)
    do {
        $listeners = @(Get-NetTCPConnection -ErrorAction Stop | Where-Object { $_.State -eq 'Listen' -and $_.LocalPort -eq $port })
        if ($listeners.Count) {
            Write-SetupProgress -Work $Work -Message "DevOps Git SSH is listening on TCP port $port."
            return
        }
        $remainingMilliseconds = ($deadline - (Get-Date)).TotalMilliseconds
        if ($remainingMilliseconds -le 0) {
            throw "DevOps Git SSH did not start listening on TCP port $port within 10 minutes. Check the SSH service and configuration logs before resuming verification."
        }
        Write-SetupProgress -Work $Work -Message "Waiting for DevOps Git SSH on TCP port $port; retrying in up to 15 seconds."
        $delayMilliseconds = [int][Math]::Min(15000, [Math]::Max(1, [Math]::Floor($remainingMilliseconds)))
        Start-Sleep -Milliseconds $delayMilliseconds
    } while ($true)
}

function Test-GuestInstallation {
    param([psobject]$Plan, [string]$Work)
    Assert-ExistingSql -Plan $Plan
    if ($Plan.Components -ne 'DevOpsOnly') { Assert-GuestSsms }
    if ($Plan.Components -eq 'SqlOnly') { return }
    $databases = Invoke-SetupSql -Plan $Plan -Query "SELECT name, state_desc FROM sys.databases WHERE name IN ('AzureDevOps_Configuration','AzureDevOps_DefaultCollection','Tfs_Configuration','Tfs_DefaultCollection')"
    Assert-GuestDevOpsDatabases -Databases $databases
    $ports = Get-SetupPorts -Plan $Plan
    $apiVersion = (Get-SetupRelease -Version $Plan.Version).ApiVersion
    $projects = Wait-GuestHttp -Url "$(Get-SetupDevOpsUrl -Plan $Plan)/DefaultCollection/_apis/projects?api-version=$apiVersion" -Json
    if ($null -eq $projects.PSObject.Properties['count'] -or $null -eq $projects.PSObject.Properties['value']) {
        throw 'Projects API response does not contain count and value.'
    }
    Wait-GuestSsh -Plan $Plan -Work $Work
    Assert-SelectedPatchCompletion -Plan $Plan -Work $Work
    if ($Plan.Email -eq 'Capture') {
        $web = Wait-GuestHttp -Url "http://localhost:$($ports.MailUi)"
        if ($web.StatusCode -ne 200) { throw 'SMTP capture UI is unhealthy.' }
        $smtp = New-Object Net.Mail.SmtpClient('localhost', $ports.Smtp)
        $mailDomain = Get-SetupMailDomain -Plan $Plan
        $message = New-Object Net.Mail.MailMessage("devops@$mailDomain", "lab@$mailDomain")
        try {
            $message.Subject = 'Guest setup SMTP capture test'
            $message.Body = 'Test-only message; no external relay is configured.'
            $smtp.Send($message)
        }
        finally { $message.Dispose(); $smtp.Dispose() }
    }
}

function Assert-GuestDevOpsDatabases {
    param([Data.DataTable]$Databases)
    $names = @($Databases.Rows | ForEach-Object { $_.name })
    $paired = ($names -contains 'AzureDevOps_Configuration' -and $names -contains 'AzureDevOps_DefaultCollection') -or
        ($names -contains 'Tfs_Configuration' -and $names -contains 'Tfs_DefaultCollection')
    if ($Databases.Rows.Count -ne 2 -or -not $paired -or
        @($Databases.Rows | Where-Object state_desc -ne 'ONLINE').Count -ne 0) {
        throw 'Expected exactly one matching AzureDevOps_ or legacy Tfs_ configuration/default collection database pair, both ONLINE. Check database names and states.'
    }
}

function Invoke-GuestSetup {
    param([string]$Path)
    $ErrorActionPreference = 'Stop'
    Set-StrictMode -Version Latest
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $work = Split-Path -Parent $Path
    if ($work -ne (Join-Path $env:ProgramData 'AdoServerLabAutoOrchestrator')) { throw 'Use the protected ProgramData\AdoServerLabAutoOrchestrator state directory.' }
    $mutex = New-Object Threading.Mutex($false, 'Global\AdoServerLabAutoOrchestrator')
    $acquired = $false
    $transcript = $false
    $state = $null
    try {
        $acquired = $mutex.WaitOne(0)
        if (-not $acquired) { throw 'Another setup worker is already running.' }
        $state = Read-SetupState -Path $Path
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        if ($identity.User.Value -ne $state.SetupSid) { throw 'Run the worker as the original setup account.' }
        $computer = Get-CimInstance Win32_ComputerSystem
        Assert-SetupMachineIdentity -Plan $state -Computer $computer
        if ($state.Status -eq 'Failed') { throw 'Previous setup failed. Repair the reported error and use Setup-Server.ps1 -Resume.' }
        if ($state.Status -eq 'Completed') {
            Unregister-ScheduledTask -TaskName 'AdoServerLabAutoOrchestrator-Resume' -Confirm:$false
            return
        }
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        Assert-SetupOperatingSystem -Version $state.Version -Os $os -AllowUnsupportedOs:(Get-SetupAllowUnsupportedOs -Plan $state)
        Assert-SetupClientOptions -Plan $state -Os $os
        $logs = Join-Path $work 'Logs'
        New-Item -ItemType Directory -Path $logs -Force | Out-Null
        Start-Transcript -Path (Join-Path $logs "setup-$((Get-Date).ToString('yyyyMMdd-HHmmss')).log") | Out-Null
        $transcript = $true
        $state.Status = 'Running'; $state.LastError = ''
        Initialize-SetupPorts -Plan $state
        if ($state.Components -ne 'SqlOnly') {
            $ports = Get-SetupPorts -Plan $state
            Write-SetupProgress -Work $work -Message "Saved TCP ports: HTTPS=$($ports.Https), Git SSH=$($ports.Ssh), SMTP=$($ports.Smtp), mail UI=$($ports.MailUi)."
        }
        Save-SetupState -State $state -Path $Path
        if ($state.RebootAfter) {
            $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')
            if ($boot -eq $state.RebootAfter) {
                Write-Host 'A previously requested restart has not happened yet. Restarting before the next stage.'
                Restart-Computer -Force
                return
            }
            $state.RebootAfter = ''
            Save-SetupState -State $state -Path $Path
        }
        $steps = @(Get-SetupSteps -Plan $state)
        if ($state.Components -ne 'SqlOnly' -and $state.StageIndex -le [array]::IndexOf($steps, 'Configure') -and
            (Initialize-SetupClientIis -Os $os -Work $work)) {
            $state.RebootAfter = $os.LastBootUpTime.ToUniversalTime().ToString('o')
            $state.Status = 'RebootPending'
            Save-SetupState -State $state -Path $Path
            Write-SetupProgress -Work $work -Message 'Restarting for client IIS prerequisites; the saved installation stage has not advanced.'
            Stop-Transcript | Out-Null
            $transcript = $false
            Restart-Computer -Force
            return
        }
        while ($state.StageIndex -lt $steps.Count) {
            $stage = $steps[$state.StageIndex]
            Write-SetupProgress -Work $work -Message "Starting $stage"
            $reboot = $false
            switch ($stage) {
                'Sql' { $reboot = Install-GuestSql -Plan $state -Work $work }
                'DevOps' { Assert-ExistingSql -Plan $state; $reboot = Install-GuestDevOps -Plan $state -Work $work }
                'Smtp' { Install-GuestSmtp -Work $work -Plan $state }
                'Configure' { $reboot = Configure-GuestDevOps -Plan $state -Work $work -Path $Path }
                'Patch' { $reboot = Install-GuestPatch -Plan $state -Work $work }
                'Ssms' { $reboot = Install-GuestSsms -Work $work }
                'Verify' { Test-GuestInstallation -Plan $state -Work $work }
                default { throw "Unexpected stage: $stage" }
            }
            Complete-SetupStage -State $state -RebootRequired $reboot
            if ($reboot) {
                $state.RebootAfter = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')
            }
            Save-SetupState -State $state -Path $Path
            if ($reboot) {
                Write-Host 'Restarting the VM. The startup task will continue at the saved next stage.'
                Stop-Transcript | Out-Null
                $transcript = $false
                Restart-Computer -Force
                return
            }
        }
        $state.Status = 'Completed'
        Save-SetupState -State $state -Path $Path
        Unregister-ScheduledTask -TaskName 'AdoServerLabAutoOrchestrator-Resume' -Confirm:$false
        Write-Host "COMPLETED: $($state.Components), $($state.Version). No backups or VM images were created."
        if ($state.Components -ne 'SqlOnly') {
            $ports = Get-SetupPorts -Plan $state
            Write-Host "DevOps: $(Get-SetupDevOpsUrl -Plan $state)/DefaultCollection"
            Write-Host "DevOps Git SSH port: $($ports.Ssh)"
            if ($state.Email -eq 'Capture') { Write-Host "Mail capture: http://localhost:$($ports.MailUi) on this VM; SMTP localhost:$($ports.Smtp)." }
        }
    }
    catch {
        $failure = $_
        if ($acquired -and $null -ne $state -and $state.Status -ne 'Completed') {
            Write-SetupProgress -Work $work -Message "FAILED: $($failure.Exception.Message)"
            $state.Status = 'Failed'; $state.LastError = $failure.Exception.Message
            Save-SetupState -State $state -Path $Path
            Disable-ScheduledTask -TaskName 'AdoServerLabAutoOrchestrator-Resume' | Out-Null
        }
        throw $failure
    }
    finally {
        if ($transcript) { Stop-Transcript | Out-Null }
        if ($acquired) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

if ($MyInvocation.InvocationName -ne '.') { Invoke-GuestSetup -Path $StatePath }
