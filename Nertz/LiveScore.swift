import Foundation
import GameKit
import Observation

// MARK: - In-person scorekeeping (live mode)
//
// The app as the table's scorecard: everyone plays with real cards, each
// device keys its own rounds, the host's device owns the truth. Players
// are identified by string ids so three kinds of people share one table:
// Game Center players (gamePlayerID — merges with online opponent
// records), app players without Game Center (a persisted device UUID),
// and paper players (no device at all — the host adds them and anyone
// keys their scores).

struct LivePlayer: Codable, Equatable, Identifiable {
    let id: String
    var name: String
    var emoji: String
    var isPaper: Bool
}

/// One player's committed score for one round — either typed straight in
/// or counted out (cards played to the middle + cards left in the Nertz
/// pile) with the math done here.
enum LiveEntry: Codable, Equatable {
    case direct(total: Int)
    case counted(table: Int, nertzLeft: Int)

    /// Nertz scoring: +1 per card on the table, −2 per card stranded.
    var delta: Int {
        switch self {
        case .direct(let total): return total
        case .counted(let table, let nertzLeft): return table - 2 * nertzLeft
        }
    }

    var counted: (table: Int, nertzLeft: Int)? {
        if case .counted(let t, let n) = self { return (t, n) }
        return nil
    }
}

struct LiveRound: Codable, Equatable {
    var entries: [String: LiveEntry] = [:]
    /// Who went out ("called Nertz") — self-reported, feeds the stat.
    var caller: String?
    var closed = false
}

struct LiveMatch: Codable, Equatable {
    let id: UUID
    let started: Date
    var hostID: String
    var hostName: String
    var targetScore: Int
    var players: [LivePlayer]
    var rounds: [LiveRound]
    /// Bumped by the host on every change; guests adopt the highest
    /// revision they've seen and nothing else.
    var revision: Int = 0
    var finished: Date?
    /// Locked in at FINISH (nil = the night just ended, nobody crossed).
    var winnerID: String?

    static func fresh(host: LivePlayer, targetScore: Int) -> LiveMatch {
        LiveMatch(
            id: UUID(),
            started: Date(),
            hostID: host.id,
            hostName: host.name,
            targetScore: targetScore,
            players: [host],
            rounds: [LiveRound()]
        )
    }

    // MARK: Reading the card

    func player(_ id: String) -> LivePlayer? {
        players.first { $0.id == id }
    }

    /// Running total — every committed entry counts, open round included,
    /// so the standings move the moment a score goes in.
    func total(for playerID: String) -> Int {
        rounds.reduce(0) { $0 + ($1.entries[playerID]?.delta ?? 0) }
    }

    /// Players sorted for the standings strip: highest total first.
    var standings: [LivePlayer] {
        players.sorted { total(for: $0.id) > total(for: $1.id) }
    }

    /// "Round 7 · Joel 54 · Sarah 61" — the one-line reminder the menu
    /// and hub both show for a night in progress.
    var summaryLine: String {
        let top = standings.prefix(2)
            .map { "\($0.name) \(total(for: $0.id))" }
            .joined(separator: " · ")
        return "Round \(rounds.count) · \(top)"
    }

    /// The round currently being played, if the match is still going.
    var openRoundIndex: Int? {
        guard finished == nil else { return nil }
        return rounds.lastIndex { !$0.closed }
    }

    /// Whoever has crossed the target on CLOSED rounds and leads outright.
    /// Computed, never stored — a host edit that fixes a typo can
    /// un-crown them until FINISH locks it in.
    var champion: String? {
        let closedTotals = players.map { p in
            (p.id, rounds.filter(\.closed).reduce(0) { $0 + ($1.entries[p.id]?.delta ?? 0) })
        }
        guard let best = closedTotals.max(by: { $0.1 < $1.1 }),
              best.1 >= targetScore,
              closedTotals.filter({ $0.1 == best.1 }).count == 1
        else { return nil }
        return best.0
    }

