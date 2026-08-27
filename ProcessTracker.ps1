<#
##################################################################################################################
#
# Microsoft Customer Experience Engineering
# jesse.esquivel@microsoft.com
# ProcessTracker.ps1
# v1.0 Initial creation 01/14/2026 - Track amount of bytes sent/received by a specific process using ETW
#
# 
# 
# Microsoft Disclaimer for custom scripts
# ================================================================================================================
# The sample scripts are not supported under any Microsoft standard support program or service. The sample scripts
# are provided AS IS without warranty of any kind. Microsoft further disclaims all implied warranties including, 
# without limitation, any implied warranties of merchantability or of fitness for a particular purpose. The entire
# risk arising out of the use or performance of the sample scripts and documentation remains with you. In no event
# shall Microsoft, its authors, or anyone else involved in the creation, production, or delivery of the scripts be
# liable for any damages whatsoever (including, without limitation, damages for loss of business profits, business
# interruption, loss of business information, or other pecuniary loss) arising out of the use of or inability to 
# use the sample scripts or documentation, even if Microsoft has been advised of the possibility of such damages.
# ================================================================================================================
#
##################################################################################################################
# Script variables - please do not change these unless you know what you are doing
##################################################################################################################
#>

<#
.SYNOPSIS
    Monitors network traffic (TCP/IP send/receive) for a specific process using ETW (Event Tracing for Windows).

.DESCRIPTION
    This script uses the Microsoft.Diagnostics.Tracing.TraceEvent library to capture kernel-level network events
    for a specified process. It tracks bytes sent and received, provides periodic updates, and generates 24-hour summaries.
    
    Requirements:
    - PowerShell 5.1 or later
    - .NET Framework 4.6.2 or later
    - Administrator privileges (required for ETW kernel sessions)
    - Microsoft.Diagnostics.Tracing.TraceEvent Nuget package dlls in the same directory as the script
      https://www.nuget.org/packages/Microsoft.Diagnostics.Tracing.TraceEvent    

.PARAMETER ProcessName
    The name of the process to monitor (without .exe extension). Default is "mssense".

.EXAMPLE
    .\ProcessExplorer.ps1 -ProcessName "mssense"

.NOTES
    Compatible with PowerShell 5.1 and .NET Framework 4.6.2
    Press Ctrl+C to stop monitoring gracefully.
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$ProcessName = "mssense",
    
    [Parameter()]
    [switch]$DebugEvents,

    [Parameter()]
    [int]$BufferSizeMB = 256
)

# Strict mode for better error handling
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Trap handler for unexpected termination
trap {
    Write-Host
    Write-Host "Error: $_" -ForegroundColor Red
    Write-Host "Initiating cleanup..." -ForegroundColor Yellow
    continue
}

#region Helper Functions

function Test-Administrator {
    <#
    .SYNOPSIS
        Checks if the current session has administrator privileges.
    #>
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch {
        return $false
    }
}

function Write-Log {
    <#
    .SYNOPSIS
        Writes a message to both console and log file.
    #>
    param(
        [string]$Message,
        [System.IO.StreamWriter]$LogFile
    )
    
    Write-Host $Message
    if ($null -ne $LogFile) {
        $LogFile.WriteLine($Message)
    }
}

function Write-CsvLog {
    <#
    .SYNOPSIS
        Writes a structured CSV row to the log file for Power BI analysis.
    #>
    param(
        [System.IO.StreamWriter]$CsvFile,
        [string]$ComputerName,
        [string]$ProcessName,
        [string]$PeriodType,
        [datetime]$StartTime,
        [datetime]$EndTime,
        [long]$BytesSent,
        [long]$BytesReceived
    )
    
    if ($null -ne $CsvFile) {
        $durationSeconds = [int](($EndTime - $StartTime).TotalSeconds)
        $totalBytes = $BytesSent + $BytesReceived
        $timestamp = $EndTime.ToString('yyyy-MM-dd HH:mm:ss')
        
        $csvRow = "{0},{1},{2},{3},{4},{5},{6},{7}" -f `
            $timestamp, `
            $ComputerName, `
            $ProcessName, `
            $PeriodType, `
            $durationSeconds, `
            $BytesSent, `
            $BytesReceived, `
            $totalBytes
        
        $CsvFile.WriteLine($csvRow)
    }
}

