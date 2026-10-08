import SwiftUI
import UIKit

/// Port of `SettingsActivity.kt`.
///
/// Android groups the page as 外观 / 教务 / 应用 / 账户, and the grouping is not cosmetic: each
/// section answers one question. The content follows Android exactly, including the icons -- every
/// row carries one, which is what makes a settings list scannable. The presentation is iOS's
/// `List` in the inset-grouped style, which supplies the section headers, the row highlighting, the
/// disclosure indicators and the disclosure behaviour on its own.
///
/// Two deliberate divergences:
///
/// - The 液态玻璃 switch is gone. On Android it picks between a hand-drawn glass effect and a
///   plain translucent one. On iOS the bottom bar is a system material (or the system's own
///   `glassEffect` when the SDK provides it), so there is no hand-drawn fallback to switch away
///   from and the row would be offering a choice that does not exist.
/// - 后台运行 is a second-level page rather than a switch. Its Android content is four rows that
///   deep-link into vendor-specific settings screens (自启动 / 电池优化 / 后台限制 / 通知权限);
///   iOS has one equivalent control, Low Power Mode, plus the notification authorisation the
///   app actually depends on, so those are listed as inspectable rows on their own page.
struct SettingsScreen: View {
    @EnvironmentObject private var state: AppState
    @State private var release: GitHubRelease?
    @State private var isCheckingRelease = false
    @State private var confirmSignOut = false
    @ObservedObject private var notifications = NotificationPreferences.shared

