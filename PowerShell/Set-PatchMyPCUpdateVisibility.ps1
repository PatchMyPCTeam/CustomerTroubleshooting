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
        $builder = New-Object -TypeName System.Data.SqlClient.SqlConnectionStringBuilder
        $builder['Data Source'] = $SqlServer
        $builder['Initial Catalog'] = $Database
        $builder['Integrated Security'] = $true
        return $builder.ConnectionString
    }
    function Get-SUSDBConnection {
        param(
            [string]$ConnectionString
        )
        $sqlConn = New-Object -TypeName System.Data.SqlClient.SqlConnection
        $sqlConn.ConnectionString = $ConnectionString
        $sqlConn.Open()
    
        return $sqlConn
    }
    function Get-WSUSTopLevelCategories {
        param(
            [string]$TitleFilter = 'Patch My PC',
            [parameter(Mandatory = $true)]
            [System.Data.SqlClient.SqlConnection]$SqlConnection,
            [switch]$IncludeSubCategories
        )
        $command = $SqlConnection.CreateCommand()
        $command.CommandText = 'spGetTopLevelCategories'
        $command.CommandType = [System.Data.CommandType]::StoredProcedure
        $adp = New-Object -TypeName System.Data.SqlClient.SqlDataAdapter -ArgumentList $command
    
        $data = New-Object -TypeName System.Data.DataSet
        $null = $adp.Fill($data)
    
        $allTopLevelCategories = $data.Tables[0]
    
        foreach ($Category in $allTopLevelCategories) {
            if ($Category.Title -match $TitleFilter) {
                $r = [pscustomobject]@{
                    Title         = $Category.Title
                    Description   = $Category.Description
                    ArrivalDate   = $Category.ArrivalDate
                    LocalUpdateID = $Category.LocalUpdateID
                    UpdateID      = $Category.UpdateID
                    CategoryType  = $Category.CategoryType
                }

                $r

                if ($IncludeSubCategories.IsPresent) {
                    Get-WSUSSubCategoriesById -Id $r.UpdateID -SqlConnection $SqlConnection
                }
            }
        }
    }
    function Get-WSUSSubCategoriesById {
        param(
            [parameter(Mandatory = $true)]
            [guid]$Id,
            [string]$PreferredCulture = 'en',
            [parameter(Mandatory = $true)]
            [System.Data.SqlClient.SqlConnection]$SqlConnection
        )

        $command = $SqlConnection.CreateCommand()
        $command.CommandText = 'spGetSubCategoriesByUpdateID'
        $command.CommandType = [System.Data.CommandType]::StoredProcedure
        $ParameterCategoryId = $command.Parameters.Add("@categoryID",[System.Data.SqlDbType]::UniqueIdentifier)
        $ParameterCategoryId.Value = $Id
        $ParameterCulture = $command.Parameters.Add("@preferredCulture", [System.Data.SqlDbType]::NVarChar, 5)
        $ParameterCulture.Value = $PreferredCulture

        $adp = New-Object -TypeName System.Data.SqlClient.SqlDataAdapter -ArgumentList $command
    
        $data = New-Object -TypeName System.Data.DataSet
        $null = $adp.Fill($data)
    
        $SubCategories = $data.Tables[0]

        foreach ($Category in $SubCategories) {
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
        $null = $command.Parameters.Add($(New-Object -TypeName System.Data.SqlClient.SqlParameter -ArgumentList 'maxResultCount', 5000))
        $null = $command.Parameters.Add($(New-Object -TypeName System.Data.SqlClient.SqlParameter -ArgumentList 'categoryID', $CategoryID))
        $adp = New-Object -TypeName System.Data.SqlClient.SqlDataAdapter -ArgumentList $command
    
        $data = New-Object -TypeName System.Data.DataSet
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
    $WSUSSQL = (Get-ItemProperty -Path 'registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Update Services\Server\Setup\').SqlServerName
    if ($WSUSSQL -match 'WID$') {
        # If the SqlServerName ends with WID then we know this to be a WID database and adjust the variable as needed
        $WSUSSQL = 'np:\\.\pipe\MICROSOFT##WID\tsql\query'
    }
    Write-Host -ForegroundColor Magenta "SqlServerName is $WSUSSQL"
    $WSUSDB = (Get-ItemProperty -Path 'registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Update Services\Server\Setup\').SqlDatabaseName
    Write-Host -ForegroundColor Magenta "SqlDatabaseName is $WSUSDB"
    $sqlConn = Get-SUSDBConnection -ConnectionString (Get-SUSDBConnectionString -SqlServer $WSUSSQL -Database $WSUSDB)
    $SUSDBQueryParam = @{
        SqlConnection = $sqlConn
    }

    $PatchMyPCCategories = Get-WSUSTopLevelCategories -IncludeSubCategories @SUSDBQueryParam
    $CategoryCount = $PatchMyPCCategories | Measure-Object | Select-Object -ExpandProperty Count

    Write-Host -ForegroundColor Magenta "Identified $CategoryCount Patch My PC Categor$(if($CategoryCount -ne 1){'ies'}else{'y'})"

    Write-Host -ForegroundColor Magenta "Setting [IsLocallyPublished] = $Visibility for up to $CategoryCount categor$(if($CategoryCount -ne 1){'ies'}else{'y'})"
    if ($PSCmdlet.ShouldProcess("$CategoryCount categor$(if($CategoryCount -ne 1){'ies'}else{'y'})", 'Set-WsusUpdateVisibility')) {
        $CategoriesChangedCount = Set-WsusUpdateVisibility -UpdateIds $PatchMyPCCategories.UpdateId -IsLocallyPublished $Visibility @SUSDBQueryParam
        Write-Host -ForegroundColor Magenta "$CategoriesChangedCount category record$(if($CategoriesChangedCount -ne 1){'s'}) $(if($CategoriesChangedCount -ne 1){'have'}else{'has'}) been set to IsLocallyPublished = $Visibility"
    }

    foreach ($Category in $PatchMyPCCategories[0]) {
        $Updates = (Get-WSUSUpdatesUnderACategory -CategoryID $Category.UpdateId @SUSDBQueryParam).UpdateId.Guid
        $UpdateCount = $Updates | Measure-Object | Select-Object -ExpandProperty Count

        Write-Host -ForegroundColor Magenta "Setting [IsLocallyPublished] = $Visibility for up to $UpdateCount update$(if($UpdateCount -ne 1){'s'})"
        if ($PSCmdlet.ShouldProcess("$UpdateCount update$(if($UpdateCount -ne 1){'s'})", 'Set-WsusUpdateVisibility')) {
            $UpdatesChangedCount = Set-WsusUpdateVisibility -UpdateIds $Updates -IsLocallyPublished $Visibility @SUSDBQueryParam
            Write-Host -ForegroundColor Magenta "$UpdatesChangedCount Update record$(if($UpdatesChangedCount -ne 1){'s'}) $(if($UpdatesChangedCount -ne 1){'have'}else{'has'}) been set to IsLocallyPublished = $Visibility"
        }
    }
}
end {
    Write-Host -ForegroundColor Cyan '_____________________________________________________'
}

# SIG # Begin signature block
# MIIo9QYJKoZIhvcNAQcCoIIo5jCCKOICAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAOn0KFwdwxzrPs
# Ac2NRCBnY9wWv8FMlmJf2L8T38UhX6CCIfIwggWNMIIEdaADAgECAhAOmxiO+dAt
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
# twGpn1eqXijiuZQwggawMIIEmKADAgECAhAIrUCyYNKcTJ9ezam9k67ZMA0GCSqG
# SIb3DQEBDAUAMGIxCzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdpQ2VydCBJbmMx
# GTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xITAfBgNVBAMTGERpZ2lDZXJ0IFRy
# dXN0ZWQgUm9vdCBHNDAeFw0yMTA0MjkwMDAwMDBaFw0zNjA0MjgyMzU5NTlaMGkx
# CzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4
# RGlnaUNlcnQgVHJ1c3RlZCBHNCBDb2RlIFNpZ25pbmcgUlNBNDA5NiBTSEEzODQg
# MjAyMSBDQTEwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQDVtC9C0Cit
# eLdd1TlZG7GIQvUzjOs9gZdwxbvEhSYwn6SOaNhc9es0JAfhS0/TeEP0F9ce2vnS
# 1WcaUk8OoVf8iJnBkcyBAz5NcCRks43iCH00fUyAVxJrQ5qZ8sU7H/Lvy0daE6ZM
# swEgJfMQ04uy+wjwiuCdCcBlp/qYgEk1hz1RGeiQIXhFLqGfLOEYwhrMxe6TSXBC
# Mo/7xuoc82VokaJNTIIRSFJo3hC9FFdd6BgTZcV/sk+FLEikVoQ11vkunKoAFdE3
# /hoGlMJ8yOobMubKwvSnowMOdKWvObarYBLj6Na59zHh3K3kGKDYwSNHR7OhD26j
# q22YBoMbt2pnLdK9RBqSEIGPsDsJ18ebMlrC/2pgVItJwZPt4bRc4G/rJvmM1bL5
# OBDm6s6R9b7T+2+TYTRcvJNFKIM2KmYoX7BzzosmJQayg9Rc9hUZTO1i4F4z8ujo
# 7AqnsAMrkbI2eb73rQgedaZlzLvjSFDzd5Ea/ttQokbIYViY9XwCFjyDKK05huzU
# tw1T0PhH5nUwjewwk3YUpltLXXRhTT8SkXbev1jLchApQfDVxW0mdmgRQRNYmtwm
# KwH0iU1Z23jPgUo+QEdfyYFQc4UQIyFZYIpkVMHMIRroOBl8ZhzNeDhFMJlP/2NP
# TLuqDQhTQXxYPUez+rbsjDIJAsxsPAxWEQIDAQABo4IBWTCCAVUwEgYDVR0TAQH/
# BAgwBgEB/wIBADAdBgNVHQ4EFgQUaDfg67Y7+F8Rhvv+YXsIiGX0TkIwHwYDVR0j
# BBgwFoAU7NfjgtJxXWRM3y5nP+e6mK4cD08wDgYDVR0PAQH/BAQDAgGGMBMGA1Ud
# JQQMMAoGCCsGAQUFBwMDMHcGCCsGAQUFBwEBBGswaTAkBggrBgEFBQcwAYYYaHR0
# cDovL29jc3AuZGlnaWNlcnQuY29tMEEGCCsGAQUFBzAChjVodHRwOi8vY2FjZXJ0
# cy5kaWdpY2VydC5jb20vRGlnaUNlcnRUcnVzdGVkUm9vdEc0LmNydDBDBgNVHR8E
# PDA6MDigNqA0hjJodHRwOi8vY3JsMy5kaWdpY2VydC5jb20vRGlnaUNlcnRUcnVz
# dGVkUm9vdEc0LmNybDAcBgNVHSAEFTATMAcGBWeBDAEDMAgGBmeBDAEEATANBgkq
# hkiG9w0BAQwFAAOCAgEAOiNEPY0Idu6PvDqZ01bgAhql+Eg08yy25nRm95RysQDK
# r2wwJxMSnpBEn0v9nqN8JtU3vDpdSG2V1T9J9Ce7FoFFUP2cvbaF4HZ+N3HLIvda
# qpDP9ZNq4+sg0dVQeYiaiorBtr2hSBh+3NiAGhEZGM1hmYFW9snjdufE5BtfQ/g+
# lP92OT2e1JnPSt0o618moZVYSNUa/tcnP/2Q0XaG3RywYFzzDaju4ImhvTnhOE7a
# brs2nfvlIVNaw8rpavGiPttDuDPITzgUkpn13c5UbdldAhQfQDN8A+KVssIhdXNS
# y0bYxDQcoqVLjc1vdjcshT8azibpGL6QB7BDf5WIIIJw8MzK7/0pNVwfiThV9zeK
# iwmhywvpMRr/LhlcOXHhvpynCgbWJme3kuZOX956rEnPLqR0kq3bPKSchh/jwVYb
# KyP/j7XqiHtwa+aguv06P0WmxOgWkVKLQcBIhEuWTatEQOON8BUozu3xGFYHKi8Q
# xAwIZDwzj64ojDzLj4gLDb879M4ee47vtevLt/B3E+bnKD+sEq6lLyJsQfmCXBVm
# zGwOysWGw/YmMwwHS6DTBwJqakAwSEs0qFEgu60bhQjiWQ1tygVQK+pKHJ6l/aCn
# HwZ05/LWUpD9r4VIIflXO7ScA+2GRfS0YW6/aOImYIbqyK+p/pQd52MbOoZWeE4w
# gga0MIIEnKADAgECAhANx6xXBf8hmS5AQyIMOkmGMA0GCSqGSIb3DQEBCwUAMGIx
# CzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdpQ2VydCBJbmMxGTAXBgNVBAsTEHd3
# dy5kaWdpY2VydC5jb20xITAfBgNVBAMTGERpZ2lDZXJ0IFRydXN0ZWQgUm9vdCBH
# NDAeFw0yNTA1MDcwMDAwMDBaFw0zODAxMTQyMzU5NTlaMGkxCzAJBgNVBAYTAlVT
# MRcwFQYDVQQKEw5EaWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1
# c3RlZCBHNCBUaW1lU3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTEwggIi
# MA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQC0eDHTCphBcr48RsAcrHXbo0Zo
# dLRRF51NrY0NlLWZloMsVO1DahGPNRcybEKq+RuwOnPhof6pvF4uGjwjqNjfEvUi
# 6wuim5bap+0lgloM2zX4kftn5B1IpYzTqpyFQ/4Bt0mAxAHeHYNnQxqXmRinvuNg
# xVBdJkf77S2uPoCj7GH8BLuxBG5AvftBdsOECS1UkxBvMgEdgkFiDNYiOTx4OtiF
# cMSkqTtF2hfQz3zQSku2Ws3IfDReb6e3mmdglTcaarps0wjUjsZvkgFkriK9tUKJ
# m/s80FiocSk1VYLZlDwFt+cVFBURJg6zMUjZa/zbCclF83bRVFLeGkuAhHiGPMvS
# GmhgaTzVyhYn4p0+8y9oHRaQT/aofEnS5xLrfxnGpTXiUOeSLsJygoLPp66bkDX1
# ZlAeSpQl92QOMeRxykvq6gbylsXQskBBBnGy3tW/AMOMCZIVNSaz7BX8VtYGqLt9
# MmeOreGPRdtBx3yGOP+rx3rKWDEJlIqLXvJWnY0v5ydPpOjL6s36czwzsucuoKs7
# Yk/ehb//Wx+5kMqIMRvUBDx6z1ev+7psNOdgJMoiwOrUG2ZdSoQbU2rMkpLiQ6bG
# RinZbI4OLu9BMIFm1UUl9VnePs6BaaeEWvjJSjNm2qA+sdFUeEY0qVjPKOWug/G6
# X5uAiynM7Bu2ayBjUwIDAQABo4IBXTCCAVkwEgYDVR0TAQH/BAgwBgEB/wIBADAd
# BgNVHQ4EFgQU729TSunkBnx6yuKQVvYv1Ensy04wHwYDVR0jBBgwFoAU7NfjgtJx
# XWRM3y5nP+e6mK4cD08wDgYDVR0PAQH/BAQDAgGGMBMGA1UdJQQMMAoGCCsGAQUF
# BwMIMHcGCCsGAQUFBwEBBGswaTAkBggrBgEFBQcwAYYYaHR0cDovL29jc3AuZGln
# aWNlcnQuY29tMEEGCCsGAQUFBzAChjVodHRwOi8vY2FjZXJ0cy5kaWdpY2VydC5j
# b20vRGlnaUNlcnRUcnVzdGVkUm9vdEc0LmNydDBDBgNVHR8EPDA6MDigNqA0hjJo
# dHRwOi8vY3JsMy5kaWdpY2VydC5jb20vRGlnaUNlcnRUcnVzdGVkUm9vdEc0LmNy
# bDAgBgNVHSAEGTAXMAgGBmeBDAEEAjALBglghkgBhv1sBwEwDQYJKoZIhvcNAQEL
# BQADggIBABfO+xaAHP4HPRF2cTC9vgvItTSmf83Qh8WIGjB/T8ObXAZz8OjuhUxj
# aaFdleMM0lBryPTQM2qEJPe36zwbSI/mS83afsl3YTj+IQhQE7jU/kXjjytJgnn0
# hvrV6hqWGd3rLAUt6vJy9lMDPjTLxLgXf9r5nWMQwr8Myb9rEVKChHyfpzee5kH0
# F8HABBgr0UdqirZ7bowe9Vj2AIMD8liyrukZ2iA/wdG2th9y1IsA0QF8dTXqvcnT
# mpfeQh35k5zOCPmSNq1UH410ANVko43+Cdmu4y81hjajV/gxdEkMx1NKU4uHQcKf
# ZxAvBAKqMVuqte69M9J6A47OvgRaPs+2ykgcGV00TYr2Lr3ty9qIijanrUR3anzE
# wlvzZiiyfTPjLbnFRsjsYg39OlV8cipDoq7+qNNjqFzeGxcytL5TTLL4ZaoBdqbh
# OhZ3ZRDUphPvSRmMThi0vw9vODRzW6AxnJll38F0cuJG7uEBYTptMSbhdhGQDpOX
# gpIUsWTjd6xpR6oaQf/DJbg3s6KCLPAlZ66RzIg9sC+NJpud/v4+7RWsWCiKi9EO
# LLHfMR2ZyJ/+xhCx9yHbxtl5TPau1j/1MIDpMPx0LckTetiSuEtQvLsNz3Qbp7wG
# WqbIiOWCnb5WqxL3/BAPvIXKUjPSxyZsq8WhbaM2tszWkPZPubdcMIIG7TCCBNWg
# AwIBAgIQCoDvGEuN8QWC0cR2p5V0aDANBgkqhkiG9w0BAQsFADBpMQswCQYDVQQG
# EwJVUzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4xQTA/BgNVBAMTOERpZ2lDZXJ0
# IFRydXN0ZWQgRzQgVGltZVN0YW1waW5nIFJTQTQwOTYgU0hBMjU2IDIwMjUgQ0Ex
# MB4XDTI1MDYwNDAwMDAwMFoXDTM2MDkwMzIzNTk1OVowYzELMAkGA1UEBhMCVVMx
# FzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMTswOQYDVQQDEzJEaWdpQ2VydCBTSEEy
# NTYgUlNBNDA5NiBUaW1lc3RhbXAgUmVzcG9uZGVyIDIwMjUgMTCCAiIwDQYJKoZI
# hvcNAQEBBQADggIPADCCAgoCggIBANBGrC0Sxp7Q6q5gVrMrV7pvUf+GcAoB38o3
# zBlCMGMyqJnfFNZx+wvA69HFTBdwbHwBSOeLpvPnZ8ZN+vo8dE2/pPvOx/Vj8Tch
# TySA2R4QKpVD7dvNZh6wW2R6kSu9RJt/4QhguSssp3qome7MrxVyfQO9sMx6ZAWj
# FDYOzDi8SOhPUWlLnh00Cll8pjrUcCV3K3E0zz09ldQ//nBZZREr4h/GI6Dxb2Uo
# yrN0ijtUDVHRXdmncOOMA3CoB/iUSROUINDT98oksouTMYFOnHoRh6+86Ltc5zjP
# KHW5KqCvpSduSwhwUmotuQhcg9tw2YD3w6ySSSu+3qU8DD+nigNJFmt6LAHvH3KS
# uNLoZLc1Hf2JNMVL4Q1OpbybpMe46YceNA0LfNsnqcnpJeItK/DhKbPxTTuGoX7w
# JNdoRORVbPR1VVnDuSeHVZlc4seAO+6d2sC26/PQPdP51ho1zBp+xUIZkpSFA8vW
# doUoHLWnqWU3dCCyFG1roSrgHjSHlq8xymLnjCbSLZ49kPmk8iyyizNDIXj//cOg
# rY7rlRyTlaCCfw7aSUROwnu7zER6EaJ+AliL7ojTdS5PWPsWeupWs7NpChUk555K
# 096V1hE0yZIXe+giAwW00aHzrDchIc2bQhpp0IoKRR7YufAkprxMiXAJQ1XCmnCf
# gPf8+3mnAgMBAAGjggGVMIIBkTAMBgNVHRMBAf8EAjAAMB0GA1UdDgQWBBTkO/zy
# Me39/dfzkXFjGVBDz2GM6DAfBgNVHSMEGDAWgBTvb1NK6eQGfHrK4pBW9i/USezL
# TjAOBgNVHQ8BAf8EBAMCB4AwFgYDVR0lAQH/BAwwCgYIKwYBBQUHAwgwgZUGCCsG
# AQUFBwEBBIGIMIGFMCQGCCsGAQUFBzABhhhodHRwOi8vb2NzcC5kaWdpY2VydC5j
# b20wXQYIKwYBBQUHMAKGUWh0dHA6Ly9jYWNlcnRzLmRpZ2ljZXJ0LmNvbS9EaWdp
# Q2VydFRydXN0ZWRHNFRpbWVTdGFtcGluZ1JTQTQwOTZTSEEyNTYyMDI1Q0ExLmNy
# dDBfBgNVHR8EWDBWMFSgUqBQhk5odHRwOi8vY3JsMy5kaWdpY2VydC5jb20vRGln
# aUNlcnRUcnVzdGVkRzRUaW1lU3RhbXBpbmdSU0E0MDk2U0hBMjU2MjAyNUNBMS5j
# cmwwIAYDVR0gBBkwFzAIBgZngQwBBAIwCwYJYIZIAYb9bAcBMA0GCSqGSIb3DQEB
# CwUAA4ICAQBlKq3xHCcEua5gQezRCESeY0ByIfjk9iJP2zWLpQq1b4URGnwWBdEZ
# D9gBq9fNaNmFj6Eh8/YmRDfxT7C0k8FUFqNh+tshgb4O6Lgjg8K8elC4+oWCqnU/
# ML9lFfim8/9yJmZSe2F8AQ/UdKFOtj7YMTmqPO9mzskgiC3QYIUP2S3HQvHG1FDu
# +WUqW4daIqToXFE/JQ/EABgfZXLWU0ziTN6R3ygQBHMUBaB5bdrPbF6MRYs03h4o
# bEMnxYOX8VBRKe1uNnzQVTeLni2nHkX/QqvXnNb+YkDFkxUGtMTaiLR9wjxUxu2h
# ECZpqyU1d0IbX6Wq8/gVutDojBIFeRlqAcuEVT0cKsb+zJNEsuEB7O7/cuvTQasn
# M9AWcIQfVjnzrvwiCZ85EE8LUkqRhoS3Y50OHgaY7T/lwd6UArb+BOVAkg2oOvol
# /DJgddJ35XTxfUlQ+8Hggt8l2Yv7roancJIFcbojBcxlRcGG0LIhp6GvReQGgMgY
# xQbV1S3CrWqZzBt1R9xJgKf47CdxVRd/ndUlQ05oxYy2zRWVFjF7mcr4C34Mj3oc
# CVccAvlKV9jEnstrniLvUxxVZE/rptb7IRE2lskKPIJgbaP5t2nGj/ULLi49xTcB
# ZU8atufk+EMF/cWuiC7POGT75qaL6vdCvHlshtjdNXOCIUjsarfNZzCCCAAwggXo
# oAMCAQICEA9Lp9vIoK2Todmfupg/Pk0wDQYJKoZIhvcNAQELBQAwaTELMAkGA1UE
# BhMCVVMxFzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMUEwPwYDVQQDEzhEaWdpQ2Vy
# dCBUcnVzdGVkIEc0IENvZGUgU2lnbmluZyBSU0E0MDk2IFNIQTM4NCAyMDIxIENB
# MTAeFw0yMjA5MTUwMDAwMDBaFw0yNTA5MTAyMzU5NTlaMIHRMRMwEQYLKwYBBAGC
# NzwCAQMTAlVTMRkwFwYLKwYBBAGCNzwCAQITCENvbG9yYWRvMR0wGwYDVQQPDBRQ
# cml2YXRlIE9yZ2FuaXphdGlvbjEUMBIGA1UEBRMLMjAxMzE2MzgzMjcxCzAJBgNV
# BAYTAlVTMREwDwYDVQQIEwhDb2xvcmFkbzEUMBIGA1UEBxMLQ2FzdGxlIFJvY2sx
# GTAXBgNVBAoTEFBhdGNoIE15IFBDLCBMTEMxGTAXBgNVBAMTEFBhdGNoIE15IFBD
# LCBMTEMwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQDyn6DYy4BKs5cC
# /2mS0pXQpEU32UNY72+mTIWWKMVHTac1BBjaW3UwfTTYPa0HWQrzwxWMYc9NGzrc
# BXc86zt1fuBsUjyuwQSpAgEseTnva1RvbtL5lNrwrJ0TjLXMyvFAYhEQ/v1vhWDd
# gIEMHWGlLGjzE/0DZX1boThIxUFwWKAjDDv3DV1EC2ZCMBeBmnGhjIfU1Erm/Cvc
# vDjM+QEMo5n08VKwS1M4tFiUtXg6EwHiewSK70+/o3voBLWHvTqSM9oEyZmFMpCF
# LCMewPDrU8qeo+7XTA2ocMltQ171JxUB1FYl4rL2o0orghnj7XrdZXPsMiYsxhei
# LzAY8P8S5P9/GQEbOOIjRTVchL4Gui+KVjj6eFJfVZha6lk6fD7eLKaQO8hP9To7
# GANF5NMd5uh4lIglI8IWPHkYQQqeZnvtUkfCx8IbEtk0jvK2JGhY3LZ0aY6cIajd
# oWf6u1iCIZmUaB8R9ET0KzyTx5HQXrOzjO0la2U7bOyIURF0eD13ngkQ1ojSCG+q
# U5iYlBp68e4MtGsopVDnxD28NCNj0nJAV376scb5yRq/gWVmISFAuv3B1IasHxVT
# e7avJ2IgBkiyxYSU9byVhmQVVTW6QwvY6AG7vUrw+PGrdk6zn+oh6c/8oYAvoj4Y
# 4qCUTDiStiptFNIwtHarSYSTZn2XlwIDAQABo4ICOTCCAjUwHwYDVR0jBBgwFoAU
# aDfg67Y7+F8Rhvv+YXsIiGX0TkIwHQYDVR0OBBYEFL08i+NsZzrUZStu8U9uSIfG
# jEz3MDIGA1UdEQQrMCmgJwYIKwYBBQUHCAOgGzAZDBdVUy1DT0xPUkFETy0yMDEz
# MTYzODMyNzAOBgNVHQ8BAf8EBAMCB4AwEwYDVR0lBAwwCgYIKwYBBQUHAwMwgbUG
# A1UdHwSBrTCBqjBToFGgT4ZNaHR0cDovL2NybDMuZGlnaWNlcnQuY29tL0RpZ2lD
# ZXJ0VHJ1c3RlZEc0Q29kZVNpZ25pbmdSU0E0MDk2U0hBMzg0MjAyMUNBMS5jcmww
# U6BRoE+GTWh0dHA6Ly9jcmw0LmRpZ2ljZXJ0LmNvbS9EaWdpQ2VydFRydXN0ZWRH
# NENvZGVTaWduaW5nUlNBNDA5NlNIQTM4NDIwMjFDQTEuY3JsMD0GA1UdIAQ2MDQw
# MgYFZ4EMAQMwKTAnBggrBgEFBQcCARYbaHR0cDovL3d3dy5kaWdpY2VydC5jb20v
# Q1BTMIGUBggrBgEFBQcBAQSBhzCBhDAkBggrBgEFBQcwAYYYaHR0cDovL29jc3Au
# ZGlnaWNlcnQuY29tMFwGCCsGAQUFBzAChlBodHRwOi8vY2FjZXJ0cy5kaWdpY2Vy
# dC5jb20vRGlnaUNlcnRUcnVzdGVkRzRDb2RlU2lnbmluZ1JTQTQwOTZTSEEzODQy
# MDIxQ0ExLmNydDAMBgNVHRMBAf8EAjAAMA0GCSqGSIb3DQEBCwUAA4ICAQBXT6If
# ohG7JJYdOBmpeg04Ckp8P+Zjv5OKFzDyoZj/3mIE3739ocEnsHvVtiCtv1R9B7rV
# DJOtN3FbXMitaaYg5EdDE7IQ+wVVh3gFyUJgIy0FK/N7y4eFoTzmdvkfhsVk97NU
# 7PyxQBeamB6Xefj4Wy7Ugf6cedJNKLl/w3P5GLSmDe/1Qb3tNYJFfqWwbFUTb479
# k3wDEwQ6J4CQ9yeSfn8uz1WVRhby6Y2UbUIx3mourzOy8LofaP3bT00Fe2m3j/IZ
# jsYUPakTF2EnqBZE8PPnf/f8D6EMwbsMTdYDUgkRhKH+DWpq3J1B7TgnK1FmygBN
# 63qgLWTxxaolQQsFAlAA2dNJg7cGe6hDlKe9Zf9StY96zS1xkpJDjbh2yGmQNz7A
# qrNJbSBOv+TnfEHyUStsJFLuL2rpoECiVyg4p6jE14uHk7I6tQ+vqrKer53Pjtsc
# N+ss7PAlMqJQ9eH0UQ29kDbx5Vs7hvyYLEbJvh2O2KfLyKlXO9zxaK+vhXtgTJ0w
# jW1ZBFeV4t3XpJE2AFf7EMXfF5TgSvoh6Px7eIIMs6oWIzX3V6w+F4dMwbCXziHH
# jmWNvpm95j4OaLb1EUiUvBKSB1pUQWpc8yycMHWOMs/aVNOS9udMBGPolMqMCUeQ
# Q576JArSmtO3WKXcMb2BNZeSM+jQQhK+EjG70TGCBlkwggZVAgEBMH0waTELMAkG
# A1UEBhMCVVMxFzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMUEwPwYDVQQDEzhEaWdp
# Q2VydCBUcnVzdGVkIEc0IENvZGUgU2lnbmluZyBSU0E0MDk2IFNIQTM4NCAyMDIx
# IENBMQIQD0un28igrZOh2Z+6mD8+TTANBglghkgBZQMEAgEFAKCBhDAYBgorBgEE
# AYI3AgEMMQowCKACgAChAoAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3AgEEMBwG
# CisGAQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCDrDCtz
# Xhn5LYFiZSOiEbPWKePREluxUR/3/RMlHNa+wzANBgkqhkiG9w0BAQEFAASCAgCS
# bHslT1ygpMhaaYXbDX2hz8nCBDLAYiKZlD+FqV2cC8b10Bx/JJM45p0gU3iIIeCm
# w0e7UzzEw7iZP6wh5tIbthNTERsA7Hx2cc1RO9UNjNgn4JK75u1CeQzZEB79iUb1
# Nc51Wk5/eFL5uxJZQUhH78EYYv3+/2Oj8n4Ti5XnxhmyMYVqGtSxON7CEZMwkUpA
# NuPulMvwqC6z0yMslExcZmQwzPmIJI+99RseIMwthByeK9i6IOdM1sHLHucCsqPw
# qo66/nQJtAuRvigN0uuxBPniV82YRhs3w7gB+mgSsjhbDZg1YQVCuz6doVnNBYcb
# jDamsoA7eQTWeBzQdAJS8KH/4XZeQpgexZv7aXZAtsbEU3Lj6drO0ieqs8l/DtcR
# UBxFLoP0GSTtbFKAyrv49riUgY1tJ8KO6yNLae32b1mfInqjN/vosRe1giWl/6GH
# c51hQrsw04szywpvhSpruuT0Dmd3dZSC6Au+jB78IcYMNqMqvqQwOM+laJait+h6
# rbaGWxjQY7jKNdPKf60v2xGXpAdRcEAho8sE1c+3PNgwa8uU8WkwYeyK6UicUbe0
# sEfDN4riYew3XdamuN1p71svpUut/jZFtGfZdgATiFL4xLxt2ffWl8LWUkUuSJG2
# 5XnO+042vH1tDzRFJ2Wo2PGahYE7NNzJ5SooaRQeRKGCAyYwggMiBgkqhkiG9w0B
# CQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdpQ2Vy
# dCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1lU3RhbXBp
# bmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAqA7xhLjfEFgtHEdqeVdGgwDQYJ
# YIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwGCSqGSIb3
# DQEJBTEPFw0yNTA2MTIxNjA4MDZaMC8GCSqGSIb3DQEJBDEiBCCj67+eVBWYfY8W
# Le8v9cjqxCbxZ0lFx5BTORN2wQhnGjANBgkqhkiG9w0BAQEFAASCAgA2Q8dd+vhm
# 9u46ggM2lImBmkaKrVmkQ4Ry6SR3NaQdcW1d5e89MJhRJtQLGX4zWLikGVXMh4Wx
# ouMdgu1lbZ4XjcsOBSIF2W8zBPogqFkmBU3piRS6U4vVAri9dKSNTV3cNyrVaVe9
# gWhwTLiiGu1I/LQOnoTlSL5zXxmpEEqSzpQSxZDdix56ni/Xm1/O55ITLm0FftAd
# JLvo/Z3c8ZPf4vTbBmuo53/8UBujOGPLCgdh2FlbHNwnXjTEIy1hpTq3yRXyUUGH
# apHq0IitLciE91O0MZXdt05bi5Ro7iZCvSdxHdKYGPySZmAlJXVW2HOgnoWf5z6f
# Uc8HfuiLgBuSgTXCVJTFyH/5tT+q4zGGbQiVsjHSgceQFSdLw+7IwwLmHIPZwwTk
# SARNwkOZoQwJNiTedmA2+77Dn92jmWQ2J7pfpkxp5WYvYlOQD0ftkvb9XMA3Nqor
# hdb2DAMvDTrM08RlucgqYjzmJ75NqVBtsBtm4ijEaIpPgcK8SqMks51vmuMJ4m27
# Nlj8CkUfu1D8wNHU7I1d83whFaAgiOY+/C++AAFI0SgKw2HHF8Sf24WRV859cCDG
# Wm4juQNvhfiCNFdcZZFr7TqQZEL/eCkYq55oQRBAWigSLMYMQWMQ8oXGoeDPXoQG
# 6tUeooLbSotpAV7n55CxuqmcmZZ5ApgBhw==
# SIG # End signature block
