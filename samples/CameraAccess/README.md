# Retrace — iOS Companion App

SwiftUI iOS app for Retrace, the AI coaching system for the XRCC Berlin 2026 hackathon. This app started life as Meta's `CameraAccess` sample for the Wearables Device Access Toolkit (DAT) SDK and has been extended into the full Retrace phone client.

> **One-liner:** Record an expert once. Coach every learner forever.

The phone is the orchestrator in Retrace's three-tier stack (**glasses → phone → server**):

- Streams camera + microphone from Ray-Ban Meta glasses via the DAT SDK.
- Talks to the Retrace backend for procedure storage, step clips, and session lifecycle.
- Opens a **direct** Gemini Live WebSocket for voice coaching (using an ephemeral token the server mints) — never routing audio through the backend, to avoid the 100–200 ms penalty of an extra hop.

## Prerequisites

- iOS 17.0+, Xcode 15+
- The Retrace backend running on the same Wi-Fi (see `main-local-server-test/`)
- Meta AI app installed + Developer Mode enabled on your Meta account
- Ray-Ban Meta glasses (optional — `MockDeviceKit` works without hardware in DEBUG builds)

## Build & Run

```bash
open samples/CameraAccess/CameraAccess.xcodeproj
```

1. Select your team and a run destination.
2. Build & run (`Cmd+R`).
3. On first launch, tap **Connect my glasses** — the app hands off to the Meta AI app to complete device registration.
4. Once registered, pick **Expert Mode** or **Learner Mode** from the mode selection screen.

### Server discovery

The app advertises/listens on Bonjour (`_retrace._tcp`) and will connect automatically when the backend is on the same Wi-Fi. A "Server Connected" toast appears on discovery. You can override the server URL from the gear icon on the mode selection screen (**Server Settings**).

### Mock device (no glasses required)

Debug builds include `MockDeviceKit`. Use the in-app debug menu (shake gesture / debug overlay) to pair a simulated Ray-Ban Meta, which lets you exercise the full UI flow without hardware.

## App Flow

```
HomeScreen (unregistered) ─► Meta AI registration ─► ModeSelection
                                                         │
                          ┌──────────────────────────────┴──────────────────────────────┐
                          ▼                                                             ▼
                     Expert Mode                                                   Learner Mode
                          │                                                             │
              Record ─► Review ─► Upload                                Discover / Library / Profile
                          │                                                             │
                          ▼                                                             ▼
              POST /api/expert/upload                        POST /api/learner/session/start
              (poll /api/procedures/{id})                    ├─► ephemeral Gemini token
                                                             ├─► open direct Live WebSocket
                                                             └─► Coaching session
                                                                 (tool calls forwarded to server)
```

### Expert Mode

Record a procedure end-to-end from the glasses, review the raw capture, then upload to the server. The upload returns `202`; the app polls procedure status until Gemini finishes generating the SOP. The procedure list view lets you edit step titles/descriptions/tips/warnings before publishing.

### Learner Mode

- **Discover** — browse available procedures from the server.
- **Library** — saved / in-progress procedures with local progress tracking.
- **Coaching** — starts a Live session, plays voice coaching through the glasses' open-ear speakers, and surfaces the current step's reference clip in a picture-in-picture overlay.
- **Profile** — pick a voice (Puck, Charon, Kore, …) with audio previews from the server.

## Project Layout

```
samples/CameraAccess/
├── CameraAccess.xcodeproj
├── CameraAccess/
│   ├── CameraAccessApp.swift          # Wearables.configure(), Bonjour, mock-device wiring
│   ├── Info.plist                     # MWDAT keys, Bonjour (_retrace._tcp), entitlements
│   ├── Models/
│   │   └── ProcedureModels.swift      # Codable mirrors of server models
│   ├── Services/
│   │   ├── BonjourDiscovery.swift     # NetService browser for _retrace._tcp
│   │   ├── GeminiLiveService.swift    # Direct WebSocket to Gemini Live + tool call plumbing
│   │   ├── GeminiTokenManager.swift   # Fetches & refreshes ephemeral tokens from the server
│   │   ├── LocalProgressStore.swift   # On-device session/step progress
│   │   ├── ProcedureAPIService.swift  # REST client for /api/procedures and /api/learner
│   │   └── VoicePreviewPlayer.swift
│   ├── Utils/
│   │   ├── AudioSessionManager.swift
│   │   ├── ExpertRecordingManager.swift
│   │   ├── UploadService.swift        # multipart POST to /api/expert/upload
│   │   └── RetraceColors / Spacing / Typography.swift
│   ├── ViewModels/
│   │   ├── WearablesViewModel.swift   # DAT registration state
│   │   ├── StreamSessionViewModel.swift
│   │   ├── CoachingSessionViewModel.swift
│   │   ├── DiscoverViewModel.swift
│   │   ├── WorkflowListViewModel.swift
│   │   ├── ProcedureDetailViewModel.swift
│   │   └── DebugMenuViewModel.swift
│   └── Views/
│       ├── MainAppView.swift          # Routes registered vs unregistered
│       ├── HomeScreenView.swift       # Onboarding / connect
│       ├── ModeSelectionView.swift    # Expert vs Learner
│       ├── RegistrationView.swift
│       ├── ServerSettingsView.swift
│       ├── DebugMenuView.swift
│       ├── Components/                # Reusable UI (cards, chips, buttons, progress bar, …)
│       ├── Expert/
│       │   ├── ExpertTabView.swift
│       │   ├── RecordTabView.swift
│       │   ├── WorkflowListView.swift
│       │   ├── ProcedureDetailView.swift
│       │   ├── ProcedureEditView.swift
│       │   └── StepEditView.swift
│       └── Learner/
│           ├── LearnerTabView.swift
│           ├── LearnerProcedureDetailView.swift
│           ├── Discover/DiscoverView.swift
│           ├── Library/LibraryView.swift
│           ├── Coaching/CoachingSessionView.swift
│           ├── Coaching/PiPReferenceView.swift
│           ├── Profile/ProfileView.swift
│           ├── Profile/VoiceSelectionView.swift
│           └── Progress/LearnerProgressView.swift
├── CameraAccessTests/
└── CameraAccessUITests/
```

## DAT SDK Integration

- `Wearables.configure()` runs at launch (see `CameraAccessApp.swift`).
- `StreamSession` + `AutoDeviceSelector` provide the camera feed.
- `MWDATMockDevice` lets you run the whole app without hardware — the UI-testing target autowires `MockRaybanMeta` with bundled `plant.mp4` / `plant.png` resources.
- See [Meta's DAT SDK docs](https://wearables.developer.meta.com/docs/develop/) for SDK reference. The AI assistant rules in `.claude/` and `.cursor/rules/` are pre-configured with SDK conventions.

## Working on this app

> **Adding a new Swift file?** The target uses a traditional `PBXGroup`, so new files on disk are **not** compiled until they are registered in `project.pbxproj`. Use the helper script in the root `CLAUDE.md` (`pbxproj` Python module) to add any new `.swift` file to the `CameraAccess` target immediately after creating it.

Permissions configured in `Info.plist`:

- `NSBluetoothAlwaysUsageDescription` — DAT SDK Bluetooth
- `NSMicrophoneUsageDescription` — expert narration capture
- `NSLocalNetworkUsageDescription` + `NSBonjourServices` — server discovery
- `NSPhotoLibraryAddUsageDescription` — save captured photos

## License

This source code is licensed under the license found in the LICENSE file in the root directory of this source tree.
