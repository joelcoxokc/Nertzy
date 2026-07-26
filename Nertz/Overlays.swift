import SwiftUI

// MARK: - Leaving the table

/// Every way out of an online match asks first, in one voice — the
/// corner button, the scoreboard's QUIT, a guest's LEAVE TABLE. What
/// it costs depends on who you are: a guest gives up a seat, the host
/// takes the whole table down.
private struct LeaveTableConfirmation: ViewModifier {
    let engine: GameEngine
    @Binding var isPresented: Bool

    private var isHost: Bool { engine.isOnlineHost }

    func body(content: Content) -> some View {
        content.confirmationDialog(
            isHost ? "Close the table?" : "Leave the table?",
            isPresented: $isPresented,
            titleVisibility: .visible
        ) {
            Button(isHost ? "Close the Table" : "Leave Match", role: .destructive) {
                engine.leaveOnlineMatch()
            }
            Button("Keep Playing", role: .cancel) {}
        } message: {
            Text(isHost
                ? "You have the deal — leaving ends the match for everyone at the table."
                : "The round settles up without you and a bot takes your seat.")
        }
    }
}

extension View {
    func leaveTableConfirmation(engine: GameEngine, isPresented: Binding<Bool>) -> some View {
        modifier(LeaveTableConfirmation(engine: engine, isPresented: isPresented))
    }
}

/// The way out, wherever it's offered. Solo it's QUIT and the match
/// keeps on CONTINUE, so it goes straight through; online it's a
/// LEAVE TABLE that always asks first. Owning the confirmation here
/// means no caller can add the button and forget the question.
struct LeaveOrQuitButton: View {
    let engine: GameEngine

    @State private var confirmLeave = false

    var body: some View {
        Button {
            if engine.isOnline {
                confirmLeave = true
            } else {
                engine.quitToMenu()
            }
        } label: {
            smallPill(engine.isOnline ? "LEAVE TABLE" : "QUIT")
        }
        .buttonStyle(.plain)
        .leaveTableConfirmation(engine: engine, isPresented: $confirmLeave)
    }
}

struct PauseOverlay: View {
    let engine: GameEngine

    @AppStorage(TablePrefs.leftHandKey) private var leftHandMode = false
    @AppStorage(TablePrefs.tapToPlayKey) private var tapToPlay = true
    /// The host's override appears a few seconds in — long enough that
    /// it never looks like the way to snatch the table back, short
    /// enough to rescue one whose pauser has vanished.
    @State private var overrideOffered = false

    /// Who else froze the table, if it wasn't me. Solo, and a pause I
    /// called myself, both read as nil — this overlay only ever renders
    /// while something holds the pause, so nil means "mine".
    private var pauser: String? {
        guard engine.isOnline, let by = engine.pausedBy, by != 0 else { return nil }
        return engine.seatName(by)
    }
    /// The engine states the rule; the view only adds the delay before
    /// the host's override shows up.
    private var canResume: Bool {
        engine.canResume && (pauser == nil || overrideOffered)
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()

            VStack(spacing: 14) {
                Image(systemName: "pause.circle.fill")
                    .font(.system(size: 42))
                    .foregroundStyle(.white.opacity(0.9))
                Text("PAUSED")
                    .font(.system(size: 32, weight: .black, design: .rounded))
                    .tracking(3)
                    .foregroundStyle(.white)
                if engine.isOnline {
                    Text(pauser.map { "\($0) paused the table" } ?? "Everyone's table is frozen")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.65))
                }
                Spacer().frame(height: 6)

                if canResume {
                    Button {
                        engine.requestPause(false)
                    } label: {
                        Text(pauser == nil ? "RESUME" : "RESUME FOR EVERYONE")
                            .font(.system(size: 18, weight: .black, design: .rounded))
                            .tracking(1.5)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(
                                Capsule().fill(LinearGradient(
                                    colors: [Color(hex: 0x35C963), Color(hex: 0x1E9B47)],
                                    startPoint: .top, endPoint: .bottom
                                ))
                            )
                    }
                    .buttonStyle(.plain)
                } else if let pauser {
                    Text("Only \(pauser) can resume.")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Capsule().fill(.white.opacity(0.07)))
                }

                // A table shuffle is a house rule for the whole table,
                // and only the host can call one on the wire — so
                // online it stays with the stuck-table detector.
                if !engine.isOnline {
                    Button {
                        engine.tableShuffle()
                        engine.requestPause(false)
                    } label: {
                        VStack(spacing: 3) {
                            Text("TABLE SHUFFLE  🔀")
                                .font(.system(size: 15, weight: .heavy, design: .rounded))
                                .tracking(1)
                                .foregroundStyle(.white)
                            Text("Stuck? Everyone re-forms their stock and moves\nthe top card to the bottom.")
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .foregroundStyle(.white.opacity(0.6))
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(.white.opacity(0.10))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(.white.opacity(0.15), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }

                SettingToggleRow(
                    title: "LEFT-HAND MODE",
                    blurb: "Nerts pile and stock at your left thumb.",
                    isOn: $leftHandMode
                )
                SettingToggleRow(
                    title: "TAP TO PLAY",
                    blurb: "Off, cards move only when you drag them.",
                    isOn: $tapToPlay
                )

                HStack(spacing: 10) {
                    // Redealing mid-match is the host's call alone, and
                    // there's no message for it — solo only.
                    if !engine.isOnline {
                        Button {
                            engine.newMatch()
                        } label: {
                            smallPill("NEW MATCH")
                        }
                        .buttonStyle(.plain)
                    }
                    LeaveOrQuitButton(engine: engine)
                }
                .padding(.top, 4)
            }
            .task(id: engine.pausedBy) {
                overrideOffered = false
                try? await Task.sleep(for: .seconds(5))
                overrideOffered = true
            }
            .padding(26)
            .frame(maxWidth: 340)
            .background(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(Color(hex: 0x0E2417).opacity(0.97))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 1)
            )
            .padding(.horizontal, 30)
        }
    }
}

