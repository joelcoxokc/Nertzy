import SwiftUI

struct MenuView: View {
    let engine: GameEngine

    @AppStorage("opponents") private var opponents = 2
    @AppStorage("difficulty") private var difficultyRaw = Difficulty.classic.rawValue

    var body: some View {
        ZStack {
            FeltBackground()
            VStack(spacing: 0) {
                Spacer(minLength: 20)
                titleBlock
                Spacer(minLength: 26)
                VStack(spacing: 24) {
                    optionSection("OPPONENTS") { opponentPicker }
                    optionSection("TABLE SPEED") { difficultyPicker }
                }
                Spacer(minLength: 26)
                dealButton
                Spacer(minLength: 34)
            }
            .padding(.horizontal, 26)
            .frame(maxWidth: 480)
        }
    }

    // MARK: Title

    private var titleBlock: some View {
        VStack(spacing: 16) {
            ZStack {
                CardView(card: Card(owner: 1, suit: .spades, rank: 1), faceUp: true, width: 62)
                    .rotationEffect(.degrees(-14))
                    .offset(x: -46, y: 8)
                    .shadow(color: .black.opacity(0.3), radius: 8, y: 5)
                CardView(card: Card(owner: 2, suit: .diamonds, rank: 13), faceUp: true, width: 62)
                    .rotationEffect(.degrees(13))
                    .offset(x: 46, y: 8)
                    .shadow(color: .black.opacity(0.3), radius: 8, y: 5)
                CardView(card: Card(owner: 0, suit: .hearts, rank: 1), faceUp: true, width: 62)
                    .shadow(color: .black.opacity(0.35), radius: 10, y: 6)
            }
            .frame(height: 104)
            VStack(spacing: 6) {
                Text("NERTZY")
                    .font(.system(size: 56, weight: .black, design: .rounded))
                    .tracking(5)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.4), radius: 8, y: 4)
                Text("The fastest card game in the world")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.65))
            }
        }
    }

    // MARK: Options

    private func optionSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.system(size: 11, weight: .heavy, design: .rounded))
                .tracking(2.5)
                .foregroundStyle(.white.opacity(0.45))
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var opponentPicker: some View {
        HStack(spacing: 10) {
            ForEach(1...3, id: \.self) { n in
                let selected = opponents == n
                Button {
                    opponents = n
                    Haptics.flip()
                } label: {
                    VStack(spacing: 4) {
                        Text(AIProfile.roster.prefix(n).map(\.emoji).joined())
                            .font(.system(size: 19))
                        Text("\(n)")
                            .font(.system(size: 21, weight: .heavy, design: .rounded))
                            .foregroundStyle(.white)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(.white.opacity(selected ? 0.20 : 0.07))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(
                                .white.opacity(selected ? 0.85 : 0.12),
                                lineWidth: selected ? 2 : 1
                            )
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var difficultyPicker: some View {
        VStack(spacing: 8) {
            ForEach(Difficulty.allCases) { d in
                let selected = difficultyRaw == d.rawValue
                Button {
                    difficultyRaw = d.rawValue
                    Haptics.flip()
                } label: {
                    HStack(spacing: 12) {
                        Text(d.emoji).font(.system(size: 22))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(d.label)
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                            Text(d.blurb)
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(.white.opacity(0.55))
                        }
                        Spacer()
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 20))
                            .foregroundStyle(selected ? Color(hex: 0x7CFFB0) : .white.opacity(0.25))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(.white.opacity(selected ? 0.18 : 0.07))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(
                                .white.opacity(selected ? 0.85 : 0.12),
                                lineWidth: selected ? 2 : 1
                            )
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Deal

    private var dealButton: some View {
        Button {
            engine.settings = GameSettings(
                opponents: opponents,
                difficulty: Difficulty(rawValue: difficultyRaw) ?? .classic
            )
            Haptics.fanfare()
            engine.newMatch()
        } label: {
            Text("DEAL ME IN")
                .font(.system(size: 20, weight: .black, design: .rounded))
                .tracking(2)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 17)
                .background(
                    Capsule().fill(LinearGradient(
                        colors: [Color(hex: 0xE0443A), Color(hex: 0xB4271E)],
                        startPoint: .top, endPoint: .bottom
                    ))
                )
                .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 1.5))
                .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
        }
        .buttonStyle(.plain)
    }
}
