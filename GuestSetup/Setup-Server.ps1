#requires -Version 5.1
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [ValidateSet('2020', '2022.1', '2022', '25H2', '26H2-RC')][string]$Version,
    [ValidateSet('Both', 'SqlOnly', 'DevOpsOnly')][string]$Components,
    [string]$DomainName,
    [ValidateSet('Domain', 'Workgroup')][string]$JoinMode = 'Domain',
    [string]$DnsHostName,
    [string]$SqlInstance,
    [ValidateSet('Capture', 'None')][string]$Email,
    [string]$Patch,
    [switch]$ListPatches,
    [pscredential]$Credential,
    [switch]$AcceptLicenseTerms,
    [switch]$AllowUnsupportedOs,
    [switch]$Resume,
    [switch]$CancelResume,
    [switch]$ValidateOnly
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$workerSource = Join-Path $PSScriptRoot 'Resume-Setup.ps1'
. $workerSource
if ($ListPatches) {
    if ($Resume -or $CancelResume -or $ValidateOnly) { throw 'Use -ListPatches separately from other setup modes.' }
    if (-not $Version) { $Version = Read-SetupChoice -Prompt 'Patch catalog version: 2020, 2022.1 (Update 1), 2022 (Update 2), 25H2 or 26H2-RC' -Choices @('2020', '2022.1', '2022', '25H2', '26H2-RC') -Default '25H2' }
    if ($Version -eq '26H2-RC') { Write-Warning '26H2 RC has no standalone patches in this catalog. 25H2 patches must not be used.' }
    Get-SetupPatchCatalog -Version $Version | Format-Table Number, Url, Notes -Wrap -AutoSize
    return
}
if ($ValidateOnly) {
    & (Join-Path $PSScriptRoot 'Test-GuestSetup.ps1')
    return
}
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Open Windows PowerShell as Administrator inside the target VM.'
}
$work = Join-Path $env:ProgramData 'AdoServerLabAutoOrchestrator'
$statePath = Join-Path $work 'state.json'
$taskName = 'AdoServerLabAutoOrchestrator-Resume'
if ($CancelResume) {
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($task) { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false }
    Write-Host 'Automatic resume removed. No installed software, databases or setup files were deleted.'
    return
}
if ($Resume) {
    if ($PSBoundParameters.ContainsKey('Patch') -or $PSBoundParameters.ContainsKey('JoinMode') -or
        $PSBoundParameters.ContainsKey('DnsHostName') -or $PSBoundParameters.ContainsKey('DomainName') -or
        $PSBoundParameters.ContainsKey('AllowUnsupportedOs')) {
        throw 'Resume preserves saved patch, join mode, hostname/domain and OS override choices. Select them only when starting a new plan.'
    }
    $state = Read-SetupState -Path $statePath
    if ($state.SetupSid -ne $identity.User.Value) { throw 'Resume using the original setup account.' }
    if ($state.Status -eq 'Completed') {
        Write-Host 'This setup already completed; no changes made.'
        return
    }
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    Assert-SetupOperatingSystem -Version $state.Version -Os $os -AllowUnsupportedOs:(Get-SetupAllowUnsupportedOs -Plan $state)
    Assert-SetupClientOptions -Plan $state -Os $os
    if ((Get-ScheduledTask -TaskName $taskName).State -eq 'Running') {
        throw 'The setup task is already running. Follow its logs rather than starting another attempt.'
    }
    $ownedInstallers = @(Get-CimInstance Win32_Process | Where-Object {
        $_.ExecutablePath -and
        $_.ExecutablePath.StartsWith("$work\", [StringComparison]::OrdinalIgnoreCase) -and
        $_.Name -match '^(SQL\d+-Developer|DevOpsSetup|DevOpsPatch|vs_SSMS|SSMS20-Setup)\.exe$'
    })
    if ($ownedInstallers.Count -gt 0) {
        throw "Previous setup child processes are still running (PIDs: $($ownedInstallers.ProcessId -join ', ')). Inspect them and stop only confirmed failed/stalled processes before retrying."
    }
    if (-not $PSCmdlet.ShouldProcess($env:COMPUTERNAME, 'Retry the saved setup plan; required reboots are automatic')) { return }
    Copy-SetupWorkerFiles -SourceFolder $PSScriptRoot -Work $work
    $state.Status = 'Pending'
    $state.LastError = ''
    Save-SetupState -State $state -Path $statePath
    Enable-ScheduledTask -TaskName $taskName | Out-Null
    Start-ScheduledTask -TaskName $taskName
    Write-Host "Resume started. Follow $work\Logs and state.json."
    return
}
if (Test-Path -LiteralPath $statePath) {
    throw 'A saved setup already exists. Use -Resume after repairing a failure, or -CancelResume to remove its task. Do not overwrite a plan containing installed software/data.'
}
$computer = Get-CimInstance Win32_ComputerSystem
if ($computer.DomainRole -ge 4) { throw 'Domain controllers are not supported.' }
if ($JoinMode -eq 'Domain' -and -not $computer.PartOfDomain) { throw 'Domain mode requires an already domain-joined VM. Join/reboot first, or explicitly select -JoinMode Workgroup.' }
if ($JoinMode -eq 'Workgroup' -and $computer.PartOfDomain) { throw 'Workgroup mode requires a non-domain-joined VM. This script does not change domain membership.' }
$os = Get-CimInstance Win32_OperatingSystem
if (-not $Version) { $Version = Read-SetupChoice -Prompt 'DevOps version: 2020, 2022.1 (Update 1), 2022 (Update 2), 25H2 or 26H2-RC' -Choices @('2020', '2022.1', '2022', '25H2', '26H2-RC') -Default '25H2' }
Assert-SetupOperatingSystem -Version $Version -Os $os -AllowUnsupportedOs:$AllowUnsupportedOs
if ($Version -eq '2022.1') { Write-Warning '2022.1 is older Update 1, for controlled lab reproduction. Update 2 patches and later security fixes are not included.' }
if ($Version -eq '26H2-RC') { Write-Warning '26H2 is a Release Candidate, not the final release. Use a disposable test deployment. This workflow supports fresh setup only, not RC-to-final upgrades.' }
if (-not $Components) { $Components = Read-SetupChoice -Prompt 'Install Both, SqlOnly, or DevOpsOnly' -Choices @('Both', 'SqlOnly', 'DevOpsOnly') -Default 'Both' }
if ($os.ProductType -eq 1) {
    Write-Warning 'Client Windows installation is for evaluation/personal use only. Azure DevOps Server Proxy is not supported. Review Windows lifecycle, ESU and security requirements.'
    if ($Version -eq '2020') { Write-Warning 'Windows 10 uses archived SSMS 20.2.1 instead of SSMS 22; older Windows/SSMS versions can lack current security fixes.' }
    if ($Components -ne 'SqlOnly') { Get-SetupClientIisFeatures -Os $os | Out-Null }
}
if ($JoinMode -eq 'Workgroup') {
    if ($DomainName) { throw 'Do not supply -DomainName in Workgroup mode; use -DnsHostName for an optional existing DNS record.' }
    $DomainName = $computer.Domain
}
elseif (-not $DomainName) {
    $answer = Read-Host "Existing domain name [$($computer.Domain)]"
    $DomainName = if ([string]::IsNullOrWhiteSpace($answer)) { $computer.Domain } else { $answer.Trim() }
}
if (-not $DnsHostName) {
    $DnsHostName = if ($JoinMode -eq 'Domain') { "$($computer.Name).$DomainName" } else { $computer.Name }
}
if ($Components -eq 'DevOpsOnly' -and -not $SqlInstance) {
    $answer = Read-Host 'Existing local SQL instance [localhost], e.g. localhost\SQL2025'
    $SqlInstance = if ([string]::IsNullOrWhiteSpace($answer)) { 'localhost' } else { $answer.Trim() }
}
if (-not $SqlInstance) { $SqlInstance = 'localhost' }
if ($Components -eq 'SqlOnly') { $Email = 'None' }
elseif (-not $Email -and $os.ProductType -eq 1 -and [int]$os.BuildNumber -lt 22000) {
    Write-Warning 'Local SMTP capture is not offered on Windows 10 because its .NET 10 runtime does not support every documented Windows 10 version. Email is None.'
    $Email = 'None'
}
elseif (-not $Email) { $Email = Read-SetupChoice -Prompt 'Test SMTP Capture on this VM, or None' -Choices @('Capture', 'None') -Default 'Capture' }
if ($Components -eq 'SqlOnly') {
    if ($Patch -and $Patch -ne 'Skip') { throw 'SqlOnly does not install DevOps patches; omit -Patch or choose Skip.' }
    $Patch = 'Skip'
}
else {
    if ($Version -eq '26H2-RC' -and -not $Patch) { $Patch = 'Skip' }
    if (-not $Patch) {
        $catalog = @(Get-SetupPatchCatalog -Version $Version)
        $catalog | Format-Table Number, Notes -Wrap -AutoSize | Out-Host
        $Patch = Read-SetupChoice -Prompt 'DevOps patch: Latest, Skip, or a listed number' `
            -Choices (@('Latest', 'Skip') + @($catalog | Where-Object Installable | ForEach-Object Number)) -Default 'Latest'
    }
    $Patch = Resolve-SetupPatchChoice -Version $Version -Choice $Patch
    if ($Version -eq '26H2-RC') { Write-Warning 'No standalone 26H2 RC patches are cataloged. Latest resolves to Skip; 25H2 patches must not be used.' }
    elseif ($Patch -eq 'Skip') { Write-Warning 'Patching is skipped. Base installation media may lack later security fixes.' }
    else {
        $selected = Get-SetupPatchCatalog -Version $Version | Where-Object Number -eq $Patch
        if ($Patch -ne (Get-SetupRelease -Version $Version).LatestPatchNumber) {
            Write-Warning 'An older patch may lack later security fixes. This is for controlled lab reproduction, not production.'
        }
        if ($selected.Notes) { Write-Warning $selected.Notes }
    }
}
if (-not $AcceptLicenseTerms) {
    throw 'Review the README and Microsoft Developer/evaluation license terms, then rerun with -AcceptLicenseTerms.'
}
$plan = [pscustomobject]@{
    SchemaVersion = 6
    AllowUnsupportedOs = [bool]$AllowUnsupportedOs
    JoinMode = $JoinMode
    DnsHostName = $DnsHostName.Trim().ToLowerInvariant()
    Ports = $null
    PatchSelection = $Patch
    Version = $Version
    Components = $Components
    DomainName = $DomainName.ToLowerInvariant()
    ComputerName = $env:COMPUTERNAME
    SqlInstance = $SqlInstance
    Email = $Email
    SetupAccount = $identity.Name
    SetupSid = $identity.User.Value
    StageIndex = 0
    Status = 'Pending'
    LastError = ''
    CertificateThumbprint = ''
    RebootAfter = ''
}
Assert-SetupPlan -Plan $plan
Assert-SetupClientOptions -Plan $plan -Os $os
Assert-SetupMachineIdentity -Plan $plan -Computer $computer
if ($JoinMode -eq 'Domain') {
    Test-ComputerSecureChannel -ErrorAction Stop | ForEach-Object { if (-not $_) { throw 'The domain secure channel is unhealthy. Repair domain connectivity first.' } }
}
if ($Components -ne 'SqlOnly') {
    Assert-SetupHostResolution -Plan $plan
    $null = Get-SetupFirewallProfile -Plan $plan
}
$release = Get-SetupRelease -Version $Version
if ($Components -ne 'DevOpsOnly' -and $SqlInstance -ne 'localhost') {
    throw 'SQL installation uses the default local instance. Use DevOpsOnly to target an existing local named instance.'
}
if ($Components -ne 'SqlOnly' -and (Get-InstalledDevOpsTools).Count -gt 0) {
    throw 'DevOps is already installed. This script configures a fresh server, not an existing-server upgrade. Existing DevOps installations are left untouched.'
}
if (Get-Service -Name (Get-SqlServiceName -Instance $SqlInstance) -ErrorAction SilentlyContinue) {
    Assert-ExistingSql -Plan $plan
}
elseif ($Components -eq 'DevOpsOnly') { throw 'DevOpsOnly requires an existing, running and supported local SQL instance.' }
Initialize-SetupPorts -Plan $plan
Assert-SetupPlan -Plan $plan
if ($Components -ne 'SqlOnly') {
    $ports = Get-SetupPorts -Plan $plan
    Write-Host "TCP ports: HTTPS=$($ports.Https); Git SSH=$($ports.Ssh); SMTP=$($ports.Smtp); mail UI=$($ports.MailUi)."
    Write-Host "Planned DevOps URL: $(Get-SetupDevOpsUrl -Plan $plan)"
}
Write-Host "Plan: $Components; DevOps $Version / SQL $($release.SqlYear); $JoinMode $DomainName; DNS hostname $($plan.DnsHostName); email $Email; patch $Patch."
if ($AllowUnsupportedOs) { Write-Warning 'Saved lab acknowledgement: OS version/build validation may be bypassed on this run and every reboot/resume. This does not make the OS supported.' }
Write-Warning 'This installs on the OS disk, performs automatic reboots, and creates no backups or VM images.'
if (-not $PSCmdlet.ShouldProcess($env:COMPUTERNAME, 'Install/configure the selected software and automatically resume after reboots')) { return }
if (-not $Credential) {
    $Credential = Read-SetupCredential -AccountName $identity.Name
}
if (-not $Credential) { throw 'Setup credentials are required for automatic resume.' }
$account = New-Object Security.Principal.NTAccount($Credential.UserName)
if ($account.Translate([Security.Principal.SecurityIdentifier]).Value -ne $identity.User.Value) {
    throw 'Use the same account running this elevated PowerShell window.'
}
New-Item -ItemType Directory -Path $work -Force | Out-Null
$acl = New-Object Security.AccessControl.DirectorySecurity
$acl.SetAccessRuleProtection($true, $false)
foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
        [Security.Principal.SecurityIdentifier]::new($sid),
        'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
}
Set-Acl -LiteralPath $work -AclObject $acl
$worker = Join-Path $work 'Resume-Setup.ps1'
Copy-SetupWorkerFiles -SourceFolder $PSScriptRoot -Work $work
$action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
    -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$worker`" -StatePath `"$statePath`""
$trigger = New-ScheduledTaskTrigger -AtStartup
$trigger.Delay = 'PT60S'
$taskSettings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 8) `
    -MultipleInstances IgnoreNew -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
$password = $Credential.GetNetworkCredential().Password
try {
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $taskSettings `
        -User $Credential.UserName -Password $password -RunLevel Highest -Force | Out-Null
}
finally { $password = $null; $Credential = $null }
try {
    Save-SetupState -State $plan -Path $statePath
    Start-ScheduledTask -TaskName $taskName
}
catch {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    throw
}
Write-Host "Setup started in the background. Logs and progress: $work"
Write-Host 'The VM may restart and disconnect your session. The task removes itself after successful completion.'
