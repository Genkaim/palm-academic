import SwiftUI
import WebKit

/// Port of `QuickEntryBaselinePrefetch` from `HomeActivity.kt`.
///
/// Android warms the four quick entries once, after a real login: it walks them in order with a
/// hidden reader, keeps the last publication each one produces, waits for the page to settle, and
/// only then records the baseline. That baseline is what every later check compares against, so
/// without it the first background run reports four simultaneous "changes" that are really just the
/// first observation.
///
/// The timing rules are the point and are copied rather than simplified:
///
/// - A page that already has data settles after 4s; one that does not waits 10s, because
///   adapters commonly publish an empty DOM skeleton first and fill it after their own XHR.
/// - Either way there is a 2s quiet period on top of the remaining minimum.
/// - A page that never publishes at all is given 30s, then counted as a failure.
///
/// A failure anywhere abandons the whole run: a partial baseline would make the next check compare
/// against a mixture of real and missing data.
struct QuickEntryBaselinePrefetch: View {
    @EnvironmentObject private var state: AppState

    /// One publication: the item it came from, the adapter's own JSON (what the log and the
    /// later snapshot comparison work off) and the parsed page (what the settle window inspects).
    private struct Snapshot {
        let item: PortalItem
        let json: String
        let page: MaterialPage
    }

    private enum Phase {
        case idle
        case running(index: Int, failure: Bool)
        case finished
    }

    @State private var phase: Phase = .idle
    /// The page currently being warmed. A single reader is shown and retargeted, which is what
    /// "serially" means here: four concurrent readers would fight over one cookie jar and one
    /// network, and Android deliberately does not do that either.
    @State private var currentItem: PortalItem?
    @State private var snapshots: [Snapshot] = []
    /// The latest publication for the current item, plus a counter that forces the settle effect
    /// to restart whenever a newer one arrives.
    @State private var latestSnapshot: Snapshot?
    @State private var publicationVersion = 0
    @State private var startedAt = Date()
    @State private var itemFinished = false

    private var definition: SchoolDefinition? { state.definition }
    private var items: [PortalItem] {
        QuickEntryBaseline.orderedQuickBaselineItems(definition?.quickItems ?? [])
    }
    private var schoolID: String { SchoolCatalog.shared.selectedSchoolID }

    private var isActive: Bool {
        state.sessionStatus == .hidden && state.isSignedIn && QuickEntryBaseline.isPending(schoolID: schoolID)
    }
    var body: some View {
        // Android arms the prefetch three seconds after the home screen settles, so the first
        // paint is not competing with four page loads. The same delay is used here.
        Color.clear
            // WKWebView must receive a real viewport for the portal's responsive scripts and XHR
            // bootstrap to run. A 1×1 reader frequently stayed at the empty DOM shell, so the
            // supposedly automatic four-page refresh never populated its cache.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .opacity(0.01)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .task { await runIfNeeded() }
            .onChange(of: currentItem) { item in
                guard let item else { return }
                startedAt = Date()
                itemFinished = false
                latestSnapshot = nil
                publicationVersion += 1
                Task {
                    try? await Task.sleep(nanoseconds: 30_000_000_000)
                    finish(item, snapshot: latestSnapshot)
                }
            }
            .overlay {
                if let currentItem {
                    reader(for: currentItem)
                }
            }
    }

    // MARK: - Run

    private func runIfNeeded() async {
        // Wait out the first paint before touching the network.
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        guard isActive, !items.isEmpty else { return }
        phase = .running(index: 0, failure: false)
        currentItem = items[0]
    }

    private func finish(_ item: PortalItem, snapshot: Snapshot?) {
        guard !itemFinished else { return }
        itemFinished = true
        var collected = snapshots
        if let snapshot { collected.append(snapshot) }
        let anyFailure = snapshot == nil || failedEarlier
        guard case .running(let index, _) = phase else { return }
        if index == items.count - 1 {
            // Every quick entry has to have produced something. A partial baseline would make the
            // next check compare against a mixture of real and missing data, and the missing ones
            // would then read as "changed" forever.
            //
            // The count is the item list's own length rather than a fixed four: the earlier literal
            // meant a school that declared a fifth quick entry never established a baseline at all,
            // and the fetch looked like it simply did not happen.
            if !anyFailure && collected.count == items.count {
                QuickEntryBaseline.complete(
                    schoolID: schoolID,
                    snapshots: collected.map { ($0.item, $0.json) }
                )
            }
            phase = .finished
            currentItem = nil
        } else {
            snapshots = collected
            phase = .running(index: index + 1, failure: anyFailure)
            currentItem = items[index + 1]
        }
    }

    private var failedEarlier: Bool {
        if case .running(_, let failure) = phase { return failure }
        return false
    }

    // MARK: - Reader

    private func reader(for item: PortalItem) -> some View {
        MaterialReaderView(
            url: item.url(baseURL: definition?.baseUrl ?? SchoolCatalog.shared.baseURL),
            adapterScript: SchoolCatalog.shared.readAdapterScript(assetPath: definition?.readerAdapter ?? ""),
            schoolConfigJSON: SchoolCatalog.shared.readerConfigJSON(),
            nativeType: item.nativeType,
            refreshToken: 0,
            action: nil,
            isDark: state.isDark,
            onLoading: { _ in },
            onContent: { page in
                // The raw JSON is read back rather than re-serialising the parsed page: the log
                // description and the later snapshot comparison both work off the adapter's own
                // output, and a round trip through the Swift model would lose fields they use.
                //
                // Only a populated page seeds the baseline: an interim "暂无…" skeleton publication
                // would otherwise be recorded as the first observation and make the real data read
                // as a change on the next check.
                guard QuickEntryBaseline.hasData(page: page, nativeType: item.nativeType) else { return }
                guard let json = MaterialPageCache.loadRaw(url: item.url(baseURL: definition?.baseUrl ?? SchoolCatalog.shared.baseURL)) else { return }
                latestSnapshot = Snapshot(item: item, json: json, page: page)
                publicationVersion += 1
                Task { await settle(item) }
            },
            onError: { _ in finish(item, snapshot: latestSnapshot) },
            onSessionExpired: {
                // A hidden reader can briefly see a redirect. Confirm centrally rather than
                // dropping the user to the login screen from a page they never opened -- and do
                // it QUIETLY: a loud check here flashed the "登录中" badge on the home screen
                // right after a perfectly good login. On success the refresh bus reloads every
                // visible reader; only a hard "expired" answer surfaces the retry badge.
                Task { await state.revalidateQuietlyPublic() }
            },
            onDiagnostic: { _ in }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(0.01)
        .allowsHitTesting(false)
    }

    /// The settle window, ported from Android's `LaunchedEffect(item.url, publicationVersion)`.
    private func settle(_ item: PortalItem) async {
        // A newer publication restarts the window, so the page has to go quiet before it counts.
        let version = publicationVersion
        try? await Task.sleep(nanoseconds: 200_000_000)
        guard version == publicationVersion, !itemFinished else { return }

        let hasData = latestSnapshot.map {
            QuickEntryBaseline.hasData(page: $0.page, nativeType: item.nativeType)
        } ?? false
        let minimum: Double = hasData ? 4_000_000_000 : 10_000_000_000
        let elapsed = Date().timeIntervalSince(startedAt) * 1_000_000_000
        let remaining = max(0, minimum - elapsed)
        try? await Task.sleep(nanoseconds: UInt64(max(2_000_000_000, remaining)))
        finish(item, snapshot: latestSnapshot)
    }
}
