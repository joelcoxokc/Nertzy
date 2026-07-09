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
        ZStack {
            // Rank, big, pinned to the top-left corner — the sliver that
            // stays readable when the card is buried in the waste fan or
            // under a work-pile cascade. Times, like a real deck.
            Text(card.rankLabel)
                .font(.custom("TimesNewRomanPS-BoldMT", size: width * 0.50))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.leading, width * 0.07)
                .padding(.top, width * 0.01)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // Suit in the top-right corner, so a cascade strip shows both.
            Text(card.suit.symbol)
                .font(.system(size: width * 0.26, weight: .bold))
                .padding(.trailing, width * 0.07)
                .padding(.top, width * 0.06)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            // The suit again, big, filling the lower half of the face.
            Text(card.suit.symbol)
                .font(.system(size: width * 0.68))
                .padding(.bottom, width * 0.10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
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

// MARK: - Opponent badge

/// An opponent, reduced to the one number that matters at the table: how
/// many cards are left in their nerts pile. A mini card back in their
/// color, pinned to the table edge, glowing red when they're about to call.
struct SeatBadge: View {
    let count: Int
    let tint: Color
    let calling: Bool
    let pulse: Int

    @State private var pulsing = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(LinearGradient(
                    colors: [tint, tint.opacity(0.70)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(
                    calling ? Color(hex: 0xFF5A4E) : .white.opacity(0.5),
                    lineWidth: calling ? 2.5 : 1.2
                )
            Text("\(count)")
                .font(.system(size: 20, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.55), radius: 1.5)
                .minimumScaleFactor(0.6)
                .padding(.horizontal, 3)
        }
        .frame(width: 36, height: 50)
        .shadow(
            color: calling ? Color(hex: 0xFF5A4E).opacity(0.85) : .black.opacity(0.35),
            radius: calling ? 10 : 4, y: 2
        )
        .scaleEffect(pulsing ? 1.14 : 1.0)
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
