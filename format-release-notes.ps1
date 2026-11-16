<#
.SYNOPSIS
    Renders the compact Markdown release notes matrix table from index.json or SDK entries.

.DESCRIPTION
    Groups published FreePascal SDK entries by (fpcVersion, gitRef), orders versions newest-first,
    formats repository branch and commit links, and generates the Markdown table used on GitHub
    Releases and GITHUB_STEP_SUMMARY.

.EXAMPLE
    .\format-release-notes.ps1 -IndexPath .\index.json
    .\format-release-notes.ps1 -IndexPath .\index.json -OutputPath .\release-notes.md
#>
[CmdletBinding()]
param(
    [Parameter()]
    [string]$IndexPath = '',

    [Parameter()]
    [AllowEmptyCollection()]
    [object[]]$Sdks = @(),

    [Parameter()]
    [string]$Repository = '',

    [Parameter()]
    [string]$ReleaseTag = '',

    [Parameter()]
    [string]$VersionsPath = '',

    [Parameter()]
    [string]$OutputPath = '',

    [Parameter()]
    [switch]$PassThru
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ScriptRoot = $PSScriptRoot

if ([string]::IsNullOrWhiteSpace($VersionsPath)) {
    $VersionsPath = Join-Path $ScriptRoot 'versions.json'
}
if ([string]::IsNullOrWhiteSpace($Repository) -and -not [string]::IsNullOrWhiteSpace($env:GITHUB_REPOSITORY)) {
    $Repository = $env:GITHUB_REPOSITORY
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

function Get-FpcVersionSortKey {
    param([string]$Version)
    if ($Version -match '^(\d+)\.(\d+)\.(\d+)(.*)$') {
        $maj     = [int]$Matches[1]
        $min     = [int]$Matches[2]
        $pat     = [int]$Matches[3]
        $suf     = $Matches[4].Trim()
        $isFinal = if ([string]::IsNullOrWhiteSpace($suf)) { 1 } else { 0 }
        return ('{0:D6}.{1:D6}.{2:D6}.{3}.{4}' -f $maj, $min, $pat, $isFinal, $suf)
    }
    return "000000.000000.000000.0.$Version"
}

function Format-RepoWebLink {
    param(
        [string]$RepoUrl,
        [string]$Kind,
        [string]$Target
    )
    if ([string]::IsNullOrWhiteSpace($RepoUrl) -or [string]::IsNullOrWhiteSpace($Target)) {
        return $null
    }
    $base = ($RepoUrl.Trim() -replace '\.git$', '').TrimEnd('/')
    if ($base -notmatch '^https?://') {
        return $null
    }
    if ($base -match '^https?://github\.com/') {
        return "$base/$Kind/$Target"
    }
    return "$base/-/$Kind/$Target"
}

$sdkEntries = @($Sdks)
$effectiveReleaseTag = $ReleaseTag

if (-not [string]::IsNullOrWhiteSpace($IndexPath)) {
    if (-not (Test-Path $IndexPath)) {
        throw "index.json not found at $IndexPath"
    }
    $indexDoc = Get-Content -Path $IndexPath -Raw | ConvertFrom-Json
    if ($sdkEntries.Count -eq 0) {
        $sdkEntries = @(Get-PropValue $indexDoc 'sdks' @())
    }
    if ([string]::IsNullOrWhiteSpace($effectiveReleaseTag)) {
        $effectiveReleaseTag = [string](Get-PropValue $indexDoc 'releaseTag' '')
    }
}

if ([string]::IsNullOrWhiteSpace($effectiveReleaseTag)) {
    $effectiveReleaseTag = 'latest'
}

# Infer Repository from an entry downloadUrl when running locally without -Repository
if ([string]::IsNullOrWhiteSpace($Repository)) {
    foreach ($s in $sdkEntries) {
        $dlUrl = [string](Get-PropValue $s 'downloadUrl' '')
        if ($dlUrl -match '^https://github\.com/([^/]+/[^/]+)/releases/download/') {
            $Repository = $Matches[1]
            break
        }
    }
}

$versionsCfg = if (Test-Path $VersionsPath) {
    Get-Content -Path $VersionsPath -Raw | ConvertFrom-Json
} else {
    $null
}

$branchOrder = @{}
if ($null -ne $versionsCfg) {
    $branchesObj = Get-PropValue $versionsCfg 'branches' $null
    if ($null -ne $branchesObj) {
        $bIdx = 0
        foreach ($bName in $branchesObj.PSObject.Properties.Name) {
            $branchOrder[$bName] = $bIdx
            $bIdx++
        }
    }
}

$sortedSdks = @(
    $sdkEntries | Sort-Object `
        @{ Expression = { [string](Get-PropValue $_ 'fpcVersion' '') } }, `
        @{ Expression = { [string](Get-PropValue $_ 'targetOs' '') } }, `
        @{ Expression = { [string](Get-PropValue $_ 'targetCpu' '') } }, `
        @{ Expression = { [string](Get-PropValue $_ 'sdkId' '') } }
)

$sdkGroupsMap   = @{}
$presentTargets = @{}
foreach ($s in $sortedSdks) {
    $triplet = [string](Get-PropValue $s 'targetTriplet' '')
    if (-not [string]::IsNullOrWhiteSpace($triplet)) {
        $presentTargets[$triplet] = $true
    }
    $ver  = [string](Get-PropValue $s 'fpcVersion' '')
    $ref  = [string](Get-PropValue $s 'gitRef' '')
    $gKey = "$ver|$ref"
    if (-not $sdkGroupsMap.ContainsKey($gKey)) {
        $bRank = if (-not [string]::IsNullOrWhiteSpace($ref) -and $branchOrder.ContainsKey($ref)) {
            $branchOrder[$ref]
        } else {
            -1
        }
        $sdkGroupsMap[$gKey] = [PSCustomObject]@{
            FpcVersion = $ver
            GitRef     = $ref
            BranchRank = $bRank
            Items      = [System.Collections.Generic.List[object]]::new()
        }
    }
    $sdkGroupsMap[$gKey].Items.Add($s)
}

$coreTargets = @(
    'x86_64-win64',
    'x86_64-linux',
    'x86_64-darwin',
    'aarch64-linux',
    'aarch64-darwin'
)
$targetColumns = [System.Collections.Generic.List[string]]::new()
foreach ($ct in $coreTargets) {
    if ($ct -eq 'aarch64-linux' -and $presentTargets.ContainsKey('aarch64-win64')) {
        $targetColumns.Add('aarch64-win64')
    }
    $targetColumns.Add($ct)
}
foreach ($pt in ($presentTargets.Keys | Sort-Object)) {
    if (-not $targetColumns.Contains($pt)) {
        $targetColumns.Add($pt)
    }
}

$orderedGroups = @(
    $sdkGroupsMap.Values | Sort-Object `
        @{ Expression = { Get-FpcVersionSortKey $_.FpcVersion }; Descending = $true }, `
        @{ Expression = { $_.BranchRank }; Descending = $true }, `
        @{ Expression = { $_.GitRef }; Ascending = $true }
)

$indexRef = if (-not [string]::IsNullOrWhiteSpace($Repository)) {
    "[``index.json``](https://github.com/$Repository/releases/download/$effectiveReleaseTag/index.json)"
} else {
    "``index.json``"
}
$invCulture = [System.Globalization.CultureInfo]::InvariantCulture

$targetHeaders = @($targetColumns | ForEach-Object { ($_ -split '-', 2) -join '<br>' })
$headerCells   = @('Version', 'Date', 'Git') + $targetHeaders
$alignCells    = @(':---', ':---', ':---') + @($targetColumns | ForEach-Object { '---:' })

$notesLines = @(
    "Prebuilt, zero-config FreePascal SDK archives including compiler, binutils, precompiled ``.ppu`` units, and clean ``rtl`` & ``packages`` source trees. SHA-256 checksum files (``.sha256``) are attached as release assets; machine-readable registry: $indexRef."
    ''
    "| $($headerCells -join ' | ') |"
    "| $($alignCells -join ' | ') |"
)

foreach ($grp in $orderedGroups) {
    $ver   = $grp.FpcVersion
    $ref   = $grp.GitRef
    $items = @($grp.Items)

    $branchesObj = if ($null -ne $versionsCfg) { Get-PropValue $versionsCfg 'branches' $null } else { $null }
    $branchCfg   = if (-not [string]::IsNullOrWhiteSpace($ref) -and $null -ne $branchesObj) {
        Get-PropValue $branchesObj $ref $null
    } else {
        $null
    }

    $repoUrl = ''
    foreach ($it in $items) {
        $candidateRepo = [string](Get-PropValue $it 'gitRepo' '')
        if (-not [string]::IsNullOrWhiteSpace($candidateRepo)) {
            $repoUrl = $candidateRepo
            break
        }
    }
    if ([string]::IsNullOrWhiteSpace($repoUrl)) {
        $cfgBranchRepo = if ($null -ne $branchCfg) { [string](Get-PropValue $branchCfg 'gitRepo' '') } else { '' }
        $cfgDefRepo    = if ($null -ne $versionsCfg) { [string](Get-PropValue $versionsCfg 'defaultRepository' '') } else { '' }
        if (-not [string]::IsNullOrWhiteSpace($cfgBranchRepo)) {
            $repoUrl = $cfgBranchRepo
        } elseif (-not [string]::IsNullOrWhiteSpace($cfgDefRepo)) {
            $repoUrl = $cfgDefRepo
        }
    }

    $gitLines = @()
    if (-not [string]::IsNullOrWhiteSpace($ref)) {
        $refUrl = Format-RepoWebLink -RepoUrl $repoUrl -Kind 'tree' -Target $ref
        if ($refUrl) {
            $gitLines += "[``$ref``]($refUrl)"
        } else {
            $gitLines += "``$ref``"
        }
    }

    $commitBadges = @()
    $seenCommits  = @{}
    foreach ($it in $items) {
        $shortC = ([string](Get-PropValue $it 'gitCommitShort' '')).Trim()
        $fullC  = ([string](Get-PropValue $it 'gitCommit' '')).Trim()
        if ([string]::IsNullOrWhiteSpace($shortC) -and $fullC.Length -ge 8) {
            $shortC = $fullC.Substring(0, 8)
        }
        if (-not [string]::IsNullOrWhiteSpace($shortC) -and -not $seenCommits.ContainsKey($shortC)) {
            $seenCommits[$shortC] = $true
            $linkTarget = if (-not [string]::IsNullOrWhiteSpace($fullC)) { $fullC } else { $shortC }
            $commitUrl  = Format-RepoWebLink -RepoUrl $repoUrl -Kind 'commit' -Target $linkTarget
            if ($commitUrl) {
                $commitBadges += "[``$shortC``]($commitUrl)"
            } else {
                $commitBadges += "``$shortC``"
            }
        }
    }
    if ($commitBadges.Count -gt 0) {
        $gitLines += ($commitBadges -join ', ')
    }

    $gitCell = if ($gitLines.Count -gt 0) { $gitLines -join '<br>' } else { '-' }

    $commitDateShort = ''
    foreach ($it in $items) {
        $rawCd = ([string](Get-PropValue $it 'gitCommitDate' '')).Trim()
        if (-not [string]::IsNullOrWhiteSpace($rawCd)) {
            try {
                $commitDateShort = [DateTimeOffset]::Parse($rawCd, $invCulture).UtcDateTime.ToString('yyyy-MM-dd', $invCulture)
            } catch {
                if ($rawCd.Length -ge 10) { $commitDateShort = $rawCd.Substring(0, 10) }
            }
            if (-not [string]::IsNullOrWhiteSpace($commitDateShort)) { break }
        }
    }

    $dateCell = if (-not [string]::IsNullOrWhiteSpace($commitDateShort)) { $commitDateShort } else { '-' }

    $byTarget = @{}
    foreach ($it in $items) {
        $t = [string](Get-PropValue $it 'targetTriplet' '')
        if (-not [string]::IsNullOrWhiteSpace($t)) {
            $byTarget[$t] = $it
        }
    }

    $rowCells = @("**$ver**", $dateCell, $gitCell)
    foreach ($col in $targetColumns) {
        if ($byTarget.ContainsKey($col)) {
            $s      = $byTarget[$col]
            $bytes  = [double](Get-PropValue $s 'sizeBytes' 0)
            $dlUrl  = [string](Get-PropValue $s 'downloadUrl' '')
            $sizeMb = [string]::Format($invCulture, '{0:N2} MB', ($bytes / 1MB))
            if (-not [string]::IsNullOrWhiteSpace($dlUrl)) {
                $rowCells += "[$sizeMb]($dlUrl)"
            } else {
                $rowCells += $sizeMb
            }
        } else {
            $rowCells += '-'
        }
    }

    $notesLines += "| $($rowCells -join ' | ') |"
}

$markdown = ($notesLines -join "`n") + "`n"

if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    $parentDir = Split-Path -Parent $OutputPath
    if (-not [string]::IsNullOrWhiteSpace($parentDir) -and -not (Test-Path $parentDir)) {
        New-Item -ItemType Directory -Force -Path $parentDir | Out-Null
    }
    [System.IO.File]::WriteAllText($OutputPath, $markdown, [System.Text.UTF8Encoding]::new($false))
}

if ([string]::IsNullOrWhiteSpace($OutputPath) -or $PassThru) {
    return $markdown
}
