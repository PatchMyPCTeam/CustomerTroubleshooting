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

        $myPolicyMatches = [regex]::Matches($content, $pattern)

        if ($myPolicyMatches.Count -eq 0) {
            throw "No win32 policy matches found in this log file"
        }
        
        # ... grab the most recent match...
        $mostRecentMatch = $myPolicyMatches | Sort-Object { $_.Index } -Descending | Select-Object -First 1
        $mostRecentPolicy = $mostRecentMatch.Value -replace '^<!\[LOG\[Get policies = ', '' -replace '\]\]$', ']'

        $myWin32AppsInPolicy = $mostRecentPolicy | ConvertFrom-Json -ErrorAction Stop
        $filteredApps = $myWin32AppsInPolicy | Where-Object { $_.Name -like "*$appNameToSearchFor*" }

        if (-not $filteredApps) {
            throw "No results found for the specified app name: $appNameToSearchFor"
        }
        
        # ... show the filtered apps in a table format...
        $filteredApps | Select-Object `
            @{Name='Win32 app ID'; Expression={$_.ID}}, `
            @{Name='Win32 app Name'; Expression={$_.Name}}, `
            @{Name='Revision'; Expression={$_.Version}}, `
            @{Name='Intent'; Expression={if ($_.Intent -eq '0') { 'NotTargeted' } elseif ($_.Intent -eq '1') { 'Available' } elseif ($_.Intent -eq '3')  { 'Required' } elseif ($_.Intent -eq '4') { 'Uninstall'} else { 'unknown' }}}, `
            @{Name='TimeFormat'; Expression={$_.StartDeadlineEx.TimeFormat}}, `
            @{Name='StartTime'; Expression={if ($_.StartDeadlineEx.StartTime -eq '1/1/0001 12:00:00 AM') { 'ASAP' } else { $_.StartDeadlineEx.StartTime }}}, `
            @{Name='Deadline'; Expression={if ($_.StartDeadlineEx.Deadline -eq '1/1/0001 12:00:00 AM') { 'ASAP' } else { $_.StartDeadlineEx.Deadline }}}, `
            @{Name='InstallContext'; Expression={if ($_.InstallContext -eq '0') { 'User' } else { 'System' }}} | 
            Sort-Object 'Win32 app Name' | 
            Format-Table -AutoSize
    }

    # If we're looking for GRS info....
    if ($getWin32AppGRSinfo) {
        # ... validate Win32AppID - throw an error if the Win32AppID is not in the expected format...
        if (-not (Test-GUID $win32AppID)) {
            throw "The win32AppID is not in the correct format."
        }

        [string]$grsPattern = '<!\[LOG\[\[Win32App\]\[GRSManager\].*'
        $myGRSMatches = [regex]::Matches($content, $grsPattern)

        $sanitizedEntries = @()

        # ... sanitize the entries to remove the prefix and filter by win32AppID...
        foreach ($match in $myGRSMatches) {
            $entry = $match -replace '^\<\!\[LOG\[\[Win32App\]\[GRSManager\] ', ''
            If ($entry -like "*$win32AppID*") {
                $sanitizedEntries += $entry
            }
        }
        #Write-Host $sanitizedEntries -ForegroundColor Green

        if ($sanitizedEntries.Count -eq 0) {
            throw "No results found in this log file for the specified win32AppID: $win32AppID"
        }
        
        $results = @()
        $forWin32AppFastRetryDeleteThis = @()

        # ... loop through the sanitized entries and extract the relevant information...
        # Find the latest entry based on the date and time
        $latestEntry = $sanitizedEntries |
        Where-Object { $_ -match "Found GRS value: (\d{2}/\d{2}/\d{4} \d{2}:\d{2}:\d{2}) at key (.+)" } |
        Sort-Object { [datetime]::ParseExact($matches[1], "MM/dd/yyyy HH:mm:ss", $null) } -Descending |
        Select-Object -First 1

        if ($latestEntry -match "Found GRS value: (\d{2}/\d{2}/\d{4} \d{2}:\d{2}:\d{2}) at key (.+)") {
        $lastInstallAttempt = [datetime]::ParseExact($matches[1], "MM/dd/yyyy HH:mm:ss", $null)
        $rawRegistryKey = $matches[2]
        $formattedRegistryKey = $rawRegistryKey -replace "=.*", "="
        $registryKeyToDelete = "HKLM:\SOFTWARE\Microsoft\IntuneManagementExtension\Win32Apps\$formattedRegistryKey"

        $retryStart = $lastInstallAttempt.AddHours(24)
        $retryEnd = $lastInstallAttempt.AddHours(30)

        $results += [PSCustomObject]@{
            'Last Install Attempt (UTC)' = $lastInstallAttempt
            'Retry Window (UTC) - 24 to 30 hours later' = "After $($retryStart.ToString('MM/dd/yyyy HH:mm:ss')) OR $($retryEnd.ToString('MM/dd/yyyy HH:mm:ss'))"
        }

        $forWin32AppFastRetryDeleteThis += [PSCustomObject]@{
            'Registry Key to delete and restart IME service for fast install retry' = $registryKeyToDelete
        }
        }

        # ... show the results in a table format...
        $results | Format-Table -AutoSize
        $forWin32AppFastRetryDeleteThis | Format-Table -AutoSize
    }

    # If we're looking for ESP profile info....
    # ... check if the log file contains ESP profile information and throw an error if it doesn't...
    if ($getESPprofileInfo) {
        [string]$espLogPattern = '<!\[LOG\[\[Win32App\]\[EspManager\].*'
        $espPolicyMatches = [regex]::Matches($content, $espLogPattern)
    
        if ($espPolicyMatches.Count -eq 0) {
            throw "No win32 policy matches found in this log file"
        }
    
        $espSanitizedEntries = @()
        foreach ($match in $espPolicyMatches) {
            # If statement is needed, otherwise it will capture other, irellevent entries that are similar in format
            if ($match.Value -match '^\<\!\[LOG\[\[Win32App\]\[EspManager\] In EspPhase') {
                # Sanitize the entry and add it to the array
                $entry = $match.Value -replace '^\<\!\[LOG\[\[Win32App\]\[EspManager\]', ''
                $espSanitizedEntries += $entry
            }
        }
    
        $espResults = @()
        #Write-Host $espSanitizedEntries -ForegroundColor Green
    
        foreach ($entry in $espSanitizedEntries) {
            # Get the EspPhase
            if ($entry -match "In EspPhase: ([^\.]+)\.") {
                $espPhase = $matches[1]
            }
    
            # Get the ID
            if ($entry -match "\. App ([^ ]+) has been registered for user") {
                $id = $matches[1]
            }
    
            # Get the app name(s) from the log line matching the regex
            if ($entry -match "\. App name: (.+?)\]LOG") {
                $softwareName = $matches[1]
            }
    
            # Add the found details to the results array
            $espResults += [PSCustomObject]@{
                'EspPhase'      = $espPhase
                'ID'            = $id
                'Software Name' = $softwareName
            }
        }

        #Write-Host $espResults -ForegroundColor Green

        $espResults | Format-Table -AutoSize
    }
} catch {
    Write-Host $($_.Exception.Message) -ForegroundColor Red
}