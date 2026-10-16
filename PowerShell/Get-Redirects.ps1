<#
.SYNOPSIS
    Repeatedly resolves a URL to discover all of the locations it redirects to.

.DESCRIPTION
    Sends a number of requests to the specified URL and records the final URL that each request
    is redirected to. This is useful for download URLs that are load balanced across multiple
    mirrors or CDNs (e.g. SourceForge), to identify every host that may need to be allowed
    through a firewall or proxy.

    A GET request is used rather than HEAD as some servers refuse HEAD requests, but only the
    response headers are read so the file itself is not downloaded.

    Returns the unique list of resolved URLs, or the unique list of hosts if -HostOnly is specified.

.PARAMETER Uri
    Absolute HTTP or HTTPS URL to resolve. Alias: URL.

.PARAMETER Attempts
    Number of times to resolve the URL. Defaults to 10.

.PARAMETER HostOnly
    Return only the unique host names rather than the full resolved URLs.

.PARAMETER UserAgent
    User-Agent string to send with each request, for servers that require a browser user agent.

.PARAMETER Headers
    Additional request headers to send with each request, e.g. @{ Accept = '*/*' }.

.EXAMPLE
    .\Get-Redirects.ps1 -Uri 'https://downloads.sourceforge.net/project/winscp/WinSCP/6.5.7/WinSCP-6.5.7-Setup.exe'
    Returns the unique URLs that the SourceForge download redirects to over 10 attempts.

.EXAMPLE
    .\Get-Redirects.ps1 -Uri 'https://downloads.sourceforge.net/project/winscp/WinSCP/6.5.7/WinSCP-6.5.7-Setup.exe' -Attempts 50 -HostOnly
    Returns the unique mirror host names that the SourceForge download redirects to over 50 attempts.

.EXAMPLE
    .\Get-Redirects.ps1 -Uri 'https://example.com/download' -UserAgent 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)' -Headers @{ Accept = '*/*' }
    Resolves a URL from a server that requires a browser user agent and an Accept header.

.NOTES
    Author Dan Gough@PatchMyPC
    Date: 2026-10-16
    Version: 1.0

    ################# DISCLAIMER #################
    Patch My PC provides scripts, macro, and other code examples for illustration only, without warranty 
    either expressed or implied, including but not limited to the implied warranties of merchantability 
    and/or fitness for a particular purpose. This script is provided 'AS IS' and Patch My PC does not 
    guarantee that the following script, macro, or code can or should be used in any situation or that 
    operation of the code will be error-free.

#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [Alias('URL')]
    [ValidateScript({ $_.IsAbsoluteUri -and $_.Scheme -in 'http', 'https' })]
    [uri]$Uri,

    [ValidateRange(1, 1000)]
    [int]$Attempts = 10,

    [switch]$HostOnly,

    [string]$UserAgent,

    [hashtable]$Headers
)

if ($PSEdition -ne 'Core') {
    Add-Type -AssemblyName System.Net.Http
    # SystemDefault (0) already lets the OS negotiate the best protocol, so only extend explicit settings
    if ([Net.ServicePointManager]::SecurityProtocol -ne 0) {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    }
}

$Handler = [System.Net.Http.HttpClientHandler]::new()
# Stop a sticky session cookie from pinning every attempt to the same mirror
$Handler.UseCookies = $false
$HttpClient = [System.Net.Http.HttpClient]::new($Handler)

if ($UserAgent) {
    $null = $HttpClient.DefaultRequestHeaders.TryAddWithoutValidation('User-Agent', $UserAgent)
}
if ($Headers) {
    foreach ($Header in $Headers.GetEnumerator()) {
        $null = $HttpClient.DefaultRequestHeaders.TryAddWithoutValidation([string]$Header.Key, [string]$Header.Value)
    }
}

try {
    $Results = for ($i = 1; $i -le $Attempts; $i++) {
        Write-Progress -Activity "Resolving redirects for $Uri" -Status "Attempt $i of $Attempts" -PercentComplete (($i - 1) / $Attempts * 100)
        $Response = $null
        try {
            # ResponseHeadersRead returns once headers arrive, so the body is never downloaded
            $Response = $HttpClient.GetAsync($Uri, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
            $null = $Response.EnsureSuccessStatusCode()
            if ($HostOnly) {
                $Response.RequestMessage.RequestUri.Host
            }
            else {
                $Response.RequestMessage.RequestUri.AbsoluteUri
            }
        }
        catch {
            Write-Warning "Stopping after $($i - 1) successful attempt(s): $($_.Exception.GetBaseException().Message)"
            break
        }
        finally {
            if ($Response) { $Response.Dispose() }
        }
    }
}
finally {
    Write-Progress -Activity "Resolving redirects for $Uri" -Completed
    $HttpClient.Dispose()
}

$Results | Sort-Object -Unique