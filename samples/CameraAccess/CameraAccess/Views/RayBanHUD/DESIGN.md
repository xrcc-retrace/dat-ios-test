# Ray-Ban HUD — Design System

This is the north-star design doc for everything rendered inside the simulated Meta Ray-Ban lens. Whenever a new component, animation, or interaction lands in coaching / expert / troubleshoot, **start here**. The point isn't to lock in pixels; it's to keep the *feel* consistent so the lens never reads as a generic iOS surface.

The lens is a small, peripheral, glasses-style display. Everything we draw should respect that constraint. Loud, dense, or attention-grabbing UIs break the metaphor — even if they'd be fine on a normal phone screen.

---

## Mission

The Ray-Ban HUD should feel:

- **Subtle** — the user is doing a real-world task. The lens supports them; it does not compete for attention.
- **Peripheral** — readable in a glance. If the user has to focus to parse a screen, the design has failed.
- **Reactive** — visibly responding to what the user does and what the AI does. Static UIs feel dead.
- **Premium** — soft glass, gentle springs, no plastic flatness. Cheap = breaks the illusion of a physical device.

When in doubt: smaller, slower, quieter, fewer affordances.

---

## Visual Language

### The glass surface

Every panel, pill, card, and overlay shares one background recipe — the `rayBanHUDPanel(shape:)` modifier in `RayBanHUDStyle.swift`. Four stacked layers:

1. Base gradient — `Color(0.44, 0.48, 0.49)` → `Color(0.39, 0.43, 0.44)` at 75% opacity (top-leading → bottom-trailing)
2. Diagonal shade — white-to-black soft overlay (5% / 1% / 12%)
3. Top-trailing radial sheen — white at 18% / 8% / clear (radius 6 → 220)
4. 1pt white stroke at 12% opacity

Plus a drop shadow: `black @ 22%, radius 18, y +10`.

**Don't recreate this manually.** Always reach for `.rayBanHUDPanel(shape: .capsule)` or `.rayBanHUDPanel(shape: .rounded(radius))`. Surface ambiguity ruins the kit. Confirmation overlays use the same panel — separation from the recessed page below comes from the recede recipe (see Overlays below), not from a heavier surface.

### Compositing model — opaque vs. additive

The lens supports two blending modes against the live camera feed, switched at runtime via Server Settings → Debug → "Additive HUD blending" (`@AppStorage("hudAdditiveBlend")`):

- **Opaque** (default): standard alpha-composited overlay. The HUD draws its panels and text directly over the camera; dark panel pixels show as dim grey, light pixels as bright. Predictable legibility regardless of background. This is what we ship by default.
- **Additive** (`.compositingGroup() + .blendMode(.plusLighter)`): the entire lens composes to one offscreen layer and **adds** its luminance to the camera. Dark HUD pixels become transparent (camera shows through unchanged); bright HUD pixels brighten the camera. This is the same optical behavior as the real Meta Ray-Ban Display — bright scenes wash panels out, dark scenes make them pop.

The toggle is global and applies to every mode (Coaching, Expert, Troubleshoot) since they all mount through the same emulator. **Don't add per-element blend-mode tweaks** — the consistency of the lens depends on a single, lens-wide compositing decision.

**Panel surface has two recipes, picked by environment.** The emulator threads `\.hudAdditiveBlend` into the panel system; `HUDSurfaceBackground` reads it and switches between:

- *Opaque mode*: mid-gray surface + white sheen + soft inner shade — reads as a defined card on the camera.
- *Additive mode*: near-black surface, no sheen, dark inner shade. Under `.plusLighter` this composites to ~transparent (camera passes through unchanged) — exactly the "dark container" Google's transparent-screens guidance prescribes. Bright surfaces would halate into the white text and destroy edges; the dark recipe gives bright content a clean low-luminance neighborhood. This is *not* a per-element opt-in — it's the panel system's two surface variants, switched once by environment.

