<#
.SYNOPSIS
    Generates index.json and release-notes.md and publishes FreePascal SDK archives to GitHub Releases.

.DESCRIPTION
    Merges newly built nikrun-fpc-sdk-*.zip archives (reading sdk-manifest.json directly from each ZIP)
    with an existing index.json from GitHub Releases (or -ExistingIndexPath), writes the updated
    index.json and Markdown release notes (via format-release-notes.ps1), uploads assets via 'gh',
    and removes superseded snapshot assets. Use -DryRun to test index and release-notes generation locally
    without modifying GitHub Releases.

.EXAMPLE
    .\publish-release.ps1 -InputDir .\dist -Repository nikrun/sdk -DryRun
    .\publish-release.ps1 -InputDir .\release-input -Repository nikrun/sdk
    .\publish-release.ps1 -Repository nikrun/sdk -RefreshNotesOnly
#>
[CmdletBinding()]
param(
    [Parameter()]
    [string]$InputDir = '',

    [Parameter()]
    [string]$Repository = '',

    [Parameter()]
    [string]$ReleaseTag = 'latest',

    [Parameter()]
    [string]$ExistingIndexPath = '',

    [Parameter()]
    [string]$VersionsPath = '',

    [Parameter()]
    [string]$IndexOutputPath = '',

    [Parameter()]
    [string]$NotesOutputPath = '',

    [Parameter()]
    [switch]$RefreshNotesOnly,

    [Parameter()]
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$ScriptRoot = $PSScriptRoot
$RepoRoot   = $ScriptRoot

if ([string]::IsNullOrWhiteSpace($InputDir)) {
    $InputDir = Join-Path $RepoRoot 'dist'
}
if ([string]::IsNullOrWhiteSpace($VersionsPath)) {
    $VersionsPath = Join-Path $ScriptRoot 'versions.json'
}
if ([string]::IsNullOrWhiteSpace($Repository) -and -not [string]::IsNullOrWhiteSpace($env:GITHUB_REPOSITORY)) {
    $Repository = $env:GITHUB_REPOSITORY
}
if ([string]::IsNullOrWhiteSpace($IndexOutputPath)) {
    $IndexOutputPath = Join-Path $InputDir 'index.json'
}
if ([string]::IsNullOrWhiteSpace($NotesOutputPath)) {
    $NotesOutputPath = Join-Path $PWD 'release-notes.md'
}

if ((-not $DryRun.IsPresent) -and [string]::IsNullOrWhiteSpace($Repository)) {
    throw "Parameter -Repository (or GITHUB_REPOSITORY) is required when publishing to GitHub Releases."
}

function Get-PropValue {
    param(
        [Parameter()]
        [object]$InputObject,
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter()]
        [object]$Default = $null
    )
    if ($null -eq $InputObject) { return $Default }
    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Name) -and $null -ne $InputObject[$Name]) {
            return $InputObject[$Name]
        }
        return $Default
    }
    $prop = $InputObject.PSObject.Properties[$Name]
    if ($null -ne $prop -and $null -ne $prop.Value) {
        return $prop.Value
    }
    return $Default
}

function Read-ZipManifestJson {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ZipPath
    )
    $archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $entry = $archive.GetEntry('sdk-manifest.json')
        if ($null -eq $entry) {
            throw "sdk-manifest.json missing inside $([System.IO.Path]::GetFileName($ZipPath))"
        }
        $stream = $entry.Open()
        try {
            $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::UTF8)
            try {
                $rawJson = $reader.ReadToEnd()
                return ($rawJson | ConvertFrom-Json)
            } finally {
                $reader.Dispose()
            }
        } finally {
            $stream.Dispose()
        }
    } finally {
        $archive.Dispose()
    }
}

if (-not $RefreshNotesOnly.IsPresent) {
    New-Item -ItemType Directory -Force -Path $InputDir | Out-Null
}

$zips = @(
    if (Test-Path $InputDir) {
        Get-ChildItem -Path $InputDir -Filter 'nikrun-fpc-sdk-*.zip' -ErrorAction SilentlyContinue
    }
)

if ((-not $RefreshNotesOnly.IsPresent) -and ($zips.Count -eq 0)) {
    throw "No FPC SDK zip artifacts were found in '$InputDir' to publish."
}

