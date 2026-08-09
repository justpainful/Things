import Foundation
import SwiftUI
import Observation
import UIKit
import ImageIO
import UniformTypeIdentifiers
import PhotosUI
import ThingsCore

/// Bringing a photo, a video or any other file **into** Things.
///
/// There are no app extensions and no share sheet into this app — a free Apple account
/// cannot provision them — so in-app import is the only way anything gets in. That makes
/// this file load-bearing rather than a convenience.
///
/// Two rules shape everything below:
///
/// 1. **Nothing heavy happens on the main actor.** Reading a 400 MB file, hashing it with
///    SHA-256 and sealing it frame by frame with AES-GCM is seconds of work. It runs in a
///    detached task; the main actor only reads a progress counter.
/// 2. **`wasDuplicate` is user-facing.** The object store is content addressed, so storing
///    the same file twice costs one copy of the bytes and two reference counts. That is a
///    good thing and the user is told it happened rather than left wondering why a 2 GB
///    import finished instantly.

// MARK: - Identifiers

extension A11y {

    /// Import controls. A separate nest rather than an extension of `Gallery`, because a
    /// nested type cannot be reopened.
    enum Attach {
        static let photoButton = "attach.photo"
        static let fileButton = "attach.file"
        static let progress = "attach.progress"
        static let result = "attach.result"
        static let duplicate = "attach.duplicate"
        static let failure = "attach.failure"
        static let done = "attach.done"
    }

    enum AddField {
        static let typeList = "addField.typeList"
        static let valueStep = "addField.valueStep"
        static let labelField = "addField.label"
        static let valueField = "addField.value"
        static let confirm = "addField.confirm"
        static let cancel = "addField.cancel"
        static func group(_ id: String) -> String { "addField.group.\(id)" }
        /// **Unchanged.** The previous sheet published exactly this string per variant and
        /// the Screenshot Tour is allowed to depend on it.
        static func type(_ id: String) -> String { "addField.\(id)" }
    }

    enum GalleryImport {
        static let addButton = "gallery.add"
        static let addPhoto = "gallery.add.photo"
        static let addFile = "gallery.add.file"
        static func image(_ fieldID: String) -> String { "gallery.image.\(fieldID)" }
    }
}

// MARK: - Choosing the variant

/// Which `attachment` variant a file becomes.
///
/// Registry-driven on purpose: the file's uniform type picks a **marker**, and the marker
/// picks the first `attachment` variant in `field-kinds.json` carrying it. Adding a new
/// attachment variant tomorrow is still a one-line JSON change with no edit here.
enum AttachmentVariants {

    static func marker(for type: UTType?) -> String? {
        guard let type else { return nil }
        if type.conforms(to: .image) { return "type:image" }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return "type:video" }
        if type.conforms(to: .audio) { return "type:audio" }
        if type.conforms(to: .pdf) { return "type:document" }
        return nil
    }

    static func variantID(for type: UTType?, registry: FieldKindRegistry) -> String {
        let attachments = registry.variants(ofKind: .attachment)
        if let wanted = marker(for: type),
           let match = attachments.first(where: { $0.marker == wanted }) {
            return match.id
        }
        if let generic = attachments.first(where: { $0.marker == "has:file" }) {
            return generic.id
        }
        return attachments.first?.id ?? "attachment"
    }

    /// The everyday word for a thing the user just picked, used when there is no filename —
    /// which is every item that comes out of the Photos picker.
    static func displayName(for type: UTType?) -> String {
        switch marker(for: type) ?? "" {
        case "type:image": return "Photo"
        case "type:video": return "Video"
        case "type:audio": return "Audio"
        case "type:document": return "Document"
        default: return "File"
        }
    }
}

// MARK: - Progress hand-off

/// A counter shared between the worker thread and the main actor.
///
/// A lock rather than an actor hop per chunk: a 400 MB file is 400 chunks, and 400 hops to
/// move a progress bar is work the main thread does not need to do. The main actor samples
/// this ten times a second instead.
final class AttachmentProgressBox: @unchecked Sendable {

