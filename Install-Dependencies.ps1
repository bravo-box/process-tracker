<#
.SYNOPSIS
    Downloads and extracts required dependencies for ProcessTracker.ps1

.DESCRIPTION
    This script downloads the required NuGet packages and extracts the necessary DLLs
    to the same directory as ProcessTracker.ps1 for .NET Framework 4.6.2+ compatibility.

.NOTES
    Requires internet connection to download packages from NuGet.org
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if ([string]::IsNullOrEmpty($scriptDir)) {
    $scriptDir = $PWD.Path
}

Write-Host "=== ProcessTracker Dependency Installer ===" -ForegroundColor Cyan
Write-Host "Target Directory: $scriptDir`n" -ForegroundColor Gray

# Only the root package needs to be listed here; its transitive dependencies are resolved
# automatically by nuget.exe. Pinned to 3.0.0 specifically because it's the last TraceEvent
# release with a .NETFramework4.6.2 target and a single dependency (System.Runtime.CompilerServices.Unsafe) -
# newer 3.1.x/3.2.x releases only ship netstandard2.0 and drag in Microsoft.Diagnostics.NETCore.Client,
# which pulls the entire Microsoft.Extensions.Logging/DependencyInjection family and is prone to
# resolving to modern SDK-only package versions that break both .NET Framework 4.6.2 and nuget.exe's
# classic installer.
$rootPackages = @(
    @{ Name = "Microsoft.Diagnostics.Tracing.TraceEvent"; Version = "3.0.0" }
)

# TFMs that actually load under .NET Framework 4.6.2+ / PowerShell 5.1, in priority order.
# net462+ builds are preferred over netstandard2.0 when both exist, since they're compiled
# directly against the target framework instead of relying on the netstandard facade.
$preferredTfms = @("net462", "net47", "net471", "net472", "net48", "net461", "net46", "netstandard2.0")
$nativeArchs = @("amd64", "x86", "arm64")

# Create temp directory for downloads
$tempDir = Join-Path $env:TEMP "ProcessExplorer_Dependencies_$([guid]::NewGuid())"
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
$installedDlls = [System.Collections.Generic.List[string]]::new()
$installedNative = [System.Collections.Generic.List[string]]::new()

try {
    $nugetExe = Join-Path $tempDir "nuget.exe"
    Write-Host "Downloading nuget.exe (used to resolve the full dependency tree)..." -ForegroundColor Yellow
    Invoke-WebRequest -Uri "https://dist.nuget.org/win-x86-commandline/latest/nuget.exe" -OutFile $nugetExe -UseBasicParsing -ErrorAction Stop

    $packagesDir = Join-Path $tempDir "packages"

    foreach ($pkg in $rootPackages) {
        Write-Host "`nResolving $($pkg.Name) v$($pkg.Version) and its dependencies..." -ForegroundColor Cyan
        # Lowest pins each transitive dependency to the minimum version its parent declares (what it
        # was actually built/tested against). Highest floats to the newest release on nuget.org, which
        # can land on a modern SDK-only package layout (buildTransitive-only, no netstandard2.0 lib)
        # that both breaks .NET Framework 4.6.2 compatibility and crashes nuget.exe's classic installer.
        & $nugetExe install $pkg.Name -Version $pkg.Version -OutputDirectory $packagesDir -DependencyVersion Lowest -NonInteractive -Verbosity quiet
        if ($LASTEXITCODE -ne 0) {
            throw "nuget.exe failed to install $($pkg.Name) $($pkg.Version) (exit code $LASTEXITCODE)"
        }
    }

    Write-Host "`nCopying assemblies to script directory..." -ForegroundColor Cyan
    Get-ChildItem -Path $packagesDir -Directory | ForEach-Object {
        $packageDir = $_.FullName

        # Prefer the real Windows implementation under runtimes\win\lib over the generic lib folder -
        # some packages (registry/security APIs) ship a stub under lib that throws at runtime.
        $libRoots = @((Join-Path $packageDir "runtimes\win\lib"), (Join-Path $packageDir "lib"))

        $chosenDir = $null
        foreach ($libRoot in $libRoots) {
            if (-not (Test-Path $libRoot)) { continue }
            foreach ($tfm in $preferredTfms) {
                $candidate = Join-Path $libRoot $tfm
                if (Test-Path $candidate) { $chosenDir = $candidate; break }
            }
            if ($chosenDir) { break }
        }

        if ($chosenDir) {
            Get-ChildItem -Path $chosenDir -Filter "*.dll" | ForEach-Object {
                $destPath = Join-Path $scriptDir $_.Name
                try {
                    Copy-Item -Path $_.FullName -Destination $destPath -Force -ErrorAction Stop
                    if ($installedDlls -notcontains $_.Name) {
                        $installedDlls.Add($_.Name)
                        Write-Host "  Installed: $($_.Name)" -ForegroundColor Green
                    }
                }
                catch {
                    # Already loaded by a prior ProcessTracker.ps1 run in this same PowerShell session -
                    # .NET Framework locks a DLL's file for the life of the process once it's loaded.
                    Write-Host "  Skipped (in use, likely already loaded in this session): $($_.Name)" -ForegroundColor Yellow
                }
            }
        }

        # ETW kernel sessions need the native DIA/KernelTraceControl DLLs alongside the script,
        # under an arch subfolder (amd64/x86/arm64) - the same layout TraceEvent's MSBuild targets produce.
        $nativeRoot = Join-Path $packageDir "build\native"
        if (Test-Path $nativeRoot) {
            foreach ($arch in $nativeArchs) {
                $archSrc = Join-Path $nativeRoot $arch
                if (-not (Test-Path $archSrc)) { continue }
                $archDest = Join-Path $scriptDir $arch
                New-Item -ItemType Directory -Path $archDest -Force | Out-Null
                Get-ChildItem -Path $archSrc -Filter "*.dll" | ForEach-Object {
                    $entry = "$arch\$($_.Name)"
                    try {
                        Copy-Item -Path $_.FullName -Destination (Join-Path $archDest $_.Name) -Force -ErrorAction Stop
                        if ($installedNative -notcontains $entry) {
                            $installedNative.Add($entry)
                            Write-Host "  Installed (native): $entry" -ForegroundColor Green
                        }
                    }
                    catch {
                        Write-Host "  Skipped (in use, likely already loaded in this session): $entry" -ForegroundColor Yellow
                    }
                }
            }
        }
    }

    Write-Host "`n=== Installation Complete ===" -ForegroundColor Green
    Write-Host "`nInstalled managed DLLs:" -ForegroundColor Cyan
    $installedDlls | Sort-Object | ForEach-Object { Write-Host "  - $_" -ForegroundColor Gray }
    if ($installedNative.Count -gt 0) {
        Write-Host "`nInstalled native DLLs:" -ForegroundColor Cyan
        $installedNative | Sort-Object | ForEach-Object { Write-Host "  - $_" -ForegroundColor Gray }
    }

    Write-Host "`nYou can now run ProcessTracker.ps1" -ForegroundColor Green
}
catch {
    Write-Host "`nError during installation: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Stack Trace: $($_.ScriptStackTrace)" -ForegroundColor Red
}
finally {
    # Cleanup temp directory
    if (Test-Path $tempDir) {
        Write-Host "`nCleaning up temporary files..." -ForegroundColor Gray
        Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# RawUI.ReadKey isn't supported in the VS Code/ISE integrated console, so fall back to Read-Host there
if ($Host.Name -eq 'ConsoleHost') {
    Write-Host "`nPress any key to exit..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}
else {
    Write-Host "`nPress Enter to exit..."
    $null = Read-Host
}
