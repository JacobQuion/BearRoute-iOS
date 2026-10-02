//
//  GameView.swift
//  Bear Route
//
//  A little easter egg: "Catch Oski" is a whack-a-mole style tap game. Oski
//  pops up on a grid and you have a few seconds to tap as many as you can.
//  No assets needed — everything is drawn with SF Symbols and the app theme.
//

import SwiftUI

struct GameView: View {
    /// Tiles on the board: three columns, four rows.
    private let tileCount = 12
    /// Background for a tile the player mistakenly tapped.
    private static let missRed = Color(red: 0.78, green: 0.12, blue: 0.12)
    /// How long a round lasts, in seconds.
    private let roundLength = 10

    @State private var activeTile: Int? = nil
    @State private var score = 0
    @State private var bestScore = 0
    @State private var timeRemaining = 0
    @State private var isPlaying = false
    /// Briefly flashes the tile the player just tapped for feedback.
    @State private var lastHitTile: Int? = nil
    /// Briefly flashes red on the tile the player tapped by mistake.
    @State private var missedTile: Int? = nil
    /// Oski's party, shown after a round that sets a new personal best.
    @State private var showCelebration = false

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    scoreboard

                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(0..<tileCount, id: \.self) { index in
                            tile(at: index)
                        }
                    }

                    controlButton
                }
                .padding(16)
            }
            // A fourth row of square tiles runs past the bottom of a short
            // screen, so let the board scroll — but only when it has to.
            .scrollBounceBehavior(.basedOnSize)
            // The app's top bar already names the section.
            .toolbar(.hidden, for: .navigationBar)
            .overlay {
                if showCelebration {
                    celebration
                }
            }
        }
    }

    // MARK: Celebration

    private var celebration: some View {
        ZStack {
            Color.black.opacity(0.65)
                .ignoresSafeArea()
                .onTapGesture { dismissCelebration() }

            ConfettiView()

            VStack(spacing: 16) {
                BouncingOski()

                Text("New High Score!")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Theme.readableBlue)

                Text("\(bestScore)")
                    .font(.system(size: 56, weight: .heavy, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)

                Text("Go Bears!")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Button {
                    dismissCelebration()
                } label: {
                    Text("Nice!")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Theme.control, in: RoundedRectangle(cornerRadius: 12))
                        .foregroundStyle(.white)
                }
                .padding(.top, 4)
            }
            .padding(28)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 24))
            .overlay(
                RoundedRectangle(cornerRadius: 24)
                    .stroke(Theme.californiaGold.opacity(0.4), lineWidth: 1)
            )
            .padding(40)
            .transition(.scale.combined(with: .opacity))
        }
    }

    private func dismissCelebration() {
        withAnimation(.easeOut(duration: 0.25)) {
            showCelebration = false
        }
    }

    // MARK: Scoreboard

    private var scoreboard: some View {
        HStack {
            stat(label: "Score", value: "\(score)")
            Spacer()
            stat(label: "Best", value: "\(bestScore)")
            Spacer()
            stat(label: "Time", value: isPlaying ? "\(timeRemaining)s" : "—")
        }
        .padding(16)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
    }

    private func stat(label: String, value: String) -> some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.weight(.bold).monospacedDigit())
                .foregroundStyle(Theme.readableBlue)
        }
    }

    // MARK: Grid

    private func tile(at index: Int) -> some View {
        let isActive = activeTile == index
        let isHit = lastHitTile == index
        let isMissed = missedTile == index

        return RoundedRectangle(cornerRadius: 14)
            .fill(isMissed ? Self.missRed : (isActive ? Theme.control : Theme.card))
            .aspectRatio(1, contentMode: .fit)
            .overlay(
                Group {
                    if isActive {
                        // Fill the whole tile with the BT logo (cropped to fit).
                        Image("AppLogo")
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .scaleEffect(isHit ? 1.3 : 1)
            )
            // Clip the whole tile so a filled logo can't bleed into its neighbors.
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.white.opacity(0.06), lineWidth: 1)
            )
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: isActive)
            .animation(.easeOut(duration: 0.2), value: isMissed)
            .onTapGesture { tap(index) }
    }

    // MARK: Controls

    private var controlButton: some View {
        Button {
            isPlaying ? endRound() : startRound()
        } label: {
            Label(isPlaying ? "Give up" : "Start round", systemImage: isPlaying ? "flag.fill" : "play.fill")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Theme.control, in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(.white)
        }
    }

    // MARK: Game logic

    private func tap(_ index: Int) {
        guard isPlaying else { return }
        if activeTile == index {
            score += 1
            lastHitTile = index
            activeTile = nil
            withAnimation { lastHitTile = nil }
        } else {
            // Tapping an empty tile is a mistake: flash it red and cost a point.
            score -= 1
            missedTile = index
            Task {
                try? await Task.sleep(for: .milliseconds(300))
                if missedTile == index { missedTile = nil }
            }
        }
    }

    private func startRound() {
        score = 0
        timeRemaining = roundLength
        isPlaying = true
        Task { await runRound() }
    }

    private func endRound() {
        isPlaying = false
        activeTile = nil
        // A new personal best (and an actual score) brings out Oski.
        if score > bestScore {
            bestScore = score
            if score > 0 {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                    showCelebration = true
                }
            }
        }
    }

    /// Drives the countdown and moves Oski around until the round ends.
    private func runRound() async {
        var elapsedMillis = 0
        // Oski jumps to a new tile every ~600ms.
        let hopMillis = 600
        var untilHop = 0

        while isPlaying && timeRemaining > 0 {
            if untilHop <= 0 {
                activeTile = Int.random(in: 0..<tileCount)
                untilHop = hopMillis
            }

            try? await Task.sleep(for: .milliseconds(100))
            elapsedMillis += 100
            untilHop -= 100

            if elapsedMillis >= 1000 {
                elapsedMillis = 0
                timeRemaining -= 1
            }
        }

        if isPlaying { endRound() }
    }
}