$repoDisplay = if (-not [string]::IsNullOrWhiteSpace($Repository)) { $Repository } else { 'local' }
if ($RefreshNotesOnly.IsPresent) {
    Write-Host "==> Refreshing release notes for '$ReleaseTag' ($repoDisplay) from existing index.json..." -ForegroundColor Cyan
} else {
    Write-Host "==> Preparing release '$ReleaseTag' ($repoDisplay) with $($zips.Count) SDK archive(s)..." -ForegroundColor Cyan
}

# Load existing index.json from local file or GitHub Release so partial branch/target runs merge cleanly
$sdkMap              = [ordered]@{}
$tempDownloadedIndex = $null
$indexSourcePath     = $ExistingIndexPath

if ([string]::IsNullOrWhiteSpace($indexSourcePath) -and -not [string]::IsNullOrWhiteSpace($Repository)) {
    if (Get-Command gh -ErrorAction SilentlyContinue) {
        $tempDownloadedIndex = Join-Path ([System.IO.Path]::GetTempPath()) ("nikrun-release-index-{0}.json" -f [guid]::NewGuid().ToString('N'))
        $prevErr = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        & gh release download $ReleaseTag --repo $Repository --pattern 'index.json' --output $tempDownloadedIndex --clobber 2>$null
        $dlExit = $LASTEXITCODE
        $ErrorActionPreference = $prevErr
        if ($dlExit -eq 0 -and (Test-Path $tempDownloadedIndex)) {
            $indexSourcePath = $tempDownloadedIndex
        }
    }
}

try {
    if (-not [string]::IsNullOrWhiteSpace($indexSourcePath) -and (Test-Path $indexSourcePath)) {
        try {
            $existingIdx = Get-Content -Path $indexSourcePath -Raw | ConvertFrom-Json
            foreach ($entry in @(Get-PropValue $existingIdx 'sdks' @())) {
                $gitRepoVal        = [string](Get-PropValue $entry 'gitRepo' '')
                $gitCommitVal      = [string](Get-PropValue $entry 'gitCommit' '')
                $gitCommitShortVal = [string](Get-PropValue $entry 'gitCommitShort' '')
                if ([string]::IsNullOrWhiteSpace($gitCommitShortVal) -and $gitCommitVal.Length -ge 8) {
                    $gitCommitShortVal = $gitCommitVal.Substring(0, 8)
                }
                $gitCommitDateVal  = [string](Get-PropValue $entry 'gitCommitDate' '')
                $entrySdkId        = [string](Get-PropValue $entry 'sdkId' '')

                $sdkMap[$entrySdkId] = [ordered]@{
                    sdkId          = $entrySdkId
                    fpcVersion     = [string](Get-PropValue $entry 'fpcVersion' '')
                    gitRepo        = $gitRepoVal
                    gitRef         = [string](Get-PropValue $entry 'gitRef' '')
                    gitCommit      = $gitCommitVal
                    gitCommitShort = $gitCommitShortVal
                    gitCommitDate  = $gitCommitDateVal
                    targetOs       = [string](Get-PropValue $entry 'targetOs' '')
                    targetCpu      = [string](Get-PropValue $entry 'targetCpu' '')
                    targetTriplet  = [string](Get-PropValue $entry 'targetTriplet' '')
                    builtAtUtc     = [string](Get-PropValue $entry 'builtAtUtc' '')
                    fileName       = [string](Get-PropValue $entry 'fileName' '')
                    sizeBytes      = [int64](Get-PropValue $entry 'sizeBytes' 0)
                    sha256         = [string](Get-PropValue $entry 'sha256' '')
                    downloadUrl    = [string](Get-PropValue $entry 'downloadUrl' '')
                }
            }
            Write-Host "    Loaded $($sdkMap.Count) existing SDK entry/entries from '$ReleaseTag'." -ForegroundColor Gray
        } catch {
            if ($RefreshNotesOnly.IsPresent) {
                throw "Failed to parse existing index.json: $_"
            }
            Write-Warning "Could not parse existing index.json, creating fresh index."
        }
    }
} finally {
    if ($null -ne $tempDownloadedIndex -and (Test-Path $tempDownloadedIndex)) {
        Remove-Item -Force $tempDownloadedIndex -ErrorAction SilentlyContinue
    }
}

