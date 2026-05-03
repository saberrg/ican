# iCan

**iCan is an ECE 441 assistive smart-cane system that pairs an iOS app with BLE cane hardware and the iCan Eye camera module to describe the user's surroundings out loud.**

The presentation story is simple: the cane/app captures what is in front of the user, chooses the best available vision backend, and speaks a useful scene summary with live or on-demand feedback.

## What works now

- **iOS companion app:** accessible home screen, voice control hooks, settings, text-to-speech, BLE communication, and scene-description flows.
- **iCan Eye BLE camera path:** firmware/app protocol support for still capture and firmware-driven live capture.
- **Live vision mode:** the app can start/stop periodic iCan Eye frames and announce useful live cues.
- **Local/offline vision path:** implemented through on-device vision services with runtime health checks and fallbacks.
- **Cloud vision path:** Gemini-backed scene descriptions for high-quality online results.
- **Fallback behavior:** the app reports degraded/unavailable backends instead of pretending every model is always present.

## Demo spine

1. Open the iCan app and connect to the cane/iCan Eye over BLE.
2. Trigger a scene description from the camera module.
3. The app routes the image through Gemini or local/offline vision depending on selected mode and backend availability.
4. The result is spoken aloud through iOS text-to-speech.
5. Start live vision to receive repeated, short environmental cues while the iCan Eye streams frames.

See [`docs/PRESENTATION_DEMO.md`](docs/PRESENTATION_DEMO.md) for the official presentation runbook.

## System overview

```text
iCan cane + iCan Eye camera
        |
        | BLE commands + JPEG frames
        v
iOS Flutter app
        |
        +--> Cloud description: Gemini
        +--> Local/offline description: Apple Vision / local VLM / Foundation Models paths when available
        +--> Live cues: periodic iCan Eye frames + on-device analysis
        v
Spoken feedback through iOS TTS
```

Key implementation anchors:

- App live mode: `lib/models/home_view_model.dart`
- Scene-description routing: `lib/services/scene_description_service.dart`
- On-device vision health/fallbacks: `lib/services/on_device_vision_service.dart`
- BLE command protocol: `lib/protocol/ble_protocol.dart` and `protocol/ble_protocol.yaml`
- iCan Eye firmware: `firmware/ican_eye/`

See [`docs/TECHNICAL_OVERVIEW.md`](docs/TECHNICAL_OVERVIEW.md) for a concise architecture map.

## Repository map

- `lib/` — Flutter app source: UI, BLE, voice control, vision routing, TTS, app state.
- `ios/` — iOS runner and native model/service integration.
- `firmware/ican_eye/` — ESP32-S3 camera firmware for iCan Eye BLE capture/live mode.
- `protocol/` — shared BLE protocol notes.
- `test/` — Dart tests for protocol and service behavior.
- `docs/` — official docs, demo notes, verification notes, and internal engineering docs.
- `assets/` — bundled app assets.

Start with [`docs/DOCUMENTATION_INDEX.md`](docs/DOCUMENTATION_INDEX.md) if you are reviewing the project for class, demo, or handoff.

## Current demo positioning

This repo should be presented as an implemented assistive-system prototype, not just a mockup:

- **Primary reliable demo:** cloud-backed scene description through the app.
- **Hardware demo:** BLE-connected iCan Eye capture and live-frame protocol where hardware is available.
- **Local/offline demo:** show the implemented local/offline pipeline and backend health checks; verify exact model availability on the demo device before promising a specific local model path live.
- **Honest fallback:** if object detection or a local model is unavailable, the app degrades to basic/vision-only output and says so.

## Build notes

This is a Flutter/iOS project. Standard development flow is through Flutter and Xcode. Some vision backends depend on device OS version, bundled model files, downloaded local models, API keys, or hardware availability; use the verification docs before a live presentation.
