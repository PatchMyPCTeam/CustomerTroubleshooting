#Requires -RunAsAdministrator

#region functions
function Write-Log {
    param(
        [Parameter(Mandatory)]
        [String]$Message,
        
        [Parameter()]
        [String]$LogPath = ('{0}\Publisher-Impact-Check.log' -f $env:temp)
    )
    
    $Timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $LogEntry = "[$Timestamp] $Message"
    Add-Content -Path $LogPath -Value $LogEntry -ErrorAction SilentlyContinue
}

function Write-Result {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Yes','No')]
        [String]$Impacted,

        [Parameter()]
        [datetime]$DateOfImpact,

        [Parameter(Mandatory)]
        [ValidateSet(1,2,3)]
        [Int]$Scenario,

        [Parameter(Mandatory)]
        [String]$Advice,

        [Parameter()]
        [String[]]$Win32AppIds
    )

    Write-Host 'Impacted: ' -NoNewline
    if ($Impacted -eq 'Yes') {
        Write-Host 'Yes' -ForegroundColor Red
    }
    else {
        Write-Host 'No' -ForegroundColor Green
    }

    if ($Impacted -eq 'Yes') {
        $CulturefInfo = Get-Culture
        Write-Host ('Date of Impact: {0}' -f $DateOfImpact.ToString($CulturefInfo.LongDatePattern))
    }

    Write-Host ('Scenario: {0}' -f $Scenario)

    if ($Impacted -eq 'No') {
        $Advice = 'No action required'
    }

    Write-Host 'Advice:'
    Write-Host "`t- $Advice"

    if ($Win32AppIds -and $Win32AppIds.Count -gt 0) {
        Write-Host "`t- Remove these apps from Intune:"
        foreach ($AppId in $Win32AppIds) {
            Write-Host "`t`t- $AppId"
        }
    }

    Write-Host ''
    Write-Host 'More information: ' -NoNewline
    Write-Host ('https://patchmypc.com/config-overlap?scenario={0}' -f $Scenario) -ForegroundColor Cyan

    $f = 'yyyy-MM-dd'
    $Message = [ordered]@{
        Impacted     = $Impacted
        DateOfImpact = if ($Impacted -eq 'Yes') { $DateOfImpact.ToString($f) + " ($f)" } else { 'N/A' }
        Scenario     = $Scenario
        Advice       = $Advice -replace "`t" -replace "`n"
        Win32AppId   = $Win32AppIds
    }
    Write-Log -Message ('Result: {0}' -f ($Message | ConvertTo-Json))
    Write-Log -Message 'Finished Patch My PC Publisher Configuration Overlap Detection'
}

function Get-InstalledSoftware {
    param(
        [Parameter(Mandatory)]
        [String]$DisplayName
    )

    $PropertyNames = 'DisplayName', 'DisplayVersion', 'PSChildName', 'Publisher', 'InstallDate', 'InstallLocation', 'WindowsInstaller'

    $AllFoundObjects = Get-ItemProperty -Path 'registry::HKEY_LOCAL_MACHINE\Software\Microsoft\Windows\CurrentVersion\Uninstall\*' -Name $propertyNames -ErrorAction SilentlyContinue

    foreach ($Result in $AllFoundObjects) {
        if ($Result.DisplayName -notlike $DisplayName) {
            #Write-Verbose ('Skipping {0} as name does not match {1}' -f $Result.DisplayName, $DisplayName)
            continue
        }

        if ([bool]$Result.WindowsInstaller -ne [bool]1) {
            continue
        }

        $Result | Select-Object -Property $PropertyNames
    }
}

function Test-Scenario {
    param(
        [Int]$Id,
        [System.Xml.XmlElement]$Settings,
        [PSObject[]]$PublishingHistory
    )

    switch ($Id) {
        1 { return (Test-Scenario1) }
        2 { return (Test-Scenario2 -Settings $Settings) }
        3 { return (Test-Scenario3 -Settings $Settings) }
        4 { return (Test-Scenario4 -Settings $Settings) }
        5 { return (Test-Scenario5 -Settings $Settings) }
        6 { return (Test-Scenario6 -PublishingHistory $PublishingHistory) }
        default {
            $Message = 'Invalid scenario id {0} specified' -f $Id
            Write-Log -Message $Message
            throw $Message
        }
    }
}

