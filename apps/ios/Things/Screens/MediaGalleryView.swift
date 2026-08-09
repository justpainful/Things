import SwiftUI
import UIKit
import ThingsCore

/// The media gallery — a Photos-like grid of a Thing's image, video and icon fields, and
/// one of the two places media gets **into** Things at all.
///
/// **Never glass on the media itself.** Media is the subject; glass over it steals from it.
/// The one glass surface here is the floating import status card, which is chrome above
/// content and therefore exactly where glass belongs.
struct MediaGalleryView: View {

    @Environment(AppModel.self) private var model

    let thingID: String

    @State private var detail: ThingDetail?
    /// Same lesson as the detail screen: without this, "loading", "nothing attached" and
    /// "the query threw" are one indistinguishable spinner, and the screenshot that proves
    /// the feature works looks identical to the one that proves it does not.
    @State private var didReceiveValue = false
    @State private var loadError: String?
    @State private var selectedFieldID: String?

    @State private var importer = AttachmentImporter()
    @State private var isPresentingChoice = false
    @State private var isPresentingPhotos = false
    @State private var isPresentingFiles = false

    private let columns = [GridItem(.adaptive(minimum: Theme.Size.galleryTile), spacing: Theme.Spacing.tight)]

    var body: some View {
        Group {
            if let detail, let registry = model.registry {
                let items = detail.galleryFields(registry: registry)
                if items.isEmpty {
                    EmptyStateView(symbol: "photo.on.rectangle",
                                   title: "No media yet",
                                   message: "Images, videos and icons you attach to this Thing show up here.",
                                   actionTitle: "Add Photo or File",
                                   action: { isPresentingChoice = true })
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: Theme.Spacing.tight) {
                            ForEach(items) { field in
                                Button {
                                    selectedFieldID = field.id
                                } label: {
                                    GalleryTile(field: field,
                                                detail: detail,
                                                registry: registry,
                                                library: model.library)
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("gallery.tile.\(field.id)")
                                .accessibilityLabel(field.label)
                            }
                        }
                        .padding(Theme.Spacing.tight)
                    }
                }
            } else if let loadError {
                EmptyStateView(symbol: "exclamationmark.triangle",
                               title: "Couldn't open media",
                               message: loadError)
            } else if didReceiveValue {
                EmptyStateView(symbol: "photo.on.rectangle",
                               title: "No media yet",
                               message: "Images, videos and icons you attach to this Thing show up here.",
                               actionTitle: "Add Photo or File",
                               action: { isPresentingChoice = true })
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Media")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isPresentingChoice = true
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(importer.isWorking)
                .accessibilityIdentifier(A11y.GalleryImport.addButton)
                .accessibilityLabel("Add Media")
            }
        }
        .confirmationDialog("Add to Media", isPresented: $isPresentingChoice, titleVisibility: .visible) {
            Button("Photo or Video") { isPresentingPhotos = true }
                .accessibilityIdentifier(A11y.GalleryImport.addPhoto)
            Button("Choose File") { isPresentingFiles = true }
                .accessibilityIdentifier(A11y.GalleryImport.addFile)
            Button("Cancel", role: .cancel) { }
        }
        .attachmentImport(photos: $isPresentingPhotos,
                          files: $isPresentingFiles,
                          thingID: thingID,
                          maxPhotos: 10,
                          importer: importer)
        .overlay(alignment: .bottom) { importStatus }
        .accessibilityIdentifier(A11y.Gallery.root)
        .navigationDestination(item: $selectedFieldID) { fieldID in
            if let detail, let field = detail.fields.first(where: { $0.id == fieldID }) {
                PhotoViewerView(field: field, detail: detail, library: model.library)
            }
        }
        .task { await observe() }
    }

    // MARK: - Import status

    @ViewBuilder
    private var importStatus: some View {
        if let progress = importer.progress {
            AttachmentProgressCard(progress: progress)
                .padding(Theme.Spacing.medium)
                .thingsGlass(cornerRadius: Theme.Radius.card)
                .padding(Theme.Spacing.medium)
                .transition(.opacity)
        } else if let failure = importer.failure {
            Button {
                importer.failure = nil
            } label: {
                AttachmentFailureCard(message: failure)
                    .padding(Theme.Spacing.medium)
            }
            .buttonStyle(.plain)
            .thingsGlass(cornerRadius: Theme.Radius.card)
            .padding(Theme.Spacing.medium)
        } else if let summary = importer.summary {
            Button {
                importer.clearSummary()
            } label: {
                VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                    AttachmentSummaryCard(summary: summary)
                    if let placement = placementNote(for: summary) {
                        Text(placement)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(Theme.Spacing.medium)
            }
            .buttonStyle(.plain)
            .thingsGlass(cornerRadius: Theme.Radius.card)
            .padding(Theme.Spacing.medium)
            .task(id: summary) {
                // Long enough to read one sentence; a tap clears it sooner.
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                // Cancelled means a *newer* summary replaced this one. Clearing here would
                // wipe the message that just arrived.
                guard !Task.isCancelled else { return }
                importer.clearSummary()
            }
        }
    }

    /// A PDF attached from here is a real field on this Thing — it is simply not a gallery
    /// variant, so it lands in the field list instead. Saying so beats leaving the user
    /// staring at a grid that did not change.
    private func placementNote(for summary: AttachmentImporter.Summary) -> String? {
        guard let registry = model.registry,
              let variant = registry.variant(summary.lastVariantID) else { return nil }
        guard !variant.showsInGallery else { return nil }
        return "A \(variant.label.lowercased()) is not media, so it was added to this Thing's fields."
    }

    // MARK: - Observation

    private func observe() async {
        guard let library = model.library else { return }
        do {
            for try await value in library.things.observeDetail(id: thingID) {
                detail = value
                didReceiveValue = true
            }
        } catch {
            loadError = String(describing: error)
            didReceiveValue = true
            model.errorMessage = "Could not load media. \(error)"
        }
    }
}

