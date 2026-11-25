#requires -Version 5.1
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.Net.Http
. (Join-Path $PSScriptRoot 'Test-DownloadUrls.ps1')
$links = @(Get-SetupDownloadLinks)
if ($links.Count -ne @($links.Url | Select-Object -Unique).Count -or
    -not @($links | Where-Object Url -like '*vs_SSMS.exe').Count -or
    -not @($links | Where-Object Url -like '*smtp4dev*').Count -or
    -not @($links | Where-Object Url -like '*2313753*').Count -or
    -not @($links | Where-Object Source -like '*2020 Patch 10*').Count) {
    throw 'Discovery must deduplicate release links and include worker literals and the manual-only patch archive.'
}
foreach ($scenario in @('Success', 'Redirect', 'Fallback', 'Missing', 'Html', 'Downgrade', 'Loop', 'Timeout', 'Network', 'InvalidUri', 'Unexpected')) {
    & {
        $script:requestCount = 0
        $script:methods = @()
        try {
            function Invoke-DownloadLinkRequest {
                param($Client, $Uri, $Method, $TimeoutSeconds)
                $script:requestCount++
                $script:methods += $Method
                $status = 200; $location = $null; $type = 'application/octet-stream'
                switch ($scenario) {
                    'Redirect' { if ($script:requestCount -eq 1) { $status = 302; $location = '/payload.exe' } }
                    'Fallback' { if ($Method -eq 'HEAD') { $status = 405 } else { $status = 206 } }
                    'Missing' { $status = 404 }
                    'Html' { $type = 'text/html' }
                    'Downgrade' { $status = 302; $location = 'http://example.invalid/payload.exe' }
                    'Loop' { $status = 302; $location = '/loop' }
                    'Timeout' { throw [TimeoutException]::new('Fixture request timeout') }
                    'Network' { throw [Net.Http.HttpRequestException]::new('Fixture network failure') }
                    'Unexpected' { throw [InvalidOperationException]::new('Fixture checker bug') }
                }
                [pscustomobject]@{ Status = $status; Location = $location; ContentType = $type }
            }
            $url = if ($scenario -eq 'InvalidUri') { 'https://[' } else { 'https://example.invalid/start' }
            $result = Test-SetupDownloadLink -Link ([pscustomobject]@{ Source = 'fixture'; Url = $url }) -Client $null -TimeoutSeconds 1
            $pass = $scenario -in @('Success', 'Redirect', 'Fallback')
            if (($result.Result -eq 'PASS') -ne $pass) { throw "Incorrect result for $scenario." }
            $expectedKind = if ($pass) { '' } elseif ($scenario -in @('InvalidUri', 'Unexpected')) { 'Error' } else { 'Unavailable' }
            if ($result.FailureKind -ne $expectedKind) { throw "Incorrect failure classification for $scenario." }
            if ($scenario -eq 'Fallback' -and ($script:methods -join ',') -ne 'HEAD,GET') { throw 'HEAD rejection must use GET fallback.' }
            if ($scenario -eq 'Redirect' -and $result.FinalUrl -ne 'https://example.invalid/payload.exe') { throw 'Relative redirect resolution failed.' }
            if ($scenario -eq 'Downgrade' -and $script:requestCount -ne 1) { throw 'HTTP downgrade must not be contacted.' }
            if ($script:requestCount -gt 11) { throw 'Redirect requests must be bounded.' }
            if (-not $pass -and -not $result.Detail) { throw 'Failures must include diagnostics.' }
        }
        finally { Remove-Variable requestCount, methods -Scope Script }
    }
}
$compilerOptions = @{}
if ($PSVersionTable.PSEdition -eq 'Desktop') { $compilerOptions.ReferencedAssemblies = @('System.Net.Http') }
Add-Type @compilerOptions -TypeDefinition @'
using System;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;

public sealed class LinkCheckContent : HttpContent {
    public bool BodyRead;
    public bool Disposed;
    protected override Task SerializeToStreamAsync(Stream stream, TransportContext context) {
        BodyRead = true;
        throw new InvalidOperationException("Response body must never be read.");
    }
    protected override bool TryComputeLength(out long length) { length = 5000000000; return true; }
    protected override void Dispose(bool disposing) { Disposed = true; base.Dispose(disposing); }
}
public sealed class LinkCheckHandler : HttpMessageHandler {
    public LinkCheckContent Content;
    public string Method;
    public string Range;
    public bool Stall;
    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token) {
        Method = request.Method.Method;
        Range = request.Headers.Range == null ? null : request.Headers.Range.ToString();
        if (Stall) { await Task.Delay(Timeout.Infinite, token); }
        Content = new LinkCheckContent();
        return new HttpResponseMessage(HttpStatusCode.OK) { Content = Content };
    }
}
'@
$handler = [LinkCheckHandler]::new()
$client = [Net.Http.HttpClient]::new($handler)
try {
    foreach ($method in @('HEAD', 'GET')) {
        $response = Invoke-DownloadLinkRequest -Client $client -Uri 'https://example.invalid/payload' -Method $method -TimeoutSeconds 1
        if ($response.Status -ne 200 -or $handler.Content.BodyRead -or -not $handler.Content.Disposed) {
            throw 'Transport must return headers and dispose the response without reading its body, including a GET that ignores Range.'
        }
        if ($handler.Method -ne $method -or ($method -eq 'GET' -and $handler.Range -ne 'bytes=0-0')) {
            throw 'Transport must send the requested method and one-byte GET range.'
        }
    }
    $handler.Stall = $true
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $timedOut = $false
    try { Invoke-DownloadLinkRequest -Client $client -Uri 'https://example.invalid/timeout' -Method HEAD -TimeoutSeconds 1 }
    catch {
        if ($_.Exception.GetBaseException() -isnot [OperationCanceledException]) { throw }
        $timedOut = $true
    }
    if (-not $timedOut -or $clock.Elapsed.TotalSeconds -gt 10) { throw 'Transport did not enforce cancellation timeout.' }
}
finally { $client.Dispose(); $handler.Dispose() }
Write-Host "PASS: discovered $($links.Count) unique source URLs; offline redirect, fallback, HTML/HTTP failure, timeout and HTTPS checks passed."
