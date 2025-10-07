#Requires -RunAsAdministrator

<#
    Scenario 1: Check if any saves have occured since upgrading to an impacted version
    Scenario 2: If Intune Apps and Intune Updates have identical DefaultOptions
    Scenario 3: Check if products in both tabs have identical config (where applicable)
        e.g. product selections and right click options
    Scenario 4: Check if any product has a tab-specific XML element in the incorrect tab
        e.g. If any Intune Update has an Available assignment or IntuneAppEspIDs
    Scenario 5: Check if a product incorrectly appears in the incorrect tab
        e.g. App-only pkgs appearing in Intune Updates, or Update-only pkgs appearing in Intune Apps
   
    At the end:
        - Indicate if impacted or not
        - If impacted, advise which backup .cab on disk they should restore to
        - parse publishing history .csv to list any Win32 pkgs erroneously published (and should be deleted)
        - User facing output: 
            Impacted: Yes/No
            Scenario: 1/2/3
            Advice:
            1: "No action required"
            2: "Backup found on disk. Please restore from backup created on <date> found at <path>"
            3: "Backup not found on disk. Please restore from backup created on or before <date>"
            
            More Information: https://patchmypc.com/kb/publisher-configuration-overlap?scenario=<1/2/3/0>
#>

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

        Write-Verbose ('Found matching application {0} {1}' -f $Result.DisplayName, $Result.DisplayVersion)
        $Result | Select-Object -Property $PropertyNames
    }
}

function Test-Scenario1 {
    <#
        Check if any saves have occured between upgrading to an impacted version and a bug fix version
        e.g. if no saves = not impacted, otherwise continue reviewing other scenarios
    #>

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
    } | Select-Object -First 1 -ExpandProperty 'Time'

    # If there is no record of an impacted version being installed, assume the earliest possible date
    if ([String]::IsNullOrWhitespace($ImpactedVersionInstallDate)) {
        $ImpactedVersionInstallDate = $Start
    }

    $BugFixVersionInstallDate = $Timeline | Where-Object {
        $_.Version -eq '2.1.50.0' -or [System.Version]$_.Version -gt [System.Version]'2.1.50.11'
    } | Select-Object -First 1 -ExpandProperty 'Time'

    # If there is no record of a bug fix version being installed, assume the latest possible date
    # It's very unlikely that this and the $ImpactedVersionInstallDate are both null
    # However the intent here is to regardless go hunting in event viewer for evidence of saves
    # The objective of trying to find an accurate date is to try and accurately advise the customer when to restore from
    if ([String]::IsNullOrWhitespace($BugFixVersionInstallDate)) {
        $BugFixVersionInstallDate = Get-Date
    }

    try {
        $Saves = Get-WinEvent -FilterHashtable @{
            LogName   = 'Patch My PC Publishing Service'
            Id        = 3009
            StartTime = $ImpactedVersionInstallDate
            EndTime   = $BugFixVersionInstallDate
        } -ErrorAction 'Stop'
    }
    catch {
        if ($_.FullyQualifiedErrorId -like 'NoMatchingEvents*') {
            return $false
        }
        else {
            throw
        }
    }

    # Any backup available prior to this date is best 
    if ($Saves.Count -gt 0) {
        return $ImpactedVersionInstallDate
    }
}