    // MARK: Mutations (host + solo device only; guests just render)

    mutating func add(player: LivePlayer) {
        guard finished == nil, self.player(player.id) == nil else { return }
        players.append(player)
    }

    mutating func update(player: LivePlayer) {
        guard let i = players.firstIndex(where: { $0.id == player.id }) else { return }
        players[i] = player
    }

    /// Take someone off the card mid-game (host's call; the host stays).
    /// Their old entries keep living in the rounds untouched — they stop
    /// counting (totals walk the player list), and if the same person
    /// rejoins later their column comes back, scores and all.
    mutating func remove(playerID: String) {
        guard finished == nil, playerID != hostID else { return }
        players.removeAll { $0.id == playerID }
    }

    /// The same table, fresh card: everyone stays seated, scores to zero.
    func rematch() -> LiveMatch {
        LiveMatch(
            id: UUID(),
            started: Date(),
            hostID: hostID,
            hostName: hostName,
            targetScore: targetScore,
            players: players,
            rounds: [LiveRound()],
            revision: 1
        )
    }

    /// Write (or clear, with nil) one cell of the card.
    mutating func apply(entry: LiveEntry?, player playerID: String, round: Int) {
        guard finished == nil, rounds.indices.contains(round), player(playerID) != nil else { return }
        rounds[round].entries[playerID] = entry
        if entry == nil, rounds[round].caller == playerID {
            rounds[round].caller = nil
        }
        healOpenRound()
    }

    mutating func setCaller(_ playerID: String?, round: Int) {
        guard finished == nil, rounds.indices.contains(round) else { return }
        rounds[round].caller = playerID
    }

    /// Draw the line under the round being played. Every committed
    /// entry stands; empty cells just score nothing.
    mutating func closeOpenRound() {
        guard let open = openRoundIndex else { return }
        rounds[open].closed = true
        healOpenRound()
    }

    /// Invariant: an unfinished match with no champion always has an
    /// open round. (Also reopens play when a host edit un-crowns.)
    private mutating func healOpenRound() {
        guard finished == nil, champion == nil else { return }
        if !rounds.contains(where: { !$0.closed }) {
            rounds.append(LiveRound())
        }
    }

    mutating func finish() {
        guard finished == nil else { return }
        winnerID = champion
        finished = Date()
    }

    // MARK: Paper players

    /// A stable id from the name ("Grandma Sue" → paper:grandma-sue), so
    /// the same guest merges across game nights in opponent records.
    /// Uniqued against the table for same-name guests.
    func paperID(for name: String) -> String {
        let slug = name.lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { out, ch in
                if ch != "-" || out.last != "-" { out.append(ch) }
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let base = "paper:\(slug.isEmpty ? "guest" : slug)"
        var candidate = base
        var n = 2
        while player(candidate) != nil {
            candidate = "\(base)-\(n)"
            n += 1
        }
        return candidate
    }
}

// MARK: - Who am I

enum LiveIdentity {
    static let emojiPool = ["🙂", "🦊", "🐻", "🐸", "🦉", "🐯", "🐰", "🦄", "🐢", "🐙", "🦁", "🐨"]

    /// Game Center id when signed in (merges with online records),
    /// else a UUID that sticks to this device.
    static var myID: String {
        if GKLocalPlayer.local.isAuthenticated {
            return GKLocalPlayer.local.gamePlayerID
        }
        let key = "liveDeviceID"
        if let saved = UserDefaults.standard.string(forKey: key) { return saved }
        let fresh = "device:\(UUID().uuidString)"
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }

    /// The name shown at the table — editable in the hub; Game Center's
    /// name is the default when it knows one.
    static var myName: String {
        get {
            if let saved = UserDefaults.standard.string(forKey: "liveName"), !saved.isEmpty {
                return saved
            }
            if GKLocalPlayer.local.isAuthenticated {
                return GKLocalPlayer.local.displayName
            }
            return "Player"
        }
        set { UserDefaults.standard.set(newValue, forKey: "liveName") }
    }

