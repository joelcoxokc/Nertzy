import Foundation
import GameKit
import Observation

// MARK: - Wire protocol

/// Tiny Codable messages over GKMatch `.reliable` (guaranteed, ordered
/// per sender) — MULTIPLAYER.md's protocol sketch. JSON on the wire:
/// tens of bytes, readable in logs. Seat numbers on the wire are always
/// GLOBAL (host = 0); each device remaps to its own local seating where
/// 0 = me.
enum NetMessage: Codable {
    case hello(name: String)
    case ping(id: UUID)
    case pong(id: UUID)
    // Table lifecycle (host → all)
    case tableConfig(TableConfig)
    case roundStart(matchID: UUID, round: Int)
    case roundEnd(summary: RoundSummary)        // seat arrays global-ordered
    case tableShuffled
    // Gameplay
    case playerClaim(WireClaim)                 // player → host
    case claimResolved(WireResolution)          // host → all
    case nertsCount(seat: Int, count: Int)      // player → all (badges)
    case nertsCalled(seat: Int)                 // player → host

    func encoded() -> Data? { try? JSONEncoder().encode(self) }
    static func decode(_ data: Data) -> NetMessage? {
        try? JSONDecoder().decode(NetMessage.self, from: data)
    }
}

/// The seating the host announces before dealing: humans in global
/// order (sorted gamePlayerIDs, host first), bots appended after.
struct TableConfig: Codable {
    struct HumanSeat: Codable {
        var id: String          // gamePlayerID
        var name: String
    }
    var humans: [HumanSeat]
    var botCount: Int
    var difficultyRaw: String   // the host's bots' speed
}

/// A card on the wire — `seat` is the GLOBAL owner; every device
/// rebuilds a local Card whose owner is its own seat numbering.
struct WireCard: Codable {
    var seat: Int
    var suit: Int
    var rank: Int
}

/// A foundation play attempt (guest → host).
struct WireClaim: Codable {
    var card: WireCard
    var source: MoveSource
    var pileID: Int?            // host's pile id; nil = new pile (ace)
    var spot: CGPoint?          // where the new pile was tossed, normalized
}

/// The host's verdict on any foundation play — the one message that
/// mutates replicas, applied strictly in arrival order.
struct WireResolution: Codable {
    var card: WireCard
    var fromSeat: Int           // global
    var source: MoveSource
    var landed: Bool
    var pileID: Int             // the pile it joined (or -1 on a bounced ace)
    var newPile: Bool
    var spot: CGPoint?          // set for new piles (and bounced aces)
    var tilt: Double
}

/// The one place seat emojis for online humans come from.
func humanSeatEmoji(_ globalSeat: Int) -> String {
    let set = ["🙂", "😎", "🤠", "🥸"]
    return set[globalSeat % set.count]
}

// MARK: - Seats

/// One chair at an online table.
struct OnlineSeat: Identifiable {
    let id: String          // gamePlayerID — identical on every device
    let name: String
    let isLocal: Bool
    var connected = true
}

// MARK: - A live match

/// A found GKMatch: the seat map, connection state, and (for Phase 1)
/// the echo test that proves the pipe. Phase 2 plugs this into the
/// TableAuthority seam.
@MainActor
@Observable
final class MatchSession {

    private(set) var seats: [OnlineSeat] = []
    private(set) var log: [LogLine] = []
    private(set) var lastRTT: Double?          // seconds, from the last pong
    private(set) var waitingFor = 0            // players still connecting
    private(set) var ended = false

    struct LogLine: Identifiable {
        let id: Int
        let text: String
    }

    @ObservationIgnored private let match: GKMatch
    @ObservationIgnored private var bridge: MatchBridge?
    @ObservationIgnored private var logCounter = 0
    @ObservationIgnored private var pendingPings: [UUID: Date] = [:]

    // Phase 2: the live game riding this match.
    /// Set on guests when the host announces seating — the menu uses it
    /// to enter the game.
    @ObservationIgnored var onTableConfig: ((TableConfig) -> Void)?
    @ObservationIgnored private var gameplaySink: ((NetMessage) -> Void)?
    @ObservationIgnored private weak var engine: GameEngine?
    @ObservationIgnored private var inGame = false

