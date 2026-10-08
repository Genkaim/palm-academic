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
    ///
    /// The declared order is kept. Android's `HomeContent` filters `school.quickItems` in place and
    /// never sorts it; `orderedQuickBaselineItems` exists for the background prefetcher, which
    /// wants the cheapest page first, so applying it here reordered the grid away from the sequence
    /// the school file declares (培养方案 / 课表 / 考试 / 成绩 became 课表 / 成绩 / 考试 / 培养方案).
    private var visibleQuickItems: [PortalItem] {
        let all = definition?.quickItems ?? []
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
            // Hide the table view's own opaque background so the explicit page colour below is
            // the single surface: it ignores EVERY safe-area edge, which carries it under the
            // status bar at the top and under the floating tab bar / home indicator at the
            // bottom. The inset-grouped section cards keep their own row backgrounds.
            .scrollContentBackground(.hidden)
            .background(PortalPalette.page.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            // The nav bar's own chrome is dropped so the list and its section headers extend under
            // the status bar; the bar itself is drawn as transparent glass by the shell. Without
            // this the page paints a thick white strip behind the time/battery area, which is the
            // "状态栏没有沉浸" read -- the page looks inset where the system already is.
            .toolbarBackground(.hidden, for: .navigationBar)
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
                        // The badge slides in from the trailing edge with a small scale, and the
                        // principal title it pushes is re-centred by the system in the same pass,
                        // so the title looks like it slides left to make room for the new control.
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            // Animating on the enum keeps the badge's appear/disappear transition (and the
            // principal title's re-centring that the system performs alongside it) on the same
            // spring as the rest of the chrome.
            .animation(.spring(response: 0.42, dampingFraction: 0.82), value: state.sessionStatus)
            .navigationDestination(for: PortalRoute.self) { route in
                switch route {
                case .item(let item):
                    // Android's `HomeActivity.openItem` splits on the same flag: a `quick` entry is
                    // drawn by the shared JS adapter, everything else is the portal's own page.
                    // Routing both through `MaterialPageScreen` left the non-quick majority with
                    // whatever the adapter happened to publish for a DOM it was not written for.
                    if item.quick == true {
                        MaterialPageScreen(item: item)
                    } else {
                        OriginalPortalScreen(item: item)
                    }
                case .notifications:
                    NotificationSettingsScreen()
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear.frame(height: BottomClearance.height)
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
            // A compact spinner without text. The whole row is small enough that adding words here
            // would push the principal title off the centre of the bar, which is what the earlier
            // "验证失败，点击重试" string was doing -- the title sat hard against the leading edge
            // and the page read as "where did the title go".
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("登录中")
                    .font(.caption2)
                    .foregroundStyle(PortalPalette.secondaryText)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(Color(uiColor: .tertiarySystemFill))
            )
        case .unavailable(let message):
            Button {
                Task { await state.revalidateSession() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .bold))
                    Text("重试登录")
                        .font(.caption.weight(.semibold))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule().fill(PortalPalette.error.opacity(0.12))
                )
                .foregroundStyle(PortalPalette.error)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(message.isEmpty ? "重试登录" : message)
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
        let quick = definition.quickItems
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
/// covers the last row. The capsule is 60pt tall with an 8pt gap above the bottom safe area;
/// the list's own bottom inset already accounts for the home indicator, so this just clears
/// the capsule plus a little air.
enum BottomClearance {
    static let height: CGFloat = 76
}