struct ScoreboardOverlay: View {
    let engine: GameEngine
    let summary: RoundSummary

    private func name(_ p: Int) -> String { engine.seatName(p) }
    private func emoji(_ p: Int) -> String { engine.seatEmoji(p) }

    private var confettiDeserved: Bool {
        if let w = summary.winner { return w == 0 }
        return summary.deltas.first == summary.deltas.max()
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()

            VStack(spacing: 20) {
                VStack(spacing: 4) {
                    Text(summary.caller >= 0 ? "NERTS!" : "ROUND OVER")
                        .font(.system(size: 46, weight: .black, design: .rounded))
                        .foregroundStyle(Color(hex: 0xFF5A4E))
                        .shadow(color: .black.opacity(0.4), radius: 6, y: 3)
                    Text(summary.caller >= 0
                        ? "\(name(summary.caller)) called it"
                        : (summary.note ?? "The table settled up"))
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.7))
                }

                VStack(spacing: 10) {
                    ForEach(0..<summary.totals.count, id: \.self) { p in
                        playerRow(p)
                    }
                }

                if let w = summary.winner {
                    Text("🏆 \(name(w)) \(w == 0 ? "win" : "wins") the match!")
                        .font(.system(size: 20, weight: .heavy, design: .rounded))
                        .foregroundStyle(Color(hex: 0xFFD166))
                }

                if engine.canAdvanceScoreboard {
                    VStack(spacing: 12) {
                        Button {
                            engine.advanceFromScoreboard()
                        } label: {
                            Text(summary.winner != nil ? "NEW MATCH" : "NEXT ROUND")
                                .font(.system(size: 18, weight: .black, design: .rounded))
                                .tracking(1.5)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 44)
                                .padding(.vertical, 14)
                                .background(
                                    Capsule().fill(LinearGradient(
                                        colors: [Color(hex: 0x3A7BFF), Color(hex: 0x2455C8)],
                                        startPoint: .top, endPoint: .bottom
                                    ))
                                )
                                .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
                        }
                        .buttonStyle(.plain)
                        LeaveOrQuitButton(engine: engine)
                    }
                } else {
                    // Guests wait for the host to deal the next one.
                    VStack(spacing: 10) {
                        Text(summary.winner != nil
                            ? "Waiting for the host…"
                            : "Waiting for the host to deal…")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.6))
                        LeaveOrQuitButton(engine: engine)
                    }
                }
            }
            .padding(26)
            .background(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(Color(hex: 0x0E2417).opacity(0.97))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 1)
            )
            .padding(.horizontal, 24)

            if confettiDeserved {
                ConfettiView(particleCount: 90).ignoresSafeArea()
            }
        }
    }

    private func playerRow(_ p: Int) -> some View {
        let delta = summary.deltas[p]
        let total = summary.totals[p]
        let isCaller = p == summary.caller
        return VStack(spacing: 5) {
            HStack(spacing: 8) {
                Text(emoji(p)).font(.system(size: 20))
                Text(name(p))
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                if isCaller {
                    Text("NERTS")
                        .font(.system(size: 9, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2.5)
                        .background(Capsule().fill(Color(hex: 0xD22B20)))
                }
                Spacer()
                Text("+\(summary.foundationCounts[p]) · −\(2 * summary.nertsLeft[p])")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))
                Text(delta >= 0 ? "+\(delta)" : "\(delta)")
                    .font(.system(size: 17, weight: .heavy, design: .rounded))
                    .foregroundStyle(delta >= 0 ? Color(hex: 0x7CFFB0) : Color(hex: 0xFF8A7A))
                    .frame(minWidth: 44, alignment: .trailing)
                Text("\(total)")
                    .font(.system(size: 17, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(minWidth: 40, alignment: .trailing)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.10))
                    Capsule()
                        .fill(Color(hex: p == 0 ? 0x3A7BFF : 0x7CFFB0).opacity(p == 0 ? 1.0 : 0.75))
                        .frame(width: geo.size.width * min(1, max(0.015, Double(total) / Double(max(1, engine.settings.targetScore)))))
                }
            }
            .frame(height: 5)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.white.opacity(p == 0 ? 0.10 : 0.05))
        )
    }
}