function Test-Scenario1 {
    <#
        Check if any saves have occured between upgrading to an impacted version and a bug fix version
        e.g. if no saves = not impacted, otherwise continue reviewing other scenarios
    #>

    Write-Log -Message 'Test-Scenario1: Check if any saves have occured between upgrading to an impacted version and a bug fix version. If no saves = not impacted, otherwise continue reviewing other scenarios.'

    $Start = Get-Date -Year 2025 -Month 8 -Day 27
    try {
        $MsiEvents = Get-WinEvent -FilterHashtable @{
            LogName      = 'Application'
            ProviderName = 'MsiInstaller'
            Id           = 1033
            StartTime    = $Start
        } -ErrorAction 'Stop' | Where-Object {
            $_.Message -like '*Patch My PC Publishing Service*'
        }
    }
    catch {
        if ($_.FullyQualifiedErrorId -like 'NoMatchingEvents*') {
            $MsiEvents = @()
        }
        else {
            throw
        }
    }

    $Timeline = foreach ($MsiEvent in $MsiEvents) {
        $ver = $null
        if ($MsiEvent.Message -match '(\d+(?:\.\d+){3})\.\s*') { $ver = $Matches[1] }

        [pscustomobject]@{
            Time   = $MsiEvent.TimeCreated
            Version = $ver
        }
    }

    $Timeline = $Timeline | Sort-Object Time

    $ImpactedVersions = @(
        [System.Version]'2.1.37.0',
        [System.Version]'2.1.41.0',
        [System.Version]'2.1.43.0',
        [System.Version]'2.1.43.1',
        [System.Version]'2.1.43.12',
        [System.Version]'2.1.46.0',
        [System.Version]'2.1.46.2',
        [System.Version]'2.1.50.2',
        [System.Version]'2.1.50.6'
    )

    $ImpactedVersionInstallDate = $Timeline | Where-Object {
        $ImpactedVersions -contains [System.Version]$_.Version
    } | Select-Object -First 1

    # If there is no record of an impacted version being installed, assume the earliest possible date
    if ([String]::IsNullOrWhitespace($ImpactedVersionInstallDate)) {
        $ImpactedVersionInstallDate = [PSCustomObject]@{
            Version = '0.0.0.0'
            Time    = $Start
        }
    }

    Write-Log -Message ('Test-Scenario1: First impacted version {0} installed on date {1}' -f 
                            $ImpactedVersionInstallDate.Version,
                            $ImpactedVersionInstallDate.Time.ToString('yyyy-MM-dd HH:mm:ss'))

    $BugFixVersionInstallDate = $Timeline | Where-Object {
        $_.Version -eq '2.1.50.0' -or [System.Version]$_.Version -gt [System.Version]'2.1.50.11'
    } | Select-Object -First 1

    # If there is no record of a bug fix version being installed, assume the latest possible date
    # It's very unlikely that this and the $ImpactedVersionInstallDate are both null
    # However the intent here is to regardless go hunting in event viewer for evidence of saves
    # The objective of trying to find an accurate date is to try and accurately advise the customer when to restore from
    if ([String]::IsNullOrWhitespace($BugFixVersionInstallDate)) {
        $BugFixVersionInstallDate = [PSCustomObject]@{
            Version = '0.0.0.0'
            Time    = Get-Date
        }
    }

    Write-Log -Message ('Test-Scenario1: Bug fix version {0} installed on date: {1}' -f 
                            $BugFixVersionInstallDate.Version,
                            $BugFixVersionInstallDate.Time.ToString('yyyy-MM-dd HH:mm:ss'))

    try {
        $Saves = Get-WinEvent -FilterHashtable @{
            LogName   = 'Patch My PC Publishing Service'
            Id        = 3009
            StartTime = $ImpactedVersionInstallDate.Time
            EndTime   = $BugFixVersionInstallDate.Time
        } -ErrorAction 'Stop'
    }
    catch {
        if ($_.FullyQualifiedErrorId -match 'NoMatchingEvents|NoMatchingLogsFound') {
            $Saves = @()
        }
        else {
            throw
        }
    }

    # Any backup available prior to this date is best 
    if ($Saves.Count -gt 0) {
        Write-Log -Message ('Test-Scenario1: Impacted. {0} saves found between upgrading to an impacted version and a bug fix version.' -f $Saves.Count)
        return $ImpactedVersionInstallDate.Time
    }
    else {
        Write-Log -Message 'Test-Scenario1: Not impacted. No saves found between upgrading to an impacted version and a bug fix version.'
        return $false
    }
}

function Test-Scenario2 {
    <#
        If Intune Apps and Intune Updates have identical DefaultOptions
    #>
    param(
        [System.Xml.XmlElement]$Settings
    )

    Write-Log -Message 'Test-Scenario2: Check if Intune Apps and Intune Updates have identical right-click options at All Products level (aka "DefaultOptions"). If identical and contain IntuneAssignments = impacted, otherwise not impacted.'

    $DefaultOptionsDefaultValueXml = '<Vendor name="AllVendors" inherited="False" />'

    # This reads funny because of the -not operator, but it essential means "if they are identical"
    if (-not (Compare-Object $Settings.DefaultOptions.Options.InnerXml @($DefaultOptionsDefaultValueXml,$DefaultOptionsDefaultValueXml))) {
        # If DefaultOptions are not configured and are default values, then not impacted
        Write-Log -Message 'Test-Scenario2: Not impacted. DefaultOptions are not configured and are default values.'
        return $false
    }
    else {
        # However, if DefaultOptions are configured, then check if they are identical and contain IntuneAssignments = flag as impacted
        $IntuneApps    = $Settings.DefaultOptions.Options | 
                            Where-Object { $_.target -eq 'Intune Applications' } | 
                            Select-Object -ExpandProperty Vendor | 
                            Where-Object { $_.Name -eq 'AllVendors' }
        $IntuneUpdates = $Settings.DefaultOptions.Options | 
                            Where-Object { $_.target -eq 'Intune Updates' } | 
                            Select-Object -ExpandProperty Vendor | 
                            Where-Object { $_.Name -eq 'AllVendors' }

        if ([String]::IsNullOrWhiteSpace($IntuneApps.InnerXml) -or [String]::IsNullOrWhiteSpace($IntuneUpdates.InnerXml)) {
            Write-Log -Message 'Test-Scenario2: Not impacted. IntuneAssignments is not configured for one of the Intune Apps or Intune Updates tabs.'
            return $false
        }
        elseif (-not (Compare-Object $IntuneApps.InnerXml $IntuneUpdates.InnerXml) -and $Settings.DefaultOptions.Options.InnerXml -match 'IntuneAssignments') {
            Write-Log -Message 'Test-Scenario2: Impacted. DefaultOptions are configured, are identical and contain IntuneAssignments.'
            return $true
        }
        elseif (-not (Compare-Object $IntuneApps.InnerXml $IntuneUpdates.InnerXml)) {
            Write-Log -Message 'Test-Scenario2: Not impacted. DefaultOptions are identical but do not contain IntuneAssignments.'
            return $false
        }
        else {
            Write-Log -Message 'Test-Scenario2: Not impacted. DefaultOptions are not identical.'
            return $false
        }
    }
}

