<#
.SYNOPSIS
    Script to list all the files in the Patch My PC Local Content Repository. 
    The list is exported as a LocalContentHashes.csv in the Local Content Repository folder

.NOTES
    ################# DISCLAIMER #################
    Patch My PC provides scripts, macro, and other code examples for illustration only, without warranty 
    either expressed or implied, including but not limited to the implied warranties of merchantability 
    and/or fitness for a particular purpose. This script is provided 'AS IS' and Patch My PC does not 
    guarantee that the following script, macro, or code can or should be used in any situation or that 
    operation of the code will be error-free.
#>

$pmpreg = 'SOFTWARE\Patch My PC Publishing Service'
Function Get-EncodedHash {
    Param(
        [Parameter(Position = 0)]
        [System.Object]$hashValue
    )

    $hashBytes = $hashValue.Hash -split '(?<=\G..)(?=.)' | ForEach-Object { [byte]::Parse($_, 'HexNumber') }
    Return [Convert]::ToBase64String($hashBytes)
}

# Get Patch My PC Local Content Repository path from registry
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

# Get all .exe and .msi files in the Local Content Repository
$resultArray = @()
$files = Get-ChildItem -Path $localContentRepo -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*msi" -or $_.Name -like "*exe" }
Foreach ($file in $files) {

    $msiVersion = $Null

    # Attempt to get MSI Version information from MSI database
    If ($file.FullName.EndsWith(".msi")) {
        
        Try {
            $installer = New-Object -ComObject WindowsInstaller.Installer
            $database = $installer.GetType().InvokeMember("OpenDatabase", "InvokeMethod", $Null, $installer, @($file.FullName, 0))
            $query = "SELECT `Value` FROM `Property` WHERE `Property` = 'ProductVersion'"
            $view = $database.GetType().InvokeMember("OpenView", "InvokeMethod", $Null, $database, ($query))
            $view.GetType().InvokeMember("Execute", "InvokeMethod", $Null, $view, $Null)
            $record = $view.GetType().InvokeMember("Fetch", "InvokeMethod", $Null, $view, $Null)
            $msiVersion = $record.GetType().InvokeMember("StringData", "GetProperty", $Null, $record, 1)
            $view.GetType().InvokeMember("Close", "InvokeMethod", $Null, $view, $Null)
        }
        Catch {
            Write-Verbose ("Failed to get MSI file version for ""$($file.FullName)"". {0}" -f $_)
        }
    }

    # Get SHA1 hash of file and encode it to Base64
    $fileHash = Get-FileHash $file.FullName -Algorithm SHA1
    $encodedhash = Get-EncodedHash $fileHash
    
    # Build result object
    $result = [PSCustomObject]@{
        Name           = $file.FullName
        FileVersion    = $file.VersionInfo.FileVersion
        ProductVersion = $file.VersionInfo.ProductVersion
        MSIVersion     = $msiVersion
        Hash           = $encodedhash
    }
    $result
    $resultArray += $result
}

# Export result to CSV
$resultArray | Export-Csv -Path $localContentRepo\LocalContentHashes.csv -NoTypeInformation

If (Test-Path -Path localContentRepo\LocalContentHashes.csv) {
    Write-Verbose ('CSV file succesfully exported to {0}' -f "$localContentRepo\LocalContentHashes.csv")
}
Else {
    Write-Verbose ('Failed to export CSV file to {0}' -f "$localContentRepo\LocalContentHashes.csv")
}