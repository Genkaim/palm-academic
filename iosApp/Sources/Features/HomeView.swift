import SwiftUI

/// SF Symbol chosen for a native portal page kind, shared by the home and quick-entry lists.
fileprivate enum PortalIcon {
    static func name(for nativeType: String?) -> String {
        switch nativeType {
        case "schedule": return "calendar.day.timeline.leading"
        case "grade": return "chart.bar.doc.horizontal"
        case "exam": return "checkmark.seal"
        case "program": return "list.bullet.clipboard"
        default: return "doc.text"
        }
    }
}

/// Port of `HomeActivity.kt`: the portal home with the four quick entries and grouped sections.
///
/// The layout is a system `List` in `.insetGrouped` rather than a hand-drawn card stack. A grouped
/// list is what every first-party iOS app uses for a sectioned index: UIKit draws the rounded
/// section background, the hairline separators, the header typography and the disclosure
/// indicator, so they track the system appearance and the iOS 26 treatment instead of being
/// re-implemented here and drifting from it. The previous version hand-painted all four at
/// `cornerRadius: 18-20` with its own shadows and dividers.
struct HomeView: View {
    @EnvironmentObject private var state: AppState
    @State private var showingSchools = false

    private var definition: SchoolDefinition? { state.definition }

    var body: some View {
        NavigationStack {
            List {
                schoolSection

                if let definition {
                    let quick = QuickEntryBaseline.orderedQuickBaselineItems(definition.quickItems)
                    if !quick.isEmpty {
                        quickEntrySection(quick)
                    }

                    ForEach(definition.groups) { group in
                        groupSection(group)
                    }
                } else {
                    unloadedSection
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("掌上教务")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button {
                            showingSchools = true
                        } label: {
                            Label("切换学校", systemImage: "building.2")
                        }
                        Button {
                            ThemePreferences.shared.isDark.toggle()
                            state.isDark = ThemePreferences.shared.isDark
                        } label: {
                            Label(
                                state.isDark ? "切换浅色外观" : "切换深色外观",
                                systemImage: state.isDark ? "sun.max" : "moon"
                            )
                        }
                        Divider()
                        Button(role: .destructive) {
                            state.signOut()
                        } label: {
                            Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented: $showingSchools) {
                SchoolPickerView { school in
                    state.selectSchool(school)
                }
            }
        }
    }

    // MARK: - Sections

    private var schoolSection: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: "building.columns")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 32, height: 32)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.accentColor.opacity(0.12))
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.selectedSchool?.name ?? "未选择学校")
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    Text("已登录教务系统")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func quickEntrySection(_ items: [PortalItem]) -> some View {
        Section("常用入口") {
            ForEach(items) { item in
                NavigationLink {
                    MaterialPageScreen(item: item)
                } label: {
                    entryRow(item.title, systemImage: PortalIcon.name(for: item.nativeType), isAccented: true)
                }
            }
        }
    }

    private func groupSection(_ group: PortalGroup) -> some View {
        Section(group.title) {
            ForEach(group.items) { item in
                NavigationLink {
                    MaterialPageScreen(item: item)
                } label: {
                    entryRow(item.title, systemImage: "doc.text", isAccented: false)
                }
            }
        }
    }

    private var unloadedSection: some View {
        Section {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                Text("学校配置尚未加载")
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Label of a navigation row. The disclosure chevron is left to the system: `NavigationLink`
    /// inside a `List` draws the standard one, and a hand-added chevron showed up next to it.
    private func entryRow(_ title: String, systemImage: String, isAccented: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(isAccented ? Color.accentColor : Color.secondary)
                .frame(width: 22)
            Text(title)
        }
    }
}

/// Quick-entry tab: shows the four canonical pages in a single list.
struct QuickEntriesView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        NavigationStack {
            List {
                if let definition = state.definition {
                    let quick = QuickEntryBaseline.orderedQuickBaselineItems(definition.quickItems)
                    Section("常用入口") {
                        ForEach(quick) { item in
                            NavigationLink {
                                MaterialPageScreen(item: item)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: PortalIcon.name(for: item.nativeType))
                                        .foregroundStyle(Color.accentColor)
                                        .frame(width: 22)
                                    Text(item.title)
                                }
                            }
                        }
                    }
                } else {
                    Section {
                        Text("学校配置尚未加载")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("快捷入口")
        }
    }
}
