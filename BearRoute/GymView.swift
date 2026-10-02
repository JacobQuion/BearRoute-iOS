//
//  GymView.swift
//  Bear Route
//
//  RecWell publishes the RSF weight room's live occupancy through a Density
//  SAFE display, embedded on their own page with a public share token:
//
//      https://recwell.berkeley.edu/facilities/recreational-sports-facility-rsf/
//          rsf-weight-room-crowd-meter/
//
//  Density's SAFE display is a JavaScript app and its underlying API isn't
//  publicly documented, so rather than guess at an endpoint we embed the exact
//  display RecWell embeds. It always shows whatever their own page shows.
//

import SwiftUI
import WebKit

enum RSF {
    /// The live weight room meter, taken verbatim from RecWell's page.
    static let weightRoomMeter = URL(string: "https://safe.density.io/#/displays/dsp_956223069054042646?token=shr_o69HxjQ0BYrY2FPD9HxdirhJYcFDCeRolEd744Uj88e")!

    static let hoursPage = URL(string: "https://recwell.berkeley.edu/facilities/recreational-sports-facility-rsf/rsf-hours/")!
    static let cardioMeterPage = URL(string: "https://recwell.berkeley.edu/facilities/recreational-sports-facility-rsf/rsf-cardio-equipment-usage-meter/")!
    static let facilityPage = URL(string: "https://recwell.berkeley.edu/facilities/recreational-sports-facility-rsf/")!
    /// Native Apple Maps directions to the RSF.
    static let maps = URL(string: "https://maps.apple.com/?daddr=2301+Bancroft+Way,+Berkeley,+CA+94720&ll=37.868578,-122.265017")!

    static let address = "2301 Bancroft Way, Berkeley, CA 94720"
}

// MARK: - Occupancy scraper

/// Whether the meter page reached the network and yielded a reading.
enum MeterLoadState {
    case loading, loaded, failed
}

/// An offscreen web view that loads Density's crowd-meter widget and scrapes
/// the occupancy percentage out of its rendered page, reporting it back so the
/// app can draw a native circular gauge instead of embedding the whole widget.
///
/// Density's SAFE display is an undocumented JavaScript app, so this reads the
/// first "NN%" it finds in the page text. It's inherently best-effort: if their
/// markup changes and no percentage is found, `loadState` falls back to
/// `.failed` and the gauge shows a graceful note.
struct OccupancyScraper: UIViewRepresentable {
    let url: URL
    /// Bumping this from the parent triggers a reload + re-scrape.
    var reloadCount: Int
    @Binding var occupancy: Int?
    @Binding var loadState: MeterLoadState

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: OccupancyScraper
        var lastReloadCount = 0
        weak var webView: WKWebView?
        private var timer: Timer?
        /// Scrapes to run at these delays after a load, to catch the JS render.
        /// Front-loaded so the first reading can appear as soon as the widget
        /// paints, with later attempts as a fallback if it renders slowly.
        private let scrapeDelays: [TimeInterval] = [0.5, 1.2, 2.5, 4.0, 6.5]

        init(_ parent: OccupancyScraper) { self.parent = parent }

        deinit { timer?.invalidate() }

        private func report(_ state: MeterLoadState) {
            DispatchQueue.main.async { self.parent.loadState = state }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            scheduleScrapes()
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            report(.failed)
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            report(.failed)
        }

