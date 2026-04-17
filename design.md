# Retrace iOS App — Design Specification

> Reference document for all UI/UX implementation. Minimalistic, professional, polished.
> Brand aesthetic: high-contrast monochrome with Hazard yellow as functional accent — a tool, not a toy.

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
5. **Dark-first for environments** — Deep OLED black reduces glare in workshops, kitchens, server rooms. High-contrast text ensures readability under variable lighting

### Visual Language

- **Typography:** Golos Text mapped to iOS HIG type scale. Until font files ship, `Font.system(...)` renders the same sizes/weights as a faithful fallback. Bold for hierarchy, SF Mono for technical data (timestamps, durations, error codes)
- **Color:** Monochrome Ink scale (ink950 → ink50) carries structure and hierarchy. **Hazard yellow** is the single functional accent, reserved for live/active indicators — never decoration. White is the CTA fill
- **Surfaces:** Layered via Ink opacity on OLED black. No gradients, no blur effects, no glassmorphism. Flat, functional surfaces differentiated by Ink level
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

The palette is two families — **Ink** for monochrome structure, **Hazard** for the single accent — plus a small semantic fallback set for system statuses. All colors resolve through named Asset Catalog entries so tokens can be retuned centrally.

**Ink (monochrome foundation)**

| Token | Hex | Asset name | Usage |
|-------|-----|------------|-------|
| `ink50` | `#F9FAFB` | `textPrimary` | Primary text, hero CTA fill, selected tab/chip |
| `ink100` | `#F3F4F6` | `textSecondary` | Subtitles, supporting copy |
| `ink200` | `#E5E7EB` | `textTertiary` | Tertiary text, subtle borders, overlines |
| `ink400` | `#9CA3AF` | `borderSubtle` | Inactive icons, placeholders, disabled text |
| `ink700` | `#374151` | `surfaceRaised` | Surface L2 (pressed/hover), step number badges |
| `ink800` | `#1F2937` | `surfaceBase` | Surface L1 (default cards, inputs) |
| `ink900` | `#111827` | `backgroundPrimary` | Deep section backgrounds |
| `ink950` | `#030712` | (app bg) | App background — deep OLED black |

**Hazard (functional accent)**

| Token | Hex | Asset name | Usage |
|-------|-----|------------|-------|
| `hazard500` | `#EAB308` | `appPrimaryColor` | Live recording dot, "REC"/"LIVE" badges, active tracking, session-live logo stroke, voice-listening pulse, focus ring, active streak days |
| `hazard600` | `#CA8A04` | `accentMuted` | Pressed/active state for hazard elements |

**Semantic fallbacks** (kept for system statuses only — not for brand expression)

| Token | Value | Asset | Usage |
|-------|-------|-------|-------|
| Success | `Color.green` | `semanticSuccess` | Glasses connected, successful completion |
| Warning | `Color.orange` | (inline) | Warning tags on steps |
| Error | red | `semanticError` | Failed recordings, destructive confirmations |
| Destructive bg | `#3A1618` | `destructiveBackground` | Destructive button background |
| Destructive fg | `#FFD8DB` | `destructiveForeground` | Destructive button text |

### 1.2 Typography

Golos Text mapped to Apple Human Interface Guidelines. Until the font files are embedded, every style is rendered with `Font.system(...)` at the exact sizes/weights/tracking below — swap is a drop-in later.

| Style | Size | Weight | Tracking | Usage |
|-------|------|--------|----------|-------|
| Large Title | 34pt | Bold (700) | -0.4pt | Screen titles ("Workflows", "Procedures", "My Library") |
| Title 1 | 28pt | Bold (700) | -0.3pt | Procedure names, hero section headers |
| Title 2 | 22pt | Bold (700) | -0.3pt | Card titles, sub-section headers |
| Title 3 | 18pt | Semibold (600) | -0.3pt | List item titles |
| Headline | 17pt | Semibold (600) | -0.4pt | Emphasized body, step titles |
| Body | 17pt | Regular (400) | -0.4pt | Descriptions, instructions |
| Callout | 16pt | Regular (400) | -0.3pt | Supporting body text, button labels |
| Footnote | 13pt | Regular (400) | 0pt | Metadata, timestamps |
| Caption 1 | 12pt | Medium (500) | 0pt | Pills, overlines, section labels |
| Mono | — | Regular | — | SF Mono for durations, timestamps, IPs, error codes (Golos has no mono variant) |

