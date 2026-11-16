<#
.SYNOPSIS
    Builds a portable, self-contained FreePascal SDK archive for the Nikrun ecosystem from a Git branch or repository URL.

.DESCRIPTION
    Validates the target Git repository and branch/ref, fetches FreePascal sources, verifies
    authentic FreePascal source layout, extracts the compiler version directly from
    compiler/version.pas, compiles the compiler, RTL, and standard packages in an isolated
    environment, bundles clean source files for IDE code completion, and packages the result
    as nikrun-fpc-sdk-<version>-<commitShortSha>-<cpu>-<os>.zip.

.EXAMPLE
    .\build.ps1
    .\build.ps1 -Branch main
    .\build.ps1 -Branch fixes_3_2
    .\build.ps1 -RepoUrl "https://gitlab.com/freepascal.org/fpc/source.git" -Branch release_3_2_4-branch
#>
[CmdletBinding()]
param(
    [Parameter()]
    [Alias('GitRef', 'Ref')]
    [string]$Branch = '',

    [Parameter()]
    [Alias('GitRepo', 'Url')]
    [string]$RepoUrl = '',

    [Parameter()]
    [string]$Commit = '',

    [Parameter()]
    [ValidateSet('auto', 'win64', 'linux', 'darwin')]
    [string]$TargetOs = 'auto',

    [Parameter()]
    [ValidateSet('auto', 'x86_64', 'aarch64')]
    [string]$TargetCpu = 'auto',

    [Parameter()]
    [string]$OutputDir = '',

    [Parameter()]
    [string]$WorkDir = '',

    [Parameter()]
    [switch]$SkipZip,

    [Parameter()]
    [switch]$VerifySourceOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ScriptRoot = $PSScriptRoot
$RepoRoot   = $ScriptRoot

if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path $RepoRoot 'dist'
}
if ([string]::IsNullOrWhiteSpace($WorkDir)) {
    $WorkDir = Join-Path $RepoRoot '.work'
}

function Write-Step([string]$Message) {
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Write-Info([string]$Message) {
    Write-Host "    $Message" -ForegroundColor Gray
}

function Write-Success([string]$Message) {
    Write-Host " [OK] $Message" -ForegroundColor Green
}

function Get-ShortStringHash([string]$Text) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        $hash  = $sha.ComputeHash($bytes)
        return ([System.BitConverter]::ToString($hash).Replace('-', '').ToLowerInvariant()).Substring(0, 8)
    } finally {
        $sha.Dispose()
    }
}

function Get-HostOs {
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        if ($IsWindows) { return 'win64' }
        if ($IsLinux)   { return 'linux' }
        if ($IsMacOS)   { return 'darwin' }
    }
    if ($env:OS -match 'Windows') { return 'win64' }
    throw "Unable to detect host operating system."
}

function Get-HostCpu {
    $arch = $env:PROCESSOR_ARCHITECTURE
    if (-not [string]::IsNullOrWhiteSpace($env:PROCESSOR_ARCHITEW6432)) {
        $arch = $env:PROCESSOR_ARCHITEW6432
    }
    if (-not [string]::IsNullOrWhiteSpace($arch)) {
        switch -Regex ($arch.ToUpperInvariant()) {
            'ARM64|AARCH64' { return 'aarch64' }
            'AMD64|X86_64'  { return 'x86_64' }
        }
    }
    if (Get-Command uname -ErrorAction SilentlyContinue) {
        $unameArch = (& uname -m).Trim().ToLowerInvariant()
        switch -Regex ($unameArch) {
            'aarch64|arm64' { return 'aarch64' }
            'x86_64|amd64'  { return 'x86_64' }
        }
    }
    return 'x86_64'
}

function Resolve-GitRepositoryInput {
    param(
        [string]$InputRepoUrl,
        [string]$InputBranch,
        [string]$DefaultRepoUrl,
        [string]$DefaultBranch,
        [PSCustomObject]$BranchesMap
    )

    $resolvedRepo   = $InputRepoUrl.Trim()
    $resolvedBranch = $InputBranch.Trim()

    # Normalize GitLab / GitHub web tree URLs (e.g. https://gitlab.com/freepascal.org/fpc/source/-/tree/fixes_3_2)
    if ($resolvedRepo -match '^(https?://[^/]+/.+?)/-/tree/([^?#]+?)/?$') {
        $baseRepo = $Matches[1]
        $treeRef  = $Matches[2]
        $resolvedRepo = if ($baseRepo.EndsWith('.git')) { $baseRepo } else { "$baseRepo.git" }
        if ([string]::IsNullOrWhiteSpace($resolvedBranch)) {
            $resolvedBranch = $treeRef
        }
    } elseif ($resolvedRepo -match '^(https?://github\.com/[^/]+/[^/]+?)/tree/([^?#]+?)/?$') {
        $baseRepo = $Matches[1]
        $treeRef  = $Matches[2]
        $resolvedRepo = if ($baseRepo.EndsWith('.git')) { $baseRepo } else { "$baseRepo.git" }
        if ([string]::IsNullOrWhiteSpace($resolvedBranch)) {
            $resolvedBranch = $treeRef
        }
    }

    if ([string]::IsNullOrWhiteSpace($resolvedBranch)) {
        $resolvedBranch = $DefaultBranch
    }

    $branchProp = if ($null -ne $BranchesMap) { $BranchesMap.PSObject.Properties[$resolvedBranch] } else { $null }
    $branchCfg  = if ($null -ne $branchProp) { $branchProp.Value } else { $null }

    if ([string]::IsNullOrWhiteSpace($resolvedRepo)) {
        if ($null -ne $branchCfg -and -not [string]::IsNullOrWhiteSpace($branchCfg.gitRepo)) {
            $resolvedRepo = $branchCfg.gitRepo.Trim()
        } else {
            $resolvedRepo = $DefaultRepoUrl
        }
    }

    return [PSCustomObject]@{
        RepoUrl      = $resolvedRepo
        Branch       = $resolvedBranch
        BranchConfig = $branchCfg
    }
}

function Assert-ValidGitRepository {
    param([string]$RepositoryUrl)

    if ([string]::IsNullOrWhiteSpace($RepositoryUrl)) {
        throw "Git repository URL must not be empty."
    }

    $isLocalDir  = Test-Path -LiteralPath $RepositoryUrl -PathType Container
    $isRemoteUrl = ($RepositoryUrl -match '^(https?|ssh|git)://[^\s]+$') -or
                   ($RepositoryUrl -match '^git@[^:\s]+:[^\s]+$')

    if (-not $isLocalDir -and -not $isRemoteUrl) {
        throw "Invalid Git repository URL or path: '$RepositoryUrl'. Expected a valid Git URL (e.g. https://gitlab.com/freepascal.org/fpc/source.git) or local Git repository."
    }

    $prevErr = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $probeOut = & git ls-remote $RepositoryUrl HEAD 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prevErr
    }

    if ($exitCode -ne 0) {
        $errDetail = ($probeOut | ForEach-Object { "$_" }) -join "`n"
        throw "URL '$RepositoryUrl' is not a valid or reachable Git repository.`n$errDetail"
    }
}

