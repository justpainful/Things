import Foundation
import GRDB

// Every row type in `spec/schema.sql`, as a **struct**.
//
// Two rules held throughout this file:
//   1. No `Record` subclasses. They are reference types with mutable state, which Swift 6
//      strict concurrency will not let us hand between actors.
//   2. No `Codable`. `FetchableRecord.init(row:)` and `encode(to:)` are hand written so
//      the hot read path does not go through a reflection-driven decoder, and so column
//      names live in exactly one place instead of being inferred from key-decoding
//      strategies.
//
// `init(row:)` is intentionally NON-throwing: a non-throwing implementation satisfies
// both the GRDB 6 (`init(row:)`) and GRDB 7 (`init(row:) throws`) protocol requirements,
// so this file compiles against either.
//
// Timestamps are `String` (ISO-8601 UTC, milliseconds) rather than `Date`. The schema
// stores TEXT, the TypeScript core round-trips TEXT, and a `Date` round trip through
// SQLite is one of the classic places two implementations quietly disagree.

// MARK: - Device

public struct Device: Identifiable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "device"

    public var id: String
    public var name: String
    public var platform: String          // 'ios' | 'windows'
    public var publicKey: Data?
    public var pairedAt: String?
    public var lastSeenAt: String?
    public var isSelf: Bool

    public init(id: String, name: String, platform: String, publicKey: Data? = nil,
                pairedAt: String? = nil, lastSeenAt: String? = nil, isSelf: Bool = false) {
        self.id = id
        self.name = name
        self.platform = platform
        self.publicKey = publicKey
        self.pairedAt = pairedAt
        self.lastSeenAt = lastSeenAt
        self.isSelf = isSelf
    }

    public init(row: Row) {
        id = row["id"]
        name = row["name"]
        platform = row["platform"]
        publicKey = row["public_key"]
        pairedAt = row["paired_at"]
        lastSeenAt = row["last_seen_at"]
        isSelf = row["is_self"]
    }

    public func encode(to container: inout PersistenceContainer) {
        container["id"] = id
        container["name"] = name
        container["platform"] = platform
        container["public_key"] = publicKey
        container["paired_at"] = pairedAt
        container["last_seen_at"] = lastSeenAt
        container["is_self"] = isSelf
    }
}

// MARK: - Thing

public struct Thing: Identifiable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "thing"

    public var id: String
    public var title: String
    public var iconJSON: String?
    public var coverObject: String?
    public var isPinned: Bool
    public var isLocked: Bool
    public var isArchived: Bool
    public var isTemplate: Bool
    public var createdAt: String
    public var updatedAt: String
    public var viewedAt: String?
    public var deletedAt: String?
    public var versionVector: String

    public init(id: String,
                title: String,
                iconJSON: String? = nil,
                coverObject: String? = nil,
                isPinned: Bool = false,
                isLocked: Bool = false,
                isArchived: Bool = false,
                isTemplate: Bool = false,
                createdAt: String,
                updatedAt: String,
                viewedAt: String? = nil,
                deletedAt: String? = nil,
                versionVector: String = "{}") {
        self.id = id
        self.title = title
        self.iconJSON = iconJSON
        self.coverObject = coverObject
        self.isPinned = isPinned
        self.isLocked = isLocked
        self.isArchived = isArchived
        self.isTemplate = isTemplate
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.viewedAt = viewedAt
        self.deletedAt = deletedAt
        self.versionVector = versionVector
    }

    public init(row: Row) {
        id = row["id"]
        title = row["title"]
        iconJSON = row["icon_json"]
        coverObject = row["cover_object"]
        isPinned = row["is_pinned"]
        isLocked = row["is_locked"]
        isArchived = row["is_archived"]
        isTemplate = row["is_template"]
        createdAt = row["created_at"]
        updatedAt = row["updated_at"]
        viewedAt = row["viewed_at"]
        deletedAt = row["deleted_at"]
        versionVector = row["version_vector"]
    }

    public func encode(to container: inout PersistenceContainer) {
        container["id"] = id
        container["title"] = title
        container["icon_json"] = iconJSON
        container["cover_object"] = coverObject
        container["is_pinned"] = isPinned
        container["is_locked"] = isLocked
        container["is_archived"] = isArchived
        container["is_template"] = isTemplate
        container["created_at"] = createdAt
        container["updated_at"] = updatedAt
        container["viewed_at"] = viewedAt
        container["deleted_at"] = deletedAt
        container["version_vector"] = versionVector
    }

    public var isDeleted: Bool { deletedAt != nil }
    public var icon: ThingIcon { ThingIcon.parse(iconJSON) }
    public var vector: VersionVector { VersionVector.parse(versionVector) }
    public var createdDate: Date? { Timestamp.date(fromISO8601: createdAt) }
    public var updatedDate: Date? { Timestamp.date(fromISO8601: updatedAt) }
}

