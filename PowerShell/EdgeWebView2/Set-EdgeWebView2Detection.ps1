<#
.SYNOPSIS

Script to fix the installation of Microsoft Edge WebView2 Runtime.
Microsoft removed the DisplayName and UninstallString from the registry key for WebView2 Runtime in a recent version. 
This script will add or restore the DisplayName and UninstallString to the registry key if they are missing or incorrect.

.NOTES

Created on:   2024-11-21
Created by:   Ben Whitmore @PatchMyPC
Filename:     Set-EdgeWebView2Detection.ps1

---------------------------------------------------------------------------------
LEGAL DISCLAIMER

The PowerShell script provided is shared with the community as-is
The author and co-author(s) make no warranties or guarantees regarding its functionality, reliability, or suitability for any specific purpose
Please note that the script may need to be modified or adapted to fit your specific environment or requirements
It is recommended to thoroughly test the script in a non-production environment before using it in a live or critical system
The author and co-author(s) cannot be held responsible for any damages, losses, or adverse effects that may arise from the use of this script
You assume all risks and responsibilities associated with its usage
---------------------------------------------------------------------------------
#>
[CmdletBinding()]
param ()

# Define constants
$registryPath = "HKLM:\SOFTWARE\wow6432node\Microsoft\Windows\CurrentVersion\Uninstall"
$edgeWebViewInstallLocation = "C:\Program Files (x86)\Microsoft\EdgeWebView\Application"
$versionRegex = '\d+\.\d+\.\d+\.\d+'
$displayName = "Microsoft Edge WebView2 Runtime"
$uninstallStringTemplate = "Installer\setup.exe --uninstall --msedgewebview --system-level --verbose-logging"
$remediationResults = @()

# Initialize remediation status
$remediationSuccess = $true

try {

    # Retrieve all subkeys in the uninstall registry path
    Write-Verbose "Retrieving subkeys from registry path: $registryPath"
    $subkeys = Get-ChildItem -Path $registryPath -ErrorAction Stop
    Write-Verbose "Found $($subkeys.Count) subkeys in the registry path."

    # Loop through subkeys to find the matching app
    foreach ($subkey in $subkeys) {
        $regProperties = Get-ItemProperty -Path $subkey.PSPath -ErrorAction Stop

        # Check if the registry entry matches the install location
        if ($regProperties.InstallLocation -eq $edgeWebViewInstallLocation) {
            Write-Verbose "Matching install location found: $edgeWebViewInstallLocation"

            # Ensure UninstallString exists and has a value
            $installedVersion = Get-ChildItem -Path $edgeWebViewInstallLocation -Directory | Where-Object { $_.Name -match $versionRegex } | Select-Object -First 1

            if ($installedVersion) {
                Write-Verbose "Found installed version: $($installedVersion.Name)"
                $uninstallString = Join-Path -Path $edgeWebViewInstallLocation -ChildPath "$($installedVersion.Name)\$uninstallStringTemplate"
            }
            else {
                Write-Verbose "WARNING: No valid version folder found in: $edgeWebViewInstallLocation"
                $remediationResults += "No valid version folder found in: $edgeWebViewInstallLocation"
                $remediationSuccess = $false
            }

            # Ensure DisplayName exists and has a value
            if (-not $regProperties.PSObject.Properties["DisplayName"] -or [string]::IsNullOrWhiteSpace($regProperties.DisplayName)) {
                try {
                    Set-ItemProperty -Path $subkey.PSPath -Name "DisplayName" -Value $displayName
                    Write-Verbose "Added DisplayName to the registry key: $($subkey.PSPath)"
                }
                catch {
                    Write-Verbose "WARNING: Failed to add DisplayName to the registry key: $($subkey.PSPath)"
                    $remediationResults += "Failed to add DisplayName to the registry key: $($subkey.PSPath)"
                    $remediationSuccess = $false
                }
            }
            else {
                Write-Verbose "DisplayName already exists: $($regProperties.DisplayName)"
            }

            # Ensure UninstallString exists and has a value
            if (-not $regProperties.PSObject.Properties["UninstallString"] -or [string]::IsNullOrWhiteSpace($regProperties.UninstallString) -or $regProperties.UninstallString -ne $uninstallString) {
                try {
                    Set-ItemProperty -Path $subkey.PSPath -Name "UninstallString" -Value $uninstallString
                    Write-Verbose "Added or updated UninstallString to the registry key: $($subkey.PSPath) with version $($installedVersion.Name)"
                }
                catch {
                    Write-Verbose "WARNING: Failed to add or update UninstallString to the registry key: $($subkey.PSPath)"
                    $remediationResults += "Failed to add or update UninstallString to the registry key: $($subkey.PSPath)"
                    $remediationSuccess = $false
                }
            }
            else {
                Write-Verbose "UninstallString already exists and is correct: $($regProperties.UninstallString)"
            }
        }
            
    }
}
catch {
    $remediationResults += $_.Exception.Message
    $remediationSuccess = $false
}

# Output result and exit with the appropriate status code
if ($remediationSuccess) {
    Write-Output "Remediation completed successfully."
    exit 0
}
else {
    Write-Output "Remediation failed"
    Write-Output $remediationResults
    exit 1
}