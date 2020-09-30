function Import-PMPCUninstallRegistryHives {
    <#
        .SYNOPSIS
            Imports the uninstall hives to the local computer from a CSV
        .DESCRIPTION
            This function is used to import all the uninstall registry hives from a CSV file to assist
            with troubleshooting application detection
        .PARAMETER ImportCsvPath
            Specifies the desired path to the CSV toimport. This defaults to the current directory with
            a file name of 'PMPC-Uninstall-Hive-Export.csv'
        .EXAMPLE
            C:\PS>  Import-PMPCUninstallRegistryHives -ImportCsvPath 'C:\temp\PMPC-Export.csv'
                Exports all the uninstall hives to a CSV file named 'C:\temp\PMPC-Export.csv'
        .EXAMPLE
            C:\PS>  Import-PMPCUninstallRegistryHives
                Exports all the uninstall hives to a CSV file named 'PMPC-Uninstall-Hive-Export.csv' in the 
                directory where the function was ran
        .NOTES
            ################# DISCLAIMER #################
            Patch My PC provides scripts, macro, and other code examples for illustration only, without warranty 
            either expressed or implied, including but not limited to the implied warranties of merchantability 
            and/or fitness for a particular purpose. This script is provided 'AS IS' and Patch My PC does not 
            guarantee that the following script, macro, or code can or should be used in any situation or that 
            operation of the code will be error-free.
    #>
    param(
        [parameter(Mandatory = $false, Position = 0)]
        [ValidateScript( { [IO.Path]::GetExtension($_) -eq '.csv' })]
        [string]$ImportCsvPath = '.\PMPC-Uninstall-Hive-Export.csv'
    )
    $UninstallHiveImport = Import-Csv -Path $ImportCsvPath

    $PropertyNames = 'DisplayName', 'DisplayVersion', 'Publisher', 'InstallDate'
    foreach ($Record in $UninstallHiveImport) {
        $Null = New-Item -Path "registry::$($Record.RegistryPath)" -Force -ErrorAction SilentlyContinue
        foreach ($Property in $PropertyNames) {
            Set-ItemProperty -Path "registry::$($Record.RegistryPath)" -Name $Property -Value $Record.$Property -Force -ErrorAction SilentlyContinue -Verbose
        }
    }
}