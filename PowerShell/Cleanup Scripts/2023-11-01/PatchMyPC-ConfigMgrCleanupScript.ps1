<#
.SYNOPSIS
    Clean Duplicate ConfigMgr Apps that may have been created due to an issue on November 1, 2023
.DESCRIPTION
    Clean Duplicate ConfigMgr Apps that may have been created due to an issue on November 1, 2023
.PARAMETER SiteCode
    Specifies the ConfigMgr Site Code to connect to for clean up
.PARAMETER ProviderMachineName
    Specifies the Primary Site Server machine name of FQDN to connect to for clean up
.EXAMPLE
    PatchMyPC-ConfigMgrCleanupScript.ps1 -SiteCode "CM1" -ProviderMachineName "Primary.CONTOSO.LOCAL"
    Connects to ConfigMgr, Finds potential duplicate apps, prompts for their removal, and removes the duplicate ConfigMgr Apps after confirmation.
.NOTES
    ################# DISCLAIMER #################
    Patch My PC provides scripts, macro, and other code examples for illustration only, without warranty 
    either expressed or implied, including but not limited to the implied warranties of merchantability 
    and/or fitness for a particular purpose. This script is provided 'AS IS' and Patch My PC does not 
    guarantee that the following script, macro, or code can or should be used in any situation or that 
    operation of the code will be error-free.
#>

[CmdletBinding()]
param (
	[Parameter(Mandatory)]
	[String]
	$SiteCode,
	[Parameter(Mandatory)]
	[String]
	$ProviderMachineName
)
#region config
$updateIdsToClean = @(
	'94cb6508-da2e-443e-84ca-99cb953b81d5',
	'f4581441-2ac2-478e-b4d2-5d381005844b',
	'8c8722b9-6c27-490a-ac8e-8687fa10b595',
	'ddda82fb-5bed-4129-8766-6ba3fbd5b5eb',
	'61034b70-cc96-4585-8e3c-07bfc63c1237',
	'b1613c43-554b-44bd-88b6-c0275cbcbeb4',
	'2c612f53-e8bc-4c9d-9245-8bbfc31197bc',
	'176dc696-0648-44b1-94ce-f30eaa129447',
	'59f4656c-99b1-4a9f-ba7c-4a266ae20869',
	'19828a30-2161-4411-bd64-6980bd041251',
	'b0311a4d-ff77-46f1-82a1-d6a30c8de1e1',
	'703e9887-03e1-4849-91f0-1138ca5c83a6',
	'e042976d-9e9c-41bf-8263-e33f86a980a6',
	'd94ae903-ff6f-432a-9c53-7af6012039ac',
	'fa08b747-c9ea-4b8f-8ec1-0884f45cc8ea',
	'c0310cf6-6f5a-4a67-a2a7-204b5465b60f',
	'4e60286c-a7ad-4bfa-b76b-235673f71869',
	'18c73441-cd2f-4afe-bf5a-4368dbcdc9e5',
	'd5ad9180-e20f-4d9b-957b-e1b619d2f1dd',
	'641c0c63-6fee-4433-8d85-61c295b2df52',
	'a5c70459-a873-46b6-813d-3ebd9e4b308e',
	'0ed446a6-a56b-4d4f-b60c-c7f18738d690',
	'db7664ca-b6d5-4a57-b5fb-ed07733ed1bf',
	'cd931cd1-4280-479f-8bb9-2e1b9dea30b6',
	'14b65ac2-715a-4e16-baf3-f8fa3103a0b2',
	'e2f0f78e-569c-4684-9ab5-de1cca4aaf0e',
	'dc2ef9c4-8381-42fc-9daf-cf2943df13e1',
	'b8b775d0-e85b-4582-a18f-9b6a4f7259d2',
	'369764e1-1c8d-4506-9a44-327dd7513a71',
	'83372cb0-1d83-4f0c-8cb0-31fc12a16215',
	'8e23d77c-d5ae-4919-9bbe-3acebcdcc36c',
	'50249d3d-cc08-47f9-98ea-ae3be62b83d3',
	'c2a1801f-f65f-43ee-b602-060101fdab0a',
	'65be955d-0bef-4371-9f78-8de5eee79bbe',
	'6d4f24c3-20d2-4efc-b1f7-e2f811e225b3',
	'bac48cc1-27dd-4c3d-ae4e-993ec513b538',
	'f9ac4063-218b-4df2-af31-d12dceb04e32',
	'b8000e4c-4b68-44a7-9b07-c05708cfd8a9',
	'd572b26a-cbf4-4154-bafd-64b3264331e3',
	'1c53ebd3-66c0-411e-9510-6ea1eac5ab4b'
)
#endregion

