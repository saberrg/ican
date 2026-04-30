# iCan Agent Brain

Use this document as the source of truth for any Codex or coding agent taking over the iCan project.

## User Standard

The user wants a sharp, technical, high-agency developer/PM.

Communication rules:
- Be direct.
- Give the next step clearly.
- Do not drown the user in generic explanation.
- Do not say the app works unless it is verified.
- Do not ship weak placeholder behavior and call it innovation.
- Ask specific questions only when blocked.
- Prefer action over planning loops.
- Use tests and verification, not eyeballing.
- Treat the demo like a high-stakes product pitch.

Tone:
- Precise.
- Results-oriented.
- No filler.
- No vague optimism.
- If something is broken, say exactly what is broken and what fixes it.

## Product Vision

iCan is an assistive app centered on the iCan Eye.

## April 2026 Repair Batch

- Startup always routes to Home for the demo; persisted caretaker role is ignored at splash.
- Describe attempts persist `DescribeAttemptTrace` breadcrumbs so the next Home launch can surface the last unfinished stage.
- Auto vision mode is Gemini cloud first. Local/native fallback runs only after native channel and Apple Vision health checks pass.
- Eye readiness means services are discovered and image, control, and instant-text notifications are subscribed.
- Future agents must use `AGENTS.md` for workstream ownership and `docs/regression_matrix.md` for gates before TestFlight.

The core demo must prove:
- The user can talk to the app.
- The app changes real behavior from voice commands.
- The iCan Eye describes the world in a user-tuned way.
- Local/offline vision is advanced, Apple-native, and real.
- The UI feels modern, calm, and Apple-like.

The product should feel like:
> "I can speak to my assistive vision system, and it instantly adapts how it sees for me."

## Demo Spine

This is the main demo path. Everything else is secondary.

1. App launches with polished iCan splash.
2. Home opens as a command center.
3. Home shows:
   - Eye connection state.
   - Voice command state.
   - Current focus mode.
   - Detail mode.
   - Live verbosity.
   - Vision backend: Auto / Cloud / Local / Local unavailable.
4. User taps `Start Voice Command`.
5. User says: `only tell me hazards`.
6. App visibly changes:
   - Focus: Safety.
   - Detail: Brief.
   - Live: Minimal.
7. App audibly confirms the change.
8. User captures/describes a scene.
9. Description follows the new setting.
10. User says `read signs first` or `use local model`.
11. App changes mode truthfully.
12. If offline AI is unavailable, the app says exactly what is missing.

## Non-Negotiables

- No fake "local AI works" claim.
- No hidden broken dependencies.
- No weak placeholder routes in the demo path.
- No manual-only validation when automated tests are possible.
- No broad refactors unless needed to pass a demo-critical gate.

## Current Project State

Repo:
- `C:\Users\17733\ican`

Important docs:
- `docs/demo_execution_control.md`
- `docs/agent_brain.md`

Current verification:
- `.\scripts\agent_verify.ps1 -SkipPubGet` passes.
- Tests increased from 8 to 22.
- Analyzer still reports many info-level lints. These do not currently fail the default gate.

Implemented:
- `VoiceControlService`.
- Self-tuning settings:
  - Speech speed.
  - Volume.
  - Prompt profile.
  - Detail level.
  - Live verbosity.
  - Vision mode.
- Home voice command button.
- Home voice state display:
  - Ready.
  - Listening.
  - Processing.
  - Partial transcript.
  - Last result.
- Home mode chips:
  - Focus.
  - Detail.
  - Live.
  - Vision.
- Hardware-free tests for:
  - Voice control parser/actions.
  - Voice command orchestration.
  - Home voice UI.
  - BLE protocol packets.

Known weak points:
- Real iPhone microphone flow is not manually verified yet.
- Real Eye BLE capture is not manually verified yet.
- BLE image assembly still accepts some partial/truncated frames.
- Gemma LiteRT-LM iOS runtime still needs a real iPhone/Xcode link validation.
- YOLO/depth Core ML assets are not proven in the Xcode Runner target.
- Standalone live detection may fail if object detection model is missing.
- Caretaker contact is not a real tested flow.
- GPS/navigation routes are weak/demo-unready.

## MCP and Skills

Configured MCPs:

```toml
[mcp_servers.openaiDeveloperDocs]
url = "https://developers.openai.com/mcp"

[mcp_servers.context7]
url = "https://mcp.context7.com/mcp"
```

After Codex restart, use:
- OpenAI docs MCP for OpenAI API/model/prompt questions.
- Context7 for current library/framework docs.
- Web search for fast-moving Apple/Core ML/local-model research, using primary sources when possible.

Custom local skills exist under:
- `C:\Users\17733\.codex\skills\ican-demo-pm`
- `C:\Users\17733\.codex\skills\ican-eye-ble`
- `C:\Users\17733\.codex\skills\ican-flutter-tdd`
- `C:\Users\17733\.codex\skills\ican-prompt-eval`
- `C:\Users\17733\.codex\skills\ican-ui-wow`
- `C:\Users\17733\.codex\skills\ican-voice-control-plane`

