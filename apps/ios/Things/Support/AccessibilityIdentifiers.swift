import Foundation

/// Stable identifiers for the Screenshot Tour.
///
/// The tour is the only consumer. Querying by visible label would make every copy change a
/// broken UI test, and a tour that breaks on copy edits stops being run.
enum A11y {

    enum Tab {
        static let things = "tab.things"
        static let collections = "tab.collections"
        static let search = "tab.search"
    }

    enum Home {
        static let root = "home.root"
        static let pinnedSection = "home.pinned"
        static let recentSection = "home.recent"
        static let collectionsSection = "home.collections"
        static let suggestionsSection = "home.suggestions"
        static let allThingsLink = "home.allThings"
        static let addButton = "home.add"
        static let settingsButton = "home.settings"
    }

    enum AllThings {
        static let root = "allThings.root"
    }

    enum Detail {
        static let root = "detail.root"
        static let title = "detail.title"
        static let addFieldButton = "detail.addField"
        static let historyButton = "detail.history"
        static let galleryButton = "detail.gallery"
        static let moreButton = "detail.more"
        static func field(_ id: String) -> String { "detail.field.\(id)" }
    }

    enum Sheets {
        static let addField = "sheet.addField"
        static let newThing = "sheet.newThing"
        static let fieldActions = "sheet.fieldActions"
    }

    enum Search {
        static let root = "search.root"
        static let field = "search.field"
        static let chips = "search.chips"
        static func chip(_ id: String) -> String { "search.chip.\(id)" }
    }

    enum Collections {
        static let root = "collections.root"
        static func row(_ id: String) -> String { "collections.row.\(id)" }
        static let detailRoot = "collections.detail"
    }

    enum Lock {
        static let root = "lock.root"
        static let keypad = "lock.keypad"
        static func digit(_ value: Int) -> String { "lock.digit.\(value)" }
        static let faceID = "lock.faceID"
    }

    enum Settings {
        static let root = "settings.root"
        static let privacyToggle = "settings.privacyMode"
        static let lockNow = "settings.lockNow"
        static let trash = "settings.trash"
        static let history = "settings.history"
        static let sync = "settings.sync"
        static let conflicts = "settings.conflicts"
        static let diagnostics = "settings.diagnostics"
    }

    enum Trash {
        static let root = "trash.root"
    }

    enum History {
        static let root = "history.root"
    }

    enum Conflict {
        static let root = "conflict.root"
    }

    enum Sync {
        static let root = "sync.root"
    }

    enum Gallery {
        static let root = "gallery.root"
        static let viewer = "gallery.viewer"
    }
}
