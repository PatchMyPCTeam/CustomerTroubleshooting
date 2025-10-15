<#
Scenarios Checked:
1. **Upgrade/Save Overlap**: Checks if any configuration saves occurred between installing an impacted version and a fixed version. If so, the environment may be impacted and a backup restore is recommended.
2. **Identical Default Options**: Checks if Intune Apps and Intune Updates have identical right-click options (DefaultOptions) at the All Products level, especially if both contain IntuneAssignments. If so, the environment is impacted.
3. **Identical Product Configurations**: Checks if products enabled in both Intune Apps and Updates have identical configuration (right-click options, etc). If a high percentage (≥90% if >10 products, or all if ≤10) are identical, the environment is impacted.
4. **Tab-Specific XML in Wrong Tab**: Checks if any product or default option has a tab-specific XML element (e.g., Available assignment or IntuneAppEspIDs) in the wrong tab. If so, the environment is impacted.
5. **Product in Wrong Tab**: Checks if app-only products appear in Intune Updates, or update-only products appear in Intune Apps. If so, the environment is impacted.
6. **Erroneous Publishing**: Checks if any products have been erroneously published (e.g., app-only products published as Intune Updates, or update-only products published as Intune Apps) using publishing history.

Expected Output:
- The script prints a summary of whether the environment is impacted, the scenario(s) detected, the date of impact (if applicable), and actionable advice (such as restoring from backup or removing specific apps from Intune).
- If impacted, it may list Win32 App IDs to remove and provide a link for more information.
- All results are logged to a file in the temp directory.

#>

if ($ExecutionContext.SessionState.LanguageMode -eq 'ConstrainedLanguage') {
    Write-Warning 'This script cannot be run in Constrained Language Mode (CLM). Please run in full language mode.'
    return
}

#region functions
function Test-Administrator {  
    $user = [Security.Principal.WindowsIdentity]::GetCurrent();
    (New-Object Security.Principal.WindowsPrincipal $user).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)  
}

function Write-Log {
    param(
        [Parameter(Mandatory)]
        [String]$Message,
        
        [Parameter(Mandatory)]
        [String]$LogPath
    )
    
    $Timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $LogEntry = "[$Timestamp] $Message"
    Add-Content -Path $LogPath -Value $LogEntry -ErrorAction SilentlyContinue
}

function Write-Result {
    param(
        [Parameter(Mandatory)]
        [String]$Path,

        [Parameter(Mandatory, ValueFromPipeline)]
        [PSCustomObject]$Result
    )

    $Result | Export-Csv -Path $Path -NoTypeInformation -Append -Encoding UTF8 -Force -ErrorAction SilentlyContinue
}

