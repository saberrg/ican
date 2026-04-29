param(
    [switch] $SkipAutomated,
    [switch] $Firmware,
    [switch] $OfflineVision,
    [switch] $Integration,
    [string] $DeviceId,
    [string] $OutDir = "build\eye_release_readiness"
)

$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $RepoRoot

function Invoke-Step {
    param(
        [Parameter(Mandatory = $true)] [string] $Name,
        [Parameter(Mandatory = $true)] [scriptblock] $Command
    )

    Write-Host ""
    Write-Host "==> $Name" -ForegroundColor Cyan
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        & $Command 2>&1 | ForEach-Object { Write-Host $_ }
    } finally {
        $ErrorActionPreference = $previousPreference
    }
    if ($LASTEXITCODE -ne 0) {
        throw "$Name failed with exit code $LASTEXITCODE"
    }
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$resolvedOutDir = Join-Path $RepoRoot $OutDir
New-Item -ItemType Directory -Force -Path $resolvedOutDir | Out-Null
$reportPath = Join-Path $resolvedOutDir "eye-readiness-$timestamp.md"

$verifyArgs = @("-SkipPubGet")
if ($Firmware) { $verifyArgs += "-Firmware" }
if ($OfflineVision) { $verifyArgs += "-OfflineVision" }

if (-not $SkipAutomated) {
    Invoke-Step "iCan automated verification" {
        & .\scripts\agent_verify.ps1 @verifyArgs
    }
}

if ($Integration) {
    $integrationArgs = @("test", "integration_test/eye_demo_startup_test.dart", "--no-pub")
    if ($DeviceId) {
        $integrationArgs += @("-d", $DeviceId)
    }
    Invoke-Step "Flutter integration test: Eye demo startup" {
        & flutter @integrationArgs
    }
}

$gitHead = git rev-parse --short HEAD
$gitStatus = git status --short
$gitStatusText = if ($gitStatus) { $gitStatus -join "`n" } else { "clean" }
$deviceText = if ($DeviceId) { $DeviceId } else { "not recorded" }
$generatedAt = (Get-Date).ToString("s")

$report = @"
# iCan Eye Release Readiness Report

Generated: $generatedAt
Git HEAD: $gitHead
Device ID: $deviceText

## Automated Gates

- [ ] `.\scripts\agent_verify.ps1 -SkipPubGet`
- [ ] `.\scripts\agent_verify.ps1 -SkipPubGet -OfflineVision`
- [ ] `.\scripts\agent_verify.ps1 -SkipPubGet -Firmware`
- [ ] `flutter test integration_test/eye_demo_startup_test.dart --no-pub`

## Test Hardware

- iPhone model:
- iOS version:
- iCan Eye board serial:
- Eye firmware commit/SHA:
- App version/build:
- TestFlight build number:
- Network state:
- Test operator:

## Real Eye Matrix

| Gate | Result | Notes |
| --- | --- | --- |
| Fresh install launches Splash then Home | TODO | |
| Caretaker and role-selection paths hidden | TODO | |
| Home speaks `iCan Eye connected.` once | TODO | |
| Eye readiness waits for image/control/instant-text notifications and STATUS | TODO | |
| STATUS heartbeat stays healthy for 2 minutes idle | TODO | |
| 10 FAST captures complete without E02/E03/E04 | TODO | |
| 5 BALANCED captures complete without disconnect | TODO | |
| PROFILE 0/1/2/3 transitions confirmed by firmware | TODO | |
| Cloud Describe returns useful one-breath output | TODO | |
| Auto mode stays cloud-first while online | TODO | |
| Offline Describe is blocked or diagnostic-only unless native health passes | TODO | |
| Live Detection runs 60 seconds without overlap/truncated TTS | TODO | |
| Live Detection runs 5 minutes without disconnect or stuck speech | TODO | |
| Stop Live sends ABORT/LIVE_STOP and returns to idle | TODO | |
| Power off Eye mid-live speaks disconnect once | TODO | |
| Reconnect after power cycle succeeds | TODO | |
| Eye double button press starts voice listening once | TODO | |
| Bad cloud/network failure produces diagnostic, not crash | TODO | |
| Relaunch after killed Describe surfaces unfinished trace | TODO | |

## Failure Injection Matrix

| Injection | Expected App Behavior | Result | Notes |
| --- | --- | --- | --- |
| No CAPTURE:START/SIZE | Eye E01 diagnostic | TODO | |
| Missing END | Eye E02 diagnostic | TODO | |
| Firmware STREAM_ABORTED | Eye E02 diagnostic with bytes/chunks | TODO | |
| Truncated JPEG | Eye E03 diagnostic | TODO | |
| CRC mismatch | Eye E04 diagnostic | TODO | |
| CAMERA_CAPTURE_FAILED | Eye E05 diagnostic | TODO | |
| Duplicate chunk | No duplicate bytes in assembled JPEG | TODO | |
| Skipped sequence | missedChunks increments and failure if incomplete | TODO | |

## Crash And Feedback Collection

- [ ] Xcode Organizer checked for this build.
- [ ] App Store Connect TestFlight feedback checked.
- [ ] Crash reports symbolicated with matching dSYM if present.
- [ ] No raw crash logs, Apple IDs, image bytes, or secrets committed.

## Dirty Worktree Snapshot

````text
$gitStatusText
````
"@

Set-Content -Path $reportPath -Value $report -Encoding UTF8
Write-Host ""
Write-Host "Readiness report written to $reportPath" -ForegroundColor Green
