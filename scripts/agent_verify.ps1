param(
    [switch] $Firmware,
    [switch] $IosPreflight,
    [switch] $OfflineVision,
    [switch] $StrictAnalyze,
    [switch] $SkipPubGet
)

$ErrorActionPreference = "Stop"

# PowerShell 7+ turns any stderr output from a native command into a
# NativeCommandError record under "Stop". flutter analyze and a few other
# tools write info-level notices to stderr even when they exit 0, which was
# bringing down the whole runner. We force each step to treat stderr as
# ordinary output and drive success purely from the exit code.
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
        # 2>&1 merges native stderr into the stdout stream so PowerShell
        # cannot promote non-fatal notices into terminating errors.
        & $Command 2>&1 | ForEach-Object { Write-Host $_ }
    } finally {
        $ErrorActionPreference = $previousPreference
    }
    if ($LASTEXITCODE -ne 0) {
        throw "$Name failed with exit code $LASTEXITCODE"
    }
}

$RepoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $RepoRoot

Invoke-Step "Flutter version" { flutter --version }

if (-not $SkipPubGet) {
    Invoke-Step "Flutter pub get" { flutter pub get }
}

Invoke-Step "Dart format check" {
    dart format --output=json --set-exit-if-changed lib test | Out-Null
}

Invoke-Step "Flutter analyze" {
    if ($StrictAnalyze) {
        flutter analyze --fatal-infos --fatal-warnings
    } else {
        flutter analyze --no-fatal-infos --fatal-warnings
    }
}

Invoke-Step "Flutter tests" {
    flutter test --no-pub
}

if ($IosPreflight) {
    Invoke-Step "iOS debug build preflight" {
        flutter build ios --debug --no-codesign --no-pub --dart-define=API_KEY=dummy
    }
}

if ($Firmware) {
    Invoke-Step "iCan Eye firmware build: xiao_esp32s3" {
        py -m platformio run -d firmware\ican_eye -e xiao_esp32s3
    }
    Invoke-Step "iCan Eye host-native chunk-math tests" {
        py -m platformio test -d firmware\ican_eye -e native
    }
}

if ($OfflineVision) {
    Invoke-Step "Offline vision static preflight" {
        $required = @(
            "lib\services\scene_description_service.dart",
            "lib\services\on_device_vision_service.dart",
            "ios\Runner\OnDeviceVisionChannel.swift",
            "ios\Runner\VisionService.swift",
            "ios\Runner\LlamaService.swift",
            "ios\Runner\ModelDownloadManager.swift",
            "ios\Runner\EyePipeline\SceneContext.swift",
            "ios\Runner\EyePipeline\PerceptionLayer.swift",
            "ios\Runner\EyePipeline\FoundationModelSynthesizer.swift"
        )

        foreach ($path in $required) {
            if (-not (Test-Path $path)) {
                throw "Missing required offline vision file: $path"
            }
        }

        if (-not (Test-Path "ios\Frameworks\llama.xcframework")) {
            Write-Warning "Missing ios\Frameworks\llama.xcframework. SmolVLM native inference cannot be validated on device until this is restored."
        }

        if (-not (Test-Path "ios\Runner\EyePipeline\Models")) {
            Write-Warning "Missing ios\Runner\EyePipeline\Models. CoreML object/depth models must be added for full offline perception."
        }

        $coreMlModels = @(
            "ios\Runner\EyePipeline\Models\YOLOv3Tiny.mlmodel",
            "ios\Runner\EyePipeline\Models\DepthAnythingV2SmallF16P6.mlpackage"
        )

        foreach ($path in $coreMlModels) {
            if (-not (Test-Path $path)) {
                Write-Warning "Missing CoreML model artifact: $path"
            }
        }

        $projectFile = "ios\Runner.xcodeproj\project.pbxproj"
        $projectText = Get-Content -Raw $projectFile
        foreach ($name in @("YOLOv3Tiny.mlmodel in Resources", "DepthAnythingV2SmallF16P6.mlpackage in Resources")) {
            if ($projectText -notmatch [regex]::Escape($name)) {
                Write-Warning "CoreML model is not linked in Runner resources: $name"
            }
        }
    }
}

Write-Host ""
Write-Host "Agent verification completed." -ForegroundColor Green
