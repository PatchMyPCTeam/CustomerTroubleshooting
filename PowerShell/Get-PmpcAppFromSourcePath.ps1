<#
.SYNOPSIS
    Query the SMS provider for applications with content sources matching a specified path. 

.DESCRIPTION
    This script queries a Configuration Manager (ConfigMgr) SMS provider for content sources
    matching a given path. It takes a site code, SMS provider, and a path as input parameters
    and uses Windows Management Instrumentation (WMI) to perform the query.

    Instances of SMS_ApplicationLatest are returned

.PARAMETER SiteCode
    The site code of the Configuration Manager site to connect to.

.PARAMETER SMSProvider
    The hostname or IP address of the SMS provider to connect to.

.PARAMETER SourcePath
    The path to be used for constructing the query.

.FUNCTIONALITY
    ConfigMgr, PowerShell

.NOTES
    Author Cody Mathis@PatchMyPC
    Date: 2023-10-27
    Version: 1.0

    ################# IMPORTANT #################
    This script must be run by someone who has access to query the SMS provider for application information.

    ################# DISCLAIMER #################
    Patch My PC provides scripts, macro, and other code examples for illustration only, without warranty 
    either expressed or implied, including but not limited to the implied warranties of merchantability 
    and/or fitness for a particular purpose. This script is provided 'AS IS' and Patch My PC does not 
    guarantee that the following script, macro, or code can or should be used in any situation or that 
    operation of the code will be error-free.

#>

param (
    [Parameter(Mandatory = $true)]
    [string]$SiteCode,
    [Parameter(Mandatory = $true)]
    [string]$SMSProvider,
    [Parameter(Mandatory = $true)]
    [string]$SourcePath
)