    private let lock = NSLock()
    private var storedBytesRead: Int64 = 0
    private var storedTotalBytes: Int64 = 0
    private var storedIsSealing = false

    var bytesRead: Int64 {
        lock.lock(); defer { lock.unlock() }
        return storedBytesRead
    }

    var totalBytes: Int64 {
        lock.lock(); defer { lock.unlock() }
        return storedTotalBytes
    }

    var isSealing: Bool {
        lock.lock(); defer { lock.unlock() }
        return storedIsSealing
    }

    func setBytesRead(_ value: Int64) {
        lock.lock(); storedBytesRead = value; lock.unlock()
    }

    func setTotalBytes(_ value: Int64) {
        lock.lock(); storedTotalBytes = value; lock.unlock()
    }

    func beginSealing() {
        lock.lock(); storedIsSealing = true; lock.unlock()
    }
}

/// What one finished import produced.
struct AttachmentOutcome: Sendable {
    var filename: String
    var byteSize: Int64
    var wasDuplicate: Bool
    /// Which registry variant the file became. The gallery needs it to know whether the
    /// new field will show up there or in the Thing's field list.
    var variantID: String
}

// MARK: - The work

/// Everything that must **not** run on the main actor.
///
/// A plain enum rather than static members of the importer: static members of a
/// `@MainActor` type are themselves main-actor isolated, which would hop the very work
/// this exists to keep off it.
enum AttachmentWorker {

    /// 1 MiB, matching the object store's frame size.
    static let chunkByteCount = 1 << 20

    static func byteCount(of url: URL) -> Int64 {
        if let values = try? url.resourceValues(forKeys: [.fileSizeKey]), let size = values.fileSize {
            return Int64(size)
        }
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attributes[.size] as? NSNumber {
            return size.int64Value
        }
        return 0
    }

    /// Chunked so the progress bar reflects real bytes rather than a guess. Peak memory is
    /// the same as `Data(contentsOf:)` — the object store takes whole `Data` — but a 2 GB
    /// import that reports nothing for ninety seconds is indistinguishable from a hang.
    static func read(_ url: URL, into box: AttachmentProgressBox) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var data = Data()
        let total = box.totalBytes
        if total > 0, total < Int64(Int.max) {
            data.reserveCapacity(Int(total))
        }
        while true {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: chunkByteCount), !chunk.isEmpty else { break }
            data.append(chunk)
            box.setBytesRead(Int64(data.count))
        }
        box.setTotalBytes(Int64(data.count))
        box.setBytesRead(Int64(data.count))
        return data
    }

    /// Dimensions without decoding the image. `object.width` / `object.height` exist so the
    /// gallery can lay out before any pixels are decrypted.
    static func imageDimensions(_ data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            return nil
        }
        return (width, height)
    }

    /// The one write. Storing the bytes and creating the field share a transaction, so a
    /// crash between them cannot leave an object nobody references — and it goes through
    /// `library.write`, so the field lands in the oplog like every other change.
    static func store(data: Data,
                      filename: String,
                      mimeType: String?,
                      variantID: String,
                      label: String,
                      thingID: String,
                      library: Library) throws -> AttachmentOutcome {
        let dimensions = imageDimensions(data)
        let wasDuplicate = try library.write { db -> Bool in
            let stored = try library.objects.store(db,
                                                   data: data,
                                                   mimeType: mimeType,
                                                   width: dimensions?.width,
                                                   height: dimensions?.height)
            try library.fields.addField(db,
                                        thingID: thingID,
                                        variantID: variantID,
                                        label: label,
                                        objectHash: stored.object.objectHash)
            return stored.wasDuplicate
        }
        return AttachmentOutcome(filename: filename,
                                 byteSize: Int64(data.count),
                                 wasDuplicate: wasDuplicate,
                                 variantID: variantID)
    }
}

