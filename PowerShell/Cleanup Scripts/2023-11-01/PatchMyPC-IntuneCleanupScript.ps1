#Requires -Modules MSAL.ps

<#
.SYNOPSIS
    Clean Duplicate Intune Apps and Updates that may have been created due to an issue on November 1, 2023
.DESCRIPTION
    Clean Duplicate Intune Apps and Updates that may have been created due to an issue on November 1, 2023
.PARAMETER ClientId
    Specifies the Client ID (Application (Client) ID) of the Intune App Registration used to connect to Intune
.PARAMETER ClientSecret
    Specifies the Client Secret of the Intune App Registration used to connect to Intune
.PARAMETER TenantId
    Specifies the Tenant ID (Directory (tenant) ID) of the Intune App Registration used to connect to Intune
.EXAMPLE
    PatchMyPC-IntuneCleanupScript.ps1 -ClientId "GUID" -TenantId "GUID"
    Authenticates against Graph, Finds potential duplicate or specific troublesome apps, prompts for their removal, and removes the duplicate Intune Apps and Updates after confirmation.
.NOTES
    The Patch My PC Publisher will not recreate assignments that are not set via right-click options 
    after this tool deletes applications, document any application assignments before running this tool.

    ################# DISCLAIMER #################
    Patch My PC provides scripts, macro, and other code examples for illustration only, without warranty 
    either expressed or implied, including but not limited to the implied warranties of merchantability 
    and/or fitness for a particular purpose. This script is provided 'AS IS' and Patch My PC does not 
    guarantee that the following script, macro, or code can or should be used in any situation or that 
    operation of the code will be error-free.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ClientId,

    [Parameter(Mandatory = $true)]
    [string]$ClientSecret,

    [Parameter(Mandatory = $true)]
    [string]$TenantId
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

$secret = ConvertTo-SecureString -String $ClientSecret -AsPlainText -Force
#endregion

#region functions
function Show-WelcomeScreen {
    [OutputType([string])]
    Param()
    $welcomeScreen = "ICAgICAgICAgICAgX19fX19fICBfXyAgICBfXyAgIF9fX19fXyAgX19fX19fICAgIA0KICAgICAgICAgICAvXCAgPT0gXC9cICItLi8gIFwgL1wgID09IFwvXCAgX19fXCAgIA0KICAgICAgICAgICBcIFwgIF8tL1wgXCBcLS4vXCBcXCBcICBfLS9cIFwgXF9fX18gIA0KICAgICAgICAgICAgXCBcX1wgICBcIFxfXCBcIFxfXFwgXF9cICAgXCBcX19fX19cIA0KICAgICAgICAgICAgIFwvXy8gICAgXC9fLyAgXC9fLyBcL18vICAgIFwvX19fX18vIA0KIF9fX19fXyAgIF9fICAgICAgIF9fX19fXyAgIF9fX19fXyAgIF9fICAgX18gICBfXyAgX18gICBfX19fX18gIA0KL1wgIF9fX1wgL1wgXCAgICAgL1wgIF9fX1wgL1wgIF9fIFwgL1wgIi0uXCBcIC9cIFwvXCBcIC9cICA9PSBcIA0KXCBcIFxfX19fXCBcIFxfX19fXCBcICBfX1wgXCBcICBfXyBcXCBcIFwtLiAgXFwgXCBcX1wgXFwgXCAgXy0vIA0KIFwgXF9fX19fXFwgXF9fX19fXFwgXF9fX19fXFwgXF9cIFxfXFwgXF9cXCJcX1xcIFxfX19fX1xcIFxfXCAgIA0KICBcL19fX19fLyBcL19fX19fLyBcL19fX19fLyBcL18vXC9fLyBcL18vIFwvXy8gXC9fX19fXy8gXC9fLyAgIA0K"
    Return $([system.text.encoding]::UTF8.GetString([system.convert]::FromBase64String($welcomeScreen)))
}

function Get-AuthToken {
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ClientId,

        [Parameter(Mandatory = $true)]
        [string]$TenantId
    )
    try {
            $auth = Get-MsalToken -ClientId $ClientId -Tenant $TenantId -ClientSecret $secret
        return $auth
    }
    catch {
        throw $_.Exception.Message
    }
}

