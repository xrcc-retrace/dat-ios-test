# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working in this repository.

## Project Overview

**Retrace iOS App** — the phone client for Retrace, an AI coaching system built for the XRCC Berlin 2026 hackathon.

> One-liner: "Record an expert once. Coach every learner forever."

This app started life as Meta's `CameraAccess` sample for the Wearables Device Access Toolkit (DAT) SDK and has been extended into the full Retrace phone client. The phone is the orchestrator in Retrace's three-tier stack:

```
Glasses / iPhone Camera  ↔  Phone (this app)  ↔  Server
                                    │
                                    ↕  (direct WebSocket, voice + video)
                               Gemini Live API
```

- Streams camera + microphone from **Ray-Ban Meta glasses** (via the DAT SDK) **or the iPhone itself** — user picks the capture transport per-session.
- Talks to the Retrace backend for procedure storage, step clips, and session lifecycle.
- Opens a **direct** Gemini Live WebSocket for voice coaching using an ephemeral token the server mints — audio and video never route through the backend.

The backend server lives in a separate repo (`main-local-server-test`). See the App Flow section for how the two talk.

## Prerequisites

- iOS 17.0+, Xcode 15+
- The Retrace backend running on the same Wi-Fi
- A Meta developer account with Developer Mode enabled, plus the Meta AI app installed (for DAT SDK registration)
- Ray-Ban Meta glasses are **optional** — `MockDeviceKit` works without hardware in DEBUG builds, and the full app runs end-to-end on iPhone alone.

## Build & Run

```bash
open samples/CameraAccess/CameraAccess.xcodeproj
```

1. Select your team and a run destination.
2. Build & run (`Cmd+R`).
3. (Optional) Tap **Connect my glasses** to hand off to the Meta AI app for DAT registration. Or skip — the app works iPhone-only.
4. Pick **Expert Mode** or **Learner Mode** from the mode selection screen.

### Server discovery

The app runs an `NWBrowser` on Bonjour (`_retrace._tcp`) and auto-discovers the backend when it's on the same Wi-Fi. A "Server Connected" toast appears on discovery. Manual override lives behind the gear icon on the mode selector (**Server Settings**) — stored in `UserDefaults` under `"serverBaseURL"`. Default fallback: `http://192.168.1.100:8000`.

### Mock device (no glasses required)

Debug builds include `MockDeviceKit`. Use the in-app debug menu (shake-gesture overlay) to pair a simulated Ray-Ban Meta. XCUITests with `--ui-testing` auto-pair `MockRaybanMeta` with bundled `plant.mp4` / `plant.png` resources.

## TestFlight deployment

Releases are fully automated. **A `v*` git tag pushed to `origin` triggers a GitHub Actions workflow that archives, signs, uploads to App Store Connect, and lands the build in TestFlight ~12-20 min later.** No Xcode UI, no Organizer, no manual signing.

### To ship a TestFlight build

When the user says "push to TestFlight" / "ship a TestFlight build" / "release a build", run:

```bash
cd dat-ios-test
git fetch --tags origin
git tag --sort=-v:refname | head -5    # find the latest v* tag
git tag vX.Y.Z                         # bump patch unless told otherwise
git push origin vX.Y.Z
```

That's the entire release process. The user does not need to open Xcode or App Store Connect for a routine build.

Manual fallback: GitHub Actions UI → **TestFlight Deploy** → **Run workflow** (button on the right). Useful if a tag was pushed but never triggered (rare).

### What runs in CI

- **Workflow:** `.github/workflows/testflight.yml`, runs on `macos-latest` with `latest-stable` Xcode (matches local Xcode 26.x)
- **Fastlane:** `samples/CameraAccess/fastlane/Fastfile`, `deploy` lane
- **Signing:** Fastlane `match` (readonly) pulls encrypted certs from the private repo `xrcc-retrace/ios-signing-certs`. Distribution cert + provisioning profile (`match AppStore com.xrcc.retrace.ios.v1`).
- **Code signing override:** `update_code_signing_settings` flips the project to `CODE_SIGN_STYLE = Manual` + `CODE_SIGN_IDENTITY = Apple Distribution` in the CI workspace only (local `project.pbxproj` is untouched, stays on Automatic for Xcode UI builds).
- **Build number:** auto-incremented from `latest_testflight_build_number(app_identifier:) + 1`. Never manually bumped.
- **Upload:** App Store Connect API key (`ASC_KEY_ID` / `ASC_ISSUER_ID` / `ASC_PRIVATE_KEY` GitHub Secrets). The Apple ID password never enters CI.

