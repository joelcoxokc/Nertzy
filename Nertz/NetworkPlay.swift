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

    /// Sentinels (like caller -1 = "nobody") pass through unchanged.
    func local(_ g: Int) -> Int {
        (0..<total).contains(g) ? globalToLocal[g] : g
    }

    func global(_ l: Int) -> Int {
        (0..<total).contains(l) ? localToGlobal[l] : l
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
            winner: s.winner.map(global),
            note: s.note
        )
    }

    func summaryToLocal(_ s: RoundSummary) -> RoundSummary {
        RoundSummary(
            caller: local(s.caller),
            foundationCounts: toLocal(s.foundationCounts),
            nertsLeft: toLocal(s.nertsLeft),
            deltas: toLocal(s.deltas),
            totals: toLocal(s.totals),
            winner: s.winner.map(local),
            note: s.note
        )
    }
}

// MARK: - The host's table

/// The device that arbitrates: a full LocalTableAuthority runs the
/// rules exactly like solo (bots included), and this wrapper sits on
/// its delegate line — every landing, bounce, shuffle, and settlement
/// is forwarded to the local engine AND broadcast to the guests.
///
/// Every human play enters the same claim pipeline the bots use, the
/// host's own included: the host has no wire to wait on, so committing
/// instantly would hand it every contested pile. Instead each claim is
/// held briefly and the pile goes to the EARLIEST TAP — the host pays
/// the same small settling beat as everyone else, which is the price
/// of the table being fair.
@MainActor
@Observable
final class HostTableAuthority: TableAuthority, TableAuthorityDelegate {

    @ObservationIgnored weak var delegate: TableAuthorityDelegate?

    private let inner = LocalTableAuthority()
    @ObservationIgnored private let map: SeatMap
    @ObservationIgnored private let seatRecords: [SeatRecord]
    @ObservationIgnored private let matchSettings: GameSettings
    @ObservationIgnored private let hold: () -> TimeInterval
    @ObservationIgnored private let sendMessage: (NetMessage) -> Void
    @ObservationIgnored private var matchID = UUID()
    @ObservationIgnored private var recordRounds = true
    /// Who is holding the table frozen (local seats), or nil.
    @ObservationIgnored private var pausedBy: Int?
    /// Is there a live round to freeze? A guest's pause can arrive just
    /// after the round settled here — accepting it then would start
    /// queueing messages against a table that isn't running.
    @ObservationIgnored private var roundLive = false
    /// The best NERTS call heard so far, while the window is open.
    @ObservationIgnored private var pendingCall: (seat: Int, tapAt: TimeInterval, note: String?)?
    /// Gameplay that arrived while the table was frozen. A player who
    /// hadn't heard about the pause yet still threw cards, and those
    /// cards are sitting in the air on their screen — holding the
    /// messages resolves them honestly on resume instead of stranding
    /// them. Bounded so a pause nobody lifts can't grow without limit.
    @ObservationIgnored private var held: [NetMessage] = []
    @ObservationIgnored private var autoResume: Task<Void, Never>?
    /// Last self-reported nerts counts for seats living on other
    /// devices (local-indexed) — badge data and the round-end tally.
    private(set) var remoteNerts: [Int?]
    /// Seats whose humans left; the host's engine plays them now, so
    /// stale wire reports for them are ignored.
    @ObservationIgnored private var convertedSeats: Set<Int> = []

    init(
        map: SeatMap,
        seatRecords: [SeatRecord],
        settings: GameSettings,
        hold: @escaping () -> TimeInterval,
        send: @escaping (NetMessage) -> Void
    ) {
        self.map = map
        self.seatRecords = seatRecords
        self.matchSettings = settings
        self.hold = hold
        self.sendMessage = send
        self.remoteNerts = Array(repeating: nil, count: map.total)
        inner.delegate = self
    }

    // MARK: Forwarded table state

