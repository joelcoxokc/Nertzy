import SwiftUI
import Observation

// MARK: - Seat mapping (multiplayer Phase 2)

/// Wire seats are GLOBAL (humans in sorted-gamePlayerID order, host
/// first, bots appended). In memory every device keeps the solo
/// convention — seat 0 is me — so the engine and views never learn
/// about global seats. This map is the only translator.
struct SeatMap {
    let total: Int
    let myGlobal: Int
    private let localToGlobal: [Int]
    private let globalToLocal: [Int]

    init(total: Int, myGlobal: Int) {
        self.total = total
        self.myGlobal = myGlobal
        var l2g = [myGlobal]
        l2g.append(contentsOf: (0..<total).filter { $0 != myGlobal })
        localToGlobal = l2g
        var g2l = Array(repeating: 0, count: total)
        for (l, g) in l2g.enumerated() { g2l[g] = l }
        globalToLocal = g2l
    }

    func local(_ g: Int) -> Int {
        (0..<total).contains(g) ? globalToLocal[g] : 0
    }

    func global(_ l: Int) -> Int {
        (0..<total).contains(l) ? localToGlobal[l] : myGlobal
    }

    func localCard(_ w: WireCard) -> Card {
        Card(owner: local(w.seat), suit: Suit(rawValue: w.suit) ?? .spades, rank: w.rank)
    }

    func wireCard(_ c: Card) -> WireCard {
        WireCard(seat: global(c.owner), suit: c.suit.rawValue, rank: c.rank)
    }

    /// Reorder a global-indexed per-seat array into local order.
    func toLocal(_ a: [Int]) -> [Int] { (0..<total).map { a[global($0)] } }
    /// Reorder a local-indexed per-seat array into global order.
    func toGlobal(_ a: [Int]) -> [Int] { (0..<total).map { a[local($0)] } }

    func summaryToGlobal(_ s: RoundSummary) -> RoundSummary {
        RoundSummary(
            caller: global(s.caller),
            foundationCounts: toGlobal(s.foundationCounts),
            nertsLeft: toGlobal(s.nertsLeft),
            deltas: toGlobal(s.deltas),
            totals: toGlobal(s.totals),
            winner: s.winner.map(global)
        )
    }

    func summaryToLocal(_ s: RoundSummary) -> RoundSummary {
        RoundSummary(
            caller: local(s.caller),
            foundationCounts: toLocal(s.foundationCounts),
            nertsLeft: toLocal(s.nertsLeft),
            deltas: toLocal(s.deltas),
            totals: toLocal(s.totals),
            winner: s.winner.map(local)
        )
    }
}

// MARK: - The host's table

/// The device that arbitrates: a full LocalTableAuthority runs the
/// rules exactly like solo (bots included), and this wrapper sits on
/// its delegate line — every landing, bounce, shuffle, and settlement
/// is forwarded to the local engine AND broadcast to the guests.
/// Remote plays arrive as messages and enter the same claim pipeline
/// bots use; "first card down" is decided by landing at this table.
@MainActor
@Observable
final class HostTableAuthority: TableAuthority, TableAuthorityDelegate {

    @ObservationIgnored weak var delegate: TableAuthorityDelegate?

    private let inner = LocalTableAuthority()
    @ObservationIgnored private let map: SeatMap
    @ObservationIgnored private let seatRecords: [SeatRecord]
    @ObservationIgnored private let matchSettings: GameSettings
    @ObservationIgnored private let sendMessage: (NetMessage) -> Void
    @ObservationIgnored private var matchID = UUID()
    @ObservationIgnored private var recordRounds = true
    /// Last self-reported nerts counts for seats living on other
    /// devices (local-indexed) — badge data and the round-end tally.
    private(set) var remoteNerts: [Int?]

    init(
        map: SeatMap,
        seatRecords: [SeatRecord],
        settings: GameSettings,
        send: @escaping (NetMessage) -> Void
    ) {
        self.map = map
        self.seatRecords = seatRecords
        self.matchSettings = settings
        self.sendMessage = send
        self.remoteNerts = Array(repeating: nil, count: map.total)
        inner.delegate = self
    }

    // MARK: Forwarded table state