    /// Deterministic seating: every device sorts the same gamePlayerIDs
    /// the same way, so the whole table agrees on seat order — and on
    /// the host (seat 0, lowest id) — without a negotiation message.
    var mySeat: Int { seats.firstIndex(where: \.isLocal) ?? 0 }
    var hostSeat: Int { 0 }
    var iAmHost: Bool { mySeat == hostSeat }

    init(match: GKMatch) {
        self.match = match
        var all = match.players.map {
            OnlineSeat(id: $0.gamePlayerID, name: $0.displayName, isLocal: false)
        }
        all.append(OnlineSeat(
            id: GKLocalPlayer.local.gamePlayerID,
            name: GKLocalPlayer.local.displayName,
            isLocal: true
        ))
        seats = all.sorted { $0.id < $1.id }
        waitingFor = match.expectedPlayerCount
        let bridge = MatchBridge(session: self)
        self.bridge = bridge
        match.delegate = bridge
        addLog(waitingFor > 0
            ? "Table found — waiting for \(waitingFor) more"
            : "Table ready — \(seats.count) seated")
        send(.hello(name: GKLocalPlayer.local.displayName))
    }

    // MARK: Actions

    func ping() {
        let id = UUID()
        pendingPings[id] = Date()
        send(.ping(id: id))
        addLog("🏓 ping sent")
    }

    func leave() {
        guard !ended else { return }
        match.delegate = nil
        match.disconnect()
        ended = true
    }

    func send(_ message: NetMessage) {
        guard let data = message.encoded() else { return }
        do {
            try match.sendData(toAllPlayers: data, with: .reliable)
        } catch {
            addLog("⚠️ send failed: \(error.localizedDescription)")
        }
    }

    // MARK: Starting the game (Phase 2)

    /// Host: announce the table (seating + bots + speed) and deal.
    func startAsHost(engine: GameEngine, botCount: Int, difficulty: Difficulty) {
        let humans = seats.map { TableConfig.HumanSeat(id: $0.id, name: $0.name) }
        let config = TableConfig(
            humans: humans,
            botCount: botCount,
            difficultyRaw: difficulty.rawValue
        )
        send(.tableConfig(config))
        beginGame(engine: engine, config: config)
    }

    /// Guest: enter the game the host just announced.
    func startAsGuest(engine: GameEngine, config: TableConfig) {
        beginGame(engine: engine, config: config)
    }

    private func beginGame(engine: GameEngine, config: TableConfig) {
        let humans = config.humans
        let total = humans.count + config.botCount
        guard total >= 2, total <= 4,
              let myGlobal = humans.firstIndex(where: { $0.id == GKLocalPlayer.local.gamePlayerID })
        else {
            addLog("⚠️ bad table config")
            return
        }
        let host = myGlobal == 0        // seat 0 (lowest id) hosts
        let map = SeatMap(total: total, myGlobal: myGlobal)
        let difficulty = Difficulty(rawValue: config.difficultyRaw) ?? .classic
        let settings = GameSettings(opponents: total - 1, difficulty: difficulty)

        // Seat identity in LOCAL order (0 = me), one list for the table
        // UI and one for the record book.
        var names: [String] = []
        var emojis: [String] = []
        var records: [SeatRecord] = []
        for l in 0..<total {
            let g = map.global(l)
            if g < humans.count {
                let name = l == 0 ? "You" : humans[g].name
                let emoji = humanSeatEmoji(g)
                names.append(name)
                emojis.append(emoji)
                records.append(SeatRecord(
                    kind: l == 0 ? .me : .human(id: humans[g].id),
                    name: name, emoji: emoji
                ))
            } else {
                let bot = AIProfile.roster[(g - humans.count) % AIProfile.roster.count]
                names.append(bot.name)
                emojis.append(bot.emoji)
                records.append(SeatRecord(kind: .bot, name: bot.name, emoji: bot.emoji))
            }
        }

        let authority: any TableAuthority
        if host {
            let h = HostTableAuthority(
                map: map, seatRecords: records, settings: settings,
                send: { [weak self] in self?.send($0) }
            )
            gameplaySink = { [weak h] in h?.receive($0) }
            authority = h
        } else {
            let g = GuestTableAuthority(
                map: map, seatRecords: records, settings: settings,
                send: { [weak self] in self?.send($0) }
            )
            gameplaySink = { [weak g] in g?.receive($0) }
            authority = g
        }

        self.engine = engine
        inGame = true
        engine.installOnlineTable(
            authority,
            host: host,
            aiSeats: host ? (humans.count..<total).map { map.local($0) } : [],
            seatNames: names,
            seatEmojis: emojis,
            settings: settings,
            onLeave: { [weak self] in self?.gameEnded() }
        )
        addLog(host ? "🃏 Dealing…" : "🃏 \(seats.first?.name ?? "Host") is dealing…")
        if host {
            engine.newMatch()
        }
    }

