<#
.SYNOPSIS
Online availability checks for all configured setup download URLs.
.EXAMPLE
.\Test-DownloadUrls.ps1
.EXAMPLE
.\Test-DownloadUrls.ps1 -ReportPath C:\Reports\download-links.csv
.NOTES
Run separately from offline tests before publishing a release. No elevation,
installation or full installer downloads. HEAD first; HTTP 403/405/501 falls
back to GET with Range bytes=0-0 and ResponseHeadersRead. Response bodies are
never read, even if a server ignores Range. Each request has a bounded timeout;
at most 10 HTTPS redirects per attempt. No certificate-validation bypass.
Availability does not verify signatures/hashes or bootstrapper dependencies.
Proxy/network failures are failures to verify, not proof the URL was removed.
Exit 0: all pass. Exit 1: unavailable links. Exit 2: configuration, discovery,
reporting or unexpected checker errors.
#>
#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateRange(1, 120)][int]$TimeoutSeconds = 30,
    [string]$ReportPath
)

function Get-SetupDownloadLinks {
    param([string]$Root = $PSScriptRoot)
    $modulePath = Join-Path $Root 'GuestSetup\Setup-Releases.psm1'
    $module = Import-Module $modulePath -Force -PassThru -ErrorAction Stop
    try {
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($modulePath, [ref]$tokens, [ref]$errors)
        if ($errors.Count) { throw ($errors.Message -join '; ') }
        $releaseFunction = $ast.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-SetupRelease'
        }, $true)
        $releaseSwitch = $releaseFunction.Body.Find({
            param($node) $node -is [Management.Automation.Language.SwitchStatementAst]
        }, $true)
        $versions = @($releaseSwitch.Clauses | ForEach-Object { $_.Item1.Value })
        if (-not $versions.Count) { throw 'No releases discovered in Get-SetupRelease.' }
        $links = @(foreach ($version in $versions) {
            $release = Get-SetupRelease -Version $version
            foreach ($property in @('SqlUrl', 'SqlIsoUrl', 'DevOpsUrl')) {
                if ($release.$property) {
                    [pscustomobject]@{ Source = "$version $property"; Url = [string]$release.$property }
                }
            }
            foreach ($patch in Get-SetupPatchCatalog -Version $version) {
                [pscustomobject]@{ Source = "$version Patch $($patch.Number)"; Url = [string]$patch.Url }
            }
        })
        $workerPath = Join-Path $Root 'GuestSetup\Resume-Setup.ps1'
        $ast = [Management.Automation.Language.Parser]::ParseFile($workerPath, [ref]$tokens, [ref]$errors)
        if ($errors.Count) { throw ($errors.Message -join '; ') }
        $commands = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Get-SetupDownload'
        }, $true))
        foreach ($command in $commands) {
            $elements = $command.CommandElements
            for ($i = 1; $i -lt $elements.Count - 1; $i++) {
                if ($elements[$i] -is [Management.Automation.Language.CommandParameterAst] -and
                    $elements[$i].ParameterName -eq 'Url' -and
                    $elements[$i + 1] -is [Management.Automation.Language.StringConstantExpressionAst]) {
                    $links += [pscustomobject]@{
                        Source = "Worker line $($command.Extent.StartLineNumber)"
                        Url = $elements[$i + 1].Value
                    }
                }
            }
        }
        foreach ($group in $links | Group-Object Url) {
            [pscustomobject]@{ Source = ($group.Group.Source -join '; '); Url = $group.Name }
        }
    }
    finally { Remove-Module $module -ErrorAction Stop }
}

function Invoke-DownloadLinkRequest {
    param([Net.Http.HttpClient]$Client, [uri]$Uri, [string]$Method, [int]$TimeoutSeconds)
    $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::new($Method), $Uri)
    $cancel = [Threading.CancellationTokenSource]::new()
    $response = $null
    try {
        if ($Method -eq 'GET') { $request.Headers.Range = [Net.Http.Headers.RangeHeaderValue]::new(0, 0) }
        $cancel.CancelAfter([timespan]::FromSeconds($TimeoutSeconds))
        $response = $Client.SendAsync($request, [Net.Http.HttpCompletionOption]::ResponseHeadersRead,
            $cancel.Token).GetAwaiter().GetResult()
        [pscustomobject]@{
            Status = [int]$response.StatusCode
            Location = $response.Headers.Location
            ContentType = [string]$response.Content.Headers.ContentType
        }
    }
    finally {
        if ($null -ne $response) { $response.Dispose() }
        $request.Dispose()
        $cancel.Dispose()
    }
}

