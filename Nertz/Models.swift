import SwiftUI

// MARK: - Cards

enum Suit: Int, CaseIterable, Hashable {
    case spades, hearts, diamonds, clubs

    var symbol: String {
        switch self {
        case .spades: return "♠"
        case .hearts: return "♥"
        case .diamonds: return "♦"
        case .clubs: return "♣"
        }
    }

    var isRed: Bool { self == .hearts || self == .diamonds }
}

struct Card: Identifiable, Hashable {
    let owner: Int          // 0 = you, 1+ = AI seats. Each player plays their own deck.
    let suit: Suit
    let rank: Int           // 1 = Ace ... 13 = King

    var id: String { "\(owner)-\(suit.rawValue)-\(rank)" }

    var rankLabel: String {
        switch rank {
        case 1: return "A"
        case 11: return "J"
        case 12: return "Q"
        case 13: return "K"
        default: return "\(rank)"
        }
    }

    var isRed: Bool { suit.isRed }
}

func newDeck(owner: Int) -> [Card] {
    var deck: [Card] = []
    for suit in Suit.allCases {
        for rank in 1...13 {
            deck.append(Card(owner: owner, suit: suit, rank: rank))
        }
    }
    return deck
}

/// Can `card` be stacked onto `base` on a work pile? (descending, alternating colors)
func stacksOnWork(_ card: Card, onto base: Card) -> Bool {
    card.rank == base.rank - 1 && card.isRed != base.isRed
}

// MARK: - Piles

struct FoundationPile: Identifiable {
    let id: Int             // unique per round — piles can be retired, so never an index
    var cards: [Card]
    let spot: CGPoint       // where it was tossed — normalized (0...1) in the scatter zone
    let tilt: Double        // resting angle in degrees; cards land how they land
    var faceDown = false    // completed: the king flipped over
    var vanishing = false   // shrinking off the table

    /// 13 normally; the -shortpiles debug flag lowers it so pile
    /// completion can be tested in seconds.
    nonisolated(unsafe) static var completeCount = 13

    var suit: Suit { cards.first?.suit ?? .spades }
    var top: Card? { cards.last }
    var isComplete: Bool { cards.count >= Self.completeCount }

    func accepts(_ card: Card) -> Bool {
        guard !isComplete, let top else { return false }
        return card.suit == top.suit && card.rank == top.rank + 1
    }
}

struct PlayerBoard {
    var nerts: [Card] = []          // last = top (face up)
    var work: [[Card]] = [[], [], [], []]   // first = base ... last = top, all face up
    var stock: [Card] = []          // last = top
    var waste: [Card] = []          // last = top
}

// MARK: - Moves

enum MoveSource: Equatable {
    case nertsTop
    case wasteTop
    case work(pile: Int, index: Int)
}

enum DropTarget: Equatable {
    case foundation(Int?)   // nil = start a new pile (aces)
    case work(Int)
}

enum DropResult {
    case foundation
    case work
    case rejected
}

// MARK: - Players & settings

struct AIProfile {
    let name: String
    let emoji: String

    static let roster: [AIProfile] = [
        AIProfile(name: "Ruby", emoji: "🦊"),
        AIProfile(name: "Bo", emoji: "🐻"),
        AIProfile(name: "Zoe", emoji: "🐸"),
    ]
}

enum CardPalette {
    static let backs: [Color] = [
        Color(hex: 0x2E6BE6),   // you — blue
        Color(hex: 0xD84339),   // red
        Color(hex: 0x8E44AD),   // purple
        Color(hex: 0xE67E22),   // orange
    ]

    static func back(for owner: Int) -> Color {
        backs[owner % backs.count]
    }
}

struct DifficultyParams {
    let interval: ClosedRange<Double>   // seconds between AI actions
    let skipChance: Double              // chance the AI fumbles and just flips
    let callDelay: ClosedRange<Double>  // how long after emptying its pile the AI calls Nerts
    let smart: Bool                     // work-pile shuffling & waste building
}

enum Difficulty: String, CaseIterable, Identifiable {
    case chill, classic, frantic

    var id: String { rawValue }

    var label: String {
        switch self {
        case .chill: return "Chill"
        case .classic: return "Classic"
        case .frantic: return "Frantic"
        }
    }

    var emoji: String {
        switch self {
        case .chill: return "🌤️"
        case .classic: return "♠️"
        case .frantic: return "🔥"
        }
    }

    var blurb: String {
        switch self {
        case .chill: return "Opponents sip their coffee"
        case .classic: return "A fair fight at the table"
        case .frantic: return "They show no mercy"
        }
    }

    var params: DifficultyParams {
        switch self {
        case .chill:
            return DifficultyParams(interval: 3.8...7.0, skipChance: 0.32, callDelay: 7.0...11.0, smart: false)
        case .classic:
            return DifficultyParams(interval: 2.2...4.0, skipChance: 0.14, callDelay: 4.0...6.5, smart: true)
        case .frantic:
            return DifficultyParams(interval: 1.1...2.1, skipChance: 0.05, callDelay: 1.5...2.8, smart: true)
        }
    }
}

struct GameSettings {
    var opponents: Int = 2          // 1...3
    var difficulty: Difficulty = .classic
}

// MARK: - Round results

struct RoundSummary {
    let caller: Int
    let foundationCounts: [Int]
    let nertsLeft: [Int]
    let deltas: [Int]
    let totals: [Int]
    let winner: Int?                // set when the match is over (someone reached 100)
}

/// An opponent's card in the air. It owns nothing until it lands: the pile
/// only updates on touchdown, and if the spot was taken first, the card
/// bounces home. First card DOWN wins, like at a real table.
struct FlyingCard: Identifiable {
    let card: Card
    let fromSeat: Int               // player index 1+
    let source: MoveSource          // where it came from, for bounce-backs
    let pileID: Int?                // nil = starting a new pile
    let spot: CGPoint?              // where a new pile will land; nil for existing piles
    var resolveAt: Date             // when the race is decided; pause-shifted
    var landed = false
    var bouncing = false            // lost the race, flying home

    var id: String { card.id }
}

/// A visual "stamp" when an opponent's card lands on a foundation.
struct LandingPulse: Identifiable {
    let id: Int
    let pileID: Int
    let owner: Int
}
