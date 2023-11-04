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
    Authenticates against Graph, Finds potential duplicate apps, prompts for their removal, and removes the duplicate Intune Apps and Updates after confirmation.
.NOTES
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

    Write-Host "`n########## IMPORTANT ##########" -ForegroundColor Cyan
    Write-Host "`nWarning: Applications that require cleanup will have assignments re-created that are configured in the Publisher only.`nAny assignments that have been manually added to the application(s), via the Intune Admin Centre, will need to be documented before continuing." -ForegroundColor Yellow
    Write-Host "`n###############################" -ForegroundColor Cyan
        
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