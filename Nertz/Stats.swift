import Foundation
import Observation

// MARK: - Match records

/// One seat at the table. Self-describing so the record format survives the
/// jump to multiplayer: bots and (later) remote humans describe themselves
/// the same way, and "which seat is me" is data, not an assumption that the
/// human sits at index 0.
struct SeatRecord: Codable, Equatable {
    enum Kind: Codable, Equatable {
        case me
        case bot
        case human(id: String)      // multiplayer, someday
    }
    let kind: Kind
    let name: String
    let emoji: String
}

/// One finished round — a Codable snapshot of RoundSummary. The scoring
/// breakdown is stored, not recomputed, so old records stay true if the
/// rules ever change.
struct RoundRecord: Codable {
    let caller: Int
    let foundationCounts: [Int]
    let nertsLeft: [Int]
    let deltas: [Int]
    let totals: [Int]
}

struct MatchRecord: Codable, Identifiable {
    /// First-class so vs-bot results never pool with vs-human ones.
    enum Mode: Codable, Equatable {
        case solo(Difficulty)
        case multiplayer
    }

    let id: UUID                    // the engine's match token
    let started: Date
    let mode: Mode
    let seats: [SeatRecord]
    var rounds: [RoundRecord]
    var winnerSeat: Int?            // nil = walked away mid-match

    var mySeat: Int? { seats.firstIndex { $0.kind == .me } }

    var difficulty: Difficulty? {
        if case .solo(let d) = mode { return d }
        return nil
    }
}

// MARK: - Store

/// The record book: an append-only match history saved as JSON. Every number
/// on the stats screen is derived from it, never stored. Results enter
/// through one door — record(_:settings:match:) with the engine's
/// authoritative RoundSummary — so a multiplayer host/server can feed the
/// same store later.
@MainActor
@Observable
final class StatsStore {
    static let shared = StatsStore()

    private(set) var matches: [MatchRecord] = []

    /// Launch-level policy; RootView turns this off for dev launches.
    var recordingEnabled = true
    private let fileURL: URL

    init() {
        let dir = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        fileURL = dir.appendingPathComponent("matches.json")
        load()
    }

    /// Append the round that just ended. `match` is the engine's token for
    /// the current match: a record is created lazily on the token's first
    /// finished round — so a deal that's quit ten seconds in leaves no
    /// trace, and a round can never leak into a previous match's record.
    /// Multiplayer callers pass their own `mode` and seat list; solo
    /// callers leave the defaults.
    func record(
        _ summary: RoundSummary,
        settings: GameSettings,
        match id: UUID,
        mode: MatchRecord.Mode? = nil,
        seats: [SeatRecord]? = nil
    ) {
        guard recordingEnabled else { return }
        if matches.last?.id != id {
            let seatList = seats ?? (0...settings.opponents).map { p in
                SeatRecord(
                    kind: p == 0 ? .me : .bot,
                    name: AIProfile.seatName(p),
                    emoji: AIProfile.seatEmoji(p)
                )
            }
            matches.append(MatchRecord(
                id: id,
                started: Date(),
                mode: mode ?? .solo(settings.difficulty),
                seats: seatList,
                rounds: [],
                winnerSeat: nil
            ))
        }
        matches[matches.count - 1].rounds.append(RoundRecord(
            caller: summary.caller,
            foundationCounts: summary.foundationCounts,
            nertsLeft: summary.nertsLeft,
            deltas: summary.deltas,
            totals: summary.totals
        ))
        if let w = summary.winner {
            matches[matches.count - 1].winnerSeat = w
        }
        save()
    }

    // MARK: Derived stats

    struct Tally {
        var matchesWon = 0
        var matchesFinished = 0
        var roundsWon = 0
        var roundsPlayed = 0
        var nertsCalls = 0
        var bestRound: Int?
        var currentStreak = 0
        var bestStreak = 0
    }

    /// A round is "won" by strictly out-scoring every other seat; streaks
    /// count finished matches only (walking away doesn't break one).
    func tally(_ difficulty: Difficulty? = nil) -> Tally {
        var t = Tally()
        var streak = 0
        for m in matches {
            if let difficulty, m.difficulty != difficulty { continue }
            guard let me = m.mySeat else { continue }
            for r in m.rounds {
                t.roundsPlayed += 1
                if r.caller == me { t.nertsCalls += 1 }
                let mine = r.deltas[me]
                if r.deltas.enumerated().allSatisfy({ $0.offset == me || $0.element < mine }) {
                    t.roundsWon += 1
                }
                t.bestRound = max(t.bestRound ?? mine, mine)
            }
            if let w = m.winnerSeat {
                t.matchesFinished += 1
                if w == me {
                    t.matchesWon += 1
                    streak += 1
                    t.bestStreak = max(t.bestStreak, streak)
                } else {
                    streak = 0
                }
            }
        }
        t.currentStreak = streak
        return t
    }

    // MARK: Disk

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? decoder.decode([MatchRecord].self, from: data)
        else { return }
        matches = decoded
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(matches) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
