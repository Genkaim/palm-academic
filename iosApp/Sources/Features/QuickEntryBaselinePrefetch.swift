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
    /// The entry list captured once when the run starts. `items` is a computed property backed by
    /// `state.definition`; if the definition is briefly reloaded (nil/reparse) while the warm-up
    /// is walking entries, indexing the live, emptied list at `items[index + 1]` trapped. The
    /// warmer must walk exactly the list it started with.
    @State private var runItems: [PortalItem] = []
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
                NSLog("PalmAcademic/baseline: warming entry %@ (%@)", item.title, item.nativeType ?? "?")
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
        guard isActive else {
            NSLog(
                "PalmAcademic/baseline: skip warm-up (signedIn=%@ status=%@ pending=%@ items=%d)",
                state.isSignedIn ? "yes" : "no",
                String(describing: state.sessionStatus),
                QuickEntryBaseline.isPending(schoolID: schoolID) ? "yes" : "no",
                items.count
            )
            return
        }
        guard !items.isEmpty else {
            NSLog("PalmAcademic/baseline: skip warm-up, no quick items declared")
            return
        }
        NSLog("PalmAcademic/baseline: warm-up started for school %@ with %d entries", schoolID, items.count)
        runItems = items
        phase = .running(index: 0, failure: false)
        currentItem = runItems[0]
    }

    private func finish(_ item: PortalItem, snapshot: Snapshot?) {
        guard !itemFinished else { return }
        itemFinished = true
        var collected = snapshots
        if let snapshot { collected.append(snapshot) }
        let anyFailure = snapshot == nil || failedEarlier
        guard case .running(let index, _) = phase else { return }
        // Work off the frozen run list; never re-index a live list that may have changed.
        guard runItems.indices.contains(index) else {
            phase = .finished
            currentItem = nil
            return
        }
        if index == runItems.count - 1 {
            // Every quick entry has to have produced something. A partial baseline would make the
            // next check compare against a mixture of real and missing data, and the missing ones
            // would then read as "changed" forever.
            //
            // The count is the item list's own length rather than a fixed four: the earlier literal
            // meant a school that declared a fifth quick entry never established a baseline at all,
            // and the fetch looked like it simply did not happen.
            if !anyFailure && collected.count == runItems.count {
                NSLog("PalmAcademic/baseline: all %d entries captured, recording baseline", collected.count)
                QuickEntryBaseline.complete(
                    schoolID: schoolID,
                    snapshots: collected.map { ($0.item, $0.json) },
                    expectedCount: runItems.count
                )
            } else {
                // The common reason "首次基线没有日志": one entry never produced data within its
                // window, so the run stays pending instead of writing the baseline entry.
                NSLog(
                    "PalmAcademic/baseline: incomplete run, keeping pending (captured=%d, required=%d, failedEarlier=%@, lastHadSnapshot=%@)",
                    collected.count, runItems.count, failedEarlier ? "yes" : "no", snapshot != nil ? "yes" : "no"
                )
            }
            phase = .finished
            currentItem = nil
        } else if runItems.indices.contains(index + 1) {
            NSLog(
                "PalmAcademic/baseline: entry %@ finished (snapshot=%@), moving to next",
                item.title, snapshot != nil ? "yes" : "no"
            )
            snapshots = collected
            phase = .running(index: index + 1, failure: anyFailure)
            currentItem = runItems[index + 1]
        } else {
            phase = .finished
            currentItem = nil
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
            onContent: { page, json in
                // The raw JSON is read back rather than re-serialising the parsed page: the log
                // description and the later snapshot comparison both work off the adapter's own
                // output, and a round trip through the Swift model would lose fields they use.
                //
                // Keep every publication, including an empty one. The settle window below waits
                // ten seconds for an empty page and restarts whenever a newer payload arrives, so
                // an AJAX skeleton is replaced by real rows while a genuinely empty exam page can
                // still become a valid comparison baseline -- exactly how Android's warmer works.
                let populated = QuickEntryBaseline.hasData(page: page, nativeType: item.nativeType)
                NSLog(
                    "PalmAcademic/baseline: publication for %@ populated=%@ sections=%d",
                    item.title, populated ? "yes" : "no", page.sections.count
                )
                latestSnapshot = Snapshot(item: item, json: json, page: page)
                publicationVersion += 1
                Task { await settle(item) }
            },
            // A navigation error invalidates this item even if an earlier DOM skeleton happened
            // to publish. Android passes null here for the same reason: a partial four-page run
            // must remain pending rather than becoming the comparison baseline.
            onError: { _ in finish(item, snapshot: nil) },
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
        .id(item.url(baseURL: definition?.baseUrl ?? SchoolCatalog.shared.baseURL))
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
