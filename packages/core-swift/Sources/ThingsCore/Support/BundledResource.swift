import Foundation

/// Locates the two normative spec files bundled with this package.
///
/// `Package.swift` copies the whole `Resources` directory, so the files live at
/// `<bundle>/Resources/…`. It tries the `subdirectory:` form first and then the bundle
/// root, because whether SwiftPM flattens a copied resource depends on whether the rule
/// named a file or a directory — and getting that wrong shows up as a missing resource on
/// a CI runner rather than on anyone's desk.
public enum BundledResource {

    public static func url(named name: String, extension fileExtension: String) -> URL? {
        if let found = Bundle.module.url(forResource: name,
                                         withExtension: fileExtension,
                                         subdirectory: "Resources") {
            return found
        }
        return Bundle.module.url(forResource: name, withExtension: fileExtension)
    }

    public static func data(named name: String, extension fileExtension: String) throws -> Data {
        guard let url = url(named: name, extension: fileExtension) else {
            throw ThingsError.resourceMissing("\(name).\(fileExtension)")
        }
        return try Data(contentsOf: url)
    }
}