function Test-Scenario3 {
    <#
        Check if products in both tabs have identical config
        e.g. product selections and right click options (where applicable)
    #>
    param(
        [System.Xml.XmlElement]$Settings
    )

    Write-Log -Message 'Test-Scenario3: Check if products in both tabs have identical configuration. For example, product selections and right-click options (where applicable).'

    $EvaluatedProducts = @{}
    $Result = @{}
    $Apps = [array]$Settings.Applications.SearchPattern
    $Updates = [array]$Settings.Updates.SearchPattern

    Write-Log -Message ('Test-Scenario3: Found {0} product(s) in Intune Apps and {1} product(s) in Intune Updates.' -f $Apps.Count, $Updates.Count)

    foreach ($PackageType in $Apps, $Updates) {
        # This function shouldn't be called if the tenant's tabs are disabled or have zero products enabled in either tab, but just in case
        if ([String]::IsNullOrWhiteSpace($PackageType)) {
            return $false
        }

        foreach ($_Product in $PackageType) {
            # These are the right-click options common between Intune Apps and Intune Updates
            $Object = [PSCustomObject]@{
                ProductName                     = [String]$_Product.Product
                ProductId                       = [String]$_Product.ProductId
                VendorId                        = [String]$_Product.VendorId
                Excluded                        = [String]$_Product.Excluded
                AdditionalArg                   = [String]$_Product.AdditionalArg
                PreCommand                      = [String]$_Product.PreCommand
                PreCommandArg                   = [String]$_Product.PreCommandArg
                AbortOnPreScriptFail            = [String]$_Product.AbortOnPreScriptFail
                PostCommand                     = [String]$_Product.PostCommand
                PostCommandArg                  = [String]$_Product.PostCommandArg
                EnableLogging                   = [String]$_Product.EnableLogging.OuterXml
                VerboseLogging                  = [String]$_Product.VerboseLogging
                LoggingFolder                   = [String]$_Product.LoggingFolder
                FailedInstallLogFolder          = [String]$_Product.FailedInstallLogFolder
                SelfUpdater                     = [String]$_Product.'Self-Updater'.InnerXml
                ReturnCodes                     = [String]$_Product.ReturnCodes.InnerXml
                BlockingProcessManagementPolicy = [String]$_Product.BlockingProcessManagementPolicy.InnerXml
                KillProcessList                 = [String]$_Product.KillProcessList
                TransformFile                   = [String]$_Product.TransformFile
                AdditionalFiles                 = [String]$_Product.AdditionalFiles.File
                AdditionalFolders               = [String]$_Product.AdditionalFolders.Folder
                IntuneCategoryIDs               = [String]$_Product.IntuneCategoryIDs.CategoryId
                IntuneRoleScopeTagIDs           = [String]$_Product.IntuneRoleScopeTagIDs.RoleScopeTagId
                IntuneNamingConvention          = [String]$_Product.IntuneNamingConvention
                IntuneAssignments               = [String]$_Product.IntuneAssignments.IntuneAssignment.InnerXml
            }

            if ($EvaluatedProducts[$_Product.ProductId]) {
                # This reads funny because of the -not operator, but it essential means "if they are identical"
                if (-not (Compare-Object $Object $EvaluatedProducts[$_Product.ProductId] -Property $Object.PSObject.Properties.Name)) {
                    $Result[$_Product.ProductId] = $true
                }
            }
            else {
                $EvaluatedProducts[$_Product.ProductId] = $Object
            }
        }
    }

    # If the number of products with the same ProductId in both tabs is greater than 10, then use a percentage threshold of 90% to determine if impacted
    # If there are fewer than 10 products enabled in either tab, then all products with the same ProductId in both tabs must be identical to be considered impacted
    # Otherwise return $false
    $TrueCount = ([array]$Result.Values).Count
    $TotalCount = if (([array]$Settings.Applications.SearchPattern).Count -ge ([array]$Settings.Updates.SearchPattern).Count) {
        ([array]$Settings.Updates.SearchPattern).Count
    }
    else {
        ([array]$Settings.Applications.SearchPattern).Count
    }
    $Threshold = 90
    
    if ($TotalCount -gt 10) {
        $PercentageTrue = ($TrueCount / $TotalCount) * 100
        if ($PercentageTrue -ge $Threshold) {
            Write-Log -Message ('Test-Scenario3: Impacted. {0}% of products with the same ProductId, present in both the Intune Apps and Intune Updates tabs, have identical right-click options configuration.' -f 
                            [math]::Round($PercentageTrue,2))
            Write-Log -Message ('Test-Scenario3: Product Ids: {0}' -f ($Result.Keys | ConvertTo-Json))
            return $true
        }
    }
    elseif ($TrueCount -gt 0 -and $TrueCount -eq $TotalCount) {
        Write-Log -Message ('Test-Scenario3: Impacted. {0} product(s) found with the same ProductId(s), present in both the Intune Apps and Intune Updates tabs, have identical right-click options configuration.' -f 
                        $TrueCount)
        Write-Log -Message ('Test-Scenario3: Product Ids: {0}' -f ($Result.Keys | ConvertTo-Json))
        return $true

    }
    else {
        Write-Log -Message ('Test-Scenario3: Not impacted. {0} product(s) found with the same ProductId(s), present in both the Intune Apps and Intune Updates tabs and have identical right-click options configuration. However, there is {1} product(s) enabled in both tabs but with different configuration. This is below the threshold to declare as impacted.' -f 
                        $TrueCount, ($TotalCount - $TrueCount))
        Write-Log -Message ('Test-Scenario3: Product Ids: {0}' -f ($Result.Keys | ConvertTo-Json))
        return $false
    }
}

