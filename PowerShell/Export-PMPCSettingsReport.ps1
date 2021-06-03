<#
.SYNOPSIS
Export a report of configured Settings from the Patch My PC Publisher
.DESCRIPTION
This script exports a csv file containing information about product selections and right click
options configured in the Patch My PC Publisher.

.EXAMPLE
C:\PS>  Export-PMPCSettingsReport.ps1
	Exports Patch My PC Publisher Settings to a CSV file named 'PatchPMyPCSettings.csv' in the script directory

.NOTES
################# DISCLAIMER #################
Patch My PC provides scripts, macro, and other code examples for illustration only, without warranty 
either expressed or implied, including but not limited to the implied warranties of merchantability 
and/or fitness for a particular purpose. This script is provided 'AS IS' and Patch My PC does not 
guarantee that the following script, macro, or code can or should be used in any situation or that 
operation of the code will be error-free.
#>

[xml]$settingsxml = Get-Content "$(Get-ItemPropertyValue "HKLM:\SOFTWARE\Patch My PC Publishing Service\" -Name Path)Settings.xml"

$IntuneApps = $settingsxml.'PatchMyPC-Settings'.Intune.Applications.SearchPattern
$IntuneUpdates = $settingsxml.'PatchMyPC-Settings'.Intune.Updates.SearchPattern
$ConfigMgrUpdates = $settingsxml.'PatchMyPC-Settings'.SearchPatterns.SearchPattern
$ConfigMgrApps = $settingsxml.'PatchMyPC-Settings'.Packages.SearchPattern

$ConfigMgrUpdates | Select-Object @{Name = "Type"; Expression = { "ConfigMgr Update" } }, Vendor, Product, @{Name = "Conflicting Process"; Expression = { if ([System.String]::IsNullOrEmpty($_.BlockingProcessManagementPolicy)) {
			"False"
		}
		else {
			$_.BlockingProcessManagementPolicy.Policy
		} }
}, @{Name = "EnableLogging"; Expression = { if ([System.String]::IsNullOrEmpty($_.EnableLogging)) {
			"False"
		}
		else {
			"True"
		} }
}, @{Name = "VerboseLogging"; Expression = { if ([System.String]::IsNullOrEmpty($_.VerboseLogging)) {
			"False"
		}
		else {
			"True"
		} }
}, LoggingFolder, @{Name = "Disable Auto-Update"; Expression = { if ([System.String]::IsNullOrEmpty($_.SelfUpdater)) {
			"False"
		}
		else {
			"True"
		} }
}, @{Name = "Delete Desktop Shortcut"; Expression = { if ([System.String]::IsNullOrEmpty($_.ShortcutFileName)) {
			"False"
		}
		else {
			"True"
		} }
}, PreCommand, PostCommand | Export-Csv -Path .\PatchPMyPCSettings.csv -NoTypeInformation -Force
$ConfigMgrApps | Select-Object @{Name = "Type"; Expression = { "ConfigMgr App" } }, Vendor, Product, @{Name = "Conflicting Process"; Expression = { if ([System.String]::IsNullOrEmpty($_.BlockingProcessManagementPolicy)) {
			"False"
		}
		else {
			$_.BlockingProcessManagementPolicy.Policy
		} }
}, @{Name = "EnableLogging"; Expression = { if ([System.String]::IsNullOrEmpty($_.EnableLogging)) {
			"False"
		}
		else {
			"True"
		} }
}, @{Name = "VerboseLogging"; Expression = { if ([System.String]::IsNullOrEmpty($_.VerboseLogging)) {
			"False"
		}
		else {
			"True"
		} }
}, LoggingFolder, @{Name = "Disable Auto-Update"; Expression = { if ([System.String]::IsNullOrEmpty($_.SelfUpdater)) {
			"False"
		}
		else {
			"True"
		} }
}, @{Name = "Delete Desktop Shortcut"; Expression = { if ([System.String]::IsNullOrEmpty($_.ShortcutFileName)) {
			"False"
		}
		else {
			"True"
		} }
}, PreCommand, PostCommand | Export-Csv -Path .\PatchPMyPCSettings.csv -NoTypeInformation -Append -Force
$IntuneUpdates | Select-Object @{Name = "Type"; Expression = { "Intune Update" } }, Vendor, Product, @{Name = "Conflicting Process"; Expression = { if ([System.String]::IsNullOrEmpty($_.BlockingProcessManagementPolicy)) {
			"False"
		}
		else {
			$_.BlockingProcessManagementPolicy.Policy
		} }
}, @{Name = "EnableLogging"; Expression = { if ([System.String]::IsNullOrEmpty($_.EnableLogging)) {
			"False"
		}
		else {
			"True"
		} }
}, @{Name = "VerboseLogging"; Expression = { if ([System.String]::IsNullOrEmpty($_.VerboseLogging)) {
			"False"
		}
		else {
			"True"
		} }
}, LoggingFolder, @{Name = "Disable Auto-Update"; Expression = { if ([System.String]::IsNullOrEmpty($_.SelfUpdater)) {
			"False"
		}
		else {
			"True"
		} }
}, @{Name = "Delete Desktop Shortcut"; Expression = { if ([System.String]::IsNullOrEmpty($_.ShortcutFileName)) {
			"False"
		}
		else {
			"True"
		} }
}, PreCommand, PostCommand | Export-Csv -Path .\PatchPMyPCSettings.csv -NoTypeInformation -Append -Force
$IntuneApps | Select-Object @{Name = "Type"; Expression = { "Intune App" } }, Vendor, Product, @{Name = "Conflicting Process"; Expression = { if ([System.String]::IsNullOrEmpty($_.BlockingProcessManagementPolicy)) {
			"False"
		}
		else {
			$_.BlockingProcessManagementPolicy.Policy
		} }
}, @{Name = "EnableLogging"; Expression = { if ([System.String]::IsNullOrEmpty($_.EnableLogging)) {
			"False"
		}
		else {
			"True"
		} }
}, @{Name = "VerboseLogging"; Expression = { if ([System.String]::IsNullOrEmpty($_.VerboseLogging)) {
			"False"
		}
		else {
			"True"
		} }
}, LoggingFolder, @{Name = "Disable Auto-Update"; Expression = { if ([System.String]::IsNullOrEmpty($_.SelfUpdater)) {
			"False"
		}
		else {
			"True"
		} }
}, @{Name = "Delete Desktop Shortcut"; Expression = { if ([System.String]::IsNullOrEmpty($_.ShortcutFileName)) {
			"False"
		}
		else {
			"True"
		} }
}, PreCommand, PostCommand | Export-Csv -Path .\PatchPMyPCSettings.csv -NoTypeInformation -Append -Force