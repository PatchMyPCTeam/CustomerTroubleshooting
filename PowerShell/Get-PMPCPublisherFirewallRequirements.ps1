<#
.SYNOPSIS
    Generates a tailored list of firewall requirements based on products enabled in the Patch My PC Publisher.

.DESCRIPTION
    Reads the Settings.xml from the Patch My PC Publishing Service installation and extracts all enabled
    product names across all tabs. These product names are then cross-referenced against a CSV containing 
    the domains, ports, and protocols required to download updates for each product. The result is a
    filtered list of only the firewall rules relevant to the products configured in the customer's environment.

    Related KB article: https://patchmypc.com/kb/list-domains-firewall-allowlist-when/

    Script must run on the same machine where the Patch My PC Publishing Service is installed.

.PARAMETER PMPCFirewallAllowlistCsv
    A URI pointing to the CSV file that maps Patch My PC product names to their required domains, ports,
    and protocols. Accepts either an HTTPS URL or a local file path.

    Defaults to the Patch My PC hosted allowlist CSV:
    https://content.patchmypc.com/downloads/csv/PatchMyPC-DomainList.csv

    It is also acceptable to supply a local file path, which can be useful in environments where the 
    Patch My PC website is not yet reachable.

.EXAMPLE
    .\Get-PublisherFirewallRequirements.ps1

    Runs the script using the default Patch My PC hosted CSV to retrieve the latest firewall requirements
    for all products enabled in the local Publisher's Settings.xml.

.EXAMPLE
    .\Get-PublisherFirewallRequirements.ps1 -PMPCFirewallAllowlistCsv 'C:\Temp\PatchMyPC-DomainList.csv'

    Runs the script using a locally cached copy of the firewall allowlist CSV, useful in environments
    where the Patch My PC website is not yet reachable.
#>
param(
    [Parameter()]
    [ValidateScript({ 
        if ($_.IsFile) {
            if (Test-Path -Path $_.LocalPath -ErrorAction 'Stop') { 
                return $true 
            }
            else { 
                throw ('File not found: {0}' -f $_.LocalPath) 
            }
        }
        else {
            try {
                $Response = Invoke-WebRequest -Uri $_ -Method Head -UseBasicParsing -ErrorAction 'Stop'
                if ($Response.StatusCode -ne 200) {
                    throw ('{0} is not accessible. Status code: {1}' -f $_, $Response.StatusCode)
                }
            }
            catch {
                throw ('Invalid URL or inaccessible: {0}' -f $_)
            }
        }
     })]
    [System.Uri]$PMPCFirewallAllowlistCsv = 'https://content.patchmypc.com/downloads/csv/PatchMyPC-DomainList.csv'
)

function Get-InstalledSoftware {
    param(
        [Parameter(Mandatory)]
        [String]$DisplayName
    )

    $PropertyNames = 'DisplayName', 'DisplayVersion', 'PSChildName', 'Publisher', 'InstallDate', 'InstallLocation', 'WindowsInstaller'

    $AllFoundObjects = Get-ItemProperty -Path 'registry::HKEY_LOCAL_MACHINE\Software\Microsoft\Windows\CurrentVersion\Uninstall\*' -Name $propertyNames -ErrorAction SilentlyContinue

    foreach ($Result in $AllFoundObjects) {
        if ($Result.DisplayName -notlike $DisplayName) {
            #Write-Verbose ('Skipping {0} as name does not match {1}' -f $Result.DisplayName, $DisplayName)
            continue
        }

        if ([bool]$Result.WindowsInstaller -ne [bool]1) {
            continue
        }

        $Result | Select-Object -Property $PropertyNames
    }
}

$Publisher = Get-InstalledSoftware -DisplayName 'Patch My PC Publishing Service'
if ([String]::IsNullOrEmpty($Publisher)) {
    throw 'Patch My PC Publishing Service is not installed.'
}
$SettingsXmlPath = '{0}\Settings.xml' -f $Publisher.InstallLocation
if (-not (Test-Path -Path $SettingsXmlPath)) {
    throw 'Settings.xml not found at {0}' -f $SettingsXmlPath
}
else {
    $Settings = [xml](Get-Content $SettingsXmlPath -ErrorAction 'Stop')
}

if ($PMPCFirewallAllowlistCsv.HostNameType -eq 'Dns') {
    $TmpFile = New-TemporaryFile
    Invoke-WebRequest -Uri $PMPCFirewallAllowlistCsv -UseBasicParsing -OutFile $TmpFile -ErrorAction 'Stop'
    [System.Uri]$PMPCFirewallAllowlistCsv = [String]$TmpFile
}

$DomainList = @{}
Import-Csv -Path $PMPCFirewallAllowlistCsv.LocalPath -ErrorAction 'Stop' | ForEach-Object {
    $DomainList[$_.Product] = [PSCustomObject]@{ 
        Domain = $_.Host 
        Port = $_.Port
        Scheme = $_.Scheme
    }
}

