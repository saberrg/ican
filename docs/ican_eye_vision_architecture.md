# iCan Eye — Modular Vision Architecture
*Last updated: 2026-04-12*

---

## System Overview

The iCan Eye implementation is designed to convert a Bluetooth streamed JPEG from the ESP32 S3 camera into a spoken scene description for a blind or visually impaired user. Gemini cloud is the strongest demonstrated vision path. Local execution paths are implemented, but availability depends on the bundled models, native runtime health, and physical device verification.

```
iCan Eye (ESP32-S3)  ──BLE──►  Flutter App  ──►  Spoken description (TTS)
     OV2640 JPEG                  4-layer pipeline
```

---

## The 4-Layer Pipeline

```
JPEG bytes (from BLE)
        │
        ▼
┌────────────────────────────────────────────┐
│  LAYER 1 · Perception  (<100ms total)      │
│  Runs always — three analyzers in parallel │
│                                            │
│  • Apple Vision Framework                  │
│    - VNRecognizeTextRequest  (OCR)         │
│    - VNClassifyImageRequest  (scene type)  │
│    - VNDetectHumanRectanglesRequest        │
│                                            │
│  • Depth Anything V2 Small (CoreML)        │
│    - Apple-provided .mlpackage (~19 MB)    │
│    - Device measurement not recorded here  │
│    - Full monocular depth map              │
│                                            │
│  • YOLOv3 Tiny (CoreML)                   │
│    - Apple-provided .mlmodel  (~35 MB)     │
│    - 80 object classes, real-time          │
│    - Bounding boxes fused with depth map   │
│      → clock positions + distance tiers    │
└────────────────┬───────────────────────────┘
                 │ PerceptionResult
                 │ {scene, people, text,
                 │  spatialObjects[], depthMap}
                 ▼
┌────────────────────────────────────────────┐
│  LAYER 2 · Understanding (VLM)             │
│  Holistic image grasp — selects best path  │
│                                            │
│  Path A · Moondream CoreML  (Phase 2)      │  ◄── PIONEER (future)
│    - Captioning, Pointing (x,y), VQA       │
│    - MoondreamVisionEncoder.mlpackage      │
│    - MoondreamTextDecoder.mlpackage        │
│    - JIT-loaded separately (no weight dup) │
│    - Mixed-Bit Palettization: 4-bit bulk,  │
│      8-bit on pointing output layers       │
│                                            │
│  Path B · SmolVLM via llama.cpp            │  ◄── current fallback
│    - Existing LlamaService.swift           │
│    - ~800 MB, Metal GPU                    │
└────────────────┬───────────────────────────┘
                 │ Token stream
                 ▼
┌────────────────────────────────────────────┐
│  LAYER 3 · Synthesis (Apple Foundation     │
│  Models, iOS 26+)                          │
│                                            │
│  Input:  ALL structured data from L1 + L2  │
│  Output: Coherent clock-position narrative │
│                                            │
│  Runtime availability check required.      │
│  Falls back to enhanced template on        │
│  unsupported devices.                      │
└────────────────┬───────────────────────────┘
                 │ Sentence-split text stream
                 ▼
┌────────────────────────────────────────────┐
│  LAYER 4 · Speech                          │
│  AVSpeechSynthesizer                       │
│  Sentence-split streaming, BT A2DP routing │
└────────────────────────────────────────────┘
```

---

## Backend Selection (Dart — SceneDescriptionService)

```
User presses capture
        │
        ▼
 VisionMode == cloudOnly? ──Yes──► Cloud (Gemini)
        │ No
        ▼
 VisionMode == auto && online? ──Yes──► Cloud (Gemini)
        │ No (offline or offlineOnly)
        ▼
 Foundation Models available? ──Yes──► foundationModels backend
        │ No                            (Layer 1 + L3 synthesis)
        ▼
 SmolVLM loaded? ──Yes──► vlm backend (Layer 1 + SmolVLM)
        │ No
        ▼
 SmolVLM ready (on disk)? ──Yes──► load it ──► vlm backend
        │ No
        ▼
 visionOnly backend (Layer 1 template)
```

**Backend enum:** `cloud | foundationModels | vlm | visionOnly`

---

## Depth + Pointing Fusion — The Core Innovation

Depth Anything V2 provides a full depth map. YOLOv3 (and later Moondream Pointing) provide object locations as (x, y) coordinates. Fused:

```
YOLOv3:    "person"  → bbox center (0.48, 0.51) → clock: 12
Depth map: sample at (0.48, 0.51)               → relativeDepth: 0.22 → "very close"

Spoken:    "A person is directly ahead, very close."
           "A bicycle is at 2 o'clock, nearby."
           "EXIT sign at 11 o'clock, far."
```

Clock mapping: `x ∈ [0, 1]` → `[9, 10, 11, 12, 1, 2, 3]` (left=9, center=12, right=3)

Depth tiers: `0–0.30 → "very close"` | `0.30–0.50 → "close"` | `0.50–0.70 → "ahead"` | `0.70+ → "far"`

---

## iOS File Structure

