import SwiftUI
import UIKit
import ThingsCore

/// A row in a list of Things.
///
/// **Not glass.** List rows are content, and content is never glass — that rule is the
/// single most important one in the design system, and the reliable tell of a third-party
/// app trying too hard is glass cards on a glass background inside a glass sheet.
struct ThingRowView: View {

    let thing: Thing
    var subtitle: String?
    var registry: FieldKindRegistry?
    var nowMilliseconds: Int64 = 0

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            ThingIconView(icon: thing.icon, title: thing.title, registry: registry)

            VStack(alignment: .leading, spacing: 1) {
                Text(thing.title)
                    .font(.body)
                    .lineLimit(2)
                    .truncationMode(.tail)

                Text(subtitle ?? RelativeTime.string(fromISO8601: thing.updatedAt,
                                                     nowMilliseconds: nowMilliseconds))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: Theme.Spacing.tight)

            if thing.isLocked {
                Image(systemName: "lock.fill")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Locked")
            }
            if thing.isPinned {
                Image(systemName: "pin.fill")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Pinned")
            }
        }
        .padding(.vertical, Theme.Spacing.hairline)
        .contentShape(Rectangle())
    }
}

/// The card used in Home's Pinned shelf.
struct ThingCardView: View {

    let thing: Thing
    var registry: FieldKindRegistry?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            ThingIconView(icon: thing.icon,
                          title: thing.title,
                          size: Theme.Size.largeIcon,
                          registry: registry)
            Spacer(minLength: 0)
            Text(thing.title)
                .font(.subheadline.weight(.medium))
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.Spacing.medium)
        .frame(width: Theme.Size.pinnedCard, alignment: .leading)
        .frame(minHeight: Theme.Size.pinnedCard, alignment: .topLeading)
        // Opaque, not glass: a card is content.
        .background(Color(uiColor: .secondarySystemBackground), in: ThingsShape.rounded(Theme.Radius.card))
        .contentShape(ThingsShape.rounded(Theme.Radius.card))
    }
}
