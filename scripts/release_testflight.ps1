param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9]+$')]
    [string] $BuildNumber,

    [string] $Version,

    [switch] $Watch
)

$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $RepoRoot

if (-not $Version) {
    $versionLine = Select-String -Path "pubspec.yaml" -Pattern "^version:\s*([0-9]+\.[0-9]+\.[0-9]+)\+" | Select-Object -First 1
    if (-not $versionLine) {
        throw "Could not infer app version from pubspec.yaml. Pass -Version explicitly."
    }
    $Version = $versionLine.Matches[0].Groups[1].Value
}

if ($Version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$') {
    throw "Version must look like 1.0.0."
}

$tag = "ios-v$Version-$BuildNumber"

Write-Host "==> Checking release tag $tag" -ForegroundColor Cyan
git rev-parse -q --verify "refs/tags/$tag" | Out-Null
if ($LASTEXITCODE -eq 0) {
    throw "Local tag already exists: $tag"
}

git ls-remote --exit-code --tags origin "refs/tags/$tag" | Out-Null
if ($LASTEXITCODE -eq 0) {
    throw "Remote tag already exists: $tag"
}
if ($LASTEXITCODE -ne 2) {
    throw "Could not check remote tag $tag"
}

Write-Host "==> Creating tag $tag" -ForegroundColor Cyan
git tag -a $tag -m "Release iCan $Version build $BuildNumber to TestFlight"

Write-Host "==> Pushing tag $tag" -ForegroundColor Cyan
git push origin $tag

Write-Host "Triggered TestFlight release from tag $tag." -ForegroundColor Green

if ($Watch) {
    $gh = Get-Command gh -ErrorAction SilentlyContinue
    if (-not $gh) {
        Write-Warning "GitHub CLI is not installed; cannot watch workflow."
        exit 0
    }

    gh auth status *> $null
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "GitHub CLI is not authenticated; run 'gh auth login' to enable workflow watching."
        exit 0
    }

    Write-Host "==> Waiting for GitHub Actions run" -ForegroundColor Cyan
    $runId = $null
    for ($i = 0; $i -lt 30; $i++) {
        $json = gh run list `
            --repo saberrg/ican `
            --workflow ios_testflight.yml `
            --limit 10 `
            --json databaseId,headBranch,event `
            2>$null
        if ($LASTEXITCODE -eq 0 -and $json) {
            $runs = $json | ConvertFrom-Json
            $match = $runs | Where-Object { $_.headBranch -eq $tag -or $_.event -eq "push" } | Select-Object -First 1
            if ($match) {
                $runId = $match.databaseId
                break
            }
        }
        Start-Sleep -Seconds 5
    }

    if ($runId) {
        gh run watch $runId --repo saberrg/ican
    } else {
        Write-Warning "Could not find the release workflow run yet. Check GitHub Actions manually."
    }
}
