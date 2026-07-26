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
    /// Ping/pong doubles as clock sync: `t0` is the sender's clock at
    /// send, `t1` the responder's clock at receipt. With those and the
    /// arrival time, a guest can express any moment in the host's
    /// clock — which is what makes "first tap wins" measurable.
    case ping(id: UUID, t0: Double)
    case pong(id: UUID, t0: Double, t1: Double)
    /// Whoever created the table (cut the code, sent the invite) gets
    /// the deal. Ties (pure auto-match, both initiated) break to the
    /// lowest claiming id — same rule on every device.
    case claimHost(id: String)
    // Table lifecycle (host → all)
    case tableConfig(TableConfig)
    case roundStart(matchID: UUID, round: Int)
    case roundEnd(summary: RoundSummary)        // seat arrays global-ordered
    case tableShuffled
    // Gameplay
    case playerClaim(WireClaim)                 // player → host
    case claimResolved(WireResolution)          // host → all
    case nertsCount(seat: Int, count: Int)      // player → all (badges)
    /// player → host. `tapAt` (host clock) is when their pile emptied —
    /// NERTS is arbitrated by earliest call, not first arrival. Optional
    /// so an unsynced clock (or an older build) still calls the round;
    /// the host then times it on arrival, as it used to.
    case nertsCalled(seat: Int, tapAt: Double?)
    case seatConverted(seat: Int)               // host → all: a bot took the chair
    // Pause — anyone may ask, only the host declares.
    case pauseRequest(seat: Int, on: Bool)      // player → host
    case pauseState(by: Int?)                   // host → all; nil = playing

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
    /// First to this total wins. Optional so configs from builds that
    /// predate the setting still decode (they played to 100).
    var targetScore: Int?
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
    /// When the player let go, expressed in the HOST's clock. The host
    /// arbitrates on this, not on arrival order. Optional so a claim
    /// from a build that predates tap stamping still decodes (the host
    /// falls back to treating it as tapped on arrival).
    var tapAt: Double?
}

// MARK: - A clock everyone can agree on

/// The table's shared clock. Every device measures its offset from the
/// host's clock off ping/pong, so "when did you tap?" means the same
/// thing everywhere. The host's own offset is always zero.
///
/// Accuracy is what matters, not precision: we keep a short window of
/// samples and trust the one with the *lowest* round trip, because a
/// fast round trip is the one least distorted by queueing. Absolute
/// wall-clock disagreement between devices is irrelevant — it cancels.
@MainActor
final class TableClock {
    private var samples: [(rtt: TimeInterval, offset: TimeInterval)] = []

    /// The sample least distorted by queueing. Recomputed on read — the
    /// window is eight entries, so this is cheaper than keeping two
    /// stored copies honest.
    private var best: (rtt: TimeInterval, offset: TimeInterval)? {
        samples.min { $0.rtt < $1.rtt }
    }

    /// hostClock ≈ myClock + offset.
    var offset: TimeInterval { best?.offset ?? 0 }
    /// Round trip to the host, when we've measured one.
    var rtt: TimeInterval? { best?.rtt }
    /// False until a round trip has actually landed. An unsynced stamp
    /// is worse than none — two devices' wall clocks can disagree by
    /// seconds, which would hand someone every pile or none. Until this
    /// flips, plays go out unstamped and the host times them on arrival.
    var synced: Bool { !samples.isEmpty }

    /// Now, in the host's clock.
    func now() -> TimeInterval { Date().timeIntervalSince1970 + offset }

    /// One completed round trip: `t0` my send, `t1` their receipt,
    /// `t3` my receipt — all in each device's own clock.
    func sample(t0: TimeInterval, t1: TimeInterval, t3: TimeInterval) {
        // Their clock at t1 vs. the midpoint of my send and receive.
        samples.append((max(0, t3 - t0), t1 - (t0 + t3) / 2))
        if samples.count > 8 { samples.removeFirst() }
    }
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
    /// Last measured round trip per player — the host sizes its
    /// arbitration hold window off the worst one at the table.
    @ObservationIgnored private var rttByPlayer: [String: TimeInterval] = [:]
    @ObservationIgnored private var heartbeat: Task<Void, Never>?

    /// This device's read on the host's clock (identity on the host).
    @ObservationIgnored let clock = TableClock()

    /// How long the host holds a contested landing before deciding, so
    /// a card tapped first but delivered late still wins its pile.
    /// Scaled to the worst connection at the table and capped hard —
    /// past a third of a second the wait reads as lag, and at that
    /// point a fair table beats a snappy one only so far.
    var tableHold: TimeInterval {
        let worstOneWay = (rttByPlayer.values.max() ?? 0) / 2
        return min(max(worstOneWay * 1.5 + 0.04, 0.12), 0.35)
    }

