# iCan Documentation Index

This page is the official starting point for reviewers, teammates, and demo prep. It separates presentation-facing docs from internal agent/planning notes so the repo is easier to scan.

## Read first

- [`../README.md`](../README.md) — project summary, current capabilities, and repo map.
- [`PRESENTATION_DEMO.md`](PRESENTATION_DEMO.md) — clean demo script and presenter checklist.
- [`TECHNICAL_OVERVIEW.md`](TECHNICAL_OVERVIEW.md) — concise architecture map for the app, BLE Eye, live vision, local/offline vision, and cloud routing.

## Verification and technical references

- [`OFFLINE_VISION_VERIFICATION.md`](OFFLINE_VISION_VERIFICATION.md) — backend-by-backend checks for Gemini, Foundation Models, local VLM, and vision-only fallback.
- [`ican_eye_vision_architecture.md`](ican_eye_vision_architecture.md) — deeper vision architecture notes.
- [`regression_matrix.md`](regression_matrix.md) — regression areas and manual test matrix.
- [`release_pipeline.md`](release_pipeline.md) — release/TestFlight pipeline notes.
- [`testflight_logging_runbook.md`](testflight_logging_runbook.md) — logging notes for TestFlight runs.

## Internal / planning docs

These are useful for engineering history but should not be the first documents shown in a class presentation:

- [`demo_execution_control.md`](demo_execution_control.md) — internal demo sprint/control notes.
- [`agent_brain.md`](agent_brain.md) — agent-oriented implementation context.
- Root-level agent handoff files such as `AGENTS.md`, `AGENT_HANDOFF.md`, and `QA_TECHNICAL_BRIEFING.md` are internal engineering references, not the official project narrative.

## Source-of-truth guidance

- For what the app is supposed to demonstrate, use `README.md` and `PRESENTATION_DEMO.md`.
- For how the system is wired, use `TECHNICAL_OVERVIEW.md`.
- For exact current behavior, verify against source files under `lib/`, `protocol/`, and `firmware/ican_eye/`.
- Do not describe local/offline or live vision as future-only. They have implemented code paths; the correct caveat is that exact model/backend availability must be verified on the demo device.
