#requires -Version 5.1

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-SetupRelease {
    param([string]$Version)
    switch ($Version) {
        '2020' {
            return [pscustomobject]@{
                SqlYear = 2019; SqlMajor = 15; ApiVersion = '6.0'
                WindowsBuild = 17763; ExactWindowsBuild = $true
                SqlUrl = 'https://go.microsoft.com/fwlink/?linkid=866662'
                SqlIsoUrl = ''
                DevOpsUrl = 'https://go.microsoft.com/fwlink/?LinkId=2195318'
                LatestPatchNumber = '19'
            }
        }
        '2022.1' {
            return [pscustomobject]@{
                SqlYear = 2022; SqlMajor = 16; ApiVersion = '7.0'
                WindowsBuild = 20348; ExactWindowsBuild = $true
                SqlUrl = ''
                SqlIsoUrl = 'https://download.microsoft.com/download/3/8/d/38de7036-2433-4207-8eae-06e247e17b25/SQLServer2022-x64-ENU-Dev.iso'
                DevOpsUrl = 'https://go.microsoft.com/fwlink/?LinkId=2245669'
                LatestPatchNumber = '4'
            }
        }
        '2022' {
            return [pscustomobject]@{
                SqlYear = 2022; SqlMajor = 16; ApiVersion = '7.0'
                WindowsBuild = 20348; ExactWindowsBuild = $true
                SqlUrl = ''
                SqlIsoUrl = 'https://download.microsoft.com/download/3/8/d/38de7036-2433-4207-8eae-06e247e17b25/SQLServer2022-x64-ENU-Dev.iso'
                DevOpsUrl = 'https://go.microsoft.com/fwlink/?LinkId=2269844'
                LatestPatchNumber = '12'
            }
        }
        '25H2' {
            return [pscustomobject]@{
                SqlYear = 2025; SqlMajor = 17; ApiVersion = '7.0'
                WindowsBuild = 20348; ExactWindowsBuild = $false
                SqlUrl = 'https://go.microsoft.com/fwlink/?linkid=2344711'
                SqlIsoUrl = ''
                DevOpsUrl = 'https://go.microsoft.com/fwlink/?LinkId=2330549'
                LatestPatchNumber = '9'
            }
        }
        '26H2-RC' {
            return [pscustomobject]@{
                SqlYear = 2025; SqlMajor = 17; ApiVersion = '7.0'
                WindowsBuild = 20348; ExactWindowsBuild = $false
                SqlUrl = 'https://go.microsoft.com/fwlink/?linkid=2344711'
                SqlIsoUrl = ''
                DevOpsUrl = 'https://go.microsoft.com/fwlink/?LinkId=2383605'
                LatestPatchNumber = 'Skip'
            }
        }
        default { throw 'Choose 2020, 2022.1 (Update 1), 2022 (Update 2), 25H2 or 26H2-RC; unsupported versions are not installed.' }
    }
}

function Assert-SetupOperatingSystem {
    [CmdletBinding()]
    param([string]$Version, [psobject]$Os, [string]$ProcessorArchitecture = $env:PROCESSOR_ARCHITECTURE,
        [switch]$AllowUnsupportedOs)
    $release = Get-SetupRelease -Version $Version
    $build = [int]$Os.BuildNumber
    $allowed = $false
    if ($ProcessorArchitecture -ne 'AMD64' -or $Os.OSArchitecture -notmatch '64') {
        throw [NotSupportedException]::new('Setup requires x64 Windows and a native x64 PowerShell process; x86 and ARM are not supported.')
    }
    if ($Os.ProductType -notin @(1, 3)) {
        throw [NotSupportedException]::new('Only Windows workstations/member servers are allowed; domain controllers cannot be overridden.')
    }
    if ($Os.ProductType -eq 3) {
        $allowed = if ($Version -in @('25H2', '26H2-RC')) { $build -in @(20348, 26100) } else { $build -eq $release.WindowsBuild }
    }
    elseif ($Os.ProductType -eq 1) {
        $sku = [int]$Os.OperatingSystemSKU
        $enterprise = $sku -in @(4, 27, 72, 84, 125, 126, 129, 130, 171, 172)
        $professional = $sku -in @(48, 49, 161, 162, 164, 165)
        $editionAllowed = if ($Version -eq '2020' -or $build -lt 22000) { $enterprise -or $professional }
            else { $professional -or $sku -in @(4, 27, 72, 84, 121, 122, 171, 172) }
        if (-not $editionAllowed) {
            throw [NotSupportedException]::new('This client Windows edition is not allowed for the selected setup. Home/unsupported editions cannot be overridden.')
        }
        if ($Version -eq '2020') {
            $allowed = ($build -eq 17134 -and $enterprise) -or
                ($build -in @(17763, 18362, 18363, 19041, 19042, 19043, 19044, 19045) -and ($enterprise -or $professional))
        }
        else {
            $allowed = $build -eq 26100 -and ($professional -or $sku -in @(4, 27, 72, 84, 121, 122, 171, 172))
        }
    }
    if (-not $allowed) {
        if ($AllowUnsupportedOs) {
            Write-Warning "LAB OVERRIDE: Windows build $build is not an approved OS pairing for DevOps $Version. Installation may fail or be unsupported. Only OS version/build validation is bypassed; all other prerequisite checks remain active."
            return
        }
        $required = switch ($Version) {
            '2020' { 'Windows Server 2019, Windows 10 Enterprise 1803, or Windows 10 Pro/Enterprise 1809-22H2' }
            '2022' { 'Windows Server 2022 or Windows 11 24H2 Pro/Enterprise/Education (non-LTSC)' }
            '2022.1' { 'Windows Server 2022 or Windows 11 24H2 Pro/Enterprise/Education (non-LTSC)' }
            '25H2' { 'Windows Server 2022/2025 or Windows 11 24H2 Pro/Enterprise/Education (non-LTSC)' }
            '26H2-RC' { 'Windows Server 2022/2025 or Windows 11 24H2 Pro/Enterprise/Education (non-LTSC)' }
        }
        throw [NotSupportedException]::new("Unsupported operating system for $Version (detected build $build). Use $required. Client installations are evaluation/personal-use only; Home editions and domain controllers are not supported.")
    }
}

