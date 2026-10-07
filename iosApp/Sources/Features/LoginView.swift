import SwiftUI

/// Port of `LoginScreen.kt`.
///
/// Android has two distinct screens rather than one screen with a hidden form: with no school
/// chosen the page is nothing but the brand block and one button pinned to the bottom, and the
/// credential fields do not exist in the hierarchy at all. Once a school is chosen the form appears
/// above a bottom area that stacks the school row, a gap and the web-login row, with the primary
/// button sitting below all of it. The content padding differs to match (64/112 unselected,
/// 24/218 selected) and the brand block collapses when the keyboard is up.
///
/// Appearance and controls are iOS's. The fields are SwiftUI's own `TextField` and `SecureField` in
/// the plain style, sitting on the grouped surface, so they carry the caret, the autofill chrome,
/// the clear button and the keyboard handling without a hosted control. A `UIViewRepresentable`
/// `UITextField` was the previous answer and it could not keep a focus mirror honest: the username
/// field passed a constant `false` for it, so `updateUIView` saw "not focused, but first responder"
/// and resigned in the same pass -- the keyboard came up and went straight back down, which reads
/// as "tapping the field does nothing". `@FocusState` cannot be wrong that way.
///
/// The field group's shape is the Android one -- 14pt outer, 6pt where the two meet -- written as
/// a background per field rather than as a shape on the control, because `UnevenRoundedRectangle`
/// is iOS 16.4 and the deployment target is 16.0.
struct LoginView: View {
    @EnvironmentObject private var state: AppState
    @State private var showingSchools = false
    @State private var revealPassword = false
    /// Which field the keyboard belongs to. `@FocusState` is the system's own focus owner, so a tap
    /// needs no extra work to raise the keyboard and "next" moves straight to the password.
    @FocusState private var focusedField: Field?
    /// Height of the software keyboard in points; 0 while it is dismissed.
    @State private var keyboardHeight: CGFloat = 0
    /// Token handles for the keyboard frame notifications registered in `observeKeyboard`.
    @State private var keyboardObservers: [NSObjectProtocol] = []

    private enum Field: Hashable {
        case username
        case password
    }

    private enum Metric {
        static let horizontal: CGFloat = 20
        static let fieldHeight: CGFloat = 50
        static let primaryButtonHeight: CGFloat = 54
        static let secondaryButtonHeight: CGFloat = 52
        /// The gap between the school row and the web-login row, which exists to clear the
        /// primary button pinned below them.
        static let secondaryGap: CGFloat = 54
        static let brandHeight: CGFloat = 172
        /// The outer radius of the joined field group, matching Android's 18pt at the system's
        /// slightly tighter 14pt.
        static let fieldGroupRadius: CGFloat = 14
        static let fieldGroupInnerRadius: CGFloat = 6
    }

    private var hasSchool: Bool { state.selectedSchool != nil }
    private var brandVisible: Bool { keyboardHeight == 0 }

