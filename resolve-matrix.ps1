<#
.SYNOPSIS
    Resolves upstream FreePascal Git branch commits and generates the CI build matrix.

.DESCRIPTION
    Reads tracked branches and runner mappings from versions.json, queries upstream
    Git repositories via 'git ls-remote', optionally compares commits against the published
    index.json on GitHub Releases (or a local file), and outputs the filtered build matrix.
    When running inside GitHub Actions, writes 'has_targets' and 'matrix' to GITHUB_OUTPUT and
    appends a Markdown status table to GITHUB_STEP_SUMMARY.

.EXAMPLE
    .\resolve-matrix.ps1
    .\resolve-matrix.ps1 -Branch main,fixes_3_2 -TargetFilter x86_64-win64 -ForceRebuild
    .\resolve-matrix.ps1 -Repository nikrun/sdk
#>
[CmdletBinding()]
param(
    [Parameter()]
    [string]$Branch = 'all',

    [Parameter()]
    [string]$RepoUrl = '',

    [Parameter()]
    [string]$TargetFilter = 'all',

    [Parameter()]
    [switch]$ForceRebuild,

    [Parameter()]
    [string]$Repository = '',

    [Parameter()]
    [string]$ReleaseTag = 'latest',

    [Parameter()]
    [string]$ExistingIndexPath = '',

    [Parameter()]
    [string]$VersionsPath = '',

    [Parameter()]
    [switch]$PassThru
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ScriptRoot = $PSScriptRoot

if ([string]::IsNullOrWhiteSpace($VersionsPath)) {
    $VersionsPath = Join-Path $ScriptRoot 'versions.json'
}
if ([string]::IsNullOrWhiteSpace($Repository)) {
    $Repository = if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_REPOSITORY)) {
        $env:GITHUB_REPOSITORY
    } else {
        'nikrun/sdk'
    }
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

