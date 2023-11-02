<#
.SYNOPSIS
    Clean Duplicate ConfigMgr Apps that may have been created due to an issue on October 2, 2023
.DESCRIPTION
    Clean Duplicate ConfigMgr Apps that may have been created due to an issue on October 2, 2023
.PARAMETER SiteCode
    Specifies the ConfigMgr Site Code to connect to for clean up
.PARAMETER ProviderMachineName
    Specifies the Primary Site Server machine name of FQDN to connect to for clean up
.EXAMPLE
    PatchMyPC-IntuneCleanupScript.ps1 -SiteCode "CM1" -ProviderMachineName "Primary.CONTOSO.LOCAL"
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
		[array]$UpdateIds
	)
	# Get the list of Applications in ConfigMgr
	$configMgrApps = Get-CMApplication -Fast | Where-Object { $_.LocalizedDescription -like "Created by Patch My PC Version *" }
	
	$appsToRemove = [System.Collections.Generic.List[PSCustomObject]]::new()
	foreach ($configMgrApp in $configMgrApps) {
		try {
			$appInfo = Get-CMDeploymentType -Application $configMgrApp
			$appLocation = ([xml]$appInfo.SDMPackageXML).AppMgmtDigest.DeploymentType.Installer.Contents.Content.Location
			if ((Split-Path $appLocation -Leaf) -in $UpdateIds) {
				Write-Verbose "Found App $($configMgrApp.LocalizedDisplayName) to Remove"
				$appsToRemove.Add($configMgrApp)
			}
		}
		catch {
			Write-Warning "Unable to get App Info for $($configMgrApp.LocalizedDisplayName) - $($_.Exception.Message)"
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
	Set-ConfigMgrSiteDrive -SiteCode $SiteCode -ProviderMachineName $ProviderMachineName
	$appsToRemove = Get-ApplicationsToRemove -UpdateIds $updateIdsToClean
	$appsToRemove | Select-Object LocalizedDisplayName, LocalizedDescription, DateCreated | Format-Table
	if ($appsToRemove.Count -ge 1) {
		$cleanupToggle = Read-Host "The following Apps will be removed, Continue [y/N]"
		if ($cleanupToggle -eq "y") {
			Remove-Applications -AppsToRemove $appsToRemove
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
#endregion
# SIG # Begin signature block
# MIIovgYJKoZIhvcNAQcCoIIorzCCKKsCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDyDmkYAqcJyEr2
# qiuPbpjCDTy+T7eRZ+IjcnUB++7dPKCCIcEwggWNMIIEdaADAgECAhAOmxiO+dAt
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
# Vzu0nAPthkX0tGFuv2jiJmCG6sivqf6UHedjGzqGVnhOMIIGwjCCBKqgAwIBAgIQ
# BUSv85SdCDmmv9s/X+VhFjANBgkqhkiG9w0BAQsFADBjMQswCQYDVQQGEwJVUzEX
# MBUGA1UEChMORGlnaUNlcnQsIEluYy4xOzA5BgNVBAMTMkRpZ2lDZXJ0IFRydXN0
# ZWQgRzQgUlNBNDA5NiBTSEEyNTYgVGltZVN0YW1waW5nIENBMB4XDTIzMDcxNDAw
# MDAwMFoXDTM0MTAxMzIzNTk1OVowSDELMAkGA1UEBhMCVVMxFzAVBgNVBAoTDkRp
# Z2lDZXJ0LCBJbmMuMSAwHgYDVQQDExdEaWdpQ2VydCBUaW1lc3RhbXAgMjAyMzCC
# AiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAKNTRYcdg45brD5UsyPgz5/X
# 5dLnXaEOCdwvSKOXejsqnGfcYhVYwamTEafNqrJq3RApih5iY2nTWJw1cb86l+uU
# UI8cIOrHmjsvlmbjaedp/lvD1isgHMGXlLSlUIHyz8sHpjBoyoNC2vx/CSSUpIIa
# 2mq62DvKXd4ZGIX7ReoNYWyd/nFexAaaPPDFLnkPG2ZS48jWPl/aQ9OE9dDH9kgt
# XkV1lnX+3RChG4PBuOZSlbVH13gpOWvgeFmX40QrStWVzu8IF+qCZE3/I+PKhu60
# pCFkcOvV5aDaY7Mu6QXuqvYk9R28mxyyt1/f8O52fTGZZUdVnUokL6wrl76f5P17
# cz4y7lI0+9S769SgLDSb495uZBkHNwGRDxy1Uc2qTGaDiGhiu7xBG3gZbeTZD+BY
# QfvYsSzhUa+0rRUGFOpiCBPTaR58ZE2dD9/O0V6MqqtQFcmzyrzXxDtoRKOlO0L9
# c33u3Qr/eTQQfqZcClhMAD6FaXXHg2TWdc2PEnZWpST618RrIbroHzSYLzrqawGw
# 9/sqhux7UjipmAmhcbJsca8+uG+W1eEQE/5hRwqM/vC2x9XH3mwk8L9CgsqgcT2c
# kpMEtGlwJw1Pt7U20clfCKRwo+wK8REuZODLIivK8SgTIUlRfgZm0zu++uuRONhR
# B8qUt+JQofM604qDy0B7AgMBAAGjggGLMIIBhzAOBgNVHQ8BAf8EBAMCB4AwDAYD
# VR0TAQH/BAIwADAWBgNVHSUBAf8EDDAKBggrBgEFBQcDCDAgBgNVHSAEGTAXMAgG
# BmeBDAEEAjALBglghkgBhv1sBwEwHwYDVR0jBBgwFoAUuhbZbU2FL3MpdpovdYxq
# II+eyG8wHQYDVR0OBBYEFKW27xPn783QZKHVVqllMaPe1eNJMFoGA1UdHwRTMFEw
# T6BNoEuGSWh0dHA6Ly9jcmwzLmRpZ2ljZXJ0LmNvbS9EaWdpQ2VydFRydXN0ZWRH
# NFJTQTQwOTZTSEEyNTZUaW1lU3RhbXBpbmdDQS5jcmwwgZAGCCsGAQUFBwEBBIGD
# MIGAMCQGCCsGAQUFBzABhhhodHRwOi8vb2NzcC5kaWdpY2VydC5jb20wWAYIKwYB
# BQUHMAKGTGh0dHA6Ly9jYWNlcnRzLmRpZ2ljZXJ0LmNvbS9EaWdpQ2VydFRydXN0
# ZWRHNFJTQTQwOTZTSEEyNTZUaW1lU3RhbXBpbmdDQS5jcnQwDQYJKoZIhvcNAQEL
# BQADggIBAIEa1t6gqbWYF7xwjU+KPGic2CX/yyzkzepdIpLsjCICqbjPgKjZ5+PF
# 7SaCinEvGN1Ott5s1+FgnCvt7T1IjrhrunxdvcJhN2hJd6PrkKoS1yeF844ektrC
# QDifXcigLiV4JZ0qBXqEKZi2V3mP2yZWK7Dzp703DNiYdk9WuVLCtp04qYHnbUFc
# jGnRuSvExnvPnPp44pMadqJpddNQ5EQSviANnqlE0PjlSXcIWiHFtM+YlRpUurm8
# wWkZus8W8oM3NG6wQSbd3lqXTzON1I13fXVFoaVYJmoDRd7ZULVQjK9WvUzF4UbF
# KNOt50MAcN7MmJ4ZiQPq1JE3701S88lgIcRWR+3aEUuMMsOI5ljitts++V+wQtaP
# 4xeR0arAVeOGv6wnLEHQmjNKqDbUuXKWfpd5OEhfysLcPTLfddY2Z1qJ+Panx+VP
# NTwAvb6cKmx5AdzaROY63jg7B145WPR8czFVoIARyxQMfq68/qTreWWqaNYiyjvr
# moI1VygWy2nyMpqy0tg6uLFGhmu6F/3Ed2wVbK6rr3M66ElGt9V/zLY4wNjsHPW2
# obhDLN9OTH0eaHDAdwrUAuBcYLso/zjlUlrWrBciI0707NMX+1Br/wd3H3GXREHJ
# uEbTbDJ8WC9nR2XlG3O2mflrLAZG70Ee8PBf4NvZrZCARK+AEEGKMIIIADCCBeig
# AwIBAgIQD0un28igrZOh2Z+6mD8+TTANBgkqhkiG9w0BAQsFADBpMQswCQYDVQQG
# EwJVUzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4xQTA/BgNVBAMTOERpZ2lDZXJ0
# IFRydXN0ZWQgRzQgQ29kZSBTaWduaW5nIFJTQTQwOTYgU0hBMzg0IDIwMjEgQ0Ex
# MB4XDTIyMDkxNTAwMDAwMFoXDTI1MDkxMDIzNTk1OVowgdExEzARBgsrBgEEAYI3
# PAIBAxMCVVMxGTAXBgsrBgEEAYI3PAIBAhMIQ29sb3JhZG8xHTAbBgNVBA8MFFBy
# aXZhdGUgT3JnYW5pemF0aW9uMRQwEgYDVQQFEwsyMDEzMTYzODMyNzELMAkGA1UE
# BhMCVVMxETAPBgNVBAgTCENvbG9yYWRvMRQwEgYDVQQHEwtDYXN0bGUgUm9jazEZ
# MBcGA1UEChMQUGF0Y2ggTXkgUEMsIExMQzEZMBcGA1UEAxMQUGF0Y2ggTXkgUEMs
# IExMQzCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAPKfoNjLgEqzlwL/
# aZLSldCkRTfZQ1jvb6ZMhZYoxUdNpzUEGNpbdTB9NNg9rQdZCvPDFYxhz00bOtwF
# dzzrO3V+4GxSPK7BBKkCASx5Oe9rVG9u0vmU2vCsnROMtczK8UBiERD+/W+FYN2A
# gQwdYaUsaPMT/QNlfVuhOEjFQXBYoCMMO/cNXUQLZkIwF4GacaGMh9TUSub8K9y8
# OMz5AQyjmfTxUrBLUzi0WJS1eDoTAeJ7BIrvT7+je+gEtYe9OpIz2gTJmYUykIUs
# Ix7A8OtTyp6j7tdMDahwyW1DXvUnFQHUViXisvajSiuCGePtet1lc+wyJizGF6Iv
# MBjw/xLk/38ZARs44iNFNVyEvga6L4pWOPp4Ul9VmFrqWTp8Pt4sppA7yE/1OjsY
# A0Xk0x3m6HiUiCUjwhY8eRhBCp5me+1SR8LHwhsS2TSO8rYkaFjctnRpjpwhqN2h
# Z/q7WIIhmZRoHxH0RPQrPJPHkdBes7OM7SVrZTts7IhREXR4PXeeCRDWiNIIb6pT
# mJiUGnrx7gy0ayilUOfEPbw0I2PSckBXfvqxxvnJGr+BZWYhIUC6/cHUhqwfFVN7
# tq8nYiAGSLLFhJT1vJWGZBVVNbpDC9joAbu9SvD48at2TrOf6iHpz/yhgC+iPhji
# oJRMOJK2Km0U0jC0dqtJhJNmfZeXAgMBAAGjggI5MIICNTAfBgNVHSMEGDAWgBRo
# N+Drtjv4XxGG+/5hewiIZfROQjAdBgNVHQ4EFgQUvTyL42xnOtRlK27xT25Ih8aM
# TPcwMgYDVR0RBCswKaAnBggrBgEFBQcIA6AbMBkMF1VTLUNPTE9SQURPLTIwMTMx
# NjM4MzI3MA4GA1UdDwEB/wQEAwIHgDATBgNVHSUEDDAKBggrBgEFBQcDAzCBtQYD
# VR0fBIGtMIGqMFOgUaBPhk1odHRwOi8vY3JsMy5kaWdpY2VydC5jb20vRGlnaUNl
# cnRUcnVzdGVkRzRDb2RlU2lnbmluZ1JTQTQwOTZTSEEzODQyMDIxQ0ExLmNybDBT
# oFGgT4ZNaHR0cDovL2NybDQuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0VHJ1c3RlZEc0
# Q29kZVNpZ25pbmdSU0E0MDk2U0hBMzg0MjAyMUNBMS5jcmwwPQYDVR0gBDYwNDAy
# BgVngQwBAzApMCcGCCsGAQUFBwIBFhtodHRwOi8vd3d3LmRpZ2ljZXJ0LmNvbS9D
# UFMwgZQGCCsGAQUFBwEBBIGHMIGEMCQGCCsGAQUFBzABhhhodHRwOi8vb2NzcC5k
# aWdpY2VydC5jb20wXAYIKwYBBQUHMAKGUGh0dHA6Ly9jYWNlcnRzLmRpZ2ljZXJ0
# LmNvbS9EaWdpQ2VydFRydXN0ZWRHNENvZGVTaWduaW5nUlNBNDA5NlNIQTM4NDIw
# MjFDQTEuY3J0MAwGA1UdEwEB/wQCMAAwDQYJKoZIhvcNAQELBQADggIBAFdPoh+i
# Ebsklh04Gal6DTgKSnw/5mO/k4oXMPKhmP/eYgTfvf2hwSewe9W2IK2/VH0HutUM
# k603cVtcyK1ppiDkR0MTshD7BVWHeAXJQmAjLQUr83vLh4WhPOZ2+R+GxWT3s1Ts
# /LFAF5qYHpd5+PhbLtSB/px50k0ouX/Dc/kYtKYN7/VBve01gkV+pbBsVRNvjv2T
# fAMTBDongJD3J5J+fy7PVZVGFvLpjZRtQjHeai6vM7Lwuh9o/dtPTQV7abeP8hmO
# xhQ9qRMXYSeoFkTw8+d/9/wPoQzBuwxN1gNSCRGEof4NamrcnUHtOCcrUWbKAE3r
# eqAtZPHFqiVBCwUCUADZ00mDtwZ7qEOUp71l/1K1j3rNLXGSkkONuHbIaZA3PsCq
# s0ltIE6/5Od8QfJRK2wkUu4vaumgQKJXKDinqMTXi4eTsjq1D6+qsp6vnc+O2xw3
# 6yzs8CUyolD14fRRDb2QNvHlWzuG/JgsRsm+HY7Yp8vIqVc73PFor6+Fe2BMnTCN
# bVkEV5Xi3dekkTYAV/sQxd8XlOBK+iHo/Ht4ggyzqhYjNfdXrD4Xh0zBsJfOIceO
# ZY2+mb3mPg5otvURSJS8EpIHWlRBalzzLJwwdY4yz9pU05L250wEY+iUyowJR5BD
# nvokCtKa07dYpdwxvYE1l5Iz6NBCEr4SMbvRMYIGUzCCBk8CAQEwfTBpMQswCQYD
# VQQGEwJVUzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4xQTA/BgNVBAMTOERpZ2lD
# ZXJ0IFRydXN0ZWQgRzQgQ29kZSBTaWduaW5nIFJTQTQwOTYgU0hBMzg0IDIwMjEg
# Q0ExAhAPS6fbyKCtk6HZn7qYPz5NMA0GCWCGSAFlAwQCAQUAoIGEMBgGCisGAQQB
# gjcCAQwxCjAIoAKAAKECgAAwGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwHAYK
# KwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEICtiD9b1
# ILptwfElBEv1C0h9xCmF/Wduoidkmy0F7W+nMA0GCSqGSIb3DQEBAQUABIICAMW7
# 6GzssKNxwGFBopzsS+qztzHvuot/X635xnmAnzSEm3V9SK+hdlK4mfIgHcRad9k0
# ZFQnHdHlUrxw/pBGTmnuC9rhY0hJxhT711oj+UFVYOV3qLfXRBAm0SuEtVxjIrDs
# RRyjjurFF0NaLMw8019N8yQEMdGCq9JMpXX8/HSsIdHZLITkJtCMUyHPpL5PIsbP
# j1REGA8fKesq3dW9fLU/vdaVBGQ6k83C/v9MvMYxXTp6jdaZXjtLfJ8MID8xHsiA
# 5EAStmINpt43WgRep9LQEJ4dbmKEzGFW9maAUh9sOgBwaen5rBqfbywdnqkQkTQ5
# S4zqTXagmVBTjOj8SUj1BD1buGgsVefjKFTR44A63EsI86WD+wDbrXhpYh3o1oJz
# BUuP277eA0FOzB2EjkQYcr7BI4cmnBgR5z9+kfwu/cqJPtOT0XpMDn0L3+84Y8mX
# 1xLTYPMeRshMKubsPGVL+a9aUq2bKc7AjuIPVfpR07FJ2K8NDg/0ElyNTlpzgAKg
# mcFZj2URQn32Gdz8JjGK1FdBxo+3bGrytIcbnbelokG5kSgYY/9emDBH/PSl8qmW
# 66bSkRRSVUk8KdC2riPBNjhhlxmhUkawUzATEDPI6RYMODaEPOkye/LGUPqS/oob
# +FdaC0YldV9BlJj4FUqMqVnRUsz42bdi2INTZ3AzoYIDIDCCAxwGCSqGSIb3DQEJ
# BjGCAw0wggMJAgEBMHcwYzELMAkGA1UEBhMCVVMxFzAVBgNVBAoTDkRpZ2lDZXJ0
# LCBJbmMuMTswOQYDVQQDEzJEaWdpQ2VydCBUcnVzdGVkIEc0IFJTQTQwOTYgU0hB
# MjU2IFRpbWVTdGFtcGluZyBDQQIQBUSv85SdCDmmv9s/X+VhFjANBglghkgBZQME
# AgEFAKBpMBgGCSqGSIb3DQEJAzELBgkqhkiG9w0BBwEwHAYJKoZIhvcNAQkFMQ8X
# DTIzMTEwMjE4MDAzMVowLwYJKoZIhvcNAQkEMSIEIK9llve6XlitwH2Ne4zT/csY
# cy1LXKlS14+bx6jfswcbMA0GCSqGSIb3DQEBAQUABIICAJzFfGC9uz3uKR+JoD0A
# 6bQbze2MMHKEjpGHSq9H8B0MLha6v278h37lEeFJwtJVpJc8hgorxrpfWIUCvMD0
# R+c80OhTSpx1lon5D7uqCRE9yHoQ8T7ITVLRbO1APFfyOkTLAv5fhHkhn8IuZLb3
# QjiTcqNU67A4Shl7mqY32DOka2shjtzYkA8MsxTop79UQtzc59OEk442/z0coEXf
# S3dOhnD6FpOY5mX17MIbQxvi4EAnA21vSow+ZU+YI01x7glb3YFDc0qcfmMcrs+7
# FXlod9PX4Rx2VYX69NRh+lA0mRV0dpfxx1Rk1ETOoI05hnjkoArNbz6usdG/FSOD
# qbb+Tfg2w5OldP5y4aRybDIIaiYZBzf8DZiDe/WSXAqTvZ7yx6XgUB9KOQzOJenh
# RHGV8Kpkn1sgveUqwwsMs5Q1W/IvOOILXcMHxwGB2k38J9nVe47Msjay2OGDZ/9s
# TiaSweoui7nKXPcWS9+t3USF+kySzJd6CLB/cTKI6IqwCCaDfnRYN5XDTV8KOb1e
# 7tnptD2ZzeqxSqlv66Z61C/FqHNB67lSCcvHg8klIKTaiW6d8JM/UhNiUI5ydxuV
# 8b6T99fXnVKUaCAjW6tmmyyLiksBq8G3PaegHYq3wEwaVubbXSQy/cfRdLczwWSS
# 1WFH2sg/erNZHAwc1+b22bEx
# SIG # End signature block
