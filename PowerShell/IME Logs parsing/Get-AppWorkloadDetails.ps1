<#
.SYNOPSIS
Parses Intune AppWorkload log files to extract information about Win32 App policies, GRS (Global Retry Schedule) details, or ESP (Enrollment Status Page) profile data.

.DESCRIPTION
This script processes the AppWorkload log files to retrieve specific information based on the selected parameter set:
- Retrieves Win32 App policies and can filter them by app name.
- Extracts GRS details for a specific Win32 App ID, including retry windows and registry keys to be deleted for fast installation retries.
- Parses ESP profile information to display app registration details during the enrollment process.

.PARAMETER logFilePath
The full path to the IME log file to be analyzed. This parameter is mandatory.

.PARAMETER getWin32AppPolicies
Switch to retrieve all Win32 App policies from the log file. Use this with the optional `appNameToSearchFor` parameter to filter results by app name.

.PARAMETER appNameToSearchFor
(Optional) The name of the app to filter the Win32 App policies. Used with the `getWin32AppPolicies` parameter.

.PARAMETER DetectionScript
Switch to include detection script information in the output when retrieving Win32 App policies. Used with the `getWin32AppPolicies` parameter.

.PARAMETER OutGridView
Switch to display the output in an Out-GridView window when retrieving Win32 App policies. Used with the `getWin32AppPolicies` parameter.

.PARAMETER getWin32AppGRSinfo
Switch to retrieve GRS (Global Retry Schedule) details for a specific Win32 App ID. Requires the `win32AppID` parameter.

.PARAMETER win32AppID
The ID of the Win32 App to retrieve GRS details for. Must be in GUID format. Used with the `getWin32AppGRSinfo` parameter.
If you don't know the GUID, you can use the `getWin32AppPolicies` parameter to find it.
This parameter is mandatory when using the `getWin32AppGRSinfo` switch.

.PARAMETER getESPprofileInfo
Switch to retrieve ESP (Enrollment Status Page) profile information from the log file.

.EXAMPLE
.\Get-AppWorkloadDetails.ps1 -logFilePath "C:\Logs\AppWorkload.log" -getWin32AppPolicies -appNameToSearchFor "Chrome"
Retrieves Win32 App policies from the specified log file and filters the results for apps with names containing "Chrome".

.EXAMPLE
.\Get-AppWorkloadDetails.ps1 -logFilePath "C:\Logs\AppWorkload.log" -getWin32AppPolicies -appNameToSearchFor "Office" -DetectionScript -OutGridView
Retrieves Win32 App policies for apps with names containing "Office", includes detection script information, and displays the results in an Out-GridView window.

.EXAMPLE
.\Get-AppWorkloadDetails.ps1 -logFilePath "C:\Logs\AppWorkload-20250314-191451.log" -getWin32AppGRSinfo -win32AppID "09da002a-e50f-459d-8364-b4f8fe012bc3"
Retrieves GRS details for the specified Win32 App ID from the log file.

.EXAMPLE
.\Get-AppWorkloadDetails.ps1 -logFilePath "C:\Logs\AppWorkload-20250314-191451.log" -getESPprofileInfo
Retrieves ESP profile information from the specified log file, if it exists.

.NOTES
- Ensure the log file path is valid and accessible.
- The script will throw errors if required parameters are missing or if the log file does not contain the expected data.

#>


param (
    [Parameter(Mandatory=$true)]
    [string]$logFilePath,

    # Params for getting Win32 App policies
    [Parameter(Mandatory=$true, ParameterSetName="GetWin32AppPolicies")]
    [switch]$getWin32AppPolicies,

    [Parameter(Mandatory=$false, ParameterSetName="GetWin32AppPolicies")]
    [string]$appNameToSearchFor,

    [Parameter(Mandatory=$false, ParameterSetName="GetWin32AppPolicies")]
    [switch]$DetectionScript,

    [Parameter(Mandatory=$false, ParameterSetName="GetWin32AppPolicies")]
    [switch]$OutGridView,

    # Params for getting Win32App GRS info
    [Parameter(Mandatory=$true, ParameterSetName="Win32AppGRSinfo")]
    [switch]$getWin32AppGRSinfo,

    [Parameter(Mandatory=$true, ParameterSetName="Win32AppGRSinfo")]
    [string]$win32AppID, #for testing 09da002a-e50f-459d-8364-b4f8fe012bc3

    # Parameter set to get info about win32 apps in ESP phase
    [Parameter(Mandatory=$true, ParameterSetName="GetESPprofileInfo")]
    [switch]$getESPprofileInfo
)

