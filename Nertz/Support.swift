import SwiftUI
import UIKit

// MARK: - Colors

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0
        )
    }
}

enum Felt {
    static let light = Color(hex: 0x1E7A46)
    static let dark = Color(hex: 0x0C4A28)
    static let deepest = Color(hex: 0x073019)
}

// MARK: - Haptics

enum Haptics {
    private static let softGen = UIImpactFeedbackGenerator(style: .soft)
    private static let lightGen = UIImpactFeedbackGenerator(style: .light)
    private static let mediumGen = UIImpactFeedbackGenerator(style: .medium)
    private static let rigidGen = UIImpactFeedbackGenerator(style: .rigid)
    private static let notifGen = UINotificationFeedbackGenerator()

    static func prepare() {
        softGen.prepare()
        lightGen.prepare()
        mediumGen.prepare()
        rigidGen.prepare()
        notifGen.prepare()
    }

    /// Picking up a card.
    static func lift() { softGen.impactOccurred(intensity: 0.7) }
    /// Flipping stock cards.
    static func flip() { lightGen.impactOccurred(intensity: 0.8) }
    /// Landing a card on a work pile.
    static func place() { mediumGen.impactOccurred() }
    /// Landing a card on a foundation — the good one.
    static func score() { rigidGen.impactOccurred(intensity: 1.0) }
    /// Invalid move.
    static func nope() { notifGen.notificationOccurred(.error) }
    /// Round won / NERTS.
    static func fanfare() { notifGen.notificationOccurred(.success) }
}

// MARK: - Shake effect (invalid move feedback)

struct ShakeEffect: GeometryEffect {
    var travel: CGFloat = 6
    var shakesPerUnit: CGFloat = 3
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(
            translationX: travel * sin(animatableData * .pi * shakesPerUnit * 2),
            y: 0
        ))
    }
}

// MARK: - Geometry helpers

extension CGPoint {
    func offsetBy(_ dx: CGFloat, _ dy: CGFloat) -> CGPoint {
        CGPoint(x: x + dx, y: y + dy)
    }

    func adding(_ translation: CGSize) -> CGPoint {
        CGPoint(x: x + translation.width, y: y + translation.height)
    }

    func distance(to other: CGPoint) -> CGFloat {
        hypot(x - other.x, y - other.y)
    }
}

/// Deterministic tiny rotation per card so cards land on the table with a
/// physical, tossed-on feel. Stable for a card for the whole session.
func tossAngle(for card: Card, spread: Double = 3.0) -> Double {
    var h = UInt64(5381)
    for b in card.id.utf8 { h = (h << 5) &+ h &+ UInt64(b) }
    let unit = Double(h % 1000) / 1000.0
    return (unit * 2 - 1) * spread
}

// MARK: - Felt table background

struct FeltBackground: View {
    var body: some View {
        ZStack {
            RadialGradient(
                colors: [Felt.light, Felt.dark, Felt.deepest],
                center: UnitPoint(x: 0.5, y: 0.38),
                startRadius: 40,
                endRadius: 900
            )
            // vignette
            LinearGradient(
                colors: [Color.black.opacity(0.35), .clear, .clear, Color.black.opacity(0.30)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
    }
}

// MARK: - Confetti

struct ConfettiView: View {
    let particleCount: Int

    @State private var start = Date()

    private let colors: [Color] = [
        Color(hex: 0xFFD166), Color(hex: 0xEF476F), Color(hex: 0x06D6A0),
        Color(hex: 0x118AB2), Color(hex: 0xF78C6B), .white,
    ]

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let t = timeline.date.timeIntervalSince(start)
                guard t < 3.4 else { return }
                for i in 0..<particleCount {
                    var h = UInt64(i &* 2654435761)
                    func rand() -> Double {
                        h = h &* 6364136223846793005 &+ 1442695040888963407
                        return Double((h >> 33) % 10_000) / 10_000.0
                    }
                    let delay = rand() * 0.35
                    let life = t - delay
                    guard life > 0 else { continue }
                    let x0 = rand() * size.width
                    let vx = (rand() - 0.5) * 90
                    let vy = 130 + rand() * 190
                    let x = x0 + vx * life
                    let y = -20 + vy * life + 190 * life * life
                    guard y < size.height + 20 else { continue }
                    let spin = life * (2 + rand() * 4) * (rand() > 0.5 ? 1 : -1)
                    let w = 6 + rand() * 5
                    let alpha = life > 2.4 ? max(0, 1 - (life - 2.4)) : 1
                    var ctx = context
                    ctx.translateBy(x: x, y: y)
                    ctx.rotate(by: .radians(spin))
                    ctx.opacity = alpha
                    let rect = CGRect(x: -w / 2, y: -w / 3, width: w, height: w * 0.66)
                    ctx.fill(Path(roundedRect: rect, cornerRadius: 1.5),
                             with: .color(colors[i % colors.count]))
                }
            }
        }
        .allowsHitTesting(false)
    }
}