function Test-Scenario4 {
    <#
        Check if any product has a tab-specific XML element in the incorrect tab
    #>
    param(
        [System.Xml.XmlElement]$Settings
    )

    Write-Log -Message 'Test-Scenario4: Check if any product has a tab-specific XML element in the incorrect tab. For example, if any Intune Update has an Available assignment or IntuneAppEspIDs.'

    if ($Settings.DefaultOptions.Options.Where{$_.target -eq 'Intune Updates'}.Vendor.IntuneAssignments.IntuneAssignment.Intent -contains 'available') {
        Write-Log -Message 'Test-Scenario4: Impacted. Intune Updates DefaultOptions has an Available assignment.'
        return $true
    }

    $UpdatesWithAvailableAssignment = $Settings.Updates.SearchPattern | Where-Object {
        $_.IntuneAssignments.IntuneAssignment.Intent -contains 'available'
    } | Select-Object -ExpandProperty ProductId

    if (-not [String]::IsNullOrWhiteSpace($UpdatesWithAvailableAssignment)) {
        Write-Log -Message 'Test-Scenario4: Impacted. At least one Intune Update has an Available assignment.'
        Write-Log -Message ('Test-Scenario4: Product Ids: {0}' -f ($UpdatesWithAvailableAssignment | ConvertTo-Json))
        return $true
    }

    $UpdatesWithEspIds = $Settings.Updates.SearchPattern | Where-Object {
        -not [String]::IsNullOrWhiteSpace($_.IntuneAppEspIDs)
    } | Select-Object -ExpandProperty ProductId

    if (-not [String]::IsNullOrWhiteSpace($UpdatesWithEspIds)) {
        Write-Log -Message 'Test-Scenario4: Impacted. At least one Intune Update has IntuneAppEspIDs configured.'
        Write-Log -Message ('Test-Scenario4: Product Ids: {0}' -f ($UpdatesWithEspIds | ConvertTo-Json))
        return $true
    }

    Write-Log -Message 'Test-Scenario4: Not impacted. No tab-specific XML elements found in the incorrect tab.'
    return $false
}

