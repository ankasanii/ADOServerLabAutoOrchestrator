#requires -Version 5.1
[CmdletBinding()]
param([ValidateSet('Metadata', 'Snapshot')][string]$Mode)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
$guest = Join-Path $PSScriptRoot 'GuestSetup'
. (Join-Path $guest 'Resume-Setup.ps1')
Import-Module (Join-Path $guest 'Setup-Monitoring.psm1') -Force -ErrorAction Stop

function Get-UiSnapshot {
    $work = Join-Path $env:ProgramData 'AdoServerLabAutoOrchestrator'
    $path = Join-Path $work 'state.json'
    $plan = $null
    $result = [ordered]@{
        HasState = $false; Status = 'NotStarted'; Summary = 'No saved setup on this VM.'
        CanResume = $false; Progress = 0; Logs = ''; Error = ''
    }
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $plan = Read-SetupState -Path $path
        Assert-SetupPlan -Plan $plan
        $steps = @(Get-SetupSteps -Plan $plan)
        $stage = if ($plan.StageIndex -lt $steps.Count) { $steps[$plan.StageIndex] } else { 'Complete' }
        $result.HasState = $true
        $result.Status = $plan.Status
        $result.Progress = [int](100 * $plan.StageIndex / $steps.Count)
        $ports = Get-SetupPorts -Plan $plan
        $endpoint = if ($plan.Components -eq 'SqlOnly') { 'SQL-only plan; no DevOps URL.' } else { Get-SetupDevOpsUrl -Plan $plan }
        $result.Summary = "$($plan.Version) / $($plan.Components) / $($plan.Email) / $(Get-SetupJoinMode -Plan $plan)`r`nStage: $stage ($($plan.StageIndex)/$($steps.Count)); patch: $($plan.PatchSelection)`r`n$endpoint`r`nSaved ports: HTTPS $($ports.Https), SSH $($ports.Ssh), SMTP $($ports.Smtp), mail UI $($ports.MailUi)"
        $result.Error = $plan.LastError
        if ($plan.Version -eq '26H2-RC') { $result.Summary += "`r`n26H2 RELEASE CANDIDATE: pre-release lab setup; no standalone RC patches cataloged." }
        foreach ($name in @('Version', 'Components', 'Email', 'PatchSelection', 'DomainName')) { $result[$name] = $plan.$name }
        $result.JoinMode = Get-SetupJoinMode -Plan $plan
        $result.DnsHostName = Get-SetupHostName -Plan $plan
        $result.AllowUnsupportedOs = Get-SetupAllowUnsupportedOs -Plan $plan
        if ($result.AllowUnsupportedOs) { $result.Summary += "`r`nLAB OVERRIDE SAVED: OS version/build validation may be bypassed; installation may be unsupported." }
        if ($plan.Status -ne 'Completed') {
            $tasks = @(Get-ScheduledTask -ErrorAction Stop | Where-Object { $_.TaskName -eq 'AdoServerLabAutoOrchestrator-Resume' -and $_.TaskPath -eq '\' })
            $result.CanResume = $tasks.Count -eq 1 -and $tasks[0].State -ne 'Running' -and
                $plan.SetupSid -eq [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        }
    }
    $result.Logs = Get-SetupMonitoringLogs -Work $work -Plan $plan -TailLines 40
    [pscustomobject]$result
}

if ($Mode -eq 'Metadata') {
    $computer = Get-CimInstance Win32_ComputerSystem
    $os = Get-CimInstance Win32_OperatingSystem
    $releases = @(foreach ($version in @('2020', '2022.1', '2022', '26H2-RC', '25H2')) {
        $release = Get-SetupRelease -Version $version
        $supported = $true
        $reason = ''
        try { Assert-SetupOperatingSystem -Version $version -Os $os }
        catch [NotSupportedException] { $supported = $false; $reason = $_.Exception.Message }
        $canOverride = $false
        $overrideReason = ''
        if (-not $supported) {
            try {
                Assert-SetupOperatingSystem -Version $version -Os $os -AllowUnsupportedOs -WarningAction SilentlyContinue
                $canOverride = $true
            }
            catch [NotSupportedException] { $overrideReason = $_.Exception.Message }
        }
        [pscustomobject]@{
            Version = $version; SqlYear = $release.SqlYear; Supported = $supported
            UnsupportedReason = $reason
            CanOverrideOs = $canOverride; OverrideBlockedReason = $overrideReason
            Patches = @(Get-SetupPatchCatalog -Version $version | Select-Object Number, Installable, Notes)
        }
    })
    [pscustomobject]@{
        Domain = $computer.Domain; Account = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        ServerAllowed = $computer.DomainRole -lt 4 -and $os.ProductType -in @(1, 3)
        ClientOs = $os.ProductType -eq 1
        LegacySsms = $os.ProductType -eq 1 -and [int]$os.BuildNumber -lt 22000
        JoinedDomain = [bool]$computer.PartOfDomain; ComputerName = $computer.Name
        Os = $os.Caption; Releases = $releases
    } | ConvertTo-Json -Depth 6 -Compress
}
else { Get-UiSnapshot | ConvertTo-Json -Depth 4 -Compress }
