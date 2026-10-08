import SwiftUI

/// Android's per-group visual styles, as reusable pieces.
///
/// `MaterialPortalActivity` does not render every section the same way. It picks between eight
/// distinct looks depending on what the section holds, and the difference is the point: a metrics
/// strip reads as columns divided by hairlines, a list of cards reads as one stacked block with the
/// cards touching, a curriculum module tree is a collapsible panel that alone carries a border. iOS
/// had a single look -- one 20pt rounded rectangle per section with loose content inside -- so the
/// four native pages came out looking nothing like Android's even where the data matched.
///
/// Each type below is one of those looks. The names follow Android's own so the mapping stays
/// checkable against `MaterialPortalActivity.kt`.
///
/// Units: Android's are dp and these are pt. The conversion Android's own code comments already
/// record -- a 104dp row reading as 96pt on a Retina display -- applies here too, so the values
/// are the design intent rather than a literal copy.
enum PortalGroupStyle {

    // MARK: - A. Stacked group

    /// Android style A: cards that touch, so the group reads as one block.
    ///
    /// 18pt on the outer corners and 6pt where neighbours meet, a 3pt gap between them, and no
    /// elevation at all. The gap is what makes the 6pt corners visible; without it the cards would
    /// read as one solid block with no boundaries.
    struct Panel<Content: View>: View {
        let position: GroupPosition
        /// Android nests a module one level deeper with a hairline border; the top level has none.
        var isNested: Bool = false
        @ViewBuilder var content: Content