function Test-Scenario5 {
    <#
        Check if a product incorrectly appears in the incorrect tab
        e.g. App-only pkgs appearing in Intune Updates, or Update-only pkgs appearing in Intune Apps
    #>
    param(
        [System.Xml.XmlElement]$Settings
    )

    # These ProductIds are true as of 2025-10-07
    $UpdateOnlyProductIDs = @(
        'b28160cd-53ab-443f-b420-5e461eb190b0',
        '56f28ca6-2311-4749-ad3d-93ff48a3cc12',
        '64e18647-0fa4-42ac-af0e-28bb20306cab',
        'c3e232e4-9cfa-4deb-b531-2246022717c9',
        'a8780c71-b528-41bb-ab77-46b942f4a3de',
        '49d8883a-c283-4c44-bc28-2a6c45ab4bc5',
        '57277296-8373-4713-8786-15d9efefc6f4',
        '06cde3f6-3758-4190-8179-8702eb01d64d',
        '57ed7de6-d7b6-44d2-9ac2-bdc09d29f649',
        '25408374-d64d-427b-9a36-faa90c4f31bd',
        '6d07768d-2f7f-4584-a16d-122de0e7de3b',
        '81106c45-1725-47eb-8ebb-66cf4d011ec8',
        'd5ae7e63-ad2a-4415-b117-e524ef29759f',
        '6ec0d3c5-4376-4a21-8620-cee681110b4c',
        'b654c1e1-cdc4-4184-b96d-c15dd2ea5d3e',
        'a1d01ccd-27c1-4d65-a0c1-9c282d621744',
        '940bc51b-f907-40ab-a3b2-31663158ec50',
        '9bb3f3f7-044e-488a-9f11-aac42dfa97c6',
        'd023f9a2-0dbe-4631-b3f6-636ab02bc766',
        '9ebf7476-1cbf-4662-adf1-028e6fad866b',
        '1e431836-bc76-42a4-abcc-62ccb4d37bba',
        'c8b2b49f-8d7b-4381-818f-750941a9f58c',
        'ab3fba47-1425-4954-8456-998e52bc1082',
        'e70e0fc2-b0af-4399-9e81-05ac1d2d5c7b',
        '06686683-85cd-4517-9d99-1e8bb7c9e74f',
        '88f532a0-3988-4d77-b0dc-c239d1826049',
        '40cc6335-71d9-4e3c-bc24-a39c3fb9225a',
        '6fb7c4c2-a2ac-4d57-abf9-60ffb51bfb15',
        'e1bd69ad-033a-4ade-9afa-5d24698600ce',
        '4c493091-891b-434f-a552-a2502f7a76db',
        '85feded8-8083-4dc5-b1c2-98854e6b3123',
        '75997370-cffc-44e0-9741-d24eddcbd880',
        '04672dcc-26f9-4c0c-a004-421dd269a100',
        'def7b0cc-69ea-4fb8-b4d8-143c1d1a947a',
        '1ce00f1d-b763-4da5-a5cc-04007a8ca527',
        '0d6e262a-9547-48ac-b3b5-94d33cedaf92',
        '7b2ddcab-5d01-42bd-828e-a6ab659c4c18',
        '5c53a8f3-d454-4919-85c9-e3b410ccb4b0',
        '32a3b19f-d15e-4880-95e9-a411f65eb13a',
        '372fc63a-6a8f-460d-bc20-4bc5e14d7cd6',
        '4727da73-22fe-414b-b11a-fdd24e0a6778',
        'c5da90fd-209f-47db-993a-db9a509994d1',
        'ba8261aa-5c7c-448c-8afb-b22ad727bd9d',
        '9461aa65-ba06-4d4b-a0b1-383ff3aab57a',
        'f6e50fee-7d76-4b61-b37a-df7e7619db01',
        'cde536ea-7313-4dd1-96ac-1e68f9ae5ff0',
        '44434b72-dc75-4ba2-b492-c692818f4cd2',
        '8f09a716-42d9-4335-8829-53e756ff630f',
        'f35e2a42-c421-420f-92eb-5c43df46bc9c',
        '3b2605c7-12ff-403d-92aa-293c5d3f16a9',
        'c6376f5f-8862-420e-9afb-00923909fa8c',
        '98178e6e-aa94-47da-893f-2cb220aa946f',
        '7a874f06-59c6-44fb-9aa9-64124cfe57d3',
        '49c0e0c3-b5ce-4956-b3fc-879b01cd4831',
        'b88c017e-83fd-4361-8290-350b4f2cbbbc',
        'cc881982-12cf-4e66-b8f7-450e22cc2789',
        '8fe137fe-f29e-4594-9937-2720ad2878dd',
        '690a4acc-48ef-4c52-97df-60073911b824',
        '89f697c1-53f3-4943-9d77-855e6b88d7d8',
        '62981eb6-6be7-45d9-bf9e-9a24b44b863c',
        'dff8d651-c6f3-4106-977a-58e73fb91301',
        'f70bdd62-9a63-492d-b855-017d88029055',
        'fa5cd52a-96bf-4769-8639-144f4a070b44',
        '95bdd25d-877c-4fa9-9b5d-614f9fc0cfe2',
        '6d6121bf-6f36-4a73-8f17-ade6258996e8',
        '45540849-6023-4f9e-bddb-618b7a072f29',
        'e05aff50-e749-4a7e-9aa8-873a5db65791',
        'cd1e37ce-d908-405f-8c9c-001ff0b26cdb',
        '63c917b3-e07c-4629-bb98-425303866160',
        'af2efb15-98d1-4999-a56b-67078e99f5c8',
        '97f9dc73-56ad-4b45-95b5-9a0ba6399978',
        'ce67e3ee-250f-4eb7-b50d-aee8d88ae665',
        '224b37ed-0399-4f11-bad7-d8adadb9ac0c',
        'ea23b577-3aa1-4d99-a4f7-4ca287efa0b6',
        'e9cd2204-0b52-42a2-a620-93cf08f458c1',
        '9ca5468c-4b81-4418-89a8-dd5926998f7f',
        'a2644695-273b-41b3-a68e-3f1cbfd3d59b',
        '87805519-48c9-4fe0-a3ee-36db74dcf521',
        'ab267a78-0a81-41f9-a910-d82bfcbaf43d',
        '06f2c843-a03f-4e48-9b4e-b2ff3043ffcf',
        '87a81558-c020-4c40-b4b7-7699ad3e8819',
        'aa6eb67b-34fa-4b33-8b71-ad0e6cecfdc8',
        'a6cc69ec-3f05-48e4-a876-7dacbf2e9bae',
        '54d7ba3c-d3e7-4385-9178-5fb446c48c79',
        'fb7a3e24-789e-4e2b-8e1a-0b8bc4194f24',
        '4271c667-ed5c-4f2f-a0bc-ddea4e16f184',
        'b73d122c-2af6-41f9-ab85-653f8034a468',
        '6c7f672b-793c-45bb-8f94-577699b65477',
        '6119ddec-eace-4608-9ac2-4d9fef678cb9',
        '72c98113-c999-4a18-a7c7-4e8109b1327b',
        '8e8fb589-6b3e-417a-82ba-35cb307a8195',
        '2619260c-d6f9-4292-9a52-7ec128c175da',
        '3fbcd8f3-5463-459a-8807-b4a359c6db6b',
        'a48a529e-aad1-498f-a091-5c37fb14e8d0',
        '5871d64c-425a-433e-9410-fd733060405f',
        '139c57f2-084d-4bb8-9c47-97179769f874',
        '5a85a030-b7df-4140-8c72-20f3bdfbf3bf',
        '27aa91b9-1cda-459d-a30e-6dcf6c9ad894',
        '3f571230-c515-43d3-907d-94aa28ddedda',
        'deee28af-07b1-4b8b-b01b-8fd7a4fa1b4b',
        '1c8546ac-284d-4c7b-b008-0ae23d53d503',
        'd13a967c-7f6d-49eb-952a-ce07f10cf563',
        '78b281d5-eac3-4f83-89d6-0cf693e0c8d7',
        '2722009c-f084-40d0-8aad-afdc8a421847',
        'e07b34e5-3238-4a81-9c11-8644826635bc',
        '5b602728-dd0d-4c98-bcce-a3b0ff81a9f3',
        '9a51c4d0-2c80-463e-895e-894ecd56613b',
        '59ab310f-51c9-419f-86f9-4aae8d4a9fae',
        '9601616b-14b2-4c21-a154-a06ef75f99df',
        '8d5c8aae-efee-477b-9f7d-24d4da1f4b5b',
        '6e387287-13ea-4c5e-8c14-2680a01bb826',
        'a758dd75-9f33-4ee7-9d7a-4668545e1f15',
        '06b03938-2627-4a5f-bf38-2f032aa4ea45',
        '69692150-9a36-4d8a-889c-3a5b87f26da6',
        '405b090a-1138-43a3-b1a7-371e6431cfff',
        '90d1eeda-db58-4443-813f-3c195b023d99',
        '5fa7f2b6-5264-4c36-9660-75beaf094126',
        '086ea912-719d-4141-9b01-336946ed591e',
        'ae5dba49-36b8-4e2f-870f-421530b10111',
        '67087298-4e94-48c7-9b3a-fc1ac871ace2',
        '7f619173-dd90-4ece-9f07-55c05218e465',
        '0b14a40e-d9df-4f83-b248-0c41db447f77',
        'c84406fa-4758-4957-9dca-79cfbc143e34',
        '99127edf-84ec-4fcc-813f-a4d62648cd60',
        'fda3c011-722e-4e5b-b409-9da52ed913d6',
        '363db78c-de91-46d3-adf8-a03c21958f5b',
        'f0f3ebbb-6bbf-40d5-a35f-83258925b619',
        '6327906c-934d-47b9-a8f2-885b825259ad',
        '1e6bf9dc-84cb-4a6e-8ccd-5b334ed04644',
        'c4349cee-0499-459b-8213-c0495f663160',
        'dcdf667a-1794-4116-b706-9cc5d1f8738f',
        'a316dcea-ec64-4e23-81a2-8fbb9524f9ef',
        'dd6583b3-29cc-46ea-80af-ddaa68ff3625',
        '618f1228-c861-4737-be8a-0d385acda85c',
        'e80be9a2-f535-4c0c-b12b-e48fc7952d33',
        'bf8c4d16-8bee-4b2c-87ec-eeb4b7cdb333',
        'ff78b118-a4c6-423b-8605-a6afed4e99ca',
        '3f87c470-cf8d-4a10-9caf-56dd28de07ef',
        '599f0dbc-3271-4999-be16-661c6530de1f',
        'cd272d0f-2a17-4405-97f7-6b3e94bdeca3'
    )

    $AppOnlyProductIDs = @(
        'f8d7a92e-94d3-4724-b064-522608554038',
        '91bcb322-74f0-4370-afe0-4c2eb95223db',
        '7e9b260a-f65e-4367-a477-b62485d64c41',
        '74d4ffe7-7785-4b80-ae93-31357eda8b6a',
        'ae68a0b5-8216-4c5d-ac03-ef3945d8d18c',
        '363fb724-09f1-41ac-9e56-3619ef2bdd92',
        '96f4f1c8-1a51-4c33-ab01-be47ad0266bb',
        '16ea4cf9-2a74-449a-afea-3791efe74f2e',
        '7d4891f1-4365-42a3-b971-c358da2f3e55',
        'a5f99151-67d8-4f41-acfc-9fec440cd9cd',
        'fb40df3c-a0f5-4f90-a97e-40e5a7df0e11',
        'ec014f48-7b7f-4b87-b2a9-14f3814eaebd'
    )

    Write-Log -Message 'Test-Scenario5: Check if a product incorrectly appears in the incorrect tab. For example, App-only packages appearing in Intune Updates, or Update-only packages appearing in Intune Apps.'

    $IntuneUpdates = foreach ($Product in $Settings.Updates.SearchPattern) {
        if ($AppOnlyProductIDs -contains $Product.ProductId) {
            $Product.ProductId
        }
    }

    $IntuneApps = foreach ($Product in $Settings.Applications.SearchPattern) {
        if ($UpdateOnlyProductIDs -contains $Product.ProductId) {
            $Product.ProductId
        }
    }

    $ReturnTrue = $false
    if (([array]$IntuneUpdates).Count -gt 0) {
        Write-Log -Message ('Test-Scenario5: Impacted. These Product Id(s) incorrectly appear in the Intune Updates tab: {0}' -f ($IntuneUpdates | ConvertTo-Json))
        $ReturnTrue = $true
    }

    if (([array]$IntuneApps).Count -gt 0) {
        Write-Log -Message ('Test-Scenario5: Impacted. These Product Id(s) incorrectly appear in the Intune Apps tab: {0}' -f ($IntuneApps | ConvertTo-Json))
        $ReturnTrue = $true
    }

    if ($ReturnTrue) {
        return $true
    }
    else {
        Write-Log -Message 'Test-Scenario5: Not impacted. No App-only products appear in Intune Updates, and no Update-only products appear in Intune Apps.'
        return $false
    }
}

