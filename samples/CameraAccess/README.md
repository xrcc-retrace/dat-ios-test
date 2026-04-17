# Retrace — iOS Companion App

SwiftUI iOS app for Retrace, the AI coaching system built for the XRCC Berlin 2026 hackathon. This app started life as Meta's `CameraAccess` sample for the Wearables Device Access Toolkit (DAT) SDK and has been extended into the full Retrace phone client.

> **One-liner:** Record an expert once. Coach every learner forever.

The phone is the orchestrator in Retrace's three-tier stack (**glasses / iPhone camera → phone → server**):

- Streams camera + microphone from **Ray-Ban Meta glasses** (via the DAT SDK) **or the iPhone** — the user picks the capture transport per-session.
- Talks to the Retrace backend (`main-local-server-test`) for procedure storage, step clips, and session lifecycle.
- Opens a **direct** Gemini Live WebSocket for voice coaching (using an ephemeral token the server mints) — audio and video never route through the backend, avoiding the 100–200 ms penalty of an extra hop.

## Prerequisites

- iOS 17.0+, Xcode 15+
- The Retrace backend running on the same Wi-Fi (see `main-local-server-test/`)
- Meta AI app installed + Developer Mode enabled on your Meta account
- Ray-Ban Meta glasses are **optional** — `MockDeviceKit` works without hardware in DEBUG builds, and the whole app runs end-to-end on iPhone alone.

## Build & Run

```bash
open samples/CameraAccess/CameraAccess.xcodeproj
```

1. Select your team and a run destination.
2. Build & run (`Cmd+R`).
3. (Optional) Tap **Connect my glasses** to hand off to the Meta AI app for DAT registration. Or skip and pick a mode directly.
4. Pick **Expert Mode** or **Learner Mode** from the mode selector. Per-session, pick a capture transport (**glasses** or **iPhone**).

### Server discovery

The app advertises / browses on Bonjour (`_retrace._tcp`) and connects automatically when the backend is on the same Wi-Fi. A "Server Connected" toast appears on discovery. You can override the server URL from the gear icon on the mode selection screen (**Server Settings**) — stored in `UserDefaults` under `"serverBaseURL"`.

### Mock device (no glasses required)

Debug builds include `MockDeviceKit`. Use the in-app debug overlay (shake gesture) to pair a simulated Ray-Ban Meta. XCUITests with the `--ui-testing` argument auto-pair `MockRaybanMeta` with bundled `plant.mp4` / `plant.png` resources — this lets you exercise the full UI flow without hardware.

## App Flow

```
AppLaunch ──► Wearables.configure() + BonjourDiscovery.startBrowsing
                         │
                         ▼
                 ModeSelectionView  ◄─── Server Settings (gear) ─── glasses pair/unpair
                         │
        ┌────────────────┴────────────────┐
        ▼                                 ▼
  Expert Mode                        Learner Mode
  (ExpertTabView)                    (LearnerTabView)
        │                                 │
  ┌─────┴──────┐                ┌─────────┼─────────┐
  ▼            ▼                ▼         ▼         ▼
 Record ───► Review ───► Upload Discover Library / Progress / Profile
  │                        │      │         │
  │ Transport:             │      └───► LearnerProcedureDetail ──► Coaching
  │  .glasses / .iPhone    │                                         │
  │                        ▼                                         ▼
  │            POST /api/expert/upload            POST /api/learner/session/start
  │            (polls /procedures/{id})                │
  │                                                    ├── ephemeral Gemini token
  │                                                    ├── direct Live WebSocket
  └──► (glasses or iPhone capture)                     └── tool calls → /tool-call
```

There is no "glasses registration gate" on the root — the app runs end-to-end on iPhone without paired glasses. Glasses connectivity is checked on-demand when the user picks a glasses-backed action, and registration happens via a sheet.

### Expert Mode

Record a procedure from the glasses or the iPhone, review the raw capture, then upload to the server. Upload returns `202`; the app polls procedure status until Gemini finishes generating the SOP. The workflow list lets you edit step titles / descriptions / tips / warnings / order before sharing.

### Learner Mode

- **Discover** — browse all procedures from the server.
- **Library** — saved + in-progress procedures, tracked locally via `LocalProgressStore`.
- **Progress** — session history (completed / abandoned / in-progress).
- **Profile** — pick a voice (Puck, Charon, Kore, …) with audio previews fetched from the server at `/api/learner/voices`. Auto-advance toggle for visual completion detection vs verbal confirmation.
- **Coaching** — the headline flow. Starts a Live session, plays voice coaching through the glasses' open-ear speakers or the iPhone loudspeaker, and surfaces the current step's reference clip in a picture-in-picture overlay. An activity feed shows live transcripts and tool calls.

## Capture transports

`CaptureTransport` (`Models/CaptureTransport.swift`) is an enum — `.glasses` or `.iPhone` — picked per-session. Both recording and coaching honor it end-to-end.

### Glasses path

