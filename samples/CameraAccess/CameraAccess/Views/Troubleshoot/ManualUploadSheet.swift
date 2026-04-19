import SwiftUI
import UniformTypeIdentifiers

/// Sheet that fires when Gemini calls `fetch_manual` and the server replies
/// with `user_upload_required`. Lets the user pick a PDF from Files, then
/// uploads and confirms. Once uploaded, the VM injects a synthetic follow-up
/// to Gemini so the conversation continues to `generate_sop_from_manual`.
struct ManualUploadSheet: View {
  @Binding var isPresented: Bool
  let onUpload: (URL) async -> Bool

  @State private var showPicker = false
  @State private var pickedURL: URL?
  @State private var isUploading = false
  @State private var uploadError: String?

  var body: some View {
    VStack(spacing: Spacing.xl) {
      Capsule()
        .fill(Color.surfaceRaised)
        .frame(width: 36, height: 4)
        .padding(.top, Spacing.md)

      VStack(spacing: Spacing.md) {
        Image(systemName: "doc.fill")
          .font(.system(size: 36))
          .foregroundColor(.textPrimary)

        Text("Manual needed")
          .font(.retraceTitle3)
          .foregroundColor(.textPrimary)

        Text("There's no manual on file for this product. Pick the manufacturer PDF — I'll read it and build a repair procedure focused on your problem.")
          .font(.retraceCallout)
          .foregroundColor(.textSecondary)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(.horizontal, Spacing.xl)

      if let url = pickedURL {
        HStack(spacing: Spacing.sm) {
          Image(systemName: "doc.text.fill")
            .foregroundColor(.semanticInfo)
          Text(url.lastPathComponent)
            .font(.retraceCallout)
            .foregroundColor(.textPrimary)
            .lineLimit(1)
            .truncationMode(.middle)
          Spacer(minLength: 0)
        }
        .padding(Spacing.md)
        .glassPanel(cornerRadius: Radius.md)
        .padding(.horizontal, Spacing.xl)
      }

      if let err = uploadError {
        Text(err)
          .font(.retraceCaption1)
          .foregroundColor(.appPrimary)
          .multilineTextAlignment(.center)
          .padding(.horizontal, Spacing.xl)
      }

      VStack(spacing: Spacing.sm) {
        CustomButton(
          title: pickedURL == nil ? "Pick PDF" : "Pick Different PDF",
          icon: "doc.badge.plus",
          style: pickedURL == nil ? .primary : .secondary,
          isDisabled: isUploading
        ) {
          showPicker = true
        }

        if pickedURL != nil {
          CustomButton(
            title: isUploading ? "Uploading…" : "Upload",
            icon: isUploading ? nil : "arrow.up.circle.fill",
            style: .primary,
            isDisabled: isUploading
          ) {
            submitUpload()
          }
        }

        CustomButton(
          title: "Cancel",
          icon: nil,
          style: .ghost,
          isDisabled: isUploading
        ) {
          isPresented = false
        }
      }
      .padding(.horizontal, Spacing.xl)

      Spacer()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.backgroundPrimary.ignoresSafeArea())
    .fileImporter(
      isPresented: $showPicker,
      allowedContentTypes: [.pdf],
      allowsMultipleSelection: false
    ) { result in
      switch result {
      case .success(let urls):
        guard let url = urls.first else { return }
        // fileImporter returns a security-scoped URL — keep a security-scoped
        // copy so the uploader can read it later without scope-expiry errors.
        if let stable = copyToTemp(url) {
          pickedURL = stable
        } else {
          uploadError = "Couldn't access that file."
        }
      case .failure(let err):
        uploadError = err.localizedDescription
      }
    }
  }

  private func submitUpload() {
    guard let url = pickedURL else { return }
    isUploading = true
    uploadError = nil
    Task {
      let ok = await onUpload(url)
      isUploading = false
      if ok {
        isPresented = false
      } else {
        uploadError = "Upload failed. Check your connection and try again."
      }
    }
  }

  private func copyToTemp(_ source: URL) -> URL? {
    let shouldStopAccess = source.startAccessingSecurityScopedResource()
    defer { if shouldStopAccess { source.stopAccessingSecurityScopedResource() } }
    let temp = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("pdf")
    do {
      try FileManager.default.copyItem(at: source, to: temp)
      return temp
    } catch {
      print("[ManualUpload] failed to copy picked file: \(error)")
      return nil
    }
  }
}
