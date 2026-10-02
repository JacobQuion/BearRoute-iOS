//
//  ContentView.swift
//  Bear Route
//
//  Created by Jacob Quion on 7/30/26.
//

import SwiftUI

extension EnvironmentValues {
    /// Whether the section a view belongs to is the one currently on screen.
    /// Every section is kept alive in a stack, so `onAppear` fires only once
    /// per launch — screens that need to restart something each time they're
    /// opened (the RSF crowd ring's sweep) watch this instead.
    @Entry var isSectionVisible = true

    /// Bumped each time the top bar's refresh button is tapped for the
    /// section a view belongs to. Sections reload when it changes.
    @Entry var refreshToken = 0
}

struct ContentView: View {
    /// Shows the branded launch screen briefly on startup, then reveals the app.
    @State private var showingSplash = true

    /// App-wide appearance, toggled from the Dining tab's top-right menu.
    /// Defaults to dark; persisted across launches.
    @AppStorage("isDarkMode") private var isDarkMode = true

    /// Owned here (not inside LibraryView) so its hours can start fetching during
    /// the splash — the Library tab is then already loaded when the user opens it.
    @StateObject private var libraryModel = LibraryViewModel()

    /// Owned here so the top bar's gear can show its diagnostics.
    @StateObject private var diningModel = DiningViewModel()

    /// How many times each section's refresh has been requested from the top
    /// bar, handed to that section as its `refreshToken`.
    @State private var refreshCounts: [AppSection: Int] = [:]

    /// Presents the Dining fetch diagnostics, opened from the gear menu.
    @State private var showingDiagnostics = false

    /// The section currently on screen, chosen from the top drop-down menu.
    @State private var section: AppSection = .dining

    /// Whether the full-width section panel is expanded below the top bar.
    @State private var showMenu = false

    /// Drives the status bar above the bottom nav into its "loading" state for a
    /// short beat whenever the section changes, so switching tabs reads as the
    /// new screen spinning up.
    @State private var isTabLoading = false

    /// Measured height of the top bar (title strip + status line, excluding
    /// the color that bleeds into the status-bar area). The section panel
    /// uses it to sit flush beneath the bar.
    @State private var barHeight: CGFloat = 56

    /// The status bar shows loading while a tab switch settles, or while the
    /// Library's hours are actually being fetched (its model lives here).
    private var isSectionLoading: Bool {
        isTabLoading || (section == .library && libraryModel.isLoading)
    }

    var body: some View {
        ZStack {
            main

            sectionPanelOverlay

            if showingSplash {
                SplashView()
                    .transition(.opacity)
            }
        }
        .preferredColorScheme(isDarkMode ? .dark : .light)
        .sheet(isPresented: $showingDiagnostics) {
            DiagnosticsView(text: diningModel.diagnostics.summary)
        }
        .task {
            // Prefetch library hours up front, independently of the splash timer.
            Task { await libraryModel.load() }
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation(.easeOut(duration: 0.45)) { showingSplash = false }
        }
    }

    /// All sections are kept alive and stacked; only the chosen one is visible
    /// and interactive, so switching between them preserves each screen's state
    /// (scroll position, loaded data) the way the old tab bar did. The drop-down
    /// menu is stacked above the sections so it never covers content. (Not a
    /// safe-area inset: the sections' navigation bars ignore custom insets, so
    /// an inset bar would sit on top of them and hide their back buttons.)
    private var main: some View {
        VStack(spacing: 0) {
            sectionMenu

            ZStack {
                ForEach(AppSection.allCases) { item in
                    view(for: item)
                        .opacity(section == item ? 1 : 0)
                        .allowsHitTesting(section == item)
                        .zIndex(section == item ? 1 : 0)
                        .environment(\.isSectionVisible, section == item)
                        .environment(\.refreshToken, refreshCounts[item, default: 0])
                }
            }
            // Breathing room between the blue bar and each screen's content.
            // A scroll margin (rather than padding) so the screens' own
            // backgrounds still run right up to the bar.
            .contentMargins(.top, 12, for: .scrollContent)
        }
        .onChange(of: section) { _, _ in
            isTabLoading = true
            Task {
                try? await Task.sleep(for: .milliseconds(750))
                isTabLoading = false
            }
        }
    }