    // Phase 2: the live game riding this match.
    /// Set on guests when the host announces seating — the menu uses it
    /// to enter the game.
    @ObservationIgnored var onTableConfig: ((TableConfig) -> Void)?
    @ObservationIgnored private var gameplaySink: ((NetMessage) -> Void)?
    @ObservationIgnored private weak var engine: GameEngine?
    @ObservationIgnored private var inGame = false
    @ObservationIgnored private var seatMap: SeatMap?

    /// The player with the deal. Whoever created the table claims it
    /// (claimHost); until a claim lands — or if nobody claims (pure
    /// auto-match) — it falls back to the lowest gamePlayerID, a rule
    /// every device computes identically. The seating the host
    /// broadcasts in tableConfig is what finally binds everyone.
    private(set) var hostID: String?
    @ObservationIgnored private var isInitiator = false

    var mySeat: Int { seats.firstIndex(where: \.isLocal) ?? 0 }
    var hostSeat: Int {
        hostID.flatMap { id in seats.firstIndex(where: { $0.id == id }) } ?? 0
    }
    var iAmHost: Bool { mySeat == hostSeat }

    /// I created this table — announce that the deal is mine.
    func claimTheDeal() {
        isInitiator = true
        registerHostClaim(GKLocalPlayer.local.gamePlayerID)
        send(.claimHost(id: GKLocalPlayer.local.gamePlayerID))
    }

