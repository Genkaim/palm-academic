import SwiftUI

/// Port of `HomeActivity.kt`: the portal home with the four quick entries and grouped sections.
struct HomeView: View {
    @EnvironmentObject private var state: AppState
    @State private var showingSchools = false

    private var definition: SchoolDefinition? { state.definition }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    schoolHeader

                    if let definition {
                        let quick = QuickEntryBaseline.orderedQuickBaselineItems(definition.quickItems)
                        if !quick.isEmpty {
                            quickEntryGrid(quick)
                        }

                        ForEach(definition.groups) { group in
                            groupSection(group)
                        }
                    } else {
                        emptyState("学校配置尚未加载")
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("掌上教务")
            .navigationBarTitleDisplayMode(.inline)
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

    private var schoolHeader: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(state.isDark ? Color.white.opacity(0.1) : Color.blue.opacity(0.1))
                .frame(width: 40, height: 40)
                .overlay(
                    Image(systemName: "building.columns")
                        .foregroundStyle(.tint)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(state.selectedSchool?.name ?? "未选择学校")
                    .font(.headline)
                    .lineLimit(1)
                Text("已登录教务系统")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.top, 8)
    }

    private func quickEntryGrid(_ items: [PortalItem]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("常用入口")
                .font(.headline)
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                spacing: 12
            ) {
                ForEach(items) { item in
                    NavigationLink {
                        MaterialPageScreen(item: item)
                    } label: {
                        quickEntryCard(item)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func quickEntryCard(_ item: PortalItem) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon(for: item.nativeType))
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.tint)
                .frame(height: 26)
            Text(item.title)
                .font(.subheadline.weight(.medium))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(height: 38, alignment: .top)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(state.isDark ? Color.white.opacity(0.07) : Color.white)
                .shadow(color: .black.opacity(state.isDark ? 0.25 : 0.07), radius: 10, y: 4)
        )
    }

    private func icon(for nativeType: String?) -> String {
        switch nativeType {
        case "schedule": return "calendar.day.timeline.leading"
        case "grade": return "chart.bar.doc.horizontal"
        case "exam": return "checkmark.seal"
        case "program": return "list.bullet.clipboard"
        default: return "doc.text"
        }
    }

    private func groupSection(_ group: PortalGroup) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(group.title)
                .font(.headline)
            VStack(spacing: 0) {
                ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
                    NavigationLink {
                        MaterialPageScreen(item: item)
                    } label: {
                        HStack {
                            Image(systemName: "doc.text")
                                .foregroundStyle(.secondary)
                                .frame(width: 24)
                            Text(item.title)
                                .foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 13)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if index < group.items.count - 1 {
                        Divider().padding(.leading, 50)
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(state.isDark ? Color.white.opacity(0.07) : Color.white)
            )
        }
    }

    private func emptyState(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(message)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 50)
    }
}

/// Quick-entry tab: shows the four canonical pages in a single scroll view.
struct QuickEntriesView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let definition = state.definition {
                        let quick = QuickEntryBaseline.orderedQuickBaselineItems(definition.quickItems)
                        ForEach(quick) { item in
                            NavigationLink {
                                MaterialPageScreen(item: item)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "square.grid.2x2")
                                        .foregroundStyle(.tint)
                                    Text(item.title)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(14)
                                .background(
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .fill(state.isDark ? Color.white.opacity(0.07) : Color.white)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    } else {
                        Text("学校配置尚未加载")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                    }
                }
                .padding(18)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("快捷入口")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}