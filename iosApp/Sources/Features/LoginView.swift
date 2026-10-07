import SwiftUI

/// Port of the login screen from `MainActivity.kt`.
struct LoginView: View {
    @EnvironmentObject private var state: AppState
    @State private var showingSchools = false
    @State private var showingWebLogin = false
    @State private var revealPassword = false
    /// First-responder mirror for the password field. The username field needs no state of its
    /// own: its "next" key just raises this one.
    @State private var passwordIsFocused = false
    /// Height of the software keyboard in points; 0 while it is dismissed.
    @State private var keyboardHeight: CGFloat = 0
    /// Token handles for the keyboard frame notifications registered in `observeKeyboard`.
    @State private var keyboardObservers: [NSObjectProtocol] = []

    var body: some View {
        ZStack {
            backgroundLayer

            ScrollView {
                VStack(spacing: 0) {
                    header
                        .padding(.top, 36)
                        .padding(.bottom, 28)

                    VStack(alignment: .leading, spacing: 10) {
                        sectionLabel("学校")
                        schoolCard

                        Text("登录信息")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 6)
                            .padding(.top, 14)

                        usernameField
                        passwordField

                        rememberCard
                            .padding(.top, 6)

                        if let errorMessage = state.errorMessage {
                            errorBanner(errorMessage)
                        }

                        loginButton
                            .padding(.top, 8)

                        webLoginButton
                            .padding(.top, 10)
                    }
                    .padding(.horizontal, 20)

                    Spacer(minLength: 40)
                }
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            // SwiftUI's ScrollView does not resize for the keyboard on iOS 16 the way Android's
            // adjustResize does, so the fields stayed underneath it. Letting the safe area grow by
            // the keyboard height both lifts the content and keeps it scrollable.
            //
            // The animation is deliberately NOT attached here. Animating the scroll view itself
            // would make every row, the card shadows and the full-screen gradient re-render on
            // each keyboard frame change, which is what made the transition stutter. Animating
            // only the inset spacer below animates one leaf view instead of the whole tree.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear
                    .frame(height: keyboardHeight)
                    .animation(.easeInOut(duration: 0.25), value: keyboardHeight)
            }
        }
        .sheet(isPresented: $showingSchools) {
            SchoolPickerView { school in
                state.selectSchool(school)
            }
        }
        .fullScreenCover(isPresented: $state.showingWebLogin) {
            WebLoginView()
                .environmentObject(state)
        }
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

    // MARK: - Keyboard avoidance

    /// iOS reports the keyboard through frame-change notifications rather than an
    /// adjustment-behaviour flag, so the height is what drives the safe-area inset.
    ///
    /// No `withAnimation` here on purpose: the spacer in `body` already carries its own
    /// `.animation(value:)`, and wrapping the state write in one as well makes the two
    /// animations fight over the same value on every frame of the keyboard transition.
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