# Function to validate win32 app ID format. It will throw an error if the Win32AppID is not in the win32 app ID format.
function Test-GUID {
    param (
        [string]$guid
    )
    if ($guid -match '^[0-9a-zA-Z]{8}-[0-9a-zA-Z]{4}-[0-9a-zA-Z]{4}-[0-9a-zA-Z]{4}-[0-9a-zA-Z]{12}$') {
        return $true
    } else {
        return $false
    }
}

function Get-DetectionScriptInfo {
    param (
        [Parameter(Mandatory=$true)]
        [string]$ScriptContent
    )
    
    try {
        # Convert Content from Json
        $DetectionScriptValue = ($ScriptContent | ConvertFrom-Json -ErrorAction SilentlyContinue)
        
        # Check Detection is a Script
        if ($DetectionScriptValue.DetectionType -eq 3) {
            # Extract Script Body
            $DetectionScriptValue = (ConvertFrom-Json ($DetectionScriptValue.DetectionText) | Select-Object -ExpandProperty ScriptBody -ErrorAction SilentlyContinue)
            # Decode Base64
            $DetectionScriptValue = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($DetectionScriptValue))

            # Check Script Signature for Signer (CN)
            if ($DetectionScriptValue -match '# SIG # Begin signature block') {
                # Convert the detection script string to byte array for Get-AuthenticodeSignature
                $DetectionScriptSigner = ((Get-AuthenticodeSignature -Content $([System.Text.Encoding]::UTF8.GetBytes($DetectionScriptValue)) -SourcePathOrExtension ".ps1" | Select-Object *).SignerCertificate.Subject -split ',')[0]
            }
            else {
                $DetectionScriptSigner = 'Not Signed'
            }
        }
        else {
            $DetectionScriptValue = 'Not a Script'
            $DetectionScriptSigner = 'N/A'
        }
    }
    catch {
        # Catch any errors during detection script processing
        $DetectionScriptValue = 'Error'
        $DetectionScriptSigner = 'Error'
    }

    return [PSCustomObject]@{
            DetectionScript = $DetectionScriptValue
            DetectionSigner = $DetectionScriptSigner
        }
}

[string] $ErrorActionPreference = 'Stop'

