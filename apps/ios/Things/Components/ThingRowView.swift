import SwiftUI
import UIKit
import ThingsCore

/// A row in a list of Things.
///
/// **Not glass.** List rows are content, and content is never glass — that rule is the
/// single most important one in the design system, and the reliable tell of a third-party
/// app trying too hard is glass cards on a glass background inside a glass sheet.
///
/// The row **reflows** at accessibility sizes rather than clipping. At AccessibilityXXL a
/// 34pt icon plus two trailing badges leaves so little width for the title that SwiftUI
/// starts hyphenating single words mid-word — "Cloud-flare" — and the timestamp truncates to
/// "2 hours a…". Shrinking the type would defeat the setting, so the icon and badges move to
/// their own line and the text gets the full width.
struct ThingRowView: View {

    let thing: Thing
    var subtitle: String?
    var registry: FieldKindRegistry?
    var nowMilliseconds: Int64 = 0

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var isAccessibilitySize: Bool { dynamicTypeSize.isAccessibilitySize }

    // Spelled as explicit `Int?` values rather than inline ternaries: `lineLimit` has
    // several overloads (Int, Int?, and three range forms), and `cond ? nil : 2` is exactly
    // the shape that makes overload resolution ambiguous.
    private var titleLineLimit: Int? { isAccessibilitySize ? nil : 2 }
    private var subtitleLineLimit: Int? { isAccessibilitySize ? 2 : 1 }

    var body: some View {
        Group {
            if isAccessibilitySize {
                VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                    HStack(spacing: Theme.Spacing.small) {
                        icon
                        Spacer(minLength: 0)
                        badges
                    }
                    labels
                }
            } else {
                HStack(spacing: Theme.Spacing.small) {
                    icon
                    labels
                    Spacer(minLength: Theme.Spacing.tight)
                    badges
                }
            }
        }
        .padding(.vertical, Theme.Spacing.hairline)
        .contentShape(Rectangle())
    }

    private var icon: some View {
        ThingIconView(icon: thing.icon,
                      variants: dominantVariants,
                      title: thing.title,
                      registry: registry)
    }

    private var labels: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(thing.title)
                .font(.body)
                // No cap at accessibility sizes: a clipped title is worse than a tall row,
                // and the row is free to grow.
                .lineLimit(titleLineLimit)
                .fixedSize(horizontal: false, vertical: true)

            Text(subtitleText)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(subtitleLineLimit)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var badges: some View {
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

    /// Shortened at accessibility sizes so "2 hours ago" becomes "2 hr" rather than
    /// "2 hours a…". Shortening the *words* is not shrinking the *type*.
    private var subtitleText: String {
        if let subtitle { return subtitle }
        return RelativeTime.string(fromISO8601: thing.updatedAt,
                                   nowMilliseconds: nowMilliseconds,
                                   style: isAccessibilitySize ? .short : .full)
    }

    /// The query already picked the dominant variant for this Thing, so the icon resolver
    /// gets a one-element list rather than the Thing's whole field set.
    private var dominantVariants: [String] {
        guard let variant = thing.dominantVariant else { return [] }
        return [variant]
    }
}

/// The card used in Home's Pinned shelf.
///
/// Photos-like and small: the card is sized to a 56pt icon plus its label, with no dead
/// space below. It grows with Dynamic Type — capped, so one long title cannot produce a card
/// wider than the phone — which is what stops words breaking mid-word at AccessibilityXXL.
struct ThingCardView: View {

    let thing: Thing
    var registry: FieldKindRegistry?

    /// Scales with the label's own text style, so the box and the words grow together.
    /// Without this the card stays 112pt wide while the label triples, which is what forces
    /// "Cloudflare" to break as "Cloud-flare".
    @ScaledMetric(relativeTo: .subheadline) private var scaledWidth: CGFloat = Theme.Size.pinnedCard

    private var width: CGFloat { min(scaledWidth, Theme.Size.pinnedCardMaxWidth) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            ThingIconView(icon: thing.icon,
                          variants: dominantVariants,
                          title: thing.title,
                          size: Theme.Size.largeIcon,
                          registry: registry)
            // No Spacer, and the label sits directly under the icon: the old card pinned the
            // title to the bottom of a 150pt box, which is where both the dead space and the
            // mismatched baselines came from.
            //
            // `reservesSpace: true` keeps every card in the shelf exactly the same height
            // whether its title wraps or not — the alternative, letting each card size
            // itself, leaves the row of cards with ragged bottoms.
            Text(thing.title)
                .font(.subheadline.weight(.medium))
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.Spacing.medium)
        .frame(width: width, alignment: .leading)
        // Opaque, not glass: a card is content.
        .background(Color(uiColor: .secondarySystemBackground), in: ThingsShape.rounded(Theme.Radius.card))
        .contentShape(ThingsShape.rounded(Theme.Radius.card))
    }

    private var dominantVariants: [String] {
        guard let variant = thing.dominantVariant else { return [] }
        return [variant]
    }
}
