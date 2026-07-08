import SwiftUI

struct StatsView: View {
    @Environment(\.dismiss) private var dismiss
    private let store = StatsStore.shared

    var body: some View {
        ZStack {
            FeltBackground()
            VStack(spacing: 0) {
                header
                if store.matches.isEmpty {
                    emptyState
                } else {
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 26) {
                            lifetimeSection
                            speedSection
                            onlineSection
                            recentSection
                        }
                        .padding(.horizontal, 26)
                        .padding(.top, 6)
                        .padding(.bottom, 44)
                    }
                }
            }
            .frame(maxWidth: 480)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Text("YOUR RECORD")
                .font(.system(size: 26, weight: .black, design: .rounded))
                .tracking(3)
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.white.opacity(0.4))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 26)
        .padding(.top, 22)
        .padding(.bottom, 18)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Text("🃏").font(.system(size: 54))
            Text("No matches yet")
                .font(.system(size: 20, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
            Text("Finish a round and your record starts here.")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.55))
            Spacer()
            Spacer()
        }
    }

    // MARK: Sections

    private var lifetimeSection: some View {
        let t = store.tally()
        return titledSection("LIFETIME") {
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                spacing: 10
            ) {
                tile("MATCHES WON", "\(t.matchesWon)", sub: "of \(t.matchesFinished) finished")
                tile("ROUNDS WON", "\(t.roundsWon)", sub: "of \(t.roundsPlayed) played")
                tile("NERTS CALLED", "\(t.nertsCalls)", sub: "went out first")
                tile("BEST ROUND", t.bestRound.map(signed) ?? "—", sub: "single-round score")
                tile("WIN STREAK", "\(t.currentStreak)", sub: "best \(t.bestStreak)")
                tile("ROUND WIN RATE", percent(t.roundsWon, t.roundsPlayed), sub: "top score at the table")
            }
        }
    }

    private var speedSection: some View {
        titledSection("BY TABLE SPEED") {
            VStack(spacing: 8) {
                ForEach(Difficulty.allCases) { d in
                    speedRow(d)
                }
            }
        }
    }

    private func speedRow(_ d: Difficulty) -> some View {
        let t = store.tally(d)
        return recordRow(
            emoji: d.emoji, label: d.label,
            matchesWon: t.matchesWon, matchesLost: t.matchesFinished - t.matchesWon,
            roundsWon: t.roundsWon, roundsPlayed: t.roundsPlayed
        )
    }

    /// One line of "who you are against X" — table speeds and humans
    /// share the same chrome.
    private func recordRow(
        emoji: String, label: String,
        matchesWon: Int, matchesLost: Int,
        roundsWon: Int, roundsPlayed: Int
    ) -> some View {
        HStack(spacing: 12) {
            Text(emoji).font(.system(size: 21))
            Text(label)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer()
            if roundsPlayed == 0 {
                Text("—")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.3))
            } else {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(matchesWon)–\(matchesLost) matches")
                        .font(.system(size: 14, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                    Text("\(roundsWon)/\(roundsPlayed) rounds · \(percent(roundsWon, roundsPlayed))")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .statsPanel()
    }

    // MARK: Online

    /// Your record against actual people — hidden until you've played
    /// someone.
    @ViewBuilder
    private var onlineSection: some View {
        let t = store.tally(mode: .multiplayer)
        if t.roundsPlayed > 0 {
            titledSection("VS HUMANS") {
                VStack(spacing: 8) {
                    recordRow(
                        emoji: "🌐", label: "All online play",
                        matchesWon: t.matchesWon, matchesLost: t.matchesFinished - t.matchesWon,
                        roundsWon: t.roundsWon, roundsPlayed: t.roundsPlayed
                    )
                    ForEach(store.opponentRecords()) { r in
                        recordRow(
                            emoji: r.emoji, label: r.name,
                            matchesWon: r.matchesWon, matchesLost: r.matchesLost,
                            roundsWon: r.roundsWon, roundsPlayed: r.roundsPlayed
                        )
                    }
                }
            }
        }
    }

    private var recentSection: some View {
        titledSection("RECENT MATCHES") {
            VStack(spacing: 8) {
                ForEach(Array(store.matches.suffix(12).reversed())) { m in
                    matchRow(m)
                }
            }
        }
    }

    private func matchRow(_ m: MatchRecord) -> some View {
        let me = m.mySeat ?? 0
        let finals = m.rounds.last?.totals ?? []
        let myScore = me < finals.count ? finals[me] : 0
        let bestOpp = finals.enumerated().filter { $0.offset != me }.map { $0.element }.max() ?? 0
        let won = m.winnerSeat == me
        let (label, color): (String, Color) = {
            guard m.winnerSeat != nil else { return ("LEFT", Color.white.opacity(0.35)) }
            return won ? ("WON", Color(hex: 0x7CFFB0)) : ("LOST", Color(hex: 0xFF8A7A))
        }()
        let meta: String = {
            let tail = "\(m.rounds.count) rd\(m.rounds.count == 1 ? "" : "s") · \(m.started.formatted(date: .abbreviated, time: .omitted))"
            if m.mode == .multiplayer, let opp = m.humanOpponents.first {
                return "vs \(opp.name) · \(tail)"
            }
            return tail
        }()
        return HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 10, weight: .black, design: .rounded))
                .tracking(1)
                .foregroundStyle(color)
                .frame(width: 40, alignment: .leading)
            Text(m.mode == .multiplayer ? "🌐" : (m.difficulty?.emoji ?? "♠️"))
                .font(.system(size: 16))
            Text("\(myScore)–\(bestOpp)")
                .font(.system(size: 15, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
            Spacer()
            Text(meta)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.white.opacity(won ? 0.09 : 0.05))
        )
    }

    // MARK: Bits

    private func tile(_ label: String, _ value: String, sub: String? = nil) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 27, weight: .black, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.system(size: 10, weight: .heavy, design: .rounded))
                .tracking(1.5)
                .foregroundStyle(.white.opacity(0.45))
            if let sub {
                Text(sub)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .frame(maxWidth: .infinity, minHeight: 84)
        .padding(.vertical, 12)
        .statsPanel()
    }

    private func signed(_ n: Int) -> String {
        n >= 0 ? "+\(n)" : "\(n)"
    }

    private func percent(_ n: Int, _ d: Int) -> String {
        guard d > 0 else { return "—" }
        return "\(Int((Double(n) / Double(d) * 100).rounded()))%"
    }
}

private extension View {
    /// The raised-panel chrome shared by tiles and rows on this screen.
    func statsPanel() -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.white.opacity(0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 1)
            )
    }
}
