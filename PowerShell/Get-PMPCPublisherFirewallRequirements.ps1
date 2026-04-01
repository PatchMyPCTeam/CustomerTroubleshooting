<#
.SYNOPSIS
    Generates a tailored list of firewall requirements based on products enabled in the Patch My PC Publisher.

.DESCRIPTION
    Reads the Settings.xml from the Patch My PC Publishing Service installation and extracts all enabled
    product names across all tabs. These product names are then cross-referenced against a CSV containing 
    the domains, ports, and protocols required to download updates for each product. The result is a
    filtered list of only the firewall rules relevant to the products configured in the customer's environment.

    Related KB article: https://patchmypc.com/kb/list-domains-firewall-allowlist-when/

    Script must run on the same machine where the Patch My PC Publishing Service is installed.

.PARAMETER PMPCFirewallAllowlistCsv
    A URI pointing to the CSV file that maps Patch My PC product names to their required domains, ports,
    and protocols. Accepts either an HTTPS URL or a local file path.

    Defaults to the Patch My PC hosted allowlist CSV:
    https://content.patchmypc.com/downloads/csv/PatchMyPC-DomainList.csv

    It is also acceptable to supply a local file path, which can be useful in environments where the 
    Patch My PC website is not yet reachable.

.EXAMPLE
    .\Get-PublisherFirewallRequirements.ps1

    Runs the script using the default Patch My PC hosted CSV to retrieve the latest firewall requirements
    for all products enabled in the local Publisher's Settings.xml.

.EXAMPLE
    .\Get-PublisherFirewallRequirements.ps1 -PMPCFirewallAllowlistCsv 'C:\Temp\PatchMyPC-DomainList.csv'

    Runs the script using a locally cached copy of the firewall allowlist CSV, useful in environments
    where the Patch My PC website is not yet reachable.
#>
param(
    [Parameter()]
    [ValidateScript({ 
        if ($_.IsFile) {
            if (Test-Path -Path $_.LocalPath -ErrorAction 'Stop') { 
                return $true 
            }
            else { 
                throw ('File not found: {0}' -f $_.LocalPath) 
            }
        }
        else {
            try {
                $Response = Invoke-WebRequest -Uri $_ -Method Head -UseBasicParsing -ErrorAction 'Stop'
                if ($Response.StatusCode -ne 200) {
                    throw ('{0} is not accessible. Status code: {1}' -f $_, $Response.StatusCode)
                }
            }
            catch {
                throw ('Invalid URL or inaccessible: {0}' -f $_)
            }
        }
     })]
    [System.Uri]$PMPCFirewallAllowlistCsv = 'https://content.patchmypc.com/downloads/csv/PatchMyPC-DomainList.csv'
)

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

$Publisher = Get-InstalledSoftware -DisplayName 'Patch My PC Publishing Service'
if ([String]::IsNullOrEmpty($Publisher)) {
    throw 'Patch My PC Publishing Service is not installed.'
}
$SettingsXmlPath = '{0}\Settings.xml' -f $Publisher.InstallLocation
if (-not (Test-Path -Path $SettingsXmlPath)) {
    throw 'Settings.xml not found at {0}' -f $SettingsXmlPath
}
else {
    $Settings = [xml](Get-Content $SettingsXmlPath -ErrorAction 'Stop')
}

if ($PMPCFirewallAllowlistCsv.HostNameType -eq 'Dns') {
    $TmpFile = New-TemporaryFile
    Invoke-WebRequest -Uri $PMPCFirewallAllowlistCsv -UseBasicParsing -OutFile $TmpFile -ErrorAction 'Stop'
    [System.Uri]$PMPCFirewallAllowlistCsv = [String]$TmpFile
}

$DomainList = @{}
Import-Csv -Path $PMPCFirewallAllowlistCsv.LocalPath -ErrorAction 'Stop' | ForEach-Object {
    $DomainList[$_.Product] = [PSCustomObject]@{ 
        Domain = $_.Host 
        Port = $_.Port
        Scheme = $_.Scheme
    }
}