// MARK: - Celebration pieces

/// A big BT badge that gently pulses, the star of the party.
private struct BouncingOski: View {
    @State private var pulse = false

    var body: some View {
        Image("AppLogo")
            .resizable()
            .scaledToFit()
            .padding(18)
            .frame(width: 96, height: 96)
            .background(Theme.berkeleyBlue)
            .clipShape(Circle())
            .overlay(Circle().stroke(Theme.californiaGold, lineWidth: 3))
            .scaleEffect(pulse ? 1.12 : 0.9)
            .rotationEffect(.degrees(pulse ? 6 : -6))
            .onAppear {
                withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
    }
}

/// A gentle downward fall of little Berkeley-blue-and-gold confetti bits.
private struct ConfettiView: View {
    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(0..<40, id: \.self) { _ in
                    ConfettiPiece(bounds: geo.size)
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

private struct ConfettiPiece: View {
    let bounds: CGSize

    /// The app's own teal palette.
    private static let palette: [Color] = [
        Theme.californiaGold, Theme.californiaGold, Theme.berkeleyBlue, Theme.foundersRock
    ]

    // Fixed per piece so each bit drifts its own way.
    private let color = palette.randomElement()!
    // Little bits: about half tiny dots, half small flecks.
    private let isDot = Double.random(in: 0...1) < 0.5
    private let xFraction = CGFloat.random(in: 0...1)
    private let dotSize = CGFloat.random(in: 4...8)
    private let flakeW = CGFloat.random(in: 5...9)
    private let flakeH = CGFloat.random(in: 4...7)
    private let delay = Double.random(in: 0...2.5)
    private let duration = Double.random(in: 4.0...6.5)
    private let spin = Double.random(in: -300...300)
    private let tilt = Double.random(in: -45...45)
    private let sway = CGFloat.random(in: -30...30)

    @State private var falling = false

    var body: some View {
        Group {
            if isDot {
                Circle()
                    .fill(color)
                    .frame(width: dotSize, height: dotSize)
            } else {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(color)
                    .frame(width: flakeW, height: flakeH)
            }
        }
        .position(
            x: xFraction * bounds.width + (falling ? sway : 0),
            y: falling ? bounds.height + 60 : -60
        )
        .rotationEffect(.degrees(falling ? spin : tilt))
        .onAppear {
            withAnimation(
                .easeIn(duration: duration)
                    .repeatForever(autoreverses: false)
                    .delay(delay)
            ) {
                falling = true
            }
        }
    }
}

#Preview {
    GameView()
}
