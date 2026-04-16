# Retrace iOS App — Design Specification

> Reference document for all UI/UX implementation. Minimalistic, professional, polished.

---

## 0. Design Philosophy & Brand Context

### Target Users

Retrace serves **industrial workers, service technicians, and skilled tradespeople** — not consumers browsing content for fun. The XRCC Berlin 2026 track sponsors define our audience:

- **WMF** service technicians maintaining professional coffee machines (320+ techs, error codes, lockout procedures)
- **Hettich** furniture fitters doing precision hinge/drawer adjustments (500+ page catalogs, 1-2mm tolerances)
- **Gira** electricians installing KNX smart home systems (3-day certification, only 1% of electricians qualified)
- **tesa** industrial adhesive applicators (surface prep, pressure, product selection)
- **Europa-Park** seasonal staff learning 100+ attraction procedures in weeks
- **Hornbach** DIY customers attempting installations (45% failure rate)
- **Vodafone** network equipment installers

These users work with their hands, often in loud/dirty environments, wearing gloves, glancing at phones between physical steps. They need **clarity over cleverness, legibility over aesthetics, and trust over delight**.

### Design Principles

1. **Industrial clarity** — High contrast, large touch targets, scannable layouts. Think instrument panel, not social feed. Every element earns its screen space
2. **Tool, not toy** — No gamification gimmicks, no playful illustrations, no rounded-bubbly aesthetics. This is a professional tool that happens to be well-designed. Closer to Flir/Bosch professional apps than Duolingo
3. **Glanceable in the field** — Key information (current step, progress, status) readable at arm's length. Bold type, strong hierarchy, minimal decoration
4. **Trust through structure** — Clean data presentation, visible status indicators, explicit actions. Technicians need to trust the instructions — the UI should feel precise and reliable
5. **Dark-first for environments** — Dark theme reduces glare in workshops, kitchens, server rooms. High-contrast text ensures readability under variable lighting

### Visual Language

- **Typography:** System SF with weight contrast (not decorative fonts). Bold for hierarchy, monospace for technical data (timestamps, durations, error codes)
- **Color:** Restrained palette. Single accent color for interactive elements. Status colors (green/orange/red) used structurally, not decoratively
- **Surfaces:** Subtle elevation via opacity differences on black. No gradients, no blur effects, no glassmorphism. Flat, functional surfaces
- **Iconography:** SF Symbols only. Outline style for navigation, filled for active states. No custom illustrations
- **Motion:** Functional transitions only (step advance, expand/collapse). No bouncy animations, no confetti, no celebration screens beyond a simple checkmark
- **Density:** Moderate information density — technicians are literate users who can handle data-rich screens. Don't over-simplify. Show step counts, durations, timestamps, tips, and warnings without hiding them behind extra taps

### Content Tone

- Step titles: imperative, action-oriented ("Remove the drip tray", "Disconnect power supply")
- Descriptions: concise, technical, specific ("Turn counterclockwise until the latch releases")
- Labels: functional nouns ("Workflows", "Steps", "Duration" — not "Your Journey", "Missions", "Time Invested")
- Status: explicit states ("Processing", "Completed", "Failed" — not "Almost there!", "Great job!")

---

## 1. Design System

### 1.1 Color Palette

| Token | Value | Usage |
|-------|-------|-------|
| `Color.appPrimary` | `#0064E0` | Accent, selected states, CTAs, active indicators |
| `Color.destructiveBackground` | `#FFD8DB` | Destructive button backgrounds |
| `Color.destructiveForeground` | `#FFD8DB` | Destructive button text |
| Background | `Color.black` | All screen backgrounds |
| Card fill | `Color(.systemGray6).opacity(0.15)` | Cards, inputs, elevated surfaces |
| Card border | `Color.appPrimary.opacity(0.3)` | Active/enabled card outlines (1px) |
| Text primary | `Color.white` | Headings, body text |
| Text secondary | `Color.gray` | Subtitles, metadata, descriptions |
| Text tertiary | `Color.gray.opacity(0.6)` | Disabled text, hints |
| Success | `Color.green` | Completion indicators, connected status |
| Warning | `Color.orange` | Warning tags |
| Info | `Color.appPrimary` | Tip tags, processing states |

### 1.2 Typography