    /// This device arbitrates, so its clock IS the table's clock —
    /// every guest measures its offset against exactly this.
    var tableNow: TimeInterval { inner.tableNow }

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
        setPause(by: nil, replayHeld: false)
        pendingCall = nil
        roundLive = true
        inner.beginRound()
        sendMessage(.roundStart(matchID: matchID, round: inner.roundNumber))
    }

    /// NERTS is the last race of the round, and it was the one place
    /// arrival order still decided things — the host's own call landed
    /// instantly while a guest's cost a one-way trip. So a call opens
    /// the same brief window a contested pile gets: every call that
    /// arrives inside it competes, and the EARLIEST emptied pile takes
    /// it. The window is measured from the first call's own stamp, which
    /// is always at least as long as the wait correctness needs.
    func endRound(caller: Int, calledAt: TimeInterval?, recordStats: Bool, note: String?) {
        recordRounds = recordStats
        // A round can end while frozen — a player dropping off settles
        // it from outside the tick. Thaw first so nothing is left held
        // against a round that no longer exists.
        roundLive = false
        setPause(by: nil, replayHeld: false)

        guard let calledAt, caller >= 0 else {
            // Not a race — a player left, or the table settled itself.
            // A call already in hand outranks a departure: somebody
            // genuinely went out, and that's the truer story.
            if pendingCall != nil { settlePendingCall(); return }
            settle(caller: caller, note: note)
            return
        }

        if let existing = pendingCall {
            // Somebody beat them to it — unless they emptied first.
            if calledAt < existing.tapAt {
                pendingCall = (seat: caller, tapAt: calledAt, note: note)
            }
            return          // a settlement is already on the clock
        }
        pendingCall = (seat: caller, tapAt: calledAt, note: note)
        let deadline = calledAt + hold()
        Task { [weak self] in
            let wait = deadline - Date().timeIntervalSince1970
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            self?.settlePendingCall()
        }
    }

    private func settlePendingCall() {
        guard let call = pendingCall else { return }
        pendingCall = nil
        settle(caller: call.seat, note: call.note)
    }

    /// The inner table must not write the record book — this wrapper
    /// records with the multiplayer seat list instead.
    private func settle(caller: Int, note: String?) {
        inner.endRound(caller: caller, calledAt: nil, recordStats: false, note: note)
    }

    func abandonRound() {
        roundLive = false
        pendingCall = nil
        setPause(by: nil, replayHeld: false)
        inner.abandonRound()
    }

    func convertSeatToBot(seat: Int) {
        guard !convertedSeats.contains(seat) else { return }
        convertedSeats.insert(seat)
        remoteNerts[seat] = nil     // the local board is the truth now
        sendMessage(.seatConverted(seat: map.global(seat)))
    }

    // MARK: Plays

    /// The host's own play is a claim like anyone else's — held for the
    /// arbitration window so a guest who tapped a hair earlier can still
    /// take the pile. The card leaves the hand immediately either way;
    /// only the rare bounce betrays that the host waited its turn.
    func playNow(_ card: Card, from source: MoveSource, at index: Int?, spot: CGPoint?) -> Bool {
        inner.submitClaim(
            card, fromSeat: 0, source: source, pileIndex: index, spot: spot,
            tapAt: tableNow, flight: hold()
        )
    }

    func submitClaim(_ card: Card, fromSeat: Int, source: MoveSource, pileIndex: Int?, spot: CGPoint?, tapAt: TimeInterval, flight: TimeInterval) -> Bool {
        inner.submitClaim(card, fromSeat: fromSeat, source: source, pileIndex: pileIndex, spot: spot, tapAt: tapAt, flight: flight)
    }

    func undoFoundationPlay(pileID: Int, cardID: String, wasNewPile: Bool) -> Bool {
        false   // no undo message in the protocol; the table moved on
    }

    func pileAccepts(_ card: Card, pileIndex: Int) -> Bool {
        inner.pileAccepts(card, pileIndex: pileIndex)
    }

    // MARK: Pause — anyone may ask, this device decides

    /// The one enforcement point for who may freeze and thaw the table.
    /// `GameEngine.canResume` mirrors this rule for the UI, but a guest
    /// asking for something it isn't owed is refused here.
    func requestPause(_ on: Bool, by seat: Int) {
        if on {
            guard roundLive, pausedBy == nil else { return }
            setPause(by: seat)
        } else {
            // Whoever called the pause lifts it. The host can always
            // override, so a phone that died mid-pause can't strand
            // everyone else at a frozen table.
            guard let holder = pausedBy, seat == holder || seat == 0 else { return }
            setPause(by: nil)
        }
    }

    /// `replayHeld` is false at a round boundary or a dissolved table:
    /// there's nothing left for the queued messages to act on.
    private func setPause(by seat: Int?, replayHeld: Bool = true) {
        autoResume?.cancel()
        autoResume = nil
        let queued = replayHeld ? held : []
        held = []
        guard seat != pausedBy else { return }
        pausedBy = seat
        sendMessage(.pauseState(by: seat.map { map.global($0) }))
        delegate?.tablePauseChanged(by: seat)
        if seat != nil {
            // Nobody's night ends because someone walked away mid-pause.
            autoResume = Task { [weak self] in
                try? await Task.sleep(for: .seconds(120))
                guard !Task.isCancelled else { return }
                self?.requestPause(false, by: 0)
            }
        } else {
            // Play is live again before these land, so they enter the
            // pipeline exactly as they would have.
            for message in queued { handle(message) }
        }
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
        // Pause traffic is never held — it's how a table gets unstuck.
        if case .pauseRequest(let globalSeat, let on) = message {
            requestPause(on, by: map.local(globalSeat))
            return
        }
        guard pausedBy == nil else {
            if held.count < 256 { held.append(message) }
            return
        }
        handle(message)
    }

    private func handle(_ message: NetMessage) {
        switch message {
        case .playerClaim(let claim):
            let card = map.localCard(claim.card)
            let fromSeat = map.local(claim.card.seat)
            let index = claim.pileID.flatMap { pid in
                inner.foundations.firstIndex(where: { $0.id == pid })
            }
            // A targeted pile that's already gone can never land.
            let doomed = claim.pileID != nil && index == nil
            // The tap already happened; the wire time it spent getting
            // here counts against its hold, not against the player.
            // (A claim with no stamp — an older build — is treated as
            // tapped on arrival, the way it used to be.)
            let tapAt = claim.tapAt ?? tableNow
            let accepted = !doomed && inner.submitClaim(
                card, fromSeat: fromSeat, source: claim.source,
                pileIndex: index, spot: claim.spot, tapAt: tapAt, flight: hold()
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
        case .nertsCalled(let globalSeat, let tapAt):
            delegate?.remoteNertsCall(
                seat: map.local(globalSeat),
                at: tapAt ?? tableNow
            )
        case .nertsCount(let globalSeat, let count):
            let local = map.local(globalSeat)
            if local != 0, local < remoteNerts.count, !convertedSeats.contains(local) {
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

    // Inner tables never emit these; conformance completeness.
    // (Pause never reaches the inner table — this wrapper is the one
    // that decides, so it answers requests itself.)
    func roundStarted(round: Int) {}
    func remoteNertsCall(seat: Int, at tapAt: TimeInterval) {}
    func seatBecameBot(seat: Int) {}
    func tableClosed(reason: String) {}
    func tablePauseChanged(by seat: Int?) {}

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

    /// My best reading of the host's clock — the only place this device
    /// converts its own time into the table's.
    var tableNow: TimeInterval { clock.now() }

    /// Reported badge counts for every seat that isn't mine (bots and
    /// humans alike — they all live on other devices).
    private(set) var remoteNerts: [Int?]

    @ObservationIgnored private let map: SeatMap
    @ObservationIgnored private let seatRecords: [SeatRecord]
    @ObservationIgnored private let matchSettings: GameSettings
    /// The host's clock, as best this device can read it — every play
    /// is stamped with it so the host can rank taps, not arrivals.
    @ObservationIgnored private let clock: TableClock
    @ObservationIgnored private let sendMessage: (NetMessage) -> Void
    @ObservationIgnored private var matchID: UUID?
    @ObservationIgnored private var outcomes: [String: WireResolution] = [:]
    /// Card ids in host-broadcast order. Replica mutations MUST apply
    /// in this order — a flight can't land before an earlier one, even
    /// if its own timer is up (two cards racing for one pile 0.3s
    /// apart would otherwise stack backwards).
    @ObservationIgnored private var resolutionOrder: [String] = []
    @ObservationIgnored private var roundActive = false
    @ObservationIgnored private var awaitingRoundEnd = false

    init(
        map: SeatMap,
        seatRecords: [SeatRecord],
        settings: GameSettings,
        clock: TableClock,
        send: @escaping (NetMessage) -> Void
    ) {
        self.map = map
        self.seatRecords = seatRecords
        self.matchSettings = settings
        self.clock = clock
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
        resolutionOrder = []
        summary = nil
        remoteNerts = Array(repeating: nil, count: map.total)
        roundActive = true
        awaitingRoundEnd = false
    }

    /// My nerts call — the host settles and answers with roundEnd.
    /// `calledAt` already arrived in the host's clock (the engine stamps
    /// through `tableNow`), so it races on the moment my pile emptied
    /// rather than on when the message lands.
    func endRound(caller: Int, calledAt: TimeInterval?, recordStats: Bool, note: String?) {
        guard roundActive, !awaitingRoundEnd else { return }
        awaitingRoundEnd = true
        sendMessage(.nertsCalled(
            seat: map.global(caller),
            tapAt: clock.synced ? calledAt : nil
        ))
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard let self, self.awaitingRoundEnd, self.roundActive else { return }
            self.delegate?.tableClosed(reason: "The table went quiet")
        }
    }

    func abandonRound() { roundActive = false }

    func convertSeatToBot(seat: Int) {}     // guests learn via seatConverted

    // MARK: Plays

    func playNow(_ card: Card, from source: MoveSource, at index: Int?, spot: CGPoint?) -> Bool {
        guard roundActive else { return false }
        let pileID: Int?
        if let index {
            guard pileAccepts(card, pileIndex: index) else { return false }
            pileID = foundations[index].id
        } else {
            guard card.rank == 1, foundations.count < maxFoundations else { return false }
            pileID = nil
        }
        // Stamp the moment of the tap in the host's clock, before any
        // of the wire's time is spent — that stamp is what wins races.
        let tapAt = tableNow
        // Born landed: the card slides straight from your hand toward
        // the pile while the claim races to the host.
        flying.append(FlyingCard(
            card: card, fromSeat: 0, source: source,
            pileID: pileID,
            spot: pileID == nil ? (spot ?? CGPoint(x: 0.5, y: 0.4)) : nil,
            tapAt: tapAt,
            resolveAt: Date().addingTimeInterval(0.35)
        ))
        sendMessage(.playerClaim(WireClaim(
            card: map.wireCard(card), source: source,
            pileID: pileID, spot: spot,
            tapAt: clock.synced ? tapAt : nil
        )))
        return true
    }

    func submitClaim(_ card: Card, fromSeat: Int, source: MoveSource, pileIndex: Int?, spot: CGPoint?, tapAt: TimeInterval, flight: TimeInterval) -> Bool {
        false   // guests simulate no bot seats
    }

    func undoFoundationPlay(pileID: Int, cardID: String, wasNewPile: Bool) -> Bool {
        false
    }

    /// The replica's pile, plus my own tosses still in the air — a run
    /// chains onto them immediately; the host bounces the chain if the
    /// base loses its race. Tosses the host has already refused are
    /// left out: their cards are on the way home.
    func pileAccepts(_ card: Card, pileIndex: Int) -> Bool {
        guard pileIndex < foundations.count else { return false }
        return foundations[pileIndex].accepts(
            card, projecting: flying, seat: 0,
            skipping: { self.outcomes[$0.id].map { !$0.landed } ?? false }
        )
    }

    // MARK: Pause — ask the host, act on the answer

    func requestPause(_ on: Bool, by seat: Int) {
        sendMessage(.pauseRequest(seat: map.global(seat), on: on))
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
        drainResolved(now: now)
        // My own unanswered tosses: give a slow connection real room,
        // then take the card back rather than hang forever.
        for f in flying where f.fromSeat == 0 && !f.bouncing
            && outcomes[f.id] == nil
            && now.timeIntervalSince(f.resolveAt) > 5 {
            flying.removeAll { $0.id == f.id }
            delegate?.claimBounced(f)
        }
    }

    /// Apply resolved flights strictly in host order. The head of the
    /// line waits out its flight time; nothing may overtake it.
    private func drainResolved(now: Date = Date()) {
        while let id = resolutionOrder.first {
            guard let res = outcomes[id] else {
                resolutionOrder.removeFirst()
                continue
            }
            guard let f = flying.first(where: { $0.id == id }) else {
                // Flight already cleared (round settled underneath it).
                outcomes.removeValue(forKey: id)
                resolutionOrder.removeFirst()
                continue
            }
            guard now >= f.resolveAt else { break }
            outcomes.removeValue(forKey: id)
            resolutionOrder.removeFirst()
            settle(f, with: res)
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
        case .seatConverted(let globalSeat):
            delegate?.seatBecameBot(seat: map.local(globalSeat))
        case .pauseState(let globalSeat):
            delegate?.tablePauseChanged(by: globalSeat.map { map.local($0) })
        default:
            break
        }
    }

    private func handleResolution(_ res: WireResolution) {
        let fromLocal = map.local(res.fromSeat)
        let card = map.localCard(res.card)
        if fromLocal == 0 {
            // The answer to my own toss — settle right now (through the
            // ordered drain, so nothing lands out of host order).
            guard let idx = flying.firstIndex(where: { $0.id == card.id }) else { return }
            outcomes[card.id] = res
            resolutionOrder.append(card.id)
            flying[idx].resolveAt = Date()
            drainResolved()
        } else {
            // Someone else's play: give it a short flight, outcome known.
            outcomes[card.id] = res
            resolutionOrder.append(card.id)
            // The replica settles strictly in host-broadcast order, so
            // this stamp is only ever cosmetic bookkeeping.
            flying.append(FlyingCard(
                card: card, fromSeat: fromLocal, source: res.source,
                pileID: res.newPile ? nil : res.pileID,
                spot: res.newPile ? res.spot : nil,
                tapAt: tableNow,
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
            foundations[i].lastLandAt = Date()
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
        for id in resolutionOrder {
            guard let res = outcomes.removeValue(forKey: id),
                  let f = flying.first(where: { $0.id == id }), !f.bouncing else { continue }
            if res.landed {
                flying.removeAll { $0.id == id }
                commitToReplica(f, res)
            } else if f.fromSeat == 0 {
                flying.removeAll { $0.id == id }
                delegate?.claimBounced(f)
            }
        }
        // My tosses the host never answered come home and count.
        for f in flying where f.fromSeat == 0 && !f.bouncing {
            delegate?.claimBounced(f)
        }
        flying = []
        outcomes = [:]
        resolutionOrder = []
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