### App identity

- **Bundle ID:** `com.xrcc.retrace.ios.v1`
- **Team ID:** `V56DG94ZL5`
- **App Store Connect record:** Retrace, SKU `retrace-ios-2026`

### External testers DO NOT auto-receive new builds

Each tag-triggered build lands in App Store Connect's TestFlight tab and waits there. To distribute to external testers, you (the human) must manually:

1. App Store Connect → Retrace → TestFlight → External Testing → group → **Add Build**
2. First build to a group requires Beta App Review (~24-48 hr)

This is intentional. Pushing tags is safe — it cannot accidentally distribute to judges or beta testers without an explicit click in App Store Connect. There is an "Automatic Distribution" toggle in the External Testing group settings that would change this; **leave it off**.

### Required Build Phase: "Patch MediaPipeTasksVision Info.plist"

The `SwiftTasksVision` SPM package's `MediaPipeTasksVision.framework` ships with a malformed `Info.plist` (missing `CFBundleVersion`, `CFBundleShortVersionString`, `MinimumOSVersion`). App Store validation rejects any build containing it. The Run Script Build Phase positioned **after** Embed Frameworks patches the plist and re-signs the framework. Do not delete or reorder this build phase — every TestFlight build needs it.

### Common failure modes

- **Tag pushed but no workflow ran** → tag was created but not pushed; verify with `git ls-remote --tags origin`. Or push the tag again.
- **"No matching provisioning profile"** in CI → match cert was revoked or the certs repo was wiped. Locally run `bundle exec fastlane match appstore` to regenerate.
- **"Build number must be greater than..."** → ASC and the workflow disagree on the latest build number. Re-running the same tag fixes it (the increment fetches fresh ASC state).
- **Beta App Review rejection** → external testing only. Iterate the build, push a new tag, and resubmit.

## App Flow

```
AppLaunch ──► Wearables.configure() + BonjourDiscovery.start
                         │
                         ▼
                  ModeSelectionView  ◄─── Server Settings (gear) ─── glasses pair/unpair
                         │
        ┌────────────────┴─────────────────┐
        ▼                                  ▼
  Expert Mode                         Learner Mode
  (ExpertTabView)                     (LearnerTabView)
        │                                  │
  ┌─────┴─────┐                  ┌─────────┼────────────┐
  ▼           ▼                  ▼         ▼            ▼
 Record ───► Review ───► Upload  Discover  Library / Progress / Profile
  │                        │       │         │
  │ Transport:             │       └──► LearnerProcedureDetail ──► Coaching
  │  .glasses / .iPhone    │                                          │
  │                        ▼                                          ▼
  │            POST /api/expert/upload              POST /api/learner/session/start
  │            (returns 202, poll /procedures/{id})      │
  │                                                      ├── ephemeral Gemini token
  │                                                      ├── direct Live WebSocket
  └──► (see Capture transports below)                    └── tool calls → /tool-call
```

### Expert Mode

Record a procedure end-to-end from the glasses or the iPhone, review the raw capture, then upload. The upload returns `202`; the app polls procedure status (`processing` → `completed` / `completed_partial` / `failed`) until Gemini finishes generating the SOP. `ProcedureEditView` + `StepEditView` let you rewrite titles, descriptions, tips, warnings, and step order before sharing.

### Learner Mode

