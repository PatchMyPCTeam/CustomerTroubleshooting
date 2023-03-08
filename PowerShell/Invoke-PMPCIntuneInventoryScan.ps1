#Requires -Module 'MSAL.PS'

<#
.SYNOPSIS
    Get Installed Software Report from Microsoft Intune Via Graph and compare it to Patch My PC SupportedProducts list
.DESCRIPTION
    Get Installed Software Report from Microsoft Intune Via Graph and compare it to Patch My PC SupportedProducts list
.PARAMETER ClientId
    ClientID from the Azure App Registration
.PARAMETER TenantID
ClientID from the Azure App Registration
.EXAMPLE
    Invoke-PMPCIntuneInventoryScan -ClientID "GUID" -TenantID "GUID"

    Exports the Inventory Comparison list from Intune.
.NOTES
    Delegate Permissions for DeviceManagementManagedDevices.Read.All need to be added
    Under authentication in the App Registration, Allow public client flows should also be enabled.

    ################# DISCLAIMER #################
    Patch My PC provides scripts, macro, and other code examples for illustration only, without warranty 
    either expressed or implied, including but not limited to the implied warranties of merchantability 
    and/or fitness for a particular purpose. This script is provided 'AS IS' and Patch My PC does not 
    guarantee that the following script, macro, or code can or should be used in any situation or that 
    operation of the code will be error-free.
#>

[CmdletBinding()]
param (
    #ClientID from the Azure App Registration
    [Parameter()]
    [String]
    $ClientId,
    #TenantID from the Azure App Registration
    [Parameter()]
    [String]
    $TenantID
)

[PSCustomObject]$SupportedProducts = [XML](Invoke-RestMethod 'https://patchmypc.com/scupcatalog/downloads/publishingservice/supportedproducts.xml') | 
    Select-Object -ExpandProperty 'SupportedProducts' |
    Select-Object -ExpandProperty 'Vendor' |
    ForEach-Object {
        $Vendor = $_
        foreach ($Product in $Vendor.Product) {
            [PSCustomObject]@{
                Vendor = $Vendor.Name
                Product = $Product.Name
                SQLSearchInclude = $Product.SQLSearchInclude -replace '%','*'
                SQLSearchExclude = $Product.SQLSearchExclude -replace '%','*'
                SQLSearchVersionInclude = $Product.SQLSearchVersionInclude -replace '%','*'
            }
        }
    }

$GetMsalTokenSplat = @{
    ClientId    = $ClientID    #ClientID from the Azure App Registration
    TenantId    = $TenantID    #TenantID from the Azure App Registration
    DeviceCode  = $true
    ErrorAction = 'Stop'
}

if (((Get-Date) -gt $Auth.ExpiresOn.DateTime) -or (-not $Auth)){
    $Auth = Get-MsalToken @GetMsalTokenSplat
} else {
    Write-Host "Skipping auth as we already have an MSAL Token"
}

$Headers = @{    
    "Content-Type"  = "application/json"    
    "Authorization" = "Bearer {0}" -f $Auth.AccessToken
}

$Body = @{    
    "reportName"       = "DetectedAppsAggregate"
    "localizationType" = "LocalizedValuesAsAdditionalColumn"
} | ConvertTo-Json

$URL = "https://graph.microsoft.com/beta/deviceManagement/reports/exportJobs"

$InvokeRestMethodSplat = @{
    URI     = $URL
    HEADERS = $Headers
}

$Response = Invoke-RestMethod @InvokeRestMethodSplat -Method 'POST' -Body $Body

$InvokeRestMethodSplat['URI'] = '{0}/{1}' -f $URL, $Response.id

$i = 0
do {    
    $Response = Invoke-RestMethod @InvokeRestMethodSplat -Method "GET"
    Write-Verbose "Waiting for report to complete. Status: $($Response.status)" -Verbose
    Write-Verbose ("Time remaining before timeout: {0} minutes" -f ((720 - $i) / 12)) -Verbose
    Start-Sleep -Seconds 5
    $i++
} until ($Response.status -eq "Completed" -or $i -gt 720) # Timeout after 1 hour