struct GalleryTile: View {

    let field: Field
    let detail: ThingDetail
    let registry: FieldKindRegistry
    let library: Library?

    var body: some View {
        let object = field.objectHash.flatMap { detail.objects[$0] }
        Rectangle()
            .fill(Color(uiColor: .secondarySystemBackground))
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                VStack(spacing: Theme.Spacing.tight) {
                    Image(systemName: registry.variant(field.variant)?.symbol ?? "photo")
                        .font(.system(size: 24, weight: .light))
                        .foregroundStyle(.secondary)
                    if object == nil {
                        // Never hide content because of a storage policy: show it, greyed,
                        // with a way to fetch it.
                        Text("Not on iPhone")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .overlay {
                // The real pixels, decrypted off the main actor, drawn over the
                // placeholder once they arrive.
                if let hash = field.objectHash, object != nil, let library {
                    DecryptedImageView(objectHash: hash,
                                       library: library,
                                       maximumSide: Theme.Size.galleryTile,
                                       contentMode: .fill)
                        .accessibilityIdentifier(A11y.GalleryImport.image(field.id))
                }
            }
            .clipShape(ThingsShape.rounded(Theme.Radius.thumbnail))
            .overlay(alignment: .bottomLeading) {
                Text(field.filename ?? field.label)
                    .font(.caption2)
                    .lineLimit(1)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .background(.thinMaterial, in: Capsule())
                    .padding(4)
            }
    }
}

/// One item, full screen.
///
/// Shows the actual image when its bytes are in the library, and says plainly when they are
/// not. A Quick Look bridge (`QLPreviewController`) remains the eventual answer for
/// arbitrary documents; this does not pretend to render bytes the phone may not have.
struct PhotoViewerView: View {

    let field: Field
    let detail: ThingDetail
    let library: Library?

    private var object: StoredObject? {
        field.objectHash.flatMap { detail.objects[$0] }
    }

    var body: some View {
        VStack(spacing: Theme.Spacing.medium) {
            Spacer()

            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
                .aspectRatio(3.0 / 4.0, contentMode: .fit)
                .overlay {
                    Image(systemName: "photo")
                        .font(.system(size: 56, weight: .ultraLight))
                        .foregroundStyle(.secondary)
                }
                .overlay {
                    if let hash = field.objectHash, object != nil, let library {
                        DecryptedImageView(objectHash: hash,
                                           library: library,
                                           contentMode: .fit)
                    }
                }
                .clipShape(ThingsShape.rounded(Theme.Radius.card))
                .padding(.horizontal, Theme.Spacing.large)

            VStack(spacing: 2) {
                Text(field.filename ?? field.label).font(.headline)
                if let object = object {
                    Text("\(object.mimeType ?? "File") · \(ByteSize.string(object.byteSize))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Not downloaded to this iPhone")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .navigationTitle(field.label)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier(A11y.Gallery.viewer)
    }
}