| Style | Spec | Usage |
|-------|------|-------|
| Display | System 36pt bold | App title on ModeSelectionView |
| Title 1 | System 22pt bold | Screen titles, procedure names |
| Title 2 | System 18pt semibold | Card titles, section headers |
| Title 3 | System 16pt semibold | List item titles |
| Body | System 15-16pt regular | Descriptions, instructions |
| Caption | System 13-14pt regular | Metadata, subtitles |
| Overline | System 13pt semibold uppercase | Section labels ("STEPS", "ANALYTICS") |
| Mono | System monospaced | Durations, timestamps, IP addresses, file sizes |
| Button | System 15pt semibold | Button labels |

### 1.3 Spacing & Layout

| Token | Value |
|-------|-------|
| Screen padding (horizontal) | 24pt |
| Section spacing | 32pt |
| Card internal padding | 20pt |
| Element spacing (tight) | 8pt |
| Element spacing (normal) | 12pt |
| Element spacing (loose) | 16pt |

### 1.4 Corner Radii

| Element | Radius |
|---------|--------|
| Buttons (CustomButton) | 30pt |
| Cards (ModeCard, CardView) | 16pt |
| Icon containers | 12pt |
| Input fields | 12pt |
| Clips / media | 8pt |
| Tags / pills | 6pt |

### 1.5 Shadows & Elevation

- Cards: `shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)`
- Minimal use — the dark theme relies on surface opacity differences rather than shadows

### 1.6 Component Catalog

#### Existing Components (reuse as-is)

| Component | File | Spec |
|-----------|------|------|
| `CustomButton` | `Views/Components/CustomButton.swift` | Full-width, 56pt height, 30pt radius. Styles: `.primary` (blue bg, white text), `.destructive` (pink bg/text) |
| `CircleButton` | `Views/Components/CircleButton.swift` | 56x56 white circle with icon + optional label |
| `CardView` | `Views/Components/CardView.swift` | Container with background, corner radius, shadow |
| `ModeCard` | `Views/ModeSelectionView.swift` | Icon + title + subtitle row card. Blue border when enabled |
| `StatusText` | `Views/Components/StatusText.swift` | Status message display |

#### New Components (to build)

| Component | Purpose | Spec |
|-----------|---------|------|
| `MetadataPill` | Compact info badge | Capsule shape, `systemGray6` at 15% fill, caption text. Shows duration, step count, date, etc. |
| `StatCard` | Analytics number display | Vertical stack: large number (Title 1, white) + label (Caption, gray). Card fill background |
| `ProcedureCard` | Procedure list item | HStack: left badge + center (title, description 2-line clamp, metadata pills) + chevron. ModeCard styling |
| `CategoryChip` | Filter pill | Capsule, unselected = card fill + white text, selected = `appPrimary` fill + white text |
| `EditableStringList` | Array editor for tips/warnings | List of text rows with delete (red minus), add button at bottom. Used in StepEditView |
| `StepProgressBar` | Discrete step indicator | Segmented horizontal bar, `appPrimary` fill on completed segments, gray track |

---

## 2. App Navigation Architecture

```
CameraAccessApp
  └── MainAppView
        ├── HomeScreenView (unregistered — onboarding + connect glasses)
        └── ModeSelectionView (registered — choose mode)
              ├── Expert Mode → ExpertTabView
              │     ├── Tab 1: "Workflows" → WorkflowListView
              │     │     └── push: ProcedureDetailView
              │     │           ├── push: ProcedureEditView
              │     │           └── push: StepEditView
              │     └── Tab 2: "Record" → RecordTabView
              │           └── StreamSessionView (existing)
              │                 └── sheet: ExpertRecordingReviewView (existing)
              │
              └── Learner Mode → LearnerTabView
                    ├── Tab 1: "Procedures" → DiscoverView
                    │     ├── overlay: SearchView
                    │     └── push: ProcedureDetailView (learner)
                    │           └── fullScreenCover: CoachingSessionView
                    ├── Tab 2: "Library" → LibraryView
                    │     └── push: ProcedureDetailView (learner)
                    ├── Tab 3: "Progress" → ProgressView
                    └── Tab 4: "Profile" → ProfileView
```

### Tab Bar Styling

- Background: black
- Unselected: white icons
- Selected: `Color.appPrimary` icon + label
- Expert tab icons: `list.bullet.rectangle.portrait` (Workflows), `video.badge.plus` (Record)
- Learner tab icons: `wrench.and.screwdriver` (Procedures), `books.vertical` (Library), `chart.bar` (Progress), `person.circle` (Profile)

