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

$ProfileList | Where-Object { -not $_.isLoaded } | Remove-RegistryHive

$AllFoundObjects | 
    Sort-Object -Property 'DisplayName' | Export-Csv -Path $ExportCsvPath -Force -NoTypeInformation -ErrorAction 'Stop'

if (Test-Path $ExportCsvPath) {
    Write-Host ('Successfully created "{0}" on host "{1}", please share this .csv with Patch My PC support' -f $ExportCsvPath, $env:ComputerName) -ForegroundColor 'Green'
}

# SIG # Begin signature block
# MIIovgYJKoZIhvcNAQcCoIIorzCCKKsCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCC9pXvptJYjwEFa
# 9m5WGY2LW89RAx08ozV0BQQI08UAQqCCIbswggWNMIIEdaADAgECAhAOmxiO+dAt
# 5+/bUOIIQBhaMA0GCSqGSIb3DQEBDAUAMGUxCzAJBgNVBAYTAlVTMRUwEwYDVQQK
# EwxEaWdpQ2VydCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xJDAiBgNV
# BAMTG0RpZ2lDZXJ0IEFzc3VyZWQgSUQgUm9vdCBDQTAeFw0yMjA4MDEwMDAwMDBa
# Fw0zMTExMDkyMzU5NTlaMGIxCzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdpQ2Vy
# dCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xITAfBgNVBAMTGERpZ2lD
# ZXJ0IFRydXN0ZWQgUm9vdCBHNDCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoC
# ggIBAL/mkHNo3rvkXUo8MCIwaTPswqclLskhPfKK2FnC4SmnPVirdprNrnsbhA3E
# MB/zG6Q4FutWxpdtHauyefLKEdLkX9YFPFIPUh/GnhWlfr6fqVcWWVVyr2iTcMKy
# unWZanMylNEQRBAu34LzB4TmdDttceItDBvuINXJIB1jKS3O7F5OyJP4IWGbNOsF
# xl7sWxq868nPzaw0QF+xembud8hIqGZXV59UWI4MK7dPpzDZVu7Ke13jrclPXuU1
# 5zHL2pNe3I6PgNq2kZhAkHnDeMe2scS1ahg4AxCN2NQ3pC4FfYj1gj4QkXCrVYJB
# MtfbBHMqbpEBfCFM1LyuGwN1XXhm2ToxRJozQL8I11pJpMLmqaBn3aQnvKFPObUR
# WBf3JFxGj2T3wWmIdph2PVldQnaHiZdpekjw4KISG2aadMreSx7nDmOu5tTvkpI6
# nj3cAORFJYm2mkQZK37AlLTSYW3rM9nF30sEAMx9HJXDj/chsrIRt7t/8tWMcCxB
# YKqxYxhElRp2Yn72gLD76GSmM9GJB+G9t+ZDpBi4pncB4Q+UDCEdslQpJYls5Q5S
# UUd0viastkF13nqsX40/ybzTQRESW+UQUOsxxcpyFiIJ33xMdT9j7CFfxCBRa2+x
# q4aLT8LWRV+dIPyhHsXAj6KxfgommfXkaS+YHS312amyHeUbAgMBAAGjggE6MIIB
# NjAPBgNVHRMBAf8EBTADAQH/MB0GA1UdDgQWBBTs1+OC0nFdZEzfLmc/57qYrhwP
# TzAfBgNVHSMEGDAWgBRF66Kv9JLLgjEtUYunpyGd823IDzAOBgNVHQ8BAf8EBAMC
# AYYweQYIKwYBBQUHAQEEbTBrMCQGCCsGAQUFBzABhhhodHRwOi8vb2NzcC5kaWdp
# Y2VydC5jb20wQwYIKwYBBQUHMAKGN2h0dHA6Ly9jYWNlcnRzLmRpZ2ljZXJ0LmNv
# bS9EaWdpQ2VydEFzc3VyZWRJRFJvb3RDQS5jcnQwRQYDVR0fBD4wPDA6oDigNoY0
# aHR0cDovL2NybDMuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0QXNzdXJlZElEUm9vdENB
# LmNybDARBgNVHSAECjAIMAYGBFUdIAAwDQYJKoZIhvcNAQEMBQADggEBAHCgv0Nc
# Vec4X6CjdBs9thbX979XB72arKGHLOyFXqkauyL4hxppVCLtpIh3bb0aFPQTSnov
# Lbc47/T/gLn4offyct4kvFIDyE7QKt76LVbP+fT3rDB6mouyXtTP0UNEm0Mh65Zy
# oUi0mcudT6cGAxN3J0TU53/oWajwvy8LpunyNDzs9wPHh6jSTEAZNUZqaVSwuKFW
# juyk1T3osdz9HNj0d1pcVIxv76FQPfx2CWiEn2/K2yCNNWAcAgPLILCsWKAOQGPF
# mCLBsln1VWvPJ6tsds5vIy30fnFqI2si/xK4VC0nftg62fC2h5b9W9FcrBjDTZ9z
# twGpn1eqXijiuZQwggawMIIEmKADAgECAhAIrUCyYNKcTJ9ezam9k67ZMA0GCSqG
# SIb3DQEBDAUAMGIxCzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdpQ2VydCBJbmMx
# GTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xITAfBgNVBAMTGERpZ2lDZXJ0IFRy
# dXN0ZWQgUm9vdCBHNDAeFw0yMTA0MjkwMDAwMDBaFw0zNjA0MjgyMzU5NTlaMGkx
# CzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4
# RGlnaUNlcnQgVHJ1c3RlZCBHNCBDb2RlIFNpZ25pbmcgUlNBNDA5NiBTSEEzODQg
# MjAyMSBDQTEwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQDVtC9C0Cit
# eLdd1TlZG7GIQvUzjOs9gZdwxbvEhSYwn6SOaNhc9es0JAfhS0/TeEP0F9ce2vnS
# 1WcaUk8OoVf8iJnBkcyBAz5NcCRks43iCH00fUyAVxJrQ5qZ8sU7H/Lvy0daE6ZM
# swEgJfMQ04uy+wjwiuCdCcBlp/qYgEk1hz1RGeiQIXhFLqGfLOEYwhrMxe6TSXBC
# Mo/7xuoc82VokaJNTIIRSFJo3hC9FFdd6BgTZcV/sk+FLEikVoQ11vkunKoAFdE3
# /hoGlMJ8yOobMubKwvSnowMOdKWvObarYBLj6Na59zHh3K3kGKDYwSNHR7OhD26j
# q22YBoMbt2pnLdK9RBqSEIGPsDsJ18ebMlrC/2pgVItJwZPt4bRc4G/rJvmM1bL5
# OBDm6s6R9b7T+2+TYTRcvJNFKIM2KmYoX7BzzosmJQayg9Rc9hUZTO1i4F4z8ujo
# 7AqnsAMrkbI2eb73rQgedaZlzLvjSFDzd5Ea/ttQokbIYViY9XwCFjyDKK05huzU
# tw1T0PhH5nUwjewwk3YUpltLXXRhTT8SkXbev1jLchApQfDVxW0mdmgRQRNYmtwm
# KwH0iU1Z23jPgUo+QEdfyYFQc4UQIyFZYIpkVMHMIRroOBl8ZhzNeDhFMJlP/2NP
# TLuqDQhTQXxYPUez+rbsjDIJAsxsPAxWEQIDAQABo4IBWTCCAVUwEgYDVR0TAQH/
# BAgwBgEB/wIBADAdBgNVHQ4EFgQUaDfg67Y7+F8Rhvv+YXsIiGX0TkIwHwYDVR0j
# BBgwFoAU7NfjgtJxXWRM3y5nP+e6mK4cD08wDgYDVR0PAQH/BAQDAgGGMBMGA1Ud
# JQQMMAoGCCsGAQUFBwMDMHcGCCsGAQUFBwEBBGswaTAkBggrBgEFBQcwAYYYaHR0
# cDovL29jc3AuZGlnaWNlcnQuY29tMEEGCCsGAQUFBzAChjVodHRwOi8vY2FjZXJ0
# cy5kaWdpY2VydC5jb20vRGlnaUNlcnRUcnVzdGVkUm9vdEc0LmNydDBDBgNVHR8E
# PDA6MDigNqA0hjJodHRwOi8vY3JsMy5kaWdpY2VydC5jb20vRGlnaUNlcnRUcnVz
# dGVkUm9vdEc0LmNybDAcBgNVHSAEFTATMAcGBWeBDAEDMAgGBmeBDAEEATANBgkq
# hkiG9w0BAQwFAAOCAgEAOiNEPY0Idu6PvDqZ01bgAhql+Eg08yy25nRm95RysQDK
# r2wwJxMSnpBEn0v9nqN8JtU3vDpdSG2V1T9J9Ce7FoFFUP2cvbaF4HZ+N3HLIvda
# qpDP9ZNq4+sg0dVQeYiaiorBtr2hSBh+3NiAGhEZGM1hmYFW9snjdufE5BtfQ/g+
# lP92OT2e1JnPSt0o618moZVYSNUa/tcnP/2Q0XaG3RywYFzzDaju4ImhvTnhOE7a
# brs2nfvlIVNaw8rpavGiPttDuDPITzgUkpn13c5UbdldAhQfQDN8A+KVssIhdXNS
# y0bYxDQcoqVLjc1vdjcshT8azibpGL6QB7BDf5WIIIJw8MzK7/0pNVwfiThV9zeK
# iwmhywvpMRr/LhlcOXHhvpynCgbWJme3kuZOX956rEnPLqR0kq3bPKSchh/jwVYb
# KyP/j7XqiHtwa+aguv06P0WmxOgWkVKLQcBIhEuWTatEQOON8BUozu3xGFYHKi8Q
# xAwIZDwzj64ojDzLj4gLDb879M4ee47vtevLt/B3E+bnKD+sEq6lLyJsQfmCXBVm
# zGwOysWGw/YmMwwHS6DTBwJqakAwSEs0qFEgu60bhQjiWQ1tygVQK+pKHJ6l/aCn
# HwZ05/LWUpD9r4VIIflXO7ScA+2GRfS0YW6/aOImYIbqyK+p/pQd52MbOoZWeE4w
# gga0MIIEnKADAgECAhANx6xXBf8hmS5AQyIMOkmGMA0GCSqGSIb3DQEBCwUAMGIx
# CzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdpQ2VydCBJbmMxGTAXBgNVBAsTEHd3
# dy5kaWdpY2VydC5jb20xITAfBgNVBAMTGERpZ2lDZXJ0IFRydXN0ZWQgUm9vdCBH
# NDAeFw0yNTA1MDcwMDAwMDBaFw0zODAxMTQyMzU5NTlaMGkxCzAJBgNVBAYTAlVT
# MRcwFQYDVQQKEw5EaWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1
# c3RlZCBHNCBUaW1lU3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTEwggIi
# MA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQC0eDHTCphBcr48RsAcrHXbo0Zo
# dLRRF51NrY0NlLWZloMsVO1DahGPNRcybEKq+RuwOnPhof6pvF4uGjwjqNjfEvUi
# 6wuim5bap+0lgloM2zX4kftn5B1IpYzTqpyFQ/4Bt0mAxAHeHYNnQxqXmRinvuNg
# xVBdJkf77S2uPoCj7GH8BLuxBG5AvftBdsOECS1UkxBvMgEdgkFiDNYiOTx4OtiF
# cMSkqTtF2hfQz3zQSku2Ws3IfDReb6e3mmdglTcaarps0wjUjsZvkgFkriK9tUKJ
# m/s80FiocSk1VYLZlDwFt+cVFBURJg6zMUjZa/zbCclF83bRVFLeGkuAhHiGPMvS
# GmhgaTzVyhYn4p0+8y9oHRaQT/aofEnS5xLrfxnGpTXiUOeSLsJygoLPp66bkDX1
# ZlAeSpQl92QOMeRxykvq6gbylsXQskBBBnGy3tW/AMOMCZIVNSaz7BX8VtYGqLt9
# MmeOreGPRdtBx3yGOP+rx3rKWDEJlIqLXvJWnY0v5ydPpOjL6s36czwzsucuoKs7
# Yk/ehb//Wx+5kMqIMRvUBDx6z1ev+7psNOdgJMoiwOrUG2ZdSoQbU2rMkpLiQ6bG
# RinZbI4OLu9BMIFm1UUl9VnePs6BaaeEWvjJSjNm2qA+sdFUeEY0qVjPKOWug/G6
# X5uAiynM7Bu2ayBjUwIDAQABo4IBXTCCAVkwEgYDVR0TAQH/BAgwBgEB/wIBADAd
# BgNVHQ4EFgQU729TSunkBnx6yuKQVvYv1Ensy04wHwYDVR0jBBgwFoAU7NfjgtJx
# XWRM3y5nP+e6mK4cD08wDgYDVR0PAQH/BAQDAgGGMBMGA1UdJQQMMAoGCCsGAQUF
# BwMIMHcGCCsGAQUFBwEBBGswaTAkBggrBgEFBQcwAYYYaHR0cDovL29jc3AuZGln
# aWNlcnQuY29tMEEGCCsGAQUFBzAChjVodHRwOi8vY2FjZXJ0cy5kaWdpY2VydC5j
# b20vRGlnaUNlcnRUcnVzdGVkUm9vdEc0LmNydDBDBgNVHR8EPDA6MDigNqA0hjJo
# dHRwOi8vY3JsMy5kaWdpY2VydC5jb20vRGlnaUNlcnRUcnVzdGVkUm9vdEc0LmNy
# bDAgBgNVHSAEGTAXMAgGBmeBDAEEAjALBglghkgBhv1sBwEwDQYJKoZIhvcNAQEL
# BQADggIBABfO+xaAHP4HPRF2cTC9vgvItTSmf83Qh8WIGjB/T8ObXAZz8OjuhUxj
# aaFdleMM0lBryPTQM2qEJPe36zwbSI/mS83afsl3YTj+IQhQE7jU/kXjjytJgnn0
# hvrV6hqWGd3rLAUt6vJy9lMDPjTLxLgXf9r5nWMQwr8Myb9rEVKChHyfpzee5kH0
# F8HABBgr0UdqirZ7bowe9Vj2AIMD8liyrukZ2iA/wdG2th9y1IsA0QF8dTXqvcnT
# mpfeQh35k5zOCPmSNq1UH410ANVko43+Cdmu4y81hjajV/gxdEkMx1NKU4uHQcKf
# ZxAvBAKqMVuqte69M9J6A47OvgRaPs+2ykgcGV00TYr2Lr3ty9qIijanrUR3anzE
# wlvzZiiyfTPjLbnFRsjsYg39OlV8cipDoq7+qNNjqFzeGxcytL5TTLL4ZaoBdqbh
# OhZ3ZRDUphPvSRmMThi0vw9vODRzW6AxnJll38F0cuJG7uEBYTptMSbhdhGQDpOX
# gpIUsWTjd6xpR6oaQf/DJbg3s6KCLPAlZ66RzIg9sC+NJpud/v4+7RWsWCiKi9EO
# LLHfMR2ZyJ/+xhCx9yHbxtl5TPau1j/1MIDpMPx0LckTetiSuEtQvLsNz3Qbp7wG
# WqbIiOWCnb5WqxL3/BAPvIXKUjPSxyZsq8WhbaM2tszWkPZPubdcMIIG7TCCBNWg
# AwIBAgIQCE/cM09+RU7bww+P+ZIYNTANBgkqhkiG9w0BAQsFADBpMQswCQYDVQQG
# EwJVUzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4xQTA/BgNVBAMTOERpZ2lDZXJ0
# IFRydXN0ZWQgRzQgVGltZVN0YW1waW5nIFJTQTQwOTYgU0hBMjU2IDIwMjUgQ0Ex
# MB4XDTI2MDgwNTAwMDAwMFoXDTM3MTEwNDIzNTk1OVowYzELMAkGA1UEBhMCVVMx
# FzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMTswOQYDVQQDEzJEaWdpQ2VydCBTSEEy
# NTYgUlNBNDA5NiBUaW1lc3RhbXAgUmVzcG9uZGVyIDIwMjYgMTCCAiIwDQYJKoZI
# hvcNAQEBBQADggIPADCCAgoCggIBALZ7pvLJ/s1K+NSbTGWz/TjGMPh8CQ6RucZC
# Lv5anHzWJjF/NWJrFIhy24fcpKXlgRiky4WAawDfU3YP0BMxt9l3Dm5oCG5Z69Aq
# EN1kgHg2epx+l+lZBcmJCcN0ASURML5uFIS80sZsDwO3BSkUxDjLJhBI+qiZP3ai
# xAC/qEGLjsBNlLol9VZ7pfGEXiMlneJIC5/YKuizVzNFKZZEeoy/0B8Zm+nzKBgS
# WG52lCO1w+nCg6XpCtklTJXeIg283hw7TmmsZXR+SMbjbrEOvZ3fP2VxIgeR28Y9
# 0ZStd3F9VuA5RVynb/whITPAo9b75Zr4Ta6Mj3URm26QZYMn/FnbuTegcoRcFEZ9
# FOqM5T6MTdtr/n74lIT/ug0eeOzmZ6QTFg33otX+bFRsIolvykE1jive4PuESaT8
# zzVeFWDAMDtozNgLctkGD1ZjkEyZtJrLl5ya0m5doH/ScpaZCZVl6pNUOCybMc/k
# xC6EAmSJY24L0yYKD1Nkddsnb/ItVKi/2nXpQNMu1PT5prW83vV8d67WowuUs0Hd
# Y4H8AMLGvdL/WHEj3ZnqMqAQQP9u3Ai9t+5eQ02GDwy0ODjdzi0xlp70W+ow63/0
# ++YDEX1M0iwgUHwbrJvfpklkZQvw3+kv3vUPItdwroczk9icflf55W1zOEKAcJVA
# IXpcMCU9AgMBAAGjggGVMIIBkTAMBgNVHRMBAf8EAjAAMB0GA1UdDgQWBBQUyWOK
# MC7USvtulPPm40B+9ezN4jAfBgNVHSMEGDAWgBTvb1NK6eQGfHrK4pBW9i/USezL
# TjAOBgNVHQ8BAf8EBAMCB4AwFgYDVR0lAQH/BAwwCgYIKwYBBQUHAwgwgZUGCCsG
# AQUFBwEBBIGIMIGFMCQGCCsGAQUFBzABhhhodHRwOi8vb2NzcC5kaWdpY2VydC5j
# b20wXQYIKwYBBQUHMAKGUWh0dHA6Ly9jYWNlcnRzLmRpZ2ljZXJ0LmNvbS9EaWdp
# Q2VydFRydXN0ZWRHNFRpbWVTdGFtcGluZ1JTQTQwOTZTSEEyNTYyMDI1Q0ExLmNy
# dDBfBgNVHR8EWDBWMFSgUqBQhk5odHRwOi8vY3JsMy5kaWdpY2VydC5jb20vRGln
# aUNlcnRUcnVzdGVkRzRUaW1lU3RhbXBpbmdSU0E0MDk2U0hBMjU2MjAyNUNBMS5j
# cmwwIAYDVR0gBBkwFzAIBgZngQwBBAIwCwYJYIZIAYb9bAcBMA0GCSqGSIb3DQEB
# CwUAA4ICAQCNxTphHp1SCt+ZrAmAfn0oQLFr0mLywSLaDXQIENoyKqxrFbJblzCV
# P/pkXmwXOdrOpWygLzlT12os5ipDCy35RBCg2UMeApEtrfGhz45F4Wt4WGdNdIbR
# Wt3YTYJmpR+b7lr4d7Uwn+H600u4D7RnOGf8Wj4UNgAdZkfHhHv1mx9EVh71SJel
# cEN/oORSjXzdjfw1iZH9d8Nh/thn6hH23d+VsPAr6GAYyzSA02nXD1nYLI7Ijmiv
# +xLCiYC41DSFYL3GhTiy0PxpawPtGRyaBVGzq+UiTfM8pD7KVyF5aQyWP4KhVGUU
# Tnmm/RlYJoW3TiXA/+t0YcT2oRVBm3JETjajHug2AL+v5jhtKVnd3D0rbHXEu27o
# +Q8p4sEWPMqKDB+qbceb6T/6WcwTwXmQ9lOCLLYcsQeSWmvKqzpAec9etE14jOQA
# zLKWdE3w/TCaKtLRaRT7LCkRYVnhA2D73FLje1O5b3HR5eHs0NzU/+xX7NbEdcof
# y0W3Wdwd1XOqtlpg/JgwtKfZM5dqO94lbUveOiJBI+xZEbGRsMNbXmMREUTgu+Oc
# a7Y73MPWcslIx2VhkSKSXjDbD6rgg39H5Mh7QfieAIjWagkJNt68Yfim6cjEzVSi
# LSeZfdkr5dtFPTW6jATlWJdYeeDRGCyatf8R1hSjzSvdN8yWQPT9gzCCB8kwggWx
# oAMCAQICEAlBhSwxLm93rMd0RNayLkYwDQYJKoZIhvcNAQELBQAwaTELMAkGA1UE
# BhMCVVMxFzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMUEwPwYDVQQDEzhEaWdpQ2Vy
# dCBUcnVzdGVkIEc0IENvZGUgU2lnbmluZyBSU0E0MDk2IFNIQTM4NCAyMDIxIENB
# MTAeFw0yNjAzMTEwMDAwMDBaFw0yNzA0MzAyMzU5NTlaMIHRMRMwEQYLKwYBBAGC
# NzwCAQMTAlVTMRkwFwYLKwYBBAGCNzwCAQITCENvbG9yYWRvMR0wGwYDVQQPDBRQ
# cml2YXRlIE9yZ2FuaXphdGlvbjEUMBIGA1UEBRMLMjAxMzE2MzgzMjcxCzAJBgNV
# BAYTAlVTMREwDwYDVQQIEwhDb2xvcmFkbzEUMBIGA1UEBxMLQ2FzdGxlIFJvY2sx
# GTAXBgNVBAoTEFBhdGNoIE15IFBDLCBMTEMxGTAXBgNVBAMTEFBhdGNoIE15IFBD
# LCBMTEMwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQCmFrmhTn0idojJ
# 7d51YC3OJjnDjtWd/u1iGtKr+/61XDDQ0uvrt5yzd0++cH4hIFRvI5Xk6Ie6GWuR
# /DIiNZhMHnmVUx1L/9XkUHp/KAwdwkeYtTn6Dyhcqbxild42QmSYaCoTz5tpz99i
# ZqcarQQ8c85j/6OMt312iixZD/OBcGokpkllnkyvQnnXib4+hXtCrtyomRTU857J
# fkPZKUdHKk8WElPi9PtIHjoWoNQkTIFUeqONuADgVcTha7cQKgHphcKhqZT+GHIC
# NyHiL7ecBrNGgox9Zpd2Xbl845WvXrbyIwpxbwV68nsLTlxNA7faXEDdSMu4uqwN
# LE8hcEUfETvAZ0A1xqnFrERFPdXQ0xflKuZVSLDak5mYKpb6CmcRlCrBj8SXj7NM
# 1QPETxMbsWknnmFxhcj/mBkDITdBXpBJnSKB2xLwzC8eZTqlYQ7gDqoIcEAJv/Pd
# SDIVRbCB9T8ziLmIYBAMjKY1tPMyMI+kG4+pChadsD644tKlzzUXyHvwvbHOuzwr
# vwq8UsMrG27wQA6uW4nZrgaYmVbLTSikYhTVczV7txTuHj8O6W2E87LVL6TPntLp
# kXC1TyRJ3jqBXDK+MjzvaQqcOgDwETNTRkLBOMsy3ByChCKfW6Ze4rdmzqBK5OPi
# ohJ3LT7Kp2WzJq9GX48C6ytA9WwGDwIDAQABo4ICAjCCAf4wHwYDVR0jBBgwFoAU
# aDfg67Y7+F8Rhvv+YXsIiGX0TkIwHQYDVR0OBBYEFEsL1EbO9agQBUggqfsA2InI
# I6VQMD0GA1UdIAQ2MDQwMgYFZ4EMAQMwKTAnBggrBgEFBQcCARYbaHR0cDovL3d3
# dy5kaWdpY2VydC5jb20vQ1BTMA4GA1UdDwEB/wQEAwIHgDATBgNVHSUEDDAKBggr
# BgEFBQcDAzCBtQYDVR0fBIGtMIGqMFOgUaBPhk1odHRwOi8vY3JsMy5kaWdpY2Vy
# dC5jb20vRGlnaUNlcnRUcnVzdGVkRzRDb2RlU2lnbmluZ1JTQTQwOTZTSEEzODQy
# MDIxQ0ExLmNybDBToFGgT4ZNaHR0cDovL2NybDQuZGlnaWNlcnQuY29tL0RpZ2lD
# ZXJ0VHJ1c3RlZEc0Q29kZVNpZ25pbmdSU0E0MDk2U0hBMzg0MjAyMUNBMS5jcmww
# gZQGCCsGAQUFBwEBBIGHMIGEMCQGCCsGAQUFBzABhhhodHRwOi8vb2NzcC5kaWdp
# Y2VydC5jb20wXAYIKwYBBQUHMAKGUGh0dHA6Ly9jYWNlcnRzLmRpZ2ljZXJ0LmNv
# bS9EaWdpQ2VydFRydXN0ZWRHNENvZGVTaWduaW5nUlNBNDA5NlNIQTM4NDIwMjFD
# QTEuY3J0MAkGA1UdEwQCMAAwDQYJKoZIhvcNAQELBQADggIBAB+ZTb1BVZB0FiG8
# voHj1X6KDkHT2iaeyBtzclOYGpkRDubMDztoEh/kSlYY4aHs+i7IOAL0JLaWBaNx
# f4+BOU5TU/6TBsBqrNw3k/keSWXhkKG8TG6gbOk3FlvC1Vaio9MwL6kOCIcnlIXw
# +DIgqe4xFbe3UYb6d8LQZqpHCB98yT7nzOgiaKfE8B4ldqMr/ZPMFZ1RV1k3VG8l
# qIpZF2Z2hXve5gcRMn/vohC/NQYuNTsnOziuFHA+w4d0BAhdRPukFMRvNcpKYWtf
# vwFW9Kz8YlJfXKVs7P034GY08MWP89GSNL8jP1LdNcaxT1Vwao2kfDsTgM44Bo3E
# 8pG0ne1KCT9jBHmi/UikZazXkong9vfg7LmWqoX5BeSRlsmg4alkoZqLPbsBuTxG
# H/uBTl+omarkA+HFZYczgVaJq3GB/nve7z5oJkTKfoRmV+ungzbML42sxb1GXJQy
# A3t6w8Bw4b76188qaxZiK4Z0mZAkM5Xt7I1UglR6I1EFdxvgZYioVBH/4eCoxiwg
# Ad3np7sk2OHNOLbY5LLepi/brPoZ4ZiW0ycuJPx91zFSbySYMbQ1rHf16lD2DP9D
# da/oN6yed825gYbar00PzcDjqlPZzs+CImYqG055nfZDzwip+Bu09AaTzHsYNevK
# kNb21I0wTdWZauRdVYHUj3qblAlwMYIGWTCCBlUCAQEwfTBpMQswCQYDVQQGEwJV
# UzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4xQTA/BgNVBAMTOERpZ2lDZXJ0IFRy
# dXN0ZWQgRzQgQ29kZSBTaWduaW5nIFJTQTQwOTYgU0hBMzg0IDIwMjEgQ0ExAhAJ
# QYUsMS5vd6zHdETWsi5GMA0GCWCGSAFlAwQCAQUAoIGEMBgGCisGAQQBgjcCAQwx
# CjAIoAKAAKECgAAwGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwHAYKKwYBBAGC
# NwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEIM2SLYME5P5AWgwH
# 6Zp3YLCmc4tR5Ne0KXWJoG7PRfl0MA0GCSqGSIb3DQEBAQUABIICAB++Lsnvv1u6
# Be3JI3EBvpEvSMd9GBtQtJwMmwex8XgRy8UPcHIXJPYh21BJSkwYAmmSyWQpmz3C
# 136nWlhJCP6ov6Vv+mkWw+PY8q9NMdZYbFvQFIYxi8nMijQAsEOzgDpfQ0Hr2WBW
# LT/GKl69CZFjeiMEYj8euAcAec9Y7gBNC8FbtohiVJtIpXEWDj1bplYsW+XCjzEa
# VGZiGklWFh2rbKHVS5Alk6It/LpN6z+pNGiWzR4xDYae6RzKLM27i8Gt6YqOm5Tm
# jzQSgZFcgkvfejEqVN7zKjVc0BSfWiXW7aWIycLypSkAY1/LH12IT74YLJsGuQpQ
# m/TVSSG0NjOwOveAkzSX185LB9/YNizGvIG8xaCOgUNRm+n9IZrlytNktyzGVyco
# 2IyTEHWhGMCp5llzePdspWv7n6dZJa3I//L03RgqZvg23fGhMMX/5mcSts/6hWY3
# WXluMcDKucfprrajBhyN03TilgbcnQTsLcp2OiQKjK0H5j4YOVMaBNl5qU/5T6YG
# v3ZTyihjdatlPekcE7V3SYGBdvE+LdrlTIrDiXPP/GD3B7giHWWfmKv+5nW59T26
# 8MSnVGBdW1niAgrJG8/BdVabIdClzsO8rGt2eMLjgbHomaFM+lE9heCmjdETtE8p
# OjHmnz7bQnMfr0Wb0fiw6xH4Y3ASqXvToYIDJjCCAyIGCSqGSIb3DQEJBjGCAxMw
# ggMPAgEBMH0waTELMAkGA1UEBhMCVVMxFzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMu
# MUEwPwYDVQQDEzhEaWdpQ2VydCBUcnVzdGVkIEc0IFRpbWVTdGFtcGluZyBSU0E0
# MDk2IFNIQTI1NiAyMDI1IENBMQIQCE/cM09+RU7bww+P+ZIYNTANBglghkgBZQME
# AgEFAKBpMBgGCSqGSIb3DQEJAzELBgkqhkiG9w0BBwEwHAYJKoZIhvcNAQkFMQ8X
# DTI2MTAwNzE3MjkxNlowLwYJKoZIhvcNAQkEMSIEILu4gG/tyZ9dzMx/KtN1Bo1S
# BnRaZvZT2rD5rZl3foB3MA0GCSqGSIb3DQEBAQUABIICAJQhOdwLEXMpfGHfX9Uu
# 4qozdxlnocLi8QHGOqyUaxYu4IrJk3Wgq+X3jgtSRUz8jIzHAsjS5Hif9eYPQZ8Q
# O9a1rJqHt6AtWJioY28My4sm5UQBwsKa+tVf81hXON76lQwqNHp5gDYGOLu74WxS
# /7xLv8EtOmlXB9nDdp2R7wTRe1dUdTCCmmvOw+Yi8HoV22FXbK3sluwFLSsEQJLQ
# CTmSD/JwvimIbsKHvbv7wmezQg/Z6s5BZaW5fmWjHrj+v6KphRcnssGXcY4UNZSo
# +d/0Rhvon2ZS0CbVlgE4nW48bbLlbE7A0x8PtqeEqWb/EaKXLLytRSZCykLAZL/g
# ymuJ+iBUHqce/Bt5F3/uR/YxtWOvXv5D2yBea7tgAb7I0HGi9l1mX0ozKIuLtvsm
# Y5ZLuO5c/iUfjDNEYKmw5ijQce12lsq8GVQIwuE0WmCNbAQMZq4EGSS3swpbrJHu
# MqF2C9y+9EpLghRiQK5o56PdWZ6OoIyrv8R5s/0iUwjG1Yn/3acFCZXIz5omvUF9
# bCRGton6TKkIc0HY6xUZnUhImMLnTQ8dtbFWKDYbNhzAUHvs4vJ2UP6+PDFhxTpJ
# GrK3QOq8qgwQaL1lQe2erug8v+Q+77SpDhOVsUW2kRJboAO1u8q1/Iu/2aS7Ef87
# N07XxjU7/k52+GaT/bmj09do
# SIG # End signature block
