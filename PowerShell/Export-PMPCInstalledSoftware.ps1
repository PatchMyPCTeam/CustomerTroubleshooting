<#
    .SYNOPSIS
        Get installed software from the local computer's registry and export to .csv
    .DESCRIPTION
        Get installed software from the local computer's registry and export to .csv
    .PARAMETER ExportCsvPath
        Specifies the desired path to the CSV to export. This defaults to the current directory with a file name of 'PMPC-Uninstall-Hive-Export.csv'
    .EXAMPLE
        Export-PMPCUninstallRegistryHives -ExportCsvPath 'C:\temp\PMPC-Export.csv'

        Exports all the uninstall hives to a CSV file named 'C:\temp\PMPC-Export.csv'
    .EXAMPLE
        Export-PMPCUninstallRegistryHives

        Exports all the uninstall hives to a CSV file named 'PMPC-Uninstall-Hive-Export.csv' in the directory where the function was ran
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
    [ValidatePattern('\.csv$')]
    [String]$ExportCsvPath = '.\PMPC-Uninstall-Hive-Export.csv'
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
    $AllFoundObjects = Get-ItemProperty -Path $AllPathsToSearch -Name $PropertyNames -ErrorAction 'Stop' | 
        Where-Object { -not [String]::IsNullOrWhiteSpace($_.DisplayName) } | 
        Select-Object -Property $PropertyNames
}
catch {
    Write-Verbose "An error occurred while gathering the properties from the registry hives. Error: $($_.Exception.Message)" -Verbose
    throw
}
    
$AllFoundObjects | Export-Csv -Path $ExportCsvPath -Force -NoTypeInformation -ErrorAction 'Stop'