The skill files were fixed to use valid frontmatter and UTF-8 without BOM.

## Agent Operating Mode

Act as:
- Program manager.
- Senior Flutter/iOS engineer.
- Test lead.
- Local AI/offline vision architect.

Use sub-agents when useful:
- Explorer agents for codebase audits.
- Worker agents for disjoint implementation slices.
- Test agents for verification gaps.

Do not hand off the immediate critical-path task if you are blocked waiting for it.

Each worker must get:
- Exact repo path.
- Write scope.
- What not to touch.
- Acceptance test.
- Required verification command.

## Workstreams

### Workstream A: Voice Command Center

Goal:
Voice commands are demoable without Eye hardware and mutate real app behavior.

Status:
Mostly implemented.

Next:
- Add better visual command result polish.
- Add exact voice command examples in Help/Home if useful.
- Make caretaker command either real or remove from accepted demo path.

### Workstream B: Eye BLE Reliability

Goal:
Eye capture is reliable and tested.

Next tasks:
1. Add image assembly tests.
2. Require complete expected size or JPEG EOI before emitting.
3. Reject truncated/corrupt frames.
4. Verify `CAPTURE`, `LIVE_START`, `LIVE_STOP`, and `BUTTON:DOUBLE`.

Acceptance:
- Ordered chunks produce valid JPEG.
- Duplicate chunks do not corrupt JPEG.
- Missing/out-of-order/truncated frames are handled truthfully.

### Workstream C: Local Offline Vision

Goal:
Local mode is impressive and real.

Target architecture:
1. Cloud-first Describe:
   - Gemini remains primary in Auto.
2. Local Describe:
   - Gemma 4 E2B through Google AI Edge LiteRT-LM on iPhone.
   - Fail closed until runtime, model hash, readiness, and self-test pass.
3. Live perception:
   - Apple Vision/Core ML object/depth/OCR remain separate from Describe.
4. Truthful backend display:
   - Local: Gemma 4 E2B.
   - Cloud: Gemini.
   - Local unavailable: missing runtime/model/readiness.

Next tasks:
1. Link the Google AI Edge LiteRT-LM iOS runtime in Runner.
2. Verify the pinned `.litertlm` model downloads and hash-checks on device.
3. Run Gemma readiness/self-test on real iPhone hardware.
4. Record first-token latency and memory behavior.
5. Keep app status exact when local is unavailable.

Do not settle for template-only as the final local story.

### Workstream D: UI Wow

Goal:
Home feels like a polished Apple-style assistive command center.

Next tasks:
1. Make Home visually cleaner.
2. Preserve accessibility.
3. Hide weak routes:
   - Nav.
   - GPS.
   - Caretaker role unless tested.
4. Keep splash strong.
5. Add widget tests for key states.

### Workstream E: Verification

Goal:
No false confidence.

Required command:

```powershell
.\scripts\agent_verify.ps1 -SkipPubGet
```

Optional offline check:

```powershell
.\scripts\agent_verify.ps1 -SkipPubGet -OfflineVision
```

Do not block on strict analyzer lint debt unless asked. Default gate ignores info-level lints.

## Immediate Next Step

Do this next:

1. Audit local/offline iOS stack.
2. Produce exact artifact list:
   - Present files.
   - Missing files.
   - Xcode-linked files.
   - Runtime-risk files.
3. Decide strongest local path:
   - Link Google AI Edge LiteRT-LM for iOS.
   - Verify Gemma 4 E2B `.litertlm` model download.
   - Wire backend status into UI.
4. Then implement Eye image validation tests/fixes.

Reason:
Voice demoability is now in place. The biggest remaining "wow or fail" risk is local/offline vision credibility.

## Fresh Agent Prompt

Use this prompt when starting a new Codex session:

```text
You are taking over the iCan project as program manager and senior developer.

Read first:
- C:\Users\17733\ican\docs\agent_brain.md
- C:\Users\17733\ican\docs\demo_execution_control.md

Repo:
- C:\Users\17733\ican

My standards:
- Be direct.
- Do not over-explain.
- Give me the next action clearly.
- Do not claim the app works unless verified.
- I want a wow demo, not weak placeholder behavior.
- Use sub-agents when useful.
- Use tests and verification.
- Use current docs/web/MCP for fast-moving local AI, Apple, Core ML, and model tooling.

Your immediate task:
Take control and continue from the current state.
Start by auditing the local/offline iOS vision stack:
- Gemma LiteRT-LM runtime linkage.
- Core ML model assets.
- Foundation Models path.
- Gemma 4 E2B model download/hash status.
- Xcode target linkage.
- What is missing.
- What is actually demoable.

Then propose and execute the next smallest implementation batch that makes local/offline vision truthful and impressive.

Before editing:
- Inspect files.
- State the concrete patch you will make.

After editing:
- Run .\scripts\agent_verify.ps1 -SkipPubGet.
- Report exact result and next blocker.
```
