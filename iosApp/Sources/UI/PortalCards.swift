import SwiftUI

/// Where a card sits inside its group, which is what decides its corner treatment.
///
/// The Android client runs one shape per group rather than one card: the first row keeps the
/// group's large radii on top and small ones underneath, the middle rows are fully rounded at the
/// small radius, and the last row is the mirror of the first. Three points of spacing between
/// cards is what makes the stack read as one block. Copying only the large radius -- as an earlier
/// iOS version did -- loses that read entirely.
enum GroupPosition: Int {
    case only, first, middle, last

    init(index: Int, count: Int) {
        switch count {
        case 0, 1: self = .only
        case 2: self = index == 0 ? .first : .last
        default:
            if index == 0 { self = .first }
            else if index == count - 1 { self = .last }
            else { self = .middle }
        }
    }
}

/// The Android `MaterialPanel` / `HomePanel` shape: 18pt on the group's outer corners, 6pt where
/// cards meet each other.
///
/// The path is written by hand rather than with `UnevenRoundedRectangle` (iOS 16.4) or
/// `Path(roundedRect:cornerRadii:)` (iOS 17), because the deployment target is 16.0 and the
/// cross-compile SDK is 16.5, where neither exists.
struct GroupedCardShape: Shape {
    var large: CGFloat = 18
    var small: CGFloat = 6
    var position: GroupPosition

    func path(in rect: CGRect) -> Path {
        let topLeft, topRight, bottomRight, bottomLeft: CGFloat
        switch position {
        case .only:
            (topLeft, topRight, bottomRight, bottomLeft) = (large, large, large, large)
        case .first:
            (topLeft, topRight, bottomRight, bottomLeft) = (large, large, small, small)
        case .middle:
            (topLeft, topRight, bottomRight, bottomLeft) = (small, small, small, small)
        case .last:
            (topLeft, topRight, bottomRight, bottomLeft) = (small, small, large, large)
        }

        let minX = rect.minX, minY = rect.minY, maxX = rect.maxX, maxY = rect.maxY
        var path = Path()
        path.move(to: CGPoint(x: minX + topLeft, y: minY))
        path.addLine(to: CGPoint(x: maxX - topRight, y: minY))
        path.addArc(tangent1End: CGPoint(x: maxX, y: minY),
                    tangent2End: CGPoint(x: maxX, y: minY + topRight),
                    radius: topRight)
        path.addLine(to: CGPoint(x: maxX, y: maxY - bottomRight))
        path.addArc(tangent1End: CGPoint(x: maxX, y: maxY),
                    tangent2End: CGPoint(x: maxX - bottomRight, y: maxY),
                    radius: bottomRight)
        path.addLine(to: CGPoint(x: minX + bottomLeft, y: maxY))
        path.addArc(tangent1End: CGPoint(x: minX, y: maxY),
                    tangent2End: CGPoint(x: minX, y: maxY - bottomLeft),
                    radius: bottomLeft)
        path.addLine(to: CGPoint(x: minX, y: minY + topLeft))
        path.addArc(tangent1End: CGPoint(x: minX, y: minY),
                    tangent2End: CGPoint(x: minX + topLeft, y: minY),
                    radius: topLeft)
        path.closeSubpath()
        return path
    }
}

/// A group's heading, matching the Android `HomeSection` / `MaterialSectionBlock` title.
struct PortalSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, 8)
            .padding(.bottom, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One row inside a group: a title and a disclosure indicator, on the system grouped surface.
///
/// Android's `PortalRow` uses a 16/15 horizontal/vertical inset and a chevron tinted with the
/// `outline` token; the icon is the only thing that varies, and Android leaves it empty.
struct PortalNavigationRow<Trailing: View>: View {
    var systemImage: String?
    var tint: Color = .accentColor
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 13) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 17))
                    .foregroundStyle(tint)
                    .frame(width: 21, alignment: .leading)
            }
            Text(title)
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
            trailing
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 15)
        .contentShape(Rectangle())
    }
}

extension PortalNavigationRow where Trailing == EmptyView {
    init(systemImage: String? = nil, tint: Color = .accentColor, title: String) {
        self.init(systemImage: systemImage, tint: tint, title: title) { EmptyView() }
    }
}

/// The Android `QuickEntryGrid`: one 20pt card holding a two-column grid with rules between the
/// cells, rather than a grid of separate cards.
///
/// The differences that matter visually are that the rules are *inside* a single surface, the row
/// height is a fixed 104pt, and each cell carries a subtitle under its title. Splitting it into
/// independent cards -- as the iOS version did -- loses the ruled-table read that Android has.
struct QuickEntryCard: View {
    let items: [PortalItem]

    private let cornerRadius: CGFloat = 20
    private let rowHeight: CGFloat = 104

    private var rows: [[PortalItem]] {
        stride(from: 0, to: items.count, by: 2).map {
            Array(items[$0..<min($0 + 2, items.count)])
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, rowItems in
                if rowIndex > 0 {
                    Divider().padding(.horizontal, 14)
                }
                HStack(spacing: 0) {
                    NavigationLink(value: rowItems[0]) {
                        cell(rowItems[0])
                    }
                    .buttonStyle(.plain)

                    Divider().frame(maxHeight: .infinity).padding(.vertical, 14)

                    if rowItems.count > 1 {
                        NavigationLink(value: rowItems[1]) {
                            cell(rowItems[1])
                        }
                        .buttonStyle(.plain)
                    } else {
                        // An odd trailing entry leaves the right half empty, exactly as the
                        // Android Row does with its weight(1f) Spacer.
                        Spacer().frame(maxWidth: .infinity)
                    }
                }
                .frame(height: rowHeight)
            }
        }
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private func cell(_ item: PortalItem) -> some View {
        VStack(spacing: 0) {
            Image(systemName: QuickEntryIcon.name(for: item))
                .font(.system(size: 24))
                .foregroundStyle(Color.primary)
            Spacer(minLength: 8)
            VStack(spacing: 2) {
                Text(item.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(QuickEntryIcon.subtitle(for: item))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }
}

/// Icon and subtitle rules for a quick entry, ported from `HomeActivity.kt`.
///
/// Both rules are worth copying exactly rather than "improving". The icon keys off the *title*
/// with `contains`, in the order 课表, 考试, 成绩, so 我的课表 and 我的班级课表 both land on the
/// calendar while 培养方案完成情况 falls through to the search glyph. The subtitle keys off
/// `nativeType` instead, which is why it is the more reliable of the two.
enum QuickEntryIcon {
    static func name(for item: PortalItem) -> String {
        if item.title.contains("课表") { return "calendar" }
        if item.title.contains("考试") { return "doc.text" }
        if item.title.contains("成绩") { return "graduationcap" }
        return "magnifyingglass"
    }

    static func subtitle(for item: PortalItem) -> String {
        switch item.nativeType {
        case "schedule": return "课程与时间"
        case "grade": return "成绩与绩点"
        case "exam": return "时间与考场"
        case "program": return "学分与进度"
        default: return "打开功能"
        }
    }
}
