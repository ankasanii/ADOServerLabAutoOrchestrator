#requires -Version 5.1
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-SetupTempFolders {
    $roots = @($env:TEMP, (Join-Path $env:SystemRoot 'Temp'))
    $userTemp = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')
    if ((Split-Path -Leaf $userTemp) -match '^\d+$') {
        $roots += Split-Path -Parent $userTemp
    }
    $folders = @(foreach ($root in $roots | Select-Object -Unique) {
        if (Test-Path -LiteralPath $root -PathType Container) {
            $root
            Get-ChildItem -LiteralPath $root -Directory -ErrorAction Stop |
                Where-Object { $_.Name -match '^\d+$' -and -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) } |
                ForEach-Object FullName
        }
    })
    $folders | Select-Object -Unique
}

function Get-SetupLogTail {
    param([string]$Path, [string]$Stage, [datetime]$Since, [int]$TailLines)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
    $file = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($file.LastWriteTime -lt $Since) { return }
    $tail = @(Get-Content -LiteralPath $Path -Tail $TailLines -ErrorAction Stop)
    if ($Stage -and $file.Name -like 'setup-*.log') {
        $marker = -1
        for ($i = 0; $i -lt $tail.Count; $i++) {
            if ($tail[$i] -match ('^\S+ Starting ' + [regex]::Escape($Stage) + '$')) { $marker = $i }
        }
        if ($marker -ge 0) { $tail = $tail[$marker..($tail.Count - 1)] }
    }
    "--- $Path ---`r`nLast updated: $($file.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))`r`n$($tail -join "`r`n")"
}

function Get-SetupDevOpsPayloadActivity {
    param([datetime]$Since)
    $cache = Join-Path $env:ProgramData 'Package Cache'
    if (-not (Test-Path -LiteralPath $cache -PathType Container)) { return }
    if ((Get-Item -LiteralPath $cache -ErrorAction Stop).Attributes -band [IO.FileAttributes]::ReparsePoint) { return }
    $latestByComponent = @{}
    $entries = Get-ChildItem -LiteralPath $cache -Directory -ErrorAction Stop |
        Where-Object { $_.Name -match '^\{[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\}v\d+(?:\.\d+)*$' -and
            -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) }
    foreach ($entry in $entries) {
        $folder = $entry.FullName
        foreach ($segment in @('packages', 'DevOpsServer')) {
            $folder = Join-Path $folder $segment
            if (-not (Test-Path -LiteralPath $folder -PathType Container) -or
                ((Get-Item -LiteralPath $folder -ErrorAction Stop).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                $folder = $null
                break
            }
        }
        if (-not $folder) { continue }
        foreach ($component in @('Core', 'Web')) {
            $componentFolder = Join-Path $folder $component
            if (-not (Test-Path -LiteralPath $componentFolder -PathType Container)) { continue }
            if ((Get-Item -LiteralPath $componentFolder -ErrorAction Stop).Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            $latest = Get-ChildItem -LiteralPath $componentFolder -File -ErrorAction Stop |
                Where-Object { $_.Extension -in @('.cab', '.msi') -and $_.LastWriteTime -ge $Since -and
                    -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) } |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($latest -and (-not $latestByComponent.ContainsKey($component) -or
                $latest.LastWriteTime -gt $latestByComponent[$component].LastWriteTime)) {
                $latestByComponent[$component] = $latest
            }
        }
    }
    foreach ($component in @('Core', 'Web')) {
        if ($latestByComponent.ContainsKey($component)) {
            $file = $latestByComponent[$component]
            "${component}: $($file.FullName)`r`nSize: $($file.Length) bytes; Last updated: $($file.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))"
        }
    }
}