$Products = foreach ($Type in 'SearchPatterns', 'Packages', 'IntuneTenants') {

    if ($Type -eq 'IntuneTenants') {
        foreach ($Tenant in $Settings.'PatchMyPC-Settings'.$Type.Tenant) {
            foreach ($_Type in 'Applications','Updates') {
                foreach ($SearchPattern in $Tenant.$_Type.SearchPattern) {
                    [PSCustomObject]@{
                        FoundIn = "IntuneTenant-$($Tenant.FriendlyName)-$_Type"
                        Vendor = $SearchPattern.vendor
                        VendorId = $SearchPattern.vendorId
                        Product = $SearchPattern.product
                        ProductId = $SearchPattern.productId
                        Domain = $DomainList[$SearchPattern.product].Domain
                        Port = $DomainList[$SearchPattern.product].Port
                        Scheme = $DomainList[$SearchPattern.product].Scheme
                    }
                }
            }
        }
    }
    else {
        foreach ($SearchPattern in $Settings.'PatchMyPC-Settings'.$Type.SearchPattern) {
            [PSCustomObject]@{
                FoundIn = $Type
                Vendor = $SearchPattern.vendor
                VendorId = $SearchPattern.vendorId
                Product = $SearchPattern.product
                ProductId = $SearchPattern.productId
                Domain = $DomainList[$SearchPattern.product].Domain
                Port = $DomainList[$SearchPattern.product].Port
                Scheme = $DomainList[$SearchPattern.product].Scheme
            }
        }
    }

}

Clear-Variable 'i' -ErrorAction 'SilentlyContinue'

foreach ($item in @(
    [PSCustomObject]@{
        Product = 'Essential Patch My PC service #{0:D2}' -f ++$i
        Domain = 'patchmypc.com'
        Port = 443
        Scheme = 'https'
    },
    [PSCustomObject]@{
        Product = 'Essential Patch My PC service #{0:D2}' -f ++$i
        Domain = 'content.patchmypc.com'
        Port = 443
        Scheme = 'https'
    },
    [PSCustomObject]@{
        Product = 'Essential Patch My PC service #{0:D2}' -f ++$i
        Domain = 'api.patchmypc.com'
        Port = 443
        Scheme = 'https'
    },
    [PSCustomObject]@{
        Product = 'Essential Patch My PC service #{0:D2}' -f ++$i
        Domain = 'portal.patchmypc.com'
        Port = 443
        Scheme = 'https'
    },
    [PSCustomObject]@{
        Product = 'Essential Patch My PC service #{0:D2}' -f ++$i
        Domain = 'us.portal.patchmypc.com'
        Port = 443
        Scheme = 'https'
    },
    [PSCustomObject]@{
        Product = 'Essential Patch My PC service #{0:D2}' -f ++$i
        Domain = 'eu.portal.patchmypc.com'
        Port = 443
        Scheme = 'https'
    },
    [PSCustomObject]@{
        Product = 'Essential Patch My PC service #{0:D2}' -f ++$i
        Domain = '*.windows.net'
        Port = 443
        Scheme = 'https'
    },
    [PSCustomObject]@{
        Product = 'Essential Patch My PC service #{0:D2}' -f ++$i
        Domain = 'login.microsoftonline.com'
        Port = 443
        Scheme = 'https'
    },
    [PSCustomObject]@{
        Product = 'Essential Patch My PC service #{0:D2}' -f ++$i
        Domain = '*.digicert.com'
        Port = 80
        Scheme = 'http'
    },
    [PSCustomObject]@{
        Product = 'Essential Patch My PC service #{0:D2}' -f ++$i
        Domain = 'timestamp.digicert.com'
        Port = 80
        Scheme = 'https'
    },
    [PSCustomObject]@{
        Product = 'Essential Patch My PC service #{0:D2}' -f ++$i
        Domain = 'ocsp.digicert.com'
        Port = 80
        Scheme = 'https'
    }
)) {
    $Products += $item
}

$Products | Sort-Object -Property 'Product' -Unique | Select-Object -Property 'Product', 'Domain', 'Port', 'Scheme'