    private var backgroundLayer: some View {
        LinearGradient(
            colors: state.isDark
                ? [Color(red: 0.07, green: 0.08, blue: 0.11), Color(red: 0.11, green: 0.13, blue: 0.18)]
                : [Color(red: 0.95, green: 0.96, blue: 0.98), Color.white],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }

    private var header: some View {
        VStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 19, style: .continuous)
                .fill(state.isDark ? Color.white.opacity(0.09) : Color.white.opacity(0.85))
                .frame(width: 62, height: 62)
                .overlay(
                    Image(systemName: "building.columns")
                        .font(.system(size: 30, weight: .regular))
                        .foregroundStyle(state.isDark ? Color.white : Color.black)
                )
                .shadow(color: .black.opacity(state.isDark ? 0.3 : 0.08), radius: 12, y: 6)

            Text("掌上教务")
                .font(.title.bold())
                .foregroundStyle(state.isDark ? Color.white : Color.black)

            Text("登录以访问你的教务信息")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, 6)
            .padding(.bottom, 6)
    }

    private var schoolCard: some View {
        Button {
            showingSchools = true
        } label: {
            HStack(spacing: 13) {
                Image(systemName: "building.columns")
                    .font(.system(size: 20))
                    .foregroundStyle(state.isDark ? Color.white : Color.black)
                Text(state.selectedSchool?.name ?? "选择学校")
                    .font(.body.weight(.medium))
                    .foregroundStyle(state.isDark ? Color.white : Color.black)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 15)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(state.isLoading)
        .background(cardBackground)
    }

    private var usernameField: some View {
        NativeLoginField(
            title: "学号 / 账号",
            systemImage: "person.crop.circle",
            text: $state.username,
            isSecure: .constant(false),
            contentType: .username,
            submitLabel: .next,
            isDisabled: state.isLoading,
            isFocused: .constant(false),
            onSubmit: { passwordIsFocused = true }
        )
        .frame(height: 44)
    }

    private var passwordField: some View {
        NativeLoginField(
            title: "密码",
            systemImage: "key",
            text: $state.password,
            isSecure: $revealPassword,
            contentType: .password,
            submitLabel: .go,
            isDisabled: state.isLoading,
            isFocused: $passwordIsFocused,
            onSubmit: { Task { await state.login() } }
        )
        .frame(height: 44)
    }

    private var rememberCard: some View {
        Button {
            state.rememberPassword.toggle()
            if !state.rememberPassword {
                CredentialStore.clear(schoolID: SchoolCatalog.shared.selectedSchoolID)
            }
        } label: {
            HStack {
                Text("记住密码")
                    .font(.body.weight(.medium))
                    .foregroundStyle(state.isDark ? Color.white : Color.black)
                Spacer()
                Toggle("", isOn: $state.rememberPassword)
                    .labelsHidden()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(state.isLoading)
        .background(cardBackground)
    }

    private func errorBanner(_ message: String) -> some View {
        Text(message)
            .font(.subheadline)
            .foregroundStyle(state.isDark ? Color(red: 1, green: 0.7, blue: 0.7) : Color(red: 0.7, green: 0.1, blue: 0.1))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(state.isDark ? Color.red.opacity(0.16) : Color.red.opacity(0.09))
            )
    }

    private var loginButton: some View {
        FilledActionButton(
            title: state.isLoading ? "登录中…" : "登录",
            systemImage: "lock",
            style: .prominent,
            isDark: state.isDark,
            isBusy: state.isLoading,
            isEnabled: canSubmit
        ) {
            Task { await state.login() }
        }
    }

    /// Port of the "网页登录" entry in `LoginView.kt`. Some deployments answer the password
    /// handshake with a challenge only a browser engine can clear, so this hands over to a real
    /// WKWebView rather than leaving the user with no way through.
    private var webLoginButton: some View {
        FilledActionButton(
            title: "网页登录",
            systemImage: "safari",
            style: .plain,
            isDark: state.isDark,
            isEnabled: !state.isLoading
        ) {
            passwordIsFocused = false
            state.showingWebLogin = true
        }
    }

    private var canSubmit: Bool {
        !state.isLoading
            && !state.username.trimmingCharacters(in: .whitespaces).isEmpty
            && !state.password.isEmpty
    }

    /// The card surface behind a login row.
    ///
    /// The shadow is deliberately a separate layer with `allowsHitTesting(false)`. Applied
    /// directly to the card shape it became part of the responder chain and consumed the first
    /// tap meant for the control inside, which is why focusing took two taps. Keeping it inert
    /// and behind the fill also renders cheaper: no drop shadow is rasterised per keystroke.
    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(state.isDark ? Color.white.opacity(0.08) : Color.white.opacity(0.9))
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.black)
                    .opacity(state.isDark ? 0.28 : 0.07)
                    .blur(radius: 10)
                    .offset(y: 4)
                    .allowsHitTesting(false)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(
                        state.isDark ? Color.white.opacity(0.1) : Color.black.opacity(0.06),
                        lineWidth: 0.8
                    )
                    .allowsHitTesting(false)
            )
    }
}

/// Port of `SchoolSelectionUi.kt`.
struct SchoolPickerView: View {
    @Environment(\.dismiss) private var dismiss
    let onSelect: (SchoolProfile) -> Void

    var body: some View {
        NavigationStack {
            List {
                ForEach(SchoolCatalog.shared.options) { school in
                    Button {
                        onSelect(school)
                        dismiss()
                    } label: {
                        HStack {
                            Text(school.name)
                                .foregroundStyle(.primary)
                            Spacer()
                            if school.id == SchoolCatalog.shared.selectedSchoolID {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                }
            }
            .navigationTitle("选择学校")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}