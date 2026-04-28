import PDFKit
import SwiftUI

/// Shown after the user picks a PDF from `.fileImporter`. Renders the
/// first page as a thumbnail, surfaces filename + page count, and offers
/// Upload / Cancel. Captures `productName` so the server can label the
/// extracted procedure correctly.
struct PDFPreviewView: View {
  let pdfURL: URL
  let onUpload: (_ pdfURL: URL, _ productName: String) -> Void
  let onCancel: () -> Void

  @State private var thumbnail: UIImage?
  @State private var pageCount: Int = 0
  @State private var fileSizeText: String = ""
  @State private var productName: String = ""
  @State private var loadError: String?

  private let maxPDFBytes: Int64 = 50 * 1024 * 1024

  var body: some View {
    NavigationStack {
      RetraceScreen {
        ScrollView {
          VStack(spacing: Spacing.screenPadding) {
            thumbnailView
              .frame(maxWidth: .infinity)
              .frame(height: 320)
              .background(Color.surfaceRaised)
              .cornerRadius(Radius.lg)

            VStack(alignment: .leading, spacing: Spacing.xs) {
              Text(pdfURL.lastPathComponent)
                .font(.retraceHeadline)
                .foregroundColor(.textPrimary)
                .lineLimit(2)
              if !metaSummary.isEmpty {
                Text(metaSummary)
                  .font(.retraceCaption1)
                  .foregroundColor(.textSecondary)
                  .monospacedDigit()
              }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: Spacing.md) {
              Text("PRODUCT NAME")
                .font(.retraceOverline)
                .tracking(0.5)
                .foregroundColor(.textSecondary)
              TextField("e.g. Nespresso Vertuo Next", text: $productName)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled(false)
                .padding(Spacing.lg)
                .background(Color.surfaceRaised)
                .cornerRadius(Radius.md)
                .overlay(
                  RoundedRectangle(cornerRadius: Radius.md)
                    .stroke(Color.borderSubtle, lineWidth: 1)
                )
              Text("Used to title the extracted procedure.")
                .font(.retraceCaption2)
                .foregroundColor(.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let loadError {
              Text(loadError)
                .font(.retraceCaption1)
                .foregroundColor(.semanticError)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
            }

            Button {
              onUpload(pdfURL, productName.trimmingCharacters(in: .whitespacesAndNewlines))
            } label: {
              Text("Upload")
                .font(.retraceFace(.semibold, size: 17))
                .foregroundColor(.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.lg)
                .background(canUpload ? Color.appPrimary : Color.surfaceRaised)
                .cornerRadius(Radius.md)
            }
            .disabled(!canUpload)

            Button(action: onCancel) {
              Text("Cancel")
                .font(.retraceBody)
                .foregroundColor(.textSecondary)
                .padding(.vertical, Spacing.md)
            }
          }
          .padding(.horizontal, Spacing.screenPadding)
          .padding(.vertical, Spacing.lg)
        }
      }
      .navigationTitle("Review Manual")
      .navigationBarTitleDisplayMode(.inline)
      .retraceNavBar()
    }
    .task { await loadThumbnail() }
  }

  private var metaSummary: String {
    var parts: [String] = []
    if pageCount > 0 { parts.append("\(pageCount) \(pageCount == 1 ? "page" : "pages")") }
    if !fileSizeText.isEmpty { parts.append(fileSizeText) }
    return parts.joined(separator: " · ")
  }

  private var canUpload: Bool {
    loadError == nil && !productName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  @ViewBuilder
  private var thumbnailView: some View {
    if let thumbnail {
      Image(uiImage: thumbnail)
        .resizable()
        .aspectRatio(contentMode: .fit)
        .padding(Spacing.xl)
    } else if loadError != nil {
      Image(systemName: "doc.fill")
        .font(.system(size: 48))
        .foregroundColor(.textTertiary)
    } else {
      ProgressView().tint(.textPrimary)
    }
  }

  private func loadThumbnail() async {
    let needsScope = pdfURL.startAccessingSecurityScopedResource()
    defer { if needsScope { pdfURL.stopAccessingSecurityScopedResource() } }

    let attrs = (try? FileManager.default.attributesOfItem(atPath: pdfURL.path)) ?? [:]
    if let size = attrs[.size] as? NSNumber {
      let bytes = size.int64Value
      fileSizeText = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
      if bytes > maxPDFBytes {
        loadError = "This PDF is too large (max 50 MB). Try a smaller file."
        return
      }
    }

    guard let document = PDFDocument(url: pdfURL) else {
      loadError = "Couldn't open this PDF. It may be encrypted or corrupted."
      return
    }
    pageCount = document.pageCount
    if let firstPage = document.page(at: 0) {
      let size = CGSize(width: 600, height: 800)
      thumbnail = firstPage.thumbnail(of: size, for: .mediaBox)
    }

    if document.isEncrypted {
      loadError = "This PDF is encrypted and can't be processed."
    }

    if productName.isEmpty {
      productName = Self.suggestedProductName(from: pdfURL)
    }
  }

  private static func suggestedProductName(from url: URL) -> String {
    let stem = url.deletingPathExtension().lastPathComponent
    let cleaned = stem
      .replacingOccurrences(of: "_", with: " ")
      .replacingOccurrences(of: "-", with: " ")
    return cleaned.capitalized
  }
}
