import CryptoKit
import Foundation
import SwiftUI

// Native iOS migration preview. This target deliberately does not use WKWebView.
// It has not been tested on a physical iPhone or iPad; validate network, login,
// safe-area and background behavior on real hardware before distribution.

struct SchoolProfile: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let origin: String
    let definitionAsset: String
}

struct SchoolIndex: Codable {
    let schools: [SchoolProfile]
}

struct SchoolDefinition: Codable {
    let id: String
    let name: String
    let baseUrl: String
    let groups: [PortalGroup]
}

struct PortalGroup: Codable, Identifiable {
    let title: String
    let items: [PortalItem]

    var id: String { title }
}

struct PortalItem: Codable, Identifiable, Hashable {
    let title: String
    let path: String
    let quick: Bool?

    var id: String { path }
}

struct PortalTable: Identifiable {
    let id = UUID()
    let rows: [[String]]
}

struct PortalPage {
    let title: String
    let statusCode: Int
    let tables: [PortalTable]
    let text: String
}

enum PortalClientError: LocalizedError {
    case invalidSchool
    case invalidResponse
    case requestFailed(Int)
    case emptySalt
    case loginRejected(String)
    case noSession

    var errorDescription: String? {
        switch self {
        case .invalidSchool: return "学校配置无效"
        case .invalidResponse: return "教务系统返回内容无法解析"
        case .requestFailed(let code): return "请求失败（HTTP \(code)），请检查网络或校园网/VPN"
        case .emptySalt: return "无法获取登录校验信息"
        case .loginRejected(let message): return message
        case .noSession: return "登录请求已完成，但没有收到会话信息"
        }
    }
}

struct PortalClient {
    let session: URLSession
    let school: SchoolProfile

    private var origin: URL? { URL(string: school.origin.trimmingCharacters(in: CharacterSet(charactersIn: "/"))) }

    private var baseURL: URL? { origin?.appendingPathComponent("student") }

    private var loginURL: URL? { baseURL?.appendingPathComponent("login") }

    func login(username: String, password: String) async throws {
        guard let baseURL, let loginURL else { throw PortalClientError.invalidSchool }

        var pageRequest = URLRequest(url: loginURL)
        pageRequest.httpMethod = "GET"
        pageRequest.setValue(baseURL.absoluteString, forHTTPHeaderField: "Referer")
        pageRequest.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        _ = try await request(pageRequest)

        var saltRequest = URLRequest(url: baseURL.appendingPathComponent("login-salt"))
        addAjaxHeaders(to: &saltRequest, referer: loginURL.absoluteString)
        let saltData = try await request(saltRequest)
        let salt = String(data: saltData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        guard let salt, !salt.isEmpty else { throw PortalClientError.emptySalt }

        let payload: [String: String] = [
            "username": username.trimmingCharacters(in: .whitespacesAndNewlines),
            "password": Self.sha1Hex("\(salt)-\(password)"),
            "captchaToken": ""
        ]
        var loginRequest = URLRequest(url: loginURL)
        addAjaxHeaders(to: &loginRequest, referer: loginURL.absoluteString)
        loginRequest.httpMethod = "POST"
        loginRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        loginRequest.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        loginRequest.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let responseData = try await request(loginRequest)

        if let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] {
            if (json["needCaptcha"] as? Bool) == true {
                throw PortalClientError.loginRejected("教务系统要求安全验证，请检查网络环境或稍后重试")
            }
            if (json["result"] as? Bool) == false {
                throw PortalClientError.loginRejected(json["message"] as? String ?? "账号或密码错误")
            }
        }

        let cookies = HTTPCookieStorage.shared.cookies(for: loginURL) ?? []
        guard cookies.contains(where: { $0.name == "SESSION" && !$0.value.isEmpty }) else {
            throw PortalClientError.noSession
        }
    }