        var body: some View {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    GroupedCardShape(position: position)
                        .fill(PortalPalette.surface)
                )
                .overlay(
                    GroupedCardShape(position: position)
                        .strokeBorder(
                            isNested ? PortalPalette.outlineVariant.opacity(0.48) : .clear,
                            lineWidth: 0.5
                        )
                )
        }
    }

    /// Lays a group of cards out with the 3pt gap Android uses between them.
    struct Stack<Content: View>: View {
        @ViewBuilder var content: Content

        var body: some View {
            VStack(spacing: 3) { content }
        }
    }

    // MARK: - Section heading

    /// Android `MaterialSectionBlock`'s heading: small, semibold, grey, indented 8pt and sitting
    /// 5pt above its content. Not a title -- these are labels for a block, and Android keeps them
    /// visually quiet so the data below is what the eye goes to.
    struct SectionLabel: View {
        let title: String

        var body: some View {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(PortalPalette.secondaryText)
                .padding(.leading, 8)
                .padding(.bottom, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// A section title together with its content, spaced the way Android spaces them (3pt).
    ///
    /// The title is optional so a section can carry several titled blocks under one scroll view --
    /// Android's curriculum page puts "学分进度" and the module tree in the same section, and a
    /// non-optional title would force a fake heading above the first one.
    struct Block<Content: View>: View {
        var title: String?
        @ViewBuilder var content: Content

        var body: some View {
            VStack(alignment: .leading, spacing: 3) {
                if let title, !title.isEmpty { SectionLabel(title: title) }
                content
            }
        }
    }

    // MARK: - B/C. Key-value rows

    /// Android style B: key-value rows inside one card, divided by hairlines, the value right
    /// aligned. Used by the `fields` sections.
    struct KeyValueCard: View {
        /// Android gives the label 40% and the value 60%, and right-aligns the value.
        private static let labelRatio: CGFloat = 0.4

        let fields: [(label: String, value: String)]

        var body: some View {
            Panel(position: .only) {
                VStack(spacing: 0) {
                    ForEach(Array(fields.enumerated()), id: \.offset) { index, field in
                        HStack(alignment: .top, spacing: 16) {
                            Text(field.label)
                                .font(.subheadline)
                                .foregroundStyle(PortalPalette.secondaryText)
                                .frame(width: 110, alignment: .leading)
                            Text(PortalGroupStyle.display(field.value))
                                .font(.callout)
                                .foregroundStyle(PortalPalette.onSurface)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                                .textSelection(.enabled)
                        }
                        .padding(.vertical, 13)
                        .padding(.horizontal, 16)
                        if index < fields.count - 1 {
                            Rectangle()
                                .fill(PortalPalette.outlineVariant.opacity(0.48))
                                .frame(height: 0.5)
                        }
                    }
                }
            }
        }
    }

    /// Android style C: key-value rows inside a card that already exists, behind a divider, with a
    /// fixed-width label. This is the variant `MaterialInfoCard` uses, and the fixed 82dp label is
    /// deliberate on Android -- these are short values like a grade, not paragraphs.
    struct InlineFields: View {
        private static let labelWidth: CGFloat = 82

        let fields: [(label: String, value: String)]

        var body: some View {
            VStack(alignment: .leading, spacing: 9) {
                ForEach(Array(fields.enumerated()), id: \.offset) { _, field in
                    HStack(alignment: .top, spacing: 14) {
                        Text(field.label)
                            .font(.caption)
                            .foregroundStyle(PortalPalette.secondaryText)
                            .frame(width: Self.labelWidth, alignment: .leading)
                        Text(PortalGroupStyle.display(field.value))
                            .font(.subheadline)
                            .foregroundStyle(PortalPalette.onSurface)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    // MARK: - E. Metric strip

    /// Android style E: metrics in one row, separated by vertical hairlines.
    ///
    /// This is the one place Android does *not* use a `MaterialPanel`: the card is a plain 20pt
    /// rounded rectangle, the values are `onSurface` rather than tinted, and the separators are
    /// vertical. The iOS version had been a two-column grid of separate small tinted cards, which
    /// inverted every one of those.
    struct MetricStrip: View {
        let items: [(label: String, value: String)]

        var body: some View {
            HStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    VStack(spacing: 7) {
                        Text(PortalGroupStyle.display(item.value))
                            .font(.headline)
                            .foregroundStyle(PortalPalette.onSurface)
                            .lineLimit(2)
                            .minimumScaleFactor(0.7)
                            .multilineTextAlignment(.center)
                        Text(item.label)
                            .font(.caption2)
                            .foregroundStyle(PortalPalette.secondaryText)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 15)
                    if index < items.count - 1 {
                        Rectangle()
                            .fill(PortalPalette.outlineVariant.opacity(0.55))
                            .frame(width: 0.5, height: 58)
                    }
                }
            }
            .frame(minHeight: 92)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(PortalPalette.surface)
            )
        }
    }

    // MARK: - D. Table

    /// Android style D: a table with a filled header row and zebra striping.
    ///
    /// The header is `surfaceVariant` at 72% and alternate rows at 32% -- both greys, not the accent
    /// blue the iOS table used for its header, which made the header look like a selection.
    struct Table: View {
        let headers: [String]
        let rows: [[String]]

        var body: some View {
            Panel(position: .only) {
                ScrollView(.horizontal, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        if !headers.isEmpty {
                            Row(cells: headers, isHeader: true)
                            hairline
                        }
                        ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                            Row(cells: row, isHeader: false, isAlternate: index.isMultiple(of: 2) == false)
                        }
                    }
                }
                .padding(.vertical, 8)
            }
        }

        /// One row, shared with the curriculum module so both render the same 148pt columns and the
        /// same zebra striping. Android's `TableRow` is a single function used by both callers.
        struct Row: View {
            private static let columnWidth: CGFloat = 148

            let cells: [String]
            var isHeader: Bool
            var isAlternate: Bool = false

            init(cells: [String], isHeader: Bool, isAlternate: Bool = false) {
                self.cells = cells
                self.isHeader = isHeader
                self.isAlternate = isAlternate
            }

            var body: some View {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                        Text(PortalGroupStyle.display(cell))
                            .font(isHeader ? .subheadline.weight(.semibold) : .callout)
                            .foregroundStyle(PortalPalette.onSurface)
                            .frame(width: Self.columnWidth, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 11)
                    }
                }
                .background(
                    isHeader
                        ? PortalPalette.surfaceVariant.opacity(0.72)
                        : (isAlternate ? PortalPalette.surfaceVariant.opacity(0.32) : Color.clear)
                )
            }
        }
    }

    // MARK: - Shared bits

    /// Android writes a dash where a value is blank, in every section that shows values. Rendering
    /// the empty string instead leaves a row that looks like a rendering bug.
    static func display(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "—" : trimmed
    }

    /// Android's hairline separator at the strength it uses inside cards.
    static var hairline: some View {
        Rectangle()
            .fill(PortalPalette.outlineVariant.opacity(0.52))
            .frame(height: 0.5)
    }
}
