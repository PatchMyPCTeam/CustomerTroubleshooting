<#
    .SYNOPSIS
        Searches the local WSUS for all Patch My PC (PMPC) updates and marks them as IsLocallyPublished = 0 in the SUSDB.

    .DESCRIPTION
        This script forces all PMPC updates to appear in the WSUS console. This is useful when WSUS is in a **standalone** 
        scenario where updates are not managed through ConfigMgr.

        By default, third-party updates do not appear in the WSUS console unless managed through ConfigMgr. This script provides 
        a **workaround** by updating the SUSDB directly.

        **Key Features:**
        - **Automatically installs SQLCMD** if it is not found.
        - **Detects whether WSUS uses WID or SQL Server** and connects accordingly.
        - **Updates all Patch My PC updates** to show in the WSUS console.

    .EXAMPLE
        Set-PMPCUpdatesToShowInWSUS.ps1
        Marks all Patch My PC updates as visible in the WSUS console.

    .NOTES
        ################# DISCLAIMER #################
        Patch My PC provides scripts, macros, and other code examples for illustration only, without warranty 
        either expressed or implied, including but not limited to the implied warranties of merchantability 
        and/or fitness for a particular purpose. 

        This script is provided **"AS IS"**, and Patch My PC does not guarantee that the following script, macro, 
        or code can or should be used in any situation or that the operation of the code will be error-free.
#>
$VerbosePreference = "Continue"

# Check if SQLCMD already exists
$sqlcmdPath = "C:\Program Files\Microsoft SQL Server\Client SDK\ODBC\170\Tools\Binn\SQLCMD.EXE"
if (Test-Path $sqlcmdPath) {
    Write-Verbose "SQLCMD already exists at: $sqlcmdPath"
}
else {
    Write-Verbose "SQLCMD not found. Downloading and installing..."
    try {
        $downloadUrl = "https://go.microsoft.com/fwlink/?linkid=2230791"
        Invoke-WebRequest -Uri $downloadUrl -OutFile "sqlcmd.msi"
        Start-Process msiexec -ArgumentList "/i sqlcmd.msi /passive IACCEPTMSSQLCMDLNUTILSLICENSETERMS=YES" -Wait
       
        # Verify installation
        if (Test-Path $sqlcmdPath) {
            Write-Verbose "SQLCMD was successfully downloaded and installed at: $sqlcmdPath"
        }
        else {
            throw
        }
    }
    catch {
        throw
    }
}

# Determine WSUS Database Connection
$wsusRegPath = "HKLM:\SOFTWARE\Microsoft\Update Services\Server\Setup"
if (Test-Path $wsusRegPath) {
    $sqlServerName = (Get-ItemProperty -Path $wsusRegPath -Name "SqlServerName").SqlServerName
    if ($sqlServerName -match "MICROSOFT##WID") {

        # Use Named Pipe for WID
        $sqlInstance = "np:\\.\pipe\MICROSOFT##WID\tsql\query"
        Write-Verbose "Detected WSUS using WID. Connecting to: $sqlInstance"
    }
    else {

        # Use Standard SQL Server Connection
        $sqlInstance = "$sqlServerName"
        Write-Verbose "Detected WSUS using SQL Server. Connecting to: $sqlInstance"
    }
}
else {
    Write-Error "Unable to determine WSUS SQL connection settings. Ensure WSUS is installed."
    throw
}

try {
    $wsus = Get-WsusServer
    $pmpcCat = $wsus.GetUpdateCategories().where({ $_.Type -eq 'Company' -and $_.title -eq 'Patch My PC' })
    $scope = [Microsoft.UpdateServices.Administration.UpdateScope]::new()
    foreach ($cat in $pmpcCat) { $null = $scope.Categories.Add($cat) }
    $allPMPCUpdates = $wsus.GetUpdates($scope)

    # Count how many PMPC updates were found
    Write-Verbose "Found $($allPMPCUpdates.Count) total updates from 'Patch My PC'"
    
    if ($allPMPCUpdates.Count -gt 0) {
        # Prepare the update IDs as a string
        $updateIdString = "'" + [string]::Join("','", $allPMPCUpdates.id.updateid.guid) + "'"
        
        # First directly verify how many have IsLocallyPublished=1 in the database
        $countQuery = @"
        SET QUOTED_IDENTIFIER ON;
        SELECT COUNT(*) AS UpdateCount 
        FROM [SUSDB].[dbo].[tbUpdate] 
        WHERE [UpdateID] IN ($updateIdString)
        AND [IsLocallyPublished] = 1;
"@
        
        # Execute the count query
        $countResult = & $sqlcmdPath -S "$sqlInstance" -d SUSDB -Q "$countQuery" -h -1
        
        # Parse the result to get just the number
        $updateCount = ($countResult | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\d+$' } | Select-Object -First 1) -as [int]
        
        Write-Verbose "Found $updateCount PMPC updates with IsLocallyPublished=1"
        
        if ($updateCount -gt 0) {

            # Now perform the update
            $updateQuery = @"
            SET QUOTED_IDENTIFIER ON;
            UPDATE [SUSDB].[dbo].[tbUpdate] 
            SET [IsLocallyPublished] = 0 
            WHERE [UpdateID] IN ($updateIdString)
            AND [IsLocallyPublished] = 1;
            SELECT @@ROWCOUNT AS RowsAffected;
"@
            
            # Execute the SQL command and capture output
            $result = & $sqlcmdPath -S "$sqlInstance" -d SUSDB -Q "$updateQuery" 2>&1
            
            # Extract rows affected
            $rowsAffected = ($result | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\d+$' } | Select-Object -First 1) -as [int]

            # Check if command executed successfully
            if ($LASTEXITCODE -eq 0) {
                Write-Verbose "SQL command executed successfully"
                Write-Verbose "Modified $rowsAffected updates to set IsLocallyPublished=0"
            }
            else {
                Write-Error "SQL command failed with exit code: $LASTEXITCODE. Error details: $result"
            }
        }
        else {
            Write-Verbose "No changes needed."
        }
    }
    else {
        Write-Verbose "No PMPC updates found. Nothing to process."
    }
}
catch {
    Write-Error $_.Exception.Message
}