Reference: [design.google/library/transparent-screens](https://design.google/library/transparent-screens). Key takeaway: on additive displays you can only add light, not subtract. **Make text legible by darkening the container behind it, not by brightening the text** (which is already white) or the surface (which only adds halation).

When designing new lens components, **assume opaque** for the legibility floor. New surfaces should pick up the panel system automatically via `.rayBanHUDPanel(...)`; only reach into `HUDSurfaceBackground` recipes if a component genuinely needs a different surface, and add the additive variant alongside the opaque one — don't add carve-outs that ignore additive mode.

### Color palette

| Role | Color | Usage |
|---|---|---|
| Primary text | `white @ 0.94–0.98` | Bar labels, body, titles |
| Secondary text | `white @ 0.70–0.85` | Step counters, captions, tracking labels |
| Active/selected fill | `white @ 0.95` (with `black @ 0.88` text) | Selected toggle pills only (Reference / Insights when their panel is open) — NOT default-focused buttons (those use the hover ring instead, see `HUDHoverHighlight`) |
| Highlight accent | `Color(1.0, 0.76, 0.11)` (warm yellow) | Unified hover ring (2pt stroke gradient, warm glow at radius 8 / opacity 0.55, soft warm fill — see `HUDHoverHighlight`); exit countdown bar; lens debug boundary; insights chip. **Reserved exclusively for the focus signal** — never used as decoration on resting elements. Earlier revisions carried a permanent 1pt yellow stroke on primary-action pills (`startProcedure` / `uploadManual` / `confirmIdentification`); that decoration was removed because at rest it stacked with the hover ring and made the focus signal ambiguous. Primary-action emphasis now comes from icons, not color (see Pills below). |
| Destructive accent | `Color(0.96, 0.26, 0.21)` (red) | Recording dot, stop pill countdown, confirm-exit subtle background |
| Success accent | Soft green gradient (radial, see `RayBanHUDCompletionSummaryCard`) | Step completion checkmark, completion pulse |
| Surface stroke | `white @ 0.12` | The 1pt panel border |

Use color for **state**, not decoration. A button doesn't get a custom color because it looks nice; it gets one because it's destructive (red) or focused (white fill).

### Typography

Inter family throughout — no system font fallbacks unless explicitly necessary.

| Use | Style | Size |
|---|---|---|
| Page title (large) | `inter(.bold)` | 20 |
| Card title | `inter(.bold)` | 14–18 |
| Body text | `inter(.medium)` | 13–14 |
| Button label | `inter(.medium)` | 11–14 |
| Tracking label (uppercase, e.g. `STEP 1 OF 5`) | `inter(.medium)` | 10–12, `tracking(1.0–1.2)` |
| Read more inline italic | `inter(.bold, italic: true)` | match body |
| Compact stat / size badge | `monospaced` system | 10 |

Keep line heights tight. The lens is small; vertical rhythm matters more than air.

---

## Layout Foundations

### The square viewport

The lens is **always square**. Side = `min(screenWidth, screenHeight) − 2 × viewportInset` (inset = 24). On a typical iPhone in portrait that's around 327×327; on Meta Ray-Ban Display the analogue is closer to 600×600. Pages design *for* a square, not for the surrounding screen.

Implications:
- Hard clip the lens (`.clipped(antialiased: true)`). Card animations exit at the boundary cleanly. No translating off-canvas.
- Slide distances are derived from the live `viewportSide` (via `GeometryReader`), never hard-coded magic numbers.
- Pages assume a square frame. If a page wants to grow, it grows *within* the square — never outside.

### Centered, never anchored

Default lens placement: centered in portrait. Bottom-trailing in landscape was previously supported; we deprecated it in favor of consistent centering.

### Stacking inside the lens

Most pages follow the same vertical rhythm:

```
┌─────────── square lens ──────────┐
│ [Top affordances row]            │   ← small toggles, status pills
│                                  │
│ [Primary content card]           │   ← step card, tip card, etc.
│                                  │
│ [Secondary expansion content]    │   ← appears via in-place expansion
│                                  │
│ [Spacer / page indicator dots]   │   ← bottom-anchored
└──────────────────────────────────┘
```

The bottom is reserved for state-driven UI (page indicator, contextual buttons during overlays). Don't pin always-visible affordances at the bottom — they steal attention from the content above.

---

## Component Patterns

### Panels

Anything with a glass background. Always via `.rayBanHUDPanel(shape:)`. Two shape variants:

- `.capsule` — for pills, badges, status chips, page-indicator container
- `.rounded(radius)` — for cards. Default `RayBanHUDLayoutTokens.cardRadius` = 24.

### Pills

Compact, capsule-shaped, often with an icon + label. Used for:
- Toggle affordances (Reference / Insights)
- Action buttons inside cards (Cancel / Confirm)
- Status indicators (recording chip, mic source badge)

Toggle pills get a `Capsule().fill(white @ 0.95)` background + black text **only when their panel is open** (i.e. `expansion == .referenceExpanded` for the Reference toggle, `.insightsExpanded` for the Insights toggle). The fill says "this is the active panel," not "the cursor is here." Inactive toggles: clear background + white text.

A **primary-action pill** (the page's forward-path action — `startProcedure`, `uploadManual`, `confirmIdentification`) is signaled by a **leading SF Symbol icon + full-opacity white text + larger size**: `arrow.right` for "Start", `square.and.arrow.up` for "Upload a manual", `checkmark` for "That's it", and so on. The icon does the visual work that a permanent yellow stroke used to do — it tells the user "this is the recommended next action" the moment the page renders, without ever stealing the focus signal. Default focus on each page lands the cursor on the primary pill, so the unified hover ring appears there on appear and reinforces the cue without competing with it.

**Secondary pills** (Try again, Rediagnose, mute, exit, the rejection / cancel paths) stay text-only at `white @ 0.7` opacity, smaller (`size: 12` vs. `14`), and pick up an `arrow.clockwise` redo glyph when their action is "go back / try again." They don't get a permanent ring or a custom highlight — only the unified hover ring lights them up on focus.

**Don't substitute custom hover treatments** (white-fill flips, color swaps, permanent yellow strokes) for the unified ring. That creates two competing emphases on the same button. Yellow is reserved for the focus signal alone — never decoration on a resting element.

### Hand-tracking status indicator

A tiny `hand.raised.fill` glyph, no backdrop, that lives next to the audio meter on every mode (Coaching's bottom audio row, Troubleshoot's bottom audio row, Expert's top status row). Hidden entirely when `@AppStorage("disableHandTracking") == true`. Otherwise its opacity reflects `HandGestureService.shared.isPoseGated` — `0.30` when the recognizer's pose gates aren't passing, `0.96` when they are. Crossfades on `.easeInOut(duration: 0.18)`. Treat it as an ambient signal, not a control — never `.hoverSelectable`, never reachable from the focus engine. The icon-with-no-backdrop pattern is intentional: it sits beside the audio meter without competing for the user's attention. Gate logic lives in one place (`HandGestureService.isPoseGated`, sourced from `productionConfig()`) so the indicator never drifts from the recognizer's actual arming behavior.

### Cards

Rounded panels containing structured info. Step card, completion summary, exit confirmation, tip card. All use `cardRadius` and `contentPadding` (20). Cards never overlap directly with other cards — separate them with the `stackSpacing` (12) token.

### Overlays — the confirmation overlay pattern is REQUIRED

This is the single most important pattern in the kit. **Every confirmation, approval, dismissal, "are you sure?", "you've finished X", "we found Y" surface uses it.** No exceptions, no ad-hoc dialogs, no inline confirms tucked into a card.

When an overlay is active, the page's content gets *replaced* (not augmented). The previous content **recedes** while the overlay **arrives**:

- Underlying content: one call — `.rayBanHUDRecede(active: overlayShown)` — which applies the canonical scale + opacity + blur + hit-testing recipe (numbers in `RayBanHUDLayoutTokens.recede*`). Tweak intensity in one place; every overlay flow inherits.
- Overlay: standard `.rayBanHUDPanel(shape: ...)` — same surface as every other panel on the lens. Enters via `.transition(.scale(scale: 0.88).combined(with: .opacity))`.
- Both transitions wrapped in a single `.spring(response: 0.32, dampingFraction: 0.85)` so they read as one motion.

**The recede is what does the work.** Foreground/background separation is established entirely on the page side — strong scale + opacity dip + blur. The overlay panel itself stays on the standard glass surface so the hover ring on its inner pills reads cleanly. Don't reach for a heavier overlay surface to "stand out more" — push the recede instead.

The shrinking-and-popping feel is load-bearing — it's what makes the lens feel like a physical surface where attention shifts between layers, instead of a stack of static panels. Don't drop the recede half "to keep things simple"; both halves of the motion are required for it to read correctly.

Use this for:

- **Confirmations** — exit confirmation (`CoachingExitConfirmationOverlay`), discard recording, delete saved workflow, abandon session, anything destructive
- **Approvals** — "Connect to this server?", "Use this manual?", consent prompts
- **Mid-flow announcements** — "Step complete!", "Procedure finished", error toasts that need acknowledgment
- **Picker/chooser surfaces** — voice selection, mode switch, anything that interrupts the current page to gather a choice

When in doubt, ask: "is the user being asked to do or acknowledge something before continuing?" If yes → confirmation overlay pattern. If no → it's probably an inline panel (which uses asymmetric transitions, see Animation System below).

`CoachingExitConfirmationOverlay` is the reference implementation — copy its skeleton (small centered glass card, Cancel / Confirm pills, default-focus on the safe option, glass background via `.rayBanHUDPanel(shape: ...)`). `TroubleshootConfirmOverlay` and `ExpertHUDStopOverlay` follow the same pattern and use the same recede recipe on the page below.

### Page indicator dots

Bottom-of-lens dot row showing current page index. Hidden when `pageCount <= 1`. Each dot: 6pt circle. Active dot: white @ 0.95. Inactive: white @ 0.32. Wrapped in a small `.rayBanHUDPanel(shape: .capsule)` container.

Do **not** add labels or numbers to the indicator. The dots alone communicate position; text breaks the peripheral feel.

---

## Interaction Patterns

### THE INPUT RULE — actions belong to the focused element

This is the headline rule of the input system. Every input — touch tap, touch swipe, pinch-drag-release, pinch-select, voice — operates on the **currently focused element only**, never page-globally. If a direction or action has no meaning for the focused element, it's a no-op. There is no fallthrough to a "page handler."

**Worked example.** On the Coaching step page:

| Cursor on… | Swipe right does… |
|---|---|
| `.stepCard` | Advance to the next step (page-level semantic for the step card) |
| `.toggleReference` | Move cursor to `.toggleInsights` (graph traversal) |
| `.toggleInsights` | Nothing (no right neighbor in the graph) |

Swipe-right on `.toggleReference` does **not** advance the step. The step-nav semantic belongs to `.stepCard` exclusively. This is the rule.

**How input maps to focus:**

- **Touch tap** on an interactive element →
   - Benign action (`.tapToFire`): tap = move cursor + fire onConfirm in one motion
   - Destructive action (`.confirmOnSecondTap`): first tap = highlight, second tap while highlighted = fire
   - Hold-driven (`.selectOnly`): tap = move cursor only; an external gesture (hold) drives the action
- **Touch swipe / pinch-drag-release directional event** → look up the focused element's neighbors / page-level semantic in the page's `FocusGraph`. If the focused element has no neighbor in that direction and no page-level override: **no-op**. Don't fall through.
- **Pinch-select** → fire the focused element's registered `onConfirm` via `coordinator.fireConfirm(for: hovered)`. Symmetric to touch's tap-to-fire / confirm-on-second-tap.

**Anti-patterns to refuse:**

- A page handler that fires an action on `.directional(...)` without checking `coordinator.hovered`.
- A `HandGestureService.shared.onEvent` closure that mutates app state without first gating on the cursor.
- A touch swipe gesture wired to a parent container that captures swipes anywhere on the lens.

When designing a new page or overlay: declare the focus graph first, decide what each focused element does on each direction, then implement. If a direction has nothing meaningful for the current focused element, leave it unbound — silence is correct, not a fallthrough.

### Page-level navigation is commit-on-release, not commit-on-highlight

The pinch recognizer emits two flavors of directional event: **highlight** events that fire mid-pinch as the thumb crosses a quadrant (drive cursor traversal in real time), and **terminal** events that fire on release. `dispatchPinchDragEvent` routes highlights through the focus engine's `.directional` channel; terminal events are intentionally not dispatched there.

For traversal — moving the cursor across the focus graph, e.g. `.toggleReference` ↔ `.toggleInsights` — highlight is the right input. The cursor follows the thumb, and releasing leaves it where it landed.

For **page-level commits** — advancing to the next step, cycling a tip carousel, anything that mutates content rather than focus — highlight is the wrong input. A learner who shifts their hand mid-pinch should not skip a step every time their thumb drifts past the quadrant boundary. Commit-on-release is the rule:

1. The page's handler returns `false` for the relevant `.directional(...)` so highlight events don't fire the page-level action.
2. The page itself listens for terminal pinch events directly via `HandGestureService.shared.onEvent`, gated on `coordinator.hovered` so the action only fires when the cursor is on the right element.
3. The listener is installed in `.onAppear` and cleared in `.onDisappear`. `HandGestureService.shared.onEvent` is a single slot — only one page should own it at a time.

Reference implementations: `ExpertNarrationTipPage` (tip carousel) and `CoachingStepPage` (step nav) both wire this exact triple. New pages that need release-to-commit directional behavior should mirror them rather than reaching for the focus engine's `.directional` channel.

### Hover-then-select (focus engine semantics)

Every interactive element conforms to a single coordinator (`HUDHoverCoordinator`). Tap = move hover. Tap-while-hovered = confirm. The hover ring (yellow stroke + glow) is the *only* visual signal that an element is targeted.

This generalizes across modalities: directional gestures move the hover; pinch-select fires confirm. Same coordinator, same ring, different input. Pages declare neighbors via the focus graph — `FocusGraph` mapping `HUDControl → FocusNeighbors(up/down/left/right)`. See `HUDInputEngine.swift` and the `*PageHandler` files in each mode.

### Default-focused element on appear

Whenever a new page or overlay becomes visible, **one element should already be hovered** so a single select gesture has somewhere to land. The choice of default focus matters:

- For benign actions (e.g., a step page's primary CTA), default-focus the most likely action.
- For **destructive overlays** (exit confirmation), default-focus the *safe* option (Cancel). A user blindly selecting must not destroy state.

Implement via `.onAppear { hoverCoordinator.hovered = .someControl }`.

### Sharing a control id across pages

A single `HUDControl` (e.g. `.diagnosticToggleMute`, `.exitWorkflowButton`) often appears on multiple pages — most lens flows put a mute pill and an exit pill on every page in the flow. That's intentional: the focus graph is per-page, but control identity is global.

The implementation detail to know: SwiftUI fires the new page's `.onAppear` before the old page's `.onDisappear` during a page transition. The confirm registry on `HUDHoverCoordinator` is therefore **token-stamped** — `registerConfirm` returns a `UUID`; `unregisterConfirm(id:token:)` is a no-op unless that token still matches the registry's current entry. The outgoing page can't wipe the incoming page's freshly-installed closure for the same id.

**Don't build a parallel id-keyed registry that bypasses tokens.** Without the token check, pinch-select / voice-select silently no-ops on every page after the first — and the failure is invisible from the touch path because `HoverSelectable` invokes `onConfirm` directly through `.onTapGesture` and never goes through the registry. The touch path keeps working while the gesture path is dead. The registry isn't optional infrastructure: it's the only path the focus engine has for non-touch confirms.

The same token discipline applies one layer up — to the **handler stack** itself. `HUDHoverCoordinator.push` returns a token; `pop(token:)` is a no-op for stack removal *and* for `hovered` re-anchoring unless that token is currently topmost. Without this guard, an outgoing page's pop fired in the same render frame as an incoming overlay's push would re-anchor `hovered` back to the page's `defaultFocus` and the overlay's cursor placement would silently revert. The user-visible failure is the same asymmetric one: touch tap works (it captures `onConfirm` directly), pinch-select fires the wrong control because `coordinator.hovered` was reverted before the user's gesture arrived. This is why every confirmation overlay in the codebase relies on `defaultFocus` via `.hudInputHandler { … }` instead of an ad-hoc `.onAppear { hovered = … }` — the abstraction is load-bearing.

### Lens back gesture (dismiss / contextual exit)

Two inputs converge on the same "I want out of this view" intent:

1. **Double index-finger pinch** — the canonical Meta-Ray-Ban-Display gesture. Detected by `PinchDragRecognizer` ("two quick taps near the same spot") and emitted as `PinchDragEvent.back` from the camera-frame loop in `GeminiLiveSessionBase`. Hosts subscribe by setting `viewModel.onBackGesture = { … }`.
2. **Screen double-tap on lens background** — dev fallback for testing without hand-tracking active (e.g. iPhone-only flows where the camera shows the workspace, not the user's hand). Wired via `RayBanHUDEmulator.onLensBackGesture` and only fires for taps on **non-interactive lens area** — hover-selectable elements take priority.

Both inputs route to the same destination handler. Currently used in Coaching (drives the exit-confirmation overlay) and Troubleshoot (drives the end-diagnostic confirmation). Reuse for any future "back" / dismiss intent — set `onBackGesture` on the VM and `onLensBackGesture` on the emulator to the same closure.

### Tap → countdown overlay (preferred for destructive actions)

`ExpertHUDStopPill` uses the two-stage tap + countdown pattern: first tap highlights the pill (`.confirmOnSecondTap` behavior), second tap opens a confirmation overlay with a 3-second auto-confirm countdown and an X button to cancel. Implementation lives in `ExpertNarrationTipPage` via `countdownStartedAt: Date?` + a one-shot `commitTask`. **The countdown bar is always Core Animation**, never polled `@State` updates per tick (see Animation System below). The overlay uses the standard panel surface and the page recedes per the recipe above.

For dangerous actions on Coaching, prefer the **double-tap → confirmation overlay** pattern instead. Hold-to-confirm survives only where the active gesture is naturally a hold (recording / pressing / etc.).

### Page navigation

Horizontal swipe drives `pageIndex`. Single-page modes (e.g., Expert with one page, Troubleshoot with zero pages) silently clamp. Future MediaPipe pinch-drag gestures call into the same `pageIndex` binding — pages never wire navigation themselves.

---

## Animation System

### Single spring vocabulary

Almost every state change in the HUD uses one of these springs. Memorize them, prefer them, only deviate with reason.

| Token | Curve | Use |
|---|---|---|
| **Standard transition** | `.spring(response: 0.32, dampingFraction: 0.85)` | Page expansion toggles, overlay enter/exit, scale-recede effects |
| **Snap-back** | `.spring(response: 0.28, dampingFraction: 0.88)` | Drag-rejected snap (didn't cross commit threshold) |
| **Continuous fill** | `.linear(duration: holdDuration)` | Hold-to-confirm progress bars, exit countdowns |
| **Completion pulse** | `.easeInOut(duration: 0.70).repeatCount(2, autoreverses: true)` | Green flash after `advance_step` succeeds |

Page slide-out (from horizontal swipe commit): `.easeOut(duration: 0.22)` over a distance equal to `viewportSide` — never a hard-coded offset.

### Recede + arrive pattern (REQUIRED for every confirmation UI)

This is the canonical pattern for "another UI is taking over" — exit confirmation, future deletion/discard prompts, mid-flow announcements, picker surfaces, completion celebrations. **It is not one option among several. It is the rule.** Anything in the lens that asks the user to confirm, approve, acknowledge, or pick uses this verbatim:

```swift
ZStack {
  underlyingContent
    .rayBanHUDRecede(active: overlayShown)

  if overlayShown {
    overlayCard
      .transition(.scale(scale: 0.88).combined(with: .opacity))
  }
}
.animation(.spring(response: 0.32, dampingFraction: 0.85), value: overlayShown)
```

The numbers are **canonical and fixed across all surfaces**:

- Receding underlay: `.rayBanHUDRecede(active:)` — applies `scaleEffect`, `opacity`, `blur`, and `allowsHitTesting` together. Values live in `RayBanHUDLayoutTokens.recedeScale` / `recedeOpacity` / `recedeBlurRadius`. Tune intensity in one place; every overlay flow inherits.
- Arriving overlay: `transition(.scale(scale: 0.88).combined(with: .opacity))`
- Single spring: `.spring(response: 0.32, dampingFraction: 0.85)`

Don't tune per-surface. Don't tweak the scale to "feel slightly more dramatic for delete vs. exit." Don't reinline the four-line recipe at a call site — that path produced silent drift between modes (the doc and three call sites split on what the values were). Consistency across confirmation surfaces is the value — users learn the gesture once, and every modal uses the exact same motion.

**Forbidden workarounds**:

- Don't drop the recede half ("the underlay scaling is subtle, do we need it?") — yes, you do. Both halves together produce the depth illusion. One half is just a popover.
- Don't sequence two `withAnimation` calls (recede first, then overlay). One spring, opposing directions, done.
- Don't substitute `spring(.bouncy)` / `spring(.snappy)` / custom timings — the canonical spring is calibrated against the rest of the kit's motion.
- Don't fade-only ("simpler — just opacity"). The recede + scale-up pair is what makes the overlay feel like it's emerging *from* the lens, not pasted on top of it.

### Asymmetric transitions for inline content

When an in-page panel appears (e.g., a reference clip or insights expanding inside `CoachingStepPage`), use:

```swift
.transition(.asymmetric(
  insertion: .opacity.combined(with: .scale(scale: 0.92, anchor: .top)),
  removal: .opacity
))
```

Insertion: a soft scale-up from the top (suggests the content "drops in" above the existing card). Removal: plain fade (don't animate the geometry on the way out — it competes with the panel above shifting back into place).

### Continuous animations: never poll

For anything that progresses over a fixed duration (countdown bar, completion-pulse fade), **drive the animation from `withAnimation(.linear(duration:))` plus a `@State` value that flips once**. The OS animates between values on the GPU at the display refresh rate — frame-perfect, doesn't fight main-thread audio decoding or camera frame work.

```swift
// GOOD
@State private var fillProgress: CGFloat = 0
.onAppear {
  withAnimation(.linear(duration: holdDuration)) { fillProgress = 1 }
}
```

```swift
// BAD — janks under load and burns CPU
@State private var fillProgress: CGFloat = 0
private let timer = Timer.publish(every: 1.0/30.0, on: .main, in: .common).autoconnect()
.onReceive(timer) { _ in fillProgress += step }
```

This is a hard rule. The Expert + Coaching exit overlays are already on the Core Animation pattern; new code follows.

**Pause / resume during a continuous animation** uses `TimelineView(.animation(paused:))` plus an elapsed-time accumulator. `RetraceAudioMeter` (animation timeline only — the meter never pauses) and `AutoScrollingContainer` (Coaching step card; pauses on pinch-select and on overlay recede) are the two canonical examples. The accumulator pattern is non-negotiable when pause is in-scope: a naive `context.date - startDate` jumps forward by the full pause duration on resume because `paused: true` only stops redraws, not the wall clock. Bank elapsed time on pause-in, snapshot a new `lastResumeAt` on pause-out, derive `currentElapsed` from `accumulated + (now - lastResumeAt)` while running. See `AutoScrollingContainer.swift` for the reference implementation.

### Audio-reactive animations

`RetraceAudioMeter` is the reference. Single peak input drives a rolling buffer + per-bar phase wobble. The wobble is multiplied by smoothed loudness so silence resolves cleanly to flat — never an ambient idle pulse. Any future audio-reactive component should follow the same "amplitude scales motion, silence scales it to zero" rule.

---

## Worked Examples

### `CoachingExitConfirmationOverlay`

Pattern: destructive confirmation modal.

- Centered glass card, ≤ 240pt wide, hugs content height
- Title: short question, never explanatory
- Two stacked pills: Cancel (default-focus, no permanent fill) on top, Confirm (subtle red @ 0.32) below
- Both pills are `.hoverSelectable`; the unified `HUDHoverHighlight` ring (yellow, 2pt + glow) shows up on the focused pill — that's how default-focus is communicated visually, not via a permanent white fill
- The handler's `defaultFocus = .exitConfirmCancel` (set on `push` of the overlay's input handler) lands the cursor on Cancel automatically, so a stray select gesture cancels, never confirms
- Triggered by `RayBanHUDEmulator.onLensBackGesture` (double-pinch on glasses, double-tap as dev fallback) — wrapped in the recede-and-arrive spring

Reuse this pattern verbatim for: deleting a saved workflow, abandoning a recording, discarding a session in progress.

### `CoachingStepPage` expansion

Pattern: in-page expandable panels.

- Default state shows a compact card; truncated content hints at "more available."
- Toggle affordances at top declare what *can* expand. Hidden when there's nothing to expand to.
- Tapping a toggle uses the asymmetric inline-content transition above.
- Other expansion states are **mutually exclusive** — one expanded panel at a time. Tapping a different toggle smoothly switches.

**Pinch-select on `.stepCard` is overloaded by current state**:
- Card is **collapsed** → expand to `.stepExpanded`.
- Card is **already expanded** AND description overflows → pause / resume the auto-scroll. The user is reading; the second pinch is "hold this position," not "shrink it back."
- Card is **already expanded** AND content fits the viewport → no-op. Collapsing what the user just expanded would surprise them.

Collapse from `.stepExpanded` happens indirectly: opening Reference / Insights (which switches `expansion`), advancing the step (resets to `.collapsed`), or the lens dismiss gesture (exit overlay, then back). The branching lives in the `.hoverSelectable(.stepCard)` `onConfirm` closure on `CoachingStepPage`. No new `HUDControl` id; one input has multiple contextual meanings, with `expansion` and `autoScrollIsOverflowing` as the discriminators. The auto-scroll itself ping-pongs top → bottom → top continuously and auto-suspends while a confirmation overlay recedes the page.

Reuse for: in-step procedure clip viewers, recording playback, multi-section settings within a single page.

### `RetraceAudioMeter`

Pattern: amplitude-driven motion.

- 9–11 vertical bars, rolling-buffer of recent peaks
- Bars travel left → right (newest sample on left) — direction matters; matches reading flow
- Per-bar sine wobble, amplitude-scaled, so silence reads as silence
- Whole-meter opacity ramps 35% → 100% with smoothed loudness — barely visible at silence, full presence at speech
- `TimelineView(.animation(...))` driven; pauses when offscreen

Reuse for: any future "real-time signal" indicator (heart rate, network throughput, gaze stability).

### `TroubleshootSearchingPage`

Pattern: multi-stage progress page driven by tool-call lifecycle.

- One page, multiple internal stages. Stage is derived from VM state — specifically, which tool call is currently in flight (`pendingToolCallNames` on `GeminiLiveSessionBase`).
- Stages render as fully different layouts inside the same page; never overlap. Transitions use the asymmetric inline transition (`.opacity + .scale(0.92, anchor: .top)` on insert, `.opacity` on remove).
- Animation triggers off the stage value (`.animation(.spring(response: 0.32, dampingFraction: 0.85), value: searchStage)`) so the spring runs once per transition, not per render.
- Continuous progress within a stage (e.g. the Google-search dotted travel-line in Stage 2) follows the no-poll rule: `withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false))` over a single state flip in `.onAppear`. Never `Timer.publish` per-tick `@State` writes.
- Stage gaps are transparent: when `searchStage` is briefly `nil` between two tool calls, the page falls back to the most-likely-next stage's layout to avoid flashing empty content.

Reuse for: any future "AI is doing something that takes a few seconds and we want to show progress" surface — embedding generation, model swap, multi-step server pipeline, etc.

---

## Anti-Patterns

Things that look fine in isolation but break the kit when shipped.

- **Always-visible destructive buttons.** They steal real estate, increase accidental destruction risk, and feel iOS-app-shaped. Hide destructive actions behind explicit gestures (double-tap, long-press) and confirmation overlays.
- **Background fills on the HUD container.** The HUD lives over a live camera feed. Any opaque container at the lens-content level kills the camera show-through and breaks the "see-through glass" illusion. Apply backgrounds only on individual pills/cards, never on parent containers.
- **Bool-driven idle pulses.** "Make it animate when something's happening" is fine. "Make it animate forever just to look alive" is dead-pixel theatre that fights with real signal motion. Silence stays silent.
- **Loud system dialogs.** SwiftUI `.alert(...)`, `.confirmationDialog(...)`, action sheets — all break the visual continuity. Build the modal inside the lens with the same glass aesthetic. The `CoachingExitConfirmationOverlay` example is the path.
- **Ad-hoc confirmation UIs.** Inline "Cancel/OK" rows tucked into a card, popovers that don't recede the underlying view, custom dialogs that drop or tweak the canonical scale/spring numbers — all forbidden. **Every** confirmation, approval, dismissal, acknowledgment, and picker surface uses the recede-and-arrive overlay pattern (see Component Patterns and Animation System). The shrinking-and-popping motion is load-bearing for the Ray-Ban lens metaphor; half-measures break it. If you find yourself thinking "this is a small confirm, can I just inline it?" — no. Copy `CoachingExitConfirmationOverlay`.
- **Polled-timer animations.** Per-tick `@State` writes for continuous progress (covered above). This is a hard rule, not a preference.
- **Cards inside cards.** Glass-on-glass nesting reads as visual noise. A panel contains content; if the content needs further grouping, use spacing or dividers, not another panel.
- **Custom font sizes outside the type scale.** Pick from the Typography table. New sizes are technical debt — they accumulate until the kit feels random.
- **Direct hex colors in views.** Add to the palette table first, then reference. Inline color literals at call sites cause drift.
- **Custom hover state on a single button.** Don't add a per-call-site `if hovered { Color.white } else { Color.clear }` background flip, text-color inversion, or alternate stroke. The unified yellow `HUDHoverHighlight` ring is the **only** hover cue across every `.hoverSelectable` element on the lens, capsule or rounded. If a button needs to read as "primary" before the cursor lands, use the resting accent stroke (1pt yellow @ 0.32) — that's a *resting* affordance, orthogonal to hover. Stacking two emphases on one button is the visual noise we just deleted from the troubleshoot pages; don't reintroduce it.

---

## Future Directions

These are coming. Designs that touch them should be aware of the trajectory.

### Focus engine + neighbor graph

Each page will declare a `FocusGraph` mapping every focusable element to its up/down/left/right neighbors. The hover coordinator gains `move(.left/.right/.up/.down)` and `select()`. MediaPipe pinch-drag wires into those calls. Default-focus on appear is required for every focusable page.

When designing a new page, **think about the neighbor map** even if you're not implementing the focus engine yet. If the layout doesn't admit a clean directional graph, the layout is wrong.

### MediaPipe pinch-drag gesture pipeline

All directional input — finger swipe today, MediaPipe tomorrow — will route through a single `coordinator.move()` and `coordinator.select()` API. New components should never wire their own gestures; they participate via the coordinator.

### Step-card full-text expansion

The step card today truncates at ~75 chars with `... Read more`. A planned tap-to-expand mode will give the full description a dedicated layout. New content patterns should account for both compact + full views by default rather than retrofitting later.

---

## Layout Token Reference

Live source of truth: `Views/RayBanHUD/RayBanHUDLayoutTokens.swift`. Quick reference of the most-used:

| Token | Value |
|---|---|
| `viewportInset` | 24 |
| `contentPadding` | 20 |
| `stackSpacing` | 12 |
| `cardRadius` | 24 |
| `iconFrame` | 36 |
| `stepSwipeMinimumDistance` | 12 |
| `stepSwipeCommitThreshold` | 80 |
| `pageSlideDuration` | 0.22 |
| `exitHoldDuration` | 2.0 |
| `completionPulseDuration` | 0.70 |
| `pageIndicatorDotDiameter` | 6 |

Don't introduce new constants at call sites. Add to the tokens file, then reference.

---

## When you're designing something new

0. **Is it a confirmation, approval, dismissal, acknowledgment, or picker surface?** If yes — STOP. Use the recede-and-arrive overlay pattern verbatim. Copy `CoachingExitConfirmationOverlay`. Don't reinvent. Don't tweak the canonical scale/spring numbers. Don't roll a `.alert` "just for this one." See **Overlays** in Component Patterns and **Recede + arrive pattern** in Animation System.
1. Re-read **Mission**. If your design adds attention-grabbing motion or always-visible affordances, reconsider.
2. Find the **closest existing pattern** in the Worked Examples section. Imitate, don't reinvent.
3. Use existing **layout tokens, animation springs, and color palette** entries. New ones go in the canonical files, not at call sites.
4. Add a **default focus** for every new focusable surface. For confirmation overlays, the default focus is the *safe* option (Cancel), never the destructive one.
5. Think about the **neighbor graph** even if focus engine isn't wired yet — bad neighbor topology = bad layout.
6. **Update this doc** when a new pattern lands. The doc is authoritative; if code disagrees, the doc gets corrected.
