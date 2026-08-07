<#
.SYNOPSIS
    Export or import WSUS RootElementType 6 (Corporate Publishing SDP) metadata
    for disconnected WSUS migrations.

.DESCRIPTION
    Supports a disconnected WSUS workflow by preserving metadata that
    'wsusutil export/import' does not carry across. For locally published
    updates, wsusutil does not transfer the tbXml.RootElementType = 6 record.
    That Type 6 record holds the full Software Distribution Package (SDP)
    metadata used by the WSUS API when calling IUpdate.ExportPackageMetadata().

    This does not stop updates from reaching clients. The visible effect on a
    downstream/offline WSUS server is that SDP-sourced fields (Filename, Hash,
    Command Line, Support URL, CVE IDs) appear blank, and the Patch My PC
    Publisher's Modify Published Updates wizard reports "Limited details
    available" for the update. Transferring the Type 6 record restores them.

    Export mode reads every latest-revision Type 6 record from SUSDB, writes each
    to an XML file keyed by UpdateID + RevisionNumber + LanguageID, and packages
    them (plus a manifest) into a single ZIP.

    Import mode reads that ZIP on the disconnected WSUS server, matches each
    package back to the already-imported update using UpdateID + RevisionNumber,
    resolves the destination server's own RevisionID, and inserts the missing
    Type 6 metadata if it is not already present.

    The database type is selected by which parameters you pass:
      - Pass -SqlServer  -> SQL mode (full SQL Server hosting SUSDB).
      - Omit  -SqlServer -> WID mode (Windows Internal Database, local only).

    ---------------------------------------------------------------------------
    LEGAL DISCLAIMER
    This PowerShell script is shared with the community as-is.
    The author and co-author(s) make no warranties or guarantees regarding its
    functionality, reliability, or suitability for any specific purpose.
    Please note that the script may need to be modified or adapted to fit your
    specific environment or requirements.
    It is recommended to thoroughly test the script in a non-production
    environment before using it in a live or critical system.
    The author and co-author(s) cannot be held responsible for any damages,
    losses, or adverse effects that may arise from the use of this script.
    You assume all risks and responsibilities associated with its usage.
    ---------------------------------------------------------------------------

.PARAMETER Mode
    Export or Import.

.PARAMETER SqlServer
    SQL Server instance hosting SUSDB. Presence of this parameter selects SQL
    mode; omit it to target the local Windows Internal Database (WID).

.PARAMETER SqlDatabase
    SUSDB database name. Defaults to 'SUSDB'.

.PARAMETER ZipPath
    Full path to the transfer ZIP (created in Export, read in Import).

.NOTES
    Name      : Invoke-WsusSdpTransfer.ps1
    Publisher : Patch My PC
    Author    : Ben Whitmore
    Copyright : (c) Patch My PC. All rights reserved.
    Requires  : Windows PowerShell 5.1

    The import path writes directly to internal SUSDB tables. This is NOT a
    Microsoft-supported WSUS database modification method and should be treated
    as a controlled workaround, not a standard supported operation.

    WID mode uses a local named pipe and therefore must be run ON the WSUS
    server, elevated, under an account with access to SUSDB. Modern WSUS
    (Server 2012+) uses the MICROSOFT##WID pipe. Legacy WSUS 3.0 (SSEE) is not
    supported by this script.

    Import is idempotent: existing Type 6 rows are detected and skipped, so a
    failed or partial run can be re-run safely.

    ---------------------------------------------------------------------------
    LEGAL DISCLAIMER
    This PowerShell script is shared with the community as-is.
    The author and co-author(s) make no warranties or guarantees regarding its
    functionality, reliability, or suitability for any specific purpose.
    Please note that the script may need to be modified or adapted to fit your
    specific environment or requirements.
    It is recommended to thoroughly test the script in a non-production
    environment before using it in a live or critical system.
    The author and co-author(s) cannot be held responsible for any damages,
    losses, or adverse effects that may arise from the use of this script.
    You assume all risks and responsibilities associated with its usage.
    ---------------------------------------------------------------------------

.EXAMPLE
    # Export from full SQL
    .\Invoke-WsusSdpTransfer.ps1 -Mode Export -SqlServer "sql1.contoso.com" -ZipPath "C:\Temp\WSUS-SDP.zip"

.EXAMPLE
    # Import to full SQL
    .\Invoke-WsusSdpTransfer.ps1 -Mode Import -SqlServer "sql2.contoso.com" -ZipPath "C:\Temp\WSUS-SDP.zip"

.EXAMPLE
    # Export from Windows Internal Database (WID) - run locally on the WSUS server
    .\Invoke-WsusSdpTransfer.ps1 -Mode Export -ZipPath "C:\Temp\WSUS-SDP.zip"