function Test-Scenario6 {
    <#
        Check if any products have been erroneously published
        e.g. App-only products published as an Intune Update, or Update-only products published as an Intune App
    #>
    param (
        [PSObject[]]$PublishingHistory
    )

    # These are all the update IDs of update-only products released since 2025-08-27 to 2025-10-09
    $UpdateOnlyUpdateIDs = @(
        '6900f4be-a854-4c2f-aee4-9941726aae66', 
        '212c9745-58e0-4cee-aa0d-f283adbba4a1', 
        '0449168d-6697-4f09-862d-0d2987d7bc3c', 
        '90dc5d37-1d41-4684-9894-d19be16dbbbe',
        '23fb1ba5-12a4-4e72-83ec-1ebef8abaf0d', 
        '5f0c66ba-9871-4a48-8d51-45faa977638d', 
        '5da123e8-1614-4bcb-b60a-0fa48facf335', 
        '217f2ed9-bf0b-4800-bab5-5e2694e435c6',
        '8e53900c-5982-42a0-a03d-89563d2137bf',
        '57f56ce0-efe9-44ab-aa5c-530c75a09b68',
        '0ab0fe4a-fc6d-4208-8cad-f42a4099cceb', 
        'e1541c5a-9b61-4578-a279-be29ebc0a1b6'
    )

    # These are all the update IDs of app-only products released since 2025-08-27 to 2025-10-09
    $AppOnlyUpdateIDs = @(
        '7fe05185-7841-42fd-9a3e-baef67526e46',
        '97641e25-07e5-4fb5-b2eb-f3f79e01e01b',
        '5aacaed0-a1d9-44fe-9e8e-d5bd2ce837c8', 
        '42378e7a-81ec-411c-bae6-69dae4be0157'
    )

    Write-Log -Message 'Test-Scenario6: Check if any products have been erroneously published. For example, App-only products published as an Intune Update, or Update-only products published as an Intune App.'

    $PublishedApps    = $PublishingHistory | Where-Object { $_.Operation -like 'IntuneApp*' }
    $PublishedUpdates = $PublishingHistory | Where-Object { $_.Operation -like 'IntuneUpdate*' }

    $ErroneouslyPublishedPkgs = foreach ($App in $PublishedApps) {
        if ($UpdateOnlyUpdateIDs -contains $App.UpdateId) {
            $App.Win32AppId
        }
    }

    $ErroneouslyPublishedPkgs += foreach ($Update in $PublishedUpdates) {
        if ($AppOnlyUpdateIDs -contains $Update.UpdateId) {
            $Update.Win32AppId
        }
    }

    if (([array]$ErroneouslyPublishedPkgs).Count -gt 0) {
        Write-Log -Message ('Test-Scenario6: Impacted. Erroneously published packages: {0}' -f ($ErroneouslyPublishedPkgs | ConvertTo-Json))
        return $ErroneouslyPublishedPkgs
    }
    else {
        Write-Log -Message 'Test-Scenario6: Not impacted. No erroneously published packages found.'
        return $false
    }
}
#endregion

