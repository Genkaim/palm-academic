import SwiftUI

/// Port of `SettingsActivity.kt`.
///
/// Android groups the page as 外观 / 教务 / 应用 / 账户, and the grouping is not cosmetic: each
/// section answers one question. The content of each is reproduced, the presentation is iOS's --
/// a `Form` with `Section`s, which is the system container for a settings screen and supplies the
/// row grouping, the disclosure indicators and the disclosure behaviour on its own.
struct SettingsScreen: View {
    @EnvironmentObject private var state: AppState
    @State private var showingSchools = false
    @State private var release: GitHubRelease?
    @State private var isRefreshing = false
    @State private var isCheckingRelease = false
    @State private var statusMessage: String?
    @State private var confirmSignOut = false
    @ObservedObject private var notifications = NotificationPreferences.shared

    var body: some View {
        NavigationStack {
            Form {
                appearanceSection
                academicSection
                notificationSection
                historySection
                applicationSection
                accountSection
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.large)
            .sheet(isPresented: $showingSchools) {
                SchoolPickerView { school in state.selectSchool(school) }
                    .environmentObject(state)
            }
            .task { await checkRelease() }
            .confirmationDialog("退出登录", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("退出登录", role: .destructive) { state.signOut() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("退出后需要重新使用学校账号登录。")
            }
        }
    }

    // MARK: - 外观

    private var appearanceSection: some View {
        Section("外观") {
            Picker("显示模式", selection: $state.themeMode) {
                ForEach(ThemeMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Toggle("液态玻璃", isOn: $state.glassEnabled)
        }
    }

    // MARK: - 教务

    private var academicSection: some View {
        Section("教务") {
            Button {
                showingSchools = true
            } label: {
                PortalNavigationRow(
                    systemImage: "building.columns",
                    title: "学校",
                    trailing: {
                        Text(state.selectedSchool?.name ?? "未选择")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                )
            }
            .buttonStyle(.plain)
            .disabled(state.isLoading)
        }
    }

    // MARK: - 变动通知（进入独立页）

    private var notificationSection: some View {
        Section {
            NavigationLink {
                NotificationSettingsScreen()
            } label: {
                PortalNavigationRow(systemImage: "bell", title: "变动通知")
            }
        }
    }

    /// The check log used to be its own bottom-bar tab. Android has no such tab -- it is reached
    /// from the notification settings -- so the entry lives here.
    private var historySection: some View {
        Section {
            NavigationLink {
                NoticeHistoryScreen()
            } label: {
                PortalNavigationRow(systemImage: "doc.text.magnifyingglass", title: "检查日志")
            }
        }
    }

    // MARK: - 应用

    private var applicationSection: some View {
        Section {
            Toggle("后台运行", isOn: $notifications.monitorEnabled)
            Button {
                Task { await checkRelease(force: true) }
            } label: {
                PortalNavigationRow(
                    systemImage: "arrow.down.circle",
                    title: "软件更新",
                    trailing: {
                        if isCheckingRelease {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("当前版本 \(appVersion)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                )
            }
            .buttonStyle(.plain)
            .disabled(isCheckingRelease)

            if let release {
                Section {
                    Link(destination: URL(string: release.htmlUrl)!) {
                        PortalNavigationRow(systemImage: "tag", title: "发现新版本 \(release.tagName)")
                    }
                }
            }
        } header: {
            Text("应用")
        } footer: {
            Text(statusMessage ?? "更新会检查 GitHub Releases，不会自动安装。")
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    // MARK: - 账户

    private var accountSection: some View {
        Section {
            Button {
                confirmSignOut = true
            } label: {
                Text("退出登录")
                    .foregroundStyle(Color.red)
            }
        } header: {
            Text("账户")
        }
    }

    // MARK: - Actions

    private func refreshSchools() async {
        isRefreshing = true
        defer { isRefreshing = false }
        await state.refreshFromGitHub()
        statusMessage = state.errorMessage ?? state.sessionNotice
    }

    private func checkRelease(force: Bool = false) async {
        guard force || release == nil else { return }
        isCheckingRelease = true
        defer { isCheckingRelease = false }
        release = try? await GitHubRepository.latestRelease()
    }
}

/// Port of `NotificationSettingsActivity.kt`: which changes are watched, how often, and the log.
struct NotificationSettingsScreen: View {
    @ObservedObject private var notifications = NotificationPreferences.shared

    var body: some View {
        Form {
            Section {
                Toggle("课表", isOn: $notifications.scheduleEnabled)
                Toggle("成绩", isOn: $notifications.gradeEnabled)
                Toggle("考试", isOn: $notifications.examEnabled)
                Toggle("培养方案", isOn: $notifications.programEnabled)
            } header: {
                Text("通知类型")
            }

            Section {
                Picker("检查频率", selection: $notifications.intervalMinutes) {
                    Text("15 分钟").tag(15)
                    Text("30 分钟").tag(30)
                    Text("60 分钟").tag(60)
                }
            } header: {
                Text("检查频率")
            } footer: {
                Text("iOS 会根据系统电量与使用情况调整实际执行频率，界面显示的是请求的间隔。")
            }

            Section {
                NavigationLink {
                    NoticeHistoryScreen()
                } label: {
                    PortalNavigationRow(systemImage: "doc.text.magnifyingglass", title: "检查日志")
                }
            } header: {
                Text("记录")
            }

            Section {
                Button {
                    PortalPollHistory.clear()
                } label: {
                    Text("清空").foregroundStyle(Color.red)
                }
            }
        }
        .navigationTitle("变动通知")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Port of `NotificationHistoryActivity.kt`.
struct NoticeHistoryScreen: View {
    @State private var entries: [PortalPollHistoryEntry] = PortalPollHistory.load()
    @State private var filter: Filter = .all

    private enum Filter: String, CaseIterable, Identifiable {
        case all = "全部"
        case changes = "有变更"
        var id: String { rawValue }
    }

    private var visibleEntries: [PortalPollHistoryEntry] {
        switch filter {
        case .all: return entries
        case .changes: return entries.filter { $0.notificationTriggered || $0.details.contains(where: \.changed) }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if visibleEntries.isEmpty {
                    // ContentUnavailableView is iOS 17+; the deployment target is 16.
                    VStack(spacing: 10) {
                        Image(systemName: "clock")
                            .font(.system(size: 34))
                            .foregroundStyle(.secondary)
                        Text("暂无检查记录")
                            .font(.headline)
                        Text("开启后台检查后，变更记录会显示在这里。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 36)
                    .listRowSeparator(.hidden)
                }
                ForEach(visibleEntries) { entry in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(entry.status)
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Text(entry.timestamp, format: .dateTime.month().day().hour().minute())
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(entry.details) { detail in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(detail.category)
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(.tint)
                                    Text(detail.summary)
                                        .font(.caption)
                                    if detail.changed {
                                        Image(systemName: "arrow.up.circle.fill")
                                            .font(.caption2)
                                            .foregroundStyle(.orange)
                                    }
                                }
                                if !detail.difference.isEmpty {
                                    Text(detail.difference)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                if let technical = detail.technicalDetails, !technical.isEmpty {
                                    Text(technical)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onDelete { indexSet in
                    var updated = entries
                    updated.remove(atOffsets: indexSet)
                    entries = updated
                    if let data = try? JSONEncoder().encode(updated) {
                        UserDefaults.standard.set(data, forKey: "poll_history_entries")
                    }
                }
            }
            .navigationTitle("变更记录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Picker("", selection: $filter) {
                        ForEach(Filter.allCases) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 160)
                }
            }
        }
    }
}

/// Port of `AboutActivity.kt`.
struct AboutScreen: View {
    @State private var release: GitHubRelease?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color.accentColor.opacity(0.12))
                        .frame(width: 76, height: 76)
                        .overlay(
                            Image(systemName: "building.columns")
                                .font(.system(size: 36))
                                .foregroundStyle(.tint)
                        )

                    Text("掌上教务")
                        .font(.title2.bold())
                    Text("iOS 原生版本 \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.4.5")")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    GlassCard(isDark: ThemePreferences.shared.isDark) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("关于本应用").font(.headline)
                            Text("本版本使用 SwiftUI 与 WKWebView 实现，与安卓端共用同一套学校配置和页面解析适配器，因此两端渲染结果保持一致。")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text("应用不收集任何个人信息，仅在你主动登录后访问对应学校的教务系统。")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let release {
                        GlassCard(isDark: ThemePreferences.shared.isDark) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("最新版本 \(release.tagName)").font(.headline)
                                if let body = release.body, !body.isEmpty {
                                    Text(body)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(12)
                                }
                                if let url = URL(string: release.htmlUrl) {
                                    Link("在 GitHub 查看", destination: url)
                                        .font(.subheadline)
                                }
                            }
                        }
                    }
                }
                .padding(20)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("关于")
            .navigationBarTitleDisplayMode(.inline)
            .task { release = try? await GitHubRepository.latestRelease() }
        }
    }
}