// MARK: - Section

public struct ThingSection: Identifiable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "section"

    public var id: String
    public var thingID: String
    public var title: String?
    public var sortOrder: Double
    public var createdAt: String
    public var updatedAt: String
    public var versionVector: String

    public init(id: String, thingID: String, title: String?, sortOrder: Double,
                createdAt: String, updatedAt: String, versionVector: String = "{}") {
        self.id = id
        self.thingID = thingID
        self.title = title
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.versionVector = versionVector
    }

    public init(row: Row) {
        id = row["id"]
        thingID = row["thing_id"]
        title = row["title"]
        sortOrder = row["sort_order"]
        createdAt = row["created_at"]
        updatedAt = row["updated_at"]
        versionVector = row["version_vector"]
    }

    public func encode(to container: inout PersistenceContainer) {
        container["id"] = id
        container["thing_id"] = thingID
        container["title"] = title
        container["sort_order"] = sortOrder
        container["created_at"] = createdAt
        container["updated_at"] = updatedAt
        container["version_vector"] = versionVector
    }

    /// A section with no title is the unnamed default section, not "Untitled".
    public var isDefaultSection: Bool { title == nil || title?.isEmpty == true }
}

// MARK: - Field

public struct Field: Identifiable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "field"

    public var id: String
    public var thingID: String
    public var sectionID: String?
    public var sortOrder: Double
    public var kind: FieldKind
    public var variant: String?
    public var label: String
    public var valueText: String?
    public var valueJSON: String?
    public var valueCipher: Data?
    public var objectHash: String?
    public var fileRefID: String?
    public var isSecret: Bool
    public var createdAt: String
    public var updatedAt: String
    public var versionVector: String

    public init(id: String,
                thingID: String,
                sectionID: String? = nil,
                sortOrder: Double,
                kind: FieldKind,
                variant: String? = nil,
                label: String,
                valueText: String? = nil,
                valueJSON: String? = nil,
                valueCipher: Data? = nil,
                objectHash: String? = nil,
                fileRefID: String? = nil,
                isSecret: Bool = false,
                createdAt: String,
                updatedAt: String,
                versionVector: String = "{}") {
        self.id = id
        self.thingID = thingID
        self.sectionID = sectionID
        self.sortOrder = sortOrder
        self.kind = kind
        self.variant = variant
        self.label = label
        self.valueText = valueText
        self.valueJSON = valueJSON
        self.valueCipher = valueCipher
        self.objectHash = objectHash
        self.fileRefID = fileRefID
        self.isSecret = isSecret
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.versionVector = versionVector
    }

    public init(row: Row) {
        id = row["id"]
        thingID = row["thing_id"]
        sectionID = row["section_id"]
        sortOrder = row["sort_order"]
        let kindText: String = row["kind"]
        kind = FieldKind(kindText)
        variant = row["variant"]
        label = row["label"]
        valueText = row["value_text"]
        valueJSON = row["value_json"]
        valueCipher = row["value_cipher"]
        objectHash = row["object_hash"]
        fileRefID = row["file_ref_id"]
        isSecret = row["is_secret"]
        createdAt = row["created_at"]
        updatedAt = row["updated_at"]
        versionVector = row["version_vector"]
    }

    public func encode(to container: inout PersistenceContainer) {
        container["id"] = id
        container["thing_id"] = thingID
        container["section_id"] = sectionID
        container["sort_order"] = sortOrder
        container["kind"] = kind.rawValue
        container["variant"] = variant
        container["label"] = label
        container["value_text"] = valueText
        container["value_json"] = valueJSON
        container["value_cipher"] = valueCipher
        container["object_hash"] = objectHash
        container["file_ref_id"] = fileRefID
        container["is_secret"] = isSecret
        container["created_at"] = createdAt
        container["updated_at"] = updatedAt
        container["version_vector"] = versionVector
    }

    /// Mirrors the schema's CHECK constraint so the app can fail early with a message a
    /// human can act on, rather than an SQLITE_CONSTRAINT code.
    public func validateValueCarrier() throws {
        var carriers = 0
        if valueText != nil { carriers += 1 }
        if valueJSON != nil { carriers += 1 }
        if valueCipher != nil { carriers += 1 }
        if objectHash != nil { carriers += 1 }
        if fileRefID != nil { carriers += 1 }
        if carriers > 1 { throw ThingsError.invalidValueCarrier(fieldID: id) }
        if isSecret && (valueText != nil || valueJSON != nil) {
            throw ThingsError.secretStoredInClear(fieldID: id)
        }
    }

    public var hasValue: Bool {
        valueText != nil || valueJSON != nil || valueCipher != nil || objectHash != nil || fileRefID != nil
    }

    public var vector: VersionVector { VersionVector.parse(versionVector) }

    /// The original filename lives on the field, not the object — the same PNG is
    /// `logo.png` in one Thing and `avatar.png` in another.
    public var filename: String? {
        guard let valueJSON, let parsed = try? JSONValue.parse(valueJSON) else { return nil }
        return parsed["filename"]?.stringValue
    }
}