    func fetch(_ item: PortalItem) async throws -> PortalPage {
        let relativePath = item.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let baseURL else {
            throw PortalClientError.invalidSchool
        }
        let url = baseURL.appendingPathComponent(relativePath, isDirectory: false)
        var request = URLRequest(url: url)
        request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw PortalClientError.invalidResponse }
        guard (200..<400).contains(httpResponse.statusCode) else {
            throw PortalClientError.requestFailed(httpResponse.statusCode)
        }
        guard let html = String(data: data, encoding: .utf8) else { throw PortalClientError.invalidResponse }
        return HTMLTableParser.parse(html: html, title: item.title, statusCode: httpResponse.statusCode)
    }

    private func request(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw PortalClientError.invalidResponse }
        guard (200..<400).contains(httpResponse.statusCode) else {
            throw PortalClientError.requestFailed(httpResponse.statusCode)
        }
        return data
    }

    private func addAjaxHeaders(to request: inout URLRequest, referer: String) {
        request.httpMethod = "GET"
        request.setValue(origin?.absoluteString, forHTTPHeaderField: "Origin")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
    }

    private static func sha1Hex(_ value: String) -> String {
        Insecure.SHA1.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

enum HTMLTableParser {
    static func parse(html: String, title: String, statusCode: Int) -> PortalPage {
        let tableMatches = matches(in: html, pattern: "(?is)<table\\b[^>]*>(.*?)</table>")
        let tables = tableMatches.map { tableHTML in
            let rows = matches(in: tableHTML, pattern: "(?is)<tr\\b[^>]*>(.*?)</tr>").map { rowHTML in
                matches(in: rowHTML, pattern: "(?is)<t[dh]\\b[^>]*>(.*?)</t[dh]>")
                    .map(Self.clean)
                    .filter { !$0.isEmpty }
            }.filter { !$0.isEmpty }
            return PortalTable(rows: rows)
        }.filter { !$0.rows.isEmpty }

        let visibleText = clean(html)
        return PortalPage(title: title, statusCode: statusCode, tables: tables, text: visibleText)
    }

    private static func matches(in text: String, pattern: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[range])
        }
    }

    private static func clean(_ html: String) -> String {
        var value = html.replacingOccurrences(of: "(?is)<script\\b[^>]*>.*?</script>", with: " ", options: .regularExpression)
        value = value.replacingOccurrences(of: "(?is)<style\\b[^>]*>.*?</style>", with: " ", options: .regularExpression)
        value = value.replacingOccurrences(of: "(?is)<[^>]+>", with: " ", options: .regularExpression)
        let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'"]
        entities.forEach { value = value.replacingOccurrences(of: $0.key, with: $0.value) }
        return value
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@MainActor
final class PortalStore: ObservableObject {
    @Published var schools: [SchoolProfile] = []
    @Published var selectedSchool: SchoolProfile?
    @Published var definition: SchoolDefinition?
    @Published var username = ""
    @Published var password = ""
    @Published var rememberPassword = false
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var authenticated = false

    private let session: URLSession
    private let defaults = UserDefaults.standard
    private let selectedSchoolKey = "native_selected_school"

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.httpCookieStorage = HTTPCookieStorage.shared
        configuration.httpShouldSetCookies = true
        session = URLSession(configuration: configuration)
        loadSchools()
    }

    func selectSchool(_ school: SchoolProfile) {
        selectedSchool = school
        defaults.set(school.id, forKey: selectedSchoolKey)
        loadCredentials()
        definition = loadDefinition(for: school)
        errorMessage = nil
    }

    func login() async {
        guard let selectedSchool else { errorMessage = "请选择学校"; return }
        guard !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !password.isEmpty else {
            errorMessage = "请输入账号和密码"
            return
        }
        isLoading = true
        errorMessage = nil
        do {
            try await PortalClient(session: session, school: selectedSchool).login(username: username, password: password)
            if rememberPassword {
                defaults.set(username, forKey: "native_username_\(selectedSchool.id)")
                defaults.set(password, forKey: "native_password_\(selectedSchool.id)")
            } else {
                defaults.removeObject(forKey: "native_password_\(selectedSchool.id)")
            }
            authenticated = true
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func logout() {
        authenticated = false
        username = ""
        password = ""
        if let selectedSchool, let loginURL = URL(string: selectedSchool.origin)?.appendingPathComponent("student/login") {
            (HTTPCookieStorage.shared.cookies(for: loginURL) ?? []).forEach(HTTPCookieStorage.shared.deleteCookie)
        }
    }

    func fetch(_ item: PortalItem) async throws -> PortalPage {
        guard let selectedSchool else { throw PortalClientError.invalidSchool }
        return try await PortalClient(session: session, school: selectedSchool).fetch(item)
    }

    private func loadSchools() {
        guard let url = Bundle.main.url(forResource: "index", withExtension: "json", subdirectory: "schools"),
              let data = try? Data(contentsOf: url),
              let index = try? JSONDecoder().decode(SchoolIndex.self, from: data) else {
            errorMessage = "学校配置加载失败"
            return
        }
        schools = index.schools
        let savedID = defaults.string(forKey: selectedSchoolKey)
        selectSchool(schools.first(where: { $0.id == savedID }) ?? schools[0])
    }

    private func loadCredentials() {
        guard let selectedSchool else { return }
        username = defaults.string(forKey: "native_username_\(selectedSchool.id)") ?? ""
        password = defaults.string(forKey: "native_password_\(selectedSchool.id)") ?? ""
        rememberPassword = !password.isEmpty
    }

    private func loadDefinition(for school: SchoolProfile) -> SchoolDefinition? {
        guard let file = school.definitionAsset.split(separator: "/").last,
              let url = Bundle.main.url(forResource: String(file).replacingOccurrences(of: ".json", with: ""), withExtension: "json", subdirectory: "schools"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SchoolDefinition.self, from: data)
    }
}

@main
struct PalmAcademicApp: App {
    @StateObject private var store = PortalStore()

    var body: some Scene {
        WindowGroup {
            Group {
                if store.authenticated {
                    PortalHomeView()
                } else {
                    LoginView()
                }
            }
            .environmentObject(store)
        }
    }
}

struct LoginView: View {
    @EnvironmentObject private var store: PortalStore
    @State private var showSchools = false
    @State private var showPassword = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    Image(systemName: "graduationcap.fill")
                        .font(.system(size: 42, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 76, height: 76)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 22))
                    Text("掌上教务")
                        .font(.largeTitle.bold())
                    Text("原生 iOS 迁移预览版 · 未经过实机测试")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 16) {
                        Text("账号密码登录")
                            .font(.title3.weight(.semibold))

                        Button { showSchools = true } label: {
                            HStack {
                                Image(systemName: "building.columns")
                                Text(store.selectedSchool?.name ?? "选择学校")
                                    .lineLimit(1)
                                Spacer()
                                Image(systemName: "chevron.right")
                            }
                        }
                        .buttonStyle(.bordered)

                        TextField("学号 / 账号", text: $store.username)
                            .textContentType(.username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .textFieldStyle(.roundedBorder)

                        HStack {
                            Group {
                                if showPassword {
                                    TextField("密码", text: $store.password)
                                } else {
                                    SecureField("密码", text: $store.password)
                                }
                            }
                            .textFieldStyle(.roundedBorder)
                            Button { showPassword.toggle() } label: {
                                Image(systemName: showPassword ? "eye.slash" : "eye")
                            }
                            .buttonStyle(.plain)
                        }

                        Toggle("记住密码", isOn: $store.rememberPassword)

                        if let errorMessage = store.errorMessage {
                            Text(errorMessage)
                                .font(.callout)
                                .foregroundStyle(.red)
                        }

                        Button {
                            Task { await store.login() }
                        } label: {
                            HStack {
                                if store.isLoading { ProgressView().tint(.white) }
                                Text(store.isLoading ? "登录中…" : "登录")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(store.isLoading)
                    }
                    .padding(20)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24))
                }
                .padding(24)
            }
            .navigationTitle("登录")
            .sheet(isPresented: $showSchools) { SchoolPickerView() }
        }
    }
}