$TempFile = New-TemporaryFile

Invoke-WebRequest -uri $Response.url -OutFile $TempFile

$TempFile = Rename-Item $TempFile ($TempFile.Name).replace(".tmp",".zip") -Passthru

Expand-Archive -Path $TempFile -DestinationPath $TempFile.DirectoryName -Force

$CsvFile = '{0}\{1}.csv' -f $TempFile.DirectoryName, $Response.id
$DetectedAppsAggregate = Import-Csv $CsvFile

Remove-Item $TempFile,$CsvFile -ErrorAction 'SilentlyContinue'

$AppCountList = foreach ($SupportedProduct in $SupportedProducts) {
    $IntuneApp = $DetectedAppsAggregate.Where{ 
        $_.ApplicationName -like $SupportedProduct.SQLSearchInclude -and 
        $_.ApplicationName -notlike $SupportedProduct.SQLSearchExclude -and 
        ({$_.ApplicationVersion -like $SupportedProduct.SQLSearchVersionInclude} -or [System.String]::IsNullOrWhiteSpace($SupportedProduct.SQLSearchVersionInclude))
    }

    if ($IntuneApp) {
        [PSCustomObject]@{
            Vendor          = [String]$SupportedProduct.Vendor
            Product         = [String]$SupportedProduct.Product
            DeviceCount     = [int]($IntuneApp | Measure-Object -Property 'DeviceCount' -Sum | Select-Object -ExpandProperty 'Sum')
        }
    }
}

$AppCountList | Sort-Object -Property Vendor, Product | Export-Csv -NoTypeInformation -Path .\PatchMyPCAppsFoundinIntune.csv
$AppCountList | out-gridview

