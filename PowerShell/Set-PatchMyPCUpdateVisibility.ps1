<#
.SYNOPSIS
    A script used to set the visibility of Patch My PC Updates in WSUS
.DESCRIPTION
    This script is useful when you have a standalone WSUS environment (not connected to ConfigMgr)
    and you want to see the Patch My PC updates in the WSUS console. By default, they do not show up.

    This is also useful for downstream WSUS servers, as the IsLocallyPublished defaults to 1 when updates
    sync to a downstream server, even if it is set to 0 on the upstream.

    This script assumes you have permissions to edit the database. Namely the IsLocallyPublished column
    in the tbUpdate table.
.PARAMETER ShowInWSUS
    A boolean that sets whether Patch My PC updates should show in WSUS or not. [$true = Show] [$false = Hide]

    Defaults to $true
.EXAMPLE
    C:\PS> Set-PatchMyPCUpdateVisibility
    Show all Patch My PC Updates in WSUS
.EXAMPLE
    C:\PS> Set-PatchMyPCUpdateVisibility -ShowInWsus $true
    Show all Patch My PC Updates in WSUS
.EXAMPLE
    C:\PS> Set-PatchMyPCUpdateVisibility -ShowInWsus $false
    Hide all Patch My PC Updates in WSUS
.NOTES
    ################# DISCLAIMER #################
    Patch My PC provides scripts, macro, and other code examples for illustration only, without warranty
    either expressed or implied, including but not limited to the implied warranties of merchantability
    and/or fitness for a particular purpose. This script is provided 'AS IS' and Patch My PC does not
    guarantee that the following script, macro, or code can or should be used in any situation or that
    operation of the code will be error-free.