The **"RETRACE" wordmark** uses letter-spaced Title 1 Bold, all caps, `ink50` on `ink950`.

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

| Element | Radius | Rationale |
|---------|--------|-----------|
| `CustomButton` | 30pt (capsule) | Preserved — signature full-width pill across the app |
| Cards (ModeCard, CardView) | 16pt | |
| Icon containers | 12pt | |
| Input fields | 12pt | |
| Clips / media | 8pt | |
| Tags / pills | 6pt | |

### 1.5 Elevation & Surface Hierarchy

No shadows. Elevation is carried entirely by Ink-level contrast on OLED black:

- **L0** — `ink950` app background
- **L1** — `ink800` default card / input surface
- **L2** — `ink700` pressed / hover / step number badge

A 1pt stroke in `ink700` at low opacity may be added for extra definition where cards sit directly on `ink950`. Avoid shadow radii on OLED — they read as grey smudges, not depth.

### 1.6 Component Catalog

**Existing components (reuse as-is, retuned tokens)**

| Component | File | Spec |
|-----------|------|------|
| `CustomButton` | `Views/Components/CustomButton.swift` | Full-width, 56pt height, 30pt capsule. **Primary**: `ink50` fill, `ink950` text (the "Hero CTA" — mirrors the reference "Start Journey" button). **Destructive**: `destructiveBackground` fill, `destructiveForeground` text |
| `CircleButton` | `Views/Components/CircleButton.swift` | 56x56 circle with icon + optional label |
| `CardView` | `Views/Components/CardView.swift` | `ink800` fill, 16pt radius, no shadow |
| `ModeCard` | `Views/ModeSelectionView.swift` | `ink800` fill, `ink700` stroke at rest, `hazard500` stroke when a live session is active. Icon + title + subtitle |
| `StatusText` | `Views/Components/StatusText.swift` | Status message display |

**New / refactored components**

| Component | Purpose | Spec |
|-----------|---------|------|
| `MetadataPill` | Compact info badge | Capsule, `ink800` fill, Caption 1 text in `ink100`. Shows duration, step count, date |
| `StatCard` | Analytics number display | Vertical stack: large number (Title 1, `ink50`) + label (Caption 1, `ink200`). `ink800` fill |
| `ProcedureCardView` | Procedure list item | HStack: step-count badge (`ink700` circle, `ink50` number) + center (title, description 2-line clamp, metadata pills) + chevron. Card styling |
| `CategoryChip` | Filter pill | Capsule. Unselected = `ink800` fill + `ink100` text. **Selected = `ink50` fill + `ink950` text** (mirrors hero CTA — Hazard is *not* used for selection) |
| `EditableStringList` | Array editor for tips/warnings | List of text rows with destructive minus, add button at bottom. Tips use `ink50` text on `ink800`; warnings use `Color.orange` tag |
| `StepProgressBar` | Discrete step indicator | Segmented horizontal bar, **`ink50` fill on completed segments**, `ink700` track. Hazard yellow is reserved for the live-session indicator that sits next to it, not the bar itself |

---

## 2. Brand Identity

### Logo

Overlapping diamonds: one solid, one hollow. The hollow diamond represents the learner **retracing** the expert's solid path — the core product metaphor rendered in the mark.

- **Idle:** both diamonds in `ink50` on `ink950`
- **Live session:** the hollow diamond's stroke shifts to `hazard500`, signaling that a session is currently tracking. This is the single place in the UI where the accent appears prominently on a brand surface

### Wordmark

"RETRACE" in Golos Text Bold (Title 1 scale), all caps, letter-spaced (+0.8pt tracking). Used on the splash, onboarding hero, and about section.

### Tagline

"Record an expert once. Coach every learner forever."

---

## 3. Accent Usage Rules

Hazard yellow is the most disciplined element of this system. The monochrome read only works if the accent stays rare. Use this table when in doubt:

**Yellow is allowed on:**
- Live recording dot and "REC" / "LIVE" badges
- Active session indicator (top bar of `CoachingSessionView`)
- Voice "Listening…" pulse, microphone-active ring
- Logo stroke during a live session
- Processing pulse on `ProcedureCardView` while a video is being segmented
- Streak/activity-day fill on `LearnerProgressView` for active days
- Focus ring on text fields and inputs