    @ViewBuilder
    private func view(for section: AppSection) -> some View {
        switch section {
        case .dining: DiningView(model: diningModel)
        case .library: LibraryView(model: libraryModel)
        case .gym: GymView()
        case .events: EventsView()
        case .game: GameView()
        }
    }

    /// The top bar that replaces the tab bar: an edge-to-edge dark blue strip
    /// naming the current section, with refresh and settings on the trailing
    /// side and the animated status line running directly beneath it. Tapping the strip
    /// toggles the section panel. The blue bleeds past the safe area so it fills
    /// the status-bar band too.
    private var sectionMenu: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Button {
                    withAnimation(menuFoldAnimation) { showMenu.toggle() }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: section.icon)
                        Text(section.title)
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.subheadline.weight(.semibold))
                            .rotationEffect(.degrees(showMenu ? 180 : 0))
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, 20)
                    .padding(.trailing, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                // The game has nothing to reload.
                if section != .game {
                    refreshButton
                        .padding(.trailing, 18)
                }

                settingsMenu
                    .padding(.trailing, 20)
            }
            .font(.headline)
            .foregroundStyle(.white)
            .padding(.vertical, 10)

            TabLoadingBar(isLoading: isSectionLoading)
        }
        .background(Theme.berkeleyBlue.ignoresSafeArea(edges: .top))
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { height in
            barHeight = height
        }
    }

    /// Reloads the current section by bumping its `refreshToken`.
    private var refreshButton: some View {
        Button {
            refreshCounts[section, default: 0] += 1
        } label: {
            Image(systemName: "arrow.clockwise")
                .foregroundStyle(.white)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Refresh")
    }

    /// App-wide settings, reachable from every section via the bar's gear.
    /// On Dining it also carries that screen's Diagnostics, which used to
    /// live in the Dining screen's own toolbar.
    private var settingsMenu: some View {
        Menu {
            Button {
                isDarkMode.toggle()
            } label: {
                Label(isDarkMode ? "Light Mode" : "Dark Mode",
                      systemImage: isDarkMode ? "sun.max" : "moon")
            }
            if section == .dining {
                Button {
                    showingDiagnostics = true
                } label: {
                    Label("Diagnostics", systemImage: "stethoscope")
                }
            }
        } label: {
            Image(systemName: "gearshape")
                .foregroundStyle(.white)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Settings")
    }

    /// A dimming scrim plus a full-width panel that folds down out of the top
    /// bar and lists every section. Built by hand because a SwiftUI `Menu`
    /// popover is system-sized and can't be forced to span the full screen
    /// width. Its charcoal surface sets it apart from the bar's blue, so the
    /// open menu reads as a panel hanging in front of the screen.
    @ViewBuilder
    private var sectionPanelOverlay: some View {
        if showMenu {
            ZStack(alignment: .top) {
                Color.black.opacity(0.45)
                    .ignoresSafeArea()
                    .onTapGesture { closeMenu() }
                    .transition(.opacity)

                VStack(spacing: 0) {
                    ForEach(AppSection.allCases) { item in
                        Button {
                            section = item
                            closeMenu()
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: item.icon)
                                    .frame(width: 26)
                                Text(item.title)
                                Spacer(minLength: 0)
                                if section == item {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Theme.skyBlue)
                                }
                            }
                            .font(.headline)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(section == item ? Color.white.opacity(0.10) : .clear)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if item != AppSection.allCases.last {
                            Divider()
                                .overlay(Color.white.opacity(0.14))
                                .padding(.leading, 24)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .background(Theme.menuPanel)
                .clipShape(
                    UnevenRoundedRectangle(bottomLeadingRadius: 18,
                                           bottomTrailingRadius: 18,
                                           style: .continuous)
                )
                .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
                // Hinges open from its own top edge, so it must be applied
                // before the padding that seats the panel below the bar.
                .transition(.fold)
                // Seat the panel directly on the bar's bottom edge.
                .padding(.top, barHeight)
            }
            .zIndex(5)
        }
    }

    private func closeMenu() {
        withAnimation(menuFoldAnimation) { showMenu = false }
    }
}

/// Timing for the section panel's fold, shared by the open and close paths. A
/// spring with a touch of overshoot so the panel settles like a hinged flap
/// rather than sliding.
private let menuFoldAnimation = Animation.spring(response: 0.34, dampingFraction: 0.78)

/// Unfolds a view downward about its top edge, as though it were hinged there.
/// Pairs with `menuFoldAnimation`; the 82° start keeps the panel from passing
/// fully edge-on, which reads as a flicker at small sizes.
private struct FoldDown: Transition {
    func body(content: Content, phase: TransitionPhase) -> some View {
        content
            .rotation3DEffect(.degrees(phase.isIdentity ? 0 : -82),
                              axis: (x: 1, y: 0, z: 0),
                              anchor: .top,
                              perspective: 0.6)
            .opacity(phase.isIdentity ? 1 : 0)
    }
}

private extension AnyTransition {
    static var fold: AnyTransition { AnyTransition(FoldDown()) }
}

/// The app's top-level sections, surfaced through the top drop-down menu.
enum AppSection: String, CaseIterable, Identifiable {
    case dining, library, gym, events, game

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dining: "Dining"
        case .library: "Libraries"
        case .gym: "Exercise"
        case .events: "Events"
        case .game: "Easter Egg Game"
        }
    }

    var icon: String {
        switch self {
        case .dining: "fork.knife"
        case .library: "books.vertical"
        case .gym: "figure.run"
        case .events: "calendar"
        case .game: "gamecontroller.fill"
        }
    }
}