try {
    # Check if the log file path exists, throw an error if it doesn't
    if (-not (Test-Path -Path $logFilePath)) {
        throw ("Error: The specified path {0} does not exist." -f $logFilePath)
    }

    $content = Get-Content -Path $logFilePath -Raw

    # If we're looking for Win32 App policies....
    if ($getWin32AppPolicies) {
        [string]$pattern = '<!\[LOG\[Get policies = \[(.*?)\]\]'

        [array]$myPolicyMatches = [regex]::Matches($content, $pattern)

        if ($myPolicyMatches.Count -eq 0) {
            throw "No win32 policy matches found in this log file"
        }

        # ... grab the most recent match...
        # added additional logic to ensure we get the most recent policy match WITH data in it.
        $mostRecentPolicy = $null
        foreach ($match in ($myPolicyMatches | Sort-Object { $_.Index } -Descending)) {
            $mostRecentPolicy = $match.Value -replace '^<!\[LOG\[Get policies = ', '' -replace '\]\]$', ']'
            if (-not [string]::IsNullOrWhiteSpace($mostRecentPolicy) -and $mostRecentPolicy -ne '[]') {
                break
            }
        }

        if (-not $mostRecentPolicy) {
            throw "No valid policy found in the log file"
        }

        $myWin32AppsInPolicy = $mostRecentPolicy | ConvertFrom-Json -ErrorAction Stop
        $filteredApps = $myWin32AppsInPolicy | Where-Object { $_.Name -like "*$appNameToSearchFor*" }

        if (-not $filteredApps) {
            throw "No results found for the specified app name: $appNameToSearchFor"
        }

        # Start Building PSCustomObject
        [Collections.Generic.List[PSCustomObject]]$PolicyApps = @()

        # Loop through the filteredApps
        foreach ($App in $filteredApps) {
            $App | ForEach-Object {
                # Create a PSCustomObject for each App
                $filteredAppsCustObj = [PSCustomObject]@{
                    'Win32 app ID'   = $_.ID
                    'Win32 app Name' = $_.Name
                    'Revision'       = $_.Version
                    'Intent'         = switch ($_.Intent) {
                        0 { 'Not Targeted' }
                        1 { 'Available' }
                        3 { 'Required' }
                        4 { 'Uninstall' }
                        Default { $_.Intent }
                    }
                    'TimeFormat'     = $_.StartDeadlineEx.TimeFormat
                    StartTime        = if ($_.StartDeadlineEx.StartTime -eq '1/1/0001 12:00:00 AM') { 'ASAP' } else { $_.StartDeadlineEx.StartTime }
                    Deadline         = if ($_.StartDeadlineEx.Deadline -eq '1/1/0001 12:00:00 AM') { 'ASAP' } else { $_.StartDeadlineEx.Deadline }
                    InstallContext   = switch (($_.InstallEx | ConvertFrom-Json -ErrorAction SilentlyContinue).RunAs) {
                        0 { 'USER' }
                        1 { 'SYSTEM' }
                        Default { ($_.InstallEx | ConvertFrom-Json -ErrorAction SilentlyContinue).RunAs }
                    }
                }

                # Add Detection Information
                if ($DetectionScript){
                    $filteredAppsCustObj | Add-Member -MemberType NoteProperty -Name 'DetectionSigner' -Value $(if ($_.DetectionRule){(Get-DetectionScriptInfo -ScriptContent $_.DetectionRule)}).DetectionSigner
                    $filteredAppsCustObj | Add-Member -MemberType NoteProperty -Name 'DetectionScript' -Value $(if ($_.DetectionRule){(Get-DetectionScriptInfo -ScriptContent $_.DetectionRule)}).DetectionScript
                }
            }
            
            # Add PSCustomObject to List
            $PolicyApps.Add($filteredAppsCustObj)
        }
        # Output
        if ($OutGridView) {
            $PolicyApps | Sort-Object 'Win32 app Name' | Out-GridView -Title "AppWorkload Policies [Total Records: $($PolicyApps.Count)]" -OutputMode Single
        }
        else {
            $PolicyApps | Sort-Object 'Win32 app Name' | Format-Table -AutoSize
        }
    }

    # If we're looking for GRS info....
    if ($getWin32AppGRSinfo) {
        # ... validate Win32AppID - throw an error if the Win32AppID is not in the expected format...
        if (-not (Test-GUID $win32AppID)) {
            throw "The win32AppID is not in the correct format."
        }

        # GRS Line Pattern
        [string]$grsPattern = '<!\[LOG\[\[Win32App\]\[GRSManager\].*'

        # Search for GRS Info
        $GRSInfoMatches = Select-String -Path "$($logFilePath)" -Pattern $grsPattern

        # GRS App ID Pattern
        [string]$grsAppIdPattern = 'Found GRS value: (\d{2}/\d{2}/\d{4} \d{2}:\d{2}:\d{2}) at key (.+)'

        # Find all the entries with the AppID and the GRS Pattern
        $GRSInfoMatches = $GRSInfoMatches | Where-Object { $_ -match "$($win32AppID)" } | Where-Object { $_ -match $grsAppIdPattern }

        # Build a Sortable List to find the latest entry
        [Collections.Generic.List[PSCustomObject]]$EntryObjects = @()
        foreach ($Entry in $GRSInfoMatches) {
            # Build a custom object with the info
            $GRSInfoObject = [PSCustomObject]@{
                'DateTime' = [datetime]::ParseExact(([regex]::Matches($Entry, '(\d{2}/\d{2}/\d{4} \d{2}:\d{2}:\d{2})')).Value, "MM/dd/yyyy HH:mm:ss", $null)
                'LineData' = $Entry
            }
            # Add to List
            $EntryObjects.Add($GRSInfoObject)
        }

        # Get the latest entry by DateTime
        $LatestEntry = $EntryObjects | Sort-Object DateTime | Select-Object -Last 1

        # Check if we found an entry
        if ($LatestEntry.Count -ne 0) {
            # Get RegistryKey and Ensure we are matching on the LatestEntry LineData 
            $formattedRegistryKey = (($LatestEntry.LineData.ToString() | Select-String -Pattern $grsAppIdPattern).Matches.Groups[2].Value) -replace '=.*', '='
            $registryKeyToDelete = "HKLM:\SOFTWARE\Microsoft\IntuneManagementExtension\Win32Apps\$formattedRegistryKey"

            # Build the Output Objects
            $GRSInformationTime = $null
            $GRSInformationTime = [PSCustomObject]@{
                'Last Install Attempt (UTC)'                = $LatestEntry.DateTime
                'Retry Window (UTC) - 24 to 30 hours later' = "After $($($LatestEntry.DateTime.AddHours(24)).ToString('MM/dd/yyyy HH:mm:ss')) OR $($($LatestEntry.DateTime.AddHours(30)).ToString('MM/dd/yyyy HH:mm:ss'))"
            }
            $GRSInformationKey = [PSCustomObject]@{
                'Registry Key to delete and restart IME service for fast install retry' = $registryKeyToDelete
            }
            
            # ... show the results in a table format...
            $GRSInformationTime | Format-Table -AutoSize
            $GRSInformationKey | Format-Table -AutoSize
        } else {
            throw "No results found in this log file for the specified win32AppID: $win32AppID"
        }
    }

    # If we're looking for ESP profile info....
    # ... check if the log file contains ESP profile information and throw an error if it doesn't...
    if ($getESPprofileInfo) {
        # ESP Pattern
        [string]$espLogPattern = '^\<\!\[LOG\[\[Win32App\]\[EspManager\] In EspPhase'

        # Search Log File(s) for the Pattern
        $PatternMatches = $null
        $PatternMatches = Select-String -Path "$($logFilePath)" -Pattern $espLogPattern

        # Build a List to find the latest entry
        [Collections.Generic.List[PSCustomObject]]$espAppEntries = @()
        foreach ($Entry in $PatternMatches) {
            # Esp App Info Pattern
            [string]$espAppInfoPattern = 'In EspPhase: ([^\.]+)\. App ([0-9a-zA-Z]{8}-[0-9a-zA-Z]{4}-[0-9a-zA-Z]{4}-[0-9a-zA-Z]{4}-[0-9a-zA-Z]{12})([^\.]+)([0-9a-zA-Z]{8}-[0-9a-zA-Z]{4}-[0-9a-zA-Z]{4}-[0-9a-zA-Z]{4}-[0-9a-zA-Z]{12})?\. App name: (.+?)\]LOG'
            # Esp App Info Match
            $espAppInfo = $($Entry.ToString() | Select-String -Pattern $espAppInfoPattern).Matches.Groups
            # Check for Account Setup
            if ($espAppInfo[3].Value -match 'user') {
                # User ID Pattern
                [string]$UserIDPattern = '[0-9a-zA-Z]{8}-[0-9a-zA-Z]{4}-[0-9a-zA-Z]{4}-[0-9a-zA-Z]{4}-[0-9a-zA-Z]{12}'
                # Grab the User ID
                $UserID = $($espAppInfo[3].Value | Select-String -Pattern $UserIDPattern).Matches.Value
            }
            else {
                $UserID = 'N/A'
            }
            # Build a PSCustomObject with the Info
            $espApp = [PSCustomObject]@{
                'EspPhase' = $espAppInfo[1].Value
                'User ID'  = $UserID
                'App ID'   = $espAppInfo[2].Value
                'App Name' = $espAppInfo[5].Value
            }
            # Add PSCustomObject to List
            $espAppEntries.Add($espApp)
        }
        # Check entries were found
        if ($espAppEntries.Count -eq 0) {
            Write-Host -ForegroundColor Yellow "[$(Get-Date -format G)] No ESP App Entries Found"
        }
        else {
            # Display the results
            $espAppEntries | Format-Table -AutoSize
        }
    }
} catch {
    Write-Host $($_.Exception.Message) -ForegroundColor Red
}