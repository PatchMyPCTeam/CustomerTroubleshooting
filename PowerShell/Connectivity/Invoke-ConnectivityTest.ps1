<#
.SYNOPSIS
    Patch My PC Connectivity Test - diagnoses outbound connectivity for the Patch My PC
    Publishing Service, in the logged-on user context or the true SYSTEM context.

.DESCRIPTION
    A single-file WinForms tool for working out why the Patch My PC Publishing Service
    cannot reach the internet.

    Checks available:
      HTTP(S) GET      status, redirects, served host, proxy used, block-page detection
      File download    real bytes pulled through the proxy, hashed and identified, which
                       is the failure a headers-only GET cannot see (an inline scanner
                       will pass HTML and then block or rewrite an .exe or .msi)
      TCP ports        80 and 443, direct and through the proxy
      TLS handshake    negotiated protocol and cipher, certificate chain validation
      Cipher matrix    what the server accepts vs what SCHANNEL offers on this box
      Ping / Tracert / Nslookup
      DNS config       resolvers, suffixes and the relevant HOSTS entries
      SMB              445/139, then a real session - share ACLs, auth, dialect
      RPC / WMI        135, the dynamic port range, then a real DCOM connect and root\sms
      Proxy view       WinINET per account, machine-wide WinHTTP, and the Publisher's own

    The check selection follows the target: an http(s) address selects the web checks, a
    path containing a backslash selects the file-share checks, anything else selects the
    server checks.

    Proxy resolution mirrors a .NET application:
      System (WinINET) - the WinINET proxy of the account the checks run as
      Direct           - empty WebProxy, no proxy used
      Override         - WebProxy(host:port) with optional credentials

    Running as SYSTEM uses a one-shot Scheduled Task registered in the root of the Task
    Scheduler Library, run, read back and then removed along with its registry entries.
    PsExec is not required. That path needs elevation.

    The Publishing Service does not have to be installed. When it is absent the network
    checks still apply to this machine; only the service's own proxy setting cannot be
    read, and the tool says so.

---------------------------------------------------------------------------------
LEGAL DISCLAIMER

The PowerShell script provided is shared with the community as-is
The author and co-author(s) make no warranties or guarantees regarding its functionality, reliability, or suitability for any specific purpose
Please note that the script may need to be modified or adapted to fit your specific environment or requirements
It is recommended to thoroughly test the script in a non-production environment before using it in a live or critical system
The author and co-author(s) cannot be held responsible for any damages, losses, or adverse effects that may arise from the use of this script
You assume all risks and responsibilities associated with its usage
---------------------------------------------------------------------------------

.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -File .\Invoke-ConnectivityTest.ps1

    Opens the tool. Run elevated to read the SYSTEM proxy hive and to run checks as SYSTEM.
    There is nothing to configure on the command line - everything is driven from the window.

.NOTES
    Name       : Invoke-ConnectivityTest.ps1
    Author     : BenWhitmore@PatchMyPC
    Requires   : Windows PowerShell 5.1
#>
[CmdletBinding()]
param(
    # Not an interface - these only exist so the script can re-launch itself (SYSTEM task, runspaces).
    [switch]$SystemTest,
    [string]$ParamFile,
    [string]$OutFile,
    [switch]$NoGui
)

$ErrorActionPreference = 'Stop'
$script:SelfPath = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }

# 5.1 does not load these itself: without them HttpClientHandler and ProtectedData are missing.
foreach ($asm in 'System.Net.Http', 'System.Security') {
    try { Add-Type -AssemblyName $asm -ErrorAction Stop } catch { }
}

# Section headings in the results pane. Anchored so markdown tables can never match.
$script:HeadingRx = '^\s*(?:-{3,}|={3,}|#{3,})(?:\s.*?(?:-{3,}|={3,}|#{3,}))?\s*$'
try {
    $sp = [System.Net.SecurityProtocolType]::Tls12
    if ([enum]::GetNames([System.Net.SecurityProtocolType]) -contains 'Tls13') {
        $sp = $sp -bor [System.Net.SecurityProtocolType]::Tls13
    }
    [System.Net.ServicePointManager]::SecurityProtocol = $sp
}
catch { }

# Shared by the GUI and every worker runspace - nothing here may depend on the GUI scope.
$PNT_Functions = {

    # Read from the registry every call: .NET caches the system proxy for the life of the process.
    function Get-WinInetProxyLive {
        $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
        $ip = $null
        try { $ip = Get-ItemProperty -Path $key -ErrorAction Stop } catch {}

        $autoUrl = if ($ip) { [string]$ip.AutoConfigURL } else { '' }
        $autoDetect = $false
        try {
            $dcs = (Get-ItemProperty -Path (Join-Path $key 'Connections') -Name 'DefaultConnectionSettings' -ErrorAction Stop).DefaultConnectionSettings
            if ($dcs -and $dcs.Length -gt 8) { $autoDetect = (([int]$dcs[8] -band 0x08) -ne 0) }
        }
        catch {}

        if ($autoUrl -or $autoDetect) {
            $bits = @()
            if ($autoDetect) { $bits += 'WPAD auto-detect' }
            if ($autoUrl) { $bits += "PAC script $autoUrl" }
            return [pscustomobject]@{
                Proxy = [System.Net.WebRequest]::GetSystemWebProxy()
                Desc  = ('Windows proxy of the running account - {0} (script evaluated by Windows; cached for this process)' -f ($bits -join ' + '))
            }
        }

        $en = if ($ip -and $null -ne $ip.ProxyEnable) { [int]$ip.ProxyEnable } else { 0 }
        $srv = if ($ip) { [string]$ip.ProxyServer } else { '' }
        if ($en -eq 0 -or -not $srv) {
            return [pscustomobject]@{ Proxy = (New-Object System.Net.WebProxy); Desc = 'Windows proxy of the running account - none configured (direct)' }
        }

        # ProxyServer is either "host:port" or a per-scheme list "http=h:p;https=h:p;ftp=h:p".
        $addr = $srv
        if ($srv -like '*=*') {
            $map = @{}
            foreach ($part in ($srv -split ';')) {
                $kv = $part -split '=', 2
                if ($kv.Count -eq 2) { $map[$kv[0].Trim().ToLowerInvariant()] = $kv[1].Trim() }
            }
            $addr = if ($map['https']) { $map['https'] } elseif ($map['http']) { $map['http'] } else { ($map.Values | Select-Object -First 1) }
        }
        if (-not $addr) { return [pscustomobject]@{ Proxy = (New-Object System.Net.WebProxy); Desc = 'Windows proxy of the running account - none configured (direct)' } }
        if ($addr -notmatch '^[a-zA-Z]+://') { $addr = "http://$addr" }

        $wp = New-Object System.Net.WebProxy($addr, $false)
        $ovr = if ($ip) { [string]$ip.ProxyOverride } else { '' }
        $byp = New-Object System.Collections.Generic.List[string]
        foreach ($t in ($ovr -split ';')) {
            $t = "$t".Trim()
            if (-not $t) { continue }
            if ($t -eq '<local>') { $wp.BypassProxyOnLocal = $true; continue }
            if ($t -eq '<-loopback>') { continue }
            $byp.Add('^' + [regex]::Escape($t).Replace('\*', '.*') + '$')
        }
        if ($byp.Count -gt 0) { try { $wp.BypassList = $byp.ToArray() } catch {} }

        $d = ('Windows proxy of the running account - {0}' -f $addr)
        if ($ovr) { $d += (' (bypass: {0})' -f $ovr) }
        [pscustomobject]@{ Proxy = $wp; Desc = $d }
    }

    function Get-ProxySignature {
        param([ValidateSet('User', 'SYSTEM')][string]$Account = 'User')
        $sid = if ($Account -eq 'SYSTEM') { 'S-1-5-18' }
        else {
            if (-not $script:CtUserSid) { try { $script:CtUserSid = (Resolve-InteractiveUser).Sid } catch {} }
            $script:CtUserSid
        }
        $path = if ($sid) { "Registry::HKEY_USERS\$sid\Software\Microsoft\Windows\CurrentVersion\Internet Settings" }
        else { 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' }

        $en = 0; $srv = ''; $ovr = ''; $auto = ''; $readable = $true
        try {
            $ip = Get-ItemProperty -Path $path -ErrorAction Stop
            if ($null -ne $ip.ProxyEnable) { $en = [int]$ip.ProxyEnable }
            $srv = [string]$ip.ProxyServer; $ovr = [string]$ip.ProxyOverride; $auto = [string]$ip.AutoConfigURL
        }
        catch { $readable = $false }

        $winHttp = ''
        try {
            $b = (Get-ItemProperty -Path "$path\Connections" -Name 'WinHttpSettings' -ErrorAction Stop).WinHttpSettings
            if ($b) { $winHttp = [System.BitConverter]::ToString($b) }
        }
        catch {}
        try {
            $b2 = (Get-ItemProperty -Path "$path\Connections" -Name 'DefaultConnectionSettings' -ErrorAction Stop).DefaultConnectionSettings
            if ($b2) { $winHttp += '/' + [System.BitConverter]::ToString($b2) }
        }
        catch {}

        $summary =
        if (-not $readable) { 'cannot read this hive (re-launch as administrator)' }
        elseif ($auto) { "PAC/WPAD - $auto" }
        elseif ($en -eq 1 -and $srv) { $srv + $(if ($ovr) { " (bypass: $ovr)" } else { '' }) }
        else { 'none configured (direct)' }

        [pscustomobject]@{
            Account  = $Account
            Readable = $readable
            Summary  = $summary
            UsesPac  = [bool]$auto
            Sig      = ('{0}|{1}|{2}|{3}|{4}' -f $en, $srv, $ovr, $auto, $winHttp)
        }
    }

    # Always empty on a normal server, but on .NET 5+ they take priority over the registry.
    function Get-ProxyEnvOverrides {
        $found = New-Object System.Collections.Generic.List[string]
        foreach ($n in 'HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'NO_PROXY') {
            $v = [Environment]::GetEnvironmentVariable($n)
            if (-not $v) { $v = [Environment]::GetEnvironmentVariable($n.ToLowerInvariant()) }
            if ($v) { $found.Add(('{0}={1}' -f $n, $v)) }
        }
        return $found
    }

    # Sends the running account's Windows credentials - a Negotiate proxy accepts a user, refuses SYSTEM.
    function Get-EffectiveProxy {
        param(
            [ValidateSet('None', 'System', 'Explicit')][string]$Mode = 'System',
            [string]$PHost, [int]$PPort, [string]$PUser, [string]$PPass,
            [bool]$UseDefaultCreds = $false
        )
        $res = switch ($Mode) {
            'None' {
                # Empty WebProxy => direct connection (bypass everything).
                [pscustomobject]@{ Proxy = (New-Object System.Net.WebProxy); Desc = 'Direct (no proxy)' }
            }
            'System' {
                Get-WinInetProxyLive
            }
            'Explicit' {
                $url = ('http://{0}:{1}' -f $PHost, $PPort)
                $wp = New-Object System.Net.WebProxy($url, $true)
                if ($PUser) { $wp.Credentials = New-Object System.Net.NetworkCredential($PUser, $PPass) }
                [pscustomobject]@{ Proxy = $wp; Desc = ('Explicit proxy {0}{1}' -f $url, $(if ($PUser) { ' (with credentials)' }else { '' })) }
            }
        }
        if ($UseDefaultCreds -and $res -and $res.Proxy -and -not $PUser) {
            try {
                $res.Proxy.Credentials = [System.Net.CredentialCache]::DefaultNetworkCredentials
                $res.Desc = $res.Desc + ' [sending Windows credentials]'
            }
            catch {}
        }
        $res | Add-Member -NotePropertyName UseDefaultCreds -NotePropertyValue ([bool]$UseDefaultCreds) -Force
        return $res
    }

    # Returns @{Host;Port} of the proxy .NET would use for $Uri, or $null for direct.
    function Resolve-ProxyForUri {
        param($ProxyObj, [string]$Uri)
        if (-not $ProxyObj) { return $null }
        try {
            $u = [uri]$Uri
            if ($ProxyObj.IsBypassed($u)) { return $null }
            $p = $ProxyObj.GetProxy($u)
            if (-not $p -or ($p.Host -eq $u.Host -and $p.Port -eq $u.Port)) { return $null }
            return @{ Host = $p.Host; Port = $p.Port }
        }
        catch { return $null }
    }

    # Many CDNs and WAFs reject a request with no User-Agent, and that 403 looks like a corporate block.
    $script:HttpUserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) PatchMyPC-ConnectivityTest/1.0'

    function Invoke-HttpTest {
        param([string]$Url, $ProxyObj, [string]$ProxyMode = 'System', [int]$TimeoutSec = 30)
        $out = New-Object System.Collections.Generic.List[string]
        $out.Add("=== HTTP(S) GET : $Url ===")
        $handler = New-Object System.Net.Http.HttpClientHandler
        $handler.AllowAutoRedirect = $true
        switch ($ProxyMode) {
            'None' { $handler.UseProxy = $false }
            'System' { $handler.UseProxy = $true; $handler.Proxy = $null }
            'Explicit' { $handler.UseProxy = $true; $handler.Proxy = $ProxyObj.Proxy }
        }
        # In System mode the handler resolves the proxy, so the credential must attach to it, not the WebProxy.
        $sendCreds = [bool]($ProxyObj -and $ProxyObj.UseDefaultCreds)
        if ($sendCreds) {
            try { $handler.UseDefaultCredentials = $true } catch {}
            try { $handler.DefaultProxyCredentials = [System.Net.CredentialCache]::DefaultNetworkCredentials } catch {}
        }
        $resolved = Resolve-ProxyForUri -ProxyObj $ProxyObj.Proxy -Uri $Url
        if ($resolved) { $out.Add(("  Proxy used     : {0}:{1}" -f $resolved.Host, $resolved.Port)) }
        else { $out.Add("  Proxy used     : (direct)") }
        $out.Add(("  Proxy creds    : {0}" -f $(if ($sendCreds) { 'sending Windows credentials of ' + [System.Security.Principal.WindowsIdentity]::GetCurrent().Name } else { 'none sent' })))
        $envOv = Get-ProxyEnvOverrides
        if ($envOv.Count) {
            $out.Add("  Proxy env vars : " + ($envOv -join '; '))
            $out.Add("                   (ignored by .NET Framework, but they OVERRIDE the registry on .NET 5+)")
        }

        $client = New-Object System.Net.Http.HttpClient($handler)
        $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSec)
        try { $client.DefaultRequestHeaders.UserAgent.ParseAdd($script:HttpUserAgent) } catch {}
        $out.Add(("  User-Agent     : {0}" -f $script:HttpUserAgent))
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $req = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Get, $Url)
            $resp = $client.SendAsync($req, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
            $sw.Stop()
            $code = [int]$resp.StatusCode
            $out.Add(("  Status         : {0} {1}" -f $code, $resp.ReasonPhrase))
            $out.Add(("  Elapsed        : {0} ms" -f $sw.ElapsedMilliseconds))
            $finalUri = $resp.RequestMessage.RequestUri.AbsoluteUri
            if ($finalUri -ne $Url) { $out.Add("  Redirected to  : $finalUri") }
            $srv = $null
            if ($resp.Headers.TryGetValues('Server', [ref]$srv)) { $out.Add(("  Server         : {0}" -f ($srv -join ', '))) }

            # 407 is the proxy refusing THIS ACCOUNT, so it is reported apart from 404/500 "reached".
            if ($code -eq 407) {
                $schemes = @()
                try { foreach ($h in $resp.Headers.ProxyAuthenticate) { if ($h.Scheme) { $schemes += $h.Scheme } } } catch {}
                if (-not $schemes.Count) {
                    $pa = $null
                    try { if ($resp.Headers.TryGetValues('Proxy-Authenticate', [ref]$pa)) { $schemes = @($pa) } } catch {}
                }
                $out.Add(("  Proxy wants    : {0}" -f $(if ($schemes.Count) { ($schemes -join ', ') } else { '(no Proxy-Authenticate header returned)' })))
                $out.Add("  RESULT         : FAIL - the PROXY rejected this account. The target was never contacted.")
                $out.Add("")
                $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
                if (-not $sendCreds) {
                    $out.Add(("  No credentials were sent. Tick 'Send Windows credentials to the proxy' under PROXY"))
                    $out.Add(("  and run this again to test whether {0} is allowed through." -f $me))
                }
                elseif ($me -eq 'NT AUTHORITY\SYSTEM') {
                    $out.Add("  SYSTEM presents the COMPUTER account (DOMAIN\HOSTNAME`$) to the proxy, not a user.")
                    $out.Add("  If the same URL passes as the logged-on user, the proxy is not authorising the")
                    $out.Add("  machine account. Either grant it access, or set an explicit proxy credential on")
                    $out.Add("  the Publishing Service Advanced tab - the service cannot use your user account.")
                }
                else {
                    $out.Add(("  {0} was sent but still refused. Check the proxy allows this user, and that the" -f $me))
                    $out.Add("  scheme above is one Windows can satisfy (Negotiate/NTLM need a domain identity;")
                    $out.Add("  Basic needs an explicit username and password in the Override option).")
                }
                $resp.Dispose()
                return $out
            }

            $ok = ($code -ge 200 -and $code -lt 400)
            $out.Add(("  RESULT         : {0}" -f $(if ($ok) { 'PASS' }else { 'REACHED (HTTP ' + $code + ')' })))
            if (-not $ok) {
                # An HTTP status means DNS, proxy, TCP and TLS all worked - nothing here is a network fault.
                $out.Add("                   The server answered, so DNS, the proxy, TCP and TLS all worked.")
                $out.Add("                   The status above is the site's own decision about the request.")
                if ($code -eq 403 -or $code -eq 429 -or $code -eq 406) {
                    $out.Add("                   403/406/429 on a direct file link is usually bot protection")
                    $out.Add("                   (Cloudflare and friends), not a block on this machine. The")
                    $out.Add("                   'File download' check requests it the way a downloader would.")
                }
            }
            # A proxy block page answers 200 from a different host, so compare served host against requested.
            if ($ok -and $finalUri -ne $Url) {
                try {
                    $h1 = ([uri]$Url).Host; $h2 = ([uri]$finalUri).Host
                    if ($h1 -ne $h2) {
                        $out.Add(("  NOTE           : the response came from {0}, not {1}." -f $h2, $h1))
                        $out.Add("                   A proxy block page or captive portal looks exactly like this.")
                    }
                }
                catch {}
            }
            $resp.Dispose()
        }
        catch {
            $sw.Stop()
            $ex = $_.Exception
            while ($ex.InnerException) { $ex = $ex.InnerException }
            $out.Add(("  Elapsed        : {0} ms" -f $sw.ElapsedMilliseconds))
            $out.Add(("  ERROR          : [{0}] {1}" -f $ex.GetType().Name, $ex.Message))
            if ($ex -is [System.Net.WebException] -and $ex.Status) { $out.Add(("  WebStatus      : {0}" -f $ex.Status)) }
            $out.Add("  RESULT         : FAIL")
        }
        finally { $client.Dispose() }
        return $out
    }

    # A headers-only GET does not prove a FILE gets through - a scanner passes HTML then blocks the .exe.
    function Invoke-DownloadTest {
        param([string]$Url, $ProxyObj, [string]$ProxyMode = 'System', [int]$TimeoutSec = 90, [int]$MaxBytes = 8388608)
        $out = New-Object System.Collections.Generic.List[string]
        $out.Add("=== FILE DOWNLOAD : $Url ===")

        function Get-BodyKind {
            param([byte[]]$B, [int]$N)
            if ($N -le 0) { return 'empty' }
            function Match([byte[]]$b, [int]$n, [int[]]$sig) {
                if ($n -lt $sig.Length) { return $false }
                for ($i = 0; $i -lt $sig.Length; $i++) { if ($b[$i] -ne $sig[$i]) { return $false } }
                return $true
            }
            if (Match $B $N @(0x4D, 0x5A)) { return 'Windows executable (MZ)' }
            if (Match $B $N @(0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1)) { return 'Windows Installer / compound file (MSI)' }
            if (Match $B $N @(0x4D, 0x53, 0x43, 0x46)) { return 'Windows cabinet (MSCF)' }
            if (Match $B $N @(0x50, 0x4B, 0x03, 0x04)) { return 'ZIP container (zip/msix/appx/nupkg)' }
            if (Match $B $N @(0x25, 0x50, 0x44, 0x46)) { return 'PDF' }
            if (Match $B $N @(0x1F, 0x8B)) { return 'gzip' }
            if (Match $B $N @(0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C)) { return '7-Zip archive' }
            if (Match $B $N @(0x52, 0x61, 0x72, 0x21)) { return 'RAR archive' }
            $take = [Math]::Min($N, 512)
            $txt = ''
            try { $txt = [System.Text.Encoding]::ASCII.GetString($B, 0, $take) } catch {}
            $lead = $txt.TrimStart([char]0xFEFF, ' ', "`t", "`r", "`n")
            if ($lead -match '^(?i)<(!doctype\s+html|html|head|body)\b') { return 'HTML page' }
            if ($lead -match '^(?i)<\?xml') { return 'XML' }
            if ($lead -match '^\s*[\{\[]') { return 'JSON' }
            # Anything with no control characters other than tab/CR/LF reads as plain text.
            $ctrl = 0
            foreach ($ch in $txt.ToCharArray()) {
                $c = [int]$ch
                if ($c -lt 32 -and $c -ne 9 -and $c -ne 10 -and $c -ne 13) { $ctrl++ }
            }
            if ($ctrl -eq 0) { return 'plain text' }
            return 'binary (unrecognised)'
        }

        function Format-Bytes {
            param([long]$N)
            if ($N -lt 1024) { return ('{0} bytes' -f $N) }
            if ($N -lt 1048576) { return ('{0:N1} KB' -f ($N / 1KB)) }
            if ($N -lt 1073741824) { return ('{0:N1} MB' -f ($N / 1MB)) }
            return ('{0:N2} GB' -f ($N / 1GB))
        }

        $filterNames = @('zscaler', 'bluecoat', 'blue coat', 'forcepoint', 'websense', 'netskope', 'iboss',
            'barracuda', 'fortiguard', 'fortinet', 'sophos', 'mcafee', 'trellix', 'squid',
            'palo alto', 'check point', 'checkpoint', 'trend micro', 'umbrella', 'symantec',
            'sonicwall', 'watchguard', 'untangle', 'smoothwall', 'lightspeed', 'contentkeeper',
            'web filter', 'content filter', 'access denied', 'blocked by', 'policy violation',
            'your organization', 'your organisation', 'network administrator')
        function Add-BodyHints {
            param($Out, [byte[]]$B, [int]$N)
            if ($N -le 0) { return }
            $txt = ''
            try { $txt = [System.Text.Encoding]::UTF8.GetString($B, 0, $N) } catch { return }
            if ($txt -match '(?is)<title[^>]*>(.{1,200}?)</title>') {
                $t = ($Matches[1] -replace '\s+', ' ').Trim()
                if ($t) { $Out.Add(("  Page title     : {0}" -f $t)) }
            }
            $hits = @()
            foreach ($nm in $filterNames) { if ($txt -match [regex]::Escape($nm)) { $hits += $nm } }
            if ($hits.Count) {
                $Out.Add(("  Page mentions  : {0}" -f (($hits | Select-Object -Unique -First 5) -join ', ')))
                $Out.Add("                   That wording belongs to a filtering product, not to the")
                $Out.Add("                   website. Something on this network answered instead of it.")
                return $true
            }
            return $false
        }
        function Read-Preview {
            param($Response, [int]$Max = 16384)
            $b = New-Object byte[] $Max
            $n = 0
            try {
                $s = $Response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
                while ($n -lt $Max) {
                    $r = $s.Read($b, $n, $Max - $n)
                    if ($r -le 0) { break }
                    $n += $r
                }
                $s.Dispose()
            }
            catch {}
            return @{ Bytes = $b; Count = $n }
        }

        $binExt = @('.exe', '.msi', '.msu', '.msp', '.cab', '.zip', '.msix', '.msixbundle', '.appx', '.appxbundle',
            '.7z', '.rar', '.iso', '.dmg', '.jar', '.nupkg', '.gz', '.tgz', '.tar', '.bin', '.dll', '.pkg')
        $leaf = ''
        $expectBinary = $false
        try {
            $leaf = [System.IO.Path]::GetFileName(([uri]$Url).AbsolutePath)
            $ext = [System.IO.Path]::GetExtension($leaf)
            $expectBinary = ($ext -and ($binExt -contains $ext.ToLowerInvariant()))
        }
        catch {}

        $handler = New-Object System.Net.Http.HttpClientHandler
        $handler.AllowAutoRedirect = $true
        switch ($ProxyMode) {
            'None' { $handler.UseProxy = $false }
            'System' { $handler.UseProxy = $true; $handler.Proxy = $null }
            'Explicit' { $handler.UseProxy = $true; $handler.Proxy = $ProxyObj.Proxy }
        }
        $sendCreds = [bool]($ProxyObj -and $ProxyObj.UseDefaultCreds)
        if ($sendCreds) {
            try { $handler.UseDefaultCredentials = $true } catch {}
            try { $handler.DefaultProxyCredentials = [System.Net.CredentialCache]::DefaultNetworkCredentials } catch {}
        }
        $resolved = Resolve-ProxyForUri -ProxyObj $ProxyObj.Proxy -Uri $Url
        if ($resolved) { $out.Add(("  Proxy used     : {0}:{1}" -f $resolved.Host, $resolved.Port)) }
        else { $out.Add("  Proxy used     : (direct)") }
        $out.Add(("  Proxy creds    : {0}" -f $(if ($sendCreds) { 'sending Windows credentials of ' + [System.Security.Principal.WindowsIdentity]::GetCurrent().Name } else { 'none sent' })))
        $out.Add(("  Cap            : {0} - enough to prove the transfer, not the whole file" -f (Format-Bytes $MaxBytes)))

        $client = New-Object System.Net.Http.HttpClient($handler)
        $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSec)
        try { $client.DefaultRequestHeaders.UserAgent.ParseAdd($script:HttpUserAgent) } catch {}
        # Downloaders do not ask for HTML; saying so stops some CDNs serving a landing page.
        try { $client.DefaultRequestHeaders.Accept.ParseAdd('*/*') } catch {}

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $resp = $null; $stream = $null
        try {
            $req = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Get, $Url)
            $resp = $client.SendAsync($req, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
            $code = [int]$resp.StatusCode
            $ttfb = $sw.ElapsedMilliseconds
            $out.Add(("  Status         : {0} {1}" -f $code, $resp.ReasonPhrase))
            $out.Add(("  Headers after  : {0} ms" -f $ttfb))
            $finalUri = $resp.RequestMessage.RequestUri.AbsoluteUri
            if ($finalUri -ne $Url) { $out.Add("  Redirected to  : $finalUri") }

            $ctype = ''
            try { if ($resp.Content.Headers.ContentType) { $ctype = $resp.Content.Headers.ContentType.ToString() } } catch {}
            $out.Add(("  Content-Type   : {0}" -f $(if ($ctype) { $ctype } else { '(not sent)' })))
            $declared = -1
            try { if ($resp.Content.Headers.ContentLength -ne $null) { $declared = [long]$resp.Content.Headers.ContentLength } } catch {}
            $out.Add(("  Content-Length : {0}" -f $(if ($declared -ge 0) { '{0} ({1} bytes)' -f (Format-Bytes $declared), $declared } else { '(not sent - chunked or streamed)' })))
            $disp = $null
            try { if ($resp.Content.Headers.TryGetValues('Content-Disposition', [ref]$disp)) { $out.Add(("  Disposition    : {0}" -f ($disp -join ', '))) } } catch {}
            $srv = $null
            try { if ($resp.Headers.TryGetValues('Server', [ref]$srv)) { $out.Add(("  Server         : {0}" -f ($srv -join ', '))) } } catch {}

            if ($code -eq 407) {
                $out.Add("  RESULT         : FAIL - the PROXY rejected this account. Nothing was downloaded.")
                $out.Add("                   Run 'HTTP(S) GET' as well - it explains the 407 in full.")
                return $out
            }
            if ($code -lt 200 -or $code -ge 300) {
                $pv = Read-Preview -Response $resp
                $pkind = Get-BodyKind -B $pv.Bytes -N $pv.Count
                if ($pv.Count -gt 0) { $out.Add(("  Refusal body   : {0}, {1}" -f $pkind, (Format-Bytes $pv.Count))) }
                $filtered = Add-BodyHints -Out $out -B $pv.Bytes -N $pv.Count
                $out.Add(("  RESULT         : FAIL - the server refused to serve the file (HTTP {0})." -f $code))
                if ($filtered) {
                    $out.Add("                   The refusal came from a filtering product on this network,")
                    $out.Add("                   not from the website. Have the URL allowed and try again.")
                }
                else {
                    $out.Add("                   The connection itself worked: DNS, the proxy, TCP and TLS")
                    $out.Add("                   all succeeded, or there would be no status code to show.")
                    if ($code -eq 403 -or $code -eq 429 -or $code -eq 406) {
                        $out.Add("                   Nothing in the response names a web filter, so a 403/406/429")
                        $out.Add("                   on a public download link is most likely bot protection at")
                        $out.Add("                   the CDN rather than a block on this network.")
                    }
                }
                return $out
            }

            # Hash over exactly the bytes that arrived, so a whole file can be checked against the vendor's.
            $sha = [System.Security.Cryptography.SHA256]::Create()
            $buf = New-Object byte[] 65536
            $head = New-Object byte[] 8192
            $headN = 0
            [long]$total = 0
            $capped = $false
            $stream = $resp.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
            while ($true) {
                $n = $stream.Read($buf, 0, $buf.Length)
                if ($n -le 0) { break }
                if ($headN -lt $head.Length) {
                    $take = [Math]::Min($n, $head.Length - $headN)
                    [Array]::Copy($buf, 0, $head, $headN, $take)
                    $headN += $take
                }
                [void]$sha.TransformBlock($buf, 0, $n, $null, 0)
                $total += $n
                if ($total -ge $MaxBytes) { $capped = $true; break }
            }
            [void]$sha.TransformFinalBlock((New-Object byte[] 0), 0, 0)
            $sw.Stop()
            $hash = ([BitConverter]::ToString($sha.Hash) -replace '-', '')
            $sha.Dispose()

            $secs = [Math]::Max($sw.Elapsed.TotalSeconds, 0.001)
            $out.Add(("  Bytes received : {0} ({1} bytes){2}" -f (Format-Bytes $total), $total, $(if ($capped) { ' - stopped at the cap' } else { '' })))
            $out.Add(("  Elapsed        : {0} ms" -f $sw.ElapsedMilliseconds))
            $out.Add(("  Throughput     : {0}/s" -f (Format-Bytes ([long]($total / $secs)))))
            $kind = Get-BodyKind -B $head -N $headN
            $out.Add(("  Body really is : {0}" -f $kind))
            # Capped, short or empty means no whole file was hashed - offering that hash would mislead.
            $whole = ((-not $capped) -and $total -gt 0 -and ($declared -lt 0 -or $total -eq $declared))
            if ($whole) {
                $out.Add(("  SHA-256        : {0}" -f $hash))
                $out.Add("                   (of the complete file - compare with the vendor's published hash)")
            }
            elseif ($total -gt 0) {
                $out.Add(("  SHA-256        : {0}" -f $hash))
                $out.Add(("                   (of the {0} that arrived, NOT of the whole file)" -f (Format-Bytes $total)))
            }

            # Order matters: a block page dressed as a 200 must be called out before anything looks acceptable.
            $htmlBody = ($kind -eq 'HTML page')
            if ($expectBinary -and $htmlBody) {
                [void](Add-BodyHints -Out $out -B $head -N $headN)
                $out.Add(("  RESULT         : FAIL - {0} was requested and a WEB PAGE came back instead." -f $leaf))
                $out.Add("                   Something between here and the server replaced the file. That is")
                $out.Add("                   what a proxy block page, a captive portal or an AV interception")
                $out.Add("                   page looks like: HTTP 200, but the payload is HTML.")
                $out.Add("                   Open the BROWSER tab and fetch this URL to read what it says.")
                return $out
            }
            if ($expectBinary -and $ctype -match '(?i)text/html') {
                $out.Add("  RESULT         : WARN - the file arrived but the server labelled it text/html.")
                $out.Add("                   Check the bytes above really are the file you expected.")
                return $out
            }
            if ($total -eq 0) {
                $out.Add("  RESULT         : FAIL - the response had no body at all.")
                $out.Add("                   A 200 with zero bytes is typical of a filter that allows the")
                $out.Add("                   request through and then drops the payload.")
                return $out
            }
            if ((-not $capped) -and $declared -ge 0 -and $total -lt $declared) {
                $out.Add(("  RESULT         : FAIL - the transfer stopped early: {0} of {1} bytes arrived." -f $total, $declared))
                $out.Add("                   A truncated download is the signature of an inline scanner or a")
                $out.Add("                   proxy that gives up on large or unrecognised content.")
                return $out
            }
            if ($capped) {
                $out.Add(("  RESULT         : PASS - {0} of real file data came through at {1}/s." -f (Format-Bytes $total), (Format-Bytes ([long]($total / $secs)))))
                $out.Add("                   The download was stopped deliberately at the cap, so this proves")
                $out.Add("                   the payload flows; it does not prove the very last byte arrives.")
            }
            else {
                $out.Add(("  RESULT         : PASS - the complete file downloaded ({0})." -f (Format-Bytes $total)))
            }
        }
        catch {
            $sw.Stop()
            $ex = $_.Exception
            while ($ex.InnerException) { $ex = $ex.InnerException }
            $out.Add(("  Elapsed        : {0} ms" -f $sw.ElapsedMilliseconds))
            $out.Add(("  ERROR          : [{0}] {1}" -f $ex.GetType().Name, $ex.Message))
            $out.Add("  RESULT         : FAIL - the download could not be completed.")
            if ($ex -is [System.IO.IOException] -or $ex -is [System.Net.Sockets.SocketException]) {
                $out.Add("                   The connection dropped part-way through. When the headers")
                $out.Add("                   succeed and the body does not, suspect something inspecting")
                $out.Add("                   the content rather than the connection.")
            }
        }
        finally {
            if ($stream) { try { $stream.Dispose() } catch {} }
            if ($resp) { try { $resp.Dispose() }   catch {} }
            $client.Dispose()
        }
        return $out
    }

    function Get-HttpContent {
        param([string]$Url, $ProxyObj, [string]$ProxyMode = 'System', [int]$TimeoutSec = 30, [int]$MaxChars = 524288)
        $res = [pscustomobject]@{
            Ok = $false; Status = $null; Reason = $null; ContentType = $null; Body = ''
            BodyChars = 0; Truncated = $false; ProxyUsed = $null; FinalUrl = $Url; Error = $null
        }
        $handler = New-Object System.Net.Http.HttpClientHandler
        $handler.AllowAutoRedirect = $true
        switch ($ProxyMode) {
            'None' { $handler.UseProxy = $false }
            'System' { $handler.UseProxy = $true; $handler.Proxy = $null }
            'Explicit' { $handler.UseProxy = $true; $handler.Proxy = $ProxyObj.Proxy }
        }
        if ($ProxyObj -and $ProxyObj.UseDefaultCreds) {
            try { $handler.UseDefaultCredentials = $true } catch {}
            try { $handler.DefaultProxyCredentials = [System.Net.CredentialCache]::DefaultNetworkCredentials } catch {}
        }
        $resolved = Resolve-ProxyForUri -ProxyObj $ProxyObj.Proxy -Uri $Url
        $res.ProxyUsed = if ($resolved) { "{0}:{1}" -f $resolved.Host, $resolved.Port } else { '(direct)' }
        $client = New-Object System.Net.Http.HttpClient($handler)
        $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSec)
        try { $client.DefaultRequestHeaders.UserAgent.ParseAdd('Mozilla/5.0 (Windows NT 10.0; Win64; x64) ConnTest') } catch {}
        try {
            $resp = $client.GetAsync($Url).GetAwaiter().GetResult()
            $res.Status = [int]$resp.StatusCode
            $res.Reason = $resp.ReasonPhrase
            $res.Ok = $resp.IsSuccessStatusCode
            $res.FinalUrl = $resp.RequestMessage.RequestUri.AbsoluteUri
            if ($resp.Content.Headers.ContentType) { $res.ContentType = $resp.Content.Headers.ContentType.ToString() }
            # Some endpoints are megabytes; rendering the rest just freezes the UI.
            $full = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            $res.BodyChars = $full.Length
            if ($MaxChars -gt 0 -and $full.Length -gt $MaxChars) {
                $res.Body = $full.Substring(0, $MaxChars)
                $res.Truncated = $true
            }
            else {
                $res.Body = $full
            }
            $resp.Dispose()
        }
        catch {
            $ex = $_.Exception; while ($ex.InnerException) { $ex = $ex.InnerException }
            $res.Error = ("[{0}] {1}" -f $ex.GetType().Name, $ex.Message)
        }
        finally { $client.Dispose() }
        return $res
    }

    # Four target forms: http(s) URL, \\server\share, server\share, bare host[:port].
    function Get-TargetInfo {
        param([string]$Target)
        $t = ([string]$Target).Trim()
        $res = [pscustomobject]@{
            Raw = $t; Kind = 'Host'; HostName = ''; Share = ''; Path = ''
            Url = ''; IsHttp = $false; Port = 0
        }
        if (-not $t) { return $res }

        if ($t -match '^(?i)https?://') {
            # An http(s) scheme is decisive even half-typed, or 'https://' classifies as a server.
            $res.Kind = 'Http'; $res.IsHttp = $true; $res.Url = $t
            $u = $null
            try { $u = [uri]$t } catch {}
            if ($u -and $u.IsAbsoluteUri -and $u.Host) {
                $res.HostName = $u.Host
                $res.Port = $u.Port; $res.Path = $u.AbsolutePath
            }
            return $res
        }
        # UNC. The // form is accepted too - it is what comes back off a clipboard sometimes.
        if ($t -match '^(?:\\\\|//)([^\\/]+)(?:[\\/]([^\\/]+))?(?:[\\/](.*))?$') {
            $res.Kind = 'Unc'; $res.HostName = $Matches[1]
            $res.Share = [string]$Matches[2]; $res.Path = [string]$Matches[3]
            $res.Port = 445
            return $res
        }
        # A backslash still means a share: 'bb-cm1\packages' as a bare host silently tested IPC$ instead.
        if ($t -match '^([^\\/]+)\\(.*)$') {
            $res.Kind = 'Unc'
            $hp = $Matches[1]; $tail = [string]$Matches[2]
            $res.Port = 445
            if ($hp -match '^\[(.+)\]:(\d+)$' -or $hp -match '^([^:]+):(\d+)$') {
                $res.HostName = $Matches[1]; $res.Port = [int]$Matches[2]
            }
            else { $res.HostName = $hp }
            if ($tail -match '^([^\\/]+)[\\/]?(.*)$') {
                $res.Share = $Matches[1]; $res.Path = [string]$Matches[2]
            }
            return $res
        }
        # Bare host. The port branch demands a single colon so a bare IPv6 literal is not misread.
        $h = ($t -split '/')[0]
        if ($h -match '^\[(.+)\]:(\d+)$') { $res.HostName = $Matches[1]; $res.Port = [int]$Matches[2] }
        elseif ($h -match '^([^:]+):(\d+)$') { $res.HostName = $Matches[1]; $res.Port = [int]$Matches[2] }
        else { $res.HostName = $h }
        return $res
    }

    # Every check needing a host name goes through this, so none has to know which form was typed.
    function Get-TargetHost {
        param([string]$Target)
        (Get-TargetInfo -Target $Target).HostName
    }

    function Test-TcpPortRaw {
        param([string]$HostName, [int]$Port, [int]$TimeoutMs = 5000)
        $tcp = New-Object System.Net.Sockets.TcpClient
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $iar = $tcp.BeginConnect($HostName, $Port, $null, $null)
            if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs)) { $sw.Stop(); return [pscustomobject]@{Open = $false; Ms = $TimeoutMs; Error = 'timeout' } }
            $tcp.EndConnect($iar); $sw.Stop()
            return [pscustomobject]@{Open = $true; Ms = $sw.ElapsedMilliseconds; Error = $null }
        }
        catch {
            # Unwrapped, or the reason reads 'Exception calling "EndConnect"...' with the useful half buried.
            $sw.Stop()
            $ex = $_.Exception; while ($ex.InnerException) { $ex = $ex.InnerException }
            return [pscustomobject]@{Open = $false; Ms = $sw.ElapsedMilliseconds; Error = (([string]$ex.Message).Trim()) }
        }
        finally { $tcp.Close() }
    }

    function Invoke-PortTest {
        param([string]$Url, $ProxyObj)
        $out = New-Object System.Collections.Generic.List[string]
        $hostName = (Get-TargetInfo -Target $Url).HostName
        # Header first, so this check always produces a section - and a card - even if the network drops.
        $out.Add("=== TCP PORT TEST : $hostName ===")
        try {
            $open = @{}
            foreach ($p in 80, 443) {
                $r = Test-TcpPortRaw -HostName $hostName -Port $p
                $open[$p] = [bool]$r.Open
                if ($r.Open) { $out.Add(("  {0,-5} direct : OPEN  ({1} ms)" -f $p, $r.Ms)) }
                else { $out.Add(("  {0,-5} direct : CLOSED/blocked ({1})" -f $p, $r.Error)) }
            }
            $resolved = Resolve-ProxyForUri -ProxyObj $ProxyObj.Proxy -Uri $Url
            $proxyOpen = $null
            if ($resolved) {
                $r = Test-TcpPortRaw -HostName $resolved.Host -Port $resolved.Port
                $proxyOpen = [bool]$r.Open
                if ($r.Open) { $out.Add(("  proxy {0}:{1} : OPEN  ({2} ms)" -f $resolved.Host, $resolved.Port, $r.Ms)) }
                else { $out.Add(("  proxy {0}:{1} : CLOSED/blocked ({2})" -f $resolved.Host, $resolved.Port, $r.Error)) }
            }
            # With a proxy the target's own ports are expected shut; the proxy's port is what matters.
            if ($resolved) {
                if ($proxyOpen) { $out.Add(("  RESULT         : PASS - the proxy {0}:{1} accepts connections." -f $resolved.Host, $resolved.Port)) }
                else { $out.Add(("  RESULT         : FAIL - the proxy {0}:{1} cannot be reached, so nothing can be downloaded through it." -f $resolved.Host, $resolved.Port)) }
            }
            elseif ($open[443]) { $out.Add("  RESULT         : PASS - 443/tcp is reachable, which is the port the Publisher needs.") }
            elseif ($open[80]) { $out.Add("  RESULT         : FAIL - 80/tcp is open but 443/tcp is blocked, so HTTPS cannot get out.") }
            else { $out.Add("  RESULT         : FAIL - neither 80/tcp nor 443/tcp could be reached.") }
        }
        catch {
            $ex = $_.Exception; while ($ex.InnerException) { $ex = $ex.InnerException }
            $out.Add(("  ERROR          : {0}" -f $ex.Message))
            $out.Add("  RESULT         : FAIL - the port test could not be completed.")
        }
        return $out
    }

    # SMB and RPC both authenticate, so a result is meaningless without naming the account.
    function Get-RunningAccount {
        try {
            $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
            if ($id.IsSystem) { return ('{0} (on the network: {1}$)' -f $id.Name, $env:COMPUTERNAME) }
            return $id.Name
        }
        catch { return "$env:USERDOMAIN\$env:USERNAME" }
    }

    # For the internal-server case: a UNC path, a content source, or the SMS Provider's admin shares.
    function Invoke-SmbTest {
        param([string]$Url)
        $out = New-Object System.Collections.Generic.List[string]
        $ti = Get-TargetInfo -Target $Url
        $hostName = $ti.HostName
        $out.Add("=== SMB / FILE SHARE : $hostName ===")
        try {
            $out.Add(("  Tested as      : {0}" -f (Get-RunningAccount)))

            # 139 is legacy NetBIOS - reported because 139-only differs from neither, but never what you want.
            $r445 = Test-TcpPortRaw -HostName $hostName -Port 445 -TimeoutMs 5000
            if ($r445.Open) { $out.Add(("  445/tcp SMB    : OPEN  ({0} ms)" -f $r445.Ms)) }
            else { $out.Add(("  445/tcp SMB    : CLOSED/blocked ({0})" -f $r445.Error)) }

            $r139 = Test-TcpPortRaw -HostName $hostName -Port 139 -TimeoutMs 3000
            if ($r139.Open) { $out.Add(("  139/tcp NetBIOS: OPEN  ({0} ms) - legacy, not used by modern SMB" -f $r139.Ms)) }
            else { $out.Add(("  139/tcp NetBIOS: CLOSED/blocked - normal on a modern network")) }

            # The port only proves a socket; auth, share ACLs and a missing share all happen after it.
            $share = if ($ti.Share) { $ti.Share } else { 'IPC$' }
            $unc = '\\{0}\{1}' -f $hostName, $share
            if ($ti.Share -and $ti.Path) { $unc = '\\{0}\{1}\{2}' -f $hostName, $ti.Share, $ti.Path }
            $out.Add(("  Path tested    : {0}{1}" -f $unc, $(if ($ti.Share) { '' } else { '  (no share given - testing the IPC$ pipe, which is what proves authentication)' })))

            $access = 'skipped'
            if ($r445.Open -or $r139.Open) {
                if ($ti.Share) {
                    try {
                        $items = @(Get-ChildItem -LiteralPath $unc -Force -ErrorAction Stop | Select-Object -First 5)
                        $access = 'ok'
                        $out.Add(("  Access         : OK - the share opened and listed {0} entr{1}" -f $items.Count, $(if ($items.Count -eq 1) { 'y' } else { 'ies' })))
                        foreach ($it in $items) { $out.Add(("                   {0}" -f $it.Name)) }
                    }
                    catch {
                        $ex = $_.Exception; while ($ex.InnerException) { $ex = $ex.InnerException }
                        $msg = ([string]$ex.Message).Trim()
                        if ($msg -match '(?i)access is denied|unauthorized') { $access = 'denied'; $out.Add("  Access         : ACCESS DENIED - the port is open and the share exists, but this account cannot read it.") }
                        elseif ($msg -match '(?i)cannot find|does not exist|not found') { $access = 'missing'; $out.Add("  Access         : NOT FOUND - the host answered but there is no such share or folder.") }
                        else { $access = 'error'; $out.Add(("  Access         : FAILED - {0}" -f $msg)) }
                    }
                }
                else {
                    # net.exe performs a real session setup and its exit code separates "refused you" from "unreachable".
                    try {
                        $null = & net.exe use $unc /persistent:no 2>&1
                        $rc = $LASTEXITCODE
                        if ($rc -eq 0) {
                            $access = 'ok'
                            $out.Add("  Access         : OK - an authenticated SMB session was established.")
                            $null = & net.exe use $unc /delete 2>&1
                        }
                        else {
                            $access = 'denied'
                            $out.Add(("  Access         : FAILED - net use returned {0}. The port is open but the SMB session was refused." -f $rc))
                        }
                    }
                    catch {
                        $access = 'error'
                        $ex = $_.Exception; while ($ex.InnerException) { $ex = $ex.InnerException }
                        $out.Add(("  Access         : FAILED - {0}" -f ([string]$ex.Message).Trim()))
                    }
                }
            }

            # The negotiated dialect matters when a hardened server has disabled SMB1/SMB2.
            try {
                $conn = @(Get-SmbConnection -ServerName $hostName -ErrorAction SilentlyContinue)
                if ($conn.Count) {
                    $d = ($conn | ForEach-Object { [string]$_.Dialect } | Sort-Object -Unique) -join ', '
                    if ($d) { $out.Add(("  SMB dialect    : {0}" -f $d)) }
                }
            }
            catch {}

            if ($access -eq 'ok') { $out.Add("  RESULT         : PASS - the share is reachable and this account can use it.") }
            elseif ($access -eq 'denied') { $out.Add("  RESULT         : FAIL - SMB is reachable but this account was refused. Check the share and NTFS permissions for the account named above.") }
            elseif ($access -eq 'missing') { $out.Add("  RESULT         : FAIL - SMB is reachable but the share or folder does not exist on that host.") }
            elseif ($r445.Open) { $out.Add("  RESULT         : FAIL - 445/tcp is open but the share could not be opened.") }
            elseif ($r139.Open) { $out.Add("  RESULT         : FAIL - only legacy 139/tcp answered. 445/tcp is what modern SMB needs.") }
            else { $out.Add("  RESULT         : FAIL - neither 445/tcp nor 139/tcp could be reached, so no file share on this host is usable.") }
        }
        catch {
            $ex = $_.Exception; while ($ex.InnerException) { $ex = $ex.InnerException }
            $out.Add(("  ERROR          : {0}" -f ([string]$ex.Message).Trim()))
            $out.Add("  RESULT         : FAIL - the SMB test could not be completed.")
        }
        return $out
    }

    # 135 only proves the mapper answers - the call lands on a dynamic port, so complete a real DCOM connect.
    function Invoke-RpcTest {
        param([string]$Url)
        $out = New-Object System.Collections.Generic.List[string]
        $ti = Get-TargetInfo -Target $Url
        $hostName = $ti.HostName
        $out.Add("=== RPC / ENDPOINT MAPPER : $hostName ===")
        try {
            $out.Add(("  Tested as      : {0}" -f (Get-RunningAccount)))

            $r135 = Test-TcpPortRaw -HostName $hostName -Port 135 -TimeoutMs 5000
            if ($r135.Open) { $out.Add(("  135/tcp EPM    : OPEN  ({0} ms)" -f $r135.Ms)) }
            else { $out.Add(("  135/tcp EPM    : CLOSED/blocked ({0})" -f $r135.Error)) }

            # A far end restricted to a narrow range shows up here. netsh labels are localised - take numbers positionally.
            try {
                $dyn = (& netsh.exe int ipv4 show dynamicport tcp 2>&1 | Out-String)
                $nums = @([regex]::Matches($dyn, '\d+') | ForEach-Object { [int]$_.Value })
                if ($nums.Count -ge 2) {
                    $out.Add(("  Local dyn range: {0}-{1} ({2} ports) - this machine's own range" -f
                            $nums[0], ($nums[0] + $nums[1] - 1), $nums[1]))
                }
            }
            catch {}

            # Skipped when 135 is shut: already known, and a dropped packet would hang for the full timeout.
            $wmiOk = $false; $wmiWhy = ''
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            if (-not $r135.Open) {
                $sw.Stop()
                $out.Add("  DCOM root\cimv2: not attempted - 135/tcp did not answer, so the call has nowhere to start")
            }
            else {
                try {
                    $opts = New-Object System.Management.ConnectionOptions
                    $opts.Impersonation = [System.Management.ImpersonationLevel]::Impersonate
                    $opts.Authentication = [System.Management.AuthenticationLevel]::PacketPrivacy
                    $opts.Timeout = [TimeSpan]::FromSeconds(20)
                    $sc = New-Object System.Management.ManagementScope (("\\{0}\root\cimv2" -f $hostName), $opts)
                    $sc.Connect()
                    $sw.Stop()
                    $wmiOk = $sc.IsConnected
                }
                catch {
                    $sw.Stop()
                    $ex = $_.Exception; while ($ex.InnerException) { $ex = $ex.InnerException }
                    $wmiWhy = ([string]$ex.Message).Trim()
                }
                if ($wmiOk) {
                    $out.Add(("  DCOM root\cimv2: CONNECTED ({0} ms) - the mapper handed out a dynamic port and it was reachable" -f $sw.ElapsedMilliseconds))
                }
                elseif ($wmiWhy -match '(?i)Unable to find type|ManagementScope') {
                    $out.Add("  DCOM root\cimv2: not testable from this PowerShell host (System.Management is unavailable)")
                }
                else {
                    $out.Add(("  DCOM root\cimv2: FAILED - {0}" -f $wmiWhy))
                }
            }

            # Absent root\sms is information, not a failure - but present and refused is the usual problem.
            $smsState = 'skip'
            if ($wmiOk) {
                try {
                    $opts2 = New-Object System.Management.ConnectionOptions
                    $opts2.Impersonation = [System.Management.ImpersonationLevel]::Impersonate
                    $opts2.Authentication = [System.Management.AuthenticationLevel]::PacketPrivacy
                    $opts2.Timeout = [TimeSpan]::FromSeconds(20)
                    $sc2 = New-Object System.Management.ManagementScope (("\\{0}\root\sms" -f $hostName), $opts2)
                    $sc2.Connect()
                    $smsState = 'ok'
                    $site = ''
                    try {
                        $q = New-Object System.Management.ObjectQuery 'SELECT SiteCode FROM SMS_ProviderLocation'
                        $s = New-Object System.Management.ManagementObjectSearcher ($sc2, $q)
                        $site = (@($s.Get()) | ForEach-Object { [string]$_['SiteCode'] } | Where-Object { $_ } | Select-Object -First 1)
                    }
                    catch {}
                    if ($site) { $out.Add(("  SMS Provider   : YES - root\sms answered, site code {0}" -f $site)) }
                    else { $out.Add("  SMS Provider   : YES - root\sms answered") }
                }
                catch {
                    $ex = $_.Exception; while ($ex.InnerException) { $ex = $ex.InnerException }
                    if ($ex.Message -match '(?i)invalid namespace') {
                        $smsState = 'absent'
                        $out.Add("  SMS Provider   : no root\sms namespace - this host is not an SMS Provider (not a fault)")
                    }
                    else {
                        $smsState = 'denied'
                        $out.Add(("  SMS Provider   : root\sms exists but was refused - {0}" -f ([string]$ex.Message).Trim()))
                    }
                }
            }

            if ($smsState -eq 'denied') { $out.Add("  RESULT         : FAIL - RPC works, but this account cannot use the SMS Provider. Check its rights in the ConfigMgr console.") }
            elseif ($wmiOk) { $out.Add("  RESULT         : PASS - the endpoint mapper and a dynamic RPC port are both reachable and authentication succeeded.") }
            elseif ($r135.Open) { $out.Add("  RESULT         : FAIL - 135/tcp answers but the RPC call itself did not complete. That is the signature of a firewall that opened 135 and nothing else, or of an authentication failure.") }
            else { $out.Add("  RESULT         : FAIL - 135/tcp could not be reached, so no RPC-based connection to this host can work.") }
        }
        catch {
            $ex = $_.Exception; while ($ex.InnerException) { $ex = $ex.InnerException }
            $out.Add(("  ERROR          : {0}" -f ([string]$ex.Message).Trim()))
            $out.Add("  RESULT         : FAIL - the RPC test could not be completed.")
        }
        return $out
    }

    function Invoke-PingTest {
        param([string]$Url, [int]$Count = 4)
        $out = New-Object System.Collections.Generic.List[string]
        $hostName = Get-TargetHost -Target $Url
        $out.Add("=== PING : $hostName ===")
        $ping = New-Object System.Net.NetworkInformation.Ping
        $times = @()
        $errs = 0
        for ($i = 0; $i -lt $Count; $i++) {
            try {
                $r = $ping.Send($hostName, 4000)
                if ($r.Status -eq 'Success') { $out.Add(("  Reply from {0}: {1} ms  TTL={2}" -f $r.Address, $r.RoundtripTime, $r.Options.Ttl)); $times += $r.RoundtripTime }
                else { $out.Add(("  {0}" -f $r.Status)) }
            }
            catch { $errs++; $ex = $_.Exception; while ($ex.InnerException) { $ex = $ex.InnerException }; $out.Add(("  ERROR: {0}" -f $ex.Message)) }
        }
        if ($times.Count) {
            $out.Add(("  Summary: {0}/{1} replies, avg {2} ms" -f $times.Count, $Count, [math]::Round(($times | Measure-Object -Average).Average, 0)))
            $out.Add(("  RESULT         : PASS - the host answers ICMP ({0}/{1} replies)." -f $times.Count, $Count))
        }
        elseif ($errs -eq $Count) {
            # Every attempt threw rather than timed out, so the name never resolved - a real failure.
            $out.Add("  Summary: the host could not be contacted at all")
            $out.Add("  RESULT         : FAIL - the host name could not be resolved or reached.")
        }
        else {
            $out.Add("  Summary: no replies (ICMP may be blocked - not necessarily a connectivity problem)")
            # Not a FAIL: plenty of networks drop ICMP by policy while HTTPS works perfectly.
            $out.Add("  RESULT         : WARN - no ICMP reply. This is common and does not by itself stop downloads.")
        }
        return $out
    }

    function Invoke-TracertTest {
        param([string]$Url, [int]$MaxHops = 20)
        $hostName = Get-TargetHost -Target $Url
        Write-Output "=== TRACERT : $hostName (max $MaxHops hops) ==="
        try {
            & tracert.exe -h $MaxHops -w 1500 $hostName 2>&1 | ForEach-Object {
                if ("$_".Trim()) { Write-Output "  $_" }
            }
        }
        catch { Write-Output "  ERROR: $($_.Exception.Message)" }
    }

    function Invoke-NslookupTest {
        param([string]$Url)
        $out = New-Object System.Collections.Generic.List[string]
        $hostName = Get-TargetHost -Target $Url
        $out.Add("=== DNS LOOKUP : $hostName ===")
        try {
            $servers = (Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Where-Object { $_.ServerAddresses } | Select-Object -First 1 -ExpandProperty ServerAddresses) -join ', '
            if ($servers) { $out.Add("  DNS servers    : $servers") }
        }
        catch { }
        $addrs = 0
        try {
            $recs = Resolve-DnsName -Name $hostName -ErrorAction Stop
            foreach ($r in $recs) {
                switch ($r.Type) {
                    'A' { $out.Add(("  A     {0}" -f $r.IPAddress)); $addrs++ }
                    'AAAA' { $out.Add(("  AAAA  {0}" -f $r.IPAddress)); $addrs++ }
                    'CNAME' { $out.Add(("  CNAME {0} -> {1}" -f $r.Name, $r.NameHost)) }
                }
            }
        }
        catch {
            $out.Add("  Resolve-DnsName failed, falling back to nslookup.exe:")
            try {
                # nslookup prints its own Server:/Address: block first, so only count answers after "Name:".
                $inAnswer = $false
                (& nslookup.exe $hostName 2>&1) | ForEach-Object {
                    $t = "$_"
                    $out.Add("  $t")
                    if ($t -match '^\s*Name\s*:') { $inAnswer = $true }
                    elseif ($inAnswer -and $t -match '^\s*Address(es)?\s*:\s*\S') { $addrs++ }
                }
            }
            catch { $out.Add("  ERROR: $($_.Exception.Message)") }
        }
        if ($addrs -gt 0) { $out.Add(("  RESULT         : PASS - the name resolved to {0} address(es)." -f $addrs)) }
        else { $out.Add("  RESULT         : FAIL - the name did not resolve, so nothing can connect to it.") }
        return $out
    }

    # Opens a TCP stream to the target, tunnelling through an HTTP proxy (CONNECT) if one applies.
    function Open-TargetStream {
        param([string]$TargetHost, [int]$TargetPort, $ResolvedProxy, [int]$TimeoutMs = 8000)
        if ($ResolvedProxy) {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $iar = $tcp.BeginConnect($ResolvedProxy.Host, $ResolvedProxy.Port, $null, $null)
            if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs)) { throw "timeout connecting to proxy $($ResolvedProxy.Host):$($ResolvedProxy.Port)" }
            $tcp.EndConnect($iar)
            $ns = $tcp.GetStream()
            $connect = "CONNECT {0}:{1} HTTP/1.1`r`nHost: {0}:{1}`r`nProxy-Connection: Keep-Alive`r`n`r`n" -f $TargetHost, $TargetPort
            $bytes = [Text.Encoding]::ASCII.GetBytes($connect)
            $ns.Write($bytes, 0, $bytes.Length)
            $sb = New-Object System.Text.StringBuilder
            $buf = New-Object byte[] 1
            while ($true) {
                if ($ns.Read($buf, 0, 1) -le 0) { break }
                [void]$sb.Append([char]$buf[0])
                if ($sb.ToString().EndsWith("`r`n`r`n")) { break }
            }
            $reply = $sb.ToString()
            $statusLine = ($reply -split "`r`n")[0]
            if ($statusLine -notmatch '\s2\d\d\s') {
                $tcp.Close()
                # A 407 means the tunnel never opened, so tag it "unknown" rather than "suite refused".
                if ($statusLine -match '\s407\s') {
                    $schemes = @()
                    foreach ($ln in ($reply -split "`r`n")) {
                        if ($ln -match '(?i)^Proxy-Authenticate:\s*(.+)$') { $schemes += $Matches[1].Trim() }
                    }
                    $detail = if ($schemes.Count) { ' wants: ' + ($schemes -join ', ') } else { '' }
                    throw ("PROXYAUTH407: the proxy requires authentication and refused this account.{0}" -f $detail)
                }
                throw "proxy CONNECT failed: $statusLine"
            }
            return @{ Tcp = $tcp; Stream = $ns }
        }
        else {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $iar = $tcp.BeginConnect($TargetHost, $TargetPort, $null, $null)
            if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs)) { throw "timeout connecting to $TargetHost`:$TargetPort" }
            $tcp.EndConnect($iar)
            return @{ Tcp = $tcp; Stream = $tcp.GetStream() }
        }
    }

    function Get-SslInfo {
        param([string]$Url, $ProxyObj)
        $out = New-Object System.Collections.Generic.List[string]
        $u = $null; try { $u = [uri]$Url } catch {}
        $targetHost = if ($u -and $u.Host) { $u.Host } else { $Url }
        $targetPort = if ($u -and $u.Port -gt 0) { $u.Port } else { 443 }
        # Header first, so this check always produces a section even if what follows fails.
        $out.Add("=== TLS HANDSHAKE : $targetHost`:$targetPort ===")
        $handshakeOk = $false
        $certErr = $null
        $hsError = $null
        try {
            $resolved = Resolve-ProxyForUri -ProxyObj $ProxyObj.Proxy -Uri ("https://{0}" -f $targetHost)
            if ($resolved) { $out.Add(("  via proxy      : {0}:{1} (CONNECT)" -f $resolved.Host, $resolved.Port)) }

            $conn = $null
            try {
                $conn = Open-TargetStream -TargetHost $targetHost -TargetPort $targetPort -ResolvedProxy $resolved
                $cb = [System.Net.Security.RemoteCertificateValidationCallback] {
                    param($s, $cert, $chain, $errors)
                    if ($errors -ne [System.Net.Security.SslPolicyErrors]::None) { $script:__certErr = $errors.ToString() }
                    return $true
                }
                $script:__certErr = $null
                $ssl = New-Object System.Net.Security.SslStream($conn.Stream, $false, $cb)
                $ssl.AuthenticateAsClient($targetHost)
                $handshakeOk = $true
                $out.Add(("  Negotiated     : {0}" -f $ssl.SslProtocol))
                $cipherLine = $null
                $niProp = $ssl.GetType().GetProperty('NegotiatedCipherSuite')
                if ($niProp) { $cipherLine = [string]$niProp.GetValue($ssl) }
                if (-not $cipherLine) {
                    $cipherLine = ("{0}/{1}bit  KeyEx={2}  Hash={3}" -f $ssl.CipherAlgorithm, $ssl.CipherStrength, $ssl.KeyExchangeAlgorithm, $ssl.HashAlgorithm)
                }
                $out.Add(("  Cipher suite   : {0}" -f $cipherLine))
                $rc = $ssl.RemoteCertificate
                if ($rc) {
                    $c2 = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($rc)
                    $out.Add(("  Cert subject   : {0}" -f $c2.Subject))
                    $out.Add(("  Cert issuer    : {0}" -f $c2.Issuer))
                    $out.Add(("  Cert expires   : {0}" -f $c2.NotAfter))
                }
                if ($script:__certErr) { $certErr = $script:__certErr; $out.Add(("  Cert warning   : {0}" -f $certErr)) }
                else { $out.Add("  Cert validation: OK (trusted)") }
                $ssl.Dispose()
            }
            catch { $ex = $_.Exception; while ($ex.InnerException) { $ex = $ex.InnerException }; $hsError = $ex.Message; $out.Add(("  ERROR          : {0}" -f $ex.Message)) }
            finally { if ($conn) { try { $conn.Tcp.Close() } catch {} } }

            $protos = @{ 'Tls1.0' = 'Tls'; 'Tls1.1' = 'Tls11'; 'Tls1.2' = 'Tls12' }
            if ([enum]::GetNames([System.Security.Authentication.SslProtocols]) -contains 'Tls13') { $protos['Tls1.3'] = 'Tls13' }
            $out.Add("  Server accepts :")
            foreach ($name in ($protos.Keys | Sort-Object)) {
                $c2 = $null
                try {
                    $c2 = Open-TargetStream -TargetHost $targetHost -TargetPort $targetPort -ResolvedProxy $resolved
                    $ssl2 = New-Object System.Net.Security.SslStream($c2.Stream, $false, ([System.Net.Security.RemoteCertificateValidationCallback] { param($a, $b, $c, $d) $true }))
                    $ssl2.AuthenticateAsClient($targetHost, $null, [System.Security.Authentication.SslProtocols]$protos[$name], $false)
                    $out.Add(("     {0,-7}: YES" -f $name))
                    $ssl2.Dispose()
                }
                catch { $out.Add(("     {0,-7}: no" -f $name)) }
                finally { if ($c2) { try { $c2.Tcp.Close() } catch {} } }
            }
        }
        catch {
            $ex = $_.Exception; while ($ex.InnerException) { $ex = $ex.InnerException }
            if (-not $hsError) { $hsError = $ex.Message }
            $out.Add(("  ERROR          : {0}" -f $ex.Message))
        }
        if (-not $handshakeOk) { $out.Add(("  RESULT         : FAIL - the TLS handshake did not complete ({0})." -f $hsError)) }
        elseif ($certErr) { $out.Add(("  RESULT         : WARN - the handshake worked but the certificate did not validate ({0})." -f $certErr)) }
        else { $out.Add("  RESULT         : PASS - the TLS handshake completed and the certificate is trusted.") }
        return $out
    }

    # SCHANNEL will not let .NET restrict the offered suites, so speak TLS by hand - one hello per suite.

    function Get-CipherSuiteTable {
        @(
            [pscustomobject]@{ Id = 0x1302; Name = 'TLS_AES_256_GCM_SHA384'; Tls13 = $true; Weak = $false; MinOs = 5 }
            [pscustomobject]@{ Id = 0x1303; Name = 'TLS_CHACHA20_POLY1305_SHA256'; Tls13 = $true; Weak = $false; MinOs = 5 }
            [pscustomobject]@{ Id = 0x1301; Name = 'TLS_AES_128_GCM_SHA256'; Tls13 = $true; Weak = $false; MinOs = 5 }
            [pscustomobject]@{ Id = 0xC030; Name = 'TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384'; Tls13 = $false; Weak = $false; MinOs = 2 }
            [pscustomobject]@{ Id = 0xC02C; Name = 'TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384'; Tls13 = $false; Weak = $false; MinOs = 1 }
            [pscustomobject]@{ Id = 0xC02F; Name = 'TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256'; Tls13 = $false; Weak = $false; MinOs = 2 }
            [pscustomobject]@{ Id = 0xC02B; Name = 'TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256'; Tls13 = $false; Weak = $false; MinOs = 1 }
            [pscustomobject]@{ Id = 0xCCA8; Name = 'TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256'; Tls13 = $false; Weak = $false; MinOs = 4 }
            [pscustomobject]@{ Id = 0xCCA9; Name = 'TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256'; Tls13 = $false; Weak = $false; MinOs = 4 }
            [pscustomobject]@{ Id = 0x009F; Name = 'TLS_DHE_RSA_WITH_AES_256_GCM_SHA384'; Tls13 = $false; Weak = $false; MinOs = 1 }
            [pscustomobject]@{ Id = 0x009E; Name = 'TLS_DHE_RSA_WITH_AES_128_GCM_SHA256'; Tls13 = $false; Weak = $false; MinOs = 1 }
            [pscustomobject]@{ Id = 0x009D; Name = 'TLS_RSA_WITH_AES_256_GCM_SHA384'; Tls13 = $false; Weak = $false; MinOs = 1 }
            [pscustomobject]@{ Id = 0x009C; Name = 'TLS_RSA_WITH_AES_128_GCM_SHA256'; Tls13 = $false; Weak = $false; MinOs = 1 }
            [pscustomobject]@{ Id = 0xC028; Name = 'TLS_ECDHE_RSA_WITH_AES_256_CBC_SHA384'; Tls13 = $false; Weak = $false; MinOs = 1 }
            [pscustomobject]@{ Id = 0xC027; Name = 'TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA256'; Tls13 = $false; Weak = $false; MinOs = 1 }
            [pscustomobject]@{ Id = 0xC024; Name = 'TLS_ECDHE_ECDSA_WITH_AES_256_CBC_SHA384'; Tls13 = $false; Weak = $false; MinOs = 1 }
            [pscustomobject]@{ Id = 0xC023; Name = 'TLS_ECDHE_ECDSA_WITH_AES_128_CBC_SHA256'; Tls13 = $false; Weak = $false; MinOs = 1 }
            [pscustomobject]@{ Id = 0x003D; Name = 'TLS_RSA_WITH_AES_256_CBC_SHA256'; Tls13 = $false; Weak = $false; MinOs = 1 }
            [pscustomobject]@{ Id = 0x003C; Name = 'TLS_RSA_WITH_AES_128_CBC_SHA256'; Tls13 = $false; Weak = $false; MinOs = 1 }
            [pscustomobject]@{ Id = 0xC014; Name = 'TLS_ECDHE_RSA_WITH_AES_256_CBC_SHA'; Tls13 = $false; Weak = $true; MinOs = 1 }
            [pscustomobject]@{ Id = 0xC013; Name = 'TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA'; Tls13 = $false; Weak = $true; MinOs = 1 }
            [pscustomobject]@{ Id = 0xC00A; Name = 'TLS_ECDHE_ECDSA_WITH_AES_256_CBC_SHA'; Tls13 = $false; Weak = $true; MinOs = 1 }
            [pscustomobject]@{ Id = 0xC009; Name = 'TLS_ECDHE_ECDSA_WITH_AES_128_CBC_SHA'; Tls13 = $false; Weak = $true; MinOs = 1 }
            [pscustomobject]@{ Id = 0x0039; Name = 'TLS_DHE_RSA_WITH_AES_256_CBC_SHA'; Tls13 = $false; Weak = $true; MinOs = 1 }
            [pscustomobject]@{ Id = 0x0033; Name = 'TLS_DHE_RSA_WITH_AES_128_CBC_SHA'; Tls13 = $false; Weak = $true; MinOs = 1 }
            [pscustomobject]@{ Id = 0x0035; Name = 'TLS_RSA_WITH_AES_256_CBC_SHA'; Tls13 = $false; Weak = $true; MinOs = 1 }
            [pscustomobject]@{ Id = 0x002F; Name = 'TLS_RSA_WITH_AES_128_CBC_SHA'; Tls13 = $false; Weak = $true; MinOs = 1 }
            [pscustomobject]@{ Id = 0x000A; Name = 'TLS_RSA_WITH_3DES_EDE_CBC_SHA'; Tls13 = $false; Weak = $true; MinOs = 1 }
            [pscustomobject]@{ Id = 0x0005; Name = 'TLS_RSA_WITH_RC4_128_SHA'; Tls13 = $false; Weak = $true; MinOs = 1 }
            [pscustomobject]@{ Id = 0x0004; Name = 'TLS_RSA_WITH_RC4_128_MD5'; Tls13 = $false; Weak = $true; MinOs = 1 }
        )
    }

    # Builds a minimal TLS ClientHello that offers exactly one cipher suite.
    function New-TlsClientHello {
        param([string]$ServerName, [int]$Suite, [switch]$WithTls13)
        function _u16 { param([int]$v) return , ([byte[]]@(([byte](($v -shr 8) -band 0xFF)), ([byte]($v -band 0xFF)))) }

        $rand = New-Object byte[] 32
        (New-Object System.Random).NextBytes($rand)

        $ext = New-Object System.Collections.Generic.List[byte]

        $hostBytes = [Text.Encoding]::ASCII.GetBytes($ServerName)
        $sni = New-Object System.Collections.Generic.List[byte]
        $sni.AddRange((_u16 ($hostBytes.Length + 3)))
        $sni.Add(0)
        $sni.AddRange((_u16 $hostBytes.Length))
        $sni.AddRange($hostBytes)
        $ext.AddRange((_u16 0x0000)); $ext.AddRange((_u16 $sni.Count)); $ext.AddRange($sni)

        $grp = New-Object System.Collections.Generic.List[byte]
        $groups = @(0x001D, 0x0017, 0x0018, 0x0019)
        $grp.AddRange((_u16 ($groups.Count * 2)))
        foreach ($g in $groups) { $grp.AddRange((_u16 $g)) }
        $ext.AddRange((_u16 0x000A)); $ext.AddRange((_u16 $grp.Count)); $ext.AddRange($grp)

        $ext.AddRange((_u16 0x000B)); $ext.AddRange((_u16 2)); $ext.Add(1); $ext.Add(0)

        $sig = New-Object System.Collections.Generic.List[byte]
        $sigs = @(0x0403, 0x0503, 0x0603, 0x0804, 0x0805, 0x0806, 0x0401, 0x0501, 0x0601, 0x0201)
        $sig.AddRange((_u16 ($sigs.Count * 2)))
        foreach ($s in $sigs) { $sig.AddRange((_u16 $s)) }
        $ext.AddRange((_u16 0x000D)); $ext.AddRange((_u16 $sig.Count)); $ext.AddRange($sig)

        if ($WithTls13) {
            $ext.AddRange((_u16 0x002B)); $ext.AddRange((_u16 5))
            $ext.Add(4); $ext.AddRange((_u16 0x0304)); $ext.AddRange((_u16 0x0303))
            # empty key_share - the server answers HelloRetryRequest, which still names the suite
            $ext.AddRange((_u16 0x0033)); $ext.AddRange((_u16 2)); $ext.AddRange((_u16 0))
        }

        # renegotiation_info (empty) - some servers reject hellos without it
        $ext.AddRange((_u16 0xFF01)); $ext.AddRange((_u16 1)); $ext.Add(0)

        $body = New-Object System.Collections.Generic.List[byte]
        $body.AddRange((_u16 0x0303))
        $body.AddRange($rand)
        $body.Add(0)
        $body.AddRange((_u16 2))
        $body.AddRange((_u16 $Suite))
        $body.Add(1); $body.Add(0)
        $body.AddRange((_u16 $ext.Count))
        $body.AddRange($ext)

        $hs = New-Object System.Collections.Generic.List[byte]
        $hs.Add(1)
        $hs.Add([byte](($body.Count -shr 16) -band 0xFF))
        $hs.Add([byte](($body.Count -shr 8) -band 0xFF))
        $hs.Add([byte]($body.Count -band 0xFF))
        $hs.AddRange($body)

        $rec = New-Object System.Collections.Generic.List[byte]
        $rec.Add(0x16); $rec.Add(3); $rec.Add(1)
        $rec.AddRange((_u16 $hs.Count))
        $rec.AddRange($hs)
        return $rec.ToArray()
    }

    # Offers ONE suite and reports whether the server picked it.
    function Test-RemoteCipherSuite {
        param([string]$TargetHost, [int]$TargetPort, $ResolvedProxy, [int]$Suite, [switch]$WithTls13, [int]$TimeoutMs = 6000)
        $conn = $null
        try {
            $conn = Open-TargetStream -TargetHost $TargetHost -TargetPort $TargetPort -ResolvedProxy $ResolvedProxy -TimeoutMs $TimeoutMs
            $s = $conn.Stream
            try { $s.ReadTimeout = $TimeoutMs; $s.WriteTimeout = $TimeoutMs } catch {}
            $hello = New-TlsClientHello -ServerName $TargetHost -Suite $Suite -WithTls13:$WithTls13
            $s.Write($hello, 0, $hello.Length); $s.Flush()

            $hdr = New-Object byte[] 5
            $got = 0
            while ($got -lt 5) { $n = $s.Read($hdr, $got, 5 - $got); if ($n -le 0) { break }; $got += $n }
            if ($got -lt 5) { return [pscustomobject]@{ Accepted = $false; Selected = 0; Detail = 'no response' } }

            $len = (([int]$hdr[3]) -shl 8) -bor ([int]$hdr[4])
            if ($len -le 0 -or $len -gt 65535) { return [pscustomobject]@{ Accepted = $false; Selected = 0; Detail = 'bad record' } }
            $payload = New-Object byte[] $len
            $got = 0
            while ($got -lt $len) { $n = $s.Read($payload, $got, $len - $got); if ($n -le 0) { break }; $got += $n }

            if ($hdr[0] -eq 0x15) {
                $desc = if ($got -ge 2) { [int]$payload[1] } else { -1 }
                $txt = switch ($desc) { 40 { 'handshake_failure' } 47 { 'illegal_parameter' } 70 { 'protocol_version' } 71 { 'insufficient_security' } 80 { 'internal_error' } default { "alert $desc" } }
                return [pscustomobject]@{ Accepted = $false; Selected = 0; Detail = $txt }
            }
            if ($hdr[0] -ne 0x16 -or $got -lt 44 -or $payload[0] -ne 0x02) {
                return [pscustomobject]@{ Accepted = $false; Selected = 0; Detail = 'no ServerHello' }
            }
            # ServerHello: type(1) len(3) version(2) random(32) sid_len(1) sid(n) cipher(2)
            $i = 4 + 2 + 32
            $sidLen = [int]$payload[$i]; $i += 1 + $sidLen
            if (($i + 1) -ge $got) { return [pscustomobject]@{ Accepted = $false; Selected = 0; Detail = 'truncated ServerHello' } }
            $sel = ((([int]$payload[$i]) -shl 8) -bor ([int]$payload[$i + 1]))
            return [pscustomobject]@{ Accepted = $true; Selected = $sel; Detail = '' }
        }
        catch { return [pscustomobject]@{ Accepted = $false; Selected = 0; Detail = $_.Exception.Message } }
        finally { if ($conn) { try { $conn.Tcp.Close() } catch {} } }
    }

    function Get-OsCipherPlatform {
        $caption = ''; $build = 0; $ver = ''
        try {
            $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
            $caption = [string]$os.Caption; $ver = [string]$os.Version
            $build = [int]($os.BuildNumber -as [int])
        }
        catch {
            try { $build = [System.Environment]::OSVersion.Version.Build; $ver = [string][System.Environment]::OSVersion.Version } catch {}
        }
        $rank = 0; $label = 'Windows 7 / Server 2008 R2 or older'
        if ($build -ge 20348) { $rank = 5; $label = 'Windows 11 / Server 2022 or newer' }
        elseif ($build -ge 19042) { $rank = 4; $label = 'Windows 10 20H2 or newer' }
        elseif ($build -ge 16299) { $rank = 3; $label = 'Windows 10 1709 / Server 2019' }
        elseif ($build -ge 10240) { $rank = 2; $label = 'Windows 10 / Server 2016' }
        elseif ($build -ge 9600) { $rank = 1; $label = 'Windows 8.1 / Server 2012 R2' }
        [pscustomobject]@{ Caption = $caption; Version = $ver; Build = $build; Rank = $rank; Label = $label }
    }

    function Get-OsSuiteGap {
        param([int]$MinOs)
        switch ($MinOs) {
            5 { 'needs Win11/2022+' }
            4 { 'needs Win10 20H2+' }
            3 { 'needs Win10 1709+' }
            2 { 'needs Win10/2016+' }
            default { 'not in this OS' }
        }
    }

    # The cipher suites SCHANNEL will offer from this machine, newest API first.
    function Get-LocalCipherSuiteNames {
        $names = New-Object System.Collections.Generic.List[string]
        $src = 'none'
        try {
            $cs = Get-TlsCipherSuite -ErrorAction Stop
            if ($cs) { foreach ($c in $cs) { $names.Add([string]$c.Name) }; $src = 'Get-TlsCipherSuite' }
        }
        catch {
            try {
                $fn = (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Cryptography\Configuration\SSL\00010002' -Name Functions -ErrorAction Stop).Functions
                foreach ($n in ($fn -split ',')) { if ($n.Trim()) { $names.Add($n.Trim()) } }
                if ($names.Count) { $src = 'SCHANNEL policy (00010002\Functions)' }
            }
            catch { }
        }
        [pscustomobject]@{ Names = $names; Source = $src }
    }

    # "OS cannot" and "box has it disabled" are kept apart - one needs a newer OS, the other a config change.
    function Get-CipherMatrix {
        param([string]$Url, $ProxyObj)

        function _cell {
            param([string]$s, [int]$w, [string]$Align = 'l')
            $pad = $w - $s.Length
            if ($pad -lt 0) { $pad = 0 }
            switch ($Align) {
                'c' { $l = [math]::Floor($pad / 2); return (' ' * $l) + $s + (' ' * ($pad - $l)) }
                'r' { return (' ' * $pad) + $s }
                default { return $s + (' ' * $pad) }
            }
        }

        # Both marks are one cell wide in Consolas, Cascadia Mono and Courier New, so columns stay aligned.
        $YES = [string][char]0x221A
        $NO = [string][char]0x00D7

        $out = New-Object System.Collections.Generic.List[string]
        $u = [uri]$Url
        $h = $u.Host
        $port = if ($u.Port -gt 0) { $u.Port } else { 443 }
        if ($u.Scheme -ne 'https') { $port = 443 }

        $resolved = Resolve-ProxyForUri -ProxyObj $ProxyObj.Proxy -Uri ("https://{0}" -f $h)
        $me = [System.Security.Principal.WindowsIdentity]::GetCurrent()

        $out.Add(("=== CIPHER SUITE COMPARISON : {0}:{1} ===" -f $h, $port))
        $out.Add(("Read by   : {0}" -f $me.Name))
        if ($resolved) { $out.Add(("Via proxy : {0}:{1} (CONNECT)" -f $resolved.Host, $resolved.Port)) }
        else { $out.Add("Via proxy : (direct)") }

        $loc = Get-LocalCipherSuiteNames
        $osp = Get-OsCipherPlatform
        $localSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($n in $loc.Names) { [void]$localSet.Add($n) }
        $out.Add(("OS        : {0}  (build {1} - {2})" -f $osp.Caption, $osp.Build, $osp.Label))
        if ($loc.Names.Count) {
            $out.Add(("Box list  : {0} suite(s) from {1}" -f $loc.Names.Count, $loc.Source))
        }
        else {
            $out.Add("Box list  : could not be enumerated (Get-TlsCipherSuite needs Windows 10 / Server 2016 or newer,")
            $out.Add("            and no SSL cipher policy is configured) - the 'Enabled' column falls back to the")
            $out.Add("            documented default list for this OS.")
        }
        $out.Add("Method    : one raw TLS ClientHello per suite - SCHANNEL cannot probe this from .NET.")
        $out.Add("")

        # Prove the transport once: otherwise all 30 probes fail alike and read as "supports nothing".
        try {
            $pre = Open-TargetStream -TargetHost $h -TargetPort $port -ResolvedProxy $resolved -TimeoutMs 8000
            try { $pre.Tcp.Close() } catch {}
        }
        catch {
            $msg = $_.Exception.Message
            $out.Add("ABORTED - no usable connection to the target, so no conclusion can be drawn about ciphers.")
            $out.Add("")
            if ($msg -like 'PROXYAUTH407:*') {
                $out.Add(("  {0}" -f ($msg -replace '^PROXYAUTH407:\s*', '')))
                $out.Add(("  Proxy          : {0}:{1}" -f $resolved.Host, $resolved.Port))
                $out.Add(("  Running as     : {0}" -f $me.Name))
                $out.Add("")
                $out.Add("  THIS IS NOT A CIPHER PROBLEM. The proxy closed the tunnel before any TLS")
                $out.Add("  handshake happened, so this machine and the server never exchanged a")
                $out.Add("  ClientHello at all. Do NOT change the SSL Cipher Suite Order policy on the")
                $out.Add("  strength of this result.")
                $out.Add("")
                $out.Add("  Fix the proxy authentication first, then run this test again:")
                $out.Add("    - tick 'Send Windows credentials to the proxy' under PROXY, or")
                $out.Add("    - use Override and supply a username and password, or")
                $out.Add("    - if running as SYSTEM, authorise the computer account on the proxy.")
            }
            else {
                $out.Add(("  {0}" -f $msg))
                $out.Add("")
                $out.Add("  The target could not be reached on this port, through this proxy, as this")
                $out.Add("  account. Run 'Ports 80/443' and 'HTTP(S) GET' first - a cipher comparison")
                $out.Add("  is only meaningful once a connection can actually be established.")
            }
            return $out
        }

        $table = Get-CipherSuiteTable
        $haveBox = ($loc.Names.Count -gt 0)
        $rows = New-Object System.Collections.Generic.List[object]
        $idx = 0
        foreach ($cs in $table) {
            $r = Test-RemoteCipherSuite -TargetHost $h -TargetPort $port -ResolvedProxy $resolved -Suite $cs.Id -WithTls13:$cs.Tls13
            $inOs = ($osp.Rank -ge [int]$cs.MinOs)
            $box = if ($haveBox) { $localSet.Contains($cs.Name) } else { $inOs }
            $srv = [bool]$r.Accepted
            $rows.Add([pscustomobject]@{
                    Name = $cs.Name; InOs = $inOs; Box = $box; Srv = $srv; Use = ($inOs -and $box -and $srv)
                    Weak = [bool]$cs.Weak; MinOs = [int]$cs.MinOs; Order = $idx
                })
            $idx++
        }

        foreach ($r in $rows) {
            $note = ''
            if (-not $r.InOs -and $r.Srv) { $note = Get-OsSuiteGap $r.MinOs }
            elseif (-not $r.Box -and $r.InOs -and $r.Srv) { $note = 'disabled here' }
            elseif ($r.Use -and $r.Weak) { $note = 'weak legacy' }
            $r | Add-Member -NotePropertyName Note -NotePropertyValue $note -Force
        }

        $rows = @($rows | Sort-Object -Property @{ Expression = { if ($_.Use) { 0 } elseif ($_.Srv) { 1 } elseif ($_.Box) { 2 } else { 3 } } }, 'Order')

        $wN = 46; $wM = 8; $wT = 18
        $out.Add(("| {0} | {1} | {2} | {3} | {4} | {5} |" -f (_cell 'Cipher suite' $wN), (_cell 'In OS' $wM 'c'), (_cell 'Enabled' $wM 'c'), (_cell 'Server' $wM 'c'), (_cell 'Usable' $wM 'c'), (_cell 'Notes' $wT)))
        $out.Add(("|{0}|{1}|{2}|{3}|{4}|{5}|" -f ('-' * ($wN + 2)), (':' + ('-' * $wM) + ':'), (':' + ('-' * $wM) + ':'), (':' + ('-' * $wM) + ':'), (':' + ('-' * $wM) + ':'), ('-' * ($wT + 2))))
        foreach ($r in $rows) {
            $out.Add(("| {0} | {1} | {2} | {3} | {4} | {5} |" -f `
                    (_cell $r.Name $wN), `
                    (_cell $(if ($r.InOs) { $YES } else { $NO }) $wM 'c'), `
                    (_cell $(if ($r.Box) { $YES } else { $NO }) $wM 'c'), `
                    (_cell $(if ($r.Srv) { $YES } else { $NO }) $wM 'c'), `
                    (_cell $(if ($r.Use) { $YES } else { $NO }) $wM 'c'), `
                    (_cell $r.Note $wT)))
        }
        $out.Add("")
        $out.Add(("Legend: {0} = yes    {1} = no" -f $YES, $NO))
        $out.Add("        In OS   - this Windows version implements the suite at all.")
        $out.Add("        Enabled - SCHANNEL will currently offer it (policy and cipher order applied).")
        $out.Add("        Server  - the target accepted it in a real ClientHello.")
        $out.Add("        Usable  - all three, so a live handshake can select it.")
        $out.Add("")

        $nUse = @($rows | Where-Object { $_.Use }).Count
        $nSrv = @($rows | Where-Object { $_.Srv }).Count
        $nBox = @($rows | Where-Object { $_.Box }).Count
        $strong = @($rows | Where-Object { $_.Use -and -not $_.Weak }).Count
        $osGap = @($rows | Where-Object { $_.Srv -and -not $_.InOs })
        $cfgGap = @($rows | Where-Object { $_.Srv -and $_.InOs -and -not $_.Box })
        $out.Add(("Summary : {0} usable, {1} accepted by the server, {2} enabled here, out of {3} probed." -f $nUse, $nSrv, $nBox, $rows.Count))

        if ($nUse -gt 0) {
            if ($strong -gt 0) { $out.Add(("RESULT  : OK - a TLS handshake can succeed ({0} strong suite(s) in common)." -f $strong)) }
            else { $out.Add("RESULT  : WEAK - the only suites in common are deprecated legacy suites.") }
        }
        else {
            $out.Add("RESULT  : FAIL - no suite is supported by both sides, so every TLS handshake to")
            $out.Add("          this host will fail. This is the 'Could not create SSL/TLS secure channel' error.")
        }

        $healthy = ($nUse -gt 0 -and $strong -gt 0)
        if (-not $healthy) {
            if ($cfgGap.Count) {
                $out.Add("")
                $out.Add(("FIXABLE HERE : {0} suite(s) the server accepts are supported by this OS but are NOT enabled." -f $cfgGap.Count))
                $out.Add("               Add them to the SSL Cipher Suite Order policy (or clear the restriction), then REBOOT:")
                foreach ($c in $cfgGap) { $out.Add("     $($c.Name)") }
            }
            if ($osGap.Count) {
                $out.Add("")
                $out.Add(("OS LIMITATION: {0} suite(s) the server accepts do not exist in {1}." -f $osGap.Count, $osp.Label))
                $out.Add("               No configuration change can enable these - the OS has to be newer:")
                foreach ($c in $osGap) { $out.Add(("     {0}   ({1})" -f $c.Name, (Get-OsSuiteGap $c.MinOs))) }
                if ($nUse -eq 0) {
                    $out.Add("               This is the Windows Server 2012 / 2012 R2 download failure described in")
                    $out.Add("               patchmypc.com/kb/request-was-aborted-could-not. Options: upgrade the OS, or")
                    $out.Add("               stage the installer manually via the local content repository.")
                }
            }
        }

        # NULL, PSK and anonymous suites are filtered out - none work against a certificate-based server.
        $probed = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($cs in $table) { [void]$probed.Add($cs.Name) }
        $extra = @($loc.Names | Where-Object {
                -not $probed.Contains($_) -and $_ -notmatch '_NULL_|_PSK_|_anon_|_EXPORT'
            })
        if ($extra.Count) {
            $out.Add("")
            $out.Add(("Also enabled here but not probed ({0}) - this tool does not test these, so whether" -f $extra.Count))
            $out.Add("the server accepts them is unknown:")
            foreach ($e in $extra) { $out.Add("  $e") }
        }
        return $out
    }

    function Get-BoxTlsConfig {
        $out = New-Object System.Collections.Generic.List[string]
        $out.Add("=== TLS CONFIGURATION ON THIS BOX ===")
        $osp = Get-OsCipherPlatform
        $out.Add(("OS: {0}   version {1}   build {2}" -f $osp.Caption, $osp.Version, $osp.Build))
        $out.Add(("    Cipher generation: {0}" -f $osp.Label))
        if ($osp.Rank -le 1) {
            $out.Add("    WARNING: this OS predates ECDHE_RSA GCM, CHACHA20 and TLS 1.3. Vendors that")
            $out.Add("             require those suites cannot be reached from here at all - see 'Cipher suites'.")
        }
        $out.Add("Protocols (SCHANNEL, Client):")
        $base = 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols'
        foreach ($proto in 'TLS 1.0', 'TLS 1.1', 'TLS 1.2', 'TLS 1.3') {
            $k = Join-Path $base ("{0}\Client" -f $proto)
            $state = 'OS default'
            try {
                if (Test-Path $k) {
                    $en = (Get-ItemProperty $k -Name Enabled -ErrorAction SilentlyContinue).Enabled
                    $dis = (Get-ItemProperty $k -Name DisabledByDefault -ErrorAction SilentlyContinue).DisabledByDefault
                    if ($en -eq 0) { $state = 'DISABLED' }
                    elseif ($en -eq 1 -and $dis -eq 0) { $state = 'Enabled' }
                    elseif ($en -eq 1 -and $dis -eq 1) { $state = 'Enabled but off-by-default' }
                    elseif ($dis -eq 1) { $state = 'Off by default' }
                    else { $state = 'Enabled (explicit)' }
                }
            }
            catch { }
            $out.Add(("  {0,-8}: {1}" -f $proto, $state))
        }
        $out.Add(".NET strong-crypto (affects .NET Framework 4.x applications):")
        foreach ($p in 'HKLM:\SOFTWARE\Microsoft\.NETFramework\v4.0.30319', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\.NETFramework\v4.0.30319') {
            try {
                $ssc = (Get-ItemProperty $p -Name SchUseStrongCrypto -ErrorAction SilentlyContinue).SchUseStrongCrypto
                $sd = (Get-ItemProperty $p -Name SystemDefaultTlsVersions -ErrorAction SilentlyContinue).SystemDefaultTlsVersions
                $out.Add(("  {0}" -f $p))
                $out.Add(("     SchUseStrongCrypto={0}  SystemDefaultTlsVersions={1}" -f $(if ($null -ne $ssc) { $ssc }else { '<unset>' }), $(if ($null -ne $sd) { $sd }else { '<unset>' })))
            }
            catch { }
        }
        $out.Add("Cipher-suite restriction policy:")
        $anyPol = $false
        foreach ($pk in @(
                'HKLM:\SOFTWARE\Policies\Microsoft\Cryptography\Configuration\SSL\00010002',
                'HKLM:\SYSTEM\CurrentControlSet\Control\Cryptography\Configuration\Local\SSL\00010002'
            )) {
            try {
                if (-not (Test-Path $pk)) { $out.Add(("  {0}`n     (not present)" -f $pk)); continue }
                $fn = (Get-ItemProperty $pk -Name Functions -ErrorAction Stop).Functions
                $names = @()
                if ($fn -is [array]) { $names = @($fn) } else { $names = @(([string]$fn) -split ',') }
                $names = @($names | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                $out.Add(("  {0}" -f $pk))
                $out.Add(("     Functions is SET - ONLY these {0} suite(s) can ever be used:" -f $names.Count))
                foreach ($n in $names) { $out.Add("       $n") }
                $anyPol = $true
            }
            catch {
                $out.Add(("  {0}" -f $pk))
                $out.Add("     (key exists but no Functions value)")
            }
        }
        if ($anyPol) {
            $out.Add("  A restriction is in force. If a download URL needs a suite that is not listed above,")
            $out.Add("  it fails with 'The request was aborted: Could not create SSL/TLS secure channel'.")
            $out.Add("  Add the missing suites or remove the Functions value, then REBOOT for it to take effect.")
        }
        else {
            $out.Add("  No cipher-suite restriction configured - the OS defaults apply (this is normal).")
        }
        $out.Add("Enabled cipher suites (Get-TlsCipherSuite, in order):")
        try {
            $cs = Get-TlsCipherSuite -ErrorAction Stop
            if ($cs) { $i = 1; foreach ($c in $cs) { $out.Add(("  {0,2}. {1}" -f $i, $c.Name)); $i++ } }
            else { $out.Add("  (none returned)") }
        }
        catch { $out.Add("  Get-TlsCipherSuite not available on this OS: $($_.Exception.Message)") }
        return $out
    }

    function Read-WinInetHive {
        param([string]$Path, [string]$Label)
        $out = New-Object System.Collections.Generic.List[string]
        try {
            if (Test-Path $Path -ErrorAction Stop) {
                $ip = Get-ItemProperty $Path -ErrorAction Stop
                $en = if ($null -ne $ip.ProxyEnable) { [int]$ip.ProxyEnable } else { 0 }
                $out.Add("${Label}:")
                $out.Add(("  ProxyEnable  : {0} ({1})" -f $en, $(if ($en) { 'ON' } else { 'off (direct unless AutoConfigURL set)' })))
                $out.Add(("  ProxyServer  : {0}" -f $(if ($ip.ProxyServer) { $ip.ProxyServer }   else { '(none)' })))
                $out.Add(("  ProxyOverride: {0}" -f $(if ($ip.ProxyOverride) { $ip.ProxyOverride } else { '(none)' })))
                $out.Add(("  AutoConfigURL: {0}" -f $(if ($ip.AutoConfigURL) { $ip.AutoConfigURL } else { '(none)' })))
            }
            else { $out.Add("${Label}: (no Internet Settings key -> direct)") }
        }
        catch { $out.Add("${Label}: unable to read ($($_.Exception.Message))") }
        return $out
    }

    # Resolves the interactive/console user (name + SID) so we can read their hive even from a SYSTEM process.
    function Resolve-InteractiveUser {
        $me = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $userName = $null; $userSid = $null
        try { $userName = (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).UserName } catch {}
        if ($userName) {
            try { $userSid = ([System.Security.Principal.NTAccount]$userName).Translate([System.Security.Principal.SecurityIdentifier]).Value } catch {}
        }
        if (-not $userSid -and $me.User.Value -ne 'S-1-5-18') { $userSid = $me.User.Value; if (-not $userName) { $userName = $me.Name } }
        [pscustomobject]@{ Name = $userName; Sid = $userSid }
    }

    # Detects proxy settings pushed by Group Policy - those win over anything written here.
    function Get-ProxyPolicyInfo {
        $out = [pscustomobject]@{ Policies = @(); PerUser = $null }
        $list = New-Object System.Collections.Generic.List[string]
        $polPaths = @(
            @{ P = 'HKLM:\Software\Policies\Microsoft\Windows\CurrentVersion\Internet Settings'; N = 'Machine policy (Internet Settings)' }
            @{ P = 'HKCU:\Software\Policies\Microsoft\Windows\CurrentVersion\Internet Settings'; N = 'User policy (Internet Settings)' }
            @{ P = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings\Policies'; N = 'User Internet Settings policies' }
        )
        foreach ($pp in $polPaths) {
            try {
                if (Test-Path $pp.P) {
                    $k = Get-ItemProperty -Path $pp.P -ErrorAction Stop
                    # Only report proxy-related values - these keys hold plenty of unrelated defaults.
                    $vals = @($k.PSObject.Properties |
                        Where-Object { $_.Name -notlike 'PS*' -and $_.Name -match 'Proxy|AutoConfig|AutoDetect|Wpad' } |
                        ForEach-Object { '{0}={1}' -f $_.Name, $_.Value })
                    if ($vals.Count) { $list.Add(('{0}: {1}' -f $pp.N, ($vals -join '; '))) }
                }
            }
            catch {}
        }
        try {
            $pu = (Get-ItemProperty -Path 'HKLM:\Software\Policies\Microsoft\Windows\CurrentVersion\Internet Settings' -Name 'ProxySettingsPerUser' -ErrorAction Stop).ProxySettingsPerUser
            $out.PerUser = $pu
            if ($pu -eq 0) { $list.Add('ProxySettingsPerUser=0 - proxy settings are machine-wide, per-user values are ignored.') }
        }
        catch {}
        $out.Policies = $list.ToArray()
        $out
    }

    # WinINET treats this blob as authoritative - ProxyEnable/ProxyServer alone will not stick.
    function New-DefaultConnectionSettings {
        param([int]$Counter, [bool]$UseProxy, [string]$ProxyServer, [string]$Bypass, [string]$PacUrl, [bool]$AutoDetect)
        $flags = 1
        if ($UseProxy -and $ProxyServer) { $flags = $flags -bor 2 }
        if ($PacUrl) { $flags = $flags -bor 4 }
        if ($AutoDetect) { $flags = $flags -bor 8 }
        $ms = New-Object System.IO.MemoryStream
        $bw = New-Object System.IO.BinaryWriter($ms)
        try {
            $bw.Write([int]0x46)
            $bw.Write([int]$Counter)
            $bw.Write([int]$flags)
            foreach ($s in @($ProxyServer, $Bypass, $PacUrl)) {
                $t = [string]$s
                $b = [System.Text.Encoding]::ASCII.GetBytes($t)
                $bw.Write([int]$b.Length)
                if ($b.Length) { $bw.Write($b) }
            }
            $bw.Write([int]0)
            $bw.Write((New-Object byte[] 32))
            $bw.Flush()
            return $ms.ToArray()
        }
        finally { $bw.Dispose(); $ms.Dispose() }
    }

    # HivePath is the account's Internet Settings key - HKCU, or HKEY_USERS\S-1-5-18 for SYSTEM.
    function Set-WinInetProxy {
        param(
            [string]$HivePath,
            [bool]$UseProxy,
            [string]$ProxyServer = '',
            [string]$Bypass = '',
            [string]$PacUrl = '',
            [bool]$AutoDetect = $false
        )
        $out = New-Object System.Collections.Generic.List[string]
        $ok = $true
        try {
            if (-not (Test-Path $HivePath)) { New-Item -Path $HivePath -Force -ErrorAction Stop | Out-Null }

            Set-ItemProperty -Path $HivePath -Name 'ProxyEnable' -Value ([int][bool]$UseProxy) -Type DWord -ErrorAction Stop
            $out.Add(('  ProxyEnable   = {0}' -f [int][bool]$UseProxy))

            if ($UseProxy -and $ProxyServer) {
                Set-ItemProperty -Path $HivePath -Name 'ProxyServer' -Value $ProxyServer -Type String -ErrorAction Stop
                $out.Add(('  ProxyServer   = {0}' -f $ProxyServer))
            }
            else {
                Remove-ItemProperty -Path $HivePath -Name 'ProxyServer' -ErrorAction SilentlyContinue
                $out.Add('  ProxyServer   = (removed)')
            }

            if ($Bypass) {
                Set-ItemProperty -Path $HivePath -Name 'ProxyOverride' -Value $Bypass -Type String -ErrorAction Stop
                $out.Add(('  ProxyOverride = {0}' -f $Bypass))
            }
            else {
                Remove-ItemProperty -Path $HivePath -Name 'ProxyOverride' -ErrorAction SilentlyContinue
                $out.Add('  ProxyOverride = (removed)')
            }

            if ($PacUrl) {
                Set-ItemProperty -Path $HivePath -Name 'AutoConfigURL' -Value $PacUrl -Type String -ErrorAction Stop
                $out.Add(('  AutoConfigURL = {0}' -f $PacUrl))
            }
            else {
                Remove-ItemProperty -Path $HivePath -Name 'AutoConfigURL' -ErrorAction SilentlyContinue
                $out.Add('  AutoConfigURL = (removed)')
            }

            # Keep the binary connection settings in step with the values above.
            $connPath = Join-Path $HivePath 'Connections'
            if (-not (Test-Path $connPath)) { New-Item -Path $connPath -Force -ErrorAction Stop | Out-Null }
            $counter = 1
            try {
                $old = (Get-ItemProperty -Path $connPath -Name 'DefaultConnectionSettings' -ErrorAction Stop).DefaultConnectionSettings
                if ($old -and $old.Length -ge 8) { $counter = [BitConverter]::ToInt32($old, 4) + 1 }
            }
            catch {}
            $blob = New-DefaultConnectionSettings -Counter $counter -UseProxy $UseProxy -ProxyServer $ProxyServer -Bypass $Bypass -PacUrl $PacUrl -AutoDetect $AutoDetect
            Set-ItemProperty -Path $connPath -Name 'DefaultConnectionSettings' -Value $blob -Type Binary -ErrorAction Stop
            # Windows keeps the legacy copy in step with the default one - do the same, do not orphan it.
            if (Get-ItemProperty -Path $connPath -Name 'SavedLegacySettings' -ErrorAction SilentlyContinue) {
                Set-ItemProperty -Path $connPath -Name 'SavedLegacySettings' -Value $blob -Type Binary -ErrorAction SilentlyContinue
            }
            $out.Add(('  DefaultConnectionSettings updated ({0} bytes, counter {1}, autodetect {2})' -f $blob.Length, $counter, $(if ($AutoDetect) { 'on' } else { 'off' })))
        }
        catch {
            $ok = $false
            $out.Add(('  ERROR: {0}' -f $_.Exception.Message))
        }
        [pscustomobject]@{ Ok = $ok; Lines = $out.ToArray() }
    }

    # Machine-wide WinHTTP proxy - BITS, Windows Update scanning and the ConfigMgr client.
    function Set-WinHttpProxy {
        param([bool]$UseProxy, [string]$ProxyServer = '', [string]$Bypass = '')
        $out = New-Object System.Collections.Generic.List[string]
        try {
            if ($UseProxy -and $ProxyServer) {
                $na = @('winhttp', 'set', 'proxy', ('proxy-server={0}' -f $ProxyServer))
                if ($Bypass) { $na += ('bypass-list={0}' -f $Bypass) }
                $r = & netsh @na 2>&1
            }
            else {
                $r = & netsh winhttp reset proxy 2>&1
            }
            foreach ($l in $r) { if ("$l".Trim()) { $out.Add(('  {0}' -f $l)) } }
        }
        catch { $out.Add(('  ERROR: {0}' -f $_.Exception.Message)) }
        $out.ToArray()
    }

    # netsh output is localised, so decode the blob: [8..11] access type, then length-prefixed strings.
    function Get-WinHttpProxy {
        param([string]$RegPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings\Connections')
        # Same wording as the per-account summary - two phrasings read as two different findings.
        $res = [pscustomobject]@{ UseProxy = $false; Server = ''; Bypass = ''; Summary = 'none configured (direct)'; Readable = $true }
        try {
            $b = (Get-ItemProperty -Path $RegPath -Name 'WinHttpSettings' -ErrorAction Stop).WinHttpSettings
        }
        catch { return $res }
        if (-not $b -or $b.Length -lt 16) { return $res }
        try {
            $access = [System.BitConverter]::ToInt32($b, 8)
            $i = 12
            $decoded = $true
            $len = [System.BitConverter]::ToInt32($b, $i); $i += 4
            $srv = ''
            if ($len -gt 0) {
                if (($i + $len) -le $b.Length) { $srv = [System.Text.Encoding]::ASCII.GetString($b, $i, $len); $i += $len }
                else { $decoded = $false }
            }
            $byp = ''
            if ($decoded -and ($i + 4) -le $b.Length) {
                $len2 = [System.BitConverter]::ToInt32($b, $i); $i += 4
                if ($len2 -gt 0) {
                    if (($i + $len2) -le $b.Length) { $byp = [System.Text.Encoding]::ASCII.GetString($b, $i, $len2) }
                    else { $decoded = $false }
                }
            }
            # A blob claiming a proxy that cannot be read must not be reported as "direct".
            if (-not $decoded) {
                $res.Readable = $false
                $res.Summary = 'the WinHTTP settings are present but could not be decoded - check "netsh winhttp show proxy"'
            }
            elseif ($access -eq 3 -and $srv) {
                $res.UseProxy = $true; $res.Server = $srv; $res.Bypass = $byp
                $res.Summary = $srv + $(if ($byp) { " (bypass: $byp)" } else { '' })
            }
        }
        catch { $res.Readable = $false; $res.Summary = 'could not decode the WinHTTP settings' }
        return $res
    }

    # Tells WinINET its settings moved. Without this, already-running apps keep the old proxy.
    function Send-WinInetChange {
        if (-not ('CtWinInet' -as [type])) {
            Add-Type -Namespace '' -Name 'CtWinInet' -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("wininet.dll", SetLastError = true, CharSet = System.Runtime.InteropServices.CharSet.Auto)]
public static extern bool InternetSetOption(System.IntPtr hInternet, int dwOption, System.IntPtr lpBuffer, int dwBufferLength);
public static void Notify() {
    InternetSetOption(System.IntPtr.Zero, 39, System.IntPtr.Zero, 0);
    InternetSetOption(System.IntPtr.Zero, 37, System.IntPtr.Zero, 0);
}
'@ -ErrorAction Stop
        }
        [CtWinInet]::Notify()
    }

    function Get-MachineProxyView {
        $out = New-Object System.Collections.Generic.List[string]
        $out.Add("Machine WinHTTP (netsh winhttp show proxy) - machine-wide, applies to both accounts:")
        try { (& netsh winhttp show proxy 2>&1) | Where-Object { "$_".Trim() } | ForEach-Object { $out.Add("  $_") } }
        catch { $out.Add("  ERROR: $($_.Exception.Message)") }
        return $out
    }

    function Get-UserProxyView {
        param([string]$SampleUrl = 'https://patchmypc.com')
        $out = New-Object System.Collections.Generic.List[string]
        $me = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $out.Add("=== USER PROXY (WinINET, per-account) ===")
        $out.Add(("This view read by : {0}" -f $me.Name))
        $u = Resolve-InteractiveUser
        $out.Add(("Logged-on user    : {0}" -f $(if ($u.Name) { "$($u.Name) (SID $($u.Sid))" } else { '(none detected)' })))
        $out.Add("")
        if ($u.Sid) {
            (Read-WinInetHive ("Registry::HKEY_USERS\$($u.Sid)\Software\Microsoft\Windows\CurrentVersion\Internet Settings") "User WinINET") | ForEach-Object { $out.Add($_) }
        }
        else {
            $out.Add("(no interactive user hive loaded; showing this process's HKCU instead)")
            (Read-WinInetHive 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' "Current HKCU WinINET") | ForEach-Object { $out.Add($_) }
        }
        $out.Add("")
        (Get-MachineProxyView) | ForEach-Object { $out.Add($_) }
        $out.Add("")
        $out.Add((".NET effective proxy for {0} (resolved as {1}):" -f $SampleUrl, $me.Name))
        try {
            $sys = [System.Net.WebRequest]::GetSystemWebProxy(); $uri = [uri]$SampleUrl; $p = $sys.GetProxy($uri)
            if ($sys.IsBypassed($uri) -or -not $p -or $p.AbsoluteUri -eq $uri.AbsoluteUri) { $out.Add("  (direct - no proxy)") }
            else { $out.Add(("  {0}" -f $p.AbsoluteUri)) }
        }
        catch { $out.Add("  ERROR: $($_.Exception.Message)") }
        return $out
    }

    function Get-SystemProxyView {
        param([string]$SampleUrl = 'https://patchmypc.com')
        $out = New-Object System.Collections.Generic.List[string]
        $me = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $isAdmin = ([Security.Principal.WindowsPrincipal]$me).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        $isSystem = $me.User.Value -eq 'S-1-5-18'
        $out.Add("=== SYSTEM PROXY (WinINET) ===")
        $out.Add("Account           : NT AUTHORITY\SYSTEM (SID S-1-5-18) - the account most Windows services run as")
        $out.Add(("This view read by : {0} (elevated={1})" -f $me.Name, $isAdmin))
        $out.Add("")
        $sysPath = 'Registry::HKEY_USERS\S-1-5-18\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
        $canReadSys = $false
        try { $canReadSys = [bool](Test-Path $sysPath -ErrorAction Stop) } catch {}
        if ($canReadSys -or $isAdmin -or $isSystem) {
            (Read-WinInetHive $sysPath "SYSTEM WinINET") | ForEach-Object { $out.Add($_) }
        }
        else {
            $out.Add("SYSTEM WinINET: (cannot read SYSTEM hive from a non-elevated user session)")
            $out.Add("  -> re-launch the tool 'As administrator' to view SYSTEM's proxy config.")
        }
        if ($isSystem) {
            $out.Add("")
            (Get-MachineProxyView) | ForEach-Object { $out.Add($_) }
            $out.Add("")
            $out.Add((".NET effective proxy for {0} (resolved as SYSTEM):" -f $SampleUrl))
            try {
                $sys = [System.Net.WebRequest]::GetSystemWebProxy(); $uri = [uri]$SampleUrl; $p = $sys.GetProxy($uri)
                if ($sys.IsBypassed($uri) -or -not $p -or $p.AbsoluteUri -eq $uri.AbsoluteUri) { $out.Add("  (direct - no proxy)") }
                else { $out.Add(("  {0}" -f $p.AbsoluteUri)) }
            }
            catch { $out.Add("  ERROR: $($_.Exception.Message)") }
        }
        else {
            $out.Add("")
            (Get-MachineProxyView) | ForEach-Object { $out.Add($_) }
            $out.Add("")
            $out.Add("(Tip: set 'Run as' to SYSTEM to resolve SYSTEM's *effective* .NET proxy natively.)")
        }
        return $out
    }

    # The Publishing Service uses its own Advanced tab setting, not WinINET - so report both.
    function Get-PublisherProxyView {
        $out = New-Object System.Collections.Generic.List[string]
        $out.Add("--- Patch My PC Publishing Service (its own settings) ---")

        $svc = $null; $svcErr = ''
        try { $svc = Get-CimInstance Win32_Service -Filter "Name='PatchMyPCService'" -ErrorAction Stop }
        catch { $ex = $_.Exception; while ($ex.InnerException) { $ex = $ex.InnerException }; $svcErr = ([string]$ex.Message).Trim() }

        $pi = Get-PublisherInfo

        # Never having had the Publisher is a normal state, so report it calmly and say what still counts.

        if (-not $pi.Installed -and -not $svc) {
            $out.Add("  Not installed  : the Publishing Service is not on this machine (no service, no install")
            $out.Add("                   folder, no registry key). That is not a fault - it just means its own")
            $out.Add("                   settings cannot be read from here.")
            $out.Add("  Still valid    : every other check in this run measured THIS machine, and those results")
            $out.Add("                   hold for it - DNS, ports, TLS, the proxy and any share or RPC target.")
            $out.Add("  Not covered    : the Publisher's OWN proxy setting, which overrides Windows' and is the")
            $out.Add("                   single most common cause of 'the server can browse but the Publisher")
            $out.Add("                   cannot'. To see that, run this tool on the server the service runs on.")
            if ($svcErr) { $out.Add(("  (service query : {0})" -f $svcErr)) }
            return $out
        }

        if ($svc) {
            $out.Add(("  Service        : {0}  (StartName {1})" -f $svc.State, $svc.StartName))
            if ($svc.StartName -and $svc.StartName -notmatch '^(LocalSystem|NT AUTHORITY\\SYSTEM)$') {
                $out.Add(("  NOTE           : the service runs as {0}, NOT SYSTEM - test the SYSTEM context with care," -f $svc.StartName))
                $out.Add("                   as that account may have different proxy and access rights.")
            }
        }
        elseif ($svcErr) {
            $out.Add(("  Service        : could not be queried from this account - {0}" -f $svcErr))
        }
        else {
            # Files but no service is a broken install, not an absent one - nothing will download until it runs.
            $out.Add("  Service        : NOT REGISTERED - the Publisher is installed here but PatchMyPCService")
            $out.Add("                   does not exist. Nothing will be published or downloaded until it does.")
        }

        if (-not $pi.Installed) {
            $out.Add("  Settings.xml   : no install folder found, so the service's own proxy setting cannot be read.")
            $out.Add("                   The service above may be running from a path this account cannot see.")
            return $out
        }

        $sx = Join-Path $pi.Path 'Settings.xml'
        if (-not (Test-Path -LiteralPath $sx)) { $out.Add(("  Settings.xml   : not found at {0}" -f $sx)); return $out }
        $out.Add(("  Settings.xml   : {0}" -f $sx))
        try {
            [xml]$doc = Get-Content -LiteralPath $sx -Raw -ErrorAction Stop
            $node = $doc.SelectSingleNode('/PatchMyPC-Settings/Proxy')
            if (-not $node) {
                $out.Add("  Proxy          : no <Proxy> element - the service uses no proxy.")
            }
            else {
                $method = [string]$node.GetAttribute('method')
                if (-not $method) { $method = '(unset)' }
                $out.Add(("  Proxy method   : {0}" -f $method))
                foreach ($a in $node.Attributes) {
                    if ($a.Name -eq 'method') { continue }
                    $v = [string]$a.Value
                    if ($a.Name -match 'pass|pwd|secret') { $v = if ($v) { '(set, not shown)' } else { '(empty)' } }
                    $out.Add(("    {0,-12} : {1}" -f $a.Name, $v))
                }
                if ($method -eq 'NoProxy') {
                    $out.Add("  The service connects DIRECTLY. If this network needs a proxy, downloads will fail")
                    $out.Add("  even when the Windows proxy above is correct - set it on the Publisher's Advanced tab.")
                }
            }
            $ts = $doc.SelectSingleNode('/PatchMyPC-Settings/TimestampServerUrl')
            if ($ts) { $out.Add(("  Timestamp URL  : {0}" -f $ts.InnerText)) }
        }
        catch { $out.Add(("  Settings.xml   : could not be read ({0})" -f $_.Exception.Message)) }
        return $out
    }

    function Get-ProxyConfigView {
        param([string]$SampleUrl = 'https://patchmypc.com')
        $me = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $out = if ($me.User.Value -eq 'S-1-5-18') { Get-SystemProxyView -SampleUrl $SampleUrl } else { Get-UserProxyView -SampleUrl $SampleUrl }
        $lines = New-Object System.Collections.Generic.List[string]
        foreach ($l in $out) { $lines.Add($l) }
        $pol = Get-ProxyPolicyInfo
        $lines.Add("")
        $lines.Add("--- Proxy Group Policy ---")
        if ($pol.Policies.Count) {
            $lines.Add("  Policy is setting the proxy - it overrides anything configured locally:")
            foreach ($l in $pol.Policies) { $lines.Add("  $l") }
        }
        else {
            $lines.Add("  No proxy Group Policy found.")
        }
        $lines.Add("")
        foreach ($l in (Get-PublisherProxyView)) { $lines.Add($l) }
        return $lines
    }

    # TargetUrl filters HOSTS down to entries that can affect that host - the whole file is noise.
    function Get-DnsConfig {
        param([string]$TargetUrl)
        $out = New-Object System.Collections.Generic.List[string]
        $me = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $out.Add("=== DNS CONFIGURATION (this machine) ===")
        $out.Add(("Read by          : {0}" -f $me.Name))
        $out.Add(("Computer         : {0}" -f $env:COMPUTERNAME))
        try {
            $gp = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties()
            $out.Add(("Primary DNS suffix: {0}" -f $(if ($gp.DomainName) { $gp.DomainName } else { '(none)' })))
        }
        catch {}
        $out.Add("")

        $out.Add("--- DNS servers per adapter (only adapters that are UP) ---")
        $any = $false
        try {
            foreach ($nic in ([System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces())) {
                if ($nic.OperationalStatus -ne 'Up') { continue }
                if ($nic.NetworkInterfaceType -eq 'Loopback') { continue }
                $props = $nic.GetIPProperties()
                $srv = @($props.DnsAddresses | ForEach-Object { $_.IPAddressToString })
                if (-not $srv.Count) { continue }
                $any = $true
                $out.Add(("  {0}  [{1}]" -f $nic.Name, $nic.NetworkInterfaceType))
                $out.Add(("     description  : {0}" -f $nic.Description))
                $ips = @($props.UnicastAddresses | ForEach-Object { $_.Address.IPAddressToString })
                if ($ips.Count) { $out.Add(("     ip address   : {0}" -f ($ips -join ', '))) }
                $gws = @($props.GatewayAddresses | ForEach-Object { $_.Address.IPAddressToString } | Where-Object { $_ -and $_ -ne '0.0.0.0' })
                if ($gws.Count) { $out.Add(("     gateway      : {0}" -f ($gws -join ', '))) }
                $out.Add(("     dns servers  : {0}" -f ($srv -join ', ')))
                if ($props.DnsSuffix) { $out.Add(("     dns suffix   : {0}" -f $props.DnsSuffix)) }
                $out.Add(("     dhcp/dns dyn : DhcpEnabled={0} DynamicDnsEnabled={1}" -f $props.IsDhcpEnabled, $props.IsDynamicDnsEnabled))
            }
        }
        catch { $out.Add("  ERROR: $($_.Exception.Message)") }
        if (-not $any) { $out.Add("  (no DNS servers found on any adapter that is up)") }
        $out.Add("")

        $out.Add("--- Suffix search list ---")
        try {
            $gl = Get-DnsClientGlobalSetting -ErrorAction Stop
            $sl = @($gl.SuffixSearchList)
            $out.Add(("  SuffixSearchList : {0}" -f $(if ($sl.Count) { $sl -join ', ' } else { '(empty - uses the primary/connection suffix)' })))
            $out.Add(("  UseDevolution    : {0}   DevolutionLevel: {1}" -f $gl.UseDevolution, $gl.DevolutionLevel))
        }
        catch { $out.Add("  (Get-DnsClientGlobalSetting unavailable: $($_.Exception.Message))") }
        $out.Add("")

        $out.Add("--- Name Resolution Policy (NRPT) - can force specific names to specific servers ---")
        try {
            $nrpt = @(Get-DnsClientNrptPolicy -ErrorAction Stop)
            if ($nrpt.Count) {
                foreach ($n in $nrpt) { $out.Add(("  {0} -> {1}" -f $n.Namespace, (@($n.NameServers) -join ', '))) }
            }
            else { $out.Add("  (no NRPT rules)") }
        }
        catch { $out.Add("  (no NRPT rules / cmdlet unavailable)") }
        $out.Add("")

        $out.Add("--- HOSTS file entries that affect this target ($env:SystemRoot\System32\drivers\etc\hosts) ---")
        try {
            $hp = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
            if (-not (Test-Path $hp)) {
                $out.Add("  (hosts file not found)")
            }
            else {
                $tgtHost = ''
                try { if ($TargetUrl) { $tgtHost = ([uri]$TargetUrl).Host } } catch { }
                if (-not $tgtHost -and $TargetUrl) { $tgtHost = ($TargetUrl -replace '^[a-z]+://', '' -split '[/:]')[0] }

                # Parent domain, so a stale entry on a sibling host of the same domain is still surfaced.
                $parent = ''
                if ($tgtHost -and $tgtHost -notmatch '^\d+\.\d+\.\d+\.\d+$') {
                    $lab = @($tgtHost -split '\.')
                    if ($lab.Count -ge 2) { $parent = ($lab[-2..-1] -join '.') }
                }
                $tIps = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
                if ($tgtHost) {
                    try { foreach ($a in [System.Net.Dns]::GetHostAddresses($tgtHost)) { [void]$tIps.Add($a.IPAddressToString) } } catch { }
                }

                $raw = @(Get-Content $hp -ErrorAction Stop)
                $active = 0
                $direct = New-Object System.Collections.Generic.List[string]
                $related = New-Object System.Collections.Generic.List[string]
                foreach ($line in $raw) {
                    $t = $line.Trim()
                    if (-not $t -or $t.StartsWith('#')) { continue }
                    $active++
                    $tok = @($t -split '\s+')
                    if ($tok.Count -lt 2) { continue }
                    $ip = $tok[0]
                    $names = New-Object System.Collections.Generic.List[string]
                    foreach ($n in $tok[1..($tok.Count - 1)]) {
                        if ($n.StartsWith('#')) { break }
                        $names.Add($n)
                    }
                    if (-not $names.Count) { continue }

                    $isDirect = $false; $isRelated = $false; $why = ''
                    if ($tgtHost) {
                        foreach ($n in $names) {
                            if ($n -eq $tgtHost) { $isDirect = $true; $why = 'name matches the target host'; break }
                        }
                    }
                    if (-not $isDirect -and $tIps.Count -and $tIps.Contains($ip)) {
                        $isDirect = $true; $why = 'maps to an IP the target currently resolves to'
                    }
                    if (-not $isDirect -and $parent) {
                        foreach ($n in $names) {
                            if ($n -eq $parent -or $n.EndsWith('.' + $parent)) { $isRelated = $true; break }
                        }
                    }
                    if ($isDirect) { $direct.Add(("    {0}      <-- {1}" -f $t, $why)) }
                    elseif ($isRelated) { $related.Add(("    {0}" -f $t)) }
                }

                if (-not $tgtHost) {
                    $out.Add("  (no target supplied, so no filtering could be applied)")
                }
                elseif ($direct.Count) {
                    $out.Add(("  These entries BYPASS DNS for {0} - a stale one here is a classic cause of failures:" -f $tgtHost))
                    foreach ($d in $direct) { $out.Add($d) }
                }
                else {
                    $out.Add(("  No hosts-file entry affects {0}." -f $tgtHost))
                }
                if ($related.Count) {
                    $cap = 12
                    $out.Add("")
                    $out.Add(("  Other entries in the same domain ({0}) - not used for this target, shown for context:" -f $parent))
                    foreach ($r in ($related | Select-Object -First $cap)) { $out.Add($r) }
                    if ($related.Count -gt $cap) { $out.Add(("    ... and {0} more" -f ($related.Count - $cap))) }
                }
                $out.Add(("  ({0} active entries in the file were checked)" -f $active))
            }
        }
        catch { $out.Add("  ERROR: $($_.Exception.Message)") }
        $out.Add("")

        $out.Add("--- Quick resolver check ---")
        $probes = New-Object System.Collections.Generic.List[string]
        try { if ($TargetUrl) { $th = ([uri]$TargetUrl).Host; if ($th) { $probes.Add($th) } } } catch { }
        foreach ($extra in @('patchmypc.com', 'microsoft.com')) { if (-not $probes.Contains($extra)) { $probes.Add($extra) } }
        foreach ($probe in $probes) {
            try {
                $sw = [System.Diagnostics.Stopwatch]::StartNew()
                $ips = @([System.Net.Dns]::GetHostAddresses($probe) | ForEach-Object { $_.IPAddressToString })
                $sw.Stop()
                $out.Add(("  {0,-20} OK   {1} ms   {2}" -f $probe, $sw.ElapsedMilliseconds, (($ips | Select-Object -First 4) -join ', ')))
            }
            catch {
                $ex = $_.Exception; while ($ex.InnerException) { $ex = $ex.InnerException }
                $out.Add(("  {0,-20} FAIL {1}" -f $probe, $ex.Message))
            }
        }
        return $out
    }

    # The HKLM key is ACL'd against non-elevated users; fall back to the default install folders.
    function Get-PublisherInfo {
        $out = [pscustomobject]@{
            Installed = $false; Path = $null; LogFolder = $null; Version = $null; Source = ''
        }
        foreach ($k in @(
                'HKLM:\SOFTWARE\Patch My PC Publishing Service',
                'HKLM:\SOFTWARE\WOW6432Node\Patch My PC Publishing Service'
            )) {
            try {
                $ip = Get-ItemProperty -Path $k -ErrorAction Stop
                if ($ip.Path) { $out.Path = ([string]$ip.Path).TrimEnd('\') }
                if ($ip.LogPath) { $out.LogFolder = ([string]$ip.LogPath).TrimEnd('\') }
                if ($ip.Version) { $out.Version = [string]$ip.Version }
                $out.Source = "registry $k"
                break
            }
            catch {}
        }
        if (-not $out.Path) {
            foreach ($c in @(
                    (Join-Path $env:ProgramFiles        'Patch My PC\Patch My PC Publishing Service'),
                    (Join-Path ${env:ProgramFiles(x86)} 'Patch My PC\Patch My PC Publishing Service')
                )) {
                if ($c -and (Test-Path -LiteralPath $c)) {
                    $out.Path = $c
                    $out.Source = 'default install folder (HKLM key not readable from this account)'
                    break
                }
            }
        }
        # Logs normally live in a Logs sub-folder, but older builds wrote to the install root.
        if (-not $out.LogFolder) { $out.LogFolder = $out.Path }
        if ($out.Path) {
            $sub = Join-Path $out.Path 'Logs'
            if (Test-Path -LiteralPath $sub) { $out.LogFolder = $sub }
        }
        $out.Installed = [bool]$out.Path
        $out
    }

    # Only a small window is searched - a multi-megabyte string costs hundreds of ms per call.
    function ConvertFrom-CmTraceStamp {
        param([string]$Text, [int]$From, [regex]$Rx, [int]$Window = 8192)
        if ($From -lt 0 -or $From -ge $Text.Length) { return $null }
        $len = [Math]::Min($Window, $Text.Length - $From)
        $sm = $Rx.Match($Text.Substring($From, $len))
        if (-not $sm.Success) { return $null }
        try {
            return [datetime]::ParseExact(
                ('{0}-{1}-{2} {3}' -f $sm.Groups[4].Value, $sm.Groups[2].Value, $sm.Groups[3].Value, $sm.Groups[1].Value),
                'yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
        }
        catch { return $null }
    }

    function Get-LogEndpoints {
        param([int]$MaxFiles = 20, [int]$MaxMainLogs = 12, [int]$MaxBytesPerFile = 4194304, [int]$MaxDownloads = 25)

        $res = [pscustomobject]@{
            Found = $false; LogFolder = $null; FilesScanned = 0; Newest = $null
            Items = @(); Downloads = @(); Info = $null; Note = ''
        }
        $info = Get-PublisherInfo
        $res.Info = $info
        if (-not $info.Installed) {
            $res.Note = 'Publishing Service not installed here, so there are no logs to mine for endpoints - the common endpoints above are still the ones it uses.'
            return $res
        }

        $folder = $info.LogFolder
        if (-not $folder -or -not (Test-Path -LiteralPath $folder)) { $res.Note = "No log folder at $folder"; return $res }
        $res.LogFolder = $folder

        $all = @(Get-ChildItem -LiteralPath $folder -Filter 'PatchMyPC*.log' -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending)
        if ($all.Count -eq 0) { $res.Note = "No PatchMyPC*.log files in $folder"; return $res }

        # Download jobs only appear in the main log, which chatty component logs can push out of a newest-N window.
        $rxMain = [regex]'^PatchMyPC(-\d{6,}-\d{4,})?\.log$'
        $pick = [ordered]@{}
        foreach ($f in @($all | Select-Object -First $MaxFiles)) { $pick[$f.FullName] = $f }
        foreach ($f in @($all | Where-Object { $rxMain.IsMatch($_.Name) } | Select-Object -First $MaxMainLogs)) { $pick[$f.FullName] = $f }
        $files = @($pick.Values | Sort-Object LastWriteTime -Descending)
        $res.Newest = $files[0].LastWriteTime

        # Capture scheme/host/port directly - a [uri] per match is far too slow on a busy log.
        $rxUrl = [regex]::new('(?<s>https?)://(?<h>[A-Za-z0-9\.\-_]+)(?::(?<p>\d+))?', 'Compiled')
        $rxStamp = [regex]'time="(\d{2}:\d{2}:\d{2})[^"]*"\s+date="(\d{2})-(\d{2})-(\d{4})"'
        # The Download component writes the product URL in three shapes.
        $rxDl = @(
            [regex]::new('download job\s+\S+\s*:\s*\((?<u>https?://[^)]+)\)\s*:\s*\[(?<f>[^\]]*)\]', 'Compiled')
            [regex]::new('Finished downloading file:\s*\[(?<u>https?://[^\]]+)\]', 'Compiled')
            [regex]::new('download job\s+\S+\s*\[(?<f>[^\]]*)\]\s*:\s*\((?<u>https?://[^)]+)\)', 'Compiled')
        )
        # Plain .NET dictionaries: PSObject property access dominates this inner loop.
        $ci = [System.StringComparer]::OrdinalIgnoreCase
        $hits = [System.Collections.Generic.Dictionary[string, int]]::new($ci)
        $lastSeen = [System.Collections.Generic.Dictionary[string, datetime]]::new($ci)
        $lastFile = [System.Collections.Generic.Dictionary[string, string]]::new($ci)
        $dl = @{}

        foreach ($f in $files) {
            $text = $null
            try {
                $fs = [System.IO.File]::Open($f.FullName, 'Open', 'Read', 'ReadWrite')
                try {
                    # Only the tail of a large log is interesting, and it is the newest part.
                    if ($fs.Length -gt $MaxBytesPerFile) { [void]$fs.Seek(-$MaxBytesPerFile, 'End') }
                    $sr = New-Object System.IO.StreamReader($fs)
                    try { $text = $sr.ReadToEnd() } finally { $sr.Dispose() }
                }
                finally { $fs.Dispose() }
            }
            catch { continue }
            if (-not $text) { continue }
            $res.FilesScanned++

            # Rule the file out with a plain ordinal search first - almost no log holds download jobs.
            $hasDl = ($text.IndexOf('download job', [System.StringComparison]::OrdinalIgnoreCase) -ge 0) -or
            ($text.IndexOf('Finished downloading file:', [System.StringComparison]::OrdinalIgnoreCase) -ge 0)
            if ($hasDl) {
                foreach ($rx in $rxDl) {
                    foreach ($m in $rx.Matches($text)) {
                        $u = $m.Groups['u'].Value.TrimEnd('.', ',', ';')
                        if (-not $u) { continue }
                        $uu = $null
                        try { $uu = [uri]$u } catch { continue }
                        if (-not $uu.Host) { continue }
                        $hh = $uu.Host.ToLowerInvariant()
                        if ($hh -eq 'localhost' -or $hh -eq '::1' -or $hh -eq '[::1]' -or $hh.StartsWith('127.')) { continue }
                        if (-not $dl.ContainsKey($u)) {
                            $file = ''
                            if ($m.Groups['f'].Success) { $file = $m.Groups['f'].Value }
                            if (-not $file) { try { $file = [System.IO.Path]::GetFileName($uu.AbsolutePath) } catch {} }
                            $when = ConvertFrom-CmTraceStamp -Text $text -From $m.Index -Rx $rxStamp
                            if (-not $when) { $when = $f.LastWriteTime }
                            $dl[$u] = [pscustomobject]@{ Url = $u; File = $file; Last = $when }
                        }
                        elseif ($m.Groups['f'].Success -and $m.Groups['f'].Value -and -not $dl[$u].File) {
                            $dl[$u].File = $m.Groups['f'].Value
                        }
                    }
                }
            }

            $ms = $rxUrl.Matches($text)
            if ($ms.Count -eq 0) { continue }

            # Walk backwards so the first hit is the newest; files are processed newest-first.
            $newIdx = [System.Collections.Generic.Dictionary[string, int]]::new($ci)
            for ($i = $ms.Count - 1; $i -ge 0; $i--) {
                $m = $ms[$i]
                $h = $m.Groups[2].Value.TrimEnd('.', '-', '_')
                if ($h.Length -lt 4) { continue }
                if ($h[0] -eq '1' -and $h.StartsWith('127.')) { continue }
                if (-not $h.Contains('.')) { continue }

                $key = $m.Groups[1].Value + '://' + $h
                $port = $m.Groups[3].Value
                if ($port -and $port -ne '80' -and $port -ne '443') { $key += ':' + $port }

                $n = 0
                if ($hits.TryGetValue($key, [ref]$n)) { $hits[$key] = $n + 1 }
                else { $hits[$key] = 1 }
                if (-not $newIdx.ContainsKey($key)) { $newIdx[$key] = $m.Index }
            }
            foreach ($k in $newIdx.Keys) {
                if ($lastSeen.ContainsKey($k)) { continue }
                $when = ConvertFrom-CmTraceStamp -Text $text -From $newIdx[$k] -Rx $rxStamp
                if (-not $when) { $when = $f.LastWriteTime }
                $lastSeen[$k] = $when
                $lastFile[$k] = $f.Name
            }
        }

        $items = foreach ($k in $hits.Keys) {
            if ($k -match '://(localhost|127\.)') { continue }
            [pscustomobject]@{
                Url      = $k.ToLowerInvariant()
                Hits     = $hits[$k]
                Last     = $(if ($lastSeen.ContainsKey($k)) { $lastSeen[$k] } else { $null })
                LastFile = $(if ($lastFile.ContainsKey($k)) { $lastFile[$k] } else { '' })
            }
        }

        $res.Found = $true
        $res.Downloads = @($dl.Values | Sort-Object -Property Last -Descending | Select-Object -First $MaxDownloads)
        $res.Items = @($items | Sort-Object -Property @{ Expression = 'Last'; Descending = $true }, @{ Expression = 'Hits'; Descending = $true })
        $res.Note = ('{0} download URL(s) and {1} endpoint(s) from {2} log file(s)' -f $res.Downloads.Count, $res.Items.Count, $res.FilesScanned)
        $res
    }

    # Central dispatcher, shared by the in-process and headless SYSTEM paths so results match.
    function Invoke-RequestedTests {
        param([string[]]$Tests, [string]$Url, $ProxyObj, [string]$ProxyMode, [int]$MaxFetchChars = 524288)
        # Each check is isolated: without this one failure threw out of the loop, skipping all the rest.
        $titles = @{
            ProxyView = 'PROXY CONFIGURATION'; DnsCfg = 'DNS CONFIGURATION'; Http = 'HTTP(S) GET'
            Ports = 'TCP PORT TEST'; Ping = 'PING'; Tracert = 'TRACEROUTE'
            Dns = 'DNS LOOKUP'; Tls = 'TLS HANDSHAKE'; BoxTls = 'THIS MACHINE - TLS'
            CipherCmp = 'CIPHER COMPARISON'; Fetch = 'PAGE FETCH'; Download = 'FILE DOWNLOAD'
            Smb = 'SMB / FILE SHARE'; Rpc = 'RPC / ENDPOINT MAPPER'
        }
        foreach ($t in $Tests) {
            try {
                switch ($t) {
                    'ProxyView' { Get-ProxyConfigView -SampleUrl $Url }
                    'DnsCfg' { Get-DnsConfig -TargetUrl $Url }
                    'Http' { Invoke-HttpTest -Url $Url -ProxyObj $ProxyObj -ProxyMode $ProxyMode }
                    'Download' { Invoke-DownloadTest -Url $Url -ProxyObj $ProxyObj -ProxyMode $ProxyMode }
                    'Ports' { Invoke-PortTest -Url $Url -ProxyObj $ProxyObj }
                    'Smb' { Invoke-SmbTest -Url $Url }
                    'Rpc' { Invoke-RpcTest -Url $Url }
                    'Ping' { Invoke-PingTest -Url $Url }
                    'Tracert' { Invoke-TracertTest -Url $Url }
                    'Dns' { Invoke-NslookupTest -Url $Url }
                    'Tls' { Get-SslInfo -Url $Url -ProxyObj $ProxyObj }
                    'BoxTls' { Get-BoxTlsConfig }
                    'CipherCmp' { Get-CipherMatrix -Url $Url -ProxyObj $ProxyObj }
                    'Fetch' {
                        # Returns the body between markers so the Browser tab can render what THIS account received.
                        $c = Get-HttpContent -Url $Url -ProxyObj $ProxyObj -ProxyMode $ProxyMode -TimeoutSec 25 -MaxChars $MaxFetchChars
                        Write-Output '<<<CT-FETCH-META>>>'
                        Write-Output "Status=$($c.Status)"
                        Write-Output "Reason=$($c.Reason)"
                        Write-Output "ContentType=$($c.ContentType)"
                        Write-Output "ProxyUsed=$($c.ProxyUsed)"
                        Write-Output "FinalUrl=$($c.FinalUrl)"
                        Write-Output "BodyChars=$($c.BodyChars)"
                        Write-Output "Truncated=$($c.Truncated)"
                        Write-Output "Error=$($c.Error)"
                        Write-Output '<<<CT-FETCH-BODY>>>'
                        foreach ($ln in ([string]$c.Body -split "`r?`n")) { Write-Output $ln }
                        Write-Output '<<<CT-FETCH-END>>>'
                    }
                    default { Write-Output "Unknown test: $t" }
                }
            }
            catch {
                # A check that dies still gets a section, so it still gets a card naming the failure.
                $ex = $_.Exception; while ($ex.InnerException) { $ex = $ex.InnerException }
                $title = $titles[$t]; if (-not $title) { $title = ([string]$t).ToUpperInvariant() }
                Write-Output ("=== {0} : {1} ===" -f $title, $Url)
                Write-Output ("  ERROR          : {0}" -f $ex.Message)
                Write-Output  "  RESULT         : FAIL - this check could not be completed."
            }
            Write-Output ''
        }
    }

    # The helper task lives in the ROOT: a task folder's registry and disk halves can desync unrepairably.
    $script:TaskFolder = '\'
    $script:TaskName = 'Patch My PC Connection Test'
    $script:TaskMarker = 'PMPC-CONNTEST-HELPER'
    # Where earlier builds put it - swept on every launch so upgrading leaves nothing behind.
    $script:LegacyTasks = @(
        @{ Folder = 'Patch My PC'; Name = 'SYSTEM Connection Test' },
        @{ Folder = 'Patch My PC Connection Test'; Name = 'SYSTEM Connection Test' },
        @{ Folder = ''; Name = 'SYSTEM Connection Test' }
    )
    # The two halves Windows keeps a task in. Variables purely so tests can sandbox the cleanup.
    $script:TaskCacheRoot = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache'
    $script:TaskDiskRoot = Join-Path $env:SystemRoot 'System32\Tasks'
    $script:TaskDesc = @"
$script:TaskMarker
 Temporary helper created by the Patch My PC Connection Test tool so that network
tests can be run as NT AUTHORITY\SYSTEM. It has no schedule, is only ever started on demand, expires automatically and is
deleted when the tool closes.
"@

    function Get-TaskFullPath { ('{0}{1}' -f $script:TaskFolder, $script:TaskName) }

    # The HRESULTs that actually come up when the helper task will not run, in words rather than hex.
    function ConvertFrom-TaskResult {
        param($Code)
        if ($null -eq $Code) { return 'no status available' }
        $c = [int64]$Code
        switch ($c) {
            267008 { 'ready (last run completed successfully)'; break }
            267009 { 'still running'; break }
            267010 { 'not run - the task is disabled'; break }
            267011 { 'has not run yet'; break }
            267012 { 'no more runs scheduled'; break }
            267014 { 'terminated - the run was stopped'; break }
            2147750687 { 'not started - an instance was already running'; break }
            2147943645 { 'not started - the service is not available (no user logged on?)'; break }
            2147942402 { 'failed - the program to run was not found'; break }
            2147942405 { 'failed - access denied launching the program'; break }
            0 { 'completed successfully'; break }
            default { ('exit code 0x{0:X8} ({1})' -f $c, $c) }
        }
    }

    # COM, not the ScheduledTasks module: the CIM provider hides the HRESULT and is absent on Server Core.
    $script:TaskStateNames = @{ 0 = 'unknown'; 1 = 'disabled'; 2 = 'queued'; 3 = 'ready'; 4 = 'running' }
    $script:SysEndMarker = '###PMPC-SYSTEM-TEST-COMPLETE###'

    function Connect-TaskService {
        # Cached: the poll loop asks twice a second for up to 150s. Rebuilt if the handle goes bad.
        if ($script:TaskSvc) {
            try { $null = $script:TaskSvc.Connected; return $script:TaskSvc } catch { $script:TaskSvc = $null }
        }
        $svc = New-Object -ComObject 'Schedule.Service'
        $svc.Connect()
        $script:TaskSvc = $svc
        return $svc
    }

    # '\' is the root and must pass through as-is - TrimEnd would make it '', which GetFolder rejects.
    function Get-TaskFolderPath {
        param([string]$Leaf)
        if ([string]::IsNullOrWhiteSpace($Leaf)) { return '\' }
        $Leaf = $Leaf.Trim().Trim('\').Trim()
        if ($Leaf -eq '') { return '\' }
        return '\' + $Leaf
    }

    function Get-TaskFolderOrNull {
        param($Svc)
        try { return $Svc.GetFolder((Get-TaskFolderPath $script:TaskFolder)) } catch { return $null }
    }

    # COM surfaces the HRESULT on the inner exception; without it every failure reads the same.
    function Get-TaskErrorText {
        param($ErrorRecord)
        $msg = ''
        $hr = 0
        try {
            $ex = $ErrorRecord.Exception
            $msg = ([string]$ex.Message).Trim()
            # Walk the WHOLE chain - only the last carries a real code, and 0x8013xxxx is a CLR wrapper.
            $walk = $ex
            $depth = 0
            while ($walk -and $depth -lt 8) {
                $h = 0
                try { $h = [int]$walk.HResult } catch {}
                if ($h -and (($h -band [int]0xFFFF0000) -ne [int]0x80130000)) {
                    $hr = $h
                    $inner = ([string]$walk.Message).Trim()
                    if ($inner) { $msg = $inner }
                    break
                }
                $walk = $walk.InnerException
                $depth++
            }
        }
        catch {}
        if (-not $msg) { $msg = 'unknown error' }
        # A message already carrying an HRESULT has been through here - appending another buries the real one.
        if ($hr -and $msg -notlike '*HRESULT 0x*') { return ('{0} (HRESULT 0x{1:X8})' -f $msg, $hr) }
        return $msg
    }

    # Names the failing step: E_INVALIDARG alone cannot be acted on, since any call can raise it.
    function Invoke-TaskStep {
        param([string]$Step, [scriptblock]$Body)
        try { return (& $Body) }
        catch { throw ('while {0}: {1}' -f $Step, (Get-TaskErrorText $_)) }
    }

    # Returns the helper task ONLY if it is unmistakably ours.
    function Get-OwnSystemTask {
        try {
            $f = Get-TaskFolderOrNull (Connect-TaskService)
            if (-not $f) { return $null }
            $t = $f.GetTask($script:TaskName)
            if (-not $t) { return $null }
            $d = ''
            try { $d = [string]$t.Definition.RegistrationInfo.Description } catch {}
            if ($d -and $d.Contains($script:TaskMarker)) { return $t }
        }
        catch {}
        return $null
    }

    # The poll loop uses -Trusted to skip re-reading the definition to re-check a marker it just wrote.
    function Get-SystemTaskState {
        param([switch]$Trusted)
        try {
            $f = Get-TaskFolderOrNull (Connect-TaskService)
            if (-not $f) { return $null }
            $t = $f.GetTask($script:TaskName)
            if (-not $t) { return $null }
            if (-not $Trusted) {
                $d = ''
                try { $d = [string]$t.Definition.RegistrationInfo.Description } catch {}
                if (-not ($d -and $d.Contains($script:TaskMarker))) { return $null }
            }
            $state = 0; $last = $null; $when = $null
            try { $state = [int]$t.State } catch {}
            try { $last = [int64]$t.LastTaskResult } catch {}
            try { $when = $t.LastRunTime } catch {}
            $nm = if ($script:TaskStateNames.ContainsKey($state)) { $script:TaskStateNames[$state] } else { 'unknown' }
            return [pscustomobject]@{ State = $state; StateName = $nm; LastTaskResult = $last
                LastRunTime = $when; Running = ($state -eq 4) 
            }
        }
        catch { return $null }
    }

    # A task the scheduler cannot enumerate is not a working task, whatever the registry claims.
    function Test-TaskEnumerable {
        param([string]$Leaf, [string]$Name)
        try {
            $svc = Connect-TaskService
            $f = $null
            try { $f = $svc.GetFolder((Get-TaskFolderPath $Leaf)) } catch { return $false }
            if (-not $f) { return $false }
            foreach ($t in $f.GetTasks(1)) { if ($t.Name -eq $Name) { return $true } }
        }
        catch {}
        return $false
    }

    # Clears a half-written registration - both halves - which nothing else can repair.
    function Clear-GhostSystemTask {
        param([string]$Leaf = '', [string]$Name = $script:TaskName)
        $removed = @()
        $rel = if ($Leaf) { Join-Path $Leaf $Name } else { $Name }
        $xml = Join-Path $script:TaskDiskRoot $rel
        $mine = $false
        try {
            if (Test-Path -LiteralPath $xml) {
                $body = ''
                try { $body = [System.IO.File]::ReadAllText($xml, [System.Text.Encoding]::Unicode) } catch {}
                if (-not ($body -and $body.Contains($script:TaskMarker))) {
                    try { $body = [System.IO.File]::ReadAllText($xml) } catch {}
                }
                if ($body -and $body.Contains($script:TaskMarker)) { $mine = $true }
            }
        }
        catch {}

        $cache = $script:TaskCacheRoot
        $tree = Join-Path (Join-Path $cache 'Tree') $rel
        $id = $null
        try { if (Test-Path -LiteralPath $tree) { $id = (Get-ItemProperty -LiteralPath $tree -Name Id -ErrorAction SilentlyContinue).Id } } catch {}

        # A cache entry with no task file that cannot be enumerated is a leftover by definition.
        $orphan = $false
        try {
            if ((Test-Path -LiteralPath $tree) -and -not (Test-Path -LiteralPath $xml) -and
                -not (Test-TaskEnumerable -Leaf $Leaf -Name $Name)) { $orphan = $true }
        }
        catch {}

        if (-not $mine -and -not $id -and -not $orphan) { return $null }

        # Registry half first: the reverse leaves a phantom that is listed but can never run.
        $treeGone = $true
        if (Test-Path -LiteralPath $tree) {
            try { Remove-Item -LiteralPath $tree -Recurse -Force -ErrorAction Stop; $removed += 'its TaskCache registration' }
            catch { $treeGone = $false }
        }
        if ($treeGone -and $id) {
            foreach ($sub in @('Tasks', 'Plain', 'Logon', 'Boot', 'Maintenance')) {
                $k = Join-Path $cache ('{0}\{1}' -f $sub, $id)
                try { if (Test-Path -LiteralPath $k) { Remove-Item -LiteralPath $k -Recurse -Force -ErrorAction Stop } } catch {}
            }
        }
        if ($mine -and $treeGone) {
            try { Remove-Item -LiteralPath $xml -Force -ErrorAction Stop; $removed += 'the task XML' } catch {}
        }
        if (-not $removed.Count) { return $null }
        return ($removed -join ' and ')
    }

    # Both halves, only when empty. COM DeleteFolder is never called - it creates exactly this mess.
    function Remove-TaskFolderTree {
        param([string]$Leaf)
        # The root is not a folder anyone may remove, and an empty leaf would resolve to it.
        if ([string]::IsNullOrWhiteSpace($Leaf) -or $Leaf.Trim('\') -eq '') { return $false }
        $Leaf = $Leaf.Trim('\')
        $dir = Join-Path $script:TaskDiskRoot $Leaf
        $tree = Join-Path (Join-Path $script:TaskCacheRoot 'Tree') $Leaf
        $hasDir = $false; $hasReg = $false
        try { $hasDir = Test-Path -LiteralPath $dir }  catch {}
        try { $hasReg = Test-Path -LiteralPath $tree } catch {}
        if (-not $hasDir -and -not $hasReg) { return $false }

        # Anything in EITHER half means the folder is not ours - '\Patch My PC' can hold real product tasks.
        try { if ($hasDir -and @(Get-ChildItem -LiteralPath $dir  -Force -ErrorAction SilentlyContinue).Count) { return $false } } catch { return $false }
        try { if ($hasReg -and @(Get-ChildItem -LiteralPath $tree -ErrorAction SilentlyContinue).Count) { return $false } } catch { return $false }

        if ($hasReg) {
            try { Remove-Item -LiteralPath $tree -Recurse -Force -ErrorAction Stop }
            catch { return $false }   # bail BEFORE touching disk, or the folder desyncs
        }
        if ($hasDir) { try { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue } catch {} }
        return $true
    }

    function Clear-LegacyTasks {
        $done = @()
        foreach ($old in $script:LegacyTasks) {
            $leaf = [string]$old.Folder
            $name = [string]$old.Name
            if ($leaf -eq '' -and $name -eq $script:TaskName) { continue }
            try {
                $svc = Connect-TaskService
                $f = $null
                try { $f = $svc.GetFolder((Get-TaskFolderPath $leaf)) } catch {}
                if ($f) {
                    try {
                        $t = $f.GetTask($name)
                        $d = ''
                        try { $d = [string]$t.Definition.RegistrationInfo.Description } catch {}
                        if ($d -and $d.Contains($script:TaskMarker)) {
                            try { $t.Stop(0) } catch {}
                            $f.DeleteTask($name, 0)
                        }
                    }
                    catch {}
                }
            }
            catch {}
            try { $null = Clear-GhostSystemTask -Leaf $leaf -Name $name } catch {}
            if ($leaf) { try { if (Remove-TaskFolderTree -Leaf $leaf) { $done += $leaf } } catch {} }
        }
        if (-not $done.Count) { return $null }
        return ("removed the old '{0}' task folder" -f ($done -join "', '"))
    }

    # Only for a desynced SUBFOLDER left by an earlier build; the root task can never need it.
    function Repair-TaskFolder {
        param([string]$Leaf = $script:TaskFolder)
        if ([string]::IsNullOrWhiteSpace($Leaf) -or $Leaf.Trim('\') -eq '') { return $false }
        $dir = Join-Path $script:TaskDiskRoot $Leaf.Trim('\')
        if (Test-Path -LiteralPath $dir) { return $false }
        try { $null = New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop; return $true }
        catch { return $false }
    }

    # Registers from scratch every run - updating in place made a re-run differ from the first.
    function Register-SystemTask {
        param([string]$ExePath, [string]$Arguments, [int]$SelfDeleteMinutes = 60)
        if ([string]::IsNullOrWhiteSpace($ExePath)) { throw 'while preparing the task: no program to run was resolved.' }
        # Full removal, not DeleteTask: a leftover Tree key makes the next registration fail E_INVALIDARG.
        try { $null = Remove-SystemTask } catch {}
        try { $script:TaskSvc = $null } catch {}
        $svc = Invoke-TaskStep 'connecting to the Task Scheduler service' { Connect-TaskService }
        # The root folder always exists, so there is nothing to create, repair or desync.
        $f = Invoke-TaskStep 'opening the Task Scheduler library root' { $svc.GetFolder((Get-TaskFolderPath $script:TaskFolder)) }
        $td = Invoke-TaskStep 'creating a task definition' { $svc.NewTask(0) }
        Invoke-TaskStep 'filling in the task definition' {
            $td.RegistrationInfo.Description = $script:TaskDesc
            $td.RegistrationInfo.Author = 'Patch My PC Connection Test'
            $td.Settings.AllowDemandStart = $true
            $td.Settings.DisallowStartIfOnBatteries = $false
            $td.Settings.StopIfGoingOnBatteries = $false
            $td.Settings.ExecutionTimeLimit = 'PT10M'
            $td.Settings.MultipleInstances = 2
            $td.Settings.StartWhenAvailable = $false
            $td.Settings.Enabled = $true
            $td.Settings.Hidden = $false
            # Self-deletes so nothing survives a crash - it needs the expiring trigger below to act on.
            $td.Settings.DeleteExpiredTaskAfter = 'PT0S'
        }
        # DISABLED and opening now, so it can never launch anything by itself.
        Invoke-TaskStep 'adding the expiry trigger' {
            $inv = [System.Globalization.CultureInfo]::InvariantCulture
            $now = Get-Date
            # A zero or negative window is rejected outright, and an expired task cannot be started on demand.
            $mins = [Math]::Max(5, $SelfDeleteMinutes)
            $trg = $td.Triggers.Create(1)
            $trg.StartBoundary = $now.ToString('yyyy-MM-ddTHH:mm:ss', $inv)
            $trg.EndBoundary = $now.AddMinutes($mins).ToString('yyyy-MM-ddTHH:mm:ss', $inv)
            $trg.Enabled = $false
        }
        Invoke-TaskStep 'adding the task action' {
            $act = $td.Actions.Create(0)
            $act.Path = $ExePath
            $act.Arguments = $Arguments
        }
        Invoke-TaskStep 'setting the task to run as SYSTEM' {
            $td.Principal.UserId = 'S-1-5-18'
            $td.Principal.LogonType = 5
            $td.Principal.RunLevel = 1
        }

        # CREATE_OR_UPDATE replaces a registration the delete could not reach. Two forms - builds differ.
        Invoke-TaskStep 'registering the task' {
            try { $f.RegisterTaskDefinition($script:TaskName, $td, 6, $null, $null, 5) }
            catch { $f.RegisterTaskDefinition($script:TaskName, $td, 6, 'S-1-5-18', $null, 5) }
        }
    }

    # Verifies the marker first, so a same-named task from anything else is left alone.
    function Remove-SystemTask {
        $ok = $false
        try {
            $svc = Connect-TaskService
            $f = Get-TaskFolderOrNull $svc
            if ($f -and (Get-OwnSystemTask)) {
                try { $f.GetTask($script:TaskName).Stop(0) } catch {}
                $f.DeleteTask($script:TaskName, 0)
                $ok = $true
            }
        }
        catch { $ok = $false }
        # DeleteTask leaves the TaskCache\Tree key behind, so this always runs and finishes the job.
        if (Clear-GhostSystemTask) { $ok = $true }
        return $ok
    }

    # Everything this tool writes to Task Scheduler, gone. Reports what it removed.
    function Remove-AllTaskArtifacts {
        $notes = @()
        try { if (Remove-SystemTask) { $notes += 'removed the helper task' } } catch {}
        try { $l = Clear-LegacyTasks; if ($l) { $notes += $l } } catch {}
        $left = @()
        try { if (Test-Path -LiteralPath (Join-Path $script:TaskDiskRoot $script:TaskName)) { $left += 'the task XML' } } catch {}
        try { if (Test-Path -LiteralPath (Join-Path (Join-Path $script:TaskCacheRoot 'Tree') $script:TaskName)) { $left += 'its TaskCache key' } } catch {}
        return [pscustomobject]@{ Notes = $notes; Leftover = $left; Clean = (-not $left.Count) }
    }

    # Readable only by SYSTEM and Administrators, DPAPI-encrypted at machine scope on top.
    function Write-ProtectedParamFile {
        param([hashtable]$Data, [string]$Path)
        $json = ($Data | ConvertTo-Json -Compress)
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
        $enc = [System.Security.Cryptography.ProtectedData]::Protect($bytes, $null, 'LocalMachine')
        [System.IO.File]::WriteAllBytes($Path, $enc)
        try {
            $acl = Get-Acl -Path $Path
            $acl.SetAccessRuleProtection($true, $false)
            # The creating account must keep access or the tool cannot shred the file afterwards.
            $ids = @(
                (New-Object System.Security.Principal.SecurityIdentifier('S-1-5-18')),
                (New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')),
                ([System.Security.Principal.WindowsIdentity]::GetCurrent().User)
            )
            $acl.SetOwner([System.Security.Principal.WindowsIdentity]::GetCurrent().User)
            foreach ($id in $ids) {
                $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($id, 'FullControl', 'Allow')))
            }
            Set-Acl -Path $Path -AclObject $acl
        }
        catch {}
    }

    function Read-ProtectedParamFile {
        param([string]$Path)
        $raw = [System.IO.File]::ReadAllBytes($Path)
        try { $dec = [System.Security.Cryptography.ProtectedData]::Unprotect($raw, $null, 'LocalMachine') }
        catch { return ($null) }
        return ([System.Text.Encoding]::UTF8.GetString($dec) | ConvertFrom-Json)
    }

    # Overwrites before deleting so a credential is not recoverable; delete runs in finally regardless.
    function Remove-FileSecurely {
        param([string]$Path)
        try {
            if (-not (Test-Path -LiteralPath $Path)) { return }
            try {
                $len = (Get-Item -LiteralPath $Path).Length
                if ($len -gt 0 -and $len -lt 1MB) {
                    $junk = New-Object byte[] $len
                    $rng = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
                    try { $rng.GetBytes($junk) } finally { $rng.Dispose() }
                    [System.IO.File]::WriteAllBytes($Path, $junk)
                }
            }
            catch {}
        }
        finally {
            try { Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue } catch {}
        }
    }

    function Invoke-SystemContextTests {
        param([string]$SelfPath, [string]$ExePath, [string[]]$Tests, [string]$Url,
            [string]$Mode, [string]$PHost, [int]$PPort, [string]$PUser, [string]$PPass,
            [bool]$UseDefaultCreds = $false,
            [int]$SelfDeleteMinutes = 60)
        $tmp = [System.IO.Path]::GetTempPath()
        $pf = Join-Path $tmp ('pmpc_ct_{0}.bin' -f ([guid]::NewGuid().ToString('N')))
        $of = Join-Path $tmp ('pmpc_ct_{0}.out' -f ([guid]::NewGuid().ToString('N')))

        # Pinned to Windows PowerShell: pwsh reads HTTP_PROXY first and ignores SchUseStrongCrypto.
        $winPs = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        if (-not (Test-Path -LiteralPath $winPs)) {
            # 32-bit host on a 64-bit OS: the task engine is 64-bit, so resolve through Sysnative.
            $alt = Join-Path $env:SystemRoot 'Sysnative\WindowsPowerShell\v1.0\powershell.exe'
            if (Test-Path -LiteralPath $alt) { $winPs = $alt }
        }
        if (Test-Path -LiteralPath $winPs) {
            if ($ExePath -and $ExePath -ne $winPs) {
                ("[SYSTEM] Host pinned to Windows PowerShell ({0}) so results match the .NET Framework service." -f $winPs)
            }
            $ExePath = $winPs
        }

        try {
            # MultipleInstances=IgnoreNew means starting over a live instance succeeds and starts nothing.
            $prev = Get-SystemTaskState
            if ($prev -and $prev.Running) {
                '[SYSTEM] A previous helper task instance is still running - stopping it so this run can start.'
                try { (Get-TaskFolderOrNull (Connect-TaskService)).GetTask($script:TaskName).Stop(0) } catch {}
                $killBy = (Get-Date).AddSeconds(15)
                while ((Get-Date) -lt $killBy) {
                    Start-Sleep -Milliseconds 500
                    $st = Get-SystemTaskState
                    if (-not $st -or -not $st.Running) { break }
                }
                $st = Get-SystemTaskState
                if ($st -and $st.Running) {
                    '[SYSTEM] ERROR: the previous instance will not stop. End it in Task Scheduler, then run again.'
                    '  RESULT         : FAIL - a previous SYSTEM helper task is still running.'
                    return
                }
                '[SYSTEM] Previous instance stopped.'
            }

            Invoke-TaskStep 'writing the parameter file' {
                Write-ProtectedParamFile -Data @{
                    Targets = @($Url); Tests = $Tests; ProxyMode = $Mode
                    PHost = $PHost; PPort = $PPort; PUser = $PUser; PPass = $PPass
                    UseDefaultCreds = [bool]$UseDefaultCreds
                } -Path $pf
            }
            $arg = ('-NonInteractive -NoProfile -ExecutionPolicy Bypass -File "{0}" -SystemTest -ParamFile "{1}" -OutFile "{2}"' -f $SelfPath, $pf, $of)

            try {
                $null = Register-SystemTask -ExePath $ExePath -Arguments $arg -SelfDeleteMinutes $SelfDeleteMinutes
            }
            catch {
                # Usually a half-written registration from an earlier failure - clear both halves and retry once.
                $why = Get-TaskErrorText $_
                if ($why -like 'while *') { ('[SYSTEM] Registration failed {0}' -f $why) } else { ('[SYSTEM] Registration failed: {0}' -f $why) }
                $ghost = Clear-GhostSystemTask
                if ($ghost) { ('[SYSTEM] Cleared a broken registration ({0}) - retrying.' -f $ghost) }
                else { '[SYSTEM] Retrying the registration.' }
                # The service caches folder handles per connection, so a stale one keeps failing on its own.
                $script:TaskSvc = $null
                $null = Register-SystemTask -ExePath $ExePath -Arguments $arg -SelfDeleteMinutes $SelfDeleteMinutes
            }

            $rt = Invoke-TaskStep 'looking the task up after registering it' {
                $f = Get-TaskFolderOrNull (Connect-TaskService)
                if (-not $f) { throw 'the Task Scheduler library root could not be opened.' }
                $f.GetTask($script:TaskName)
            }
            Invoke-TaskStep 'starting the task' {
                # RunEx is Run() with explicit flags; some builds reject Run()'s own defaults.
                try { $null = $rt.Run($null) }
                catch { $null = $rt.RunEx($null, 0, 0, $null) }
            }
            ("[SYSTEM] Started '\{0}' as NT AUTHORITY\SYSTEM; waiting for results..." -f $script:TaskName)
            if (-not $script:SysTaskHintShown) {
                $script:SysTaskHintShown = $true
                $vis = Get-TaskVisibility
                if ($vis.Com -and $vis.Schtasks) {
                    '[SYSTEM] It is registered and the scheduler can enumerate it. It is removed again as soon'
                    '[SYSTEM] as the run finishes, so nothing is left on the machine. Task Scheduler also never'
                    '[SYSTEM] refreshes on its own - select Task Scheduler Library and press F5 to see it.'
                }
                elseif ($vis.Xml -or $vis.Tree) {
                    '[SYSTEM] WARNING: the scheduler cannot enumerate this task even though it is on disk. That is'
                    '[SYSTEM] the broken registration that hides it from the console - see the SYSTEM tab.'
                }
            }

            $started = (Get-Date)
            $deadline = $started.AddSeconds(150)
            $nextBeat = $started.AddSeconds(10)
            $ranAtAll = $false
            $finished = $false
            $script:SysEmitted = 0
            # Tail the output file while the task runs, so a blind two-minute wait becomes live progress.
            $tail = {
                param([bool]$Final)
                if (-not (Test-Path $of)) { return }
                $cur = @(Get-Content -LiteralPath $of -ErrorAction SilentlyContinue)
                # Hold back the last line mid-run: a flush can be caught half-written.
                $upto = if ($Final) { $cur.Count } else { $cur.Count - 1 }
                for ($i = $script:SysEmitted; $i -lt $upto; $i++) {
                    if ($cur[$i] -ne $script:SysEndMarker) { $cur[$i] }
                }
                if ($upto -gt $script:SysEmitted) { $script:SysEmitted = $upto }
            }
            # Completion is read from the results themselves - an unqueryable task never reports its state.
            $isDone = {
                try {
                    if (-not (Test-Path $of)) { return $false }
                    $c = @(Get-Content -LiteralPath $of -ErrorAction SilentlyContinue)
                    return ($c.Count -gt 0 -and $c[$c.Count - 1] -eq $script:SysEndMarker)
                }
                catch { return $false }
            }
            while ((Get-Date) -lt $deadline) {
                Start-Sleep -Milliseconds 500
                $st = Get-SystemTaskState -Trusted
                if ($st -and $st.Running) { $ranAtAll = $true }
                & $tail $false
                if (& $isDone) { $finished = $true; break }
                # Fallback for a killed task, or an older copy on disk that does not write the marker.
                if ($ranAtAll -and $st -and -not $st.Running -and (Test-Path $of)) {
                    Start-Sleep -Milliseconds 300; $finished = $true; break
                }
                if ((Get-Date) -ge $nextBeat) {
                    $nextBeat = (Get-Date).AddSeconds(10)
                    $secs = [int]((Get-Date) - $started).TotalSeconds
                    $state = if ($st) { ConvertFrom-TaskResult $st.LastTaskResult } else { 'the task could not be queried' }
                    ('[SYSTEM] {0}s elapsed - {1}{2}' -f $secs, $state,
                    $(if ($script:SysEmitted -gt 0) { ", $($script:SysEmitted) line(s) received" } else { ', nothing received yet' }))
                }
            }
            if (Test-Path $of) {
                & $tail $true
                if (-not $finished) {
                    '[SYSTEM] WARNING: the task was still running after 150s - the results above may be incomplete.'
                }
            }
            else {
                $st = Get-SystemTaskState -Trusted
                $state = if ($st) { ConvertFrom-TaskResult $st.LastTaskResult } else { 'the task could not be queried' }
                '[SYSTEM] ERROR: the helper task produced no output.'
                ('[SYSTEM]   Task status : {0}' -f $state)
                ('[SYSTEM]   Last run    : {0}' -f $(if ($st -and $st.LastRunTime) { $st.LastRunTime } else { 'never' }))
                if (-not $ranAtAll) {
                    '[SYSTEM]   The task never entered the running state, so Windows refused to start it.'
                    '[SYSTEM]   Check Task Scheduler > History for this task, and that the session is elevated.'
                }
                '  RESULT         : FAIL - no results were returned from the SYSTEM context.'
            }
        }
        catch {
            # Steps from Invoke-TaskStep already read as a sentence, so they follow ERROR without a colon.
            $why = Get-TaskErrorText $_
            if ($why -like 'while *') { ('[SYSTEM] ERROR {0}' -f $why) } else { ('[SYSTEM] ERROR: {0}' -f $why) }
            '  RESULT         : FAIL - the SYSTEM helper task could not be run.'
        }
        finally {
            # Both halves removed as soon as the run ends, or the next run trips over the leftover.
            try { $null = Remove-SystemTask } catch {}
            Remove-FileSecurely $pf
            Remove-FileSecurely $of
        }
    }

    # Clears a task orphaned by a run that was killed, and residue from earlier builds.
    function Clear-StaleSystemTask {
        $notes = @()
        $st = Get-SystemTaskState
        if ($st) {
            if ($st.Running) { $notes += "A previous SYSTEM helper task is still running - left alone." }
            elseif (Remove-SystemTask) { $notes += "Removed a SYSTEM helper task left behind by a previous run." }
            else { $notes += "Found a leftover SYSTEM helper task but could not remove it (needs elevation)." }
        }
        else {
            # A broken registration the scheduler will not admit to can still fail every future run.
            $ghost = Clear-GhostSystemTask
            if ($ghost) { $notes += ("Cleared a broken SYSTEM helper task registration ({0})." -f $ghost) }
        }
        try { $lg = Clear-LegacyTasks; if ($lg) { $notes += (($lg.Substring(0, 1).ToUpper() + $lg.Substring(1)) + '.') } } catch {}
        if (-not $notes.Count) { return $null }
        return ($notes -join ' ')
    }

    # Answers "it runs but I cannot see it" with facts - missing only from the console means press F5.
    function Get-TaskVisibility {
        $full = (Get-TaskFolderPath $script:TaskFolder).TrimEnd('\') + '\' + $script:TaskName
        $r = [ordered]@{ Com = $false; Schtasks = $false; Xml = $false; Tree = $false; Tasks = $false; Guid = $null }
        try { if (Get-OwnSystemTask) { $r.Com = $true } } catch {}
        $old = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $null = & schtasks.exe /query /tn $full 2>&1
            $r.Schtasks = ($LASTEXITCODE -eq 0)
        }
        catch {} finally { $ErrorActionPreference = $old }
        try { $r.Xml = Test-Path -LiteralPath (Join-Path $script:TaskDiskRoot $full.TrimStart('\')) } catch {}
        try {
            $tc = $script:TaskCacheRoot
            $tp = Join-Path $tc ('Tree' + $full)
            if (Test-Path -LiteralPath $tp) {
                $r.Tree = $true
                $id = (Get-ItemProperty -LiteralPath $tp -Name Id -ErrorAction SilentlyContinue).Id
                if ($id) { $r.Guid = $id; $r.Tasks = Test-Path -LiteralPath (Join-Path $tc ('Tasks\' + $id)) }
            }
        }
        catch {}
        return [pscustomobject]$r
    }

    function Get-SystemTaskReport {
        param([int]$SelfDeleteMinutes = 60)
        $out = New-Object System.Collections.Generic.List[string]
        $out.Add("=== HOW THIS TOOL REACHES NT AUTHORITY\SYSTEM ===")
        $out.Add("No PsExec is involved. Choosing the SYSTEM context registers a scheduled task,")
        $out.Add("starts it on demand, reads its output, then leaves it registered so you can")
        $out.Add("inspect it here.")
        $out.Add("")
        $out.Add("Location         : Task Scheduler Library (root - no subfolder is created)")
        $out.Add(("Task name        : {0}" -f $script:TaskName))
        $out.Add("Run as           : S-1-5-18  (NT AUTHORITY\SYSTEM)")
        $out.Add("Logon type       : ServiceAccount      Run level: Highest")
        $out.Add(("Trigger          : one DISABLED trigger, valid from registration for {0} minutes" -f $SelfDeleteMinutes))
        $out.Add("                   It can never fire - it exists only to give the task an expiry,")
        $out.Add("                   which is what makes Windows delete the task by itself.")
        $out.Add("")
        $out.Add("=== HOW IT IS CLEANED UP ===")
        $out.Add("  1. Normally      - deleted when you close this tool.")
        $out.Add("  2. Killed/crash  - deleted by the next launch of this tool (startup sweep).")
        $out.Add(("  3. Neither       - Task Scheduler deletes it itself once the trigger expires" ))
        $out.Add(("                     ({0} minutes after the last SYSTEM test), via" -f $SelfDeleteMinutes))
        $out.Add("                     DeleteExpiredTaskAfter=PT0S. Survives reboots.")
        $out.Add("")
        $out.Add("  Deletion is guarded: this tool only removes a task in the folder above,")
        $out.Add(("  with that exact name, whose description contains the marker {0}." -f $script:TaskMarker))
        $out.Add("  Anything else in Task Scheduler is never touched.")
        $out.Add("")
        $t = Get-OwnSystemTask
        if ($t) {
            $st = Get-SystemTaskState -Trusted
            $out.Add("Currently registered: YES")
            $out.Add(("  State          : {0}" -f $(if ($st) { $st.StateName } else { 'unknown' })))
            $def = $t.Definition
            foreach ($a in $def.Actions) {
                $out.Add(("  Executable     : {0}" -f $a.Path))
                $out.Add(("  Arguments      : {0}" -f $a.Arguments))
            }
            $out.Add(("  Principal      : {0} (logonType={1}, runLevel={2})" -f $def.Principal.UserId, $def.Principal.LogonType, $def.Principal.RunLevel))
            foreach ($tr in $def.Triggers) {
                $out.Add(("  Trigger        : enabled={0}  expires={1}" -f $tr.Enabled, $tr.EndBoundary))
            }
            $out.Add(("  DeleteExpiredTaskAfter: {0}" -f $def.Settings.DeleteExpiredTaskAfter))
            if ($st) {
                $out.Add(("  Last run time  : {0}" -f $(if ($st.LastRunTime) { $st.LastRunTime } else { 'never' })))
                $out.Add(("  Last result    : {0}" -f (ConvertFrom-TaskResult $st.LastTaskResult)))
            }
            $out.Add("")
            $v = Get-TaskVisibility
            $yn = { param($b) if ($b) { 'yes' } else { 'NO' } }
            $out.Add("  Where Windows has it recorded:")
            $out.Add(("    Task Scheduler service : {0}" -f (& $yn $v.Com)))
            $out.Add(("    schtasks /query        : {0}" -f (& $yn $v.Schtasks)))
            $out.Add(("    Task file on disk      : {0}" -f (& $yn $v.Xml)))
            $out.Add(("    TaskCache\Tree key     : {0}" -f (& $yn $v.Tree)))
            $out.Add(("    TaskCache\Tasks key    : {0}{1}" -f (& $yn $v.Tasks), $(if ($v.Guid) { "  $($v.Guid)" } else { '' })))
            if ($v.Com -and $v.Schtasks) {
                $out.Add("")
                $out.Add("  The task is fully registered and the scheduler can enumerate it. If the Task")
                $out.Add("  Scheduler console is not showing it, that is the console, not the task: it does")
                $out.Add("  not refresh on its own. Select Task Scheduler Library and press F5. To confirm")
                $out.Add("  it from a prompt without the console at all:")
                $out.Add(('    schtasks /query /tn "\{0}" /v /fo list' -f $script:TaskName))
            }
            elseif ($v.Xml -or $v.Tree) {
                $out.Add("")
                $out.Add("  This is a half-written registration: it exists on disk or in the registry but")
                $out.Add("  the scheduler cannot enumerate it, which is exactly why it shows in Explorer")
                $out.Add("  and not in the console. Running a SYSTEM test clears both halves and rebuilds it.")
            }
            $out.Add("")
            $out.Add("  NOTE: the parameter file the task points at is DPAPI-encrypted (machine")
            $out.Add("  scope), readable only by SYSTEM and Administrators, and shredded straight")
            $out.Add("  after each run - so a proxy password is never left on disk. Because of")
            $out.Add("  that, starting the task by hand from Task Scheduler produces no results;")
            $out.Add("  use the buttons in this tool instead.")
        }
        else {
            $out.Add("Currently registered: NO")
            $v = Get-TaskVisibility
            if ($v.Xml -or $v.Tree) {
                $out.Add("")
                $out.Add("  BUT a broken registration is still on this machine:")
                $out.Add(("    Task file on disk      : {0}" -f $(if ($v.Xml) { 'yes' } else { 'no' })))
                $out.Add(("    TaskCache\Tree key     : {0}" -f $(if ($v.Tree) { 'yes' } else { 'no' })))
                $out.Add("  That is what makes a task show in Explorer or the registry and stay invisible")
                $out.Add("  in the Task Scheduler console. Run any SYSTEM test and it is cleared and rebuilt")
                $out.Add("  automatically - it is also swept on every launch of this tool, when elevated.")
                $out.Add("")
            }
            $out.Add("  Switch the context to SYSTEM and run any test - the task appears immediately.")
        }
        return $out
    }
}

. $PNT_Functions
$script:PNT_FunctionsText = $PNT_Functions.ToString()

if ($SystemTest) {
    # Nothing may throw out of here without writing $OutFile - the parent has no other channel.
    $ErrorActionPreference = 'Continue'
    $lines = New-Object System.Collections.Generic.List[string]

    # Called at every stage, so a hard failure part-way still leaves the parent something to show.
    $flush = {
        if ($OutFile) { try { $lines | Set-Content -Path $OutFile -Encoding UTF8 -ErrorAction SilentlyContinue } catch {} }
    }

    $lines.Add("############ SYSTEM CONTEXT TEST ############")
    $lines.Add(("Time      : {0}" -f (Get-Date)))
    try { $lines.Add(("Running as: {0}" -f [System.Security.Principal.WindowsIdentity]::GetCurrent().Name)) }
    catch { $lines.Add("Running as: (identity could not be read)") }
    $lines.Add(("Host      : PowerShell {0} ({1}-bit), session {2}" -f $PSVersionTable.PSVersion,
            $(if ([Environment]::Is64BitProcess) { 64 } else { 32 }),
            $(try { (Get-Process -Id $PID).SessionId } catch { '?' })))
    & $flush

    try {
        $p = if ($ParamFile -and (Test-Path $ParamFile)) { Read-ProtectedParamFile -Path $ParamFile } else { $null }
        if ($ParamFile -and -not $p) {
            $lines.Add("No readable parameter file - this task was started outside the Connection Test tool.")
            $lines.Add("The tool encrypts its parameters and shreds them after each run, so nothing runs here.")
            $lines.Add("  RESULT         : FAIL - the parameter file could not be read.")
            & $flush
            return
        }
        $targets = if ($p -and $p.Targets) { @($p.Targets) } else { @('https://patchmypc.com') }
        $mode = if ($p -and $p.ProxyMode) { $p.ProxyMode } else { 'System' }
        # Only covers a parameter file that arrived without them - runs the useful minimum, not nothing.
        $tests = if ($p -and $p.Tests) { @($p.Tests) }  else { @('ProxyView', 'Http') }
        $maxCh = if ($p -and $p.MaxFetchChars) { [int]$p.MaxFetchChars } else { 524288 }
        $useDc = [bool]($p -and $p.UseDefaultCreds)

        # Resolving the proxy can mean a WPAD probe: slow, and the most likely thing to stall as a service.
        $lines.Add("Resolving the proxy for this account...")
        & $flush
        try {
            $proxy = Get-EffectiveProxy -Mode $mode -PHost $p.PHost -PPort ([int]$p.PPort) -PUser $p.PUser -PPass $p.PPass -UseDefaultCreds $useDc
            $lines[$lines.Count - 1] = ("Proxy mode: {0} -> {1}" -f $mode, $proxy.Desc)
        }
        catch {
            $lines[$lines.Count - 1] = ("Proxy mode: {0} -> ERROR resolving the proxy: {1}" -f $mode, $_.Exception.Message)
            $lines.Add("Continuing with a direct connection so the tests still report something.")
            $proxy = $null
        }
        try { $envOv = Get-ProxyEnvOverrides; if ($envOv.Count) { $lines.Add("Proxy env : " + ($envOv -join '; ')) } } catch {}
        & $flush

        foreach ($t in $targets) {
            $lines.Add(''); $lines.Add("======================================================")
            & $flush
            try {
                (Invoke-RequestedTests -Tests $tests -Url $t -ProxyObj $proxy -ProxyMode $mode -MaxFetchChars $maxCh) |
                ForEach-Object { $lines.Add($_) }
            }
            catch {
                $lines.Add(("=== TESTS FAILED : {0} ===" -f $t))
                $lines.Add(("  ERROR          : {0}" -f $_.Exception.Message))
                $lines.Add(("  Type           : {0}" -f $_.Exception.GetType().Name))
                $lines.Add(("  At             : line {0}" -f $_.InvocationInfo.ScriptLineNumber))
                $lines.Add("  RESULT         : FAIL - the checks could not be completed in the SYSTEM context.")
            }
            & $flush
        }
    }
    catch {
        $lines.Add('')
        $lines.Add("=== SYSTEM CONTEXT TEST FAILED ===")
        $lines.Add(("  ERROR          : {0}" -f $_.Exception.Message))
        $lines.Add(("  Type           : {0}" -f $_.Exception.GetType().Name))
        $lines.Add(("  At             : line {0}" -f $_.InvocationInfo.ScriptLineNumber))
        $lines.Add(("  Command        : {0}" -f $_.InvocationInfo.Line.Trim()))
        $lines.Add("  RESULT         : FAIL - the SYSTEM run stopped before it finished.")
    }
    finally {
        # Written last, so the parent can tell "finished" from "still going" without the scheduler.
        $lines.Add($script:SysEndMarker)
        & $flush
        if (-not $OutFile) { $lines | Where-Object { $_ -ne $script:SysEndMarker } | ForEach-Object { Write-Output $_ } }
    }
    return
}

if ($NoGui) { return }

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Must be set before the first window handle exists, or Windows bitmap-stretches everything.
if (-not ('CtShell' -as [type])) {
    try {
        Add-Type -Namespace '' -Name 'CtShell' -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool SetProcessDpiAwarenessContext(System.IntPtr value);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool SetProcessDPIAware();
[System.Runtime.InteropServices.DllImport("dwmapi.dll")]
public static extern int DwmSetWindowAttribute(System.IntPtr hwnd, int attr, ref int value, int size);
[System.Runtime.InteropServices.DllImport("uxtheme.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
public static extern int SetWindowTheme(System.IntPtr hwnd, string sub, string idlist);
// Undocumented uxtheme ordinals. 135 is SetPreferredAppMode on 1903+ and AllowDarkModeForApp
// on 1809; both take 1/2 as "use dark", so one call covers each. 133 opts a single window in.
[System.Runtime.InteropServices.DllImport("uxtheme.dll", EntryPoint = "#135")]
private static extern int SetPreferredAppMode(int mode);
[System.Runtime.InteropServices.DllImport("uxtheme.dll", EntryPoint = "#133")]
private static extern bool AllowDarkModeForWindow(System.IntPtr hwnd, bool allow);
// 104 republishes the immersive colour policy. Without it ShouldAppsUseDarkMode keeps
// answering with the value cached before SetPreferredAppMode ran, and the common controls
// carry on drawing light. 136 does the same for menus.
[System.Runtime.InteropServices.DllImport("uxtheme.dll", EntryPoint = "#104")]
private static extern void RefreshImmersiveColorPolicyState();
[System.Runtime.InteropServices.DllImport("uxtheme.dll", EntryPoint = "#136")]
private static extern void FlushMenuThemes();
[System.Runtime.InteropServices.DllImport("uxtheme.dll", EntryPoint = "#132")]
private static extern bool ShouldAppsUseDarkMode();
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Auto)]
private static extern System.IntPtr SendMessage(System.IntPtr hwnd, int msg, System.IntPtr wp, System.IntPtr lp);
[System.Runtime.InteropServices.DllImport("user32.dll")]
private static extern bool SetWindowPos(System.IntPtr hwnd, System.IntPtr after, int x, int y, int cx, int cy, uint flags);
// SCROLLINFO is read through raw memory rather than a declared struct: Add-Type
// -MemberDefinition can only add members to a generated class, it cannot declare types.
[System.Runtime.InteropServices.DllImport("user32.dll")]
private static extern bool GetScrollInfo(System.IntPtr hwnd, int bar, System.IntPtr si);

// { nMin, nMax, nPage, nPos } for one of a window's own scrollbars, or null if it has none.
// SB_VERT = 1, SB_HORZ = 0. SIF_ALL = 0x17.
public static int[] ScrollInfo(System.IntPtr hwnd, bool vertical) {
    if (hwnd == System.IntPtr.Zero) return null;
    System.IntPtr p = System.Runtime.InteropServices.Marshal.AllocHGlobal(28);
    try {
        System.Runtime.InteropServices.Marshal.WriteInt32(p, 0, 28);
        System.Runtime.InteropServices.Marshal.WriteInt32(p, 4, 0x17);
        if (!GetScrollInfo(hwnd, vertical ? 1 : 0, p)) return null;
        return new int[] {
            System.Runtime.InteropServices.Marshal.ReadInt32(p,  8),
            System.Runtime.InteropServices.Marshal.ReadInt32(p, 12),
            System.Runtime.InteropServices.Marshal.ReadInt32(p, 16),
            System.Runtime.InteropServices.Marshal.ReadInt32(p, 20)
        };
    } catch { return null; }
    finally { System.Runtime.InteropServices.Marshal.FreeHGlobal(p); }
}

// Scrolls a window to an absolute position the way its own scrollbar would. THUMBTRACK
// moves it, THUMBPOSITION commits, ENDSCROLL lets the control tidy up; edit controls want
// all three or they snap back on the next repaint.
public static void ScrollTo(System.IntPtr hwnd, bool vertical, int pos) {
    if (hwnd == System.IntPtr.Zero) return;
    int msg = vertical ? 0x0115 : 0x0114;
    if (pos < 0) pos = 0;
    if (pos > 0xFFFF) pos = 0xFFFF;             // WM_*SCROLL carries the position in 16 bits
    try {
        SendMessage(hwnd, msg, new System.IntPtr((pos << 16) | 5), System.IntPtr.Zero);
        SendMessage(hwnd, msg, new System.IntPtr((pos << 16) | 4), System.IntPtr.Zero);
        SendMessage(hwnd, msg, new System.IntPtr(8), System.IntPtr.Zero);
    } catch {}
}

public static void EnableDpi() {
    // -4 = PER_MONITOR_AWARE_V2 (Windows 10 1703+). -3 = PER_MONITOR_AWARE.
    try { if (SetProcessDpiAwarenessContext(new System.IntPtr(-4))) return; } catch {}
    try { if (SetProcessDpiAwarenessContext(new System.IntPtr(-3))) return; } catch {}
    try { SetProcessDPIAware(); } catch {}
}

// Opts the process into dark mode so the COMMON CONTROLS follow - combo box dropdowns,
// tooltips and the like. It does NOT reach the scrollbars of an Edit, RichEdit or
// AutoScroll panel: those were measured on Windows 11 with every documented and
// undocumented switch below turned on and stayed white, which is why this tool draws its
// own (see New-ThemedScrollBar). 2 = ForceDark. Harmless before Windows 10 1809.
public static bool DarkAppMode() {
    bool ok = false;
    try { SetPreferredAppMode(2); ok = true; } catch {}
    try { RefreshImmersiveColorPolicyState(); } catch {}
    try { FlushMenuThemes(); } catch {}
    return ok;
}

// True once the process is genuinely in dark mode - the check that says whether the
// scrollbars will actually come back dark, rather than whether the call was accepted.
public static bool IsDarkMode() {
    try { return ShouldAppsUseDarkMode(); } catch {}
    return false;
}

// Applies the dark scrollbar theme to one control's window. Returns the SetWindowTheme
// HRESULT: 0 = applied. Anything else means the OS declined and the light bar stays.
public static int DarkControl(System.IntPtr hwnd) {
    if (hwnd == System.IntPtr.Zero) return -1;
    int hr = -2;
    try { AllowDarkModeForWindow(hwnd, true); } catch {}
    try { hr = SetWindowTheme(hwnd, "DarkMode_Explorer", null); } catch {}
    // SetWindowTheme alone only changes what the control WOULD draw. The non-client area is
    // not repainted until the control is told the theme moved, and a frame-changed
    // SetWindowPos is what makes it recalculate and redraw the scrollbars.
    try { SendMessage(hwnd, 0x031A, System.IntPtr.Zero, System.IntPtr.Zero); } catch {}   // WM_THEMECHANGED
    // SWP_NOMOVE|NOSIZE|NOZORDER|NOACTIVATE|FRAMECHANGED
    try { SetWindowPos(hwnd, System.IntPtr.Zero, 0, 0, 0, 0, 0x0002 | 0x0001 | 0x0004 | 0x0010 | 0x0020); } catch {}
    return hr;
}

// DWMWA_USE_IMMERSIVE_DARK_MODE. 20 on Windows 10 1903+ and Windows 11; 19 on 1809.
// A light title bar above a dark window is the other instant "unfinished" tell.
public static void DarkTitleBar(System.IntPtr hwnd) {
    int on = 1;
    try { if (DwmSetWindowAttribute(hwnd, 20, ref on, 4) == 0) return; } catch {}
    try { DwmSetWindowAttribute(hwnd, 19, ref on, 4); } catch {}
}
'@ -ErrorAction Stop
    }
    catch {}
}
try { [CtShell]::EnableDpi() } catch {}
try { $null = [CtShell]::DarkAppMode() } catch {}

# Measured NOT to reach a RichTextBox, TextBox or AutoScroll panel - those get New-ThemedScrollBar.
function Set-DarkScrollbars {
    param($Control)
    if (-not ('CtShell' -as [type]) -or -not $Control) { return }
    try { if ($Control.IsHandleCreated) { $null = [CtShell]::DarkControl($Control.Handle) } } catch {}
    try { foreach ($c in $Control.Controls) { Set-DarkScrollbars $c } } catch {}
}

# Again on show: Windows repaints the frame when first displayed, undoing an early call.
function Set-DarkFrame {
    param($Form)
    if (-not ('CtShell' -as [type])) { return }
    $apply = { try { [CtShell]::DarkTitleBar($this.Handle) } catch {} }
    try { if ($Form.IsHandleCreated) { [CtShell]::DarkTitleBar($Form.Handle) } } catch {}
    $Form.Add_HandleCreated($apply)
    $Form.Add_Shown($apply)
}

[System.Windows.Forms.Application]::EnableVisualStyles()
try { [System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false) } catch {}

# Win32 sends the wheel to the FOCUSED window - with the Target combo focused that CHANGES THE TARGET.
if (-not ('CtWheelFilter' -as [type])) {
    try {
        Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public class CtWheelFilter : IMessageFilter {
    [StructLayout(LayoutKind.Sequential)] private struct POINT { public int X; public int Y; }
    [DllImport("user32.dll")] private static extern IntPtr WindowFromPoint(POINT p);
    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    private static extern IntPtr SendMessage(IntPtr hwnd, int msg, IntPtr wp, IntPtr lp);

    private const int WM_MOUSEWHEEL  = 0x020A;
    private const int WM_MOUSEHWHEEL = 0x020E;

    public bool PreFilterMessage(ref Message m) {
        if (m.Msg != WM_MOUSEWHEEL && m.Msg != WM_MOUSEHWHEEL) return false;
        try {
            // lParam carries SCREEN coordinates for the wheel messages, which is exactly
            // what WindowFromPoint wants. The low and high words are signed - a pointer on
            // a monitor left of the primary one has a negative X.
            long lp = m.LParam.ToInt64();
            POINT p;
            p.X = (short)(ushort)(lp & 0xFFFF);
            p.Y = (short)(ushort)((lp >> 16) & 0xFFFF);

            IntPtr h = WindowFromPoint(p);
            if (h == IntPtr.Zero || h == m.HWnd) return false;

            // FromChildHandle walks up from an inner window - a combo box's edit field, the
            // browser control's own document window - to the WinForms control that owns it.
            // Null means the pointer is over something that is not ours: leave it alone.
            Control owner = Control.FromHandle(h);
            Control c     = Control.FromChildHandle(h);
            if (c == null) return false;

            ComboBox cb = c as ComboBox;
            if (cb != null && !cb.DroppedDown) return true;   // eaten, never acted on

            // A window with no WinForms control of its own is a native child that already
            // knows how to scroll itself - the browser's document window is the one that
            // matters here. Hand it the message untouched.
            if (owner == null) {
                SendMessage(h, m.Msg, m.WParam, m.LParam);
                return true;
            }

            // Otherwise walk up to the nearest thing that can actually scroll. The pointer is
            // usually over a check box or a label, and sending the wheel to one of those
            // would simply swallow it - which is indistinguishable from the bug being fixed.
            Control t = c;
            while (t != null) {
                string tag = t.Tag as string;
                if (tag == "scrollbar") break;              // this tool's own drawn bars
                if (t is TextBoxBase) break;
                if (t is ListControl || t is TreeView || t is ListView || t is DataGridView) break;
                ScrollableControl sc = t as ScrollableControl;
                if (sc != null && sc.AutoScroll) break;
                t = t.Parent;
            }
            // Nothing under the pointer scrolls. The message is still EATEN rather than let
            // through: falling back to default handling would send it to whatever holds the
            // focus, and that is the whole bug - a wheel over a blank part of the window has
            // no business changing the URL under test. Doing nothing is the correct outcome.
            if (t == null) return true;

            SendMessage(t.Handle, m.Msg, m.WParam, m.LParam);
            return true;
        } catch { return false; }
    }
}
'@
    }
    catch {}
}
try {
    if ('CtWheelFilter' -as [type]) {
        $script:WheelFilter = New-Object CtWheelFilter
        [System.Windows.Forms.Application]::AddMessageFilter($script:WheelFilter)
    }
}
catch {}

# Catches anything escaping a handler, which would otherwise show a raw .NET dialog mid-update.
$script:UiErrors = New-Object System.Collections.Generic.List[string]
$script:InErrorNet = $false

# Identifies the exact file running, so a report is never attributed to the wrong build.
$script:BuildStamp = 'unknown build'
$script:SelfLines = @()
try {
    if ($script:SelfPath -and (Test-Path -LiteralPath $script:SelfPath)) {
        $script:SelfLines = [System.IO.File]::ReadAllLines($script:SelfPath)
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            $h = $sha.ComputeHash([System.IO.File]::ReadAllBytes($script:SelfPath))
            $script:BuildStamp = ('{0} lines, sha256 {1}' -f $script:SelfLines.Count,
                (($h[0..3] | ForEach-Object { $_.ToString('x2') }) -join ''))
        }
        finally { $sha.Dispose() }
    }
}
catch {}

function Write-UnhandledError {
    param($Ex, [string]$Where = 'the window')
    # Re-entry would be fatal: reporting an error must never be able to raise one.
    if ($script:InErrorNet) { return }
    $script:InErrorNet = $true
    try {
        $type = 'Exception'; $msg = 'unknown error'; $ln = 0; $stmt = ''; $file = ''; $trace = ''
        try { if ($Ex) { $type = $Ex.GetType().Name; $msg = [string]$Ex.Message } } catch {}
        try {
            $rec = $null
            if ($Ex -is [System.Management.Automation.IContainsErrorRecord]) { $rec = $Ex.ErrorRecord }
            if ($rec -and $rec.InvocationInfo) {
                $ln = [int]$rec.InvocationInfo.ScriptLineNumber
                $stmt = ("$($rec.InvocationInfo.Line)").Trim()
                $file = [string]$rec.InvocationInfo.ScriptName
            }
            if ($rec) { $trace = ("$($rec.ScriptStackTrace)").Trim() }
        }
        catch {}

        $head = if ($ln) { '  [ui error] {0} in {1} at line {2}: {3}' -f $type, $Where, $ln, $msg }
        else { '  [ui error] {0} in {1}: {2}' -f $type, $Where, $msg }
        $out = @($head)
        if ($stmt) { $out += ('              >> {0}' -f $stmt) }

        # A line number is only meaningful against the source it compiled from, so cross-check the file.
        try {
            $srcName = if ($file) { $file } else { '(compiled in memory, not from a file)' }
            $out += ('              source: {0}' -f $srcName)
            if ($ln -gt 0 -and $script:SelfLines.Count -ge $ln) {
                $onDisk = ("$($script:SelfLines[$ln - 1])").Trim()
                if ($stmt -and $onDisk -ne $stmt) {
                    $out += ('              NOTE: line {0} of {1} is actually:' -f $ln, (Split-Path $script:SelfPath -Leaf))
                    $out += ('                    {0}' -f $onDisk)
                    $out += '                    The two do not match, so the fault is NOT at that line of this'
                    $out += '                    file - it came from a script block built at run time, or from a'
                    $out += '                    different copy of the tool. Check the build stamp below.'
                }
            }
            $out += ('              build : {0}' -f $script:BuildStamp)
        }
        catch {}
        if ($trace) {
            $out += '              call stack:'
            foreach ($t in @($trace -split "`r?`n" | Select-Object -First 6)) {
                if ("$t".Trim()) { $out += ('                {0}' -f "$t".Trim()) }
            }
        }
        $out += '              The tool carried on. Please include this LOG tab if you report it.'
        try { $script:UiErrors.Add($head) } catch {}

        # Straight to the control: Append-ToBox is defined later and could be the thing that failed.
        try {
            if ($outBox -and $outBox.IsHandleCreated) {
                $outBox.SelectionStart = $outBox.TextLength
                $outBox.SelectionLength = 0
                $outBox.SelectionColor = $script:Pal.Error
                $outBox.AppendText(($out -join "`r`n") + "`r`n")
                $outBox.SelectionColor = $script:Pal.OutText
                $outBox.SelectionStart = $outBox.TextLength
                $outBox.ScrollToCaret()
            }
        }
        catch {}
    }
    catch {
    }
    finally { $script:InErrorNet = $false }
}

# Automatic mode already routes here - this replaces the dialog rather than adding to it.
[System.Windows.Forms.Application]::add_ThreadException({
        param($s, $e)
        try { Write-UnhandledError $e.Exception 'the window' } catch {}
    })
try {
    [System.Windows.Forms.Application]::SetUnhandledExceptionMode(
        [System.Windows.Forms.UnhandledExceptionMode]::CatchException)
}
catch {}
# Worker runspaces run off the UI thread, where ThreadException never fires.
try {
    [System.AppDomain]::CurrentDomain.add_UnhandledException({
            param($s, $e)
            try { Write-UnhandledError $e.ExceptionObject 'a background thread' } catch {}
        })
}
catch {}

$script:Pal = @{
    Base900  = [System.Drawing.Color]::FromArgb(21, 21, 33)
    Base800  = [System.Drawing.Color]::FromArgb(30, 30, 45)
    Base700  = [System.Drawing.Color]::FromArgb(42, 42, 60)
    Base600  = [System.Drawing.Color]::FromArgb(58, 58, 80)
    Accent   = [System.Drawing.Color]::FromArgb(27, 188, 155)
    AccentHi = [System.Drawing.Color]::FromArgb(17, 164, 134)
    Blue     = [System.Drawing.Color]::FromArgb(4, 144, 218)
    BlueHi   = [System.Drawing.Color]::FromArgb(0, 127, 194)
    Text     = [System.Drawing.Color]::White
    TextDim  = [System.Drawing.Color]::FromArgb(167, 175, 186)
    OutText  = [System.Drawing.Color]::FromArgb(224, 226, 235)
    Border   = [System.Drawing.Color]::FromArgb(72, 72, 100)
    Line     = [System.Drawing.Color]::FromArgb(56, 56, 80)
    Success  = [System.Drawing.Color]::FromArgb(80, 205, 137)
    Warning  = [System.Drawing.Color]::FromArgb(255, 199, 0)
    Error    = [System.Drawing.Color]::FromArgb(241, 65, 108)
}

$script:InstalledFonts = (New-Object System.Drawing.Text.InstalledFontCollection).Families | ForEach-Object { $_.Name }
function Resolve-Font {
    param([string[]]$Names, [single]$Size, [System.Drawing.FontStyle]$Style = 'Regular')
    $fam = $Names | Where-Object { $script:InstalledFonts -contains $_ } | Select-Object -First 1
    if (-not $fam) { $fam = 'Segoe UI' }
    New-Object System.Drawing.Font($fam, $Size, $Style)
}
# Type scale - every control uses one of these, nothing else defines a Font.
$uiNames = @('Segoe UI Variable Text', 'Segoe UI')
$monoNames = @('Cascadia Mono', 'Cascadia Code', 'Consolas')
$script:UiFont = Resolve-Font -Names $uiNames   -Size 10
$script:UiFontBold = Resolve-Font -Names $uiNames   -Size 10 -Style Bold
$script:UiFontH = Resolve-Font -Names @('Segoe UI Variable Display', 'Segoe UI') -Size 16 -Style Bold
$script:UiFontSub = Resolve-Font -Names $uiNames   -Size 9
$script:UiFontSec = Resolve-Font -Names $uiNames   -Size 9  -Style Bold
$script:MonoFont = Resolve-Font -Names $monoNames -Size 10

function Style-Button {
    param($b, [string]$Kind = 'secondary')
    $b.FlatStyle = 'Flat'
    $b.FlatAppearance.BorderSize = 0
    $b.ForeColor = [System.Drawing.Color]::White
    $b.Font = $script:UiFontBold
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    $b.UseCompatibleTextRendering = $false
    switch ($Kind) {
        'primary' { $back = $script:Pal.Accent; $hov = $script:Pal.AccentHi }
        'tertiary' { $back = $script:Pal.Base700; $hov = $script:Pal.Base600 }
        default { $back = $script:Pal.Blue; $hov = $script:Pal.BlueHi }
    }
    $b.BackColor = $back
    $b.FlatAppearance.MouseOverBackColor = $hov
    $b.FlatAppearance.MouseDownBackColor = $hov
    # The owner-drawn button paints from these; FlatAppearance only matters on the fallback path.
    if ($b.PSObject.Properties['NormalColor']) {
        $b.NormalColor = $back
        $b.HoverColor = $hov
        $b.Invalidate()
    }
    if ($b.PSObject.Properties['CornerRadius']) {
        $b.Invalidate()
    }
    else {
        Set-RoundedRegion $b 8
        # Tag is NOT free here - the test buttons carry their definition in it.
        if (-not $script:RoundedBtns.Contains($b)) {
            [void]$script:RoundedBtns.Add($b)
            $b.Add_Resize({ Set-RoundedRegion $this 8 })
            # A stock Flat button paints a light focus ring no property can change - repaint the face over it.
            $b.Add_MouseEnter($script:BtnFaceEnter)
            $b.Add_MouseLeave($script:BtnFaceLeave)
            $b.Add_MouseDown($script:BtnFaceDown)
            $b.Add_MouseUp($script:BtnFaceUp)
            $b.Add_GotFocus($script:BtnFaceRedraw)
            $b.Add_LostFocus($script:BtnFaceRedraw)
            $b.Add_EnabledChanged($script:BtnFaceRedraw)
            $b.Add_Paint($script:BtnFacePaint)
        }
        $b | Add-Member -NotePropertyName BtnFace  -NotePropertyValue $back -Force
        $b | Add-Member -NotePropertyName BtnHover -NotePropertyValue $hov  -Force
        $b.Invalidate()
    }
}

$script:BtnFaceShift = {
    param($c, $d)
    $f = { param($v) if ($v -lt 0) { 0 } elseif ($v -gt 255) { 255 } else { [int]$v } }
    [System.Drawing.Color]::FromArgb($c.A, (& $f ($c.R + $d)), (& $f ($c.G + $d)), (& $f ($c.B + $d)))
}
$script:BtnFaceEnter = { try { $this | Add-Member -NotePropertyName BtnHot  -NotePropertyValue $true  -Force; $this.Invalidate() } catch {} }
$script:BtnFaceLeave = { try {
        $this | Add-Member -NotePropertyName BtnHot  -NotePropertyValue $false -Force
        $this | Add-Member -NotePropertyName BtnDown -NotePropertyValue $false -Force; $this.Invalidate() 
    }
    catch {} }
$script:BtnFaceDown = { try { $this | Add-Member -NotePropertyName BtnDown -NotePropertyValue $true  -Force; $this.Invalidate() } catch {} }
$script:BtnFaceUp = { try { $this | Add-Member -NotePropertyName BtnDown -NotePropertyValue $false -Force; $this.Invalidate() } catch {} }
$script:BtnFaceRedraw = { try { $this.Invalidate() } catch {} }
$script:BtnFacePaint = {
    param($s, $e)
    try {
        $face = $s.BtnFace
        if (-not $face) { $face = $s.BackColor }
        if ($s.BtnDown) { $face = & $script:BtnFaceShift ($(if ($s.BtnHover) { $s.BtnHover } else { $face })) -14 }
        elseif ($s.BtnHot) { if ($s.BtnHover) { $face = $s.BtnHover } }
        if (-not $s.Enabled) { $face = & $script:BtnFaceShift $face -28 }
        $g = $e.Graphics
        $br = New-Object System.Drawing.SolidBrush $face
        # The whole client rectangle: the ring sits right at the edge and the Region clips this back.
        $g.FillRectangle($br, $s.ClientRectangle)
        $br.Dispose()
        $fg = if ($s.Enabled) { $s.ForeColor } else { & $script:BtnFaceShift $s.ForeColor -70 }
        [System.Windows.Forms.TextRenderer]::DrawText($g, $s.Text, $s.Font, $s.ClientRectangle, $fg,
            ([System.Windows.Forms.TextFormatFlags]'HorizontalCenter,VerticalCenter,SingleLine,EndEllipsis,HidePrefix'))
    }
    catch {}
}
$script:RoundedBtns = New-Object 'System.Collections.Generic.HashSet[object]'
$script:OptionCtls = New-Object 'System.Collections.Generic.HashSet[object]'

# WinForms paints the glyph in system colours, so the selected state is invisible on dark.
$script:OptionPaint = {
    param($s, $e)
    $g = $e.Graphics
    $isRadio = ($s -is [System.Windows.Forms.RadioButton])

    # Ask the renderer for the glyph size - guessing low leaves a sliver of it poking out.
    $gw = 13
    try {
        $gsz = if ($isRadio) {
            [System.Windows.Forms.RadioButtonRenderer]::GetGlyphSize($g, [System.Windows.Forms.VisualStyles.RadioButtonState]::UncheckedNormal)
        }
        else {
            [System.Windows.Forms.CheckBoxRenderer]::GetGlyphSize($g, [System.Windows.Forms.VisualStyles.CheckBoxState]::UncheckedNormal)
        }
        if ($gsz.Width -gt 0) { $gw = $gsz.Width }
    }
    catch {}
    $cover = $gw + 4

    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::None
    $bg = New-Object System.Drawing.SolidBrush $s.BackColor
    $g.FillRectangle($bg, -1, -1, ($cover + 1), ($s.ClientSize.Height + 2))
    $bg.Dispose()
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias

    $box = $gw - 1
    $y = [int](($s.ClientSize.Height - $box) / 2)
    $on = $s.Checked
    $line = if ($on) { $script:Pal.Accent } else { $script:Pal.TextDim }
    $pen = New-Object System.Drawing.Pen($line, [single]1.5)
    if ($isRadio) {
        $g.DrawEllipse($pen, 1, $y, ($box - 1), ($box - 1))
        if ($on) {
            $inset = [int][math]::Max(3, [math]::Round($box / 4))
            $br = New-Object System.Drawing.SolidBrush $script:Pal.Accent
            $g.FillEllipse($br, (1 + $inset), ($y + $inset), ($box - 1 - 2 * $inset), ($box - 1 - 2 * $inset))
            $br.Dispose()
        }
    }
    else {
        $rect = New-Object System.Drawing.Rectangle(1, $y, ($box - 1), ($box - 1))
        if ($on) {
            $br = New-Object System.Drawing.SolidBrush $script:Pal.Accent
            $g.FillRectangle($br, $rect)
            $br.Dispose()
            $tick = New-Object System.Drawing.Pen([System.Drawing.Color]::White, [single]2)
            # Must be a strongly-typed Point[]; PowerShell's default Object[] will not bind.
            $pts = [System.Drawing.Point[]]@(
                (New-Object System.Drawing.Point((1 + [int]($box * 0.25)), ($y + [int]($box * 0.5)))),
                (New-Object System.Drawing.Point((1 + [int]($box * 0.42)), ($y + [int]($box * 0.68)))),
                (New-Object System.Drawing.Point((1 + [int]($box * 0.75)), ($y + [int]($box * 0.28)))))
            $g.DrawLines($tick, $pts)
            $tick.Dispose()
        }
        $g.DrawRectangle($pen, $rect)
    }
    $pen.Dispose()
}

function Style-Option {
    param($c)
    $c.FlatStyle = 'Flat'
    $c.ForeColor = $script:Pal.Text
    $c.Cursor = [System.Windows.Forms.Cursors]::Hand
    $c.UseCompatibleTextRendering = $false
    if (-not $script:OptionCtls.Contains($c)) {
        [void]$script:OptionCtls.Add($c)
        $c.Add_Paint($script:OptionPaint)
        $c.Add_CheckedChanged({ $this.Invalidate() })
    }
}

function Set-RoundedRegion {
    param($Ctl, [int]$Radius = 8)
    if ($Ctl.Width -le 0 -or $Ctl.Height -le 0) { return }
    $r = [Math]::Min($Radius, [Math]::Floor([Math]::Min($Ctl.Width, $Ctl.Height) / 2))
    if ($r -lt 2) { return }
    $d = $r * 2
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $p.AddArc(0, 0, $d, $d, 180, 90)
    $p.AddArc($Ctl.Width - $d - 1, 0, $d, $d, 270, 90)
    $p.AddArc($Ctl.Width - $d - 1, $Ctl.Height - $d - 1, $d, $d, 0, 90)
    $p.AddArc(0, $Ctl.Height - $d - 1, $d, $d, 90, 90)
    $p.CloseFigure()
    $old = $Ctl.Region
    $Ctl.Region = New-Object System.Drawing.Region($p)
    if ($old) { try { $old.Dispose() } catch {} }
    $p.Dispose()
}

# Draws its own face and caption so WinForms' light focus ring never runs. Falls back to Button.
$script:BtnType = [System.Windows.Forms.Button]
$script:BtnTypeError = $null
try {
    if (-not ('PmpcFlatButton' -as [type])) {
        # Touch the types first so their implementation assemblies appear in the list below.
        $null = [System.Drawing.SolidBrush], [System.Windows.Forms.TextRenderer], [System.Drawing.Color]
        $null = New-Object System.Drawing.Bitmap 1, 1
        $refs = @([AppDomain]::CurrentDomain.GetAssemblies() |
            Where-Object { -not $_.IsDynamic -and $_.Location } |
            ForEach-Object { $_.Location } | Sort-Object -Unique)
        Add-Type -ReferencedAssemblies $refs -WarningAction SilentlyContinue -ErrorAction Stop -TypeDefinition @'
using System;
using System.Drawing;
using System.Windows.Forms;

public class PmpcFlatButton : Button {
    public Color NormalColor = Color.Empty;
    public Color HoverColor  = Color.Empty;
    public Color PressColor  = Color.Empty;
    public int   CornerRadius = 8;
    private bool _hover;
    private bool _down;

    public PmpcFlatButton() {
        SetStyle(ControlStyles.UserPaint
               | ControlStyles.AllPaintingInWmPaint
               | ControlStyles.OptimizedDoubleBuffer
               | ControlStyles.ResizeRedraw, true);
        FlatStyle = FlatStyle.Flat;
        FlatAppearance.BorderSize = 0;
    }

    protected override bool ShowFocusCues { get { return false; } }

    protected override void OnMouseEnter(EventArgs e) { _hover = true; Invalidate(); base.OnMouseEnter(e); }
    protected override void OnMouseLeave(EventArgs e) { _hover = false; _down = false; Invalidate(); base.OnMouseLeave(e); }
    protected override void OnMouseDown(MouseEventArgs e) {
        if (e.Button == MouseButtons.Left) { _down = true; Invalidate(); }
        base.OnMouseDown(e);
    }
    protected override void OnMouseUp(MouseEventArgs e) {
        if (_down) { _down = false; Invalidate(); }
        base.OnMouseUp(e);
    }
    protected override void OnEnabledChanged(EventArgs e) { Invalidate(); base.OnEnabledChanged(e); }

    private static int Clamp(int v) { return v < 0 ? 0 : (v > 255 ? 255 : v); }
    private static Color Shift(Color c, int d) {
        return Color.FromArgb(c.A, Clamp(c.R + d), Clamp(c.G + d), Clamp(c.B + d));
    }

    private Color FaceColor() {
        Color n = NormalColor.IsEmpty ? BackColor : NormalColor;
        Color h = HoverColor.IsEmpty ? Shift(n, 16) : HoverColor;
        if (!Enabled) { return Shift(n, -28); }
        // Pressed is derived from the hover face, not the resting one, so it always reads as
        // one step further in whatever direction hover moved - the palette's hover shade is
        // darker than the resting shade, so shifting the resting colour would invert that.
        if (_down)  { return PressColor.IsEmpty ? Shift(h, -14) : PressColor; }
        if (_hover) { return h; }
        return n;
    }

    protected override void OnPaint(PaintEventArgs e) {
        // Clipping the control to a rounded Region hard-clips the pixels, so the corners come
        // out jagged - aliased corners are one of the things that read as cheap. Painting the
        // rounded path here with antialiasing gives clean edges instead. The parent colour is
        // filled first so the area outside the curve blends with the surface behind it.
        Color face = FaceColor();
        Graphics g = e.Graphics;
        Color behind = (Parent != null) ? Parent.BackColor : BackColor;
        using (SolidBrush bg = new SolidBrush(behind)) { g.FillRectangle(bg, ClientRectangle); }

        int r = CornerRadius;
        int max = Math.Min(Width, Height) / 2;
        if (r > max) { r = max; }
        System.Drawing.Drawing2D.SmoothingMode old = g.SmoothingMode;
        g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
        if (r >= 2) {
            int d = r * 2;
            using (System.Drawing.Drawing2D.GraphicsPath p = new System.Drawing.Drawing2D.GraphicsPath()) {
                p.AddArc(0, 0, d, d, 180, 90);
                p.AddArc(Width - d - 1, 0, d, d, 270, 90);
                p.AddArc(Width - d - 1, Height - d - 1, d, d, 0, 90);
                p.AddArc(0, Height - d - 1, d, d, 90, 90);
                p.CloseFigure();
                using (SolidBrush b = new SolidBrush(face)) { g.FillPath(b, p); }
            }
        } else {
            using (SolidBrush b = new SolidBrush(face)) { g.FillRectangle(b, ClientRectangle); }
        }
        g.SmoothingMode = old;
        // HidePrefix keeps "&&" rendering as a literal "&" without an accelerator underline.
        TextFormatFlags fl = TextFormatFlags.HorizontalCenter
                           | TextFormatFlags.VerticalCenter
                           | TextFormatFlags.SingleLine
                           | TextFormatFlags.EndEllipsis
                           | TextFormatFlags.HidePrefix;
        Color fg = Enabled ? ForeColor : Shift(ForeColor, -70);
        TextRenderer.DrawText(e.Graphics, Text, Font, ClientRectangle, fg, fl);
    }
}
'@
    }
    $script:BtnType = [PmpcFlatButton]
}
catch { $script:BtnTypeError = $_.Exception.Message }

function New-ActionButton {
    param([string]$Text, [int]$MinWidth = 88, [int]$Height = 32)
    $b = $script:BtnType::new()
    $b.Text = $Text
    $b.Height = $Height
    $w = [System.Windows.Forms.TextRenderer]::MeasureText($Text, $script:UiFontBold).Width + 32
    $b.Width = [Math]::Max($MinWidth, $w)
    return $b
}

function Set-ButtonRow {
    param($Buttons, [int]$Top, [int]$Left = 2, [int]$Gap = 8)
    $x = $Left
    foreach ($b in $Buttons) {
        $b.Location = New-Object System.Drawing.Point($x, $Top)
        $x += $b.Width + $Gap
    }
    return $x
}

# WinForms only invalidates the newly exposed strip on grow, so a painted border smears.
function Set-PanelRedraw {
    param($Ctl)
    try { $Ctl.Add_Resize({ $this.Invalidate() }) } catch {}
    try {
        $pi = [System.Windows.Forms.Control].GetProperty('DoubleBuffered',
            ([System.Reflection.BindingFlags]'Instance,NonPublic'))
        if ($pi) { $pi.SetValue($Ctl, $true, $null) }
    }
    catch {}
}

# 1px-padded panel whose BackColor reads as a crisp border. Tagged 'frame' for the themer.
function New-Frame {
    param($Child, [string]$Location, [string]$Size, [string]$Anchor = 'Top,Left,Right', [string]$Dock)
    $p = New-Object System.Windows.Forms.Panel
    $p.Tag = 'frame'
    $p.Padding = New-Object System.Windows.Forms.Padding(1)
    $p.BackColor = $script:Pal.Border
    if ($Dock) { $p.Dock = $Dock } else { $p.Location = $Location; $p.Size = $Size; $p.Anchor = $Anchor }
    $Child.Dock = 'Fill'
    $p.Controls.Add($Child)
    return $p
}

# Windows draws scrollbars non-client, so the control is oversized to push its own bars out of view.
$script:SbW = 11

# $null when there is nothing to scroll, in which case only the track is painted.
function Get-SbGeom {
    param($Bar)
    try {
        $inf = & $Bar.SbInfo
        if (-not $inf) { return $null }
        $range = [double]($inf.Max - $inf.Min + 1)
        $page = [double][Math]::Max(1, $inf.Page)
        if ($range -le $page -or $range -le 1) { return $null }
        $len = if ($Bar.SbVert) { $Bar.ClientSize.Height } else { $Bar.ClientSize.Width }
        if ($len -le 8) { return $null }
        $thumb = [int][Math]::Max(24, [Math]::Min($len, [Math]::Floor($len * $page / $range)))
        $span = [Math]::Max(1, $len - $thumb)
        $den = [Math]::Max(1, $range - $page)
        $off = [int][Math]::Round($span * [Math]::Max(0, $inf.Pos - $inf.Min) / $den)
        $off = [Math]::Max(0, [Math]::Min($span, $off))
        return @{ Thumb = $thumb; Span = $span; Off = $off; Den = $den; Info = $inf }
    }
    catch { return $null }
}

function Set-SbFromOffset {
    param($Bar, $Geom, [int]$Offset)
    $t = [Math]::Max(0, [Math]::Min($Geom.Span, $Offset))
    $pos = [int][Math]::Round($Geom.Info.Min + ($t * $Geom.Den / $Geom.Span))
    & $Bar.SbSet $pos
}

$script:SbPaint = {
    param($s, $e)
    # A Paint handler must never throw - the bar would be left unpainted and read as vanished.
    try {
        $e.Graphics.Clear($s.BackColor)
        $g = Get-SbGeom $s
        if (-not $g) { return }
        $col = if ($s.SbDrag -or $s.SbHot) { $script:Pal.TextDim } else { $script:Pal.Border }
        $br = New-Object System.Drawing.SolidBrush $col
        try {
            if ($s.SbVert) { $e.Graphics.FillRectangle($br, 3, $g.Off, [Math]::Max(1, $s.ClientSize.Width - 6), $g.Thumb) }
            else { $e.Graphics.FillRectangle($br, $g.Off, 3, $g.Thumb, [Math]::Max(1, $s.ClientSize.Height - 6)) }
        }
        finally { $br.Dispose() }
    }
    catch {}
}

$script:SbDown = {
    param($s, $e)
    try {
        $g = Get-SbGeom $s
        if (-not $g) { return }
        $p = if ($s.SbVert) { $e.Y } else { $e.X }
        if ($p -ge $g.Off -and $p -lt ($g.Off + $g.Thumb)) {
            $s.SbGrab = $p - $g.Off
        }
        else {
            $s.SbGrab = [int]($g.Thumb / 2)
            Set-SbFromOffset $s $g ($p - $s.SbGrab)
        }
        $s.SbDrag = $true
        $s.Capture = $true
        $s.Invalidate()
    }
    catch {}
}

$script:SbMove = {
    param($s, $e)
    try {
        if ($s.SbDrag) {
            $g = Get-SbGeom $s
            if ($g) {
                $p = if ($s.SbVert) { $e.Y } else { $e.X }
                Set-SbFromOffset $s $g ($p - $s.SbGrab)
                $s.Invalidate()
            }
        }
        elseif (-not $s.SbHot) { $s.SbHot = $true; $s.Invalidate() }
    }
    catch {}
}

$script:SbUp = { param($s, $e) try { $s.SbDrag = $false; $s.Capture = $false; $s.Invalidate() } catch {} }
$script:SbLeave = { param($s, $e) try { if (-not $s.SbDrag) { $s.SbHot = $false; $s.Invalidate() } } catch {} }

# The pointer is over the bar often enough that it has to handle the wheel itself.
$script:SbWheel = {
    param($s, $e)
    try {
        $i = & $s.SbInfo
        if (-not $i) { return }
        $step = [Math]::Max(1, [int]([Math]::Max(1, $i.Page) / 3))
        $notch = [int]($e.Delta / 120)
        # Max is the last position of the WHOLE range, so content ends one page back from it.
        $end = [Math]::Max($i.Min, $i.Max - $i.Page + 1)
        $pos = $i.Pos - ($notch * $step)
        if ($pos -lt $i.Min) { $pos = $i.Min }
        if ($pos -gt $end) { $pos = $end }
        if ($pos -ne $i.Pos) { & $s.SbSet $pos; $s.Invalidate() }
    }
    catch {}
}

$script:ScrollBars = @()

# $GetInfo returns @{ Min; Max; Page; Pos } (or $null); $SetPos takes an absolute position.
function New-ThemedScrollBar {
    param($GetInfo, $SetPos, $Track, [switch]$Horizontal)
    $bar = New-Object System.Windows.Forms.Panel
    $bar.Tag = 'scrollbar'
    $bar.BackColor = if ($Track) { $Track } else { $script:Pal.Base800 }
    if ($Horizontal) { $bar.Height = $script:SbW; $bar.Dock = 'Bottom' }
    else { $bar.Width = $script:SbW; $bar.Dock = 'Right' }
    $bar | Add-Member -NotePropertyName SbVert -NotePropertyValue (-not $Horizontal) -Force
    $bar | Add-Member -NotePropertyName SbInfo -NotePropertyValue $GetInfo -Force
    $bar | Add-Member -NotePropertyName SbSet  -NotePropertyValue $SetPos  -Force
    $bar | Add-Member -NotePropertyName SbDrag -NotePropertyValue $false   -Force
    $bar | Add-Member -NotePropertyName SbHot  -NotePropertyValue $false   -Force
    $bar | Add-Member -NotePropertyName SbGrab -NotePropertyValue 0        -Force
    $bar | Add-Member -NotePropertyName SbLast -NotePropertyValue ''       -Force
    Set-PanelRedraw $bar
    $bar.Add_Paint($script:SbPaint)
    $bar.Add_MouseDown($script:SbDown)
    $bar.Add_MouseMove($script:SbMove)
    $bar.Add_MouseUp($script:SbUp)
    $bar.Add_MouseLeave($script:SbLeave)
    $bar.Add_MouseWheel($script:SbWheel)
    $script:ScrollBars += $bar
    return $bar
}

# A control can scroll itself without telling anyone, so re-read every bar on the UI tick.
function Sync-ScrollBars {
    foreach ($b in $script:ScrollBars) {
        try {
            if (-not $b.Visible) { continue }
            $i = & $b.SbInfo
            $key = if ($i) { '{0}/{1}/{2}/{3}' -f $i.Min, $i.Max, $i.Page, $i.Pos } else { '-' }
            if ($key -ne $b.SbLast) { $b.SbLast = $key; $b.Invalidate() }
        }
        catch {}
    }
}

# Keeps the clipped control one scrollbar bigger than its frame. Tag decides about the horizontal.
$script:SbHostResize = {
    try {
        $h = $this
        if ($h.Controls.Count -lt 1) { return }
        $b = $h.Controls[0]
        $ew = [System.Windows.Forms.SystemInformation]::VerticalScrollBarWidth
        $eh = if ([string]$h.Tag -eq 'sbhost') { [System.Windows.Forms.SystemInformation]::HorizontalScrollBarHeight } else { 0 }
        $b.SetBounds(0, 0, [Math]::Max(1, $h.ClientSize.Width + $ew), [Math]::Max(1, $h.ClientSize.Height + $eh))
    }
    catch {}
}

# 'sbhost' hides both native bars, 'sbhost-v' only the vertical one.
function New-SbHost {
    param($Child, $Back, [switch]$VerticalOnly)
    $h = New-Object System.Windows.Forms.Panel
    $h.Tag = if ($VerticalOnly) { 'sbhost-v' } else { 'sbhost' }
    $h.Dock = 'Fill'
    if ($Back) { $h.BackColor = $Back }
    $Child.Dock = 'None'
    $Child.Location = New-Object System.Drawing.Point(0, 0)
    $h.Controls.Add($Child)
    $h.Add_Resize($script:SbHostResize)
    return $h
}

# $null when the control cannot scroll that way - the signal to paint an empty track.
function Get-BoxScrollInfo {
    param($Box, [bool]$Vertical)
    try {
        if (-not $Box -or -not $Box.IsHandleCreated) { return $null }
        $i = [CtShell]::ScrollInfo($Box.Handle, $Vertical)
        if (-not $i) { return $null }
        return @{ Min = $i[0]; Max = $i[1]; Page = $i[2]; Pos = $i[3] }
    }
    catch { return $null }
}

# The drawn bar cannot see wheel, keyboard, caret or new text, so each has to repaint it.
function Add-BoxScrollSync {
    param($Box, $V, $H)
    $Box | Add-Member -NotePropertyName SbBars -NotePropertyValue @($V, $H) -Force
    $sync = { try { foreach ($b in $this.SbBars) { if ($b) { $b.Invalidate() } } } catch {} }
    $Box.Add_VScroll($sync)
    $Box.Add_HScroll($sync)
    $Box.Add_TextChanged($sync)
    $Box.Add_Resize($sync)
    $Box.Add_MouseWheel($sync)
    $Box.Add_MouseUp($sync)
    $Box.Add_KeyUp($sync)
    $Box.Add_VisibleChanged($sync)
}

function New-Rule {
    param([string]$Location, [int]$Width = 976)
    $r = New-Object System.Windows.Forms.Panel
    $r.Tag = 'rule'
    $r.Location = $Location
    $r.Size = New-Object System.Drawing.Size($Width, 1)
    $r.Anchor = 'Top,Left,Right'
    $r.BackColor = $script:Pal.Line
    return $r
}

function New-SectionLabel {
    param([string]$Text, [string]$Location)
    $l = New-Object System.Windows.Forms.Label
    $l.Tag = 'section'
    $l.Text = $Text.ToUpper()
    $l.Location = $Location
    $l.AutoSize = $true
    $l.Font = $script:UiFontBold
    $l.ForeColor = $script:Pal.Accent
    return $l
}

# A disabled TextBox paints light grey with near-black text; use ReadOnly and our own colours.
function Set-BoxActive {
    param($Box, [bool]$Active)
    $Box.ReadOnly = -not $Active
    $Box.TabStop = $Active
    $Box.BackColor = if ($Active) { $script:Pal.Base700 } else { $script:Pal.Base900 }
    $Box.ForeColor = if ($Active) { $script:Pal.Text }    else { $script:Pal.TextDim }
}

# Same problem for check boxes and radio buttons - keep them enabled, just dim the caption.
function Set-CheckActive {
    param($Ctl, [bool]$Active)
    $Ctl.ForeColor = if ($Active) { $script:Pal.Text } else { $script:Pal.TextDim }
}

function Set-ControlTheme {
    param($parent)
    foreach ($c in $parent.Controls) {
        # Match on type, not name: the action buttons are a Button subclass and Check/Radio are not Buttons.
        $tn = $c.GetType().Name
        if ($c -is [System.Windows.Forms.Button]) { $tn = 'Button' }
        switch ($tn) {
            'Button' {
                $kind = 'secondary'
                if ($c.Text -match 'Fetch|^Run |^Apply$') { $kind = 'primary' }
                elseif ($c.Text -match 'Refresh|Clear|Save|Re-read|^Cancel$|^Close$|^OK$|Edit proxy|Task Scheduler|Copy from') { $kind = 'tertiary' }
                Style-Button $c $kind
            }
            'RichTextBox' { $c.BackColor = $script:Pal.Base900; $c.ForeColor = $script:Pal.OutText; $c.BorderStyle = 'None'; $c.Font = $script:MonoFont }
            'TextBox' { $c.BackColor = $script:Pal.Base700; $c.ForeColor = $script:Pal.Text; $c.BorderStyle = 'FixedSingle' }
            'ComboBox' { $c.BackColor = $script:Pal.Base700; $c.ForeColor = $script:Pal.Text; $c.FlatStyle = 'Flat' }
            'Label' {
                if ($c.Tag -eq 'section') { $c.ForeColor = $script:Pal.Accent }
                else { $c.ForeColor = if ($c.Font.Bold) { $script:Pal.Text } else { $script:Pal.TextDim } }
            }
            'RadioButton' { Style-Option $c }
            'CheckBox' { Style-Option $c }
            'GroupBox' { $c.ForeColor = $script:Pal.Text; $c.BackColor = $script:Pal.Base800 }
            'Panel' {
                switch ([string]$c.Tag) {
                    'frame' { $c.BackColor = $script:Pal.Border }
                    'rule' { $c.BackColor = $script:Pal.Line }
                    'card' { $c.BackColor = $script:Pal.Base900 }
                    'scrollbar' { }
                    'sbhost' { }
                    default { $c.BackColor = $script:Pal.Base800 }
                }
            }
            'FlowLayoutPanel' { $c.BackColor = $script:Pal.Base800 }
        }
        if ($c.Controls.Count -gt 0) { Set-ControlTheme $c }
    }
}

function Apply-Theme {
    $form.BackColor = $script:Pal.Base800
    $form.ForeColor = $script:Pal.Text
    $form.Font = $script:UiFont

    Set-ControlTheme $form

}

$script:PreconfiguredUrls = @(
    'https://patchmypc.com'
    'https://patchmypc.com/scupcatalog/downloads/publishingservice/supportedproducts.xml'
    'https://api.patchmypc.com'
    'https://login.microsoftonline.com'
    'https://graph.microsoft.com'
)

# Cap on the body kept for the Browser tab - some endpoints are megabytes.
$script:MaxFetchChars = 512 * 1024

$script:Jobs = New-Object System.Collections.ArrayList
$script:Retired = New-Object System.Collections.ArrayList
$script:LastLogJob = $null
$script:Acct = 'User'
$script:IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$script:MeName = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name

# The WebBrowser defaults to IE7 mode; opt into IE11 BEFORE the control is built.
function Set-BrowserEmulation {
    try {
        $exe = [System.IO.Path]::GetFileName(([System.Diagnostics.Process]::GetCurrentProcess()).MainModule.FileName)
        $key = 'HKCU:\Software\Microsoft\Internet Explorer\Main\FeatureControl\FEATURE_BROWSER_EMULATION'
        if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
        New-ItemProperty -Path $key -Name $exe -Value 11001 -PropertyType DWord -Force | Out-Null
        return $exe
    }
    catch { return $null }
}
$script:EmuExe = Set-BrowserEmulation

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Network Connectivity Test'
$form.StartPosition = 'CenterScreen'
$form.ClientSize = New-Object System.Drawing.Size(1080, 880)
$form.MinimumSize = New-Object System.Drawing.Size(1060, 640)
# Font mode, not Dpi: fonts are in points and already grow with DPI - Dpi would double it.
$form.Font = $script:UiFont
$form.AutoScaleDimensions = New-Object System.Drawing.SizeF(7, 15)
$form.AutoScaleMode = 'Font'
Set-DarkFrame $form

$mono = $script:MonoFont
$boldFont = $script:UiFontBold

# Fully docked. Docking resolves highest z-order first, so the Fill control is added FIRST.

$pnlSteps = New-Object System.Windows.Forms.Panel
$pnlSteps.Dock = 'Top'; $pnlSteps.Size = New-Object System.Drawing.Size(1024, 212)

$lblStep1 = New-SectionLabel -Text 'What to test' -Location '16,10'

$lblTarget = New-Object System.Windows.Forms.Label
$lblTarget.Text = 'Target'; $lblTarget.Location = '16,38'; $lblTarget.AutoSize = $true
$cboTarget = New-Object System.Windows.Forms.ComboBox
$cboTarget.Location = '120,34'; $cboTarget.Size = '888,26'; $cboTarget.Anchor = 'Top,Left,Right'
$cboTarget.DropDownStyle = 'DropDown'
$cboTarget.DrawMode = 'OwnerDrawFixed'
$cboTarget.ItemHeight = 20
$cboTarget.MaxDropDownItems = 20
$cboTarget.DropDownWidth = 900

# Items are objects so the list can show an annotation while ToString() stays a clean URL.
function New-UrlItem {
    param([string]$Url, [string]$Note = '', [switch]$Header)
    $o = [pscustomobject]@{ Url = $Url; Note = $Note; IsHeader = [bool]$Header }
    $o | Add-Member -MemberType ScriptMethod -Name ToString -Value { $this.Url } -Force
    $o
}

# The log scan is slow, so it runs in the background and appends its group later.
function Build-TargetList {
    $cboTarget.Items.Clear()
    [void]$cboTarget.Items.Add((New-UrlItem -Url '--  COMMON ENDPOINTS  ------------------------------------------' -Header))
    foreach ($u in $script:PreconfiguredUrls) { [void]$cboTarget.Items.Add((New-UrlItem -Url $u)) }
    $cboTarget.SelectedIndex = 1
}

function Start-LogScan {
    Start-Task -Name 'Scanning PatchMyPC logs' -Target $null -Kind 'LogScan' -Work {
        param($MaxFiles)
        $r = Get-LogEndpoints -MaxFiles $MaxFiles
        Write-Output ('FOLDER=' + [string]$r.LogFolder)
        Write-Output ('FILES=' + [string]$r.FilesScanned)
        Write-Output ('NOTE=' + [string]$r.Note)
        if ($r.Info) {
            Write-Output ('INSTALL=' + [string]$r.Info.Path)
            Write-Output ('SOURCE=' + [string]$r.Info.Source)
            Write-Output ('VERSION=' + [string]$r.Info.Version)
        }
        foreach ($i in $r.Downloads) {
            Write-Output ('DOWN={0}|{1}|{2}' -f $i.Url, $i.File, $(if ($i.Last) { $i.Last.ToString('yyyy-MM-dd HH:mm') } else { '' }))
        }
        foreach ($i in $r.Items) {
            Write-Output ('ITEM={0}|{1}|{2}' -f $i.Url, $i.Hits, $(if ($i.Last) { $i.Last.ToString('yyyy-MM-dd HH:mm') } else { '' }))
        }
    } -Params @{ MaxFiles = 20 }
}

function Add-LogEndpointGroup {
    param([string[]]$Lines)
    $meta = @{}
    $items = New-Object System.Collections.Generic.List[object]
    $downs = New-Object System.Collections.Generic.List[object]
    foreach ($l in $Lines) {
        if ($l -like 'ITEM=*') {
            $parts = $l.Substring(5) -split '\|', 3
            if ($parts.Count -ge 1 -and $parts[0]) {
                $items.Add([pscustomobject]@{ Url = $parts[0]; Hits = $parts[1]; Last = $parts[2] })
            }
        }
        elseif ($l -like 'DOWN=*') {
            $parts = $l.Substring(5) -split '\|', 3
            if ($parts.Count -ge 1 -and $parts[0]) {
                $downs.Add([pscustomobject]@{ Url = $parts[0]; File = $parts[1]; Last = $parts[2] })
            }
        }
        elseif ($l -match '^([A-Z]+)=(.*)$') { $meta[$Matches[1]] = $Matches[2] }
    }

    $keep = $cboTarget.Text
    # Drop any previous log groups before re-adding (the scan can be run again).
    for ($i = $cboTarget.Items.Count - 1; $i -ge 0; $i--) {
        if ($cboTarget.Items[$i].IsLog) { $cboTarget.Items.RemoveAt($i) }
    }
    $addItem = {
        param($o)
        $o | Add-Member -NotePropertyName IsLog -NotePropertyValue $true -Force
        [void]$cboTarget.Items.Add($o)
    }
    if ($downs.Count -gt 0) {
        & $addItem (New-UrlItem -Url ('--  DOWNLOAD URLs FROM THE LOGS - {0}  --------------------------' -f $downs.Count) -Header)
        foreach ($it in $downs) {
            $note = if ($it.File) { '{0}   last {1}' -f $it.File, $it.Last } else { 'last {0}' -f $it.Last }
            & $addItem (New-UrlItem -Url $it.Url -Note $note)
        }
    }
    if ($items.Count -gt 0) {
        & $addItem (New-UrlItem -Url ('--  SERVICE ENDPOINTS FROM THE LOGS - {0}  ----------------------' -f $items.Count) -Header)
        foreach ($it in $items) {
            & $addItem (New-UrlItem -Url $it.Url -Note ('last {0}   x{1}' -f $it.Last, $it.Hits))
        }
    }
    $cboTarget.Text = $keep

    $bits = New-Object System.Collections.Generic.List[string]
    if ($meta['VERSION']) { $bits.Add(('Publishing Service {0}' -f $meta['VERSION'])) }
    elseif ($meta['INSTALL']) { $bits.Add('Publishing Service found') }
    if ($meta['FILES']) { $bits.Add(('{0} log file(s) scanned' -f $meta['FILES'])) }
    $bits.Add(('{0} download URL(s), {1} endpoint(s) added to the dropdown' -f $downs.Count, $items.Count))
    if ($items.Count -eq 0 -and $downs.Count -eq 0 -and $meta['NOTE']) { $bits.Clear(); $bits.Add([string]$meta['NOTE']) }
    Append-ToBox $outBox (@('', '=== PUBLISHING SERVICE LOG SCAN ===') + @($bits | ForEach-Object { "  $_" }))

}

# Headers are decoration only - bounce the selection past them.
$script:CboGuard = $false
$cboTarget.Add_SelectedIndexChanged({
        if ($script:CboGuard) { return }
        $i = $cboTarget.SelectedIndex
        if ($i -lt 0 -or -not $cboTarget.Items[$i].IsHeader) { return }
        $script:CboGuard = $true
        try {
            if ($i + 1 -lt $cboTarget.Items.Count) { $cboTarget.SelectedIndex = $i + 1 }
            elseif ($i -gt 0) { $cboTarget.SelectedIndex = $i - 1 }
        }
        finally { $script:CboGuard = $false }
    })

$cboTarget.Add_DrawItem({
        param($s, $e)
        if ($e.Index -lt 0 -or $e.Index -ge $s.Items.Count) { return }
        $it = $s.Items[$e.Index]
        $g = $e.Graphics
        if ($it.IsHeader) {
            $bg = New-Object System.Drawing.SolidBrush $script:Pal.Base900
            $g.FillRectangle($bg, $e.Bounds); $bg.Dispose()
            $fb = New-Object System.Drawing.SolidBrush $script:Pal.Accent
            $g.DrawString($it.Url, $script:UiFontSub, $fb, [single]($e.Bounds.X + 3), [single]($e.Bounds.Y + 3))
            $fb.Dispose()
            return
        }
        $sel = (($e.State -band [System.Windows.Forms.DrawItemState]::Selected) -ne 0)
        $bg = New-Object System.Drawing.SolidBrush $(if ($sel) { $script:Pal.Accent } else { $script:Pal.Base700 })
        $g.FillRectangle($bg, $e.Bounds); $bg.Dispose()
        $fb = New-Object System.Drawing.SolidBrush $(if ($sel) { [System.Drawing.Color]::White } else { $script:Pal.Text })
        $g.DrawString($it.Url, $s.Font, $fb, [single]($e.Bounds.X + 3), [single]($e.Bounds.Y + 2))
        $fb.Dispose()
        if ($it.Note) {
            $w = [int]$g.MeasureString($it.Url, $s.Font).Width
            $nb = New-Object System.Drawing.SolidBrush $(if ($sel) { [System.Drawing.Color]::White } else { $script:Pal.TextDim })
            $g.DrawString($it.Note, $script:UiFontSub, $nb, [single]($e.Bounds.X + 12 + $w), [single]($e.Bounds.Y + 3))
            $nb.Dispose()
        }
    })

Build-TargetList

# WinForms scopes radio exclusivity to the parent, and two groups share this panel.
$script:RadioGroups = @{}
$script:RadioSync = {
    if (-not $this.Checked) { return }
    $g = $script:RadioGroups[[string]$this.Tag]
    if (-not $g) { return }
    foreach ($r in $g) { if (-not [object]::ReferenceEquals($r, $this) -and $r.Checked) { $r.Checked = $false } }
}
# AutoCheck is off, so a click has to set the state itself. Space also raises Click.
$script:RadioClick = { if (-not $this.Checked) { $this.Checked = $true } }
function Register-RadioGroup {
    param([string]$Name, [object[]]$Radios)
    $script:RadioGroups[$Name] = $Radios
    foreach ($r in $Radios) {
        $r.AutoCheck = $false
        $r.Tag = $Name
        $r.Add_CheckedChanged($script:RadioSync)
        $r.Add_Click($script:RadioClick)
    }
}

# LinkArea covers only the bracketed words. LinkLabel is not matched by the recursive themer.
$lblRunAs = New-Object System.Windows.Forms.LinkLabel
$lblRunAs.Text = 'Run as (more info)'
$lblRunAs.Location = '16,72'; $lblRunAs.AutoSize = $true
$lblRunAs.LinkArea = New-Object System.Windows.Forms.LinkArea(8, 9)
$lblRunAs.LinkBehavior = 'HoverUnderline'
$lblRunAs.LinkColor = $script:Pal.Accent
$lblRunAs.ActiveLinkColor = $script:Pal.Accent
$lblRunAs.VisitedLinkColor = $script:Pal.Accent
$lblRunAs.ForeColor = $script:Pal.TextDim
$lblRunAs.Add_LinkClicked({ Show-SystemInfo })

$rbCtxUser = New-Object System.Windows.Forms.RadioButton
$rbCtxUser.Text = 'Logged-on user'; $rbCtxUser.Location = '120,70'; $rbCtxUser.AutoSize = $true; $rbCtxUser.Checked = $true
$rbCtxSys = New-Object System.Windows.Forms.RadioButton
$rbCtxSys.Text = 'SYSTEM'; $rbCtxSys.Location = '268,70'; $rbCtxSys.AutoSize = $true

$lblSysNote = New-Object System.Windows.Forms.Label
$lblSysNote.Text = ''; $lblSysNote.Location = '370,72'; $lblSysNote.AutoSize = $true

$ruleSteps = New-Rule -Location '16,104' -Width 992

$lblStep2 = New-SectionLabel -Text 'Proxy' -Location '16,116'

$btnEditProxy = New-ActionButton 'Edit proxy...' 104 26
$btnEditProxy.Location = New-Object System.Drawing.Point((1008 - $btnEditProxy.Width), 112); $btnEditProxy.Anchor = 'Top,Right'
$btnRefreshProxy = New-ActionButton 'Refresh' 78 26
$btnRefreshProxy.Location = New-Object System.Drawing.Point(($btnEditProxy.Left - 6 - $btnRefreshProxy.Width), 112); $btnRefreshProxy.Anchor = 'Top,Right'

# A read-out, not a switch: checks always use the WinINET proxy of the 'Run as' account.
$lblWinInetCap = New-Object System.Windows.Forms.Label
$lblWinInetCap.Text = 'Windows (WinINET)'; $lblWinInetCap.Location = '16,148'; $lblWinInetCap.AutoSize = $true

$lblLiveProxy = New-Object System.Windows.Forms.Label
$lblLiveProxy.Text = ''; $lblLiveProxy.Location = '196,148'; $lblLiveProxy.AutoSize = $true; $lblLiveProxy.MaximumSize = '560,0'

$lblWinHttpCap = New-Object System.Windows.Forms.Label
$lblWinHttpCap.Text = 'Machine (WinHTTP)'; $lblWinHttpCap.Location = '16,174'; $lblWinHttpCap.AutoSize = $true

$lblWinHttp = New-Object System.Windows.Forms.Label
$lblWinHttp.Text = ''; $lblWinHttp.Location = '196,174'; $lblWinHttp.AutoSize = $true; $lblWinHttp.MaximumSize = '560,0'

# Registered before any behavioural handler, or Set-Account fires on a half-updated state.
Register-RadioGroup 'ctx' @($rbCtxUser, $rbCtxSys)
$rbCtxUser.Checked = $true

$pnlSteps.Controls.AddRange(@(
        $lblStep1, $lblTarget, $cboTarget, $lblRunAs, $rbCtxUser, $rbCtxSys, $lblSysNote, $ruleSteps,
        $lblStep2, $lblWinInetCap, $lblLiveProxy, $lblWinHttpCap, $lblWinHttp,
        $btnRefreshProxy, $btnEditProxy
    ))

$pnlBottom = New-Object System.Windows.Forms.Panel
$pnlBottom.Dock = 'Bottom'; $pnlBottom.Height = 50
$btnClear = New-ActionButton 'Clear' 88 30
$btnClear.Location = '12,10'
$btnSave = New-ActionButton 'Save log...' 104 30
$btnSave.Location = '108,10'
$lblCtxPill = New-Object System.Windows.Forms.Label
$lblCtxPill.Text = ''; $lblCtxPill.Location = '228,17'; $lblCtxPill.AutoSize = $true
$lblCtxPill.Font = $script:UiFontBold
$pnlBottom.Controls.AddRange(@($btnClear, $btnSave, $lblCtxPill))

# Transient chatter is dropped; anything worth keeping goes to the log, which gets pasted into tickets.
function Set-Status {
    param([string]$Text, [switch]$Keep)
    if (-not $Keep -or -not $Text) { return }
    try { Append-ToBox $outBox @(('  [note] {0}' -f $Text)) } catch {}
}

# A TabControl can leave an owner-drawn tab blank, so use plain panels and label buttons.
$tabHost = New-Object System.Windows.Forms.Panel
$tabHost.Dock = 'Fill'
$tabHost.Padding = New-Object System.Windows.Forms.Padding(10, 0, 10, 8)

$pnlPages = New-Object System.Windows.Forms.Panel
$pnlPages.Dock = 'Fill'
# Padding reserves the pixel the border is drawn in, or Dock=Fill covers it.
$pnlPages.Padding = New-Object System.Windows.Forms.Padding(1)
Set-PanelRedraw $pnlPages
$pnlPages.Add_Paint({
        param($s, $e)
        try {
            $pen = New-Object System.Drawing.Pen($script:Pal.Border, 1)
            $e.Graphics.DrawRectangle($pen, 0, 0, ($s.ClientSize.Width - 1), ($s.ClientSize.Height - 1))
            $pen.Dispose()
        }
        catch {}
    })

$pnlTabBar = New-Object System.Windows.Forms.Panel
$pnlTabBar.Dock = 'Top'; $pnlTabBar.Height = 36
Set-PanelRedraw $pnlTabBar

$tabHost.Controls.Add($pnlPages)
$tabHost.Controls.Add($pnlTabBar)

$script:Pages = New-Object System.Collections.ArrayList
$script:TabX = 0
$script:TabClick = { Select-Page ([int]$this.Tag) }
$script:TabBorderPaint = {
    param($s, $e)
    try {
        $sel = ([int]$s.Tag -eq $script:PageIndex)
        $col = if ($sel) { $script:Pal.Accent } else { $script:Pal.Line }
        $pen = New-Object System.Drawing.Pen($col, 1)
        $e.Graphics.DrawRectangle($pen, 0, 0, ($s.ClientSize.Width - 1), ($s.ClientSize.Height - 1))
        $pen.Dispose()
    }
    catch {}
}

# Buttons flow from x=0, the same left edge the page content starts at.
function Add-Page {
    param([string]$Text, $Panel)
    $w = [System.Windows.Forms.TextRenderer]::MeasureText($Text, $script:UiFontBold).Width + 44

    $btn = New-Object System.Windows.Forms.Label
    $btn.Text = $Text
    $btn.AutoSize = $false
    $btn.Size = New-Object System.Drawing.Size($w, 33)
    $btn.Location = New-Object System.Drawing.Point($script:TabX, 0)
    $btn.TextAlign = 'MiddleCenter'
    $btn.Font = $script:UiFontBold
    $btn.Cursor = [System.Windows.Forms.Cursors]::Hand

    $ul = New-Object System.Windows.Forms.Panel
    $ul.Size = New-Object System.Drawing.Size($w, 2)
    $ul.Location = New-Object System.Drawing.Point($script:TabX, 34)

    $script:TabX += $w
    $Panel.Dock = 'Fill'
    $Panel.Visible = $false

    $btn.Tag = $script:Pages.Count
    $btn.Add_Click($script:TabClick)

    $btn.Add_Paint($script:TabBorderPaint)
    $pnlTabBar.Controls.Add($btn)
    $pnlTabBar.Controls.Add($ul)
    $pnlPages.Controls.Add($Panel)
    [void]$script:Pages.Add([pscustomobject]@{ Btn = $btn; Rule = $ul; Panel = $Panel })
}

function Select-Page {
    param([int]$Index)
    if ($Index -lt 0 -or $Index -ge $script:Pages.Count) { return }
    $script:PageIndex = $Index
    for ($i = 0; $i -lt $script:Pages.Count; $i++) {
        $p = $script:Pages[$i]
        $sel = ($i -eq $Index)
        $p.Panel.Visible = $sel
        $p.Btn.ForeColor = if ($sel) { $script:Pal.Text }   else { $script:Pal.TextDim }
        $p.Btn.BackColor = if ($sel) { $script:Pal.Base700 } else { $script:Pal.Base800 }
        $p.Rule.BackColor = if ($sel) { $script:Pal.Accent }  else { $script:Pal.Base800 }
        if ($sel) { $p.Panel.BringToFront() }
        $p.Btn.Invalidate()
    }
    # Append-ToBox cannot scroll a box that is off screen, so a hidden transcript stays parked.
    foreach ($b in @($outBox, $srcBox)) {
        if ($b -and $b.Visible -and $b.IsHandleCreated -and $b.TextLength -gt 0) {
            try { $b.SelectionStart = $b.TextLength; $b.ScrollToCaret() } catch {}
        }
    }
}
$script:PageIndex = 0

# Addressed by caption, never by ordinal - reordering tabs would point the buttons at the wrong pane.
function Get-PageIndex {
    param([string]$Text)
    for ($i = 0; $i -lt $script:Pages.Count; $i++) {
        if ($script:Pages[$i].Btn.Text -eq $Text) { return $i }
    }
    return -1
}

# Fill first, then each Top band bottom-up, then the Bottom bar.
$form.Controls.Add($tabHost)
$form.Controls.Add($pnlSteps)
$form.Controls.Add($pnlBottom)

# Cards are built by PARSING the "=== NAME ===" and "RESULT :" lines the checks already emit.
$tabTests = New-Object System.Windows.Forms.Panel
$tabTests.Padding = New-Object System.Windows.Forms.Padding(0)

$railW = 208
$pnlRail = New-Object System.Windows.Forms.Panel
$pnlRail.Dock = 'Left'; $pnlRail.Width = $railW; $pnlRail.Tag = 'card'
$pnlRail.Padding = New-Object System.Windows.Forms.Padding(10, 8, 10, 8)
$pnlRail.AutoScroll = $true

$script:TestChecks = New-Object System.Collections.ArrayList
$railY = 6
function Add-RailHeading {
    param([string]$Text)
    $l = New-Object System.Windows.Forms.Label
    $l.Tag = 'section'; $l.Text = $Text.ToUpper(); $l.AutoSize = $true
    $l.Font = $script:UiFontBold; $l.ForeColor = $script:Pal.Accent
    $l.Location = New-Object System.Drawing.Point(8, $script:RailY)
    $pnlRail.Controls.Add($l)
    $script:RailY += 24
}
function Add-RailTest {
    param([string]$Text, [string]$Token, [switch]$On, [string]$Note = '')
    $c = New-Object System.Windows.Forms.CheckBox
    $c.Text = $Text; $c.AutoSize = $true; $c.Checked = [bool]$On
    $c.Location = New-Object System.Drawing.Point(8, $script:RailY)
    $c.Tag = $Token
    $pnlRail.Controls.Add($c)
    [void]$script:TestChecks.Add($c)
    if ($Note) {
        $n = New-Object System.Windows.Forms.Label
        $n.Text = $Note; $n.AutoSize = $true; $n.Font = $script:UiFontSub
        $n.ForeColor = $script:Pal.Warning
        $n.Location = New-Object System.Drawing.Point(($railW - 52), ($script:RailY + 2))
        $pnlRail.Controls.Add($n)
    }
    $script:RailY += 23
}
$script:RailY = $railY

Add-RailHeading 'Connectivity'
Add-RailTest 'HTTP(S) GET'   'Http'      -On
Add-RailTest 'File download' 'Download'
Add-RailTest 'Ports 80/443'  'Ports'     -On
Add-RailTest 'Ping'          'Ping'
Add-RailTest 'Tracert'       'Tracert'   -Note 'slow'
Add-RailTest 'Nslookup'      'Dns'
$script:RailY += 8
Add-RailHeading 'Windows server'
Add-RailTest 'SMB / file share' 'Smb'
Add-RailTest 'RPC / WMI'        'Rpc'
$script:RailY += 8
Add-RailHeading 'TLS'
Add-RailTest 'Handshake'      'Tls'      -On
Add-RailTest 'TLS config'     'BoxTls'
Add-RailTest 'Cipher suites'  'CipherCmp' -Note 'slow'
$script:RailY += 8
Add-RailHeading 'Configuration'
Add-RailTest 'DNS config'     'DnsCfg'
$script:RailY += 14

$btnRun = New-ActionButton 'Run selected' ($railW - 16) 34
$btnRun.Location = New-Object System.Drawing.Point(8, $script:RailY)
$pnlRail.Controls.Add($btnRun)
$script:RailY += 40
$btnCancelRun = New-ActionButton 'Cancel' ($railW - 16) 28
$btnCancelRun.Location = New-Object System.Drawing.Point(8, $script:RailY)
$btnCancelRun.Visible = $false
$pnlRail.Controls.Add($btnCancelRun)

# Three rules: starts with http, contains a backslash, or neither. Backslash is checked first.
$script:DefaultsByKind = @{
    Http = @('Http', 'Ports', 'Tls')
    Unc  = @('Ping', 'Smb')
    Host = @('Ping', 'Rpc')
}
$script:KindWords = @{
    Http = 'a web address'; Unc = 'a file share'; Host = 'a server name'
}
$script:LastTargetKind = ''
# Only re-applied when the KIND changes, or a hand-made selection would be thrown away.
function Sync-ChecksToTarget {
    param([switch]$Quiet)
    if (-not $script:TestChecks -or $script:TestChecks.Count -eq 0) { return }
    $ti = Get-TargetInfo -Target $cboTarget.Text
    if (-not $ti.HostName) { return }
    if ($ti.Kind -eq $script:LastTargetKind) { return }
    $script:LastTargetKind = $ti.Kind

    $want = $script:DefaultsByKind[$ti.Kind]
    if (-not $want) { return }
    $names = @()
    foreach ($c in $script:TestChecks) {
        $c.Checked = ($want -contains [string]$c.Tag)
        if ($c.Checked) { $names += $c.Text }
    }
    if (-not $Quiet) {
        $msg = ('Target looks like {0} - selected {1}. Change the ticks if you want something else.' -f
            $script:KindWords[$ti.Kind], ($names -join ', '))
        # Set-Status only reaches the LOG, so the hint carries it where the user is actually looking.
        Set-Status $msg -Keep
        try {
            if ($lblEmpty -and $lblEmpty.Visible) {
                $lblEmpty.Text = $msg + [Environment]::NewLine +
                'Each check becomes a card here; open one to see the full output. The LOG tab keeps everything verbatim.'
            }
        }
        catch {}
    }
}
# Run moves focus off the combo first, so a typed target is always classified before the run.
$cboTarget.Add_Leave({ try { $script:TargetSync.Stop() } catch {}; Sync-ChecksToTarget })
$cboTarget.Add_SelectionChangeCommitted({ try { $script:TargetSync.Stop() } catch {}; Sync-ChecksToTarget })

# Debounced: a URL typed straight through is classified once, not once per character.
$script:TargetSync = New-Object System.Windows.Forms.Timer
$script:TargetSync.Interval = 350
$script:TargetSync.Add_Tick({
        try { $script:TargetSync.Stop(); Sync-ChecksToTarget } catch {}
    })
$cboTarget.Add_TextChanged({ try { $script:TargetSync.Stop(); $script:TargetSync.Start() } catch {} })

$railFrame = New-Frame -Child $pnlRail -Dock 'Left'
# Only the right edge is drawn - the other three sit on the page frame and would read as 2px.
$railFrame.Padding = New-Object System.Windows.Forms.Padding(0, 0, 1, 0)
$railFrame.Width = $railW + 1

$script:VerdictColor = $script:Pal.Accent
$script:VerdictIsRunning = $false
# Reserves a bar's width so the banner lines up exactly with the cards below it.
function Get-VerdictBox {
    $w = $pnlVerdict.ClientSize.Width - 20 - $script:SbW
    return [Math]::Max(4, $w)
}
function Set-VerdictTextWidth {
    try { $lblVerdictP.Width = [Math]::Max(200, (Get-VerdictBox) - 32) } catch {}
}
$pnlVerdict = New-Object System.Windows.Forms.Panel
$pnlVerdict.Dock = 'Top'; $pnlVerdict.Height = 0; $pnlVerdict.Visible = $false
Set-PanelRedraw $pnlVerdict
$pnlVerdict.Add_Resize({ Set-VerdictTextWidth })
$pnlVerdict.Add_Paint({
        param($s, $e)
        try {
            $w = Get-VerdictBox
            $h = $s.ClientSize.Height - 17
            if ($w -le 4 -or $h -le 4) { return }
            $g = $e.Graphics
            $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $r = 8; $d = $r * 2
            $path = New-Object System.Drawing.Drawing2D.GraphicsPath
            $path.AddArc(10, 8, $d, $d, 180, 90)
            $path.AddArc((10 + $w - $d), 8, $d, $d, 270, 90)
            $path.AddArc((10 + $w - $d), (8 + $h - $d), $d, $d, 0, 90)
            $path.AddArc(10, (8 + $h - $d), $d, $d, 90, 90)
            $path.CloseFigure()
            $fill = New-Object System.Drawing.SolidBrush $script:Pal.Base900
            $g.FillPath($fill, $path); $fill.Dispose()
            $pen = New-Object System.Drawing.Pen($script:VerdictColor, 2)
            $g.DrawPath($pen, $path); $pen.Dispose()
            $path.Dispose()
        }
        catch {}
    })
$lblVerdictH = New-Object System.Windows.Forms.Label
$lblVerdictH.Location = '26,20'; $lblVerdictH.AutoSize = $true; $lblVerdictH.Font = $script:UiFontBold
$lblVerdictH.BackColor = $script:Pal.Base900
$lblVerdictP = New-Object System.Windows.Forms.Label
$lblVerdictP.Location = '26,42'; $lblVerdictP.AutoSize = $false
$lblVerdictP.Size = New-Object System.Drawing.Size(700, 20)
$lblVerdictP.Font = $script:UiFont
$lblVerdictP.BackColor = $script:Pal.Base900
$lblVerdictP.AutoEllipsis = $true
$pnlVerdict.Controls.AddRange(@($lblVerdictH, $lblVerdictP))

$pnlCards = New-Object System.Windows.Forms.FlowLayoutPanel
$pnlCards.Dock = 'Fill'
$pnlCards.FlowDirection = 'TopDown'
$pnlCards.WrapContents = $false
$pnlCards.AutoScroll = $true
$pnlCards.Tag = 'cardhost'
Set-PanelRedraw $pnlCards

$lblEmpty = New-Object System.Windows.Forms.Label
$lblEmpty.AutoSize = $false
$lblEmpty.Size = New-Object System.Drawing.Size(600, 60)
$lblEmpty.Font = $script:UiFont
$lblEmpty.Text = "Pick what to check on the left, then Run selected." + [Environment]::NewLine +
"Each check becomes a card here; open one to see the full output. The LOG tab keeps everything verbatim."
$pnlCards.Controls.Add($lblEmpty)

# The pane is deliberately oversized to hide its native bars, so its last strip is out of sight.
$pnlCards.Padding = New-Object System.Windows.Forms.Padding(10, 10, 10, 10)

$cardsHost = New-SbHost -Child $pnlCards -Back $script:Pal.Base800
$sbCards = New-ThemedScrollBar -Track $script:Pal.Base800 `
    -GetInfo {
    try {
        $vs = $pnlCards.VerticalScroll
        if (-not $vs.Visible) { return $null }
        @{ Min = 0; Max = $vs.Maximum; Page = $vs.LargeChange; Pos = (-$pnlCards.AutoScrollPosition.Y) }
    }
    catch { $null }
} `
    -SetPos {
    param($p)
    # AutoScrollPosition reads negative, writes positive, and sets BOTH axes.
    try { $pnlCards.AutoScrollPosition = New-Object System.Drawing.Point((-$pnlCards.AutoScrollPosition.X), $p); Set-CardChevrons } catch {}
}
$sbCardsH = New-ThemedScrollBar -Track $script:Pal.Base800 -Horizontal `
    -GetInfo {
    try {
        $hs = $pnlCards.HorizontalScroll
        if (-not $hs.Visible) { return $null }
        @{ Min = 0; Max = $hs.Maximum; Page = $hs.LargeChange; Pos = (-$pnlCards.AutoScrollPosition.X) }
    }
    catch { $null }
} `
    -SetPos {
    param($p)
    try { $pnlCards.AutoScrollPosition = New-Object System.Drawing.Point($p, (-$pnlCards.AutoScrollPosition.Y)); Set-CardChevrons } catch {}
}
$script:SbCardsSync = { try { $sbCards.Invalidate(); $sbCardsH.Invalidate(); Set-CardChevrons } catch {} }
$pnlCards.Add_Scroll($script:SbCardsSync)
$pnlCards.Add_MouseWheel($script:SbCardsSync)
$pnlCards.Add_ControlAdded($script:SbCardsSync)
$pnlCards.Add_ControlRemoved($script:SbCardsSync)
$pnlCards.Add_ClientSizeChanged($script:SbCardsSync)

# Docking applies in reverse z-order, so the vertical bar claims full height like a native pair.
$pnlCardArea = New-Object System.Windows.Forms.Panel
$pnlCardArea.Dock = 'Fill'
$pnlCardArea.BackColor = $script:Pal.Base800
$pnlCardArea.Controls.Add($cardsHost)
$pnlCardArea.Controls.Add($sbCardsH)
$pnlCardArea.Controls.Add($sbCards)

$tabTests.Controls.Add($pnlCardArea)
$tabTests.Controls.Add($pnlVerdict)
$tabTests.Controls.Add($railFrame)
Add-Page 'TESTS' $tabTests

# Kept verbatim: support workflows depend on pasting this into a ticket.
$tabLog = New-Object System.Windows.Forms.Panel
$tabLog.Padding = New-Object System.Windows.Forms.Padding(0)

$outBox = New-Object System.Windows.Forms.RichTextBox
$outBox.Name = 'outputBox'; $outBox.Font = $mono; $outBox.ReadOnly = $true
$outBox.WordWrap = $false; $outBox.ScrollBars = 'Both'
$logHost = New-SbHost -Child $outBox -Back $script:Pal.Base900
$sbLogV = New-ThemedScrollBar -Track $script:Pal.Base900 `
    -GetInfo { Get-BoxScrollInfo $outBox $true } `
    -SetPos { param($p) try { [CtShell]::ScrollTo($outBox.Handle, $true, $p) } catch {} }
$sbLogH = New-ThemedScrollBar -Horizontal -Track $script:Pal.Base900 `
    -GetInfo { Get-BoxScrollInfo $outBox $false } `
    -SetPos { param($p) try { [CtShell]::ScrollTo($outBox.Handle, $false, $p) } catch {} }
Add-BoxScrollSync $outBox $sbLogV $sbLogH
$tabLog.Controls.Add($logHost)
$tabLog.Controls.Add($sbLogH)
$tabLog.Controls.Add($sbLogV)
# Registered after BROWSER below, so the tab order reads TESTS, BROWSER, LOG.

$tabBrowser = New-Object System.Windows.Forms.Panel
$tabBrowser.Padding = New-Object System.Windows.Forms.Padding(0)

$srcBox = New-Object System.Windows.Forms.RichTextBox
$srcBox.Name = 'srcBox'; $srcBox.Font = $mono
$srcBox.ReadOnly = $true; $srcBox.WordWrap = $false; $srcBox.ScrollBars = 'Both'
$srcHost = New-SbHost -Child $srcBox -Back $script:Pal.Base900
$sbSrcV = New-ThemedScrollBar -Track $script:Pal.Base900 `
    -GetInfo { Get-BoxScrollInfo $srcBox $true } `
    -SetPos { param($p) try { [CtShell]::ScrollTo($srcBox.Handle, $true, $p) } catch {} }
$sbSrcH = New-ThemedScrollBar -Horizontal -Track $script:Pal.Base900 `
    -GetInfo { Get-BoxScrollInfo $srcBox $false } `
    -SetPos { param($p) try { [CtShell]::ScrollTo($srcBox.Handle, $false, $p) } catch {} }
Add-BoxScrollSync $srcBox $sbSrcV $sbSrcH
$srcWrap = New-Object System.Windows.Forms.Panel
$srcWrap.Tag = 'card'; $srcWrap.Dock = 'Fill'; $srcWrap.Visible = $false
$srcWrap.Controls.Add($srcHost)
$srcWrap.Controls.Add($sbSrcH)
$srcWrap.Controls.Add($sbSrcV)
$script:SrcWrap = $srcWrap
$web = $null
try {
    $web = New-Object System.Windows.Forms.WebBrowser
    $web.Dock = 'Fill'
    # A viewer for one downloaded response, never a browser - script stripped, navigation cancelled.
    $web.ScriptErrorsSuppressed = $true
    $web.AllowNavigation = $true          # required: assigning DocumentText is a navigation
    $web.IsWebBrowserContextMenuEnabled = $false
    $web.WebBrowserShortcutsEnabled = $false
    $web.AllowWebBrowserDrop = $false
    $web.Add_Navigating({
            param($s, $e)
            # DocumentText writes go via about:blank; anything else would bypass the account and proxy under test.
            if ($e.Url -and $e.Url.Scheme -notin @('about')) {
                $e.Cancel = $true
                try { Add-BlockedRequest } catch {}
            }
        })
    $web.Add_NewWindow({ param($s, $e) $e.Cancel = $true })
}
catch { $web = $null }
$script:BrowserWeb = $web

$bHostPanel = New-Object System.Windows.Forms.Panel
$bHostPanel.Tag = 'card'
$bHostPanel.Controls.Add($srcWrap)
if ($web) { $bHostPanel.Controls.Add($web) }
$bFrame = New-Frame -Child $bHostPanel -Dock 'Fill'
$bFrame.Padding = New-Object System.Windows.Forms.Padding(0, 1, 0, 0)

$pnlBTop = New-Object System.Windows.Forms.Panel
$pnlBTop.Dock = 'Top'; $pnlBTop.Height = 104
$bx = 14
$lblB = New-Object System.Windows.Forms.Label
$lblB.Text = 'Fetches the Target using the Run as account and proxy selected above, then renders what came back (page scripts never run).'
$lblB.Location = New-Object System.Drawing.Point($bx, 6); $lblB.AutoSize = $true; $lblB.MaximumSize = '1000,0'
$btnFetch = New-ActionButton 'Fetch && Render' 150
$btnFetch.Location = New-Object System.Drawing.Point($bx, 36)
$rbRendered = New-Object System.Windows.Forms.RadioButton
$rbRendered.Text = 'Rendered'; $rbRendered.Location = New-Object System.Drawing.Point(($bx + 174), 44); $rbRendered.AutoSize = $true; $rbRendered.Checked = $true
$rbSource = New-Object System.Windows.Forms.RadioButton
$rbSource.Text = 'HTML source'; $rbSource.Location = New-Object System.Drawing.Point(($bx + 278), 44); $rbSource.AutoSize = $true
$lblBStatus = New-Object System.Windows.Forms.Label
$lblBStatus.Text = ''; $lblBStatus.Location = New-Object System.Drawing.Point($bx, 76); $lblBStatus.AutoSize = $false
$lblBStatus.Size = New-Object System.Drawing.Size(1040, 22)
$lblBStatus.Anchor = 'Top,Left'
$lblBStatus.AutoEllipsis = $true
$lblBStatus.TextAlign = 'MiddleLeft'
$tipB = New-Object System.Windows.Forms.ToolTip
$tipB.SetToolTip($lblB, "Scripts are stripped before the response is rendered, and the pane cannot navigate anywhere.`r`nThat keeps the view faithful to what the server actually sent, and keeps remote code out of this (often elevated) process.")
$tipB.SetToolTip($rbRendered, "Renders the response with the site's own CSS and images, minus its scripts.")
$tipB.SetToolTip($rbSource, 'The raw bytes exactly as received, scripts included.')
$pnlBTop.Controls.AddRange(@($lblB, $btnFetch, $rbRendered, $rbSource, $lblBStatus))
$script:FitBStatus = { try { $lblBStatus.Width = $pnlBTop.ClientSize.Width - $bx - 4 } catch {} }
$pnlBTop.Add_SizeChanged($script:FitBStatus)

$script:BStatusBase = ''
$script:NavBlocked = 0
function Set-BStatus {
    param([string]$Text, $Color)
    $script:BStatusBase = $Text
    $script:NavBlocked = 0
    $lblBStatus.Text = $Text
    if ($Color) { $lblBStatus.ForeColor = $Color }
}
function Add-BlockedRequest {
    $script:NavBlocked++
    $lblBStatus.Text = ('{0}   |   {1} external request{2} blocked' -f `
            $script:BStatusBase, $script:NavBlocked, $(if ($script:NavBlocked -eq 1) { '' } else { 's' }))
}

$tabBrowser.Controls.Add($bFrame)
$tabBrowser.Controls.Add($pnlBTop)
Add-Page 'BROWSER' $tabBrowser
Add-Page 'LOG' $tabLog

function Append-ToBox {
    param($Box, [string[]]$Lines, [System.Drawing.Color]$Color)
    if (-not $Box -or -not $Lines -or $Lines.Count -eq 0) { return }
    # A caller that names a colour means it; ordinary output gets its headings picked out.
    if ($null -ne $Color) {
        $Box.SelectionColor = $Color
        $Box.AppendText(($Lines -join "`r`n") + "`r`n")
    }
    else {
        $body = $Box.ForeColor
        # Appending line-by-line re-lays-out the control every time and locks the UI on large responses.
        $run = New-Object System.Collections.Generic.List[string]
        $runHead = $false
        $flush = {
            if ($run.Count) {
                $Box.SelectionColor = $(if ($runHead) { $script:Pal.Accent } else { $body })
                $Box.AppendText(($run -join "`r`n") + "`r`n")
                $run.Clear()
            }
        }
        $first = $true
        foreach ($ln in $Lines) {
            $isHead = [bool]($ln -match $script:HeadingRx)
            if (-not $first -and $isHead -ne $runHead) { & $flush }
            $runHead = $isHead; $first = $false
            $run.Add($ln)
        }
        & $flush
    }
    $Box.SelectionStart = $Box.TextLength
    # The raw log is usually on a hidden page, and scrolling an unseen control costs on every tick.
    if ($Box.Visible -and $Box.IsHandleCreated) { try { $Box.ScrollToCaret() } catch {} }
}

# Anything unrecognised becomes an INFO card - the parser never discards output.
$script:CardSectionRx = '^\s*(?:={3,}|#{3,})\s*(?<t>(?=[^=#\s])[^=#]*[^=#\s])\s*(?:={3,}|#{3,})\s*$'

function Get-CardStatus {
    param([string[]]$Lines)
    $text = ($Lines -join "`n")
    if ($text -match '(?m)^\s*RESULT\s*:\s*(?:PASS|OK)\b') { return 'PASS' }
    if ($text -match '(?m)^\s*RESULT\s*:\s*FAIL') { return 'FAIL' }
    if ($text -match '(?m)^\s*(?:ABORTED|RESULT\s*:\s*(?:WEAK|WARN|REACHED))') { return 'WARN' }
    if ($text -match '(?m)^\s*(?:WARNING|.*TLS INTERCEPTION DETECTED)') { return 'WARN' }
    if ($text -match '(?m)^\s*(?:\[SYSTEM\] )?ERROR\s*:') { return 'FAIL' }
    return 'INFO'
}

# One line that answers "so what". Ordered by how directly each pattern states the outcome.
function Get-CardSummary {
    param([string[]]$Lines, [string]$Status)
    foreach ($rx in @(
            '(?m)^\s*RESULT\s*:\s*(?:PASS|FAIL|WEAK|WARN|OK)\s*-\s*(.+?)\s*$',
            '(?m)^\s*ABORTED\s*-\s*(.+?)\s*$',
            '(?m)^\s*(?:\[SYSTEM\] )?ERROR\s*:\s*(.+?)\s*$',
            '(?m)^\s*Proxy wants\s*:\s*(.+?)\s*$',
            '(?m)^\s*Status\s*:\s*(.+?)\s*$',
            '(?m)^\s*Summary\s*:\s*(.+?)\s*$',
            '(?m)^\s*RESULT\s*:\s*(.+?)\s*$'
        )) {
        $m = [regex]::Match(($Lines -join "`n"), $rx)
        if ($m.Success -and $m.Groups[1].Value.Trim()) { return $m.Groups[1].Value.Trim() }
    }
    foreach ($l in $Lines) {
        $t = "$l".Trim()
        if ($t -and $t -notmatch $script:CardSectionRx) { return $t }
    }
    return ''
}

function Split-IntoCardSections {
    param([string[]]$Lines)
    $sections = New-Object System.Collections.Generic.List[object]
    $cur = $null
    foreach ($l in $Lines) {
        $m = [regex]::Match([string]$l, $script:CardSectionRx)
        if ($m.Success -and $m.Groups['t'].Value.Trim()) {
            $cur = [pscustomobject]@{ Title = $m.Groups['t'].Value.Trim(); Lines = (New-Object System.Collections.Generic.List[string]) }
            $sections.Add($cur)
            continue
        }
        if (-not $cur) {
            # Output before any header (the SYSTEM preamble, for instance) still gets a home.
            $cur = [pscustomobject]@{ Title = 'Run details'; Lines = (New-Object System.Collections.Generic.List[string]) }
            $sections.Add($cur)
        }
        $cur.Lines.Add([string]$l)
    }
    foreach ($s in $sections) {
        while ($s.Lines.Count -gt 0 -and -not "$($s.Lines[$s.Lines.Count-1])".Trim()) { $s.Lines.RemoveAt($s.Lines.Count - 1) }
    }
    return @($sections | Where-Object { $_.Lines.Count -gt 0 })
}

# One shared block, and children are found by Name: Add-Member attaches to the PSObject wrapper.
function Get-CardPart {
    param($Card, [string]$Name)
    try {
        $hit = $Card.Controls[$Name]
        if ($hit) { return $hit }
        $hd = $Card.Controls['cardHead']
        if ($hd) { return $hd.Controls[$Name] }
    }
    catch {}
    return $null
}

$script:CardToggle = {
    try {
        $c = $this
        while ($c -and [string]$c.Tag -notlike 'resultcard*') { $c = $c.Parent }
        if (-not $c) { return }
        $dt = Get-CardPart $c 'cardDetail'
        if (-not $dt) { return }
        $h = 120
        try { if ($null -ne $c.CardH) { $h = [int]$c.CardH } } catch {}
        if ([string]$c.Tag -match ':(\d+)$') { $h = [int]$Matches[1] }
        $open = -not $dt.Visible
        $dt.Visible = $open
        $c.Height = if ($open) { 43 + $h } else { 44 }
        $cv = Get-CardPart $c 'cardChevron'
        if ($cv) { $cv.Text = if ($open) { '-' } else { '+' } }
        # An open card can be wider than the pane, so re-measure and tell the drawn bars.
        Set-CardWidths
        Sync-ScrollBars
    }
    catch {}
}

# Pinned to the visible right edge, because the card's own right edge may have scrolled away.
function Set-CardChevron {
    param($Card)
    try {
        $cv = Get-CardPart $Card 'cardChevron'
        if (-not $cv) { return }
        $x = [Math]::Min($Card.Width - 32, ($cardsHost.ClientSize.Width - $Card.Left - 32))
        if ($x -lt 24) { $x = 24 }
        if ($cv.Left -ne $x) { $cv.Left = $x }
        if ($cv.Top -ne 12) { $cv.Top = 12 }
    }
    catch {}
}
function Set-CardChevrons {
    foreach ($c in @($pnlCards.Controls)) { Set-CardChevron $c }
}
$script:CardReflow = { Set-CardChevron $this }

function New-StatusChip {
    param([string]$Status)
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Status
    $l.Font = $script:UiFontSec
    $l.TextAlign = 'MiddleCenter'
    $l.AutoSize = $false
    $l.Size = New-Object System.Drawing.Size(58, 21)
    $l.Location = New-Object System.Drawing.Point(12, 11)
    switch ($Status) {
        'PASS' { $l.BackColor = [System.Drawing.Color]::FromArgb(30, 62, 48); $l.ForeColor = $script:Pal.Success }
        'FAIL' { $l.BackColor = [System.Drawing.Color]::FromArgb(66, 27, 42); $l.ForeColor = $script:Pal.Error }
        'WARN' { $l.BackColor = [System.Drawing.Color]::FromArgb(64, 52, 16); $l.ForeColor = $script:Pal.Warning }
        default { $l.BackColor = [System.Drawing.Color]::FromArgb(22, 48, 68); $l.ForeColor = $script:Pal.Blue }
    }
    Set-RoundedRegion $l 5
    return $l
}

# A RichTextBox adds its own leading, so measure a real one rather than trusting Font.Height.
$script:MonoCell = $null
function Get-MonoCell {
    if ($script:MonoCell) { return $script:MonoCell }
    $w = 9.0; $h = 18.0
    $probe = $null
    try {
        $probe = New-Object System.Windows.Forms.RichTextBox
        $probe.Font = $script:MonoFont
        $probe.WordWrap = $false
        $probe.BorderStyle = 'None'
        $probe.ScrollBars = 'None'
        $probe.Size = New-Object System.Drawing.Size(4000, 600)
        $null = $probe.Handle
        $probe.Text = ((1..10 | ForEach-Object { 'X' * 80 }) -join "`r`n")
        $p0 = $probe.GetPositionFromCharIndex(0)
        $p9 = $probe.GetPositionFromCharIndex($probe.GetFirstCharIndexFromLine(9))
        $pe = $probe.GetPositionFromCharIndex(79)
        if ($p9.Y -gt $p0.Y) { $h = [double]($p9.Y - $p0.Y) / 9.0 }
        if ($pe.X -gt $p0.X) { $w = [double]($pe.X - $p0.X) / 79.0 }
    }
    catch {
    }
    finally { if ($probe) { try { $probe.Dispose() } catch {} } }
    $script:MonoCell = @{ W = $w; H = $h }
    return $script:MonoCell
}

# Created collapsed; expanding just changes the height, which the FlowLayoutPanel re-flows.
function New-ResultCard {
    param([string]$Title, [string[]]$Lines, [string]$Status)

    $card = New-Object System.Windows.Forms.Panel
    $card.Height = 44
    $card.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 8)
    $card.BackColor = $script:Pal.Base900

    $hd = New-Object System.Windows.Forms.Panel
    $hd.Name = 'cardHead'
    $hd.Dock = 'Top'; $hd.Height = 43; $hd.BackColor = $script:Pal.Base900
    $hd.Cursor = [System.Windows.Forms.Cursors]::Hand

    $chip = New-StatusChip $Status

    $nm = New-Object System.Windows.Forms.Label
    $nm.Text = $Title; $nm.AutoSize = $true; $nm.Font = $script:UiFontBold
    $nm.ForeColor = $script:Pal.Text
    $nm.Location = New-Object System.Drawing.Point(80, 13)

    $cv = New-Object System.Windows.Forms.Label
    $cv.Name = 'cardChevron'
    $cv.Text = '+'; $cv.AutoSize = $false; $cv.Size = New-Object System.Drawing.Size(20, 20)
    $cv.TextAlign = 'MiddleCenter'; $cv.Font = $script:UiFontBold
    $cv.ForeColor = $script:Pal.TextDim
    $cv.Anchor = 'Top,Left'

    $hd.Controls.AddRange(@($chip, $nm, $cv))

    $dt = New-Object System.Windows.Forms.RichTextBox
    $dt.Name = 'cardDetail'
    $dt.Multiline = $true; $dt.ReadOnly = $true; $dt.WordWrap = $false
    $dt.ScrollBars = 'None'; $dt.BorderStyle = 'None'
    $dt.Font = $script:MonoFont
    $dt.BackColor = [System.Drawing.Color]::FromArgb(16, 16, 26)
    $dt.ForeColor = $script:Pal.OutText
    $dt.Dock = 'Fill'
    $dt.Visible = $false
    $dt.Text = ($Lines -join "`r`n")
    $dt.Add_HandleCreated({ try { $null = [CtShell]::DarkControl($this.Handle) } catch {} })

    $card.Controls.Add($dt)
    $card.Controls.Add($hd)
    # Sized to hold the whole section, since the detail box has no scrollbars of its own.
    $m = Get-MonoCell
    $longest = 0
    foreach ($ln in $Lines) { if ($ln.Length -gt $longest) { $longest = $ln.Length } }
    $wanted = [int][Math]::Min(12000, [Math]::Max(90, [Math]::Ceiling($Lines.Count * $m.H) + 18))
    $card.Tag = 'resultcard'
    # Natural width of the widest line, used to widen the column when this card is open.
    $card | Add-Member -NotePropertyName CardH -NotePropertyValue $wanted -Force
    $card | Add-Member -NotePropertyName CardW -NotePropertyValue ([int]([Math]::Ceiling($longest * $m.W) + 34)) -Force

    # Walks up to the card rather than assuming a nesting depth, so the header can gain controls.
    $hd.Add_Click($script:CardToggle)
    foreach ($child in @($chip, $nm, $cv)) {
        $child.Cursor = [System.Windows.Forms.Cursors]::Hand
        $child.Add_Click($script:CardToggle)
    }

    $card.Add_SizeChanged($script:CardReflow)
    return $card
}

# KeepBanner lets Set-VerdictRunning take the banner over without it flickering off and back.
function Clear-ResultCards {
    param([switch]$KeepBanner)
    $pnlCards.SuspendLayout()
    try {
        foreach ($c in @($pnlCards.Controls)) { $pnlCards.Controls.Remove($c); try { $c.Dispose() } catch {} }
    }
    finally { $pnlCards.ResumeLayout() }
    if (-not $KeepBanner) { $pnlVerdict.Visible = $false; $pnlVerdict.Height = 0 }
}

# Section headers arrive as each check starts, so counting them gives a real "x of y".
function Set-VerdictRunning {
    param([int]$Current, [int]$Total, [string]$Name, [switch]$WaitingForSystem)
    $script:VerdictIsRunning = $true
    $script:VerdictColor = $script:Pal.Blue
    if ($WaitingForSystem -and $Current -le 0) {
        $lblVerdictH.Text = ('Running {0} check{1} as SYSTEM' -f $Total, $(if ($Total -eq 1) { '' } else { 's' }))
        $lblVerdictP.Text = 'Waiting for the one-shot scheduled task. Live progress appears on the LOG tab.'
    }
    else {
        $n = [Math]::Max(1, [Math]::Min($Current, $Total))
        $lblVerdictH.Text = ('Running check {0} of {1}' -f $n, $Total)
        $lblVerdictP.Text = if ($Name) { $Name } else { 'Starting...' }
    }
    $lblVerdictH.ForeColor = $script:Pal.Blue
    $lblVerdictP.ForeColor = $script:Pal.TextDim
    $pnlVerdict.BackColor = $script:Pal.Base800
    if (-not $pnlVerdict.Visible) { $pnlVerdict.Height = 76; $pnlVerdict.Visible = $true }
    Set-VerdictTextWidth
    $pnlVerdict.Invalidate()
}

# Counts only checks that reported a verdict - context sections are cards, not checks.
function Set-Verdict {
    param([int]$Pass, [int]$Fail, [int]$Warn, [int]$Info, [string]$Detail)
    $graded = $Pass + $Fail + $Warn
    $total = $graded + $Info
    $acct = $script:Acct
    if ($total -le 0) {
        $col = $script:Pal.TextDim
        $lblVerdictH.Text = ('Run finished as {0}, but no recognisable check output was returned' -f $acct)
        if (-not $Detail) { $Detail = 'The full transcript is on the LOG tab.' }
    }
    elseif ($Fail -gt 0) {
        $col = $script:Pal.Error
        $lblVerdictH.Text = ('{0} of {1} checks failed as {2}' -f $Fail, $graded, $acct)
    }
    elseif ($Warn -gt 0) {
        $col = $script:Pal.Warning
        $lblVerdictH.Text = ('{0} of {1} checks need attention as {2}' -f $Warn, $graded, $acct)
    }
    elseif ($Pass -gt 0) {
        $col = $script:Pal.Success
        $lblVerdictH.Text = ('{0} of {1} checks passed as {2}, none failed' -f $Pass, $graded, $acct)
    }
    else {
        $col = $script:Pal.Blue
        $lblVerdictH.Text = ('{0} section{1} returned as {2}, but nothing reported a pass or fail' -f $Info, $(if ($Info -eq 1) { '' } else { 's' }), $acct)
    }
    $lblVerdictH.ForeColor = $col
    $script:VerdictIsRunning = $false
    $script:VerdictColor = $col
    $lblVerdictP.Text = $Detail
    $lblVerdictP.ForeColor = $script:Pal.TextDim
    $pnlVerdict.BackColor = $script:Pal.Base800
    $pnlVerdict.Height = 76
    $pnlVerdict.Visible = $true
    try { Set-VerdictTextWidth } catch {}
    $pnlVerdict.Invalidate()
}

function Add-ResultCards {
    param([string[]]$Lines)
    $sections = @()
    if ($Lines -and $Lines.Count -gt 0) { $sections = @(Split-IntoCardSections -Lines $Lines) }
    if ($sections.Count -eq 0) {
        Set-Verdict -Pass 0 -Fail 0 -Warn 0 -Info 0 -Detail 'Nothing was parsed out of the run. The full transcript is on the LOG tab.'
        return
    }

    $p = 0; $f = 0; $w = 0; $i = 0; $firstBad = ''
    # ResumeLayout in finally, or a throw leaves the panel suspended and no card ever paints.
    $pnlCards.SuspendLayout()
    try {
        foreach ($c in @($pnlCards.Controls)) { $pnlCards.Controls.Remove($c); try { $c.Dispose() } catch {} }
        $cw = [Math]::Max(320, $cardsHost.ClientSize.Width - 20)
        # One malformed section must not cost the whole set - it gets its own FAILED card instead.
        foreach ($s in $sections) {
            try {
                $st = Get-CardStatus  -Lines $s.Lines
                $sum = Get-CardSummary -Lines $s.Lines -Status $st
                switch ($st) { 'PASS' { $p++ } 'FAIL' { $f++ } 'WARN' { $w++ } default { $i++ } }
                if (-not $firstBad -and ($st -eq 'FAIL' -or $st -eq 'WARN')) { $firstBad = ('{0}: {1}' -f $s.Title, $sum) }
                $card = New-ResultCard -Title $s.Title -Lines $s.Lines -Status $st
                # Measured off the visible frame, so adding a card cannot start a resize loop.
                $card.Width = $cw
                $pnlCards.Controls.Add($card)
            }
            catch {
                $i++
                $why = ('{0}: {1}' -f $_.Exception.GetType().Name, $_.Exception.Message)
                if (-not $firstBad) { $firstBad = ('{0} could not be rendered - {1}' -f $s.Title, $why) }
                try {
                    $bad = New-ResultCard -Title ($s.Title + '  (render failed)') `
                        -Lines (@($why, '') + @($s.Lines)) -Status 'WARN'
                    $bad.Width = $cw
                    $pnlCards.Controls.Add($bad)
                }
                catch {}
            }
        }
    }
    finally { $pnlCards.ResumeLayout() }
    if (-not $firstBad) { $firstBad = 'No problems found on the checks that were run. Open a card for its full output.' }
    Set-Verdict -Pass $p -Fail $f -Warn $w -Info $i -Detail $firstBad
}

# Measured off the HOST's width, not the oversized pane's, so widening cannot loop.
$script:CardResizing = $false
function Get-CardColumnWidth {
    $w = [Math]::Max(320, $cardsHost.ClientSize.Width - 20)
    foreach ($c in @($pnlCards.Controls)) {
        try {
            $dt = $c.Controls['cardDetail']
            if ($dt -and $dt.Visible -and $null -ne $c.CardW -and [int]$c.CardW -gt $w) { $w = [int]$c.CardW }
        }
        catch {}
    }
    return $w
}
function Set-CardWidths {
    if ($script:CardResizing) { return }
    $script:CardResizing = $true
    try {
        $w = Get-CardColumnWidth
        $pnlCards.SuspendLayout()
        try {
            foreach ($c in @($pnlCards.Controls)) { if ($c.Width -ne $w) { $c.Width = $w } }
        }
        finally { $pnlCards.ResumeLayout() }
        Set-CardChevrons
        if ($pnlVerdict.Visible) { Set-VerdictTextWidth }
    }
    catch {
    }
    finally { $script:CardResizing = $false }
}
$pnlCards.Add_Resize({ Set-CardWidths })

function Set-BoxText {
    param($Box, [string]$Text, [System.Drawing.Color]$Color)
    if (-not $Box) { return }
    $Box.Clear()
    if ($null -ne $Color) { $Box.SelectionColor = $Color } else { $Box.SelectionColor = $Box.ForeColor }
    $Box.AppendText([string]$Text)
    $Box.SelectionStart = 0
    if ($Box.Visible -and $Box.IsHandleCreated) { try { $Box.ScrollToCaret() } catch {} }
}

function Update-AccountUi {
    $isSys = ($script:Acct -eq 'SYSTEM')
    $script:CtxGuard = $true
    try {
        if ($isSys) { $rbCtxSys.Checked = $true } else { $rbCtxUser.Checked = $true }
    }
    finally { $script:CtxGuard = $false }

    $rbCtxUser.Left = $lblRunAs.Right + 22
    $rbCtxSys.Left = $rbCtxUser.Right + 24

    if ($script:IsAdmin) {
        $lblSysNote.Text = ''
    }
    else {
        $lblSysNote.Text = 'Needs an elevated session.'
        $lblSysNote.ForeColor = $script:Pal.Error
    }
    $lblSysNote.Left = $rbCtxSys.Right + 24

    $who = if ($isSys) { 'SYSTEM' } else { $script:MeName }
    $lblWinInetCap.Text = ('Windows (WinINET) - {0}' -f $who)
    if ($script:ToolTips) {
        $wiTip = ("The per-account WinINET proxy for {0}. The Publisher falls back to SYSTEM's copy when no proxy is set in the Publisher itself." -f $who)
        $script:ToolTips.SetToolTip($lblWinInetCap, $wiTip)
        $script:ToolTips.SetToolTip($lblLiveProxy, $wiTip)
    }
    $vx = [Math]::Max(($lblWinInetCap.Right + 20), ($lblWinHttpCap.Right + 20))
    $lblLiveProxy.Left = $vx
    $lblWinHttp.Left = $vx
    $room = $btnRefreshProxy.Left - $vx - 24
    if ($room -gt 120) {
        $lblLiveProxy.MaximumSize = New-Object System.Drawing.Size($room, 0)
        $lblWinHttp.MaximumSize = New-Object System.Drawing.Size($room, 0)
    }
    Update-Step3Caption
}

function Update-Step3Caption {
    if (-not $lblCtxPill) { return }
    $isSys = ($script:Acct -eq 'SYSTEM')
    $lblCtxPill.Text = ('Running as: {0}' -f $(if ($isSys) { 'NT AUTHORITY\SYSTEM' } else { $script:MeName }))
    $lblCtxPill.ForeColor = if ($isSys) { $script:Pal.Warning } else { $script:Pal.Accent }
    try {
        if ($script:ToolTips) {
            $script:ToolTips.SetToolTip($lblCtxPill, ("{0}`r`nBuild: {1}" -f $script:SelfPath, $script:BuildStamp))
        }
    }
    catch {}
}

function Set-Account {
    param([string]$Account)
    if ($Account -eq $script:Acct) { return }
    $script:Acct = $Account
    Update-AccountUi
    Update-LiveProxy
    Set-BStatus '' $script:Pal.TextDim
}

function Show-SystemInfo {
    if ($script:SysInfoDlg) { try { $script:SysInfoDlg.Activate() } catch {}; return }

    $dlg = New-Object System.Windows.Forms.Form
    $script:SysInfoDlg = $dlg
    $dlg.Text = 'Testing as SYSTEM'
    Set-DarkFrame $dlg
    $dlg.StartPosition = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'; $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false
    $dlg.ClientSize = New-Object System.Drawing.Size(660, 470)
    $dlg.Font = $script:UiFont
    $dlg.BackColor = $script:Pal.Base800
    $dlg.ForeColor = $script:Pal.Text

    $lblH = New-SectionLabel -Text 'Why SYSTEM' -Location '16,14'
    $body = New-Object System.Windows.Forms.Label
    $body.Location = '16,40'; $body.AutoSize = $true; $body.MaximumSize = '628,0'
    $body.Text = @"
The Patch My PC Publishing Service runs as NT AUTHORITY\SYSTEM, and it downloads content using the same .NET and WinINET plumbing as Internet Explorer. Proxy settings, TLS configuration and web-filter policy can all differ between your account and SYSTEM, so a URL that works for you can still fail for the service.

Testing as SYSTEM reproduces what the service actually sees. Historically that meant PsExec plus Internet Explorer, which is no longer available on current servers.
"@

    $lblH2 = New-SectionLabel -Text 'How this tool does it' -Location '16,196'
    $body2 = New-Object System.Windows.Forms.Label
    $body2.Location = '16,222'; $body2.AutoSize = $true; $body2.MaximumSize = '628,0'
    $body2.Text = @"
Windows only hands a real SYSTEM token to a service or a scheduled task, so this tool registers a task, runs one batch of tests through it, reads the results back and removes it. No PsExec, and nothing is installed.

    Task     \$($script:TaskName)
    Runs     NT AUTHORITY\SYSTEM, highest privileges, only when you press a test button
    Trigger  disabled, so Windows never starts it on its own
    Expiry   self-deletes 60 minutes after it is created

The task is removed when this tool closes, swept up on the next launch if the tool was killed, and deleted by Windows at expiry regardless. Deletion is guarded by a marker in the task description, so a task of the same name that this tool did not create is never touched.

Parameters are passed in a DPAPI-encrypted, ACL-restricted file that is overwritten and deleted afterwards, so a proxy password is never written to disk in clear. Running the task by hand produces nothing.

Registering a task as NT AUTHORITY\SYSTEM needs local administrator rights, which is why this option requires an elevated session.
"@

    $btnOk = New-ActionButton 'Close' 88 26
    $btnOk.Add_Click({ $script:SysInfoDlg.Close() })
    $dlg.AcceptButton = $btnOk
    $dlg.CancelButton = $btnOk

    $btnOpenTs = New-ActionButton 'Open Task Scheduler' 168 26
    $btnOpenTs.Enabled = $script:IsAdmin
    $btnOpenTs.Add_Click({
            $rep = New-Object System.Collections.Generic.List[string]
            $rep.Add('')
            try {
                Start-Process -FilePath 'mmc.exe' -ArgumentList 'taskschd.msc' -ErrorAction Stop
                $rep.Add(("Task Scheduler opening - look in Task Scheduler Library for '{0}'." -f $script:TaskName))
            }
            catch {
                $rep.Add(('Could not open Task Scheduler: {0}' -f $_.Exception.Message))
                $rep.Add('Start it manually with: taskschd.msc')
            }
            $script:SysInfoDlg.Close()
        })

    $dlg.Controls.AddRange(@($lblH, $body, $lblH2, $body2, $btnOpenTs, $btnOk))
    $lblH2.Top = $body.Bottom + 20
    $body2.Top = $lblH2.Bottom + 8
    $dlg.ClientSize = New-Object System.Drawing.Size(660, ($body2.Bottom + 66))
    $btnOk.Location = New-Object System.Drawing.Point((660 - $btnOk.Width - 16), ($body2.Bottom + 20))
    $btnOk.Anchor = 'Bottom,Right'
    $btnOpenTs.Location = New-Object System.Drawing.Point(16, ($body2.Bottom + 20))
    $btnOpenTs.Anchor = 'Bottom,Left'
    Set-ControlTheme $dlg
    $dlg.Add_FormClosed({ $script:SysInfoDlg = $null })
    [void]$dlg.ShowDialog($form)
}

$script:CtxGuard = $false
$rbCtxUser.Add_CheckedChanged({ if (-not $script:CtxGuard -and $rbCtxUser.Checked) { Set-Account 'User' } })
$rbCtxSys.Add_CheckedChanged({ if (-not $script:CtxGuard -and $rbCtxSys.Checked) { Set-Account 'SYSTEM' } })

# Checks read the proxy at the moment they run, so this poll only keeps the summary honest.
$script:ProxySig = @{}
$script:WinHttpSig = $null
function Update-LiveProxy {
    param([switch]$Notify)

    try {
        $wh = Get-WinHttpProxy
        if ($wh) {
            $lblWinHttp.Text = $wh.Summary
            $lblWinHttp.ForeColor =
            if (-not $wh.Readable) { $script:Pal.Warning }
            elseif ($wh.UseProxy) { $script:Pal.Text }
            else { $script:Pal.TextDim }
            $script:WinHttpSig = $wh.Summary
        }
    }
    catch {}

    $s = $null
    try { $s = Get-ProxySignature -Account $script:Acct } catch { return }
    if (-not $s) { return }

    $prev = $script:ProxySig[$script:Acct]
    $script:ProxySig[$script:Acct] = $s.Sig

    $lblLiveProxy.Text = ('{0}' -f $s.Summary)
    $lblLiveProxy.ForeColor =
    if (-not $s.Readable) { $script:Pal.Warning }
    elseif ($s.Summary -like 'none configured*') { $script:Pal.TextDim }
    else { $script:Pal.Accent }

    if ($Notify -and $prev -and $prev -ne $s.Sig) {
        $t = Get-Date -Format 'HH:mm:ss'
        $lblLiveProxy.ForeColor = $script:Pal.Warning
        if ($s.UsesPac -and $script:Acct -eq 'User') {
            # .NET caches the PAC resolver for the life of the process, so this is the one case needing a restart.
            Set-Status -Keep ("PAC/WPAD config changed at {0} - restart the tool to re-evaluate it as the logged-on user." -f $t)
        }
        else {
            Set-Status -Keep ("Proxy config for {0} changed at {1} - picked up automatically, re-run to compare." -f $script:Acct, $t)
        }

    }
}

$script:ProxyWatch = New-Object System.Windows.Forms.Timer
$script:ProxyWatch.Interval = 4000
$script:ProxyWatch.Add_Tick({ try { Update-LiveProxy -Notify } catch {} })

$script:ToolTips = New-Object System.Windows.Forms.ToolTip
$script:ToolTips.SetToolTip($btnRefreshProxy, "Re-read both proxy stacks from the registry right now.")
$script:ToolTips.SetToolTip($btnEditProxy, @"
Choose which of the two independent Windows proxy stacks to edit:
Per-account (WinINET)  - browsers, the .NET default proxy, and the Publishing Service.
Machine-wide (WinHTTP) - BITS, Windows Update and the ConfigMgr client.
"@)
$whTip = @"
The machine-wide WinHTTP proxy - what 'netsh winhttp show proxy' reports.
BITS, Windows Update scanning and the ConfigMgr client typically leverage it.

The Publishing Service does NOT read this one. Its own proxy settings win, and with
none set it falls back to the WinINET proxy of the account it runs as (SYSTEM) -
the row above. So a proxy here does not mean the Publisher is using it, and
'none configured (direct)' here does not mean the Publisher is going direct.
"@
$script:ToolTips.SetToolTip($lblWinHttpCap, $whTip)
$script:ToolTips.SetToolTip($lblWinHttp, $whTip)

$btnRefreshProxy.Add_Click({
        $script:ProxySig.Remove($script:Acct)
        Update-LiveProxy
        Set-Status ('Proxy settings re-read at {0}.' -f (Get-Date -Format 'HH:mm:ss'))
    })

# Writes the same values Windows' own proxy UI writes, for whichever account is selected.
function Show-ProxyEditor {
    if ($script:ProxyDlg) { try { $script:ProxyDlg.Activate() } catch {}; return }
    $forSystem = ($script:Acct -eq 'SYSTEM')
    $hive = if ($forSystem) { 'Registry::HKEY_USERS\S-1-5-18\Software\Microsoft\Windows\CurrentVersion\Internet Settings' }
    else { 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' }
    $who = if ($forSystem) { 'SYSTEM' } else { $script:MeName }
    $canWrite = (-not $forSystem) -or $script:IsAdmin

    $dlg = New-Object System.Windows.Forms.Form
    $script:ProxyDlg = $dlg
    $dlg.Text = ('Edit proxy - {0}' -f $who)
    Set-DarkFrame $dlg
    $dlg.StartPosition = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'; $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false
    $dlg.ClientSize = New-Object System.Drawing.Size(688, 532)
    $dlg.Font = $script:UiFont
    $dlg.BackColor = $script:Pal.Base800
    $dlg.ForeColor = $script:Pal.Text

    $lblCtx = New-Object System.Windows.Forms.Label
    $lblCtx.Location = '16,14'; $lblCtx.AutoSize = $true; $lblCtx.MaximumSize = '656,0'
    $lblCtx.Font = $script:UiFontBold
    $lblCtx.Text = if ($forSystem) { 'SYSTEM  -  the account Windows services run as' }
    else { ('Logged-on user  -  {0}' -f $script:MeName) }

    $lblElev = New-Object System.Windows.Forms.Label
    $lblElev.AutoSize = $true; $lblElev.MaximumSize = '656,0'
    $lblElev.Visible = (-not $canWrite)
    $lblElev.Text = "Writing SYSTEM's proxy needs an elevated session - re-launch this tool as administrator."

    # WinINET and WinHTTP are parallel stacks, not layers, so the machine-wide one has its own editor.
    $lblWinHttpNote = New-Object System.Windows.Forms.Label
    $lblWinHttpNote.AutoSize = $true; $lblWinHttpNote.MaximumSize = '656,0'
    $lblWinHttpNote.Text = "Sets this account's WinINET proxy. The machine-wide WinHTTP proxy is a separate setting - pick it from the 'Edit proxy...' menu. Change the account under 'Run as' to edit the other one."
    $tipP = New-Object System.Windows.Forms.ToolTip
    $tipP.AutoPopDelay = 32000; $tipP.InitialDelay = 350; $tipP.ReshowDelay = 100
    $tipP.SetToolTip($lblWinHttpNote, @"
Windows has two independent proxy stacks. Neither overrides the other - an application
gets whichever one it was written against:

  WinINET  (per account, this dialog)      - browsers, most desktop apps, and the Publishing
                                             Service (it falls back to SYSTEM's copy)
  WinHTTP  (machine-wide, its own dialog)  - BITS, Windows Update scanning, ConfigMgr client

Keeping the two consistent is usually what you want on a server.
WinHTTP only stores a static proxy and bypass list - it cannot hold a PAC script and
cannot auto-detect (WPAD).
"@)

    $rule1 = New-Rule -Location '16,0' -Width 656

    $chkAuto = New-Object System.Windows.Forms.CheckBox
    $chkAuto.Text = 'Automatically detect settings (WPAD)'; $chkAuto.AutoSize = $true
    $rbNoProxy = New-Object System.Windows.Forms.RadioButton
    $rbNoProxy.Text = 'No proxy (direct connection)'; $rbNoProxy.AutoSize = $true
    $rbManual = New-Object System.Windows.Forms.RadioButton
    $rbManual.Text = 'Use a proxy server'; $rbManual.AutoSize = $true

    $lblAddr = New-Object System.Windows.Forms.Label
    $lblAddr.Text = 'Address'; $lblAddr.AutoSize = $true
    $tpHost = New-Object System.Windows.Forms.TextBox
    $tpHost.Size = '272,23'
    $lblPortD = New-Object System.Windows.Forms.Label
    $lblPortD.Text = 'Port'; $lblPortD.AutoSize = $true
    $tpPort = New-Object System.Windows.Forms.TextBox
    $tpPort.Size = '76,23'

    $lblByp = New-Object System.Windows.Forms.Label
    $lblByp.Text = 'Bypass these addresses (one per line, * allowed):'
    $lblByp.AutoSize = $true
    $tpBypass = New-Object System.Windows.Forms.TextBox
    $tpBypass.Size = '608,58'; $tpBypass.Multiline = $true; $tpBypass.ScrollBars = 'Vertical'
    $chkLocal = New-Object System.Windows.Forms.CheckBox
    $chkLocal.Text = 'Bypass the proxy for local (intranet) addresses'; $chkLocal.AutoSize = $true

    $rbPac = New-Object System.Windows.Forms.RadioButton
    $rbPac.Text = 'Use an automatic configuration script (PAC)'; $rbPac.AutoSize = $true
    $tpPac = New-Object System.Windows.Forms.TextBox
    $tpPac.Size = '608,23'

    $lblWarn = New-Object System.Windows.Forms.Label
    $lblWarn.AutoSize = $true; $lblWarn.MaximumSize = '656,0'
    $lblWarn.Text = 'Checking for Group Policy...'

    $btnApply = New-ActionButton 'Apply' 84 30
    $btnCancel = New-ActionButton 'Cancel' 84 30
    $btnCancel.DialogResult = 'Cancel'; $dlg.CancelButton = $btnCancel

    $dlg.Controls.AddRange(@(
            $lblCtx, $lblElev, $lblWinHttpNote, $rule1,
            $chkAuto, $rbNoProxy, $rbManual, $lblAddr, $tpHost, $lblPortD, $tpPort,
            $lblByp, $tpBypass, $chkLocal, $rbPac, $tpPac, $lblWarn, $btnApply, $btnCancel
        ))

    $syncEnabled = {
        $m = $rbManual.Checked
        Set-BoxActive $tpHost $m; Set-BoxActive $tpPort $m; Set-BoxActive $tpBypass $m
        Set-CheckActive $chkLocal $m
        Set-BoxActive $tpPac $rbPac.Checked
    }
    $loadCurrent = {
        $en = 0; $srv = ''; $ovr = ''; $pac = ''
        $readOk = $true
        try {
            $k = Get-ItemProperty -Path $hive -ErrorAction Stop
            $en = [int]$k.ProxyEnable
            $srv = [string]$k.ProxyServer
            $ovr = [string]$k.ProxyOverride
            $pac = [string]$k.AutoConfigURL
        }
        catch { $readOk = $false }
        # Per-scheme values (http=a:1;https=b:2) - show the https entry, that is what matters here.
        if ($srv -match '=') {
            $pick = ($srv -split ';' | Where-Object { $_ -like 'https=*' } | Select-Object -First 1)
            if (-not $pick) { $pick = ($srv -split ';' | Where-Object { $_ -like 'http=*' } | Select-Object -First 1) }
            if ($pick) { $srv = ($pick -split '=', 2)[1] }
        }
        $h = $srv; $pt = ''
        if ($srv -match '^(.*):(\d+)$') { $h = $Matches[1]; $pt = $Matches[2] }
        $tpHost.Text = $h; $tpPort.Text = $pt
        $parts = @($ovr -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        $chkLocal.Checked = [bool](@($parts | Where-Object { $_ -eq '<local>' }).Count)
        $tpBypass.Lines = @($parts | Where-Object { $_ -ne '<local>' })
        $tpPac.Text = $pac
        if ($pac) { $rbPac.Checked = $true }
        elseif ($en -eq 1) { $rbManual.Checked = $true }
        else { $rbNoProxy.Checked = $true }

        # WPAD auto-detect only lives in the binary blob (flag 8), not in a plain value.
        $auto = $false
        try {
            $blob = (Get-ItemProperty -Path (Join-Path $hive 'Connections') -Name 'DefaultConnectionSettings' -ErrorAction Stop).DefaultConnectionSettings
            if ($blob -and $blob.Length -ge 12) { $auto = (([BitConverter]::ToInt32($blob, 8) -band 8) -ne 0) }
        }
        catch {}
        $chkAuto.Checked = $auto
        & $syncEnabled

        $pol = Get-ProxyPolicyInfo
        if (-not $readOk) {
            $lblWarn.Text = ("Could not read {0}'s current settings - it may not be loaded or readable from this session." -f $who)
        }
        elseif ($pol.Policies.Count) {
            $lblWarn.Text = ("POLICY DETECTED - these settings may be overwritten:`r`n" + (($pol.Policies | Select-Object -First 2) -join "`r`n"))
        }
        else {
            $lblWarn.Text = 'No proxy Group Policy found - management tools can still overwrite this at any time.'
        }
    }

    $rbNoProxy.Add_CheckedChanged($syncEnabled)
    $rbManual.Add_CheckedChanged($syncEnabled)
    $rbPac.Add_CheckedChanged($syncEnabled)

    $btnApply.Add_Click({
            if (-not $canWrite) {
                [void][System.Windows.Forms.MessageBox]::Show($dlg, "Writing SYSTEM's proxy needs an elevated session. Re-launch this tool as administrator, or switch 'Run as' to the logged-on user.", 'Edit proxy', 'OK', 'Warning')
                return
            }
            $useProxy = $rbManual.Checked
            $server = ''
            if ($useProxy) {
                if (-not $tpHost.Text.Trim()) {
                    [void][System.Windows.Forms.MessageBox]::Show($dlg, 'Enter the proxy address.', 'Edit proxy', 'OK', 'Warning'); return
                }
                $server = $tpHost.Text.Trim()
                if ($tpPort.Text.Trim()) { $server += ':' + $tpPort.Text.Trim() }
            }
            $byp = @()
            if ($useProxy) {
                $byp = @($tpBypass.Lines | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -ne '<local>' })
                if ($chkLocal.Checked) { $byp += '<local>' }
            }
            $bypass = ($byp -join ';')
            $pac = if ($rbPac.Checked) { $tpPac.Text.Trim() } else { '' }
            if ($rbPac.Checked -and -not $pac) {
                [void][System.Windows.Forms.MessageBox]::Show($dlg, 'Enter the .pac script URL.', 'Edit proxy', 'OK', 'Warning'); return
            }

            $what = if ($rbPac.Checked) { "PAC script $pac" } elseif ($useProxy) { "proxy $server" } else { 'no proxy (direct)' }
            if ($chkAuto.Checked) { $what += '  + auto-detect (WPAD)' }

            $res = Set-WinInetProxy -HivePath $hive -UseProxy $useProxy -ProxyServer $server -Bypass $bypass -PacUrl $pac -AutoDetect $chkAuto.Checked
            # Tell WinINET the settings moved, otherwise running apps keep the old ones.
            try { Send-WinInetChange | Out-Null } catch {}

            if (-not $res.Ok) {
                $errs = (($res.Lines | Where-Object { $_ -match 'ERROR' }) -join "`r`n")
                [void][System.Windows.Forms.MessageBox]::Show($dlg, ("The proxy could not be written.`r`n`r`n{0}" -f $errs), 'Edit proxy', 'OK', 'Error')
                return
            }

            Set-Status -Keep ('Windows proxy for {0} set to {1}' -f $who, $what)
            $wh = Get-WinHttpProxy
            $note = @('', '=== WINDOWS PROXY CHANGED ===',
                ('  Account        : {0}' -f $who),
                ('  WinINET set to : {0}' -f $what),
                '  Applies to     : every application running as that account.')
            if ($wh.UseProxy -ne $useProxy -or ($useProxy -and $wh.Server -ne $server)) {
                Set-Status -Keep ('Windows proxy for {0} set - machine WinHTTP still differs' -f $who)
                $note += ('  Machine WinHTTP: UNCHANGED and different - still reads {0}' -f $wh.Summary)
                $note += '                   That is a separate stack (BITS, Windows Update scanning, the ConfigMgr'
                $note += '                   client). The Publishing Service does not read it - with no proxy set in'
                $note += "                   the Publisher itself it falls back to SYSTEM's WinINET proxy above."
            }
            else {
                $note += ('  Machine WinHTTP: {0}' -f $wh.Summary)
            }
            Append-ToBox $outBox $note
            $script:ProxySig.Remove($script:Acct)
            Update-LiveProxy
            $dlg.DialogResult = 'OK'; $dlg.Close()
        })

    & $loadCurrent
    Set-ControlTheme $dlg
    & $syncEnabled
    $lblCtx.ForeColor = $script:Pal.Text
    $lblElev.ForeColor = $script:Pal.Warning
    $lblWarn.ForeColor = if ($lblWarn.Text -like 'POLICY DETECTED*' -or $lblWarn.Text -like 'Could not read*') { $script:Pal.Warning } else { $script:Pal.TextDim }
    $lblWinHttpNote.ForeColor = $script:Pal.TextDim

    # Stacked from a running cursor: the wrapped labels change height with account and elevation.
    $y = $lblCtx.Bottom + 6
    $lblWinHttpNote.Location = New-Object System.Drawing.Point(16, $y); $y = $lblWinHttpNote.Bottom + 8
    # Test $canWrite - the Visible getter reports EFFECTIVE visibility and is false until shown.
    if (-not $canWrite) { $lblElev.Location = New-Object System.Drawing.Point(16, $y); $y = $lblElev.Bottom + 8 }
    $rule1.Top = $y; $y = $rule1.Bottom + 12
    $chkAuto.Location = New-Object System.Drawing.Point(16, $y); $y = $chkAuto.Bottom + 10
    $rbNoProxy.Location = New-Object System.Drawing.Point(16, $y); $y = $rbNoProxy.Bottom + 4
    $rbManual.Location = New-Object System.Drawing.Point(16, $y); $y = $rbManual.Bottom + 8
    $tpHost.Location = New-Object System.Drawing.Point(110, $y)
    $lblAddr.Location = New-Object System.Drawing.Point(40, ($y + 3))
    $lblPortD.Location = New-Object System.Drawing.Point(398, ($y + 3))
    $tpPort.Location = New-Object System.Drawing.Point(436, $y); $y = $tpHost.Bottom + 10
    $lblByp.Location = New-Object System.Drawing.Point(40, $y); $y = $lblByp.Bottom + 6
    $tpBypass.Location = New-Object System.Drawing.Point(40, $y); $y = $tpBypass.Bottom + 8
    $chkLocal.Location = New-Object System.Drawing.Point(40, $y); $y = $chkLocal.Bottom + 12
    $rbPac.Location = New-Object System.Drawing.Point(16, $y); $y = $rbPac.Bottom + 6
    $tpPac.Location = New-Object System.Drawing.Point(40, $y); $y = $tpPac.Bottom + 14
    $lblWarn.Location = New-Object System.Drawing.Point(16, $y); $y = $lblWarn.Bottom + 14
    $btnApply.Location = New-Object System.Drawing.Point(496, $y)
    $btnCancel.Location = New-Object System.Drawing.Point(592, $y)
    $dlg.ClientSize = New-Object System.Drawing.Size(688, ($btnApply.Bottom + 16))

    [void]$dlg.ShowDialog($form)
    $dlg.Dispose()
    $script:ProxyDlg = $null
}
# One entry point for both proxy stacks - they are parallel settings, not a main and a side one.
$script:ProxyEditMenu = New-Object System.Windows.Forms.ContextMenuStrip
$script:ProxyEditMenu.ShowImageMargin = $false
$script:ProxyEditMenu.BackColor = $script:Pal.Base700
$script:ProxyEditMenu.ForeColor = $script:Pal.Text
$script:ProxyEditMenu.Font = $script:UiFont
$script:ProxyEditMenu.Renderer = New-Object System.Windows.Forms.ToolStripProfessionalRenderer

$miUserProxy = New-Object System.Windows.Forms.ToolStripMenuItem
$miUserProxy.Text = 'Windows proxy for this account (WinINET)...'
$miUserProxy.Add_Click({ Show-ProxyEditor })

$miMachineProxy = New-Object System.Windows.Forms.ToolStripMenuItem
$miMachineProxy.Text = 'Machine-wide proxy (WinHTTP)...'
$miMachineProxy.Add_Click({ Show-WinHttpEditor })

[void]$script:ProxyEditMenu.Items.Add($miUserProxy)
[void]$script:ProxyEditMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
[void]$script:ProxyEditMenu.Items.Add($miMachineProxy)

$btnEditProxy.Add_Click({
        $miUserProxy.Text = ('Windows proxy for {0} (WinINET)...' -f $(if ($script:Acct -eq 'SYSTEM') { 'SYSTEM' } else { $script:MeName }))
        $script:ProxyEditMenu.Show($btnEditProxy, 0, $btnEditProxy.Height)
    })

# One value for the whole computer, and what Windows services read, so changing it is deliberate.
function Show-WinHttpEditor {
    if ($script:WinHttpDlg) { try { $script:WinHttpDlg.Activate() } catch {}; return }
    $canWrite = $script:IsAdmin

    $dlg = New-Object System.Windows.Forms.Form
    $script:WinHttpDlg = $dlg
    $dlg.Text = 'Edit machine-wide WinHTTP proxy'
    Set-DarkFrame $dlg
    $dlg.StartPosition = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'; $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false
    $dlg.ClientSize = New-Object System.Drawing.Size(688, 434)
    $dlg.Font = $script:UiFont
    $dlg.BackColor = $script:Pal.Base800
    $dlg.ForeColor = $script:Pal.Text

    $lblCur = New-Object System.Windows.Forms.Label
    $lblCur.AutoSize = $true; $lblCur.MaximumSize = '656,0'
    $lblCur.Font = $script:UiFontBold

    $lblSub = New-Object System.Windows.Forms.Label
    $lblSub.AutoSize = $true; $lblSub.MaximumSize = '656,0'
    $lblSub.Text = 'One setting for the whole computer, read by BITS, Windows Update scanning and the ConfigMgr client. The Publishing Service does not use it - it falls back to SYSTEM''s per-account WinINET proxy. Independent of the per-account proxy, and it can only hold a static proxy (no PAC, no WPAD).'

    $lblElev = New-Object System.Windows.Forms.Label
    $lblElev.AutoSize = $true; $lblElev.MaximumSize = '656,0'
    $lblElev.Visible = (-not $canWrite)
    $lblElev.Text = 'Changing this needs an elevated session - re-launch this tool as administrator. You can still read the current value.'

    $rule1 = New-Rule -Location '16,0' -Width 656

    $rbWhNone = New-Object System.Windows.Forms.RadioButton
    $rbWhNone.Text = 'No proxy (direct connection)'; $rbWhNone.AutoSize = $true
    $rbWhProxy = New-Object System.Windows.Forms.RadioButton
    $rbWhProxy.Text = 'Use a proxy server'; $rbWhProxy.AutoSize = $true
    # Direct children of the dialog, so WinForms' own parent-scoped grouping already applies.

    $lblAddr = New-Object System.Windows.Forms.Label
    $lblAddr.Text = 'Address'; $lblAddr.Location = '40,0'; $lblAddr.AutoSize = $true
    $twHost = New-Object System.Windows.Forms.TextBox
    $twHost.Size = '272,23'
    $lblPortD = New-Object System.Windows.Forms.Label
    $lblPortD.Text = 'Port'; $lblPortD.AutoSize = $true
    $twPort = New-Object System.Windows.Forms.TextBox
    $twPort.Size = '76,23'

    $lblByp = New-Object System.Windows.Forms.Label
    $lblByp.Text = 'Bypass these addresses (one per line, * allowed):'
    $lblByp.AutoSize = $true
    $twBypass = New-Object System.Windows.Forms.TextBox
    $twBypass.Size = '608,58'; $twBypass.Multiline = $true; $twBypass.ScrollBars = 'Vertical'
    $chkWhLocal = New-Object System.Windows.Forms.CheckBox
    $chkWhLocal.Text = 'Bypass the proxy for local (intranet) addresses'; $chkWhLocal.AutoSize = $true

    $btnCopy = New-ActionButton 'Copy from account' 156 30
    $btnApply = New-ActionButton 'Apply' 84 30
    $btnCancel = New-ActionButton 'Cancel' 84 30
    $btnCancel.DialogResult = 'Cancel'; $dlg.CancelButton = $btnCancel

    # The controls are parented first so they measure with the dialog's font, not the default one.
    $dlg.Controls.AddRange(@(
            $lblCur, $lblSub, $lblElev, $rule1,
            $rbWhNone, $rbWhProxy, $lblAddr, $twHost, $lblPortD, $twPort,
            $lblByp, $twBypass, $chkWhLocal, $btnCopy, $btnApply, $btnCancel
        ))

    $tipW = New-Object System.Windows.Forms.ToolTip
    $tipW.AutoPopDelay = 32000; $tipW.InitialDelay = 350; $tipW.ReshowDelay = 100
    $tipW.SetToolTip($btnCopy, "Fills the fields below from the proxy configured for the account selected under 'Run as'.`r`nNothing is written until you press Apply.")

    $syncEnabled = {
        $m = $rbWhProxy.Checked
        Set-BoxActive $twHost $m; Set-BoxActive $twPort $m; Set-BoxActive $twBypass $m
        Set-CheckActive $chkWhLocal $m
    }
    $loadCurrent = {
        $wh = Get-WinHttpProxy
        $lblCur.Text = ('Currently: {0}' -f $wh.Summary)
        $h = $wh.Server; $pt = ''
        if ($wh.Server -match '^(.*):(\d+)$') { $h = $Matches[1]; $pt = $Matches[2] }
        $twHost.Text = $h; $twPort.Text = $pt
        $parts = @($wh.Bypass -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        $chkWhLocal.Checked = [bool](@($parts | Where-Object { $_ -eq '<local>' }).Count)
        $twBypass.Lines = @($parts | Where-Object { $_ -ne '<local>' })
        if ($wh.UseProxy) { $rbWhProxy.Checked = $true } else { $rbWhNone.Checked = $true }
        & $syncEnabled
    }

    $rbWhNone.Add_CheckedChanged($syncEnabled)
    $rbWhProxy.Add_CheckedChanged($syncEnabled)

    # Convenience only. PAC/WPAD accounts have nothing WinHTTP can express.
    $btnCopy.Add_Click({
            $sig = Get-ProxySignature -Account $script:Acct
            if ($sig.UsesPac) {
                [void][System.Windows.Forms.MessageBox]::Show($dlg,
                    ("{0} is configured with a PAC script or WPAD auto-detect.`r`n`r`nWinHTTP cannot express either - it only stores a static proxy. Read the PAC script to find the proxy it hands out for the URLs you care about, then enter that here." -f $script:Acct),
                    'Copy from account', 'OK', 'Warning')
                return
            }
            if ($sig.Summary -like 'none configured*') {
                $rbWhNone.Checked = $true; & $syncEnabled
                return
            }
            $srv = ($sig.Summary -split ' \(bypass:')[0].Trim()
            if ($srv -match '=') {
                $pick = ($srv -split ';' | Where-Object { $_ -like 'https=*' } | Select-Object -First 1)
                if (-not $pick) { $pick = ($srv -split ';' | Where-Object { $_ -like 'http=*' } | Select-Object -First 1) }
                if ($pick) { $srv = ($pick -split '=', 2)[1] }
            }
            $h = $srv; $pt = ''
            if ($srv -match '^(.*):(\d+)$') { $h = $Matches[1]; $pt = $Matches[2] }
            $rbWhProxy.Checked = $true
            $twHost.Text = $h; $twPort.Text = $pt
            if ($sig.Summary -match '\(bypass: (.+)\)') {
                $parts = @($Matches[1] -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                $chkWhLocal.Checked = [bool](@($parts | Where-Object { $_ -eq '<local>' }).Count)
                $twBypass.Lines = @($parts | Where-Object { $_ -ne '<local>' })
            }
            & $syncEnabled
        })

    $btnApply.Add_Click({
            if (-not $canWrite) {
                [void][System.Windows.Forms.MessageBox]::Show($dlg, 'Changing the machine WinHTTP proxy needs an elevated session. Re-launch this tool as administrator.', 'Machine WinHTTP', 'OK', 'Warning')
                return
            }
            $useProxy = $rbWhProxy.Checked
            $server = ''
            if ($useProxy) {
                if (-not $twHost.Text.Trim()) {
                    [void][System.Windows.Forms.MessageBox]::Show($dlg, 'Enter the proxy address.', 'Machine WinHTTP', 'OK', 'Warning'); return
                }
                $server = $twHost.Text.Trim()
                if ($twPort.Text.Trim()) { $server += ':' + $twPort.Text.Trim() }
            }
            $byp = @()
            if ($useProxy) {
                $byp = @($twBypass.Lines | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -ne '<local>' })
                if ($chkWhLocal.Checked) { $byp += '<local>' }
            }
            $bypass = ($byp -join ';')
            $what = if ($useProxy) { "proxy $server" } else { 'no proxy (direct)' }

            [void](Set-WinHttpProxy -UseProxy $useProxy -ProxyServer $server -Bypass $bypass)
            $after = Get-WinHttpProxy
            $ok = ($after.UseProxy -eq $useProxy) -and ((-not $useProxy) -or ($after.Server -eq $server))

            Append-ToBox $outBox @('', '=== MACHINE WinHTTP PROXY CHANGED ===',
                ('  Now reads      : {0}' -f $after.Summary),
                ('  Bypass list    : {0}' -f $(if ($bypass) { $bypass } else { '(none)' })),
                '  Applies to     : BITS, Windows Update scanning and the ConfigMgr client.',
                '  Not used by    : the Publishing Service - it falls back to SYSTEM''s WinINET proxy.',
                '  Note           : services already running keep their old proxy until restarted.')
            if (-not $ok) {
                [void][System.Windows.Forms.MessageBox]::Show($dlg, ("The WinHTTP proxy does not read back as expected.`r`n`r`nIt now reads: {0}" -f $after.Summary), 'Machine WinHTTP', 'OK', 'Error')
                & $loadCurrent
                return
            }
            $dlg.DialogResult = 'OK'; $dlg.Close()
        })

    & $loadCurrent
    Set-ControlTheme $dlg
    & $syncEnabled
    $lblCur.ForeColor = $script:Pal.Text
    $lblSub.ForeColor = $script:Pal.TextDim
    $lblElev.ForeColor = $script:Pal.Warning

    # Stacked from a running cursor: the labels wrap differently by value and elevation.
    $y = 14
    $lblCur.Location = New-Object System.Drawing.Point(16, $y); $y = $lblCur.Bottom + 6
    $lblSub.Location = New-Object System.Drawing.Point(16, $y); $y = $lblSub.Bottom + 8
    # $canWrite, not $lblElev.Visible - that reports effective visibility and is false until shown.
    if (-not $canWrite) { $lblElev.Location = New-Object System.Drawing.Point(16, $y); $y = $lblElev.Bottom + 8 }
    $rule1.Top = $y; $y = $rule1.Bottom + 12
    $rbWhNone.Location = New-Object System.Drawing.Point(16, $y); $y = $rbWhNone.Bottom + 4
    $rbWhProxy.Location = New-Object System.Drawing.Point(16, $y); $y = $rbWhProxy.Bottom + 8
    $twHost.Location = New-Object System.Drawing.Point(110, $y)
    $lblAddr.Location = New-Object System.Drawing.Point(40, ($y + 3))
    $lblPortD.Location = New-Object System.Drawing.Point(398, ($y + 3))
    $twPort.Location = New-Object System.Drawing.Point(436, $y); $y = $twHost.Bottom + 10
    $lblByp.Location = New-Object System.Drawing.Point(40, $y); $y = $lblByp.Bottom + 6
    $twBypass.Location = New-Object System.Drawing.Point(40, $y); $y = $twBypass.Bottom + 8
    $chkWhLocal.Location = New-Object System.Drawing.Point(40, $y); $y = $chkWhLocal.Bottom + 16
    $btnCopy.Location = New-Object System.Drawing.Point(16, $y)
    $btnApply.Location = New-Object System.Drawing.Point(496, $y)
    $btnCancel.Location = New-Object System.Drawing.Point(592, $y)
    $dlg.ClientSize = New-Object System.Drawing.Size(688, ($btnApply.Bottom + 16))

    [void]$dlg.ShowDialog($form)
    $dlg.Dispose()
    $script:WinHttpDlg = $null
}

function Get-ProxyParams {
    # Fixed: everything runs over the account's own WinINET proxy so the service can reproduce it.
    @{ Mode = 'System'; PHost = ''; PPort = 0; PUser = ''; PPass = ''; UseDefaultCreds = $false }
}

function Start-Task {
    param([string]$Name, [scriptblock]$Work, [hashtable]$Params, $Target, [string]$Kind = 'Log', [int]$Total = 0)
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'; $rs.Open()
    $ps = [powershell]::Create(); $ps.Runspace = $rs
    [void]$ps.AddScript($script:PNT_FunctionsText)
    [void]$ps.AddStatement().AddScript($Work.ToString())
    if ($Params) { [void]$ps.AddParameters($Params) }
    # Explicit output collection so the pump can drain partial results while the task is still running.
    $outColl = New-Object 'System.Management.Automation.PSDataCollection[psobject]'
    $inColl = New-Object 'System.Management.Automation.PSDataCollection[psobject]'
    $inColl.Complete()
    $handle = $ps.BeginInvoke($inColl, $outColl)
    # All is kept for the card parser; SecCount/SecName track progress without re-scanning.
    [void]$script:Jobs.Add([pscustomobject]@{ Name = $Name; PS = $ps; Handle = $handle; RS = $rs; Target = $Target; Kind = $Kind; Out = $outColl; Drained = 0
            All = (New-Object System.Collections.Generic.List[string])
            Total = $Total; SecCount = 0; SecName = ''; Carded = $false; BoxLine = $null 
        })
    if ($Kind -eq 'Log') { $script:LastLogJob = $script:Jobs[$script:Jobs.Count - 1] }
    try {
        if ($Kind -ne 'LogScan') {
            $btnRun.Text = 'Running...'
            $btnRun.Enabled = $false
            $btnCancelRun.Enabled = $true
            $btnCancelRun.Visible = $true
        }
    }
    catch {}
    if ($Kind -eq 'Log') {
        Append-ToBox $Target @("", ("----- {0}  [{1}] -----" -f $Name, (Get-Date -Format HH:mm:ss))) $script:Pal.Accent
        # Cards are built from the transcript the user can see, so the two tabs cannot disagree.
        try { $script:Jobs[$script:Jobs.Count - 1].BoxLine = @($Target.Lines).Count } catch {}
    }
}

function Get-RunTranscript {
    param($Job)
    $fromJob = @($Job.All)
    $fromBox = @()
    try {
        if ($Job.Target -and $null -ne $Job.BoxLine) {
            $all = @($Job.Target.Lines)
            if ($all.Count -gt $Job.BoxLine) {
                foreach ($ln in $all[$Job.BoxLine..($all.Count - 1)]) {
                    # Stop at anything that belongs to a later run or to the background log scan.
                    if ($ln -match '^-{4,}\s' -or $ln -like '=== PUBLISHING SERVICE LOG SCAN*') { break }
                    $fromBox += $ln
                }
            }
        }
    }
    catch { $fromBox = @() }
    $nj = @($fromJob | Where-Object { $_ -match $script:CardSectionRx }).Count
    $nb = @($fromBox | Where-Object { $_ -match $script:CardSectionRx }).Count
    if ($nb -gt $nj) {
        try { Append-ToBox $Job.Target @(("  [note] Cards built from the transcript ({0} sections) - the run buffer only held {1}." -f $nb, $nj)) $script:Pal.Warning } catch {}
        return $fromBox
    }
    return $fromJob
}

function Invoke-Ctx {
    param([string]$Name, [string[]]$Tests, $Target, [string]$Kind = 'Log', [switch]$ClearFirst)
    if ($script:Acct -eq 'SYSTEM' -and -not $script:IsAdmin) {
        if ($Kind -eq 'Fetch') { Set-BStatus 'SYSTEM context requires an elevated session.' $script:Pal.Error; return }
        $script:VerdictIsRunning = $false
        $script:VerdictColor = $script:Pal.Error
        $lblVerdictH.Text = 'SYSTEM context requires an elevated session'
        $lblVerdictH.ForeColor = $script:Pal.Error
        $lblVerdictP.Text = "Re-launch the tool 'As administrator' to run as NT AUTHORITY\SYSTEM."
        $lblVerdictP.ForeColor = $script:Pal.TextDim
        $pnlVerdict.Height = 76; $pnlVerdict.Visible = $true; $pnlVerdict.Invalidate()
        return
    }
    if ($ClearFirst) { $Target.Clear() }
    if ($script:Acct -eq 'SYSTEM') { $script:SystemTaskUsed = $true }
    $pp = Get-ProxyParams
    Start-Task -Name ("{0} [{1}]" -f $Name, $script:Acct) -Target $Target -Kind $Kind -Total @($Tests).Count -Work {
        param($Acct, $Tests, $SelfPath, $ExePath, $Url, $Mode, $PHost, $PPort, $PUser, $PPass, $UseDefaultCreds, $MaxFetchChars)
        if ($Acct -eq 'SYSTEM') {
            Invoke-SystemContextTests -SelfPath $SelfPath -ExePath $ExePath -Tests $Tests -Url $Url -Mode $Mode -PHost $PHost -PPort $PPort -PUser $PUser -PPass $PPass -UseDefaultCreds $UseDefaultCreds
        }
        else {
            $proxy = Get-EffectiveProxy -Mode $Mode -PHost $PHost -PPort $PPort -PUser $PUser -PPass $PPass -UseDefaultCreds $UseDefaultCreds
            Invoke-RequestedTests -Tests $Tests -Url $Url -ProxyObj $proxy -ProxyMode $Mode -MaxFetchChars $MaxFetchChars
        }
    } -Params @{
        Acct = $script:Acct; Tests = $Tests; SelfPath = $script:SelfPath; ExePath = (Get-Process -Id $PID).Path
        Url = $cboTarget.Text; Mode = $pp.Mode; PHost = $pp.PHost; PPort = $pp.PPort; PUser = $pp.PUser; PPass = $pp.PPass
        UseDefaultCreds = $pp.UseDefaultCreds; MaxFetchChars = $script:MaxFetchChars
    }
}

# Every ticked check goes into one job, so the whole picture arrives together.
$btnRun.Add_Click({
        $tests = @()
        foreach ($c in $script:TestChecks) { if ($c.Checked) { $tests += [string]$c.Tag } }
        if (-not $tests.Count) {
            Set-Status -Keep 'Nothing selected - tick at least one check on the left.'
            return
        }
        Select-Page 0
        Clear-ResultCards -KeepBanner
        $script:LastLogJob = $null
        Set-VerdictRunning -Current 0 -Total $tests.Count -Name '' -WaitingForSystem:($script:Acct -eq 'SYSTEM')
        Invoke-Ctx -Name 'Checks' -Tests $tests -Target $outBox
    })

$btnCancelRun.Add_Click({
        # BeginStop, not Stop: Stop blocks until the pipeline unwinds and would freeze the window.
        $btnCancelRun.Enabled = $false

        foreach ($job in @($script:Jobs)) { try { [void]$job.PS.BeginStop($null, $null) } catch {} }
    })

$script:ToggleView = {
    try {
        if ($rbSource.Checked -or -not $script:BrowserWeb) {
            $srcWrap.Visible = $true; if ($script:BrowserWeb) { $script:BrowserWeb.Visible = $false }
        }
        else {
            $srcWrap.Visible = $false; $script:BrowserWeb.Visible = $true
        }
    }
    catch {}
}
$rbRendered.Add_CheckedChanged($script:ToggleView)
$rbSource.Add_CheckedChanged($script:ToggleView)

$btnFetch.Add_Click({
        Set-BStatus ("Fetching as {0}..." -f $script:Acct) $script:Pal.TextDim
        Invoke-Ctx -Name 'Fetch' -Tests @('Fetch') -Target $srcBox -Kind 'Fetch'
    })

# MSHTML draws its bars non-client, so the legacy scrollbar-* CSS is the only lever.
function Get-ScrollbarCss {
    # Both spellings: IE7 mode wants the unprefixed properties, IE10+ standards mode wants -ms-.
    $p = @(
        'scrollbar-base-color:#1E1E2D', 'scrollbar-face-color:#484864',
        'scrollbar-track-color:#151521', 'scrollbar-arrow-color:#A7AFBA',
        'scrollbar-shadow-color:#1E1E2D', 'scrollbar-highlight-color:#1E1E2D',
        'scrollbar-3dlight-color:#1E1E2D', 'scrollbar-darkshadow-color:#151521'
    )
    $decl = ($p -join ';') + ';' + (($p | ForEach-Object { '-ms-' + $_ }) -join ';') + ';'
    "<style>html,body{$decl}</style>"
}

function Get-InfoDoc {
    param([string]$Message, [string]$PreText)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("<html><head><meta http-equiv='X-UA-Compatible' content='IE=edge'>")
    [void]$sb.Append((Get-ScrollbarCss))
    [void]$sb.Append("</head>")
    [void]$sb.Append("<body style='background:#151521;color:#A1A5B7;font-family:" + $script:UiFont.FontFamily.Name + ";font-size:10pt;margin:12px'>")
    [void]$sb.Append("<div style='color:#FFC700;margin-bottom:10px'>" + $Message + "</div>")
    if ($PreText) {
        [void]$sb.Append("<pre style='background:#0B0B14;color:#C9D1D9;border:1px solid #3E3E56;padding:10px;white-space:pre-wrap;word-wrap:break-word;font-family:" + $script:MonoFont.FontFamily.Name + ",Consolas,monospace;font-size:9pt'>")
        [void]$sb.Append($PreText)
        [void]$sb.Append("</pre>")
    }
    [void]$sb.Append("</body></html>")
    $sb.ToString()
}

function Show-FetchResult {
    param([string[]]$Lines)
    $script:LastFetch = $Lines
    $meta = @{}; $body = New-Object System.Collections.Generic.List[string]
    $state = 0
    foreach ($l in $Lines) {
        if ($l -eq '<<<CT-FETCH-META>>>') { $state = 1; continue }
        if ($l -eq '<<<CT-FETCH-BODY>>>') { $state = 2; continue }
        if ($l -eq '<<<CT-FETCH-END>>>') { $state = 3; continue }
        if ($state -eq 1) { $i = $l.IndexOf('='); if ($i -gt 0) { $meta[$l.Substring(0, $i)] = $l.Substring($i + 1) } }
        elseif ($state -eq 2) { $body.Add($l) }
    }
    if ($state -eq 0) {
        Set-BoxText $srcBox ($Lines -join "`r`n") $script:Pal.Error
        Set-BStatus 'No response returned - see source view.' $script:Pal.Error
        $rbSource.Checked = $true
        return
    }
    $html = ($body -join "`r`n")
    Set-BoxText $srcBox $html

    $trueChars = 0; [void][int]::TryParse([string]$meta['BodyChars'], [ref]$trueChars)
    $wasCut = ([string]$meta['Truncated'] -eq 'True')
    $sizeNote = if ($trueChars -gt 0) { '  |  {0:N0} KB' -f [math]::Round($trueChars / 1KB) } else { '' }
    if ($wasCut) { $sizeNote += ' (showing first {0:N0} KB)' -f [math]::Round($html.Length / 1KB) }

    if ($meta['Error']) {
        Set-BStatus ("FAILED as {0}: {1}" -f $script:Acct, $meta['Error']) $script:Pal.Error
    }
    else {
        Set-BStatus ("as {0}  |  HTTP {1} {2}  |  proxy {3}  |  {4}{5}" -f $script:Acct, $meta['Status'], $meta['Reason'], $meta['ProxyUsed'], $meta['ContentType'], $sizeNote) `
        $(if ($meta['Status'] -eq '200') { $script:Pal.Success } else { $script:Pal.Warning })
    }

    if ($script:BrowserWeb) {
        try {
            # Only hand real HTML to MSHTML - a multi-megabyte XML document hangs the engine.
            $ctype = [string]$meta['ContentType']
            $isHtml = ($ctype -match '(?i)text/html|application/xhtml') -or
            ($ctype -eq '' -and $html -match '(?i)^\s*(<!doctype\s+html|<html\b)')
            $tooBig = ($html.Length -gt 1048576)

            if ([string]::IsNullOrWhiteSpace($html)) {
                $script:BrowserWeb.DocumentText = Get-InfoDoc 'Empty response body.' $null
            }
            elseif (-not $isHtml -or $tooBig) {
                $why = if ($tooBig) { 'Response is {0:N0} KB - too large to render safely.' -f [math]::Round($html.Length / 1KB) }
                else { 'Response is {0} - not HTML, so it is shown as text.' -f $(if ($ctype) { $ctype } else { 'not identified as HTML' }) }
                $preview = if ($html.Length -gt 65536) { $html.Substring(0, 65536) } else { $html }
                $esc = try { [System.Net.WebUtility]::HtmlEncode($preview) } catch { $null }
                if (-not $esc) { $esc = $preview -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;' }
                $extra = if ($preview.Length -lt $html.Length) { "`r`n`r`n... preview truncated - use the HTML source view for the rest." } else { '' }
                $script:BrowserWeb.DocumentText = Get-InfoDoc $why ($esc + $extra)
            }
            else {
                # Always static. Sites also ship JS that detects the legacy engine and redirects away.
                $doc = [regex]::Replace($html, '(?is)<script\b[^>]*>.*?</script\s*>', '')
                $doc = [regex]::Replace($doc, '(?is)<script\b[^>]*/?>', '')
                $doc = [regex]::Replace($doc, '(?is)</?noscript[^>]*>', '')
                $doc = [regex]::Replace($doc, '(?i)\son[a-z]+\s*=\s*"[^"]*"', '')
                $doc = [regex]::Replace($doc, "(?i)\son[a-z]+\s*=\s*'[^']*'", '')
                $doc = [regex]::Replace($doc, '(?is)<meta[^>]+http-equiv\s*=\s*["'']?refresh["'']?[^>]*>', '')
                # Frames and plugins here are trackers or ads - no diagnostic value, and they phone out.
                $doc = [regex]::Replace($doc, '(?is)<(iframe|frame|embed|object|applet)\b[^>]*>.*?</\1\s*>', '')
                $doc = [regex]::Replace($doc, '(?is)<(iframe|frame|embed|applet)\b[^>]*/?>', '')
                # Lazy-loading frameworks park the real image in data-src / data-lazy-src.
                $doc = [regex]::Replace($doc, '(?i)\sdata-(lazy-)?src\s*=', ' src=')
                # <base> resolves relative assets, X-UA-Compatible forces IE11, scrollbar-* colours its bars.
                $inject = ('<base href="{0}"><meta http-equiv="X-UA-Compatible" content="IE=edge">{1}' -f $meta['FinalUrl'], (Get-ScrollbarCss))
                $m = [regex]::Match($doc, '(?i)<head[^>]*>')
                $doc = if ($m.Success) { $doc.Insert($m.Index + $m.Length, $inject) } else { $inject + $doc }
                $script:BrowserWeb.DocumentText = $doc
            }
        }
        catch {
            $script:BrowserWeb.DocumentText = ("<html><head>{2}</head><body style='background:#151521;color:#F1416C;font-family:{1};font-size:10pt'>Render error: {0}</body></html>" -f $_.Exception.Message, $script:UiFont.FontFamily.Name, (Get-ScrollbarCss))
        }
    }
    & $script:ToggleView
}

# Guarded against re-entry: a nested message pump must not mutate $script:Jobs mid-tick.
$script:Pumping = $false
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 250
# Every step independently guarded - this un-sticks the Run button.
function Set-IdleUi {
    try {
        if ($script:VerdictIsRunning) {
            # Last line of defence: build cards from the output rather than claim there is nothing to show.
            $j = $script:LastLogJob
            if ($j -and -not $j.Carded) {
                try {
                    $src = @(Get-RunTranscript $j)
                    if ($src.Count) {
                        Add-ResultCards -Lines $src
                        $j.Carded = $true
                        Append-ToBox $outBox @("  [note] The results were rendered after the run ended abnormally.") $script:Pal.Warning
                    }
                }
                catch {}
            }
        }
        if ($script:VerdictIsRunning) {
            $script:VerdictIsRunning = $false
            $script:VerdictColor = $script:Pal.TextDim
            $lblVerdictH.Text = 'Run finished'
            $lblVerdictH.ForeColor = $script:Pal.TextDim
            $lblVerdictP.Text = 'The run ended without returning a result to summarise - the full transcript, including any error, is at the bottom of the LOG tab.'
            $lblVerdictP.ForeColor = $script:Pal.TextDim
            if (-not $pnlVerdict.Visible) { $pnlVerdict.Height = 76; $pnlVerdict.Visible = $true }
            $pnlVerdict.Invalidate()
        }
    }
    catch {}
    try { $btnRun.Text = 'Run selected' }    catch {}
    try { $btnRun.Enabled = $true }          catch {}
    try { $btnCancelRun.Visible = $false }   catch {}
    try { $btnCancelRun.Enabled = $true }    catch {}
}

$timer.Add_Tick({
        if ($script:Pumping) { return }
        # Runs on every tick whether or not a job is in flight, so a fault here would fire continuously.
        try { Sync-ScrollBars } catch {}
        # $script:Retired MUST be tested too, or a run leaks a PowerShell instance and an STA runspace.
        if ($script:Jobs.Count -eq 0 -and $script:Retired.Count -eq 0) {
            try { if (-not $btnRun.Enabled) { Set-IdleUi } } catch {}
            return
        }
        $script:Pumping = $true
        try {
            $done = @()
            foreach ($job in @($script:Jobs)) {
                # 'Log' tasks render progressively: drain whatever the runspace has produced so far.
                if ($job.Kind -eq 'Log' -and -not $job.Handle.IsCompleted) {
                    try {
                        $n = $job.Out.Count
                        if ($n -gt $job.Drained) {
                            $partial = @()
                            for ($i = $job.Drained; $i -lt $n; $i++) {
                                $ln = [string]$job.Out[$i]
                                $partial += $ln; $job.All.Add($ln)
                                if ($ln -match $script:CardSectionRx) { $job.SecCount++; $job.SecName = $Matches['t'] }
                            }
                            $job.Drained = $n
                            Append-ToBox $job.Target $partial
                            if ($job.Total -gt 0) {
                                Set-VerdictRunning -Current $job.SecCount -Total $job.Total -Name $job.SecName -WaitingForSystem:($script:Acct -eq 'SYSTEM')
                            }
                        }
                    }
                    catch {}
                }
                if ($job.Handle.IsCompleted) {
                    $done += $job
                    try {
                        # Each stage guarded on its own, or a throw skips the card builder and leaves TESTS empty.
                        $stageErr = $null
                        try { $job.PS.EndInvoke($job.Handle) | Out-Null } catch {}
                        $lines = @()
                        try {
                            for ($i = $job.Drained; $i -lt $job.Out.Count; $i++) { $lines += [string]$job.Out[$i]; $job.All.Add([string]$job.Out[$i]) }
                            $job.Drained = $job.Out.Count
                        }
                        catch { $stageErr = ('reading the results: {0}: {1}' -f $_.Exception.GetType().Name, $_.Exception.Message) }
                        # A check that throws emits no header, so fold the errors in as their own section.
                        try {
                            if ($job.PS.Streams.Error.Count) {
                                $errLines = @('', '=== TEST ERRORS ===')
                                foreach ($e in @($job.PS.Streams.Error)) {
                                    $errLines += ('  {0}' -f $e.ToString())
                                    $inv = $null
                                    try { $inv = $e.InvocationInfo } catch {}
                                    if ($inv -and $inv.ScriptLineNumber) {
                                        $errLines += ('     at line {0}: {1}' -f $inv.ScriptLineNumber, ("$($inv.Line)").Trim())
                                    }
                                }
                                $errLines += ('  RESULT         : FAIL - {0} test(s) raised an error and produced no output.' -f @($job.PS.Streams.Error).Count)
                                $lines += $errLines
                                foreach ($l in $errLines) { $job.All.Add([string]$l) }
                                try { $job.PS.Streams.Error.Clear() } catch {}
                            }
                        }
                        catch { if (-not $stageErr) { $stageErr = ('collecting test errors: {0}: {1}' -f $_.Exception.GetType().Name, $_.Exception.Message) } }
                        try {
                            if ($job.Kind -eq 'Fetch') { Show-FetchResult -Lines $lines }
                            elseif ($job.Kind -eq 'LogScan') { Add-LogEndpointGroup -Lines $lines }
                            elseif ($lines.Count) { Append-ToBox $job.Target $lines }
                        }
                        catch { if (-not $stageErr) { $stageErr = ('writing the transcript: {0}: {1}' -f $_.Exception.GetType().Name, $_.Exception.Message) } }

                        # Built from COMPLETE output: nothing is PASS or FAIL until its RESULT line arrives.
                        if ($job.Kind -eq 'Log') {
                            $script:CardError = $null
                            $src = @(Get-RunTranscript $job)
                            try { Add-ResultCards -Lines $src; $job.Carded = $true }
                            catch { $script:CardError = ('building the cards: {0}: {1}' -f $_.Exception.GetType().Name, $_.Exception.Message) }
                            if (-not $script:CardError -and -not $src.Count) { $script:CardError = $stageErr }

                            if ($stageErr) { Append-ToBox $outBox @("  [run error] $stageErr") $script:Pal.Error }
                            if ($script:CardError) {
                                $script:VerdictIsRunning = $false
                                Append-ToBox $outBox @("  [run error] $($script:CardError)") $script:Pal.Error
                                $script:VerdictColor = $script:Pal.Error
                                $lblVerdictH.Text = 'Checks finished, but the results could not be rendered'
                                $lblVerdictH.ForeColor = $script:Pal.Error
                                $lblVerdictP.Text = ('Failed while {0}  -  the full output is on the LOG tab.' -f $script:CardError)
                                $lblVerdictP.ForeColor = $script:Pal.TextDim
                                if (-not $pnlVerdict.Visible) { $pnlVerdict.Height = 76; $pnlVerdict.Visible = $true }
                                $pnlVerdict.Invalidate()
                            }
                        }
                        elseif ($stageErr) {
                            Append-ToBox $job.Target @("  [run error] $stageErr") $script:Pal.Error
                        }
                    }
                    catch {
                        $why = ('{0}: {1}' -f $_.Exception.GetType().Name, $_.Exception.Message)
                        try { Append-ToBox $job.Target @("  [task error] $why") $script:Pal.Error } catch {}
                        if ($job.Kind -eq 'Log') {
                            try {
                                $script:VerdictIsRunning = $false
                                $script:VerdictColor = $script:Pal.Error
                                $lblVerdictH.Text = 'Checks finished, but the results could not be rendered'
                                $lblVerdictH.ForeColor = $script:Pal.Error
                                $lblVerdictP.Text = ('{0}  -  the full output is on the LOG tab.' -f $why)
                                $lblVerdictP.ForeColor = $script:Pal.TextDim
                                if (-not $pnlVerdict.Visible) { $pnlVerdict.Height = 76; $pnlVerdict.Visible = $true }
                                $pnlVerdict.Invalidate()
                            }
                            catch {}
                        }
                    }
                    finally {
                        # Belt and braces: a run that produced output always gets its cards.
                        if ($job.Kind -eq 'Log' -and -not $job.Carded) {
                            try {
                                $src = @(Get-RunTranscript $job)
                                if ($src.Count) { Add-ResultCards -Lines $src; $job.Carded = $true }
                            }
                            catch {}
                        }
                        # Disposing straight after EndInvoke can race the runspace's worker thread.
                        [void]$script:Retired.Add($job)
                    }
                }
            }
            foreach ($d in $done) { $script:Jobs.Remove($d) }
            # Dispose jobs retired on a previous tick - by now their worker threads have fully unwound.
            if ($script:Retired.Count) {
                foreach ($r in @($script:Retired)) {
                    if ($r.RetireTick) {
                        try { $r.PS.Dispose() } catch {}
                        try { $r.RS.Dispose() } catch {}
                        $script:Retired.Remove($r)
                    }
                    else { $r | Add-Member -NotePropertyName RetireTick -NotePropertyValue $true -Force }
                }
            }
            # Only a check run owns the Run button - the log scan can outlive it and stick the button.
            if (@($script:Jobs | Where-Object { $_.Kind -ne 'LogScan' }).Count -eq 0 -and -not $btnRun.Enabled) { Set-IdleUi }
        }
        catch {
            # A tick must never die silently - it owns the Run button.
            try {
                Set-Status -Keep ('Pump error: {0}' -f $_.Exception.Message)

            }
            catch {}
        }
        finally { $script:Pumping = $false }
    })
$timer.Start()

function Get-ActiveOutputBox {
    if ($script:PageIndex -eq (Get-PageIndex 'BROWSER')) { return $srcBox }
    return $outBox
}
$btnClear.Add_Click({
        if ($script:PageIndex -eq (Get-PageIndex 'TESTS')) { Clear-ResultCards; return }
        $b = Get-ActiveOutputBox; if ($b) { $b.Clear() }
    })
$btnSave.Add_Click({
        $box = Get-ActiveOutputBox
        if (-not $box -or -not $box.Text) { Set-Status -Keep 'Nothing to save yet.'; return }
        $dlg = New-Object System.Windows.Forms.SaveFileDialog
        $dlg.Filter = 'Text (*.txt)|*.txt'; $dlg.FileName = ('ConnectivityTest_{0}_{1:yyyyMMdd_HHmmss}.txt' -f $script:Acct, (Get-Date))
        if ($dlg.ShowDialog() -eq 'OK') {
            # A saved log ends up on a support ticket, so it identifies the exact file that produced it.
            $hdr = @(('# Patch My PC Connectivity Test - {0}' -f (Get-Date)),
                ('# Script : {0}' -f $script:SelfPath),
                ('# Build  : {0}' -f $script:BuildStamp),
                ('# Context: {0}' -f $script:Acct), '')
            ($hdr + @($box.Lines)) | Set-Content -Path $dlg.FileName -Encoding UTF8
        }
    })

$form.Add_Shown({
        # No preamble: the transcript gets pasted into tickets, so it starts at the first real line.
        Set-DarkScrollbars $form
        Update-AccountUi
        Update-LiveProxy
        $script:ProxyWatch.Start()
        Start-LogScan
        # If a previous run was killed rather than closed, tidy its helper task up now.
        try {
            $sweep = Clear-StaleSystemTask
            if ($sweep) { Set-Status -Keep $sweep }
        }
        catch {}
        if (-not $script:BrowserWeb) { $rbRendered.Visible = $false; $rbSource.Checked = $true }
        & $script:ToggleView
        # about:blank is white, so give the pane a themed document until the first fetch.
        try {
            if ($script:BrowserWeb) {
                $script:BrowserWeb.DocumentText =
                Get-InfoDoc 'Nothing fetched yet - set a Target above and press Fetch &amp; Render.' $null
            }
        }
        catch {}
    })

Apply-Theme
# Page strip colours are owned by Select-Page, so it runs after the recursive themer.
$pnlTabBar.BackColor = $script:Pal.Base800
$pnlPages.BackColor = $script:Pal.Base800
$tabHost.BackColor = $script:Pal.Base800
Select-Page 0

# These use explicit colours; re-assert after the recursive themer runs.
$pnlBottom.BackColor = $script:Pal.Base900
$pnlSteps.BackColor = $script:Pal.Base800
# The service runs as SYSTEM, so default to it whenever the helper task can be registered.
if ($script:IsAdmin) {
    $script:CtxGuard = $true
    try {
        $script:Acct = 'SYSTEM'
        $rbCtxSys.Checked = $true
    }
    finally { $script:CtxGuard = $false }
}
Update-AccountUi

# The height at which the test list stops needing a scrollbar, Cancel's reserved room included.
function Get-RailFitHeight {
    try {
        if (-not $pnlRail -or $pnlRail.Height -le 0) { return 0 }
        $needs = $btnCancelRun.Bottom + $pnlRail.Padding.Bottom + 2
        $chrome = $form.Height - $pnlRail.Height
        return [int]($chrome + $needs)
    }
    catch { return 0 }
}

# Opens at 80% of the working area so the action bar cannot land off-screen on a server console.
function Set-InitialWindowSize {
    param($Form, [int]$FloorHeight = 0, [double]$HeightFraction = 0.80, [double]$WidthFraction = 0.95)
    try {
        $scr = $null
        try { $scr = [System.Windows.Forms.Screen]::FromControl($Form) } catch {}
        if (-not $scr) { $scr = [System.Windows.Forms.Screen]::PrimaryScreen }
        if (-not $scr) { return }
        $wa = $scr.WorkingArea

        $w = [int][Math]::Min($Form.Width, [Math]::Floor($wa.Width * $WidthFraction))
        $h = [int][Math]::Min($Form.Height, [Math]::Max([Math]::Floor($wa.Height * $HeightFraction), $FloorHeight))
        # The desktop has the last word - a floor taller than the screen recreates the problem.
        $h = [int][Math]::Min($h, $wa.Height)

        # MinimumSize must come down FIRST or it silently overrides the clamp.
        $Form.MinimumSize = New-Object System.Drawing.Size(
            ([int][Math]::Min($Form.MinimumSize.Width, $w)),
            ([int][Math]::Min([Math]::Max($Form.MinimumSize.Height, $FloorHeight), $h)))
        $Form.Size = New-Object System.Drawing.Size($w, $h)

        # CenterScreen centres on the pre-resize size, so position explicitly against the working area.
        $Form.StartPosition = 'Manual'
        $Form.Location = New-Object System.Drawing.Point(
            ($wa.X + [int](($wa.Width - $w) / 2)),
            ($wa.Y + [int](($wa.Height - $h) / 2)))
    }
    catch {}
}
Set-InitialWindowSize $form -FloorHeight (Get-RailFitHeight)
# Primes the remembered kind, which also keeps the rail's -On ticks and DefaultsByKind in step.
Sync-ChecksToTarget -Quiet

[void]$form.ShowDialog()
$timer.Stop()
try { $script:ProxyWatch.Stop() } catch {}
try { $script:TargetSync.Stop() } catch {}
# BeginStop here too - a worker in a socket read would hold the window open while it unwinds.
foreach ($job in @($script:Jobs)) { try { [void]$job.PS.BeginStop($null, $null) } catch {} }
try { $script:Jobs.Clear(); $script:Retired.Clear() } catch {}
# Leave no artefacts behind: task, TaskCache entries and any legacy folder.
try { if ($script:SystemTaskUsed) { Remove-AllTaskArtifacts | Out-Null } } catch {}
