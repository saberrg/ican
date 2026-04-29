# iCan Eye Reliability Overhaul

One-page reference for the capture/live/description pipeline shipped on
`release/eye-reliability-smolvlm2-build-25`. This is the architecture, not
the story — for context on what this replaced see the PR description.

## Goals

- Describe captures complete without E02 or partial-JPEG failures.
- Live mode survives 60+ seconds with the Eye staying connected.
- Local vision never crashes the app; cloud is the primary path.
- Cloud output is safe, spatial, and speakable in one breath for a blind
  user.

## Capture path

```
App                                   Eye (XIAO ESP32-S3)
 │  CAPTURE / LIVE_START (write)        │
 ├─────────────────────────────────────▶│
 │                                      │  sensors → JPEG (profile FAST)
 │◀───── CAPTURE:START (notify) ────────┤
 │◀───── SIZE:{bytes}  ─────────────────┤
 │◀───── CRC:{hex}     ─────────────────┤
 │◀───── chunk 0   (≤240B payload)  ────┤  (backpressure-aware notify)
 │◀───── chunk 1                        │
 │        …                             │
 │◀───── END:{chunks}  (3×)  ───────────┤
 │
 │  ABORT (write) — optional            │
 ├─────────────────────────────────────▶│
 │◀───── ERR:STREAM_ABORTED:…:user      │
```

- Chunk payload is clamped to
  `EYE_IMAGE_FIRMWARE_PAYLOAD_CAP = 240` bytes regardless of the negotiated
  MTU. Smaller chunks + more of them beat large chunks that saturate the iOS
  ACL queue late in the transfer.
- The Flutter `EyeImageTransferAssembler`
  (`lib/protocol/eye_capture_diagnostics.dart`) owns validation: dedupes
  chunks, tracks missed sequence numbers, validates JPEG magic/end + optional
  end-to-end CRC32, emits `EyeCaptureDiagnostic` on failure.
- `BleService` only marks the Eye "connected" once notifications on image /
  capture-control / instant-text are subscribed AND a STATUS round trip
  succeeds (`BleReadinessPhase.ready`).

## Backpressure algorithm (firmware)

```
sendNotify(handle, data, len):
  if s_congested: waitForCongestionClear(2000 ms)
  for attempt in 0..<40:
    rc = esp_ble_gatts_send_indicate(...)
    if rc == ESP_OK: return ok
    if !clientConnected: return fail
    if s_congested: waitForCongestionClear(500 ms)
    sleep(computeBackoffMs(attempt, rc == ESP_ERR_NO_MEM))
  return fail
```

- `computeBackoffMs` (see `firmware/ican_eye/lib/ble_eye/chunk_math.h`) grows
  from 5 ms up to 50 ms for generic failures and from 20 ms up to 100 ms for
  `ESP_ERR_NO_MEM`. Total retry budget is bounded at ~3.1 s even in the
  worst case.
- Each successful chunk shifts `s_paceMs` by ±1 (bounded [5, 50] ms) so
  sustained streams adapt to the current link quality.
- Every 16 chunks `waitForCongestionClear(200ms)` runs as an unconditional
  drain gap, keeping queue depth low.
- Unit tests live in `firmware/ican_eye/test/test_chunk_math/` and run under
  `pio test -e native`.

## Live-mode state machine

### Firmware (`firmware/ican_eye/src/main.cpp`)

| State         | Set by                  | Exits via                          |
|---------------|-------------------------|------------------------------------|
| `liveMode=F`  | LIVE_STOP, disconnect   | LIVE_START                         |
| `liveMode=T`  | LIVE_START              | LIVE_STOP, disconnect, ABORT       |
| `liveBusy=T`  | just before capture     | after `streamImageViaBle` returns  |

- `lastLiveCaptureMs` is now stamped **after** the stream ends, so the
  `max(300ms, interval/2)` idle gap starts counting from capture completion.
  Back-to-back captures with zero dwell are impossible by construction.
- `LIVE_BUSY` is notified at capture start, `LIVE_IDLE` after END, so the app
  can surface "in flight" state without polling.

### App (`lib/screens/live_detection_screen.dart`)

```
idle → starting → transferring → analyzing → speaking → cooldown → transferring
                                                              │
                                                              ▼
                                           stopping (on disconnect or user stop) → idle
```

- Frames arriving in states other than `transferring` or `cooldown` are
  dropped — no overlapping analyze/speak cycles.
- On Eye disconnect: cancel the in-flight analysis, flush TTS, speak
  "iCan Eye disconnected. Live mode stopped." exactly once (5 s debounce),
  transition to `idle`.