- **Discover** — all procedures from the server.
- **Library** — saved + in-progress procedures, tracked locally via `LocalProgressStore`.
- **Progress** — session history (completed / abandoned / in-progress).
- **Profile** — voice picker with audio previews fetched from the server (`/api/learner/voices`), plus an auto-advance toggle.
- **Coaching** — the headline flow. Gemini Live voice coaching with PiP reference-clip overlay, activity feed (learner transcripts, AI replies, tool calls), mute, and live connection status.
- **Troubleshoot** (`Views/Troubleshoot/`) — Parallel Live session backed by `/api/troubleshoot/*`. `TroubleshootSessionView` + `DiagnosticSessionViewModel` orchestrate the diagnose-then-coach flow: user describes a broken product, Gemini issues `identify_product` → `confirm_identification`, then `search_procedures`; on no-match the model calls `web_search_for_fix` (returns a procedure with cited sources) and finally `handoff_to_learner` to spawn a normal coaching session. Includes `DiagnosticPhaseBar`, `DiagnosticResolutionPanel`, `ManualUploadSheet`, `TroubleshootConfirmOverlay`, `TroubleshootPageHandler`, and HUD `Pages/`.

### Onboarding

`Views/Onboarding/` (container + Screens + Components) handles first-launch — permissions, capture-transport pick, and a quick orientation. Skip-on-launch logic is keyed off `UserDefaults`.

### Hand tracking

`HandTracking/` is the gesture substrate for the Ray-Ban HUD's hover-then-select pattern. Composed of:

- `HandLandmarkerService` — wraps Apple Vision (or MediaPipe-style) hand-pose extraction.
- `HandGestureService` — high-level state machine (`hover`, `select`, `idle`).
- `MicroGestureRecognizer` + `PinchDragRecognizer` — concrete recognizers fed by the landmarker.
- `HandTrackingConfig` — tuning knobs (smoothing, hysteresis, pinch thresholds).
- `HandGestureDebugStack` — debug overlay; toggled from the Debug Menu.
- `HandLandmarkFrame` — the per-frame data bag the recognizers consume.

The HUD reads `HandGestureService.$state` to drive focus rings, the recede-and-arrive overlay, and hold-to-confirm. Coaching and troubleshoot sessions both consume it; recording paths don't (yet).

## Capture transports

`Models/CaptureTransport.swift` — `enum CaptureTransport { case glasses, iPhone }`. The user picks per-session. Both recording and coaching honor it end-to-end.

### Glasses path

