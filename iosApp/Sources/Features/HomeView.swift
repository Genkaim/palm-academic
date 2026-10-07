import SwiftUI

/// SF Symbol chosen for a native portal page kind, shared by the home and quick-entry screens.
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
/// The container follows Apple's split for content screens. A `List` is for interacting with a
/// *data set*, and a `Form` is for data entry and preferences — a home screen is neither, it is a
/// content feed of a two-dimensional quick-entry grid plus grouped cards. So this is a
/// `ScrollView`, per "Picking container views for your content".
///
/// Everything inside is a system semantic colour (`secondarySystemGroupedBackground` over
/// `systemGroupedBackground`) and nothing casts a shadow. That is deliberate on two counts: the
/// official cards separate themselves by colour rather than by drop shadow, and semantic colours
/// are what the system re-tints for the iOS 26 material treatment — a hand-painted
/// `Color.white.opacity(0.07)` would not follow it, which is why the previous version had to
/// branch on `state.isDark` for every surface.
struct HomeView: View {
    @EnvironmentObject private var state: AppState
    @State private var showingSchools = false

    private var definition: SchoolDefinition? { state.definition }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    identityCard

                    if let definition {
                        let quick = QuickEntryBaseline.orderedQuickBaselineItems(definition.quickItems)
                        if !quick.isEmpty {
                            quickEntryGrid(quick)
                        }

                        ForEach(definition.groups) { group in
                            groupCard(group)
                        }
                    } else {
                        unloadedCard
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground))
            // A home screen is a content page, so it carries the large title; the inline variant
            // belongs to a pushed detail page.
            .navigationTitle("掌上教务")
            .navigationBarTitleDisplayMode(.large)
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

    // MARK: - Cards

    private var identityCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "building.columns")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 40, height: 40)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(state.selectedSchool?.name ?? "未选择学校")
                    .font(.headline)
                    .lineLimit(1)
                Text("已登录教务系统")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func quickEntryGrid(_ items: [PortalItem]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("常用入口")
                .font(.headline)
                .padding(.leading, 2)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(items) { item in
                    NavigationLink {
                        MaterialPageScreen(item: item)
                    } label: {
                        quickEntryTile(item)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func quickEntryTile(_ item: PortalItem) -> some View {
        VStack(spacing: 10) {
            Image(systemName: PortalIcon.name(for: item.nativeType))
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(height: 28)
            Text(item.title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(height: 40, alignment: .top)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .padding(.horizontal, 8)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func groupCard(_ group: PortalGroup) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(group.title)
                .font(.headline)
                .padding(.leading, 2)

            VStack(spacing: 0) {
                ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
                    NavigationLink {
                        MaterialPageScreen(item: item)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "doc.text")
                                .foregroundStyle(.secondary)
                                .frame(width: 22)
                            Text(item.title)
                                .foregroundStyle(.primary)
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 13)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if index < group.items.count - 1 {
                        Divider().padding(.leading, 50)
                    }
                }
            }
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private var unloadedCard: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
            Text("学校配置尚未加载")
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// Quick-entry tab: the four canonical pages as a card list, matching the home screen's shape.
struct QuickEntriesView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if let definition = state.definition {
                        let quick = QuickEntryBaseline.orderedQuickBaselineItems(definition.quickItems)
                        ForEach(quick) { item in
                            NavigationLink {
                                MaterialPageScreen(item: item)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: PortalIcon.name(for: item.nativeType))
                                        .foregroundStyle(Color.accentColor)
                                        .frame(width: 22)
                                    Text(item.title)
                                        .foregroundStyle(.primary)
                                    Spacer(minLength: 8)
                                    Image(systemName: "chevron.right")
                                        .font(.footnote.weight(.semibold))
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 14)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                    } else {
                        Text("学校配置尚未加载")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("快捷入口")
            .navigationBarTitleDisplayMode(.large)
        }
    }
}