// MARK: - The importer

@MainActor
@Observable
final class AttachmentImporter {

    struct Progress: Equatable {
        var filename: String
        var totalBytes: Int64
        var bytesRead: Int64
        /// Hashing, encrypting and the database write. There is no byte count to report —
        /// it is one call into the object store — so this phase is honestly indeterminate
        /// rather than a bar that invents movement.
        var isSealing: Bool

        var fraction: Double {
            guard totalBytes > 0 else { return 0 }
            return min(1, max(0, Double(bytesRead) / Double(totalBytes)))
        }

        var isDeterminate: Bool { !isSealing && totalBytes > 0 }

        var detail: String {
            if isSealing { return "Encrypting…" }
            if totalBytes > 0 {
                return "\(ByteSize.string(bytesRead)) of \(ByteSize.string(totalBytes))"
            }
            return "Preparing…"
        }
    }

    /// What to tell the user afterwards. Deliberately not a transient toast in the sheet:
    /// "already stored" is information, and information that flashes for two seconds is
    /// information nobody has.
    struct Summary: Equatable {
        var added: Int
        var duplicates: Int
        var lastFilename: String
        var lastByteSize: Int64
        var lastVariantID: String

        var title: String {
            if added == 1 { return duplicates == 1 ? "Already in Things" : "Attached" }
            return "\(added) files attached"
        }

        var message: String {
            if added == 1 {
                if duplicates == 1 {
                    return "\(lastFilename) is already stored in Things. It was linked to this Thing rather than stored a second time."
                }
                return "\(lastFilename) · \(ByteSize.string(lastByteSize))"
            }
            if duplicates > 0 {
                return "\(duplicates) of them were already stored in Things and were linked rather than stored again."
            }
            return "Everything you picked was added."
        }

        var mentionsDuplicate: Bool { duplicates > 0 }
    }

    private(set) var progress: Progress?
    private(set) var summary: Summary?
    var failure: String?

    var isWorking: Bool { progress != nil }

    func clearSummary() { summary = nil }

    // MARK: Files

    func attach(fileAt url: URL, to thingID: String, label: String?, model: AppModel) async {
        guard let library = model.library, let registry = model.registry else { return }

        let filename = url.lastPathComponent
        let type = UTType(filenameExtension: url.pathExtension)
        let variantID = AttachmentVariants.variantID(for: type, registry: registry)
        let mimeType = type?.preferredMIMEType
        let fieldLabel = Self.resolve(label: label, fallback: filename)

        summary = nil
        failure = nil
        progress = Progress(filename: filename, totalBytes: 0, bytesRead: 0, isSealing: false)

        let box = AttachmentProgressBox()
        let work = Task.detached(priority: .userInitiated) { () async throws -> AttachmentOutcome in
            // A document picked in Files is outside the app's container until the sandbox
            // is opened for it, and closing it again is not optional.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            box.setTotalBytes(AttachmentWorker.byteCount(of: url))
            let data = try AttachmentWorker.read(url, into: box)
            box.beginSealing()
            return try AttachmentWorker.store(data: data,
                                              filename: filename,
                                              mimeType: mimeType,
                                              variantID: variantID,
                                              label: fieldLabel,
                                              thingID: thingID,
                                              library: library)
        }

        await follow(work, box: box)
    }

    // MARK: Photos and videos

