import SwiftUI

/// Port of `HomeActivity.kt`'s `HomeContent`.
///
/// The order and the copy come from Android and are not reordered: 状态, then 常用功能, then the
/// school's own groups in the order the definition lists them. Quick entries are ordered by
/// `nativeType` (课表 / 成绩 / 考试 / 培养方案) through the same helper Android uses, and a group's
/// own items keep their declared order.
///
/// The presentation is iOS's. Each group is a `List` section rather than a hand-stacked card
/// group, because "a titled group of rows you tap through" is exactly what an inset-grouped list
/// is for, and reproducing Android's four-position radius stack on top of a `ScrollView` re-derives
/// what the system already draws.
struct HomeView: View {
    @EnvironmentObject private var state: AppState
    /// Value-based navigation so the status panel can push the page a pending change belongs to,
    /// the way Android acknowledges the notice and then opens the matching quick entry.
    @State private var path: [PortalRoute] = []
    @State private var historyVersion = 0

    private var definition: SchoolDefinition? { state.definition }

    /// Android trims the query and matches titles only -- group headings, subtitles and paths are
    /// not searched -- then drops any group left with nothing in it.
    private var visibleQuickItems: [PortalItem] {
        let all = QuickEntryBaseline.orderedQuickBaselineItems(definition?.quickItems ?? [])
        guard state.isSearching else { return all }
        return all.filter { $0.title.localizedCaseInsensitiveContains(state.trimmedSearchQuery) }
    }

    private var visibleGroups: [PortalGroup] {
        let groups = definition?.groups ?? []
        guard state.isSearching else { return groups }
        return groups.compactMap { group in
            let items = group.items.filter {
                $0.quick != true && $0.title.localizedCaseInsensitiveContains(state.trimmedSearchQuery)
            }
            return items.isEmpty ? nil : PortalGroup(title: group.title, items: items)
        }
    }

