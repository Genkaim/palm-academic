import SwiftUI

/// Port of `HomeActivity.kt`'s `HomeContent`.
///
/// Structure and copy follow Android; the surfaces are iOS. Concretely that means the two-column
/// quick-entry block is one ruled card rather than a grid of tiles, the group stacks use the
/// four-position radius scheme, the header carries the school name on its own line, and the whole
/// page filters through the bar's search field.
struct HomeView: View {
    @EnvironmentObject private var state: AppState
    @State private var showingSchools = false
    /// Value-based navigation so the status panel can push the page a pending change belongs to,
    /// the way Android acknowledges the notice and then opens the matching quick entry.
    @State private var path: [PortalItem] = []

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
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    // Android's status panel leads the page and is hidden while a search is
                    // actually filtering something.
                    if !state.isSearching {
                        statusPanel
                    }

                    if !visibleQuickItems.isEmpty {
                        PortalSectionHeader(title: state.isSearching ? "搜索结果" : "常用功能")
                        QuickEntryCard(items: visibleQuickItems)
                    }

                    ForEach(visibleGroups) { group in
                        groupStack(group)
                    }

                    if state.isSearching && !hasSearchResults {
                        searchEmptyState
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 112)
            }
            .background(Color(.systemGroupedBackground))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Android's top bar carries a bold title with the school name on a second line, so
                // the principal toolbar item holds both rather than using the system large title.
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        Text("掌上教务")
                            .font(.headline.weight(.bold))
                        Text(state.selectedSchool?.name ?? "未选择学校")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        showingSchools = true
                    } label: {
                        Image(systemName: "building.2")
                    }
                    .accessibilityLabel("切换学校")
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    sessionStatusBadge
                }
            }
            .navigationDestination(for: PortalItem.self) { item in
                MaterialPageScreen(item: item)
            }
            .sheet(isPresented: $showingSchools) {
                SchoolPickerView { school in state.selectSchool(school) }
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
                    .foregroundStyle(.secondary)
            }
        case .unavailable:
            Button {
                Task { await state.revalidateSession() }
            } label: {
                Text("验证失败，点击重试")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("验证失败，点击重试")
        }
    }

    // MARK: - Sections

    /// Port of `HomeStatusPanel`. It opens the notification settings when nothing has changed, and
    /// jumps to the affected page when something has.
    private var statusPanel: some View {
        VStack(alignment: .leading, spacing: 3) {
            PortalSectionHeader(title: "状态")
            Button {
                openStatusPanel()
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: "bell")
                        .font(.system(size: 20))
                        .foregroundStyle(Color.primary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(statusTitle)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.primary)
                        Text(statusSubtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if state.sessionNotice == nil {
                        Text(statusBadge)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(Color(.tertiarySystemFill))
                            )
                    }
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 15)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(Color(.secondarySystemGroupedBackground),
                          in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private var enabledNotificationCount: Int {
        let prefs = NotificationPreferences.shared
        return [prefs.scheduleEnabled, prefs.gradeEnabled, prefs.examEnabled, prefs.programEnabled]
            .filter { $0 }.count
    }

    private var statusTitle: String {
        if let notice = state.sessionNotice { return "\(notice)有新变化" }
        return "变动通知"
    }

    private var statusSubtitle: String {
        if let notice = state.sessionNotice { return "点击查看最新\(notice)信息" }
        return enabledNotificationCount == 0 ? "课表、成绩与考试提醒均已关闭" : "后台检测运行中"
    }

    private var statusBadge: String {
        enabledNotificationCount == 0 ? "未开启" : "\(enabledNotificationCount) 项"
    }

    private func openStatusPanel() {
        guard let notice = state.sessionNotice, let definition else {
            state.selectedTab = .settings
            return
        }
        let quick = QuickEntryBaseline.orderedQuickBaselineItems(definition.quickItems)
        let target = quick.first { $0.title.contains(notice) }
            ?? definition.groups.flatMap(\.items).first { $0.title.contains(notice) }
        state.dismissSessionNotice()
        if let target {
            path = [target]
        }
    }

    /// Port of `PortalItemCard`: one stack of rows sharing a single surface, the corners stepping
    /// from 18pt to 6pt so the block reads as one card.
    private func groupStack(_ group: PortalGroup) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            PortalSectionHeader(title: group.title)
            VStack(spacing: 3) {
                ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
                    NavigationLink(value: item) {
                        PortalNavigationRow(title: item.title)
                    }
                    .buttonStyle(.plain)
                    .background(
                        Color(.secondarySystemGroupedBackground),
                        in: GroupedCardShape(position: GroupPosition(index: index, count: group.items.count))
                    )
                }
            }
        }
    }

    private var searchEmptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("没有找到相关功能")
                .font(.headline)
            Text("换一个关键词试试")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 56)
        .padding(.horizontal, 24)
    }
}
