<#
.SYNOPSIS
    Get installed software from the local computer's registry and export to .csv
.DESCRIPTION
    Get installed software from the local computer's registry and export to .csv
.PARAMETER FilePath
    The desired path to the CSV to export. This defaults to $PSScriptRoot.
.PARAMETER FileName
    The file name of the .csv file itself. This defaults to "PMPC-Uninstall-Hive-Export.csv".
.PARAMETER ExcludeComputerNameInFileName
    By default, $env:CompuerName is always prefixed for the FileName parameter. Use this switch to override that behaviour.
.EXAMPLE
    .\Export-PMPCInstalledSoftware.ps1 -FilePath 'C:\temp' -FileName 'InstalledSoftware.csv' -ExcludeComputerNameInFileName

    Exports all of the values in the below registry keys to "C:\temp\LAPTOP1-InstalledSoftware.csv":
        - HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall
        - HKLM:\SOFTWARE\WOW6432NODE\Microsoft\Windows\CurrentVersion\Uninstall
        - HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall
        - HKCU:\SOFTWARE\WOW6432NODE\Microsoft\Windows\CurrentVersion\Uninstall
.NOTES
    ################# DISCLAIMER #################
    Patch My PC provides scripts, macro, and other code examples for illustration only, without warranty 
    either expressed or implied, including but not limited to the implied warranties of merchantability 
    and/or fitness for a particular purpose. This script is provided 'AS IS' and Patch My PC does not 
    guarantee that the following script, macro, or code can or should be used in any situation or that 
    operation of the code will be error-free.
#>
param(
    [Parameter()]
    [ValidateScript({
        if (-not (Test-Path -Path $_)) {
            throw "Path '$_' does not exist."
        }
        return $true
    })]
    [String]$FilePath = $PSScriptRoot,

    [Parameter()]
    [ValidatePattern('\.csv$')]
    [String]$FileName = 'PMPC-Uninstall-Hive-Export.csv',

    [Parameter()]
    [Switch]$ExcludeComputerNameInFileName
)

$PropertyNames = @(
    'DisplayName',
    'DisplayVersion',
    'Publisher', 
    'InstallDate', 
    'UninstallString', 
    'QuietUninstallString', 
    'SystemComponent',
    'WindowsInstaller',
    @{Label = 'RegistryKey'; Expression = { $_.PSChildName } },
    @{Label = 'RegistryKeyFull'; Expression = { $_.PSPath -replace 'Microsoft.PowerShell.Core\\Registry::' } }
)

$AllPathsToSearch = foreach ($Hive in 'HKEY_CURRENT_USER', 'HKEY_LOCAL_MACHINE') {
    foreach ($ArchitectureRoot in 'SOFTWARE', 'SOFTWARE\WOW6432Node') {
        [String]::Format('registry::{0}\{1}\Microsoft\Windows\CurrentVersion\Uninstall\*', $Hive, $ArchitectureRoot)
    }
}
    
try {
    $AllFoundObjects = Get-ItemProperty -Path $AllPathsToSearch -ErrorAction 'Stop' | 
        Where-Object { -not [String]::IsNullOrWhiteSpace($_.DisplayName) } | 
        Select-Object -Property $PropertyNames
}
catch {
    Write-Verbose "An error occurred while gathering the properties from the registry hives. Error: $($_.Exception.Message)" -Verbose
    throw
}

if ($ExcludeComputerNameInFileName.IsPresent) {
    $ExportCsvPath = '{0}\{1}' -f $FilePath, $FileName
}
else {
    $ExportCsvPath = '{0}\{1}-{2}' -f $FilePath, $env:ComputerName, $FileName
}

$AllFoundObjects | Export-Csv -Path $ExportCsvPath -Force -NoTypeInformation -ErrorAction 'Stop'

if (Test-Path $ExportCsvPath) {
    Write-Verbose ('Successfully created "{0}" on host "{1}", please share this .csv with Patch My PC support' -f $ExportCsvPath, $env:ComputerName) -Verbose
}