#region functions
function Set-ConfigMgrSiteDrive {
	[OutputType([System.Void])]
	param (
		[Parameter(Mandatory)]
		[String]
		$SiteCode,
		[Parameter(Mandatory)]
		[String]
		$ProviderMachineName
	)
	try {
		# Import the ConfigurationManager.psd1 module 
		if ($null -eq (Get-Module ConfigurationManager)) {
			Import-Module "$($ENV:SMS_ADMIN_UI_PATH)\..\ConfigurationManager.psd1"
		}

		# Connect to the site's drive if it is not already present
		if ($null -eq (Get-PSDrive -Name $SiteCode -PSProvider CMSite -ErrorAction SilentlyContinue)) {
			New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $ProviderMachineName
		}

		# Set the current location to be the site code.
		Push-Location
		Set-Location "$($SiteCode):\"
	}
	catch {
		throw $_.Exception.Message
	}
	
}

function Get-ApplicationsToRemove {
	[OutputType([System.Collections.Generic.List[PSCustomObject]])]
	param (
		[Parameter(Mandatory)]
		[String]$SiteCode,

		[Parameter(Mandatory)]
		[String]$ProviderMachineName,
	
		[Parameter(Mandatory)]
		[array]$UpdateIds
	)

	$CommonParams = @{
		ComputerName = $ProviderMachineName
		Namespace	 = 'root\SMS\site_{0}' -f $SiteCode
		ErrorAction  = 'Stop'
	}

	$appsToRemove = foreach ($UpdateId in $UpdateIds) {
		$Query      = "SELECT ContentSource, ContentUniqueID FROM SMS_Content WHERE ContentSource LIKE '%{0}%'" -f $UpdateId
		$SMSContent = Get-CimInstance -Query $Query @CommonParams

		foreach ($_SMSContent in $SMSContent) {
			$Query 			= "SELECT AppModelName, ContentId, IsLatest FROM SMS_DeploymentType WHERE ContentId = '{0}'" -f $_SMSContent.ContentUniqueID
			$DeploymentType = Get-CimInstance -Query $Query @CommonParams
			
			if (-not [String]::IsNullOrWhiteSpace($DeploymentType) -and $DeploymentType.IsLatest) {
				Get-CMApplication -ModelName $DeploymentType.AppModelName -Fast -ErrorAction 'Stop'
			}
		}
	}
	
	return $appsToRemove
}

function Remove-Applications {
	[OutputType([System.Void])]
	param (
		[Parameter(Mandatory)]
		[Array]$AppsToRemove
	)
	foreach ($appToRemove in $AppsToRemove) {
		try {
			if ($appToRemove.NumberOfDeployments -eq 0) {

				$AppInfo = Get-CMDeploymentType -Application $appToRemove
				$AppLocation = ([xml]$AppInfo.SDMPackageXML).AppMgmtDigest.DeploymentType.Installer.Contents.Content.Location
				# Delete the application from ConfigMgr
				$appToRemove | Remove-CMApplication -force
				
				# Delete the application content from the filesystem
				$AppLocation = Resolve-Path Filesystem::$AppLocation
				if (Test-Path $AppLocation -ErrorAction SilentlyContinue) {
					Write-Host "Removing Content for $($appToRemove.LocalizedDisplayName) at $AppLocation" -ForegroundColor Cyan
					Remove-Item $AppLocation -Recurse
				}
				else {
					Write-Host "Unable to find content location $AppLocation skipping content location deletion" -ForegroundColor Red
				}
			}
			else {
				Write-Host "Skipping removal of $($appToRemove.LocalizedDisplayname) as it has deployments" -ForegroundColor Yellow
			}
		}
		catch {
			Write-Warning "Unable to remove $($appToRemove.LocalizedDisplayName) - $($_.Exception.Message)"
		}
	}
}

