#requires -Version 5.1

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module -Name (Join-Path $PSScriptRoot 'Setup-Releases.psm1') -DisableNameChecking -ErrorAction Stop

function Resolve-SetupPatchChoice {
    param([string]$Version, [string]$Choice)
    if ($Choice -eq 'Skip') { return 'Skip' }
    if ($Choice -eq 'Latest') { return (Get-SetupRelease -Version $Version).LatestPatchNumber }
    $match = @(Get-SetupPatchCatalog -Version $Version | Where-Object Number -eq $Choice)
    if ($match.Count -ne 1) { throw "Invalid patch '$Choice' for $Version. Choose Latest, Skip, or a listed patch number." }
    if (-not $match[0].Installable) { throw "$Version Patch $Choice requires manual pipeline task uploads; it is not a standalone server patch and cannot be selected by this setup. Review its release notes." }
    return $match[0].Number
}

function Get-SelectedSetupPatch {
    param([psobject]$Plan)
    $choice = if ($Plan.SchemaVersion -ge 3) { $Plan.PatchSelection } elseif ($Plan.Version -eq '26H2-RC') { 'Skip' } elseif ($Plan.Version -eq '2022.1') { '4' } elseif ($Plan.Version -eq '2022') { '12' } elseif ($Plan.Version -eq '25H2') { '9' } else { '19' }
    if ($Plan.Components -eq 'SqlOnly' -or $choice -eq 'Skip') { return $null }
    $number = Resolve-SetupPatchChoice -Version $Plan.Version -Choice $choice
    return Get-SetupPatchCatalog -Version $Plan.Version | Where-Object Number -eq $number
}

function Get-SetupJoinMode {
    param([psobject]$Plan)
    if ($Plan.SchemaVersion -ge 5) { return $Plan.JoinMode }
    return 'Domain'
}

function Get-SetupHostName {
    param([psobject]$Plan)
    if ($Plan.SchemaVersion -ge 5) { return $Plan.DnsHostName }
    return "$($Plan.ComputerName.ToLowerInvariant()).$($Plan.DomainName)"
}

function Get-SetupAllowUnsupportedOs {
    param([psobject]$Plan)
    if ($Plan.SchemaVersion -ge 6) { return $Plan.AllowUnsupportedOs }
    return $false
}

function Assert-SetupPlan {
    param([psobject]$Plan)
    if ($Plan.SchemaVersion -notin @(1, 2, 3, 4, 5, 6)) { throw 'Unsupported saved setup schema.' }
    if ($Plan.SchemaVersion -ge 6 -and $Plan.AllowUnsupportedOs -isnot [bool]) {
        throw 'Saved AllowUnsupportedOs must be a Boolean acknowledgement.'
    }
    if ($Plan.SchemaVersion -ge 4 -and $null -ne $Plan.Ports) {
        $seen = @()
        foreach ($name in @('Https', 'Ssh', 'Smtp', 'MailUi')) {
            $port = $Plan.Ports.$name
            if (($port -isnot [int] -and $port -isnot [long]) -or $port -lt 1 -or $port -gt 65535 -or $seen -contains $port) {
                throw 'Saved ports must be distinct integer TCP ports from 1 through 65535.'
            }
            $seen += $port
        }
    }
    Get-SetupRelease -Version $Plan.Version | Out-Null
    if ($Plan.Components -notin @('Both', 'SqlOnly', 'DevOpsOnly')) { throw 'Invalid components selection.' }
    if ($Plan.SchemaVersion -ge 3) {
        $choice = Resolve-SetupPatchChoice -Version $Plan.Version -Choice $Plan.PatchSelection
        if ($choice -cne $Plan.PatchSelection -or ($Plan.Components -eq 'SqlOnly' -and $choice -ne 'Skip')) {
            throw 'Saved patch selection must be a resolved patch number or Skip; SqlOnly requires Skip.'
        }
    }
    if ($Plan.Email -notin @('Capture', 'None') -or ($Plan.Components -eq 'SqlOnly' -and $Plan.Email -ne 'None')) { throw 'Invalid email selection.' }
    $mode = Get-SetupJoinMode -Plan $Plan
    if ($mode -notin @('Domain', 'Workgroup')) { throw 'Invalid saved join mode.' }
    if ($mode -eq 'Domain') {
        if ($Plan.DomainName -notmatch '^(?=.{3,253}$)([a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}$') { throw 'Invalid existing domain name.' }
    }
    elseif ($Plan.DomainName -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,14}$') { throw 'Invalid saved workgroup name.' }
    if ($Plan.ComputerName -notmatch '^[a-zA-Z0-9][a-zA-Z0-9-]{0,14}$') { throw 'Invalid computer name.' }
    if ($Plan.SchemaVersion -ge 5) {
        $hostName = Get-SetupHostName -Plan $Plan
        $address = $null
        if ($hostName -notmatch '^(?=.{1,253}$)[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$' -or
            $hostName -eq 'localhost' -or [Net.IPAddress]::TryParse($hostName, [ref]$address) -or
            $hostName -cne $hostName.ToLowerInvariant()) {
            throw 'DNS hostname must be a lowercase DNS/VM name, not an IP address, URL, wildcard or localhost.'
        }
        if ($mode -eq 'Domain' -and $hostName -ne "$($Plan.ComputerName).$($Plan.DomainName)".ToLowerInvariant()) {
            throw 'Domain mode preserves the computer joined-domain hostname; custom DNS is supported in Workgroup mode only.'
        }
        if ($mode -eq 'Workgroup' -and $Plan.SetupAccount -notlike "$($Plan.ComputerName)\*") {
            throw 'Workgroup setup requires a local Windows account on this VM. Run setup as an organization-approved local administrator (VMNAME\username) with a password, not a PIN. Microsoft Entra ID/AzureAD or domain accounts on a non-AD-domain-joined VM are not supported by this workflow. Automatic reboot/resume requires password-based Task Scheduler logon. Use Domain mode only on an AD-domain-joined VM.'
        }
    }
    $localServer = '(?:localhost|\.|' + [regex]::Escape($Plan.ComputerName) + ')'
    if ($Plan.SqlInstance -notmatch ('^' + $localServer + '(?:\\[a-zA-Z][a-zA-Z0-9_]{0,15})?$')) {
        throw 'SQL must be a local default/named instance, such as localhost or localhost\SQL2025. Remote SQL is not included.'
    }
    if ($Plan.Components -ne 'DevOpsOnly' -and $Plan.SqlInstance -ne 'localhost') { throw 'SQL installation requires the default localhost instance.' }
    if ($Plan.SetupAccount -match '["\r\n]' -or [string]::IsNullOrWhiteSpace($Plan.SetupAccount)) { throw 'Invalid setup account.' }
    try { [Security.Principal.SecurityIdentifier]::new($Plan.SetupSid) | Out-Null }
    catch [ArgumentException] { throw 'Invalid setup account SID.' }
    $steps = @(Get-SetupSteps -Plan $Plan)
    if (($Plan.StageIndex -isnot [int] -and $Plan.StageIndex -isnot [long]) -or
        $Plan.StageIndex -lt 0 -or $Plan.StageIndex -gt $steps.Count) { throw 'Invalid saved stage index.' }
    if ($Plan.Status -notin @('Pending', 'Running', 'RebootPending', 'Failed', 'Completed')) { throw 'Invalid saved setup status.' }
    if ($Plan.Status -eq 'Completed' -and $Plan.StageIndex -ne $steps.Count) { throw 'Completed status requires all stages to finish.' }
    if ($Plan.RebootAfter -and $Plan.RebootAfter -notmatch '^\d{4}-\d{2}-\d{2}T') { throw 'Invalid pending reboot timestamp.' }
}