.LINK
    https://patchmypc.com
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [bool]$ShowInWSUS = $true
)
begin {
    [int]$Visibility = -not $ShowInWSUS
    Write-Host -ForegroundColor Cyan @'
    
 @@@@@@@      @@@@@@@@@@      @@@@@@@       @@@@@@@  
 @@@@@@@@     @@@@@@@@@@@     @@@@@@@@     @@@@@@@@  
 @@!  @@@     @@! @@! @@!     @@!  @@@     !@@       
 !@!  @!@     !@! !@! !@!     !@!  @!@     !@!       
 @!@@!@!      @!! !!@ @!@     @!@@!@!      !@!       
 !!@!!!       !@!   ! !@!     !!@!!!       !!!       
 !!:          !!:     !!:     !!:          :!!       
 :!:          :!:     :!:     :!:          :!:       
  ::          :::     ::       ::           ::: :::  
  :            :      :        :            :: :: :  
_____________________________________________________
    
'@
    Write-Host -ForegroundColor Magenta "[ShowInWSUS = $ShowInWSUS] - Will set [IsLocallyPublished = $Visibility]"
    
    function Get-SUSDBConnectionString {
        param(
            [string]$SqlServer,
            [string]$Database
        )
        $builder = [System.Data.SqlClient.SqlConnectionStringBuilder]::new()
        $builder['Data Source'] = $SqlServer
        $builder['Initial Catalog'] = $Database
        $builder['Integrated Security'] = $true
        return $builder.ConnectionString
    }
    function Get-SUSDBConnection {
        param(
            [string]$ConnectionString
        )
        $sqlConn = [System.Data.SqlClient.SqlConnection]::new()
        $sqlConn.ConnectionString = $ConnectionString
        $sqlConn.Open()
    
        return $sqlConn
    }
    function Get-WSUSTopLevelCategories {
        param(
            [string]$TitleFilter = 'Patch My PC',
            [parameter(Mandatory = $true)]
            [System.Data.SqlClient.SqlConnection]$SqlConnection
        )
        $command = $SqlConnection.CreateCommand()
        $command.CommandText = 'spGetTopLevelCategories'
        $command.CommandType = [System.Data.CommandType]::StoredProcedure
        $adp = [System.Data.SqlClient.SqlDataAdapter]::new($command)
    
        $data = [System.Data.DataSet]::new()
        $null = $adp.Fill($data)
    
        $allTopLevelCategories = $data.Tables[0]
    
        foreach ($Category in $allTopLevelCategories) {
            if ($Category.Title -match $TitleFilter) {
                [pscustomobject]@{
                    Title         = $Category.Title
                    Description   = $Category.Description
                    ArrivalDate   = $Category.ArrivalDate
                    LocalUpdateID = $Category.LocalUpdateID
                    UpdateID      = $Category.UpdateID
                    CategoryType  = $Category.CategoryType
                }
            }
        }
    }
    function Get-WSUSUpdatesUnderACategory {
        param(
            [parameter(Mandatory = $true)]
            [Guid]$CategoryID,
            [parameter(Mandatory = $false)]
            [int]$MaxResultCount = 5000,
            [parameter(Mandatory = $true)]
            [System.Data.SqlClient.SqlConnection]$SqlConnection
        )
        $command = $SqlConnection.CreateCommand()
        $command.CommandText = 'spGetUpdatesUnderACategory'
        $command.CommandType = [System.Data.CommandType]::StoredProcedure
        $null = $command.Parameters.Add([System.Data.SqlClient.SqlParameter]::new('maxResultCount', 5000))
        $null = $command.Parameters.Add([System.Data.SqlClient.SqlParameter]::new('categoryID', $CategoryID))
        $adp = [System.Data.SqlClient.SqlDataAdapter]::new($command)
    
        $data = [System.Data.DataSet]::new()
        $null = $adp.Fill($data)
    
        return $data.Tables[0]
    }
    function Set-WsusUpdateVisibility {
        param(
            [parameter(Mandatory = $true)]
            [string[]]$UpdateIds,
            [int]$IsLocallyPublished = 0,
            [parameter(Mandatory = $true)]
            [System.Data.SqlClient.SqlConnection]$SqlConnection
        )
        $sqlQuery = "UPDATE [SUSDB].[dbo].[tbUpdate] SET [IsLocallyPublished] = $IsLocallyPublished WHERE [IsLocallyPublished] <> $IsLocallyPublished AND [UpdateID] IN ('$([string]::Join("','", $UpdateIds))');"
        $command = $SqlConnection.CreateCommand()
        $command.CommandText = $sqlQuery
    
        return $command.ExecuteNonQuery()
    }
}
process {
    $WSUSSQL = Get-ItemPropertyValue -Path 'registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Update Services\Server\Setup\' -Name SqlServerName
    if ($WSUSSQL -match 'WID$') {
        # If the SqlServerName ends with WID then we know this to be a WID database and adjust the variable as needed
        $WSUSSQL = 'np:\\.\pipe\MICROSOFT##WID\tsql\query'
    }
    Write-Host -ForegroundColor Magenta "SqlServerName is $WSUSSQL"
    $WSUSDB = Get-ItemPropertyValue -Path 'registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Update Services\Server\Setup\' -Name SqlDatabaseName
    Write-Host -ForegroundColor Magenta "SqlDatabaseName is $WSUSDB"
    $sqlConn = Get-SUSDBConnection -ConnectionString (Get-SUSDBConnectionString -SqlServer $WSUSSQL -Database $WSUSDB)
    $SUSDBQueryParam = @{
        SqlConnection = $sqlConn
    }
    $PatchMyPCCategories = Get-WSUSTopLevelCategories @SUSDBQueryParam
    $CategoryCount = $PatchMyPCCategories | Measure-Object | Select-Object -ExpandProperty Count
    Write-Host -ForegroundColor Magenta "Identified $CategoryCount Patch My PC Categor$(if($CategoryCount -ne 1){'ies'}else{'y'})"
    foreach ($Category in $PatchMyPCCategories) {
        $Updates = (Get-WSUSUpdatesUnderACategory -CategoryID $Category.UpdateId @SUSDBQueryParam).UpdateId.Guid
        $UpdateCount = $Updates | Measure-Object | Select-Object -ExpandProperty Count
        Write-Host -ForegroundColor Magenta "Setting [IsLocallyPublished] = $Visibility for up to $UpdateCount update$(if($UpdateCount -ne 1){'s'})"
        if($PSCmdlet.ShouldProcess("$UpdateCount update$(if($UpdateCount -ne 1){'s'})", 'Set-WsusUpdateVisibility')){
            $UpdatesChangedCount = Set-WsusUpdateVisibility -UpdateIds $Updates -IsLocallyPublished $Visibility @SUSDBQueryParam
            Write-Host -ForegroundColor Magenta "$UpdatesChangedCount Update record$(if($UpdatesChangedCount -ne 1){'s'}) $(if($UpdatesChangedCount -ne 1){'have'}else{'has'}) been set to IsLocallyPublished = $Visibility"
        }
    }
}
end {
    Write-Host -ForegroundColor Cyan '_____________________________________________________'
}