# SIG # Begin signature block
# MIIovgYJKoZIhvcNAQcCoIIorzCCKKsCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBzbRYCV6H+3DkA
# LmKzCTIze3dXPAmu3z9oOAkeId7b7qCCIbswggWNMIIEdaADAgECAhAOmxiO+dAt
# 5+/bUOIIQBhaMA0GCSqGSIb3DQEBDAUAMGUxCzAJBgNVBAYTAlVTMRUwEwYDVQQK
# EwxEaWdpQ2VydCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xJDAiBgNV
# BAMTG0RpZ2lDZXJ0IEFzc3VyZWQgSUQgUm9vdCBDQTAeFw0yMjA4MDEwMDAwMDBa
# Fw0zMTExMDkyMzU5NTlaMGIxCzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdpQ2Vy
# dCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xITAfBgNVBAMTGERpZ2lD
# ZXJ0IFRydXN0ZWQgUm9vdCBHNDCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoC
# ggIBAL/mkHNo3rvkXUo8MCIwaTPswqclLskhPfKK2FnC4SmnPVirdprNrnsbhA3E
# MB/zG6Q4FutWxpdtHauyefLKEdLkX9YFPFIPUh/GnhWlfr6fqVcWWVVyr2iTcMKy
# unWZanMylNEQRBAu34LzB4TmdDttceItDBvuINXJIB1jKS3O7F5OyJP4IWGbNOsF
# xl7sWxq868nPzaw0QF+xembud8hIqGZXV59UWI4MK7dPpzDZVu7Ke13jrclPXuU1
# 5zHL2pNe3I6PgNq2kZhAkHnDeMe2scS1ahg4AxCN2NQ3pC4FfYj1gj4QkXCrVYJB
# MtfbBHMqbpEBfCFM1LyuGwN1XXhm2ToxRJozQL8I11pJpMLmqaBn3aQnvKFPObUR
# WBf3JFxGj2T3wWmIdph2PVldQnaHiZdpekjw4KISG2aadMreSx7nDmOu5tTvkpI6
# nj3cAORFJYm2mkQZK37AlLTSYW3rM9nF30sEAMx9HJXDj/chsrIRt7t/8tWMcCxB
# YKqxYxhElRp2Yn72gLD76GSmM9GJB+G9t+ZDpBi4pncB4Q+UDCEdslQpJYls5Q5S
# UUd0viastkF13nqsX40/ybzTQRESW+UQUOsxxcpyFiIJ33xMdT9j7CFfxCBRa2+x
# q4aLT8LWRV+dIPyhHsXAj6KxfgommfXkaS+YHS312amyHeUbAgMBAAGjggE6MIIB
# NjAPBgNVHRMBAf8EBTADAQH/MB0GA1UdDgQWBBTs1+OC0nFdZEzfLmc/57qYrhwP
# TzAfBgNVHSMEGDAWgBRF66Kv9JLLgjEtUYunpyGd823IDzAOBgNVHQ8BAf8EBAMC
# AYYweQYIKwYBBQUHAQEEbTBrMCQGCCsGAQUFBzABhhhodHRwOi8vb2NzcC5kaWdp
# Y2VydC5jb20wQwYIKwYBBQUHMAKGN2h0dHA6Ly9jYWNlcnRzLmRpZ2ljZXJ0LmNv
# bS9EaWdpQ2VydEFzc3VyZWRJRFJvb3RDQS5jcnQwRQYDVR0fBD4wPDA6oDigNoY0
# aHR0cDovL2NybDMuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0QXNzdXJlZElEUm9vdENB
# LmNybDARBgNVHSAECjAIMAYGBFUdIAAwDQYJKoZIhvcNAQEMBQADggEBAHCgv0Nc
# Vec4X6CjdBs9thbX979XB72arKGHLOyFXqkauyL4hxppVCLtpIh3bb0aFPQTSnov
# Lbc47/T/gLn4offyct4kvFIDyE7QKt76LVbP+fT3rDB6mouyXtTP0UNEm0Mh65Zy
# oUi0mcudT6cGAxN3J0TU53/oWajwvy8LpunyNDzs9wPHh6jSTEAZNUZqaVSwuKFW
# juyk1T3osdz9HNj0d1pcVIxv76FQPfx2CWiEn2/K2yCNNWAcAgPLILCsWKAOQGPF
# mCLBsln1VWvPJ6tsds5vIy30fnFqI2si/xK4VC0nftg62fC2h5b9W9FcrBjDTZ9z
# twGpn1eqXijiuZQwggawMIIEmKADAgECAhAIrUCyYNKcTJ9ezam9k67ZMA0GCSqG
# SIb3DQEBDAUAMGIxCzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdpQ2VydCBJbmMx
# GTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xITAfBgNVBAMTGERpZ2lDZXJ0IFRy
# dXN0ZWQgUm9vdCBHNDAeFw0yMTA0MjkwMDAwMDBaFw0zNjA0MjgyMzU5NTlaMGkx
# CzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4
# RGlnaUNlcnQgVHJ1c3RlZCBHNCBDb2RlIFNpZ25pbmcgUlNBNDA5NiBTSEEzODQg
# MjAyMSBDQTEwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQDVtC9C0Cit
# eLdd1TlZG7GIQvUzjOs9gZdwxbvEhSYwn6SOaNhc9es0JAfhS0/TeEP0F9ce2vnS
# 1WcaUk8OoVf8iJnBkcyBAz5NcCRks43iCH00fUyAVxJrQ5qZ8sU7H/Lvy0daE6ZM
# swEgJfMQ04uy+wjwiuCdCcBlp/qYgEk1hz1RGeiQIXhFLqGfLOEYwhrMxe6TSXBC
# Mo/7xuoc82VokaJNTIIRSFJo3hC9FFdd6BgTZcV/sk+FLEikVoQ11vkunKoAFdE3
# /hoGlMJ8yOobMubKwvSnowMOdKWvObarYBLj6Na59zHh3K3kGKDYwSNHR7OhD26j
# q22YBoMbt2pnLdK9RBqSEIGPsDsJ18ebMlrC/2pgVItJwZPt4bRc4G/rJvmM1bL5
# OBDm6s6R9b7T+2+TYTRcvJNFKIM2KmYoX7BzzosmJQayg9Rc9hUZTO1i4F4z8ujo
# 7AqnsAMrkbI2eb73rQgedaZlzLvjSFDzd5Ea/ttQokbIYViY9XwCFjyDKK05huzU
# tw1T0PhH5nUwjewwk3YUpltLXXRhTT8SkXbev1jLchApQfDVxW0mdmgRQRNYmtwm
# KwH0iU1Z23jPgUo+QEdfyYFQc4UQIyFZYIpkVMHMIRroOBl8ZhzNeDhFMJlP/2NP
# TLuqDQhTQXxYPUez+rbsjDIJAsxsPAxWEQIDAQABo4IBWTCCAVUwEgYDVR0TAQH/
# BAgwBgEB/wIBADAdBgNVHQ4EFgQUaDfg67Y7+F8Rhvv+YXsIiGX0TkIwHwYDVR0j
# BBgwFoAU7NfjgtJxXWRM3y5nP+e6mK4cD08wDgYDVR0PAQH/BAQDAgGGMBMGA1Ud
# JQQMMAoGCCsGAQUFBwMDMHcGCCsGAQUFBwEBBGswaTAkBggrBgEFBQcwAYYYaHR0
# cDovL29jc3AuZGlnaWNlcnQuY29tMEEGCCsGAQUFBzAChjVodHRwOi8vY2FjZXJ0
# cy5kaWdpY2VydC5jb20vRGlnaUNlcnRUcnVzdGVkUm9vdEc0LmNydDBDBgNVHR8E
# PDA6MDigNqA0hjJodHRwOi8vY3JsMy5kaWdpY2VydC5jb20vRGlnaUNlcnRUcnVz
# dGVkUm9vdEc0LmNybDAcBgNVHSAEFTATMAcGBWeBDAEDMAgGBmeBDAEEATANBgkq
# hkiG9w0BAQwFAAOCAgEAOiNEPY0Idu6PvDqZ01bgAhql+Eg08yy25nRm95RysQDK
# r2wwJxMSnpBEn0v9nqN8JtU3vDpdSG2V1T9J9Ce7FoFFUP2cvbaF4HZ+N3HLIvda
# qpDP9ZNq4+sg0dVQeYiaiorBtr2hSBh+3NiAGhEZGM1hmYFW9snjdufE5BtfQ/g+
# lP92OT2e1JnPSt0o618moZVYSNUa/tcnP/2Q0XaG3RywYFzzDaju4ImhvTnhOE7a
# brs2nfvlIVNaw8rpavGiPttDuDPITzgUkpn13c5UbdldAhQfQDN8A+KVssIhdXNS
# y0bYxDQcoqVLjc1vdjcshT8azibpGL6QB7BDf5WIIIJw8MzK7/0pNVwfiThV9zeK
# iwmhywvpMRr/LhlcOXHhvpynCgbWJme3kuZOX956rEnPLqR0kq3bPKSchh/jwVYb
# KyP/j7XqiHtwa+aguv06P0WmxOgWkVKLQcBIhEuWTatEQOON8BUozu3xGFYHKi8Q
# xAwIZDwzj64ojDzLj4gLDb879M4ee47vtevLt/B3E+bnKD+sEq6lLyJsQfmCXBVm
# zGwOysWGw/YmMwwHS6DTBwJqakAwSEs0qFEgu60bhQjiWQ1tygVQK+pKHJ6l/aCn
# HwZ05/LWUpD9r4VIIflXO7ScA+2GRfS0YW6/aOImYIbqyK+p/pQd52MbOoZWeE4w
# gga0MIIEnKADAgECAhANx6xXBf8hmS5AQyIMOkmGMA0GCSqGSIb3DQEBCwUAMGIx
# CzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdpQ2VydCBJbmMxGTAXBgNVBAsTEHd3
# dy5kaWdpY2VydC5jb20xITAfBgNVBAMTGERpZ2lDZXJ0IFRydXN0ZWQgUm9vdCBH
# NDAeFw0yNTA1MDcwMDAwMDBaFw0zODAxMTQyMzU5NTlaMGkxCzAJBgNVBAYTAlVT
# MRcwFQYDVQQKEw5EaWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1
# c3RlZCBHNCBUaW1lU3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTEwggIi
# MA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQC0eDHTCphBcr48RsAcrHXbo0Zo
# dLRRF51NrY0NlLWZloMsVO1DahGPNRcybEKq+RuwOnPhof6pvF4uGjwjqNjfEvUi
# 6wuim5bap+0lgloM2zX4kftn5B1IpYzTqpyFQ/4Bt0mAxAHeHYNnQxqXmRinvuNg
# xVBdJkf77S2uPoCj7GH8BLuxBG5AvftBdsOECS1UkxBvMgEdgkFiDNYiOTx4OtiF
# cMSkqTtF2hfQz3zQSku2Ws3IfDReb6e3mmdglTcaarps0wjUjsZvkgFkriK9tUKJ
# m/s80FiocSk1VYLZlDwFt+cVFBURJg6zMUjZa/zbCclF83bRVFLeGkuAhHiGPMvS
# GmhgaTzVyhYn4p0+8y9oHRaQT/aofEnS5xLrfxnGpTXiUOeSLsJygoLPp66bkDX1
# ZlAeSpQl92QOMeRxykvq6gbylsXQskBBBnGy3tW/AMOMCZIVNSaz7BX8VtYGqLt9
# MmeOreGPRdtBx3yGOP+rx3rKWDEJlIqLXvJWnY0v5ydPpOjL6s36czwzsucuoKs7
# Yk/ehb//Wx+5kMqIMRvUBDx6z1ev+7psNOdgJMoiwOrUG2ZdSoQbU2rMkpLiQ6bG
# RinZbI4OLu9BMIFm1UUl9VnePs6BaaeEWvjJSjNm2qA+sdFUeEY0qVjPKOWug/G6
# X5uAiynM7Bu2ayBjUwIDAQABo4IBXTCCAVkwEgYDVR0TAQH/BAgwBgEB/wIBADAd
# BgNVHQ4EFgQU729TSunkBnx6yuKQVvYv1Ensy04wHwYDVR0jBBgwFoAU7NfjgtJx
# XWRM3y5nP+e6mK4cD08wDgYDVR0PAQH/BAQDAgGGMBMGA1UdJQQMMAoGCCsGAQUF
# BwMIMHcGCCsGAQUFBwEBBGswaTAkBggrBgEFBQcwAYYYaHR0cDovL29jc3AuZGln
# aWNlcnQuY29tMEEGCCsGAQUFBzAChjVodHRwOi8vY2FjZXJ0cy5kaWdpY2VydC5j
# b20vRGlnaUNlcnRUcnVzdGVkUm9vdEc0LmNydDBDBgNVHR8EPDA6MDigNqA0hjJo
# dHRwOi8vY3JsMy5kaWdpY2VydC5jb20vRGlnaUNlcnRUcnVzdGVkUm9vdEc0LmNy
# bDAgBgNVHSAEGTAXMAgGBmeBDAEEAjALBglghkgBhv1sBwEwDQYJKoZIhvcNAQEL
# BQADggIBABfO+xaAHP4HPRF2cTC9vgvItTSmf83Qh8WIGjB/T8ObXAZz8OjuhUxj
# aaFdleMM0lBryPTQM2qEJPe36zwbSI/mS83afsl3YTj+IQhQE7jU/kXjjytJgnn0
# hvrV6hqWGd3rLAUt6vJy9lMDPjTLxLgXf9r5nWMQwr8Myb9rEVKChHyfpzee5kH0
# F8HABBgr0UdqirZ7bowe9Vj2AIMD8liyrukZ2iA/wdG2th9y1IsA0QF8dTXqvcnT
# mpfeQh35k5zOCPmSNq1UH410ANVko43+Cdmu4y81hjajV/gxdEkMx1NKU4uHQcKf
# ZxAvBAKqMVuqte69M9J6A47OvgRaPs+2ykgcGV00TYr2Lr3ty9qIijanrUR3anzE
# wlvzZiiyfTPjLbnFRsjsYg39OlV8cipDoq7+qNNjqFzeGxcytL5TTLL4ZaoBdqbh
# OhZ3ZRDUphPvSRmMThi0vw9vODRzW6AxnJll38F0cuJG7uEBYTptMSbhdhGQDpOX
# gpIUsWTjd6xpR6oaQf/DJbg3s6KCLPAlZ66RzIg9sC+NJpud/v4+7RWsWCiKi9EO
# LLHfMR2ZyJ/+xhCx9yHbxtl5TPau1j/1MIDpMPx0LckTetiSuEtQvLsNz3Qbp7wG
# WqbIiOWCnb5WqxL3/BAPvIXKUjPSxyZsq8WhbaM2tszWkPZPubdcMIIG7TCCBNWg
# AwIBAgIQCoDvGEuN8QWC0cR2p5V0aDANBgkqhkiG9w0BAQsFADBpMQswCQYDVQQG
# EwJVUzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4xQTA/BgNVBAMTOERpZ2lDZXJ0
# IFRydXN0ZWQgRzQgVGltZVN0YW1waW5nIFJTQTQwOTYgU0hBMjU2IDIwMjUgQ0Ex
# MB4XDTI1MDYwNDAwMDAwMFoXDTM2MDkwMzIzNTk1OVowYzELMAkGA1UEBhMCVVMx
# FzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMTswOQYDVQQDEzJEaWdpQ2VydCBTSEEy
# NTYgUlNBNDA5NiBUaW1lc3RhbXAgUmVzcG9uZGVyIDIwMjUgMTCCAiIwDQYJKoZI
# hvcNAQEBBQADggIPADCCAgoCggIBANBGrC0Sxp7Q6q5gVrMrV7pvUf+GcAoB38o3
# zBlCMGMyqJnfFNZx+wvA69HFTBdwbHwBSOeLpvPnZ8ZN+vo8dE2/pPvOx/Vj8Tch
# TySA2R4QKpVD7dvNZh6wW2R6kSu9RJt/4QhguSssp3qome7MrxVyfQO9sMx6ZAWj
# FDYOzDi8SOhPUWlLnh00Cll8pjrUcCV3K3E0zz09ldQ//nBZZREr4h/GI6Dxb2Uo
# yrN0ijtUDVHRXdmncOOMA3CoB/iUSROUINDT98oksouTMYFOnHoRh6+86Ltc5zjP
# KHW5KqCvpSduSwhwUmotuQhcg9tw2YD3w6ySSSu+3qU8DD+nigNJFmt6LAHvH3KS
# uNLoZLc1Hf2JNMVL4Q1OpbybpMe46YceNA0LfNsnqcnpJeItK/DhKbPxTTuGoX7w
# JNdoRORVbPR1VVnDuSeHVZlc4seAO+6d2sC26/PQPdP51ho1zBp+xUIZkpSFA8vW
# doUoHLWnqWU3dCCyFG1roSrgHjSHlq8xymLnjCbSLZ49kPmk8iyyizNDIXj//cOg
# rY7rlRyTlaCCfw7aSUROwnu7zER6EaJ+AliL7ojTdS5PWPsWeupWs7NpChUk555K
# 096V1hE0yZIXe+giAwW00aHzrDchIc2bQhpp0IoKRR7YufAkprxMiXAJQ1XCmnCf
# gPf8+3mnAgMBAAGjggGVMIIBkTAMBgNVHRMBAf8EAjAAMB0GA1UdDgQWBBTkO/zy
# Me39/dfzkXFjGVBDz2GM6DAfBgNVHSMEGDAWgBTvb1NK6eQGfHrK4pBW9i/USezL
# TjAOBgNVHQ8BAf8EBAMCB4AwFgYDVR0lAQH/BAwwCgYIKwYBBQUHAwgwgZUGCCsG
# AQUFBwEBBIGIMIGFMCQGCCsGAQUFBzABhhhodHRwOi8vb2NzcC5kaWdpY2VydC5j
# b20wXQYIKwYBBQUHMAKGUWh0dHA6Ly9jYWNlcnRzLmRpZ2ljZXJ0LmNvbS9EaWdp
# Q2VydFRydXN0ZWRHNFRpbWVTdGFtcGluZ1JTQTQwOTZTSEEyNTYyMDI1Q0ExLmNy
# dDBfBgNVHR8EWDBWMFSgUqBQhk5odHRwOi8vY3JsMy5kaWdpY2VydC5jb20vRGln
# aUNlcnRUcnVzdGVkRzRUaW1lU3RhbXBpbmdSU0E0MDk2U0hBMjU2MjAyNUNBMS5j
# cmwwIAYDVR0gBBkwFzAIBgZngQwBBAIwCwYJYIZIAYb9bAcBMA0GCSqGSIb3DQEB
# CwUAA4ICAQBlKq3xHCcEua5gQezRCESeY0ByIfjk9iJP2zWLpQq1b4URGnwWBdEZ
# D9gBq9fNaNmFj6Eh8/YmRDfxT7C0k8FUFqNh+tshgb4O6Lgjg8K8elC4+oWCqnU/
# ML9lFfim8/9yJmZSe2F8AQ/UdKFOtj7YMTmqPO9mzskgiC3QYIUP2S3HQvHG1FDu
# +WUqW4daIqToXFE/JQ/EABgfZXLWU0ziTN6R3ygQBHMUBaB5bdrPbF6MRYs03h4o
# bEMnxYOX8VBRKe1uNnzQVTeLni2nHkX/QqvXnNb+YkDFkxUGtMTaiLR9wjxUxu2h
# ECZpqyU1d0IbX6Wq8/gVutDojBIFeRlqAcuEVT0cKsb+zJNEsuEB7O7/cuvTQasn
# M9AWcIQfVjnzrvwiCZ85EE8LUkqRhoS3Y50OHgaY7T/lwd6UArb+BOVAkg2oOvol
# /DJgddJ35XTxfUlQ+8Hggt8l2Yv7roancJIFcbojBcxlRcGG0LIhp6GvReQGgMgY
# xQbV1S3CrWqZzBt1R9xJgKf47CdxVRd/ndUlQ05oxYy2zRWVFjF7mcr4C34Mj3oc
# CVccAvlKV9jEnstrniLvUxxVZE/rptb7IRE2lskKPIJgbaP5t2nGj/ULLi49xTcB
# ZU8atufk+EMF/cWuiC7POGT75qaL6vdCvHlshtjdNXOCIUjsarfNZzCCB8kwggWx
# oAMCAQICEAPSjq0JsKWh6sO6DavkqBwwDQYJKoZIhvcNAQELBQAwaTELMAkGA1UE
# BhMCVVMxFzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMUEwPwYDVQQDEzhEaWdpQ2Vy
# dCBUcnVzdGVkIEc0IENvZGUgU2lnbmluZyBSU0E0MDk2IFNIQTM4NCAyMDIxIENB
# MTAeFw0yNTA4MjIwMDAwMDBaFw0yODA5MTYyMzU5NTlaMIHRMRMwEQYLKwYBBAGC
# NzwCAQMTAlVTMRkwFwYLKwYBBAGCNzwCAQITCENvbG9yYWRvMR0wGwYDVQQPDBRQ
# cml2YXRlIE9yZ2FuaXphdGlvbjEUMBIGA1UEBRMLMjAxMzE2MzgzMjcxCzAJBgNV
# BAYTAlVTMREwDwYDVQQIEwhDb2xvcmFkbzEUMBIGA1UEBxMLQ2FzdGxlIFJvY2sx
# GTAXBgNVBAoTEFBhdGNoIE15IFBDLCBMTEMxGTAXBgNVBAMTEFBhdGNoIE15IFBD
# LCBMTEMwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQC8KLG0T7/YRgyQ
# USv/gkR1AlO3cdHAGRKxr8LqKWqzwbfaGvsisfOOe8yIETe8vIGFy+GECd8msOq7
# SmkWHJgEdvy7V1FgMkOzuyoAk/wIzgvdnbjc9AkXj01IQgRYzddhtYbrCZ8UoK8f
# qP0xHNFBWfleqUTHMoagBunstL/oB4WVbHelh0+6V1kcL8oVAefahypFKHwTXvdv
# bJz4d166/GlrWhVDJVwyYK5H8xgBCp1KDpXq3rjpqEy3/PuuDvJN45oxIlg9JyU0
# OTfyjeqslSlIwhVxSngOz34LNnJn6dokVWYFqbf+7mb1Jh5LcRk93ZdlezUDqTTN
# 3ZejP/uOxDRcmZjEVuBZtTGvWPXhBIJUUcfEiiGLRI59H9BYVDOdNxIUHbQ3SzwF
# L4iJt2zW1ELxFhcI2Sr6kRIX1lOm0UwiMSbN9M17pzkhUmegSAtPoPl94gUHTvAa
# VWa5ryIkznOR88CT1sdn6+Omke0Zlluz1YkzxWsF61SqiKCfSlvSxRNSWiydGs3C
# WCMpRNnMXzGoP+HYZBsQpqvX/0JcqLFln3hQIPhN61j+tZAjsv8Whmozwf7dPlU6
# CS76tbPF5/1Y1WGUcyHHqf0gKLabxi26w9T1YhmniA6XcC7FWO1fmcH2E2OXGw2k
# /x364zwzD9LikFk1JM27/UCCETaEcQIDAQABo4ICAjCCAf4wHwYDVR0jBBgwFoAU
# aDfg67Y7+F8Rhvv+YXsIiGX0TkIwHQYDVR0OBBYEFLEdM/t5ETHFdxo9vpEr2GV1
# 10QfMD0GA1UdIAQ2MDQwMgYFZ4EMAQMwKTAnBggrBgEFBQcCARYbaHR0cDovL3d3
# dy5kaWdpY2VydC5jb20vQ1BTMA4GA1UdDwEB/wQEAwIHgDATBgNVHSUEDDAKBggr
# BgEFBQcDAzCBtQYDVR0fBIGtMIGqMFOgUaBPhk1odHRwOi8vY3JsMy5kaWdpY2Vy
# dC5jb20vRGlnaUNlcnRUcnVzdGVkRzRDb2RlU2lnbmluZ1JTQTQwOTZTSEEzODQy
# MDIxQ0ExLmNybDBToFGgT4ZNaHR0cDovL2NybDQuZGlnaWNlcnQuY29tL0RpZ2lD
# ZXJ0VHJ1c3RlZEc0Q29kZVNpZ25pbmdSU0E0MDk2U0hBMzg0MjAyMUNBMS5jcmww
# gZQGCCsGAQUFBwEBBIGHMIGEMCQGCCsGAQUFBzABhhhodHRwOi8vb2NzcC5kaWdp
# Y2VydC5jb20wXAYIKwYBBQUHMAKGUGh0dHA6Ly9jYWNlcnRzLmRpZ2ljZXJ0LmNv
# bS9EaWdpQ2VydFRydXN0ZWRHNENvZGVTaWduaW5nUlNBNDA5NlNIQTM4NDIwMjFD
# QTEuY3J0MAkGA1UdEwQCMAAwDQYJKoZIhvcNAQELBQADggIBAJ2HuFdgLTtj5K7n
# zrgKI+rS/k0Rxfh/w3Bn1q8FwGfUfBMYtiFgb1+ms45VRCD/WWAoiyu53dpoo6Tv
# 3OqHeIrWu3dDy82muUWW06zng5mux1gmH/yCwmAQHwRCGsYMmwWpS6YhEZZFN7gH
# /1DibELwWWbM7Et3O7y1BGgV5JVGMjgDfNn3T28APncrZlmZjpvnPi+lWPRvrgEp
# wPDJHZQd2cqzHbuwmDLGxNN1+gJBg9WTeg44UXv7P9be2ADp7j6e94XCzVoBEXrW
# IrfkJpfoMilFs09TCBHs1U3ykC48q9MZbLqxr9747K5/9svw5aw5d+9Kgp/VuuX0
# Y87XD02B54p9MDzUJZ2mBVPDaixlS4V8M841yxzFlLjBKGhTQG8D9UsgZy3vPTv6
# Lgybsi3ZiBV0bbOFZYZ6fC8RHDCJd9efmIjCoBY2H2xQK3HvT2rJVlZ7/OmzPjc6
# 0a97GZkv+KxWqif4b8T9nAzDzkrcxfRXG7YT5tUiYq3cpa7Zvh8UEz9DQ/X6UUjv
# hIbF4/8PM3UykMaV7awaOS1xOJc4/PHbg6k11MR1iu8GEAI34VGL/Y8riHm3VacW
# 27a0LG4iQt3Xmqv1KjsXKaRi/d85gz/vLH1uaf4TEUyQNlxln8bRe0swBwsDq69U
# Jyb6r9kS76ZAICpyU+o5ItPQ6ygTMYIGWTCCBlUCAQEwfTBpMQswCQYDVQQGEwJV
# UzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4xQTA/BgNVBAMTOERpZ2lDZXJ0IFRy
# dXN0ZWQgRzQgQ29kZSBTaWduaW5nIFJTQTQwOTYgU0hBMzg0IDIwMjEgQ0ExAhAD
# 0o6tCbCloerDug2r5KgcMA0GCWCGSAFlAwQCAQUAoIGEMBgGCisGAQQBgjcCAQwx
# CjAIoAKAAKECgAAwGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwHAYKKwYBBAGC
# NwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEIOxdO7VTlu/9DsNx
# vRR2t6z9MxMU3Fu5RUKxMoX4C8rKMA0GCSqGSIb3DQEBAQUABIICAI8oAMJPu0EE
# S+mCpntmAyCg+l5tHCZEQtnG6dcYCPC6UbBo+roJWa33xtYQw0y47t5lFyE2+n6z
# GuHflFe/4Dl3FkYp2RtRckuRRbyTUBL4/rqzlwlhPO8IVn6YrDbbyGJdJm0ppY4M
# /jJCIt11sSvdHC3NrdaAINWVRXoeGuIA5xptCZ4DfmCBhvS48/u2jVS7HeIBz2Ps
# DeUxPQsYrriJYRUmBZfEG9MHc3+tDKcdRYgqNOU8Cbk0LCrmmU8OCVdPfWhSc8Im
# rVZx1nE3pEhcdjqTfk1odfyFqmfEXiZTXLyCB7zRDSMHbz1lZA8/qk+w1slgDe8K
# t7UlMHK446UE8Bz4gzzEEd7hN6l7DH1c/0vo7zi08X3Sf1KyaJvMm2swQtplrsHT
# B5qA5Ceyrf77ZMBWd6bQq+gT1ZgsR7EJFoJMp0BAjj8Uuk1TfY5fw6vdKjS+Jww1
# S32IB9Vd3HYS4jIMyckMTg40w0V5GLi0Y86vnmZNwrFboEbo5ZELm6vKyeyL8GQr
# m3QsGNn6wbq3TqjDYH+9HDSc697FAjspvvvymNdZTp4Ib5usrZ7I7Tftia5rRi1R
# ID6tYDXvPnuJQkiknIsoljqj4UNuGTjX47DVbPPgdaw/URs+g6DlRoEcuq6OC77o
# 24LnThQT7YOzaX/ItedkZTPb5g90IXZ/oYIDJjCCAyIGCSqGSIb3DQEJBjGCAxMw
# ggMPAgEBMH0waTELMAkGA1UEBhMCVVMxFzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMu
# MUEwPwYDVQQDEzhEaWdpQ2VydCBUcnVzdGVkIEc0IFRpbWVTdGFtcGluZyBSU0E0
# MDk2IFNIQTI1NiAyMDI1IENBMQIQCoDvGEuN8QWC0cR2p5V0aDANBglghkgBZQME
# AgEFAKBpMBgGCSqGSIb3DQEJAzELBgkqhkiG9w0BBwEwHAYJKoZIhvcNAQkFMQ8X
# DTI2MDQwMTE3MzI0NlowLwYJKoZIhvcNAQkEMSIEINboPxbtIqj6O7X+IT1LJy8t
# wYbcConlKHVvHQTE+Y8fMA0GCSqGSIb3DQEBAQUABIICAArWmkdMWhE2/0hmWhC8
# 2UX4rXNq4tS5Z1W0x+tiXBbqmS+JILuU8zdEK7REg28UMPnAj+8pbdTQaC/XePqQ
# qOY2YeQz6oL73bqZWAnI8zgH4ukAb+j/WxUWVv4frT9GK/sZDG6WEHXC9yUfn5uC
# zL+hyPq2adJanSTXDGI/oljPcF7TUIEIqpA7tfxExvYQ2vvsR2gUclDRiXLNHzyd
# H3FSiyuuoF4V/koRrm6TnMmQmB0YZ5LCIRO6e5pba7OaU3f1NW3PLdyknMOWiV4v
# 3yLALJfLnGoPemAuARPFIGNT3Rk3mFqeJ6Q29vQuJaC0CayBQiMQUcS5QXyPMcXW
# sxmBX6C93EcdrgO6Y+PewUv8gW46I2CXczn4ozURR1KUzIUGrkrtZlNsg8H75yY2
# PtpTLhePZMoBlT4aN7M8QaYluBglIROzn2qD9k+N8czC7vEPKnCtjKsxXJVaxaEG
# kwiM5GxJy7WBM09Q/OCZad6RzUGu+z+hKjE9jIUUjX1ArFfvcCNoJ0gYjItA7M0i
# FJs2dwfMzULB2BgatKUV13QfXSwklvfU7ls9RQofR0tc2FwUEV2h1YCM801CZ3yz
# KuQOgCmMuXzJRCM9C0J9VykoEe5FHHxoB/PTY+POU/FLuxEnAEbq0Izqt1+SHvMX
# UwqpCMSHfLoX2xE3UnrI1CHk
# SIG # End signature block