        /// A burst of scrapes right after load (the widget renders async), then
        /// a slow repeating refresh to keep the reading live.
        func scheduleScrapes() {
            for delay in scrapeDelays {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.scrape()
                }
            }
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                self?.scrape()
            }
            // If none of the burst scrapes find a number, surface the failure.
            DispatchQueue.main.asyncAfter(deadline: .now() + scrapeDelays.last! + 2) { [weak self] in
                guard let self else { return }
                if self.parent.occupancy == nil { self.report(.failed) }
            }
        }

        func scrape() {
            let js = "(function(){var m=document.body.innerText.match(/(\\d{1,3})\\s*%/);return m?m[1]:null;})();"
            webView?.evaluateJavaScript(js) { [weak self] result, _ in
                guard let self, let text = result as? String, let value = Int(text),
                      (0...100).contains(value) else { return }
                DispatchQueue.main.async {
                    self.parent.occupancy = value
                    self.parent.loadState = .loaded
                }
            }
        }
    }

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        webView.load(URLRequest(url: url))
        context.coordinator.lastReloadCount = reloadCount
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        guard context.coordinator.lastReloadCount != reloadCount else { return }
        context.coordinator.lastReloadCount = reloadCount
        DispatchQueue.main.async {
            self.occupancy = nil
            self.loadState = .loading
        }
        webView.load(URLRequest(url: url))
    }
}

// MARK: - Crowd ring

/// A native circular occupancy gauge: a ring that sweeps up from 0% to the
/// live reading, its color sliding green → yellow → orange → red as it
/// travels around, with the number counting up in step. The sweep replays
/// every time the RSF tab is opened.
struct CrowdRing: View {
    let percent: Int?

    /// Drives the whole gauge. Animating this one value is what makes the arc
    /// travel around the ring instead of snapping to its final length.
    @State private var sweep: Double = 0

    /// The in-flight sweep, held so a replay can cancel the one before it and
    /// so a sweep isn't left running after the tab is switched away.
    @State private var sweepTask: Task<Void, Never>?

    /// The RSF screen is never torn down — it just gets hidden behind another
    /// section — so this, rather than `onAppear`, is what tells the ring it's
    /// being opened again.
    @Environment(\.isSectionVisible) private var isSectionVisible

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.12), lineWidth: 20)

            // Kept in the hierarchy even before the first reading arrives, so
            // the sweep has a 0% starting point to animate away from.
            CrowdRingGauge(sweep: sweep)
                .opacity(percent == nil ? 0 : 1)

            if percent == nil {
                ProgressView()
            }
        }
        .frame(width: 210, height: 210)
        // Every visit to the tab replays the sweep, so the ring always fills
        // from 0 on screen rather than sitting at the number it was left on.
        .onAppear { startSweep() }
        .onChange(of: isSectionVisible) { _, _ in startSweep() }
        .onChange(of: percent) { _, _ in startSweep() }
        .onDisappear { sweepTask?.cancel() }
    }

    /// Rewinds the ring to 0 and sends it back up to the current reading.
    /// While the tab is hidden it just parks at 0, so a reading that lands
    /// offscreen still gets its full sweep the next time the tab is opened.
    private func startSweep() {
        sweepTask?.cancel()
        sweep = 0
        guard let percent, isSectionVisible else { return }

        sweepTask = Task { @MainActor in
            // Let the rewind render before animating. Set back to back, the
            // two updates coalesce and the arc eases from wherever it was
            // left instead of travelling the whole way up from 0.
            try? await Task.sleep(for: .milliseconds(30))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 1.4)) {
                sweep = Double(percent)
            }
        }
    }
}

/// The animating half of ``CrowdRing``. Conforming the view itself to
/// `Animatable` means SwiftUI re-runs `body` on every frame of the sweep, so
/// the arc, its color, and the readout all track the same in-flight value.
@Animatable
private struct CrowdRingGauge: View {
    var sweep: Double

    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0, to: min(max(sweep, 0), 100) / 100)
                .stroke(Self.color(at: sweep),
                        style: StrokeStyle(lineWidth: 20, lineCap: .round))
                .rotationEffect(.degrees(-90))

            Text("\(Int(sweep.rounded()))%")
                .font(.system(size: 46, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary)
        }
    }

    /// The color the arc passes through on its way up: calm green while the
    /// room is quiet, then yellow, orange, and red once it's packed. Stops are
    /// bunched low so even a middling reading like 50% crosses two of them —
    /// the color visibly travels with the arc rather than settling on one hue.
    private static let stops: [(mark: Double, color: Color)] = [
        (0,   Color(red: 0.13, green: 0.78, blue: 0.44)),
        (30,  Color(red: 0.85, green: 0.86, blue: 0.20)),
        (55,  Color(red: 0.98, green: 0.62, blue: 0.15)),
        (80,  Color(red: 0.94, green: 0.32, blue: 0.20)),
        (100, Color(red: 0.86, green: 0.15, blue: 0.28))
    ]

    /// The point on that scale for a given reading, interpolated between the
    /// surrounding stops so the hue slides continuously instead of snapping.
    private static func color(at percent: Double) -> Color {
        let value = min(max(percent, 0), 100)
        guard let upper = stops.firstIndex(where: { $0.mark >= value }), upper > 0 else {
            return stops[0].color
        }
        let low = stops[upper - 1], high = stops[upper]
        return low.color.mix(with: high.color,
                             by: (value - low.mark) / (high.mark - low.mark))
    }
}

