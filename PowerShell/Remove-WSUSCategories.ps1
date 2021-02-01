param(
    [parameter(Mandatory = $true)]
    [string]$SqlServer,
    [parameter(Mandatory = $false)]
    [switch]$Force
)

function Get-SUSDConnectionString {
    param(
        [string]$SqlServer
    )
    $builder = [System.Data.SqlClient.SqlConnectionStringBuilder]::new()
    $builder['Data Source'] = $SqlServer
    $builder['Initial Catalog'] = 'SUSDB'
    $builder['Integrated Security'] = $true
    return $builder.ConnectionString
}
function Get-WSUSTopLevelCategories {
    param(
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
        if ($Category.Title -notmatch '^Microsoft$|^Local Publisher$') {
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

function Get-WSUSSubCategoriesByUpdateID {
    param(
        [parameter(Mandatory = $true)]
        [guid]$CategoryID,
        [parameter(Mandatory = $true)]
        [System.Data.SqlClient.SqlConnection]$SqlConnection
    )

    $command = $SqlConnection.CreateCommand()
    $command.CommandText = 'spGetSubCategoriesByUpdateID'
    $command.CommandType = [System.Data.CommandType]::StoredProcedure
    $null = $command.Parameters.Add([System.Data.SqlClient.SqlParameter]::new('categoryID', $CategoryID))
    $adp = [System.Data.SqlClient.SqlDataAdapter]::new($command)
    
    $data = [System.Data.DataSet]::new()
    $null = $adp.Fill($data)

    $allSubCategories = $data.Tables[0]

    foreach ($Category in $allSubCategories) {
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

function Get-WSUSUpdateRevisionIDs {
    param(
        [parameter(Mandatory = $true)]
        [string]$LocalUpdateID,
        [parameter(Mandatory = $true)]
        [System.Data.SqlClient.SqlConnection]$SqlConnection
    )
    $RevisionIDQuery = [string]::Format(@"
        SELECT r.RevisionID FROM dbo.tbRevision r
            WHERE r.LocalUpdateID = {0}
            AND (EXISTS (SELECT * FROM dbo.tbBundleDependency WHERE BundledRevisionID = r.RevisionID)
            OR EXISTS (SELECT * FROM dbo.tbPrerequisiteDependency WHERE PrerequisiteRevisionID = r.RevisionID))
"@, $LocalUpdateID)

    $command = $SqlConnection.CreateCommand()
    $command.CommandText = $RevisionIDQuery
    $command.CommandType = [System.Data.CommandType]::Text
    $adp = [System.Data.SqlClient.SqlDataAdapter]::new($command)
    
    $data = [System.Data.DataSet]::new()
    $null = $adp.Fill($data)

    return $data.Tables[0].RevisionID
}

function Invoke-WSUSDeleteUpdateByUpdateID {
    param(
        [parameter(Mandatory = $true)]
        [Guid]$UpdateID,
        [parameter(Mandatory = $true)]
        [string]$LocalUpdateID,
        [parameter(Mandatory = $false)]
        [switch]$Force,
        [parameter(Mandatory = $true)]
        [System.Data.SqlClient.SqlConnection]$SqlConnection
    )
    $SUSDBQueryParam = @{
        SqlConnection = $SqlConnection
    }

    $command = $SqlConnection.CreateCommand()
    $command.CommandText = 'spDeleteUpdateByUpdateID'
    $command.CommandType = [System.Data.CommandType]::StoredProcedure
    $null = $command.Parameters.Add([System.Data.SqlClient.SqlParameter]::new('updateID', $UpdateID))

    if ($Force) {
        $RevisionsToRemove = Get-WSUSUpdateRevisionIDs -LocalUpdateID $LocalUpdateID @SUSDBQueryParam
        foreach ($RevisionID in $RevisionsToRemove) {
            Invoke-WSUSDeleteRevisionByRevisionID -RevisionID $RevisionID @SUSDBQueryParam
        }
    }    

    $command.ExecuteNonQuery()
}

function Invoke-WSUSDeleteRevisionByRevisionID {
    param(
        [parameter(Mandatory = $true)]
        [int]$RevisionID,
        [parameter(Mandatory = $true)]
        [System.Data.SqlClient.SqlConnection]$SqlConnection
    )
    $command = $SqlConnection.CreateCommand()
    $command.CommandText = 'spDeleteRevision'
    $command.CommandType = [System.Data.CommandType]::StoredProcedure
    $null = $command.Parameters.Add([System.Data.SqlClient.SqlParameter]::new('revisionID', $RevisionID))
    $command.ExecuteNonQuery()
}

$sqlConn = [System.Data.SqlClient.SqlConnection]::new()
$sqlConn.ConnectionString = Get-SUSDConnectionString -SqlServer $SqlServer
$sqlConn.Open()

$SUSDBQueryParam = @{
    SqlConnection = $sqlConn
}

$TopLevelCategories = Get-WSUSTopLevelCategories @SUSDBQueryParam
$CategoriesToDelete = $TopLevelCategories | Out-GridView -Title "Select Categories To Delete" -OutputMode Multiple

foreach ($TopLevelCategory in $CategoriesToDelete) {
    $SubCategories = Get-WSUSSubCategoriesByUpdateID -CategoryID $TopLevelCategory.UpdateID @SUSDBQueryParam

    foreach ($Category in $SubCategories) {
        $UpdatesToDelete = Get-WSUSUpdatesUnderACategory -CategoryID $Category.UpdateID @SUSDBQueryParam
        foreach ($Update in $UpdatesToDelete) {
            Write-Output "Trying to delete $($Update.Title)"
            Invoke-WSUSDeleteUpdateByUpdateID -UpdateID $Update.UpdateID -LocalUpdateID $Update.LocalUpdateID -Force:$Force @SUSDBQueryParam
        }
        Write-Output "Trying to delete $($Category.Title)"
        Invoke-WSUSDeleteUpdateByUpdateID -UpdateID $Category.UpdateID-LocalUpdateID $Category.LocalUpdateID -Force:$Force @SUSDBQueryParam
    }
    Write-Output "Trying to delete $($TopLevelCategory.Title)"
    Invoke-WSUSDeleteUpdateByUpdateID -UpdateID $TopLevelCategory.UpdateID -LocalUpdateID $TopLevelCategory.LocalUpdateID -Force:$Force @SUSDBQueryParam
}