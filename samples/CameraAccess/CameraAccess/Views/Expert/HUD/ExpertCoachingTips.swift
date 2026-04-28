import Foundation

/// Static pool of "how to narrate well" reminders shown on the Expert HUD.
///
/// These exist so an expert recording a procedure gets the same kind of
/// consistent in-screen coaching that the learner gets during a Gemini Live
/// session — but without any AI on the wire. Cycled by user gesture only
/// (touch swipe or pinch-drag-release).
struct ExpertNarrationTip: Identifiable, Equatable {
  let id: Int
  let title: String
  let body: String
}

enum ExpertCoachingTips {
  static let pool: [ExpertNarrationTip] = [
    ExpertNarrationTip(
      id: 0,
      title: "Teach like they've never seen it",
      body: "Speak clearly and explain as if the learner has zero context. Name the tool, name the part, name the action."
    ),
    ExpertNarrationTip(
      id: 1,
      title: "Narrate every step out loud",
      body: "Say the step before you do it, then describe what you're doing while you do it."
    ),
    ExpertNarrationTip(
      id: 2,
      title: "Call out warnings BEFORE the risk",
      body: "If something could pinch, burn, shock, or break — mention it before you touch it, not after."
    ),
    ExpertNarrationTip(
      id: 3,
      title: "Drop tips for the non-obvious",
      body: "Gotchas, shortcuts, things you only know from experience — those are gold. Say them out loud."
    ),
    ExpertNarrationTip(
      id: 4,
      title: "Pause between steps",
      body: "A short silence between steps makes it much easier to auto-segment clips later."
    ),
    ExpertNarrationTip(
      id: 5,
      title: "Speak into the mic",
      body: "If you turn your head away from the camera, the narration goes with it. Stay oriented toward what you're showing."
    ),
    ExpertNarrationTip(
      id: 6,
      title: "If you improvised, say so",
      body: "Calling out a deviation from the 'normal' way teaches the learner when rules can bend."
    ),
  ]
}