- DAT SDK `StreamSession` via `wearables.createSession(deviceSelector:)` → `deviceSession.addStream(config:)` (0.6 API; `StreamSession` has no public init, it's attached as a capability to a `DeviceSession`).
- `AutoDeviceSelector` picks the best paired device.
- Audio flows through BT HFP.

### iPhone path

- `Utils/IPhoneCameraCapture.swift` wraps `AVCaptureSession` (720×1280 portrait — matches the glasses stream geometry so the writer settings work unchanged).
- `ViewModels/IPhoneExpertRecordingViewModel.swift` drives the recording path.
- `ViewModels/IPhoneCoachingCameraSource.swift` throttles sample buffers to ≈0.5 fps JPEG for the coaching path, matching the glasses frame rate so the token budget is the same.
- Audio is forced onto the built-in mic + loudspeaker.

### AudioSessionManager modes

`Utils/AudioSessionManager.swift` has four modes — the VM picks one based on transport + activity:

| Mode | Purpose |
|---|---|
| `.coaching` | Full-duplex with AEC, speaker fallback. Prefers BT HFP glasses if paired. |
| `.coachingPhoneOnly` | Full-duplex with AEC, forced built-in mic + loudspeaker. Used when `.iPhone` transport — ignores HFP even if glasses are paired. |
| `.recording` | Simplex capture, no playback, no AEC. Expert recording via glasses (HFP) or iPhone mic fallback. |
| `.recordingPhoneOnly` | Simplex capture, forced built-in mic. iPhone-native expert recording — ignores HFP. |

## Gemini Live client

`Services/GeminiLiveService.swift` is a `@MainActor ObservableObject` that opens the direct WebSocket, drives the wire protocol, and surfaces callbacks. Notable behavior:

- **Wire endpoint** — `BidiGenerateContentConstrained` (v1alpha ephemeral-token variant). This endpoint delivers JSON control messages as **binary** WebSocket frames (UTF-8 encoded `{...}` bytes, not text frames). The service sniffs the first byte of each binary frame before deciding between JSON parsing and raw PCM audio playback.
- **Setup handshake** — after `didOpenWithProtocol`, sends `{"setup": {}}` as the very first frame (required; config is already baked into the ephemeral token). `.connected` flips only after `setupComplete` arrives, so the audio send gate can't open before Gemini is ready.
- **Send gate** — per-buffer gate with three inputs: mic muted, a pending tool call, or Gemini not ready. Logged only on OPEN / CLOSED transitions, not per buffer.
- **Session resumption** — persists `sessionResumptionUpdate.new_handle`. On `goAway` (~60 s warning) or socket error, the view model mints a handle-baked token via `POST /api/learner/session/{id}/token?handle=...`, reconnects, waits for `setupComplete`, then injects `GET /api/learner/session/{id}/context-summary` as a user turn to re-orient the model on the real current step.
- **Barge-in** — `serverContent.interrupted` triggers a playback buffer flush via `AudioSessionManager.clearPlaybackBuffer(reason: "barge-in")` so the learner doesn't hear the stale reply continuing.
- **Tool calls** — `json.toolCall.functionCalls[]` → `onToolCall(id, name, args)`. The VM forwards to the server via `POST /api/learner/session/{id}/tool-call`, unwraps `{result: {...}}`, updates local state (step index, PiP toggle, completion), and sends a `toolResponse` back to Gemini.
- **Pending tool-call set** — a `Set<String>` of in-flight tool call ids (not a single `Optional<String>`). If Gemini ever emits multiple function calls in one `toolCall` frame, the audio/video send gate stays closed until the last one completes.
- **Context growth observability** — logs every crossed 10k band of `usageMetadata.totalTokenCount`. Drops >30k between samples are flagged as server-side context compression firing (100k → 40k).

### Token management

`Services/GeminiTokenManager.swift` is a Swift `actor`:

- Seeds with the token returned from `POST /api/learner/session/start`.
- `validToken()` refreshes proactively if within 5 min of expiry.
- `forceRefresh(handle: String? = nil)` is called on auth errors or before a resumption-aware reconnect. Dedups concurrent callers via a `Task<EphemeralTokenResponse, Error>?`.
- Passes `?handle=...` to the server's token endpoint so the new token carries `SessionResumptionConfig(handle=...)`.

## Project Layout

```
samples/CameraAccess/
├── CameraAccess.xcodeproj
├── CameraAccess/
│   ├── CameraAccessApp.swift          # Wearables.configure(), BonjourDiscovery.start, UI-test MockDeviceKit auto-wire
│   ├── Info.plist                     # MWDAT, mic, camera, Bonjour (_retrace._tcp), photos, entitlements
│   ├── CameraAccess.entitlements
│   ├── Assets.xcassets
│   ├── TestResources/                 # plant.mp4, plant.png for MockDeviceKit
│   ├── Resources/                     # Bundled fonts, icons, lottie/animation assets
│   ├── DiamondLogoDither.metal        # Custom shader used by the splash + brand surfaces
│   ├── HandTracking/                  # Hand-pose substrate for HUD hover-then-select
│   │   ├── HandLandmarkerService.swift
│   │   ├── HandGestureService.swift
│   │   ├── HandTrackingConfig.swift
│   │   ├── MicroGestureRecognizer.swift
│   │   ├── PinchDragRecognizer.swift
│   │   ├── HandLandmarkFrame.swift
│   │   └── HandGestureDebugStack.swift
│   ├── Models/
│   │   ├── CaptureTransport.swift     # .glasses | .iPhone
│   │   ├── DiagnosticModels.swift     # Codable mirrors of /api/troubleshoot (session, state, handoff, manual upload/status, candidate procedure, diagnostic log entry)
│   │   └── ProcedureModels.swift      # Codable mirrors of server models (procedures, steps, session, voices, SessionRecord)
│   ├── Services/
│   │   ├── BonjourDiscovery.swift     # NWBrowser for _retrace._tcp; caches serverBaseURL
│   │   ├── GeminiLiveService.swift    # Direct WebSocket, binary-frame JSON sniffing, resumption, barge-in, tool plumbing
│   │   ├── GeminiTokenManager.swift   # actor — force-refresh with optional resumption handle, concurrent-caller dedup
│   │   ├── LocalProgressStore.swift   # Saved procedures + session history (UserDefaults)
│   │   ├── ProcedureAPIService.swift  # REST client for /api/procedures and /api/learner
│   │   └── VoicePreviewPlayer.swift
│   ├── Utils/
│   │   ├── AudioSessionManager.swift  # Four modes (coaching / coachingPhoneOnly / recording / recordingPhoneOnly)
│   │   ├── ExpertRecordingManager.swift  # AVAssetWriter pipeline (720×1280, shared host-clock session start for video + audio)
│   │   ├── IPhoneCameraCapture.swift  # AVCaptureSession wrapper for iPhone transport
│   │   ├── UploadService.swift        # multipart POST to /api/expert/upload
│   │   └── Retrace{Colors,Spacing,Typography}.swift
│   ├── ViewModels/
│   │   ├── WearablesViewModel.swift           # DAT registration state
│   │   ├── StreamSessionViewModel.swift       # glasses stream preview
│   │   ├── IPhoneExpertRecordingViewModel.swift
│   │   ├── IPhoneCoachingCameraSource.swift
│   │   ├── GeminiLiveSessionBase.swift        # Shared base — token lifecycle, reconnect-on-goAway, setup-complete gate. Used by Coaching + Diagnostic VMs.
│   │   ├── CoachingSessionViewModel.swift     # the big one — Gemini Live orchestration, transport switch, transcripts, tool calls, resumption
│   │   ├── DiagnosticSessionViewModel.swift   # Troubleshoot-mode Live session. Forwards tool calls to /api/troubleshoot/*; on handoff_to_learner, transitions into a fresh coaching session.
│   │   ├── DiscoverViewModel.swift
│   │   ├── LibraryViewModel.swift
│   │   ├── WorkflowListViewModel.swift
│   │   ├── ProcedureDetailViewModel.swift
│   │   ├── DebugMenuViewModel.swift
│   │   └── MockDeviceKit/              # Debug-only view models
│   └── Views/
│       ├── MainAppView.swift          # Top-level (no glasses registration gate)
│       ├── HomeScreenView.swift       # Onboarding — connect glasses (optional)
│       ├── ModeSelectionView.swift    # Expert vs Learner picker with server-connected toast
│       ├── RegistrationView.swift
│       ├── ServerSettingsView.swift   # Manual serverBaseURL override + glasses pairing management
│       ├── DebugMenuView.swift
│       ├── StreamView.swift / NonStreamView.swift / IPhoneCameraPreview.swift / PhotoPreviewView.swift / ExpertRecordingReviewView.swift  # Capture-side primitives reused by Expert + Coaching
│       ├── Components/                # CardView, CategoryChip, ModeCard, StepProgressBar, GlassPanelModifier, etc.
│       ├── Onboarding/                # OnboardingContainerView + Screens/ + Components/ — first-launch flow
│       ├── RayBanHUD/                 # Lens design system — see DESIGN.md before touching lens UI
│       ├── Troubleshoot/              # TroubleshootSessionView, TroubleshootIntroView, DiagnosticPhaseBar, DiagnosticResolutionPanel, ManualUploadSheet, TroubleshootConfirmOverlay, TroubleshootPageHandler, Pages/, Components/
│       ├── Expert/                    # ExpertTabView, RecordTabView, IPhoneRecordingView, WorkflowListView, ProcedureDetailView, ProcedureEditView, StepEditView
│       ├── MockDeviceKit/
│       └── Learner/
│           ├── LearnerTabView.swift
│           ├── LearnerProcedureDetailView.swift
│           ├── Discover/              DiscoverView.swift
│           ├── Library/               LibraryView.swift
│           ├── Coaching/              CoachingSessionView.swift, PiPReferenceView.swift
│           ├── Profile/               ProfileView.swift, VoiceSelectionView.swift
│           └── Progress/              LearnerProgressView.swift
├── CameraAccessTests/
└── CameraAccessUITests/
```

## DAT SDK conventions

- Three modules — `MWDATCore` (devices, registration, permissions, selectors), `MWDATCamera` (`StreamSession`, `VideoFrame`, photo capture), `MWDATMockDevice` (MockDeviceKit, MockRaybanMeta).
- Entry point is `Wearables.shared` after `Wearables.configure()` at launch.
- 0.6 API: `wearables.createSession(deviceSelector:)` → `deviceSession.addStream(config:)`. `StreamSession` has **no public init** — it's a capability attached to the `DeviceSession`.
- Imports:
  ```swift
  import MWDATCore
  import MWDATCamera
  #if DEBUG
  import MWDATMockDevice
  #endif
  ```
- Use `async/await` for all SDK operations. Use `AsyncSequence` / publisher `.listen {}` to observe streams.
- Annotate UI-updating code with `@MainActor`. Never block main with frame processing.

Full DAT reference: [Meta Wearables DAT SDK docs](https://wearables.developer.meta.com/docs/develop/), plus `.claude/rules/dat-conventions.md` and `.cursor/rules/`.

## Permissions (`Info.plist`)

Already configured:

- `NSBluetoothAlwaysUsageDescription` — DAT SDK Bluetooth.
- `NSCameraUsageDescription` — iPhone capture path + coaching camera.
- `NSMicrophoneUsageDescription` — expert narration + AI coaching.
- `NSLocalNetworkUsageDescription` + `NSBonjourServices = ["_retrace._tcp"]` — server discovery.
- `NSPhotoLibraryAddUsageDescription` — save captured photos.
- `UIBackgroundModes = ["bluetooth-peripheral", "external-accessory"]` — DAT glasses stay connected in background.
- `UISupportedExternalAccessoryProtocols = ["com.meta.ar.wearable"]`.
- Portrait-only on iPhone.

## REQUIRED: Adding new Swift files to the Xcode project

The main `CameraAccess` target uses traditional `PBXGroup` — new `.swift` files on disk are **not** compiled until registered in `project.pbxproj`. **After creating any new `.swift` file, immediately run this from the repo root:**

```bash
cd samples/CameraAccess
python3 -c "
from pbxproj import XcodeProject
import os
project = XcodeProject.load('CameraAccess.xcodeproj/project.pbxproj')
existing = set()
for obj in project.objects.get_objects_in_section('PBXFileReference'):
    p = getattr(obj, 'path', None)
    if p:
        existing.add(p)
        if not p.startswith('CameraAccess/'):
            existing.add('CameraAccess/' + p)
for root, dirs, files in os.walk('CameraAccess'):
    for fn in files:
        if fn.endswith('.swift'):
            rel = os.path.join(root, fn)
            if rel not in existing and fn not in existing:
                print(f'Adding: {rel}')
                project.add_file(rel, target_name='CameraAccess')
project.save()
"
```

Requires `pip install pbxproj` once in your environment.

Do not skip this step. Do not wait for the user to ask. Do not just leave a reminder.

## Ray-Ban HUD design system

The simulated Meta Ray-Ban lens has its own visual language, layout grid, animation vocabulary, and interaction model. **Before adding or redesigning anything that renders inside the lens** (coaching pages, expert recording chrome, troubleshoot canvas, future overlays/notifications/transitions), read the design doc:

📄 `samples/CameraAccess/CameraAccess/Views/RayBanHUD/DESIGN.md`

It covers: glass-panel surface recipe, color palette, typography scale, square-viewport layout rules, panel/pill/card/overlay component patterns, hover-then-select interaction model, default-focus rules for destructive actions, the canonical recede-and-arrive overlay animation, the spring-token vocabulary, audio-reactive motion, anti-patterns to avoid, and worked examples (`CoachingExitConfirmationOverlay`, `CoachingStepPage` expansion, `RetraceAudioMeter`).

When you ship a new pattern, **update the doc** so it stays authoritative.

## Critical Architecture Decisions

1. **Voice + video go direct** to Gemini Live — not through the server. A server hop adds 100-200 ms per exchange and breaks conversational feel.
2. **Two capture transports, one coaching pipeline.** `CaptureTransport` (`.glasses` / `.iPhone`) is picked per-session. The coaching VM, audio manager, and Gemini Live client are all transport-agnostic — they just see "a JPEG source" and "a mic buffer source."
3. **Session resumption is the canonical reconnect path.** On `goAway` (Gemini's ~60 s shutdown warning) or socket error, mint a handle-baked token, reopen the WebSocket, and inject the server's `context-summary` as a user turn so the model re-orients on the real current step. Losing the handle means starting over — persist it aggressively.
4. **Ephemeral tokens only.** The Gemini API key never lives in this app. The server mints short-lived, single-use tokens locked to a specific model / prompt / tool set / voice. `GeminiTokenManager` is a Swift `actor` so concurrent callers can't double-mint.
5. **Audio send gate is three-gated.** `isSendingAudio (mute) && pendingToolCallIds.isEmpty && isGeminiReady`. Gate state is edge-logged — flipping state prints "OPEN" or "CLOSED (reason)", per-buffer state does not.
6. **Tool calls close the gate.** When Gemini issues a function call, the VM adds the id to `pendingToolCallIds` and clears the playback buffer so Gemini's half-spoken reply doesn't continue over the next turn. The gate reopens only when every in-flight tool id has a `toolResponse` ACKed.
7. **Barge-in is server-detected.** `serverContent.interrupted` is Gemini's server-VAD telling us it cancelled generation because the learner talked over it. We must flush playback or the glasses speaker keeps playing the old reply.
8. **Bonjour over hardcoded IPs.** `BonjourDiscovery` populates `UserDefaults["serverBaseURL"]`; `ServerSettingsView` provides manual override. No IPs in code.
9. **Camera lifecycle is serialized.** `CoachingSessionViewModel.cameraLifecycleTask` chains every start/stop so a rapid dismiss + reopen can't race two `StreamSession` objects (DAT SDK returns WARP error 3 on that race).
10. **No glasses registration gate.** The app used to require pairing before showing the mode selector; now glasses are checked on-demand when the user picks a glasses-backed action. iPhone-only flows never prompt.

## Swift patterns + gotchas

- **`@MainActor` on all view models.** Combine sinks dispatch to `DispatchQueue.main` before updating `@Published` state.
- **Observe Combine `.$connectionState`, don't poll.** The coaching VM used to poll `isAISpeaking` every 200 ms and flickered; the current sink is race-free.
- **ISO8601 with milliseconds, not microseconds.** Server emits `timespec="milliseconds"`. Our `ISO8601DateFormatter.withFractionalSeconds` caps at 3 fractional digits. Keep the formats aligned or token-validity checks silently fail and force every connect into a network refresh.
- **Don't reuse ephemeral tokens.** Google documents `uses=1`. Every retry and resumption path mints a new one. If an initial handshake fails, call `tokenManager.forceRefresh()` before retry.
- **Teardown order in `stopGeminiLiveSession` matters.** Close send gate → drop Combine subs → stop audio capture → disconnect Gemini → null the service. Any other order causes "notConnected" spam or a racy `onAudioData` into a deallocated manager.
- **Room-tone on mic start.** The first few mic buffers can be silent — `AudioSessionManager` has diagnostics for this. If you see "silent mic" warnings, check `AudioSessionMode` is correct for the transport.
- **JPEG sent from glasses path is driven off the DAT video publisher.** One frame decodes to `UIImage` → `jpegData(compressionQuality: 0.5)` → WebSocket. Keep the 2 s throttle + quality 0.5 unless you re-run the token-budget math.