# SIG # Begin signature block
# MIIljAYJKoZIhvcNAQcCoIIlfTCCJXkCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBJQ3p68H2ufoBC
# XJCku+JqWK30kvMDe8GEU67sXF4hkqCCH4swggWNMIIEdaADAgECAhAOmxiO+dAt
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
# twGpn1eqXijiuZQwggXAMIIEqKADAgECAhAKR308aKJ9O5MNHDo9bpE4MA0GCSqG
# SIb3DQEBCwUAMGwxCzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdpQ2VydCBJbmMx
# GTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xKzApBgNVBAMTIkRpZ2lDZXJ0IEVW
# IENvZGUgU2lnbmluZyBDQSAoU0hBMikwHhcNMjAwNDE3MDAwMDAwWhcNMjMwNDI2
# MTIwMDAwWjCB0jETMBEGCysGAQQBgjc8AgEDEwJVUzEZMBcGCysGAQQBgjc8AgEC
# EwhDb2xvcmFkbzEdMBsGA1UEDwwUUHJpdmF0ZSBPcmdhbml6YXRpb24xFDASBgNV
# BAUTCzIwMTMxNjM4MzI3MQswCQYDVQQGEwJVUzERMA8GA1UECBMIQ29sb3JhZG8x
# FTATBgNVBAcTDENhc3RsZSBQaW5lczEZMBcGA1UEChMQUGF0Y2ggTXkgUEMsIExM
# QzEZMBcGA1UEAxMQUGF0Y2ggTXkgUEMsIExMQzCCASIwDQYJKoZIhvcNAQEBBQAD
# ggEPADCCAQoCggEBAJne/tFnykB3D2AcOzu64ayQxamyDOC2iv+OgFBmq+m/CSRl
# Jn4lKzsZPK7ykuXROEjRPB4y4HQCQ86Z2xMR2Njtw7Wsr44rY7+Any9D4DnavX9Y
# 2GEuViVBCm3/n8RTlsezNIE0yNPvd5N5BrpvKABPDxvmNN9So+HnC/5iYZNR1rDt
# wr7m6NWxDIQLnwFxvYxZkiihQdHUO0TMIAekLfBxTq46l2+5V2PjE2vAsQ+D/lDL
# dfJ2n8XWaqICyzymnEoIUp+Tf2w5VHKMU9gpi4QJ0OqzqSWy27+Y4wojTwLkrZ9v
# JOZtdtS4qq0RV1Xucm4H7mhDmrj2X7tHEnFSceMCAwEAAaOCAfUwggHxMB8GA1Ud
# IwQYMBaAFI/ofvBtMmoABSPHcJdqOpD/a+rUMB0GA1UdDgQWBBSilZ/GwpZbIL9D
# rH6W/A2mRvCi7jAyBgNVHREEKzApoCcGCCsGAQUFBwgDoBswGQwXVVMtQ09MT1JB
# RE8tMjAxMzE2MzgzMjcwDgYDVR0PAQH/BAQDAgeAMBMGA1UdJQQMMAoGCCsGAQUF
# BwMDMHsGA1UdHwR0MHIwN6A1oDOGMWh0dHA6Ly9jcmwzLmRpZ2ljZXJ0LmNvbS9F
# VkNvZGVTaWduaW5nU0hBMi1nMS5jcmwwN6A1oDOGMWh0dHA6Ly9jcmw0LmRpZ2lj
# ZXJ0LmNvbS9FVkNvZGVTaWduaW5nU0hBMi1nMS5jcmwwSwYDVR0gBEQwQjA3Bglg
# hkgBhv1sAwIwKjAoBggrBgEFBQcCARYcaHR0cHM6Ly93d3cuZGlnaWNlcnQuY29t
# L0NQUzAHBgVngQwBAzB+BggrBgEFBQcBAQRyMHAwJAYIKwYBBQUHMAGGGGh0dHA6
# Ly9vY3NwLmRpZ2ljZXJ0LmNvbTBIBggrBgEFBQcwAoY8aHR0cDovL2NhY2VydHMu
# ZGlnaWNlcnQuY29tL0RpZ2lDZXJ0RVZDb2RlU2lnbmluZ0NBLVNIQTIuY3J0MAwG
# A1UdEwEB/wQCMAAwDQYJKoZIhvcNAQELBQADggEBAF7tPenzLG9ZkmAemfxlXGpu
# wDWICICz8pJn97E5RsxXYh36X0rxrobE7m3RtwLiWsM3Xeo+q2zH9aqdIBlPA/bb
# 3tticFoSAFDPMVLewaoZsSqTQ0M8kietmgnKvbr4dJlbBtiw5Ctw97mT7CEQ/DdQ
# wWmgmHvCDZFFM7qtvKNsj3BC+w8LY34+jDv6OrUGIz1rW/MScrhSBtjWHZHkTB9c
# rhQqAckQYH3MF5Exlm3JfDGx8OA3r973e9c2gdk+xM18DDDwukhuYY552fRB4mM3
# cE50BJTLJD6wHuGZ9r4ymj9OYyOXx6ErGnLHIRRq/1mUulKBnwtlEnDy1Ji5QZMw
# ggauMIIElqADAgECAhAHNje3JFR82Ees/ShmKl5bMA0GCSqGSIb3DQEBCwUAMGIx
# CzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdpQ2VydCBJbmMxGTAXBgNVBAsTEHd3
# dy5kaWdpY2VydC5jb20xITAfBgNVBAMTGERpZ2lDZXJ0IFRydXN0ZWQgUm9vdCBH
# NDAeFw0yMjAzMjMwMDAwMDBaFw0zNzAzMjIyMzU5NTlaMGMxCzAJBgNVBAYTAlVT
# MRcwFQYDVQQKEw5EaWdpQ2VydCwgSW5jLjE7MDkGA1UEAxMyRGlnaUNlcnQgVHJ1
# c3RlZCBHNCBSU0E0MDk2IFNIQTI1NiBUaW1lU3RhbXBpbmcgQ0EwggIiMA0GCSqG
# SIb3DQEBAQUAA4ICDwAwggIKAoICAQDGhjUGSbPBPXJJUVXHJQPE8pE3qZdRodbS
# g9GeTKJtoLDMg/la9hGhRBVCX6SI82j6ffOciQt/nR+eDzMfUBMLJnOWbfhXqAJ9
# /UO0hNoR8XOxs+4rgISKIhjf69o9xBd/qxkrPkLcZ47qUT3w1lbU5ygt69OxtXXn
# HwZljZQp09nsad/ZkIdGAHvbREGJ3HxqV3rwN3mfXazL6IRktFLydkf3YYMZ3V+0
# VAshaG43IbtArF+y3kp9zvU5EmfvDqVjbOSmxR3NNg1c1eYbqMFkdECnwHLFuk4f
# sbVYTXn+149zk6wsOeKlSNbwsDETqVcplicu9Yemj052FVUmcJgmf6AaRyBD40Nj
# gHt1biclkJg6OBGz9vae5jtb7IHeIhTZgirHkr+g3uM+onP65x9abJTyUpURK1h0
# QCirc0PO30qhHGs4xSnzyqqWc0Jon7ZGs506o9UD4L/wojzKQtwYSH8UNM/STKvv
# mz3+DrhkKvp1KCRB7UK/BZxmSVJQ9FHzNklNiyDSLFc1eSuo80VgvCONWPfcYd6T
# /jnA+bIwpUzX6ZhKWD7TA4j+s4/TXkt2ElGTyYwMO1uKIqjBJgj5FBASA31fI7tk
# 42PgpuE+9sJ0sj8eCXbsq11GdeJgo1gJASgADoRU7s7pXcheMBK9Rp6103a50g5r
# mQzSM7TNsQIDAQABo4IBXTCCAVkwEgYDVR0TAQH/BAgwBgEB/wIBADAdBgNVHQ4E
# FgQUuhbZbU2FL3MpdpovdYxqII+eyG8wHwYDVR0jBBgwFoAU7NfjgtJxXWRM3y5n
# P+e6mK4cD08wDgYDVR0PAQH/BAQDAgGGMBMGA1UdJQQMMAoGCCsGAQUFBwMIMHcG
# CCsGAQUFBwEBBGswaTAkBggrBgEFBQcwAYYYaHR0cDovL29jc3AuZGlnaWNlcnQu
# Y29tMEEGCCsGAQUFBzAChjVodHRwOi8vY2FjZXJ0cy5kaWdpY2VydC5jb20vRGln
# aUNlcnRUcnVzdGVkUm9vdEc0LmNydDBDBgNVHR8EPDA6MDigNqA0hjJodHRwOi8v
# Y3JsMy5kaWdpY2VydC5jb20vRGlnaUNlcnRUcnVzdGVkUm9vdEc0LmNybDAgBgNV
# HSAEGTAXMAgGBmeBDAEEAjALBglghkgBhv1sBwEwDQYJKoZIhvcNAQELBQADggIB
# AH1ZjsCTtm+YqUQiAX5m1tghQuGwGC4QTRPPMFPOvxj7x1Bd4ksp+3CKDaopafxp
# wc8dB+k+YMjYC+VcW9dth/qEICU0MWfNthKWb8RQTGIdDAiCqBa9qVbPFXONASIl
# zpVpP0d3+3J0FNf/q0+KLHqrhc1DX+1gtqpPkWaeLJ7giqzl/Yy8ZCaHbJK9nXzQ
# cAp876i8dU+6WvepELJd6f8oVInw1YpxdmXazPByoyP6wCeCRK6ZJxurJB4mwbfe
# Kuv2nrF5mYGjVoarCkXJ38SNoOeY+/umnXKvxMfBwWpx2cYTgAnEtp/Nh4cku0+j
# Sbl3ZpHxcpzpSwJSpzd+k1OsOx0ISQ+UzTl63f8lY5knLD0/a6fxZsNBzU+2QJsh
# IUDQtxMkzdwdeDrknq3lNHGS1yZr5Dhzq6YBT70/O3itTK37xJV77QpfMzmHQXh6
# OOmc4d0j/R0o08f56PGYX/sr2H7yRp11LB4nLCbbbxV7HhmLNriT1ObyF5lZynDw
# N7+YAN8gFk8n+2BnFqFmut1VwDophrCYoCvtlUG3OtUVmDG0YgkPCr2B2RP+v6TR
# 81fZvAT6gt4y3wSJ8ADNXcL50CN/AAvkdgIm2fBldkKmKYcJRyvmfxqkhQ/8mJb2
# VVQrH4D6wPIOK+XW+6kvRBVK5xMOHds3OBqhK/bt1nz8MIIGvDCCBaSgAwIBAgIQ
# A/G04V86gvEUlniz19hHXDANBgkqhkiG9w0BAQsFADBsMQswCQYDVQQGEwJVUzEV
# MBMGA1UEChMMRGlnaUNlcnQgSW5jMRkwFwYDVQQLExB3d3cuZGlnaWNlcnQuY29t
# MSswKQYDVQQDEyJEaWdpQ2VydCBIaWdoIEFzc3VyYW5jZSBFViBSb290IENBMB4X
# DTEyMDQxODEyMDAwMFoXDTI3MDQxODEyMDAwMFowbDELMAkGA1UEBhMCVVMxFTAT
# BgNVBAoTDERpZ2lDZXJ0IEluYzEZMBcGA1UECxMQd3d3LmRpZ2ljZXJ0LmNvbTEr
# MCkGA1UEAxMiRGlnaUNlcnQgRVYgQ29kZSBTaWduaW5nIENBIChTSEEyKTCCASIw
# DQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBAKdT+g+ytRPxZM+EgPyugDXRttfH
# oyysGiys8YSsOjUSOpKRulfkxMnzL6hIPLfWbtyXIrpReWGvQy8Nt5u0STGuRFg+
# pKGWp4dPI37DbGUkkFU+ocojfMVC6cR6YkWbfd5jdMueYyX4hJqarUVPrn0fyBPL
# dZvJ4eGK+AsMmPTKPtBFqnoepViTNjS+Ky4rMVhmtDIQn53wUqHv6D7TdvJAWtz6
# aj0bS612sIxc7ja6g+owqEze8QsqWEGIrgCJqwPRFoIgInbrXlQ4EmLh0nAk2+0f
# cNJkCYAt4radzh/yuyHzbNvYsxl7ilCf7+w2Clyat0rTCKA5ef3dvz06CSUCAwEA
# AaOCA1gwggNUMBIGA1UdEwEB/wQIMAYBAf8CAQAwDgYDVR0PAQH/BAQDAgGGMBMG
# A1UdJQQMMAoGCCsGAQUFBwMDMH8GCCsGAQUFBwEBBHMwcTAkBggrBgEFBQcwAYYY
# aHR0cDovL29jc3AuZGlnaWNlcnQuY29tMEkGCCsGAQUFBzAChj1odHRwOi8vY2Fj
# ZXJ0cy5kaWdpY2VydC5jb20vRGlnaUNlcnRIaWdoQXNzdXJhbmNlRVZSb290Q0Eu
# Y3J0MIGPBgNVHR8EgYcwgYQwQKA+oDyGOmh0dHA6Ly9jcmwzLmRpZ2ljZXJ0LmNv
# bS9EaWdpQ2VydEhpZ2hBc3N1cmFuY2VFVlJvb3RDQS5jcmwwQKA+oDyGOmh0dHA6
# Ly9jcmw0LmRpZ2ljZXJ0LmNvbS9EaWdpQ2VydEhpZ2hBc3N1cmFuY2VFVlJvb3RD
# QS5jcmwwggHEBgNVHSAEggG7MIIBtzCCAbMGCWCGSAGG/WwDAjCCAaQwOgYIKwYB
# BQUHAgEWLmh0dHA6Ly93d3cuZGlnaWNlcnQuY29tL3NzbC1jcHMtcmVwb3NpdG9y
# eS5odG0wggFkBggrBgEFBQcCAjCCAVYeggFSAEEAbgB5ACAAdQBzAGUAIABvAGYA
# IAB0AGgAaQBzACAAQwBlAHIAdABpAGYAaQBjAGEAdABlACAAYwBvAG4AcwB0AGkA
# dAB1AHQAZQBzACAAYQBjAGMAZQBwAHQAYQBuAGMAZQAgAG8AZgAgAHQAaABlACAA
# RABpAGcAaQBDAGUAcgB0ACAAQwBQAC8AQwBQAFMAIABhAG4AZAAgAHQAaABlACAA
# UgBlAGwAeQBpAG4AZwAgAFAAYQByAHQAeQAgAEEAZwByAGUAZQBtAGUAbgB0ACAA
# dwBoAGkAYwBoACAAbABpAG0AaQB0ACAAbABpAGEAYgBpAGwAaQB0AHkAIABhAG4A
# ZAAgAGEAcgBlACAAaQBuAGMAbwByAHAAbwByAGEAdABlAGQAIABoAGUAcgBlAGkA
# bgAgAGIAeQAgAHIAZQBmAGUAcgBlAG4AYwBlAC4wHQYDVR0OBBYEFI/ofvBtMmoA
# BSPHcJdqOpD/a+rUMB8GA1UdIwQYMBaAFLE+w2kD+L9HAdSYJhoIAu9jZCvDMA0G
# CSqGSIb3DQEBCwUAA4IBAQAZM0oMgTM32602yeTJOru1Gy56ouL0Q0IXnr9OoU3h
# sdvpgd2fAfLkiNXp/gn9IcHsXYDS8NbBQ8L+dyvb+deRM85s1bIZO+Yu1smTT4hA
# js3h9X7xD8ZZVnLo62pBvRzVRtV8ScpmOBXBv+CRcHeH3MmNMckMKaIz7Y3ih82J
# jT8b/9XgGpeLfNpt+6jGsjpma3sBs83YpjTsEgGrlVilxFNXqGDm5wISoLkjZKJN
# u3yBJWQhvs/uQhhDl7ulNwavTf8mpU1hS+xGQbhlzrh5ngiWC4GMijuPx5mMoypu
# mG1eYcaWt4q5YS2TuOsOBEPX9f6m8GLUmWqlwcHwZJSAMIIGwDCCBKigAwIBAgIQ
# DE1pckuU+jwqSj0pB4A9WjANBgkqhkiG9w0BAQsFADBjMQswCQYDVQQGEwJVUzEX
# MBUGA1UEChMORGlnaUNlcnQsIEluYy4xOzA5BgNVBAMTMkRpZ2lDZXJ0IFRydXN0
# ZWQgRzQgUlNBNDA5NiBTSEEyNTYgVGltZVN0YW1waW5nIENBMB4XDTIyMDkyMTAw
# MDAwMFoXDTMzMTEyMTIzNTk1OVowRjELMAkGA1UEBhMCVVMxETAPBgNVBAoTCERp
# Z2lDZXJ0MSQwIgYDVQQDExtEaWdpQ2VydCBUaW1lc3RhbXAgMjAyMiAtIDIwggIi
# MA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQDP7KUmOsap8mu7jcENmtuh6BSF
# dDMaJqzQHFUeHjZtvJJVDGH0nQl3PRWWCC9rZKT9BoMW15GSOBwxApb7crGXOlWv
# M+xhiummKNuQY1y9iVPgOi2Mh0KuJqTku3h4uXoW4VbGwLpkU7sqFudQSLuIaQyI
# xvG+4C99O7HKU41Agx7ny3JJKB5MgB6FVueF7fJhvKo6B332q27lZt3iXPUv7Y3U
# TZWEaOOAy2p50dIQkUYp6z4m8rSMzUy5Zsi7qlA4DeWMlF0ZWr/1e0BubxaompyV
# R4aFeT4MXmaMGgokvpyq0py2909ueMQoP6McD1AGN7oI2TWmtR7aeFgdOej4TJEQ
# ln5N4d3CraV++C0bH+wrRhijGfY59/XBT3EuiQMRoku7mL/6T+R7Nu8GRORV/zbq
# 5Xwx5/PCUsTmFntafqUlc9vAapkhLWPlWfVNL5AfJ7fSqxTlOGaHUQhr+1NDOdBk
# +lbP4PQK5hRtZHi7mP2Uw3Mh8y/CLiDXgazT8QfU4b3ZXUtuMZQpi+ZBpGWUwFjl
# 5S4pkKa3YWT62SBsGFFguqaBDwklU/G/O+mrBw5qBzliGcnWhX8T2Y15z2LF7OF7
# ucxnEweawXjtxojIsG4yeccLWYONxu71LHx7jstkifGxxLjnU15fVdJ9GSlZA076
# XepFcxyEftfO4tQ6dwIDAQABo4IBizCCAYcwDgYDVR0PAQH/BAQDAgeAMAwGA1Ud
# EwEB/wQCMAAwFgYDVR0lAQH/BAwwCgYIKwYBBQUHAwgwIAYDVR0gBBkwFzAIBgZn
# gQwBBAIwCwYJYIZIAYb9bAcBMB8GA1UdIwQYMBaAFLoW2W1NhS9zKXaaL3WMaiCP
# nshvMB0GA1UdDgQWBBRiit7QYfyPMRTtlwvNPSqUFN9SnDBaBgNVHR8EUzBRME+g
# TaBLhklodHRwOi8vY3JsMy5kaWdpY2VydC5jb20vRGlnaUNlcnRUcnVzdGVkRzRS
# U0E0MDk2U0hBMjU2VGltZVN0YW1waW5nQ0EuY3JsMIGQBggrBgEFBQcBAQSBgzCB
# gDAkBggrBgEFBQcwAYYYaHR0cDovL29jc3AuZGlnaWNlcnQuY29tMFgGCCsGAQUF
# BzAChkxodHRwOi8vY2FjZXJ0cy5kaWdpY2VydC5jb20vRGlnaUNlcnRUcnVzdGVk
# RzRSU0E0MDk2U0hBMjU2VGltZVN0YW1waW5nQ0EuY3J0MA0GCSqGSIb3DQEBCwUA
# A4ICAQBVqioa80bzeFc3MPx140/WhSPx/PmVOZsl5vdyipjDd9Rk/BX7NsJJUSx4
# iGNVCUY5APxp1MqbKfujP8DJAJsTHbCYidx48s18hc1Tna9i4mFmoxQqRYdKmEIr
# UPwbtZ4IMAn65C3XCYl5+QnmiM59G7hqopvBU2AJ6KO4ndetHxy47JhB8PYOgPvk
# /9+dEKfrALpfSo8aOlK06r8JSRU1NlmaD1TSsht/fl4JrXZUinRtytIFZyt26/+Y
# siaVOBmIRBTlClmia+ciPkQh0j8cwJvtfEiy2JIMkU88ZpSvXQJT657inuTTH4YB
# ZJwAwuladHUNPeF5iL8cAZfJGSOA1zZaX5YWsWMMxkZAO85dNdRZPkOaGK7DycvD
# +5sTX2q1x+DzBcNZ3ydiK95ByVO5/zQQZ/YmMph7/lxClIGUgp2sCovGSxVK05iQ
# RWAzgOAj3vgDpPZFR+XOuANCR+hBNnF3rf2i6Jd0Ti7aHh2MWsgemtXC8MYiqE+b
# vdgcmlHEL5r2X6cnl7qWLoVXwGDneFZ/au/ClZpLEQLIgpzJGgV8unG1TnqZbPTo
# ntRamMifv427GFxD9dAq6OJi7ngE273R+1sKqHB+8JeEeOMIA11HLGOoJTiXAdI/
# Otrl5fbmm9x+LMz/F0xNAKLY1gEOuIvu5uByVYksJxlh9ncBjDGCBVcwggVTAgEB
# MIGAMGwxCzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdpQ2VydCBJbmMxGTAXBgNV
# BAsTEHd3dy5kaWdpY2VydC5jb20xKzApBgNVBAMTIkRpZ2lDZXJ0IEVWIENvZGUg
# U2lnbmluZyBDQSAoU0hBMikCEApHfTxoon07kw0cOj1ukTgwDQYJYIZIAWUDBAIB
# BQCggYQwGAYKKwYBBAGCNwIBDDEKMAigAoAAoQKAADAZBgkqhkiG9w0BCQMxDAYK
# KwYBBAGCNwIBBDAcBgorBgEEAYI3AgELMQ4wDAYKKwYBBAGCNwIBFTAvBgkqhkiG
# 9w0BCQQxIgQghFYtiHsDx/eHm5iJ4e6phZSW11QUWrT+fhyxP2UlDAIwDQYJKoZI
# hvcNAQEBBQAEggEAiH5AKspr5zZHricbRhvRyGpBCqFrQo8P9ZyeAY++QdnQ5M9w
# 7rpzEd0IRUYC/lpJwhhMhaIMJrFdACV5SeT9swzwdzrYCp0oRUfJdHw6fxpc5BnE
# aIKe+Kr7/IuIjGISF6FdjIL5l5MC3LOFato/3+YcT2GLeTh4JBGKV235q8QuwHY6
# 3Msy/ahwdht2YRvtmKY+eFAaJYCq71mpFi8PKTSEJiAQGdUKnP4zPu4vVqgfHvog
# EhKNKPj/ejkCM6SBdo3ebI5Np7fWk6VNkKnG9hZpcB7OjcRYQ+mgNw1iY8XiHCgk
# rFquJcvMWSOe7hl24TwSmSuPmS/SwO/sluKQwaGCAyAwggMcBgkqhkiG9w0BCQYx
# ggMNMIIDCQIBATB3MGMxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdpQ2VydCwg
# SW5jLjE7MDkGA1UEAxMyRGlnaUNlcnQgVHJ1c3RlZCBHNCBSU0E0MDk2IFNIQTI1
# NiBUaW1lU3RhbXBpbmcgQ0ECEAxNaXJLlPo8Kko9KQeAPVowDQYJYIZIAWUDBAIB
# BQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwGCSqGSIb3DQEJBTEPFw0y
# MzAzMDgyMDE0MDRaMC8GCSqGSIb3DQEJBDEiBCCg9N4o8kSZAgZ21dk4Hci9yA3I
# UFIWAzPly/8TE/a76TANBgkqhkiG9w0BAQEFAASCAgDIMedVdQs7llktVWHp+gnT
# dSLXY7Z8DEGUUrrJlkMekDCgOaVnaXx2X+AfX6I5kR2LzbJTN6mqSSDPo2bvDkP1
# 3PosIuPBzF6oBcm3c3iI1aUwDNtifTovGGJRTxnpmTtEBS0AEvTFBf/u8L0vxRPb
# oY70F9hUk5vUQRdnCakQJXI9iboeVRVt9biqVKwUl7a7n8RopGijvGUC2dxLp65O
# +5eMk3q7za8papzk+90lM9WOJekBl0VYfEUoBzo+pPglQxaymSgXrsEwzPfRFud4
# PqOANgO1bomrNu6yTXeZH1x+FyO6xvrGffOmAqQlXbHVVG8TzDVqI8PxSq3P/nDo
# MfJV+I7B7Tv7xbLEJcsEtBw+B1XPVsF2es5secJkqa2iEWxlH51oH7im1rpIfkYo
# h80uhRpdD2853pCFAR2X4Y4avM1oss6r/50avlkhTL9O6SUQEbW3mYXSm7WxWawd
# w30fp3r2omMRlk5gPZgi1eKoe26ksp0K6nTYR817IkgIKmuGuaEkBdNNljPMAXbZ
# 18/ViPYUN5M5WD7Tr1H/F0s5n40gICRJQSROEJWeVCFrhQgwLi2KsgaI0n4BhtgA
# MiZC4vESBd77sy0UZKELI64gr6uPgEMsc/VksZN3B1D7OAUpjvRjB7+Z4/bJdn0B
# GNtwYwD7wNR/QB2dhZmodA==
# SIG # End signature block