function Test-SetupDownloadLink {
    param([psobject]$Link, [Net.Http.HttpClient]$Client, [int]$TimeoutSeconds)
    $uri = $null
    $method = 'HEAD'
    $status = $null
    $failureKind = 'Error'
    try {
        $uri = [uri]$Link.Url
        if (-not $uri.IsAbsoluteUri -or $uri.Scheme -ne 'https' -or $uri.UserInfo) {
            throw "Download URL must use HTTPS without embedded credentials: $uri"
        }
        foreach ($attempt in @('HEAD', 'GET')) {
            $method = $attempt
            $uri = [uri]$Link.Url
            for ($redirect = 0; $redirect -le 10; $redirect++) {
                if (-not $uri.IsAbsoluteUri -or $uri.Scheme -ne 'https' -or $uri.UserInfo) {
                    $failureKind = 'Unavailable'
                    throw "Download/redirect must use HTTPS without embedded credentials: $uri"
                }
                $status = $null
                try {
                    $response = Invoke-DownloadLinkRequest -Client $Client -Uri $uri -Method $method -TimeoutSeconds $TimeoutSeconds
                }
                catch {
                    $cause = $_.Exception.GetBaseException()
                    if ($cause -is [Net.Http.HttpRequestException] -or
                        $cause -is [OperationCanceledException] -or $cause -is [TimeoutException]) {
                        $failureKind = 'Unavailable'
                    }
                    throw
                }
                $status = $response.Status
                if ($status -in @(301, 302, 303, 307, 308)) {
                    $failureKind = 'Unavailable'
                    if ($redirect -eq 10 -or -not $response.Location) { throw 'Redirect limit reached or missing Location header.' }
                    $uri = [uri]::new($uri, [string]$response.Location)
                    $failureKind = 'Error'
                    continue
                }
                break
            }
            if ($method -eq 'HEAD' -and $status -in @(403, 405, 501)) { continue }
            if ($status -notin @(200, 206)) {
                $failureKind = 'Unavailable'
                throw "HTTP $status; link could not be verified."
            }
            if ($response.ContentType -match '(?i)text/html|application/xhtml') {
                $failureKind = 'Unavailable'
                throw 'Endpoint returned HTML rather than an installer/archive response.'
            }
            return [pscustomobject]@{
                Result = 'PASS'; Source = $Link.Source; Url = $Link.Url
                FailureKind = ''
                Method = $method; Status = $status; FinalUrl = $uri.AbsoluteUri; Detail = 'Available (headers only)'
            }
        }
    }
    catch {
        return [pscustomobject]@{
            Result = 'FAIL'; Source = $Link.Source; Url = $Link.Url
            FailureKind = $failureKind
            Method = $method; Status = $status; FinalUrl = [string]$uri; Detail = $_.Exception.Message
        }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'
    Set-StrictMode -Version Latest
    $handler = $null; $client = $null
    try {
        Add-Type -AssemblyName System.Net.Http
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $handler = [Net.Http.HttpClientHandler]::new()
        $handler.AllowAutoRedirect = $false
        $client = [Net.Http.HttpClient]::new($handler)
        $client.Timeout = [Threading.Timeout]::InfiniteTimeSpan
        $client.DefaultRequestHeaders.UserAgent.ParseAdd('AdoServerLabAutoOrchestrator-LinkCheck/1.0')
        $links = @(Get-SetupDownloadLinks)
        if (-not $links.Count) { throw 'No download URLs discovered.' }
        $results = @(foreach ($link in $links) {
            Write-Host "Checking $($link.Source): $($link.Url)"
            Test-SetupDownloadLink -Link $link -Client $client -TimeoutSeconds $TimeoutSeconds
        })
        $results | Format-Table Result, Source, Status, Method, Detail -Wrap -AutoSize | Out-Host
        $failed = @($results | Where-Object Result -eq 'FAIL')
        if ($failed.Count) { $failed | Format-List | Out-Host }
        if ($ReportPath) { $results | Export-Csv -LiteralPath $ReportPath -NoTypeInformation -Encoding UTF8 }
        Write-Host "$($results.Count - $failed.Count)/$($results.Count) unique download URLs passed. No installer bodies read; no software installed."
        if (@($failed | Where-Object FailureKind -eq 'Error').Count) { exit 2 }
        if ($failed.Count) { exit 1 }
        exit 0
    }
    catch { Write-Error -ErrorRecord $_ -ErrorAction Continue; exit 2 }
    finally {
        if ($null -ne $client) { $client.Dispose() }
        if ($null -ne $handler) { $handler.Dispose() }
    }
}
