import Foundation

/// Every error this package throws. Deliberately one flat type: the app has to render
/// these, and a forest of nested error enums makes that miserable.
public enum ThingsError: Error, CustomStringConvertible, Sendable {

    // Resources / registry
    case resourceMissing(String)
    case registryInvalid(String)

    // Database
    case databaseNotOpen
    case schemaLoadFailed(String)
    case entityNotFound(entity: String, id: String)
    case unsupportedEntityType(String)
    case invalidColumn(entity: String, column: String)

    // Crypto
    case cryptoFailure(String)
    case envelopeMalformed(String)
    case keyDerivationFailed(String)
    case keychainFailure(status: Int32, operation: String)
    case secureEnclaveUnavailable

    // Object store
    case objectNotFound(String)
    case objectCorrupt(hash: String, reason: String)

    // Model
    case invalidValueCarrier(fieldID: String)
    case secretStoredInClear(fieldID: String)
    case malformedIdentifier(String)
    case malformedHLC(String)

    // Search
    case searchUnavailable(String)

    public var description: String {
        switch self {
        case .resourceMissing(let name):
            return "Bundled resource missing: \(name)"
        case .registryInvalid(let reason):
            return "field-kinds.json is not valid: \(reason)"
        case .databaseNotOpen:
            return "The library is not open."
        case .schemaLoadFailed(let reason):
            return "Could not create the schema: \(reason)"
        case .entityNotFound(let entity, let id):
            return "No \(entity) with id \(id)."
        case .unsupportedEntityType(let type):
            return "Unknown entity type '\(type)'."
        case .invalidColumn(let entity, let column):
            return "'\(column)' is not a column of \(entity)."
        case .cryptoFailure(let reason):
            return "Encryption failed: \(reason)"
        case .envelopeMalformed(let reason):
            return "Malformed encrypted value: \(reason)"
        case .keyDerivationFailed(let reason):
            return "Could not derive the key: \(reason)"
        case .keychainFailure(let status, let operation):
            return "Keychain \(operation) failed (OSStatus \(status))."
        case .secureEnclaveUnavailable:
            return "This device has no Secure Enclave."
        case .objectNotFound(let hash):
            return "No stored file with hash \(hash)."
        case .objectCorrupt(let hash, let reason):
            return "Stored file \(hash) is unreadable: \(reason)"
        case .invalidValueCarrier(let fieldID):
            return "Field \(fieldID) has more than one value."
        case .secretStoredInClear(let fieldID):
            return "Field \(fieldID) is a secret but carries a plaintext value."
        case .malformedIdentifier(let value):
            return "'\(value)' is not a valid id."
        case .malformedHLC(let value):
            return "'\(value)' is not a valid clock stamp."
        case .searchUnavailable(let reason):
            return "Search is unavailable: \(reason)"
        }
    }

    public var localizedDescription: String { description }
}
