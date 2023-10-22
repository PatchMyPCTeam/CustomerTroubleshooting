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