    private func registerHostClaim(_ id: String) {
        // Once the table is dealt the seating has settled it; a late
        // claim must not move the deal (or the clock's reference peer)
        // out from under a game in progress.
        guard !inGame else { return }
        if let current = hostID {
            hostID = min(current, id)
        } else {
            hostID = id
        }
    }

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
        let now = Date()
        // Every peer answers the same ping, so a record has to outlive
        // the first reply — otherwise only the quickest peer is ever
        // measured and the hold window never sees the slowest one.
        // Sweep instead: unanswered pings age out, so this stays small.
        pendingPings = pendingPings.filter { now.timeIntervalSince($0.value) < 10 }
        let id = UUID()
        pendingPings[id] = now
        send(.ping(id: id, t0: now.timeIntervalSince1970))
        if !inGame { addLog("🏓 ping sent") }
    }

    /// A quiet ping every couple of seconds for the whole match: it
    /// keeps each guest's clock offset honest as the network drifts,
    /// and keeps the host's hold window sized to the real connection.
    private func startHeartbeat() {
        heartbeat?.cancel()
        heartbeat = Task { [weak self] in
            // Ends itself if the session is gone, so a torn-down match
            // can never leave a timer waking the main actor forever.
            while !Task.isCancelled {
                guard let self else { break }
                self.ping()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func leave() {
        heartbeat?.cancel()
        heartbeat = nil
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

    /// Answer one peer rather than shouting at the table. Pongs are the
    /// only traffic that has exactly one interested recipient, and at a
    /// four-player table broadcasting them would put twelve times more
    /// heartbeat messages on the wire than anyone reads.
    private func send(_ message: NetMessage, to playerID: String) {
        guard let data = message.encoded() else { return }
        guard let player = match.players.first(where: { $0.gamePlayerID == playerID }) else {
            send(message)       // unknown peer — the broadcast still reaches them
            return
        }
        try? match.send(data, to: [player], dataMode: .reliable)
    }

    // MARK: Starting the game (Phase 2)

    /// Host: announce the table (seating + bots + speed) and deal.
    /// The host seats itself first — tableConfig's order IS the global
    /// seating, so whoever sends it becomes seat 0 everywhere.
    func startAsHost(engine: GameEngine, botCount: Int, difficulty: Difficulty, targetScore: Int = 100) {
        let me = seats.filter(\.isLocal)
        let others = seats.filter { !$0.isLocal }
        let humans = (me + others).map { TableConfig.HumanSeat(id: $0.id, name: $0.name) }
        let config = TableConfig(
            humans: humans,
            botCount: botCount,
            difficultyRaw: difficulty.rawValue,
            targetScore: targetScore
        )
        send(.tableConfig(config))
        beginGame(engine: engine, config: config)
    }

    /// Guest: enter the game the host just announced.
    func startAsGuest(engine: GameEngine, config: TableConfig) {
        beginGame(engine: engine, config: config)
    }

    private func beginGame(engine: GameEngine, config: TableConfig) {
        guard !inGame else { return }    // first announced table wins
        let humans = config.humans
        let total = humans.count + config.botCount
        guard total >= 2, total <= 4,
              let myGlobal = humans.firstIndex(where: { $0.id == GKLocalPlayer.local.gamePlayerID })
        else {
            addLog("⚠️ bad table config")
            return
        }
        let host = myGlobal == 0        // seat 0 (lowest id) hosts
        // The announced seating is the last word on who has the deal —
        // bind it here rather than trusting a claimHost message that may
        // never have arrived, because clock sync keys off knowing which
        // peer's pongs carry the table's clock.
        hostID = humans.first?.id
        let map = SeatMap(total: total, myGlobal: myGlobal)
        let difficulty = Difficulty(rawValue: config.difficultyRaw) ?? .classic
        let settings = GameSettings(
            opponents: total - 1,
            difficulty: difficulty,
            targetScore: config.targetScore ?? 100
        )

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
                hold: { [weak self] in self?.tableHold ?? 0.2 },
                send: { [weak self] in self?.send($0) }
            )
            gameplaySink = { [weak h] in h?.receive($0) }
            authority = h
        } else {
            let g = GuestTableAuthority(
                map: map, seatRecords: records, settings: settings,
                clock: clock,
                send: { [weak self] in self?.send($0) }
            )
            gameplaySink = { [weak g] in g?.receive($0) }
            authority = g
        }

        self.engine = engine
        self.seatMap = map
        inGame = true
        startHeartbeat()
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

    func received(_ data: Data, from id: String, name: String) {
        guard let message = NetMessage.decode(data) else {
            addLog("⚠️ \(data.count) undecodable bytes from \(name)")
            return
        }
        switch message {
        case .hello(let n):
            addLog("👋 \(n) is at the table")
        case .claimHost(let hostClaim):
            let hadDeal = iAmHost
            registerHostClaim(hostClaim)
            if hadDeal != iAmHost || hostID == hostClaim {
                addLog("👑 \(name) has the deal")
            }
        case .ping(let pingID, let t0):
            // Echo their send time back with ours; they do the maths.
            send(.pong(id: pingID, t0: t0, t1: Date().timeIntervalSince1970), to: id)
            if !inGame { addLog("📨 ping from \(name) — answered") }
        case .pong(let pingID, let t0, let t1):
            guard let sentAt = pendingPings[pingID] else { return }
            let t3 = Date()
            let rtt = t3.timeIntervalSince(sentAt)
            lastRTT = rtt
            rttByPlayer[id] = rtt
            // Only the host's clock is the table's clock.
            if id == hostID {
                clock.sample(t0: t0, t1: t1, t3: t3.timeIntervalSince1970)
            }
            if !inGame {
                addLog(String(format: "🏓 pong from %@ — %.0f ms round trip", name, rtt * 1000))
            }
        case .tableConfig(let config):
            addLog("🪑 Table set: \(config.humans.count) players, \(config.botCount) bots")
            onTableConfig?(config)
        case .roundStart, .roundEnd, .tableShuffled,
             .playerClaim, .claimResolved, .nertsCount, .nertsCalled,
             .seatConverted, .pauseRequest, .pauseState:
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
        // match is found, so the hello from init can miss) — and
        // restate the deal for anyone who missed the claim.
        send(.hello(name: GKLocalPlayer.local.displayName))
        if isInitiator {
            send(.claimHost(id: GKLocalPlayer.local.gamePlayerID))
        }
    }

    func playerDisconnected(id: String, name: String) {
        guard let globalSeat = seats.firstIndex(where: { $0.id == id }) else { return }
        seats[globalSeat].connected = false
        addLog("🔴 \(name) disconnected")
        waitingFor = match.expectedPlayerCount
        guard inGame else { return }
        if globalSeat == 0 {
            // The host is gone — no arbiter, the table closes.
            engine?.leaveOnlineMatch(note: "\(name) closed the table")
        } else if iAmHost, let seatMap {
            // A guest left: settle the round and seat a bot in their
            // chair from the next deal. Other guests hear it from the
            // host's roundEnd + seatConverted messages.
            engine?.onlineHumanLeft(seat: seatMap.local(globalSeat), name: name)
        }
    }

    /// GameKit wobbles through `.unknown` while a connection is being
    /// established — it is NOT a disconnect. Show progress, change nothing.
    func playerStateUnknown(name: String) {
        addLog("⏳ \(name) is connecting…")
    }

    func failed(_ message: String) {
        addLog("⚠️ \(message)")
        heartbeat?.cancel()
        heartbeat = nil
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
        let id = player.gamePlayerID
        Task { @MainActor [weak session] in
            session?.received(data, from: id, name: name)
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