// MARK: - Object store

public struct StoredObject: Identifiable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "object"

    /// Named `objectHash` rather than `hash` so it cannot shadow `Hashable.hash(into:)`.
    /// The column is still `hash`.
    public var objectHash: String
    public var byteSize: Int64
    public var mimeType: String?
    public var width: Int?
    public var height: Int?
    public var durationMs: Int?
    public var encKeyWrap: Data
    public var encNonce: Data
    public var refCount: Int
    public var createdAt: String

    public var id: String { objectHash }

    public init(objectHash: String, byteSize: Int64, mimeType: String? = nil,
                width: Int? = nil, height: Int? = nil, durationMs: Int? = nil,
                encKeyWrap: Data, encNonce: Data, refCount: Int = 0, createdAt: String) {
        self.objectHash = objectHash
        self.byteSize = byteSize
        self.mimeType = mimeType
        self.width = width
        self.height = height
        self.durationMs = durationMs
        self.encKeyWrap = encKeyWrap
        self.encNonce = encNonce
        self.refCount = refCount
        self.createdAt = createdAt
    }

    public init(row: Row) {
        objectHash = row["hash"]
        byteSize = row["byte_size"]
        mimeType = row["mime_type"]
        width = row["width"]
        height = row["height"]
        durationMs = row["duration_ms"]
        encKeyWrap = row["enc_key_wrap"]
        encNonce = row["enc_nonce"]
        refCount = row["ref_count"]
        createdAt = row["created_at"]
    }

    public func encode(to container: inout PersistenceContainer) {
        container["hash"] = objectHash
        container["byte_size"] = byteSize
        container["mime_type"] = mimeType
        container["width"] = width
        container["height"] = height
        container["duration_ms"] = durationMs
        container["enc_key_wrap"] = encKeyWrap
        container["enc_nonce"] = encNonce
        container["ref_count"] = refCount
        container["created_at"] = createdAt
    }
}

// MARK: - File references

