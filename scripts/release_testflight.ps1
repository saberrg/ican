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

if ($Version -and $Version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$') {
    throw "Version must look like 1.0.0."
}

$branch = "release/testflight-build-$BuildNumber"

Write-Host "==> Checking release branch $branch" -ForegroundColor Cyan
git ls-remote --exit-code --heads origin "refs/heads/$branch" | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-Host "Remote branch exists; updating it to trigger a new TestFlight run." -ForegroundColor Yellow
} elseif ($LASTEXITCODE -ne 2) {
    throw "Could not check remote branch $branch"
}

Write-Host "==> Pushing release branch $branch" -ForegroundColor Cyan
git push origin "HEAD:refs/heads/$branch"

Write-Host "Triggered TestFlight release from branch $branch." -ForegroundColor Green

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
            $match = $runs | Where-Object { $_.headBranch -eq $branch -or $_.event -eq "push" } | Select-Object -First 1
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
