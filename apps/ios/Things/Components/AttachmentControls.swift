import SwiftUI
import UniformTypeIdentifiers
import PhotosUI
import ThingsCore

/// The two ways in, and the three things the user sees while and after they happen.
///
/// Presented from Booleans rather than embedded as views, so a caller can trigger either
/// route from a toolbar button, a confirmation dialog or a list row — a `PhotosPicker` view
/// cannot live inside a `Menu`, and the gallery needs exactly that.

// MARK: - Presentation

struct AttachmentImportModifier: ViewModifier {

    @Environment(AppModel.self) private var model

    @Binding var isPresentingPhotos: Bool
    @Binding var isPresentingFiles: Bool

    let thingID: String
    /// The label the new field gets. `nil` means "use the filename".
    var label: String?
    var maxPhotos: Int
    let importer: AttachmentImporter

    @State private var photoItems: [PhotosPickerItem] = []

    func body(content: Content) -> some View {
        content
            .photosPicker(isPresented: $isPresentingPhotos,
                          selection: $photoItems,
                          maxSelectionCount: maxPhotos,
                          matching: .any(of: [.images, .videos]))
            .fileImporter(isPresented: $isPresentingFiles,
                          allowedContentTypes: [.item],
                          allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    Task { @MainActor in
                        await importer.attach(fileAt: url, to: thingID, label: label, model: model)
                    }
                case .failure(let error):
                    let message = error.localizedDescription
                    Task { @MainActor in
                        importer.failure = "That file could not be opened. \(message)"
                    }
                }
            }
            .onChange(of: photoItems) { _, items in
                guard !items.isEmpty else { return }
                photoItems = []
                Task { @MainActor in
                    await importer.attach(photos: items, to: thingID, label: label, model: model)
                }
            }
    }
}

extension View {

    func attachmentImport(photos: Binding<Bool>,
                          files: Binding<Bool>,
                          thingID: String,
                          label: String? = nil,
                          maxPhotos: Int = 1,
                          importer: AttachmentImporter) -> some View {
        modifier(AttachmentImportModifier(isPresentingPhotos: photos,
                                          isPresentingFiles: files,
                                          thingID: thingID,
                                          label: label,
                                          maxPhotos: maxPhotos,
                                          importer: importer))
    }
}

// MARK: - Buttons

/// Two full-width rows, each comfortably past 44pt, for use inside a list or a form.
struct AttachmentImportButtons: View {

    @Binding var isPresentingPhotos: Bool
    @Binding var isPresentingFiles: Bool
    var isEnabled: Bool = true

    var body: some View {
        // `Group` stays transparent in a `List` and yields two rows. A modifier applied to
        // the `Group` itself would wrap it and collapse them into one, so `.disabled` goes
        // on each button.
        Group {
            Button {
                isPresentingPhotos = true
            } label: {
                row("Photo or Video", symbol: "photo.on.rectangle")
            }
            .disabled(!isEnabled)
            .accessibilityIdentifier(A11y.Attach.photoButton)

            Button {
                isPresentingFiles = true
            } label: {
                row("Choose File", symbol: "folder")
            }
            .disabled(!isEnabled)
            .accessibilityIdentifier(A11y.Attach.fileButton)
        }
    }

    private func row(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
    }
}

// MARK: - Progress

/// Content, not chrome — no glass. The caller decides whether it floats.
struct AttachmentProgressCard: View {

    let progress: AttachmentImporter.Progress

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
            Text(progress.filename)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)

            if progress.isDeterminate {
                ProgressView(value: progress.fraction)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
            }

            Text(progress.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier(A11y.Attach.progress)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Adding \(progress.filename)")
        .accessibilityValue(progress.detail)
    }
}

// MARK: - Result

/// The finished state, including the one case that must never be silent: the bytes were
/// already in the library, so Things linked what it had instead of storing a second copy.
struct AttachmentSummaryCard: View {

    let summary: AttachmentImporter.Summary

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.small) {
            Image(systemName: summary.mentionsDuplicate ? "square.on.square" : "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(summary.mentionsDuplicate ? Theme.Palette.inkSecondary : Theme.Palette.success)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(summary.title)
                    .font(.subheadline.weight(.medium))
                Text(summary.message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .accessibilityIdentifier(summary.mentionsDuplicate ? A11y.Attach.duplicate : A11y.Attach.result)
        .accessibilityElement(children: .combine)
    }
}

/// A failure the user can act on. `AppModel.errorMessage` is written by `perform` but no
/// screen renders it, so an import failure routed only there would be invisible.
struct AttachmentFailureCard: View {

    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.small) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title3)
                .foregroundStyle(Theme.Palette.warning)
                .accessibilityHidden(true)
            Text(message)
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .accessibilityIdentifier(A11y.Attach.failure)
        .accessibilityElement(children: .combine)
    }
}
