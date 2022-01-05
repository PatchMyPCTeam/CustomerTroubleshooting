<#
.SYNOPSIS
    Enable or Disable WSUS client (Windows Update Agent) trace logging.
.DESCRIPTION
    This function can be used to enable or disable WSUS client (Windows Update Agent) trace logging. This is useful when you need to debug a problem with the WSUS client.
.PARAMETER TraceLogging
    This parameter sets the trace logging state. It can be either Enabled or Disabled.
.EXAMPLE
    C:\PS> Enable-WSUSClientTraceLogging -TraceLogging Enabled
        Enables WSUS trace logging.
.EXAMPLE
    C:\PS> Enable-WSUSClientTraceLogging -TraceLogging Disabled
        Disables WSUS trace logging. 
.NOTES
    This script makes modifications to the registry. Modifying REGISTRY settings incorrectly can cause serious problems that may prevent your computer from booting properly. 
    Patch My PC cannot guarantee that any problems resulting from the configuring of REGISTRY settings can be solved. Modifications of these settings are at your own risk.
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $false)]
    [ValidateSet('Enabled', 'Disabled')]
    [string]$TraceLogging = 'Enabled'
)
begin {
    $rootWUPath = 'registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate'
    $tracePath = "$rootWUPath\Trace"
    $restartService = $true
}
process {
    switch ($TraceLogging) {
        Enabled {
            if (-not (Test-Path $tracePath)) {
                $null = New-Item -Path $rootWUPath -Name Trace -ItemType Directory
            }
            Set-ItemProperty -Path $tracePath -Name Flags -Value 7 -Force
            Set-ItemProperty -Path $tracePath -Name Level -Value 4 -Force
        }
        Disabled {
            if (Test-Path $tracePath) {
                Remove-Item -Path $tracePath -Recurse -Force
            }
            else {
                Write-Warning 'Trace logging is already disabled'
                $restartService = $false
            }
        }
    }
}
end {
    if ($restartService) {
        Restart-Service -Name wuauserv
        Write-Host "Trace logging is now $TraceLogging"
    }
}