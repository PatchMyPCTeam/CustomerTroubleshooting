<#
.SYNOPSIS
    Get installed software from the local computer's registry and export to .csv
.DESCRIPTION
    Get installed software from the local computer's registry and export to .csv.
    Run with admin rights if trying to determine which user installed a per-user MSI and it was not the current user.
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
        - HKU:\*\
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
    [String]$FilePath,

    [Parameter()]
    [ValidatePattern('\.csv$')]
    [String]$FileName = 'PMPC-Uninstall-Hive-Export.csv',

    [Parameter()]
    [Switch]$ExcludeComputerNameInFileName
)

function Get-MsiInstallationContext {
    param(
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [ValidateScript({
                if (-not ($_ -match '^\{?[A-F0-9]{8}-(?:[A-F0-9]{4}-){3}[A-F0-9]{12}\}?$')) {
                    throw "Invalid ProductCode format. Please provide a valid GUID."
                }
                return $true
            })]
        [String]$ProductCode
    )

    $CompressedGuid = -join (($ProductCode | Select-String -Pattern '^\{?(.{8})-(.{4})-(.{4})-(.{2})(.{2})-(.{2})(.{2})(.{2})(.{2})(.{2})(.{2})\}?$' -AllMatches).Matches.Groups[1..11].Value | ForEach-Object { $CharArray = $_.ToCharArray(); [System.Array]::Reverse($CharArray); -join $CharArray })

    [Boolean]$AllUsers = Test-Path -Path "HKLM:\SOFTWARE\Classes\Installer\Products\$CompressedGuid"
    [Boolean]$CurrentUser = Test-Path -Path "HKCU:\SOFTWARE\Microsoft\Installer\Products\$CompressedGuid"

    $SIDs = Get-ChildItem -Path 'Registry::HKEY_USERS\' -ErrorAction Ignore | Where-Object PSChildName -match '^S.+\d$' | Select-Object -ExpandProperty PSChildName
    $Users = foreach ($SID in $SIDs) {
        if (Test-Path -Path "Registry::HKEY_USERS\$SID\SOFTWARE\Microsoft\Installer\Products\$CompressedGuid") {
            try {
                (New-Object System.Security.Principal.SecurityIdentifier($SID)).Translate([System.Security.Principal.NTAccount]).Value
            }
            catch {
                $SID
            }
        }
    }

    [PSCustomObject]@{
        AllUsers    = $AllUsers
        CurrentUser = $CurrentUser
        Users = $Users
    }
}

function Import-RegistryHive {
    param (
        [Parameter(Mandatory)]
        [String]$File,

        [Parameter(Mandatory)]
        [String]$Name
    )

    $TestDrive = Get-PSDrive -Name $Name -ErrorAction 'SilentlyContinue'

    if ($null -ne $TestDrive) {
        return $TestDrive
    }

    $Key = 'HKU\{0}' -f $Name

    $Process = Start-Process -FilePath "$env:WINDIR\system32\reg.exe" -ArgumentList "load $Key $File" -WindowStyle 'Hidden' -PassThru -Wait

    if ($Process.ExitCode) {
        Write-Host ('Could not load the registry hive "{0}", exit code: {1}' -f $File, $Process.ExitCode) -ForegroundColor 'Red'
        return
    }

    try {
        New-PSDrive -Name $Name -PSProvider 'Registry' -Root $Key -Scope 'Script' -ErrorAction 'Stop'
    }
    catch {
        Write-Host ('Could not create the PSDrive "{0}", error: {1}' -f $Name, $_.Exception.Message) -ForegroundColor 'Red'
    }
}

function Remove-RegistryHive {
    param (
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [Alias('SID')]
        [String[]]$Name
    )
    process {
        foreach ($item in $Name) {
            $Drive = Get-PSDrive -Name $item -ErrorAction 'SilentlyContinue'
            if ($null -eq $Drive) { continue }

            try {
                Remove-PSDrive $Drive.Name -ErrorAction 'Stop'
            }
            catch {
                Write-Host ('Could not remove the PSDrive "{0}", error: {1}' -f $Drive.Name, $_.Exception.Message) -ForegroundColor 'Red'
                Write-Host 'Trying to unload registry hive anyway...' -ForegroundColor 'Red'
            }

            # Without this, releasing the registry key occasionally doesn't happen in time before calling reg.exe unload
            [System.GC]::Collect()

            # Don't unload the SYSTEM hive
            if ($item -eq 'S-1-5-18') { continue }

            $Key = $Drive.Root
            $Process = Start-Process -FilePath "$env:WINDIR\system32\reg.exe" -ArgumentList "unload $Key" -WindowStyle 'Hidden' -PassThru -Wait
    
            if ($Process.ExitCode) {
                Write-Host ('Could not unload the registry hive "{0}", exit code: {1}' -f $Key, $Process.ExitCode) -ForegroundColor 'Red'
            }
        }
    }
}

function New-PSSystemRegistryHiveDrive {
    $TestDrive = Get-PSDrive -Name 'S-1-5-18' -ErrorAction 'SilentlyContinue'

    if ($null -ne $TestDrive) {
        return $TestDrive
    }

    New-PSDrive -Name 'S-1-5-18' -PSProvider 'Registry' -Root 'HKU\S-1-5-18' -Scope 'Script' -ErrorAction 'Stop'
}

function Test-Administrator {
    $user = [Security.Principal.WindowsIdentity]::GetCurrent()
    $IsAdministrator = [Security.Principal.WindowsPrincipal]::new($user).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)

    $Username = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    
    $IsAdministrator -or $Username -eq 'NT AUTHORITY\SYSTEM'
}