    var body: some View {
        NavigationStack {
            List {
                appearanceSection
                academicSection
                applicationSection
                accountSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.large)
            // The bar floats over the content rather than insetting the page, so the last row --
            // 退出登录 -- would otherwise sit under it and could not be tapped. An inset added
            // around the NavigationStack is swallowed by the stack's own inset handling, so the
            // clearance has to live on the List itself.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear.frame(height: BottomClearance.height)
            }
            .task { await checkRelease() }
        }
    }

    // MARK: - 外观

    private var appearanceSection: some View {
        Section {
            HStack(spacing: 12) {
                PortalRowIcon("paintpalette").glyph()
                VStack(alignment: .leading, spacing: 3) {
                    Text("显示模式")
                        .font(.body)
                    Text("选择界面的明暗外观")
                        .font(.caption)
                        .foregroundStyle(PortalPalette.secondaryText)
                }
                Spacer(minLength: 8)
            }
            .padding(.vertical, 4)

            Picker("显示模式", selection: $state.themeMode) {
                ForEach(ThemeMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 4, trailing: 16))
            // The segmented control is the last thing in the group, so the section's closing
            // separator would draw a line under a control that already has its own edges.
            .listRowSeparator(.hidden)
        } header: {
            Text("外观")
        }
    }

    // MARK: - 教务

    private var academicSection: some View {
        Section {
            // A NavigationLink rather than a Button, so the system draws the disclosure indicator.
            // The earlier Button carried a hand-drawn one and the row had none at all, which is why
            // 学校 looked like the only entry that did something.
            NavigationLink {
                SchoolPickerView { school in state.selectSchool(school) }
                    .environmentObject(state)
            } label: {
                PortalSettingsRow(
                    icon: PortalRowIcon("building.columns"),
                    title: "学校",
                    subtitle: state.selectedSchool?.name ?? "未选择"
                )
            }

            NavigationLink {
                NotificationSettingsScreen()
            } label: {
                PortalSettingsRow(
                    icon: PortalRowIcon("bell"),
                    title: "变动通知",
                    subtitle: "课表、成绩与考试提醒"
                )
            }
        } header: {
            Text("教务")
        }
    }

    // MARK: - 应用

    private var applicationSection: some View {
        Section {
            NavigationLink {
                BackgroundSupportScreen()
            } label: {
                PortalSettingsRow(
                    icon: PortalRowIcon("arrow.triangle.2.circlepath"),
                    title: "后台运行",
                    subtitle: "后台刷新、低电量模式与通知权限"
                )
            }

            Button {
                Task { await checkRelease(force: true) }
            } label: {
                PortalSettingsRow(
                    icon: PortalRowIcon("arrow.down.circle"),
                    title: "软件更新",
                    subtitle: isCheckingRelease ? "正在检查更新…" : "当前版本 \(appVersion)",
                    showsSpinner: isCheckingRelease
                )
            }
            .buttonStyle(.plain)
            .disabled(isCheckingRelease)

            NavigationLink {
                AboutScreen()
            } label: {
                PortalSettingsRow(
                    icon: PortalRowIcon("info.circle"),
                    title: "关于",
                    subtitle: "开源引用、作者与项目地址"
                )
            }
        } header: {
            Text("应用")
        } footer: {
            Text(release.map { "发现新版本 \($0.tagName)" } ?? "更新会检查 GitHub Releases，不会自动安装。")
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    // MARK: - 账户

    private var accountSection: some View {
        Section {
            Button {
                withAnimation(.easeOut(duration: 0.16)) { confirmSignOut = true }
            } label: {
                HStack(spacing: 12) {
                    PortalRowIcon("rectangle.portrait.and.arrow.right").glyph()
                    Text("退出登录")
                        .foregroundStyle(PortalPalette.error)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } header: {
            Text("账户")
        }
        // The system's own confirmation, so the alert is the one iOS draws. The request was to
        // change where it appears, not what it looks like: an earlier pass answered "lower please"
        // with a hand-built sheet, which traded the platform's alert for something that merely
        // resembles it -- its own corner radius, its own type scale, its own dimming -- and those
        // are exactly the things that drift with every OS release. The lower position comes for
        // free here: on a phone `confirmationDialog` is an action sheet, and it rises from the
        // bottom edge, which is where the row that opened it already is.
        .confirmationDialog(
            "退出登录？",
            isPresented: $confirmSignOut,
            titleVisibility: .visible
        ) {
            Button("退出", role: .destructive) { state.signOut() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将清除本应用中的登录会话并停止后台监测。")
        }
    }

    // MARK: - Actions

    private func checkRelease(force: Bool = false) async {
        guard force || release == nil else { return }
        isCheckingRelease = true
        defer { isCheckingRelease = false }
        release = try? await GitHubRepository.latestRelease()
    }
}

/// One settings row: the icon, a title and a subtitle, in the shape `Settings` uses on iOS.
///
/// Android's `SettingsNavigationPanel` draws a 22pt outline glyph, then the title and description,
/// then a chevron. The chevron here is the system's -- `NavigationLink` draws its own, and a
/// hand-drawn one on top of it would double up.
struct PortalSettingsRow: View {
    let icon: PortalRowIcon
    let title: String
    var subtitle: String = ""
    var showsSpinner: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            icon.glyph()
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(PortalPalette.onSurface)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(PortalPalette.secondaryText)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if showsSpinner {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

/// Port of `NotificationSettingsActivity.kt`: which changes are watched, how often, and the log.
struct NotificationSettingsScreen: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var notifications = NotificationPreferences.shared
    @State private var entries: [PortalPollHistoryEntry] = PortalPollHistory.load()
    @State private var isChecking = false

    var body: some View {
        List {
            Section {
                Toggle("课表", isOn: $notifications.scheduleEnabled)
                Toggle("成绩", isOn: $notifications.gradeEnabled)
                Toggle("考试", isOn: $notifications.examEnabled)
                Toggle("培养方案", isOn: $notifications.programEnabled)
            } header: {
                Text("通知类型")
            }

            Section {
                Toggle("后台检查", isOn: $notifications.monitorEnabled)
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
                Button {
                    Task { await runCheckNow() }
                } label: {
                    PortalSettingsRow(
                        icon: PortalRowIcon("arrow.clockwise"),
                        title: "立即检查",
                        subtitle: isChecking ? "正在检查…" : "手动抓取一次并写入日志",
                        showsSpinner: isChecking
                    )
                }
                .buttonStyle(.plain)
                .disabled(isChecking)

                NavigationLink {
                    NoticeHistoryScreen(entries: $entries)
                } label: {
                    PortalSettingsRow(
                        icon: PortalRowIcon("doc.text.magnifyingglass"),
                        title: "检查日志",
                        subtitle: entries.isEmpty ? "暂无记录" : "\(entries.count) 条记录"
                    )
                }
            } header: {
                Text("记录")
            } footer: {
                Text("清空日志在“检查日志”页内进行。")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("变动通知")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: BottomClearance.height)
        }
        .onAppear { entries = PortalPollHistory.load() }
        .onReceive(NotificationCenter.default.publisher(for: PortalPollHistory.didChangeNotification)) { _ in
            entries = PortalPollHistory.load()
        }
    }

    /// The background worker only runs when the system grants it a slot, which on iOS can be
    /// minutes or hours after the switch is turned on. Running it inline gives the log its first
    /// entry immediately and proves the session works, which is what a user opening this page is
    /// actually trying to find out.
    private func runCheckNow() async {
        isChecking = true
        defer { isChecking = false }
        _ = await PortalPollWorker.shared.run(manual: true)
        entries = PortalPollHistory.load()
    }
}

/// Port of `NotificationHistoryActivity.kt`.
struct NoticeHistoryScreen: View {
    @Binding var entries: [PortalPollHistoryEntry]
    /// The list's editing environment, driven by the toolbar's delete button so the platform draws
    /// the red delete control on each row.
    ///
    /// Read through the binding rather than the value, and unwrapped: `\.editMode` is declared as
    /// an optional `Binding<EditMode>?`, so both the comparison and the assignment have to go
    /// through the projection. Reading the value directly fails to type-check, and the resulting
    /// overload-resolution failure is reported several lines away at the `.toolbar` call.
    @Environment(\.editMode) private var editModeBinding
    @State private var expandedEntryIDs: Set<UUID> = []
    @State private var exportURL: URL?

    private var isEditing: Bool { editModeBinding?.wrappedValue == .active }

    var body: some View {
        List {
            if entries.isEmpty {
                // ContentUnavailableView is iOS 17+; the deployment target is 16.
                VStack(spacing: 10) {
                    Image(systemName: "clock")
                        .font(.system(size: 34))
                        .foregroundStyle(PortalPalette.secondaryText)
                    Text("暂无检查记录")
                        .font(.headline)
                    Text("在上方点击“立即检查”即可手动抓取一次。")
                        .font(.footnote)
                        .foregroundStyle(PortalPalette.secondaryText)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 36)
                .listRowSeparator(.hidden)
            }
            ForEach(entries) { entry in
                historyRow(entry)
            }
            .onDelete { indexSet in
                var updated = entries
                updated.remove(atOffsets: indexSet)
                entries = updated
                PortalPollHistory.replace(updated)
                refreshExport()
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("检查日志")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // A trash button rather than `EditButton`. `EditButton` is the system's own way into the
            // list's editing environment, but it labels itself 编辑/完成, so the corner read as
            // "switch to another mode" rather than "get rid of something". The mode itself is still
            // the system's -- driving `editMode` is what puts the platform's red delete control on
            // every row and keeps the swipe-to-delete counterpart -- only the affordance in the
            // corner is spelled as the action it performs.
            //
            // It replaces a filter. The log is short by nature -- one entry per check run, and a
            // background check runs a handful of times a day -- so there was never enough in it to
            // filter; what people actually want to do here is get rid of entries. Clearing the
            // whole log keeps its own button at the bottom, which is the destructive read of "删除"
            // and deserves to stay separate from deleting one row.
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    withAnimation {
                        editModeBinding?.wrappedValue = isEditing ? .inactive : .active
                    }
                } label: {
                    Image(systemName: isEditing ? "checkmark" : "trash")
                }
                .disabled(entries.isEmpty)
                .accessibilityLabel(isEditing ? "完成删除" : "删除记录")
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                if let exportURL {
                    ShareLink(item: exportURL) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("导出 TXT 日志")
                }
            }
        }
        // Clearing lives here rather than on the parent page: it is an operation *on* the log, so
        // it belongs where the log is read. The clearance for the floating bar and the button share
        // one inset, because a view can only have one inset per edge.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Color.clear.frame(height: BottomClearance.height)
                Button(role: .destructive) {
                    entries = []
                    PortalPollHistory.clear()
                    exportURL = nil
                } label: {
                    Text("清空日志")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .disabled(entries.isEmpty)
            }
            .background(PortalPalette.page)
        }
        .onAppear(perform: refreshExport)
        .onReceive(NotificationCenter.default.publisher(for: PortalPollHistory.didChangeNotification)) { _ in
            entries = PortalPollHistory.load()
            refreshExport()
        }
    }

    private func historyRow(_ entry: PortalPollHistoryEntry) -> some View {
        let expanded = expandedEntryIDs.contains(entry.id)
        return Button {
            if expanded { expandedEntryIDs.remove(entry.id) } else { expandedEntryIDs.insert(entry.id) }
        } label: {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.timestamp, format: .dateTime.year().month().day().hour().minute())
                            .font(.subheadline.weight(.semibold))
                        Text(entry.status)
                            .font(.caption)
                            .foregroundStyle(PortalPalette.secondaryText)
                    }
                    Spacer(minLength: 8)
                    Text(entry.notificationTriggered ? "已触发通知" : "未触发通知")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(entry.notificationTriggered ? Color.accentColor : PortalPalette.secondaryText)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(PortalPalette.secondaryText)
                }
                if expanded {
                    Divider()
                    ForEach(entry.details) { detail in
                        detailRow(detail)
                    }
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(expanded ? "双击收起详情" : "双击展开详情")
    }

    private func detailRow(_ detail: PortalPollHistoryDetail) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(detail.category).font(.caption.weight(.semibold))
                Spacer()
                if detail.notificationTriggered { Text("已通知").font(.caption2).foregroundStyle(Color.accentColor) }
            }
            Text("结果：\(detail.summary)").font(.caption)
            Text("检测到变化：\(detail.changed ? "是" : "否")").font(.caption)
            if let enabled = detail.notificationEnabled {
                Text("该项提醒：\(enabled ? "已开启" : "未开启")").font(.caption)
            }
            if let code = detail.responseCode, !(200...299).contains(code) {
                Text("HTTP 状态：\(code)").font(.caption)
            }
            if !detail.difference.isEmpty { Text(detail.difference).font(.caption).foregroundStyle(PortalPalette.secondaryText) }
            if let technical = detail.technicalDetails, !technical.isEmpty { Text(technical).font(.caption2).foregroundStyle(PortalPalette.outline) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func refreshExport() {
        exportURL = PortalPollHistory.exportURL(for: entries)
    }
}

/// Port of `BackgroundSupportActivity.kt`.
///
/// Android's page lists four things that can be wrong with background execution and deep-links
/// into vendor settings to fix each. iOS has exactly one comparable switch -- Low Power Mode,
/// which suspends `BGAppRefreshTask` until it is turned off -- plus the notification authorisation
/// that a persistent notification would need. The internal mechanics differ by platform, which the
/// brief allows; what has to match is that the page exists, is reachable in one tap, and says what
/// state the app is actually in.
struct BackgroundSupportScreen: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var notifications = NotificationPreferences.shared
    @ObservedObject private var localNetwork = LocalNetworkProbe.shared
    @State private var authorisation: UNAuthorizationStatus = .notDetermined
    @State private var lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled

    var body: some View {
        List {
            Section {
                statusRow(
                    icon: PortalRowIcon("network"),
                    title: "本地网络权限",
                    detail: localNetworkDetail,
                    healthy: localNetwork.state.isHealthy
                )
                statusRow(
                    icon: PortalRowIcon("bolt"),
                    title: "低电量模式",
                    detail: lowPowerMode
                        ? "已开启，系统会推迟后台刷新"
                        : "已关闭，后台刷新按请求间隔执行",
                    healthy: !lowPowerMode
                )
                statusRow(
                    icon: PortalRowIcon("bell.badge"),
                    title: "通知权限",
                    detail: authorisationLabel,
                    healthy: authorisation == .authorized || authorisation == .provisional
                )
                statusRow(
                    icon: PortalRowIcon("arrow.triangle.2.circlepath"),
                    title: "后台检查",
                    detail: notifications.monitorEnabled
                        ? "已开启，每 \(notifications.intervalMinutes) 分钟请求一次"
                        : "已关闭",
                    healthy: notifications.monitorEnabled
                )
            } header: {
                Text("系统状态")
            } footer: {
                Text("iOS 不会让应用常驻后台。刷新由系统的 BGTaskScheduler 调度，"
                     + "实际执行时间取决于电量与使用习惯，可在「设置 → 通用 → 后台 App 刷新」中查看本应用的授权。")
            }

            Section {
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    PortalSettingsRow(
                        icon: PortalRowIcon("gearshape"),
                        title: "打开系统设置",
                        subtitle: "调整通知、低电量模式与后台 App 刷新"
                    )
                }
                .buttonStyle(.plain)

                Button {
                    Task { await localNetwork.probe(force: true) }
                } label: {
                    PortalSettingsRow(
                        icon: PortalRowIcon("arrow.clockwise"),
                        title: "重新检测",
                        subtitle: localNetwork.state.label
                    )
                }
                .buttonStyle(.plain)
            } header: {
                Text("操作")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("后台运行")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: BottomClearance.height)
        }
        .onAppear {
            refreshStatus()
            Task { await localNetwork.probe() }
        }
    }

    /// The local-network answer, spelled out. A refused connection is otherwise invisible from the
    /// UI: the load simply never finishes, which looks identical to a broken reader.
    private var localNetworkDetail: String {
        switch localNetwork.state {
        case .unknown: return "尚未检测"
        case .probing: return "正在连接教务服务器…"
        case .allowed: return "已授权，可访问教务系统"
        case .denied: return "未授权，校园网下无法加载教务页面"
        case .unreachable(let reason): return reason
        }
    }

    /// A status row with no chevron: nothing here can be fixed from inside the app except by
    /// leaving for Settings, which the section below already offers.
    private func statusRow(
        icon: PortalRowIcon,
        title: String,
        detail: String,
        healthy: Bool
    ) -> some View {
        HStack(spacing: 12) {
            icon.glyph()
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(healthy ? PortalPalette.secondaryText : PortalPalette.error)
            }
            Spacer(minLength: 8)
        }
        .padding(.vertical, 4)
    }

    private var authorisationLabel: String {
        switch authorisation {
        case .authorized: return "已允许"
        case .provisional: return "已允许（静默通知）"
        case .denied: return "未允许，变动通知不会送达"
        case .ephemeral: return "临时授权"
        case .notDetermined: return "尚未询问"
        @unknown default: return "未知"
        }
    }

    private func refreshStatus() {
        lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let status = settings.authorizationStatus
            Task { @MainActor in authorisation = status }
        }
    }
}