    var foundations: [FoundationPile] { inner.foundations }
    var flying: [FlyingCard] { inner.flying }
    var scores: [Int] { inner.scores }
    var roundNumber: Int { inner.roundNumber }
    var summary: RoundSummary? { inner.summary }
    var maxFoundations: Int { inner.maxFoundations }

    // MARK: Lifecycle

    func beginMatch(settings: GameSettings) {
        matchID = UUID()
        inner.beginMatch(settings: settings)
    }

    func advanceRound() { inner.advanceRound() }

    func beginRound() {
        remoteNerts = Array(repeating: nil, count: map.total)
        inner.beginRound()
        sendMessage(.roundStart(matchID: matchID, round: inner.roundNumber))
    }

    func endRound(caller: Int, recordStats: Bool) {
        recordRounds = recordStats
        // The inner table must not write the record book — this wrapper
        // records with the multiplayer seat list instead.
        inner.endRound(caller: caller, recordStats: false)
    }

    func abandonRound() { inner.abandonRound() }

    // MARK: Plays

    func playNow(_ card: Card, from source: MoveSource, at index: Int?, spot: CGPoint?) -> Int? {
        let wasNewPile = index == nil
        guard let pileID = inner.playNow(card, from: source, at: index, spot: spot) else { return nil }
        broadcastResolution(
            card: card, fromSeat: 0, source: source,
            landed: true, pileID: pileID, newPile: wasNewPile, bounceSpot: nil
        )
        return pileID
    }

    func submitClaim(_ card: Card, fromSeat: Int, source: MoveSource, pileIndex: Int?, spot: CGPoint?, flight: TimeInterval) -> Bool {
        inner.submitClaim(card, fromSeat: fromSeat, source: source, pileIndex: pileIndex, spot: spot, flight: flight)
    }

    func undoFoundationPlay(pileID: Int, cardID: String, wasNewPile: Bool) -> Bool {
        false   // no undo message in the protocol; the table moved on
    }

    // MARK: Badges

    func reportNerts(seat: Int, count: Int) {
        sendMessage(.nertsCount(seat: map.global(seat), count: count))
    }

    func reportedNertsCount(seat: Int) -> Int? {
        seat < remoteNerts.count ? remoteNerts[seat] : nil
    }

    // MARK: Pacing (driven by the host engine's tick)

    func settleDueClaims(now: Date) { inner.settleDueClaims(now: now) }
    func checkStuck(now: Date) { inner.checkStuck(now: now) }
    func noteActivity() { inner.noteActivity() }
    func shiftDeadlines(by delta: TimeInterval) { inner.shiftDeadlines(by: delta) }

    // MARK: Wire intake

    func receive(_ message: NetMessage) {
        switch message {
        case .playerClaim(let claim):
            let card = map.localCard(claim.card)
            let fromSeat = map.local(claim.card.seat)
            let index = claim.pileID.flatMap { pid in
                inner.foundations.firstIndex(where: { $0.id == pid })
            }
            // A targeted pile that's already gone can never land.
            let doomed = claim.pileID != nil && index == nil
            let accepted = !doomed && inner.submitClaim(
                card, fromSeat: fromSeat, source: claim.source,
                pileIndex: index, spot: claim.spot, flight: 0.3
            )
            if !accepted {
                // Illegal at the door — answer anyway so the thrower's
                // card flies home instead of hanging.
                sendMessage(.claimResolved(WireResolution(
                    card: claim.card, fromSeat: claim.card.seat, source: claim.source,
                    landed: false, pileID: claim.pileID ?? -1,
                    newPile: claim.pileID == nil, spot: claim.spot, tilt: 0
                )))
            }
        case .nertsCalled(let globalSeat):
            delegate?.remoteNertsCall(seat: map.local(globalSeat))
        case .nertsCount(let globalSeat, let count):
            let local = map.local(globalSeat)
            if local != 0, local < remoteNerts.count {
                remoteNerts[local] = count
            }
        default:
            break
        }
    }

    // MARK: Delegate interception (inner table → engine + wire)

    func claimLanded(_ claim: FlyingCard, on pileID: Int) {
        broadcastResolution(
            card: claim.card, fromSeat: claim.fromSeat, source: claim.source,
            landed: true, pileID: pileID,
            newPile: claim.pileID == nil, bounceSpot: nil
        )
        delegate?.claimLanded(claim, on: pileID)
    }