// MARK: - Screen

struct GymView: View {
    @State private var reloadCount = 0
    @State private var meterState: MeterLoadState = .loading
    @State private var occupancy: Int?
    /// Bumped by the top bar's refresh button.
    @Environment(\.refreshToken) private var refreshToken

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    meterCard
                    infoCard
                }
                .padding(16)
            }
            .navigationTitle("RSF")
            .navigationBarTitleDisplayMode(.inline)
            // The app's top bar names the section and carries refresh.
            .toolbar(.hidden, for: .navigationBar)
            .refreshable {
                reloadCount += 1
            }
            .onChange(of: refreshToken) { _, _ in
                reloadCount += 1
            }
        }
    }

    // MARK: Live meter

    private var meterCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "dumbbell.fill")
                    .foregroundStyle(Theme.californiaGold)
                Text("Crowd Meter")
                    .font(.headline)
                    .foregroundStyle(Theme.readableBlue)
            }

            ZStack {
                // Offscreen data source: loads Density's widget and scrapes the
                // percentage. Kept in the hierarchy (opacity 0) so its JS runs.
                OccupancyScraper(url: RSF.weightRoomMeter, reloadCount: reloadCount,
                                 occupancy: $occupancy, loadState: $meterState)
                    .frame(width: 240, height: 240)
                    .opacity(0)
                    .allowsHitTesting(false)

                if meterState == .failed && occupancy == nil {
                    meterUnavailable
                } else {
                    CrowdRing(percent: occupancy)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 260)

            Text("Live weight room occupancy · pull down to refresh")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
    }

    /// Shown over the meter when its embedded page can't reach the network.
    private var meterUnavailable: some View {
        VStack(spacing: 10) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 34))
                .foregroundStyle(Theme.californiaGold)
            Text("Couldn't load the crowd meter")
                .font(.subheadline.weight(.semibold))
                .multilineTextAlignment(.center)
            Text("Check your connection and try again.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Retry") {
                reloadCount += 1
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.control)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: Links

    private var infoCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            row(icon: "figure.run", title: "Cardio equipment meter", url: RSF.cardioMeterPage)
            Divider().padding(.leading, 44)
            row(icon: "clock", title: "RSF hours", url: RSF.hoursPage)
            Divider().padding(.leading, 44)
            mapsRow
            Divider().padding(.leading, 44)
            row(icon: "building.2", title: "About the facility", url: RSF.facilityPage)
        }
        .padding(.vertical, 4)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
    }

    /// A directions row that makes clear it opens the native Apple Maps app,
    /// with the RSF's street address shown beneath.
    private var mapsRow: some View {
        Link(destination: RSF.maps) {
            HStack(spacing: 12) {
                Image(systemName: "map.fill")
                    .foregroundStyle(Theme.californiaGold)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Directions in Apple Maps")
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                    Text(RSF.address)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    private func row(icon: String, title: String, url: URL) -> some View {
        Link(destination: url) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .foregroundStyle(Theme.californiaGold)
                    .frame(width: 20)
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }
}

#Preview {
    GymView()
}
