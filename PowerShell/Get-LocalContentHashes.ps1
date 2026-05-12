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

# Check if the script is running with administrative permissions
If (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "This script must be run with administrative permissions. Please re-run it as Administrator."
}

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

    If (-not (Test-Path -Path $CatalogPath)) {
        throw ("Patch My PC catalog not found at '{0}'." -f $CatalogPath)
    }

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
$files = Get-ChildItem -Path $localContentRepo -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*msi" -or $_.Name -like "*exe" -or $_.Name -like "*zip" }
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
# MIIovgYJKoZIhvcNAQcCoIIorzCCKKsCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAH1deogD+d/O9F
# QXvFuDKCVQ8NNDvdTyUTkSl7hypjvaCCIbswggWNMIIEdaADAgECAhAOmxiO+dAt
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
# oAMCAQICEAlBhSwxLm93rMd0RNayLkYwDQYJKoZIhvcNAQELBQAwaTELMAkGA1UE
# BhMCVVMxFzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMUEwPwYDVQQDEzhEaWdpQ2Vy
# dCBUcnVzdGVkIEc0IENvZGUgU2lnbmluZyBSU0E0MDk2IFNIQTM4NCAyMDIxIENB
# MTAeFw0yNjAzMTEwMDAwMDBaFw0yNzA0MzAyMzU5NTlaMIHRMRMwEQYLKwYBBAGC
# NzwCAQMTAlVTMRkwFwYLKwYBBAGCNzwCAQITCENvbG9yYWRvMR0wGwYDVQQPDBRQ
# cml2YXRlIE9yZ2FuaXphdGlvbjEUMBIGA1UEBRMLMjAxMzE2MzgzMjcxCzAJBgNV
# BAYTAlVTMREwDwYDVQQIEwhDb2xvcmFkbzEUMBIGA1UEBxMLQ2FzdGxlIFJvY2sx
# GTAXBgNVBAoTEFBhdGNoIE15IFBDLCBMTEMxGTAXBgNVBAMTEFBhdGNoIE15IFBD
# LCBMTEMwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQCmFrmhTn0idojJ
# 7d51YC3OJjnDjtWd/u1iGtKr+/61XDDQ0uvrt5yzd0++cH4hIFRvI5Xk6Ie6GWuR
# /DIiNZhMHnmVUx1L/9XkUHp/KAwdwkeYtTn6Dyhcqbxild42QmSYaCoTz5tpz99i
# ZqcarQQ8c85j/6OMt312iixZD/OBcGokpkllnkyvQnnXib4+hXtCrtyomRTU857J
# fkPZKUdHKk8WElPi9PtIHjoWoNQkTIFUeqONuADgVcTha7cQKgHphcKhqZT+GHIC
# NyHiL7ecBrNGgox9Zpd2Xbl845WvXrbyIwpxbwV68nsLTlxNA7faXEDdSMu4uqwN
# LE8hcEUfETvAZ0A1xqnFrERFPdXQ0xflKuZVSLDak5mYKpb6CmcRlCrBj8SXj7NM
# 1QPETxMbsWknnmFxhcj/mBkDITdBXpBJnSKB2xLwzC8eZTqlYQ7gDqoIcEAJv/Pd
# SDIVRbCB9T8ziLmIYBAMjKY1tPMyMI+kG4+pChadsD644tKlzzUXyHvwvbHOuzwr
# vwq8UsMrG27wQA6uW4nZrgaYmVbLTSikYhTVczV7txTuHj8O6W2E87LVL6TPntLp
# kXC1TyRJ3jqBXDK+MjzvaQqcOgDwETNTRkLBOMsy3ByChCKfW6Ze4rdmzqBK5OPi
# ohJ3LT7Kp2WzJq9GX48C6ytA9WwGDwIDAQABo4ICAjCCAf4wHwYDVR0jBBgwFoAU
# aDfg67Y7+F8Rhvv+YXsIiGX0TkIwHQYDVR0OBBYEFEsL1EbO9agQBUggqfsA2InI
# I6VQMD0GA1UdIAQ2MDQwMgYFZ4EMAQMwKTAnBggrBgEFBQcCARYbaHR0cDovL3d3
# dy5kaWdpY2VydC5jb20vQ1BTMA4GA1UdDwEB/wQEAwIHgDATBgNVHSUEDDAKBggr
# BgEFBQcDAzCBtQYDVR0fBIGtMIGqMFOgUaBPhk1odHRwOi8vY3JsMy5kaWdpY2Vy
# dC5jb20vRGlnaUNlcnRUcnVzdGVkRzRDb2RlU2lnbmluZ1JTQTQwOTZTSEEzODQy
# MDIxQ0ExLmNybDBToFGgT4ZNaHR0cDovL2NybDQuZGlnaWNlcnQuY29tL0RpZ2lD
# ZXJ0VHJ1c3RlZEc0Q29kZVNpZ25pbmdSU0E0MDk2U0hBMzg0MjAyMUNBMS5jcmww
# gZQGCCsGAQUFBwEBBIGHMIGEMCQGCCsGAQUFBzABhhhodHRwOi8vb2NzcC5kaWdp
# Y2VydC5jb20wXAYIKwYBBQUHMAKGUGh0dHA6Ly9jYWNlcnRzLmRpZ2ljZXJ0LmNv
# bS9EaWdpQ2VydFRydXN0ZWRHNENvZGVTaWduaW5nUlNBNDA5NlNIQTM4NDIwMjFD
# QTEuY3J0MAkGA1UdEwQCMAAwDQYJKoZIhvcNAQELBQADggIBAB+ZTb1BVZB0FiG8
# voHj1X6KDkHT2iaeyBtzclOYGpkRDubMDztoEh/kSlYY4aHs+i7IOAL0JLaWBaNx
# f4+BOU5TU/6TBsBqrNw3k/keSWXhkKG8TG6gbOk3FlvC1Vaio9MwL6kOCIcnlIXw
# +DIgqe4xFbe3UYb6d8LQZqpHCB98yT7nzOgiaKfE8B4ldqMr/ZPMFZ1RV1k3VG8l
# qIpZF2Z2hXve5gcRMn/vohC/NQYuNTsnOziuFHA+w4d0BAhdRPukFMRvNcpKYWtf
# vwFW9Kz8YlJfXKVs7P034GY08MWP89GSNL8jP1LdNcaxT1Vwao2kfDsTgM44Bo3E
# 8pG0ne1KCT9jBHmi/UikZazXkong9vfg7LmWqoX5BeSRlsmg4alkoZqLPbsBuTxG
# H/uBTl+omarkA+HFZYczgVaJq3GB/nve7z5oJkTKfoRmV+ungzbML42sxb1GXJQy
# A3t6w8Bw4b76188qaxZiK4Z0mZAkM5Xt7I1UglR6I1EFdxvgZYioVBH/4eCoxiwg
# Ad3np7sk2OHNOLbY5LLepi/brPoZ4ZiW0ycuJPx91zFSbySYMbQ1rHf16lD2DP9D
# da/oN6yed825gYbar00PzcDjqlPZzs+CImYqG055nfZDzwip+Bu09AaTzHsYNevK
# kNb21I0wTdWZauRdVYHUj3qblAlwMYIGWTCCBlUCAQEwfTBpMQswCQYDVQQGEwJV
# UzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4xQTA/BgNVBAMTOERpZ2lDZXJ0IFRy
# dXN0ZWQgRzQgQ29kZSBTaWduaW5nIFJTQTQwOTYgU0hBMzg0IDIwMjEgQ0ExAhAJ
# QYUsMS5vd6zHdETWsi5GMA0GCWCGSAFlAwQCAQUAoIGEMBgGCisGAQQBgjcCAQwx
# CjAIoAKAAKECgAAwGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwHAYKKwYBBAGC
# NwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEIA+WvZkb5zIhnBtH
# XR3ftYu2iy0XX2p/8wuBzePAc8kQMA0GCSqGSIb3DQEBAQUABIICABT812UCQLC5
# 2eBiPdQ+o6NIa65dVo3Z9ceruKOo+vXa4iSLgViTQE6JB9C6Jdpf0eKda/7ZS3T2
# eRpITc/jHRMFqMNzm6fPqBe7pj/wRwNjwRI2T3MsVnDl3abrhZIVF2TZP849lAKm
# csYy39GI//ibNMAZ34cZ9dKhVJ56SBqGV0arm+lsSJc3aPknZ8fu9T7ELNzy6SnS
# YLm06N/piLpH+Zj010f1+DibpyxzycQIwg2LRT//JVR16fsKt+H03b1KhsG2FOrU
# GbUns2OQgq2WKd8ArIodo8APvSKVIfbT7Nm55TTU/0HMBll8NNOFJwyPictV4zL+
# G//2GnuMQipKxqbzV8AprirsSY2stTnoxRiXHLlqzhRKddRQ7gzyEB3IVEex+IQ0
# VCiQ+WFs9PLO0RakkxyATYWmhx5md95Qatvr6YLSfAoyUjf6U1TH3IjKrDJs6wE/
# DXOHUxUulxtmGiwMuLNIetPT/nfQAbSL456R84NBK8C2mpjcpOWcxVe17LIOCdeT
# m58QJQ5NWIdnQWG9aySl3JACEw4xouVff7MhXZu4bFgnJktQanFD+xOo7Y/TWlHR
# q0dH/VE9QpJ3ioXoO56z9gglgrnSgjcOD3JV398A37Sqta/BbkN/w/8nBvW7lytX
# e8TsEKSNojm72nWevwBwckbPztqK5uxEoYIDJjCCAyIGCSqGSIb3DQEJBjGCAxMw
# ggMPAgEBMH0waTELMAkGA1UEBhMCVVMxFzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMu
# MUEwPwYDVQQDEzhEaWdpQ2VydCBUcnVzdGVkIEc0IFRpbWVTdGFtcGluZyBSU0E0
# MDk2IFNIQTI1NiAyMDI1IENBMQIQCoDvGEuN8QWC0cR2p5V0aDANBglghkgBZQME
# AgEFAKBpMBgGCSqGSIb3DQEJAzELBgkqhkiG9w0BBwEwHAYJKoZIhvcNAQkFMQ8X
# DTI2MDUxMTE3NTcxNFowLwYJKoZIhvcNAQkEMSIEIEaRb2eFXzuPJL0Ev0QugX83
# bLKRLsaBUurHKDIpGG2hMA0GCSqGSIb3DQEBAQUABIICAMbaxt27XjOEYQrDkW9b
# wMsVEjcGWFJKt8wo7w1LwwURMVlwJgqlUgxsM05D5fQnjvz1usk6I5DSJoiH2z88
# b8tBQ3ibKbv36XFGrJbMG+0bec4SVaeiJtBf6YZ+pt/SA6nmxF6z9jMWji2zOw/z
# jM3q9EH+iBbx0N6EPru7Cjy9Xt6pvJtTLJZYHmOp2xu5amMVwh0QuVvDN8zxKfQh
# vBG2eawYu2T9hyN0cVm2qDBYesjN4/UqVJLKdf2b8NlsJInqQPbXcD1zADWw9ucK
# aqmDrbLEynShXjpCmHi6Mp/FoPm2P2DqeU8aD8LMzY4aUzMOGZ15fzf1sLj35gtv
# rUnFviyN3XyHFP1N5AmEAy7uPTS8CWXh8oh0veqTNbB3Y/koWN3GMbVvw+x56Q0H
# SOSJXFvBgBRzg0xB6uyXLXxJkoGzBAjmVHFEu5EXZJAC6blJzIXzm/6c+KlxVgxg
# 182SLXjEBsuGhXxp0/5YphUzYYvh5Y1ZAMgdk0YbWT6knXF8zhbo8lTKNkki+Wwp
# xigRGdnBfpeeSQf93k8MLkL1oVym3RKA0ui8g8P+T2vpT7RMsgipQZ3J0/Lw+eNH
# iuSvz24H7mUo5MMecxG07btq9Q6o0TL6PB+Gm1M9dj5d840s7FJfF22csCPGJbIR
# 7kRuGu5BcvkyD435RSOoeJuw
# SIG # End signature block