function Get-FullHostnameFromSourcePath {
    param (
        [string]$SourcePath
    )

    $firstFolderSeparatorIndex = $SourcePath.Substring(2).IndexOf("\")
    $hostname = $SourcePath.Substring(2, $firstFolderSeparatorIndex)

    return $hostname
}

function Get-NonFqdnHostname {
    param (
        [string]$hostname
    )

    $firstDotInHostname = $hostname.IndexOf(".")
    $newHostname = $hostname

    if ($firstDotInHostname -ne -1) {
        $newHostname = $hostname.Substring(0, $firstDotInHostname)
    }

    return $newHostname
}

function Get-QueryFormattedPath {
    <#
    .SYNOPSIS
        Get a query-formatted path based on the input path. This is a path that is safe for querying WMI.

    .DESCRIPTION
        This function calculates a query-formatted path based on the input path. It extracts the hostname,
        replaces it if a non-FQDN hostname is found, and combines the components to create the final path
        that is safe for querying WMI.

    .PARAMETER SourcePath
        The input path to be formatted.

    .EXAMPLE
        Get-QueryFormattedPath -SourcePath "\\Server\Share\File"
        # Returns "\\Server\Share\File"

    .NOTES
        The function also escapes special characters for use in regular expressions.
    #>
    param (
        [string]$SourcePath
    )

    $folder = [System.IO.DirectoryInfo]::new($SourcePath)
    $rootFolderPath = $folder.Parent.Parent.Parent.FullName
    $lastFolderName = $folder.Name

    try {
        $fullHostname = Get-FullHostnameFromSourcePath $SourcePath
        $newHostname = (Get-NonFqdnHostname $fullHostname) + "%"

        $rootFolderPath = $rootFolderPath -replace [regex]::Escape($fullHostname), $newHostname
    }
    catch {
    }

    return (Join-Path $rootFolderPath "%$lastFolderName") -replace '\\', '\\' -replace '\[', '[[]'
}

# Define the queryFormattedPath by calling the Get-QueryFormattedPath function
$queryFormattedPath = Get-QueryFormattedPath -SourcePath $SourcePath

# Build the WMI query
$contentQuery = "SELECT ContentID, ContentSource, ContentUniqueID, SecurityKey FROM SMS_Content WHERE (ContentSource LIKE '$queryFormattedPath%')"

Write-Host "Querying SMS provider $SMSProvider for content sources matching [InputPath: $SourcePath] [Query: $contentQuery]"

# Execute the query
$contentQueryResults = Get-WmiObject -Query $contentQuery -Namespace "root\sms\site_$SiteCode" -ComputerName $SMSProvider



# Process the results
if ($contentQueryResults) {
    $allMatchingApps = foreach ($appContent in $contentQueryResults) {
        $appQuery = "SELECT * FROM SMS_ApplicationLatest where ModelName = '$($appContent.SecurityKey)'"
        Write-Verbose "Querying SMS provider $SMSProvider for application matching [SecurityKey: $($appContent.SecurityKey)] [Query: $appQuery]"
        $appQueryResults = Get-WmiObject -Query $appQuery -Namespace "root\sms\site_$SiteCode" -ComputerName $SMSProvider
        if ($appQueryResults) {
            $appQueryResults
        }
        else {
            Write-Host "No matching application found for content source $($appContent.SecurityKey)."
        }
    }
    if ($allMatchingApps) {
        $allMatchingApps
    }
    else {
        Write-Host "No matching applications found."
    }
} else {
    Write-Host "No matching content sources found."
}
# SIG # Begin signature block
# MIIovgYJKoZIhvcNAQcCoIIorzCCKKsCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDd3z8aPZZQn9ZQ
# w/6FzRmY/H3Bd+r9bs/FhBfCEYl5EqCCIcEwggWNMIIEdaADAgECAhAOmxiO+dAt
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
# twGpn1eqXijiuZQwggauMIIElqADAgECAhAHNje3JFR82Ees/ShmKl5bMA0GCSqG
# SIb3DQEBCwUAMGIxCzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdpQ2VydCBJbmMx
# GTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xITAfBgNVBAMTGERpZ2lDZXJ0IFRy
# dXN0ZWQgUm9vdCBHNDAeFw0yMjAzMjMwMDAwMDBaFw0zNzAzMjIyMzU5NTlaMGMx
# CzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdpQ2VydCwgSW5jLjE7MDkGA1UEAxMy
# RGlnaUNlcnQgVHJ1c3RlZCBHNCBSU0E0MDk2IFNIQTI1NiBUaW1lU3RhbXBpbmcg
# Q0EwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQDGhjUGSbPBPXJJUVXH
# JQPE8pE3qZdRodbSg9GeTKJtoLDMg/la9hGhRBVCX6SI82j6ffOciQt/nR+eDzMf
# UBMLJnOWbfhXqAJ9/UO0hNoR8XOxs+4rgISKIhjf69o9xBd/qxkrPkLcZ47qUT3w
# 1lbU5ygt69OxtXXnHwZljZQp09nsad/ZkIdGAHvbREGJ3HxqV3rwN3mfXazL6IRk
# tFLydkf3YYMZ3V+0VAshaG43IbtArF+y3kp9zvU5EmfvDqVjbOSmxR3NNg1c1eYb
# qMFkdECnwHLFuk4fsbVYTXn+149zk6wsOeKlSNbwsDETqVcplicu9Yemj052FVUm
# cJgmf6AaRyBD40NjgHt1biclkJg6OBGz9vae5jtb7IHeIhTZgirHkr+g3uM+onP6
# 5x9abJTyUpURK1h0QCirc0PO30qhHGs4xSnzyqqWc0Jon7ZGs506o9UD4L/wojzK
# QtwYSH8UNM/STKvvmz3+DrhkKvp1KCRB7UK/BZxmSVJQ9FHzNklNiyDSLFc1eSuo
# 80VgvCONWPfcYd6T/jnA+bIwpUzX6ZhKWD7TA4j+s4/TXkt2ElGTyYwMO1uKIqjB
# Jgj5FBASA31fI7tk42PgpuE+9sJ0sj8eCXbsq11GdeJgo1gJASgADoRU7s7pXche
# MBK9Rp6103a50g5rmQzSM7TNsQIDAQABo4IBXTCCAVkwEgYDVR0TAQH/BAgwBgEB
# /wIBADAdBgNVHQ4EFgQUuhbZbU2FL3MpdpovdYxqII+eyG8wHwYDVR0jBBgwFoAU
# 7NfjgtJxXWRM3y5nP+e6mK4cD08wDgYDVR0PAQH/BAQDAgGGMBMGA1UdJQQMMAoG
# CCsGAQUFBwMIMHcGCCsGAQUFBwEBBGswaTAkBggrBgEFBQcwAYYYaHR0cDovL29j
# c3AuZGlnaWNlcnQuY29tMEEGCCsGAQUFBzAChjVodHRwOi8vY2FjZXJ0cy5kaWdp
# Y2VydC5jb20vRGlnaUNlcnRUcnVzdGVkUm9vdEc0LmNydDBDBgNVHR8EPDA6MDig
# NqA0hjJodHRwOi8vY3JsMy5kaWdpY2VydC5jb20vRGlnaUNlcnRUcnVzdGVkUm9v
# dEc0LmNybDAgBgNVHSAEGTAXMAgGBmeBDAEEAjALBglghkgBhv1sBwEwDQYJKoZI
# hvcNAQELBQADggIBAH1ZjsCTtm+YqUQiAX5m1tghQuGwGC4QTRPPMFPOvxj7x1Bd
# 4ksp+3CKDaopafxpwc8dB+k+YMjYC+VcW9dth/qEICU0MWfNthKWb8RQTGIdDAiC
# qBa9qVbPFXONASIlzpVpP0d3+3J0FNf/q0+KLHqrhc1DX+1gtqpPkWaeLJ7giqzl
# /Yy8ZCaHbJK9nXzQcAp876i8dU+6WvepELJd6f8oVInw1YpxdmXazPByoyP6wCeC
# RK6ZJxurJB4mwbfeKuv2nrF5mYGjVoarCkXJ38SNoOeY+/umnXKvxMfBwWpx2cYT
# gAnEtp/Nh4cku0+jSbl3ZpHxcpzpSwJSpzd+k1OsOx0ISQ+UzTl63f8lY5knLD0/
# a6fxZsNBzU+2QJshIUDQtxMkzdwdeDrknq3lNHGS1yZr5Dhzq6YBT70/O3itTK37
# xJV77QpfMzmHQXh6OOmc4d0j/R0o08f56PGYX/sr2H7yRp11LB4nLCbbbxV7HhmL
# NriT1ObyF5lZynDwN7+YAN8gFk8n+2BnFqFmut1VwDophrCYoCvtlUG3OtUVmDG0
# YgkPCr2B2RP+v6TR81fZvAT6gt4y3wSJ8ADNXcL50CN/AAvkdgIm2fBldkKmKYcJ
# RyvmfxqkhQ/8mJb2VVQrH4D6wPIOK+XW+6kvRBVK5xMOHds3OBqhK/bt1nz8MIIG
# sDCCBJigAwIBAgIQCK1AsmDSnEyfXs2pvZOu2TANBgkqhkiG9w0BAQwFADBiMQsw
# CQYDVQQGEwJVUzEVMBMGA1UEChMMRGlnaUNlcnQgSW5jMRkwFwYDVQQLExB3d3cu
# ZGlnaWNlcnQuY29tMSEwHwYDVQQDExhEaWdpQ2VydCBUcnVzdGVkIFJvb3QgRzQw
# HhcNMjEwNDI5MDAwMDAwWhcNMzYwNDI4MjM1OTU5WjBpMQswCQYDVQQGEwJVUzEX
# MBUGA1UEChMORGlnaUNlcnQsIEluYy4xQTA/BgNVBAMTOERpZ2lDZXJ0IFRydXN0
# ZWQgRzQgQ29kZSBTaWduaW5nIFJTQTQwOTYgU0hBMzg0IDIwMjEgQ0ExMIICIjAN
# BgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEA1bQvQtAorXi3XdU5WRuxiEL1M4zr
# PYGXcMW7xIUmMJ+kjmjYXPXrNCQH4UtP03hD9BfXHtr50tVnGlJPDqFX/IiZwZHM
# gQM+TXAkZLON4gh9NH1MgFcSa0OamfLFOx/y78tHWhOmTLMBICXzENOLsvsI8Irg
# nQnAZaf6mIBJNYc9URnokCF4RS6hnyzhGMIazMXuk0lwQjKP+8bqHPNlaJGiTUyC
# EUhSaN4QvRRXXegYE2XFf7JPhSxIpFaENdb5LpyqABXRN/4aBpTCfMjqGzLmysL0
# p6MDDnSlrzm2q2AS4+jWufcx4dyt5Big2MEjR0ezoQ9uo6ttmAaDG7dqZy3SvUQa
# khCBj7A7CdfHmzJawv9qYFSLScGT7eG0XOBv6yb5jNWy+TgQ5urOkfW+0/tvk2E0
# XLyTRSiDNipmKF+wc86LJiUGsoPUXPYVGUztYuBeM/Lo6OwKp7ADK5GyNnm+960I
# HnWmZcy740hQ83eRGv7bUKJGyGFYmPV8AhY8gyitOYbs1LcNU9D4R+Z1MI3sMJN2
# FKZbS110YU0/EpF23r9Yy3IQKUHw1cVtJnZoEUETWJrcJisB9IlNWdt4z4FKPkBH
# X8mBUHOFECMhWWCKZFTBzCEa6DgZfGYczXg4RTCZT/9jT0y7qg0IU0F8WD1Hs/q2
# 7IwyCQLMbDwMVhECAwEAAaOCAVkwggFVMBIGA1UdEwEB/wQIMAYBAf8CAQAwHQYD
# VR0OBBYEFGg34Ou2O/hfEYb7/mF7CIhl9E5CMB8GA1UdIwQYMBaAFOzX44LScV1k
# TN8uZz/nupiuHA9PMA4GA1UdDwEB/wQEAwIBhjATBgNVHSUEDDAKBggrBgEFBQcD
# AzB3BggrBgEFBQcBAQRrMGkwJAYIKwYBBQUHMAGGGGh0dHA6Ly9vY3NwLmRpZ2lj
# ZXJ0LmNvbTBBBggrBgEFBQcwAoY1aHR0cDovL2NhY2VydHMuZGlnaWNlcnQuY29t
# L0RpZ2lDZXJ0VHJ1c3RlZFJvb3RHNC5jcnQwQwYDVR0fBDwwOjA4oDagNIYyaHR0
# cDovL2NybDMuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0VHJ1c3RlZFJvb3RHNC5jcmww
# HAYDVR0gBBUwEzAHBgVngQwBAzAIBgZngQwBBAEwDQYJKoZIhvcNAQEMBQADggIB
# ADojRD2NCHbuj7w6mdNW4AIapfhINPMstuZ0ZveUcrEAyq9sMCcTEp6QRJ9L/Z6j
# fCbVN7w6XUhtldU/SfQnuxaBRVD9nL22heB2fjdxyyL3WqqQz/WTauPrINHVUHmI
# moqKwba9oUgYftzYgBoRGRjNYZmBVvbJ43bnxOQbX0P4PpT/djk9ntSZz0rdKOtf
# JqGVWEjVGv7XJz/9kNF2ht0csGBc8w2o7uCJob054ThO2m67Np375SFTWsPK6Wrx
# oj7bQ7gzyE84FJKZ9d3OVG3ZXQIUH0AzfAPilbLCIXVzUstG2MQ0HKKlS43Nb3Y3
# LIU/Gs4m6Ri+kAewQ3+ViCCCcPDMyu/9KTVcH4k4Vfc3iosJocsL6TEa/y4ZXDlx
# 4b6cpwoG1iZnt5LmTl/eeqxJzy6kdJKt2zyknIYf48FWGysj/4+16oh7cGvmoLr9
# Oj9FpsToFpFSi0HASIRLlk2rREDjjfAVKM7t8RhWByovEMQMCGQ8M4+uKIw8y4+I
# Cw2/O/TOHnuO77Xry7fwdxPm5yg/rBKupS8ibEH5glwVZsxsDsrFhsP2JjMMB0ug
# 0wcCampAMEhLNKhRILutG4UI4lkNbcoFUCvqShyepf2gpx8GdOfy1lKQ/a+FSCH5
# Vzu0nAPthkX0tGFuv2jiJmCG6sivqf6UHedjGzqGVnhOMIIGwjCCBKqgAwIBAgIQ
# BUSv85SdCDmmv9s/X+VhFjANBgkqhkiG9w0BAQsFADBjMQswCQYDVQQGEwJVUzEX
# MBUGA1UEChMORGlnaUNlcnQsIEluYy4xOzA5BgNVBAMTMkRpZ2lDZXJ0IFRydXN0
# ZWQgRzQgUlNBNDA5NiBTSEEyNTYgVGltZVN0YW1waW5nIENBMB4XDTIzMDcxNDAw
# MDAwMFoXDTM0MTAxMzIzNTk1OVowSDELMAkGA1UEBhMCVVMxFzAVBgNVBAoTDkRp
# Z2lDZXJ0LCBJbmMuMSAwHgYDVQQDExdEaWdpQ2VydCBUaW1lc3RhbXAgMjAyMzCC
# AiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAKNTRYcdg45brD5UsyPgz5/X
# 5dLnXaEOCdwvSKOXejsqnGfcYhVYwamTEafNqrJq3RApih5iY2nTWJw1cb86l+uU
# UI8cIOrHmjsvlmbjaedp/lvD1isgHMGXlLSlUIHyz8sHpjBoyoNC2vx/CSSUpIIa
# 2mq62DvKXd4ZGIX7ReoNYWyd/nFexAaaPPDFLnkPG2ZS48jWPl/aQ9OE9dDH9kgt
# XkV1lnX+3RChG4PBuOZSlbVH13gpOWvgeFmX40QrStWVzu8IF+qCZE3/I+PKhu60
# pCFkcOvV5aDaY7Mu6QXuqvYk9R28mxyyt1/f8O52fTGZZUdVnUokL6wrl76f5P17
# cz4y7lI0+9S769SgLDSb495uZBkHNwGRDxy1Uc2qTGaDiGhiu7xBG3gZbeTZD+BY
# QfvYsSzhUa+0rRUGFOpiCBPTaR58ZE2dD9/O0V6MqqtQFcmzyrzXxDtoRKOlO0L9
# c33u3Qr/eTQQfqZcClhMAD6FaXXHg2TWdc2PEnZWpST618RrIbroHzSYLzrqawGw
# 9/sqhux7UjipmAmhcbJsca8+uG+W1eEQE/5hRwqM/vC2x9XH3mwk8L9CgsqgcT2c
# kpMEtGlwJw1Pt7U20clfCKRwo+wK8REuZODLIivK8SgTIUlRfgZm0zu++uuRONhR
# B8qUt+JQofM604qDy0B7AgMBAAGjggGLMIIBhzAOBgNVHQ8BAf8EBAMCB4AwDAYD
# VR0TAQH/BAIwADAWBgNVHSUBAf8EDDAKBggrBgEFBQcDCDAgBgNVHSAEGTAXMAgG
# BmeBDAEEAjALBglghkgBhv1sBwEwHwYDVR0jBBgwFoAUuhbZbU2FL3MpdpovdYxq
# II+eyG8wHQYDVR0OBBYEFKW27xPn783QZKHVVqllMaPe1eNJMFoGA1UdHwRTMFEw
# T6BNoEuGSWh0dHA6Ly9jcmwzLmRpZ2ljZXJ0LmNvbS9EaWdpQ2VydFRydXN0ZWRH
# NFJTQTQwOTZTSEEyNTZUaW1lU3RhbXBpbmdDQS5jcmwwgZAGCCsGAQUFBwEBBIGD
# MIGAMCQGCCsGAQUFBzABhhhodHRwOi8vb2NzcC5kaWdpY2VydC5jb20wWAYIKwYB
# BQUHMAKGTGh0dHA6Ly9jYWNlcnRzLmRpZ2ljZXJ0LmNvbS9EaWdpQ2VydFRydXN0
# ZWRHNFJTQTQwOTZTSEEyNTZUaW1lU3RhbXBpbmdDQS5jcnQwDQYJKoZIhvcNAQEL
# BQADggIBAIEa1t6gqbWYF7xwjU+KPGic2CX/yyzkzepdIpLsjCICqbjPgKjZ5+PF
# 7SaCinEvGN1Ott5s1+FgnCvt7T1IjrhrunxdvcJhN2hJd6PrkKoS1yeF844ektrC
# QDifXcigLiV4JZ0qBXqEKZi2V3mP2yZWK7Dzp703DNiYdk9WuVLCtp04qYHnbUFc
# jGnRuSvExnvPnPp44pMadqJpddNQ5EQSviANnqlE0PjlSXcIWiHFtM+YlRpUurm8
# wWkZus8W8oM3NG6wQSbd3lqXTzON1I13fXVFoaVYJmoDRd7ZULVQjK9WvUzF4UbF
# KNOt50MAcN7MmJ4ZiQPq1JE3701S88lgIcRWR+3aEUuMMsOI5ljitts++V+wQtaP
# 4xeR0arAVeOGv6wnLEHQmjNKqDbUuXKWfpd5OEhfysLcPTLfddY2Z1qJ+Panx+VP
# NTwAvb6cKmx5AdzaROY63jg7B145WPR8czFVoIARyxQMfq68/qTreWWqaNYiyjvr
# moI1VygWy2nyMpqy0tg6uLFGhmu6F/3Ed2wVbK6rr3M66ElGt9V/zLY4wNjsHPW2
# obhDLN9OTH0eaHDAdwrUAuBcYLso/zjlUlrWrBciI0707NMX+1Br/wd3H3GXREHJ
# uEbTbDJ8WC9nR2XlG3O2mflrLAZG70Ee8PBf4NvZrZCARK+AEEGKMIIIADCCBeig
# AwIBAgIQD0un28igrZOh2Z+6mD8+TTANBgkqhkiG9w0BAQsFADBpMQswCQYDVQQG
# EwJVUzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4xQTA/BgNVBAMTOERpZ2lDZXJ0
# IFRydXN0ZWQgRzQgQ29kZSBTaWduaW5nIFJTQTQwOTYgU0hBMzg0IDIwMjEgQ0Ex
# MB4XDTIyMDkxNTAwMDAwMFoXDTI1MDkxMDIzNTk1OVowgdExEzARBgsrBgEEAYI3
# PAIBAxMCVVMxGTAXBgsrBgEEAYI3PAIBAhMIQ29sb3JhZG8xHTAbBgNVBA8MFFBy
# aXZhdGUgT3JnYW5pemF0aW9uMRQwEgYDVQQFEwsyMDEzMTYzODMyNzELMAkGA1UE
# BhMCVVMxETAPBgNVBAgTCENvbG9yYWRvMRQwEgYDVQQHEwtDYXN0bGUgUm9jazEZ
# MBcGA1UEChMQUGF0Y2ggTXkgUEMsIExMQzEZMBcGA1UEAxMQUGF0Y2ggTXkgUEMs
# IExMQzCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAPKfoNjLgEqzlwL/
# aZLSldCkRTfZQ1jvb6ZMhZYoxUdNpzUEGNpbdTB9NNg9rQdZCvPDFYxhz00bOtwF
# dzzrO3V+4GxSPK7BBKkCASx5Oe9rVG9u0vmU2vCsnROMtczK8UBiERD+/W+FYN2A
# gQwdYaUsaPMT/QNlfVuhOEjFQXBYoCMMO/cNXUQLZkIwF4GacaGMh9TUSub8K9y8
# OMz5AQyjmfTxUrBLUzi0WJS1eDoTAeJ7BIrvT7+je+gEtYe9OpIz2gTJmYUykIUs
# Ix7A8OtTyp6j7tdMDahwyW1DXvUnFQHUViXisvajSiuCGePtet1lc+wyJizGF6Iv
# MBjw/xLk/38ZARs44iNFNVyEvga6L4pWOPp4Ul9VmFrqWTp8Pt4sppA7yE/1OjsY
# A0Xk0x3m6HiUiCUjwhY8eRhBCp5me+1SR8LHwhsS2TSO8rYkaFjctnRpjpwhqN2h
# Z/q7WIIhmZRoHxH0RPQrPJPHkdBes7OM7SVrZTts7IhREXR4PXeeCRDWiNIIb6pT
# mJiUGnrx7gy0ayilUOfEPbw0I2PSckBXfvqxxvnJGr+BZWYhIUC6/cHUhqwfFVN7
# tq8nYiAGSLLFhJT1vJWGZBVVNbpDC9joAbu9SvD48at2TrOf6iHpz/yhgC+iPhji
# oJRMOJK2Km0U0jC0dqtJhJNmfZeXAgMBAAGjggI5MIICNTAfBgNVHSMEGDAWgBRo
# N+Drtjv4XxGG+/5hewiIZfROQjAdBgNVHQ4EFgQUvTyL42xnOtRlK27xT25Ih8aM
# TPcwMgYDVR0RBCswKaAnBggrBgEFBQcIA6AbMBkMF1VTLUNPTE9SQURPLTIwMTMx
# NjM4MzI3MA4GA1UdDwEB/wQEAwIHgDATBgNVHSUEDDAKBggrBgEFBQcDAzCBtQYD
# VR0fBIGtMIGqMFOgUaBPhk1odHRwOi8vY3JsMy5kaWdpY2VydC5jb20vRGlnaUNl
# cnRUcnVzdGVkRzRDb2RlU2lnbmluZ1JTQTQwOTZTSEEzODQyMDIxQ0ExLmNybDBT
# oFGgT4ZNaHR0cDovL2NybDQuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0VHJ1c3RlZEc0
# Q29kZVNpZ25pbmdSU0E0MDk2U0hBMzg0MjAyMUNBMS5jcmwwPQYDVR0gBDYwNDAy
# BgVngQwBAzApMCcGCCsGAQUFBwIBFhtodHRwOi8vd3d3LmRpZ2ljZXJ0LmNvbS9D
# UFMwgZQGCCsGAQUFBwEBBIGHMIGEMCQGCCsGAQUFBzABhhhodHRwOi8vb2NzcC5k
# aWdpY2VydC5jb20wXAYIKwYBBQUHMAKGUGh0dHA6Ly9jYWNlcnRzLmRpZ2ljZXJ0
# LmNvbS9EaWdpQ2VydFRydXN0ZWRHNENvZGVTaWduaW5nUlNBNDA5NlNIQTM4NDIw
# MjFDQTEuY3J0MAwGA1UdEwEB/wQCMAAwDQYJKoZIhvcNAQELBQADggIBAFdPoh+i
# Ebsklh04Gal6DTgKSnw/5mO/k4oXMPKhmP/eYgTfvf2hwSewe9W2IK2/VH0HutUM
# k603cVtcyK1ppiDkR0MTshD7BVWHeAXJQmAjLQUr83vLh4WhPOZ2+R+GxWT3s1Ts
# /LFAF5qYHpd5+PhbLtSB/px50k0ouX/Dc/kYtKYN7/VBve01gkV+pbBsVRNvjv2T
# fAMTBDongJD3J5J+fy7PVZVGFvLpjZRtQjHeai6vM7Lwuh9o/dtPTQV7abeP8hmO
# xhQ9qRMXYSeoFkTw8+d/9/wPoQzBuwxN1gNSCRGEof4NamrcnUHtOCcrUWbKAE3r
# eqAtZPHFqiVBCwUCUADZ00mDtwZ7qEOUp71l/1K1j3rNLXGSkkONuHbIaZA3PsCq
# s0ltIE6/5Od8QfJRK2wkUu4vaumgQKJXKDinqMTXi4eTsjq1D6+qsp6vnc+O2xw3
# 6yzs8CUyolD14fRRDb2QNvHlWzuG/JgsRsm+HY7Yp8vIqVc73PFor6+Fe2BMnTCN
# bVkEV5Xi3dekkTYAV/sQxd8XlOBK+iHo/Ht4ggyzqhYjNfdXrD4Xh0zBsJfOIceO
# ZY2+mb3mPg5otvURSJS8EpIHWlRBalzzLJwwdY4yz9pU05L250wEY+iUyowJR5BD
# nvokCtKa07dYpdwxvYE1l5Iz6NBCEr4SMbvRMYIGUzCCBk8CAQEwfTBpMQswCQYD
# VQQGEwJVUzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4xQTA/BgNVBAMTOERpZ2lD
# ZXJ0IFRydXN0ZWQgRzQgQ29kZSBTaWduaW5nIFJTQTQwOTYgU0hBMzg0IDIwMjEg
# Q0ExAhAPS6fbyKCtk6HZn7qYPz5NMA0GCWCGSAFlAwQCAQUAoIGEMBgGCisGAQQB
# gjcCAQwxCjAIoAKAAKECgAAwGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwHAYK
# KwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEIMa48B6x
# b3OI6jlUES3aLEJ5plxS7DcWNswn/dCYDT+xMA0GCSqGSIb3DQEBAQUABIICACz2
# 6cC0DPwoJzbpd9vdRKG2fMJz611fz/3rthk8HfWOfeVYtB/CcjOmYV9iJ3KEpBK+
# 8aOIOlcHnMWFJPwbp4yinmVHjF3c5GBq/qbi4ZvjFkKIVOmUM5rN6BJ7ILEdohml
# CHp+TKyqExfSEr+f7TGDSH8XqaXYyC1JGi00BB8PrqFttsOaZMArf0/ABZnCR8gx
# rtujbXis7aFzQzCpgB2bThVa/6ZZ42JQPPnKDtib/0DUJP31npPsS/Z4P7JkeGMW
# k5tUvO8QbYQSr/vLV/LpZQI650doxMgQfifkbQHXSURNQRdi0RrWUDZw1tw5sP0V
# HmQ1zBkKt83EPp8urULejvOzPP1qy9LH5KOMsDrVx5onym4VX1kdUD9r46/q6R0p
# fM/EX9e8UI6NK1CUU58SHCxbBLMYzdktm08d0RqeSbVZSvMsc9rKQq778+q3pj3W
# 4kcDUbu37G7uZEYCX1DGqIwy9wVzkLp+hB7WwrEjDD/6iubQN3j0sIjz+k9CtYPT
# aMWpNMYHbWFzd12gMPdd+AMjQrcV0nWIGZ7U/O3DZYEDSKSTswmckAly6hbE4EOC
# hOgqAyJMt53da+JkgqKNLDhM7S7T26NmETVqGzgJc/dMaAx99pEC9S7Hhx+4CLr0
# htxazQrSS7Xo9QRFT7UJTStxMEzZfGzaa/Jnd38NoYIDIDCCAxwGCSqGSIb3DQEJ
# BjGCAw0wggMJAgEBMHcwYzELMAkGA1UEBhMCVVMxFzAVBgNVBAoTDkRpZ2lDZXJ0
# LCBJbmMuMTswOQYDVQQDEzJEaWdpQ2VydCBUcnVzdGVkIEc0IFJTQTQwOTYgU0hB
# MjU2IFRpbWVTdGFtcGluZyBDQQIQBUSv85SdCDmmv9s/X+VhFjANBglghkgBZQME
# AgEFAKBpMBgGCSqGSIb3DQEJAzELBgkqhkiG9w0BBwEwHAYJKoZIhvcNAQkFMQ8X
# DTIzMTAyNzEyNTUyMlowLwYJKoZIhvcNAQkEMSIEIP8rLJKRiFIeQTSFczZZZOGi
# I/BNRM1/lrTLHIwJQM4bMA0GCSqGSIb3DQEBAQUABIICAJR2E+A+ilpuNUd4icKY
# CVFfFIUMZAXmPVIe1Bj5bvSavpIniA1lCgjKzH/O3DW1DLu9st/wudsN2AnXE1qI
# QhLqh+Apo9Nm39YsiJOViwFWK/Y9OM8a/sdpF2Szz2atJE8sos3HzXppZ3N3DVJB
# 7T0P/qD6FRC/4xKIkDBaV/mwnssn43HIyecKxe6WRFOyGb2ZqTHP3zNG8cfFUKJM
# +yeLPzSu3KcVM6LcvwrjbVh3seYhW94+oJpljcPOTSaLeD9yBGTp5ogz9w/vFEVR
# bHgGmznsAQfhg93Wnh9MZr9uMK7xMYSgwDfA8lxPbob5eH4QYMiKIwlC5mmquu6i
# LTSMmyN+B0YUyXRB1OTY1sda/ShMSqxTlcocHANPm6T91gsosLQSaDkd4R7YHBe4
# 5ckZJG1PKwx6pNJjGbkoxYJAOVD7Oe8KHsiadGoUwyMe6ZFpNKrJUPE14grv6bf/
# ytkoKmdmpqWqTytt5tUmOKfRkzsJfe61fcVuGzCUeUsrMmLj01kxpHKfaPHP57k7
# 1sgSg5qZR08esVDatFVY/A+lRs+5edLZwa0DD/E60qKirickEJQcCDbIslG1/Rxb
# 9hj7J7ADiyjB4lDrlSV3MSSrT3Vamtf8SChT+hnKRqh00FZA8RlFV+hToLqkBr+Y
# z6ONtvHlNnPzHem9hUQUdJt9
# SIG # End signature block
