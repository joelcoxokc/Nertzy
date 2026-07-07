import SwiftUI

struct ScoreboardOverlay: View {
    let engine: GameEngine
    let summary: RoundSummary

    private func name(_ p: Int) -> String {
        p == 0 ? "You" : AIProfile.roster[p - 1].name
    }

    private func emoji(_ p: Int) -> String {
        p == 0 ? "🙂" : AIProfile.roster[p - 1].emoji
    }

    private var confettiDeserved: Bool {
        if let w = summary.winner { return w == 0 }
        return summary.deltas.first == summary.deltas.max()
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()

            VStack(spacing: 20) {
                VStack(spacing: 4) {
                    Text("NERTS!")
                        .font(.system(size: 46, weight: .black, design: .rounded))
                        .foregroundStyle(Color(hex: 0xFF5A4E))
                        .shadow(color: .black.opacity(0.4), radius: 6, y: 3)
                    Text("\(name(summary.caller)) called it")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.7))
                }

                VStack(spacing: 10) {
                    ForEach(0..<summary.totals.count, id: \.self) { p in
                        playerRow(p)
                    }
                }

                if let w = summary.winner {
                    Text("🏆 \(name(w)) wins the match!")
                        .font(.system(size: 20, weight: .heavy, design: .rounded))
                        .foregroundStyle(Color(hex: 0xFFD166))
                }

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
                        .frame(width: geo.size.width * min(1, max(0.015, Double(total) / 100.0)))
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