**Yellow is NOT allowed on:**
- Primary CTA fills → use `ink50` (white)
- Selected tab icons/labels → use `ink50`
- Selected category chips → white fill, black text
- Step number badges → `ink700` circle, `ink50` number
- Links, emphasized body text, section headers
- Bookmark icons, chevrons, completed-step checkmarks

The rule of thumb: if it means "this is happening right now," it can be yellow. If it means "this is important" or "this is selected," it is white.

---

## 4. App Navigation Architecture

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
                    │     └── push: LearnerProcedureDetailView
                    │           └── fullScreenCover: CoachingSessionView
                    ├── Tab 2: "Library" → LibraryView
                    │     └── push: LearnerProcedureDetailView
                    ├── Tab 3: "Progress" → LearnerProgressView
                    └── Tab 4: "Profile" → ProfileView
```

### Tab Bar Styling

- Background: `ink950`
- Unselected: `ink400` icons and labels
- **Selected: `ink50` (white) icon + label — never Hazard yellow.** Yellow is reserved for live session states (per §3)
- Expert tab icons: `list.bullet.rectangle.portrait` (Workflows), `video.badge.plus` (Record)
- Learner tab icons: `wrench.and.screwdriver` (Procedures), `books.vertical` (Library), `chart.bar` (Progress), `person.circle` (Profile)

---

## 5. Expert Flow

### 5.1 ExpertTabView

**Purpose:** Container for the two-tab Expert experience.

**Behavior:**
- Each tab wraps its own `NavigationStack`
- When a recording completes successfully in Tab 2, programmatically switch to Tab 1 and push to the new procedure's `ProcedureDetailView`
- Uses shared `@State selectedTab` binding

---

### 5.2 WorkflowListView (Tab 1: Workflows)

**Purpose:** "My Workflows" — all procedures the expert has created.

**Layout (top → bottom):**

1. **Navigation bar**
   - Large Title: "Workflows"
   - Trailing: gear icon → ServerSettingsView

2. **Summary strip** — horizontal row of `MetadataPill` components
   - "X procedures" | "Y total steps"

3. **Procedure list** — vertical scroll of `ProcedureCard` items
   - Step count badge (`ink700` circle, `ink50` number) | title + description (2-line) + metadata pills (duration, date) | chevron
   - **Processing state:** pulsing `hazard500` dot, subtitle "Processing with AI…" in `ink100`
   - **Failed state:** red dot (`semanticError`), error message in red

4. **Empty state** (no procedures)
   - SF Symbol `video.badge.plus` at 48pt in `ink400`
   - "No workflows yet"
   - "Record your first procedure using your glasses or upload a video"
   - `CustomButton.primary` "Start Recording" → switches to Tab 2

**Interactions:**
- Tap card → push `ProcedureDetailView`
- Swipe left → red "Delete" action
- Pull to refresh → re-fetch from `GET /api/procedures`

**Data:** `WorkflowListViewModel` fetches `GET /api/procedures`.

---

### 5.3 ProcedureDetailView

**Purpose:** Full read view of a single procedure. The expert's primary review surface.

**Layout (ScrollView, top → bottom):**

1. **Navigation bar** — Back arrow · "Edit" text button · overflow (`...`) with "Share" / "Delete"
2. **Header** — Title 1 in `ink50`, Body description in `ink100`, metadata row (duration · step count · created date pills)
3. **Analytics card** (section label: "ANALYTICS", Caption 1 in `ink200`, uppercase)
   - Grid of `StatCard` items: "Learners Trained", "Completion Rate", "Avg. Time"
   - For hackathon: show "0" / "—" with subtle "Coming with Learner Mode" label
4. **Steps section** (label: "STEPS")
   - Expandable step cards
   - Collapsed: step number (`ink50` in `ink700` circle), title, timestamp range
   - Expanded: description, video clip player, tip tags (`ink800` bg, `ink100` text), warning tags (`Color.orange` bg at 20%, `Color.orange` text)
   - Pencil icon on each step header → push `StepEditView`
5. **Source video section** (label: "SOURCE RECORDING") — collapsible via disclosure group

**Interactions:** Tap step → expand/collapse · Tap "Edit" → push `ProcedureEditView` · Tap pencil → push `StepEditView` · Tap "Delete" → confirmation → `DELETE /api/procedures/{id}` → pop to list.

---

### 5.4 ProcedureEditView

**Purpose:** Edit procedure-level fields. Pushed from ProcedureDetailView.

**Layout:**

1. **Navigation bar** — Leading "Cancel" · Trailing "Save" (`ink50`, disabled until changes detected) · Title "Edit Workflow"
2. **Form fields** (ScrollView, not SwiftUI Form — to maintain dark theme)
   - **Title** — Caption 1 overline + TextField, `ink800` fill, `hazard500` stroke on focus (focus ring is one of the sanctioned yellow surfaces per §3)
   - **Description** — label + TextEditor, minimum 3 lines
3. **Step order section** (label: "STEP ORDER") — list of step titles with drag handles; `.onMove` modifier
4. **Danger zone** — "Delete Procedure" `CustomButton.destructive`

**Data:** Requires new `PUT /api/procedures/{id}`.

---

### 5.5 StepEditView

**Purpose:** Edit a single step. Pushed from ProcedureDetailView.

**Layout:**

1. **Navigation bar** — Cancel · "Save" in `ink50` · Title "Edit Step X"
2. **Fields**
   - **Title** — TextField
   - **Description** — TextEditor, 4+ lines
   - **Tips** — `EditableStringList` with `ink50` text. Each row: text + destructive minus. "Add Tip" button at bottom
   - **Warnings** — `EditableStringList` with orange accent
   - **Timestamps** — Start/End in compact time format
3. **Clip preview** — small read-only video player

**Data:** Requires new `PUT /api/procedures/{id}/steps/{step_number}`.

---

### 5.6 RecordTabView (Tab 2: Record)

**Purpose:** Wrapper around the existing recording flow, adding an upload-from-library option.

**Landing state** (no active stream):
- SF Symbol `video.fill` in `ink400`
- "Record a New Procedure" (Title 2)
- "Stream from your glasses and record, or upload an existing video" (Body, `ink100`)
- Two `ModeCard` action cards:
  - "Record with Glasses" → existing StreamSessionView / NonStreamView flow
  - "Upload Video" → MediaPickerView → ExpertRecordingReviewView

**Active state:** existing StreamView with recording controls. **REC dot is `hazard500` (live indicator — sanctioned per §3).**

**Completion:** After successful processing, show procedure title + step count, then "View Procedure" `CustomButton.primary` switches to Tab 1 and pushes to ProcedureDetailView.

---

## 6. Learner Flow

### 6.1 LearnerTabView

Container for the four-tab Learner experience. Same dark tab bar styling (per §4). Each tab wraps its own `NavigationStack`.

---

### 6.2 DiscoverView (Tab 1: Procedures)

**Purpose:** Browse and find procedures to learn. Framed as a professional procedure catalog, not a content feed.

**Layout (ScrollView, top → bottom):**

1. **Header bar** — Large Title "Procedures" · trailing: glasses connection indicator (green/`ink400` dot) + search icon
2. **Search bar** — rounded rect, `ink800` fill, magnifying glass icon in `ink400`. Tapping opens `SearchView`. Placeholder: "Search by device, task, or error code…"
3. **"Resume Session" card** (conditional — shown if in-progress session exists)
   - Full-width `ink800` card with `hazard500` stroke (active-session surface per §3)
   - Procedure title + progress indicator (steps completed / total, linear bar, `ink50` fill)
   - "Resume" `CustomButton.primary`
   - Most important CTA on screen — placed above all browsing content
4. **Category chips** — horizontal scroll row
   - "All", "Coffee Machines", "Electrical", "Assembly", "Maintenance", "Cleaning"
   - `CategoryChip` styling: capsule, unselected = `ink800`/`ink100`, selected = `ink50` fill, `ink950` text
5. **Procedure list** — vertical list of `ProcedureCardView` items
   - Title, description (2-line), step count badge, duration badge
   - Metadata row: person icon + completion count, difficulty indicator (derived from step count / duration)
   - When no completion data: show "New" badge (Caption 1, `ink700` bg, `ink50` text)

**Data:** `DiscoverViewModel` fetches `GET /api/procedures`, filters by category client-side.

---

### 6.3 SearchView

**Purpose:** Full-screen search with live results.

**Layout:**
- Top: search text field with cancel button
- Below: filtered list of `ProcedureCardView` items
- Empty state: "No results for [query]"

---

### 6.4 LearnerProcedureDetailView

**Purpose:** Full detail page for a procedure. The briefing screen before starting a guided session — like reviewing a work order.

**Layout (ScrollView, top → bottom):**

1. **Header area** — Procedure title (Title 1, `ink50`), description (Body, `ink100`), metadata row of `MetadataPill` components: `clock` + duration · `list.number` + step count · `person.2` + completions
2. **Completion stats bar** — Completions count + average completion time. Placeholder values for hackathon ("No data yet")
3. **Action buttons**
   - "Start Procedure" — `CustomButton.primary` (white fill, black text), full width. Presents `CoachingSessionView` as `.fullScreenCover`
   - "Save to Library" — outline style, `ink100` text. Toggles bookmark (bookmark icon fills with `ink50`)
4. **Steps overview** — reuse existing step detail component; expandable list. Step numbers prominent (Title 3, `ink50` in `ink700` circles)
5. **Warnings summary** (if any warnings exist across steps) — aggregated orange tags at the bottom, separate from tips
6. **Tips section** — aggregated tips, `ink800` bg tags, collapsible

**Data:** `GET /api/procedures/{id}`. Bookmark state in `UserDefaults`.

---

### 6.5 CoachingSessionView

**Purpose:** The core real-time coaching experience. Full-screen, hands-free optimized. This is where Hazard yellow earns the most screen time — the whole session is a "live" state.

**Presentation:** `.fullScreenCover` from LearnerProcedureDetailView.

**Initialization:**
1. Start `StreamSession` (reuse DAT SDK pattern from expert mode)
2. Open Gemini Live WebSocket for voice (audio-only, 15-min session)
3. Begin streaming glasses mic audio
4. Load procedure steps from server

**Screen layout:**

```
+----------------------------------------+
|  [X]  ● LIVE          [Step 2 of 6]    |   Top bar — hazard500 dot
+----------------------------------------+
|   +----------+                         |
|   |  PiP     |                         |   Draggable reference clip
|   +----------+                         |
|                                        |
|      Live camera feed from glasses     |   Full-screen background
|                                        |
+----------------------------------------+
|  Step 2: Attach the foamer             |
|  Slide it onto the nozzle until        |   Semi-transparent ink950 panel
|  it clicks.                            |
|  [tip] Hold at 45 degrees              |
+----------------------------------------+
|  [████████████░░░░░░░░] 2/6            |   ink50 fill, ink700 track
+----------------------------------------+
|  ● Listening…                          |   hazard500 mic pulse
|  [Mic]     [Next Step]     [Help]      |
+----------------------------------------+
```

**Component details:**

- **Top bar:** Close (X) left · **"● LIVE" badge in `hazard500`** · "Step N of M" right
- **Live camera feed:** Reuses `StreamSession` + `VideoFrame` rendering from expert `StreamView`. If no glasses connected: `ink900` placeholder with "Connect glasses to see live view"
- **PiP reference overlay:** 120x90pt draggable thumbnail (top-right default). Expert's reference clip for current step from `GET /api/clips/{id}/step_{n}.mp4`. 8pt corners
- **Step instruction panel:** Semi-transparent `ink950` card over bottom third. Headline (17pt semibold, `ink50`) + Body description in `ink100` + tip tags. Slide transition on step advance
- **Step progress bar:** `ink50` fill on completed segments, `ink700` track. **Deliberately white — not yellow — so the bar reads as progress, not as alarm**
- **Voice status indicator:**
  - "● Listening…" + `hazard500` pulsing mic icon (receiving audio)
  - "Speaking…" + animated waveform (Gemini responding, `ink50`)
  - "Connecting…" + spinner
  - "Disconnected" + retry button
- **Bottom controls:** three `CircleButton` items — Mic toggle · "Next Step" · "Help"

**Completion state:** Bottom panel transforms into completion card:
- Checkmark icon in `ink50` (simple fade-in, no bounce)
- "Procedure Complete" (no exclamation — keep it professional)
- Total time + steps completed
- "Done" `CustomButton.primary` dismisses

No confetti, no celebratory animations — this is a work tool.

---

### 6.6 LibraryView (Tab 2: Library)

**Purpose:** Personal collection of saved and attempted procedures.

**Layout:**
1. **Header:** Large Title "My Library"
2. **Segmented control:** "Saved" | "History"
3. **Saved segment:** list of `ProcedureCardView` items for bookmarked IDs. Empty state: `bookmark.slash` in `ink400` + "No saved procedures yet"
4. **History segment:** list of session records — title · date · status badge (Completed = green, In Progress = `hazard500`, Abandoned = `ink400`) · steps completed / total. Tap → push LearnerProcedureDetailView

**Data:** `LocalProgressStore` (UserDefaults-backed). Saved = `Set<String>`. History = `[SessionRecord]`.

---

### 6.7 LearnerProgressView (Tab 3: Progress)

**Purpose:** Training log and statistics. A professional competency record — useful for technicians tracking certifications or managers auditing training completion.

**Layout (ScrollView, top → bottom):**

1. **Header:** Large Title "Training Log"
2. **Stats cards** — horizontal scroll of 3 `StatCard` items: "Procedures Completed" · "Total Steps" · "Time Trained"
3. **Activity overview** — row of last 7 days
   - Circle per day: **`hazard500` fill = active, `ink700` outline = inactive** (sanctioned yellow per §3 — active days are a live status)
   - Day labels (Mon, Tue, etc.) in Caption 1
   - No "streak" language — functional tracking, not gamification
4. **Session history** — chronological list; tap → push LearnerProcedureDetailView

**Data:** Computed from `LocalProgressStore`.

---

### 6.8 ProfileView (Tab 4: Profile)

**Purpose:** Identity, glasses connection, app settings.

**Layout (ScrollView, sections):**

1. **Profile header** — `person.circle.fill` large in `ink50` + display name
2. **Glasses section** (label: "DEVICE") — connection status card (green/`ink400` dot) + "Reconnect" / "Disconnect" button
3. **Server section** (label: "SERVER") — link to existing `ServerSettingsView`
4. **Preferences section** (label: "PREFERENCES") — Gemini voice picker · auto-advance toggle
5. **About section** — "Retrace v1.0" · "Record an expert once. Coach every learner forever."

---

## 7. Data Architecture

### 7.1 Existing API Endpoints (no changes needed)

| Endpoint | Used by |
|----------|---------|
| `GET /api/procedures` | WorkflowListView, DiscoverView |
| `GET /api/procedures/{id}` | ProcedureDetailView, LearnerProcedureDetailView |
| `DELETE /api/procedures/{id}` | WorkflowListView, ProcedureDetailView |
| `POST /api/expert/upload` | RecordTabView |
| `GET /api/clips/{id}/step_{n}.mp4` | Step clips, PiP reference |
| `GET /api/uploads/{filename}` | Source video playback |

### 7.2 New API Endpoints Needed

| Endpoint | Purpose | Used by |
|----------|---------|---------|
| `PUT /api/procedures/{id}` | Update title, description, step order | ProcedureEditView |
| `PUT /api/procedures/{id}/steps/{n}` | Update step fields | StepEditView |
| `GET /api/procedures/{id}/stats` | Learner analytics (stub) | ProcedureDetailView |

### 7.3 Local Storage (UserDefaults)

| Key | Type | Purpose |
|-----|------|---------|
| `serverBaseURL` | `String` | Server URL (existing) |
| `savedProcedureIDs` | `Set<String>` | Bookmarked procedures |
| `sessionHistory` | `[SessionRecord]` | Completed/in-progress sessions |
| `geminiVoice` | `String` | Preferred Gemini voice |
| `autoAdvanceEnabled` | `Bool` | Auto-advance on visual verification |

### 7.4 iOS Models

```swift
struct ProcedureListItem: Codable, Identifiable {
    let id: String
    let title: String
    let description: String
    let totalDuration: Double
    let createdAt: String
    let status: String?
    let stepCount: Int
}

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

struct SessionRecord: Codable, Identifiable {
    let id: String
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

## 8. ViewModels

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

## 9. Interaction Patterns

| Interaction | Pattern |
|-------------|---------|
| Card tap | Push onto NavigationStack |
| Swipe left on list item | Destructive action (delete) |
| Pull down on list | Refresh data |
| Step expand/collapse | Disclosure with chevron rotation |
| Bookmark toggle | Icon fills with spring animation |
| Step advance (coaching) | Slide left/right transition |
| PiP reference drag | `DragGesture`, dismiss by swiping off-screen |
| Session start | `.fullScreenCover` presentation |
| Edit screens | Push navigation with Cancel/Save in nav bar |
| Tab switch on completion | Programmatic tab selection via binding |
| Long press | Not used (keep interactions discoverable) |

---

## 10. Implementation

This document is the spec. To bring the running app in line with it — Asset Catalog color swaps, `CustomButton` primary style flip, `RetraceTypography.swift` scale updates — see `rebrand-migration.md` at the repo root.
