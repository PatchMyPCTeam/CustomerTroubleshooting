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
# SIG # Begin signature block
# MIIovAYJKoZIhvcNAQcCoIIorTCCKKkCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCB/Xl/SIY0QClNR
# KfehPHX7S+ug5BChcDQIe0XW3Ha3LKCCIb8wggWNMIIEdaADAgECAhAOmxiO+dAt
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
# Vzu0nAPthkX0tGFuv2jiJmCG6sivqf6UHedjGzqGVnhOMIIGwDCCBKigAwIBAgIQ
# DE1pckuU+jwqSj0pB4A9WjANBgkqhkiG9w0BAQsFADBjMQswCQYDVQQGEwJVUzEX
# MBUGA1UEChMORGlnaUNlcnQsIEluYy4xOzA5BgNVBAMTMkRpZ2lDZXJ0IFRydXN0
# ZWQgRzQgUlNBNDA5NiBTSEEyNTYgVGltZVN0YW1waW5nIENBMB4XDTIyMDkyMTAw
# MDAwMFoXDTMzMTEyMTIzNTk1OVowRjELMAkGA1UEBhMCVVMxETAPBgNVBAoTCERp
# Z2lDZXJ0MSQwIgYDVQQDExtEaWdpQ2VydCBUaW1lc3RhbXAgMjAyMiAtIDIwggIi
# MA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQDP7KUmOsap8mu7jcENmtuh6BSF
# dDMaJqzQHFUeHjZtvJJVDGH0nQl3PRWWCC9rZKT9BoMW15GSOBwxApb7crGXOlWv
# M+xhiummKNuQY1y9iVPgOi2Mh0KuJqTku3h4uXoW4VbGwLpkU7sqFudQSLuIaQyI
# xvG+4C99O7HKU41Agx7ny3JJKB5MgB6FVueF7fJhvKo6B332q27lZt3iXPUv7Y3U
# TZWEaOOAy2p50dIQkUYp6z4m8rSMzUy5Zsi7qlA4DeWMlF0ZWr/1e0BubxaompyV
# R4aFeT4MXmaMGgokvpyq0py2909ueMQoP6McD1AGN7oI2TWmtR7aeFgdOej4TJEQ
# ln5N4d3CraV++C0bH+wrRhijGfY59/XBT3EuiQMRoku7mL/6T+R7Nu8GRORV/zbq
# 5Xwx5/PCUsTmFntafqUlc9vAapkhLWPlWfVNL5AfJ7fSqxTlOGaHUQhr+1NDOdBk
# +lbP4PQK5hRtZHi7mP2Uw3Mh8y/CLiDXgazT8QfU4b3ZXUtuMZQpi+ZBpGWUwFjl
# 5S4pkKa3YWT62SBsGFFguqaBDwklU/G/O+mrBw5qBzliGcnWhX8T2Y15z2LF7OF7
# ucxnEweawXjtxojIsG4yeccLWYONxu71LHx7jstkifGxxLjnU15fVdJ9GSlZA076
# XepFcxyEftfO4tQ6dwIDAQABo4IBizCCAYcwDgYDVR0PAQH/BAQDAgeAMAwGA1Ud
# EwEB/wQCMAAwFgYDVR0lAQH/BAwwCgYIKwYBBQUHAwgwIAYDVR0gBBkwFzAIBgZn
# gQwBBAIwCwYJYIZIAYb9bAcBMB8GA1UdIwQYMBaAFLoW2W1NhS9zKXaaL3WMaiCP
# nshvMB0GA1UdDgQWBBRiit7QYfyPMRTtlwvNPSqUFN9SnDBaBgNVHR8EUzBRME+g
# TaBLhklodHRwOi8vY3JsMy5kaWdpY2VydC5jb20vRGlnaUNlcnRUcnVzdGVkRzRS
# U0E0MDk2U0hBMjU2VGltZVN0YW1waW5nQ0EuY3JsMIGQBggrBgEFBQcBAQSBgzCB
# gDAkBggrBgEFBQcwAYYYaHR0cDovL29jc3AuZGlnaWNlcnQuY29tMFgGCCsGAQUF
# BzAChkxodHRwOi8vY2FjZXJ0cy5kaWdpY2VydC5jb20vRGlnaUNlcnRUcnVzdGVk
# RzRSU0E0MDk2U0hBMjU2VGltZVN0YW1waW5nQ0EuY3J0MA0GCSqGSIb3DQEBCwUA
# A4ICAQBVqioa80bzeFc3MPx140/WhSPx/PmVOZsl5vdyipjDd9Rk/BX7NsJJUSx4
# iGNVCUY5APxp1MqbKfujP8DJAJsTHbCYidx48s18hc1Tna9i4mFmoxQqRYdKmEIr
# UPwbtZ4IMAn65C3XCYl5+QnmiM59G7hqopvBU2AJ6KO4ndetHxy47JhB8PYOgPvk
# /9+dEKfrALpfSo8aOlK06r8JSRU1NlmaD1TSsht/fl4JrXZUinRtytIFZyt26/+Y
# siaVOBmIRBTlClmia+ciPkQh0j8cwJvtfEiy2JIMkU88ZpSvXQJT657inuTTH4YB
# ZJwAwuladHUNPeF5iL8cAZfJGSOA1zZaX5YWsWMMxkZAO85dNdRZPkOaGK7DycvD
# +5sTX2q1x+DzBcNZ3ydiK95ByVO5/zQQZ/YmMph7/lxClIGUgp2sCovGSxVK05iQ
# RWAzgOAj3vgDpPZFR+XOuANCR+hBNnF3rf2i6Jd0Ti7aHh2MWsgemtXC8MYiqE+b
# vdgcmlHEL5r2X6cnl7qWLoVXwGDneFZ/au/ClZpLEQLIgpzJGgV8unG1TnqZbPTo
# ntRamMifv427GFxD9dAq6OJi7ngE273R+1sKqHB+8JeEeOMIA11HLGOoJTiXAdI/
# Otrl5fbmm9x+LMz/F0xNAKLY1gEOuIvu5uByVYksJxlh9ncBjDCCCAAwggXooAMC
# AQICEA9Lp9vIoK2Todmfupg/Pk0wDQYJKoZIhvcNAQELBQAwaTELMAkGA1UEBhMC
# VVMxFzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMUEwPwYDVQQDEzhEaWdpQ2VydCBU
# cnVzdGVkIEc0IENvZGUgU2lnbmluZyBSU0E0MDk2IFNIQTM4NCAyMDIxIENBMTAe
# Fw0yMjA5MTUwMDAwMDBaFw0yNTA5MTAyMzU5NTlaMIHRMRMwEQYLKwYBBAGCNzwC
# AQMTAlVTMRkwFwYLKwYBBAGCNzwCAQITCENvbG9yYWRvMR0wGwYDVQQPDBRQcml2
# YXRlIE9yZ2FuaXphdGlvbjEUMBIGA1UEBRMLMjAxMzE2MzgzMjcxCzAJBgNVBAYT
# AlVTMREwDwYDVQQIEwhDb2xvcmFkbzEUMBIGA1UEBxMLQ2FzdGxlIFJvY2sxGTAX
# BgNVBAoTEFBhdGNoIE15IFBDLCBMTEMxGTAXBgNVBAMTEFBhdGNoIE15IFBDLCBM
# TEMwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQDyn6DYy4BKs5cC/2mS
# 0pXQpEU32UNY72+mTIWWKMVHTac1BBjaW3UwfTTYPa0HWQrzwxWMYc9NGzrcBXc8
# 6zt1fuBsUjyuwQSpAgEseTnva1RvbtL5lNrwrJ0TjLXMyvFAYhEQ/v1vhWDdgIEM
# HWGlLGjzE/0DZX1boThIxUFwWKAjDDv3DV1EC2ZCMBeBmnGhjIfU1Erm/CvcvDjM
# +QEMo5n08VKwS1M4tFiUtXg6EwHiewSK70+/o3voBLWHvTqSM9oEyZmFMpCFLCMe
# wPDrU8qeo+7XTA2ocMltQ171JxUB1FYl4rL2o0orghnj7XrdZXPsMiYsxheiLzAY
# 8P8S5P9/GQEbOOIjRTVchL4Gui+KVjj6eFJfVZha6lk6fD7eLKaQO8hP9To7GANF
# 5NMd5uh4lIglI8IWPHkYQQqeZnvtUkfCx8IbEtk0jvK2JGhY3LZ0aY6cIajdoWf6
# u1iCIZmUaB8R9ET0KzyTx5HQXrOzjO0la2U7bOyIURF0eD13ngkQ1ojSCG+qU5iY
# lBp68e4MtGsopVDnxD28NCNj0nJAV376scb5yRq/gWVmISFAuv3B1IasHxVTe7av
# J2IgBkiyxYSU9byVhmQVVTW6QwvY6AG7vUrw+PGrdk6zn+oh6c/8oYAvoj4Y4qCU
# TDiStiptFNIwtHarSYSTZn2XlwIDAQABo4ICOTCCAjUwHwYDVR0jBBgwFoAUaDfg
# 67Y7+F8Rhvv+YXsIiGX0TkIwHQYDVR0OBBYEFL08i+NsZzrUZStu8U9uSIfGjEz3
# MDIGA1UdEQQrMCmgJwYIKwYBBQUHCAOgGzAZDBdVUy1DT0xPUkFETy0yMDEzMTYz
# ODMyNzAOBgNVHQ8BAf8EBAMCB4AwEwYDVR0lBAwwCgYIKwYBBQUHAwMwgbUGA1Ud
# HwSBrTCBqjBToFGgT4ZNaHR0cDovL2NybDMuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0
# VHJ1c3RlZEc0Q29kZVNpZ25pbmdSU0E0MDk2U0hBMzg0MjAyMUNBMS5jcmwwU6BR
# oE+GTWh0dHA6Ly9jcmw0LmRpZ2ljZXJ0LmNvbS9EaWdpQ2VydFRydXN0ZWRHNENv
# ZGVTaWduaW5nUlNBNDA5NlNIQTM4NDIwMjFDQTEuY3JsMD0GA1UdIAQ2MDQwMgYF
# Z4EMAQMwKTAnBggrBgEFBQcCARYbaHR0cDovL3d3dy5kaWdpY2VydC5jb20vQ1BT
# MIGUBggrBgEFBQcBAQSBhzCBhDAkBggrBgEFBQcwAYYYaHR0cDovL29jc3AuZGln
# aWNlcnQuY29tMFwGCCsGAQUFBzAChlBodHRwOi8vY2FjZXJ0cy5kaWdpY2VydC5j
# b20vRGlnaUNlcnRUcnVzdGVkRzRDb2RlU2lnbmluZ1JTQTQwOTZTSEEzODQyMDIx
# Q0ExLmNydDAMBgNVHRMBAf8EAjAAMA0GCSqGSIb3DQEBCwUAA4ICAQBXT6IfohG7
# JJYdOBmpeg04Ckp8P+Zjv5OKFzDyoZj/3mIE3739ocEnsHvVtiCtv1R9B7rVDJOt
# N3FbXMitaaYg5EdDE7IQ+wVVh3gFyUJgIy0FK/N7y4eFoTzmdvkfhsVk97NU7Pyx
# QBeamB6Xefj4Wy7Ugf6cedJNKLl/w3P5GLSmDe/1Qb3tNYJFfqWwbFUTb479k3wD
# EwQ6J4CQ9yeSfn8uz1WVRhby6Y2UbUIx3mourzOy8LofaP3bT00Fe2m3j/IZjsYU
# PakTF2EnqBZE8PPnf/f8D6EMwbsMTdYDUgkRhKH+DWpq3J1B7TgnK1FmygBN63qg
# LWTxxaolQQsFAlAA2dNJg7cGe6hDlKe9Zf9StY96zS1xkpJDjbh2yGmQNz7AqrNJ
# bSBOv+TnfEHyUStsJFLuL2rpoECiVyg4p6jE14uHk7I6tQ+vqrKer53PjtscN+ss
# 7PAlMqJQ9eH0UQ29kDbx5Vs7hvyYLEbJvh2O2KfLyKlXO9zxaK+vhXtgTJ0wjW1Z
# BFeV4t3XpJE2AFf7EMXfF5TgSvoh6Px7eIIMs6oWIzX3V6w+F4dMwbCXziHHjmWN
# vpm95j4OaLb1EUiUvBKSB1pUQWpc8yycMHWOMs/aVNOS9udMBGPolMqMCUeQQ576
# JArSmtO3WKXcMb2BNZeSM+jQQhK+EjG70TGCBlMwggZPAgEBMH0waTELMAkGA1UE
# BhMCVVMxFzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMUEwPwYDVQQDEzhEaWdpQ2Vy
# dCBUcnVzdGVkIEc0IENvZGUgU2lnbmluZyBSU0E0MDk2IFNIQTM4NCAyMDIxIENB
# MQIQD0un28igrZOh2Z+6mD8+TTANBglghkgBZQMEAgEFAKCBhDAYBgorBgEEAYI3
# AgEMMQowCKACgAChAoAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3AgEEMBwGCisG
# AQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCBeLz74rl4x
# lIxAWZa1z40LSZf9iGYfxf2Kig494FBzKjANBgkqhkiG9w0BAQEFAASCAgCkcnMC
# zLuxSdB6+eoIdvIep/p4nS44sTXvJvvh5SMlyLSyc9CLsL/Bc80RUClEo+fVq0HQ
# prLlOFHDr9shI7e0i1Ihouoo4KIF/Z5s8S8QdTCOu2x4kRFa2MTUx6FiQWIg5UnS
# NiC2JLRoH8V6mFEs3CWSTVEFof5pYrKyAAWKQDXlBNDzA0W9Koid7dpLryxqLW2I
# B83gKKNBqdFeN0AlcejnsIkMKXh5hX3iZQvNKNPQ9reuwHQsrIGCLhGDb7NGSFA8
# bLYrv9oNMA+UrjgFpCCYdx8edIYowoVXjojjZTHYr0vDcGDSPTvT6O3vuNM+bdsh
# wy4KE9A8052gwtWQW2FXKbPkdmwwJWGeYVPejKaZPNmO5odo0+VBTk7dCQO/9zyD
# e1wrxkR6s6RMoxyQuLmst8Qw9PydzmBD+ueDqDhq9HuGZ5xWJKRrQNu6LUUYdQ7T
# V6j4JcGpTsfpDx3Z0Uzsx+DqQUavt41nXLlvnlbOhuxj64TlzsUYCsxhEwQqlLrb
# qWQ/P7PxeddEGrmVGp/fPrEwwv+RLolmJzSb5id/53TdjeFcoKH2lo0uExAjQjBe
# 3Xm/Ylqu4Zpqvr6C35FibKM3XVF+4bT8KlDakFN0WhnaH7bjszvFe1ULHvVcD9w3
# IRTd8MMEsll9pOKZt0Lv+O3NrR6YTT9w3uDXVqGCAyAwggMcBgkqhkiG9w0BCQYx
# ggMNMIIDCQIBATB3MGMxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdpQ2VydCwg
# SW5jLjE7MDkGA1UEAxMyRGlnaUNlcnQgVHJ1c3RlZCBHNCBSU0E0MDk2IFNIQTI1
# NiBUaW1lU3RhbXBpbmcgQ0ECEAxNaXJLlPo8Kko9KQeAPVowDQYJYIZIAWUDBAIB
# BQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwGCSqGSIb3DQEJBTEPFw0y
# MjEyMDUxNDQzNTVaMC8GCSqGSIb3DQEJBDEiBCDSm3Ui7iwvLX7tvLGVpBRQwL/W
# rNt6RGvsTtq50s/v8zANBgkqhkiG9w0BAQEFAASCAgAc4oGHiskWScBNU7AAjCpg
# 6VDjfn4yrY1GPfY/JV/UdoNkY2EAnSUn2d14pj641OsAUqkjg/tXvoz3lFmv1IHk
# pvUqFascMx6r2FYMqXkt7TMKHd+Q3iMvgVb2mGDXQkBTcHSp/KYDCXd9V1fxnHxp
# M8wq0sG/wulYSEsfoG013LftE1OWv5e9AVopCFB13Ut2mqzNCsdCspaAKg8J9q3I
# NzrPGfjVfMhIiLnjW32v7Pq+ZjkY3kJFspy/L4SEsY9GMLQ5Rs+oKV19f1QaAqwq
# iiF4afAY3kYsCdM8kPM0lEzR52RzalyrgbJIVAaSetMH2vIHE7hKR46fRdPKeffn
# tweLgWIgfXH/Ida63aUWE3v06gTwz5AwxEXnPOG3etYmVSJcNgYEEAsYkr7s98Ga
# 3QvMIC+VAIPQHIJiDNeJJcTclxEdtyhotsvQWq7+dyo228PNSzrqo6AmXrkOEQYs
# Fx8t2SiJXytRjBX9G53L+ZqP0UoWbokQ2sTDKSr1YHwKmfHd/HjhlHTkXu9iPMXj
# 7JDvVQOw0GMaKTLQeY88EyPGSsUn4tLsCxds+OdV+oH+A0u/8kVdGoJ5AUU0lYGl
# zpYpKg3p838dk1wjD9PiDhrHoocbNb7UMfT3P8lZOPkrvxl8u/2FQX9Yb0krW5NP
# SFjUAafxNaz9tLYKCAPIcg==
# SIG # End signature block
