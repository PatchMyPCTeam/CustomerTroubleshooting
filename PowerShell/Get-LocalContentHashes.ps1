<#
.SYNOPSIS
    Script to list all the files in the Patch My PC Local Content Repository.
    Files found in the Local Content Repository are compared to the Patch My PC catalog to see if they have the expected hash.
    The list is exported as a LocalContentHashes.csv in the Local Content Repository folder or the working directory if the Local Content Repository folder is not accessible.

.NOTES

    Author Ben Whitmore@PatchMyPC
    Date: 2021-09-15
    Version: 1.0

    ################# IMPORTANT #################
    This script must be run on the Patch My PC Publishing Service server

    ################# DISCLAIMER #################
    Patch My PC provides scripts, macro, and other code examples for illustration only, without warranty 
    either expressed or implied, including but not limited to the implied warranties of merchantability 
    and/or fitness for a particular purpose. This script is provided 'AS IS' and Patch My PC does not 
    guarantee that the following script, macro, or code can or should be used in any situation or that 
    operation of the code will be error-free.
#>

$pmpreg = 'SOFTWARE\Patch My PC Publishing Service'
$VerbosePreference = 'Continue'

Function Get-MsiInfo {
    Param (
        [Parameter(Mandatory = $true)]
        [String]$File,
        
        [Parameter(Mandatory = $true)]
        [String]$Property
    )

    # Use the WindowsInstaller.Installer COM object to query the MSI file
    $installer = New-Object -ComObject WindowsInstaller.Installer
    $database = $installer.GetType().InvokeMember("OpenDatabase", "InvokeMethod", $Null, $installer, @($File, 0))

    Try {
        $query = "SELECT `Value` FROM `Property` WHERE `Property` = '$Property'"
        $view = $database.GetType().InvokeMember("OpenView", "InvokeMethod", $Null, $database, ($query))
        $view.GetType().InvokeMember("Execute", "InvokeMethod", $Null, $view, $Null)
        $record = $view.GetType().InvokeMember("Fetch", "InvokeMethod", $Null, $view, $Null)

        If ($record) {
            $msiProperty = $record.GetType().InvokeMember("StringData", "GetProperty", $Null, $record, 1)

            Return $msiProperty
        }
    }
    Catch {
        Write-Warning  ("Failed to get MSI property '{0}' from '{1}'" -f $Property, $File)
    }
    Finally {
        $view.GetType().InvokeMember("Close", "InvokeMethod", $Null, $view, $Null) | Out-Null
        [System.Runtime.Interopservices.Marshal]::ReleaseComObject($view) | Out-Null
        [System.Runtime.Interopservices.Marshal]::ReleaseComObject($database) | Out-Null
        [System.Runtime.Interopservices.Marshal]::ReleaseComObject($installer) | Out-Null
    }
}
Function Get-EncodedHash {
    [CmdletBinding()]
    Param(
        [Parameter(Position = 0)]
        [System.Object]$HashValue
    )

    $hashBytes = $hashValue.Hash -split '(?<=\G..)(?=.)' | ForEach-Object { [byte]::Parse($_, 'HexNumber') }
    Return [Convert]::ToBase64String($hashBytes)
}

Function Get-CatalogXml {
    [CmdletBinding()]
    Param(
        [Parameter(Position = 0)]
        [String]$CatalogPath
    ) 

    # Read the Patch My PC catalog from disk
    $namespace = @{
        "smc" = "http://schemas.microsoft.com/sms/2005/04/CorporatePublishing/SystemsManagementCatalog.xsd"
        "sdp" = "http://schemas.microsoft.com/wsus/2005/04/CorporatePublishing/SoftwareDistributionPackage.xsd"
    }

    $xml = Select-Xml -Path $CatalogPath -Namespace $namespace -XPath "//smc:SoftwareDistributionPackage" 

    Return $xml

    # Clean-up
    $xml = $Null
    [System.GC]::Collect()
}