- Stop button / `dispose`: `sendEyeAbort` → `stopLiveCapture` →
  `setEyeProfile(1)`.

## Error codes

| Code        | Where              | Meaning                                                           |
|-------------|--------------------|-------------------------------------------------------------------|
| `Eye E01`   | Flutter diagnostic | Capture command reached Eye but no `CAPTURE:START` / `SIZE` back. |
| `Eye E02`   | Flutter diagnostic | Stream stalled or firmware aborted. Includes sent/expected bytes. |
| `Eye E03`   | Flutter diagnostic | JPEG envelope invalid (missing magic / EOI) or size mismatch.     |
| `Eye E04`   | Flutter diagnostic | CRC32 mismatch between firmware and received bytes.               |
| `Eye E05`   | Flutter diagnostic | Firmware reported `ERR:CAMERA_CAPTURE_FAILED`.                    |
| `Local L00` | Flutter local vis. | JPEG pre-validation rejected bytes before the native channel.     |
| `Local L01` | Flutter local vis. | `MissingPluginException` — native vision channel not registered.  |
| `Local L02` | Flutter local vis. | Apple Vision analysis failed.                                     |
| `Local L20` | Flutter local vis. | SmolVLM2 inference failed or produced no output.                  |
| `Local L30` | Flutter local vis. | Apple Foundation Models failed.                                   |

Each `EyeCaptureDiagnostic` exposes `.stableCode`, `.spokenMessage`, and the
new `.toCopyString()` used by Vision Diagnostic's "Copy Result".

### `ERR:STREAM_ABORTED` wire format

```
ERR:STREAM_ABORTED:{sentChunks}:{sentBytes}:{expectedBytes}[:reason]
```

Only `user` is currently emitted as the reason (response to an `ABORT`
command). Old firmware without ABORT support emits the 3-field form; the
Dart parser tolerates both.

## SmolVLM2 model caching

- Files live in `~/Documents/models/` with `isExcludedFromBackup = true`.
- Each `<modelfile>.gguf` now has a sidecar `<modelfile>.gguf.verified`
  holding `{sha256, size, mtime}` written atomically (`.verified.tmp` →
  `rename`).
- `isFileValid(verifyHash: true)` short-circuits to true when size, mtime,
  and recorded sha256 all match — avoids 20-30 s SHA256 rehashes of the
  ~440 MB text model on every launch.
- Any size mismatch or download resume invalidates the sidecar; a crash
  mid-write cannot wedge future launches because the atomic rename only
  publishes a fully-written JSON.

## Cloud prompt contract

- One opinionated `ScenePromptBuilder`:
  - Hazards first (stairs/edges, moving vehicles, approaching pedestrians,
    wet/glass/overhead, within-reach).
  - Clock positions 12/3/9 with depth buckets: within reach, a few steps,
    several steps, far.
  - Verbatim visible text.
  - Walkable path / doors / openings last.
  - One breath, < 60 words, no markdown / "I see" / "the image shows" /
    "previous response" / "cut off" / "as an AI".
- Default user prompt: *"What does a blind user need to know right now to
  move and stay safe? Speak it in one breath."*
- `_stripCloudMetaText` rejects sentences containing any of the banned
  meta-phrases; the rest of the output still ships to TTS so failures stay
  soft.

## Tests that gate the acceptance criteria

- `firmware/ican_eye/test/test_chunk_math/` — chunk-math helpers.
- `test/protocol/eye_capture_diagnostics_test.dart` — assembler state,
  error parsing, `toCopyString` goldens.
- `test/services/ble_service_test.dart` — abort path resets assembler,
  heartbeat, command-path readiness.
- `test/services/on_device_vision_service_test.dart` — JPEG pre-validation
  never crosses the native channel.
- `test/services/scene_prompt_builder_test.dart` — must/must-not-contain
  goldens for the system prompt.
- `test/services/scene_description_service_test.dart` — continuation
  retries, meta-text stripping, auto-mode local fallback.

## Real-device acceptance (required before ship)

Record in the PR body:

- iPhone model + iOS version, Eye board serial, firmware commit SHA.
- 3 × Describe captures — no E02, no partial JPEG, useful spoken output.
- 1 × Live session ≥ 60 s at default interval — Eye stays connected, no
  overlapping cycles, TTS never truncated.
- Force a disconnect mid-session — app speaks the diagnostic once, then
  reconnects cleanly.
- Second launch with SmolVLM2 already downloaded — no progress bar, "Check
  Local Stack" shows ready < 1 s.
