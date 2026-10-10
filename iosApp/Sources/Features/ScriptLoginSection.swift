import SwiftUI
import UIKit

/// type=script 学校在既有登录页上【增量挂载】的表单区：
/// 方式分段切换（仅脚本显式声明 methodSwitch 时出现）、schema 驱动的字段组、
/// 短信验证码按钮、图形验证码、复选框、二维码面板，以及验证码挑战/登录失败弹窗。
/// 与安卓 LoginScreen.kt 末尾的 Script* 控件一一对应，不另起登录页面。
struct ScriptLoginSection: View {
    @ObservedObject var controller: ScriptLoginController
    @FocusState private var focusedKey: String?

    private enum Metric {
        static let fieldHeight: CGFloat = 62
        static let groupRadius: CGFloat = 26
        static let innerRadius: CGFloat = 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch controller.phase {
            case .loading:
                loadingState
                    .transition(.opacity)
            case .ready:
                if let initError = controller.initError {
                    errorBanner(initError)
                } else {
                    methodTabs
                    if let method = controller.currentMethod() {
                        // 整块随方式切换滑入滑出；字段增减也包含在同一动画事务内。
                        methodBody(method)
                            .id(method.id)
                            .transition(.methodSwitch)
                    }
                    if let error = controller.error {
                        errorBanner(error)
                            .transition(.opacity)
                    }
                    if controller.busy || controller.status != nil {
                        statusSurface
                            .transition(.opacity)
                    }
                }
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: controller.methodId)
        .animation(.easeInOut(duration: 0.2), value: controller.phase)
        .alert(
            "登录失败",
            isPresented: Binding(
                get: { controller.failureDialog != nil },
                set: { presented in if !presented { controller.dismissFailure() } }
            ),
            presenting: controller.failureDialog
        ) { _ in
            Button("取消", role: .cancel) { controller.dismissFailure() }
            Button("重试") { controller.retryAfterFailure() }
        } message: { message in
            Text(message)
        }
        .overlay(alignment: .center) {
            if controller.captchaChallenge != nil {
                captchaChallengeCard
            }
        }
    }

    // MARK: - Method body