struct SchoolPickerView: View {
    @EnvironmentObject private var store: PortalStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(store.schools) { school in
                Button {
                    store.selectSchool(school)
                    dismiss()
                } label: {
                    HStack {
                        Text(school.name)
                        Spacer()
                        if school.id == store.selectedSchool?.id {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                        }
                    }
                }
            }
            .navigationTitle("选择学校")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
        }
    }
}

struct PortalHomeView: View {
    @EnvironmentObject private var store: PortalStore
    @State private var showSchoolPicker = false

    var body: some View {
        NavigationStack {
            List {
                Section("常用入口") {
                    ForEach(store.definition?.groups.flatMap { $0.items }.filter { $0.quick == true } ?? []) { item in
                        NavigationLink(item.title) { NativePortalPageView(item: item) }
                    }
                }
                ForEach(store.definition?.groups ?? []) { group in
                    Section(group.title) {
                        ForEach(group.items) { item in
                            NavigationLink(item.title) { NativePortalPageView(item: item) }
                        }
                    }
                }
            }
            .navigationTitle(store.selectedSchool?.name ?? "掌上教务")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSchoolPicker = true } label: { Image(systemName: "building.columns") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("退出") { store.logout() }
                }
            }
            .sheet(isPresented: $showSchoolPicker) { SchoolPickerView() }
            .safeAreaInset(edge: .bottom) {
                Text("原生 iOS 迁移预览版 · 未经过实机测试")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity)
                    .background(.bar)
            }
        }
    }
}

struct NativePortalPageView: View {
    @EnvironmentObject private var store: PortalStore
    let item: PortalItem
    @State private var page: PortalPage?
    @State private var errorMessage: String?
    @State private var isLoading = true

    var body: some View {
        Group {
            if isLoading {
                ProgressView("加载中…")
            } else if let errorMessage {
                VStack(spacing: 12) {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.largeTitle)
                    Text("加载失败").font(.headline)
                    Text(errorMessage)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                .padding()
            } else if let page {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("HTTP \(page.statusCode)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(page.tables) { table in
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(Array(table.rows.enumerated()), id: \.offset) { index, row in
                                    Text(row.joined(separator: "  ·  "))
                                        .font(index == 0 ? .headline : .body)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(10)
                                        .background(index == 0 ? Color.accentColor.opacity(0.12) : Color.clear)
                                }
                            }
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                        }
                        if page.tables.isEmpty {
                            Text(page.text.isEmpty ? "页面没有可显示的结构化内容" : page.text)
                                .textSelection(.enabled)
                        }
                    }
                    .padding()
                }
                .refreshable { await load() }
            }
        }
        .navigationTitle(item.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            page = try await store.fetch(item)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}