function Get-AppTSandDeploymentsInfo {
	[OutputType([System.Collections.ArrayList])]
	param(
		[Parameter(Mandatory)]
		# IResultObject#SMS_Application
		[PSObject[]]$appsToRemove
	)

    ## Get all task sequences
    $TaskSequenceNames = (Get-CMTaskSequence -Fast).Name

    foreach ($appToRemove in $appsToRemove) {
    
        $localizedDisplayName = $appToRemove.LocalizedDisplayName
        $applicationCI_UniqueID = $appToRemove.CI_UniqueID
        ## need to remove the revision number in the CI_UniqueID as the TS is not going to reference the app Revision number
        $lastSlashIndex = $applicationCI_UniqueID.LastIndexOf('/')
        $applicationCI_UniqueID = $applicationCI_UniqueID.Substring(0, $lastSlashIndex)

        ###############################################
        ## Check if the app has active deployments
        ###############################################
        $deployments = Get-CMApplicationDeployment -Name $localizedDisplayName | Select-Object ApplicationName, CollectionName
        if ($null -ne $deployments)	{
            $activeDeployments = foreach ($deployment in $deployments) {
                [PSCustomObject]@{
                    ApplicationName = $deployment.ApplicationName
                    Collection      = $deployment.CollectionName        
                }
            }
        }

        ########################################################
        ## Check if the app is referenced in a Task Sequence
        ########################################################
        [array]$tsInfo = foreach ($taskSequenceName in $TaskSequenceNames) {
            # Check if the application CI_UniqueID is referenced in the task sequence
            [array]$references = (Get-CMTaskSequence -WarningAction SilentlyContinue | Where-Object { $_.Name -eq $taskSequenceName }).References.Package
            if ($null -ne $references) {            
                foreach ($reference in $references) {
                    if ($reference -eq $applicationCI_UniqueID) {
                        [array]$steps = Get-CMTaskSequenceStep -TaskSequenceName $taskSequenceName | Where-Object { $_.SmsProviderObjectPath -eq "SMS_TaskSequence_InstallApplicationAction" }
                        foreach ($step in $steps) {
                            if ($step.ApplicationName -like "*$applicationCI_UniqueID*") {
                                #Write-Host ("Task Sequence Name: {0}." -f $taskSequenceName) -BackgroundColor Red
                                #Write-Host ("Step Name: {0}" -f $step.Name)
                                #Write-Host "Please remove the application from the Task Sequence first, before deleting it. You will have to re-add it to the TS after the app is recreated"
                                [PSCustomObject]@{
                                    TaskSequenceName = $taskSequenceName
                                    TaskSequenceStep = $step.Name
                                }
                            }
                        }
                    }
                }
            }
        }

        #######################################################################
        ## Check if the app has any deployments or is referenced in any TS
        #######################################################################
        if ($activeDeployments.Count -gt 0){
            #Write-host ("The application {0} has the following active deployments. Please delete them first and re-run this script." -f $localizedDisplayName) -BackgroundColor Red
            #$activeDeployments | Format-Table -AutoSize
            $hasActiveDeployments = $true
        }
        if ($tsInfo.Count -gt 0){
            #Write-host ("The application {0} is referenced in the following task sequences. Please remove these first and re-run this script." -f $localizedDisplayName) -BackgroundColor Red
            #$tsInfo | Format-Table -AutoSize
            $hasTaskSequenceReferences = $true
        }
    }

    # Check if either $hasActiveDeployments or $hasTaskSequenceReferences is true
    $result = $hasActiveDeployments -or $hasTaskSequenceReferences
    #return $AppTSandDeploymentsInfoResult
    # Return results
    [PSCustomObject]@{
        AppTSandDeploymentsInfoResult = $result
        ActiveDeployments = $activeDeployments
        TSInfo = $tsInfo
        ApplicationName = $localizedDisplayName
    }
}

