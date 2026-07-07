import SwiftUI

// MARK: - A playing card

struct CardView: View {
    let card: Card
    let faceUp: Bool
    let width: CGFloat

    private var height: CGFloat { width * 1.42 }
    private var radius: CGFloat { width * 0.12 }
    private var ink: Color { card.isRed ? Color(hex: 0xC9252D) : Color(hex: 0x20202A) }

    var body: some View {
        ZStack {
            face.opacity(faceUp ? 1 : 0)
            back
                .opacity(faceUp ? 0 : 1)
                .rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
        }
        .frame(width: width, height: height)
        .rotation3DEffect(
            .degrees(faceUp ? 0 : 180),
            axis: (x: 0, y: 1, z: 0),
            perspective: 0.35
        )
    }

    // MARK: Face

    private var face: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(LinearGradient(
                colors: [.white, Color(hex: 0xF0F0EA)],
                startPoint: .top, endPoint: .bottom
            ))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.10), lineWidth: 0.8)
            )
            .overlay(faceContent)
    }

    private var faceContent: some View {
        VStack(spacing: 0) {
            // Top half: the rank, big — hugs the top edge so it stays
            // readable when cards fan out in a work pile.
            Text(card.rankLabel)
                .font(.system(size: width * 0.54, weight: .heavy, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, width * 0.05)
            // Bottom half: the suit, big.
            Text(card.suit.symbol)
                .font(.system(size: width * 0.50))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .foregroundStyle(ink)
    }

    // MARK: Back

    private var back: some View {
        let tint = CardPalette.back(for: card.owner)
        return RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(LinearGradient(
                colors: [tint, tint.opacity(0.72)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            ))
            .overlay(
                RoundedRectangle(cornerRadius: radius * 0.62, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.55), lineWidth: max(1.2, width * 0.028))
                    .padding(width * 0.075)
            )
            .overlay(
                Image(systemName: "suit.spade.fill")
                    .font(.system(size: width * 0.28))
                    .foregroundStyle(.white.opacity(0.42))
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.18), lineWidth: 0.8)
            )
    }
}

// MARK: - Empty slot markers

struct SlotMarker: View {
    let width: CGFloat
    var label: String?
    var icon: String?

    var body: some View {
        RoundedRectangle(cornerRadius: width * 0.12, style: .continuous)
            .strokeBorder(
                Color.white.opacity(0.22),
                style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])
            )
            .background(
                RoundedRectangle(cornerRadius: width * 0.12, style: .continuous)
                    .fill(Color.black.opacity(0.10))
            )
            .overlay {
                if let label {
                    Text(label)
                        .font(.system(size: width * 0.42, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.28))
                } else if let icon {
                    Image(systemName: icon)
                        .font(.system(size: width * 0.32, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.40))
                }
            }
            .frame(width: width, height: width * 1.42)
    }
}

// MARK: - Opponent seat chip

struct SeatChip: View {
    let profile: AIProfile
    let nertsLeft: Int
    let score: Int
    let backTint: Color
    let calling: Bool
    let pulse: Int

    @State private var pulsing = false

    var body: some View {
        HStack(spacing: 7) {
            Text(profile.emoji)
                .font(.system(size: 25))
            VStack(alignment: .leading, spacing: 1) {
                Text(profile.name)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text("\(score) pts")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.6))
            }
            ZStack {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(backTint)
                    .frame(width: 21, height: 29)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(.white.opacity(0.5), lineWidth: 1)
                    )
                Text("\(nertsLeft)")
                    .font(.system(size: 12, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.6), radius: 1.5)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.black.opacity(calling ? 0.55 : 0.28)))
        .overlay(
            Capsule().strokeBorder(
                calling ? Color(hex: 0xFF5A4E) : .white.opacity(0.15),
                lineWidth: calling ? 2 : 1
            )
        )
        .scaleEffect(pulsing ? 1.07 : 1.0)
        .animation(.spring(response: 0.22, dampingFraction: 0.5), value: pulsing)
        .onChange(of: pulse) { _, _ in
            pulsing = true
            Task {
                try? await Task.sleep(for: .milliseconds(150))
                pulsing = false
            }
        }
    }
}

// MARK: - Landing pulse ring

/// An expanding colored ring stamped on a foundation pile the moment an
/// opponent's card lands, tinted with that player's color.
struct LandingRing: View {
    let color: Color
    let cardW: CGFloat

    @State private var expand = false

    var body: some View {
        RoundedRectangle(cornerRadius: cardW * 0.12 + 3, style: .continuous)
            .strokeBorder(color, lineWidth: 3.5)
            .frame(width: cardW + 8, height: cardW * 1.42 + 8)
            .shadow(color: color.opacity(0.8), radius: 6)
            .scaleEffect(expand ? 1.45 : 0.95)
            .opacity(expand ? 0 : 1)
            .onAppear {
                withAnimation(.easeOut(duration: 0.6)) { expand = true }
            }
            .allowsHitTesting(false)
    }
}

// MARK: - The big red button

struct NertsButton: View {
    let action: () -> Void

    @State private var pulse = false

    var body: some View {
        Button(action: action) {
            Text("NERTS!")
                .font(.system(size: 24, weight: .black, design: .rounded))
                .tracking(1)
                .foregroundStyle(.white)
                .padding(.horizontal, 26)
                .padding(.vertical, 14)
                .background(
                    Capsule().fill(LinearGradient(
                        colors: [Color(hex: 0xFF5A4E), Color(hex: 0xD22B20)],
                        startPoint: .top, endPoint: .bottom
                    ))
                )
                .overlay(Capsule().strokeBorder(.white.opacity(0.35), lineWidth: 1.5))
                .shadow(color: Color(hex: 0xD22B20).opacity(0.6), radius: pulse ? 18 : 8, y: 4)
                .scaleEffect(pulse ? 1.06 : 0.98)
        }
        .buttonStyle(.plain)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}
