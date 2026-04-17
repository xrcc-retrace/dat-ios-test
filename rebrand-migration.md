# Retrace Rebrand — Code Migration Plan

> Companion to [design.md](design.md). This doc lists the concrete asset and code changes that bring the running app in line with the updated brand spec.

## Context

`design.md` has been updated with the **"Focus Flight" monochrome** brand direction — a high-contrast Ink scale, Hazard yellow reserved for live/active states, white CTAs on a black OLED surface, and a Golos Text type scale (SF fallback for now). The app's Expert/Learner architecture is already built; what needs to change is the visual token layer, not the component structure.

## Strategy

Views already consume **named Asset Catalog colors** (`textPrimary`, `surfaceBase`, `appPrimaryColor`, etc.), so retuning the underlying hex values ripples through the entire app for free. Only the primary button style and a small set of hardcoded references need direct code edits. Everything else is a one-line JSON change in an `*.colorset/Contents.json`.

The migration is intentionally scoped to the token layer — no per-view polish this pass.

---

## B.1 Asset Catalog color updates

Edit `Contents.json` in each of these colorsets under [samples/CameraAccess/CameraAccess/Assets.xcassets/](samples/CameraAccess/CameraAccess/Assets.xcassets/). Retrace is dark-first, so set both the light and dark variant of each asset to the same Ink/Hazard hex for now.

| Asset | New value | Notes |
|-------|-----------|-------|
| `appPrimaryColor.colorset` | `#EAB308` (Hazard 500) | Replaces blue `#0064E0`. This flips every live/active indicator to yellow in one shot |
| `accentMuted.colorset` | `#CA8A04` (Hazard 600) | Pressed state for hazard surfaces |
| `backgroundPrimary.colorset` | `#030712` (ink950) | Deep OLED black |
| `surfaceBase.colorset` | `#1F2937` (ink800) | Default card surface |
| `surfaceRaised.colorset` | `#374151` (ink700) | Pressed / step-number badges |
| `borderSubtle.colorset` | `#9CA3AF` (ink400) | Used at low opacity for borders, inactive icons |
| `textPrimary.colorset` | `#F9FAFB` (ink50) | Primary text + hero CTA fill |
| `textSecondary.colorset` | `#F3F4F6` (ink100) | Secondary text |
| `textTertiary.colorset` | `#E5E7EB` (ink200) | Tertiary text, section labels |
| `destructiveBackground.colorset` | `#3A1618` | Dark red replaces existing pink — reads correctly on OLED |
| `destructiveForeground.colorset` | `#FFD8DB` | Unchanged |
| `semanticSuccess` / `semanticError` / `semanticInfo` | unchanged | Kept as fallback for system statuses |

## B.2 `CustomButton` primary style

File: [samples/CameraAccess/CameraAccess/Views/Components/CustomButton.swift](samples/CameraAccess/CameraAccess/Views/Components/CustomButton.swift)

The `.primary` case currently fills with `appPrimaryColor` (soon yellow) — but the spec calls for the Hero CTA to be **white on black**, not yellow. Change the `.primary` style to:

- Fill: `Color("textPrimary")` (white, ink50)
- Foreground: `Color("backgroundPrimary")` (black, ink950)
- Keep the 30pt capsule — do not migrate to the brand doc's 10pt

The `.destructive` case keeps its existing asset bindings — the Asset Catalog swap in B.1 handles its color update.

## B.3 Typography scale

File: [samples/CameraAccess/CameraAccess/RetraceTypography.swift](samples/CameraAccess/CameraAccess/RetraceTypography.swift)

Update the 9 `Font` extensions to match the Golos Text iOS Typescale from design.md §1.2:

- Use `.system(size:, weight:)` — keep SF as the fallback for now
- Apply `.tracking(...)` where the scale specifies non-zero letter spacing (Large Title −0.4, Title 1 −0.3, Title 2 −0.3, Title 3 −0.3, Headline −0.4, Body −0.4, Callout −0.3)
- Add a top-of-file comment: `// TODO: swap Font.system to Font.custom("GolosText-*", size:) once font files are embedded`

Do **not** add font files to the bundle or edit `Info.plist` in this pass — the font swap is deliberately deferred.

## B.4 ModeCard active stroke

File: [samples/CameraAccess/CameraAccess/Views/ModeSelectionView.swift](samples/CameraAccess/CameraAccess/Views/ModeSelectionView.swift)

If the active-card border currently reads from `Color("appPrimaryColor")`, it becomes yellow automatically after B.1 — which is correct per the spec (live session indicator). Verify; if the border is hardcoded to `Color.blue` or a raw `#0064E0`, swap to the named asset.

## B.5 Selected-tab + selected-chip styling

Check tab bars and category chips:

- [samples/CameraAccess/CameraAccess/Views/Expert/ExpertTabView.swift](samples/CameraAccess/CameraAccess/Views/Expert/ExpertTabView.swift)
- [samples/CameraAccess/CameraAccess/Views/Learner/LearnerTabView.swift](samples/CameraAccess/CameraAccess/Views/Learner/LearnerTabView.swift)
- `CategoryChip` component under `Views/Components/`

Per design.md §3, **selected tabs and selected chips use white (`textPrimary`), not Hazard yellow**. If any of these currently bind to `appPrimaryColor`, swap to `textPrimary` so the B.1 change doesn't paint the entire tab bar yellow.

Same check for the `StepProgressBar` completed-segment fill — should be `textPrimary`, not `appPrimaryColor`.

## B.6 Live-state surfaces (confirm, don't change)

The following should continue to read from `appPrimaryColor` — they'll light up yellow automatically after B.1 and that's desired:

- Recording REC dot in `StreamSessionView` / `ExpertRecordingReviewView`
- Processing pulse on cards in `WorkflowListView`
- Active-day circles in `LearnerProgressView`
- Voice "Listening…" pulse in `CoachingSessionView`
- Active-session stroke on the "Resume Session" card in `DiscoverView`
- Focus ring on text fields in `ProcedureEditView` / `StepEditView`

No edits required — this is a sanity audit.

---

## Out of scope (deliberately deferred)

These are **not** part of this pass and should be tracked as follow-ups:

- Embedding Golos Text `.ttf` files and updating `Info.plist` `UIAppFonts`
- Per-view polish of spacing, icon weights, or motion
- Destructive-button visual treatment beyond the color swap
- Logo asset refresh (overlapping-diamond mark with hazard-stroke live state)
- New screens or flows not present in current code
- Retuning animations (spring curves, transitions)

---

## Verification

1. Build the app via the `build` skill after B.1–B.3 land — confirm zero compile errors
2. Launch on simulator; walk each surface:
   - `ModeSelectionView` — background ink950, cards ink800, active stroke yellow, CTA white-on-black
   - `WorkflowListView` — processing dot pulses yellow on card
   - `ProcedureDetailView` — step number badges are `ink700` circles with `ink50` numbers (not yellow)
   - `ExpertTabView` / `LearnerTabView` — selected tab icon + label are white, not yellow
   - `RecordTabView` → live session — REC dot is yellow
   - `DiscoverView` — category chip selected state is white fill / black text; resume card has yellow stroke
   - `LearnerProgressView` — active day circles are yellow, inactive are `ink700` outlines
   - `CoachingSessionView` — step progress bar is white fill on `ink700` track; "● LIVE" badge and voice pulse are yellow
3. Side-by-side with the "Focus Flight" reference screenshot — the overall read should be monochrome with yellow only as punctuation
4. Flag any remaining blue pixels or unexpected yellow for a follow-up per-view cleanup pass (out of scope here)