    var body: some View {
        ZStack {
            // Android paints `MaterialTheme.colorScheme.background`, which is #F2F2F7 light and
            // #000000 dark. `systemGroupedBackground` is exactly those two values, so the page
            // follows the appearance without a single hand-picked colour.
            PortalPalette.page.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 18) {
                    // The brand block collapses by height rather than being removed from the tree.
                    // Removing it -- which is what an `if` around the whole block does -- rebuilds
                    // the fields' container the moment the keyboard appears, and `@FocusState`
                    // cannot survive that: the field comes back unfocused, the keyboard is already
                    // on its way down, and the next tap has to start over. That is the "tapping the
                    // field twice" symptom.
                    brand
                        .frame(height: brandVisible ? Metric.brandHeight : 0)
                        .clipped()
                        .opacity(brandVisible ? 1 : 0)
                    if hasSchool {
                        credentialForm
                    }
                }
                .padding(.horizontal, Metric.horizontal)
                // The two Android content paddings, which are what make the unselected screen feel
                // like a different screen rather than the same one with a hidden form. The selected
                // padding shrinks while the keyboard is up so the fields stay reachable without the
                // bottom area having to lift the whole page.
                .padding(.top, hasSchool ? 24 : 64)
                .padding(.bottom, hasSchool ? (keyboardHeight > 0 ? 24 : 218) : 112)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollDisabled(keyboardHeight > 0)
        }
        // The bottom area is an overlay rather than a safe-area inset. An inset is lifted by the
        // keyboard as a unit, which drags the school row and the web-login row up with it; Android
        // only moves the primary action and fades the other two, and that is what happens here.
        .overlay(alignment: .bottom) { bottomArea }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .sheet(isPresented: $showingSchools) {
            SchoolPickerView { school in
                state.selectSchool(school)
            }
            .environmentObject(state)
        }
        .fullScreenCover(isPresented: $state.showingWebLogin) {
            WebLoginView()
                .environmentObject(state)
        }
        .animation(.easeInOut(duration: 0.25), value: hasSchool)
        .animation(.easeOut(duration: 0.22), value: keyboardHeight > 0)
        .onAppear {
            NotificationPreferences.shared.clearAuthenticationFailureMarker()
            observeKeyboard()
            Task {
                let granted = await NotificationPreferences.shared.requestAuthorization()
                _ = granted
            }
        }
        .onDisappear { stopObservingKeyboard() }
    }

    // MARK: - Blocks

    private var brand: some View {
        VStack(spacing: 12) {
            Image(systemName: "building.columns")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(PortalPalette.onSurface)
            Text("掌上教务")
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(PortalPalette.onSurface)
        }
        .frame(maxWidth: .infinity)
        .frame(height: Metric.brandHeight)
        .clipped()
    }

    private var credentialForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            formLabel("密码登录")
            VStack(spacing: 0) {
                usernameField
                    .background(
                        GroupedCardShape(
                            large: Metric.fieldGroupRadius,
                            small: Metric.fieldGroupInnerRadius,
                            position: .first
                        )
                        .fill(PortalPalette.surface)
                    )
                Divider()
                    .padding(.leading, 34)
                passwordField
                    .background(
                        GroupedCardShape(
                            large: Metric.fieldGroupRadius,
                            small: Metric.fieldGroupInnerRadius,
                            position: .last
                        )
                        .fill(PortalPalette.surface)
                    )
            }
            rememberRow
            if let errorMessage = state.errorMessage {
                errorBanner(errorMessage)
            }
        }
    }

    private var bottomArea: some View {
        VStack(spacing: 0) {
            if hasSchool {
                // Android's secondary actions fade as the keyboard arrives
                // (`secondaryActionAlpha = 1 - imeProgress * 2`) and do not move. They stay pinned
                // to the bottom while the primary button rides above the keyboard.
                VStack(spacing: 10) {
                    secondaryButton(
                        systemImage: "building.columns",
                        title: state.selectedSchool?.name ?? "选择学校",
                        showsChevron: true
                    ) { showingSchools = true }
                    // The gap is not decorative: it clears the primary button pinned below.
                    Color.clear.frame(height: Metric.secondaryGap)
                    secondaryButton(systemImage: "safari", title: "用网页登录", showsChevron: false) {
                        focusedField = nil
                        state.showingWebLogin = true
                    }
                }
                .opacity(secondaryOpacity)
                .allowsHitTesting(keyboardHeight == 0)
                .padding(.bottom, 20 + Metric.primaryButtonHeight)

                // Only this one follows the keyboard. It is a system prominent button tinted to
                // Android's `primary` token, so it keeps the system's own corner radius, press
                // animation and disabled appearance instead of a hand-drawn capsule.
                Button {
                    focusedField = nil
                    Task { await state.login() }
                } label: {
                    HStack(spacing: 8) {
                        if state.isLoading {
                            ProgressView()
                        } else {
                            Image(systemName: "lock")
                        }
                        Text(state.isLoading ? "登录中…" : "登录")
                            .font(.body.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: Metric.primaryButtonHeight - 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(PortalPalette.primary)
                .foregroundStyle(PortalPalette.plainSurface)
                .controlSize(.large)
                .disabled(!canSubmit || state.isLoading)
                .offset(y: -primaryLift)
            } else {
                schoolSelectionPrompt
                    .padding(.bottom, 20)
            }
        }
        .padding(.horizontal, Metric.horizontal)
        .padding(.bottom, 20)
    }

    /// How far the keyboard has risen, 0...1. Android derives this the same way, from the IME inset
    /// against the navigation bar inset.
    private var keyboardProgress: CGFloat {
        guard keyboardHeight > 0 else { return 0 }
        let screenHeight = UIScreen.main.bounds.height
        guard screenHeight > 0 else { return 1 }
        return min(max(keyboardHeight / (screenHeight * 0.45), 0), 1)
    }

    /// The secondary actions are gone by the time the keyboard is half up.
    private var secondaryOpacity: Double { max(0, 1 - Double(keyboardProgress) * 2) }

    /// The primary button's travel. It clears the secondary block -- two 52pt rows, a 10pt gap and
    /// the 20pt of padding -- and then follows the keyboard the rest of the way.
    private var primaryLift: CGFloat {
        keyboardProgress * (Metric.secondaryGap + Metric.secondaryButtonHeight * 2 + 24)
    }

    /// The unselected screen's only affordance: a line of copy and one full-width button.
    private var schoolSelectionPrompt: some View {
        VStack(spacing: 12) {
            Text("选择学校以继续登录")
                .font(.subheadline)
                .foregroundStyle(PortalPalette.secondaryText)
            Button {
                showingSchools = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "building.columns")
                    Text("选择学校")
                        .font(.body.weight(.semibold))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity)
                .frame(height: Metric.primaryButtonHeight - 8)
            }
            // The system prominent button, tinted to Android's `primary` token so the page keeps
            // the client's colour while the control itself is the platform's.
            .buttonStyle(.borderedProminent)
            .tint(PortalPalette.primary)
            .foregroundStyle(PortalPalette.plainSurface)
            .controlSize(.large)
            .disabled(state.isLoading)
        }
    }

    /// The outlined counterpart Android builds with `OutlinedButton` and a pill shape.
    ///
    /// Rendered with the system bordered style so the corner radius, the press state and the
    /// disabled appearance are the platform's.
    private func secondaryButton(
        systemImage: String,
        title: String,
        showsChevron: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                Text(title)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                }
            }
            .font(.body)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity)
            .frame(height: Metric.secondaryButtonHeight - 6)
        }
        .buttonStyle(.bordered)
        .tint(PortalPalette.outline.opacity(0.8))
        .foregroundStyle(PortalPalette.onSurface)
        .controlSize(.large)
        .disabled(state.isLoading)
    }

    private var rememberRow: some View {
        Button {
            state.rememberPassword.toggle()
            if !state.rememberPassword {
                CredentialStore.clear(schoolID: SchoolCatalog.shared.selectedSchoolID)
            }
        } label: {
            HStack {
                Text("记住密码")
                    .font(.body.weight(.medium))
                    .foregroundStyle(PortalPalette.onSurface)
                Spacer()
                // The system's own switch, at the system's own size.
                Toggle("", isOn: $state.rememberPassword)
                    .labelsHidden()
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .background(Capsule().fill(PortalPalette.surface))
        }
        .buttonStyle(.plain)
        .frame(height: 48)
        .disabled(state.isLoading)
    }

    private func formLabel(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(PortalPalette.secondaryText)
            .padding(.horizontal, 8)
            .padding(.bottom, -6)
    }

    // MARK: - Keyboard avoidance

    private func observeKeyboard() {
        keyboardObservers = [
            NotificationCenter.default.addObserver(
                forName: UIResponder.keyboardWillChangeFrameNotification,
                object: nil,
                queue: .main
            ) { notification in
                guard let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey]
                        as? CGRect,
                      let screen = notification.object as? UIScreen else { return }
                let overlap = screen.bounds.maxY - frame.minY
                keyboardHeight = overlap > 0 ? overlap : 0
            },
            NotificationCenter.default.addObserver(
                forName: UIResponder.keyboardWillHideNotification,
                object: nil,
                queue: .main
            ) { _ in
                keyboardHeight = 0
            }
        ]
    }

    private func stopObservingKeyboard() {
        keyboardObservers.forEach(NotificationCenter.default.removeObserver)
        keyboardObservers = []
    }

    // MARK: - Fields

    /// The username field. SwiftUI's own `TextField` is the control Apple's sign-in screens use;
    /// `@FocusState` owns the keyboard, so a tap raises it and "next" moves to the password without
    /// either view having to mirror anything.
    private var usernameField: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.crop.circle")
                .foregroundStyle(PortalPalette.secondaryText)
                .frame(width: 22)
            TextField("学号 / 账号", text: $state.username)
                .textContentType(.username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.next)
                .focused($focusedField, equals: .username)
                .onSubmit { focusedField = .password }
                .disabled(state.isLoading)
        }
        .padding(.horizontal, 12)
        .frame(height: Metric.fieldHeight)
    }

    /// The password field. `SecureField` and `TextField` are separate types rather than one control
    /// with a flag, so the reveal toggle swaps them; the text lives in `AppState` either way, which
    /// is what makes the swap invisible to the user.
    @ViewBuilder
    private var passwordField: some View {
        HStack(spacing: 8) {
            Image(systemName: "key")
                .foregroundStyle(PortalPalette.secondaryText)
                .frame(width: 22)
            if revealPassword {
                TextField("密码", text: $state.password)
                    .textContentType(.password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .focused($focusedField, equals: .password)
                    .onSubmit { submit() }
            } else {
                SecureField("密码", text: $state.password)
                    .textContentType(.password)
                    .submitLabel(.go)
                    .focused($focusedField, equals: .password)
                    .onSubmit { submit() }
            }
            if !state.isLoading {
                Button {
                    revealPassword.toggle()
                } label: {
                    Image(systemName: revealPassword ? "eye.slash" : "eye")
                        .foregroundStyle(PortalPalette.secondaryText)
                }
                .buttonStyle(.plain)
                .frame(width: 34, height: 44)
                .contentShape(Rectangle())
                .accessibilityLabel(revealPassword ? "隐藏密码" : "显示密码")
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(height: Metric.fieldHeight)
        .disabled(state.isLoading)
    }

    private func submit() {
        guard canSubmit else { return }
        focusedField = nil
        Task { await state.login() }
    }

    private var canSubmit: Bool {
        !state.isLoading
            && !state.username.trimmingCharacters(in: .whitespaces).isEmpty
            && !state.password.isEmpty
    }

    private func errorBanner(_ message: String) -> some View {
        Text(message)
            .font(.subheadline)
            .foregroundStyle(PortalPalette.error)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(PortalPalette.errorContainer)
            )
    }
}

/// Port of `SchoolSelectionUi.kt`.
///
/// Picking one value out of a set is what `List(selection:)` exists for, so the tick is the
/// system's rather than a hand-drawn one that could drift from the selection. On top of that the
/// Android layout is reproduced: pinyin-initial sections, the school's id under its name, a
/// refresh action in the navigation bar, and the adapter-guide link at the bottom.
///
/// A name shows semibold when it is the active one, which is why the row reads the selection
/// rather than relying on the system's selection background alone.
struct SchoolPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var state: AppState
    @State private var selection: String?
    @State private var isRefreshing = false
    @State private var statusMessage: String?
    let onSelect: (SchoolProfile) -> Void

    @MainActor
    init(onSelect: @escaping (SchoolProfile) -> Void) {
        self.onSelect = onSelect
        // Seed from the active profile so the row the user is on is already ticked on open.
        _selection = State(initialValue: SchoolCatalog.shared.selectedSchoolID)
    }

    @MainActor
    private var schools: [SchoolProfile] { SchoolCatalog.shared.options }

    @MainActor
    private var sections: [(key: String, items: [SchoolProfile])] {
        let buckets = Dictionary(grouping: schools) { PinyinGrouping.key(for: $0.name) }
        return buckets.keys
            .sorted(by: PinyinGrouping.isOrderedBefore)
            .map { key in
                (key: key, items: buckets[key, default: []].sorted { $0.name < $1.name })
            }
    }

    private static let guideURL = URL(string: "https://github.com/Genkaim/palm-academic/blob/main/docs/ADAPTER_GUIDE.md")!

    var body: some View {
        NavigationStack {
            List(selection: $selection) {
                ForEach(sections, id: \.key) { section in
                    Section {
                        ForEach(section.items) { school in
                            row(for: school)
                        }
                    } header: {
                        Text(section.key)
                    }
                }

                Section {
                    Link(destination: Self.guideURL) {
                        Text("没有找到你的学校？查看适配指引")
                            .foregroundStyle(Color.accentColor)
                    }
                } footer: {
                    if let statusMessage {
                        Text(statusMessage)
                    }
                }
            }
            .navigationTitle("选择学校")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Task { await refresh() }
                    } label: {
                        if isRefreshing {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("刷新")
                        }
                    }
                    .disabled(isRefreshing)
                }
            }
            .onChange(of: selection) { newValue in
                guard let newValue, let school = schools.first(where: { $0.id == newValue }) else { return }
                onSelect(school)
                dismiss()
            }
        }
        .environmentObject(state)
    }

    private func row(for school: SchoolProfile) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(school.name)
                .font(.body.weight(school.id == selection ? .semibold : .regular))
                .foregroundStyle(.primary)
            Text(school.id)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .tag(school.id)
    }

    private func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        await state.refreshFromGitHub()
        statusMessage = state.errorMessage ?? state.sessionNotice
    }
}