# Match AD, AAD, and system profile SID formats
$PatternSID = '^S-1-(5-21|12)(-[^\s_]+)*$'

$PropertyNames = @(
    'DisplayName',
    'DisplayVersion',
    'Publisher', 
    'InstallDate', 
    'UninstallString', 
    'QuietUninstallString', 
    'SystemComponent',
    'WindowsInstaller',
    @{Label = 'Username';         Expression = { 
            switch -Regex ($_.PSDrive) {
                'HKLM'      { 'LocalMachine' }
                'HKCU'      { '{0}\{1}' -f $env:userdomain, $env:username }
                'S-1-5-18'  { 'NT AUTHORITY\SYSTEM' }
                $PatternSID {
                    try {
                        [System.Security.Principal.SecurityIdentifier]$SID = $_.Name
                        $SID.Translate([System.Security.Principal.NTAccount]).Value
                    }
                    catch {
                        $_.Name
                    }
                }
            }
        } 
    }
    @{Label = 'MSIAllUsers';     Expression = { if ($_.WindowsInstaller) { (Get-MsiInstallationContext ($_.PSChildName) -ErrorAction Ignore).AllUsers } } },
    @{Label = 'MSICurrentUser';  Expression = { if ($_.WindowsInstaller) { (Get-MsiInstallationContext ($_.PSChildName) -ErrorAction Ignore).CurrentUser } } },
    @{Label = 'MSIUsers';        Expression = { if ($_.WindowsInstaller) { (Get-MsiInstallationContext ($_.PSChildName) -ErrorAction Ignore).Users -join ', ' } } },
    @{Label = 'RegistryKey';     Expression = { $_.PSChildName } },
    @{Label = 'RegistryKeyFull'; Expression = { $_.PSPath -replace 'Microsoft.PowerShell.Core\\Registry::' -replace 'HKEY_LOCAL_MACHINE', 'HKLM' -replace 'HKEY_CURRENT_USER', 'HKCU' } }
)

[array]$Hives = 'HKLM'

if (Test-Administrator) {
    $Hives += New-PSSystemRegistryHiveDrive | Select-Object -ExpandProperty 'Name'

    $ProfileList = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\*' | 
                        Where-Object { $_.PSChildName -match $PatternSID } | 
                        Select-Object @(
                            @{ Label = 'SID';      Expression = { $_.PSChildName } }, 
                            @{ Label = 'Hive';     Expression = { $Path = '{0}\ntuser.dat' -f $_.ProfileImagePath; if (Test-Path -Path $Path) { $Path } } },
                            @{ Label = 'isLoaded'; Expression = { Test-Path -Path "Registry::HKU\$($_.PSChildName)" } }
                        )
    
    $Hives += foreach ($_Profile in $ProfileList) {
        if (-not $_Profile.isLoaded) {
            Import-RegistryHive -File $_Profile.Hive -Name $_Profile.SID | Select-Object -ExpandProperty 'Name'
        }
        else {
            try {
                New-PSDrive -Name $_Profile.SID -PSProvider 'Registry' -Root "HKU\$($_Profile.SID)" -Scope 'Script' -ErrorAction 'Stop' |
                    Select-Object -ExpandProperty 'Name'
            }
            catch {
                Write-Host ('Could not create the PSDrive for currently logged in user "{0}", error: {1}' -f $_Profile.SID, $_.Exception.Message) -ForegroundColor 'Red'
            }
        }
    }
}
else {
    Write-Host 'The script is not running as an administrator, only querying HKLM and HKCU' -ForegroundColor 'Cyan'
    Write-Host 'To query all user profiles, please run the script as an administrator' -ForegroundColor 'Cyan'

    # Don't query HKCU if the script is running as SYSTEM or the logged in user is an admin, to avoid dupes in output
    $Hives += 'HKCU'
}

$AllPathsToSearch = foreach ($Hive in $Hives) {
    foreach ($ArchitectureRoot in 'SOFTWARE', 'SOFTWARE\WOW6432Node') {
        '{0}:\{1}\Microsoft\Windows\CurrentVersion\Uninstall\*' -f $Hive, $ArchitectureRoot
    }
}

$AllFoundObjects = foreach ($Path in $AllPathsToSearch) {
    try {
        if (Test-Path $Path) {
            Get-ItemProperty -Path $Path -ErrorAction 'Stop' | 
                Where-Object { -not [String]::IsNullOrWhiteSpace($_.DisplayName) } | 
                Select-Object -Property $PropertyNames
        }
    }
    catch {
        Write-Verbose "An error occurred while querying $Path" -Verbose
        Write-Error $_
    }
}

if (-not $PSBoundParameters.ContainsKey('FilePath')) {
	$FilePath = $PSScriptRoot
}

if ($ExcludeComputerNameInFileName.IsPresent) {
    $ExportCsvPath = '{0}\{1}' -f $FilePath, $FileName
}
else {
    $ExportCsvPath = '{0}\{1}-{2}' -f $FilePath, $env:ComputerName, $FileName
}

$ProfileList.Where{ -not $_.isLoaded } | Remove-RegistryHive

$AllFoundObjects | 
    Sort-Object -Property 'DisplayName' | Export-Csv -Path $ExportCsvPath -Force -NoTypeInformation -ErrorAction 'Stop'

if (Test-Path $ExportCsvPath) {
    Write-Host ('Successfully created "{0}" on host "{1}", please share this .csv with Patch My PC support' -f $ExportCsvPath, $env:ComputerName) -ForegroundColor 'Green'
}