function Show-WelcomeScreen {
	[OutputType([string])]
	Param()
	$welcomeScreen = "ICAgICAgICAgICAgX19fX19fICBfXyAgICBfXyAgIF9fX19fXyAgX19fX19fICAgIA0KICAgICAgICAgICAvXCAgPT0gXC9cICItLi8gIFwgL1wgID09IFwvXCAgX19fXCAgIA0KICAgICAgICAgICBcIFwgIF8tL1wgXCBcLS4vXCBcXCBcICBfLS9cIFwgXF9fX18gIA0KICAgICAgICAgICAgXCBcX1wgICBcIFxfXCBcIFxfXFwgXF9cICAgXCBcX19fX19cIA0KICAgICAgICAgICAgIFwvXy8gICAgXC9fLyAgXC9fLyBcL18vICAgIFwvX19fX18vIA0KIF9fX19fXyAgIF9fICAgICAgIF9fX19fXyAgIF9fX19fXyAgIF9fICAgX18gICBfXyAgX18gICBfX19fX18gIA0KL1wgIF9fX1wgL1wgXCAgICAgL1wgIF9fX1wgL1wgIF9fIFwgL1wgIi0uXCBcIC9cIFwvXCBcIC9cICA9PSBcIA0KXCBcIFxfX19fXCBcIFxfX19fXCBcICBfX1wgXCBcICBfXyBcXCBcIFwtLiAgXFwgXCBcX1wgXFwgXCAgXy0vIA0KIFwgXF9fX19fXFwgXF9fX19fXFwgXF9fX19fXFwgXF9cIFxfXFwgXF9cXCJcX1xcIFxfX19fX1xcIFxfXCAgIA0KICBcL19fX19fLyBcL19fX19fLyBcL19fX19fLyBcL18vXC9fLyBcL18vIFwvXy8gXC9fX19fXy8gXC9fLyAgIA0K"
	Return $([system.text.encoding]::UTF8.GetString([system.convert]::FromBase64String($welcomeScreen)))
}
#endregion

#region Process
try {
	Show-WelcomeScreen

	Write-Host "`n########## IMPORTANT ##########" -ForegroundColor Cyan
	Write-Host "`nWarning: Applications that require cleanup, that are deployed, will not be deleted by this script.`nAction: Please document and delete existing deployments for affected applications before continuing." -ForegroundColor Yellow
	Write-Host "`nWarning: Applications that require cleanup, that are referenced by a Task Sequence, will not be deleted by this script.`nAction: Please document existing Task Sequences before removing the application from the Task Sequence step and continuing." -ForegroundColor Yellow
	Write-Host "`nWarning: After following the advice above, and before agreeing to delete the following applications, please be mindful that Patch My PC Publisher will not re-create deployments or add applications back to Task Sequence steps." -ForegroundColor Yellow
	Write-Host "Action: Ensure existing application deployments and Task Sequence reference have been recorded before continuing." -ForegroundColor Yellow
	Write-Host "`n###############################" -ForegroundColor Cyan


	Set-ConfigMgrSiteDrive -SiteCode $SiteCode -ProviderMachineName $ProviderMachineName
	$appsToRemove = Get-ApplicationsToRemove -UpdateIds $updateIdsToClean -SiteCode $SiteCode -ProviderMachineName $ProviderMachineName
	$appsToRemove | Select-Object LocalizedDisplayName, LocalizedDescription, DateCreated | Format-Table
	if ($appsToRemove.Count -ge 1) {

        $TSDeploymentsCheck = Get-AppTSandDeploymentsInfo -appsToRemove $appsToRemove

        if ($TSDeploymentsCheck.AppTSandDeploymentsInfoResult) {
            # There are active deployments or task sequence references
            $activeDeployments = $TSDeploymentsCheck.ActiveDeployments
            $tsInfo = $TSDeploymentsCheck.TSInfo
            $localizedDisplayName = $TSDeploymentsCheck.ApplicationName

            if ($activeDeployments.Count -gt 0) {
                Write-host ("The application {0} has the following active deployments. Please delete them first and re-run this script." -f $localizedDisplayName) -BackgroundColor Red
                $activeDeployments | Format-Table -AutoSize
            }

            if ($tsInfo.Count -gt 0) {
                Write-host ("The application {0} is referenced in the following task sequences. Please remove these first and re-run this script." -f $localizedDisplayName) -BackgroundColor Red
                $tsInfo | Format-Table -AutoSize
            }
    
        } else {
            # No active deployments or task sequence references
            $cleanupToggle = Read-Host "The following Apps will be removed, Continue [y/N]"
		    if ($cleanupToggle -eq "y") {
			    Remove-Applications -AppsToRemove $appsToRemove
		    }
        }
	}
	else {
		Write-Host "No applications detected for cleanup!" -ForegroundColor Green
	}
}
catch {
	Write-Warning $_.Exception.Message
}
finally {
	Pop-Location
}
