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

# SIG # Begin signature block
# MIIogQYJKoZIhvcNAQcCoIIocjCCKG4CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCh2fg2JXnyAp/A
# M89NPvy7l7f3RC/tM+l2IWyZqyaOH6CCIYQwggWNMIIEdaADAgECAhAOmxiO+dAt
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
# twGpn1eqXijiuZQwggauMIIElqADAgECAhAHNje3JFR82Ees/ShmKl5bMA0GCSqG
# SIb3DQEBCwUAMGIxCzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdpQ2VydCBJbmMx
# GTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xITAfBgNVBAMTGERpZ2lDZXJ0IFRy
# dXN0ZWQgUm9vdCBHNDAeFw0yMjAzMjMwMDAwMDBaFw0zNzAzMjIyMzU5NTlaMGMx
# CzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdpQ2VydCwgSW5jLjE7MDkGA1UEAxMy
# RGlnaUNlcnQgVHJ1c3RlZCBHNCBSU0E0MDk2IFNIQTI1NiBUaW1lU3RhbXBpbmcg
# Q0EwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQDGhjUGSbPBPXJJUVXH
# JQPE8pE3qZdRodbSg9GeTKJtoLDMg/la9hGhRBVCX6SI82j6ffOciQt/nR+eDzMf
# UBMLJnOWbfhXqAJ9/UO0hNoR8XOxs+4rgISKIhjf69o9xBd/qxkrPkLcZ47qUT3w
# 1lbU5ygt69OxtXXnHwZljZQp09nsad/ZkIdGAHvbREGJ3HxqV3rwN3mfXazL6IRk
# tFLydkf3YYMZ3V+0VAshaG43IbtArF+y3kp9zvU5EmfvDqVjbOSmxR3NNg1c1eYb
# qMFkdECnwHLFuk4fsbVYTXn+149zk6wsOeKlSNbwsDETqVcplicu9Yemj052FVUm
# cJgmf6AaRyBD40NjgHt1biclkJg6OBGz9vae5jtb7IHeIhTZgirHkr+g3uM+onP6
# 5x9abJTyUpURK1h0QCirc0PO30qhHGs4xSnzyqqWc0Jon7ZGs506o9UD4L/wojzK
# QtwYSH8UNM/STKvvmz3+DrhkKvp1KCRB7UK/BZxmSVJQ9FHzNklNiyDSLFc1eSuo
# 80VgvCONWPfcYd6T/jnA+bIwpUzX6ZhKWD7TA4j+s4/TXkt2ElGTyYwMO1uKIqjB
# Jgj5FBASA31fI7tk42PgpuE+9sJ0sj8eCXbsq11GdeJgo1gJASgADoRU7s7pXche
# MBK9Rp6103a50g5rmQzSM7TNsQIDAQABo4IBXTCCAVkwEgYDVR0TAQH/BAgwBgEB
# /wIBADAdBgNVHQ4EFgQUuhbZbU2FL3MpdpovdYxqII+eyG8wHwYDVR0jBBgwFoAU
# 7NfjgtJxXWRM3y5nP+e6mK4cD08wDgYDVR0PAQH/BAQDAgGGMBMGA1UdJQQMMAoG
# CCsGAQUFBwMIMHcGCCsGAQUFBwEBBGswaTAkBggrBgEFBQcwAYYYaHR0cDovL29j
# c3AuZGlnaWNlcnQuY29tMEEGCCsGAQUFBzAChjVodHRwOi8vY2FjZXJ0cy5kaWdp
# Y2VydC5jb20vRGlnaUNlcnRUcnVzdGVkUm9vdEc0LmNydDBDBgNVHR8EPDA6MDig
# NqA0hjJodHRwOi8vY3JsMy5kaWdpY2VydC5jb20vRGlnaUNlcnRUcnVzdGVkUm9v
# dEc0LmNybDAgBgNVHSAEGTAXMAgGBmeBDAEEAjALBglghkgBhv1sBwEwDQYJKoZI
# hvcNAQELBQADggIBAH1ZjsCTtm+YqUQiAX5m1tghQuGwGC4QTRPPMFPOvxj7x1Bd
# 4ksp+3CKDaopafxpwc8dB+k+YMjYC+VcW9dth/qEICU0MWfNthKWb8RQTGIdDAiC
# qBa9qVbPFXONASIlzpVpP0d3+3J0FNf/q0+KLHqrhc1DX+1gtqpPkWaeLJ7giqzl
# /Yy8ZCaHbJK9nXzQcAp876i8dU+6WvepELJd6f8oVInw1YpxdmXazPByoyP6wCeC
# RK6ZJxurJB4mwbfeKuv2nrF5mYGjVoarCkXJ38SNoOeY+/umnXKvxMfBwWpx2cYT
# gAnEtp/Nh4cku0+jSbl3ZpHxcpzpSwJSpzd+k1OsOx0ISQ+UzTl63f8lY5knLD0/
# a6fxZsNBzU+2QJshIUDQtxMkzdwdeDrknq3lNHGS1yZr5Dhzq6YBT70/O3itTK37
# xJV77QpfMzmHQXh6OOmc4d0j/R0o08f56PGYX/sr2H7yRp11LB4nLCbbbxV7HhmL
# NriT1ObyF5lZynDwN7+YAN8gFk8n+2BnFqFmut1VwDophrCYoCvtlUG3OtUVmDG0
# YgkPCr2B2RP+v6TR81fZvAT6gt4y3wSJ8ADNXcL50CN/AAvkdgIm2fBldkKmKYcJ
# RyvmfxqkhQ/8mJb2VVQrH4D6wPIOK+XW+6kvRBVK5xMOHds3OBqhK/bt1nz8MIIG
# sDCCBJigAwIBAgIQCK1AsmDSnEyfXs2pvZOu2TANBgkqhkiG9w0BAQwFADBiMQsw
# CQYDVQQGEwJVUzEVMBMGA1UEChMMRGlnaUNlcnQgSW5jMRkwFwYDVQQLExB3d3cu
# ZGlnaWNlcnQuY29tMSEwHwYDVQQDExhEaWdpQ2VydCBUcnVzdGVkIFJvb3QgRzQw
# HhcNMjEwNDI5MDAwMDAwWhcNMzYwNDI4MjM1OTU5WjBpMQswCQYDVQQGEwJVUzEX
# MBUGA1UEChMORGlnaUNlcnQsIEluYy4xQTA/BgNVBAMTOERpZ2lDZXJ0IFRydXN0
# ZWQgRzQgQ29kZSBTaWduaW5nIFJTQTQwOTYgU0hBMzg0IDIwMjEgQ0ExMIICIjAN
# BgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEA1bQvQtAorXi3XdU5WRuxiEL1M4zr
# PYGXcMW7xIUmMJ+kjmjYXPXrNCQH4UtP03hD9BfXHtr50tVnGlJPDqFX/IiZwZHM
# gQM+TXAkZLON4gh9NH1MgFcSa0OamfLFOx/y78tHWhOmTLMBICXzENOLsvsI8Irg
# nQnAZaf6mIBJNYc9URnokCF4RS6hnyzhGMIazMXuk0lwQjKP+8bqHPNlaJGiTUyC
# EUhSaN4QvRRXXegYE2XFf7JPhSxIpFaENdb5LpyqABXRN/4aBpTCfMjqGzLmysL0
# p6MDDnSlrzm2q2AS4+jWufcx4dyt5Big2MEjR0ezoQ9uo6ttmAaDG7dqZy3SvUQa
# khCBj7A7CdfHmzJawv9qYFSLScGT7eG0XOBv6yb5jNWy+TgQ5urOkfW+0/tvk2E0
# XLyTRSiDNipmKF+wc86LJiUGsoPUXPYVGUztYuBeM/Lo6OwKp7ADK5GyNnm+960I
# HnWmZcy740hQ83eRGv7bUKJGyGFYmPV8AhY8gyitOYbs1LcNU9D4R+Z1MI3sMJN2
# FKZbS110YU0/EpF23r9Yy3IQKUHw1cVtJnZoEUETWJrcJisB9IlNWdt4z4FKPkBH
# X8mBUHOFECMhWWCKZFTBzCEa6DgZfGYczXg4RTCZT/9jT0y7qg0IU0F8WD1Hs/q2
# 7IwyCQLMbDwMVhECAwEAAaOCAVkwggFVMBIGA1UdEwEB/wQIMAYBAf8CAQAwHQYD
# VR0OBBYEFGg34Ou2O/hfEYb7/mF7CIhl9E5CMB8GA1UdIwQYMBaAFOzX44LScV1k
# TN8uZz/nupiuHA9PMA4GA1UdDwEB/wQEAwIBhjATBgNVHSUEDDAKBggrBgEFBQcD
# AzB3BggrBgEFBQcBAQRrMGkwJAYIKwYBBQUHMAGGGGh0dHA6Ly9vY3NwLmRpZ2lj
# ZXJ0LmNvbTBBBggrBgEFBQcwAoY1aHR0cDovL2NhY2VydHMuZGlnaWNlcnQuY29t
# L0RpZ2lDZXJ0VHJ1c3RlZFJvb3RHNC5jcnQwQwYDVR0fBDwwOjA4oDagNIYyaHR0
# cDovL2NybDMuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0VHJ1c3RlZFJvb3RHNC5jcmww
# HAYDVR0gBBUwEzAHBgVngQwBAzAIBgZngQwBBAEwDQYJKoZIhvcNAQEMBQADggIB
# ADojRD2NCHbuj7w6mdNW4AIapfhINPMstuZ0ZveUcrEAyq9sMCcTEp6QRJ9L/Z6j
# fCbVN7w6XUhtldU/SfQnuxaBRVD9nL22heB2fjdxyyL3WqqQz/WTauPrINHVUHmI
# moqKwba9oUgYftzYgBoRGRjNYZmBVvbJ43bnxOQbX0P4PpT/djk9ntSZz0rdKOtf
# JqGVWEjVGv7XJz/9kNF2ht0csGBc8w2o7uCJob054ThO2m67Np375SFTWsPK6Wrx
# oj7bQ7gzyE84FJKZ9d3OVG3ZXQIUH0AzfAPilbLCIXVzUstG2MQ0HKKlS43Nb3Y3
# LIU/Gs4m6Ri+kAewQ3+ViCCCcPDMyu/9KTVcH4k4Vfc3iosJocsL6TEa/y4ZXDlx
# 4b6cpwoG1iZnt5LmTl/eeqxJzy6kdJKt2zyknIYf48FWGysj/4+16oh7cGvmoLr9
# Oj9FpsToFpFSi0HASIRLlk2rREDjjfAVKM7t8RhWByovEMQMCGQ8M4+uKIw8y4+I
# Cw2/O/TOHnuO77Xry7fwdxPm5yg/rBKupS8ibEH5glwVZsxsDsrFhsP2JjMMB0ug
# 0wcCampAMEhLNKhRILutG4UI4lkNbcoFUCvqShyepf2gpx8GdOfy1lKQ/a+FSCH5
# Vzu0nAPthkX0tGFuv2jiJmCG6sivqf6UHedjGzqGVnhOMIIGvDCCBKSgAwIBAgIQ
# C65mvFq6f5WHxvnpBOMzBDANBgkqhkiG9w0BAQsFADBjMQswCQYDVQQGEwJVUzEX
# MBUGA1UEChMORGlnaUNlcnQsIEluYy4xOzA5BgNVBAMTMkRpZ2lDZXJ0IFRydXN0
# ZWQgRzQgUlNBNDA5NiBTSEEyNTYgVGltZVN0YW1waW5nIENBMB4XDTI0MDkyNjAw
# MDAwMFoXDTM1MTEyNTIzNTk1OVowQjELMAkGA1UEBhMCVVMxETAPBgNVBAoTCERp
# Z2lDZXJ0MSAwHgYDVQQDExdEaWdpQ2VydCBUaW1lc3RhbXAgMjAyNDCCAiIwDQYJ
# KoZIhvcNAQEBBQADggIPADCCAgoCggIBAL5qc5/2lSGrljC6W23mWaO16P2RHxjE
# iDtqmeOlwf0KMCBDEr4IxHRGd7+L660x5XltSVhhK64zi9CeC9B6lUdXM0s71EOc
# Re8+CEJp+3R2O8oo76EO7o5tLuslxdr9Qq82aKcpA9O//X6QE+AcaU/byaCagLD/
# GLoUb35SfWHh43rOH3bpLEx7pZ7avVnpUVmPvkxT8c2a2yC0WMp8hMu60tZR0Cha
# V76Nhnj37DEYTX9ReNZ8hIOYe4jl7/r419CvEYVIrH6sN00yx49boUuumF9i2T8U
# uKGn9966fR5X6kgXj3o5WHhHVO+NBikDO0mlUh902wS/Eeh8F/UFaRp1z5SnROHw
# SJ+QQRZ1fisD8UTVDSupWJNstVkiqLq+ISTdEjJKGjVfIcsgA4l9cbk8Smlzddh4
# EfvFrpVNnes4c16Jidj5XiPVdsn5n10jxmGpxoMc6iPkoaDhi6JjHd5ibfdp5uzI
# Xp4P0wXkgNs+CO/CacBqU0R4k+8h6gYldp4FCMgrXdKWfM4N0u25OEAuEa3Jyidx
# W48jwBqIJqImd93NRxvd1aepSeNeREXAu2xUDEW8aqzFQDYmr9ZONuc2MhTMizch
# NULpUEoA6Vva7b1XCB+1rxvbKmLqfY/M/SdV6mwWTyeVy5Z/JkvMFpnQy5wR14GJ
# cv6dQ4aEKOX5AgMBAAGjggGLMIIBhzAOBgNVHQ8BAf8EBAMCB4AwDAYDVR0TAQH/
# BAIwADAWBgNVHSUBAf8EDDAKBggrBgEFBQcDCDAgBgNVHSAEGTAXMAgGBmeBDAEE
# AjALBglghkgBhv1sBwEwHwYDVR0jBBgwFoAUuhbZbU2FL3MpdpovdYxqII+eyG8w
# HQYDVR0OBBYEFJ9XLAN3DigVkGalY17uT5IfdqBbMFoGA1UdHwRTMFEwT6BNoEuG
# SWh0dHA6Ly9jcmwzLmRpZ2ljZXJ0LmNvbS9EaWdpQ2VydFRydXN0ZWRHNFJTQTQw
# OTZTSEEyNTZUaW1lU3RhbXBpbmdDQS5jcmwwgZAGCCsGAQUFBwEBBIGDMIGAMCQG
# CCsGAQUFBzABhhhodHRwOi8vb2NzcC5kaWdpY2VydC5jb20wWAYIKwYBBQUHMAKG
# TGh0dHA6Ly9jYWNlcnRzLmRpZ2ljZXJ0LmNvbS9EaWdpQ2VydFRydXN0ZWRHNFJT
# QTQwOTZTSEEyNTZUaW1lU3RhbXBpbmdDQS5jcnQwDQYJKoZIhvcNAQELBQADggIB
# AD2tHh92mVvjOIQSR9lDkfYR25tOCB3RKE/P09x7gUsmXqt40ouRl3lj+8QioVYq
# 3igpwrPvBmZdrlWBb0HvqT00nFSXgmUrDKNSQqGTdpjHsPy+LaalTW0qVjvUBhcH
# zBMutB6HzeledbDCzFzUy34VarPnvIWrqVogK0qM8gJhh/+qDEAIdO/KkYesLyTV
# OoJ4eTq7gj9UFAL1UruJKlTnCVaM2UeUUW/8z3fvjxhN6hdT98Vr2FYlCS7Mbb4H
# v5swO+aAXxWUm3WpByXtgVQxiBlTVYzqfLDbe9PpBKDBfk+rabTFDZXoUke7zPgt
# d7/fvWTlCs30VAGEsshJmLbJ6ZbQ/xll/HjO9JbNVekBv2Tgem+mLptR7yIrpaid
# RJXrI+UzB6vAlk/8a1u7cIqV0yef4uaZFORNekUgQHTqddmsPCEIYQP7xGxZBIhd
# mm4bhYsVA6G2WgNFYagLDBzpmk9104WQzYuVNsxyoVLObhx3RugaEGru+SojW4dH
# PoWrUhftNpFC5H7QEY7MhKRyrBe7ucykW7eaCuWBsBb4HOKRFVDcrZgdwaSIqMDi
# CLg4D+TPVgKx2EgEdeoHNHT9l3ZDBD+XgbF+23/zBjeCtxz+dL/9NWR6P2eZRi7z
# cEO1xwcdcqJsyz/JceENc2Sg8h3KeFUCS7tpFk7CrDqkMIIHyTCCBbGgAwIBAgIQ
# DMNw87U7UZ48Hv1za61jojANBgkqhkiG9w0BAQsFADBpMQswCQYDVQQGEwJVUzEX
# MBUGA1UEChMORGlnaUNlcnQsIEluYy4xQTA/BgNVBAMTOERpZ2lDZXJ0IFRydXN0
# ZWQgRzQgQ29kZSBTaWduaW5nIFJTQTQwOTYgU0hBMzg0IDIwMjEgQ0ExMB4XDTIz
# MDQwNzAwMDAwMFoXDTI2MDQzMDIzNTk1OVowgdExEzARBgsrBgEEAYI3PAIBAxMC
# VVMxGTAXBgsrBgEEAYI3PAIBAhMIQ29sb3JhZG8xHTAbBgNVBA8MFFByaXZhdGUg
# T3JnYW5pemF0aW9uMRQwEgYDVQQFEwsyMDEzMTYzODMyNzELMAkGA1UEBhMCVVMx
# ETAPBgNVBAgTCENvbG9yYWRvMRQwEgYDVQQHEwtDYXN0bGUgUm9jazEZMBcGA1UE
# ChMQUGF0Y2ggTXkgUEMsIExMQzEZMBcGA1UEAxMQUGF0Y2ggTXkgUEMsIExMQzCC
# AiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAKaQcs40YzBFv5HXQFPd04rK
# J4uBdwvAZLKuULy+icZOpgs/Sy329Ng5ikhB5o1IdvE2cOT20sjs3qgb4e+rqs7t
# aTCe6RNLsDINsmcTlp4yxOfV80EZ08ld3o36GEgH0Vy1vrJXLTRKNULzV7gIzF/e
# 3tO1Fab4IxKZNcBSXiv8ORqcgT9O7/RZoqyG87iU6Q/dKfC4WzvU396XJ3FMZrI+
# s4CgV8p6pVNjijBjH7pmzoXynFtA0j6NH6tg4DmQvm+kfWXtWbDpPYhdFz1gccJt
# 1DjTrJetpIwBzDAS8NGA75HQhBmQ3gcnNDJLgylB3HyWOeXS+vxXR0Pi/W419cfn
# 8zCFH0u2O4QFaZsT2HoIE/t9EhdAKdHoKwvVoCgwvlx3jjwFq5MnoB2oJiNmTGQy
# hiRvCaw6JACKUa43eJvlRKylEy4INDTOX5BeivJoTqCw0cCAd6ZuRh6gRl8shIVf
# N78qunQqJZQkDimtQY5Sn33w+ee5/lFSxOxBg6iu7vCGPZ6QxJd6oVdRa8t87vJ4
# QVlsMQQRa400S7kqIX1HOnbR3hxgvcks8kBRMYtZ8g3Fz/WTCW5sWbExVpn6HC6D
# sRhosF/DBGYmIqQJz6odkCFCr7QcmpGjoZs4jRDegSC5utEusBYmvCfVxtud3R43
# WEdCRfHuD1OFDm5HoonnAgMBAAGjggICMIIB/jAfBgNVHSMEGDAWgBRoN+Drtjv4
# XxGG+/5hewiIZfROQjAdBgNVHQ4EFgQU3wgET0b7maQo7OF3wwGWm83hl+0wDgYD
# VR0PAQH/BAQDAgeAMBMGA1UdJQQMMAoGCCsGAQUFBwMDMIG1BgNVHR8Ega0wgaow
# U6BRoE+GTWh0dHA6Ly9jcmwzLmRpZ2ljZXJ0LmNvbS9EaWdpQ2VydFRydXN0ZWRH
# NENvZGVTaWduaW5nUlNBNDA5NlNIQTM4NDIwMjFDQTEuY3JsMFOgUaBPhk1odHRw
# Oi8vY3JsNC5kaWdpY2VydC5jb20vRGlnaUNlcnRUcnVzdGVkRzRDb2RlU2lnbmlu
# Z1JTQTQwOTZTSEEzODQyMDIxQ0ExLmNybDA9BgNVHSAENjA0MDIGBWeBDAEDMCkw
# JwYIKwYBBQUHAgEWG2h0dHA6Ly93d3cuZGlnaWNlcnQuY29tL0NQUzCBlAYIKwYB
# BQUHAQEEgYcwgYQwJAYIKwYBBQUHMAGGGGh0dHA6Ly9vY3NwLmRpZ2ljZXJ0LmNv
# bTBcBggrBgEFBQcwAoZQaHR0cDovL2NhY2VydHMuZGlnaWNlcnQuY29tL0RpZ2lD
# ZXJ0VHJ1c3RlZEc0Q29kZVNpZ25pbmdSU0E0MDk2U0hBMzg0MjAyMUNBMS5jcnQw
# CQYDVR0TBAIwADANBgkqhkiG9w0BAQsFAAOCAgEADaIfBgYBzz7rZspAw5OGKL7n
# t4eo6SMcS91NAex1HWxak4hX7yqQB25Oa66WaVBtd14rZxptoGQ88FDezI1qyUs4
# bwi4NaW9WBY8QDnGGhgyZ3aT3ZEBEvMWy6MFpzlyvjPBcWE5OGuoRMhP42TSMhvF
# lZGCPZy02PLUdGcTynL55YhdTcGJnX0Z2OgSaHUQTmXhgRX+fajIilPnmmv8Av4C
# lr6Xa9SoNHltA04JRiCu4ejDGFqA94F696jSJ+AUYHys6bnPc0E8JB9YnFCAurPR
# G8YBJAofUtxnGIHGE0EiQTZeXf0nKmVBIXkE3hT4mZx7pH7wrlCr0FV4qnq6j0ua
# j4oKqFbkdyzb5u+XQe9pPojshnjVzhIRK53wsGaFP4gSURxWvcThIOyoaKrVDZOd
# LQZXEz8Anks3Vs5XscjyzFR7pv/3Reik7FaZRTvd5rDW6foDJOiCwX5p+UnldHGH
# W83rDvtks1rwgKwuuxvCG3Bkjirl94EImpiugGaRQ7S2Lydxpqzv7Hng4YQbIIvV
# MNC7mNrVZPNWdF4/a9yjDt2nJrnRcDK1zvHBXSrAYIycQ6hhhlHS9Y4MRhz35t1d
# u/Y0IXDB7HBYSvcsrpxtBzXLTd2NCNCtdkwYIl7WTQeoCbZWvo4PbzJBOnPjs1tN
# 4upe9XomxtZkNAwIOfMxggZTMIIGTwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYD
# VQQKEw5EaWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBH
# NCBDb2RlIFNpZ25pbmcgUlNBNDA5NiBTSEEzODQgMjAyMSBDQTECEAzDcPO1O1Ge
# PB79c2utY6IwDQYJYIZIAWUDBAIBBQCggYQwGAYKKwYBBAGCNwIBDDEKMAigAoAA
# oQKAADAZBgkqhkiG9w0BCQMxDAYKKwYBBAGCNwIBBDAcBgorBgEEAYI3AgELMQ4w
# DAYKKwYBBAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgHdhPfiCe/zf8H5noIwLkrhIQ
# 9DR7f8KcC7MSp8ojTUswDQYJKoZIhvcNAQEBBQAEggIALTR8ShXH0ltumtnRA4xM
# QiQW93FNC4SJRfJzSiHAy2av5hOrbk2f5eBvWA1yuJSES7AvFyJAHnpfIMKFj2Uf
# Gcey4ed7ny/Y3yCdCG2qljN7vzmFXPHHtjfcvgW6sjh5c0/QrnZMDLtiWodBih1P
# pJdK5suk53mWXCD17UmccxPR0X+NcR7z4/H6lGwbiJ7P2MnKyxq7sNkCgveTtmhO
# ntk9vXL78giAKThEKZHNKsVhUcd3W7fhatYmfST3JrsZoc+WNXfEcEgCeBhxwcmX
# 1qMWDCj8BUdMVqk81yYt7r0mD4f+4branrrniyT8I1O6VAJRCBSq1kWAxFki/fIF
# fDnq1kviTLG6irxYvu73P4EoCU3WteEmbNUctdje8HBliMyb7RgH4G9GkmjleETm
# quUVU2l37I2Ia1JOl3ECwBbcRvk3vsjRcURfl0SF0i/++JuSSPbgTTPDF0tIoY7B
# /wwV2u7/gxLheZKsSYbBEI0if9rPL6KyYQMRewrw5Xm1YcWwA5yPmpLXbP0Sm/4p
# uqnem0ZeBpnAow/gNKuVWZCU07KtBzygzfC7as7iknsGfNklY29PsEZuaiEQrXTC
# LkL7ci4HaYcQMPBu9Q2Far6aIc7ggbSDjSVo2Yf8hFq7Nhkurpc8RR/oHQMM1nNJ
# 0+S7zmGdb++Qd7K1yHq79dyhggMgMIIDHAYJKoZIhvcNAQkGMYIDDTCCAwkCAQEw
# dzBjMQswCQYDVQQGEwJVUzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4xOzA5BgNV
# BAMTMkRpZ2lDZXJ0IFRydXN0ZWQgRzQgUlNBNDA5NiBTSEEyNTYgVGltZVN0YW1w
# aW5nIENBAhALrma8Wrp/lYfG+ekE4zMEMA0GCWCGSAFlAwQCAQUAoGkwGAYJKoZI
# hvcNAQkDMQsGCSqGSIb3DQEHATAcBgkqhkiG9w0BCQUxDxcNMjQxMjEyMTUyNTA1
# WjAvBgkqhkiG9w0BCQQxIgQgzwzcfLlkU/Z7mQ6eOXAsa8JTKOhwGCVKTkho32Xk
# A3MwDQYJKoZIhvcNAQEBBQAEggIAX+Cckito2i2vjgyr5xwu2+stUQwOn0TyriS1
# MXtBkQTT781UO56NnzTeMd2QS1UcPl7NAI+CAj7mQtHr9pf0SC1P7uT59S6k/1vh
# mICsZl9V1pjHey7tFw262nof6syFcHCPB5Bp0+EZhZM5G78Oro3olpN6g2/6UcC/
# IwWBmVrYd/QX6lAAsOBVXSnNGI2tvkt8QKQHEvOwf/nW3xJk1Mo54Aq6dcUNAplx
# ez/wnjio7edHxuGbaOVt0RgsVYFY5+GMrqVVVvMmDRaaA3PUiVhfZ0tiFIInZLdv
# N5zCJLswwgiKr6NPrXpKxEBDDfi8AO0ULTZEPZG73NkESC/4kVBpZN5VRuS87tDc
# Cvop/aEZAWVGVufRYUpMfxtw8RxS2Og/ZWJlG52XFMXquom/qWcGWZ+Md0da+s06
# XoTJXaJBg2sVqNJ0rKEaizEa0ZIP5Km+wQsJef4GTDjrz6UAmSA2V+4Rsbdb1BUM
# pZKMpgs8Lo3VzvTgD9o+b3D8ZFgpj7VeKb4ItzpV4rp2O/q6TKlEukJA84gup8Hr
# X6bu9XaIyflyBOyK+uEZ2vBXFPTynCfBuzrxEjYYY6ryPVb6yB5mhrUEEx+g5pcu
# QMPTMrrd9S3wO4Rvkjh6CRI8ik3Hl9fVIkv1qFUCzT0026+Uot4oPvbw4oo7te9d
# IHhL+u4=
# SIG # End signature block
