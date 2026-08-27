# ProcessTracker (PowerShell)

ProcessTracker is a Windows ETW-based network telemetry utility that tracks per-process TCP send and receive byte counts. It is written in PowerShell 5.1 for compatibility and uses the Microsoft Trace Event nuget package libraries.

This repository is PowerShell-only and centered on:
- ProcessTracker.ps1 (main tracker script)
- Install-Dependencies.ps1 (dependency bootstrap script)

## What It Does

The script captures kernel TCP/IP ETW events and aggregates network traffic for a target process name (default: mssense).

Key capabilities:
- Tracks cumulative bytes sent and received, plus the delta for each capture interval
- Prints periodic status to console
- Produces 24-hour rolling summaries
- Handles graceful shutdown with final totals
- Writes structured CSV logs suitable for Power BI/reporting
- Recovers prior cumulative totals, and the in-progress 24-hour window, from CSV across restarts

## Repository Layout

- Main script: ProcessTracker.ps1
- Dependency installer: Install-Dependencies.ps1

## Requirements

## Platform
- Windows

## Runtime
- Windows PowerShell 5.1
- .NET Framework 4.6.2 or later (4.7.2+ recommended)

## Privileges
- Administrator rights are required to create ETW kernel sessions

## Required DLLs (repository root)

Install-Dependencies.ps1 downloads these automatically - see [Installing Dependencies](#installing-dependencies). It pins `Microsoft.Diagnostics.Tracing.TraceEvent` to 3.0.0 specifically, since that's the last release with a native `net462` build and a single dependency (newer releases only ship netstandard2.0 and pull in a much larger, harder-to-resolve dependency chain).

Core TraceEvent components (net462 build):
- Microsoft.Diagnostics.Tracing.TraceEvent.dll
- Microsoft.Diagnostics.FastSerialization.dll
- Dia2Lib.dll
- TraceReloggerLib.dll
- OSExtensions.dll
- System.Runtime.CompilerServices.Unsafe.dll (TraceEvent's only dependency)

Native DIA/kernel-control DLLs (installed under an `amd64`/`x86`/`arm64` subfolder matching your process architecture):
- KernelTraceControl.dll
- msdia140.dll
- msvcp140.dll / vcruntime140.dll / vcruntime140_1.dll

## Quick Start

1. Open an elevated Windows PowerShell session (Run as Administrator).
2. Change to the repository directory.
3. Run the tracker:

```powershell
Set-Location C:\Development\ProcessTracker-net462
.\ProcessTracker.ps1 -ProcessName mssense
```

Optional debug event output:

```powershell
.\ProcessTracker.ps1 -ProcessName mssense -DebugEvents
```

## Running as a Scheduled Task

To keep monitoring running unattended and survive reboots, register it as a Scheduled Task that starts at boot with highest privileges: `Register-ScheduledTask -TaskName "ProcessTracker" -Action (New-ScheduledTaskAction -Execute "powershell.exe" -Argument '-NoProfile -WindowStyle Hidden -File "C:\Development\ProcessTracker-net462\ProcessTracker.ps1" -ProcessName mssense' -WorkingDirectory "C:\Development\ProcessTracker-net462") -Trigger (New-ScheduledTaskTrigger -AtStartup) -Principal (New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest)`.

## Parameters

- -ProcessName <name> - process to monitor, without the .exe extension (default: mssense)
- -IntervalSeconds <seconds> - how often accumulated byte counts are flushed to the CSV log (default: 300, i.e. 5 minutes)
- -BufferSizeMB <MB> - ETW kernel session buffer size; increase if you see buffer-overrun warnings (default: 256)
- -DebugEvents (switch) - prints every matched send/receive event to the console for troubleshooting

Examples:

```powershell
.\ProcessTracker.ps1 -ProcessName chrome
.\ProcessTracker.ps1 -ProcessName mssense -IntervalSeconds 60
.\ProcessTracker.ps1 -ProcessName mssense -DebugEvents
```

## Installing Dependencies

If dependency load errors occur, run:

```powershell
.\Install-Dependencies.ps1
```

Installer behavior:
- Downloads nuget.exe and uses it to resolve Microsoft.Diagnostics.Tracing.TraceEvent 3.0.0 and its full dependency tree
- Copies the best-matching managed DLLs (preferring a native net462 build over netstandard2.0) to the script directory
- Copies the native DIA/KernelTraceControl DLLs into `amd64`/`x86`/`arm64` subfolders next to the script
- Skips any file that's locked because it's already loaded by a ProcessTracker.ps1 instance running in the same PowerShell session

Notes:
- Internet access is required to reach nuget.org and dist.nuget.org
- Run this from a separate/fresh PowerShell window if ProcessTracker.ps1 is currently running in your session, otherwise its loaded DLLs will be skipped as locked
- Script pauses for keypress before exiting

## Output and Logs

Console output includes:
- Start banner and monitored PID list
- Periodic sent/received totals
- 24-hour summaries
- Final summary at shutdown

Generated CSV files (script directory):
- `<ComputerName>-<ProcessName>-DataLogging.csv` - the main log, one row every `-IntervalSeconds`
- `<ComputerName>-<ProcessName>-DataLogging_24Hour.csv` - one row every completed 24-hour window

### Main log columns (`DataLogging.csv`)

| Column | Meaning |
|---|---|
| Timestamp | End of the period, `yyyy-MM-dd HH:mm:ss` |
| ComputerName | Value of `$env:ComputerName` |
| ProcessName | The `-ProcessName` value being monitored |
| PeriodType | `Interval` (routine tick) or `Final` (written once at shutdown) |
| DurationSeconds | Length of the period this row covers |
| BytesSentDelta | Bytes sent **during this period only** |
| BytesReceivedDelta | Bytes received **during this period only** |
| TotalBytesDelta | BytesSentDelta + BytesReceivedDelta |
| BytesSent | Running cumulative bytes sent since monitoring first started (survives restarts) |
| BytesReceived | Running cumulative bytes received since monitoring first started (survives restarts) |
| TotalBytes | BytesSent + BytesReceived |

For bandwidth reporting (e.g. daily/weekly/monthly totals to inform purchasing decisions), sum the `*Delta` columns over whatever date range you need - this gives an accurate total regardless of how many times the script has been restarted. The cumulative `BytesSent`/`BytesReceived`/`TotalBytes` columns are for continuity/at-a-glance monitoring, not for period totals.

### Daily log columns (`DataLogging_24Hour.csv`)

| Column | Meaning |
|---|---|
| Timestamp | End of the period, `yyyy-MM-dd HH:mm:ss` |
| ComputerName | Value of `$env:ComputerName` |
| ProcessName | The `-ProcessName` value being monitored |
| PeriodType | `Daily` (a completed rolling 24h window) or `Partial` (written once at shutdown if the current window hasn't reached 24h yet) |
| DurationSeconds | Length of the period this row covers |
| BytesSent | Total bytes sent during that 24-hour window (not cumulative - resets each window) |
| BytesReceived | Total bytes received during that 24-hour window (not cumulative - resets each window) |
| TotalBytes | BytesSent + BytesReceived |

The 24-hour window is a rolling window anchored to whenever monitoring first began (or last completed a full 24h cycle) - it is not aligned to calendar midnight.

Resume behavior across restarts:
- The main log's running cumulative totals (`BytesSent`/`BytesReceived`) are recovered from the last `Interval` row.
- The in-progress 24-hour window (its start time and bytes accumulated so far) is reconstructed from the daily log plus any main-log rows written since the last completed `Daily` row, so a restart mid-window no longer loses that partial day of data.
- If an existing CSV was written before the delta columns existed, its header row is rewritten in place to the current schema the next time the script runs (existing data rows are left as-is).

## Stopping the Script

Press Ctrl+C to stop.

The script attempts graceful shutdown by:
- Stopping ETW processing
- Closing CSV writers cleanly
- Printing and logging final counters

## Troubleshooting

## Access Denied / ETW Session Creation Fails

Actions:
- Confirm PowerShell is running as Administrator
- Ensure no conflicting ETW session remains active

## No Data Captured

Possible causes:
- Target process not running
- Process name mismatch
- No qualifying TCP events during interval

Actions:
- Verify process name and running instances
- Retry with an active process
- Use -DebugEvents to inspect incoming event data

## Assembly Load Errors

Actions:
- Ensure required DLLs exist in repository root
- Run Install-Dependencies.ps1
- Prefer .NET Framework 4.7.2+ where available

## Security and Privacy

- Requires elevation for kernel ETW access
- Captures aggregate byte counts only (no payload capture)
- Logs include timestamps, host name, process name, and counters
- Apply your organization retention/compliance policies to log files

## Known Limitations

- Windows-only
- Focused on kernel TCP/IP events
- Name-based process targeting can include multiple instances of the same executable
- PID list is captured at startup; new process instances may require restarting the script

## Disclaimer

This repository includes a Microsoft custom script disclaimer in ProcessTracker.ps1. Validate supportability and production-use policy requirements before deployment.