- DAT SDK `StreamSession` via `wearables.createSession(deviceSelector:)` → `deviceSession.addStream(config:)` (0.6 API: `StreamSession` has no public init, it's a capability attached to the `DeviceSession`).
- `AutoDeviceSelector` picks the best paired device.
- Audio flows through BT HFP.

### iPhone path

- `Utils/IPhoneCameraCapture.swift` wraps `AVCaptureSession` (720×1280 portrait, matching the glasses stream geometry so the writer settings work unchanged).
- `ViewModels/IPhoneExpertRecordingViewModel.swift` drives expert recording.
- `ViewModels/IPhoneCoachingCameraSource.swift` throttles sample buffers to ≈0.5 fps JPEG (quality 0.5) for coaching — same token budget as the glasses path.
- Audio is forced onto the built-in mic + loudspeaker.

### AudioSessionManager modes

`Utils/AudioSessionManager.swift` has four modes — the VM picks one based on transport + activity:

| Mode | Purpose |
|---|---|
| `.coaching` | Full-duplex with AEC, speaker fallback, prefers BT HFP glasses if paired. |
| `.coachingPhoneOnly` | Full-duplex with AEC, forced built-in mic + loudspeaker. Used when the learner picked `.iPhone` — ignores HFP even if glasses are paired. |
| `.recording` | Simplex capture, no playback, no AEC. Expert recording via glasses (HFP) or iPhone mic fallback. |
| `.recordingPhoneOnly` | Simplex capture, forced built-in mic. iPhone-native expert recording. |

## Gemini Live client

`Services/GeminiLiveService.swift` opens the direct WebSocket and drives the wire protocol. Notable behavior:

- **Wire endpoint** — `BidiGenerateContentConstrained` (v1alpha ephemeral-token variant). JSON control messages arrive as **binary** WebSocket frames (UTF-8 encoded `{...}` bytes, not text frames). The service sniffs the first byte of each binary frame before deciding between JSON parsing and raw PCM audio playback.
- **Setup handshake** — after `didOpenWithProtocol`, sends `{"setup": {}}` as the very first frame. `.connected` flips only after `setupComplete` arrives; the audio send gate can't open before Gemini is ready.
- **Session resumption** — persists `sessionResumptionUpdate.new_handle`. On `goAway` (Gemini's ~60 s shutdown warning) or socket error, the view model mints a handle-baked token via the server's token endpoint, reconnects, waits for `setupComplete`, then injects `/context-summary` as a user turn so the model re-orients on the real current step.
- **Barge-in** — `serverContent.interrupted` triggers a playback buffer flush so the learner doesn't hear a stale reply continuing after they spoke over the model.
- **Tool calls** — `onToolCall(id, name, args)` → VM forwards to the server, unwraps `{result: {...}}`, updates local state (step index, PiP toggle, completion), and sends a `toolResponse` back to Gemini.
- **Pending-tool-call set** — the audio / video send gate is closed while any tool call is in flight. Using a `Set<String>` (not a single `Optional`) handles the case where Gemini emits multiple function calls in one `toolCall` frame.
- **Context growth observability** — logs every crossed 10k band of `usageMetadata.totalTokenCount`. Drops >30k between samples are flagged as server-side context compression firing (100k → 40k).

`Services/GeminiTokenManager.swift` is a Swift `actor`: seeds from the session/start response, refreshes proactively 5 min before expiry, and `forceRefresh(handle:)` is called on auth errors or before a resumption-aware reconnect.

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
│   ├── Models/
│   │   ├── CaptureTransport.swift     # .glasses | .iPhone
│   │   └── ProcedureModels.swift      # Codable mirrors of server models (procedures, steps, session, voices, SessionRecord)
│   ├── Services/
│   │   ├── BonjourDiscovery.swift     # NWBrowser for _retrace._tcp; caches serverBaseURL
│   │   ├── GeminiLiveService.swift    # Direct WebSocket, binary-frame JSON sniffing, resumption, barge-in, tool plumbing
│   │   ├── GeminiTokenManager.swift   # actor — force-refresh with optional resumption handle, concurrent-caller dedup
│   │   ├── LocalProgressStore.swift   # Saved procedures + session history (UserDefaults)
│   │   ├── ProcedureAPIService.swift  # REST client for /api/procedures and /api/learner
│   │   └── VoicePreviewPlayer.swift
│   ├── Utils/
│   │   ├── AudioSessionManager.swift  # Four modes: coaching / coachingPhoneOnly / recording / recordingPhoneOnly
│   │   ├── ExpertRecordingManager.swift  # AVAssetWriter pipeline (720×1280)
│   │   ├── IPhoneCameraCapture.swift  # AVCaptureSession wrapper for iPhone transport
│   │   ├── UploadService.swift        # multipart POST to /api/expert/upload
│   │   └── Retrace{Colors,Spacing,Typography}.swift
│   ├── ViewModels/
│   │   ├── WearablesViewModel.swift           # DAT registration state
│   │   ├── StreamSessionViewModel.swift       # glasses stream preview
│   │   ├── IPhoneExpertRecordingViewModel.swift
│   │   ├── IPhoneCoachingCameraSource.swift
│   │   ├── CoachingSessionViewModel.swift     # the big one — Gemini Live orchestration, transport switch, transcripts, tool calls, resumption
│   │   ├── DiscoverViewModel.swift
│   │   ├── LibraryViewModel.swift
│   │   ├── WorkflowListViewModel.swift
│   │   ├── ProcedureDetailViewModel.swift
│   │   ├── DebugMenuViewModel.swift
│   │   └── MockDeviceKit/
│   └── Views/
│       ├── MainAppView.swift
│       ├── HomeScreenView.swift
│       ├── ModeSelectionView.swift
│       ├── RegistrationView.swift
│       ├── ServerSettingsView.swift
│       ├── DebugMenuView.swift
│       ├── Components/                # CardView, CategoryChip, ModeCard, StepProgressBar, GlassPanelModifier, …
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

## DAT SDK Integration

- `Wearables.configure()` runs at launch (`CameraAccessApp.swift`).
- `StreamSession` + `AutoDeviceSelector` provide the camera feed via the 0.6 API (`createSession` → `addStream`).
- `MWDATMockDevice` lets you run the whole app without hardware — the UI-testing target auto-wires `MockRaybanMeta` with bundled resources.
- See [Meta's DAT SDK docs](https://wearables.developer.meta.com/docs/develop/). The AI assistant rules in `.claude/` and `.cursor/rules/` are pre-configured with SDK conventions.

## Permissions (`Info.plist`)

- `NSBluetoothAlwaysUsageDescription` — DAT SDK Bluetooth.
- `NSCameraUsageDescription` — iPhone capture + coaching camera.
- `NSMicrophoneUsageDescription` — expert narration + AI coaching.
- `NSLocalNetworkUsageDescription` + `NSBonjourServices = ["_retrace._tcp"]` — server discovery.
- `NSPhotoLibraryAddUsageDescription` — save captured photos.
- `UIBackgroundModes = ["bluetooth-peripheral", "external-accessory"]` — glasses stay connected in background.

## Critical Architecture Decisions

1. **Voice + video go direct** to Gemini Live — not through the server. A server hop costs 100–200 ms per exchange and breaks conversational feel.
2. **Two capture transports, one coaching pipeline.** `CaptureTransport` (`.glasses` / `.iPhone`) is picked per-session. The coaching VM, audio manager, and Gemini Live client are transport-agnostic — they see "a JPEG source" and "a mic buffer source."
3. **Session resumption is the canonical reconnect path.** On `goAway` or socket error the VM mints a handle-baked token, reopens the WebSocket, and injects the server's `context-summary` as a user turn so the model re-orients on the real current step.
4. **Ephemeral tokens only.** The Gemini API key never lives in this app. The server mints short-lived, single-use tokens locked to a specific model / prompt / tool set / voice. `GeminiTokenManager` is a Swift `actor` so concurrent callers can't double-mint.
5. **Audio send gate is three-gated** — mic-unmuted **AND** no pending tool call **AND** Gemini ready. Gate transitions are edge-logged (OPEN / CLOSED with reason), per-buffer state is not.
6. **Tool calls close the gate** and clear playback, so Gemini's half-spoken reply doesn't continue over the next turn. The gate reopens only when every in-flight tool id has a `toolResponse` ACKed.
7. **Barge-in is server-detected.** `serverContent.interrupted` is Gemini's server-VAD telling us it cancelled generation because the learner talked over it — we must flush playback.
8. **Bonjour over hardcoded IPs.** `BonjourDiscovery` populates `UserDefaults["serverBaseURL"]`; `ServerSettingsView` provides manual override.
9. **Camera lifecycle is serialized.** `CoachingSessionViewModel.cameraLifecycleTask` chains every start/stop so a rapid dismiss + reopen can't race two `StreamSession` objects (the DAT SDK returns WARP error 3 on that race).
10. **No glasses registration gate.** The app used to require pairing before showing the mode selector; now glasses are checked on-demand when the user picks a glasses-backed action. iPhone-only flows never prompt.

## Working on this app

> **Adding a new Swift file?** The target uses a traditional `PBXGroup`, so new files on disk are **not** compiled until registered in `project.pbxproj`. Use the helper script in `CLAUDE.md` (`pbxproj` Python module) to add any new `.swift` file to the `CameraAccess` target immediately after creating it. Don't skip this — builds will silently miss the file.

### Swift patterns + gotchas

- `@MainActor` on all view models. Combine sinks dispatch to `DispatchQueue.main` before updating `@Published` state.
- Observe `$connectionState` with a Combine sink, don't poll — the old 200 ms poll caused visible UI flicker.
- ISO8601 with **millisecond** precision on both ends (server uses `timespec="milliseconds"`). `ISO8601DateFormatter.withFractionalSeconds` caps at 3 fractional digits — 6-digit microseconds silently fail to parse and force spurious refreshes.
- Don't reuse ephemeral tokens. Google documents `uses=1`; every retry and resumption path mints a fresh one.
- Teardown order in `stopGeminiLiveSession` matters: close send gate → drop Combine subs → stop audio capture → disconnect Gemini → null the service. Other orders cause "notConnected" spam or races against deallocated managers.

## License

This source code is licensed under the license found in the LICENSE file in the root directory of this source tree.