function Get-AuthHeader {
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$AuthToken
    )
    try {
        $authHeader = @{
            'Authorization' = $AuthToken.CreateAuthorizationHeader()
        }
        return $authHeader
    }
    catch {
        throw $_.Exception.Message
    }
}

function Get-IntuneApplicationsToRemove {
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$AuthToken,

        [Parameter(Mandatory = $true)]
        [Array]$UpdateIds
    )
    $graphApiVersion = 'beta'
    $graphEndpoint = "deviceappmanagement/mobileapps?`$filter=isOf('microsoft.graph.win32LobApp')"
    $uri = "https://graph.microsoft.com/$graphApiVersion/$($graphEndpoint)"
    try {
        # Page through all apps in the tenant..
        $headers = Get-AuthHeader -AuthToken $AuthToken
        $restParams = @{
            Method      = 'Get'
            Uri         = $uri
            Headers     = $headers
            ContentType = 'Application/Json'
        }
        $query = Invoke-RestMethod @restParams
        $result = if ([String]::IsNullOrWhitespace($query.'@odata.nextLink')) {
            Write-Verbose "nextLink null on first response"
            Write-Verbose "`n$($query.value.Count) objects returned from Graph"
            $query.value
        }
        elseif ($query) {
            while ($query.'@odata.nextLink') {
                Write-Verbose "`n$($query.value.Count) objects returned from Graph"
                $query.value
                Write-Verbose "$($result.count) objects in result array"
                $nextParams = @{
                    Method      = 'Get'
                    Uri         = $query.'@odata.nextLink'
                    Headers     = $headers
                    ContentType = 'Application/Json'
                }
                $query = Invoke-RestMethod @nextParams
            }
            $query.value
            Write-Verbose "$($query.value.Count) objects returned from Graph"
            Write-Verbose "$($result.count) objects in result array"
        }
        $apps = $result | Select-Object id, displayName, notes
        # parse through the updateIds and select the apps we want to tear out.
        $appsToRemove = $apps | Where-Object { $_.notes -match "PmpAppId:($($UpdateIds -join '|'))|PmpUpdateId:($($UpdateIds -join '|'))" }
        return $appsToRemove
    }
    catch {
        throw $_.Exception.Message
    }
}

function Remove-IntuneApplications {
    [OutputType([System.Void])]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$AuthToken,

        [Parameter(Mandatory = $true)]
        [String[]]$AppIdsToRemove
    )
    $graphApiVersion = 'beta'
    $graphEndpoint = '$batch'
    $uri = "https://graph.microsoft.com/$graphApiVersion/$($graphEndpoint)"
    try {
        $appIds = $AppIdsToRemove
        $batchRequestBodies = New-GraphBatchRequests -AppIds $appIds

        foreach ($batch in $batchRequestBodies) {
            $headers = Get-AuthHeader -AuthToken $AuthToken
            $headers.'ConsistencyLevel' = "eventual"
            $requestParams = @{
                Method      = 'POST'
                Uri         = $uri
                Body        = $($batch | ConvertTo-Json -Depth 20 )
                headers     = $headers
                ContentType = 'Application/Json'
            }
            $batchResponse = Invoke-RestMethod @requestParams
            $batchResponse.responses | 
            Select-Object id, status, body | 
            ForEach-Object { Write-Verbose $($_ | ConvertTo-Json -Depth 20) }
        }
    }
    catch {
        throw $_.Exception.Message
    }
}

function New-GraphBatchRequests {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [String[]]
        $AppIds
    )

    $batchCount = 19
    $start = 0
    $end = $batchCount
    if ($end -gt $AppIds.count) { $end = $AppIds.Count }
    $batchBody = [System.Collections.Generic.List[PSCustomObject]]::new()
    while ($end -le $AppIds.Count -and $start -le $appIds.Count) {
        $list = [System.Collections.Generic.List[PSCustomObject]]::new()
        $i = 1
        Write-Verbose "Building batch $start - $end of $($AppIds.Count)"
        ($start..$end) | ForEach-Object {
            $list.Add([PSCustomObject]@{
                    id     = $i
                    method = "DELETE"
                    url    = "/deviceAppManagement/mobileApps/$($AppIds[$_])"
                })
            $i++
        }
        $batchBody.Add([PSCustomObject]@{
                requests = $list
                headers  = "application/json"
            })
        $end = $end + $batchCount
        if ($end -gt $AppIds.count) { $end = $AppIds.Count }
        $start = $start + $batchCount
    }
    return $batchBody
}
#endregion