---

## 3. Expert Flow

### 3.1 ExpertTabView

**Purpose:** Container for the two-tab Expert experience.

**Behavior:**
- Each tab wraps its own `NavigationStack`
- When a recording completes successfully in Tab 2, programmatically switch to Tab 1 and push to the new procedure's `ProcedureDetailView`
- Uses shared `@State selectedTab` binding

---

### 3.2 WorkflowListView (Tab 1: Workflows)

**Purpose:** "My Workflows" — all procedures the expert has created.

**Layout (top → bottom):**

1. **Navigation bar**
   - Large title: "Workflows"
   - Trailing: gear icon → ServerSettingsView

2. **Summary strip** — horizontal row of `MetadataPill` components
   - "X procedures" | "Y total steps"

3. **Procedure list** — vertical scroll of `ProcedureCard` items
   - Each card shows: step count badge (circle, `appPrimary` bg) | title + description (2-line) + metadata pills (duration, date) | chevron
   - **Processing state:** pulsing `appPrimary` dot, subtitle "Processing with AI..." in accent color
   - **Failed state:** red dot, error message in red

4. **Empty state** (no procedures)
   - SF Symbol `video.badge.plus` at 48pt in `appPrimary`
   - "No workflows yet"
   - "Record your first procedure using your glasses or upload a video"
   - `CustomButton` "Start Recording" → switches to Tab 2

**Interactions:**
- Tap card → push `ProcedureDetailView`
- Swipe left → red "Delete" action
- Pull to refresh → re-fetch from `GET /api/procedures`

**Data:** `WorkflowListViewModel` fetches `GET /api/procedures`, returns list items with id, title, description, total_duration, created_at, status, step_count.

---

### 3.3 ProcedureDetailView

**Purpose:** Full read view of a single procedure. The expert's primary review surface.

**Layout (ScrollView, top → bottom):**

1. **Navigation bar**
   - Back arrow
   - Trailing: "Edit" text button + overflow menu (`...`) with "Share" and "Delete"

2. **Header**
   - Title (Title 1, white)
   - Description (Body, gray)
   - Metadata row: duration pill, step count pill, created date pill

3. **Analytics card** (section label: "ANALYTICS")
   - Grid of `StatCard` items: "Learners Trained", "Completion Rate", "Avg. Time"
   - For hackathon: show "0" / "—" with subtle "Coming with Learner Mode" label
   - Card fill background, 16pt radius

4. **Steps section** (section label: "STEPS")
   - Vertical list of expandable step cards
   - Collapsed: step number (`appPrimary`), title, timestamp range
   - Expanded: + description, video clip player, tips (blue tags), warnings (orange tags)
   - Pencil icon on each step header → push `StepEditView`

5. **Source video section** (section label: "SOURCE RECORDING")
   - Full video player for original uploaded video
   - Collapsible via disclosure group

**Interactions:**
- Tap step → expand/collapse
- Tap "Edit" → push `ProcedureEditView`
- Tap step pencil → push `StepEditView`
- Tap "Delete" in overflow → confirmation alert → `DELETE /api/procedures/{id}` → pop to list

**Data:** `ProcedureDetailViewModel` fetches `GET /api/procedures/{id}`, returns full `ProcedureResponse`.

---

### 3.4 ProcedureEditView

**Purpose:** Edit procedure-level fields. Pushed from ProcedureDetailView.

**Layout:**

1. **Navigation bar**
   - Leading: "Cancel"
   - Trailing: "Save" (in `appPrimary`, disabled until changes detected)
   - Title: "Edit Workflow"

2. **Form fields** (ScrollView, not SwiftUI Form — to maintain dark theme)
   - **Title** — label (Overline) + TextField, card fill background, `appPrimary` border on focus
   - **Description** — label + TextEditor, minimum 3 lines

3. **Step order section** (section label: "STEP ORDER")
   - List of step titles with drag handles
   - Each row: drag icon + step number + title
   - `.onMove` modifier for reordering

4. **Danger zone**
   - "Delete Procedure" `CustomButton` with `.destructive` style

**Data:** Requires `PUT /api/procedures/{id}` endpoint (new). Sends updated title, description, step order array.

---

### 3.5 StepEditView

**Purpose:** Edit a single step. Pushed from ProcedureDetailView.

**Layout:**

1. **Navigation bar**
   - Leading: "Cancel"
   - Trailing: "Save" (`appPrimary`)
   - Title: "Edit Step X"