function Write-HostResult {
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

    # These are all the update IDs of update-only products as of 2025-10-10
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
        'e1541c5a-9b61-4578-a279-be29ebc0a1b6',
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

    # These are all the update IDs of app-only products as of 2025-10-10
    $AppOnlyUpdateIDs = @(
        '7fe05185-7841-42fd-9a3e-baef67526e46',
        '97641e25-07e5-4fb5-b2eb-f3f79e01e01b',
        '5aacaed0-a1d9-44fe-9e8e-d5bd2ce837c8', 
        '42378e7a-81ec-411c-bae6-69dae4be0157',
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

if (-not(Test-Administrator)) {
    Write-Warning 'This script must be run as an administrator.'
    return
}

$LogPath = '{0}\temp' -f $env:windir
if (-not (Test-Path $LogPath)) {
    $LogPath = $env:temp
    $PSDefaultParameterValues['Write-Log:LogPath'] = '{0}\PatchMyPC-Publisher-ConfigOverlap-Impact-Check.log' -f $LogPath
}
else {
    $PSDefaultParameterValues['Write-Log:LogPath'] = '{0}\PatchMyPC-Publisher-ConfigOverlap-Impact-Check.log' -f $LogPath
}

Write-Log -Message 'Starting Patch My PC Publisher Configuration Overlap Detection'

Write-Log -Message 'Checking if Patch My PC Publishing Service is installed'
$Publisher = Get-InstalledSoftware -DisplayName 'Patch My PC Publishing Service'
Write-Log -Message ('ARP data: ' + ($Publisher | ConvertTo-Json))

if ([String]::IsNullOrWhitespace($Publisher)) {
    $Message = 'Patch My PC Publishing Service is not installed on this device'
    Write-Log -Message $Message
    Write-Warning $Message
    return
}

$PSDefaultParameterValues['Write-Result:Path'] = '{0}\PatchMyPC-ConfigOverlapImpactDetection.csv' -f $Publisher.InstallLocation

if ($Publisher.DisplayVersion -lt [System.Version]'2.1.37.0') {
    Write-Log -Message 'Not impacted as version is less than 2.1.37.0, quitting'
    Write-HostResult -Impacted 'No' -Scenario 1 -Advice 'No action required'
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
    Write-HostResult -Impacted 'No' -Scenario 1 -Advice 'No action required'
    [PSCustomObject]@{
        Date     = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        Impacted = 'No'
        Scenarios = ''
    } | Write-Result
    return
}

$BackupFolder = '{0}\Backup' -f $Publisher.InstallLocation
if (Test-Path $BackupFolder) {
    $BackupCabFile = Get-ChildItem -Path $BackupFolder -Filter 'Settings*.cab' -ErrorAction 'SilentlyContinue' | 
                        Where-Object { $_.LastWriteTime -le $BackupRestoreDate } |
                        Select-Object -Last 1
}

$WriteResultParams = @{}
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

# Track the scenarios that were found to be impacted
$ScenarioImpactTracker = @()

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
        if (Test-Scenario -Id $ScenarioId -Settings $Tenant) {
            $ScenarioImpactTracker += $ScenarioId
            $true
        }
        else {
            $false
        }
    }

    if ($TenantResults -contains $true) {
        $TenantImpacted = $true
    }
}

# Always check scenario 6 (erroneously published packages) regardless of tenant results
$Scenario6Result = $false
$PublishingHistoryCsv = '{0}\PatchMyPC-PublishingHistory.csv' -f $Publisher.InstallLocation

if (-not (Test-Path $PublishingHistoryCsv)) {
    Write-Log -Message ('Publishing history file not found: {0}' -f $PublishingHistoryCsv)
}
else {
    try {
        $PublishingHistory = Import-Csv -Path $PublishingHistoryCsv -ErrorAction Stop
        $Scenario6Result = Test-Scenario -Id 6 -PublishingHistory $PublishingHistory
        if ($Scenario6Result -ne $false) {
            $ScenarioImpactTracker += 6
        }
    }
    catch {
        Write-Log -Message ('Failed to process publishing history: {0}' -f $_.Exception.Message)
    }
}

if ($Scenario6Result -ne $false) {
    Write-HostResult -Impacted 'Yes' -Win32AppIds $Scenario6Result @WriteResultParams
    [PSCustomObject]@{
        Date     = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        Impacted = 'Yes'
        Scenarios = [String]::Join(',', ($ScenarioImpactTracker | Sort-Object -Unique))
    } | Write-Result
    return
}
elseif ($TenantImpacted) {
    Write-HostResult -Impacted 'Yes' @WriteResultParams
    [PSCustomObject]@{
        Date     = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        Impacted = 'Yes'
        Scenarios = [String]::Join(',', ($ScenarioImpactTracker | Sort-Object -Unique))
    } | Write-Result
    return
}

Write-HostResult -Impacted 'No' -Scenario 1 -Advice 'No action required'
[PSCustomObject]@{
    Date     = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    Impacted = 'No'
    Scenarios = ''
} | Write-Result
return