function Get-SetupPatchCatalog {
    param([string]$Version)
    if ($Version -eq '26H2-RC') { return }
    $prefix = switch ($Version) {
        '2020' { 'devops2020.1.2patch' }
        '2022' { 'devops2022.2patch' }
        '2022.1' { 'devops2022.1patch' }
        '25H2' { 'devopsserverpatch' }
        default { throw 'Choose 2020, 2022.1, 2022 or 25H2 for the patch catalog.' }
    }
    $hashes = if ($Version -eq '2020') {
        @'
1 80AB689C60E0D70D68F887427461F9CCE337D47F8EA200B3F2C2166D78323924
2 6AA0F93DF332F97F19A1C8E2B7A6F70D87AF152430288FC0D140FCFFDABF5F90
3 8C5B28FBB356A734EB4CB603251C0FC64548F9AD2D923AB4796D641A101ECAF5
4 425972CB093174EF457AB8722AF279B40DA0CFCF9791626C815B2CDBC2728C62
5 500F2970FF9A61953D60DE20336535CB9B25D332F0C074AB6DF3F07728473160
6 B5F8DB349D5608D058787BC33E0B6EB0534C3A22B8B8077F0144C217D374CC86
7 5D0CF6D7C2AB84B0290877A5CE83612C0CF855655FD77B9546E3C90A6B99D3AE
8 14C486017B4141E8213C46F8506CB0CEF73BFDD727446695A5F1B37E640A06EA
9 45A0EBBDE13C9F1F93181CD6D7538C04176FC4EC23840AFD18BA0B0A4A45BBC9
10 389BA66EEBC32622FB83402E21373CE20AE040F70461B9F9AF9EFCED5034D2E5
11 C47B9C898C2E08527F1DDC3E7A5E67F1A11C3AFF860DE9B5FF3DD8718C3AAE87
12 C4C9EEBBDD3B07C36658C9F78AEA57A980AA633F99DF2A3AD5036F957F095E53
13 55B0A30EABD66EB22AA6093B7750EF3CFEFE79423018E304503CE728158F56F6
14 89AF4B1FCA1E2BD813A42F0D3E568E64AB470E5FD0A2F87F9E4894B8CA361420
15 66B6FDE4949C0B7A87B20F3BC8E0673774401929D8B75E37F599DFF8BA74ABE5
16 0C60AF43C79EAF3FD5A91E3DA6D9218F262B33EFE13E7A69E2C2AB336F1920A5
17 139D489FC8F9EF96069A956482FBA6153058704BB1F3C8AB3637D7ADC3A95C94
18 0CE1EB0E5E2788B1D3B1E9736B966292852DDB3CCADCB7850D4307AF1DF201E2
19 DE6E1E3557232783269840AAB6AFCF372A1B9F7FFDE0D74BCCDF7572B10D963F
'@
    }
    elseif ($Version -eq '2022.1') {
        @'
1 9D0FDCCD1F20461E586689B756E600CC16424018A3377042F7DC3A6EEF096FB6
2 59B3191E86DB787F91FDD1966554DE580CA97F06BA9CCB1D747D41A2317A5441
3 E7DE45650D74A1B1C47F947CDEF4BF3307C4323D749408EE7F0524C2A04D2911
4 29012B79569F042E2ED4518CE7216CA521F9435CCD80295B71F734AA60FCD03F
'@
    }
    elseif ($Version -eq '2022') {
        @'
1 64CB502F29A49DF2F3B756028A92C30D30AA761060902075AB27B72899E31408
2 70930BE091607B490890A48C250DAB6C2087F7F610CC695C9C632C679A491D23
3 F5C2DA846B8A38A1FB55D1EB555FB2FD6B974B0436F573CC01A0FEBAF3D67521
4 975B0FC28737C15BA40D6E084663D1A735A66FA821EB40C7A377AE3D58F0C7DA
5 299AC29F15BC254167C2987450EF722B083594AFA885A8DAB46625C92D982C1C
6 B0B42C0085045C0B8B8B60C1ECB6D157734758AA24D6A3040A9B57770401A55D
7 73523C82BA4F910170E812C1B43374146BFD0EA9A29E2B0DA50A096360E1461F
8 D44ECE516945569F8B3FD23386B52D085FF83E237B741B1FD3238E59B52AE386
9 3055F46D9A38976410AA210CC35FAA6F1899982EC1AFC620F82B7A4BBFD2CF1B
10 66E9AB43E6387E6B38B1AE411BAA31E4FD8C26584E2692928F6BDC5D88D78DC1
11 FBD79B3E311E4CC20F63AAD1AD85B7FEAC1118C281AFCF32C5B5FC9593CFD480
12 EFB629EBE8B5A7AF4526F8F79A6EE7BC4F610B5057C0B051A84F320D2B6D1606
'@
    }
    else {
        @'
1 5747BE1A88557FA7AF45EDA4CE13E98FA997E8B7264CE6AC38D119D5E03CE05E
2 367CCDAFAAFB3EB7ABF12BE33712239E679826B0868A295245854A5667F3E010
3 FE5740404365B9C685702D7C983CEB05E14AE1C2348FAD680701F75ACB73D31E
4 9E02F3E5EA570DB3FE4A62B3D968755272BA6BAB84B044BA845B3A1C66F71E5D
5 8CBF68E696AE84F7FB78C1E9854854760DF23240C6C2E61B437ED84322F23F4B
6 F2C270BCD52595DB19083BE79A769BC7ECBDB121D530797EF49203A5A02BAF75
7 38C21ED67BB4D5B45E666142C50025E6DBC3DB1940E63F1EC5BC0F2884DF2A47
8 3072F2B81E7FD57D80D52B23AF8FF08B16CE562DC28CCB724BDE4B7728A2A01F
9 8860146214BEC8D3BA685F79058EC88B735E4858569FE35477AC364CCFFFF875
'@
    }
    foreach ($line in ($hashes -split '\r?\n')) {
        $parts = $line.Trim() -split ' '
        $number = $parts[0]
        $url = "https://aka.ms/$prefix$number"
        $notes = ''
        $installable = $true
        if ($Version -eq '2020') {
            if ($number -in @('1', '2', '3', '5')) { $url = "https://aka.ms/azdev2020.1.2patch$number" }
            if ([int]$number -ge 8) { $notes = 'Server patch only; review release-note agent/task update prerequisites separately.' }
            if ($number -eq '10') {
                $url = 'https://download.microsoft.com/download/8/0/1/80197e1d-6c4c-4da8-9b01-05064be73df1/Tasks20231103.zip'
                $installable = $false
                $notes = 'Task ZIP/manual TFX upload, not a standalone server installer. Not selectable by this setup.'
            }
            if ($number -in @('15', '16')) { $notes += ' Review agent CDN migration prerequisites.' }
        }
        elseif ($Version -eq '2022') {
            switch ($number) {
                '1' { $notes = 'Fix already included in republished fresh installation media.' }
                '3' { $notes = 'Republished February 24, 2025; catalog uses replacement hash.' }
                '4' { $url += '.exe'; $notes = 'Review CDN migration prerequisites in release notes.' }
                '5' { $notes = 'Review agent CDN migration prerequisites in release notes.' }
                '6' { $notes = 'Release notes retain a known-issue investigation warning; prefer a later patch.' }
            }
        }
        elseif ($Version -eq '2022.1') {
            $notes = 'Older Update 1 release for controlled lab reproduction; Update 2 patches do not apply.'
            if ($number -eq '2') { $notes += ' Known Proxy Server regression; fixed in Patch 3.' }
        }
        elseif ($number -eq '2') { $notes = 'Fix included in March 13, 2026 republished fresh media.' }
        [pscustomobject]@{ Number = $number; Url = $url; Hash = $parts[1]; Notes = $notes; Installable = $installable }
    }
}

Export-ModuleMember -Function Get-SetupRelease, Assert-SetupOperatingSystem, Get-SetupPatchCatalog
