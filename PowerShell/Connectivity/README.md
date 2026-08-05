# Network Connectivity Test

A single-file PowerShell tool that can be used to test connectivity to websites and servers.

<img width="1080" height="832" alt="image" src="https://github.com/user-attachments/assets/c4ebf4e5-7481-4670-bd79-1ce8850e2228" />

It runs the checks **as the logged-on user or as `NT AUTHORITY\SYSTEM`**, using the same proxy, TLS and DNS settings the service itself would use.

## Why this exists

The usual way to reproduce a Publishing Service connectivity problem was:

```
psexec -s -i cmd.exe
> "C:\Program Files\Internet Explorer\iexplore.exe"
```

Because Internet Explorer used the same `IWebProxy` plumbing (WinINET) that the service uses, so whatever IE saw, the service saw.
Internet Explorer has been removed from modern Windows Server builds, and PsExec is increasingly blocked by endpoint protection.

## Requirements

| | |
|---|---|
| PowerShell | **Windows PowerShell 5.1** |
| Elevation | Only needed for the **SYSTEM** context and for editing machine-wide proxy settings |

## Quick start

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\Invoke-ConnectivityTest.ps1
```

1. Pick or type a **Target**.
2. Choose **Run as**: *Logged-on user* or *SYSTEM*.
3. The checks on the left tick themselves to suit the target or can be adjusted.
4. Click **Run selected**.

## Using the tool

### What to test

**Target** accepts 4 forms:

| You type | Treated as |
|---|---|
| `https://patchmypc.com/...` | Web address |
| `\\server\share` | File share (UNC) |
| `server\share` | File share — the leading `\\` is optional |
| `server` | Server name or IP |

The dropdown is pre-populated with the endpoints the Publishing Service uses. If the Publisher is installed, a second group of endpoints is **scraped from the PatchMyPC.log**, newest first, so you can test the URL that  failed easily.

### TESTS tab

| Group | Check | What it does |
|---|---|---|
| Connectivity | **HTTP(S) GET** | Status, redirects, served host, proxy used, block-page detection |
| | **File download** | Pulls real bytes through the proxy, identifies what actually arrived, hashes it |
| | **Ports 80/443** | TCP reachability, direct and through the proxy |
| | **Ping** | ICMP round-trip |
| | **Tracert** | Hop-by-hop path *(slow)* |
| | **Nslookup** | Name resolution and which resolver answered |
| Windows server | **SMB / file share** | 445 and 139, then a real session — auth, share ACLs, dialect |
| | **RPC / WMI** | 135, the dynamic port range, a real DCOM connect, and `root\sms` |
| TLS | **Handshake** | Negotiated protocol and cipher, certificate chain validation |
| | **TLS config** | What SCHANNEL has enabled on this box |
| | **Cipher suites** | What the server accepts vs what this box offers, side by side *(slow)* |
| Configuration | **DNS config** | Resolvers, suffixes, and the HOSTS entries relevant to the target |

### Automatic Test Selection

The selection follows what the target *is*:

| Target starts with / contains | Checks selected |
|---|---|
| `http://` or `https://` | HTTP(S) GET, Ports 80/443, TLS Handshake |
| a backslash (`\`) | Ping, SMB / file share |
| anything else | Ping, RPC / WMI |

This re-applies only when the *kind* of target changes.

### Run as

| Option | What it proves |
|---|---|
| **Logged-on user** | What *you* can reach. Your account holds a Kerberos ticket, so an authenticating proxy usually lets you straight through. |
| **SYSTEM** | What the **service** can reach. SYSTEM presents the machine account `DOMAIN\HOSTNAME$` — which is very often the account a proxy refuses. *Requires an elevated session.* |

## Results

Every check produces a card. Click a card to open its full output.
The banner at the top summarizes the run and doubles as a live progress indicator.

### LOG tab

The complete transcript. **Save log…** writes it to a text file that can be shared with support.


### BROWSER tab

Fetches a http target using the selected account and proxy.

It is a **viewer, not a browser**: page scripts are stripped before rendering, frames and plugin objects are removed, and every outbound navigation is cancelled and counted. Switch to **HTML source** to see the raw bytes exactly as received.

This is how you catch a captive portal or a proxy block page that returns a perfectly healthy `200 OK`.

## Testing internal servers and file shares

- **SMB** checks 445 (and legacy 139), then performs a **real session setup**, so you find out about authentication, share ACLs and missing shares, not just whether a socket opens.
- **RPC / WMI** checks 135, reads the dynamic port range, then completes a **real DCOM connect** and probes `root\sms`. A firewall that opens 135 alone is the single most common reason a remote WMI or SMS Provider connection hangs, and a port scan cannot tell you that.

## Proxy

The panel is a read-out of the configured proxy:

| Row | What it is |
|---|---|
| **Windows (WinINET)** | The proxy for the account named under *Run as*. This is the one that affects the Publishing Service. |
| **Machine (WinHTTP)** | The machine-wide setting Windows services read. A separate, parallel stack — neither overrides the other. |

**Refresh** re-reads both and **Edit proxy** drops a menu with 2 entries the WinINET proxy for the account under *Run as*, and the machine-wide WinHTTP proxy

> [!IMPORTANT]
> **The Publishing Service uses its own proxy setting**
>
> The Publishing service reads the proxy configured on its **own Advanced tab**, stored in `Settings.xml`, *not* the Windows proxy. It will fall back to the **SYSTEM** WinINET proxy when no explicit proxy is set in the Publisher and one is set for SYSTEM.

Every check resolves the proxy from the registry **at the moment it runs**

## How the SYSTEM context works

No PsExec. The tool registers a **one-shot Scheduled Task** in the root of the Task Scheduler Library, runs it as `NT AUTHORITY\SYSTEM`, streams the results back live, then deletes the task **and its registry entries**.

- Run parameters are written to a file only SYSTEM and Administrators can read, DPAPI-encrypted at machine scope, and securely overwritten afterwards.
- The task is registered disabled, with an expiring trigger and `DeleteExpiredTaskAfter`, so nothing survives a crash.
- The tool only ever touches a task carrying its own marker in the description.