    @ViewBuilder
    private func methodBody(_ method: LoginScriptRuntime.Method) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            formLabel(method.label)
            if method.kind == "qrcode" {
                qrPanel
            } else {
                fieldGroup(method)
            }
            checkboxGroup(method)
        }
    }

    // MARK: - States

    /// 输入框下方的提示不加底色：仅小字与转圈，与表单分隔由间距承担。
    private var loadingState: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("正在加载登录方式…")
                .font(.subheadline)
                .foregroundStyle(PortalPalette.secondaryText)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
    }

    private var statusSurface: some View {
        HStack(spacing: 10) {
            if controller.busy {
                ProgressView().controlSize(.small)
            }
            Text(controller.status ?? "处理中…")
                .font(.subheadline)
                .foregroundStyle(PortalPalette.secondaryText)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
    }

    // MARK: - Method switch

    /// 只有脚本在 describe() 顶层显式声明 methodSwitch:true 且方式多于一个时才出现。
    @ViewBuilder
    private var methodTabs: some View {
        if controller.methodSwitch && controller.methods.count > 1 {
            Picker("登录方式", selection: Binding(
                get: { controller.methodId },
                set: { newValue in
                    if let method = controller.methods.first(where: { $0.id == newValue }) {
                        focusedKey = nil
                        // 与表单区的 methodSwitch 转场处于同一个弹性动画事务。
                        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                            controller.selectMethod(method)
                        }
                    }
                }
            )) {
                ForEach(controller.methods, id: \.id) { method in
                    Text(method.label).tag(method.id)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    // MARK: - Fields

    @ViewBuilder
    private func fieldGroup(_ method: LoginScriptRuntime.Method) -> some View {
        if !method.fields.isEmpty {
            VStack(spacing: 0) {
                ForEach(Array(method.fields.enumerated()), id: \.element.id) { index, field in
                    if index > 0 {
                        Divider().padding(.leading, 34)
                    }
                    fieldRow(field, position: cardPosition(index: index, count: method.fields.count))
                }
            }
        }
    }

    private func cardPosition(index: Int, count: Int) -> GroupPosition {
        if count == 1 { return .only }
        if index == 0 { return .first }
        if index == count - 1 { return .last }
        return .middle
    }

    @ViewBuilder
    private func fieldRow(
        _ field: LoginScriptRuntime.Field,
        position: GroupPosition
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: iconName(for: field))
                .foregroundStyle(PortalPalette.secondaryText)
                .frame(width: 22)
            textInput(for: field)
                .frame(maxWidth: .infinity, alignment: .leading)
            trailingAccessory(for: field)
        }
        .padding(.leading, 12)
        .padding(.trailing, field.type == "captcha" || field.type == "smsCode" ? 9 : 6)
        .frame(height: Metric.fieldHeight)
        .background(
            GroupedCardShape(large: Metric.groupRadius, small: Metric.innerRadius, position: position)
                .fill(PortalPalette.surface)
        )
        .contentShape(Rectangle())
        .onTapGesture { focusedKey = field.id }
    }

    @ViewBuilder
    private func textInput(for field: LoginScriptRuntime.Field) -> some View {
        let binding = Binding(
            get: { controller.values[field.id] ?? "" },
            set: { controller.setValue(field.id, $0) }
        )
        let submitLabel: SubmitLabel = isLastInput(field) ? .go : .next
        if field.type == "password" {
            SecureField(field.placeholder.isEmpty ? field.label : field.placeholder, text: binding)
                .textContentType(.password)
                .submitLabel(submitLabel)
                .focused($focusedKey, equals: field.id)
                .onSubmit { submitted(field) }
        } else {
            TextField(field.placeholder.isEmpty ? field.label : field.placeholder, text: binding)
                .textContentType(contentType(for: field))
                .keyboardType(keyboardType(for: field))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(submitLabel)
                .focused($focusedKey, equals: field.id)
                .onSubmit { submitted(field) }
        }
    }

    @ViewBuilder
    private func trailingAccessory(for field: LoginScriptRuntime.Field) -> some View {
        switch field.type {
        case "captcha":
            captchaImageButton(field)
        case "smsCode":
            smsButton(field)
        default:
            EmptyView()
        }
    }

    private func captchaImageButton(_ field: LoginScriptRuntime.Field) -> some View {
        Button {
            focusedKey = nil
            controller.refreshCaptcha(field)
        } label: {
            Group {
                if let data = controller.captchaImages[field.id], let image = UIImage(data: data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    VStack(spacing: 2) {
                        Image(systemName: "arrow.clockwise")
                        Text("加载").font(.caption2)
                    }
                    .foregroundStyle(PortalPalette.secondaryText)
                }
            }
            .frame(width: 106, height: 44)
        }
        .buttonStyle(.plain)
        .disabled(controller.busy)
        .accessibilityLabel("刷新验证码")
    }

    private func smsButton(_ field: LoginScriptRuntime.Field) -> some View {
        Button {
            focusedKey = nil
            controller.sendSms(field)
        } label: {
            Text(controller.smsCooldown > 0
                 ? "\(controller.smsCooldown)s"
                 : "获取验证码")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(
                    controller.smsCooldown > 0
                        ? PortalPalette.secondaryText
                        : PortalPalette.primary
                )
                .frame(width: 104, height: 44)
        }
        .buttonStyle(.plain)
        .disabled(controller.smsCooldown > 0 || controller.busy)
    }

    // MARK: - Checkboxes

    @ViewBuilder
    private func checkboxGroup(_ method: LoginScriptRuntime.Method) -> some View {
        ForEach(method.checkboxes, id: \.id) { checkbox in
            HStack {
                Text(checkbox.label)
                    .font(.body.weight(.medium))
                    .foregroundStyle(PortalPalette.onSurface)
                Spacer(minLength: 0)
                Toggle("", isOn: Binding(
                    get: { controller.checkboxes[checkbox.id] ?? checkbox.defaultChecked },
                    set: { _ in controller.toggleCheckbox(checkbox.id) }
                ))
                .labelsHidden()
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .background(Capsule().fill(PortalPalette.surface))
        }
    }

    // MARK: - QR panel

    private var qrPanel: some View {
        VStack(spacing: 14) {
            Group {
                if let image = controller.qrImage {
                    Image(uiImage: image)
                        .resizable()
                        .interpolation(.none)
                        .scaledToFit()
                        .padding(10)
                } else {
                    ProgressView()
                }
            }
            .frame(width: 232, height: 232)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            Text(qrDisplayMessage)
                .font(.subheadline)
                .foregroundStyle(
                    controller.qrState == "expired"
                        ? PortalPalette.error
                        : PortalPalette.secondaryText
                )
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private var qrDisplayMessage: String {
        if !controller.qrMessage.isEmpty { return controller.qrMessage }
        switch controller.qrState {
        case "scanned": return "已扫描，请在手机上确认"
        case "expired": return "二维码已失效"
        default: return "请使用学校 App / 微信扫码登录"
        }
    }

    // MARK: - Captcha challenge modal

    private var captchaChallengeCard: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture { controller.dismissCaptchaDialog() }
            VStack(spacing: 14) {
                Text("请输入图形验证码")
                    .font(.headline)
                    .foregroundStyle(PortalPalette.onSurface)
                Button {
                    controller.refreshDialogCaptcha()
                } label: {
                    Group {
                        if let data = controller.captchaDialogImage, let image = UIImage(data: data) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                        } else {
                            ProgressView()
                        }
                    }
                    .frame(width: 200, height: 72)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("刷新验证码")

                TextField("验证码", text: Binding(
                    get: { controller.captchaDialogInput },
                    set: { controller.captchaDialogInput = $0 }
                ))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .multilineTextAlignment(.center)
                .frame(height: 44)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(PortalPalette.page)
                )
                .padding(.horizontal, 4)

                HStack(spacing: 12) {
                    Button {
                        controller.dismissCaptchaDialog()
                    } label: {
                        Text("取消")
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        controller.confirmCaptchaDialog()
                    } label: {
                        Text("确定")
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(PortalPalette.primary)
                    .disabled(controller.captchaDialogInput
                        .trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(20)
            .frame(maxWidth: 320)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(PortalPalette.surface)
            )
            .shadow(color: .black.opacity(0.18), radius: 24, y: 8)
            .padding(28)
        }
    }

    // MARK: - Helpers

    private func formLabel(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(PortalPalette.secondaryText)
            .padding(.horizontal, 8)
            .padding(.bottom, -6)
    }

    /// 错误提示同样不加底色，仅用错误色文字。
    private func errorBanner(_ message: String) -> some View {
        Text(message)
            .font(.subheadline)
            .foregroundStyle(PortalPalette.error)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
    }

    private func iconName(for field: LoginScriptRuntime.Field) -> String {
        switch field.type {
        case "password": return "key"
        case "tel": return "phone"
        case "captcha": return "number.square"
        case "smsCode": return "message"
        default:
            return field.id == "username" ? "person.crop.circle" : "textformat"
        }
    }

    private func contentType(for field: LoginScriptRuntime.Field) -> UITextContentType? {
        switch field.type {
        case "tel": return .telephoneNumber
        case "captcha", "smsCode": return .oneTimeCode
        default: return field.id == "username" ? .username : nil
        }
    }

    private func keyboardType(for field: LoginScriptRuntime.Field) -> UIKeyboardType {
        switch field.type {
        case "tel": return .phonePad
        case "captcha", "smsCode": return .asciiCapableNumberPad
        default: return .default
        }
    }

    private func isLastInput(_ field: LoginScriptRuntime.Field) -> Bool {
        guard let method = controller.currentMethod(),
              let index = method.fields.firstIndex(where: { $0.id == field.id }) else {
            return true
        }
        return index == method.fields.count - 1
    }

    private func submitted(_ field: LoginScriptRuntime.Field) {
        guard let method = controller.currentMethod(),
              let index = method.fields.firstIndex(where: { $0.id == field.id }),
              index + 1 < method.fields.count else {
            focusedKey = nil
            controller.submit()
            return
        }
        focusedKey = method.fields[index + 1].id
    }
}

private extension AnyTransition {
    /// 登录方式切换：旧方式向左淡出，新方式从右侧淡入（与安卓 AnimatedContent 同向）。
    static let methodSwitch: AnyTransition = .asymmetric(
        insertion: .opacity.combined(with: .move(edge: .trailing)),
        removal: .opacity.combined(with: .move(edge: .leading))
    )
}
