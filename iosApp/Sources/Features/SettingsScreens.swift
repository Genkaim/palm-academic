import SwiftUI

/// Port of `SettingsActivity.kt` and `NotificationSettingsActivity.kt`.
struct SettingsScreen: View {
    @EnvironmentObject private var state: AppState
    @State private var showingSchools = false
    @State private var release: GitHubRelease?
    @State private var isRefreshing = false
    @State private var isCheckingRelease = false
    @State private var statusMessage: String?
    @ObservedObject private var notifications = NotificationPreferences.shared

    var body: some View {
        NavigationStack {
            Form {
                accountSection
                monitoringSection
                notificationSection
                historySection
                appearanceSection
                schoolSection
                aboutSection
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showingSchools) {
                SchoolPickerView { school in state.selectSchool(school) }
            }
            .task { await checkRelease() }
        }
    }

    private var accountSection: some View {
        Section("账号") {
            LabeledContent("学校", value: state.selectedSchool?.name ?? "未选择")
            LabeledContent("账号", value: state.username.isEmpty ? "未记住" : state.username)
            Button(role: .destructive) {
                state.signOut()
            } label: {
                Text("退出登录")
            }
        }
    }

    private var monitoringSection: some View {
        Section {
            Toggle("启用后台检查", isOn: $notifications.monitorEnabled)
            if notifications.monitorEnabled {
                Picker("检查间隔", selection: $notifications.intervalMinutes) {
                    Text("15 分钟").tag(15)
                    Text("30 分钟").tag(30)
                    Text("60 分钟").tag(60)
                    Text("3 小时").tag(180)
                }
            }
        } header: {
            Text("后台检查")
        } footer: {
            Text("iOS 会根据系统电量与使用情况调整实际执行频率，界面显示的是请求的间隔。")
        }
    }

    private var notificationSection: some View {
        Section("变更提醒") {
            Toggle("课表", isOn: $notifications.scheduleEnabled)
            Toggle("成绩", isOn: $notifications.gradeEnabled)
            Toggle("考试", isOn: $notifications.examEnabled)
            Toggle("培养方案", isOn: $notifications.programEnabled)
        }
    }

    /// The check log used to be its own bottom-bar tab. Android has no such tab -- the log is
    /// reached from Settings, under the notification section -- so the entry lives here.
    private var historySection: some View {
        Section {
            NavigationLink {
                NoticeHistoryScreen()
            } label: {
                LabeledContent("检查日志", value: "查看检测历史与具体变动")
            }
        } header: {
            Text("记录")
        }
    }

    private var appearanceSection: some View {
        Section("外观") {
            Toggle("深色模式", isOn: Binding(
                get: { ThemePreferences.shared.isDark },
                set: { newValue in
                    ThemePreferences.shared.isDark = newValue
                    state.isDark = newValue
                }
            ))
        }
    }

    private var schoolSection: some View {
        Section {
            Button("切换学校") { showingSchools = true }
            Button {
                Task { await refreshSchools() }
            } label: {
                HStack {
                    Text("从 GitHub 更新学校配置")
                    if isRefreshing { Spacer(); ProgressView().controlSize(.small) }
                }
            }
            .disabled(isRefreshing)

            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("学校配置")
        } footer: {
            Text("更新会校验学校定义、HTTPS 地址与远程配置路径，校验失败时保留当前配置。")
        }
    }

    private var aboutSection: some View {
        Section("关于") {
            LabeledContent("版本", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
            if let release {
                LabeledContent("最新版本", value: release.tagName)
                if let url = URL(string: release.htmlUrl) {
                    Link("查看更新日志", destination: url)
                }
            }
            Button {
                Task { await checkRelease(force: true) }
            } label: {
                HStack {
                    Text("检查更新")
                    if isCheckingRelease { Spacer(); ProgressView().controlSize(.small) }
                }
            }
            .disabled(isCheckingRelease)
        }
    }

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