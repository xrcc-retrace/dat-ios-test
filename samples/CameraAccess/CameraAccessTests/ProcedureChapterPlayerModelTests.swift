import XCTest

@testable import CameraAccess

final class ProcedureChapterPlayerModelTests: XCTestCase {

  func testActiveStepBeforeFirstChapterStartIsNil() {
    let steps = [
      makeStep(number: 1, start: 5, end: 12),
      makeStep(number: 2, start: 12, end: 24),
    ]

    XCTAssertNil(ProcedureChapterPlayerModel.activeStep(at: 4.9, steps: steps))
  }

  func testActiveStepAtBoundaryMovesToNextChapter() {
    let steps = [
      makeStep(number: 1, start: 0, end: 12),
      makeStep(number: 2, start: 12, end: 24),
      makeStep(number: 3, start: 24, end: 39),
    ]

    let active = ProcedureChapterPlayerModel.activeStep(at: 12, steps: steps)

    XCTAssertEqual(active?.stepNumber, 2)
  }

  func testActiveStepAfterLastChapterStartStaysOnLastChapter() {
    let steps = [
      makeStep(number: 1, start: 0, end: 12),
      makeStep(number: 2, start: 12, end: 24),
      makeStep(number: 3, start: 24, end: 39),
    ]

    let active = ProcedureChapterPlayerModel.activeStep(at: 55, steps: steps)

    XCTAssertEqual(active?.stepNumber, 3)
  }

  func testActiveStepSortsUnorderedStepsForCallers() {
    let steps = [
      makeStep(number: 3, start: 24, end: 39),
      makeStep(number: 1, start: 0, end: 12),
      makeStep(number: 2, start: 12, end: 24),
    ]

    let active = ProcedureChapterPlayerModel.activeStep(at: 18, steps: steps)

    XCTAssertEqual(active?.stepNumber, 2)
  }

  func testSourceVideoURLUsesServerProvidedFilename() {
    let procedure = makeProcedure(sourceVideo: "custom.mov")

    XCTAssertEqual(
      procedure.sourceVideoURL(serverBaseURL: "https://example.com")?.absoluteString,
      "https://example.com/api/uploads/custom.mov"
    )
  }

  func testSourceVideoURLFallsBackToLegacyMP4Filename() {
    let procedure = makeProcedure(sourceVideo: nil)

    XCTAssertEqual(
      procedure.sourceVideoURL(serverBaseURL: "https://example.com")?.absoluteString,
      "https://example.com/api/uploads/procedure-123.mp4"
    )
  }

  func testDescriptionPreviewShorterThanLimitIsNotTruncatable() {
    let preview = ProcedureDescriptionPreview(description: "Short summary")

    XCTAssertEqual(preview.fullText, "Short summary")
    XCTAssertNil(preview.collapsedText)
    XCTAssertFalse(preview.isTruncatable)
  }

  func testDescriptionPreviewAtExactLimitIsNotTruncatable() {
    let description = String(repeating: "a", count: ProcedureDescriptionPreview.collapsedCharacterLimit)
    let preview = ProcedureDescriptionPreview(description: description)

    XCTAssertEqual(preview.fullText, description)
    XCTAssertNil(preview.collapsedText)
    XCTAssertFalse(preview.isTruncatable)
  }

  func testDescriptionPreviewLongerThanLimitAppendsEllipsis() {
    let description = String(repeating: "a", count: ProcedureDescriptionPreview.collapsedCharacterLimit + 5)
    let preview = ProcedureDescriptionPreview(description: description)

    XCTAssertEqual(
      preview.collapsedText,
      String(repeating: "a", count: ProcedureDescriptionPreview.collapsedCharacterLimit) + "… "
    )
    XCTAssertTrue(preview.isTruncatable)
  }

  func testDescriptionPreviewBacksUpToLastWhitespaceWhenCuttingWord() {
    let description = "This summary has enough words that the limit lands inside supercalifragilisticexpialidocious territory."
    let preview = ProcedureDescriptionPreview(description: description, characterLimit: 66)

    XCTAssertEqual(preview.collapsedText, "This summary has enough words that the limit lands inside… ")
    XCTAssertTrue(preview.isTruncatable)
  }

  func testOrderedStepsSortByTimestampStart() {
    let procedure = ProcedureResponse(
      id: "procedure-123",
      title: "Procedure",
      description: "Description",
      steps: [
        makeStep(number: 3, start: 24, end: 39),
        makeStep(number: 1, start: 0, end: 12),
        makeStep(number: 2, start: 12, end: 24),
      ],
      totalDuration: 39,
      createdAt: "2026-04-21T12:00:00Z",
      status: nil,
      errorMessage: nil,
      sourceVideo: nil
    )

    XCTAssertEqual(procedure.orderedSteps.map(\.stepNumber), [1, 2, 3])
  }

  private func makeProcedure(sourceVideo: String?) -> ProcedureResponse {
    ProcedureResponse(
      id: "procedure-123",
      title: "Procedure",
      description: "Description",
      steps: [
        makeStep(number: 1, start: 0, end: 12),
      ],
      totalDuration: 12,
      createdAt: "2026-04-21T12:00:00Z",
      status: nil,
      errorMessage: nil,
      sourceVideo: sourceVideo
    )
  }

  private func makeStep(number: Int, start: Double, end: Double) -> ProcedureStepResponse {
    ProcedureStepResponse(
      stepNumber: number,
      title: "Step \(number)",
      description: "Description \(number)",
      timestampStart: start,
      timestampEnd: end
    )
  }
}
