param(
    [parameter(Mandatory = $true)]
    [string]$SqlServer,
    [parameter(Mandatory = $false)]
    [switch]$Force
)
function Get-WSUSTopLevelCategories {
    param(
        [parameter(Mandatory = $true)]
        [string]$SqlInstance,
        [parameter(Mandatory = $false)]
        [string]$Database = 'SUSDB'
    )
    $getTopLevelCatSplat = @{
        SqlInstance = $SqlInstance
        Database    = $Database
        CommandType = 'StoredProcedure'
        Query       = 'spGetTopLevelCategories'
    }

    $allTopLevelCategories = Invoke-DbaQuery @getTopLevelCatSplat

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
        [string]$SqlInstance,
        [parameter(Mandatory = $false)]
        [string]$Database = 'SUSDB'
    )
    $getUpdatesUnderCatSplat = @{
        SqlInstance   = $SqlInstance
        Database      = $Database
        Query         = 'spGetUpdatesUnderACategory'
        As            = 'DataSet'
        CommandType   = 'StoredProcedure'
        SqlParameters = @{categoryID = $CategoryID; maxResultCount = $MaxResultCount }
    }

    return (Invoke-DbaQuery @getUpdatesUnderCatSplat).Tables[0]
}

function Get-WSUSSubCategoriesByUpdateID {
    param(
        [parameter(Mandatory = $true)]
        [guid]$CategoryID,
        [parameter(Mandatory = $true)]
        [string]$SqlInstance,
        [parameter(Mandatory = $false)]
        [string]$Database = 'SUSDB'
    )
    $getSubCatByIDSplat = @{
        SqlInstance   = $SqlInstance
        Database      = $Database
        CommandType   = 'StoredProcedure'
        Query         = 'spGetSubCategoriesByUpdateID'
        SqlParameters = @{
            categoryID = $CategoryID
        }
    }
    $allSubCategories = Invoke-DbaQuery @getSubCatByIDSplat

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
        [string]$SqlInstance,
        [parameter(Mandatory = $false)]
        [string]$Database = 'SUSDB'
    )
    $RevisionIDQuery = [string]::Format(@"
        SELECT r.RevisionID FROM dbo.tbRevision r
           WHERE r.LocalUpdateID = {0}
           AND (EXISTS (SELECT * FROM dbo.tbBundleDependency WHERE BundledRevisionID = r.RevisionID)
               OR EXISTS (SELECT * FROM dbo.tbPrerequisiteDependency WHERE PrerequisiteRevisionID = r.RevisionID))
"@, $LocalUpdateID)

    $getUpdateRevisionIDsSplat = @{
        SqlInstance = $SqlInstance
        Database    = $Database
        Query       = $RevisionIDQuery
    }

    return (Invoke-DbaQuery @getUpdateRevisionIDsSplat).RevisionID
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
        [string]$SqlInstance,
        [parameter(Mandatory = $false)]
        [string]$Database = 'SUSDB'
    )
    $SUSDBQueryParam = @{
        SqlInstance = $SqlInstance
        Database    = $Database
    }

    $deleteUpdateSplat = @{
        Query         = 'spDeleteUpdateByUpdateID'
        CommandType   = 'StoredProcedure'
        SqlParameters = @{
            updateID = $UpdateID
        }
    }

    if ($Force) {
        $RevisionsToRemove = Get-WSUSUpdateRevisionIDs -LocalUpdateID $LocalUpdateID @SUSDBQueryParam
        foreach ($RevisionID in $RevisionsToRemove) {
            Invoke-WSUSDeleteRevisionByRevisionID -RevisionID $RevisionID @SUSDBQueryParam
        }
    }    

    return Invoke-DbaQuery @deleteUpdateSplat @SUSDBQueryParam
}

function Invoke-WSUSDeleteRevisionByRevisionID {
    param(
        [parameter(Mandatory = $true)]
        [guid]$RevisionID,
        [parameter(Mandatory = $true)]
        [string]$SqlInstance,
        [parameter(Mandatory = $false)]
        [string]$Database = 'SUSDB'
    )
    $deleteRevisionSplat = @{
        SqlInstance   = $SqlInstance
        Database      = $Database
        Query         = 'spDeleteRevision'
        CommandType   = 'StoredProcedure'
        SqlParameters = @{
            revisionID = $RevisionID
        }
    }

    return Invoke-DbaQuery @deleteRevisionSplat
}

$SUSDBQueryParam = @{
    SqlInstance = $SqlServer
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