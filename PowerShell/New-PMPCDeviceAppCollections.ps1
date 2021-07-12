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
	Import-Module "$($ENV:SMS_ADMIN_UI_PATH)\..\ConfigurationManager.psd1"
}

# Connect to the site's drive if it is not already present
if ($null -eq (Get-PSDrive -Name $SiteCode -PSProvider CMSite -ErrorAction SilentlyContinue)) {
	New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $ProviderMachineName
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
# SIG # Begin signature block
# MIIbzAYJKoZIhvcNAQcCoIIbvTCCG7kCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCA61ql21ZfrnVkw
# 4i47x9ssomLsfbJzn5s7IlYWlIdRqaCCFrswggT+MIID5qADAgECAhANQkrgvjqI
# /2BAIc4UAPDdMA0GCSqGSIb3DQEBCwUAMHIxCzAJBgNVBAYTAlVTMRUwEwYDVQQK
# EwxEaWdpQ2VydCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xMTAvBgNV
# BAMTKERpZ2lDZXJ0IFNIQTIgQXNzdXJlZCBJRCBUaW1lc3RhbXBpbmcgQ0EwHhcN
# MjEwMTAxMDAwMDAwWhcNMzEwMTA2MDAwMDAwWjBIMQswCQYDVQQGEwJVUzEXMBUG
# A1UEChMORGlnaUNlcnQsIEluYy4xIDAeBgNVBAMTF0RpZ2lDZXJ0IFRpbWVzdGFt
# cCAyMDIxMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAwuZhhGfFivUN
# CKRFymNrUdc6EUK9CnV1TZS0DFC1JhD+HchvkWsMlucaXEjvROW/m2HNFZFiWrj/
# ZwucY/02aoH6KfjdK3CF3gIY83htvH35x20JPb5qdofpir34hF0edsnkxnZ2OlPR
# 0dNaNo/Go+EvGzq3YdZz7E5tM4p8XUUtS7FQ5kE6N1aG3JMjjfdQJehk5t3Tjy9X
# tYcg6w6OLNUj2vRNeEbjA4MxKUpcDDGKSoyIxfcwWvkUrxVfbENJCf0mI1P2jWPo
# GqtbsR0wwptpgrTb/FZUvB+hh6u+elsKIC9LCcmVp42y+tZji06lchzun3oBc/gZ
# 1v4NSYS9AQIDAQABo4IBuDCCAbQwDgYDVR0PAQH/BAQDAgeAMAwGA1UdEwEB/wQC
# MAAwFgYDVR0lAQH/BAwwCgYIKwYBBQUHAwgwQQYDVR0gBDowODA2BglghkgBhv1s
# BwEwKTAnBggrBgEFBQcCARYbaHR0cDovL3d3dy5kaWdpY2VydC5jb20vQ1BTMB8G
# A1UdIwQYMBaAFPS24SAd/imu0uRhpbKiJbLIFzVuMB0GA1UdDgQWBBQ2RIaOpLqw
# Zr68KC0dRDbd42p6vDBxBgNVHR8EajBoMDKgMKAuhixodHRwOi8vY3JsMy5kaWdp
# Y2VydC5jb20vc2hhMi1hc3N1cmVkLXRzLmNybDAyoDCgLoYsaHR0cDovL2NybDQu
# ZGlnaWNlcnQuY29tL3NoYTItYXNzdXJlZC10cy5jcmwwgYUGCCsGAQUFBwEBBHkw
# dzAkBggrBgEFBQcwAYYYaHR0cDovL29jc3AuZGlnaWNlcnQuY29tME8GCCsGAQUF
# BzAChkNodHRwOi8vY2FjZXJ0cy5kaWdpY2VydC5jb20vRGlnaUNlcnRTSEEyQXNz
# dXJlZElEVGltZXN0YW1waW5nQ0EuY3J0MA0GCSqGSIb3DQEBCwUAA4IBAQBIHNy1
# 6ZojvOca5yAOjmdG/UJyUXQKI0ejq5LSJcRwWb4UoOUngaVNFBUZB3nw0QTDhtk7
# vf5EAmZN7WmkD/a4cM9i6PVRSnh5Nnont/PnUp+Tp+1DnnvntN1BIon7h6JGA078
# 9P63ZHdjXyNSaYOC+hpT7ZDMjaEXcw3082U5cEvznNZ6e9oMvD0y0BvL9WH8dQgA
# dryBDvjA4VzPxBFy5xtkSdgimnUVQvUtMjiB2vRgorq0Uvtc4GEkJU+y38kpqHND
# Udq9Y9YfW5v3LhtPEx33Sg1xfpe39D+E68Hjo0mh+s6nv1bPull2YYlffqe0jmd4
# +TaY4cso2luHpoovMIIFMTCCBBmgAwIBAgIQCqEl1tYyG35B5AXaNpfCFTANBgkq
# hkiG9w0BAQsFADBlMQswCQYDVQQGEwJVUzEVMBMGA1UEChMMRGlnaUNlcnQgSW5j
# MRkwFwYDVQQLExB3d3cuZGlnaWNlcnQuY29tMSQwIgYDVQQDExtEaWdpQ2VydCBB
# c3N1cmVkIElEIFJvb3QgQ0EwHhcNMTYwMTA3MTIwMDAwWhcNMzEwMTA3MTIwMDAw
# WjByMQswCQYDVQQGEwJVUzEVMBMGA1UEChMMRGlnaUNlcnQgSW5jMRkwFwYDVQQL
# ExB3d3cuZGlnaWNlcnQuY29tMTEwLwYDVQQDEyhEaWdpQ2VydCBTSEEyIEFzc3Vy
# ZWQgSUQgVGltZXN0YW1waW5nIENBMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIB
# CgKCAQEAvdAy7kvNj3/dqbqCmcU5VChXtiNKxA4HRTNREH3Q+X1NaH7ntqD0jbOI
# 5Je/YyGQmL8TvFfTw+F+CNZqFAA49y4eO+7MpvYyWf5fZT/gm+vjRkcGGlV+Cyd+
# wKL1oODeIj8O/36V+/OjuiI+GKwR5PCZA207hXwJ0+5dyJoLVOOoCXFr4M8iEA91
# z3FyTgqt30A6XLdR4aF5FMZNJCMwXbzsPGBqrC8HzP3w6kfZiFBe/WZuVmEnKYmE
# UeaC50ZQ/ZQqLKfkdT66mA+Ef58xFNat1fJky3seBdCEGXIX8RcG7z3N1k3vBkL9
# olMqT4UdxB08r8/arBD13ays6Vb/kwIDAQABo4IBzjCCAcowHQYDVR0OBBYEFPS2
# 4SAd/imu0uRhpbKiJbLIFzVuMB8GA1UdIwQYMBaAFEXroq/0ksuCMS1Ri6enIZ3z
# bcgPMBIGA1UdEwEB/wQIMAYBAf8CAQAwDgYDVR0PAQH/BAQDAgGGMBMGA1UdJQQM
# MAoGCCsGAQUFBwMIMHkGCCsGAQUFBwEBBG0wazAkBggrBgEFBQcwAYYYaHR0cDov
# L29jc3AuZGlnaWNlcnQuY29tMEMGCCsGAQUFBzAChjdodHRwOi8vY2FjZXJ0cy5k
# aWdpY2VydC5jb20vRGlnaUNlcnRBc3N1cmVkSURSb290Q0EuY3J0MIGBBgNVHR8E
# ejB4MDqgOKA2hjRodHRwOi8vY3JsNC5kaWdpY2VydC5jb20vRGlnaUNlcnRBc3N1
# cmVkSURSb290Q0EuY3JsMDqgOKA2hjRodHRwOi8vY3JsMy5kaWdpY2VydC5jb20v
# RGlnaUNlcnRBc3N1cmVkSURSb290Q0EuY3JsMFAGA1UdIARJMEcwOAYKYIZIAYb9
# bAACBDAqMCgGCCsGAQUFBwIBFhxodHRwczovL3d3dy5kaWdpY2VydC5jb20vQ1BT
# MAsGCWCGSAGG/WwHATANBgkqhkiG9w0BAQsFAAOCAQEAcZUS6VGHVmnN793afKpj
# erN4zwY3QITvS4S/ys8DAv3Fp8MOIEIsr3fzKx8MIVoqtwU0HWqumfgnoma/Capg
# 33akOpMP+LLR2HwZYuhegiUexLoceywh4tZbLBQ1QwRostt1AuByx5jWPGTlH0gQ
# GF+JOGFNYkYkh2OMkVIsrymJ5Xgf1gsUpYDXEkdws3XVk4WTfraSZ/tTYYmo9WuW
# wPRYaQ18yAGxuSh1t5ljhSKMYcp5lH5Z/IwP42+1ASa2bKXuh1Eh5Fhgm7oMLStt
# osR+u8QlK0cCCHxJrhO24XxCQijGGFbPQTS2Zl22dHv1VjMiLyI2skuiSpXY9aaO
# UjCCBcAwggSooAMCAQICEApHfTxoon07kw0cOj1ukTgwDQYJKoZIhvcNAQELBQAw
# bDELMAkGA1UEBhMCVVMxFTATBgNVBAoTDERpZ2lDZXJ0IEluYzEZMBcGA1UECxMQ
# d3d3LmRpZ2ljZXJ0LmNvbTErMCkGA1UEAxMiRGlnaUNlcnQgRVYgQ29kZSBTaWdu
# aW5nIENBIChTSEEyKTAeFw0yMDA0MTcwMDAwMDBaFw0yMzA0MjYxMjAwMDBaMIHS
# MRMwEQYLKwYBBAGCNzwCAQMTAlVTMRkwFwYLKwYBBAGCNzwCAQITCENvbG9yYWRv
# MR0wGwYDVQQPDBRQcml2YXRlIE9yZ2FuaXphdGlvbjEUMBIGA1UEBRMLMjAxMzE2
# MzgzMjcxCzAJBgNVBAYTAlVTMREwDwYDVQQIEwhDb2xvcmFkbzEVMBMGA1UEBxMM
# Q2FzdGxlIFBpbmVzMRkwFwYDVQQKExBQYXRjaCBNeSBQQywgTExDMRkwFwYDVQQD
# ExBQYXRjaCBNeSBQQywgTExDMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKC
# AQEAmd7+0WfKQHcPYBw7O7rhrJDFqbIM4LaK/46AUGar6b8JJGUmfiUrOxk8rvKS
# 5dE4SNE8HjLgdAJDzpnbExHY2O3Dtayvjitjv4CfL0PgOdq9f1jYYS5WJUEKbf+f
# xFOWx7M0gTTI0+93k3kGum8oAE8PG+Y031Kj4ecL/mJhk1HWsO3Cvubo1bEMhAuf
# AXG9jFmSKKFB0dQ7RMwgB6Qt8HFOrjqXb7lXY+MTa8CxD4P+UMt18nafxdZqogLL
# PKacSghSn5N/bDlUcoxT2CmLhAnQ6rOpJbLbv5jjCiNPAuStn28k5m121LiqrRFX
# Ve5ybgfuaEOauPZfu0cScVJx4wIDAQABo4IB9TCCAfEwHwYDVR0jBBgwFoAUj+h+
# 8G0yagAFI8dwl2o6kP9r6tQwHQYDVR0OBBYEFKKVn8bCllsgv0Osfpb8DaZG8KLu
# MDIGA1UdEQQrMCmgJwYIKwYBBQUHCAOgGzAZDBdVUy1DT0xPUkFETy0yMDEzMTYz
# ODMyNzAOBgNVHQ8BAf8EBAMCB4AwEwYDVR0lBAwwCgYIKwYBBQUHAwMwewYDVR0f
# BHQwcjA3oDWgM4YxaHR0cDovL2NybDMuZGlnaWNlcnQuY29tL0VWQ29kZVNpZ25p
# bmdTSEEyLWcxLmNybDA3oDWgM4YxaHR0cDovL2NybDQuZGlnaWNlcnQuY29tL0VW
# Q29kZVNpZ25pbmdTSEEyLWcxLmNybDBLBgNVHSAERDBCMDcGCWCGSAGG/WwDAjAq
# MCgGCCsGAQUFBwIBFhxodHRwczovL3d3dy5kaWdpY2VydC5jb20vQ1BTMAcGBWeB
# DAEDMH4GCCsGAQUFBwEBBHIwcDAkBggrBgEFBQcwAYYYaHR0cDovL29jc3AuZGln
# aWNlcnQuY29tMEgGCCsGAQUFBzAChjxodHRwOi8vY2FjZXJ0cy5kaWdpY2VydC5j
# b20vRGlnaUNlcnRFVkNvZGVTaWduaW5nQ0EtU0hBMi5jcnQwDAYDVR0TAQH/BAIw
# ADANBgkqhkiG9w0BAQsFAAOCAQEAXu096fMsb1mSYB6Z/GVcam7ANYgIgLPykmf3
# sTlGzFdiHfpfSvGuhsTubdG3AuJawzdd6j6rbMf1qp0gGU8D9tve22JwWhIAUM8x
# Ut7BqhmxKpNDQzySJ62aCcq9uvh0mVsG2LDkK3D3uZPsIRD8N1DBaaCYe8INkUUz
# uq28o2yPcEL7Dwtjfj6MO/o6tQYjPWtb8xJyuFIG2NYdkeRMH1yuFCoByRBgfcwX
# kTGWbcl8MbHw4Dev3vd71zaB2T7EzXwMMPC6SG5hjnnZ9EHiYzdwTnQElMskPrAe
# 4Zn2vjKaP05jI5fHoSsacschFGr/WZS6UoGfC2UScPLUmLlBkzCCBrwwggWkoAMC
# AQICEAPxtOFfOoLxFJZ4s9fYR1wwDQYJKoZIhvcNAQELBQAwbDELMAkGA1UEBhMC
# VVMxFTATBgNVBAoTDERpZ2lDZXJ0IEluYzEZMBcGA1UECxMQd3d3LmRpZ2ljZXJ0
# LmNvbTErMCkGA1UEAxMiRGlnaUNlcnQgSGlnaCBBc3N1cmFuY2UgRVYgUm9vdCBD
# QTAeFw0xMjA0MTgxMjAwMDBaFw0yNzA0MTgxMjAwMDBaMGwxCzAJBgNVBAYTAlVT
# MRUwEwYDVQQKEwxEaWdpQ2VydCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5j
# b20xKzApBgNVBAMTIkRpZ2lDZXJ0IEVWIENvZGUgU2lnbmluZyBDQSAoU0hBMikw
# ggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQCnU/oPsrUT8WTPhID8roA1
# 0bbXx6MsrBosrPGErDo1EjqSkbpX5MTJ8y+oSDy31m7clyK6UXlhr0MvDbebtEkx
# rkRYPqShlqeHTyN+w2xlJJBVPqHKI3zFQunEemJFm33eY3TLnmMl+ISamq1FT659
# H8gTy3WbyeHhivgLDJj0yj7QRap6HqVYkzY0visuKzFYZrQyEJ+d8FKh7+g+03by
# QFrc+mo9G0utdrCMXO42uoPqMKhM3vELKlhBiK4AiasD0RaCICJ2615UOBJi4dJw
# JNvtH3DSZAmALeK2nc4f8rsh82zb2LMZe4pQn+/sNgpcmrdK0wigOXn93b89Ogkl
# AgMBAAGjggNYMIIDVDASBgNVHRMBAf8ECDAGAQH/AgEAMA4GA1UdDwEB/wQEAwIB
# hjATBgNVHSUEDDAKBggrBgEFBQcDAzB/BggrBgEFBQcBAQRzMHEwJAYIKwYBBQUH
# MAGGGGh0dHA6Ly9vY3NwLmRpZ2ljZXJ0LmNvbTBJBggrBgEFBQcwAoY9aHR0cDov
# L2NhY2VydHMuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0SGlnaEFzc3VyYW5jZUVWUm9v
# dENBLmNydDCBjwYDVR0fBIGHMIGEMECgPqA8hjpodHRwOi8vY3JsMy5kaWdpY2Vy
# dC5jb20vRGlnaUNlcnRIaWdoQXNzdXJhbmNlRVZSb290Q0EuY3JsMECgPqA8hjpo
# dHRwOi8vY3JsNC5kaWdpY2VydC5jb20vRGlnaUNlcnRIaWdoQXNzdXJhbmNlRVZS
# b290Q0EuY3JsMIIBxAYDVR0gBIIBuzCCAbcwggGzBglghkgBhv1sAwIwggGkMDoG
# CCsGAQUFBwIBFi5odHRwOi8vd3d3LmRpZ2ljZXJ0LmNvbS9zc2wtY3BzLXJlcG9z
# aXRvcnkuaHRtMIIBZAYIKwYBBQUHAgIwggFWHoIBUgBBAG4AeQAgAHUAcwBlACAA
# bwBmACAAdABoAGkAcwAgAEMAZQByAHQAaQBmAGkAYwBhAHQAZQAgAGMAbwBuAHMA
# dABpAHQAdQB0AGUAcwAgAGEAYwBjAGUAcAB0AGEAbgBjAGUAIABvAGYAIAB0AGgA
# ZQAgAEQAaQBnAGkAQwBlAHIAdAAgAEMAUAAvAEMAUABTACAAYQBuAGQAIAB0AGgA
# ZQAgAFIAZQBsAHkAaQBuAGcAIABQAGEAcgB0AHkAIABBAGcAcgBlAGUAbQBlAG4A
# dAAgAHcAaABpAGMAaAAgAGwAaQBtAGkAdAAgAGwAaQBhAGIAaQBsAGkAdAB5ACAA
# YQBuAGQAIABhAHIAZQAgAGkAbgBjAG8AcgBwAG8AcgBhAHQAZQBkACAAaABlAHIA
# ZQBpAG4AIABiAHkAIAByAGUAZgBlAHIAZQBuAGMAZQAuMB0GA1UdDgQWBBSP6H7w
# bTJqAAUjx3CXajqQ/2vq1DAfBgNVHSMEGDAWgBSxPsNpA/i/RwHUmCYaCALvY2Qr
# wzANBgkqhkiG9w0BAQsFAAOCAQEAGTNKDIEzN9utNsnkyTq7tRsueqLi9ENCF56/
# TqFN4bHb6YHdnwHy5IjV6f4J/SHB7F2A0vDWwUPC/ncr2/nXkTPObNWyGTvmLtbJ
# k0+IQI7N4fV+8Q/GWVZy6OtqQb0c1UbVfEnKZjgVwb/gkXB3h9zJjTHJDCmiM+2N
# 4ofNiY0/G//V4BqXi3zabfuoxrI6Zmt7AbPN2KY07BIBq5VYpcRTV6hg5ucCEqC5
# I2SiTbt8gSVkIb7P7kIYQ5e7pTcGr03/JqVNYUvsRkG4Zc64eZ4IlguBjIo7j8eZ
# jKMqbphtXmHGlreKuWEtk7jrDgRD1/X+pvBi1JlqpcHB8GSUgDGCBGcwggRjAgEB
# MIGAMGwxCzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdpQ2VydCBJbmMxGTAXBgNV
# BAsTEHd3dy5kaWdpY2VydC5jb20xKzApBgNVBAMTIkRpZ2lDZXJ0IEVWIENvZGUg
# U2lnbmluZyBDQSAoU0hBMikCEApHfTxoon07kw0cOj1ukTgwDQYJYIZIAWUDBAIB
# BQCggYQwGAYKKwYBBAGCNwIBDDEKMAigAoAAoQKAADAZBgkqhkiG9w0BCQMxDAYK
# KwYBBAGCNwIBBDAcBgorBgEEAYI3AgELMQ4wDAYKKwYBBAGCNwIBFTAvBgkqhkiG
# 9w0BCQQxIgQgmw8h6z6z54Ex4M+bRIHBGOqeNSScidT74y4wMoOd65IwDQYJKoZI
# hvcNAQEBBQAEggEAHgJjaXbwHgb0/eNUEh8RViXc4Y/3fjF2zucFgWg/S+G5mYZ9
# Czjfj4+yD2tBBTo/eOiuGNvMYTQ/y25W4BCHH6S2PdItW+WipEp1nprtIrf258Zq
# YGu1HaI7pZ01m7HWZIvwylzXSFP07N4GqHVkyrfbwQqhk+5X9T1/YODZZ1Dw/96Y
# YiMHD0TlOzf78JNZ06ZTkLQMYLHDbv+dmHS4Kv78nXzliYMKRkK8KoUfXYTAFzv0
# 3TS9AVtsBT1m4UsGCuxwYpEMiMhwZj0vn3CIXQcCBDeMVVd2/jrsSa1OD+bqmVqL
# bZvs+5blHJ1ogG0Y+v4j9tmlXKsxSOvx0LtdXaGCAjAwggIsBgkqhkiG9w0BCQYx
# ggIdMIICGQIBATCBhjByMQswCQYDVQQGEwJVUzEVMBMGA1UEChMMRGlnaUNlcnQg
# SW5jMRkwFwYDVQQLExB3d3cuZGlnaWNlcnQuY29tMTEwLwYDVQQDEyhEaWdpQ2Vy
# dCBTSEEyIEFzc3VyZWQgSUQgVGltZXN0YW1waW5nIENBAhANQkrgvjqI/2BAIc4U
# APDdMA0GCWCGSAFlAwQCAQUAoGkwGAYJKoZIhvcNAQkDMQsGCSqGSIb3DQEHATAc
# BgkqhkiG9w0BCQUxDxcNMjEwNzEyMjAwNTQxWjAvBgkqhkiG9w0BCQQxIgQgeAlg
# 3ugLjkOZjY+L2nEbGAKj32tThABOZPL21pNddm4wDQYJKoZIhvcNAQEBBQAEggEA
# CUf2yrUKbxfhHzli++/L0GaoHjb6mS3Qy0q1PUsIXUdpzRL7ilnik/2XgFMggjYU
# ADBPslrkIN4c5Rr5vCkXYNlD1mPKh+fyJqZioTuQB10q8NR679CbOJwi0JOJv3gx
# x25AMxPE8VJH/UGSfLagmtEOzAb3MNxTPooY+5xrp6IIV+DUwIGMuW4hvfeUegiE
# mqklfZkliEp6l4FQ6DDkRzXGTHXMAPu2J7nK0Xa9JIDmmjwWIpHvxHiJgLjBr+jb
# MYC5dOnvPszbQNZM1t/yayhicj+2z7ohtPokjRQNfu9vDtjW09hXVOz0ffwt8YVi
# h3/dD4u4yhOgNdV6Zgvf4g==
# SIG # End signature block