#region process
try {
    Show-WelcomeScreen
    $authToken = Get-AuthToken -ClientId $ClientId -TenantId $TenantId
    $appsToRemove = Get-IntuneApplicationsToRemove -AuthToken $authToken -UpdateIds $updateIdsToClean
    $appsToRemove | Format-Table
    if ($appsToRemove.ImmediateBaseObject.Count -ge 1) {
        $cleanupToggle = Read-Host "The following Apps will be removed, Continue [y/N]"
        if ($cleanupToggle -eq "y") {
            Remove-IntuneApplications -AuthToken $authToken -AppIdsToRemove $appsToRemove.id
        }
        else {
            Write-Host "No applications detected for cleanup!" -ForegroundColor Green
        }
    }
}
catch {
    Write-Warning $_.Exception.Message
}
#endregion

# SIG # Begin signature block
# MIIohwYJKoZIhvcNAQcCoIIoeDCCKHQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDyQXaRvYBZFsTT
# y55E/WrBRjfyzXvxxyK0Ca411He4kaCCIYowggWNMIIEdaADAgECAhAOmxiO+dAt
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
# uEbTbDJ8WC9nR2XlG3O2mflrLAZG70Ee8PBf4NvZrZCARK+AEEGKMIIHyTCCBbGg
# AwIBAgIQDMNw87U7UZ48Hv1za61jojANBgkqhkiG9w0BAQsFADBpMQswCQYDVQQG
# EwJVUzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4xQTA/BgNVBAMTOERpZ2lDZXJ0
# IFRydXN0ZWQgRzQgQ29kZSBTaWduaW5nIFJTQTQwOTYgU0hBMzg0IDIwMjEgQ0Ex
# MB4XDTIzMDQwNzAwMDAwMFoXDTI2MDQzMDIzNTk1OVowgdExEzARBgsrBgEEAYI3
# PAIBAxMCVVMxGTAXBgsrBgEEAYI3PAIBAhMIQ29sb3JhZG8xHTAbBgNVBA8MFFBy
# aXZhdGUgT3JnYW5pemF0aW9uMRQwEgYDVQQFEwsyMDEzMTYzODMyNzELMAkGA1UE
# BhMCVVMxETAPBgNVBAgTCENvbG9yYWRvMRQwEgYDVQQHEwtDYXN0bGUgUm9jazEZ
# MBcGA1UEChMQUGF0Y2ggTXkgUEMsIExMQzEZMBcGA1UEAxMQUGF0Y2ggTXkgUEMs
# IExMQzCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAKaQcs40YzBFv5HX
# QFPd04rKJ4uBdwvAZLKuULy+icZOpgs/Sy329Ng5ikhB5o1IdvE2cOT20sjs3qgb
# 4e+rqs7taTCe6RNLsDINsmcTlp4yxOfV80EZ08ld3o36GEgH0Vy1vrJXLTRKNULz
# V7gIzF/e3tO1Fab4IxKZNcBSXiv8ORqcgT9O7/RZoqyG87iU6Q/dKfC4WzvU396X
# J3FMZrI+s4CgV8p6pVNjijBjH7pmzoXynFtA0j6NH6tg4DmQvm+kfWXtWbDpPYhd
# Fz1gccJt1DjTrJetpIwBzDAS8NGA75HQhBmQ3gcnNDJLgylB3HyWOeXS+vxXR0Pi
# /W419cfn8zCFH0u2O4QFaZsT2HoIE/t9EhdAKdHoKwvVoCgwvlx3jjwFq5MnoB2o
# JiNmTGQyhiRvCaw6JACKUa43eJvlRKylEy4INDTOX5BeivJoTqCw0cCAd6ZuRh6g
# Rl8shIVfN78qunQqJZQkDimtQY5Sn33w+ee5/lFSxOxBg6iu7vCGPZ6QxJd6oVdR
# a8t87vJ4QVlsMQQRa400S7kqIX1HOnbR3hxgvcks8kBRMYtZ8g3Fz/WTCW5sWbEx
# Vpn6HC6DsRhosF/DBGYmIqQJz6odkCFCr7QcmpGjoZs4jRDegSC5utEusBYmvCfV
# xtud3R43WEdCRfHuD1OFDm5HoonnAgMBAAGjggICMIIB/jAfBgNVHSMEGDAWgBRo
# N+Drtjv4XxGG+/5hewiIZfROQjAdBgNVHQ4EFgQU3wgET0b7maQo7OF3wwGWm83h
# l+0wDgYDVR0PAQH/BAQDAgeAMBMGA1UdJQQMMAoGCCsGAQUFBwMDMIG1BgNVHR8E
# ga0wgaowU6BRoE+GTWh0dHA6Ly9jcmwzLmRpZ2ljZXJ0LmNvbS9EaWdpQ2VydFRy
# dXN0ZWRHNENvZGVTaWduaW5nUlNBNDA5NlNIQTM4NDIwMjFDQTEuY3JsMFOgUaBP
# hk1odHRwOi8vY3JsNC5kaWdpY2VydC5jb20vRGlnaUNlcnRUcnVzdGVkRzRDb2Rl
# U2lnbmluZ1JTQTQwOTZTSEEzODQyMDIxQ0ExLmNybDA9BgNVHSAENjA0MDIGBWeB
# DAEDMCkwJwYIKwYBBQUHAgEWG2h0dHA6Ly93d3cuZGlnaWNlcnQuY29tL0NQUzCB
# lAYIKwYBBQUHAQEEgYcwgYQwJAYIKwYBBQUHMAGGGGh0dHA6Ly9vY3NwLmRpZ2lj
# ZXJ0LmNvbTBcBggrBgEFBQcwAoZQaHR0cDovL2NhY2VydHMuZGlnaWNlcnQuY29t
# L0RpZ2lDZXJ0VHJ1c3RlZEc0Q29kZVNpZ25pbmdSU0E0MDk2U0hBMzg0MjAyMUNB
# MS5jcnQwCQYDVR0TBAIwADANBgkqhkiG9w0BAQsFAAOCAgEADaIfBgYBzz7rZspA
# w5OGKL7nt4eo6SMcS91NAex1HWxak4hX7yqQB25Oa66WaVBtd14rZxptoGQ88FDe
# zI1qyUs4bwi4NaW9WBY8QDnGGhgyZ3aT3ZEBEvMWy6MFpzlyvjPBcWE5OGuoRMhP
# 42TSMhvFlZGCPZy02PLUdGcTynL55YhdTcGJnX0Z2OgSaHUQTmXhgRX+fajIilPn
# mmv8Av4Clr6Xa9SoNHltA04JRiCu4ejDGFqA94F696jSJ+AUYHys6bnPc0E8JB9Y
# nFCAurPRG8YBJAofUtxnGIHGE0EiQTZeXf0nKmVBIXkE3hT4mZx7pH7wrlCr0FV4
# qnq6j0uaj4oKqFbkdyzb5u+XQe9pPojshnjVzhIRK53wsGaFP4gSURxWvcThIOyo
# aKrVDZOdLQZXEz8Anks3Vs5XscjyzFR7pv/3Reik7FaZRTvd5rDW6foDJOiCwX5p
# +UnldHGHW83rDvtks1rwgKwuuxvCG3Bkjirl94EImpiugGaRQ7S2Lydxpqzv7Hng
# 4YQbIIvVMNC7mNrVZPNWdF4/a9yjDt2nJrnRcDK1zvHBXSrAYIycQ6hhhlHS9Y4M
# Rhz35t1du/Y0IXDB7HBYSvcsrpxtBzXLTd2NCNCtdkwYIl7WTQeoCbZWvo4PbzJB
# OnPjs1tN4upe9XomxtZkNAwIOfMxggZTMIIGTwIBATB9MGkxCzAJBgNVBAYTAlVT
# MRcwFQYDVQQKEw5EaWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1
# c3RlZCBHNCBDb2RlIFNpZ25pbmcgUlNBNDA5NiBTSEEzODQgMjAyMSBDQTECEAzD
# cPO1O1GePB79c2utY6IwDQYJYIZIAWUDBAIBBQCggYQwGAYKKwYBBAGCNwIBDDEK
# MAigAoAAoQKAADAZBgkqhkiG9w0BCQMxDAYKKwYBBAGCNwIBBDAcBgorBgEEAYI3
# AgELMQ4wDAYKKwYBBAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgbbUJlwMhekPxdOqG
# vo5gAjKIYut+PKZQcDrQdrElf9QwDQYJKoZIhvcNAQEBBQAEggIAWcRzIFRy96Yh
# z4pOEp8tWsn6mpGFmPPDs9HPTSXsbEEr/loWj1DaSQMvXKSAcXseZuMT8TSK4wJf
# 95vOfqlyvFAFUuegcP8iTxS4VRbghgM3U99SE+4MwH0f4uLLsWLGL3JM7zZ7j8Qz
# wMFBxamaDkbJewWJMIKMFgwCraIIlmz6P81N1UawwwUlcQqd0gLlTJ3HIC4gRO5s
# yuiWs+Kdq/O47KLytpamnAUi8ACsI3qyFiVM7S7ylP9AuL/W0pIxtM6Rec/ofSfA
# xh1VickeQJtYdxsK87Rhw5IoiOYACfk7J28tRDIn3V/IfX8m8r8sy6spS//FWQTF
# dp3MJyXE9+oCw8TjVGjHeygNEu/9HZ9+oFQG4pQifevmOGAD+ThibvTYP0xc9/5E
# wvAf57sTYCZDZR0sw/XKPt1bo4JxgB/w9iT7BN4QlUc5vKyZMA2Cq3lkvrXnAAHA
# o1VsA7JPyzY1qH2Bk2jGDNjJJtWgwBHGvv70Rzs2ADiRRmvbJMKneQO2d870YOaV
# jJd2fp6HTDAf9OT7AoL66WS9WymkxxjrXxaQTsT9xJRcF00a9ULKM6RF7lDqBAqF
# S36iLWUgl1Ipk+3Yoo+STmGXynSlqb0Crl/YsCSk4+tocAjW2T7qWVIdvaueKkoV
# h6mQRnNPps8aWjBqQtk5AGO6tjYHP4yhggMgMIIDHAYJKoZIhvcNAQkGMYIDDTCC
# AwkCAQEwdzBjMQswCQYDVQQGEwJVUzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4x
# OzA5BgNVBAMTMkRpZ2lDZXJ0IFRydXN0ZWQgRzQgUlNBNDA5NiBTSEEyNTYgVGlt
# ZVN0YW1waW5nIENBAhAFRK/zlJ0IOaa/2z9f5WEWMA0GCWCGSAFlAwQCAQUAoGkw
# GAYJKoZIhvcNAQkDMQsGCSqGSIb3DQEHATAcBgkqhkiG9w0BCQUxDxcNMjMxMTA0
# MDIzOTIzWjAvBgkqhkiG9w0BCQQxIgQgcw1YPBJ2fD/d61knIvyQ1IOkybWggVLw
# ewW5yPxgIMcwDQYJKoZIhvcNAQEBBQAEggIAnGYnGERaCNAf3XMUVpEDH9/1fBZP
# GeWyIcZUAcPlthkks4FV7ihRRKw6hs1Vrf2Z69D7WikwIGMgngFLCh4myOAu8f6m
# l8MNcgT4b+B9bwgo0dTfUIJ4oPaA6CGJn9kIQJokbYGQkYfWQP/Xc25gLd6q+lB7
# oBUe5OPzamLTVf4oCYzcv+VFhor2TParOeBuFLxsWo/xZsUe8MP+at3uz8CXGml6
# wH3cg9QDafCufjm7YZhV1tzZ0U6Q2GZjJ/MUJJ2QMyeG0U2QUEUps7JDmo/HBXFZ
# oiSrClr7qN8ubqV+dG+32uYLT+t+wMdOYwOvTUigowjnWoLByhIdtVHicYZPQWH/
# U7ZfH6f3knaKhRlRIt3XOBr3LU9K+OSCJz4834CLnlXtS6cDLkqrFMvuN6x1Tdcy
# IvbMlTMaYMs1wB/712NpZBbdIsiEzG9aQ5TBvtRqjYeqOz+BBKcTT01vXzfpFMbO
# //JINVXd9LgklkG7nTruPA/EuYSrVh1I7jFVRUuqSJt6N39mPBEp8HNWq4uVWVer
# DL3uoeyPiiDiob/eVw3ik/3SeQnXmJhhViT1Pn0OXG6g7B9Q+2Yy9GG8Bbw+ZN1y
# M160MKV6+oieBadZR/n6m0rzsbrLrKChe0PcJ0mgj8e2me4oaHuM0/O76Ode8lzl
# WIB/WNRRM3S5duY=
# SIG # End signature block