$Products = foreach ($Type in 'SearchPatterns', 'Packages', 'IntuneTenants') {

    if ($Type -eq 'IntuneTenants') {
        foreach ($Tenant in $Settings.'PatchMyPC-Settings'.$Type.Tenant) {
            foreach ($_Type in 'Applications','Updates') {
                foreach ($SearchPattern in $Tenant.$_Type.SearchPattern) {
                    [PSCustomObject]@{
                        FoundIn = "IntuneTenant-$($Tenant.FriendlyName)-$_Type"
                        Vendor = $SearchPattern.vendor
                        VendorId = $SearchPattern.vendorId
                        Product = $SearchPattern.product
                        ProductId = $SearchPattern.productId
                        Domain = $DomainList[$SearchPattern.product].Domain
                        Port = $DomainList[$SearchPattern.product].Port
                        Scheme = $DomainList[$SearchPattern.product].Scheme
                    }
                }
            }
        }
    }
    else {
        foreach ($SearchPattern in $Settings.'PatchMyPC-Settings'.$Type.SearchPattern) {
            [PSCustomObject]@{
                FoundIn = $Type
                Vendor = $SearchPattern.vendor
                VendorId = $SearchPattern.vendorId
                Product = $SearchPattern.product
                ProductId = $SearchPattern.productId
                Domain = $DomainList[$SearchPattern.product].Domain
                Port = $DomainList[$SearchPattern.product].Port
                Scheme = $DomainList[$SearchPattern.product].Scheme
            }
        }
    }

}

Clear-Variable 'i' -ErrorAction 'SilentlyContinue'

foreach ($item in @(
    [PSCustomObject]@{
        Product = 'Essential Patch My PC service #{0:D2}' -f ++$i
        Domain = 'patchmypc.com'
        Port = 443
        Scheme = 'https'
    },
    [PSCustomObject]@{
        Product = 'Essential Patch My PC service #{0:D2}' -f ++$i
        Domain = 'content.patchmypc.com'
        Port = 443
        Scheme = 'https'
    },
    [PSCustomObject]@{
        Product = 'Essential Patch My PC service #{0:D2}' -f ++$i
        Domain = 'api.patchmypc.com'
        Port = 443
        Scheme = 'https'
    },
    [PSCustomObject]@{
        Product = 'Essential Patch My PC service #{0:D2}' -f ++$i
        Domain = 'portal.patchmypc.com'
        Port = 443
        Scheme = 'https'
    },
    [PSCustomObject]@{
        Product = 'Essential Patch My PC service #{0:D2}' -f ++$i
        Domain = 'us.portal.patchmypc.com'
        Port = 443
        Scheme = 'https'
    },
    [PSCustomObject]@{
        Product = 'Essential Patch My PC service #{0:D2}' -f ++$i
        Domain = 'eu.portal.patchmypc.com'
        Port = 443
        Scheme = 'https'
    },
    [PSCustomObject]@{
        Product = 'Essential Patch My PC service #{0:D2}' -f ++$i
        Domain = '*.windows.net'
        Port = 443
        Scheme = 'https'
    },
    [PSCustomObject]@{
        Product = 'Essential Patch My PC service #{0:D2}' -f ++$i
        Domain = 'login.microsoftonline.com'
        Port = 443
        Scheme = 'https'
    },
    [PSCustomObject]@{
        Product = 'Essential Patch My PC service #{0:D2}' -f ++$i
        Domain = '*.digicert.com'
        Port = 80
        Scheme = 'http'
    },
    [PSCustomObject]@{
        Product = 'Essential Patch My PC service #{0:D2}' -f ++$i
        Domain = 'timestamp.digicert.com'
        Port = 80
        Scheme = 'https'
    },
    [PSCustomObject]@{
        Product = 'Essential Patch My PC service #{0:D2}' -f ++$i
        Domain = 'ocsp.digicert.com'
        Port = 80
        Scheme = 'https'
    }
)) {
    $Products += $item
}

$Products | Sort-Object -Property 'Product' -Unique | Select-Object -Property 'Product', 'Domain', 'Port', 'Scheme'