```
ios/Runner/
├── EyePipeline/                         ← NEW (Phase 1)
│   ├── SceneContext.swift               ← SpatialObject, PerceptionResult data models
│   ├── DepthEstimator.swift             ← Depth Anything V2 CoreML wrapper
│   ├── ObjectDetector.swift             ← YOLOv3 Tiny CoreML wrapper
│   ├── PerceptionLayer.swift            ← Orchestrates L1: async concurrent execution
│   └── FoundationModelSynthesizer.swift ← Apple Foundation Models (iOS 26+)
│
├── LlamaService.swift                   ← SmolVLM via llama.cpp (existing)
├── ModelDownloadManager.swift           ← HuggingFace download manager (existing)
├── OnDeviceVisionChannel.swift          ← Flutter↔Swift bridge (updated)
└── VisionService.swift                  ← Apple Vision Framework (existing)
```

**Note:** Add `ios/Runner/EyePipeline/` folder to Xcode project via
*File → Add Files to "Runner"* (or drag the folder into Xcode Navigator).

---

## Dart File Structure

```
lib/services/
├── scene_description_service.dart   ← Backend selector + synthesis (updated)
├── on_device_vision_service.dart    ← Platform channel client (updated)
├── ble_service.dart                 ← BLE + image reassembly (unchanged)
├── vertex_ai_service.dart           ← Gemini cloud (unchanged)
└── connectivity_service.dart        ← Internet check (unchanged)
```

---

## CoreML Models Required (Phase 1)

Both are free from Apple's ML models page. Run `scripts/download_coreml_models.sh` to download, then add to Xcode project.

| Model | File | Size | Source |
|---|---|---|---|
| Depth Anything V2 Small | `DepthAnythingV2SmallF16P6.mlpackage` | ~19 MB | Apple ML Models |
| YOLOv3 Tiny | `YOLOv3Tiny.mlmodel` | ~35 MB | Apple ML Models |

---

## Phase 2 — Moondream CoreML (Pioneer Work)

### Architecture
Two separate `.mlpackage` files loaded JIT (Apple's Stable Diffusion pattern):
- `MoondreamVisionEncoder.mlpackage` — static CoreML, `torch.jit.trace` on `(1, 3, 378, 378)` input
- `MoondreamTextDecoder.mlpackage` — stateful CoreML (`MLState` KV cache, iOS 18+)

### Conversion Strategy
- Load Moondream 0.5B from HuggingFace (`trust_remote_code=True`)
- Use **dynamic sequence length shapes** (avoids static-shape attention OOM — coremltools Issue #2590 / PR #2636)
- Apply **Mixed-Bit Palettization**: 4-bit for bulk transformer layers, 8-bit for final projection (pointing output) layers
- Target: ~200–250 MB total vs 800 MB for SmolVLM Q8_0

### Validation Gate
Before accepting any quantization, run `scripts/validate_moondream_quantization.py`:
- Compare pointing (x, y) coordinate outputs of F16 reference vs quantized model on 20 test images
- Reject if mean coordinate delta > 0.05 (normalized), fall back to 6-bit global

### Key Risk Mitigations
| Risk | Mitigation |
|---|---|
| Static-shape attention OOM (Issue #2590) | Use dynamic shapes in `ct.convert()` |
| 4-bit pointing degradation | 8-bit on output projection layers via MBP |
| Multifunction weight duplication | Separate .mlpackage files, not multifunction |
| Foundation Models unavailability | Runtime check; graceful fallback to template |

---

## System Prompt (Shared Across All Backends)

```
You are the vision system for a blind person wearing a chest camera.
Speak in plain, conversational English — no markdown, no bullet points.
Describe the scene in 4–6 sentences:
1) WHERE you are (room type, indoor/outdoor, setting)
2) SAFETY: obstacles, steps, edges, vehicles, people (use clock positions: 9=left, 12=ahead, 3=right)
3) DIRECTLY AHEAD and within arm's reach
4) Read any visible text verbatim
5) Notable objects, colors, landmarks for orientation
Be specific and spatial. Never say "I see" — describe as if you are the person's eyes.
```

---

## Apple CoreML Models Considered

The design considers Depth Anything V2 Small, YOLOv3 Tiny, DETR ResNet50, and DeepLabv3 for local perception. The repository does not contain a checked in device receipt that proves latency or availability for these models inside the iCan application. Treat the model list as planned or optional integration work rather than a project benchmark.

---

## Resources

- Moondream HuggingFace: https://huggingface.co/vikhyatk/moondream2
- Moondream 2B GGUF: https://huggingface.co/ggml-org/moondream2-20250414-GGUF
- Apple CoreML Models: https://developer.apple.com/machine-learning/models/
- Apple Foundation Models (WWDC25): https://developer.apple.com/videos/play/wwdc2025/286/
- coremltools stateful models: https://apple.github.io/coremltools/docs-guides/source/stateful-models.html
- coremltools Issue #2590 (static-shape OOM): https://github.com/apple/coremltools/issues/2590
- Depth Anything V2 paper: https://arxiv.org/abs/2406.09414