    func claimBounced(_ claim: FlyingCard) {
        // A remote card bounced back onto its owner's nerts pile —
        // their reported count is now one short. Fix the tally.
        let simulatedHere = claim.fromSeat == 0 || map.global(claim.fromSeat) >= seatRecordsHumanCount
        if !simulatedHere, claim.source == .nertsTop, let n = remoteNerts[claim.fromSeat] {
            remoteNerts[claim.fromSeat] = n + 1
        }
        broadcastResolution(
            card: claim.card, fromSeat: claim.fromSeat, source: claim.source,
            landed: false, pileID: claim.pileID ?? -1,
            newPile: claim.pileID == nil, bounceSpot: claim.spot
        )
        delegate?.claimBounced(claim)
    }

    private var seatRecordsHumanCount: Int {
        seatRecords.filter {
            if case .bot = $0.kind { return false } else { return true }
        }.count
    }

    func nertsLeftCounts() -> [Int] {
        // Local boards for the seats that live here; self-reported
        // counts (bounce-adjusted) for everyone else.
        var counts = delegate?.nertsLeftCounts() ?? Array(repeating: 0, count: map.total)
        for seat in 0..<map.total {
            if let reported = remoteNerts[seat], seat < counts.count {
                counts[seat] = reported
            }
        }
        return counts
    }

    func roundEnded(_ summary: RoundSummary) {
        sendMessage(.roundEnd(summary: map.summaryToGlobal(summary)))
        if recordRounds {
            StatsStore.shared.record(
                summary, settings: matchSettings, match: matchID,
                mode: .multiplayer, seats: seatRecords
            )
        }
        delegate?.roundEnded(summary)
    }

    func tableShuffleCalled() {
        sendMessage(.tableShuffled)
        delegate?.tableShuffleCalled()
    }

    // Inner tables never emit these three; conformance completeness.
    func roundStarted(round: Int) {}
    func remoteNertsCall(seat: Int) {}
    func tableClosed(reason: String) {}

    private func broadcastResolution(
        card: Card, fromSeat: Int, source: MoveSource,
        landed: Bool, pileID: Int, newPile: Bool, bounceSpot: CGPoint?
    ) {
        var spot: CGPoint?
        var tilt = 0.0
        if landed, let pile = inner.foundations.first(where: { $0.id == pileID }) {
            spot = pile.spot
            tilt = pile.tilt
        } else if !landed {
            spot = bounceSpot
        }
        sendMessage(.claimResolved(WireResolution(
            card: map.wireCard(card), fromSeat: map.global(fromSeat), source: source,
            landed: landed, pileID: pileID, newPile: newPile, spot: spot, tilt: tilt
        )))
    }
}

// MARK: - A guest's table

/// A strictly host-ordered replica. Foundations only ever change when
/// a `claimResolved` arrives; your own plays become short claims tossed
/// at the host (the card leaves your hand immediately and slides toward
/// the pile — the host's answer lands it or bounces it home). All the
/// flight visuals reuse the solo claim pipeline: outcomes are queued on
/// `flying` and settled by the engine's tick.
@MainActor
@Observable
final class GuestTableAuthority: TableAuthority {

    @ObservationIgnored weak var delegate: TableAuthorityDelegate?

    private(set) var foundations: [FoundationPile] = []
    private(set) var flying: [FlyingCard] = []
    private(set) var scores: [Int] = []
    private(set) var roundNumber = 1
    private(set) var summary: RoundSummary?
    var maxFoundations: Int { 4 * map.total }

    /// Reported badge counts for every seat that isn't mine (bots and
    /// humans alike — they all live on other devices).
    private(set) var remoteNerts: [Int?]

    @ObservationIgnored private let map: SeatMap
    @ObservationIgnored private let seatRecords: [SeatRecord]
    @ObservationIgnored private let matchSettings: GameSettings
    @ObservationIgnored private let sendMessage: (NetMessage) -> Void
    @ObservationIgnored private var matchID: UUID?
    @ObservationIgnored private var outcomes: [String: WireResolution] = [:]
    @ObservationIgnored private var roundActive = false
    @ObservationIgnored private var awaitingRoundEnd = false