public struct FileRef: Identifiable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "file_ref"

    public enum Status: String, Sendable {
        case present, missing, unknown
    }

    public var id: String
    public var deviceID: String
    public var path: String
    public var isDirectory: Bool
    public var sizeAtLink: Int64?
    public var mtimeAtLink: String?
    public var contentHash: String?
    public var lastSeenAt: String?
    public var status: String
    public var createdAt: String

    public init(id: String, deviceID: String, path: String, isDirectory: Bool = false,
                sizeAtLink: Int64? = nil, mtimeAtLink: String? = nil, contentHash: String? = nil,
                lastSeenAt: String? = nil, status: Status = .unknown, createdAt: String) {
        self.id = id
        self.deviceID = deviceID
        self.path = path
        self.isDirectory = isDirectory
        self.sizeAtLink = sizeAtLink
        self.mtimeAtLink = mtimeAtLink
        self.contentHash = contentHash
        self.lastSeenAt = lastSeenAt
        self.status = status.rawValue
        self.createdAt = createdAt
    }

    public init(row: Row) {
        id = row["id"]
        deviceID = row["device_id"]
        path = row["path"]
        isDirectory = row["is_directory"]
        sizeAtLink = row["size_at_link"]
        mtimeAtLink = row["mtime_at_link"]
        contentHash = row["content_hash"]
        lastSeenAt = row["last_seen_at"]
        status = row["status"]
        createdAt = row["created_at"]
    }

    public func encode(to container: inout PersistenceContainer) {
        container["id"] = id
        container["device_id"] = deviceID
        container["path"] = path
        container["is_directory"] = isDirectory
        container["size_at_link"] = sizeAtLink
        container["mtime_at_link"] = mtimeAtLink
        container["content_hash"] = contentHash
        container["last_seen_at"] = lastSeenAt
        container["status"] = status
        container["created_at"] = createdAt
    }

    public var statusValue: Status { Status(rawValue: status) ?? .unknown }

    /// The last path component, for display. Works for Windows paths too, which is the
    /// whole reason this is hand rolled instead of `URL(fileURLWithPath:).lastPathComponent`.
    public var displayName: String {
        let separators = CharacterSet(charactersIn: "/\\")
        let components = path.components(separatedBy: separators).filter { !$0.isEmpty }
        return components.last ?? path
    }
}

// MARK: - Collections and tags

public struct ThingCollection: Identifiable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "collection"

    public var id: String
    public var name: String
    public var iconJSON: String?
    public var sortOrder: Double
    public var parentID: String?
    public var isSmart: Bool
    public var isSystem: Bool
    public var smartQuery: String?
    public var createdAt: String
    public var updatedAt: String
    public var versionVector: String

    public init(id: String, name: String, iconJSON: String? = nil, sortOrder: Double,
                parentID: String? = nil, isSmart: Bool = false, isSystem: Bool = false,
                smartQuery: String? = nil, createdAt: String, updatedAt: String,
                versionVector: String = "{}") {
        self.id = id
        self.name = name
        self.iconJSON = iconJSON
        self.sortOrder = sortOrder
        self.parentID = parentID
        self.isSmart = isSmart
        self.isSystem = isSystem
        self.smartQuery = smartQuery
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.versionVector = versionVector
    }

    public init(row: Row) {
        id = row["id"]
        name = row["name"]
        iconJSON = row["icon_json"]
        sortOrder = row["sort_order"]
        parentID = row["parent_id"]
        isSmart = row["is_smart"]
        isSystem = row["is_system"]
        smartQuery = row["smart_query"]
        createdAt = row["created_at"]
        updatedAt = row["updated_at"]
        versionVector = row["version_vector"]
    }

    public func encode(to container: inout PersistenceContainer) {
        container["id"] = id
        container["name"] = name
        container["icon_json"] = iconJSON
        container["sort_order"] = sortOrder
        container["parent_id"] = parentID
        container["is_smart"] = isSmart
        container["is_system"] = isSystem
        container["smart_query"] = smartQuery
        container["created_at"] = createdAt
        container["updated_at"] = updatedAt
        container["version_vector"] = versionVector
    }

    public var icon: ThingIcon { ThingIcon.parse(iconJSON) }
}

