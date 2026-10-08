import SwiftUI

/// Port of `LoginScreen.kt`.
///
/// Android has two distinct screens rather than one screen with a hidden form: with no school
/// chosen the page is nothing but the brand block and one button pinned to the bottom, and the
/// credential fields do not exist in the hierarchy at all. Once a school is chosen the form appears
/// above a bottom area that stacks the school row, the web-login row and the primary button, in
/// that order and at one spacing, so that signing in reads top to bottom in the order you decide
/// how to do it. The content padding differs between the two states (64/112 unselected, 24/40
/// selected) and the brand block collapses when the keyboard is up.
///
/// Appearance and controls are iOS's. The fields are SwiftUI's own `TextField` and `SecureField` in
/// the plain style, sitting on the grouped surface, so they carry the caret, the autofill chrome,
/// the clear button and the keyboard handling without a hosted control. A `UIViewRepresentable`
/// `UITextField` was the previous answer and it could not keep a focus mirror honest: the username
/// field passed a constant `false` for it, so `updateUIView` saw "not focused, but first responder"
/// and resigned in the same pass -- the keyboard came up and went straight back down, which reads
/// as "tapping the field does nothing". `@FocusState` cannot be wrong that way.
///
/// The field group's shape is the Android one -- 14pt outer, square where the two meet -- written
/// as a background per field rather than as a shape on the control, because
/// `UnevenRoundedRectangle` is iOS 16.4 and the deployment target is 16.0. Squaring the meeting
/// ends is what makes the two read as one group with a line through it; rounding them gave each
/// field a shape of its own and the group a seam instead of a divider.
struct LoginView: View {
    @EnvironmentObject private var state: AppState
    @State private var showingSchools = false
    @State private var revealPassword = false
    /// Which field the keyboard belongs to. `@FocusState` is the system's own focus owner, so a tap
    /// needs no extra work to raise the keyboard and "next" moves straight to the password.
    @FocusState private var focusedField: Field?
    /// Height of the software keyboard in points; 0 while it is dismissed. Nothing but the brand
    /// block's collapse and the secondary rows' fade are driven from this: both are things the
    /// system's own keyboard avoidance does not do, whereas lifting the bottom area is, and that is
    /// left to it.
    @State private var keyboardHeight: CGFloat = 0
    /// The duration the system says it is about to animate the keyboard with, read from its own
    /// notification so this page's movement is not timed against a guess.
    @State private var keyboardDuration: Double = 0.25
    /// Token handles for the keyboard frame notifications registered in `observeKeyboard`.
    @State private var keyboardObservers: [NSObjectProtocol] = []

    private enum Field: Hashable {
        case username
        case password
    }

    private enum Metric {
        static let horizontal: CGFloat = 20
        /// Taller fields than the system default row: the group reads as a deliberate sign-in card
        /// rather than two cramped table rows.
        static let fieldHeight: CGFloat = 56
        static let primaryButtonHeight: CGFloat = 56
        static let secondaryButtonHeight: CGFloat = 54
        /// The gap between the adjacent rows of the bottom area: between the two secondary rows,
        /// and between them and the primary button below. One number for both, because they belong
        /// to one group of actions and a different gap between some of them than between others
        /// reads as two groups.
        static let buttonSpacing: CGFloat = 10
        /// Clearance between the bottom area and the edge of the reserved region.
        static let bottomPadding: CGFloat = 16
        /// The brand is now a compact logo-plus-title header row rather than a hero block, so its
        /// height is just the row's.
        static let brandHeight: CGFloat = 44
        /// The outer radius of the joined field group, enlarged so the card reads rounded on all
        /// four outer corners.
        static let fieldGroupRadius: CGFloat = 20
        /// The radius where the two fields meet, which is zero. A positive value there -- 6pt was
        /// here -- rounds each field into its own shape, so the pair reads as two cards with a seam
        /// rather than as one group with a divider; rounding one end of each field and squaring the
        /// other draws neither cleanly.
        static let fieldGroupInnerRadius: CGFloat = 0
    }

    /// Mirrors Android's `hasSelectedSchool`: a school was explicitly chosen at some point, so the
    /// persisted (last selected) school drives the form. The non-nil active profile cannot be used
    /// here because the catalog falls back to the built-in default school even on first run.
    private var hasSchool: Bool { state.hasSelectedSchool }
    private var brandVisible: Bool { keyboardHeight == 0 }