if ($RefreshNotesOnly.IsPresent -and ($sdkMap.Count -eq 0)) {
    throw "Cannot refresh release notes: no existing index.json entries found for release '$ReleaseTag'."
}

$supersededAssets = [System.Collections.Generic.List[string]]::new()

if (-not $RefreshNotesOnly.IsPresent) {
    foreach ($zip in $zips) {
        $shaFile = "$($zip.FullName).sha256"
        $sha256  = if (Test-Path $shaFile) {
            ((Get-Content -Path $shaFile -Raw).Trim() -split '\s+')[0].ToLowerInvariant()
        } else {
            (Get-FileHash -Path $zip.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        }

        $manifest           = Read-ZipManifestJson -ZipPath $zip.FullName
        $manifestSdkId      = [string](Get-PropValue $manifest 'sdkId' '')
        $manifestFpcVer     = [string](Get-PropValue $manifest 'fpcVersion' '')
        $manifestGitRepo    = [string](Get-PropValue $manifest 'gitRepo' '')
        $manifestGitRef     = [string](Get-PropValue $manifest 'gitRef' '')
        $manifestGitCommit  = [string](Get-PropValue $manifest 'gitCommit' '')
        $manifestShortSha   = [string](Get-PropValue $manifest 'gitCommitShort' '')
        if ([string]::IsNullOrWhiteSpace($manifestShortSha) -and $manifestGitCommit.Length -ge 8) {
            $manifestShortSha = $manifestGitCommit.Substring(0, 8)
        }
        $manifestCommitDate = [string](Get-PropValue $manifest 'gitCommitDate' '')
        $manifestTargetOs   = [string](Get-PropValue $manifest 'targetOs' '')
        $manifestTargetCpu  = [string](Get-PropValue $manifest 'targetCpu' '')
        $manifestTriplet    = [string](Get-PropValue $manifest 'targetTriplet' '')
        $manifestBuiltAt    = [string](Get-PropValue $manifest 'builtAtUtc' '')

        # Supersede previous snapshot for the same (gitRef, fpcVersion, targetTriplet)
        foreach ($oldKey in @($sdkMap.Keys)) {
            $old = $sdkMap[$oldKey]
            $sameBranchVersionTarget = ($old.gitRef -eq $manifestGitRef) -and
                                       ($old.fpcVersion -eq $manifestFpcVer) -and
                                       ($old.targetTriplet -eq $manifestTriplet)

            if ($sameBranchVersionTarget) {
                if ($old.fileName -ne $zip.Name) {
                    $supersededAssets.Add($old.fileName)
                    $supersededAssets.Add("$($old.fileName).sha256")
                }
                $sdkMap.Remove($oldKey)
            }
        }

        $downloadUrl = if (-not [string]::IsNullOrWhiteSpace($Repository)) {
            "https://github.com/$Repository/releases/download/$ReleaseTag/$($zip.Name)"
        } else {
            $zip.Name
        }

        $sdkMap[$manifestSdkId] = [ordered]@{
            sdkId          = $manifestSdkId
            fpcVersion     = $manifestFpcVer
            gitRepo        = $manifestGitRepo
            gitRef         = $manifestGitRef
            gitCommit      = $manifestGitCommit
            gitCommitShort = $manifestShortSha
            gitCommitDate  = $manifestCommitDate
            targetOs       = $manifestTargetOs
            targetCpu      = $manifestTargetCpu
            targetTriplet  = $manifestTriplet
            builtAtUtc     = $manifestBuiltAt
            fileName       = $zip.Name
            sizeBytes      = [int64]$zip.Length
            sha256         = $sha256
            downloadUrl    = $downloadUrl
        }
        Write-Host " [+] Indexed $manifestSdkId (branch: $manifestGitRef, commit: $manifestShortSha, $([math]::Round($zip.Length / 1MB, 2)) MB)" -ForegroundColor Green
    }
}

$needsAssetPublish = (-not $RefreshNotesOnly.IsPresent)
$sortedSdks = @($sdkMap.Values | Sort-Object { $_.fpcVersion }, { $_.targetOs }, { $_.targetCpu }, { $_.sdkId })

if ($needsAssetPublish) {
    $indexObj = [ordered]@{
        schemaVersion = 1
        releaseTag    = $ReleaseTag
        updatedAtUtc  = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        sdks          = $sortedSdks
    }

    $indexParent = Split-Path -Parent $IndexOutputPath
    if (-not [string]::IsNullOrWhiteSpace($indexParent) -and -not (Test-Path $indexParent)) {
        New-Item -ItemType Directory -Force -Path $indexParent | Out-Null
    }
    $indexJson = ($indexObj | ConvertTo-Json -Depth 6) + "`n"
    [System.IO.File]::WriteAllText($IndexOutputPath, $indexJson, [System.Text.UTF8Encoding]::new($false))
    Write-Host "    Wrote index.json ($($sortedSdks.Count) SDK entries) -> $IndexOutputPath" -ForegroundColor Gray
}

$formatNotesScript = Join-Path $ScriptRoot 'format-release-notes.ps1'
& $formatNotesScript `
    -Sdks $sortedSdks `
    -Repository $Repository `
    -ReleaseTag $ReleaseTag `
    -VersionsPath $VersionsPath `
    -OutputPath $NotesOutputPath | Out-Null

Write-Host "    Wrote release notes -> $NotesOutputPath" -ForegroundColor Gray

if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_STEP_SUMMARY)) {
    $notesContent = Get-Content -Path $NotesOutputPath -Raw
    [System.IO.File]::AppendAllText($env:GITHUB_STEP_SUMMARY, $notesContent, [System.Text.UTF8Encoding]::new($false))
}

if ($DryRun.IsPresent) {
    if ($supersededAssets.Count -gt 0) {
        Write-Host "    [DryRun] Would remove $($supersededAssets.Count) superseded asset(s): $(($supersededAssets | Select-Object -Unique) -join ', ')" -ForegroundColor DarkGray
    }
    Write-Host " [OK] Dry run completed without modifying GitHub Releases." -ForegroundColor Green
    return
}

# Create release if it doesn't exist, otherwise update notes (and upload assets when not refresh-only)
$prevErr = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
& gh release view $ReleaseTag --repo $Repository >$null 2>&1
$viewExit = $LASTEXITCODE
$ErrorActionPreference = $prevErr

if ($viewExit -ne 0) {
    if ($RefreshNotesOnly.IsPresent) {
        throw "Release '$ReleaseTag' does not exist on $Repository."
    }
    Write-Host "==> Creating new GitHub Release '$ReleaseTag'..." -ForegroundColor Cyan
    & gh release create $ReleaseTag --repo $Repository --title "FreePascal SDKs" --notes-file $NotesOutputPath
    if ($LASTEXITCODE -ne 0) { throw "gh release create failed" }
} else {
    Write-Host "==> Updating existing GitHub Release '$ReleaseTag'..." -ForegroundColor Cyan
    & gh release edit $ReleaseTag --repo $Repository --title "FreePascal SDKs" --notes-file $NotesOutputPath
    if ($LASTEXITCODE -ne 0) { throw "gh release edit failed" }
}

if ($needsAssetPublish) {
    $assetsToUpload = @()
    $assetsToUpload += @(Get-ChildItem -Path $InputDir -Filter 'nikrun-fpc-sdk-*.zip' -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    $assetsToUpload += @(Get-ChildItem -Path $InputDir -Filter 'nikrun-fpc-sdk-*.zip.sha256' -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    $assetsToUpload += $IndexOutputPath

    Write-Host "==> Uploading $($assetsToUpload.Count) asset(s) to GitHub Release '$ReleaseTag'..." -ForegroundColor Cyan
    & gh release upload $ReleaseTag @assetsToUpload --repo $Repository --clobber
    if ($LASTEXITCODE -ne 0) { throw "gh release upload failed" }

    # Clean up superseded old snapshot assets after new assets & index.json are live
    foreach ($staleAsset in ($supersededAssets | Select-Object -Unique)) {
        Write-Host "    Removing superseded release asset: $staleAsset" -ForegroundColor DarkGray
        $prevErr = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        & gh release delete-asset $ReleaseTag $staleAsset --repo $Repository --yes >$null 2>&1
        $ErrorActionPreference = $prevErr
    }

    Write-Host " [OK] Published GitHub Release '$ReleaseTag' and index.json!" -ForegroundColor Green
} else {
    Write-Host " [OK] Refreshed release notes for '$ReleaseTag'!" -ForegroundColor Green
}