function Get-SetupMonitoringLogs {
    param([string]$Work, [psobject]$Plan, [ValidateRange(1, 1000)][int]$TailLines = 40)
    $parts = New-Object 'System.Collections.Generic.List[string]'
    $paths = New-Object 'System.Collections.Generic.List[string]'
    $stage = ''
    $since = [datetime]::MinValue
    if ($null -ne $Plan) {
        $steps = @(Get-SetupSteps -Plan $Plan)
        if ($Plan.StageIndex -lt $steps.Count) { $stage = $steps[$Plan.StageIndex] }
    }
    $progress = Join-Path $Work 'progress.log'
    if ($stage) {
        $lines = @()
        if (Test-Path -LiteralPath $progress -PathType Leaf) { $lines = @(Get-Content -LiteralPath $progress -ErrorAction Stop) }
        $marker = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match ('^\S+ Starting ' + [regex]::Escape($stage) + '$')) {
                $marker = $i
                $since = [datetimeoffset]::Parse(($lines[$i] -split ' ')[0]).LocalDateTime
            }
        }
        if ($marker -lt 0) { return 'Waiting for the current stage to start; completed-stage installer logs are hidden.' }
        $parts.Add("--- Current stage progress: $stage ---`r`n" +
            (($lines[$marker..($lines.Count - 1)] | Select-Object -Last $TailLines) -join "`r`n"))
    }
    elseif (Test-Path -LiteralPath $progress -PathType Leaf) {
        $parts.Add((Get-SetupLogTail -Path $progress -Since $since -TailLines $TailLines))
    }
    $transcripts = Join-Path $Work 'Logs'
    if (Test-Path -LiteralPath $transcripts -PathType Container) {
        $latest = Get-ChildItem -LiteralPath $transcripts -Filter 'setup-*.log' -File -ErrorAction Stop |
            Where-Object { $_.LastWriteTime -ge $since } |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($latest) {
            $text = Get-SetupLogTail -Path $latest.FullName -Stage $stage -Since $since -TailLines $TailLines
            if ($text) { $parts.Add($text) }
        }
    }
    $installerSince = (Get-Date).AddMinutes(-10)
    if ($installerSince -lt $since) { $installerSince = $since }
    if ($stage -in @('DevOps', 'Patch')) {
        $activity = @(Get-SetupDevOpsPayloadActivity -Since $installerSince)
        if ($activity.Count) {
            $parts.Add("--- Installer payload activity (last 10 minutes; metadata only) ---`r`n" +
                ($activity -join "`r`n`r`n") +
                "`r`nRecent cache writes may reflect downloading or staging; they do not prove installation completion.")
        }
    }
    $installerTailLines = [Math]::Min($TailLines, 10)
    $tempFolders = @()
    $folders = @()
    $productLogs = Join-Path $env:ProgramData 'Microsoft\Azure DevOps\Server Configuration\Logs'
    if ($stage -eq 'Configure') { $folders += @{ Path = $productLogs; Filter = 'TFS_*.log' } }
    if ($stage -eq 'Patch') { $folders += @{ Path = $productLogs; Filter = 'Patch_*.log' } }
    foreach ($folder in $folders) {
        if (Test-Path -LiteralPath $folder.Path -PathType Container) {
            $latest = Get-ChildItem -LiteralPath $folder.Path -Filter $folder.Filter -File -ErrorAction Stop |
                Where-Object { $_.LastWriteTime -ge $installerSince } |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($latest) { $paths.Add($latest.FullName) }
        }
    }
    if ($stage -in @('Sql', 'DevOps', 'Patch', 'Ssms')) {
        $pattern = switch ($stage) {
            'Sql' { 'sql|ssei' }
            'DevOps' { 'devops|tfs' }
            'Patch' { 'devops|tfs|patch' }
            'Ssms' { '^dd_|^SSMS.*Setup' }
        }
        $tempFolders = @(Get-SetupTempFolders)
        $candidates = @(foreach ($folder in $tempFolders) {
                Get-ChildItem -LiteralPath $folder -File -ErrorAction Stop |
                    Where-Object { $_.Extension -in @('.log', '.txt') -and
                        $_.LastWriteTime -ge $installerSince -and $_.Name -match $pattern -and
                        ($stage -ne 'Ssms' -or $_.Name -notmatch 'devops|tfs|vcredist') }
        })
        $latest = $candidates | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($latest) {
            if ($stage -in @('DevOps', 'Patch')) {
                $bundles = @($candidates | Where-Object { $_.Name -match '^dd_(devops|tfs).*_\d{14}\.(log|txt)$' })
                foreach ($log in $bundles | Sort-Object LastWriteTime -Descending | Select-Object -First 1) {
                    $paths.Add($log.FullName)
                }
                $bundlePaths = @($bundles | ForEach-Object FullName)
                foreach ($log in $candidates | Where-Object { $_.FullName -notin $bundlePaths } |
                    Sort-Object LastWriteTime -Descending | Select-Object -First 3) {
                    $paths.Add($log.FullName)
                }
            }
            else { $paths.Add($latest.FullName) }
        }
    }
    if ($stage -eq 'Ssms') {
        $ssmsLogs = @(foreach ($tempFolder in $tempFolders) {
            $folder = Join-Path $tempFolder 'SSMS'
            if (Test-Path -LiteralPath $folder -PathType Container) {
                Get-ChildItem -LiteralPath $folder -File -Recurse -ErrorAction Stop |
                    Where-Object { $_.Extension -in @('.log', '.txt') -and $_.LastWriteTime -ge $installerSince }
            }
        })
        $latest = $ssmsLogs | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($latest) { $paths.Add($latest.FullName) }
    }
    if ($stage -eq 'Sql') {
        $major = (Get-SetupRelease -Version $Plan.Version).SqlMajor * 10
        $folder = Join-Path $env:ProgramFiles "Microsoft SQL Server\$major\Setup Bootstrap\Log"
        if (Test-Path -LiteralPath $folder -PathType Container) {
            $paths.Add((Join-Path $folder 'Summary.txt'))
            $run = Get-ChildItem -LiteralPath $folder -Directory -ErrorAction Stop |
                Where-Object { $_.Name -match '^\d{8}_\d{6}$' } |
                Sort-Object Name -Descending | Select-Object -First 1
            if ($run) {
                $paths.Add((Join-Path $run.FullName 'Detail.txt'))
                $latest = Get-ChildItem -LiteralPath $run.FullName -Filter '*.log' -File -ErrorAction Stop |
                    Where-Object { $_.LastWriteTime -ge $installerSince } |
                    Sort-Object LastWriteTime -Descending | Select-Object -First 1
                if ($latest) { $paths.Add($latest.FullName) }
            }
        }
    }
    $installerParts = New-Object 'System.Collections.Generic.List[string]'
    foreach ($path in @($paths | Select-Object -Unique)) {
        $text = Get-SetupLogTail -Path $path -Since $installerSince -TailLines $installerTailLines
        if ($text) { $installerParts.Add($text) }
    }
    if ($installerParts.Count) {
        $parts.Add("--- Installer details: files updated in the last 10 minutes; up to $installerTailLines lines each ---`r`n`r`n" +
            ($installerParts -join "`r`n`r`n"))
    }
    elseif ($stage -in @('Sql', 'DevOps', 'Patch', 'Ssms', 'Configure')) {
        $message = 'No recent installer log activity (last 10 minutes). Setup may still be downloading or working.'
        if ($tempFolders.Count) { $message += "`r`nSearched TEMP folders: $($tempFolders -join '; ')" }
        $parts.Add($message)
    }
    return ($parts -join "`r`n`r`n")
}

Export-ModuleMember -Function Get-SetupMonitoringLogs