/// Port of `AboutActivity.kt`.
///
/// The content is Android's exactly, in the same order: an identity block, then 项目 (author and
/// repository address), then 开源引用 with the same five entries, the same descriptions and the
/// same licence strings. It is a legal notice as much as a credits page -- the attribution has to
/// match the licences it is claiming -- so the list is copied rather than paraphrased.
///
/// Only the rendering is iOS's: a `List` in the inset-grouped style instead of a LazyColumn of
/// hand-shaped cards, with the logo and the two heading lines as the first group.
struct AboutScreen: View {
    @State private var release: GitHubRelease?

    var body: some View {
        List {
            Section {
                VStack(spacing: 10) {
                    Image(systemName: "building.columns")
                        .font(.system(size: 52, weight: .light))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 120, height: 120)
                        .background(Circle().fill(PortalPalette.surface))
                        .clipShape(Circle())
                    Text("掌上教务")
                        .font(.largeTitle.weight(.bold))
                        .multilineTextAlignment(.center)
                    Text("PalmAcademic · \(appVersion)")
                        .font(.subheadline)
                        .foregroundStyle(PortalPalette.secondaryText)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .listRowBackground(Color.clear)
            }

            Section {
                Link(destination: URL(string: "https://github.com/Genkaim")!) {
                    AboutLinkRow(
                        leading: AnyView(AuthorAvatar()),
                        title: "作者",
                        description: "Genkaim"
                    )
                }
                Link(destination: URL(string: "https://github.com/Genkaim/palm-academic")!) {
                    AboutLinkRow(
                        leading: AnyView(
                            Image(systemName: "chevron.left.forwardslash.chevron.right")
                                .font(.system(size: 22))
                                .foregroundStyle(PortalPalette.onSurface)
                        ),
                        title: "项目地址",
                        description: "github.com/Genkaim/palm-academic"
                    )
                }
            } header: {
                Text("项目")
            }

            Section {
                ForEach(Self.openSourceReferences) { reference in
                    Link(destination: URL(string: reference.url)!) {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(reference.name)
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(PortalPalette.onSurface)
                                Text(reference.description)
                                    .font(.caption)
                                    .foregroundStyle(PortalPalette.secondaryText)
                                Text(reference.license)
                                    .font(.caption)
                                    .foregroundStyle(Color.accentColor)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "arrow.up.right")
                                .font(.footnote)
                                .foregroundStyle(PortalPalette.outline)
                        }
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                }
            } header: {
                Text("开源引用")
            }

            if let release {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("最新版本 \(release.tagName)")
                            .font(.subheadline.weight(.semibold))
                        if let body = release.body, !body.isEmpty {
                            Text(body)
                                .font(.caption)
                                .foregroundStyle(PortalPalette.secondaryText)
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("版本")
                }
            }
        }
        .listStyle(.insetGrouped)
        .background(PortalPalette.page)
        .navigationTitle("关于")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: BottomClearance.height)
        }
        .task { release = try? await GitHubRepository.latestRelease() }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    /// The rows Android's `AboutLinkCard` draws: a leading slot 40pt square, the title and
    /// description, and the open-in-new glyph.
    private func AboutLinkRow(leading: AnyView, title: String, description: String) -> some View {
        HStack(spacing: 14) {
            leading
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(PortalPalette.onSurface)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(PortalPalette.secondaryText)
            }
            Spacer(minLength: 8)
            Image(systemName: "arrow.up.right")
                .font(.footnote)
                .foregroundStyle(PortalPalette.outline)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    /// The author row's avatar. Android ships a 40dp drawable for it; there is no equivalent asset
    /// in the iOS bundle, so the same 40pt circle is drawn with the owner's initial -- the circle is
    /// what carries the layout, not the picture.
    private struct AuthorAvatar: View {
        var body: some View {
            ZStack {
                Circle().fill(
                    LinearGradient(
                        colors: [Color(red: 0.31, green: 0.58, blue: 0.95), Color(red: 0.45, green: 0.36, blue: 0.88)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                Text("G")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 40, height: 40)
            .clipShape(Circle())
        }
    }

    private struct OpenSourceReference: Identifiable {
        let name: String
        let description: String
        let license: String
        let url: String
        var id: String { url }
    }

    /// Copied verbatim from `AboutActivity.kt`. The descriptions say what each dependency is
    /// actually used for in the Android client, which is why two of them name libraries iOS does
    /// not use at all: the notice covers the project, not the current platform's dependency list.
    private static let openSourceReferences: [OpenSourceReference] = [
        OpenSourceReference(
            name: "AndroidX · Jetpack Compose",
            description: "Activity、AppCompat、WebKit、Lifecycle、WorkManager 与 Material 3",
            license: "Apache License 2.0",
            url: "https://developer.android.com/jetpack/androidx"
        ),
        OpenSourceReference(
            name: "OkHttp 4.12.0",
            description: "网络请求与连接管理",
            license: "Apache License 2.0",
            url: "https://github.com/square/okhttp"
        ),
        OpenSourceReference(
            name: "AndroidLiquidGlass · Backdrop 1.0.6",
            description: "液态玻璃、模糊与折射效果",
            license: "Apache License 2.0",
            url: "https://github.com/Kyant0/AndroidLiquidGlass"
        ),
        OpenSourceReference(
            name: "Shapes 1.2.0",
            description: "Compose 图形与胶囊形状支持",
            license: "Apache License 2.0",
            url: "https://github.com/Kyant0/Shapes"
        )
    ]
}
