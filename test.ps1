<#
.SYNOPSIS
    Installs a built Nikrun FreePascal SDK archive locally, generates fpc.cfg, and runs an end-to-end smoke test.

.EXAMPLE
    .\test.ps1
    .\test.ps1 -ZipPath .\dist\nikrun-fpc-sdk-3.2.4-66940ee6-x86_64-win64.zip
    .\test.ps1 -SdkPath "$env:USERPROFILE\.nikrun\sdks\nikrun-fpc-sdk-3.2.4-66940ee6-x86_64-win64"
#>
[CmdletBinding()]
param(
    [Parameter()]
    [string]$ZipPath = '',

    [Parameter()]
    [string]$InstallRoot = '',

    [Parameter()]
    [string]$SdkPath = ''
)

$ErrorActionPreference = 'Stop'
$ScriptRoot = $PSScriptRoot
$RepoRoot   = $ScriptRoot
Set-StrictMode -Version Latest

# 1. If no existing SdkPath was explicitly passed, extract and configure the ZIP archive first
if ([string]::IsNullOrWhiteSpace($SdkPath)) {
    if ([string]::IsNullOrWhiteSpace($InstallRoot)) {
        $HomeDir     = if ($env:USERPROFILE) { $env:USERPROFILE } else { $env:HOME }
        $InstallRoot = Join-Path $HomeDir '.nikrun\sdks'
    }

    if ([string]::IsNullOrWhiteSpace($ZipPath)) {
        $DistDir   = Join-Path $RepoRoot 'dist'
        $LatestZip = Get-ChildItem -Path $DistDir -Filter 'nikrun-fpc-*.zip' -ErrorAction SilentlyContinue |
                     Sort-Object LastWriteTime -Descending |
                     Select-Object -First 1
        if ($null -eq $LatestZip) {
            throw "No nikrun-fpc-*.zip found in $DistDir. Run .\build.ps1 first."
        }
        $ZipPath = $LatestZip.FullName
    }

    if (-not (Test-Path $ZipPath)) {
        throw "FPC SDK archive not found: $ZipPath"
    }

    $SdkName = [System.IO.Path]::GetFileNameWithoutExtension($ZipPath)
    $SdkPath = Join-Path $InstallRoot $SdkName

    Write-Host "`n==> Installing FPC SDK '$SdkName' for testing..." -ForegroundColor Cyan
    Write-Host "    Source Archive : $ZipPath" -ForegroundColor Gray
    Write-Host "    Destination    : $SdkPath" -ForegroundColor Gray

    if (Test-Path $SdkPath) {
        Remove-Item -Recurse -Force $SdkPath
    }
    New-Item -ItemType Directory -Force -Path $SdkPath | Out-Null

    if (($env:OS -match 'Windows') -and (Get-Command tar.exe -ErrorAction SilentlyContinue)) {
        & tar.exe -xf $ZipPath -C $SdkPath
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to extract $ZipPath via tar.exe"
        }
    } elseif (Get-Command unzip -ErrorAction SilentlyContinue) {
        & unzip -q $ZipPath -d $SdkPath
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to extract $ZipPath via unzip"
        }
    } else {
        Expand-Archive -Path $ZipPath -DestinationPath $SdkPath -Force
    }

    $ManifestFile = Join-Path $SdkPath 'sdk-manifest.json'
    if (-not (Test-Path $ManifestFile)) {
        throw "Invalid FPC SDK archive: sdk-manifest.json missing in $SdkPath"
    }
    $Manifest = Get-Content $ManifestFile -Raw | ConvertFrom-Json

    $BinDir   = Join-Path $SdkPath $Manifest.paths.binDir
    $UnitsDir = Join-Path $SdkPath $Manifest.paths.unitsDir
    $FpcCfg   = Join-Path $BinDir 'fpc.cfg'

    if ($Manifest.targetOs -ne 'win64' -and (Get-Command chmod -ErrorAction SilentlyContinue)) {
        & chmod -R +x $BinDir
    }

    $NormalizedBin   = $BinDir.Replace('\', '/')
    $NormalizedUnits = $UnitsDir.Replace('\', '/')

    $ExtraPlatformCfg = ""
    if ($Manifest.targetOs -eq 'darwin') {
        $darwinLines = @()
        $minMacOs = if ($Manifest.targetCpu -eq 'aarch64') { '11.0' } else { '10.15' }
        $darwinLines += "-WM$minMacOs"
        if (Get-Command xcrun -ErrorAction SilentlyContinue) {
            $macSdk = (& xcrun --show-sdk-path 2>$null | Select-Object -First 1).Trim()
            if (-not [string]::IsNullOrWhiteSpace($macSdk)) {
                $darwinLines += "-XR$macSdk"
                if (Test-Path "$macSdk/usr/lib") {
                    $darwinLines += "-Fl$macSdk/usr/lib"
                }
            }
        }
        if (Test-Path '/Library/Developer/CommandLineTools/usr/bin') {
            $darwinLines += "-FD/Library/Developer/CommandLineTools/usr/bin"
        }
        $ExtraPlatformCfg = "`n# macOS SDK sysroot, library stubs, and toolchain paths`n" + ($darwinLines -join "`n")
    } elseif ($Manifest.targetOs -eq 'linux') {
        $linuxLibLines = @()
        foreach ($candidate in @(
            "/lib/$($Manifest.targetCpu)-linux-gnu",
            "/usr/lib/$($Manifest.targetCpu)-linux-gnu",
            "/lib64",
            "/usr/lib64",
            "/lib",
            "/usr/lib"
        )) {
            if (Test-Path $candidate) {
                $linuxLibLines += "-Fl$candidate"
            }
        }
        if (Get-Command gcc -ErrorAction SilentlyContinue) {
            $crtBegin = (& gcc -print-file-name=crtbegin.o 2>$null | Select-Object -First 1).Trim()
            if (-not [string]::IsNullOrWhiteSpace($crtBegin) -and (Test-Path $crtBegin)) {
                $gccLibDir = Split-Path -Parent $crtBegin
                $linuxLibLines += "-Fl$gccLibDir"
            }
        }
        if ($Manifest.targetCpu -eq 'aarch64') {
            $linuxLibLines += "-k--defsym=__libc_csu_init=0"
            $linuxLibLines += "-k--defsym=__libc_csu_fini=0"
        }
        if ($linuxLibLines.Count -gt 0) {
            $ExtraPlatformCfg = "`n# System C library search paths`n" + ($linuxLibLines -join "`n")
        }
    }

    # Generate a clean, deterministic fpc.cfg tailored to this installation directory
    $CfgContent = @"
# ==============================================================================
# Nikrun Portable FreePascal SDK Configuration (Auto-generated)
# SDK: $($Manifest.sdkId) (FPC $($Manifest.fpcVersion), $($Manifest.targetTriplet))
# ==============================================================================

# Default to Object Pascal mode with AnsiStrings unless overridden in source
-Mobjfpc
-Sh
-Sc
-Si

# Enable DWARF debug info & line info when -dDEBUG is passed, strip in -dRELEASE
#IFDEF DEBUG
-gl
-gw2
-Cr
-Ci
-Co
#ENDIF

#IFDEF RELEASE
-O2
-Xs
-CX
-XX
#ENDIF

# Unit search paths (RTL & Packages)
-Fu$NormalizedUnits
-Fu$NormalizedUnits/*
-Fu$NormalizedUnits/rtl

# Binary & Binutils search path (ld, as, ar, windres)
-FD$NormalizedBin

# Library search path
-Fl$NormalizedUnits$ExtraPlatformCfg

# Display errors, warnings, and notes with full file paths for IDE Problem Matchers
-viwn
-vb
-l-
"@

    $CfgContent | Set-Content -Path $FpcCfg -Encoding ASCII
    # On Unix (Linux/macOS), FPC automatically searches ../etc/fpc.cfg relative to the compiler binary
    $UnixEtcDir = Join-Path (Split-Path -Parent $BinDir) 'etc'
    New-Item -ItemType Directory -Force -Path $UnixEtcDir | Out-Null
    $CfgContent | Set-Content -Path (Join-Path $UnixEtcDir 'fpc.cfg') -Encoding ASCII
    Write-Host " [OK] Generated clean fpc.cfg at: $FpcCfg" -ForegroundColor Green
}

# 2. Verify SDK structure and run smoke test
Write-Host "`n==> Testing Nikrun FreePascal SDK at: $SdkPath" -ForegroundColor Cyan

$ManifestPath = Join-Path $SdkPath 'sdk-manifest.json'
if (-not (Test-Path $ManifestPath)) {
    throw "Test failed: sdk-manifest.json missing in $SdkPath"
}
$Manifest = Get-Content $ManifestPath -Raw | ConvertFrom-Json
if ([string]::IsNullOrWhiteSpace($Manifest.gitCommit)) {
    throw "Test failed: gitCommit missing in $ManifestPath"
}
Write-Host " [OK] Verified Commit SHA     : $($Manifest.gitCommit)" -ForegroundColor Green

$FpcBin    = Join-Path $SdkPath $Manifest.paths.fpcBinary
$FpcCfg    = Join-Path (Join-Path $SdkPath $Manifest.paths.binDir) 'fpc.cfg'
$UnitsDir  = Join-Path $SdkPath $Manifest.paths.unitsDir
$RtlSrcDir = Join-Path $SdkPath $Manifest.paths.rtlSourceDir
$PkgSrcDir = Join-Path $SdkPath $Manifest.paths.packagesSourceDir

foreach ($item in @(
    @{ Name = 'Compiler Binary'; Path = $FpcBin },
    @{ Name = 'Compiler Config'; Path = $FpcCfg },
    @{ Name = 'Units Directory'; Path = $UnitsDir },
    @{ Name = 'RTL Source Dir';  Path = $RtlSrcDir },
    @{ Name = 'Packages Source'; Path = $PkgSrcDir }
)) {
    if (-not (Test-Path $item.Path)) {
        throw "Test failed: $($item.Name) not found at $($item.Path)"
    }
    Write-Host " [OK] Verified $($item.Name): $($item.Path)" -ForegroundColor Green
}

# Create an isolated temporary project to compile & run
$TestWorkDir = Join-Path $RepoRoot '.work\sdk-smoke-test'
if (Test-Path $TestWorkDir) {
    Remove-Item -Recurse -Force $TestWorkDir
}
$TestSrcDir   = Join-Path $TestWorkDir 'src'
$TestCacheDir = Join-Path $TestWorkDir '.cache'
$TestBinDir   = Join-Path $TestWorkDir 'bin'
New-Item -ItemType Directory -Force -Path $TestSrcDir, $TestCacheDir, $TestBinDir | Out-Null

$SmokePas = Join-Path $TestSrcDir 'smoketest.pas'
@"
program smoketest;

{`$mode objfpc}{`$H+}

uses
  SysUtils, Classes, Generics.Collections, fpjson;

type
  TNumberList = specialize TList<Integer>;

var
  Numbers: TNumberList;
  Sum, N: Integer;
  JsonObj: TJSONObject;
begin
  Numbers := TNumberList.Create;
  try
    Numbers.AddRange([10, 20, 12]);
    Sum := 0;
    for N in Numbers do
      Inc(Sum, N);

    JsonObj := TJSONObject.Create;
    try
      JsonObj.Add('status', 'ok');
      JsonObj.Add('compilerVersion', {`$I %FPCVERSION%});
      JsonObj.Add('targetCpu', {`$I %FPCTARGETCPU%});
      JsonObj.Add('targetOs', {`$I %FPCTARGETOS%});
      JsonObj.Add('answer', Sum);
      WriteLn(JsonObj.AsJSON);
    finally
      JsonObj.Free;
    end;
  finally
    Numbers.Free;
  end;
end.
"@ | Set-Content -Path $SmokePas -Encoding UTF8

Write-Host "`n==> Compiling smoke test with isolated FPC SDK..." -ForegroundColor Cyan
& $FpcBin -n "@$FpcCfg" -dDEBUG "-FE$TestBinDir" "-FU$TestCacheDir" $SmokePas
if ($LASTEXITCODE -ne 0) {
    throw "Smoke test compilation failed with exit code $LASTEXITCODE"
}

$ExeExt   = if ($Manifest.targetOs -eq 'win64') { '.exe' } else { '' }
$SmokeExe = Join-Path $TestBinDir "smoketest$ExeExt"
if (-not (Test-Path $SmokeExe)) {
    throw "Compiled executable not found at $SmokeExe"
}

Write-Host "==> Running compiled binary..." -ForegroundColor Cyan
$Output = & $SmokeExe
if ($LASTEXITCODE -ne 0) {
    throw "Smoke test execution failed with exit code $LASTEXITCODE"
}

Write-Host "    Output: $Output" -ForegroundColor Gray
$Parsed = $Output | ConvertFrom-Json
if ($Parsed.status -ne 'ok' -or $Parsed.answer -ne 42) {
    throw "Unexpected smoke test output: $Output"
}

Write-Host " [OK] FPC SDK Smoke Test PASSED (FPC $($Parsed.compilerVersion) on $($Parsed.targetCpu)-$($Parsed.targetOs))!" -ForegroundColor Green