Write-Log -Message 'Starting Patch My PC Publisher Configuration Overlap Detection'

$WriteResultParams = @{}

if ($ExecutionContext.SessionState.LanguageMode -eq 'ConstrainedLanguage') {
    Write-Warning 'This script cannot be run in Constrained Language Mode (CLM). Please run in full language mode.'
    return
}

Write-Log -Message 'Checking if Patch My PC Publishing Service is installed'
$Publisher = Get-InstalledSoftware -DisplayName 'Patch My PC Publishing Service'
Write-Log -Message ('ARP data: ' + ($Publisher | ConvertTo-Json))

if ([String]::IsNullOrWhitespace($Publisher)) {
    $Message = 'Patch My PC Publishing Service is not installed on this device'
    Write-Log -Message $Message
    Write-Warning $Message
    return
}

if ($Publisher.DisplayVersion -lt [System.Version]'2.1.37.0') {
    Write-Log -Message 'Not impacted as version is less than 2.1.37.0, quitting'
    Write-Result -Impacted 'No' -Scenario 1 -Advice 'No action required'
    return
}

$SettingsXmlPath = '{0}\Settings.xml' -f $Publisher.InstallLocation
if (-not (Test-Path $SettingsXmlPath)) {
    $Message = 'Patch My PC Publishing Service settings file {0} does not exist' -f $SettingsXmlPath
    Write-Log -Message $Message
    Write-Warning $Message
    return
}
else {
    $Settings = [xml](Get-Content -Path $SettingsXmlPath -ErrorAction 'Stop') | 
                    Select-Object -ExpandProperty 'PatchMyPC-Settings' | 
                    Select-Object -ExpandProperty 'IntuneTenants'
}