function Get-SetupSteps {
    param([psobject]$Plan)
    if ($Plan.Components -ne 'DevOpsOnly') { 'Sql' }
    if ($Plan.Components -ne 'SqlOnly') {
        'DevOps'
        if ($Plan.Email -eq 'Capture') { 'Smtp' }
        'Configure'
        if ($null -ne (Get-SelectedSetupPatch -Plan $Plan)) { 'Patch' }
    }
    if ($Plan.SchemaVersion -ge 2 -and $Plan.Components -ne 'DevOpsOnly') { 'Ssms' }
    'Verify'
}

function Save-SetupState {
    param([psobject]$State, [string]$Path)
    Assert-SetupPlan -Plan $State
    $temporary = "$Path.tmp"
    $State | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $temporary -Encoding UTF8
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Read-SetupState {
    param([string]$Path)
    $state = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    Assert-SetupPlan -Plan $state
    Update-SetupStateSchema -State $state
    return $state
}

function Update-SetupStateSchema {
    param([psobject]$State)
    if ($State.SchemaVersion -eq 1) {
        $oldCount = @(Get-SetupSteps -Plan $State).Count
        $State.SchemaVersion = 2
        if ($State.Components -ne 'DevOpsOnly' -and $State.StageIndex -eq $oldCount) {
            $State.StageIndex++
        }
        Assert-SetupPlan -Plan $State
    }
    if ($State.SchemaVersion -eq 2) {
        $selection = if ($State.Components -eq 'SqlOnly') { 'Skip' } else { (Get-SelectedSetupPatch -Plan $State).Number }
        $State | Add-Member -NotePropertyName PatchSelection -NotePropertyValue $selection -Force
        $State.SchemaVersion = 3
        Assert-SetupPlan -Plan $State
    }
    if ($State.SchemaVersion -eq 3) {
        $State | Add-Member -NotePropertyName Ports -NotePropertyValue $null -Force
        $State.SchemaVersion = 4
        Assert-SetupPlan -Plan $State
    }
    if ($State.SchemaVersion -eq 4) {
        $State | Add-Member -NotePropertyName JoinMode -NotePropertyValue 'Domain' -Force
        $State | Add-Member -NotePropertyName DnsHostName -NotePropertyValue ((Get-SetupHostName -Plan $State).ToLowerInvariant()) -Force
        $State.SchemaVersion = 5
        Assert-SetupPlan -Plan $State
    }
    if ($State.SchemaVersion -eq 5) {
        $State | Add-Member -NotePropertyName AllowUnsupportedOs -NotePropertyValue $false -Force
        $State.SchemaVersion = 6
        Assert-SetupPlan -Plan $State
    }
}

function Complete-SetupStage {
    param([psobject]$State, [bool]$RebootRequired)
    $count = @(Get-SetupSteps -Plan $State).Count
    if ($State.StageIndex -ge $count) { throw 'Cannot advance an already completed plan.' }
    $State.StageIndex++
    $State.Status = if ($RebootRequired) { 'RebootPending' } else { 'Running' }
}

Export-ModuleMember -Function Resolve-SetupPatchChoice, Get-SelectedSetupPatch, Get-SetupJoinMode, Get-SetupHostName, Get-SetupAllowUnsupportedOs, Assert-SetupPlan, Get-SetupSteps, Save-SetupState, Read-SetupState, Update-SetupStateSchema, Complete-SetupStage