/// A slim status bar running along the bottom of the dark blue nav strip. At
/// rest it "breathes" — a faint light rule gently pulsing its opacity. While a
/// tab is loading it turns into a sky-blue segment that sweeps left → right on
/// a loop, reading as busy without a spinner.
struct TabLoadingBar: View {
    let isLoading: Bool

    /// Drives the idle breathing pulse (opacity), running while not loading.
    @State private var breathe = false

    /// Drives the loading sweep (horizontal offset), running while loading.
    @State private var sweep = false

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let segment = width * 0.35
            ZStack(alignment: .leading) {
                // The idle/track rule, a subtle sky blue that breathes when
                // not loading.
                Rectangle()
                    .fill(Theme.skyBlue)
                    .opacity(isLoading ? 0.28 : (breathe ? 0.55 : 0.18))

                // The travelling sky-blue segment shown only while loading.
                if isLoading {
                    Capsule()
                        .fill(Theme.skyBlue.opacity(0.9))
                        .frame(width: segment)
                        .offset(x: sweep ? width : -segment)
                }
            }
            .clipped()
        }
        .frame(height: 3)
        .animation(.easeInOut(duration: 0.3), value: isLoading)
        .onAppear { restartAnimation() }
        .onChange(of: isLoading) { _, _ in restartAnimation() }
    }

    /// Kicks off whichever looping animation matches the current state: the
    /// left-to-right sweep while loading, or the gentle breathing pulse at rest.
    private func restartAnimation() {
        if isLoading {
            sweep = false
            withAnimation(.linear(duration: 0.5).repeatForever(autoreverses: false)) {
                sweep = true
            }
        } else {
            breathe = false
            withAnimation(.easeInOut(duration: 4.5).repeatForever(autoreverses: true)) {
                breathe = true
            }
        }
    }
}

/// The branded launch screen: the Bear Route logo centered on the app's dark
/// blue, with a small "not affiliated" disclaimer pinned to the bottom.
struct SplashView: View {
    var body: some View {
        ZStack {
            Theme.berkeleyBlue.ignoresSafeArea()

            VStack {
                Spacer()
                Image("AppLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 260)
                Spacer()
                Text("This app is not affiliated with UC Berkeley.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.bottom, 24)
            }
        }
    }
}

#Preview {
    ContentView()
}