    private var hasSearchResults: Bool {
        !visibleQuickItems.isEmpty || !visibleGroups.isEmpty
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                // Android's status panel leads the page and is hidden while a search is
                // surface is open, including before the first character is entered.
                if !state.isSearchPresented {
                    statusPanel
                }

                if !visibleQuickItems.isEmpty {
                    Section {
                        QuickEntryCard(items: visibleQuickItems) { item in
                            path = [.item(item)]
                        }
                            // The card brings its own surface and its cells are plain buttons, so
                            // the section must not add a row background or a disclosure indicator.
                            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    } header: {
                        Text(state.isSearchPresented ? "搜索结果" : "常用功能")
                    }
                }

                ForEach(visibleGroups) { group in
                    Section {
                        ForEach(group.items) { item in
                            NavigationLink(value: PortalRoute.item(item)) {
                                PortalNavigationRow(title: item.title)
                            }
                        }
                    } header: {
                        Text(group.title)
                    }
                }

                if state.isSearchPresented && state.isSearching && !hasSearchResults {
                    searchEmptyState
                        .listRowSeparator(.hidden)
                }
            }
            .listStyle(.insetGrouped)
            .background(PortalPalette.page)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Android's top bar carries a bold title with the school name on its second line.
                // There is no leading item: the school is changed from Settings, which is where
                // Android puts it too.
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        Text("掌上教务")
                            .font(.headline.weight(.bold))
                        Text(state.selectedSchool?.name ?? "未选择学校")
                            .font(.caption)
                            .foregroundStyle(PortalPalette.secondaryText)
                            .lineLimit(1)
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    sessionStatusBadge
                }
            }
            .navigationDestination(for: PortalRoute.self) { route in
                switch route {
                case .item(let item): MaterialPageScreen(item: item)
                case .notifications: NotificationSettingsScreen()
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear.frame(height: BottomClearance.height)
            }
            .overlay {
                QuickEntryBaselinePrefetch()
            }
            .onReceive(NotificationCenter.default.publisher(for: PortalPollHistory.didChangeNotification)) { _ in
                historyVersion &+= 1
            }
        }
    }

    // MARK: - Header

    /// Port of `PortalSessionStatus`: nothing for a healthy session, a spinner while checking, and
    /// a tappable failure otherwise.
    @ViewBuilder
    private var sessionStatusBadge: some View {
        switch state.sessionStatus {
        case .hidden:
            EmptyView()
        case .checking:
            HStack(spacing: 7) {
                ProgressView().controlSize(.mini)
                Text("尝试登录…")
                    .font(.caption)
                    .foregroundStyle(PortalPalette.secondaryText)
            }
        case .unavailable:
            Button {
                Task { await state.revalidateSession() }
            } label: {
                Text("验证失败，点击重试")
                    .font(.caption)
                    .foregroundStyle(PortalPalette.error)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("验证失败，点击重试")
        }
    }

    // MARK: - Sections

    /// Port of `HomeStatusPanel`.
    ///
    /// Android's behaviour is: with no pending change the panel opens the notification settings,
    /// and with one it acknowledges the notice and opens the page the change belongs to. Both are
    /// implemented here; the earlier version only switched tabs, so the panel looked like it did
    /// nothing when tapped.
    private var statusPanel: some View {
        Section {
            Button {
                openStatusPanel()
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: "bell")
                        .font(.system(size: 20))
                        .foregroundStyle(PortalPalette.onSurface)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(statusTitle)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(PortalPalette.onSurface)
                        Text(statusSubtitle)
                            .font(.caption)
                            .foregroundStyle(PortalPalette.secondaryText)
                    }
                    Spacer(minLength: 8)
                    if state.sessionNotice == nil {
                        Text(statusBadge)
                            .font(.caption)
                            .foregroundStyle(PortalPalette.secondaryText)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(Color(uiColor: .tertiarySystemFill))
                            )
                    }
                }
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } header: {
            Text("状态")
        }
    }

    private var enabledNotificationCount: Int {
        let prefs = NotificationPreferences.shared
        return [prefs.scheduleEnabled, prefs.gradeEnabled, prefs.examEnabled, prefs.programEnabled]
            .filter { $0 }.count
    }

    private var statusTitle: String {
        _ = historyVersion
        if let notice = PortalPollHistory.latestUnreadChange() { return "\(notice.category)有新变化" }
        return "变动通知"
    }

    private var statusSubtitle: String {
        _ = historyVersion
        if let notice = PortalPollHistory.latestUnreadChange() { return "点击查看最新\(notice.category)信息" }
        if let notice = state.sessionNotice { return notice }
        return enabledNotificationCount == 0 ? "课表、成绩与考试提醒均已关闭" : "后台检测运行中"
    }

    private var statusBadge: String {
        enabledNotificationCount == 0 ? "未开启" : "\(enabledNotificationCount) 项"
    }

    private func openStatusPanel() {
        guard let notice = PortalPollHistory.latestUnreadChange(), let definition else {
            // No pending change: Android opens the notification settings page itself
            // (`onNormalClick = onOpenNotifications`), not the settings tab.
            path.append(.notifications)
            return
        }
        let quick = QuickEntryBaseline.orderedQuickBaselineItems(definition.quickItems)
        let target = quick.first { $0.nativeType == notice.nativeType }
            ?? definition.groups.flatMap(\.items).first { $0.nativeType == notice.nativeType }
        PortalPollHistory.acknowledge(changeID: notice.entryID)
        if let target {
            path = [.item(target)]
        } else {
            path.append(.notifications)
        }
    }

    private var searchEmptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 40))
                .foregroundStyle(PortalPalette.secondaryText)
            Text("没有找到相关功能")
                .font(.headline)
            Text("换一个关键词试试")
                .font(.subheadline)
                .foregroundStyle(PortalPalette.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
        .padding(.horizontal, 24)
    }
}

/// Everything the home stack can push. One route type keeps a single `navigationDestination`,
/// which SwiftUI requires -- a stack cannot mix destination types.
enum PortalRoute: Hashable {
    case item(PortalItem)
    case notifications
}

/// How much room every scrolling page has to leave below its content so the floating bar never
/// covers the last row. The bar is 64pt tall with 8pt below it, and the list's own bottom inset
/// already accounts for the home indicator, so this is the bar's height plus a little air.
enum BottomClearance {
    static let height: CGFloat = 84
}
