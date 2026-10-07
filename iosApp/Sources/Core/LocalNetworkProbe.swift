import Foundation
import Network

/// Reports whether the app is actually allowed to reach the school's portal.
///
/// A university portal reached over the campus network resolves to a private address, and since
/// iOS 14 that needs the local-network permission. Without it the system refuses the connection
/// before a byte is sent, and it refuses *silently* from the caller's point of view: the URLSession
/// or the web view simply never completes, with nothing in the error the app can read. The only
/// outward sign is the system prompt, which is attributed to the process that owns the socket --
/// a sub-app running inside another host gets the host's name on it, or gets no prompt at all.
///
/// That makes "is this a permissions problem or a broken reader?" unanswerable from the UI, which
/// is exactly the wrong place to leave it. A direct TCP attempt to the portal host produces a
/// distinguishable answer instead: the policy refusal arrives as `EPERM`, which nothing else does.
///
/// Opening that socket is also what makes the permission obtainable. The system asks exactly once
/// per install, and it asks when something reaches for a campus address -- not when the app sets
/// up its own plumbing. A probe nobody ever runs therefore leaves the permission *undecided*, not
/// merely unreported: the prompt never appears, every later load fails quietly, and the page looks
/// broken. That is why `AppState.bootstrap` asks for the answer as soon as the school is known.
@MainActor
final class LocalNetworkProbe: ObservableObject {
    static let shared = LocalNetworkProbe()

    enum State: Equatable {
        case unknown
        case probing
        /// The portal answered a direct TCP handshake.
        case allowed
        /// The system refused the private-address connection.
        case denied
        /// The name does not resolve, or the host is unreachable.
        case unreachable(String)

        var label: String {
            switch self {
            case .unknown: return "尚未检测"
            case .probing: return "检测中…"
            case .allowed: return "已授权"
            case .denied: return "未授权"
            case .unreachable(let reason): return reason
            }
        }

        var isHealthy: Bool { self == .allowed }
    }

    @Published private(set) var state: State = .unknown
    /// Last server the answer was about, so a school switch does not leave a stale result showing.
    private var lastEndpoint: PortalEndpoint?
    /// Guards against a probe being started again while one is already out.
    private var inFlight = false

    private init() {}

    /// Runs the probe unless it has already answered for this server.
    ///
    /// The answer is cached rather than per launch: the permission cannot change without the app
    /// being reinstalled or the user visiting Settings, so re-asking every time a screen appears
    /// would only cost battery.
    func probe(force: Bool = false) async {
        guard let endpoint = Self.portalEndpoint else {
            state = .unreachable("学校地址不可用")
            return
        }
        if !force, lastEndpoint == endpoint, state != .unknown, state != .probing { return }
        guard !inFlight else { return }

        lastEndpoint = endpoint
        inFlight = true
        state = .probing

        // `.tcp` with no TLS: the point is whether the socket may be opened at all, which is the
        // question the policy governs. Handshaking with TLS would add a certificate problem to a
        // question that is not about certificates.
        let connection = NWConnection(
            host: NWEndpoint.Host(endpoint.host),
            port: NWEndpoint.Port(rawValue: endpoint.port) ?? 443,
            using: .tcp
        )

        connection.stateUpdateHandler = { [weak self] connectionState in
            let finish: (State) -> Void = { result in
                Task { @MainActor in
                    self?.inFlight = false
                    self?.state = result
                }
                connection.cancel()
            }

            switch connectionState {
            case .ready:
                finish(.allowed)
            case .failed(let error):
                finish(Self.classify(error))
            case .waiting(let error):
                // A waiting state on a private address is what a policy refusal looks like before
                // it is promoted to a failure, so it is reported as a denial rather than retried
                // forever.
                if Self.isPermissionDenial(error) { finish(.denied) }
            case .cancelled:
                break
            default:
                break
            }
        }

        connection.start(queue: .global(qos: .utility))
        // The probe must not be able to hold the app up, and a portal that accepts no answer is
        // indistinguishable from one that refused without a policy, so give it a moment and stop.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.timeout) {
            Task { @MainActor in
                guard self.inFlight, self.state == .probing else { return }
                self.inFlight = false
                self.state = .unreachable("无响应")
                connection.cancel()
            }
        }
    }

    /// Long enough for a campus DNS lookup and one round trip on a slow network, short enough that
    /// nobody is waiting on the answer. The state is only read from a settings page, so nothing in
    /// the app's own flow is blocked by this either way.
    private static let timeout: TimeInterval = 3

    /// The server the portal is reached at: host *and port*, taken from the selected school's own
    /// origin so the probe asks the question the reader asks.
    ///
    /// The port has to come from the origin rather than being assumed. A probe pointed at 443
    /// against a portal served over http is refused by the server instead of by policy, and a
    /// refusal and a refusal-by-policy are the same string to the person reading it, so the wrong
    /// port turns a reachable server into a false "未授权".
    private struct PortalEndpoint: Equatable {
        let host: String
        let port: UInt16
    }

    private static var portalEndpoint: PortalEndpoint? {
        guard let url = URL(string: SchoolCatalog.shared.origin),
              let host = url.host, !host.isEmpty else { return nil }
        if let port = url.port, port > 0, port <= Int(UInt16.max) {
            return PortalEndpoint(host: host, port: UInt16(port))
        }
        return PortalEndpoint(host: host, port: url.scheme == "https" ? 443 : 80)
    }

    /// `EPERM` is the signature of a policy refusal. A refused socket is not an ordinary network
    /// failure -- those surface as timeouts, resets or name-resolution errors -- so separating it
    /// here is what makes the answer useful.
    private static func isPermissionDenial(_ error: NWError) -> Bool {
        switch error {
        case .posix(let code):
            return code == POSIXErrorCode.EPERM
        case .dns(let code):
            // DNS reports its own refusals as kDNSServiceErr_* values, not as errno, so the two
            // cases cannot share a comparison. kDNSServiceErr_PolicyDenied is what the local
            // network restriction produces on a name lookup.
            return Int32(code) == Self.dnsPolicyDenied || Int32(code) == POSIXErrorCode.EPERM.rawValue
        default:
            return false
        }
    }

    private static let dnsPolicyDenied: Int32 = -65570

    private static func classify(_ error: NWError) -> State {
        if isPermissionDenial(error) { return .denied }
        switch error {
        case .posix(let code): return .unreachable("连接被拒绝（\(code)）")
        case .dns: return .unreachable("域名无法解析")
        case .tls: return .unreachable("TLS 握手失败")
        default: return .unreachable("无法连接")
        }
    }
}