    static var myEmoji: String {
        get { UserDefaults.standard.string(forKey: "liveEmoji") ?? emojiPool[0] }
        set { UserDefaults.standard.set(newValue, forKey: "liveEmoji") }
    }

    static var me: LivePlayer {
        LivePlayer(id: myID, name: myName, emoji: myEmoji, isPaper: false)
    }
}

// MARK: - Into the record book

/// A finished night becomes ordinary match history: every device that
/// claimed a player writes its own perspective through the same
/// StatsStore.record door solo and online rounds use — so games played,
/// opponent records, and Game Center leaderboards all just work. Seat 0
/// is me on every device (the multiplayer convention the leaderboard
/// reporter expects). Paper players record nothing themselves, but they
/// appear in everyone else's book as human seats.
@MainActor
enum LiveRecorder {
    private static let recordedKey = "liveRecordedMatches"

    static func recordIfNeeded(_ match: LiveMatch, myPlayerID: String) {
        guard match.finished != nil, let me = match.player(myPlayerID) else { return }
        // Final snapshots can arrive more than once — one entry per night.
        var recorded = UserDefaults.standard.stringArray(forKey: recordedKey) ?? []
        guard !recorded.contains(match.id.uuidString) else { return }

        let scoringRounds = match.rounds.filter { !$0.entries.isEmpty }
        guard !scoringRounds.isEmpty else { return }
        recorded = Array(recorded.suffix(9)) + [match.id.uuidString]
        UserDefaults.standard.set(recorded, forKey: recordedKey)

        let seats = [me] + match.players.filter { $0.id != myPlayerID }
        let seatRecords = seats.map { p in
            SeatRecord(kind: p.id == myPlayerID ? .me : .human(id: p.id), name: p.name, emoji: p.emoji)
        }
        let settings = GameSettings(
            opponents: max(1, seats.count - 1),
            difficulty: .classic,
            targetScore: match.targetScore
        )
        var totals = Array(repeating: 0, count: seats.count)
        for (i, round) in scoringRounds.enumerated() {
            let deltas = seats.map { round.entries[$0.id]?.delta ?? 0 }
            for j in totals.indices { totals[j] += deltas[j] }
            let counted = seats.map { round.entries[$0.id]?.counted }
            let summary = RoundSummary(
                caller: round.caller.flatMap { c in seats.firstIndex { $0.id == c } } ?? -1,
                foundationCounts: counted.map { $0?.table ?? 0 },
                nertsLeft: counted.map { $0?.nertzLeft ?? 0 },
                deltas: deltas,
                totals: totals,
                winner: i == scoringRounds.count - 1
                    ? match.winnerID.flatMap { w in seats.firstIndex { $0.id == w } }
                    : nil
            )
            StatsStore.shared.record(
                summary, settings: settings, match: match.id, mode: .live, seats: seatRecords
            )
        }
    }
}

// MARK: - Disk

/// The night on disk — both the host's room (revivable: reopening the
/// app re-advertises the same table) and a guest's last look at the
/// board (so the card never blanks while the host's phone naps).
struct LiveSave: Codable {
    var match: LiveMatch
    var myPlayerID: String
    var isHost: Bool
    /// The advertised room, stable across PLAY AGAIN rematches (older
    /// saves fall back to the match id, which used to be the room).
    var roomID: String?
}

@MainActor
@Observable
final class LiveSaver {
    static let shared = LiveSaver()

    private(set) var saved: LiveSave?
    @ObservationIgnored private let fileURL: URL

    private init() {
        let dir = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        fileURL = dir.appendingPathComponent("live.json")
        if let data = try? Data(contentsOf: fileURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            saved = try? decoder.decode(LiveSave.self, from: data)
        }
    }

    func save(_ save: LiveSave) {
        saved = save
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(save) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    func clear() {
        saved = nil
        try? FileManager.default.removeItem(at: fileURL)
    }
}