public struct CollectionMember: Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "collection_member"

    public var collectionID: String
    public var thingID: String
    public var sortOrder: Double
    public var addedAt: String

    public init(collectionID: String, thingID: String, sortOrder: Double, addedAt: String) {
        self.collectionID = collectionID
        self.thingID = thingID
        self.sortOrder = sortOrder
        self.addedAt = addedAt
    }

    public init(row: Row) {
        collectionID = row["collection_id"]
        thingID = row["thing_id"]
        sortOrder = row["sort_order"]
        addedAt = row["added_at"]
    }

    public func encode(to container: inout PersistenceContainer) {
        container["collection_id"] = collectionID
        container["thing_id"] = thingID
        container["sort_order"] = sortOrder
        container["added_at"] = addedAt
    }
}

public struct Tag: Identifiable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "tag"

    public var id: String
    public var name: String
    public var color: String?
    public var createdAt: String

    public init(id: String, name: String, color: String? = nil, createdAt: String) {
        self.id = id
        self.name = name
        self.color = color
        self.createdAt = createdAt
    }

    public init(row: Row) {
        id = row["id"]
        name = row["name"]
        color = row["color"]
        createdAt = row["created_at"]
    }

    public func encode(to container: inout PersistenceContainer) {
        container["id"] = id
        container["name"] = name
        container["color"] = color
        container["created_at"] = createdAt
    }
}

public struct ThingTag: Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "thing_tag"

    public var thingID: String
    public var tagID: String

    public init(thingID: String, tagID: String) {
        self.thingID = thingID
        self.tagID = tagID
    }

    public init(row: Row) {
        thingID = row["thing_id"]
        tagID = row["tag_id"]
    }

    public func encode(to container: inout PersistenceContainer) {
        container["thing_id"] = thingID
        container["tag_id"] = tagID
    }
}

// MARK: - Oplog

public enum ChangeOperation: String, Sendable, Hashable {
    case create, update, delete
}

public enum EntityType: String, Sendable, Hashable, CaseIterable {
    case thing, section, field, collection, member, tag
    case thingTag = "thing_tag"
    case fileRef = "file_ref"

    /// The table this entity type writes to. `member` and `thing_tag` are join rows with
    /// composite keys and are handled separately by the oplog applier.
    public var tableName: String {
        switch self {
        case .thing: return "thing"
        case .section: return "section"
        case .field: return "field"
        case .collection: return "collection"
        case .member: return "collection_member"
        case .tag: return "tag"
        case .thingTag: return "thing_tag"
        case .fileRef: return "file_ref"
        }
    }
}

public struct Change: Identifiable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "change"

    public var id: String
    public var deviceID: String
    public var hlc: String
    public var entityType: String
    public var entityID: String
    public var op: String
    public var attrsJSON: String
    public var prevJSON: String?
    public var appliedAt: String

    public init(id: String, deviceID: String, hlc: String, entityType: EntityType,
                entityID: String, op: ChangeOperation, attrsJSON: String,
                prevJSON: String? = nil, appliedAt: String) {
        self.id = id
        self.deviceID = deviceID
        self.hlc = hlc
        self.entityType = entityType.rawValue
        self.entityID = entityID
        self.op = op.rawValue
        self.attrsJSON = attrsJSON
        self.prevJSON = prevJSON
        self.appliedAt = appliedAt
    }

    public init(row: Row) {
        id = row["id"]
        deviceID = row["device_id"]
        hlc = row["hlc"]
        entityType = row["entity_type"]
        entityID = row["entity_id"]
        op = row["op"]
        attrsJSON = row["attrs_json"]
        prevJSON = row["prev_json"]
        appliedAt = row["applied_at"]
    }

    public func encode(to container: inout PersistenceContainer) {
        container["id"] = id
        container["device_id"] = deviceID
        container["hlc"] = hlc
        container["entity_type"] = entityType
        container["entity_id"] = entityID
        container["op"] = op
        container["attrs_json"] = attrsJSON
        container["prev_json"] = prevJSON
        container["applied_at"] = appliedAt
    }

    public var operation: ChangeOperation? { ChangeOperation(rawValue: op) }
    public var entity: EntityType? { EntityType(rawValue: entityType) }
    public var stamp: HLC? { HLC.parse(hlc) }
    public var attributes: JSONValue { (try? JSONValue.parse(attrsJSON)) ?? .object([:]) }
    public var previous: JSONValue? {
        guard let prevJSON else { return nil }
        return try? JSONValue.parse(prevJSON)
    }
}

