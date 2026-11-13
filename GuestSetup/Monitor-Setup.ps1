#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateRange(1, 3600)][int]$IntervalSeconds = 10,
    [ValidateRange(1, 1000)][int]$TailLines = 10,
    [switch]$Once
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$work = Join-Path $env:ProgramData 'AdoServerLabAutoOrchestrator'
$statePath = Join-Path $work 'state.json'
. (Join-Path $PSScriptRoot 'Resume-Setup.ps1')
Import-Module (Join-Path $PSScriptRoot 'Setup-Monitoring.psm1') -Force -ErrorAction Stop
do {
    if (-not $Once) { Clear-Host }
    Write-Host "AdoServerLabAutoOrchestrator read-only dashboard: $work. Press Ctrl+C to stop monitoring, not setup."
    $state = $null
    if (Test-Path -LiteralPath $statePath) {
        $state = Read-SetupState -Path $statePath
        $steps = @(Get-SetupSteps -Plan $state)
        $stage = if ($state.StageIndex -lt $steps.Count) { $steps[$state.StageIndex] } else { 'Complete' }
        Write-Host "`n[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] $($state.Version) / $($state.Components): $($state.Status); current stage: $stage"
        $patch = Get-SelectedSetupPatch -Plan $state
        Write-Host "Saved DevOps patch choice: $(if ($null -eq $patch) { 'Skip' } else { $patch.Number })"
        Write-Host "Saved membership: $(Get-SetupJoinMode -Plan $state); hostname: $(Get-SetupHostName -Plan $state)"
        $ports = Get-SetupPorts -Plan $state
        Write-Host "TCP ports: HTTPS=$($ports.Https); Git SSH=$($ports.Ssh); SMTP=$($ports.Smtp); mail UI=$($ports.MailUi)"
        if ($state.LastError) { Write-Warning $state.LastError }
    }
    else { Write-Warning "No saved setup found at $statePath." }
    Write-Host (Get-SetupMonitoringLogs -Work $work -Plan $state -TailLines $TailLines)
    if ($null -ne $state -and $state.Status -in @('Completed', 'Failed')) {
        Write-Host "Monitoring stopped: setup status is $($state.Status)."
        break
    }
    if (-not $Once) { Start-Sleep -Seconds $IntervalSeconds }
} while (-not $Once)
