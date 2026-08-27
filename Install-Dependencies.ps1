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

# Define required packages and their versions
$packages = @(
    @{ Name = "System.Memory"; Version = "4.5.5"; DllPath = "lib\netstandard2.0\System.Memory.dll" },
    @{ Name = "System.Buffers"; Version = "4.5.1"; DllPath = "lib\netstandard2.0\System.Buffers.dll" },
    @{ Name = "System.Runtime.CompilerServices.Unsafe"; Version = "6.0.0"; DllPath = "lib\netstandard2.0\System.Runtime.CompilerServices.Unsafe.dll" },
    @{ Name = "System.Numerics.Vectors"; Version = "4.5.0"; DllPath = "lib\netstandard2.0\System.Numerics.Vectors.dll" },
    @{ Name = "System.Text.Json"; Version = "9.0.0"; DllPath = "lib\netstandard2.0\System.Text.Json.dll" },
    @{ Name = "System.Text.Encodings.Web"; Version = "9.0.0"; DllPath = "lib\netstandard2.0\System.Text.Encodings.Web.dll" },
    @{ Name = "System.Reflection.Metadata"; Version = "9.0.0"; DllPath = "lib\netstandard2.0\System.Reflection.Metadata.dll" },
    @{ Name = "System.Collections.Immutable"; Version = "9.0.0"; DllPath = "lib\netstandard2.0\System.Collections.Immutable.dll" },
    @{ Name = "Microsoft.Win32.Registry"; Version = "5.0.0"; DllPath = "lib\netstandard2.0\Microsoft.Win32.Registry.dll" },
    @{ Name = "System.Security.AccessControl"; Version = "6.0.0"; DllPath = "lib\netstandard2.0\System.Security.AccessControl.dll" },
    @{ Name = "System.Security.Principal.Windows"; Version = "5.0.0"; DllPath = "lib\netstandard2.0\System.Security.Principal.Windows.dll" }
)

# Create temp directory for downloads
$tempDir = Join-Path $env:TEMP "ProcessExplorer_Dependencies_$([guid]::NewGuid())"
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

try {
    foreach ($package in $packages) {
        $packageName = $package.Name
        $packageVersion = $package.Version
        $dllRelativePath = $package.DllPath
        
        Write-Host "Processing: $packageName v$packageVersion..." -ForegroundColor Yellow
        
        # Download package
        $nupkgUrl = "https://www.nuget.org/api/v2/package/$packageName/$packageVersion"
        $nupkgPath = Join-Path $tempDir "$packageName.$packageVersion.nupkg"
        
        Write-Host "  Downloading..." -ForegroundColor Gray
        try {
            Invoke-WebRequest -Uri $nupkgUrl -OutFile $nupkgPath -UseBasicParsing -ErrorAction Stop
        }
        catch {
            Write-Host "  Warning: Failed to download $packageName - $($_.Exception.Message)" -ForegroundColor Red
            continue
        }
        
        # Extract package (nupkg is just a zip file)
        $extractPath = Join-Path $tempDir "$packageName.$packageVersion"
        Write-Host "  Extracting..." -ForegroundColor Gray
        
        # Rename to .zip for extraction
        $zipPath = [System.IO.Path]::ChangeExtension($nupkgPath, ".zip")
        Move-Item -Path $nupkgPath -Destination $zipPath -Force
        
        Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force
        
        # Copy DLL to script directory
        $dllPath = Join-Path $extractPath $dllRelativePath
        
        if (Test-Path $dllPath) {
            $destPath = Join-Path $scriptDir (Split-Path -Leaf $dllPath)
            Copy-Item -Path $dllPath -Destination $destPath -Force
            Write-Host "  Installed: $(Split-Path -Leaf $dllPath)" -ForegroundColor Green
        }
        else {
            Write-Host "  Warning: DLL not found at expected path: $dllRelativePath" -ForegroundColor Red
            Write-Host "  Package may have different structure. Searching..." -ForegroundColor Yellow
            
            # Search for the DLL in the package
            $dllName = Split-Path -Leaf $dllRelativePath
            $foundDll = Get-ChildItem -Path $extractPath -Filter $dllName -Recurse -ErrorAction SilentlyContinue | 
                        Where-Object { $_.FullName -like "*\lib\*" } | 
                        Select-Object -First 1
            
            if ($foundDll) {
                $destPath = Join-Path $scriptDir $dllName
                Copy-Item -Path $foundDll.FullName -Destination $destPath -Force
                Write-Host "  Installed: $dllName (found at alternate location)" -ForegroundColor Green
            }
            else {
                Write-Host "  Error: Could not find $dllName in package" -ForegroundColor Red
            }
        }
        
        Write-Host ""
    }
    
    Write-Host "=== Installation Complete ===" -ForegroundColor Green
    Write-Host "`nInstalled DLLs:" -ForegroundColor Cyan
    Get-ChildItem -Path $scriptDir -Filter "System.*.dll" | ForEach-Object {
        Write-Host "  - $($_.Name)" -ForegroundColor Gray
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

Write-Host "`nPress any key to exit..."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