function Ensure-FpcSources {
    param(
        [string]$RefName,
        [string]$RepoUrl,
        [switch]$ReuseIfPresent
    )

    $safeRef = ($RefName -replace '[^A-Za-z0-9._-]', '_')
    if ($safeRef.Length -gt 28) {
        $safeRef = $safeRef.Substring(0, 28)
    }
    $repoHash    = Get-ShortStringHash ($RepoUrl.ToLowerInvariant())
    $cacheSrcDir = Join-Path $WorkDir "src-$safeRef-$repoHash"
    $gitDir      = Join-Path $cacheSrcDir '.git'

    if ($ReuseIfPresent -and (Test-Path (Join-Path $cacheSrcDir 'compiler\version.pas'))) {
        Write-Info "Using cached bootstrap FreePascal source ($RefName) in $cacheSrcDir"
        return $cacheSrcDir
    }

    Write-Step "Fetching FreePascal source ('$RefName') from $RepoUrl..."
    if (-not (Test-Path $gitDir)) {
        if (Test-Path $cacheSrcDir) {
            Remove-Item -Recurse -Force $cacheSrcDir
        }
        New-Item -ItemType Directory -Force -Path $cacheSrcDir | Out-Null
        & git -C $cacheSrcDir init -q | Out-Host
        & git -C $cacheSrcDir remote add origin $RepoUrl | Out-Host
    } else {
        & git -C $cacheSrcDir remote set-url origin $RepoUrl | Out-Host
    }

    $prevErr = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & git -C $cacheSrcDir fetch --depth 1 origin $RefName | Out-Host
        if ($LASTEXITCODE -ne 0) {
            throw "git fetch failed for ref '$RefName' from '$RepoUrl'."
        }
        & git -C $cacheSrcDir checkout -f -q FETCH_HEAD | Out-Host
        if ($LASTEXITCODE -ne 0) {
            throw "git checkout failed for ref '$RefName' from '$RepoUrl'."
        }
    } finally {
        $ErrorActionPreference = $prevErr
    }

    return $cacheSrcDir
}

function Get-FpcSourceMetadata {
    param(
        [string]$SourceRoot,
        [string]$RepoUrl,
        [string]$RefName
    )

    $versionPas  = Join-Path $SourceRoot 'compiler\version.pas'
    $makefileFpc = Join-Path $SourceRoot 'Makefile.fpc'
    $compilerDir = Join-Path $SourceRoot 'compiler'
    $rtlDir      = Join-Path $SourceRoot 'rtl'
    $packagesDir = Join-Path $SourceRoot 'packages'

    foreach ($required in @($versionPas, $makefileFpc, $compilerDir, $rtlDir, $packagesDir)) {
        if (-not (Test-Path $required)) {
            throw "Repository '$RepoUrl' (ref '$RefName') is not a valid FreePascal source tree (missing '$(Split-Path -Leaf $required)')."
        }
    }

    $versionContent = Get-Content -Path $versionPas -Raw
    $verMatch   = [regex]::Match($versionContent, "(?m)^\s*version_nr\s*=\s*'(\d+)'\s*;")
    $relMatch   = [regex]::Match($versionContent, "(?m)^\s*release_nr\s*=\s*'(\d+)'\s*;")
    $patchMatch = [regex]::Match($versionContent, "(?m)^\s*patch_nr\s*=\s*'(\d+)'\s*;")
    $minorMatch = [regex]::Match($versionContent, "(?m)^\s*minorpatch\s*=\s*'([A-Za-z0-9._-]*)'\s*;")

    if (-not ($verMatch.Success -and $relMatch.Success -and $patchMatch.Success)) {
        throw "Unable to parse FreePascal version constants (version_nr / release_nr / patch_nr) from '$versionPas'."
    }

    $versionNr  = $verMatch.Groups[1].Value
    $releaseNr  = $relMatch.Groups[1].Value
    $patchNr    = $patchMatch.Groups[1].Value
    $minorPatch = if ($minorMatch.Success) { $minorMatch.Groups[1].Value } else { '' }

    $coreVersion = "$versionNr.$releaseNr.$patchNr"
    $fullVersion = "$coreVersion$minorPatch"

    $iWinPas = Join-Path $SourceRoot 'compiler\systems\i_win.pas'
    $supportsWin64Arm64 = (Test-Path $iWinPas) -and
                          (Select-String -Path $iWinPas -Pattern 'system_aarch64_win64' -Quiet)

    $gitCommitFull = (& git -C $SourceRoot rev-parse HEAD 2>$null | Select-Object -First 1)
    if ([string]::IsNullOrWhiteSpace($gitCommitFull)) {
        throw "Failed to determine Git commit SHA in '$SourceRoot'."
    }
    $gitCommitFull  = $gitCommitFull.Trim().ToLowerInvariant()
    $gitCommitShort = if ($gitCommitFull.Length -ge 8) { $gitCommitFull.Substring(0, 8) } else { $gitCommitFull }

    $gitCommitDateRaw = (& git -C $SourceRoot show -s --format=%cI HEAD 2>$null | Select-Object -First 1)
    $gitCommitDateUtc = ''
    if (-not [string]::IsNullOrWhiteSpace($gitCommitDateRaw)) {
        try {
            $gitCommitDateUtc = [DateTimeOffset]::Parse($gitCommitDateRaw.Trim(), [System.Globalization.CultureInfo]::InvariantCulture).UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ')
        } catch {
            $gitCommitDateUtc = $gitCommitDateRaw.Trim()
        }
    }

    return [PSCustomObject]@{
        CoreVersion        = $coreVersion
        FullVersion        = $fullVersion
        GitCommitFull      = $gitCommitFull
        GitCommitShort     = $gitCommitShort
        GitCommitDate      = $gitCommitDateUtc
        SupportsWin64Arm64 = [bool]$supportsWin64Arm64
    }
}

