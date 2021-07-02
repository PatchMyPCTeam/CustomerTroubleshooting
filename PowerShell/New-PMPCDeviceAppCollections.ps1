<#
.SYNOPSIS
Creates ConfigMgr Device Collections based on Applications selected in Patch My PC
.DESCRIPTION
This script creates ConfigMgr Device Collections based on Applications selected in the Patch My PC Publisher.
One collection will be created per Application using a query membership rule the devices targeted by the rule
will have the associated application installed. Additionally, an option is provided to create collection where
the specified application is not installed.
.EXAMPLE
C:\PS>  New-PMPCDeviceAppCollections.ps1
	Creates device collection based on selected applications in Patch My PC
.NOTES
################# DISCLAIMER #################
Patch My PC provides scripts, macro, and other code examples for illustration only, without warranty 
either expressed or implied, including but not limited to the implied warranties of merchantability 
and/or fitness for a particular purpose. This script is provided 'AS IS' and Patch My PC does not 
guarantee that the following script, macro, or code can or should be used in any situation or that 
operation of the code will be error-free.
#>

# Script Configuration
$SiteCode = "" # Site code 
$ProviderMachineName = "" # SMS Provider machine name
$LimitingCollection = "All Systems" #Limiting Collection for all Collections created by this script
$AddExcludeCollections = $false #Also create collections for devices where the application is NOT installed

# Import the ConfigurationManager.psd1 module 
if ($null -eq (Get-Module ConfigurationManager)) {
	Import-Module "$($ENV:SMS_ADMIN_UI_PATH)\..\ConfigurationManager.psd1" @initParams 
}

# Connect to the site's drive if it is not already present
if ($null -eq (Get-PSDrive -Name $SiteCode -PSProvider CMSite -ErrorAction SilentlyContinue)) {
	New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $ProviderMachineName @initParams
}

# Set the current location to be the site code.
Set-Location "$($SiteCode):\"

[xml]$settingsxml = Get-Content "$(Get-ItemPropertyValue "HKLM:\SOFTWARE\Patch My PC Publishing Service\" -Name Path)Settings.xml"
$ConfigMgrApps = $settingsxml.'PatchMyPC-Settings'.Packages.SearchPattern


$ConfigMgrApps | ForEach-Object { 
	Write-Host "`n$($_.Product)`n"
	try {
	$NewCollection = New-CMDeviceCollection -Name "Devices With $($_.product) installed" -LimitingCollectionName $LimitingCollection -ErrorAction Stop
	} catch {
		Write-Host "ERROR: Failed to create Collection for $($_.product)"
		Break
	}

	# Look in the 64 bit installed programs if 64 bit
	if ($_.SQLSearchTarget -eq "Target64bit") {
		$arch = "_64"
	} else {
		$arch = ""
	}

	if (([System.String]::IsNullOrEmpty($_.SQLSearchExclude))) {
		$SQLSearchExclude = ""
	} else {
		$SQLSearchExclude = " and SMS_G_System_ADD_REMOVE_PROGRAMS$arch.DisplayName not like `"$($_.SQLSearchExclude)`""
	}

	if (([System.String]::IsNullOrEmpty($_.SQLSearchExclude))) {
		$SqlSearchVersionInclude = ""
	}
	else {
		$SqlSearchVersionInclude = " and SMS_G_System_ADD_REMOVE_PROGRAMS$arch.Version like `"$($_.SQLSeachVersionInclude)`""
	}
	
	$Query = @"
select SMS_R_System.ResourceId, SMS_R_System.ResourceType, SMS_R_System.Name, SMS_R_System.SMSUniqueIdentifier, SMS_R_System.ResourceDomainORWorkgroup, SMS_R_System.Client from SMS_R_System inner join SMS_G_System_ADD_REMOVE_PROGRAMS$arch on SMS_G_System_ADD_REMOVE_PROGRAMS$arch.ResourceId = SMS_R_System.ResourceId where SMS_G_System_ADD_REMOVE_PROGRAMS$arch.DisplayName like "$($_.SQLSearchInclude)"$SQLSearchExclude$SQLSearchVersionInclude
"@
	Add-CMDeviceCollectionQueryMembershipRule -InputObject $NewCollection -QueryExpression $query -RuleName $_.Product

	if ($AddExcludeCollections) {
		$ExcludeCollection = New-CMDeviceCollection -Name "Devices with $($_.Product) NOT installed" -LimitingCollectionName $LimitingCollection
		Add-CMDeviceCollectionIncludeMembershipRule -InputObject $ExcludeCollection -includeCollectionName $LimitingCollection
		Add-CMDeviceCollectionExcludeMembershipRule -InputObject $ExcludeCollection -ExcludeCollection $NewCollection
	}
}