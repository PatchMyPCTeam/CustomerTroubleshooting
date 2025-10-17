[CmdletBinding()]
param (
    [Parameter(Mandatory)]
    [ValidateScript({
        if (Test-Path $_) {
            $true
        } else {
            Write-Error "The path $_ does not exist."
            $false
        }
    })]
    [String]$Path
)

# No need to sort, default file system ordering here is perfect as-is
$smstslog = Get-ChildItem $Path -File -Filter 'smsts*.log'

$Regex = '(?<Result>Successfully completed the action|Failed to run the action)(?:: (?<FailedActionName>[^.]+)\. Error (?<ErrorCode>[^]]+)\]LOG]\!| \((?<SuccessActionName>[^)]+)\)).*?time="(?<Time>[^"]+)" date="(?<Date>[^"]+)"'

$r = foreach ($Log in $smstslog) {
    Get-Content $Log | ForEach-Object { 
        if ($_ -match $Regex) {

            [PSCustomObject]@{
                Result   = if ($Matches['Result'][0] -eq 'S') { 
                    'Success'
                    $Step = $Matches['SuccessActionName']
                    $ExitCode = 0
                } 
                else { 
                    'Failed'
                    $Step = $Matches['FailedActionName']
                    $ExitCode = $Matches['ErrorCode']
                }
                Step     = $Step
                ExitCode = $ExitCode
                Date     = '{0} {1}' -f $Matches['Date'], $Matches['Time']
                LogFile  = $Log.Name
            }
        }
    }
}

$r | Format-Table -AutoSize