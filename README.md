<div align="center">

<img src="https://github.com/xrcc-retrace/.github/raw/main/profile/assets/retrace-banner.svg" alt="Retrace" width="100%" />

# Retrace — iOS

### Record an expert once. Coach every learner forever.

The phone client for **Retrace**, an AI coaching system built for the **XRCC Berlin 2026** hackathon.
A SwiftUI app that captures from Ray-Ban Meta glasses or the iPhone camera, then talks **directly** to Gemini Live for real-time, visually-verified voice coaching.

[**▶ Watch the demo**](https://www.youtube.com/watch?v=gMlgZh2H5eE) &nbsp;·&nbsp; [**🏛 Org overview**](https://github.com/xrcc-retrace) &nbsp;·&nbsp; [**🛰 Backend repo**](https://github.com/xrcc-retrace/main-local-server-test)

</div>

---

## Where this sits in Retrace

Retrace is a three-tier system:

```
  Capture          Phone (this app)              Backend
┌─────────┐      ┌──────────────────┐       ┌────────────────┐
│ Ray-Ban │      │ Capture          │       │ Procedure      │
│ Meta    │ ───► │ orchestrator     │ ◄───► │ pipeline       │
│ glasses │      │ Gemini Live      │  REST │ Session ctrl   │
│   OR    │      │ client + token   │       │ Tool dispatch  │
│ iPhone  │      │ actor            │       │ Token minting  │
│ camera  │      │ Activity feed    │       │ Bonjour        │
└─────────┘      └────────┬─────────┘       └────────┬───────┘
                          │                          │
                          │ direct WebSocket         │ Files API
                          │ (BidiGenerateContent     │ + Pro REST
                          │  Constrained, v1alpha)   │
                          ▼                          ▼
                ┌───────────────────────────────────────────┐
                │           Gemini API (Google)             │
                │  Live (3.1 Flash) · 2.5 Pro · 2.5 Flash   │
                └───────────────────────────────────────────┘
```

The phone is the orchestrator. **Voice and ~0.5 fps video flow straight from the phone to Gemini Live** — they never hop through our backend. The backend is the control plane: it builds the system prompt, mints a short-lived ephemeral token, and dispatches tool calls.

> Full system architecture, the three product flows, and the cross-cutting design decisions live in the **[org profile README](https://github.com/xrcc-retrace)**. This README focuses on the iOS side.

---

## Highlights

- **Two capture transports, one coaching pipeline.** `CaptureTransport.glasses` (DAT SDK 0.6) or `CaptureTransport.iPhone` (`AVCaptureSession`). The coaching VM, audio session manager, and Gemini client are transport-agnostic — they just see *"a JPEG source"* and *"a mic buffer source."*
- **Direct Gemini Live socket** with full wire-protocol handling — binary-frame JSON sniffing, `setupComplete` gating, server-VAD barge-in, function-call interception, session resumption.
- **Indefinite session length** via context compression (100k → 40k) and `sessionResumptionUpdate.new_handle`. On `goAway` we mint a handle-baked token, reconnect, and inject a server-built `context-summary` so the model wakes up on the *real* current step.
- **Three-gated audio send pipeline.** `!muted && pendingToolCallIds.isEmpty && isGeminiReady`. Edge-logged on transition only — no per-buffer spam.
- **Ray-Ban HUD design system** — a square 600×600 lens canvas with a single shared spring vocabulary, glass-panel surface recipe, hover-then-select interaction model, hold-to-confirm for destructive actions, and a canonical recede-and-arrive overlay. See `Views/RayBanHUD/DESIGN.md` before touching lens UI.
- **Hand-tracking substrate** for the HUD's hover-then-select pattern — Apple Vision pose extraction → micro-gesture + pinch-drag recognizers → state machine consumed by SwiftUI focus.
- **Troubleshoot mode** — full diagnose-then-coach flow backed by `/api/troubleshoot/*`. Identify product → search the procedure library → on no-match, run web-grounded synthesis → handoff into a normal coaching session.
- **Bonjour LAN discovery** with cached `serverBaseURL` and a manual override in Server Settings. No hardcoded IPs.
- **Mock device path** — `MockDeviceKit` lets us develop and demo end-to-end without physical glasses; XCUITests auto-pair `MockRaybanMeta` with bundled fixtures.

---

## Build & run

### Prerequisites

- macOS with **Xcode 15+**
- **iOS 17.0+** target device (real device recommended; sim works for non-camera flows)
- A Meta developer account with **Developer Mode** + the Meta AI app installed (only if pairing real glasses)
- The Retrace backend reachable on the same Wi-Fi or via the cloud URL (https://retracexrcc.duckdns.org)

### Run locally

```bash
git clone https://github.com/xrcc-retrace/dat-ios-test.git
cd dat-ios-test
open samples/CameraAccess/CameraAccess.xcodeproj
```

1. Pick a real device (or simulator), set your team.
2. **Cmd+R** to build and run.
3. (Optional) Tap **Connect my glasses** to hand off to the Meta AI app for DAT registration. The app runs end-to-end iPhone-only without this.
4. Pick **Expert Mode** or **Learner Mode**.

### Server discovery

The app starts an `NWBrowser` for `_retrace._tcp` on launch. A "Server Connected" toast appears when it finds the backend on the same Wi-Fi. Manual override lives behind the gear icon on the mode selector (**Server Settings**), stored in `UserDefaults["serverBaseURL"]`. The cloud fallback is `https://retracexrcc.duckdns.org`.

### Mock device (no glasses required)

DEBUG builds include `MockDeviceKit`. Use the in-app debug menu (shake-gesture overlay) to pair a simulated Ray-Ban Meta. UI tests with `--ui-testing` auto-pair `MockRaybanMeta` with bundled `plant.mp4` / `plant.png`.

---

## Architecture

### Capture transports

`Models/CaptureTransport.swift` — `enum CaptureTransport { case glasses, iPhone }`. Picked per-session; both recording and coaching honor it end-to-end.

| Transport | Capture | Audio |
|---|---|---|
| `.glasses` | DAT SDK `StreamSession` via `wearables.createSession(deviceSelector:).addStream(config:)`. `AutoDeviceSelector` picks the best paired device. | Bluetooth HFP routed through `AVAudioSession` |
| `.iPhone` | `Utils/IPhoneCameraCapture.swift` wraps `AVCaptureSession` at 720×1280 portrait — geometry matches the glasses stream so the writer settings work unchanged. Coaching path throttles sample buffers to ≈0.5 fps JPEG to match the glasses frame rate and token budget. | Forced built-in mic + loudspeaker |

`Utils/AudioSessionManager.swift` has four modes — the VM picks one based on transport + activity:

| Mode | Purpose |
|---|---|
| `.coaching` | Full-duplex with AEC, speaker fallback. Prefers BT HFP glasses if paired. |
| `.coachingPhoneOnly` | Full-duplex with AEC, forced built-in mic + loudspeaker. Used when `.iPhone` transport — ignores HFP even if glasses are paired. |
| `.recording` | Simplex capture, no playback, no AEC. Expert recording via glasses (HFP) or iPhone mic fallback. |
| `.recordingPhoneOnly` | Simplex capture, forced built-in mic. iPhone-native expert recording — ignores HFP. |

### Gemini Live client

`Services/GeminiLiveService.swift` is a `@MainActor ObservableObject` that owns the WebSocket and the wire protocol.

- **Endpoint** — `BidiGenerateContentConstrained` (v1alpha ephemeral-token variant). This endpoint delivers JSON control messages as **binary** WebSocket frames (UTF-8-encoded `{...}` bytes, not text frames). The service sniffs the first byte of every binary frame before deciding between JSON parsing and raw PCM audio playback.
- **Setup handshake** — sends `{"setup": {}}` as the very first frame after `didOpenWithProtocol` (config is already baked into the token). `.connected` flips only after `setupComplete` arrives, so the audio gate can't open before Gemini is ready.
- **Send gate** — three inputs: mic muted, pending tool call, or Gemini not ready. Edge-logged: only OPEN / CLOSED transitions print.
- **Tool calls** — `json.toolCall.functionCalls[]` → `onToolCall(id, name, args)`. The VM forwards to `POST /api/learner/session/{id}/tool-call`, unwraps `{result: {...}}`, updates local state (step index, PiP toggle, completion), and replies to Gemini with `toolResponse`.
- **Pending tool-call set** — a `Set<String>`, not an `Optional<String>`. If Gemini ever emits multiple function calls in one `toolCall` frame, the audio + video send gate stays closed until the *last* one completes.
- **Session resumption** — persists `sessionResumptionUpdate.new_handle`. On `goAway` (~60 s warning) or socket error, the VM mints a handle-baked token via `POST /api/learner/session/{id}/token?handle=...`, reconnects, waits for `setupComplete`, then injects `GET /api/learner/session/{id}/context-summary` as a user turn so the model re-orients on the real current step.
- **Barge-in** — `serverContent.interrupted` triggers a playback buffer flush via `AudioSessionManager.clearPlaybackBuffer(reason: "barge-in")`. Without this the open-ear glasses speakers keep playing the stale reply over the next learner turn.
- **Context growth observability** — logs every crossed 10k band of `usageMetadata.totalTokenCount`. Drops >30k between samples are flagged as server-side context compression firing (100k → 40k).

### Token management

`Services/GeminiTokenManager.swift` is a Swift `actor`:

- Seeds with the token returned from `POST /api/learner/session/start`.
- `validToken()` refreshes proactively if within 5 min of expiry.
- `forceRefresh(handle: String? = nil)` is called on auth errors or before a resumption-aware reconnect. Dedups concurrent callers via a `Task<EphemeralTokenResponse, Error>?`.
- Passes `?handle=...` so the new token carries `SessionResumptionConfig(handle=...)`.

### Hand tracking + HUD

The `HandTracking/` substrate feeds the Ray-Ban HUD's hover-then-select pattern:

- `HandLandmarkerService` — Apple Vision (or MediaPipe-style) hand-pose extraction.
- `HandGestureService` — high-level state machine (`hover`, `select`, `idle`).
- `MicroGestureRecognizer` + `PinchDragRecognizer` — concrete recognizers fed by the landmarker.
- `HandTrackingConfig` — tuning knobs (smoothing, hysteresis, pinch thresholds).
- `HandGestureDebugStack` — debug overlay; toggled from the Debug Menu.

The HUD reads `HandGestureService.$state` to drive focus rings, the recede-and-arrive overlay, and hold-to-confirm. Coaching and Troubleshoot sessions both consume it.

### Ray-Ban HUD design system

The simulated lens has its own visual language, layout grid, animation vocabulary, and interaction model. **Before adding or redesigning anything that renders inside the lens** (coaching pages, expert recording chrome, troubleshoot canvas, future overlays/notifications/transitions), read:

📄 [`samples/CameraAccess/CameraAccess/Views/RayBanHUD/DESIGN.md`](samples/CameraAccess/CameraAccess/Views/RayBanHUD/DESIGN.md)

It covers the glass-panel surface recipe, color palette, typography scale, square-viewport layout rules, panel/pill/card/overlay component patterns, hover-then-select interaction model, default-focus rules for destructive actions, the canonical recede-and-arrive overlay, the spring-token vocabulary, audio-reactive motion, anti-patterns to avoid, and worked examples.

---

## App flow

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
  │                                                      └── tool calls → /tool-call
```

### Expert Mode

Record a procedure end-to-end from glasses or iPhone, review the raw capture, then upload. The upload returns `202`; the app polls procedure status (`processing` → `completed` / `completed_partial` / `failed`) until Gemini finishes. `ProcedureEditView` + `StepEditView` let you rewrite titles, descriptions, tips, warnings, and step order before sharing.

### Learner Mode

- **Discover** — all procedures from the server.
- **Library** — saved + in-progress procedures, tracked locally via `LocalProgressStore`.
- **Progress** — session history (completed / abandoned / in-progress).
- **Profile** — voice picker with audio previews fetched from the server (`/api/learner/voices`), plus an auto-advance toggle.
- **Coaching** — Gemini Live voice coaching with PiP reference-clip overlay, activity feed, mute, and live connection status.

### Troubleshoot mode

`Views/Troubleshoot/` orchestrates the diagnose-then-coach flow via `/api/troubleshoot/*`. The user describes a broken product; Gemini issues `identify_product` → `confirm_identification`, then `search_procedures`. On no-match the model calls `web_search_for_fix` (returns a procedure with cited sources), and finally `handoff_to_learner` to spawn a normal coaching session. UI is built around `DiagnosticPhaseBar`, `DiagnosticResolutionPanel`, `ManualUploadSheet`, `TroubleshootConfirmOverlay`, `TroubleshootPageHandler`, and a HUD-page collection.

---

## Tech stack

| Layer | Pick |
|---|---|
| Language / framework | Swift 5.9, SwiftUI, Combine, Swift Concurrency (`actor`, `@MainActor`, `AsyncSequence`) |
| Smart-glasses SDK | Meta DAT SDK 0.6 — `MWDATCore` + `MWDATCamera` + `MWDATMockDevice` |
| Capture | `AVFoundation`, `AVCaptureSession`, `AVAssetWriter` |
| Networking | `URLSession`, `URLSessionWebSocketTask` (Gemini Live), `Network.framework` `NWBrowser` (Bonjour) |
| Hand tracking | Apple Vision + MediaPipe Tasks Vision (`SwiftTasksVision` SPM package) |
| Distribution | TestFlight via Fastlane `match` + GitHub Actions on `v*` tag push |

---

## TestFlight deployment

A `v*` git tag push triggers `.github/workflows/testflight.yml`, which:

1. Spins up macOS with `latest-stable` Xcode (matches local Xcode 26.x).
2. Pulls signing certs via Fastlane `match` (readonly) from the private `xrcc-retrace/ios-signing-certs` repo.
3. Flips the project to `CODE_SIGN_STYLE = Manual` + `CODE_SIGN_IDENTITY = Apple Distribution` for the CI workspace only.
4. Auto-increments build number from `latest_testflight_build_number(app_identifier:) + 1`.
5. Uploads to App Store Connect via API key (`ASC_KEY_ID` / `ASC_ISSUER_ID` / `ASC_PRIVATE_KEY` GitHub Secrets).

```bash
git fetch --tags origin
git tag --sort=-v:refname | head -5    # find the latest v* tag
git tag vX.Y.Z                         # bump patch
git push origin vX.Y.Z
```

That's the entire release process. ~12–20 min from push to TestFlight.

External-tester distribution is **not** automatic — first build to a group requires Beta App Review (~24–48 hr), then each new build needs a manual "Add Build" click in App Store Connect. This is intentional: pushing tags can never accidentally distribute to judges or beta testers.

### Required Build Phase: "Patch MediaPipeTasksVision Info.plist"

The `SwiftTasksVision` SPM package's `MediaPipeTasksVision.framework` ships with a malformed `Info.plist` (missing `CFBundleVersion`, `CFBundleShortVersionString`, `MinimumOSVersion`). App Store validation rejects any build containing it. The Run Script Build Phase positioned **after** Embed Frameworks patches the plist and re-signs the framework. Do not delete or reorder this build phase.

---

## Project layout

```
samples/CameraAccess/
├── CameraAccess.xcodeproj
├── CameraAccess/
│   ├── CameraAccessApp.swift          # Wearables.configure(), BonjourDiscovery.start, UI-test MockDeviceKit auto-wire
│   ├── Info.plist                     # MWDAT, mic, camera, Bonjour (_retrace._tcp), photos, entitlements
│   ├── HandTracking/                  # Hand-pose substrate for HUD hover-then-select
│   ├── Models/
│   │   ├── CaptureTransport.swift     # .glasses | .iPhone
│   │   ├── DiagnosticModels.swift     # Codable mirrors of /api/troubleshoot
│   │   └── ProcedureModels.swift      # Codable mirrors of server models
│   ├── Services/
│   │   ├── BonjourDiscovery.swift     # NWBrowser for _retrace._tcp
│   │   ├── GeminiLiveService.swift    # Direct WebSocket, binary-frame JSON sniffing, resumption, barge-in
│   │   ├── GeminiTokenManager.swift   # actor — force-refresh with optional resumption handle, dedup
│   │   ├── LocalProgressStore.swift   # Saved procedures + session history (UserDefaults)
│   │   ├── ProcedureAPIService.swift  # REST client for /api/procedures and /api/learner
│   │   └── VoicePreviewPlayer.swift
│   ├── Utils/
│   │   ├── AudioSessionManager.swift  # Four modes (coaching / coachingPhoneOnly / recording / recordingPhoneOnly)
│   │   ├── ExpertRecordingManager.swift  # AVAssetWriter pipeline (720×1280, shared host-clock session start)
│   │   ├── IPhoneCameraCapture.swift  # AVCaptureSession wrapper for iPhone transport
│   │   └── UploadService.swift        # multipart POST to /api/expert/upload
│   ├── ViewModels/
│   │   ├── GeminiLiveSessionBase.swift        # Shared base — token lifecycle, reconnect-on-goAway, setup-complete gate
│   │   ├── CoachingSessionViewModel.swift     # the big one — Gemini Live orchestration, transport switch, transcripts
│   │   ├── DiagnosticSessionViewModel.swift   # Troubleshoot-mode Live session
│   │   ├── IPhoneCoachingCameraSource.swift   # 0.5 fps JPEG throttle for iPhone transport
│   │   ├── IPhoneExpertRecordingViewModel.swift
│   │   └── ...                                # Discover / Library / Workflow / ProcedureDetail / DebugMenu
│   └── Views/
│       ├── ModeSelectionView.swift            # Expert vs Learner picker
│       ├── ServerSettingsView.swift           # Manual serverBaseURL override + glasses pairing
│       ├── Onboarding/                        # First-launch flow
│       ├── RayBanHUD/                         # Lens design system — see DESIGN.md before touching
│       ├── Troubleshoot/                      # Diagnose-then-coach UI
│       ├── Expert/                            # Record / Review / Upload / Workflow / Edit
│       └── Learner/                           # Discover / Library / Coaching / Profile / Progress
├── CameraAccessTests/
└── CameraAccessUITests/
```

---

## Critical iOS-side design decisions

The cross-cutting Retrace decisions (direct-to-Gemini, ephemeral tokens, current-step-only prompt, etc.) live in the **[org profile README](https://github.com/xrcc-retrace)**. The ones specific to this app:

1. **Two capture transports, one coaching pipeline.** `CaptureTransport` is picked per-session; the coaching VM, audio manager, and Live client are transport-agnostic.
2. **Session resumption is the canonical reconnect path.** On `goAway` or socket error, mint a handle-baked token, reopen the WebSocket, and inject the server's `context-summary` as a user turn. Losing the handle means starting over — persist it aggressively.
3. **Audio send gate is three-gated.** `!muted && pendingToolCallIds.isEmpty && isGeminiReady`. Edge-logged.
4. **Tool calls close the gate.** When Gemini issues a function call, the VM adds the id to `pendingToolCallIds` and clears the playback buffer. The gate reopens only when every in-flight tool id has a `toolResponse` ACKed.
5. **Barge-in is server-detected.** `serverContent.interrupted` is Gemini's server-VAD telling us it cancelled generation. Flush playback or the speaker keeps going.
6. **Camera lifecycle is serialized.** `CoachingSessionViewModel.cameraLifecycleTask` chains every start/stop so a rapid dismiss + reopen can't race two `StreamSession` objects (DAT SDK returns WARP error 3 on that race).
7. **No glasses registration gate.** Glasses are checked on-demand when the user picks a glasses-backed action. iPhone-only flows never prompt.
8. **HUD confirm registrations and handler-stack pushes are token-stamped.** SwiftUI fires the new view's `.onAppear` before the old view's `.onDisappear` during page transitions; without UUID tokens, an outgoing page silently wipes an incoming overlay's freshly-installed closure (asymmetric failure: touch tap still works, pinch-select silently no-ops).

---

## Permissions (`Info.plist`)

Already configured:

- `NSBluetoothAlwaysUsageDescription` — DAT SDK Bluetooth
- `NSCameraUsageDescription` — iPhone capture path + coaching camera
- `NSMicrophoneUsageDescription` — expert narration + AI coaching
- `NSLocalNetworkUsageDescription` + `NSBonjourServices = ["_retrace._tcp"]` — server discovery
- `NSPhotoLibraryAddUsageDescription` — save captured photos
- `UIBackgroundModes = ["bluetooth-peripheral", "external-accessory"]` — DAT glasses stay connected in background
- `UISupportedExternalAccessoryProtocols = ["com.meta.ar.wearable"]`
- Portrait-only on iPhone

---

## Adding new Swift files

The main `CameraAccess` target uses traditional `PBXGroup` — new `.swift` files on disk are **not** compiled until they're registered in `project.pbxproj`. After creating any new `.swift` file:

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

Requires `pip install pbxproj` once.

---

## Attribution

Forked from Meta's [`meta-wearables-dat-ios`](https://github.com/facebook/meta-wearables-dat-ios) `CameraAccess` sample. The DAT SDK, the bundled `.claude/` skills, and the original sample-app scaffolding carry their Meta licensing — see [`LICENSE`](LICENSE) and [`NOTICE`](NOTICE).

A second README at [`samples/CameraAccess/README.md`](samples/CameraAccess/README.md) covers the same iOS app at the Xcode-project scope (handy when navigating the project from inside Xcode).

---

<div align="center">

Built by the XRCC Retrace team for the Berlin 2026 hackathon.

[**Org profile**](https://github.com/xrcc-retrace) &nbsp;·&nbsp; [**Backend**](https://github.com/xrcc-retrace/main-local-server-test)

</div>
