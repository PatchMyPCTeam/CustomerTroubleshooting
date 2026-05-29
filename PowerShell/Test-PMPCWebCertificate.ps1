<#
.SYNOPSIS
Tests HTTPS connectivity, outputs remote leAf certificate details, and tests revocation for a URL.

.DESCRIPTION
Validates the provided URL, opens a plain TCP connection to verify network
reachability, then opens a TLS connection to retrieve and display certificate
metadata (thumbprint, issuer, expiration, and subject). Also verifies the
certificate chain is trusted by the local Windows certificate store, and
performs an online revocation check against the OCSP/CRL endpoints for every
certificate in the chain to verify the machine can reach those endpoints.

.PARAMETER URL
Absolute HTTP or HTTPS URL to test.

.PARAMETER ShowAllCerts
When specified, displays all certificates sent by the server (leaf + intermediates).
Shows all certs that were NOT used during revocation

.EXAMPLE
.\Test-PMPCWebCertificate.ps1
Runs the test against the default URL: https://patchmypc.com

.EXAMPLE
.\Test-PMPCWebCertificate.ps1 -URL "https://example.com"
Runs the same connectivity and certificate checks for a custom URL.

.EXAMPLE
.\Test-PMPCWebCertificate.ps1 -URL "https://example.com" -ShowAllCerts
Runs the checks and displays all certificates in the chain sent by the server.

.NOTES
    Author:  Michael Escamilla
    Date:    2026-05-26
    Version: 2.1
#>

