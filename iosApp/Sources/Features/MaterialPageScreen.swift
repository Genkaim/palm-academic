import SwiftUI

/// Port of `MaterialPortalActivity.kt`: renders a `MaterialPage` produced by the shared JS adapter.
struct MaterialPageScreen: View {
    @EnvironmentObject private var state: AppState
    let item: PortalItem

    @State private var page: MaterialPage?
    @State private var errorMessage: String?
    @State private var isLoading = true
    @State private var refreshToken = 0
    @State private var action: MaterialReaderAction?
    @State private var actionToken = 0
    @State private var choiceValues: [String: String] = [:]

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
            Color(.systemGroupedBackground).ignoresSafeArea()

            // The WebView is the data source, so it has to be in the tree before -- and
            // independently of -- anything it feeds. It used to live inside `content(loaded)`, which
            // only renders once `page` is non-nil, and `page` is only ever set by this WebView's
            // callback. On a cold cache that is a circular dependency: the view that produces the
            // data waits for the data, so the page spun forever.
            reader
                .frame(width: 0, height: 0)
                .opacity(0)
                .clipped()

            if isLoading && page == nil {
                ProgressView("加载中…")
            } else if let errorMessage, page == nil {
                errorState(errorMessage)
            } else if let loaded = page {
                content(loaded)
            }
        }
        .navigationTitle(item.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    refreshToken += 1
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("刷新")
            }
        }
        .task {
            if page == nil { await loadCachedThenFetch() }
        }
    }

    /// The hidden reader. It stays mounted for the life of the screen and drives the refresh
    /// token; the rendered page is only a projection of what it publishes.
    private var reader: some View {
        MaterialReaderView(
            url: url,
            adapterScript: adapterScript,
            schoolConfigJSON: SchoolCatalog.shared.readerConfigJSON(),
            refreshToken: refreshToken,
            action: action,
            isDark: state.isDark,
            onLoading: { loading in
                Task { @MainActor in if !loading { isLoading = false } }
            },
            onContent: { newPage in
                Task { @MainActor in
                    page = newPage
                    isLoading = false
                    errorMessage = nil
                }
            },
            onError: { message in
                Task { @MainActor in
                    isLoading = false
                    if page == nil { errorMessage = message }
                }
            },
            onSessionExpired: {
                Task { @MainActor in
                    state.signOut(message: "登录已过期，请重新登录")
                }
            }
        )
    }

    // MARK: - Content

    @ViewBuilder
    // The parameter is deliberately not named `page`: it would shadow the @State
    // property for the whole view body, and the WebView callback assigns to it.
    private func content(_ snapshot: MaterialPage) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if isLoading {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("正在刷新…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                ForEach(snapshot.choices) { choice in
                    choicePicker(choice)
                }

                actionRow(snapshot)

                if snapshot.sections.isEmpty {
                    Text("页面没有可显示的结构化内容")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 30)
                }

                ForEach(snapshot.sections) { section in
                    sectionView(section)
                }
            }
            .padding(18)
        }
        .refreshable {
            refreshToken += 1
            try? await Task.sleep(nanoseconds: 600_000_000)
        }
    }

    private func choicePicker(_ choice: MaterialChoice) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(choice.label)
                .font(.subheadline.weight(.medium))
            Picker(choice.label, selection: Binding(
                get: { choiceValues[choice.id] ?? choice.value },
                set: { newValue in
                    choiceValues[choice.id] = newValue
                    actionToken += 1
                    action = MaterialReaderAction(id: choice.id, value: newValue, token: actionToken)
                }
            )) {
                ForEach(choice.options, id: \.value) { option in
                    Text(option.label).tag(option.value)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(state.isDark ? Color.white.opacity(0.07) : Color.white)
            )
        }
    }

    @ViewBuilder
    private func actionRow(_ page: MaterialPage) -> some View {
        if !page.actions.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(page.actions, id: \.id) { pageAction in
                        Button {
                            actionToken += 1
                            action = MaterialReaderAction(id: pageAction.id, value: pageAction.value, token: actionToken)
                        } label: {
                            Text(pageAction.label)
                                .font(.footnote.weight(.medium))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(
                                    Capsule().fill(Color.accentColor.opacity(0.14))
                                )
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                    }
                }
            }
        }
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

    private func sectionHeader(_ title: String, subtitle: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if !title.isEmpty {
                Text(title).font(.headline)
            }
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func scheduleSection(_ title: String, _ semesterStartDate: String, _ days: [ScheduleDay]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(title, subtitle: semesterStartDate.isEmpty ? nil : "开学日期 \(semesterStartDate)")
            ForEach(days) { day in
                VStack(alignment: .leading, spacing: 8) {
                    Text(day.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.tint)
                    ForEach(day.lessons) { lesson in
                        lessonCard(lesson)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(sectionBackground)
            }
        }
    }

    private func lessonCard(_ lesson: MaterialCardItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(lesson.title)
                .font(.subheadline.weight(.semibold))
            if !lesson.subtitle.isEmpty {
                Text(lesson.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let schedule = lesson.schedule {
                HStack(spacing: 10) {
                    if !schedule.weeks.isEmpty {
                        Label(schedule.weeks, systemImage: "calendar")
                    }
                    if !schedule.location.isEmpty {
                        Label(schedule.location, systemImage: "mappin.and.ellipse")
                    }
                    if !schedule.teacher.isEmpty {
                        Label(schedule.teacher, systemImage: "person")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            if !lesson.fields.isEmpty {
                Divider()
                ForEach(lesson.fields, id: \.label) { field in
                    HStack(alignment: .top) {
                        Text(field.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 76, alignment: .leading)
                        Text(field.value)
                            .font(.caption)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(state.isDark ? Color.white.opacity(0.06) : Color(.systemBackground))
        )
    }

    private func cardSection(_ title: String, _ cards: [MaterialCardItem]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !title.isEmpty { sectionHeader(title) }
            ForEach(cards) { card in
                lessonCard(card)
            }
        }
        .padding(14)
        .background(sectionBackground)
    }

    private func tableSection(_ title: String, _ headers: [String], _ rows: [[String]]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !title.isEmpty { sectionHeader(title) }
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    if !headers.isEmpty {
                        HStack(alignment: .top, spacing: 0) {
                            ForEach(headers, id: \.self) { header in
                                Text(header)
                                    .font(.caption.weight(.semibold))
                                    .frame(minWidth: 84, alignment: .leading)
                            }
                        }
                        .padding(.vertical, 8)
                        .background(Color.accentColor.opacity(0.1))
                    }
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        HStack(alignment: .top, spacing: 0) {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                Text(cell)
                                    .font(.caption)
                                    .frame(minWidth: 84, alignment: .leading)
                            }
                        }
                        .padding(.vertical, 7)
                        .background(Color.clear)
                    }
                }
            }
        }
        .padding(14)
        .background(sectionBackground)
    }

    private func statsSection(_ title: String, _ items: [MaterialStatItem]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !title.isEmpty { sectionHeader(title) }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(items, id: \.label) { item in
                    VStack(spacing: 4) {
                        Text(item.value)
                            .font(.title3.weight(.bold))
                            .foregroundStyle(.tint)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                        Text(item.label)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(state.isDark ? Color.white.opacity(0.06) : Color(.systemBackground))
                    )
                }
            }
        }
        .padding(14)
        .background(sectionBackground)
    }

    private func fieldsSection(_ title: String, _ fields: [(label: String, value: String)]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !title.isEmpty { sectionHeader(title) }
            ForEach(fields, id: \.label) { field in
                HStack(alignment: .top) {
                    Text(field.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 88, alignment: .leading)
                    Text(field.value)
                        .font(.caption)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                }
                if field.label != fields.last?.label {
                    Divider()
                }
            }
        }
        .padding(14)
        .background(sectionBackground)
    }

    private func textSection(_ title: String, _ paragraphs: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !title.isEmpty { sectionHeader(title) }
            ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                Text(paragraph)
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
        .background(sectionBackground)
    }

    private func programSection(_ title: String, _ completed: String, _ required: String, _ modules: [ProgramModule]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if !title.isEmpty { sectionHeader(title) }

            if !completed.isEmpty || !required.isEmpty {
                HStack(spacing: 16) {
                    if !completed.isEmpty {
                        VStack(spacing: 3) {
                            Text(completed)
                                .font(.title2.weight(.bold))
                                .foregroundStyle(.tint)
                            Text("已修学分").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    if !required.isEmpty {
                        VStack(spacing: 3) {
                            Text(required)
                                .font(.title2.weight(.bold))
                            Text("要求学分").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(state.isDark ? Color.white.opacity(0.06) : Color(.systemBackground))
                )
            }

            ForEach(modules) { module in
                AnyView(programModuleView(module, depth: 0))
            }
        }
        .padding(14)
        .background(sectionBackground)
    }

    private func programModuleView(_ module: ProgramModule, depth: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if !module.status.isEmpty {
                    Text(module.status)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.16)))
                        .foregroundStyle(Color.accentColor)
                }
                Text(module.title)
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
            }
            .padding(.leading, CGFloat(depth) * 14)

            if !module.requirements.isEmpty {
                Text(module.requirements.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, CGFloat(depth) * 14)
            }

            if !module.courses.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 4) {
                        if !module.headers.isEmpty {
                            HStack(spacing: 0) {
                                ForEach(module.headers, id: \.self) { header in
                                    Text(header).font(.caption2.weight(.semibold)).frame(minWidth: 78, alignment: .leading)
                                }
                            }
                        }
                        ForEach(Array(module.courses.enumerated()), id: \.offset) { _, row in
                            HStack(spacing: 0) {
                                ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                    Text(cell).font(.caption2).frame(minWidth: 78, alignment: .leading)
                                }
                            }
                        }
                    }
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(state.isDark ? Color.white.opacity(0.05) : Color(.systemBackground))
                    )
                }
                .padding(.leading, CGFloat(depth) * 14)
            }

            // The module tree is recursive, so the return type has to be erased;
            // an opaque `some View` here would be defined in terms of itself.
            ForEach(module.children) { child in
                AnyView(programModuleView(child, depth: depth + 1))
            }
        }
    }

    private func linksSection(_ title: String, _ links: [(title: String, url: String)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !title.isEmpty { sectionHeader(title) }
            ForEach(links, id: \.url) { link in
                Link(destination: URL(string: link.url) ?? URL(string: "about:blank")!) {
                    HStack {
                        Image(systemName: "safari").foregroundStyle(.tint)
                        Text(link.title.isEmpty ? link.url : link.title)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(14)
        .background(sectionBackground)
    }

    private var sectionBackground: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(state.isDark ? Color.white.opacity(0.06) : Color.white)
            .shadow(color: .black.opacity(state.isDark ? 0.22 : 0.06), radius: 10, y: 4)
    }

    // MARK: - Loading

    /// Renders the cached snapshot immediately, then lets the WebView refresh behind it.
    private func loadCachedThenFetch() async {
        if let cached = MaterialPageCache.load(url: url) {
            page = cached
            isLoading = false
        }
        isLoading = true
        refreshToken += 1
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("加载失败")
                .font(.headline)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("重试") {
                refreshToken += 1
                isLoading = true
                errorMessage = nil
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 4)
        }
        .padding(24)
    }
}