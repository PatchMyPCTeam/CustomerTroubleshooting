<#
.SYNOPSIS

Script to detect and validate the installation of Microsoft Edge WebView2 Runtime.
Checks registry entries and installation folder to ensure the WebView2 Runtime is properly installed and functional.
Outputs "Remediation Required" or "Remediation Not Required" based on validation results.

.NOTES

Created on:   2024-11-21
Created by:   Ben Whitmore @PatchMyPC
Filename:     Get-EdgeWebView2Detection.ps1

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
$binaryName = "msedgewebview2.exe"
$remediationRequired = $false

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

            # Validate the version folder and binary existence
            Write-Verbose "Checking for version folder in: $edgeWebViewInstallLocation"
            $installedVersion = Get-ChildItem -Path $edgeWebViewInstallLocation -Directory | Where-Object { $_.Name -match $versionRegex } | Select-Object -First 1

            if ($installedVersion) {
                Write-Verbose "Version folder found: $($installedVersion.Name)"
                $binaryPath = Join-Path -Path $edgeWebViewInstallLocation -ChildPath "$($installedVersion.Name)\$binaryName"

                if (-not (Test-Path -Path $binaryPath)) {
                    Write-Verbose "'$binaryName' is missing in folder: $($binaryPath)"
                    $remediationRequired = $true
                }
                else {
                    Write-Verbose "'$binaryName' exists in folder: $($binaryPath)"
                }
            }
            else {
                Write-Verbose "No valid version folder found in: $edgeWebViewInstallLocation"
                $remediationRequired = $true
            }

            # Ensure DisplayName exists and has a value
            if (-not $regProperties.PSObject.Properties["DisplayName"] -or [string]::IsNullOrWhiteSpace($regProperties.DisplayName)) {
                Write-Verbose "DisplayName is missing or empty."
                $remediationRequired = $true
            }
            else {
                Write-Verbose "DisplayName exists: $($regProperties.DisplayName)"
            }

            # Ensure UninstallString exists and has a value
            if (-not $regProperties.PSObject.Properties["UninstallString"] -or [string]::IsNullOrWhiteSpace($regProperties.UninstallString)) {
                Write-Verbose "UninstallString is missing or empty."
                $remediationRequired = $true
            }
            else {
                Write-Verbose "UninstallString exists: $($regProperties.UninstallString)"
            }
        }
    }

    # Output remediation status
    if ($remediationRequired) {
        Write-Output "Remediation Required"
        exit 1
    }
    else {
        Write-Output "Remediation Not Required"
        exit 0
    }
}
catch {
    $_.Exception.Message
}