.EXAMPLE
    # Import to Windows Internal Database (WID) - run locally on the WSUS server
    .\Invoke-WsusSdpTransfer.ps1 -Mode Import -ZipPath "C:\Temp\WSUS-SDP.zip"
#>

[CmdletBinding(DefaultParameterSetName = 'WID')]
param (
    [Parameter(Mandatory)]
    [ValidateSet('Export', 'Import')]
    [string]$Mode,

    # Presence of -SqlServer selects the SQL parameter set; omitting it selects WID.
    [Parameter(Mandatory, ParameterSetName = 'SQL')]
    [ValidateNotNullOrEmpty()]
    [string]$SqlServer,

    [Parameter(ParameterSetName = 'SQL')]
    [Parameter(ParameterSetName = 'WID')]
    [ValidateNotNullOrEmpty()]
    [string]$SqlDatabase = 'SUSDB',

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ZipPath
)

$ErrorActionPreference = 'Stop'

# The parameter set name is the database type: 'SQL' or 'WID'.
$DatabaseType = $PSCmdlet.ParameterSetName

# Compiled ZIP API (System.IO.Compression) is used instead of Compress-Archive /
# Expand-Archive: it is deterministic, faster, avoids the script-module quirks of
# the Archive cmdlets, and has no practical size limit.
Add-Type -AssemblyName System.IO.Compression.FileSystem

#region Validate ZIP path -----------------------------------------------------

if ([System.IO.Path]::GetExtension($ZipPath) -ne '.zip') {
    throw "-ZipPath must specify a .zip file, for example: C:\WSUS-SDP-Export.zip"
}

# Resolve to a full, absolute path.
$ZipPath = [System.IO.Path]::GetFullPath($ZipPath)

# ZipPath must not point to an existing directory.
if (Test-Path -LiteralPath $ZipPath -PathType Container) {
    throw "-ZipPath points to a directory. Specify the ZIP filename, for example: C:\WSUS-SDP-Export.zip"
}

#endregion

#region Environment checks ----------------------------------------------------

if ($DatabaseType -eq 'WID') {
    # WID is reachable only via a local named pipe and typically requires elevation.
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Warning "WID mode connects to a local named pipe and usually requires an elevated session. If the connection fails, re-run as Administrator on the WSUS server."
    }
}

#endregion

#region Build SQL connection --------------------------------------------------

if ($DatabaseType -eq 'WID') {
    # Standard WSUS Windows Internal Database named pipe (Server 2012+).
    $DataSource = 'np:\\.\pipe\MICROSOFT##WID\tsql\query'
}
else {
    $DataSource = $SqlServer
}

# Use the builder so the connection string is assembled safely (no reliance on
# whitespace/newline tolerance in the parser).
$csb = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
$csb['Data Source'] = $DataSource
$csb['Initial Catalog'] = $SqlDatabase
$csb['Integrated Security'] = $true
$csb['TrustServerCertificate'] = $true
$csb['Connect Timeout'] = 30
$connectionString = $csb.ConnectionString

#endregion

#region Banner ----------------------------------------------------------------

Write-Host
Write-Host "WSUS SDP Metadata Transfer"
Write-Host "--------------------------"
Write-Host "Mode          : $Mode"
Write-Host "Database Type : $DatabaseType"
Write-Host "Database      : $SqlDatabase"
if ($DatabaseType -eq 'SQL') {
    Write-Host "SQL Server    : $SqlServer"
}
else {
    Write-Host "WID           : $DataSource"
}
Write-Host "ZIP           : $ZipPath"
Write-Host

#endregion

#region Open connection -------------------------------------------------------

$connection = New-Object System.Data.SqlClient.SqlConnection $connectionString
try {
    $connection.Open()
}
catch {
    $connection.Dispose()
    throw "Unable to connect to WSUS database '$SqlDatabase'. $($_.Exception.Message)"
}

#endregion