function Copy-CleanFpcSources {
    param([string]$SourceRoot, [string]$TargetSourceRoot)

    Write-Step "Bundling clean FPC sources (rtl & packages)..."
    $allowedExts  = [System.Collections.Generic.HashSet[string]]::new([string[]]@('.pas', '.pp', '.inc', '.lpr', '.fpc'), [System.StringComparer]::OrdinalIgnoreCase)
    $excludedDirs = [System.Collections.Generic.HashSet[string]]::new([string[]]@('examples', 'tests', 'test', 'demo', 'doc', 'units', 'units_bs', '.git'), [System.StringComparer]::OrdinalIgnoreCase)

    foreach ($sub in @('rtl', 'packages')) {
        $srcSub = Join-Path $SourceRoot $sub
        $dstSub = Join-Path $TargetSourceRoot $sub
        if (-not (Test-Path $srcSub)) {
            throw "Required source folder '$srcSub' not found!"
        }
        Write-Info "Copying $sub sources..."
        New-Item -ItemType Directory -Force -Path $dstSub | Out-Null

        if ($HostOs -eq 'win64' -and (Get-Command robocopy -ErrorAction SilentlyContinue)) {
            & robocopy $srcSub $dstSub *.pas *.pp *.inc *.lpr *.fpc /S /NFL /NDL /NJH /NJS /NC /NS /NP /XD examples tests test demo doc units units_bs 2>&1 | Out-Null
            if ($LASTEXITCODE -ge 8) {
                throw "robocopy failed with exit code $LASTEXITCODE"
            }
        } else {
            $srcPrefixLen = $srcSub.TrimEnd('/', '\').Length + 1
            foreach ($file in [System.IO.Directory]::EnumerateFiles($srcSub, '*', [System.IO.SearchOption]::AllDirectories)) {
                $ext = [System.IO.Path]::GetExtension($file)
                if (-not $allowedExts.Contains($ext)) { continue }
                $relPath  = $file.Substring($srcPrefixLen)
                $segments = $relPath.Split([char[]]@('/', '\'))
                $skip     = $false
                for ($i = 0; $i -lt ($segments.Length - 1); $i++) {
                    if ($excludedDirs.Contains($segments[$i])) {
                        $skip = $true
                        break
                    }
                }
                if ($skip) { continue }
                $dstFile = Join-Path $dstSub $relPath
                $dstDir  = [System.IO.Path]::GetDirectoryName($dstFile)
                if (-not [System.IO.Directory]::Exists($dstDir)) {
                    [System.IO.Directory]::CreateDirectory($dstDir) | Out-Null
                }
                [System.IO.File]::Copy($file, $dstFile, $true)
            }
        }
    }
    Write-Success "RTL and Packages sources bundled."
}

function Invoke-BoundedCompilerProbe {
    param(
        [Parameter(Mandatory)][string]$BinaryPath,
        [Parameter(Mandatory)][string]$Arguments,
        [string]$PathPrepend = '',
        [int]$TimeoutSeconds = 15
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = $BinaryPath
    $psi.Arguments              = $Arguments
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true

    if (-not [string]::IsNullOrWhiteSpace($PathPrepend)) {
        $combinedPath = "$PathPrepend$([System.IO.Path]::PathSeparator)$env:PATH"
        if ($PSVersionTable.PSVersion.Major -ge 6) {
            $psi.Environment['PATH'] = $combinedPath
        } else {
            $psi.EnvironmentVariables['PATH'] = $combinedPath
        }
    }

    $proc = [System.Diagnostics.Process]::Start($psi)
    if ($null -eq $proc) {
        return [PSCustomObject]@{
            TimedOut = $false
            ExitCode = -1
            StdOut   = ''
            StdErr   = "Failed to start process '$BinaryPath'."
        }
    }

    try {
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $errTask = $proc.StandardError.ReadToEndAsync()

        if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
            try { $proc.Kill() } catch {}
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
            return [PSCustomObject]@{
                TimedOut = $true
                ExitCode = -1
                StdOut   = ''
                StdErr   = "Timed out after ${TimeoutSeconds}s"
            }
        }

        $proc.WaitForExit()
        return [PSCustomObject]@{
            TimedOut = $false
            ExitCode = $proc.ExitCode
            StdOut   = $outTask.GetAwaiter().GetResult().Trim()
            StdErr   = $errTask.GetAwaiter().GetResult().Trim()
        }
    } finally {
        $proc.Dispose()
    }
}

function Test-CompilerBinary {
    param(
        [Parameter(Mandatory)][string]$CompilerPath,
        [string]$PathPrepend = '',
        [string]$ExpectedSourceOs = '',
        [string]$ExpectedSourceCpu = '',
        [string]$ExpectedTargetOs = '',
        [string]$ExpectedTargetCpu = '',
        [int]$TimeoutSeconds = 15,
        [switch]$PassThruBool
    )

    $fail = {
        param([string]$Reason)
        if ($PassThruBool) {
            return $false
        }
        throw "Compiler fast-fail smoke check failed for '$CompilerPath': $Reason"
    }

    if (-not (Test-Path -LiteralPath $CompilerPath)) {
        return (& $fail "Binary does not exist.")
    }

    foreach ($flag in @('-iV', '-iSO', '-iSP', '-iVSPTPSOTO')) {
        $res = Invoke-BoundedCompilerProbe `
            -BinaryPath     $CompilerPath `
            -Arguments      $flag `
            -PathPrepend    $PathPrepend `
            -TimeoutSeconds $TimeoutSeconds

        if ($res.TimedOut) {
            return (& $fail "'$flag' timed out after ${TimeoutSeconds}s.")
        }
        if ($res.ExitCode -ne 0) {
            return (& $fail "'$flag' exited with code $($res.ExitCode) (stderr: $($res.StdErr)).")
        }
        if ([string]::IsNullOrWhiteSpace($res.StdOut)) {
            return (& $fail "'$flag' returned empty stdout.")
        }

        switch ($flag) {
            '-iV' {
                if ($res.StdOut -notmatch '^\d+\.\d+\.\d+') {
                    return (& $fail "Unexpected '-iV' output '$($res.StdOut)'.")
                }
            }
            '-iSO' {
                if ((-not [string]::IsNullOrWhiteSpace($ExpectedSourceOs)) -and ($res.StdOut -ne $ExpectedSourceOs)) {
                    return (& $fail "Expected '-iSO' = '$ExpectedSourceOs', got '$($res.StdOut)'.")
                }
            }
            '-iSP' {
                if ((-not [string]::IsNullOrWhiteSpace($ExpectedSourceCpu)) -and ($res.StdOut -ne $ExpectedSourceCpu)) {
                    return (& $fail "Expected '-iSP' = '$ExpectedSourceCpu', got '$($res.StdOut)'.")
                }
            }
            '-iVSPTPSOTO' {
                $parts = @($res.StdOut -split '\s+' | Where-Object { $_ -ne '' })
                if ($parts.Count -lt 5) {
                    return (& $fail "Expected 5 tokens from '-iVSPTPSOTO', got '$($res.StdOut)'.")
                }
                $ver    = $parts[0]
                $srcCpu = $parts[1]
                $tgtCpu = $parts[2]
                $srcOs  = $parts[3]
                $tgtOs  = $parts[4]
                if ((-not [string]::IsNullOrWhiteSpace($ExpectedTargetCpu)) -and ($tgtCpu -ne $ExpectedTargetCpu)) {
                    return (& $fail "Expected target CPU '$ExpectedTargetCpu', got '$tgtCpu' ('$($res.StdOut)').")
                }
                if ((-not [string]::IsNullOrWhiteSpace($ExpectedTargetOs)) -and ($tgtOs -ne $ExpectedTargetOs)) {
                    return (& $fail "Expected target OS '$ExpectedTargetOs', got '$tgtOs' ('$($res.StdOut)').")
                }
                if (-not $PassThruBool) {
                    Write-Success "Verified compiler binary ($ver, host=$srcCpu-$srcOs -> target=$tgtCpu-$tgtOs): $CompilerPath"
                }
            }
        }
    }

    if ($PassThruBool) {
        return $true
    }
}

function Ensure-BootstrapFpc {
    param([string]$TargetSourceRoot)

    $bootstrapWork = Join-Path $WorkDir "bootstrap-$TargetTriplet"
    $bootBin       = Join-Path $bootstrapWork "bin\$TargetTriplet"
    $bootPpc64     = Join-Path $bootBin "ppcx64$ExeExt"
    $bootPpcTarget = Join-Path $bootBin $PpcName

    if ($HostOs -eq 'win64') {
        $hasArm64Clang = ($TargetCpu -ne 'aarch64') -or (Test-Path (Join-Path $bootBin "clang.exe"))
        if ((Test-Path $bootPpcTarget) -and (Test-Path (Join-Path $bootBin "make.exe")) -and $hasArm64Clang) {
            if (Test-CompilerBinary -CompilerPath $bootPpcTarget -PathPrepend $bootBin -ExpectedSourceOs 'win64' -ExpectedSourceCpu $TargetCpu -ExpectedTargetOs 'win64' -ExpectedTargetCpu $TargetCpu -PassThruBool) {
                Write-Info "Using verified cached bootstrap compiler in: $bootBin"
                return @{
                    RootDir = $bootstrapWork
                    BinDir  = $bootBin
                    PpcPath = $bootPpcTarget
                }
            }
            Write-Info "Cached bootstrap compiler '$bootPpcTarget' failed fast-fail smoke check; rebuilding..."
            Remove-Item -LiteralPath $bootPpcTarget -Force -ErrorAction SilentlyContinue
        }

        Write-Step "Preparing isolated Win64 bootstrap compiler & binutils..."
        New-Item -ItemType Directory -Force -Path $bootBin | Out-Null

        $winBootCfg  = $VersionsConfig.bootstrapPackages.win64
        $binutilsUrl = if ($null -ne $BranchConfig -and -not [string]::IsNullOrWhiteSpace($BranchConfig.binariesRepoUrl)) {
            $BranchConfig.binariesRepoUrl
        } else {
            $winBootCfg.binutilsArchiveUrl
        }

        # 1. Download & extract binutils (binw64, binw32, crossbinw64) from GitLab fpc/build
        $binUrlHash  = Get-ShortStringHash ($binutilsUrl.ToLowerInvariant())
        $archivePath = Join-Path $WorkDir "fpc-binutils-$binUrlHash.tar.gz"
        if (-not (Test-Path $archivePath)) {
            Write-Info "Downloading FPC binutils archive ($binutilsUrl)..."
            & curl.exe -L --fail --retry 3 -o $archivePath $binutilsUrl | Out-Host
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to download FPC binutils archive from $binutilsUrl"
            }
        }
        $extractDir = Join-Path $WorkDir "fpc-binutils-extract-$binUrlHash"
        if (-not (Test-Path $extractDir)) {
            New-Item -ItemType Directory -Force -Path $extractDir | Out-Null
            Write-Info "Extracting Win64 binutils..."
            & tar.exe -xzf $archivePath -C $extractDir | Out-Host
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to extract $archivePath"
            }
        }
        $innerDir = Get-ChildItem -Path $extractDir -Directory | Select-Object -First 1
        $binW64   = Join-Path $innerDir.FullName "install\binw64"
        $binW32   = Join-Path $innerDir.FullName "install\binw32"
        $crossW64 = Join-Path $innerDir.FullName "install\crossbinw64"

        Copy-Item -Path (Join-Path $binW64 '*') -Destination $bootBin -Recurse -Force
        if (Test-Path $crossW64) {
            Copy-Item -Path (Join-Path $crossW64 '*') -Destination $bootBin -Recurse -Force
        }
        foreach ($f in (Get-ChildItem -Path $binW32 -Filter "*.exe")) {
            $dst = Join-Path $bootBin $f.Name
            if (-not (Test-Path $dst)) {
                Copy-Item -Path $f.FullName -Destination $dst -Force
            }
        }
        if (Test-Path (Join-Path $binW32 "windres.h")) {
            Copy-Item -Path (Join-Path $binW32 "windres.h") -Destination (Join-Path $bootBin "windres.h") -Force
        }

        # 2. Download official 1 MB ppc386 bootstrap zip and bootstrap native 64-bit ppcx64.exe
        $ppc386Zip = Join-Path $WorkDir "i386-win32-ppc386-3.2.2.zip"
        if (-not (Test-Path $ppc386Zip)) {
            Write-Info "Downloading bootstrap compiler ($($winBootCfg.bootstrapCompilerZipUrl))..."
            & curl.exe -L --fail --retry 3 -o $ppc386Zip $winBootCfg.bootstrapCompilerZipUrl | Out-Host
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to download bootstrap compiler zip."
            }
        }
        & tar.exe -xf $ppc386Zip -C $bootBin | Out-Host
        $ppc386Exe = Join-Path $bootBin "ppc386.exe"

        # Bootstrap native 64-bit ppcx64.exe from official 3.2.2 compiler source
        $bootSrcRepo = if (-not [string]::IsNullOrWhiteSpace($winBootCfg.bootstrapSourceRepo)) { $winBootCfg.bootstrapSourceRepo } else { $VersionsConfig.defaultRepository }
        $bootSrcRef  = if (-not [string]::IsNullOrWhiteSpace($winBootCfg.bootstrapSourceRef))  { $winBootCfg.bootstrapSourceRef }  else { 'release_3_2_2' }
        $bootVerSrc  = Ensure-FpcSources -RefName $bootSrcRef -RepoUrl $bootSrcRepo -ReuseIfPresent
        $cycledPpc64 = Join-Path $bootVerSrc "compiler\ppcx64.exe"

        if (-not (Test-Path $cycledPpc64)) {
            Write-Info "Bootstrapping native 64-bit ppcx64.exe via compiler cycle..."
            $oldPath = $env:PATH
            try {
                $env:PATH = "$bootBin;$env:SystemRoot\System32;$env:SystemRoot"
                Push-Location (Join-Path $bootVerSrc "compiler")
                try {
                    & (Join-Path $bootBin "make.exe") cycle PP="$ppc386Exe" OS_TARGET=win64 CPU_TARGET=x86_64 | Out-Host
                    if ($LASTEXITCODE -ne 0) {
                        throw "Bootstrap compiler cycle failed with exit code $LASTEXITCODE"
                    }
                } finally {
                    Pop-Location
                }
            } finally {
                $env:PATH = $oldPath
            }
        }

        Copy-Item -Path $cycledPpc64 -Destination $bootPpc64 -Force
        Test-CompilerBinary -CompilerPath $bootPpc64 -PathPrepend $bootBin -ExpectedSourceOs 'win64' -ExpectedSourceCpu 'x86_64' -ExpectedTargetOs 'win64' -ExpectedTargetCpu 'x86_64'
        Write-Success "Native x86_64 bootstrap compiler ready: $bootPpc64"

        # If targeting native Windows ARM64 (aarch64-win64), extract standalone LLVM assembler & bootstrap ppca64.exe
        if ($TargetCpu -eq 'aarch64') {
            $llvmZip = Join-Path $WorkDir "llvm-mingw-aarch64.zip"
            if (-not (Test-Path $llvmZip)) {
                Write-Info "Downloading standalone ARM64 LLVM assembler & binutils ($($winBootCfg.llvmMingwArm64ZipUrl))..."
                & curl.exe -L --fail --retry 3 -o $llvmZip $winBootCfg.llvmMingwArm64ZipUrl | Out-Host
                if ($LASTEXITCODE -ne 0) {
                    throw "Failed to download llvm-mingw ARM64 archive."
                }
            }
            Write-Info "Extracting ARM64 clang.exe, llvm-ar.exe, llvm-dlltool.exe, and llvm-windres.exe..."
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $zipArchive = [System.IO.Compression.ZipFile]::OpenRead($llvmZip)
            try {
                foreach ($entry in $zipArchive.Entries) {
                    if ($entry.FullName -match "^[^/]+/bin/(clang-\d+\.exe|llvm-ar\.exe|llvm-dlltool\.exe|llvm-objdump\.exe|llvm-strip\.exe|windres\.exe|libLLVM.*\.dll|libclang-cpp\.dll|libc\+\+\.dll|libunwind\.dll|libwinpthread-1\.dll)$") {
                        $fileName = [System.IO.Path]::GetFileName($entry.FullName)
                        [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, (Join-Path $bootBin $fileName), $true)
                    }
                }
            } finally {
                $zipArchive.Dispose()
            }
            $clangReal = Get-ChildItem -Path $bootBin -Filter "clang-*.exe" | Select-Object -First 1
            if ($null -eq $clangReal) {
                throw "clang-*.exe not found in $llvmZip"
            }
            Copy-Item -Path $clangReal.FullName -Destination (Join-Path $bootBin "clang.exe") -Force
            Copy-Item -Path (Join-Path $bootBin "llvm-ar.exe") -Destination (Join-Path $bootBin "ar.exe") -Force
            Copy-Item -Path (Join-Path $bootBin "llvm-strip.exe") -Destination (Join-Path $bootBin "strip.exe") -Force
            Copy-Item -Path (Join-Path $bootBin "llvm-objdump.exe") -Destination (Join-Path $bootBin "objdump.exe") -Force
            if (Test-Path (Join-Path $bootBin "llvm-dlltool.exe")) {
                Copy-Item -Path (Join-Path $bootBin "llvm-dlltool.exe") -Destination (Join-Path $bootBin "dlltool.exe") -Force
            }

            $cycledA64 = Join-Path $TargetSourceRoot "compiler\ppca64.exe"
            Write-Info "Bootstrapping native ARM64 ppca64.exe via cross-cycle..."
            & git -C $TargetSourceRoot checkout -- . | Out-Host
            & git -C $TargetSourceRoot clean -fdx | Out-Host
            $oldPath = $env:PATH
            try {
                $env:PATH = "$bootBin;$env:SystemRoot\System32;$env:SystemRoot"
                Push-Location (Join-Path $TargetSourceRoot "compiler")
                try {
                    $prevErr = $ErrorActionPreference
                    $ErrorActionPreference = 'Continue'
                    try {
                        & (Join-Path $bootBin "make.exe") cycle PP="$bootPpc64" OS_TARGET=win64 CPU_TARGET=aarch64 BINUTILSPREFIX= | Out-Host
                        if ($LASTEXITCODE -ne 0) {
                            throw "ARM64 bootstrap compiler cycle failed with exit code $LASTEXITCODE"
                        }
                    } finally {
                        $ErrorActionPreference = $prevErr
                    }
                } finally {
                    Pop-Location
                }
            } finally {
                $env:PATH = $oldPath
            }
            Copy-Item -Path $cycledA64 -Destination $bootPpcTarget -Force
            Test-CompilerBinary -CompilerPath $bootPpcTarget -PathPrepend $bootBin -ExpectedSourceOs 'win64' -ExpectedSourceCpu 'aarch64' -ExpectedTargetOs 'win64' -ExpectedTargetCpu 'aarch64'
            Write-Success "Native ARM64 bootstrap compiler ready: $bootPpcTarget"
        }

        return @{
            RootDir = $bootstrapWork
            BinDir  = $bootBin
            PpcPath = $bootPpcTarget
        }
    } else {
        $hostPpcName = $VersionsConfig.compilerBinaries.$HostCpu + $ExeExt
        $bootPpc     = Join-Path $bootBin $hostPpcName
        if (Test-Path $bootPpc) {
            if (Test-CompilerBinary -CompilerPath $bootPpc -PathPrepend $bootBin -ExpectedSourceOs $HostOs -ExpectedSourceCpu $HostCpu -PassThruBool) {
                return @{
                    RootDir = $bootstrapWork
                    BinDir  = $bootBin
                    PpcPath = $bootPpc
                }
            }
            Write-Info "Cached bootstrap compiler '$bootPpc' failed fast-fail smoke check; rebuilding..."
            Remove-Item -LiteralPath $bootPpc -Force -ErrorAction SilentlyContinue
        }

        $archSuffix = "$HostCpu-$HostOs"
        $tarUrl     = $VersionsConfig.bootstrapPackages.$archSuffix.tarUrl
        if ([string]::IsNullOrWhiteSpace($tarUrl)) {
            throw "No bootstrap tarUrl configured in versions.json for $archSuffix"
        }

        $tarPath = Join-Path $WorkDir "fpc-3.2.2.$archSuffix.tar"
        if (-not (Test-Path $tarPath)) {
            Write-Info "Downloading official FPC bootstrap archive ($tarUrl)..."
            & curl -L --fail --retry 3 -o $tarPath $tarUrl | Out-Host
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to download $tarUrl"
            }
        }

        $extractUnix = Join-Path $WorkDir "fpc-unix-extract-$archSuffix"
        if (Test-Path $extractUnix) {
            Remove-Item -Recurse -Force $extractUnix
        }
        $extractRoot = Join-Path $bootstrapWork "extracted"
        if (Test-Path $extractRoot) {
            Remove-Item -Recurse -Force $extractRoot
        }
        New-Item -ItemType Directory -Force -Path $extractUnix, $extractRoot, $bootBin | Out-Null

        & tar -xf $tarPath -C $extractUnix | Out-Host
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to extract $tarPath"
        }

        $innerTarDir = Get-ChildItem -Path $extractUnix -Directory | Select-Object -First 1
        $baseTar     = Get-ChildItem -Path $innerTarDir.FullName -Filter "binary.*.tar" | Select-Object -First 1
        if ($null -eq $baseTar) {
            throw "binary.*.tar not found inside $tarPath"
        }
        & tar -xf $baseTar.FullName -C $extractUnix | Out-Host
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to extract $($baseTar.FullName)"
        }

        foreach ($subGz in (Get-ChildItem -Path $extractUnix -Filter "*.tar.gz")) {
            & tar -xzf $subGz.FullName -C $extractRoot | Out-Host
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to extract $($subGz.FullName)"
            }
        }

        $extractedBin = Join-Path $extractRoot "bin"
        if (Test-Path $extractedBin) {
            foreach ($file in (Get-ChildItem -Path $extractedBin -File)) {
                Copy-Item -Path $file.FullName -Destination (Join-Path $bootBin $file.Name) -Force
            }
        }

        $libFpcPpc = Join-Path $extractRoot "lib/fpc/3.2.2/$hostPpcName"
        if (Test-Path $libFpcPpc) {
            Copy-Item -Path $libFpcPpc -Destination $bootPpc -Force
        }

        if (-not (Test-Path $bootPpc)) {
            throw "Bootstrap compiler binary $hostPpcName was not found in extracted archive ($libFpcPpc)."
        }

        if ($HostOs -eq 'darwin') {
            # Modern Xcode strip removed the legacy -no_uuid flag invoked by FPC's Makefile during cycle comparison
            $stripShim = Join-Path $bootBin 'strip'
            $shimCode  = "#!/bin/sh`nargs=`"`"`nfor a in `"`$@`"; do [ `"`$a`" != `"-no_uuid`" ] && args=`"`$args `$a`"; done`nexec /usr/bin/strip `$args`n"
            [System.IO.File]::WriteAllText($stripShim, $shimCode, [System.Text.Encoding]::ASCII)

            # Modern Xcode Clang assembler rejects non-private labels inside .cfi_startproc/.cfi_endproc in FPC 3.2.x's rtti.s
            $clangShim  = Join-Path $bootBin 'clang'
            $clangLines = @(
                '#!/bin/sh',
                'for a in "$@"; do',
                '  case "$a" in',
                '    *rtti.s) /usr/bin/perl -pi -e ''s/_\$RTTI\$_Lj/L\$RTTI\$_Lj/g; s/^\s*\.globl\s+L\$RTTI\$_Lj.*$//g'' "$a" ;;',
                '  esac',
                'done',
                'exec /usr/bin/clang "$@"'
            )
            [System.IO.File]::WriteAllText($clangShim, ($clangLines -join "`n") + "`n", [System.Text.Encoding]::ASCII)
        }

        & chmod -R +x $bootBin | Out-Host
        Test-CompilerBinary -CompilerPath $bootPpc -PathPrepend $bootBin -ExpectedSourceOs $HostOs -ExpectedSourceCpu $HostCpu
        Write-Success "Isolated bootstrap compiler ready: $bootPpc"

        return @{
            RootDir = $bootstrapWork
            BinDir  = $bootBin
            PpcPath = $bootPpc
        }
    }
}

