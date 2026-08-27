# ProcessTracker (PowerShell)

ProcessTracker is a Windows ETW-based network telemetry utility that tracks per-process TCP send and receive byte counts. It is written in PowerShell 5.1 for compatibility and uses the Microsoft Trace Event nuget package libraries.

This repository is PowerShell-only and centered on:
- ProcessTracker.ps1 (main tracker script)
- Install-Dependencies.ps1 (dependency bootstrap script)

## What It Does

The script captures kernel TCP/IP ETW events and aggregates network traffic for a target process name (default: mssense).

Key capabilities:
- Tracks cumulative bytes sent and received
- Prints periodic status to console
- Produces 24-hour rolling summaries
- Handles graceful shutdown with final totals
- Writes structured CSV logs suitable for Power BI/reporting
- Recovers prior cumulative totals from CSV across restarts

## Repository Layout

- Main script: ProcessTracker.ps1
- Dependency installer: Install-Dependencies.ps1
- PowerShell notes: README-PowerShell.md
- Required runtime DLLs: *.dll files in repository root

## Requirements

## Platform
- Windows

## Runtime
- Windows PowerShell 5.1
- .NET Framework 4.6.2 or later (4.7.2+ recommended)

## Privileges
- Administrator rights are required to create ETW kernel sessions

## Required DLLs (repository root)

Core TraceEvent components:
- Microsoft.Diagnostics.Tracing.TraceEvent.dll
- Microsoft.Diagnostics.FastSerialization.dll
- Dia2Lib.dll
- TraceReloggerLib.dll

Additional netstandard compatibility dependencies used by the script when present:
- System.Memory.dll
- System.Buffers.dll
- System.Runtime.CompilerServices.Unsafe.dll
- System.Numerics.Vectors.dll
- System.Text.Json.dll
- System.Text.Encodings.Web.dll
- System.Reflection.Metadata.dll
- System.Collections.Immutable.dll
- Microsoft.Win32.Registry.dll
- System.Security.AccessControl.dll
- System.Security.Principal.Windows.dll

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

- -ProcessName <name>
- -DebugEvents (switch)

Examples:

```powershell
.\ProcessTracker.ps1 -ProcessName chrome
.\ProcessTracker.ps1 -ProcessName mssense -DebugEvents
```

## Installing Dependencies

If dependency load errors occur, run:

```powershell
.\Install-Dependencies.ps1
```

Installer behavior:
- Downloads required NuGet packages from nuget.org
- Extracts needed DLLs
- Copies DLLs to the script directory

Notes:
- Internet access is required in order to dynamically download the nuget traceevent package
- Script pauses for keypress before exiting

## Output and Logs

Console output includes:
- Start banner and monitored PID list
- Periodic sent/received totals
- 24-hour summaries
- Final summary at shutdown

Generated CSV files (script directory):
- <ComputerName>-<ProcessName>-DataLogging.csv
- <ComputerName>-<ProcessName>-DataLogging_24Hour.csv

CSV schema:
- Timestamp
- ComputerName
- ProcessName
- PeriodType
- DurationSeconds
- BytesSent
- BytesReceived
- TotalBytes

PeriodType values:
- Interval
- Daily
- Partial
- Final

Resume behavior:
- At startup, the script reads the latest Interval row from the main CSV to continue cumulative totals.

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