function Get-SafeEventProperty {
    <#
    .SYNOPSIS
        Safely retrieves a property from an event payload with defensive checking.
    #>
    param(
        [object]$EventData,
        [string]$PropertyName,
        [object]$DefaultValue = 0
    )
    
    try {
        if ($null -ne $EventData -and $EventData.PSObject.Properties.Name -contains $PropertyName) {
            $value = $EventData.$PropertyName
            if ($null -ne $value) {
                return $value
            }
        }
        return $DefaultValue
    }
    catch {
        return $DefaultValue
    }
}

function Get-PreviousCsvTotals {
    <#
    .SYNOPSIS
        Reads the last entry from an existing DataLogging CSV to recover cumulative totals
        across script restarts (e.g. after a reboot).
    .DESCRIPTION
        Returns a hashtable with BytesSent and BytesReceived from the last row in the CSV.
        If the file doesn't exist or can't be read, returns zeros.
    #>
    param(
        [string]$CsvFilePath
    )
    
    $result = @{ BytesSent = [long]0; BytesReceived = [long]0 }
    
    try {
        if (-not (Test-Path $CsvFilePath)) {
            return $result
        }
        
        # Read the last non-empty line from the CSV
        $lines = [System.IO.File]::ReadAllLines($CsvFilePath)
        
        # Walk backward to find the last "Interval" row (skip Final, Partial, empty lines)
        for ($i = $lines.Count - 1; $i -ge 1; $i--) {
            $line = $lines[$i].Trim()
            if ([string]::IsNullOrEmpty($line)) { continue }
            
            $fields = $line.Split(',')
            # Expected: Timestamp,ComputerName,ProcessName,PeriodType,DurationSeconds,BytesSent,BytesReceived,TotalBytes
            if ($fields.Count -ge 8 -and $fields[3] -eq 'Interval') {
                $result.BytesSent = [long]$fields[5]
                $result.BytesReceived = [long]$fields[6]
                return $result
            }
        }
    }
    catch {
        Write-Host "Warning: Could not read previous CSV totals: $($_.Exception.Message)" -ForegroundColor Yellow
    }
    
    return $result
}

#endregion

#region Main Script

<# Validate process name doesn't include extension
if ([System.IO.Path]::HasExtension($ProcessName)) {
    $nameWithoutExt = [System.IO.Path]::GetFileNameWithoutExtension($ProcessName)
    Write-Host "Error: Process name should not include the file extension." -ForegroundColor Red
    Write-Host "Please use '$nameWithoutExt' instead of '$ProcessName'" -ForegroundColor Red
    exit 1
}
#>
# Check for administrator privileges
if (-not (Test-Administrator)) {
    Write-Host "Error: This script requires Administrator privileges to access ETW kernel sessions." -ForegroundColor Red
    Write-Host "Please run as Administrator." -ForegroundColor Red
    exit 1
}

# Get script directory for relative paths
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if ([string]::IsNullOrEmpty($scriptDir)) {
    $scriptDir = $PWD.Path
}

# Load TraceEvent assemblies
# For PowerShell 5.1 with .NET Framework 4.6.2, we need to load netstandard2.0 DLLs
# This requires proper binding redirects or loading the required dependencies
Write-Host "Loading TraceEvent libraries..." -ForegroundColor Cyan

# Look for DLLs in the same directory as the script
$fastSerializationDll = Join-Path $scriptDir "Microsoft.Diagnostics.FastSerialization.dll"
$traceEventDll = Join-Path $scriptDir "Microsoft.Diagnostics.Tracing.TraceEvent.dll"
$dia2LibDll = Join-Path $scriptDir "Dia2Lib.dll"
$traceReloggerDll = Join-Path $scriptDir "TraceReloggerLib.dll"

# Check if required DLLs exist
$missingDlls = @()

if (-not (Test-Path $fastSerializationDll)) {
    $missingDlls += "Microsoft.Diagnostics.FastSerialization.dll"
}

if (-not (Test-Path $traceEventDll)) {
    $missingDlls += "Microsoft.Diagnostics.Tracing.TraceEvent.dll"
}

