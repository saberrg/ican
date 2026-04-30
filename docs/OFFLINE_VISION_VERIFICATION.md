# Offline Vision Backend Verification

Use the hidden Vision Diagnostic screen to test each backend in isolation.

Access: Settings > About > long-press the Version row.

The diagnostic screen can use a phone photo instead of an iCan Eye capture:
tap Pick Test Photo, choose an image from Photos, then run diagnostics. The
Gemma readiness probe will use that selected image until another image is
chosen or the screen is rebuilt.

## Describe Backends

### 1. Cloud Gemini

| Item | Detail |
|------|--------|
| Prerequisites | Internet connection, valid `API_KEY` injected via `--dart-define` |
| Expected first-token latency | 500-1500 ms, depending on network and model tier |
| Known failure modes | `API_KEY not set`, HTTP 401/403/429, timeout, malformed or empty cloud response |

### 2. Gemma 4 E2B LiteRT-LM

| Item | Detail |
|------|--------|
| Prerequisites | iPhone build with Google AI Edge LiteRT-LM runtime linked, `gemma-4-E2B-it.litertlm` downloaded and SHA-verified |
| Expected first-token latency | Must be measured on a real iPhone after the LiteRT-LM runtime is linked |
| Known failure modes | Runtime not linked, model not downloaded, SHA/size mismatch, insufficient memory, native inference error, empty token stream |

Gemma is the only local Describe backend. Offline-only mode fails closed when Gemma readiness has not passed. Auto mode remains cloud-first and only falls back to Gemma after cloud failure plus native/local readiness.

## Live Perception

Live detection still uses the native iOS perception stack separately from Describe:

| Item | Detail |
|------|--------|
| Apple Vision | OCR, scene classification, person rectangles |
| Core ML assets | Object/depth models if present in the iOS target |
| Failure behavior | Live falls back or reports a local diagnostic; it is not a Describe substitute |

## General Notes

- Pick a well-lit indoor photo with readable text and at least one object.
- Run each backend 2-3 times; first run often includes model load overhead.
- The diagnostic screen bypasses the fallback chain. If a backend fails, it reports the failure instead of silently using another backend.
- Use Copy Result to capture timing, backend status, and output for bug reports.
- Do not claim Gemma device validation until a real iPhone build links LiteRT-LM and produces non-empty model output.
