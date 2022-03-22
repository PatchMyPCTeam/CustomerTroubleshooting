<#
    .SYNOPSIS
        Searches the local WSUS for all PMPC updates and marks them as IsLocallyPublished = 0 in the SUSDB

    .DESCRIPTION
        This script is used to force all PMPC updates to show in the WSUS console. This is useful when you are in a WSUS
        standalone scenarion and will not be managing updates through ConfigMgr or some other method.

        By default, third party updates do not show in WSUS. This is a workound. Use at your own risk as it is a database edit.

    .EXAMPLE
        C:\PS>  Set-PMPCUpdatesToShowInWSUS.ps1
            Sets all PMPC updates to show in WSUS console. 

    .NOTES
        ################# DISCLAIMER #################
        Patch My PC provides scripts, macro, and other code examples for illustration only, without warranty 
        either expressed or implied, including but not limited to the implied warranties of merchantability 
        and/or fitness for a particular purpose. This script is provided 'AS IS' and Patch My PC does not 
        guarantee that the following script, macro, or code can or should be used in any situation or that 
        operation of the code will be error-free.
#>
$WSUSSQL = Get-ItemPropertyValue -Path 'registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Update Services\Server\Setup\' -Name SqlServerName

$wsus = Get-WsusServer
$pmpcCat = $wsus.GetUpdateCategories().where({ $_.Type -eq 'Company' -and $_.title -eq 'Patch My pc' })
$scope = [Microsoft.UpdateServices.Administration.UpdateScope]::new()
foreach ($cat in $pmpcCat) {
    $null = $scope.Categories.Add($cat)
}
$allPMPCUpdates = $wsus.GetUpdates($scope)
$sqlQuery = "UPDATE [SUSDB].[dbo].[tbUpdate] SET [IsLocallyPublished] = 0 WHERE [IsLocallyPublished] = 1 AND [UpdateID] IN ('$([string]::Join("','", $allPMPCUpdates.id.updateid.guid))');"
Invoke-Sqlcmd -ServerInstance $WSUSSQL -Database SUSDB -Query $sqlQuery