if (-not (Test-Path $dia2LibDll)) {
    $missingDlls += "Dia2Lib.dll"
}

if (-not (Test-Path $traceReloggerDll)) {
    $missingDlls += "TraceReloggerLib.dll"
}

if ($missingDlls.Count -gt 0) {
    Write-Host "Error: Required DLLs not found in script directory:" -ForegroundColor Red
    foreach ($dll in $missingDlls) {
        Write-Host "  - $dll" -ForegroundColor Red
    }
    Write-Host "`nExpected location: $scriptDir" -ForegroundColor Yellow
    Write-Host "Please copy all required DLLs from the TraceEvent NuGet package to the script directory." -ForegroundColor Yellow
    exit 1
}

try {
    # Load managed assemblies
    # Note: Dia2Lib.dll and TraceReloggerLib.dll are native/COM interop and will be loaded automatically
    # Note: netstandard2.0 DLLs work with .NET Framework 4.6.2+ when netstandard facade is available
    
    # If two dependencies pin slightly different versions of the same assembly (e.g. across
    # TraceEvent's own dependency chain), resolve to whichever one we already loaded instead of
    # failing on an exact strong-name version match.
    $onAssemblyResolve = [System.ResolveEventHandler] {
        param($resolveSender, $resolveArgs)
        $requestedName = (New-Object System.Reflection.AssemblyName($resolveArgs.Name)).Name
        [System.AppDomain]::CurrentDomain.GetAssemblies() |
            Where-Object { $_.GetName().Name -eq $requestedName } |
            Select-Object -First 1
    }
    [System.AppDomain]::CurrentDomain.add_AssemblyResolve($onAssemblyResolve)
    
    # Load every dependency DLL the installer placed next to this script (anything other than the
    # four TraceEvent DLLs themselves, which are loaded explicitly below in the required order).
    # Discovering these dynamically - rather than hardcoding names - keeps this in sync with
    # whatever TraceEvent's transitive dependency tree happens to require.
    $explicitDlls = @($fastSerializationDll, $traceEventDll, $dia2LibDll, $traceReloggerDll)
    $optionalDependencies = Get-ChildItem -Path $scriptDir -Filter "*.dll" -ErrorAction SilentlyContinue |
        Where-Object { $explicitDlls -notcontains $_.FullName } |
        Select-Object -ExpandProperty FullName
    
    foreach ($depPath in $optionalDependencies) {
        try {
            Write-Host "Loading dependency: $(Split-Path -Leaf $depPath)..." -ForegroundColor Gray
            Add-Type -Path $depPath -ErrorAction SilentlyContinue
        }
        catch {
            # Ignore if already loaded or failed to load
        }
    }
    
    Write-Host "Loading FastSerialization.dll..." -ForegroundColor Gray
    Add-Type -Path $fastSerializationDll -ErrorAction Stop
    
    Write-Host "Loading TraceEvent.dll..." -ForegroundColor Gray
    Add-Type -Path $traceEventDll -ErrorAction Stop
    
    Write-Host "TraceEvent libraries loaded successfully." -ForegroundColor Green
}
catch [System.Reflection.ReflectionTypeLoadException] {
    Write-Host "Error loading TraceEvent assemblies: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "`nLoader Exceptions:" -ForegroundColor Yellow
    
    $missingAssemblies = @()
    foreach ($loaderException in $_.Exception.LoaderExceptions) {
        Write-Host "  - $($loaderException.Message)" -ForegroundColor Red
        
        # Extract assembly name from error message
        if ($loaderException.Message -match "Could not load file or assembly '([^,]+)") {
            $asmName = $matches[1]
            if ($missingAssemblies -notcontains $asmName) {
                $missingAssemblies += $asmName
            }
        }
    }
    
    if ($missingAssemblies.Count -gt 0) {
        Write-Host "`nMissing Dependencies:" -ForegroundColor Yellow
        foreach ($asm in $missingAssemblies) {
            Write-Host "  - $asm.dll" -ForegroundColor Cyan
        }
        Write-Host "`nTo resolve this:" -ForegroundColor Yellow
        Write-Host "  1. Download the missing DLLs from NuGet packages:" -ForegroundColor Yellow
        Write-Host "     - System.Memory (from System.Memory package)" -ForegroundColor Gray
        Write-Host "     - System.Text.Json (from System.Text.Json package)" -ForegroundColor Gray
        Write-Host "     - System.Reflection.Metadata (from System.Reflection.Metadata package)" -ForegroundColor Gray
        Write-Host "  2. Copy them to: $scriptDir" -ForegroundColor Yellow
    }
    
    Write-Host "`nCurrent .NET Version: $([System.Environment]::Version)" -ForegroundColor Cyan
    exit 1
}
catch {
    Write-Host "Error loading TraceEvent assemblies: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "`nException Type: $($_.Exception.GetType().FullName)" -ForegroundColor Yellow
    if ($_.Exception.InnerException) {
        Write-Host "Inner Exception: $($_.Exception.InnerException.Message)" -ForegroundColor Red
    }
    Write-Host "`nCurrent .NET Version: $([System.Environment]::Version)" -ForegroundColor Cyan
    Write-Host "This may occur if .NET Standard 2.0 support is not available." -ForegroundColor Yellow
    Write-Host "Ensure .NET Framework 4.7.2+ is installed." -ForegroundColor Yellow
    exit 1
}

