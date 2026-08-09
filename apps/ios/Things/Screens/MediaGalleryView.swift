import SwiftUI
import UIKit
import ThingsCore

/// The media gallery — a Photos-like grid of a Thing's image, video and icon fields.
///
/// **Never glass.** Media is the subject; glass over it steals from it.
struct MediaGalleryView: View {

    @Environment(AppModel.self) private var model

    let thingID: String

    @State private var detail: ThingDetail?
    @State private var selectedFieldID: String?

    private let columns = [GridItem(.adaptive(minimum: Theme.Size.galleryTile), spacing: Theme.Spacing.tight)]

    var body: some View {
        Group {
            if let detail, let registry = model.registry {
                let items = detail.galleryFields(registry: registry)
                if items.isEmpty {
                    EmptyStateView(symbol: "photo.on.rectangle",
                                   title: "No media yet",
                                   message: "Images, videos and icons you attach to this Thing show up here.")
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: Theme.Spacing.tight) {
                            ForEach(items) { field in
                                Button {
                                    selectedFieldID = field.id
                                } label: {
                                    GalleryTile(field: field, detail: detail, registry: registry)
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("gallery.tile.\(field.id)")
                            }
                        }
                        .padding(Theme.Spacing.tight)
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Media")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier(A11y.Gallery.root)
        .navigationDestination(item: $selectedFieldID) { fieldID in
            if let detail, let field = detail.fields.first(where: { $0.id == fieldID }) {
                PhotoViewerView(field: field, detail: detail)
            }
        }
        .task { await observe() }
    }

    private func observe() async {
        guard let library = model.library else { return }
        do {
            for try await value in library.things.observeDetail(id: thingID) {
                detail = value
            }
        } catch {
            model.errorMessage = "Could not load media. \(error)"
        }
    }
}

struct GalleryTile: View {

    let field: Field
    let detail: ThingDetail
    let registry: FieldKindRegistry

    var body: some View {
        let object = field.objectHash.flatMap { detail.objects[$0] }
        ZStack {
            Rectangle()
                .fill(Color(uiColor: .secondarySystemBackground))
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
        .aspectRatio(1, contentMode: .fill)
        .clipShape(ThingsShape.rounded(Theme.Radius.thumbnail))
        .overlay(alignment: .bottomLeading) {
            if let name = field.filename {
                Text(name)
                    .font(.caption2)
                    .lineLimit(1)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .background(.thinMaterial, in: Capsule())
                    .padding(4)
            }
        }
    }
}

/// One item, full screen.
///
/// A real Quick Look bridge (`QLPreviewController`) is the eventual answer for arbitrary
/// documents; this ships the metadata view so the screen exists, is photographed, and does
/// not pretend to render bytes the phone may not have downloaded.
struct PhotoViewerView: View {

    let field: Field
    let detail: ThingDetail

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
                .padding(.horizontal, Theme.Spacing.large)
            VStack(spacing: 2) {
                Text(field.filename ?? field.label).font(.headline)
                if let hash = field.objectHash, let object = detail.objects[hash] {
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