Function Get-CatalogHash {
    [CmdletBinding()]
    Param(
        [Parameter(Position = 0)]
        [Object]$Catalog,
        [Parameter(Position = 1)]
        [Object]$EncodedHashes
    )

    # Check to see if the hash exists in the Patch My PC catalog
    $resultCatArray = @()
    $processedHashes = @{}

    ForEach ($node in $Catalog.Node) {
        
        ForEach ($hash in $EncodedHashes) { 
            
            If ($node.InstallableItem.OriginFile.Digest -eq $hash -and -not $processedHashes.ContainsKey($hash)) {

                # Return the result if a matching digest is found in the catalog
                $catMatchResult = [PSCustomObject]@{
                    CatTitle    = $node.LocalizedProperties.Title
                    CatFileName = $node.InstallableItem.OriginFile.FileName
                    CatFileHash = $node.InstallableItem.OriginFile.Digest
                    CatBulletin = $node.UpdateSpecificData.SecurityBulletinID
                }
                $resultCatArray += $catMatchResult

                # Add the hash to the processed hashes table
                $processedHashes[$hash] = $true
            }
        }
        
        # Reset the processed hashes table
        $processedHashes = @{}
    }

    Return $resultCatArray
}

################# MAIN #################


################# 1: Get Patch My PC Environment #################

# Check if Patch My PC Publishing Service is installed
$settingsReg = (Get-ItemProperty -Path "HKLM:\$pmpreg" -Name 'Path').Path
$settingsFile = Get-Item -Path $settingsReg
$settingsXml = [xml](Get-Content -Path (Join-Path -Path $settingsFile.FullName -ChildPath 'Settings.xml')) 
$localContentRepo = $settingsXml.'PatchMyPC-Settings'.LocalContentRepository

# Test if Local Content Repository path exists. Exit if it doesn't
Try {
    Test-Path -Path $localContentRepo -ErrorAction Stop | Out-Null
}
Catch {
    Write-Warning -Message 'Could not find the Local Content Repository path in the Patch My PC Publishing Service registry key'
    Exit
}

################# 2: Get installer files from Local Content Repository #################

# Get all .exe and .msi files in the Local Content Repository
$resultArray = @()
$files = Get-ChildItem -Path $localContentRepo -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*msi" -or $_.Name -like "*exe" }
Write-Verbose -Message ("There {0} '{1}' file{2} in the Local Content Repository. Getting file information, please wait..." -f $(If (($files | Measure-Object).Count -eq 1) { "is" } Else { "are" }), ($files | Measure-Object).Count, $(If (($files | Measure-Object).Count -ne 1) { "s" } Else { $Null }))

Foreach ($file in $files) {
    $msiVersion = $Null

    # Attempt to get MSI Version information from MSI database
    If ($file.FullName.EndsWith(".msi")) {
        
        $msiVersion = Get-MsiInfo -File $file.FullName -Property 'ProductVersion' | Out-String
        $msiVersion = $msiVersion.TrimEnd()
    }

    # Get SHA1 hash of file and encode it to Base64
    $fileHash = Get-FileHash $file.FullName -Algorithm SHA1
    $encodedhash = Get-EncodedHash -HashValue $fileHash
    
    # Build result object
    $result = [PSCustomObject]@{
        Name           = $file.FullName
        FileVersion    = $file.VersionInfo.FileVersion
        ProductVersion = $file.VersionInfo.ProductVersion
        MSIVersion     = $msiVersion
        FileHash       = $encodedhash
    }

    $resultArray += $result
}

# Output result to console
$resultArray | Format-Table -AutoSize
$hashesOnDisk = $resultArray.FileHash

################# 3: Check if the hash of the files in the Local Content Reposity are matched in the Patch My PC catalog #################

# Check if the hash exists in the Patch My PC catalog
$catalogFile = Join-Path -Path $settingsFile -ChildPath 'Latest Catalog\PatchMyPC.xml'
Write-Verbose -Message ("Loading Patch My PC catalog from '{0}'" -f $catalogFile)
$xmlContentCommand = Measure-Command { $xmlContent = Get-CatalogXml -CatalogPath $catalogFile }
Write-Verbose -Message ("It took '{0}' seconds to load '{1}' products from the Patch My PC catalog" -f $xmlContentCommand.TotalSeconds , ($xmlContent.Node | Measure-Object).Count)
$catalogData = Get-CatalogHash -Catalog $xmlContent -EncodedHashes $hashesOnDisk