# Define CSV log file paths
$csvLogFilePath = Join-Path $scriptDir "$env:ComputerName-$ProcessName-DataLogging.csv"
$csvDailyLogFilePath = Join-Path $scriptDir "$env:ComputerName-$ProcessName-DataLogging_24Hour.csv"

# Recover previous cumulative totals from existing CSV BEFORE opening StreamWriter (which locks the file)
$previousTotals = Get-PreviousCsvTotals -CsvFilePath $csvLogFilePath
if ($previousTotals.BytesSent -gt 0 -or $previousTotals.BytesReceived -gt 0) {
    Write-Host "Recovered previous cumulative totals from CSV:" -ForegroundColor Cyan
    Write-Host ("  Previous Sent: {0:N0} bytes ({1:F2} MB)" -f $previousTotals.BytesSent, ($previousTotals.BytesSent / 1MB)) -ForegroundColor Cyan
    Write-Host ("  Previous Received: {0:N0} bytes ({1:F2} MB)" -f $previousTotals.BytesReceived, ($previousTotals.BytesReceived / 1MB)) -ForegroundColor Cyan
}

# Initialize CSV log files
$csvLogFile = $null
$csvDailyLogFile = $null

try {
    
    # Create main interval log with header if new file
    $isNewFile = -not (Test-Path $csvLogFilePath)
    $csvLogFile = New-Object System.IO.StreamWriter($csvLogFilePath, $true, [System.Text.Encoding]::UTF8)
    $csvLogFile.AutoFlush = $true
    
    if ($isNewFile) {
        $csvLogFile.WriteLine("Timestamp,ComputerName,ProcessName,PeriodType,DurationSeconds,BytesSent,BytesReceived,TotalBytes")
    }
    
    # Create daily summary log with header if new file
    $isNewDailyFile = -not (Test-Path $csvDailyLogFilePath)
    $csvDailyLogFile = New-Object System.IO.StreamWriter($csvDailyLogFilePath, $true, [System.Text.Encoding]::UTF8)
    $csvDailyLogFile.AutoFlush = $true
    
    if ($isNewDailyFile) {
        $csvDailyLogFile.WriteLine("Timestamp,ComputerName,ProcessName,PeriodType,DurationSeconds,BytesSent,BytesReceived,TotalBytes")
    }
    
    Write-Host "CSV log files initialized." -ForegroundColor Green
    Write-Host "Main log: $csvLogFilePath" -ForegroundColor Gray
    Write-Host "Daily log: $csvDailyLogFilePath" -ForegroundColor Gray
}
catch {
    Write-Host "Error initializing CSV log files: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# Get process IDs for the target process
$processes = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue
$processList = New-Object 'System.Collections.Generic.HashSet[int]'

if ($null -ne $processes) {
    foreach ($proc in $processes) {
        [void]$processList.Add($proc.Id)
    }
}

if ($processList.Count -eq 0) {
    Write-Host "Warning: No processes found with name '$ProcessName'" -ForegroundColor Yellow
    Write-Host "The script will continue monitoring, but no data will be captured until the process starts." -ForegroundColor Yellow
}

# Display monitored PIDs
Write-Host 
Write-Host "#####################################################################################"
$timestamp = Get-Date -Format "M/d/yyyy HH:mm:ss"
Write-Host "$timestamp - Started capturing bytes sent/received for $ProcessName.exe"
if ($processList.Count -gt 0) {
    Write-Host "Monitoring PID: $($processList -join ', ')"
}
Write-Host "#####################################################################################"
Write-Host

# Counter variables (thread-safe using synchronized hashtable)
# Seed Sent/Received with previous totals so the running total continues across restarts
$counters = [hashtable]::Synchronized(@{
    Received = [long]$previousTotals.BytesReceived
    Sent = [long]$previousTotals.BytesSent
    DailyReceived = [long]0
    DailySent = [long]0
    DailyWindowStart = Get-Date
})

# Flag for graceful shutdown
$script:shutdownRequested = $false

# Handle Ctrl+C for graceful shutdown
$null = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action {
    $script:shutdownRequested = $true
}

# Create cleanup scriptblock
$cleanupScript = {
    param($session)
    if ($null -ne $session) {
        try {
            $session.Stop()
            $session.Dispose()
        }
        catch {
            # Suppress disposal errors
        }
    }
}

# ETW Session and Processing
$session = $null
$etwRunspace = $null
$etwPowerShell = $null

try {
    Write-Host "Starting ETW kernel session..." -ForegroundColor Cyan
    
    # Create unique session name
    $sessionName = "ProcessPayloadSession_$PID"
    
    # Create the ETW session
    try {
        $session = New-Object Microsoft.Diagnostics.Tracing.Session.TraceEventSession($sessionName)
    }
    catch [System.UnauthorizedAccessException] {
        Write-Host "Error: Access denied when creating ETW session." -ForegroundColor Red
        Write-Host "Ensure you are running as Administrator and no other ETW session conflicts exist." -ForegroundColor Red
        throw
    }
    catch {
        Write-Host "Error creating ETW session: $($_.Exception.Message)" -ForegroundColor Red
        throw
    }
    
    # Size the ETW buffers explicitly. The TraceEvent default (~64MB, or 2MB per
    # logical CPU if larger) can overrun silently on a chatty process, causing
    # ETW to drop events with no exception - the script would just under-report
    # bytes sent/received. This must be set before EnableKernelProvider is called.
    $session.BufferSizeMB = $BufferSizeMB

    # Enable kernel provider for network events
    $networkKeywords = [Microsoft.Diagnostics.Tracing.Parsers.KernelTraceEventParser+Keywords]::NetworkTCPIP
    $session.EnableKernelProvider($networkKeywords)
    
    Write-Host "ETW session started successfully. (Buffer size: ${BufferSizeMB}MB)" -ForegroundColor Green
    
    # Create a runspace for ETW processing (non-blocking)
    $etwRunspace = [runspacefactory]::CreateRunspace()
    $etwRunspace.Open()
    $etwRunspace.SessionStateProxy.SetVariable("session", $session)
    $etwRunspace.SessionStateProxy.SetVariable("processList", $processList)
    $etwRunspace.SessionStateProxy.SetVariable("counters", $counters)
    $etwRunspace.SessionStateProxy.SetVariable("DebugEvents", $DebugEvents)
    
    $etwPowerShell = [powershell]::Create()
    $etwPowerShell.Runspace = $etwRunspace
    
    # ETW processing scriptblock - register handlers and process events
    # Note: Using string-based scriptblock to ensure proper variable scope
    [void]$etwPowerShell.AddScript(@'
        try {
            $eventCount = 0
            
            # Define event handler for TcpIpRecv
            $recvHandler = {
                param($data)
                try {
                    $script:eventCount++
                    
                    # Access properties safely
                    $processId = 0
                    $size = 0
                    
                    if ($data.PSObject.Properties['ProcessID']) {
                        $processId = $data.ProcessID
                    }
                    if ($data.PSObject.Properties['size']) {
                        $size = $data.size
                    }
                    
                    if ($DebugEvents) {
                        [Console]::WriteLine("Recv: PID=$processId Size=$size")
                    }
                    
                    if ($processList.Contains($processId) -and $size -gt 0) {
                        $counters['Received'] = $counters['Received'] + $size
                        $counters['DailyReceived'] = $counters['DailyReceived'] + $size
                        if ($DebugEvents) {
                            [Console]::WriteLine("  -> Matched Recv! Total: $($counters['Received'])")
                        }
                    }
                }
                catch {
                    if ($DebugEvents) {
                        [Console]::WriteLine("Recv Error: $_")
                    }
                }
            }
            
            # Define event handler for TcpIpSend
            $sendHandler = {
                param($data)
                try {
                    $script:eventCount++
                    
                    # Access properties safely
                    $processId = 0
                    $size = 0
                    
                    if ($data.PSObject.Properties['ProcessID']) {
                        $processId = $data.ProcessID
                    }
                    if ($data.PSObject.Properties['size']) {
                        $size = $data.size
                    }
                    
                    if ($DebugEvents) {
                        [Console]::WriteLine("Send: PID=$processId Size=$size")
                    }
                    
                    if ($processList.Contains($processId) -and $size -gt 0) {
                        $counters['Sent'] = $counters['Sent'] + $size
                        $counters['DailySent'] = $counters['DailySent'] + $size
                        if ($DebugEvents) {
                            [Console]::WriteLine("  -> Matched Send! Total: $($counters['Sent'])")
                        }
                    }
                }
                catch {
                    if ($DebugEvents) {
                        [Console]::WriteLine("Send Error: $_")
                    }
                }
            }
            
            # Register event handlers
            $session.Source.Kernel.add_TcpIpRecv($recvHandler)
            $session.Source.Kernel.add_TcpIpSend($sendHandler)
            
            if ($DebugEvents) {
                [Console]::WriteLine("Event handlers registered. Starting event processing...")
            }
            
            # Process events (blocking call) - use explicit method invocation
            $null = $session.Source.GetType().GetMethod('Process').Invoke($session.Source, $null)
        }
        catch {
            # ETW processing errors are logged but don't crash the script
            [Console]::WriteLine("ETW processing error: $($_.Exception.Message)")
        }
'@)
    
    # Start ETW processing asynchronously
    $etwHandle = $etwPowerShell.BeginInvoke()
    
    Write-Host "Monitoring network traffic. Press Ctrl+C to stop." -ForegroundColor Green
    Write-Host
    
    # Tracks the last-seen ETW buffer overrun count so we can detect and warn
    # when the kernel session starts dropping events (silent data loss).
    $lastEventsLost = 0
    
    # Main monitoring loop
    while (-not $script:shutdownRequested) {
        # Wait for update interval (5 minutes)
        Start-Sleep -Seconds 300
        
        # Check for shutdown
        if ($script:shutdownRequested) {
            break
        }
        
        # Read counters with null-safe handling
        $currentSent = if ($null -eq $counters.Sent) { [long]0 } else { $counters.Sent }
        $currentReceived = if ($null -eq $counters.Received) { [long]0 } else { $counters.Received }
        $currentDailySent = if ($null -eq $counters.DailySent) { [long]0 } else { $counters.DailySent }
        $currentDailyReceived = if ($null -eq $counters.DailyReceived) { [long]0 } else { $counters.DailyReceived }
        $dailyStart = $counters.DailyWindowStart
        
        # Detect ETW buffer overruns - if events are lost, Sent/Received are under-counted
        # with no exception raised, so this must be checked explicitly.
        try {
            $currentEventsLost = $session.EventsLost
            if ($currentEventsLost -gt $lastEventsLost) {
                Write-Host "Warning: ETW buffers overran - $($currentEventsLost - $lastEventsLost) events lost since last check (total: $currentEventsLost). Byte counts may be under-reported. Consider increasing -BufferSizeMB." -ForegroundColor Red
                $lastEventsLost = $currentEventsLost
            }
        }
        catch {
            # Ignore if the session doesn't support querying EventsLost at this point
        }
        
        # Check if 24 hours have passed
        $elapsed = (Get-Date) - $dailyStart
        if ($elapsed.TotalHours -ge 24) {
            $dailyEnd = Get-Date
            
            # Log 24-hour summary
            try {
                Write-Host
                Write-Host "=== 24-Hour Period Complete ===" -ForegroundColor Cyan
                Write-Host "Period: $($dailyStart.ToString('yyyy-MM-dd HH:mm:ss')) to $($dailyEnd.ToString('yyyy-MM-dd HH:mm:ss'))"
                Write-Host ("Duration: {0}:{1:D2}:{2:D2}:{3:D2}" -f $elapsed.Days, $elapsed.Hours, $elapsed.Minutes, $elapsed.Seconds)
                Write-Host ("Sent: {0:N0} bytes ({1:F2} MB)" -f $currentDailySent, ($currentDailySent / 1MB))
                Write-Host ("Received: {0:N0} bytes ({1:F2} MB)" -f $currentDailyReceived, ($currentDailyReceived / 1MB))
                Write-Host "==============================" -ForegroundColor Cyan
                Write-Host
                
                # Write CSV entry for 24-hour period
                Write-CsvLog -CsvFile $csvDailyLogFile `
                    -ComputerName $env:ComputerName `
                    -ProcessName $ProcessName `
                    -PeriodType "Daily" `
                    -StartTime $dailyStart `
                    -EndTime $dailyEnd `
                    -BytesSent $currentDailySent `
                    -BytesReceived $currentDailyReceived
            }
            catch {
                Write-Host "Error writing 24-hour summary to CSV log: $($_.Exception.Message)" -ForegroundColor Red
            }
            
            # Reset daily counters
            $counters.DailySent = 0
            $counters.DailyReceived = 0
            $counters.DailyWindowStart = Get-Date
        }
        
        # Log current status (5-minute interval)
        $timestamp = Get-Date -Format "M/d/yyyy HH:mm:ss"
        $statusMsg = "$timestamp - Sent: {0:N0} bytes    Received: {1:N0} bytes" -f $currentSent, $currentReceived
        Write-Host $statusMsg
        
        # Write CSV entry for this interval
        $intervalEnd = Get-Date
        $intervalStart = $intervalEnd.AddSeconds(-300)
        Write-CsvLog -CsvFile $csvLogFile `
            -ComputerName $env:ComputerName `
            -ProcessName $ProcessName `
            -PeriodType "Interval" `
            -StartTime $intervalStart `
            -EndTime $intervalEnd `
            -BytesSent $currentSent `
            -BytesReceived $currentReceived
    }
}
catch {
    Write-Host "Error during monitoring: $($_.Exception.Message)" -ForegroundColor Red
}
finally {
    Write-Host
    Write-Host "Shutting down gracefully..." -ForegroundColor Yellow
    
    # Report final ETW buffer-overrun count so any silent under-counting is visible
    if ($null -ne $session) {
        try {
            $totalEventsLost = $session.EventsLost
            if ($totalEventsLost -gt 0) {
                Write-Host "Warning: ETW session lost $totalEventsLost events total due to buffer overruns. Sent/Received totals may be under-reported." -ForegroundColor Red
            }
        }
        catch {
            # Ignore if EventsLost can't be queried (e.g. session already stopped)
        }
    }
    
    # Stop ETW session
    if ($null -ne $session) {
        try {
            Write-Host "Stopping ETW session..." -ForegroundColor Cyan
            # Use Source.StopProcessing() first to stop event processing
            if ($null -ne $session.Source) {
                try {
                    $session.Source.StopProcessing()
                }
                catch {
                    # Ignore if already stopped
                }
            }
            # Then stop the session itself
            $session.Stop()
        }
        catch [System.TypeInitializationException] {
            # Registry type initialization can fail on cleanup - this is safe to ignore
            Write-Host "ETW session cleanup complete." -ForegroundColor Gray
        }
        catch {
            Write-Host "Warning: Error stopping ETW session: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
    
    # Stop ETW processing thread
    if ($null -ne $etwPowerShell) {
        try {
            $etwPowerShell.Stop()
            $etwPowerShell.Dispose()
        }
        catch {
            # Suppress disposal errors
        }
    }
    
    if ($null -ne $etwRunspace) {
        try {
            $etwRunspace.Close()
            $etwRunspace.Dispose()
        }
        catch {
            # Suppress disposal errors
        }
    }
    
    # Dispose session
    if ($null -ne $session) {
        try {
            $session.Dispose()
        }
        catch {
            # Suppress disposal errors
        }
    }
    
    # Final summary
    $shutdownTime = Get-Date
    $finalElapsed = $shutdownTime - $counters.DailyWindowStart
    
    # Get counter values with null-safe handling for shutdown
    $finalSent = if ($null -eq $counters.Sent) { [long]0 } else { $counters.Sent }
    $finalReceived = if ($null -eq $counters.Received) { [long]0 } else { $counters.Received }
    $finalDailySent = if ($null -eq $counters.DailySent) { [long]0 } else { $counters.DailySent }
    $finalDailyReceived = if ($null -eq $counters.DailyReceived) { [long]0 } else { $counters.DailyReceived }
    
    # Log final partial period if any data exists
    if ($finalDailySent -gt 0 -or $finalDailyReceived -gt 0) {
        Write-Host
        Write-Host "=== Final Partial Period ===" -ForegroundColor Cyan
        Write-Host "Period: $($counters.DailyWindowStart.ToString('yyyy-MM-dd HH:mm:ss')) to $($shutdownTime.ToString('yyyy-MM-dd HH:mm:ss'))"
        Write-Host ("Duration: {0}:{1:D2}:{2:D2}:{3:D2}" -f $finalElapsed.Days, $finalElapsed.Hours, $finalElapsed.Minutes, $finalElapsed.Seconds)
        Write-Host ("Sent: {0:N0} bytes ({1:F2} MB)" -f $finalDailySent, ($finalDailySent / 1MB))
        Write-Host ("Received: {0:N0} bytes ({1:F2} MB)" -f $finalDailyReceived, ($finalDailyReceived / 1MB))
        Write-Host "============================" -ForegroundColor Cyan
        Write-Host
        
        if ($null -ne $csvDailyLogFile) {
            try {
                # Write CSV entry for final partial period
                Write-CsvLog -CsvFile $csvDailyLogFile `
                    -ComputerName $env:ComputerName `
                    -ProcessName $ProcessName `
                    -PeriodType "Partial" `
                    -StartTime $counters.DailyWindowStart `
                    -EndTime $shutdownTime `
                    -BytesSent $finalDailySent `
                    -BytesReceived $finalDailyReceived
            }
            catch {
                Write-Host "Warning: Could not write to daily CSV log file during shutdown." -ForegroundColor Yellow
            }
        }
    }
    
    # Total summary
    Write-Host
    Write-Host "$($shutdownTime.ToString('M/d/yyyy HH:mm:ss')) - Final Summary:" -ForegroundColor Green
    Write-Host ("Total Sent: {0:N0} bytes ({1:F2} MB)" -f $finalSent, ($finalSent / 1MB))
    Write-Host ("Total Received: {0:N0} bytes ({1:F2} MB)" -f $finalReceived, ($finalReceived / 1MB))
    Write-Host
    
    # Write final cumulative summary to CSV
    if ($null -ne $csvLogFile) {
        try {
            Write-CsvLog -CsvFile $csvLogFile `
                -ComputerName $env:ComputerName `
                -ProcessName $ProcessName `
                -PeriodType "Final" `
                -StartTime $counters.DailyWindowStart `
                -EndTime $shutdownTime `
                -BytesSent $finalSent `
                -BytesReceived $finalReceived
        }
        catch {
            Write-Host "Warning: Could not write final summary to CSV log file." -ForegroundColor Yellow
        }
    }
    
    # Close CSV log files with proper error handling
    if ($null -ne $csvLogFile) {
        try {
            $csvLogFile.Flush()
            $csvLogFile.Close()
            $csvLogFile.Dispose()
            $csvLogFile = $null
        }
        catch {
            Write-Host "Warning: Error closing main CSV log file: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
    
    if ($null -ne $csvDailyLogFile) {
        try {
            $csvDailyLogFile.Flush()
            $csvDailyLogFile.Close()
            $csvDailyLogFile.Dispose()
            $csvDailyLogFile = $null
        }
        catch {
            Write-Host "Warning: Error closing daily CSV log file: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
    
    Write-Host "Script completed." -ForegroundColor Green
    
    # Force garbage collection to release any remaining file handles
    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()
    
    # Allow a brief moment for cleanup to complete
    Start-Sleep -Milliseconds 500
}

#endregion

# Explicitly exit the PowerShell process
exit 0
