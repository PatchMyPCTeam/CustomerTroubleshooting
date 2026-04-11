<#
.SYNOPSIS
Tests HTTPS connectivity and prints remote certificate details for a URL.

.DESCRIPTION
Validates the provided URL, performs an HTTP web request, then opens a TCP/TLS
connection to retrieve and display certificate metadata (thumbprint, issuer,
expiration, and subject).

.PARAMETER URL
Absolute HTTP or HTTPS URL to test.

.EXAMPLE
.\Test-PMPCWebCertificate.ps1
Runs the test against the default URL: https://patchmypc.com

.EXAMPLE
.\Test-PMPCWebCertificate.ps1 -URL "https://example.com"
Runs the same connectivity and certificate checks for a custom URL.
#>

param(
    [Parameter(Mandatory = $false)]
    [string]
    $URL = "https://patchmypc.com"
)

# Validate URI
try {
    $URI = [System.Uri]::new($URL)
    $AllowedSchemes = @("http", "https")
    if (-not ($URI.IsAbsoluteUri -and $AllowedSchemes -contains $URI.Scheme.ToLower())) {
        return Write-Host "URI must be absolute and use http or https scheme: $URL" -ForegroundColor Red
    }
}
catch {
    Write-Host "Invalid URI format: $URL" -ForegroundColor Red
    Write-Host "Example: ""https://example.com""" -ForegroundColor Yellow
    return    
}

Write-Host "Running as: [$([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)]" -ForegroundColor DarkGray
Write-Host "Testing connectivity: [$($URL)]" -ForegroundColor DarkGray

# Test HTTP connectivity
try {
    $req = Invoke-WebRequest -Uri $URI -UseBasicParsing -TimeoutSec 10
    Write-Host "Web Request Status: $($req.StatusCode)" -ForegroundColor Green
}
catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
}

try {
    $HostName = $URI.Host
    $Port = if ($URI.IsDefaultPort) { 443 } else { $URI.Port }

    $tcpClient = [System.Net.Sockets.TcpClient]::new()
    $tcpClient.Connect($HostName, $Port)

    $sslStream = [System.Net.Security.SslStream]::new(
        $tcpClient.GetStream(), $false,
        [System.Net.Security.RemoteCertificateValidationCallback] { param($s, $c, $ch, $e) $true }
    )
    try {
        $sslStream.AuthenticateAsClient($HostName)
        $RemoteCert = $sslStream.RemoteCertificate
        if ($null -ne $RemoteCert) {
            $cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($RemoteCert)
            [PSCustomObject]@{
                Thumbprint = $cert.Thumbprint
                Issuer     = $cert.Issuer
                NotAfter   = $cert.NotAfter
                Subject    = $cert.Subject
            } | Format-List
        }
        else {
            Write-Host "No Certificate" -ForegroundColor Red
        }
    }
    finally {
        $sslStream.Dispose()
        $tcpClient.Dispose()
    }
}
catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
}

# Pause to ensure the user can read the output before the console closes
Read-Host "Press Enter to exit..."