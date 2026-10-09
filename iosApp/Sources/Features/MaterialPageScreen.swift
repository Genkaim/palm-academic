import SwiftUI

/// Port of `MaterialPortalActivity.kt`: renders a `MaterialPage` produced by the shared JS adapter.
struct MaterialPageScreen: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let item: PortalItem

    /// Cold start is FETCHING, not AUTHENTICATING: the user only reaches this screen through the
    /// signed-in shell, so claiming "尝试登录…" before a single request has even bounced was a
    /// false alarm right after login (matching Android, which shows AUTHENTICATING only while a
    /// central session CHECKING is actually running). `.authenticating` is entered later, and
    /// only by an explicit login-redirect callback.
    @State private var loadState: LoadState = .loading
    @State private var refreshToken = 0
    @State private var action: MaterialReaderAction?
    @State private var actionToken = 0
    @State private var choiceValues: [String: String] = [:]
    /// Exported schedule files, produced once a schedule page has content. Building them lazily in
    /// the menu would mean re-serialising on every tap; they are small and immutable.
    @State private var exports: [ScheduleExport.Format: URL] = [:]
    /// The reader's own account of a load that produced nothing, kept so the watchdog's failure
    /// text can name a cause instead of only reporting that there was one.
    @State private var diagnostic: String?
    /// True while a refresh runs behind already-rendered content. Kept apart from `loadState` so the
    /// cached page stays on screen instead of being replaced by a spinner.
    @State private var isRefreshing = false
    /// Set when the USER explicitly changes a control (semester, rank type). Only such a turn is
    /// allowed to replace rendered data with a genuinely empty page; interim empty publications
    /// during a cold load or a plain refresh are ignored so a DOM skeleton can never flash over
    /// real data.
    @State private var allowsEmpty = false
    /// Which curriculum modules are unfolded. Android keys the default off `depth == 1`, so the
    /// first level opens and everything nested inside it stays shut; a user opening or closing one
    /// is remembered here rather than recomputed from the data on every redraw.
    @State private var expandedPrograms: Set<String> = []
    /// Guards the one-time seeding of `expandedPrograms` from the module tree. Without it a refresh
    /// would re-open everything the user had just closed.
    @State private var programExpansionSeeded = false
    /// Which weekday the timetable is filtered to, or nil for all of them. Android keeps this in
    /// the same state as the rest of the controls so the pill and the list cannot disagree.
    @State private var selectedDay: String?
    /// Only a genuinely cold network result gets an entrance. A cached snapshot is already-known
    /// state and must appear immediately when the destination opens; replaying the entrance on
    /// every visit makes navigation feel slower and visually unstable.
    @State private var animateContentEntrance = false

    /// The six states `MaterialPortalActivity` distinguishes. The previous version collapsed these
    /// into `isLoading` plus an optional error string, which could not tell "the portal is slow"
    /// apart from "the network is gone" -- and Android gives those two different screens, the second
    /// with a retry that re-runs validation rather than the fetch.
    private enum LoadState: Equatable {
        case authenticating
        case unavailable
        case loading
        case loaded
        case failed(String)
        case sessionExpired
    }

    private var page: MaterialPage? {
        if case .loaded = loadState { return renderedPage }
        return nil
    }

    @State private var renderedPage: MaterialPage?

    private var scheduleSection: MaterialSection? {
        renderedPage?.sections.first { if case .schedule = $0 { return true } else { return false } }
    }

    private var url: String {
        let base = state.definition?.baseUrl ?? "\(SchoolCatalog.shared.origin)/student"
        return item.url(baseURL: base)
    }

    private var adapterScript: String {
        guard let asset = state.definition?.readerAdapter else { return "" }
        return SchoolCatalog.shared.readAdapterScript(assetPath: asset)
    }

    var body: some View {
        ZStack {
            PortalPalette.page.ignoresSafeArea()

            // The WebView is the data source, so it has to be in the tree before -- and
            // independently of -- anything it feeds. It used to live inside `content(loaded)`, which
            // only renders once `page` is non-nil, and `page` is only ever set by this WebView's
            // callback. On a cold cache that is a circular dependency: the view that produces the
            // data waits for the data, so the page spun forever.
            //
            // It is laid out at full size rather than collapsed to zero, and made invisible with an
            // alpha instead, because that is what Android does (`Modifier.fillMaxSize().alpha(0.01f)`).
            // A zero-sized WKWebView never lays out its document: WebKit defers the page's first
            // paint, the adapter's bootstrap can run before there is anything to observe, and the
            // result is a load that never produces content. Hit testing is off, so a real frame
            // costs nothing the user can see or touch.
            reader
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .opacity(0.01)
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            switch loadState {
            case .authenticating:
                // A quiet revalidation must not throw away data already on screen: with a rendered
                // page the content stays visible and the toolbar spinner carries the "登录中"
                // signal; only a cold page with nothing to show gets the full-screen status.
                if let loaded = renderedPage {
                    content(loaded)
                        .transition(contentEntranceTransition)
                } else {
                    statusView(icon: "hourglass", title: "尝试登录…", detail: "正在验证教务登录状态")
                        .transition(statusTransition)
                }
            case .unavailable:
                statusView(
                    icon: "wifi.exclamationmark",
                    title: "无法验证教务系统",
                    detail: "网络较慢，或当前网络无法访问教务系统",
                    actionTitle: "重试",
                    action: { Task { await state.revalidateSession() }; loadState = .authenticating }
                )
                .transition(statusTransition)
            case .loading:
                statusView(icon: "arrow.down.doc", title: "正在获取…", detail: item.title)
                    .transition(statusTransition)
            case .failed(let message):
                statusView(icon: "exclamationmark.triangle", title: "加载失败", detail: message) {
                    retry()
                }
                .transition(statusTransition)
            case .sessionExpired:
                statusView(icon: "person.crop.circle.badge.exclamationmark", title: "登录状态已失效", detail: "请重新登录后继续")
                    .transition(statusTransition)
            case .loaded:
                if let loaded = renderedPage {
                    content(loaded)
                        .transition(contentEntranceTransition)
                }
            }
        }
        // A cold result only travels eight points while fading in. The strong ease-out starts
        // immediately and settles gently; cached results disable this transaction entirely.
        .animation(
            reduceMotion ? nil : .timingCurve(0.23, 1, 0.32, 1, duration: 0.24),
            value: loadState
        )
        // Android titles the screen with the page's own heading, which the adapter sets from the
        // portal ("我的成绩", "课程表"). The catalogue name was a reasonable stand-in before the
        // page existed; once it does, using it means the title never matches the content.
        .navigationTitle(page?.title ?? item.title)
        .navigationBarTitleDisplayMode(.inline)
        // Drops the nav bar's opaque chrome so the WebView surface extends behind the status bar
        // and the title floats over the content rather than sitting inside a strip.
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                // The timetable always owns a visible export affordance. Keeping it present while
                // the first snapshot is loading prevents the trailing controls from jumping; it
                // becomes enabled as soon as at least one export file has been produced.
                if item.nativeType == "schedule" {
                    Menu {
                        if exports.isEmpty {
                            Text("课表加载完成后即可导出")
                        } else {
                            ForEach(ScheduleExport.Format.allCases) { format in
                                if let url = exports[format] {
                                    ShareLink(item: url) {
                                        Label(format.displayName, systemImage: format.systemImage)
                                    }
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .disabled(exports.isEmpty)
                    .accessibilityLabel("导出课表")
                }
                Button {
                    retry()
                } label: {
                    // Icon-only, like every other in-app refresh control: a plain bar glyph with no
                    // word and no filled background. A spinner replaces the glyph while a refresh
                    // runs, which also keeps the control tappable to cancel a stuck one.
                    if isRefreshing || loadState == .loading || loadState == .authenticating {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 16, weight: .semibold))
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isRefreshing ? "正在刷新" : "刷新")
            }
        }
        .task {
            if renderedPage == nil { await loadCachedThenFetch() }
        }
        // A successful background revalidation (the trusted-session retry) lands here. The reader
        // was stuck on a stale page or the portal's login redirect, so bump the refresh token to
        // reload against the now-valid session -- without the user having to tap anything.
        .onReceive(NotificationCenter.default.publisher(for: SessionRefreshBus.didRefreshNotification)) { _ in
            // A quiet revalidation just succeeded: this is a plain re-fetch, not a login attempt.
            loadState = renderedPage == nil ? .loading : loadState
            retry()
        }
    }

    /// One of the non-content states, in the shape Android gives each of them.
    private func statusView(
        icon: String,
        title: String,
        detail: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 40)
    }

    private var statusTransition: AnyTransition { .opacity }

    private var contentEntranceTransition: AnyTransition {
        guard animateContentEntrance, !reduceMotion else { return .identity }
        return .opacity.combined(with: .offset(y: 8))
    }

    private func retry() {
        // A refresh over rendered content must keep it on screen (the "刷新中" strip); only a cold
        // retry with nothing rendered goes back to the full-screen loading state. Setting
        // `loadState = .loading` unconditionally used to throw the cached page away on every tap.
        if renderedPage != nil {
            isRefreshing = true
        } else {
            loadState = .loading
        }
        refreshToken += 1
    }

    /// The single gate every adapter publication passes through.
    ///
    /// The adapter publishes continuously while the page builds itself: an empty "暂无…" skeleton
    /// for the grade/exam pages can arrive BEFORE the entry's own XHR has returned the rows. Every
    /// such publication used to replace the screen (and, via the bridge, the cache), which is how a
    /// refresh "把数据刷没" -- the skeleton landed after the real rows. The rules:
    ///
    /// - Cold load with nothing rendered: ignore empties, keep the loading state until real data
    ///   arrives (the watchdog turns a genuinely empty page into a failure/hint).
    /// - Refresh over rendered content: ignore empties, keep the prior data on screen.
    /// - After an explicit user action (semester/排名 control), a genuinely empty result is
    ///   allowed through so picking a semester with nothing in it reads correctly.
    private func accept(_ newPage: MaterialPage) {
        let meaningful = QuickEntryBaseline.hasData(page: newPage, nativeType: item.nativeType)
        if !meaningful {
            if renderedPage == nil { return }
            if !allowsEmpty { return }
        }
        animateContentEntrance = renderedPage == nil
        renderedPage = newPage
        loadState = .loaded
        isRefreshing = false
        allowsEmpty = false
        // Real content rendering is the strongest possible proof the session is alive -- port of
        // Android calling `PortalSessionCoordinator.markAuthenticated()` from `onContent`. Any
        // "登录中" badge or quiet revalidation started by a transient redirect is retired now.
        state.markSessionReady()
        prepareExports(for: newPage)
        prepareProgramExpansion(for: newPage)
    }

    /// The hidden reader. It stays mounted for the life of the screen and drives the refresh
    /// token; the rendered page is only a projection of what it publishes.
    private var reader: some View {
        MaterialReaderView(
            url: url,
            adapterScript: adapterScript,
            schoolConfigJSON: SchoolCatalog.shared.readerConfigJSON(),
            nativeType: item.nativeType,
            refreshToken: refreshToken,
            action: action,
            isDark: state.isDark,
            onLoading: { loading in
                Task { @MainActor in
                    if loading {
                        // A refresh over existing content keeps the page on screen; only a cold
                        // load shows the spinner, which is what Android's FETCHING state means.
                        if renderedPage == nil { loadState = .loading }
                    }
                    // On `false` we deliberately stay put. The reader calls it both for a real
                    // login redirect AND at the end of an ordinary commit on some portal pages;
                    // flipping to AUTHENTICATING on the latter is what flashed "尝试登录…" right
                    // after a successful login. The explicit session-expired callback owns that
                    // transition; content/error callbacks own the others.
                }
            },
            onContent: { newPage, _ in
                Task { @MainActor in
                    accept(newPage)
                }
            },
            onError: { message in
                Task { @MainActor in
                    isRefreshing = false
                    // A refresh that failed over content already on screen keeps it: stale data with
                    // a visible timestamp beats an error page that throws away something usable.
                    if renderedPage == nil { loadState = .failed(message) }
                }
            },
            onSessionExpired: {
                Task { @MainActor in
                    // A trusted session that says "session expired" is almost always a cookie
                    // timeout, not a stolen credential. The reader is dropped back into its
                    // authenticating state and the app kicks off a quiet revalidation; only if
                    // the server keeps saying no for a while does the user get a re-login screen.
                    // The revalidation itself publishes the badge text, so the page only needs to
                    // hand off the trigger and reset its own surface.
                    if state.sessionTrusted {
                        loadState = .authenticating
                        await state.revalidateQuietlyPublic()
                    } else {
                        loadState = .sessionExpired
                        state.signOut(message: "登录已过期，请重新登录")
                    }
                }
            },
            onDiagnostic: { reason in
                // The page's own explanation of why it produced nothing. It arrives while the load
                // state is still "loading", so it is kept apart from the error text and only shown
                // once the watchdog has actually given up -- otherwise a slow-but-fine page would
                // flash a scary message.
                Task { @MainActor in
                    diagnostic = reason
                }
            }
        )
    }

    // MARK: - Content

    /// Android widens its page gutter on a tablet; the phone value is 16.
    private var horizontalInset: CGFloat {
        horizontalSizeClass == .regular ? 32 : 16
    }

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @ViewBuilder
    // The parameter is deliberately not named `page`: it would shadow the @State
    // property for the whole view body, and the WebView callback assigns to it.
    private func content(_ snapshot: MaterialPage) -> some View {
        // Sections with no data of their own are dropped rather than rendered as empty cards:
        // an element must mean there is data behind it. The functional controls panel (choices /
        // day filter / rank buttons) is not data and still shows.
        let visibleSections = snapshot.sections.filter(hasContent)
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Loading is conveyed by the toolbar's rotating refresh glyph, not a strip here:
                // a strip inside the content competes with the page data for attention and reads
                // as "another loading screen" rather than "this page is fine, the fetch is still
                // running".
                controlsPanel(snapshot)

                if visibleSections.isEmpty {
                    Text("暂无数据")
                        .font(.callout)
                        .foregroundStyle(PortalPalette.secondaryText)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 56)
                }

                ForEach(visibleSections) { section in
                    sectionView(section)
                }
            }
            .padding(.horizontal, horizontalInset)
            .padding(.vertical, 16)
        }
        .refreshable {
            retry()
            try? await Task.sleep(nanoseconds: 600_000_000)
        }
        // This screen is pushed inside HomeView's navigation stack, but the shell's floating tab
        // bar is a UIKit sibling above that stack. HomeView's own inset does not propagate through
        // a pushed destination, so every redrawn page must reserve the same clearance itself.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: BottomClearance.height)
        }
    }

    /// Whether a section carries actual data. Used to keep empty shells off screen entirely; an
    /// empty group is not information.
    private func hasContent(_ section: MaterialSection) -> Bool {
        switch section {
        case .schedule(_, _, let days):
            return days.contains { !$0.lessons.isEmpty }
        case .cards(_, let cards):
            return !cards.isEmpty
        case .table(_, let headers, let rows):
            return !headers.isEmpty && !rows.isEmpty
        case .stats(_, let items):
            return items.contains { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty && $0.value != "--" }
        case .fields(_, let fields):
            return fields.contains { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
        case .text(_, let paragraphs):
            return paragraphs.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        case .links(_, let links):
            return !links.isEmpty
        case .program(_, let completed, let required, let modules):
            return !completed.isEmpty || !required.isEmpty || modules.contains { $0.hasData() }
        }
    }

    /// Android `PageControls`.
    ///
    /// Android puts the semester picker, the day filter and the rank-type buttons inside *one*
    /// panel under a "筛选" heading, each with its own small grey label. The iOS version had them as
    /// three loose strips floating between the nav bar and the content, with the picker on its own
    /// rounded card and the action buttons as free-floating tinted capsules -- which is why the
    /// pages did not read as the same app. The order and the grouping are both load-bearing: the
    /// filters belong above the data they filter, inside one surface.
    @ViewBuilder
    private func controlsPanel(_ page: MaterialPage) -> some View {
        let days = page.sections.compactMap { section -> [ScheduleDay]? in
            if case .schedule(_, _, let scheduleDays) = section { return scheduleDays }
            return nil
        }.first ?? []

        if !page.choices.isEmpty || !page.actions.isEmpty || !days.isEmpty {
            PortalGroupStyle.Block(title: "筛选") {
                PortalGroupStyle.Panel(position: .only) {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(page.choices) { choice in
                            VStack(alignment: .leading, spacing: 8) {
                                controlLabel(choice.label)
                                choicePicker(choice)
                            }
                        }

                        if !days.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                controlLabel("显示日期")
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 8) {
                                        choicePill(label: "全部", isOn: selectedDay == nil) {
                                            selectedDay = nil
                                        }
                                        ForEach(days) { day in
                                            choicePill(
                                                label: day.name.replacingOccurrences(of: "星期", with: "周"),
                                                isOn: selectedDay == day.name
                                            ) {
                                                selectedDay = selectedDay == day.name ? nil : day.name
                                            }
                                        }
                                    }
                                    .padding(.vertical, 1)
                                }
                            }
                        }

                        if !page.actions.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                controlLabel("排名类型")
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 8) {
                                        ForEach(page.actions, id: \.id) { pageAction in
                                            Button {
                                                actionToken += 1
                                                // A user-driven result may legitimately be empty,
                                                // so that publication is allowed to replace the
                                                // rows already on screen.
                                                allowsEmpty = true
                                                action = MaterialReaderAction(id: pageAction.id, value: pageAction.value, token: actionToken)
                                            } label: {
                                                Text(pageAction.label)
                                                    .font(.subheadline)
                                                    .foregroundStyle(PortalPalette.onSurface)
                                                    .frame(minHeight: 44)
                                                    .padding(.horizontal, 14)
                                            }
                                            .buttonStyle(.plain)
                                            .background(
                                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                                    .strokeBorder(PortalPalette.outline.opacity(0.42), lineWidth: 1)
                                            )
                                        }
                                    }
                                    .padding(.vertical, 1)
                                }
                            }
                        }
                    }
                    .padding(16)
                }
            }
        }
    }

    /// Android's `labelMedium` / `Medium` sub-label above each control: small, semibold, grey.
    private func controlLabel(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(PortalPalette.secondaryText)
    }

    /// Android `MaterialChoicePill`: 12pt corners, at least 44pt tall, filled `onSurface` when
    /// selected and `surfaceVariant` when not.
    private func choicePill(label: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(isOn ? PortalPalette.onPrimary : PortalPalette.onSurface)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .frame(minHeight: 44)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(isOn ? PortalPalette.onSurface : PortalPalette.surfaceVariant)
                )
        }
        .buttonStyle(.plain)
    }

    /// Android `ChoiceMenu`: a full-width outlined button showing the current selection, with the
    /// disclosure chevron pinned to the trailing edge.
    private func choicePicker(_ choice: MaterialChoice) -> some View {
        Picker(choice.label, selection: Binding(
            get: { choiceValues[choice.id] ?? choice.value },
            set: { newValue in
                choiceValues[choice.id] = newValue
                actionToken += 1
                // A user-driven semester may legitimately be empty; allow that publication through
                // instead of holding the old semester's rows on screen.
                allowsEmpty = true
                action = MaterialReaderAction(id: choice.id, value: newValue, token: actionToken)
            }
        )) {
            ForEach(choice.options, id: \.value) { option in
                Text(option.label).tag(option.value)
            }
        }
        .pickerStyle(.menu)
        .tint(PortalPalette.onSurface)
        .frame(maxWidth: .infinity, minHeight: 48)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(PortalPalette.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(PortalPalette.outline.opacity(0.28), lineWidth: 1)
        )
    }

    // The eight branches each return a different concrete type, and the program
    // branch is recursive, so the result is erased rather than left opaque.
    private func sectionView(_ section: MaterialSection) -> AnyView {
        switch section {
        case .schedule(let title, let semesterStartDate, let days):
            return AnyView(scheduleSection(title, semesterStartDate, days))
        case .cards(let title, let cards):
            return AnyView(cardSection(title, cards))
        case .table(let title, let headers, let rows):
            return AnyView(tableSection(title, headers, rows))
        case .stats(let title, let items):
            return AnyView(statsSection(title, items))
        case .fields(let title, let fields):
            return AnyView(fieldsSection(title, fields))
        case .text(let title, let paragraphs):
            return AnyView(textSection(title, paragraphs))
        case .program(let title, let completed, let required, let modules):
            return AnyView(programSection(title, completed, required, modules))
        case .links(let title, let links):
            return AnyView(linksSection(title, links))
        }
    }

    // MARK: - Schedule

    /// Android `ScheduleSection`.
    ///
    /// Two things here are not optional on Android and were missing here. The day heading carries
    /// the lesson count on the right, and each lesson leads with its time in a fixed 62pt column
    /// divided from the details by a vertical rule. The time had been demoted into a row of icons,
    /// which is both a different visual language and worse at the one job it was doing: telling you
    /// when the class starts.
    ///
    /// The third is the day filter: Android shows every weekday stacked, which on a phone is a very
    /// long scroll to answer "what do I have today", so it narrows to the picked day (or all of
    /// them) and says so when the chosen day is empty rather than showing a blank page.
    private func scheduleSection(_ title: String, _ semesterStartDate: String, _ days: [ScheduleDay]) -> some View {
        let visible = selectedDay.map { name in days.filter { $0.name == name } } ?? days
        let emptyDetail = selectedDay.map { name in
            "\(name.replacingOccurrences(of: "星期", with: "周"))暂无课程"
        } ?? "当前课表暂无课程"

        return PortalGroupStyle.Block(title: title) {
            if visible.allSatisfy({ $0.lessons.isEmpty }) {
                emptyNotice(
                    icon: "calendar",
                    title: "提示",
                    detail: semesterStartDate.isEmpty
                        ? emptyDetail
                        : "\(emptyDetail)（开学日期 \(semesterStartDate)）"
                )
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(visible) { day in
                        scheduleDay(day)
                    }
                }
            }
        }
    }

    /// One day: a heading with the count on the right, then the lessons as a touching group.
    private func scheduleDay(_ day: ScheduleDay) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(day.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PortalPalette.secondaryText)
                Spacer(minLength: 8)
                Text("\(day.lessons.count) 项")
                    .font(.caption2)
                    .foregroundStyle(PortalPalette.secondaryText)
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 5)

            if day.lessons.isEmpty {
                PortalGroupStyle.Panel(position: .only) {
                    Text("本日暂无课程")
                        .font(.callout)
                        .foregroundStyle(PortalPalette.secondaryText)
                        .padding(16)
                }
            } else {
                PortalGroupStyle.Stack {
                    ForEach(Array(day.lessons.enumerated()), id: \.offset) { index, lesson in
                        lessonCard(lesson, position: GroupPosition(index: index, count: day.lessons.count))
                    }
                }
            }
        }
    }

    /// Android `ScheduleLessonCard`: a 62pt time column, a vertical rule, then the details.
    private func lessonCard(_ lesson: MaterialCardItem, position: GroupPosition) -> some View {
        PortalGroupStyle.Panel(position: position) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(PortalGroupStyle.display(lesson.schedule?.startTime ?? ""))
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(PortalPalette.onSurface)
                    Text(lesson.schedule.map { "\($0.endTime.isEmpty ? "" : "至 \($0.endTime)")" } ?? "")
                        .font(.caption2)
                        .foregroundStyle(PortalPalette.secondaryText)
                }
                .frame(width: 62, alignment: .leading)

                Rectangle()
                    .fill(PortalPalette.outlineVariant.opacity(0.62))
                    .frame(width: 0.5)
                    .frame(minHeight: 56)

                VStack(alignment: .leading, spacing: 6) {
                    Text(PortalGroupStyle.display(lesson.title))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(PortalPalette.onSurface)
                    if !lesson.subtitle.isEmpty {
                        Text(lesson.subtitle)
                            .font(.caption)
                            .foregroundStyle(PortalPalette.secondaryText)
                    }
                    // Android joins these into one plain line. Three icon chips said the same thing
                    // in a different visual language, and the icons were decorative rather than
                    // informative.
                    if let schedule = lesson.schedule {
                        let details = [schedule.location, schedule.teacher, schedule.weeks]
                            .filter { !$0.isEmpty }
                            .joined(separator: " · ")
                        if !details.isEmpty {
                            Text(details)
                                .font(.caption)
                                .foregroundStyle(PortalPalette.secondaryText)
                        }
                    }
                    if !lesson.fields.isEmpty {
                        PortalGroupStyle.hairline
                        PortalGroupStyle.InlineFields(
                            fields: lesson.fields.map { (label: $0.label, value: $0.value) }
                        )
                    }
                }
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 13)
        }
    }

    /// Android `CardsSection` -- the `cards` kind, used by the grade page's per-semester cards and
    /// by the exam page's arrangements.
    private func cardSection(_ title: String, _ cards: [MaterialCardItem]) -> some View {
        PortalGroupStyle.Block(title: title) {
            if cards.isEmpty {
                emptyNotice(icon: "tray", title: "", detail: "暂无数据")
            } else {
                PortalGroupStyle.Stack {
                    ForEach(Array(cards.enumerated()), id: \.offset) { index, card in
                        infoCard(card, position: GroupPosition(index: index, count: cards.count))
                    }
                }
            }
        }
    }

    /// Android `MaterialInfoCard`.
    ///
    /// The `accent` is the reason this needed its own renderer: on the grade page it is the score
    /// and on the exam page it is the arrangement's state, and it is the single most looked-at
    /// value on the card. iOS never rendered it at all.
    private func infoCard(_ card: MaterialCardItem, position: GroupPosition) -> some View {
        PortalGroupStyle.Panel(position: position) {
            VStack(alignment: .leading, spacing: 11) {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(card.title.isEmpty ? "未命名项目" : card.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(PortalPalette.onSurface)
                        if !card.subtitle.isEmpty {
                            Text(card.subtitle)
                                .font(.caption)
                                .foregroundStyle(PortalPalette.secondaryText)
                        }
                    }
                    Spacer(minLength: 8)
                    if !card.accent.isEmpty {
                        Text(card.accent)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(PortalPalette.onSurface)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(PortalPalette.surfaceVariant)
                            )
                    }
                }
                // Android drops blank values rather than rendering an empty row, which is what made
                // the iOS cards look padded with nothing.
                let fields = card.fields.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
                if !fields.isEmpty {
                    PortalGroupStyle.hairline
                    PortalGroupStyle.InlineFields(
                        fields: fields.map { (label: $0.label, value: $0.value) }
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 15)
        }
    }

    private func tableSection(_ title: String, _ headers: [String], _ rows: [[String]]) -> some View {
        PortalGroupStyle.Block(title: title) {
            PortalGroupStyle.Table(headers: headers, rows: rows)
        }
    }

    /// Android `StatsSection` -- the grade page's "GPA与排名" strip.
    private func statsSection(_ title: String, _ items: [MaterialStatItem]) -> some View {
        PortalGroupStyle.Block(title: title) {
            PortalGroupStyle.MetricStrip(
                items: items.map { (label: $0.label, value: $0.value) }
            )
        }
    }

    private func fieldsSection(_ title: String, _ fields: [(label: String, value: String)]) -> some View {
        PortalGroupStyle.Block(title: title) {
            PortalGroupStyle.KeyValueCard(fields: fields)
        }
    }

    /// Android `TextCard` -- the plain prose card, used by the exam page's notice.
    private func textSection(_ title: String, _ paragraphs: [String]) -> some View {
        PortalGroupStyle.Block(title: title) {
            PortalGroupStyle.Panel(position: .only) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                        Text(paragraph)
                            .font(.callout)
                            .foregroundStyle(PortalPalette.onSurface)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
                .padding(16)
            }
        }
    }

    /// Android's empty-data card. Rendered as a panel so a section that has nothing still occupies
    /// its slot with something deliberate rather than collapsing to a bare heading.
    private func emptyNotice(icon: String, title: String, detail: String) -> some View {
        PortalGroupStyle.Panel(position: .only) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundStyle(PortalPalette.secondaryText)
                VStack(alignment: .leading, spacing: 2) {
                    if !title.isEmpty {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(PortalPalette.onSurface)
                    }
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(PortalPalette.secondaryText)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
        }
    }

    /// Android `ProgramSection`, which is really two blocks: a credit-progress panel and the
    /// module tree. They were merged into one card here, which lost the progress bar entirely --
    /// the numbers were there but the one thing that answers "how far along am I" was not.
    private func programSection(_ title: String, _ completed: String, _ required: String, _ modules: [ProgramModule]) -> some View {
        let completedValue = CGFloat(Double(completed) ?? 0)
        let requiredValue = CGFloat(Double(required) ?? 0)
        let progress = requiredValue > 0 ? min(max(completedValue / requiredValue, 0), 1) : 0

        return PortalGroupStyle.Block(title: nil) {
            VStack(alignment: .leading, spacing: 24) {
                PortalGroupStyle.Block(title: "学分进度") {
                    PortalGroupStyle.Panel(position: .only) {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(alignment: .bottom) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("已完成学分")
                                        .font(.subheadline)
                                        .foregroundStyle(PortalPalette.secondaryText)
                                    Text(PortalGroupStyle.display(completed))
                                        .font(.title2.weight(.bold))
                                        .foregroundStyle(PortalPalette.onSurface)
                                }
                                Spacer(minLength: 8)
                                Text("要求 \(PortalGroupStyle.display(required))")
                                    .font(.subheadline)
                                    .foregroundStyle(PortalPalette.secondaryText)
                                    .padding(.bottom, 4)
                            }

                            // Android's `LinearProgressIndicator`: 7dp tall, 4dp corners, filled in
                            // `onSurface` over a `surfaceVariant` track. The track stays visible at
                            // 0% because "no progress yet" and "no requirement known" read the same
                            // otherwise.
                            GeometryReader { geometry in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(PortalPalette.surfaceVariant)
                                    Capsule()
                                        .fill(PortalPalette.onSurface)
                                        .frame(width: max(7, geometry.size.width * progress))
                                }
                            }
                            .frame(height: 7)

                            Text(requiredValue > 0
                                 ? "已完成 \(Int(progress * 100))%"
                                 : "正在读取培养方案要求")
                                .font(.footnote)
                                .foregroundStyle(PortalPalette.secondaryText)
                        }
                        .padding(18)
                    }
                }

                PortalGroupStyle.Block(title: title.isEmpty ? "培养方案" : title) {
                    PortalGroupStyle.Stack {
                        ForEach(Array(modules.enumerated()), id: \.offset) { index, module in
                            programModuleView(module, position: GroupPosition(index: index, count: modules.count))
                        }
                    }
                }
            }
        }
    }

    /// Android `ProgramModuleCard`: a collapsible panel whose header is the whole tap target, and
    /// which is open by default only at the first level (`depth == 1`). Nested modules carry a hair
    /// border because they sit on a panel background rather than the page.
    private func programModuleView(_ module: ProgramModule, position: GroupPosition) -> AnyView {
        let isOpen = expandedPrograms.contains(module.id)

        return AnyView(
            PortalGroupStyle.Panel(position: position, isNested: module.depth > 1) {
                VStack(alignment: .leading, spacing: 0) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            if expandedPrograms.contains(module.id) {
                                expandedPrograms.remove(module.id)
                            } else {
                                expandedPrograms.insert(module.id)
                            }
                        }
                    } label: {
                        HStack(alignment: .center, spacing: 12) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(module.title)
                                    .font(.headline)
                                    .foregroundStyle(PortalPalette.onSurface)
                                    .multilineTextAlignment(.leading)
                                // Android renders each requirement on its own line rather than
                                // joining them with a separator, so a two-requirement module does
                                // not collapse into one unreadable run-on.
                                ForEach(Array(module.requirements.enumerated()), id: \.offset) { _, requirement in
                                    Text(requirement)
                                        .font(.footnote)
                                        .foregroundStyle(PortalPalette.secondaryText)
                                        .multilineTextAlignment(.leading)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                if !module.status.isEmpty {
                                    Text(Self.programStatusLabel(module.status))
                                        .font(.caption)
                                        .foregroundStyle(PortalPalette.secondaryText)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(
                                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                .fill(PortalPalette.surfaceVariant)
                                        )
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(PortalPalette.secondaryText)
                        }
                        .padding(.horizontal, 15)
                        .padding(.vertical, 13)
                        .frame(minHeight: 58, alignment: .center)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if isOpen {
                        if !module.courses.isEmpty {
                            PortalGroupStyle.hairline
                            ScrollView(.horizontal, showsIndicators: false) {
                                VStack(alignment: .leading, spacing: 0) {
                                    if !module.headers.isEmpty {
                                        PortalGroupStyle.Table.Row(cells: module.headers, isHeader: true)
                                    }
                                    ForEach(Array(module.courses.enumerated()), id: \.offset) { index, row in
                                        PortalGroupStyle.Table.Row(cells: row, isHeader: false, isAlternate: index.isMultiple(of: 2) == false)
                                    }
                                }
                                .padding(.vertical, 6)
                            }
                        }
                        if !module.children.isEmpty {
                            VStack(spacing: 3) {
                                ForEach(Array(module.children.enumerated()), id: \.offset) { index, child in
                                    programModuleView(child, position: GroupPosition(index: index, count: module.children.count))
                                }
                            }
                            .padding(.leading, 12)
                            .padding(.trailing, 8)
                            .padding(.bottom, 10)
                        }
                    }
                }
            }
        )
    }

    /// Android maps the raw status codes to words before display; a bare `PASSED` in a Chinese
    /// interface is a leaked enum.
    private static func programStatusLabel(_ status: String) -> String {
        switch status {
        case "PASSED": return "已完成"
        case "FAILED": return "未完成"
        default: return status
        }
    }

    /// Android `LinkCard`: a touching group of chevron rows. There is no URL text and no external-link
    /// glyph -- the row's whole surface is the target and the chevron is the only affordance.
    private func linksSection(_ title: String, _ links: [(title: String, url: String)]) -> some View {
        PortalGroupStyle.Block(title: title) {
            if links.isEmpty {
                emptyNotice(icon: "link", title: "提示", detail: "暂无数据")
            } else {
                PortalGroupStyle.Stack {
                    ForEach(Array(links.enumerated()), id: \.offset) { index, link in
                        let position = GroupPosition(index: index, count: links.count)
                        if let target = URL(string: link.url), !link.url.isEmpty {
                            Link(destination: target) {
                                linkRow(link.title.isEmpty ? link.url : link.title, position: position)
                            }
                            .buttonStyle(.plain)
                        } else {
                            linkRow(link.title.isEmpty ? link.url : link.title, position: position)
                        }
                    }
                }
            }
        }
    }

    private func linkRow(_ text: String, position: GroupPosition) -> some View {
        PortalGroupStyle.Panel(position: position) {
            HStack(spacing: 8) {
                Text(text)
                    .font(.body.weight(.medium))
                    .foregroundStyle(PortalPalette.onSurface)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(PortalPalette.secondaryText)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 15)
            .contentShape(Rectangle())
        }
    }

    // MARK: - Loading

    /// Renders the cached snapshot immediately, then lets the WebView refresh behind it.
    ///
    /// The cache is what makes a second visit feel instant, and the refresh is what keeps it honest
    /// -- a page that only ever read the cache would show last term's timetable indefinitely. The
    /// refresh is unconditional, so entering a page always re-reads the portal; the cache only
    /// decides what is on screen while that request is in flight.
    private func loadCachedThenFetch() async {
        // Only a genuinely meaningful snapshot is shown instantly. Older builds cached interim
        // "暂无…" skeletons; reviving those would reopen the page on empty chrome.
        if let cached = MaterialPageCache.load(url: url),
           QuickEntryBaseline.hasData(page: cached, nativeType: item.nativeType) {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                animateContentEntrance = false
                renderedPage = cached
                loadState = .loaded
            }
            prepareExports(for: cached)
            prepareProgramExpansion(for: cached)
            // Distinguish "showing what we had" from "fetching", so a slow network does not look
            // like a blank page and the refresh is visible rather than silent. The fetch below is
            // the reader's own mount-time load; it runs behind this content.
            isRefreshing = true
        } else {
            // Only a genuinely cold visit shows the full-screen loading state.
            loadState = .loading
        }
        // NO `refreshToken += 1` here. Mounting the reader already performs one fresh network load
        // (MaterialReaderView starts it after the cookie restore), so a bump here immediately
        // reloaded the entry document and cancelled its follow-up XHR -- the grade and exam pages
        // render their rows from that XHR, so the bump is exactly what emptied them.
        // A watchdog. A portal that answers with a login redirect, a JS error or an empty shell
        // never calls back, and a spinner that never resolves is indistinguishable from "still
        // working". After this long without content the page says so and offers a retry, which is
        // what turns an undebuggable hang into a reportable state.
        try? await Task.sleep(nanoseconds: 40_000_000_000)
        guard !Task.isCancelled else { return }
        if renderedPage != nil {
            // A cached snapshot is on screen and the fresh fetch never produced data: end the
            // refresh strip but keep the cached content -- and, since only meaningful pages are
            // cached, what stays is real data rather than a skeleton.
            isRefreshing = false
            return
        }
        // The load's own finish flips .loading into .authenticating, so a watchdog that only
        // checked .loading never fired and a data-less page sat on "尝试登录…" forever. Both are
        // unresolved states; either must be able to reach the failure screen.
        guard loadState == .loading || loadState == .authenticating else { return }
        // The page's own account of what went wrong comes first; the local-network answer comes
        // next, because a refused private-address connection is invisible from the load's own
        // report and would otherwise be indistinguishable from a broken reader.
        var reason = diagnostic ?? "页面在 40 秒内没有返回数据，可能是教务会话已失效或该页面需要网页端交互。"
        if diagnostic == nil, !LocalNetworkProbe.shared.state.isHealthy {
            reason += "\n本地网络：\(LocalNetworkProbe.shared.state.label)"
        }
        loadState = .failed(reason)
    }

    /// Opens the first level of the curriculum tree once, matching Android's `depth == 1` default.
    ///
    /// Android seeds this per module with `remember(module.id)`, which survives redraws but not a
    /// reload; here it is seeded once per page load and then owned by the user, so a refresh does not
    /// undo a collapse. Only the first level opens -- the nested modules are the detail, and opening
    /// all of them would turn a curriculum page into an unscrollable wall.
    private func prepareProgramExpansion(for page: MaterialPage) {
        guard !programExpansionSeeded else { return }
        programExpansionSeeded = true

        var seeds: Set<String> = []
        func walk(_ modules: [ProgramModule]) {
            for module in modules {
                if module.depth == 1 { seeds.insert(module.id) }
                walk(module.children)
            }
        }
        for section in page.sections {
            if case .program(_, _, _, let modules) = section {
                walk(modules)
            }
        }
        expandedPrograms = seeds
    }

    /// Writes the three export formats once a schedule page has content, so the share menu can hand
    /// out files instead of re-serialising on every tap.
    private func prepareExports(for page: MaterialPage) {
        guard case .schedule(let semester, let semesterStart, let days) = scheduleSection else {
            exports = [:]
            return
        }
        let profile = state.selectedSchool?.fallbackUnitTimes ?? [:]
        guard days.contains(where: { !$0.lessons.isEmpty }) else {
            exports = [:]
            return
        }
        let schoolID = SchoolCatalog.shared.selectedSchoolID
        var produced: [ScheduleExport.Format: URL] = [:]
        for format in ScheduleExport.Format.allCases {
            if let url = ScheduleExport.write(
                format,
                semester: semester,
                semesterStartDate: semesterStart,
                days: days,
                unitTimes: profile,
                schoolID: schoolID
            ) {
                produced[format] = url
            }
        }
        exports = produced
    }

}