2. **Fields**
   - **Title** — TextField
   - **Description** — TextEditor, 4+ lines
   - **Tips** — `EditableStringList` with `appPrimary` accent. Each row: text + red minus to delete. "Add Tip" button at bottom
   - **Warnings** — `EditableStringList` with orange accent. Same pattern
   - **Timestamps** — Start/End in compact time format (less likely to need editing, shown for transparency)

3. **Clip preview** — small video player for the step's clip (read-only reference)

**Data:** Requires `PUT /api/procedures/{id}/steps/{step_number}` endpoint (new).

---

### 3.6 RecordTabView (Tab 2: Record)

**Purpose:** Wrapper around the existing recording flow, adding an upload-from-library option.

**Landing state** (no active stream):
- SF Symbol `video.fill` in `appPrimary`
- "Record a New Procedure" (Title 2)
- "Stream from your glasses and record, or upload an existing video" (Body, gray)
- Two action cards (ModeCard style):
  - "Record with Glasses" → existing StreamSessionView/NonStreamView flow
  - "Upload Video" → MediaPickerView → ExpertRecordingReviewView

**Active state:** existing StreamView with recording controls.

**Completion:** After successful processing, show procedure title + step count, then "View Procedure" button switches to Tab 1 and pushes to ProcedureDetailView.

---

## 4. Learner Flow

### 4.1 LearnerTabView

**Purpose:** Container for the four-tab Learner experience.

Same dark tab bar styling. Each tab wraps its own `NavigationStack`.

---

### 4.2 DiscoverView (Tab 1: Procedures)

**Purpose:** Browse and find procedures to learn. The primary content discovery surface. Framed as a professional procedure catalog, not a content feed.

**Layout (ScrollView, top → bottom):**

1. **Header bar**
   - Large title: "Procedures"
   - Trailing: glasses connection indicator (green/gray dot) + search icon

2. **Search bar** — rounded rect with magnifying glass icon
   - Tapping opens `SearchView` as a full-screen overlay
   - Live filtering by title, description (client-side over fetched procedures)
   - Placeholder text: "Search by device, task, or error code..."

3. **"Resume Session" card** (conditional — shown if in-progress session exists)
   - Full-width card with `appPrimary` border
   - Procedure title + progress indicator (steps completed / total, linear bar not ring)
   - "Resume" button
   - Most important CTA on screen — placed above all browsing content

4. **Category chips** — horizontal scroll row
   - "All", "Coffee Machines", "Electrical", "Assembly", "Maintenance", "Cleaning" (hardcoded for hackathon; maps to sponsor domains: WMF, Gira, Hettich, general)
   - `CategoryChip` styling: capsule, selected = `appPrimary` fill
   - Tapping filters the procedure list below

5. **Procedure list** — vertical list of `ProcedureCard` items
   - Each card: title, description (2-line), step count badge, duration badge
   - Metadata row: person icon + completion count, difficulty indicator (derived from step count / duration)
   - When no completion data: show "New" badge
   - Tap → push `ProcedureDetailView` (learner variant)

**Data:** `DiscoverViewModel` fetches `GET /api/procedures`, filters by category client-side.

---

### 4.3 SearchView

**Purpose:** Full-screen search with live results.

**Layout:**
- Top: search text field with cancel button
- Below: filtered list of `ProcedureCard` items matching query
- Empty state: "No results for [query]"

**Presentation:** overlay or NavigationLink push from DiscoverView.

---

### 4.4 ProcedureDetailView (Learner Variant)

**Purpose:** Full detail page for a procedure. The briefing screen before starting a guided session — like reviewing a work order before starting.

**Layout (ScrollView, top → bottom):**

1. **Header area**
   - Procedure title (Title 1, white)
   - Description (Body, gray)
   - Metadata row in `MetadataPill` components: `clock` + duration | `list.number` + step count | `person.2` + completions

2. **Completion stats bar**
   - Completions count + average completion time
   - Placeholder values for hackathon ("No data yet")

3. **Action buttons**
   - "Start Procedure" — `CustomButton` `.primary`, full width. Presents `CoachingSessionView` as `.fullScreenCover`
   - "Save to Library" — outline/secondary style. Toggles bookmark (bookmark icon fills with `appPrimary`)

