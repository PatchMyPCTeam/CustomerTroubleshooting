<#
.SYNOPSIS
    Identify dependency relationships between applications in Configuration Manager.
.DESCRIPTION
    Identify dependency relationships between applications in Configuration Manager.

    Dependency relationships are shown for all applications, not just Patch My PC-made apps. 
    It will show you, for each app, what its parent or child dependent application is. 
    If there are multiple dependencies, they will be comma-separated in the output.
    It will not indicate dependency group membership, prioriity within its group, nor whether the Auto Install option is enabled - just a flat list of dependencies.
.EXAMPLE
    .\Get-PMPCAppRelationships.ps1 -SiteCode "ABC" -SiteServer "cm01.contoso.com"
    Retrieves application dependency relationships from the Configuration Manager site with site code "ABC" on server "cm01.contoso.com".
.EXAMPLE
    .\Get-PMPCAppRelationships.ps1 -SiteCode "XYZ" -SiteServer "sccm.contoso.com" | Export-Csv -Path "C:\AppDependencies.csv" -NoTypeInformation
    Retrieves application dependency relationships from the Configuration Manager site with site code "XYZ" on server "sccm.contoso.com" and exports the results to a CSV file.
#>


[CmdletBinding()]
param (
    [Parameter(Mandatory)]
    [String]$SiteCode,

    [Parameter(Mandatory)]
    [String]$SiteServer
)

$GetCimInstanceSplat = @{
    'namespace' = 'root\SMS\site_{0}' -f $SiteCode
    'computername' = $SiteServer
}

$Apps = @{}

Get-CimInstance -ClassName SMS_ApplicationLatest @GetCimInstanceSplat | ForEach-Object { $Apps[$_.CI_ID] = $_ }

foreach ($App in $Apps.Keys) {
    $GetCimInstanceSplat['filter'] = 'FromApplicationCIID={0}' -f $App
    $Dependency = Get-CimInstance -ClassName SMS_AppDependenceRelation_Flat @GetCimInstanceSplat
    if ([String]::IsNullOrEmpty($Dependency)) {
        $ChildDependency = $null
    }
    else {
        $ChildDependency = [String]::Join(', ', $Apps[$Dependency.ToApplicationCIID].LocalizedDisplayName)
    }

    $GetCimInstanceSplat['filter'] = 'ToApplicationCIID={0}' -f $App
    $Dependency = Get-CimInstance -ClassName SMS_AppDependenceRelation_Flat @GetCimInstanceSplat
    if ([String]::IsNullOrEmpty($Dependency)) {
        $ParentDependency = $null
    }
    else {
        $ParentDependency = [String]::Join(', ', $Apps[$Dependency.FromApplicationCIID].LocalizedDisplayName)
    }

    [PSCustomObject]@{
        Application = $Apps[$App].LocalizedDisplayName
        CIID = $App
        ParentDependency = $ParentDependency
        ChildDependency = $ChildDependency
    }
}