Write-Log -Message 'Beginning scenario tests'

$BackupRestoreDate = Test-Scenario -Id 1

if ($BackupRestoreDate -eq $false) {
    Write-Result -Impacted 'No' -Scenario 1 -Advice 'No action required'
    return
}

$BackupFolder = '{0}\Backup' -f $Publisher.InstallLocation
if (Test-Path $BackupFolder) {
    $BackupCabFile = Get-ChildItem -Path $BackupFolder -Filter 'Settings*.cab' -ErrorAction 'SilentlyContinue' | 
                        Where-Object { $_.LastWriteTime -le $BackupRestoreDate } |
                        Select-Object -Last 1
}

if (-not [String]::IsNullOrWhiteSpace($BackupCabFile)) {
    $WriteResultParams['Scenario']     = 2
    $WriteResultParams['DateOfImpact'] = $BackupRestoreDate
    $WriteResultParams['Advice']       = "Backup found on disk. Please restore from backup created on {0} found at:`n`t`"{1}`"" -f 
                                            $BackupCabFile.LastWriteTime, $BackupCabFile.FullName

    Write-Log -Message ('Found recommended backup .cab file: {0}' -f $BackupCabFile.Name)
}
else {
    $WriteResultParams['Scenario']     = 3
    $WriteResultParams['DateOfImpact'] = $BackupRestoreDate
    $WriteResultParams['Advice']       = 'Backup not found on disk. Please restore from backup created on or before {0}' -f $BackupRestoreDate

    Write-Log -Message 'No backup .cab file found on disk predating impacted version install date'
}

# Check tenant-specific scenarios (2-5)
$TenantImpacted = $false
foreach ($Tenant in $Settings.Tenant) {
    # Skip tenants that don't have both Apps and Updates enabled with products selected
    if (($Tenant.EnableApplications -ne 'True' -and $Tenant.EnableUpdates -ne 'True') -or
        ([String]::IsNullOrWhiteSpace($Tenant.Applications) -or [String]::IsNullOrWhiteSpace($Tenant.Updates))) {
        Write-Log -Message ('Skipping tenant "{0}" - Apps or Updates disabled or no products selected' -f $Tenant.Name)
        continue
    }

    Write-Log -Message ('Processing tenant: {0}' -f $Tenant.Name)

    # Test scenarios 2-5 for this tenant
    $TenantResults = foreach ($ScenarioId in 2..5) {
        Test-Scenario -Id $ScenarioId -Settings $Tenant
    }

    if ($TenantResults -contains $true) {
        $TenantImpacted = $true
    }
}

# Always check scenario 6 (erroneously published packages) regardless of tenant results
$Scenario6Result = $false
if ($BackupRestoreDate -ne $false -and $BackupRestoreDate -is [datetime]) {
    $PublishingHistoryCsv = '{0}\PatchMyPC-PublishingHistory.csv' -f $Publisher.InstallLocation
    
    if (-not (Test-Path $PublishingHistoryCsv)) {
        Write-Log -Message ('Publishing history file not found: {0}' -f $PublishingHistoryCsv)
    }
    else {
        try {
            $PublishingHistory = Import-Csv -Path $PublishingHistoryCsv -ErrorAction Stop | 
                Where-Object { [datetime]::Parse($_.Date) -gt $BackupRestoreDate }

            $Scenario6Result = Test-Scenario -Id 6 -PublishingHistory $PublishingHistory
        }
        catch {
            Write-Log -Message ('Failed to process publishing history: {0}' -f $_.Exception.Message)
        }
    }
}

if ($Scenario6Result -ne $false) {
    Write-Result -Impacted 'Yes' -Win32AppIds $Scenario6Result @WriteResultParams
    return
}
elseif ($TenantImpacted) {
    Write-Result -Impacted 'Yes' @WriteResultParams
    return
}

Write-Result -Impacted 'No' -Scenario 1 -Advice 'No action required'
return