function Resolve-RemoteBranchCommit {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RemoteRepoUrl,
        [Parameter(Mandatory = $true)]
        [string]$RefName
    )

    if ($RefName -match '^[0-9a-fA-F]{40}$') {
        return $RefName.ToLowerInvariant()
    }

    $prevErr = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $lines = @(& git ls-remote $RemoteRepoUrl "refs/heads/$RefName" "refs/tags/$RefName" "refs/tags/$RefName^{}" 2>&1)
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prevErr
    }

    if ($exitCode -ne 0) {
        throw "git ls-remote failed for '$RemoteRepoUrl' ('$RefName'): $($lines -join "`n")"
    }

    $headSha   = $null
    $peeledSha = $null
    $tagSha    = $null
    foreach ($line in $lines) {
        $text = "$line".Trim()
        if ($text -match '^([0-9a-fA-F]{40})\s+(.+)$') {
            $sha = $Matches[1].ToLowerInvariant()
            $ref = $Matches[2].Trim()
            if ($ref -eq "refs/heads/$RefName")       { $headSha   = $sha }
            elseif ($ref -eq "refs/tags/$RefName^{}") { $peeledSha = $sha }
            elseif ($ref -eq "refs/tags/$RefName")    { $tagSha    = $sha }
        }
    }

    if ($headSha)   { return $headSha }
    if ($peeledSha) { return $peeledSha }
    if ($tagSha)    { return $tagSha }

    throw "Branch or tag '$RefName' was not found in Git repository '$RemoteRepoUrl'."
}

if (-not (Test-Path $VersionsPath)) {
    throw "versions.json not found at $VersionsPath"
}
$cfg = Get-Content -Path $VersionsPath -Raw | ConvertFrom-Json

$configuredBranches = @($cfg.branches.PSObject.Properties.Name)
$selectedRaw        = $Branch.Trim()
$repoOverride       = $RepoUrl.Trim()
$targetFilterClean  = $TargetFilter.Trim()
$onlyIfUpdated      = (-not $ForceRebuild.IsPresent)

if ([string]::IsNullOrWhiteSpace($selectedRaw) -or $selectedRaw.ToLowerInvariant() -eq 'all') {
    $selectedBranches = $configuredBranches
} else {
    $selectedBranches = @($selectedRaw.Split(',', [System.StringSplitOptions]::RemoveEmptyEntries) | ForEach-Object { $_.Trim() })
}

# Load existing index.json when incremental update check is active
$existingSdks = @()
if ($onlyIfUpdated) {
    $tempDownloadedIndex = $null
    $indexToRead         = $ExistingIndexPath

    if ([string]::IsNullOrWhiteSpace($indexToRead) -and -not [string]::IsNullOrWhiteSpace($Repository)) {
        if (Get-Command gh -ErrorAction SilentlyContinue) {
            $tempDownloadedIndex = Join-Path ([System.IO.Path]::GetTempPath()) ("nikrun-existing-sdk-index-{0}.json" -f [guid]::NewGuid().ToString('N'))
            $prevErr = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            & gh release download $ReleaseTag --repo $Repository --pattern 'index.json' --output $tempDownloadedIndex --clobber 2>$null
            $dlExit = $LASTEXITCODE
            $ErrorActionPreference = $prevErr
            if ($dlExit -eq 0 -and (Test-Path $tempDownloadedIndex)) {
                $indexToRead = $tempDownloadedIndex
            }
        }
    }

    try {
        if (-not [string]::IsNullOrWhiteSpace($indexToRead) -and (Test-Path $indexToRead)) {
            try {
                $existingIdx  = Get-Content -Path $indexToRead -Raw | ConvertFrom-Json
                $existingSdks = @(Get-PropValue $existingIdx 'sdks' @())
                Write-Host "Loaded $($existingSdks.Count) published SDK entry/entries for update comparison." -ForegroundColor Cyan
            } catch {
                Write-Warning "Could not parse existing index.json; treating all branches as needing build."
            }
        } else {
            Write-Host "No existing index.json available for '$ReleaseTag'; all selected branches will be built." -ForegroundColor Yellow
        }
    } finally {
        if ($null -ne $tempDownloadedIndex -and (Test-Path $tempDownloadedIndex)) {
            Remove-Item -Force $tempDownloadedIndex -ErrorAction SilentlyContinue
        }
    }
}

$defaultTargets  = @($cfg.targetRunners.PSObject.Properties.Name)
$hasTargetFilter = (-not [string]::IsNullOrWhiteSpace($targetFilterClean)) -and ($targetFilterClean.ToLowerInvariant() -ne 'all')
$filterTokens    = @(
    if ($hasTargetFilter) {
        $targetFilterClean.Split(',', [System.StringSplitOptions]::RemoveEmptyEntries) | ForEach-Object { $_.Trim().ToLowerInvariant() }
    }
)

$matchedCandidatesCount = 0
$targetsToBuild         = @()
$summaryLines           = @(
    '### FreePascal SDK Branch Update Check'
    ''
    '| Branch / Ref | Upstream Commit | Status | Targets Queued |'
    '| :--- | :--- | :--- | :--- |'
)

foreach ($branchName in $selectedBranches) {
    $branchCfg = Get-PropValue $cfg.branches $branchName $null
    $branchRepo = if ($null -ne $branchCfg) { [string](Get-PropValue $branchCfg 'gitRepo' '') } else { '' }

    $effectiveRepoUrl = if (-not [string]::IsNullOrWhiteSpace($repoOverride)) {
        $repoOverride
    } elseif (-not [string]::IsNullOrWhiteSpace($branchRepo)) {
        $branchRepo
    } else {
        [string]$cfg.defaultRepository
    }

    $cfgTargets = @(if ($null -ne $branchCfg) { Get-PropValue $branchCfg 'supportedTargets' @() })
    $supportedTargets = @(
        if ($cfgTargets.Count -gt 0) {
            $cfgTargets
        } else {
            $defaultTargets
        }
    )

    $remoteCommit = Resolve-RemoteBranchCommit -RemoteRepoUrl $effectiveRepoUrl -RefName $branchName
    $shortCommit  = $remoteCommit.Substring(0, 8)
    $safeArtifact = ($branchName -replace '[^A-Za-z0-9._-]', '_')

    $branchQueued = 0
    $branchTotal  = 0

    foreach ($triplet in $supportedTargets) {
        $parts = $triplet -split '-', 2
        if ($parts.Count -ne 2) {
            throw "Invalid target triplet '$triplet' for branch '$branchName' (expected '<cpu>-<os>')."
        }
        $cpu = $parts[0]
        $os  = $parts[1]

        if ($hasTargetFilter) {
            $osCpu       = "$os-$cpu".ToLowerInvariant()
            $cpuOs       = "$cpu-$os".ToLowerInvariant()
            $branchOsCpu = "$($branchName):$osCpu".ToLowerInvariant()
            $branchCpuOs = "$($branchName):$cpuOs".ToLowerInvariant()
            if (($filterTokens -notcontains $osCpu) -and
                ($filterTokens -notcontains $cpuOs) -and
                ($filterTokens -notcontains $branchOsCpu) -and
                ($filterTokens -notcontains $branchCpuOs)) {
                continue
            }
        }

        $runnerName = [string](Get-PropValue $cfg.targetRunners $triplet '')
        if ([string]::IsNullOrWhiteSpace($runnerName)) {
            throw "No GitHub Actions runner configured in versions.json targetRunners for '$triplet'."
        }

        $matchedCandidatesCount++
        $branchTotal++

        if ($onlyIfUpdated) {
            $alreadyPublished = $existingSdks | Where-Object {
                ([string](Get-PropValue $_ 'gitRef' '') -eq $branchName) -and
                ([string](Get-PropValue $_ 'targetTriplet' '') -eq $triplet) -and
                (([string](Get-PropValue $_ 'gitCommit' '')).ToLowerInvariant() -eq $remoteCommit)
            } | Select-Object -First 1

            if ($null -ne $alreadyPublished) {
                continue
            }
        }

        $branchQueued++
        $targetsToBuild += [ordered]@{
            branch          = $branchName
            artifact_branch = $safeArtifact
            repo_url        = $effectiveRepoUrl
            git_commit      = $remoteCommit
            short_commit    = $shortCommit
            runner          = $runnerName
            target_os       = $os
            target_cpu      = $cpu
        }
    }

    if ($branchTotal -eq 0) {
        $summaryLines += "| ``$branchName`` | ``$shortCommit`` | Filtered out | 0 |"
    } elseif ($branchQueued -eq 0) {
        Write-Host " [SKIP] '$branchName' ($shortCommit) is already up-to-date across all $branchTotal target(s)." -ForegroundColor Green
        $summaryLines += "| ``$branchName`` | ``$shortCommit`` | Up-to-date (skipped) | 0 / $branchTotal |"
    } else {
        $reason = if ($onlyIfUpdated) { 'Update detected' } else { 'Rebuild requested' }
        Write-Host " [BUILD] '$branchName' ($shortCommit): $reason -> queuing $branchQueued / $branchTotal target(s)." -ForegroundColor Cyan
        $summaryLines += "| ``$branchName`` | ``$shortCommit`` | **$reason** | **$branchQueued / $branchTotal** |"
    }
}

if ($matchedCandidatesCount -eq 0) {
    throw "No matrix targets matched branch='$selectedRaw' and target_filter='$targetFilterClean'."
}

$summaryMarkdown = ($summaryLines -join "`n") + "`n"
if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_STEP_SUMMARY)) {
    [System.IO.File]::AppendAllText($env:GITHUB_STEP_SUMMARY, $summaryMarkdown, [System.Text.UTF8Encoding]::new($false))
}

$hasTargets = ($targetsToBuild.Count -gt 0)
$json       = @{ include = @($targetsToBuild) } | ConvertTo-Json -Compress -Depth 4

Write-Host "Matrix ($($targetsToBuild.Count) target(s)): $json"

if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_OUTPUT)) {
    $outputText = "has_targets=$($hasTargets.ToString().ToLowerInvariant())`nmatrix=$json`n"
    [System.IO.File]::AppendAllText($env:GITHUB_OUTPUT, $outputText, [System.Text.UTF8Encoding]::new($false))
}

if ($PassThru) {
    return [PSCustomObject]@{
        HasTargets      = $hasTargets
        TargetsCount    = $targetsToBuild.Count
        MatrixJson      = $json
        SummaryMarkdown = $summaryMarkdown
    }
}