# 1. Load versions.json & resolve Git repository + branch/ref
$VersionsFile = Join-Path $ScriptRoot 'versions.json'
if (-not (Test-Path $VersionsFile)) {
    throw "versions.json not found at: $VersionsFile"
}
$VersionsConfig = Get-Content $VersionsFile -Raw | ConvertFrom-Json

$ResolvedGit = Resolve-GitRepositoryInput `
    -InputRepoUrl   $RepoUrl `
    -InputBranch    $Branch `
    -DefaultRepoUrl $VersionsConfig.defaultRepository `
    -DefaultBranch  $VersionsConfig.defaultBranch `
    -BranchesMap    $VersionsConfig.branches

$EffectiveRepoUrl = $ResolvedGit.RepoUrl
$EffectiveBranch  = $ResolvedGit.Branch
$BranchConfig     = $ResolvedGit.BranchConfig
$FetchRef         = if (-not [string]::IsNullOrWhiteSpace($Commit)) { $Commit.Trim() } else { $EffectiveBranch }

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null

# 2. Validate Git repository, fetch sources, and inspect FreePascal compiler/version.pas
Write-Step "Validating Git repository..."
Assert-ValidGitRepository -RepositoryUrl $EffectiveRepoUrl
Write-Success "Verified reachable Git repository: $EffectiveRepoUrl"

$srcRoot = Ensure-FpcSources -RefName $FetchRef -RepoUrl $EffectiveRepoUrl
$FpcMeta = Get-FpcSourceMetadata -SourceRoot $srcRoot -RepoUrl $EffectiveRepoUrl -RefName $EffectiveBranch

$FpcVersion     = $FpcMeta.FullVersion
$FpcCoreVersion = $FpcMeta.CoreVersion
$gitCommitFull  = $FpcMeta.GitCommitFull
$gitCommitShort = $FpcMeta.GitCommitShort
$gitCommitDate  = $FpcMeta.GitCommitDate

$HostOs  = Get-HostOs
$HostCpu = Get-HostCpu

if ($TargetOs -eq 'auto')  { $TargetOs = $HostOs }
if ($TargetCpu -eq 'auto') { $TargetCpu = $HostCpu }

$TargetTriplet = "$TargetCpu-$TargetOs"
if ($TargetOs -eq 'win64' -and $TargetCpu -eq 'aarch64' -and (-not $FpcMeta.SupportsWin64Arm64)) {
    Write-Host " [!] Note: FPC $FpcVersion ($EffectiveBranch) does not support native aarch64-win64; targeting x86_64-win64." -ForegroundColor Yellow
    $TargetCpu     = 'x86_64'
    $TargetTriplet = 'x86_64-win64'
}

$ExeExt  = if ($TargetOs -eq 'win64') { '.exe' } else { '' }
$PpcName = $VersionsConfig.compilerBinaries.$TargetCpu + $ExeExt
$SdkId   = "nikrun-fpc-sdk-$FpcVersion-$gitCommitShort-$TargetTriplet"

Write-Step "Nikrun FPC SDK Builder"
Write-Info "Host System    : $HostCpu-$HostOs"
Write-Info "Target System  : $TargetTriplet"
Write-Info "Git Repository : $EffectiveRepoUrl"
Write-Info "Branch / Ref   : $EffectiveBranch"
Write-Info "Commit SHA     : $gitCommitFull ($gitCommitShort)"
if (-not [string]::IsNullOrWhiteSpace($gitCommitDate)) {
    Write-Info "Commit Date    : $gitCommitDate"
}
Write-Info "FPC Version    : $FpcVersion (from compiler/version.pas)"
Write-Info "SDK Identifier : $SdkId"

if ($VerifySourceOnly) {
    Write-Success "Source verification completed (-VerifySourceOnly)."
    return [PSCustomObject]@{
        SdkId              = $SdkId
        FpcVersion         = $FpcVersion
        GitRepo            = $EffectiveRepoUrl
        GitRef             = $EffectiveBranch
        GitCommit          = $gitCommitFull
        GitCommitShort     = $gitCommitShort
        GitCommitDate      = $gitCommitDate
        TargetOs           = $TargetOs
        TargetCpu          = $TargetCpu
        TargetTriplet      = $TargetTriplet
        SupportsWin64Arm64 = $FpcMeta.SupportsWin64Arm64
        SourceRoot         = $srcRoot
    }
}

$StageDir   = Join-Path $WorkDir "stage\$SdkId"
$StageBin   = Join-Path $StageDir "bin\$TargetTriplet"
$StageUnits = Join-Path $StageDir "units\$TargetTriplet"
$StageSrc   = Join-Path $StageDir "source"

if (Test-Path $StageDir) {
    Write-Info "Cleaning previous staging directory: $StageDir"
    Remove-Item -Recurse -Force $StageDir
}
New-Item -ItemType Directory -Force -Path $StageBin | Out-Null
New-Item -ItemType Directory -Force -Path $StageUnits | Out-Null
New-Item -ItemType Directory -Force -Path $StageSrc | Out-Null

# 3. Prepare isolated bootstrap compiler & compile FreePascal SDK from source
Write-Step "Building FPC $FpcVersion ($EffectiveBranch @ $gitCommitShort) from source..."
$base    = Ensure-BootstrapFpc -TargetSourceRoot $srcRoot
$bootPpc = $base.PpcPath

$makeExe = Join-Path $base.BinDir "make$ExeExt"
if (-not (Test-Path $makeExe)) {
    $makeCmd = Get-Command make -ErrorAction SilentlyContinue
    if ($null -eq $makeCmd) { throw "GNU make not found." }
    $makeExe = $makeCmd.Source
}

$extraMakeArgs = @(
    "RELEASE=1",
    "UPXPROG=echo",
    "FPMAKEOPT=--threads=4"
)
if (-not [string]::IsNullOrWhiteSpace($gitCommitShort)) {
    $extraMakeArgs += "REVSTR=$gitCommitShort"
    $extraMakeArgs += "REVINC=force"
}
if ($HostOs -eq 'darwin') {
    $extraMakeArgs += "DIFF=/usr/bin/true"
    $darwinOpts = @("-FD$($base.BinDir)")
    if (Get-Command xcrun -ErrorAction SilentlyContinue) {
        $macSdkPath = (& xcrun --show-sdk-path 2>$null | Select-Object -First 1).Trim()
        if (-not [string]::IsNullOrWhiteSpace($macSdkPath)) {
            Write-Info "Detected macOS SDK sysroot: $macSdkPath"
            $darwinOpts += "-XR$macSdkPath"
            if (Test-Path "$macSdkPath/usr/lib") {
                $darwinOpts += "-Fl$macSdkPath/usr/lib"
            }
        }
    }
    $extraMakeArgs += "OPT=$($darwinOpts -join ' ')"
} elseif ($HostOs -eq 'linux' -and $TargetCpu -eq 'aarch64') {
    $extraMakeArgs += "OPT=-k--defsym=__libc_csu_init=0 -k--defsym=__libc_csu_fini=0"
} elseif ($HostOs -eq 'win64' -and $TargetCpu -eq 'aarch64') {
    $extraMakeArgs += "OVERRIDEVERSIONCHECK=1"
    $extraMakeArgs += "BINUTILSPREFIX="
}

Write-Info "Cleaning source tree before full build..."
Get-Process -Name 'fpmake' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
& git -C $srcRoot checkout -- . | Out-Host
& git -C $srcRoot clean -fdx | Out-Host

$oldPath = $env:PATH
try {
    if ($HostOs -eq 'win64') {
        $env:PATH = "$($base.BinDir);$env:SystemRoot\System32;$env:SystemRoot"
    } else {
        $env:PATH = "$($base.BinDir):/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin"
    }
    Write-Info "Isolated PATH: $env:PATH"

    Push-Location $srcRoot
    try {
        $prevErrorAction = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            Write-Info "Running 'make all' (compiling compiler, RTL, packages & utils)..."
            & $makeExe all PP="$bootPpc" OS_TARGET="$TargetOs" CPU_TARGET="$TargetCpu" @extraMakeArgs | Out-Host
            if ($LASTEXITCODE -ne 0) {
                throw "FPC 'make all' failed with exit code $LASTEXITCODE"
            }

            Write-Info "Running 'make install' into staging directory..."
            & $makeExe install PP="$bootPpc" OS_TARGET="$TargetOs" CPU_TARGET="$TargetCpu" INSTALL_PREFIX="$StageDir" @extraMakeArgs | Out-Host
            if ($LASTEXITCODE -ne 0) {
                throw "FPC 'make install' failed with exit code $LASTEXITCODE"
            }
        } finally {
            $ErrorActionPreference = $prevErrorAction
        }
    } finally {
        Pop-Location
    }
} finally {
    $env:PATH = $oldPath
}

# Normalize directory layout on Linux/macOS if make install placed units under lib/fpc/<ver>/units
$libFpcRoot = Join-Path $StageDir "lib/fpc"
$libFpcDir  = Join-Path $libFpcRoot $FpcVersion
if (-not (Test-Path $libFpcDir)) {
    $libFpcDir = Join-Path $libFpcRoot $FpcCoreVersion
}
if ((-not (Test-Path $libFpcDir)) -and (Test-Path $libFpcRoot)) {
    $firstLibSub = Get-ChildItem -Path $libFpcRoot -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $firstLibSub) {
        $libFpcDir = $firstLibSub.FullName
    }
}
if (Test-Path $libFpcDir) {
    $libUnits = Join-Path $libFpcDir "units/$TargetTriplet"
    if (Test-Path $libUnits) {
        Copy-Item -Path (Join-Path $libUnits '*') -Destination $StageUnits -Recurse -Force
    }
    $libPpc = Join-Path $libFpcDir $PpcName
    if (Test-Path $libPpc) {
        Copy-Item -Path $libPpc -Destination (Join-Path $StageBin $PpcName) -Force
    }
    $libMsg   = Join-Path $libFpcDir "msg"
    $stageMsg = Join-Path $StageDir "msg"
    if ((Test-Path $libMsg) -and -not (Test-Path $stageMsg)) {
        Copy-Item -Path $libMsg -Destination $stageMsg -Recurse -Force
    }
    $plainBin = Join-Path $StageDir "bin"
    foreach ($f in (Get-ChildItem -Path $plainBin -File -ErrorAction SilentlyContinue)) {
        Move-Item -Path $f.FullName -Destination (Join-Path $StageBin $f.Name) -Force
    }
    Remove-Item -Recurse -Force (Join-Path $StageDir "lib") -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force (Join-Path $StageDir "share") -ErrorAction SilentlyContinue
}

# Copy plex/pyacc code templates (yylex.cod, yyparse.cod) into StageBin across all platforms
foreach ($codFile in @('yylex.cod', 'yyparse.cod')) {
    $srcCod = Join-Path $srcRoot "utils\tply\$codFile"
    $dstCod = Join-Path $StageBin $codFile
    if ((Test-Path $srcCod) -and -not (Test-Path $dstCod)) {
        Copy-Item -Path $srcCod -Destination $dstCod -Force
    }
}

# Copy essential binutils into StageBin on Windows
if ($HostOs -eq 'win64') {
    $winTools = if ($TargetCpu -eq 'aarch64') {
        @('ar.exe', 'dlltool.exe', 'make.exe', 'windres.exe', 'windres.h', 'objdump.exe', 'strip.exe', 'clang.exe')
    } else {
        @('ar.exe', 'as.exe', 'ld.exe', 'dlltool.exe', 'make.exe', 'windres.exe', 'windres.h', 'cpp.exe', 'objdump.exe', 'strip.exe', 'clang.exe')
    }
    foreach ($tool in $winTools) {
        $srcTool = Join-Path $base.BinDir $tool
        $dstTool = Join-Path $StageBin $tool
        if ((Test-Path $srcTool) -and -not (Test-Path $dstTool)) {
            Copy-Item -Path $srcTool -Destination $dstTool -Force
        }
    }
    foreach ($dll in (Get-ChildItem -Path $base.BinDir -Filter '*.dll' -ErrorAction SilentlyContinue)) {
        Copy-Item -Path $dll.FullName -Destination (Join-Path $StageBin $dll.Name) -Force
    }
}

Copy-CleanFpcSources -SourceRoot $srcRoot -TargetSourceRoot $StageSrc

# 4. Verify staged compiler binary and units
$StagedFpc = Join-Path $StageBin "fpc$ExeExt"
$StagedPpc = Join-Path $StageBin $PpcName
if (-not (Test-Path $StagedFpc)) {
    throw "Staging verification failed: $StagedFpc is missing!"
}
if (-not (Test-Path $StagedPpc)) {
    throw "Staging verification failed: $StagedPpc is missing!"
}
if ($TargetOs -eq $HostOs -and $TargetCpu -eq $HostCpu) {
    Test-CompilerBinary `
        -CompilerPath      $StagedPpc `
        -PathPrepend       $StageBin `
        -ExpectedSourceOs  $TargetOs `
        -ExpectedSourceCpu $TargetCpu `
        -ExpectedTargetOs  $TargetOs `
        -ExpectedTargetCpu $TargetCpu
}

# 5. Write sdk-manifest.json (including full & short commit SHA + branch/repo metadata)
$Manifest = [ordered]@{
    schemaVersion      = 1
    sdkId              = $SdkId
    fpcVersion         = $FpcVersion
    gitRepo            = $EffectiveRepoUrl
    gitRef             = $EffectiveBranch
    gitCommit          = $gitCommitFull
    gitCommitShort     = $gitCommitShort
    gitCommitDate      = $gitCommitDate
    targetOs           = $TargetOs
    targetCpu          = $TargetCpu
    targetTriplet      = $TargetTriplet
    builtAtUtc         = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    paths              = [ordered]@{
        binDir             = "bin/$TargetTriplet"
        fpcBinary          = "bin/$TargetTriplet/fpc$ExeExt"
        ppcBinary          = "bin/$TargetTriplet/$PpcName"
        fpcmkcfgBinary     = "bin/$TargetTriplet/fpcmkcfg$ExeExt"
        unitsDir           = "units/$TargetTriplet"
        rtlSourceDir       = "source/rtl"
        packagesSourceDir  = "source/packages"
    }
}
$ManifestPath = Join-Path $StageDir 'sdk-manifest.json'
$Manifest | ConvertTo-Json -Depth 5 | Set-Content -Path $ManifestPath -Encoding UTF8
Write-Success "Created SDK manifest: $ManifestPath"

# 6. Create portable ZIP archive + SHA256 checksum
$ZipFilePath = Join-Path $OutputDir "$SdkId.zip"
if (-not $SkipZip) {
    Write-Step "Creating portable FPC SDK archive: $ZipFilePath"
    if (Test-Path $ZipFilePath) {
        Remove-Item -Force $ZipFilePath
    }

    if ($HostOs -ne 'win64' -and (Get-Command chmod -ErrorAction SilentlyContinue)) {
        & chmod -R +x $StageBin | Out-Host
    }

    if ($HostOs -eq 'win64' -and (Get-Command tar.exe -ErrorAction SilentlyContinue)) {
        Push-Location $StageDir
        try {
            & tar.exe -a -cf $ZipFilePath * | Out-Host
            if ($LASTEXITCODE -ne 0) {
                throw "tar.exe failed to create zip archive"
            }
        } finally {
            Pop-Location
        }
    } elseif ($HostOs -ne 'win64' -and (Get-Command zip -ErrorAction SilentlyContinue)) {
        Push-Location $StageDir
        try {
            & zip -rq $ZipFilePath . | Out-Host
            if ($LASTEXITCODE -ne 0) {
                throw "zip failed to create archive"
            }
        } finally {
            Pop-Location
        }
    } else {
        Compress-Archive -Path (Join-Path $StageDir '*') -DestinationPath $ZipFilePath -Force
    }

    $Hash = (Get-FileHash -Path $ZipFilePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $ShaFilePath = "$ZipFilePath.sha256"
    "$Hash  $SdkId.zip" | Set-Content -Path $ShaFilePath -Encoding ASCII

    $ZipSizeMb = [math]::Round((Get-Item $ZipFilePath).Length / 1MB, 2)
    Write-Success "Archive created: $ZipFilePath ($ZipSizeMb MB)"
    Write-Success "SHA256         : $Hash"
}

Write-Host "`nFPC SDK build completed successfully!" -ForegroundColor Green
return [PSCustomObject]@{
    SdkId       = $SdkId
    StageDir    = $StageDir
    ZipFilePath = if (-not $SkipZip) { $ZipFilePath } else { $null }
    Manifest    = $Manifest
}