4. **Steps overview** — reuse existing `StepDetailView` component
   - Expandable step list showing title, description, timestamps, tips, warnings, clip player
   - Gives the learner a preview of what they'll be walked through
   - Step numbers displayed prominently — technicians reference steps by number

5. **Warnings summary** (if any warnings exist across steps)
   - Aggregated warnings section at the bottom with orange tags
   - Safety-critical information surfaced prominently
   - Separate from tips — warnings deserve their own visibility in industrial contexts

6. **Tips section**
   - Aggregated tips across all steps, blue tags
   - Collapsible — less critical than warnings

**Data:** `GET /api/procedures/{id}`. Bookmark state stored in `UserDefaults` (Set of procedure IDs).

---

### 4.5 CoachingSessionView

**Purpose:** The core real-time coaching experience. Full-screen, hands-free optimized.

**Presentation:** `.fullScreenCover` from SkillDetailView.

**Initialization flow:**
1. Start `StreamSession` (reuse same DAT SDK pattern as expert mode)
2. Open Gemini Live WebSocket for voice (audio-only, 15-min session)
3. Begin streaming glasses mic audio to Gemini Live
4. Load procedure steps from server

**Screen layout:**

```
+----------------------------------------+
|  [X Close]              [Step 2 of 6]  |   Top bar
+----------------------------------------+
|                                        |
|   +----------+                         |
|   |  PiP     |   (reference clip)      |   Draggable overlay
|   +----------+                         |
|                                        |
|      Live camera feed from glasses     |   Full-screen background
|      (reuse StreamView frame render)   |
|                                        |
+----------------------------------------+
|  Step 2: Attach the foamer             |   Current step panel
|  Slide it onto the nozzle until        |   (semi-transparent black)
|  it clicks.                            |
|  [tip] Hold at 45 degrees             |
+----------------------------------------+
|  [===████████==========] 2/6           |   StepProgressBar
+----------------------------------------+
|  Voice: Listening...                   |   Voice status
|  [Mic]     [Next Step]     [Help]      |   Bottom controls
+----------------------------------------+
```

**Component details:**

- **Top bar:** Close (X) on left with confirmation alert. "Step N of M" on right
- **Live camera feed:** Reuses `StreamSession` + `VideoFrame` rendering from expert `StreamView`. If no glasses connected: dark placeholder with "Connect glasses to see live view"
- **PiP reference overlay:** 120x90pt draggable thumbnail (top-right default). Shows expert's reference clip for current step from `GET /api/clips/{id}/step_{n}.mp4`. Drag via `DragGesture`, dismiss by swiping off-screen
- **Step instruction panel:** Semi-transparent black card over bottom third. Title (Title 3, white) + description (Body, gray) + tip tags. Animated transition on step advance: current slides left, next slides in from right (`.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading))`)
- **Step progress bar:** `StepProgressBar` component. `appPrimary` fill, gray track, discrete segments
- **Voice status indicator:**
  - "Listening..." + pulsing mic icon (receiving audio)
  - "Speaking..." + animated waveform (Gemini responding)
  - "Connecting..." + spinner
  - "Disconnected" + retry button
- **Bottom controls:** three `CircleButton` items
  - Mic toggle (mute/unmute)
  - "Next Step" (manual advance via server)
  - "Help" (triggers "Can you explain this step again?" to Gemini)

**Completion state:** Bottom panel transforms into completion card:
- Checkmark icon (simple, no animation beyond a fade-in)
- "Procedure Complete" (no exclamation — keep it professional)
- Total time taken + steps completed
- "Done" button dismisses the session
- No confetti, no celebratory animations — this is a work tool

**Data:** `CoachingSessionViewModel` manages StreamSession, Gemini Live WebSocket, step state polling, tool call forwarding.

---

### 4.6 LibraryView (Tab 2: Library)

**Purpose:** Personal collection of saved and attempted procedures.

**Layout:**

1. **Header:** Large title "My Library"

2. **Segmented control:** "Saved" | "History"

3. **Saved segment:**
   - List of `ProcedureCard` items for bookmarked procedure IDs
   - Fetches full data from `GET /api/procedures/{id}` per saved ID
   - Empty state: bookmark.slash icon + "No saved procedures yet. Discover skills and save them here."

4. **History segment:**
   - List of session records:
     - Procedure title
     - Date (formatted)
     - Status badge: "Completed" (green) / "In Progress" (accent) / "Abandoned" (gray)
     - Steps completed / total
   - Tap → push SkillDetailView
   - Empty state: clock.arrow.circlepath icon + "No learning history yet"