public struct Conflict: Identifiable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "conflict"

    public var id: String
    public var entityType: String
    public var entityID: String
    public var versionAJSON: String
    public var versionBJSON: String
    public var detectedAt: String
    public var resolvedAt: String?
    public var resolution: String?

    public init(id: String, entityType: String, entityID: String,
                versionAJSON: String, versionBJSON: String, detectedAt: String,
                resolvedAt: String? = nil, resolution: String? = nil) {
        self.id = id
        self.entityType = entityType
        self.entityID = entityID
        self.versionAJSON = versionAJSON
        self.versionBJSON = versionBJSON
        self.detectedAt = detectedAt
        self.resolvedAt = resolvedAt
        self.resolution = resolution
    }

    public init(row: Row) {
        id = row["id"]
        entityType = row["entity_type"]
        entityID = row["entity_id"]
        versionAJSON = row["version_a_json"]
        versionBJSON = row["version_b_json"]
        detectedAt = row["detected_at"]
        resolvedAt = row["resolved_at"]
        resolution = row["resolution"]
    }

    public func encode(to container: inout PersistenceContainer) {
        container["id"] = id
        container["entity_type"] = entityType
        container["entity_id"] = entityID
        container["version_a_json"] = versionAJSON
        container["version_b_json"] = versionBJSON
        container["detected_at"] = detectedAt
        container["resolved_at"] = resolvedAt
        container["resolution"] = resolution
    }

    public var isOpen: Bool { resolvedAt == nil }
}

// MARK: - Local state

public struct MetaEntry: Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "meta"

    public var key: String
    public var value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }

    public init(row: Row) {
        key = row["key"]
        value = row["value"]
    }

    public func encode(to container: inout PersistenceContainer) {
        container["key"] = key
        container["value"] = value
    }
}

public struct SyncState: Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "sync_state"

    public var peerDeviceID: String
    public var lastHLCSent: String?
    public var lastHLCReceived: String?
    public var lastSyncAt: String?

    public init(peerDeviceID: String, lastHLCSent: String? = nil,
                lastHLCReceived: String? = nil, lastSyncAt: String? = nil) {
        self.peerDeviceID = peerDeviceID
        self.lastHLCSent = lastHLCSent
        self.lastHLCReceived = lastHLCReceived
        self.lastSyncAt = lastSyncAt
    }

    public init(row: Row) {
        peerDeviceID = row["peer_device_id"]
        lastHLCSent = row["last_hlc_sent"]
        lastHLCReceived = row["last_hlc_recv"]
        lastSyncAt = row["last_sync_at"]
    }

    public func encode(to container: inout PersistenceContainer) {
        container["peer_device_id"] = peerDeviceID
        container["last_hlc_sent"] = lastHLCSent
        container["last_hlc_recv"] = lastHLCReceived
        container["last_sync_at"] = lastSyncAt
    }
}

public struct Thumbnail: Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "thumbnail"

    public var objectHash: String
    public var size: Int
    public var byteSize: Int64
    public var encNonce: Data
    public var createdAt: String

    public init(objectHash: String, size: Int, byteSize: Int64, encNonce: Data, createdAt: String) {
        self.objectHash = objectHash
        self.size = size
        self.byteSize = byteSize
        self.encNonce = encNonce
        self.createdAt = createdAt
    }

    public init(row: Row) {
        objectHash = row["object_hash"]
        size = row["size"]
        byteSize = row["byte_size"]
        encNonce = row["enc_nonce"]
        createdAt = row["created_at"]
    }

    public func encode(to container: inout PersistenceContainer) {
        container["object_hash"] = objectHash
        container["size"] = size
        container["byte_size"] = byteSize
        container["enc_nonce"] = encNonce
        container["created_at"] = createdAt
    }
}
