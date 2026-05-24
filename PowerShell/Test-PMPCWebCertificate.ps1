<#
.SYNOPSIS
Tests HTTPS connectivity and prints remote certificate details for a URL.

.DESCRIPTION
Validates the provided URL, performs an HTTP web request, then opens a TCP/TLS
connection to retrieve and display certificate metadata (thumbprint, issuer,
expiration, and subject). Also performs an online certificate revocation check
using the OCSP URL embedded in the certificate's AIA extension to verify the
machine can reach the revocation endpoint (e.g. ocsp.digicert.cn).

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

#region Validate URI
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
#endregion

Write-Host "Running as: [$([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)]" -ForegroundColor DarkGray

#region - Test HTTP connectivity
# Determines if the endpoint is reachable because Invoke-WebRequest does not validate the certificate
Write-Host "----------------------------------" -ForegroundColor DarkGray
Write-Host "Testing HTTP Connectivity" -ForegroundColor Cyan
Write-Host "Verifies the URL is reachable over HTTP, No Cert checks." -ForegroundColor DarkGray
Write-Host "----------------------------------" -ForegroundColor DarkGray
try {
    $req = Invoke-WebRequest -Uri $URI -UseBasicParsing -TimeoutSec 10
    Write-Host "Web Request Status: $($req.StatusCode)" -ForegroundColor Green
}
catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
}
#endregion

#region - Retrieve and display certificate details
Write-Host ""
Write-Host "----------------------------------" -ForegroundColor DarkGray
Write-Host "Retrieving Certificate Details" -ForegroundColor Cyan
Write-Host "Connects via TLS and displays the server's certificate metadata, No Cert checks." -ForegroundColor DarkGray
Write-Host "----------------------------------" -ForegroundColor DarkGray
try {
    $HostName = $URI.Host
    $Port = if ($URI.IsDefaultPort) { 443 } else { $URI.Port }

    # Open a TCP connection to the host
    $tcpClient = [System.Net.Sockets.TcpClient]::new()
    $tcpClient.Connect($HostName, $Port)

    # Wrap the TCP connection in an SSL stream; the callback accepts all certificates so we can inspect them manually
    $sslStream = [System.Net.Security.SslStream]::new(
        $tcpClient.GetStream(), $false,
        [System.Net.Security.RemoteCertificateValidationCallback] { param($s, $c, $ch, $e) $true }
    )
    try {
        # Preserve existing protocols and include TLS 1.2
        $sslProtocols = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Security.Authentication.SslProtocols]::Tls12
        # Perform the TLS handshake; revocation check is skipped here and done manually later
        $sslStream.AuthenticateAsClient($HostName, $null, $sslProtocols, $false)
        # Get the server's certificate from the SSL stream
        $RemoteCert = $sslStream.RemoteCertificate
        if ($null -ne $RemoteCert) {
            $cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($RemoteCert)

            $AIAUrls = $null
            $CRLUrls = $null
            foreach ($extension in $cert.Extensions) {
                switch ($extension.Oid.Value) {
                    '1.3.6.1.5.5.7.1.1' {
                        # AIA (Authority Information Access)
                        $formatted = ([System.Security.Cryptography.AsnEncodedData]::new($extension.Oid, $extension.RawData)).Format($true)
                        $AIAUrls = [regex]::Matches($formatted, 'https?://[^\s,;)]+').Value
                    }
                    '2.5.29.31' {
                        # CRL Distribution Points
                        $formatted = ([System.Security.Cryptography.AsnEncodedData]::new($extension.Oid, $extension.RawData)).Format($true)
                        $CRLUrls = [regex]::Matches($formatted, 'https?://[^\s,;)]+').Value
                    }
                }
            }
            
            [PSCustomObject]@{
                Thumbprint = $cert.Thumbprint
                Issuer     = $cert.Issuer
                NotAfter   = $cert.NotAfter
                Subject    = $cert.Subject
                AIA        = $AIAUrls
                CRLs       = $CRLUrls
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
#endregion

#region - Test certificate validity
# Validates the full trust chain and revocation status using X509Chain.
try {
    Write-Host "----------------------------------" -ForegroundColor DarkGray
    Write-Host "Testing Certificate Validity" -ForegroundColor Cyan
    Write-Host "Checks the certificate trust chain and revocation status." -ForegroundColor DarkGray
    Write-Host "----------------------------------" -ForegroundColor DarkGray

    # Create a new X509Chain object used to build and validate the certificate chain
    $chain = [System.Security.Cryptography.X509Certificates.X509Chain]::new()
    # Contact the OCSP/CRL endpoint to perform a live revocation check (as opposed to Offline or NoCheck)
    $chain.ChainPolicy.RevocationMode = [System.Security.Cryptography.X509Certificates.X509RevocationMode]::Online
    # Only check the end-entity (leaf) certificate for revocation, not intermediate or root CAs
    $chain.ChainPolicy.RevocationFlag = [System.Security.Cryptography.X509Certificates.X509RevocationFlag]::EndCertificateOnly
    # Do not suppress any validation errors - all chain errors will be surfaced in ChainStatus
    $chain.ChainPolicy.VerificationFlags = [System.Security.Cryptography.X509Certificates.X509VerificationFlags]::NoFlag
    if ($null -eq $cert) {
        Write-Host "Certificate Check: Skipped - no certificate was retrieved." -ForegroundColor Yellow
        return
    }
    try {
        $chainBuilt = $chain.Build($cert)
        if ($chainBuilt) {
            Write-Host "Certificate Check: Passed" -ForegroundColor Green
        }
        else {
            foreach ($status in $chain.ChainStatus) {
                switch ($status.Status) {
                    'Revoked' {
                        Write-Host "Certificate Check: Certificate is REVOKED" -ForegroundColor Red
                    }
                    { $_ -in 'RevocationStatusUnknown', 'OfflineRevocation' } {
                        $ocspUrls = if ($AIAUrls) { $AIAUrls -join ', ' } else { 'unknown' }
                        Write-Host "Certificate Check: Could not reach OCSP/CRL endpoint - check connectivity to: $ocspUrls" -ForegroundColor Yellow
                    }
                    default {
                        Write-Host "Certificate Check: $($status.Status) - $($status.StatusInformation.Trim())" -ForegroundColor Red
                    }
                }
            }
        }
    }
    finally {
        $chain.Dispose()
    }
}
catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
}
#endregion

# Pause to ensure the user can read the output before the console closes
Read-Host "Press Enter to exit..."