function Test-Scenario2 {
    <#
        If Intune Apps and Intune Updates have identical DefaultOptions
    #>
    param(
        [System.Xml.XmlElement]$Settings
    )

    $DefaultOptionsDefaultValueXml = '<Vendor name="AllVendors" inherited="False" />'

    # This reads funny because of the -not operator, but it essential means "if they are identical"
    if (-not (Compare-Object $Settings.DefaultOptions.Options.InnerXml @($DefaultOptionsDefaultValueXml,$DefaultOptionsDefaultValueXml))) {
        # If DefaultOptions are not configured and are default values, then not impacted
        return $false
    }
    else {
        # However, if DefaultOptions are configured, are identical and contain IntuneAssignments, then flag as impacted
        $IntuneApps = $Settings.DefaultOptions.Options.Where{$_.target -eq 'Intune Applications'}
        $IntuneUpdates = $Settings.DefaultOptions.Options.Where{$_.target -eq 'Intune Updates'}

        -not (Compare-Object $IntuneApps.InnerXml $IntuneUpdates.InnerXml) -and
        $Settings.DefaultOptions.Options.InnerXml -match 'IntuneAssignments'
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

    $EvaluatedProducts = @{}
    $Result = @{}

    foreach ($_Product in 
        $Settings.Applications.SearchPattern, 
        $Settings.Updates.SearchPattern
    ) {
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
            if (-not (Compare-Object $Object $EvaluatedProducts[$_Product.ProductId])) {
                $Result[$_Product.ProductId] = $true
            }
        }
        else {
            $EvaluatedProducts[$_Product.ProductId] = $Object
        }
    }

    # count the number of $true values in $Result.value, and if more than 90% are $true, then return $true
    # if there are 10 or fewer and all are $true, return $true
    # otherwise return $false
    $TrueCount = ([array]$Result.Values).Count
    $TotalCount = ([array]$Settings.Applications.SearchPattern).Count + ([array]$Settings.Updates.SearchPattern).Count
    if ($TotalCount -gt 10) {
        $PercentageTrue = ($TrueCount / $TotalCount) * 100
        if ($PercentageTrue -ge 90) {
            Write-Verbose ('{0}% of products with identical ProductId in Intune Apps and Intune Updates have identical configuration' -f 
                            [math]::Round($PercentageTrue,2)) -Verbose
            return $true
        }
    }
    elseif ($Result.Values -notcontains $false) {
        Write-Verbose ('All {0} products with identical ProductId in Intune Apps and Intune Updates have identical configuration' -f 
                        $TotalCount) -Verbose
        return $true

    }
    else {
        Write-Verbose ('Only {0} products with identical ProductId in Intune Apps and Intune Updates have identical configuration' -f 
                        $TrueCount) -Verbose
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

    $Settings.Updates.SearchPattern.IntuneAssignments.IntuneAssignment.Intent -contains 'available' -or
    $Settings.DefaultOptions.Options.Where{$_.target -eq 'Intune Updates'}.Vendor.IntuneAssignments.IntuneAssignment.Intent -contains 'available' -or
    -not [String]::IsNullOrWhiteSpace($Settings.Updates.SearchPattern.IntuneAppEspIDs)
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
    $UpdateOnlyProductIds = @(
        'b28160cd-53ab-443f-b420-5e461eb190b0', # Adobe Acrobat 2020 Classic
        '56f28ca6-2311-4749-ad3d-93ff48a3cc12', # Adobe Acrobat Classic 2024 Update (MSP-x64)
        '64e18647-0fa4-42ac-af0e-28bb20306cab', # Adobe Acrobat DC Continuous
        'c3e232e4-9cfa-4deb-b531-2246022717c9', # Adobe Acrobat DC Continuous (x64)
        'a8780c71-b528-41bb-ab77-46b942f4a3de', # Adobe Acrobat Reader 2020 Classic
        '49d8883a-c283-4c44-bc28-2a6c45ab4bc5', # Adobe Acrobat Reader DC Continuous (en-US)
        '57277296-8373-4713-8786-15d9efefc6f4', # Adobe Acrobat Reader DC Continuous MUI
        '06cde3f6-3758-4190-8179-8702eb01d64d', # Adobe Acrobat Reader DC Continuous (x64)
        '57ed7de6-d7b6-44d2-9ac2-bdc09d29f649', # Adobe Acrobat Reader DC Continuous MUI (x64)
        '25408374-d64d-427b-9a36-faa90c4f31bd', # Autodesk Advance Steel 2023 (EXE-x64)
        '6d07768d-2f7f-4584-a16d-122de0e7de3b', # Autodesk Advance Steel 2024 (EXE-x64)
        '81106c45-1725-47eb-8ebb-66cf4d011ec8', # Autodesk Advance Steel 2025 (EXE-x64)
        'd5ae7e63-ad2a-4415-b117-e524ef29759f', # Autodesk Advance Steel 2026 (EXE-x64)
        '6ec0d3c5-4376-4a21-8620-cee681110b4c', # Autodesk AutoCAD 2021
        'b654c1e1-cdc4-4184-b96d-c15dd2ea5d3e', # Autodesk AutoCAD Map 3D 2021 (EXE-x64)
        'a1d01ccd-27c1-4d65-a0c1-9c282d621744', # Autodesk AutoCAD MEP 2021 (EXE-x64)
        '940bc51b-f907-40ab-a3b2-31663158ec50', # Autodesk AutoCAD 2022
        '9bb3f3f7-044e-488a-9f11-aac42dfa97c6', # Autodesk AutoCAD Architecture 2022 (EXE-x64)
        'd023f9a2-0dbe-4631-b3f6-636ab02bc766', # Autodesk AutoCAD LT 2022 (EXE-x64)
        '9ebf7476-1cbf-4662-adf1-028e6fad866b', # Autodesk AutoCAD Map 3D 2022 (EXE-x64)
        '1e431836-bc76-42a4-abcc-62ccb4d37bba', # Autodesk AutoCAD Mechanical 2022 (EXE-x64)
        'c8b2b49f-8d7b-4381-818f-750941a9f58c', # Autodesk AutoCAD Mechanical 2023 (EXE-x64)
        'ab3fba47-1425-4954-8456-998e52bc1082', # Autodesk AutoCAD Mechanical 2024 (EXE-x64)
        'e70e0fc2-b0af-4399-9e81-05ac1d2d5c7b', # Autodesk AutoCAD Mechanical 2025 (EXE-x64)
        '06686683-85cd-4517-9d99-1e8bb7c9e74f', # Autodesk AutoCAD MEP 2022 (EXE-x64)
        '88f532a0-3988-4d77-b0dc-c239d1826049', # Autodesk AutoCAD 2023
        '40cc6335-71d9-4e3c-bc24-a39c3fb9225a', # Autodesk AutoCAD Architecture 2023 (EXE-x64)
        '6fb7c4c2-a2ac-4d57-abf9-60ffb51bfb15', # Autodesk AutoCAD Architecture 2024 (EXE-x64)
        'e1bd69ad-033a-4ade-9afa-5d24698600ce', # Autodesk AutoCAD Architecture 2025 (EXE-x64)
        '4c493091-891b-434f-a552-a2502f7a76db', # Autodesk AutoCAD Electrical 2022 (EXE-x64)
        '85feded8-8083-4dc5-b1c2-98854e6b3123', # Autodesk AutoCAD Electrical 2023 (EXE-x64)
        '75997370-cffc-44e0-9741-d24eddcbd880', # Autodesk AutoCAD Electrical 2024 (EXE-x64)
        '04672dcc-26f9-4c0c-a004-421dd269a100', # Autodesk AutoCAD Electrical 2025 (EXE-x64)
        'def7b0cc-69ea-4fb8-b4d8-143c1d1a947a', # Autodesk AutoCAD LT 2023 (EXE-x64)
        '1ce00f1d-b763-4da5-a5cc-04007a8ca527', # Autodesk AutoCAD Map 3D 2023 (EXE-x64)
        '0d6e262a-9547-48ac-b3b5-94d33cedaf92', # Autodesk AutoCAD Map 3D 2024 (EXE-x64)
        '7b2ddcab-5d01-42bd-828e-a6ab659c4c18', # Autodesk AutoCAD Map 3D 2025 (EXE-x64)
        '5c53a8f3-d454-4919-85c9-e3b410ccb4b0', # Autodesk AutoCAD Map 3D 2026 (EXE-x64)
        '32a3b19f-d15e-4880-95e9-a411f65eb13a', # Autodesk AutoCAD MEP 2023 (EXE-x64)
        '372fc63a-6a8f-460d-bc20-4bc5e14d7cd6', # Autodesk AutoCAD MEP 2024 (EXE-x64)
        '4727da73-22fe-414b-b11a-fdd24e0a6778', # Autodesk AutoCAD MEP 2025 (EXE-x64)
        'c5da90fd-209f-47db-993a-db9a509994d1', # Autodesk AutoCAD Plant 3D 2022 (EXE-x64)
        'ba8261aa-5c7c-448c-8afb-b22ad727bd9d', # Autodesk AutoCAD Plant 3D 2023 (EXE-x64)
        '9461aa65-ba06-4d4b-a0b1-383ff3aab57a', # Autodesk AutoCAD Plant 3D 2024 (EXE-x64)
        'f6e50fee-7d76-4b61-b37a-df7e7619db01', # Autodesk AutoCAD Plant 3D 2025 (EXE-x64)
        'cde536ea-7313-4dd1-96ac-1e68f9ae5ff0', # Autodesk AutoCAD Plant 3D 2026 (EXE-x64)
        '44434b72-dc75-4ba2-b492-c692818f4cd2', # Autodesk AutoCAD 2024 (EXE-x64)
        '8f09a716-42d9-4335-8829-53e756ff630f', # Autodesk AutoCAD 2025 (EXE-x64)
        'f35e2a42-c421-420f-92eb-5c43df46bc9c', # Autodesk AutoCAD 2026 (EXE-x64)
        '3b2605c7-12ff-403d-92aa-293c5d3f16a9', # Autodesk AutoCAD LT 2024 (EXE-x64)
        'c6376f5f-8862-420e-9afb-00923909fa8c', # Autodesk AutoCAD LT 2025 (EXE-x64)
        '98178e6e-aa94-47da-893f-2cb220aa946f', # Autodesk AutoCAD LT 2026 (EXE-x64)
        '7a874f06-59c6-44fb-9aa9-64124cfe57d3', # Autodesk Civil 3D 2022 (EXE-x64)
        '49c0e0c3-b5ce-4956-b3fc-879b01cd4831', # Autodesk Civil 3D 2023 (EXE-x64)
        'b88c017e-83fd-4361-8290-350b4f2cbbbc', # Autodesk Civil 3D 2024 (EXE-x64)
        'cc881982-12cf-4e66-b8f7-450e22cc2789', # Autodesk Civil 3D 2025 (EXE-x64)
        '8fe137fe-f29e-4594-9937-2720ad2878dd', # Autodesk Design Review
        '690a4acc-48ef-4c52-97df-60073911b824', # Autodesk Fabrication CADmep 2022 (EXE-x64)
        '89f697c1-53f3-4943-9d77-855e6b88d7d8', # Autodesk Fabrication CADmep 2023 (EXE-x64)
        '62981eb6-6be7-45d9-bf9e-9a24b44b863c', # Autodesk Inventor Professional 2022 (EXE-x64)
        'dff8d651-c6f3-4106-977a-58e73fb91301', # Autodesk Inventor Professional 2023 (EXE-x64)
        'f70bdd62-9a63-492d-b855-017d88029055', # Autodesk Inventor Professional 2024 (EXE-x64)
        'fa5cd52a-96bf-4769-8639-144f4a070b44', # Autodesk Inventor Professional 2025 (EXE-x64)
        '95bdd25d-877c-4fa9-9b5d-614f9fc0cfe2', # Autodesk Inventor Professional 2026 (EXE-x64)
        '6d6121bf-6f36-4a73-8f17-ade6258996e8', # Autodesk Navisworks Freedom 2022 (EXE-x64)
        '45540849-6023-4f9e-bddb-618b7a072f29', # Autodesk Navisworks Freedom 2023 (EXE-x64)
        'e05aff50-e749-4a7e-9aa8-873a5db65791', # Autodesk Navisworks Freedom 2024 (EXE-x64)
        'cd1e37ce-d908-405f-8c9c-001ff0b26cdb', # Autodesk Navisworks Freedom 2025 (EXE-x64)
        '63c917b3-e07c-4629-bb98-425303866160', # Autodesk Navisworks Freedom 2026 (EXE-x64)
        'af2efb15-98d1-4999-a56b-67078e99f5c8', # Autodesk Navisworks Manage 2022 (EXE-x64)
        '97f9dc73-56ad-4b45-95b5-9a0ba6399978', # Autodesk Navisworks Manage 2023 (EXE-x64)
        'ce67e3ee-250f-4eb7-b50d-aee8d88ae665', # Autodesk Navisworks Manage 2024 (EXE-x64)
        '224b37ed-0399-4f11-bad7-d8adadb9ac0c', # Autodesk Navisworks Manage 2025 (EXE-x64)
        'ea23b577-3aa1-4d99-a4f7-4ca287efa0b6', # Autodesk Navisworks Manage 2026 (EXE-x64)
        'e9cd2204-0b52-42a2-a620-93cf08f458c1', # Autodesk Navisworks Simulate 2022 (EXE-x64)
        '9ca5468c-4b81-4418-89a8-dd5926998f7f', # Autodesk Navisworks Simulate 2023 (EXE-x64)
        'a2644695-273b-41b3-a68e-3f1cbfd3d59b', # Autodesk Navisworks Simulate 2024 (EXE-x64)
        '87805519-48c9-4fe0-a3ee-36db74dcf521', # Autodesk Navisworks Simulate 2025 (EXE-x64)
        'ab267a78-0a81-41f9-a910-d82bfcbaf43d', # Autodesk Navisworks Simulate 2026 (EXE-x64)
        '06f2c843-a03f-4e48-9b4e-b2ff3043ffcf', # Autodesk ReCap Photo 2022 (EXE-x64)
        '87a81558-c020-4c40-b4b7-7699ad3e8819', # Autodesk ReCap Photo 2023 (EXE-x64)
        'aa6eb67b-34fa-4b33-8b71-ad0e6cecfdc8', # Autodesk ReCap Photo 2024 (EXE-x64)
        'a6cc69ec-3f05-48e4-a876-7dacbf2e9bae', # Autodesk ReCap Photo 2025 (EXE-x64)
        '54d7ba3c-d3e7-4385-9178-5fb446c48c79', # Autodesk ReCap Pro 2022 (EXE-x64)
        'fb7a3e24-789e-4e2b-8e1a-0b8bc4194f24', # Autodesk ReCap Pro 2023 (EXE-x64)
        '4271c667-ed5c-4f2f-a0bc-ddea4e16f184', # Autodesk ReCap Pro 2024 (EXE-x64)
        'b73d122c-2af6-41f9-ab85-653f8034a468', # Autodesk ReCap Pro 2025 (EXE-x64)
        '6c7f672b-793c-45bb-8f94-577699b65477', # Autodesk ReCap Pro 2026 (EXE-x64)
        '6119ddec-eace-4608-9ac2-4d9fef678cb9', # Autodesk Revit 2019
        '72c98113-c999-4a18-a7c7-4e8109b1327b', # Autodesk Revit 2020
        '8e8fb589-6b3e-417a-82ba-35cb307a8195', # Autodesk Revit 2021
        '2619260c-d6f9-4292-9a52-7ec128c175da', # Autodesk Revit 2022
        '3fbcd8f3-5463-459a-8807-b4a359c6db6b', # Autodesk Revit 2024 (EXE-x64)
        'a48a529e-aad1-498f-a091-5c37fb14e8d0', # Autodesk Revit 2026 (EXE-x64)
        '5871d64c-425a-433e-9410-fd733060405f', # Autodesk Revit LT 2022 (EXE-x64)
        '139c57f2-084d-4bb8-9c47-97179769f874', # Autodesk Revit LT 2023 (EXE-x64)
        '5a85a030-b7df-4140-8c72-20f3bdfbf3bf', # Autodesk Revit LT 2024 (EXE-x64)
        '27aa91b9-1cda-459d-a30e-6dcf6c9ad894', # Autodesk Revit LT 2025 (EXE-x64)
        '3f571230-c515-43d3-907d-94aa28ddedda', # Autodesk Structural Bridge Design 2022 (EXE-x64)
        'deee28af-07b1-4b8b-b01b-8fd7a4fa1b4b', # Autodesk Structural Bridge Design 2023 (EXE-x64)
        '1c8546ac-284d-4c7b-b008-0ae23d53d503', # Autodesk Structural Bridge Design 2024 (EXE-x64)
        'd13a967c-7f6d-49eb-952a-ce07f10cf563', # Autodesk Vault Basic 2023 Client (EXE-x64)
        '78b281d5-eac3-4f83-89d6-0cf693e0c8d7', # Autodesk Vault Basic 2024 Client (EXE-x64)
        '2722009c-f084-40d0-8aad-afdc8a421847', # Autodesk Vault Basic 2025 Client (EXE-x64)
        'e07b34e5-3238-4a81-9c11-8644826635bc', # Autodesk Vault Basic 2026 Client (EXE-x64)
        '5b602728-dd0d-4c98-bcce-a3b0ff81a9f3', # Autodesk Vault Professional 2023 Client (EXE-x64)
        '9a51c4d0-2c80-463e-895e-894ecd56613b', # Autodesk Vault Professional 2024 Client (EXE-x64)
        '59ab310f-51c9-419f-86f9-4aae8d4a9fae', # Autodesk Vault Professional 2025 Client (EXE-x64)
        '9601616b-14b2-4c21-a154-a06ef75f99df', # Autodesk Vault Professional 2026 Client (EXE-x64)
        '8d5c8aae-efee-477b-9f7d-24d4da1f4b5b', # Autodesk Vehicle Tracking 2022 (EXE-x64)
        '6e387287-13ea-4c5e-8c14-2680a01bb826', # Autodesk Vehicle Tracking 2023 (EXE-x64)
        'a758dd75-9f33-4ee7-9d7a-4668545e1f15', # Autodesk Vehicle Tracking 2024 (EXE-x64)
        '06b03938-2627-4a5f-bf38-2f032aa4ea45', # Robot Structural Analysis Professional 2022 (EXE-x64)
        '69692150-9a36-4d8a-889c-3a5b87f26da6', # Robot Structural Analysis Professional 2023 (EXE-x64)
        '405b090a-1138-43a3-b1a7-371e6431cfff', # Robot Structural Analysis Professional 2024 (EXE-x64)
        '90d1eeda-db58-4443-813f-3c195b023d99', # FileMaker Pro 2023 Update (MSP-x64)
        '5fa7f2b6-5264-4c36-9660-75beaf094126', # FileMaker Pro 2024 Update (MSP-x64)
        '086ea912-719d-4141-9b01-336946ed591e', # FileMaker Pro 2025 Update (MSP-x64)
        'ae5dba49-36b8-4e2f-870f-421530b10111', # EndNote 20 (MSP-x86)
        '67087298-4e94-48c7-9b3a-fc1ac871ace2', # EndNote 21 (MSP-x86)
        '7f619173-dd90-4ece-9f07-55c05218e465', # Local Administrator Password Solution (x64)
        '0b14a40e-d9df-4f83-b248-0c41db447f77', # Local Administrator Password Solution (x86)
        'c84406fa-4758-4957-9dca-79cfbc143e34', # Microsoft SQL Server Management Studio 17
        '99127edf-84ec-4fcc-813f-a4d62648cd60', # Microsoft SQL Server Management Studio 21 Update (EXE-x64)
        'fda3c011-722e-4e5b-b409-9da52ed913d6', # Visual Studio Build Tools 2017 Update (EXE-x64)
        '363db78c-de91-46d3-adf8-a03c21958f5b', # Visual Studio Build Tools 2019 Update (EXE-x64)
        'f0f3ebbb-6bbf-40d5-a35f-83258925b619', # Visual Studio Build Tools 2022 Update (EXE-x64)
        '6327906c-934d-47b9-a8f2-885b825259ad', # Visual Studio Community 2017 Update (EXE-x64)
        '1e6bf9dc-84cb-4a6e-8ccd-5b334ed04644', # Visual Studio Community 2019 Update (EXE-x64)
        'c4349cee-0499-459b-8213-c0495f663160', # Visual Studio Community 2022 Update (EXE-x64)
        'dcdf667a-1794-4116-b706-9cc5d1f8738f', # Visual Studio Enterprise 2017 Update (EXE-x64)
        'a316dcea-ec64-4e23-81a2-8fbb9524f9ef', # Visual Studio Enterprise 2019 Update (EXE-x64)
        'dd6583b3-29cc-46ea-80af-ddaa68ff3625', # Visual Studio Enterprise 2022 Update (EXE-x64)
        '618f1228-c861-4737-be8a-0d385acda85c', # Visual Studio Professional 2017 Update (EXE-x64)
        'e80be9a2-f535-4c0c-b12b-e48fc7952d33', # Visual Studio Professional 2019 Update (EXE-x64)
        'bf8c4d16-8bee-4b2c-87ec-eeb4b7cdb333', # Visual Studio Professional 2022 Update (EXE-x64)
        'ff78b118-a4c6-423b-8605-a6afed4e99ca', # TeamViewer Latest (EXE-x64)
        '3f87c470-cf8d-4a10-9caf-56dd28de07ef', # TeamViewer Latest (EXE-x86)
        '599f0dbc-3271-4999-be16-661c6530de1f', # TeamViewer Latest (MSI-x64)
        'cd272d0f-2a17-4405-97f7-6b3e94bdeca3' # TeamViewer Latest (MSI-x86)

    )
    $AppOnlyProductIds = @(
        'f8d7a92e-94d3-4724-b064-522608554038', # Adobe Acrobat Pro (64-bit)
        '91bcb322-74f0-4370-afe0-4c2eb95223db', # Adobe Flash Player Removal Tool
        '7e9b260a-f65e-4367-a477-b62485d64c41', # Bloomberg Terminal
        '74d4ffe7-7785-4b80-ae93-31357eda8b6a', # ESET Server Security 9 (MSI-x64)
        'ae68a0b5-8216-4c5d-ac03-ef3945d8d18c', # ESET Server Security 10 (MSI-x64)
        '363fb724-09f1-41ac-9e56-3619ef2bdd92', # GanttProject
        '96f4f1c8-1a51-4c33-ab01-be47ad0266bb', # Kofax Power PDF 4.1 Advanced
        '16ea4cf9-2a74-449a-afea-3791efe74f2e', # Kofax Power PDF 5 Advanced
        '7d4891f1-4365-42a3-b971-c358da2f3e55', # Kofax Power PDF 5.1 Advanced
        'a5f99151-67d8-4f41-acfc-9fec440cd9cd', # Microsoft SQL Server Management Studio 16
        'fb40df3c-a0f5-4f90-a97e-40e5a7df0e11', # Sysmon (x86)
        'ec014f48-7b7f-4b87-b2a9-14f3814eaebd'  # Sysmon (x64)
    )

    foreach ($Product in $Settings.Updates.SearchPattern) {
        if ($AppOnlyProductIds -contains $Product.ProductId) {
            return $true
        }
    }

    foreach ($Product in $Settings.Applications.SearchPattern) {
        if ($UpdateOnlyProductIds -contains $Product.ProductId) {
            return $true
        }
    }

    return $false
}

function Write-Result {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Yes','No')]
        [String]$Impacted,

        [Parameter(Mandatory)]
        [ValidateSet(1,2,3)]
        [Int]$Scenario,

        [Parameter(Mandatory)]
        [String]$Advice
    )

    Write-Host 'Impacted: ' -NoNewline
    if ($Impacted) {
        Write-Host 'Yes' -ForegroundColor Red
    }
    else {
        Write-Host 'No' -ForegroundColor Green
    }

    Write-Host ('Scenario: {0}' -f $Scenario)

    if ($Impacted -eq 'No') {
        $Advice = 'No action required'
    }

    Write-Host ('Advice: {0}' -f $Advice)
    Write-Host ''
    Write-Host ('More Information: https://patchmypc.com/kb/publisher-configuration-overlap?scenario={0}' -f $Scenario)
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

$BackupRestoreDate = Test-Scenario1

if ($BackupRestoreDate -eq $false) {
    Write-Result -Impacted 'No' -Scenario 1 -Advice 'No action required'
    return
}

$BackupFolder = '{0}\Backup' -f $Publisher.InstallLocation
if (Test-Path $BackupFolder) {
    $BackupCabFile = Get-ChildItem -Path $BackupFolder -Filter 'Settings*.cab' -ErrorAction 'Stop' | 
                        Where-Object { $_.LastWriteTime -le $BackupRestoreDate } |
                        Select-Object -Last 1
    $WriteResultParams['Scenario'] = 2
    $WriteResultParams['Advice'] = 'Backup found on disk. Please restore from backup created on {0} found at "{1}"' -f 
                                        $BackupCabFile.LastWriteTime, $BackupCabFile.FullName
}
else {
    $WriteResultParams['Scenario'] = 3
    $WriteResultParams['Advice'] = 'Backup not found on disk. Please restore from backup created on or before {0}' -f $BackupRestoreDate
}

foreach ($Tenant in $Settings.Tenant) {

    # If either the Intune Apps or Intune Updates tabs are disabled, skip this tenant
    # or if there are no products enabled in at least one tab, skip this tenant
    # i.e. only process tenants where both tabs are enabled and have products selected in both tabs
    if (
        ($Tenant.EnableApplications -ne 'True' -or $Tenant.EnableUpdates -ne 'True') -or
        ([String]::IsNullOrWhiteSpace($Tenant.Applications) -or [String]::IsNullOrWhiteSpace($Tenant.Updates))
    ) {
        continue
    }

    if (Test-Scenario2 -Settings $Tenant) {
        Write-Result -Impacted 'Yes' @WriteResultParams
        return
    }

    if (Test-Scenario3 -Settings $Tenant) {
        Write-Result -Impacted 'Yes' @WriteResultParams
        return
    }

    if (Test-Scenario4 -Settings $Tenant) {
        Write-Result -Impacted 'Yes' @WriteResultParams
        return
    }

    if (Test-Scenario5 -Settings $Tenant) {
        Write-Result -Impacted 'Yes' @WriteResultParams
        return
    }
}

Write-Result -Impacted 'No' -Scenario 1 -Advice 'No action required'
return