    func attach(photos items: [PhotosPickerItem], to thingID: String, label: String?, model: AppModel) async {
        guard let library = model.library, let registry = model.registry else { return }
        guard !items.isEmpty else { return }

        summary = nil
        failure = nil

        var added = 0
        var duplicates = 0
        var lastFilename = ""
        var lastByteSize: Int64 = 0
        var lastVariantID = ""

        for (index, item) in items.enumerated() {
            let type = item.supportedContentTypes.first
            let variantID = AttachmentVariants.variantID(for: type, registry: registry)
            let base = AttachmentVariants.displayName(for: type)
            let fileExtension = type?.preferredFilenameExtension ?? "dat"
            let filename = items.count > 1
                ? "\(base) \(index + 1).\(fileExtension)"
                : "\(base).\(fileExtension)"
            let fieldLabel = Self.resolve(label: items.count > 1 ? nil : label, fallback: filename)
            let mimeType = type?.preferredMIMEType

            // The Photos picker hands over bytes out of process and reports no byte count
            // on the way, so this phase is indeterminate. It does not block the main actor:
            // the await suspends, it does not spin.
            progress = Progress(filename: filename, totalBytes: 0, bytesRead: 0, isSealing: false)

            let data: Data
            do {
                guard let loaded = try await item.loadTransferable(type: Data.self) else {
                    progress = nil
                    failure = "Things could not read \(filename) from Photos."
                    break
                }
                data = loaded
            } catch {
                progress = nil
                failure = "Things could not read \(filename) from Photos. \(error.localizedDescription)"
                break
            }

            let box = AttachmentProgressBox()
            box.setTotalBytes(Int64(data.count))
            box.setBytesRead(Int64(data.count))
            box.beginSealing()
            progress = Progress(filename: filename,
                                totalBytes: Int64(data.count),
                                bytesRead: Int64(data.count),
                                isSealing: true)

            let work = Task.detached(priority: .userInitiated) { () async throws -> AttachmentOutcome in
                try AttachmentWorker.store(data: data,
                                           filename: filename,
                                           mimeType: mimeType,
                                           variantID: variantID,
                                           label: fieldLabel,
                                           thingID: thingID,
                                           library: library)
            }

            guard let outcome = await settle(work, box: box) else { break }
            added += 1
            if outcome.wasDuplicate { duplicates += 1 }
            lastFilename = outcome.filename
            lastByteSize = outcome.byteSize
            lastVariantID = outcome.variantID
        }

        progress = nil
        if added > 0 {
            summary = Summary(added: added,
                              duplicates: duplicates,
                              lastFilename: lastFilename,
                              lastByteSize: lastByteSize,
                              lastVariantID: lastVariantID)
        }
    }

    // MARK: - Driving one task

    private func follow(_ work: Task<AttachmentOutcome, Error>,
                        box: AttachmentProgressBox) async {
        guard let outcome = await settle(work, box: box) else { return }
        summary = Summary(added: 1,
                          duplicates: outcome.wasDuplicate ? 1 : 0,
                          lastFilename: outcome.filename,
                          lastByteSize: outcome.byteSize,
                          lastVariantID: outcome.variantID)
    }

    /// Samples the shared counter while the work runs, then reports the outcome. Returns
    /// `nil` when the import failed, having already published the message.
    private func settle(_ work: Task<AttachmentOutcome, Error>,
                        box: AttachmentProgressBox) async -> AttachmentOutcome? {
        let sampler = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                if Task.isCancelled { break }
                guard self.progress != nil else { break }
                self.progress?.totalBytes = box.totalBytes
                self.progress?.bytesRead = box.bytesRead
                self.progress?.isSealing = box.isSealing
            }
        }

        do {
            let outcome = try await work.value
            sampler.cancel()
            progress = nil
            return outcome
        } catch {
            sampler.cancel()
            progress = nil
            failure = Self.message(for: error)
            return nil
        }
    }

    // MARK: - Helpers

    private static func resolve(label: String?, fallback: String) -> String {
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? fallback : trimmed
    }

    /// Errors say what happened and what to do.
    private static func message(for error: Error) -> String {
        if let thingsError = error as? ThingsError {
            return "\(thingsError.description) Nothing was added."
        }
        if error is CancellationError {
            return "That import was cancelled. Nothing was added."
        }
        return "That file could not be added. \(error.localizedDescription)"
    }
}