**Data:** UserDefaults-backed `LocalProgressStore`. Saved = `Set<String>` of procedure IDs. History = `[SessionRecord]` (Codable).

---

### 4.7 ProgressView (Tab 3: Progress)

**Purpose:** Training log and statistics. Framed as a professional competency record — useful for technicians tracking certifications or managers auditing training completion.

**Layout (ScrollView, top → bottom):**

1. **Header:** Large title "Training Log"

2. **Stats cards** — horizontal scroll of 3 `StatCard` items:
   - "Procedures Completed" — count
   - "Total Steps" — sum of steps across completed procedures
   - "Time Trained" — sum of session durations (formatted as Xh Ym)

3. **Activity overview** — row of last 7 days
   - Circle per day: `appPrimary` fill = active, gray outline = inactive
   - Day labels (Mon, Tue, etc.)
   - Functional tracking, not gamification — no "streak" language

4. **Session history** — chronological list
   - "Completed: [title] (N steps, M:SS)" with date
   - "Started: [title]" with date
   - Tap → push ProcedureDetailView (learner variant)

**Data:** All from `LocalProgressStore`. Computed from session history records.

---

### 4.8 ProfileView (Tab 4: Profile)

**Purpose:** Identity, glasses connection, app settings.

**Layout (ScrollView, sections):**

1. **Profile header**
   - Avatar placeholder: `person.circle.fill` large, `appPrimary`
   - Display name (from UserDefaults or hardcoded for hackathon)

2. **Glasses section** (section label: "DEVICE")
   - Connection status card: glasses model + status (Connected/Disconnected)
   - "Reconnect" / "Disconnect" button
   - Links to existing registration flow

3. **Server section** (section label: "SERVER")
   - Link to existing `ServerSettingsView`

4. **Preferences section** (section label: "PREFERENCES")
   - Voice selection: picker for Gemini voice ("Puck", "Charon", etc.)
   - Auto-advance toggle: whether steps auto-advance on visual verification

5. **About section**
   - "Retrace v1.0"
   - "Record an expert once. Coach every learner forever."

---

## 5. Data Architecture

### 5.1 Existing API Endpoints (no changes needed)

| Endpoint | Used by |
|----------|---------|
| `GET /api/procedures` | WorkflowListView, DiscoverView |
| `GET /api/procedures/{id}` | ProcedureDetailView, SkillDetailView |
| `DELETE /api/procedures/{id}` | WorkflowListView, ProcedureDetailView |
| `POST /api/expert/upload` | RecordTabView (existing) |
| `GET /api/clips/{id}/step_{n}.mp4` | Step clips, PiP reference |
| `GET /api/uploads/{filename}` | Source video playback |

### 5.2 New API Endpoints Needed

| Endpoint | Purpose | Used by |
|----------|---------|---------|
| `PUT /api/procedures/{id}` | Update title, description, step order | ProcedureEditView |
| `PUT /api/procedures/{id}/steps/{n}` | Update step fields | StepEditView |
| `GET /api/procedures/{id}/stats` | Learner analytics (stub) | ProcedureDetailView |

### 5.3 Local Storage (UserDefaults)

| Key | Type | Purpose |
|-----|------|---------|
| `serverBaseURL` | `String` | Server URL (existing) |
| `savedProcedureIDs` | `Set<String>` | Bookmarked procedures |
| `sessionHistory` | `[SessionRecord]` | Completed/in-progress sessions |
| `geminiVoice` | `String` | Preferred Gemini voice |
| `autoAdvanceEnabled` | `Bool` | Auto-advance on visual verification |

### 5.4 New iOS Models

```swift
// List item (lighter than ProcedureResponse)
struct ProcedureListItem: Codable, Identifiable {
    let id: String
    let title: String
    let description: String
    let totalDuration: Double
    let createdAt: String
    let status: String?
    let stepCount: Int
}

// Edit requests
struct ProcedureUpdateRequest: Codable {
    var title: String?
    var description: String?
    var stepOrder: [Int]?
}

struct StepUpdateRequest: Codable {
    var title: String?
    var description: String?
    var tips: [String]?
    var warnings: [String]?
    var timestampStart: Double?
    var timestampEnd: Double?
}

// Local session tracking
struct SessionRecord: Codable, Identifiable {
    let id: String  // UUID
    let procedureId: String
    let procedureTitle: String
    let startedAt: Date
    var completedAt: Date?
    var stepsCompleted: Int
    var totalSteps: Int
    var status: SessionStatus  // .inProgress, .completed, .abandoned
}
```