    var body: some View {
        ZStack {
            // Android paints `MaterialTheme.colorScheme.background`, which is #F2F2F7 light and
            // #000000 dark. `systemGroupedBackground` is exactly those two values, so the page
            // follows the appearance without a single hand-picked colour. Only this background
            // opts out of the safe area, so it fills behind the status bar and the home indicator;
            // the content does not, which is what lets the keyboard move it.
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
                        // The animation belongs on this one leaf. On the page it also animates the
                        // bottom area's own movement, which the system is already animating, so the
                        // two curves run together and the area arrives at a different time from the
                        // keyboard it is supposed to be riding.
                        .animation(keyboardAnimation, value: keyboardHeight)
                    if hasSchool {
                        credentialForm
                    }
                }
                .padding(.horizontal, Metric.horizontal)
                // The compact header needs only a small gap from the status bar; the first-run
                // landing keeps a little more air. Nothing here depends on the keyboard: the area
                // below reserves its own space, and the scroll view's content inset is adjusted by
                // the system when the keyboard comes up.
                .padding(.top, hasSchool ? 16 : 28)
                .padding(.bottom, hasSchool ? 16 : 40)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            // The bottom area sits *inside* the scroll view's bottom safe area rather than on top
            // of the screen. That single choice is what makes the login button follow the input
            // method: `safeAreaInset` places its content in the region the system reserves for the
            // keyboard, so the area is lifted with it -- by the system, along its own curve, at its
            // own duration, including the hardware keyboard's toolbar and every shape the input
            // method takes. An overlay aligned to the further side of that ignores all of it, which
            // is why the button stayed put and disappeared under the keyboard.
            //
            // The area deliberately carries NO opaque background. The band is roughly the height of
            // the two secondary rows plus the button, and while it rides up with the keyboard it
            // crosses the lower input field; filling it with the page colour painted a rectangle
            // over the fields for the whole rise. The reserved region is exclusive at rest, so
            // nothing scrolls under the area and no fill is needed there.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                bottomArea
            }
        }
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

    /// The compact page header: a small logo and a small title in one row, pinned to the leading
    /// edge. It replaces the old centered hero block; the row still collapses by height while the
    /// keyboard is up, so the focus-survival behaviour of the container below it is unchanged.
    private var brand: some View {
        HStack(spacing: 10) {
            Image(systemName: "building.columns")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(PortalPalette.primary)
            Text("掌上教务")
                .font(.headline.weight(.bold))
                .foregroundStyle(PortalPalette.onSurface)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
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

    /// The login, school and web-login buttons, as one group at the foot of the page.
    ///
    /// They are stacked in reading order -- switch the school, use the browser instead, then commit
    /// -- with one spacing between each pair, and the group is what the keyboard lifts. The primary
    /// needs no offset of its own any more: being the last thing in the area already puts it
    /// against the edge the keyboard leaves.
    private var bottomArea: some View {
        VStack(spacing: 0) {
            if hasSchool {
                // Android's secondary actions fade as the keyboard arrives
                // (`secondaryActionAlpha = 1 - imeProgress * 2`) and do not move. They keep their
                // height while invisible rather than being removed from the layout, because
                // removing them would pull the primary button down onto the keyboard at the same
                // moment the keyboard arrived -- a second motion on top of the one being watched.
                VStack(spacing: Metric.buttonSpacing) {
                    secondaryButton(
                        systemImage: "building.columns",
                        title: state.selectedSchool?.name ?? "选择学校",
                        showsChevron: true
                    ) { showingSchools = true }
                    secondaryButton(systemImage: "safari", title: "用网页登录", showsChevron: false) {
                        focusedField = nil
                        state.showingWebLogin = true
                    }
                }
                .opacity(secondaryOpacity)
                .allowsHitTesting(keyboardHeight == 0)

                loginButton
                    .padding(.top, Metric.buttonSpacing)
            } else {
                schoolSelectionPrompt
            }
        }
        .padding(.horizontal, Metric.horizontal)
        .padding(.top, 8)
        .padding(.bottom, Metric.bottomPadding)
    }

    /// The primary action. A system prominent button tinted to Android's `primary` token, so it
    /// keeps the system's own corner radius, press animation and disabled appearance instead of a
    /// hand-drawn capsule.
    private var loginButton: some View {
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

    /// The keyboard's own curve, or as close to it as SwiftUI can be given.
    ///
    /// `UIView.AnimationCurve` is what the system publishes alongside its keyboard frame, and it
    /// has no counterpart here -- the value it reports for a keyboard is one of its reserved ones,
    /// not a public member -- so the curve is written as its control points instead of being read.
    /// Linear is what made this read wrong before: an element that travels at a constant speed for
    /// a constant time looks dragged, because every real thing that has been pushed accelerates out
    /// and settles in. This curve leaves at once and spends most of its time approaching the end.
    ///
    /// The duration *is* read from the system, because that one it does report and getting it wrong
    /// leaves the page and the keyboard arriving separately.
    private var keyboardAnimation: Animation {
        .timingCurve(0.25, 1, 0.5, 1, duration: max(keyboardDuration, 0.2))
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
                // The system publishes the duration it is about to move the keyboard with. Reading
                // it rather than picking one is what keeps the brand block's collapse from running
                // against the keyboard's own arrival: the bottom area is moved by the system now, so
                // anything still animated by hand has to be timed to it or visibly lag it.
                if let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey]
                        as? Double, duration > 0 {
                    keyboardDuration = duration
                }
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
                // The field has to claim the remaining width itself. Left to itself inside an
                // HStack it is sized to its text, so the tappable area is the few glyphs the
                // placeholder occupies -- which is why tapping the row next to it did nothing and
                // the field appeared to need two taps.
                .frame(maxWidth: .infinity, alignment: .leading)
                .focused($focusedField, equals: .username)
                .onSubmit { focusedField = .password }
                .disabled(state.isLoading)
        }
        .padding(.horizontal, 12)
        .frame(height: Metric.fieldHeight)
        // Tapping anywhere on the row -- including the leading glyph and the empty space -- focuses
        // the field. This is what a text field's own hit area covers on iOS.
        .contentShape(Rectangle())
        .onTapGesture { focusedField = .username }
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
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .focused($focusedField, equals: .password)
                    .onSubmit { submit() }
            } else {
                SecureField("密码", text: $state.password)
                    .textContentType(.password)
                    .submitLabel(.go)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in revealButtonIsHit = true }
                        .onEnded { _ in revealButtonIsHit = false }
                )
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(height: Metric.fieldHeight)
        .disabled(state.isLoading)
        .contentShape(Rectangle())
        .onTapGesture {
            // The reveal button is a sibling inside this row, so the tap has to be ignored while it
            // is the thing under the finger; otherwise flipping the reveal also raises the keyboard.
            if !revealButtonIsHit { focusedField = .password }
        }
    }

    /// Set by the reveal button for the duration of its own tap. SwiftUI gives no way to ask a
    /// gesture whether it landed on a sibling, so the button marks the moment itself.
    @State private var revealButtonIsHit = false

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
        // Seed from the active profile so the row the user is on is already ticked on open -- but
        // only when a school was explicitly chosen at some point. `selectedSchoolID` alone cannot
        // be used here: the catalog falls back to the built-in default ("cupk") on first run, so
        // seeding from it unconditionally opens the picker with a school ticked that the user
        // never chose.
        _selection = State(initialValue: SchoolCatalog.shared.hasSelectedSchool
            ? SchoolCatalog.shared.selectedSchoolID
            : nil)
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
            // Rows carry their own Button rather than relying on `List(selection:)`: outside edit
            // mode a list does not reliably write a single-selection binding on iPhone, which
            // meant a tap could highlight without ever calling `onSelect`, so the chosen school
            // was never persisted. The button writes the selection, the checkmark reads it.
            List {
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
        Button {
            selection = school.id
        } label: {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(school.name)
                        .font(.body.weight(school.id == selection ? .semibold : .regular))
                        .foregroundStyle(.primary)
                    Text(school.id)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if school.id == selection {
                    Image(systemName: "checkmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                }
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(school.id == selection ? "当前选择" : "")
    }

    private func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        await state.refreshFromGitHub()
        statusMessage = state.errorMessage ?? state.sessionNotice
    }
}