param(
    [Parameter(Mandatory = $false)]
    [string]
    $URL = "https://patchmypc.com",

    [Parameter(Mandatory = $false)]
    [switch]
    $ShowAllCerts
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
Write-Host "PowerShell : $($PSVersionTable.PSVersion.Major).$($PSVersionTable.PSVersion.Minor) ($($PSVersionTable.PSEdition))" -ForegroundColor DarkGray

#region - Test TCP connectivity
# A plain TCP connect tests network reachability with zero cert/OCSP involvement.
# Invoke-WebRequest triggers OS-level revocation checks during TLS, which fails when OCSP endpoints are blocked.
Write-Host "----------------------------------" -ForegroundColor DarkGray
Write-Host "Testing TCP Connectivity" -ForegroundColor Cyan
Write-Host "Confirms the host and port are reachable at the network level. No TLS or cert checks." -ForegroundColor DarkGray
Write-Host "----------------------------------" -ForegroundColor DarkGray
$Port = if ($URI.IsDefaultPort) { if ($URI.Scheme -eq 'https') { 443 } else { 80 } } else { $URI.Port }
try {
    $tcpTest = [System.Net.Sockets.TcpClient]::new()
    try {
        $tcpTest.Connect($URI.Host, $Port)
        Write-Host "TCP Connect: Succeeded ($($URI.Host):$Port)" -ForegroundColor Green
    }
    finally {
        $tcpTest.Dispose()
    }
}
catch {
    Write-Host "TCP Connect: Failed ($($URI.Host):$Port) - $($_.Exception.Message)" -ForegroundColor Red
}
#endregion

if ($URI.Scheme -eq 'https') {

    # Helper Function: extract URLs from an X509 extension by OID using its formatted ASN.1 text
    function Get-CertExtensionUrls {
        param(
            [System.Security.Cryptography.X509Certificates.X509Certificate2]
            $Certificate,
            [string]
            $Oid
        )

        $extension = $Certificate.Extensions | Where-Object { $_.Oid.Value -eq $Oid } | Select-Object -First 1
        if (-not $extension) { return $null }
        $formatted = ([System.Security.Cryptography.AsnEncodedData]::new($extension.Oid, $extension.RawData)).Format($true)
        return [regex]::Matches($formatted, 'https?://[^\s,;)]+').Value
    }

    #region - Retrieve and display certificate details
    Write-Host "`n----------------------------------" -ForegroundColor DarkGray
    Write-Host "Retrieving Certificate Details" -ForegroundColor Cyan
    Write-Host "Connects via TLS and displays the server's certificate metadata, No Cert checks." -ForegroundColor DarkGray
    Write-Host "----------------------------------" -ForegroundColor DarkGray
    try {
        $HostName = $URI.Host

        # Open a TCP connection to the host
        $tcpClient = [System.Net.Sockets.TcpClient]::new()
        $tcpClient.Connect($HostName, $Port)

        # Capture the chain the server actually sent during the TLS handshake.
        # Script-scope is used because scriptblock-as-delegate runs in an isolated scope.
        $Script:ServerSentChain = $null
        $Script:SslPolicyErrors = [System.Net.Security.SslPolicyErrors]::None
        $validationCallback = [System.Net.Security.RemoteCertificateValidationCallback] {
            param($s, $c, $ch, $e)
            # ChainElements contains the OS-resolved chain (leaf + intermediates + root).
            $Script:ServerSentChain = $ch.ChainElements |
            ForEach-Object { [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($_.Certificate) }
            # Capture OS-reported TLS policy errors (revocation errors absent since checkCertificateRevocation=false)
            $Script:SslPolicyErrors = $e
            $true
        }

        # Wrap the TCP connection in an SSL stream; the callback accepts all certificates so we can inspect them manually
        $sslStream = [System.Net.Security.SslStream]::new(
            $tcpClient.GetStream(), $false, $validationCallback
        )
        try {
            # Start with TLS 1.2; add TLS 1.3 only if the runtime supports it (.NET Core 3+ / .NET 5+)
            $sslProtocols = [System.Security.Authentication.SslProtocols]::Tls12
            if ([Enum]::IsDefined([System.Security.Authentication.SslProtocols], 12288)) {
                $sslProtocols = [System.Security.Authentication.SslProtocols]($sslProtocols -bor 12288)
            }
            # Perform the TLS handshake; revocation check is skipped here and done manually later
            $sslStream.AuthenticateAsClient($HostName, $null, $sslProtocols, $false)
            # Get the server's certificate from the SSL stream
            $RemoteCert = $sslStream.RemoteCertificate
            if ($null -ne $RemoteCert) {
                $Certificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($RemoteCert)

                # By default show only the leaf cert. -ShowAllCerts shows all certs the server sent.
                $CertChain = if ($ShowAllCerts -and $Script:ServerSentChain) { $Script:ServerSentChain } else { @($Certificate) }
                $serverCount = if ($Script:ServerSentChain) { $Script:ServerSentChain.Count } else { 1 }
                Write-Host "Server sent $($serverCount) cert(s)$(if (-not $ShowAllCerts -and $serverCount -gt 1) { ' (use -ShowAllCerts to see all)' }):" -ForegroundColor DarkGray
                for ($i = 0; $i -lt $CertChain.Count; $i++) {
                    $CurrentCert = $CertChain[$i]
                    $role = if ($i -eq 0) { 'Leaf' } elseif ($i -eq $CertChain.Count - 1 -and $CurrentCert.Subject -eq $CurrentCert.Issuer) { 'Root' } else { 'Intermediate' }
                    Write-Host "[$i] $role" -ForegroundColor Cyan
                    [PSCustomObject]@{
                        Thumbprint = $CurrentCert.Thumbprint
                        Serial     = $CurrentCert.SerialNumber
                        Subject    = $CurrentCert.Subject
                        Issuer     = $CurrentCert.Issuer
                        NotBefore  = $CurrentCert.NotBefore
                        NotAfter   = $CurrentCert.NotAfter
                        AIA        = Get-CertExtensionUrls -Certificate $CurrentCert -Oid '1.3.6.1.5.5.7.1.1'
                        CRLs       = Get-CertExtensionUrls -Certificate $CurrentCert -Oid '2.5.29.31'
                    } | Format-List
                }

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
        if ($_.Exception.Message -match 'closed the transport stream|Authentication failed') {
            Write-Host "Hint: TCP connectivity succeeded but the TLS handshake was rejected." -ForegroundColor Yellow
            Write-Host "      Likely causes:" -ForegroundColor Yellow
            Write-Host "        - SSL inspection intercepting or blocking the handshake" -ForegroundColor Yellow
            Write-Host "        - Firewall performing deep packet inspection and dropping the TLS ClientHello" -ForegroundColor Yellow
            Write-Host "        - TLS version or cipher suite mismatch between this client and the server/proxy" -ForegroundColor Yellow
        }
    }
    #endregion

    #region - Test certificate validation
    # Contacts live OCSP/CRL endpoints to verify no cert in the chain has been revoked.
    # Unreachable endpoints are reported separately from actual revocations.
    Write-Host "`n----------------------------------" -ForegroundColor DarkGray
    Write-Host "Testing Certificate Validation" -ForegroundColor Cyan
    Write-Host "Contacts OCSP/CRL endpoints to check revocation status for each cert in the chain." -ForegroundColor DarkGray
    Write-Host "The trust path may differ from what the server sent due to AIA fetching or local store resolution." -ForegroundColor DarkGray
    Write-Host "Tip: To force a live OCSP/CRL check (bypass Windows cache) run: certutil -urlcache * delete" -ForegroundColor DarkGray
    if ($PSVersionTable.PSVersion.Major -lt 7) {
        Write-Host "NOTE: Running on PowerShell $($PSVersionTable.PSVersion.Major).$($PSVersionTable.PSVersion.Minor) - Chain validation may not follow the server-sent intermediates" -ForegroundColor Yellow
        Write-Host "      Windows may resolve its own path via AIA or local store instead." -ForegroundColor Yellow
        Write-Host "      Re-run using pwsh.exe (PS7+/.NET Core 3.1+) for more reliable results." -ForegroundColor Yellow
    }
    Write-Host "----------------------------------" -ForegroundColor DarkGray

    if ($null -eq $Certificate) {
        Write-Host "Skipped - no certificate was retrieved." -ForegroundColor Yellow
    }
    else {
        $CertChainVal = [System.Security.Cryptography.X509Certificates.X509Chain]::new()
        $CertChainVal.ChainPolicy.RevocationMode = [System.Security.Cryptography.X509Certificates.X509RevocationMode]::Online
        $CertChainVal.ChainPolicy.RevocationFlag = [System.Security.Cryptography.X509Certificates.X509RevocationFlag]::ExcludeRoot
        $CertChainVal.ChainPolicy.VerificationFlags = [System.Security.Cryptography.X509Certificates.X509VerificationFlags]::NoFlag
        $CertChainVal.ChainPolicy.UrlRetrievalTimeout = [System.TimeSpan]::Zero
        $CertChainVal.ChainPolicy.VerificationTime = [System.DateTime]::Now
        # Seed the intermediate certs so hopefully Windows follows the trust path rather than resolving its own chain via AIA downloads or local store
        if ($Script:ServerSentChain -and $Script:ServerSentChain.Count -gt 1) {
            foreach ($serverCert in $Script:ServerSentChain | Select-Object -Skip 1) {
                [void]$CertChainVal.ChainPolicy.ExtraStore.Add($serverCert)
            }
        }
        try {
            $ValidChain = $CertChainVal.Build($Certificate)
            Write-Host "Chain Validation : $(if ($ValidChain) { 'Passed' } else { 'FAILED' })" -ForegroundColor $(if ($ValidChain) { 'Green' } else { 'Red' })
            for ($i = 0; $i -lt $CertChainVal.ChainElements.Count; $i++) {
                $CertElement = $CertChainVal.ChainElements[$i]
                $Role = if ($i -eq 0) { 'Leaf' } elseif ($CertElement.Certificate.Subject -eq $CertElement.Certificate.Issuer) { 'Root' } else { 'Intermediate' }
                $CommonName = if ($CertElement.Certificate.Subject -match 'CN=([^,]+)') { $Matches[1].Trim() } else { $CertElement.Certificate.Thumbprint }
                $AIAUrls = if ($urls = Get-CertExtensionUrls -Certificate $CertElement.Certificate -Oid '1.3.6.1.5.5.7.1.1') { $urls -join ', ' } else { 'none' }
                if (-not $CertElement.ChainElementStatus) {
                    Write-Host "     OK          : [$Role] $CommonName" -ForegroundColor Green
                }
                else {
                    # Handle revocation statuses as a group - only print UNREACHABLE once per cert
                    # even if both RevocationStatusUnknown and OfflineRevocation are present
                    $RevStatus = $CertElement.ChainElementStatus | Where-Object { $_.Status -in 'Revoked', 'RevocationStatusUnknown', 'OfflineRevocation' } | Select-Object -First 1
                    if ($RevStatus) {
                        switch ($RevStatus.Status) {
                            'Revoked' {
                                Write-Host "     REVOKED     : [$Role] $CommonName [$AIAUrls]" -ForegroundColor Red
                            }
                            default {
                                Write-Host "     UNREACHABLE : [$Role] $CommonName" -ForegroundColor Yellow
                                Write-Host "                   Verify connectivity to: $AIAUrls" -ForegroundColor Yellow
                            }
                        }
                    }
                    # Handle all other (non-revocation) statuses individually
                    foreach ($Status in $CertElement.ChainElementStatus | Where-Object { $_.Status -notin 'Revoked', 'RevocationStatusUnknown', 'OfflineRevocation' }) {
                        Write-Host "     $($Status.Status.ToString().PadRight(12)): [$Role] $CommonName : $($Status.StatusInformation.Trim())" -ForegroundColor Red
                    }
                }
            }
            # Notify if Windows resolved a different chain path than the server sent
            $resolvedThumbs = $CertChainVal.ChainElements | ForEach-Object { $_.Certificate.Thumbprint }
            $diff = $Script:ServerSentChain | Where-Object { $_.Thumbprint -notin $resolvedThumbs }
            if ($diff) {
                Write-Host "`nWindows resolved a different trust path; $($diff.Count) server-sent cert(s) were not used$(if (-not $ShowAllCerts) { ' (use -ShowAllCerts to see which)' })." -ForegroundColor DarkGray
                if ($ShowAllCerts) {
                    foreach ($excludedCert in $diff) {
                        $excludedCommonName = if ($excludedCert.Subject -match 'CN=([^,]+)') { $Matches[1].Trim() } else { $excludedCert.Thumbprint }
                        Write-Host "     Not used    : $excludedCommonName [$($excludedCert.Thumbprint)]" -ForegroundColor DarkGray
                    }
                }
            }
        }
        finally {
            $CertChainVal.Dispose()
        }

        # This is the SslPolicyErrors value the OS reported during the TLS handshake (captured in the callback).
        # This WILL catch: RemoteCertificateChainErrors from an untrusted/replaced cert
        # (e.g. TLS inspection proxy) and RemoteCertificateNameMismatch.
        $cleanPolicy = $Script:SslPolicyErrors -eq [System.Net.Security.SslPolicyErrors]::None
        Write-Host ""
        if ($cleanPolicy) {
            Write-Host "SSL Policy       : Passed" -ForegroundColor Green
        }
        else {
            Write-Host "SSL Policy       : FAILED - $($Script:SslPolicyErrors)" -ForegroundColor Red
            Write-Host "   Common causes:" -ForegroundColor Yellow
            Write-Host "   - TLS inspection proxy replacing the certificate (RemoteCertificateChainErrors)" -ForegroundColor Yellow
            Write-Host "   - Certificate name mismatch detected by OS before callback (RemoteCertificateNameMismatch)" -ForegroundColor Yellow
        }
    }
    #endregion
}
else {
    Write-Host "`nSkipping certificate checks: scheme '$($URI.Scheme)' is not https." -ForegroundColor Yellow
}

# Pause to ensure the user can read the output before the console closes
Read-Host "Press Enter to exit..."