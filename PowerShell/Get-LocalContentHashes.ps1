<#
.SYNOPSIS
    Script to list all the files in the Patch My PC Local Content Repository. 
    The list is exported as a LocalContentHashes.csv in the Local Content Repository folder

.NOTES
    ################# DISCLAIMER #################
    Patch My PC provides scripts, macro, and other code examples for illustration only, without warranty 
    either expressed or implied, including but not limited to the implied warranties of merchantability 
    and/or fitness for a particular purpose. This script is provided 'AS IS' and Patch My PC does not 
    guarantee that the following script, macro, or code can or should be used in any situation or that 
    operation of the code will be error-free.
#>

$pmpreg = 'SOFTWARE\Patch My PC Publishing Service'

Function Get-EncodedHash {
    [CmdletBinding()]
    Param(
        [Parameter(Position = 0)]
        [System.Object]$hashValue
    )
    $encodedHash = [String](
        ($hashValue |
        Select-Object Algorithm,
        @{Name = 'HashHex'; Expression = 'Hash' },
        @{Name = 'HashBase64'; Expression = { 
                [Convert]::ToBase64String(@( $_.Hash -split '(?<=\G..)(?=.)' | ForEach-Object { [byte]::Parse($_, 'HexNumber') } )) } 
        }, Path
        ).HashBase64
    )
    return $encodedHash

}

$settingsReg = (Get-ItemProperty -Path "HKLM:\$pmpreg" -Name "Path").Path
$settingsFile = Get-Item -Path $settingsReg
$settingsXml = [xml](Get-Content -Path (Join-Path -Path $settingsFile.FullName -ChildPath Settings.xml))
$localContentRepo = $settingsXml.'PatchMyPC-Settings'.LocalContentRepository

try {
    Test-Path -Path $localContentRepo -ErrorAction Stop
}
catch {
    Write-Warning -Message "Could not find the Local Content Repository path in the Patch My PC Publishing Service registry key"
    Exit
}

$files = Get-ChildItem -Path $localContentRepo -Recurse -File
Foreach ($file in $files) {
    $fileHash = Get-FileHash $file.FullName -Algorithm SHA1
    $encodedhash = Get-EncodedHash $fileHash
    $result = [PSCustomObject]@{
        Name = $file.FullName
        Hash = $encodedhash
    }
    $result
    $result | Export-Csv -Path $localContentRepo\LocalContentHashes.csv -Append -NoTypeInformation
}