try {

    #region EXPORT ------------------------------------------------------------

    if ($Mode -eq 'Export') {

        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("WSUS-SDP-" + [Guid]::NewGuid().ToString())
        New-Item -Path $tempRoot -ItemType Directory -Force | Out-Null

        try {
            $query = @"
SELECT
    CONVERT(varchar(36), u.UpdateID) AS UpdateID,
    r.RevisionNumber,
    x.LanguageID,
    CAST(x.RootElementXml AS nvarchar(max)) AS SdpXml
FROM dbo.tbXml x
INNER JOIN dbo.tbRevision r
    ON x.RevisionID = r.RevisionID
INNER JOIN dbo.tbUpdate u
    ON r.LocalUpdateID = u.LocalUpdateID
WHERE
    x.RootElementType = 6
    AND r.IsLatestRevision = 1
ORDER BY
    u.UpdateID,
    r.RevisionNumber,
    x.LanguageID;
"@

            $command = $connection.CreateCommand()
            $command.CommandText = $query
            $command.CommandTimeout = 0

            $reader = $command.ExecuteReader()

            $count = 0
            $manifestEntries = New-Object System.Collections.Generic.List[object]
            $utf8NoBom = New-Object System.Text.UTF8Encoding($false)

            try {
                while ($reader.Read()) {

                    $updateId = $reader['UpdateID'].ToString().ToLowerInvariant()
                    $revisionNumber = [int]$reader['RevisionNumber']
                    $languageId = [int]$reader['LanguageID']
                    $xml = $reader['SdpXml'].ToString()

                    $fileName = '{0}_Rev{1}_Lang{2}.xml' -f $updateId, $revisionNumber, $languageId
                    $filePath = Join-Path $tempRoot $fileName

                    # Store as UTF-8 without BOM.
                    [System.IO.File]::WriteAllText($filePath, $xml, $utf8NoBom)

                    $manifestEntries.Add([PSCustomObject]@{
                            UpdateID       = $updateId
                            RevisionNumber = $revisionNumber
                            LanguageID     = $languageId
                            FileName       = $fileName
                            # Match the on-disk encoding (UTF-8) so the count is meaningful.
                            XmlBytes       = $utf8NoBom.GetByteCount($xml)
                        })

                    Write-Host "Exported : $fileName"
                    $count++
                }
            }
            finally {
                $reader.Close()
                $reader.Dispose()
                $command.Dispose()
            }

            if ($count -eq 0) {
                Write-Warning "No RootElementType 6 (SDP) records found. The ZIP will contain only a manifest."
            }

            #region Manifest ------------------------------------------------------

            $exportedUtc = [DateTime]::UtcNow.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)

            $manifest = [PSCustomObject]@{
                Format             = 'WSUS-RootElementType6'
                FormatVersion      = 1
                ExportedUtc        = $exportedUtc
                SourceDatabaseType = $DatabaseType
                SourceServer       = $DataSource
                SourceDatabase     = $SqlDatabase
                RootElementType    = 6
                ExportedItems      = $count
                # Force an array so a single-item export still serializes as a list.
                Items              = @($manifestEntries.ToArray())
            }

            $manifestPath = Join-Path $tempRoot 'manifest.json'
            $manifest |
            ConvertTo-Json -Depth 5 |
            Set-Content -Path $manifestPath -Encoding UTF8

            #endregion

            #region Create ZIP ----------------------------------------------------

            $zipDirectory = Split-Path $ZipPath -Parent
            if ($zipDirectory -and -not (Test-Path $zipDirectory)) {
                New-Item -Path $zipDirectory -ItemType Directory -Force | Out-Null
            }

            if (Test-Path $ZipPath) {
                Remove-Item $ZipPath -Force
            }

            # Zip the contents of $tempRoot at the archive root (includeBaseDirectory = $false).
            [System.IO.Compression.ZipFile]::CreateFromDirectory(
                $tempRoot,
                $ZipPath,
                [System.IO.Compression.CompressionLevel]::Optimal,
                $false
            )

            #endregion

            Write-Host
            Write-Host "Export complete."
            Write-Host "Type 6 packages exported : $count"
            Write-Host "ZIP created              : $ZipPath"
        }
        finally {
            if (Test-Path $tempRoot) {
                Remove-Item $tempRoot -Recurse -Force
            }
        }
    }

    #endregion

    #region IMPORT ------------------------------------------------------------

    if ($Mode -eq 'Import') {

        if (-not (Test-Path $ZipPath)) {
            throw "ZIP file does not exist: $ZipPath"
        }

        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("WSUS-SDP-" + [Guid]::NewGuid().ToString())
        New-Item -Path $tempRoot -ItemType Directory -Force | Out-Null

        try {
            [System.IO.Compression.ZipFile]::ExtractToDirectory($ZipPath, $tempRoot)

            #region Read manifest (informational) -----------------------------

            $manifestPath = Join-Path $tempRoot 'manifest.json'
            if (Test-Path $manifestPath) {
                $manifest = Get-Content -Path $manifestPath -Raw | ConvertFrom-Json
                Write-Host "Archive created : $($manifest.ExportedUtc)"
                Write-Host "Archive items   : $($manifest.ExportedItems)"
                Write-Host
            }

            #endregion

            $files = Get-ChildItem -Path $tempRoot -Filter '*.xml' -File

            $imported = 0
            $alreadyExists = 0
            $notFound = 0
            $skipped = 0   # malformed filename or content (not touched in DB)
            $failed = 0   # database error during insert

            # Compile the filename pattern once.
            $pattern = '^(?<UpdateID>[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})_Rev(?<Revision>\d+)_Lang(?<Language>\d+)$'

            # Prepared once; parameter values are reset per file below.
            $insertSql = @"
SET NOCOUNT ON;

DECLARE @RevisionID INT;

SELECT @RevisionID = r.RevisionID
FROM dbo.tbUpdate u
INNER JOIN dbo.tbRevision r
    ON u.LocalUpdateID = r.LocalUpdateID
WHERE
    u.UpdateID = @UpdateID
    AND r.RevisionNumber = @RevisionNumber;

IF @RevisionID IS NULL
BEGIN
    SELECT 'UpdateNotFound';
    RETURN;
END;

IF EXISTS
(
    SELECT 1
    FROM dbo.tbXml
    WHERE
        RevisionID = @RevisionID
        AND RootElementType = 6
        AND LanguageID = @LanguageID
)
BEGIN
    SELECT 'AlreadyExists';
    RETURN;
END;

INSERT INTO dbo.tbXml
(
    RootElementXml,
    RootElementType,
    LanguageID,
    RevisionID
)
VALUES
(
    @Xml,
    6,
    @LanguageID,
    @RevisionID
);

SELECT 'Imported';
"@

            foreach ($file in $files) {

                # Expected: 52fc34d1-c23a-4805-84be-da9f7a56833f_Rev1_Lang0.xml
                if ($file.BaseName -notmatch $pattern) {
                    Write-Warning "Unexpected filename, skipped: $($file.Name)"
                    $skipped++
                    continue
                }

                $updateId = [Guid]$Matches.UpdateID
                $revisionNumber = [int]$Matches.Revision
                $languageId = [int]$Matches.Language

                # Files were explicitly exported as UTF-8.
                $xml = [System.IO.File]::ReadAllText($file.FullName, [System.Text.Encoding]::UTF8)

                # Basic sanity check before touching SUSDB.
                if ([string]::IsNullOrWhiteSpace($xml) -or -not $xml.TrimStart().StartsWith('<')) {
                    Write-Warning "Invalid XML content, skipped: $($file.Name)"
                    $skipped++
                    continue
                }

                $command = $connection.CreateCommand()
                $command.CommandTimeout = 0
                $command.CommandText = $insertSql

                $null = $command.Parameters.Add('@UpdateID', [System.Data.SqlDbType]::UniqueIdentifier)
                $command.Parameters['@UpdateID'].Value = $updateId

                $null = $command.Parameters.Add('@RevisionNumber', [System.Data.SqlDbType]::Int)
                $command.Parameters['@RevisionNumber'].Value = $revisionNumber

                $null = $command.Parameters.Add('@LanguageID', [System.Data.SqlDbType]::Int)
                $command.Parameters['@LanguageID'].Value = $languageId

                # NVarChar(-1) = NVARCHAR(MAX).
                $null = $command.Parameters.Add('@Xml', [System.Data.SqlDbType]::NVarChar, -1)
                $command.Parameters['@Xml'].Value = $xml

                try {
                    # Each statement is atomic and the operation is idempotent
                    # (AlreadyExists guard), so a partial run is safe to re-run.
                    $result = [string]$command.ExecuteScalar()

                    switch ($result) {
                        'Imported' {
                            Write-Host "Imported : $($file.Name)"
                            $imported++
                        }
                        'AlreadyExists' {
                            Write-Host "Exists   : $($file.Name)"
                            $alreadyExists++
                        }
                        'UpdateNotFound' {
                            Write-Warning "Not found: $($file.Name)"
                            $notFound++
                        }
                        default {
                            Write-Warning "Unexpected result '$result': $($file.Name)"
                            $failed++
                        }
                    }
                }
                catch {
                    Write-Warning "Failed: $($file.Name)"
                    Write-Warning $_.Exception.Message
                    $failed++
                }
                finally {
                    $command.Dispose()
                }
            }

            Write-Host
            Write-Host "Import complete."
            Write-Host "Imported        : $imported"
            Write-Host "Already existed : $alreadyExists"
            Write-Host "Update not found: $notFound"
            Write-Host "Skipped         : $skipped"
            Write-Host "Failed          : $failed"
        }
        finally {
            if (Test-Path $tempRoot) {
                Remove-Item $tempRoot -Recurse -Force
            }
        }
    }

    #endregion

}
finally {
    #region Cleanup connection ------------------------------------------------
    if ($connection.State -eq [System.Data.ConnectionState]::Open) {
        $connection.Close()
    }
    $connection.Dispose()
    #endregion
}