    init(
        map: SeatMap,
        seatRecords: [SeatRecord],
        settings: GameSettings,
        send: @escaping (NetMessage) -> Void
    ) {
        self.map = map
        self.seatRecords = seatRecords
        self.matchSettings = settings
        self.sendMessage = send
        self.remoteNerts = Array(repeating: nil, count: map.total)
        self.scores = Array(repeating: 0, count: map.total)
    }

    // MARK: Lifecycle (the host drives; the engine follows)

    func beginMatch(settings: GameSettings) {}
    func advanceRound() {}

    func beginRound() {
        foundations = []
        flying = []
        outcomes = [:]
        summary = nil
        remoteNerts = Array(repeating: nil, count: map.total)
        roundActive = true
        awaitingRoundEnd = false
    }

    func endRound(caller: Int, recordStats: Bool) {
        // My nerts call — the host settles and answers with roundEnd.
        guard roundActive, !awaitingRoundEnd else { return }
        awaitingRoundEnd = true
        sendMessage(.nertsCalled(seat: map.global(caller)))
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard let self, self.awaitingRoundEnd, self.roundActive else { return }
            self.delegate?.tableClosed(reason: "The table went quiet")
        }
    }

    func abandonRound() { roundActive = false }

    // MARK: Plays

    func playNow(_ card: Card, from source: MoveSource, at index: Int?, spot: CGPoint?) -> Int? {
        guard roundActive else { return nil }
        let pileID: Int?
        if let index {
            guard index < foundations.count, foundations[index].accepts(card) else { return nil }
            pileID = foundations[index].id
        } else {
            guard card.rank == 1, foundations.count < maxFoundations else { return nil }
            pileID = nil
        }
        // Born landed: the card slides straight from your hand toward
        // the pile while the claim races to the host.
        flying.append(FlyingCard(
            card: card, fromSeat: 0, source: source,
            pileID: pileID,
            spot: pileID == nil ? (spot ?? CGPoint(x: 0.5, y: 0.4)) : nil,
            resolveAt: Date().addingTimeInterval(0.35),
            landed: true
        ))
        sendMessage(.playerClaim(WireClaim(
            card: map.wireCard(card), source: source, pileID: pileID, spot: spot
        )))
        return pileID ?? -1
    }

    func submitClaim(_ card: Card, fromSeat: Int, source: MoveSource, pileIndex: Int?, spot: CGPoint?, flight: TimeInterval) -> Bool {
        false   // guests simulate no bot seats
    }

    func undoFoundationPlay(pileID: Int, cardID: String, wasNewPile: Bool) -> Bool {
        false
    }

    // MARK: Badges

    func reportNerts(seat: Int, count: Int) {
        sendMessage(.nertsCount(seat: map.global(seat), count: count))
    }

    func reportedNertsCount(seat: Int) -> Int? {
        seat < remoteNerts.count ? remoteNerts[seat] : nil
    }

    // MARK: Pacing

    func settleDueClaims(now: Date) {
        let due = flying.filter { !$0.bouncing && now >= $0.resolveAt }
        for f in due {
            if let res = outcomes.removeValue(forKey: f.id) {
                settle(f, with: res)
            } else if f.fromSeat == 0, now.timeIntervalSince(f.resolveAt) > 3 {
                // The host never answered — take the card back.
                flying.removeAll { $0.id == f.id }
                delegate?.claimBounced(f)
            }
        }
    }

    func checkStuck(now: Date) {}
    func noteActivity() {}

    func shiftDeadlines(by delta: TimeInterval) {
        for i in flying.indices {
            flying[i].resolveAt = flying[i].resolveAt.addingTimeInterval(delta)
        }
    }

    // MARK: Wire intake

    func receive(_ message: NetMessage) {
        switch message {
        case .claimResolved(let res):
            handleResolution(res)
        case .nertsCount(let globalSeat, let count):
            let local = map.local(globalSeat)
            if local != 0, local < remoteNerts.count {
                remoteNerts[local] = count
            }
        case .roundStart(let matchID, let round):
            handleRoundStart(matchID: matchID, round: round)
        case .roundEnd(let globalSummary):
            handleRoundEnd(globalSummary)
        case .tableShuffled:
            delegate?.tableShuffleCalled()
        default:
            break
        }
    }

    private func handleResolution(_ res: WireResolution) {
        let fromLocal = map.local(res.fromSeat)
        let card = map.localCard(res.card)
        if fromLocal == 0 {
            // The answer to my own toss — settle it on the next tick.
            guard let idx = flying.firstIndex(where: { $0.id == card.id }) else { return }
            outcomes[card.id] = res
            flying[idx].resolveAt = Date()
        } else {
            // Someone else's play: give it a short flight, outcome known.
            outcomes[card.id] = res
            flying.append(FlyingCard(
                card: card, fromSeat: fromLocal, source: res.source,
                pileID: res.newPile ? nil : res.pileID,
                spot: res.newPile ? res.spot : nil,
                resolveAt: Date().addingTimeInterval(0.3)
            ))
            let id = card.id
            Task {
                try? await Task.sleep(for: .milliseconds(30))
                if let i = self.flying.firstIndex(where: { $0.id == id }) {
                    self.flying[i].landed = true
                }
            }
        }
    }

    private func settle(_ f: FlyingCard, with res: WireResolution) {
        if res.landed {
            flying.removeAll { $0.id == f.id }
            commitToReplica(f, res)
        } else if f.fromSeat == 0 {
            // My card lost the race — straight back to my board.
            flying.removeAll { $0.id == f.id }
            delegate?.claimBounced(f)
        } else if let idx = flying.firstIndex(where: { $0.id == f.id }) {
            // Their card flies home and fades.
            flying[idx].bouncing = true
            delegate?.claimBounced(f)   // no-op here; their board, their device
            let id = f.id
            Task {
                try? await Task.sleep(for: .milliseconds(500))
                self.flying.removeAll { $0.id == id }
            }
        }
    }

    private func commitToReplica(_ f: FlyingCard, _ res: WireResolution) {
        if res.newPile {
            guard !foundations.contains(where: { $0.id == res.pileID }) else { return }
            foundations.append(FoundationPile(
                id: res.pileID, cards: [f.card],
                spot: res.spot ?? CGPoint(x: 0.5, y: 0.4),
                tilt: res.tilt
            ))
        } else {
            guard let i = foundations.firstIndex(where: { $0.id == res.pileID }) else { return }
            foundations[i].cards.append(f.card)
            if foundations[i].isComplete {
                retirePile(res.pileID)
            }
        }
        delegate?.claimLanded(f, on: res.pileID)
    }

    /// Same choreography as the solo table: flip, pause, shrink, gone.
    private func retirePile(_ pileID: Int) {
        Task {
            try? await Task.sleep(for: .seconds(0.9))
            guard self.roundActive,
                  let i = self.foundations.firstIndex(where: { $0.id == pileID }),
                  self.foundations[i].isComplete else { return }
            self.foundations[i].faceDown = true
            Sound.play(.place)
            try? await Task.sleep(for: .seconds(1.5))
            guard self.roundActive,
                  let j = self.foundations.firstIndex(where: { $0.id == pileID }) else { return }
            self.foundations[j].vanishing = true
            try? await Task.sleep(for: .milliseconds(400))
            guard self.roundActive,
                  let k = self.foundations.firstIndex(where: { $0.id == pileID }) else { return }
            self.foundations.remove(at: k)
        }
    }

    private func handleRoundStart(matchID id: UUID, round: Int) {
        if matchID != id {
            matchID = id
            scores = Array(repeating: 0, count: map.total)
        }
        roundNumber = round
        delegate?.roundStarted(round: round)
    }

    private func handleRoundEnd(_ globalSummary: RoundSummary) {
        // Whatever is still airborne settles instantly, in host order.
        for f in flying where !f.bouncing {
            if let res = outcomes.removeValue(forKey: f.id) {
                if res.landed {
                    commitToReplica(f, res)
                } else if f.fromSeat == 0 {
                    delegate?.claimBounced(f)
                }
            } else if f.fromSeat == 0 {
                delegate?.claimBounced(f)
            }
        }
        flying = []
        outcomes = [:]
        roundActive = false
        awaitingRoundEnd = false
        let local = map.summaryToLocal(globalSummary)
        scores = local.totals
        summary = local
        StatsStore.shared.record(
            local, settings: matchSettings, match: matchID ?? UUID(),
            mode: .multiplayer, seats: seatRecords
        )
        delegate?.roundEnded(local)
    }
}
