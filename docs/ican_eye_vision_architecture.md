# iCan Eye Vision Architecture

Last updated: 2026-04-30

## System Overview

The iCan Eye pipeline converts a BLE-streamed JPEG from the ESP32-S3 camera into a spoken scene description. Describe is cloud-first by default. Local Describe is Gemma-only and must prove native readiness before use.

```text
iCan Eye JPEG -> Flutter app -> SceneDescriptionService -> TTS
                         |
                         +-- Cloud Gemini, default in Auto
                         +-- Gemma 4 E2B LiteRT-LM, local fallback/offline
```

## Describe Backend Selection

```text
User presses Describe
        |
        v
VisionMode == cloudOnly?
        | yes
        v
Cloud Gemini

VisionMode == auto?
        | yes
        v
Try Cloud Gemini first
        |
        +-- success -> speak cloud result
        +-- failure -> require native channel health + Gemma readiness
                         |
                         +-- ready -> Gemma local
                         +-- not ready -> report cloud failure/local unavailable

VisionMode == offlineOnly?
        |
        v
Require Gemma readiness
        |
        +-- ready -> Gemma local
        +-- not ready -> fail closed with local diagnostic
```

Backend enum: `cloud | gemma`.

## Local Gemma Stack

Files:

```text
lib/services/on_device_vision_service.dart
lib/services/scene_description_service.dart
ios/Runner/OnDeviceVisionChannel.swift
ios/Runner/GemmaLiteRtService.swift
ios/Runner/GemmaModelDownloadManager.swift
```

Native channel:

```text
Method channel: com.ican/on_device_vision
Stream channel: com.ican/gemma_stream
```

Model artifact:

```text
Filename: gemma-4-E2B-it.litertlm
Runtime: Google AI Edge LiteRT-LM for iOS
Storage: Documents/models, excluded from iCloud backup
Integrity: expected byte size + SHA-256 sidecar
```

The iOS service is intentionally fail-closed until the LiteRT-LM runtime is actually linked into the Runner target. It must not return fake descriptions.

## Live Perception

Live mode is separate from Describe. It can still use native Apple Vision/Core ML perception for OCR, object, person, and depth diagnostics. Those models are not allowed to masquerade as the local Describe backend.

## Eye Button Contract

The owning mapping remains `HomeViewModel._buttonSub`:

| Eye event | Behavior |
|-----------|----------|
| `BUTTON:SINGLE` | Run active Describe pipeline. No-op while Live is running. |
| `BUTTON:DOUBLE` | Toggle Cloud/Local Describe mode. Stop Live first if needed. |
| `BUTTON:LONG` | Toggle Live detection. |

Voice command remains in-app only through the Listen button.

## Verification

Required local gates:

```powershell
dart format lib test
flutter test --no-pub
.\scripts\agent_verify.ps1 -SkipPubGet
.\scripts\agent_verify.ps1 -SkipPubGet -OfflineVision
```

Required real-device gate before claiming local Describe works:

1. Build Runner on a real iPhone with LiteRT-LM linked.
2. Download and verify `gemma-4-E2B-it.litertlm`.
3. Run Vision Diagnostic Gemma self-test and readiness probe.
4. Capture three iCan Eye JPEGs and confirm non-empty Gemma descriptions.
5. Record iPhone model, iOS version, app build, and model hash in the PR notes.