---

## 6. New ViewModels

| ViewModel | Responsibility |
|-----------|---------------|
| `WorkflowListViewModel` | Fetch procedure list, delete, pull-to-refresh |
| `ProcedureDetailViewModel` | Fetch full procedure, manage expansion state, delete |
| `ProcedureEditViewModel` | Track edited fields, detect changes, save |
| `StepEditViewModel` | Track edited step fields, manage tip/warning arrays, save |
| `DiscoverViewModel` | Fetch procedures, filter by category/search |
| `CoachingSessionViewModel` | StreamSession, Gemini Live WebSocket, step state, tool calls |
| `LibraryViewModel` | Manage saved/history from LocalProgressStore |
| `LocalProgressStore` | UserDefaults persistence for bookmarks, history, stats |

All: `@MainActor`, `ObservableObject`, async/await networking.

---

## 7. File Structure (new files)

```
Views/
  Expert/
    ExpertTabView.swift
    WorkflowListView.swift
    ProcedureDetailView.swift
    ProcedureEditView.swift
    StepEditView.swift
    RecordTabView.swift
  Learner/
    LearnerTabView.swift
    Discover/
      DiscoverView.swift
      SearchView.swift
      CategoryChipView.swift
    SkillDetailView.swift
    Coaching/
      CoachingSessionView.swift
      StepInstructionPanel.swift
      PiPReferenceView.swift
      VoiceStatusView.swift
      SessionCompleteView.swift
    Library/
      LibraryView.swift
    Progress/
      ProgressView.swift
    Profile/
      ProfileView.swift
  Components/
    MetadataPill.swift
    StatCard.swift
    ProcedureCardView.swift
    EditableStringList.swift
    StepProgressBar.swift

ViewModels/
  WorkflowListViewModel.swift
  ProcedureDetailViewModel.swift
  ProcedureEditViewModel.swift
  StepEditViewModel.swift
  DiscoverViewModel.swift
  CoachingSessionViewModel.swift
  LibraryViewModel.swift

Services/
  LearnerAPIService.swift
  GeminiLiveService.swift
  LocalProgressStore.swift

Models/
  SessionModels.swift
```

---

## 8. Interaction Patterns

| Interaction | Pattern |
|-------------|---------|
| Card tap | Push onto NavigationStack |
| Swipe left on list item | Destructive action (delete) |
| Pull down on list | Refresh data |
| Step expand/collapse | Disclosure with chevron rotation animation |
| Bookmark toggle | Icon fills with spring animation |
| Step advance (coaching) | Slide left/right transition |
| PiP reference | Draggable via DragGesture, dismiss by swiping off-screen |
| Session start | `.fullScreenCover` presentation |
| Edit screens | Push navigation with Cancel/Save in nav bar |
| Tab switch on completion | Programmatic tab selection via binding |
| Long press | Not used (keep interactions discoverable) |

---

## 9. Implementation Priority

### Phase 1: Expert Management (foundation)
1. `ExpertTabView` + `WorkflowListView` — procedure list browsing
2. `ProcedureDetailView` — full procedure view with expandable steps
3. `RecordTabView` — wrap existing recording flow + add upload option
4. Wire completion from recording → procedure detail

### Phase 2: Expert Editing
5. Backend: `PUT` endpoints for procedure and step editing
6. `ProcedureEditView` with step reordering
7. `StepEditView` with tip/warning editing

### Phase 3: Learner Browse
8. `LearnerTabView` + `DiscoverView` — procedure browsing
9. `SkillDetailView` — procedure detail for learners
10. `LibraryView` + `LocalProgressStore` — bookmarks and history
11. `ProgressView` — stats dashboard
12. `ProfileView` — settings and device management

### Phase 4: Learner Coaching Session
13. `CoachingSessionView` — live camera feed + step panel + controls
14. `GeminiLiveService` — voice WebSocket integration
15. PiP reference overlay
16. Visual verification integration
17. Session completion flow

### Phase 5: Polish
18. Analytics section on ProcedureDetailView (stub data)
19. Social proof placeholders on DiscoverView / SkillDetailView
20. Activity streak on ProgressView
21. Animations and transitions
22. Empty states throughout
23. Error states and retry patterns