    private func gameEnded() {
        inGame = false
        gameplaySink = nil
        leave()
    }

    // MARK: Events (from the bridge, on the main actor)

    func received(_ data: Data, fromName name: String) {
        guard let message = NetMessage.decode(data) else {
            addLog("⚠️ \(data.count) undecodable bytes from \(name)")
            return
        }
        switch message {
        case .hello(let n):
            addLog("👋 \(n) is at the table")
        case .ping(let id):
            send(.pong(id: id))
            addLog("📨 ping from \(name) — answered")
        case .pong(let id):
            if let sentAt = pendingPings.removeValue(forKey: id) {
                let rtt = Date().timeIntervalSince(sentAt)
                lastRTT = rtt
                addLog(String(format: "🏓 pong from %@ — %.0f ms round trip", name, rtt * 1000))
            }
        case .tableConfig(let config):
            addLog("🪑 Table set: \(config.humans.count) players, \(config.botCount) bots")
            onTableConfig?(config)
        case .roundStart, .roundEnd, .tableShuffled,
             .playerClaim, .claimResolved, .nertsCount, .nertsCalled:
            gameplaySink?(message)
        }
    }

    func playerConnected(id: String, name: String) {
        if let i = seats.firstIndex(where: { $0.id == id }) {
            seats[i].connected = true
        } else {
            // A player whose connection completed after the match formed.
            seats.append(OnlineSeat(id: id, name: name, isLocal: false))
            seats.sort { $0.id < $1.id }
        }
        addLog("🟢 \(name) connected")
        waitingFor = match.expectedPlayerCount
        // Greet over the now-open pipe (invite flows connect after the
        // match is found, so the hello from init can miss).
        send(.hello(name: GKLocalPlayer.local.displayName))
    }

    func playerDisconnected(id: String, name: String) {
        if let i = seats.firstIndex(where: { $0.id == id }) {
            seats[i].connected = false
        }
        addLog("🔴 \(name) disconnected")
        waitingFor = match.expectedPlayerCount
        // Mid-game, a lost human ends the table (rejoin is Phase 3).
        if inGame {
            engine?.leaveOnlineMatch()
        }
    }

    /// GameKit wobbles through `.unknown` while a connection is being
    /// established — it is NOT a disconnect. Show progress, change nothing.
    func playerStateUnknown(name: String) {
        addLog("⏳ \(name) is connecting…")
    }

    func failed(_ message: String) {
        addLog("⚠️ \(message)")
        ended = true
        if inGame {
            engine?.leaveOnlineMatch()
        }
    }

    private func addLog(_ text: String) {
        logCounter += 1
        log.append(LogLine(id: logCounter, text: text))
        if log.count > 24 { log.removeFirst(log.count - 24) }
    }
}

/// GKMatchDelegate needs an NSObject; this bridge keeps MatchSession a
/// plain @Observable class and hops every callback onto the main actor.
private final class MatchBridge: NSObject, GKMatchDelegate {
    weak var session: MatchSession?

    init(session: MatchSession) {
        self.session = session
    }

    func match(_ match: GKMatch, didReceive data: Data, fromRemotePlayer player: GKPlayer) {
        let name = player.displayName
        Task { @MainActor [weak session] in
            session?.received(data, fromName: name)
        }
    }

    func match(_ match: GKMatch, player: GKPlayer, didChange state: GKPlayerConnectionState) {
        let id = player.gamePlayerID
        let name = player.displayName
        Task { @MainActor [weak session] in
            switch state {
            case .connected:
                session?.playerConnected(id: id, name: name)
            case .disconnected:
                session?.playerDisconnected(id: id, name: name)
            default:
                session?.playerStateUnknown(name: name)
            }
        }
    }

    func match(_ match: GKMatch, didFailWithError error: Error?) {
        let message = error?.localizedDescription ?? "Connection failed"
        Task { @MainActor [weak session] in
            session?.failed(message)
        }
    }
}