# Output Patch My PC hash match to file on disk result to console
If ($catalogData) {
    Write-Verbose -Message ("There {0} '{1}' file{2} in the Local Content Repository matching hashes in the Patch My PC catalog" -f $(If (($catalogData | Measure-Object).Count -eq 1) { "is" } Else { "are" }), ($catalogData | Measure-Object).Count, $(If (($catalogData | Measure-Object).Count -ne 1) { "s" } Else { $Null }))
    $catalogData | Format-Table -AutoSize
}
Else {
    Write-Verbose -Message "None of the files found in the Local Content Repository were matched to the Patch My PC catalog"
}

################# 4: Merge Local Content Repository and catalog data results and prepare for CSV export of results #################

# Merge Catalog data to result array
$mergedArray = @()
ForEach ($result in $resultArray) {
    $newArrayResults = [PSCustomObject]@{
        Name            = $result.Name
        FileVersion     = $result.FileVersion
        ProductVersion  = $result.ProductVersion
        MSIVersion      = $result.MSIVersion
        FileHash        = $result.FileHash
        CatMatch        = $false
        CatTitle        = $Null
        CatFileName     = $Null
        CatFileHash     = $Null
        CatFileBulletin = $Null
    }

    ForEach ($catResult in $catalogData) {
        
        If ($result.FileHash -eq $catResult.CatFileHash) {
            $newArrayResults.CatMatch = $true
            $newArrayResults.CatTitle = $catResult.CatTitle
            $newArrayResults.CatFileName = $catResult.CatFileName
            $newArrayResults.CatFileHash = $catResult.CatFileHash
            $newArrayResults.CatFileBulletin = $catResult.CatBulletin
        } 
    }
    $mergedArray += $newArrayResults
}