# SIG # Begin signature block
# MIIovgYJKoZIhvcNAQcCoIIorzCCKKsCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAK4igdAS+3SZCD
# ULFkxNNhWiGtBMZkq5fRnG/JBfe2i6CCIbswggWNMIIEdaADAgECAhAOmxiO+dAt
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
# ZU8atufk+EMF/cWuiC7POGT75qaL6vdCvHlshtjdNXOCIUjsarfNZzCCB8kwggWx
# oAMCAQICEAPSjq0JsKWh6sO6DavkqBwwDQYJKoZIhvcNAQELBQAwaTELMAkGA1UE
# BhMCVVMxFzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMUEwPwYDVQQDEzhEaWdpQ2Vy
# dCBUcnVzdGVkIEc0IENvZGUgU2lnbmluZyBSU0E0MDk2IFNIQTM4NCAyMDIxIENB
# MTAeFw0yNTA4MjIwMDAwMDBaFw0yODA5MTYyMzU5NTlaMIHRMRMwEQYLKwYBBAGC
# NzwCAQMTAlVTMRkwFwYLKwYBBAGCNzwCAQITCENvbG9yYWRvMR0wGwYDVQQPDBRQ
# cml2YXRlIE9yZ2FuaXphdGlvbjEUMBIGA1UEBRMLMjAxMzE2MzgzMjcxCzAJBgNV
# BAYTAlVTMREwDwYDVQQIEwhDb2xvcmFkbzEUMBIGA1UEBxMLQ2FzdGxlIFJvY2sx
# GTAXBgNVBAoTEFBhdGNoIE15IFBDLCBMTEMxGTAXBgNVBAMTEFBhdGNoIE15IFBD
# LCBMTEMwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQC8KLG0T7/YRgyQ
# USv/gkR1AlO3cdHAGRKxr8LqKWqzwbfaGvsisfOOe8yIETe8vIGFy+GECd8msOq7
# SmkWHJgEdvy7V1FgMkOzuyoAk/wIzgvdnbjc9AkXj01IQgRYzddhtYbrCZ8UoK8f
# qP0xHNFBWfleqUTHMoagBunstL/oB4WVbHelh0+6V1kcL8oVAefahypFKHwTXvdv
# bJz4d166/GlrWhVDJVwyYK5H8xgBCp1KDpXq3rjpqEy3/PuuDvJN45oxIlg9JyU0
# OTfyjeqslSlIwhVxSngOz34LNnJn6dokVWYFqbf+7mb1Jh5LcRk93ZdlezUDqTTN
# 3ZejP/uOxDRcmZjEVuBZtTGvWPXhBIJUUcfEiiGLRI59H9BYVDOdNxIUHbQ3SzwF
# L4iJt2zW1ELxFhcI2Sr6kRIX1lOm0UwiMSbN9M17pzkhUmegSAtPoPl94gUHTvAa
# VWa5ryIkznOR88CT1sdn6+Omke0Zlluz1YkzxWsF61SqiKCfSlvSxRNSWiydGs3C
# WCMpRNnMXzGoP+HYZBsQpqvX/0JcqLFln3hQIPhN61j+tZAjsv8Whmozwf7dPlU6
# CS76tbPF5/1Y1WGUcyHHqf0gKLabxi26w9T1YhmniA6XcC7FWO1fmcH2E2OXGw2k
# /x364zwzD9LikFk1JM27/UCCETaEcQIDAQABo4ICAjCCAf4wHwYDVR0jBBgwFoAU
# aDfg67Y7+F8Rhvv+YXsIiGX0TkIwHQYDVR0OBBYEFLEdM/t5ETHFdxo9vpEr2GV1
# 10QfMD0GA1UdIAQ2MDQwMgYFZ4EMAQMwKTAnBggrBgEFBQcCARYbaHR0cDovL3d3
# dy5kaWdpY2VydC5jb20vQ1BTMA4GA1UdDwEB/wQEAwIHgDATBgNVHSUEDDAKBggr
# BgEFBQcDAzCBtQYDVR0fBIGtMIGqMFOgUaBPhk1odHRwOi8vY3JsMy5kaWdpY2Vy
# dC5jb20vRGlnaUNlcnRUcnVzdGVkRzRDb2RlU2lnbmluZ1JTQTQwOTZTSEEzODQy
# MDIxQ0ExLmNybDBToFGgT4ZNaHR0cDovL2NybDQuZGlnaWNlcnQuY29tL0RpZ2lD
# ZXJ0VHJ1c3RlZEc0Q29kZVNpZ25pbmdSU0E0MDk2U0hBMzg0MjAyMUNBMS5jcmww
# gZQGCCsGAQUFBwEBBIGHMIGEMCQGCCsGAQUFBzABhhhodHRwOi8vb2NzcC5kaWdp
# Y2VydC5jb20wXAYIKwYBBQUHMAKGUGh0dHA6Ly9jYWNlcnRzLmRpZ2ljZXJ0LmNv
# bS9EaWdpQ2VydFRydXN0ZWRHNENvZGVTaWduaW5nUlNBNDA5NlNIQTM4NDIwMjFD
# QTEuY3J0MAkGA1UdEwQCMAAwDQYJKoZIhvcNAQELBQADggIBAJ2HuFdgLTtj5K7n
# zrgKI+rS/k0Rxfh/w3Bn1q8FwGfUfBMYtiFgb1+ms45VRCD/WWAoiyu53dpoo6Tv
# 3OqHeIrWu3dDy82muUWW06zng5mux1gmH/yCwmAQHwRCGsYMmwWpS6YhEZZFN7gH
# /1DibELwWWbM7Et3O7y1BGgV5JVGMjgDfNn3T28APncrZlmZjpvnPi+lWPRvrgEp
# wPDJHZQd2cqzHbuwmDLGxNN1+gJBg9WTeg44UXv7P9be2ADp7j6e94XCzVoBEXrW
# IrfkJpfoMilFs09TCBHs1U3ykC48q9MZbLqxr9747K5/9svw5aw5d+9Kgp/VuuX0
# Y87XD02B54p9MDzUJZ2mBVPDaixlS4V8M841yxzFlLjBKGhTQG8D9UsgZy3vPTv6
# Lgybsi3ZiBV0bbOFZYZ6fC8RHDCJd9efmIjCoBY2H2xQK3HvT2rJVlZ7/OmzPjc6
# 0a97GZkv+KxWqif4b8T9nAzDzkrcxfRXG7YT5tUiYq3cpa7Zvh8UEz9DQ/X6UUjv
# hIbF4/8PM3UykMaV7awaOS1xOJc4/PHbg6k11MR1iu8GEAI34VGL/Y8riHm3VacW
# 27a0LG4iQt3Xmqv1KjsXKaRi/d85gz/vLH1uaf4TEUyQNlxln8bRe0swBwsDq69U
# Jyb6r9kS76ZAICpyU+o5ItPQ6ygTMYIGWTCCBlUCAQEwfTBpMQswCQYDVQQGEwJV
# UzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4xQTA/BgNVBAMTOERpZ2lDZXJ0IFRy
# dXN0ZWQgRzQgQ29kZSBTaWduaW5nIFJTQTQwOTYgU0hBMzg0IDIwMjEgQ0ExAhAD
# 0o6tCbCloerDug2r5KgcMA0GCWCGSAFlAwQCAQUAoIGEMBgGCisGAQQBgjcCAQwx
# CjAIoAKAAKECgAAwGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwHAYKKwYBBAGC
# NwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEIJ6DJ0CfnOcp6Qwi
# tbf1jrSkJyH9Yx9znU26w2PIKenVMA0GCSqGSIb3DQEBAQUABIICAA8T6MlaMU1G
# CnclPXLIdUYX/3eEixJgDL4QFoORNXTcK2kowoRn84a2V0fUT21GnOt7WLH+StYA
# BDYR5WI2/swvmJIzj5rUJQuTLDGgGpiYjX+n5oWOtj0uZsbRUjIFPOHe9BRAEZUB
# tPYFw1XjEaEkyaam6oRpN4lovasoD8YbvZFg7pD4iP0XMjVgC0NgTSz1yoOyBa+k
# NjNyVY1KlPs5MvusvoplnWxABqExPJ8+1FZ3xdNiSiry2BDlgl3Y8mJHMQiyHeFE
# cIRsg17El6AULVyHH0RTC1UfSXi/We0egV3LqqUy51BQBfTB9oaHrYJKeOY4pZub
# 5T4TxKh8hOphhSx9DVAE2mf/xKftABDMZoYwuEd+/tajXZH9wzfjYwzghaxPG3Pp
# rWHcHGLxOuZHysdk9qImUQsCjYVazN1cHkRvhQ6uF7Tl6Nj4JF9A1nue4VTbwrrs
# Ye/ehNRsjgESc69xLy0YEnqWLymEslZwJMwcZNTW61y7/GBBJFKudH0o5A4OsO3J
# JejAcdvqHMVh/KjMhpSJzgowcF5sSx+HUiwg61WdE7DC8i1cRDahgm9m8+XXVRIL
# QKm7cyVA6fmWEw86oqr9PmZ1j+S09BxrziVS766ewCfdusYogrKkTVj+/oG2jLTt
# 2sS9mRba1ig0wDrm4maO4YWTlES1CEozoYIDJjCCAyIGCSqGSIb3DQEJBjGCAxMw
# ggMPAgEBMH0waTELMAkGA1UEBhMCVVMxFzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMu
# MUEwPwYDVQQDEzhEaWdpQ2VydCBUcnVzdGVkIEc0IFRpbWVTdGFtcGluZyBSU0E0
# MDk2IFNIQTI1NiAyMDI1IENBMQIQCoDvGEuN8QWC0cR2p5V0aDANBglghkgBZQME
# AgEFAKBpMBgGCSqGSIb3DQEJAzELBgkqhkiG9w0BBwEwHAYJKoZIhvcNAQkFMQ8X
# DTI1MTAxNTE2MDg0MVowLwYJKoZIhvcNAQkEMSIEIFN7qYP69fEgmEl2BBDKzOEo
# xb2Kt+HtHMJh9k8JD1DPMA0GCSqGSIb3DQEBAQUABIICADIAnnZ6V/o13u2P2iQP
# RZ8idT9yG9pAFV8ph++qf8A7+Evanxb15mo6eMQjFzgGplsr29vwu2EJbfUPT+3O
# fp6JFPkC3fLdGSIfQipksVB/1Qb4DPQYWanX/6xoB9ljCw4gCPlJUa4A8gYWW2H/
# xGrjT4q8Y4iUDlRRvlQAouhP9ui63aKOwppcgTZyHIMicGjkHKk4pzo2gySsKNRe
# ECNJvrkpD1dX5YtJfFZ86kDF9OLZBD/ocILbl8hQFpzqhZyoxdiSLMVPlVNKgflj
# qzWM99VlnLyl4POgO3PySbFznWzAPpkKbbbpFa6AXhaun/RmyMrK7gDHNVm2aJrU
# 4ZYHAxrhQIJRb4Dk3okwQYSxL/bcLLoj95T6Pn2bm6xD5nNPcTKHzuWqFUScuBAU
# 3T5SSDY+D6mdilh28VKSLtfgneIX5jMivcTNF0Q6JTqvDVmRrclKCQayusVgm6Z4
# 6qkjlDk8McZKdVDvdyou7IwCeMPSlQtCubt24SybBMOWfliqn2hEhWjpwRLqWuM4
# eJgqKfqFfLD8bEPY2CN/g1p9J6AiSaqY8pic964mcTvVWYqpjQIALPgrfP4U8QnS
# eA30sBaNcs565SVlB/j/nMLPTTmeiIbbnJgYxIZN57lFXomZWZhrJGxtwe+jx5vA
# Q7/MHE5r0CpCsCB5kL2PvWOk
# SIG # End signature block