# Export results to CSV, preferring the Local Content Repository location first and then the current working directory
Try {
    $mergedArray | Export-Csv -Path $localContentRepo\LocalContentHashes.csv -NoTypeInformation -ErrorAction Continue

    If (Test-Path -Path $localContentRepo\LocalContentHashes.csv) {
        Write-Verbose -Message ("CSV file succesfully exported to '{0}'" -f "$localContentRepo\LocalContentHashes.csv") 
    }
}
Catch {
    Write-Verbose -Message ("Failed to export CSV file to '{0}': {1}" -f "$localContentRepo\LocalContentHashes.csv", $_)
}
If (-not (Test-Path -Path $localContentRepo\LocalContentHashes.csv)) {
    Write-Verbose -Message ("Failed to export CSV file to '{0}'. Check your account has permissions to write to that location. Trying to save instead to current working directory..." -f "$localContentRepo\LocalContentHashes.csv")
    Try {
        $mergedArray | Export-Csv -Path .\LocalContentHashes.csv -NoTypeInformation
        If (Test-Path -Path .\LocalContentHashes.csv) {
            Write-Verbose -Message ("CSV file succesfully exported to '{0}'" -f (((Get-Location).Path, "\LocalContentHashes.csv") -join ""))
        }
    }
    Catch {
        Write-Verbose -Message ("Failed to export CSV file to '{0}'. Check your account has permissions to write to that location." -f ((Get-Location).Path, "\LocalContentHashes.csv") -join "")
    }
}
# SIG # Begin signature block
# MIIogQYJKoZIhvcNAQcCoIIocjCCKG4CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBJPLhmiy/eihtS
# /ZVVli97dZeAqhaVSjyT05NNtnYZ3aCCIYQwggWNMIIEdaADAgECAhAOmxiO+dAt
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
# Vzu0nAPthkX0tGFuv2jiJmCG6sivqf6UHedjGzqGVnhOMIIGvDCCBKSgAwIBAgIQ
# C65mvFq6f5WHxvnpBOMzBDANBgkqhkiG9w0BAQsFADBjMQswCQYDVQQGEwJVUzEX
# MBUGA1UEChMORGlnaUNlcnQsIEluYy4xOzA5BgNVBAMTMkRpZ2lDZXJ0IFRydXN0
# ZWQgRzQgUlNBNDA5NiBTSEEyNTYgVGltZVN0YW1waW5nIENBMB4XDTI0MDkyNjAw
# MDAwMFoXDTM1MTEyNTIzNTk1OVowQjELMAkGA1UEBhMCVVMxETAPBgNVBAoTCERp
# Z2lDZXJ0MSAwHgYDVQQDExdEaWdpQ2VydCBUaW1lc3RhbXAgMjAyNDCCAiIwDQYJ
# KoZIhvcNAQEBBQADggIPADCCAgoCggIBAL5qc5/2lSGrljC6W23mWaO16P2RHxjE
# iDtqmeOlwf0KMCBDEr4IxHRGd7+L660x5XltSVhhK64zi9CeC9B6lUdXM0s71EOc
# Re8+CEJp+3R2O8oo76EO7o5tLuslxdr9Qq82aKcpA9O//X6QE+AcaU/byaCagLD/
# GLoUb35SfWHh43rOH3bpLEx7pZ7avVnpUVmPvkxT8c2a2yC0WMp8hMu60tZR0Cha
# V76Nhnj37DEYTX9ReNZ8hIOYe4jl7/r419CvEYVIrH6sN00yx49boUuumF9i2T8U
# uKGn9966fR5X6kgXj3o5WHhHVO+NBikDO0mlUh902wS/Eeh8F/UFaRp1z5SnROHw
# SJ+QQRZ1fisD8UTVDSupWJNstVkiqLq+ISTdEjJKGjVfIcsgA4l9cbk8Smlzddh4
# EfvFrpVNnes4c16Jidj5XiPVdsn5n10jxmGpxoMc6iPkoaDhi6JjHd5ibfdp5uzI
# Xp4P0wXkgNs+CO/CacBqU0R4k+8h6gYldp4FCMgrXdKWfM4N0u25OEAuEa3Jyidx
# W48jwBqIJqImd93NRxvd1aepSeNeREXAu2xUDEW8aqzFQDYmr9ZONuc2MhTMizch
# NULpUEoA6Vva7b1XCB+1rxvbKmLqfY/M/SdV6mwWTyeVy5Z/JkvMFpnQy5wR14GJ
# cv6dQ4aEKOX5AgMBAAGjggGLMIIBhzAOBgNVHQ8BAf8EBAMCB4AwDAYDVR0TAQH/
# BAIwADAWBgNVHSUBAf8EDDAKBggrBgEFBQcDCDAgBgNVHSAEGTAXMAgGBmeBDAEE
# AjALBglghkgBhv1sBwEwHwYDVR0jBBgwFoAUuhbZbU2FL3MpdpovdYxqII+eyG8w
# HQYDVR0OBBYEFJ9XLAN3DigVkGalY17uT5IfdqBbMFoGA1UdHwRTMFEwT6BNoEuG
# SWh0dHA6Ly9jcmwzLmRpZ2ljZXJ0LmNvbS9EaWdpQ2VydFRydXN0ZWRHNFJTQTQw
# OTZTSEEyNTZUaW1lU3RhbXBpbmdDQS5jcmwwgZAGCCsGAQUFBwEBBIGDMIGAMCQG
# CCsGAQUFBzABhhhodHRwOi8vb2NzcC5kaWdpY2VydC5jb20wWAYIKwYBBQUHMAKG
# TGh0dHA6Ly9jYWNlcnRzLmRpZ2ljZXJ0LmNvbS9EaWdpQ2VydFRydXN0ZWRHNFJT
# QTQwOTZTSEEyNTZUaW1lU3RhbXBpbmdDQS5jcnQwDQYJKoZIhvcNAQELBQADggIB
# AD2tHh92mVvjOIQSR9lDkfYR25tOCB3RKE/P09x7gUsmXqt40ouRl3lj+8QioVYq
# 3igpwrPvBmZdrlWBb0HvqT00nFSXgmUrDKNSQqGTdpjHsPy+LaalTW0qVjvUBhcH
# zBMutB6HzeledbDCzFzUy34VarPnvIWrqVogK0qM8gJhh/+qDEAIdO/KkYesLyTV
# OoJ4eTq7gj9UFAL1UruJKlTnCVaM2UeUUW/8z3fvjxhN6hdT98Vr2FYlCS7Mbb4H
# v5swO+aAXxWUm3WpByXtgVQxiBlTVYzqfLDbe9PpBKDBfk+rabTFDZXoUke7zPgt
# d7/fvWTlCs30VAGEsshJmLbJ6ZbQ/xll/HjO9JbNVekBv2Tgem+mLptR7yIrpaid
# RJXrI+UzB6vAlk/8a1u7cIqV0yef4uaZFORNekUgQHTqddmsPCEIYQP7xGxZBIhd
# mm4bhYsVA6G2WgNFYagLDBzpmk9104WQzYuVNsxyoVLObhx3RugaEGru+SojW4dH
# PoWrUhftNpFC5H7QEY7MhKRyrBe7ucykW7eaCuWBsBb4HOKRFVDcrZgdwaSIqMDi
# CLg4D+TPVgKx2EgEdeoHNHT9l3ZDBD+XgbF+23/zBjeCtxz+dL/9NWR6P2eZRi7z
# cEO1xwcdcqJsyz/JceENc2Sg8h3KeFUCS7tpFk7CrDqkMIIHyTCCBbGgAwIBAgIQ
# DMNw87U7UZ48Hv1za61jojANBgkqhkiG9w0BAQsFADBpMQswCQYDVQQGEwJVUzEX
# MBUGA1UEChMORGlnaUNlcnQsIEluYy4xQTA/BgNVBAMTOERpZ2lDZXJ0IFRydXN0
# ZWQgRzQgQ29kZSBTaWduaW5nIFJTQTQwOTYgU0hBMzg0IDIwMjEgQ0ExMB4XDTIz
# MDQwNzAwMDAwMFoXDTI2MDQzMDIzNTk1OVowgdExEzARBgsrBgEEAYI3PAIBAxMC
# VVMxGTAXBgsrBgEEAYI3PAIBAhMIQ29sb3JhZG8xHTAbBgNVBA8MFFByaXZhdGUg
# T3JnYW5pemF0aW9uMRQwEgYDVQQFEwsyMDEzMTYzODMyNzELMAkGA1UEBhMCVVMx
# ETAPBgNVBAgTCENvbG9yYWRvMRQwEgYDVQQHEwtDYXN0bGUgUm9jazEZMBcGA1UE
# ChMQUGF0Y2ggTXkgUEMsIExMQzEZMBcGA1UEAxMQUGF0Y2ggTXkgUEMsIExMQzCC
# AiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAKaQcs40YzBFv5HXQFPd04rK
# J4uBdwvAZLKuULy+icZOpgs/Sy329Ng5ikhB5o1IdvE2cOT20sjs3qgb4e+rqs7t
# aTCe6RNLsDINsmcTlp4yxOfV80EZ08ld3o36GEgH0Vy1vrJXLTRKNULzV7gIzF/e
# 3tO1Fab4IxKZNcBSXiv8ORqcgT9O7/RZoqyG87iU6Q/dKfC4WzvU396XJ3FMZrI+
# s4CgV8p6pVNjijBjH7pmzoXynFtA0j6NH6tg4DmQvm+kfWXtWbDpPYhdFz1gccJt
# 1DjTrJetpIwBzDAS8NGA75HQhBmQ3gcnNDJLgylB3HyWOeXS+vxXR0Pi/W419cfn
# 8zCFH0u2O4QFaZsT2HoIE/t9EhdAKdHoKwvVoCgwvlx3jjwFq5MnoB2oJiNmTGQy
# hiRvCaw6JACKUa43eJvlRKylEy4INDTOX5BeivJoTqCw0cCAd6ZuRh6gRl8shIVf
# N78qunQqJZQkDimtQY5Sn33w+ee5/lFSxOxBg6iu7vCGPZ6QxJd6oVdRa8t87vJ4
# QVlsMQQRa400S7kqIX1HOnbR3hxgvcks8kBRMYtZ8g3Fz/WTCW5sWbExVpn6HC6D
# sRhosF/DBGYmIqQJz6odkCFCr7QcmpGjoZs4jRDegSC5utEusBYmvCfVxtud3R43
# WEdCRfHuD1OFDm5HoonnAgMBAAGjggICMIIB/jAfBgNVHSMEGDAWgBRoN+Drtjv4
# XxGG+/5hewiIZfROQjAdBgNVHQ4EFgQU3wgET0b7maQo7OF3wwGWm83hl+0wDgYD
# VR0PAQH/BAQDAgeAMBMGA1UdJQQMMAoGCCsGAQUFBwMDMIG1BgNVHR8Ega0wgaow
# U6BRoE+GTWh0dHA6Ly9jcmwzLmRpZ2ljZXJ0LmNvbS9EaWdpQ2VydFRydXN0ZWRH
# NENvZGVTaWduaW5nUlNBNDA5NlNIQTM4NDIwMjFDQTEuY3JsMFOgUaBPhk1odHRw
# Oi8vY3JsNC5kaWdpY2VydC5jb20vRGlnaUNlcnRUcnVzdGVkRzRDb2RlU2lnbmlu
# Z1JTQTQwOTZTSEEzODQyMDIxQ0ExLmNybDA9BgNVHSAENjA0MDIGBWeBDAEDMCkw
# JwYIKwYBBQUHAgEWG2h0dHA6Ly93d3cuZGlnaWNlcnQuY29tL0NQUzCBlAYIKwYB
# BQUHAQEEgYcwgYQwJAYIKwYBBQUHMAGGGGh0dHA6Ly9vY3NwLmRpZ2ljZXJ0LmNv
# bTBcBggrBgEFBQcwAoZQaHR0cDovL2NhY2VydHMuZGlnaWNlcnQuY29tL0RpZ2lD
# ZXJ0VHJ1c3RlZEc0Q29kZVNpZ25pbmdSU0E0MDk2U0hBMzg0MjAyMUNBMS5jcnQw
# CQYDVR0TBAIwADANBgkqhkiG9w0BAQsFAAOCAgEADaIfBgYBzz7rZspAw5OGKL7n
# t4eo6SMcS91NAex1HWxak4hX7yqQB25Oa66WaVBtd14rZxptoGQ88FDezI1qyUs4
# bwi4NaW9WBY8QDnGGhgyZ3aT3ZEBEvMWy6MFpzlyvjPBcWE5OGuoRMhP42TSMhvF
# lZGCPZy02PLUdGcTynL55YhdTcGJnX0Z2OgSaHUQTmXhgRX+fajIilPnmmv8Av4C
# lr6Xa9SoNHltA04JRiCu4ejDGFqA94F696jSJ+AUYHys6bnPc0E8JB9YnFCAurPR
# G8YBJAofUtxnGIHGE0EiQTZeXf0nKmVBIXkE3hT4mZx7pH7wrlCr0FV4qnq6j0ua
# j4oKqFbkdyzb5u+XQe9pPojshnjVzhIRK53wsGaFP4gSURxWvcThIOyoaKrVDZOd
# LQZXEz8Anks3Vs5XscjyzFR7pv/3Reik7FaZRTvd5rDW6foDJOiCwX5p+UnldHGH
# W83rDvtks1rwgKwuuxvCG3Bkjirl94EImpiugGaRQ7S2Lydxpqzv7Hng4YQbIIvV
# MNC7mNrVZPNWdF4/a9yjDt2nJrnRcDK1zvHBXSrAYIycQ6hhhlHS9Y4MRhz35t1d
# u/Y0IXDB7HBYSvcsrpxtBzXLTd2NCNCtdkwYIl7WTQeoCbZWvo4PbzJBOnPjs1tN
# 4upe9XomxtZkNAwIOfMxggZTMIIGTwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYD
# VQQKEw5EaWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBH
# NCBDb2RlIFNpZ25pbmcgUlNBNDA5NiBTSEEzODQgMjAyMSBDQTECEAzDcPO1O1Ge
# PB79c2utY6IwDQYJYIZIAWUDBAIBBQCggYQwGAYKKwYBBAGCNwIBDDEKMAigAoAA
# oQKAADAZBgkqhkiG9w0BCQMxDAYKKwYBBAGCNwIBBDAcBgorBgEEAYI3AgELMQ4w
# DAYKKwYBBAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgCgTpAnC/a5yIjygiFj8kJJ27
# 7IpN33o3FwDtvXaelSIwDQYJKoZIhvcNAQEBBQAEggIAbVLHlUfkhawKqQeDOs4I
# 94L8T3n5qOIR/JHwB7a3GwZffK61zp2PZt+DfZB7D+kv5N1DJ1/sCUEWz6r8uLrV
# +r4qenjKAr+KmrDfuLgwmAUwgbfGojvyNmKST32yX3TjyYwFwpQg0q7+R7mlB8Ce
# eTdkhqM6Vhpd+zKJcEU5uxLLITLDq+KGKiSEiw8YO1M6x/yDM5H5EM4koiFC7Elf
# MR0Bt4QhahNb3Cycnx052S82m2aU7jdXKjgjgGMzE/DB8aB8fBLLU97dWL8XTfPf
# PiSm+Fb96mTvA64d0m5C39NkL6NNmQb5lS+2a63r9PLU89H1cep5PHgAjlMxr+x/
# cW7PoSrls+Mq3ldT5UZBkc58WfY8pnEkN/8tHZ9qTzZ1dmSB6MJvUtWP2gDc/JkA
# kMHQk0rAcA3cjS56dPjp6umR1MdIX3Buai0yHShrY86JlLvmvN6sozg7dcPAmUrO
# f4SBab/wHIcnvFblLwRGqN4vzaHPTpEfDCoxuEBXL8Xt79X1Al36kvIfIm6wRLkJ
# tCOTFBnlLWFs3mSuLJ53UtNGCPpq8p6PsT8IkWIREnIEeMPdzmacFOU9W1O+gYCS
# Nr1HXL1Dt1dC3tCHMSIC0BX4e6u5vmBto6PV5DnvQIzf63+RfaWJCQc/HUYIixnO
# eSb+pcAKSg2pdfsoqaT6HTGhggMgMIIDHAYJKoZIhvcNAQkGMYIDDTCCAwkCAQEw
# dzBjMQswCQYDVQQGEwJVUzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4xOzA5BgNV
# BAMTMkRpZ2lDZXJ0IFRydXN0ZWQgRzQgUlNBNDA5NiBTSEEyNTYgVGltZVN0YW1w
# aW5nIENBAhALrma8Wrp/lYfG+ekE4zMEMA0GCWCGSAFlAwQCAQUAoGkwGAYJKoZI
# hvcNAQkDMQsGCSqGSIb3DQEHATAcBgkqhkiG9w0BCQUxDxcNMjQxMjEyMTUyNTUy
# WjAvBgkqhkiG9w0BCQQxIgQguBe93ExZeJhGaidAOB1HvY0pcbtg+Mq+Qy9rXfgH
# 930wDQYJKoZIhvcNAQEBBQAEggIArVWzxtpOGZ2dTAtjdb9TkCvSAOZLUsJP5svB
# f52slHGzAwD7XECEiE1+5A9mmTvedOgFpP7V94UBRk1V0h51Hib4KlizPAFIEQ5e
# 8Hxz6DiRmTeC7OAi05ZgXlUa6Uizm3TLZ6yWFWc4L7fvVN3cAr7rv6D0SmWEjtnS
# aEMqcLtX9+RqLqvUWwYwmd8QC5s4DeYnUItA9wm2NaHvEZMjoe/BB24Qf1GSfL9O
# VLfPnFn1+rfkLbOJ2txgPYTjePg6rN7/T0ajtmpVDuepUaOmtoCSoX1E/+lT2qHB
# vo7CoKlTw0GdDNqe65gTMp5CWbEXhEYyqIwPIwxs8R9ma3WOhRV96C6SlFfe+zu5
# Ooz1gqh1OJ46g+zNhBYaKoZeNQVFJbfLNKBRvtZ//aOgVTbqFWVopokVtLyWp3r7
# TsU+VymQ2o4+TXmBFMowu+E9wg4a3iBwz6JkKGiBBM4tRqWOz2ksPfWp1vyMYCRp
# vC+YMJ+RzQbn0sJlkTuZUGqMxNBdz7En/NvFFbkAxPkmGopGYYDqeZ4FVy3kD67Z
# MrddsVCFe5nloS4wN9oI6AcgD5YG7IZdy6Vr10dvrvAxvHZsuLpBGFE7NkChukZr
# 8FpAy/IAvBJOOJjcPTkh/bP0SID9dj3MPXO1elxVebOedgF1YaT10bVoD8QVHiPe
# X0BPfvY=
# SIG # End signature block
