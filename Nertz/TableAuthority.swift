import SwiftUI
import Observation

// MARK: - The authority seam (multiplayer Phase 0)

/// Events flowing back from the shared table to whoever runs the local
/// board sim and presentation — the "host → all" message stream from
/// MULTIPLAYER.md. In solo play these are direct synchronous calls, so
/// the game feels exactly as it did when the engine did everything.
@MainActor
protocol TableAuthorityDelegate: AnyObject {
    /// A thrown card won its race and landed on `pileID`.
    func claimLanded(_ claim: FlyingCard, on pileID: Int)
    /// A thrown card lost its race; give it back to its owner if that
    /// seat's board is simulated on this device.
    func claimBounced(_ claim: FlyingCard)
    /// Queried while a round is being settled, after in-flight claims
    /// land or bounce — players self-report their leftover nerts cards.
    func nertsLeftCounts() -> [Int]
    /// The round is decided: settle up and show the scoreboard.
    func roundEnded(_ summary: RoundSummary)
    /// The whole table has been stuck too long — everyone shuffles.
    func tableShuffleCalled()
    /// A new round is starting table-wide (networked guests get this
    /// when the host deals; solo never does — the engine deals itself).
    func roundStarted(round: Int)
    /// A remote player called nerts — end the round with them as
    /// caller. `tapAt` is when their pile emptied, in the host's clock.
    func remoteNertsCall(seat: Int, at tapAt: TimeInterval)
    /// A departed player's seat is bot-driven from the next round.
    func seatBecameBot(seat: Int)
    /// The online table died (host left, connection lost) — bail out.
    func tableClosed(reason: String)
    /// The table froze or thawed. `seat` is who is holding the pause
    /// (local seats, 0 = you), or nil when play resumes. Online this is
    /// the host's declaration, so every device freezes on one word.
    func tablePauseChanged(by seat: Int?)
}

/// The one owner of everything *contested* in Nertz: the foundations in
/// the middle, the claims racing for them, round settlement, and the
/// scores. Each player's own board (nerts, work, stock, waste) never
/// crosses this line. Solo play runs `LocalTableAuthority`; a networked
/// table (host arbitration or a guest's replica) swaps in behind this
/// protocol without touching the board sim, input, or presentation.
@MainActor
protocol TableAuthority: AnyObject {
    var delegate: TableAuthorityDelegate? { get set }

    /// Now, in the table's clock — the one every seat's taps are
    /// measured against. Solo and the host answer with their own clock
    /// (they *are* the reference); a guest answers with its measured
    /// offset from the host. Anything that stamps a moment goes through
    /// here, so no caller has to know which device it's running on.
    var tableNow: TimeInterval { get }

    // Shared table state — read-only outside the authority.
    var foundations: [FoundationPile] { get }
    var flying: [FlyingCard] { get }
    var scores: [Int] { get }
    var roundNumber: Int { get }
    var summary: RoundSummary? { get }
    var maxFoundations: Int { get }

    // Match / round lifecycle.
    func beginMatch(settings: GameSettings)
    func advanceRound()
    func beginRound()
    /// Settles the round: lands or bounces whatever is still in the
    /// air, tallies, updates scores, records the result, and announces
    /// it via `roundEnded`. `caller` -1 = settled without a call (a
    /// player left); `note` explains it on the scoreboard.
    ///
    /// `calledAt` is when the caller's pile actually emptied, in the
    /// host's clock — NERTS is a race too, and at a networked table the
    /// host holds the settlement briefly and gives it to the earliest
    /// call rather than the first one off the wire. nil means "not a
    /// race, settle now" (a departure). Solo ignores it entirely.
    func endRound(caller: Int, calledAt: TimeInterval?, recordStats: Bool, note: String?)
    /// The round stops mattering (quit to menu) — no settlement.
    func abandonRound()
    /// A seat's human is gone; from the next round the host's engine
    /// plays it. (Solo/guest: nothing to do here — guests learn via
    /// the seatConverted message.)
    func convertSeatToBot(seat: Int)

    // Foundation plays — the only ways a card reaches the middle.
    /// Your own play. Solo commits it instantly; a networked table (host
    /// or guest alike) turns it into a claim from seat 0, because at a
    /// real table your card has to win its race like anyone else's.
    /// False = the spot is visibly illegal right now.
    func playNow(_ card: Card, from source: MoveSource, at index: Int?, spot: CGPoint?) -> Bool
    /// An in-flight claim: the card is in the air now, but the pile
    /// only mutates when it lands, and among cards racing for one pile
    /// the EARLIEST TAP wins — losers bounce home via `claimBounced`.
    /// `tapAt` is when the player actually let go, in the host's clock;
    /// `flight` is measured from that moment, not from arrival, so a
    /// slow wire costs a player nothing. `spot` is where a new pile was
    /// aimed (nil = pick an open spot). False = illegal at throw time.
    func submitClaim(_ card: Card, fromSeat: Int, source: MoveSource, pileIndex: Int?, spot: CGPoint?, tapAt: TimeInterval, flight: TimeInterval) -> Bool
    /// One-level rollback of an instant commit, if the table hasn't
    /// moved on. Solo undo today; always false at a networked table.
    func undoFoundationPlay(pileID: Int, cardID: String, wasNewPile: Bool) -> Bool

    /// Would this card land on this pile right now? At a networked
    /// table your own still-flying tosses count as already down, so a
    /// run (4♥ then 5♥) chains without waiting for the wire — if the
    /// chain's base bounces, the host bounces the rest.
    func pileAccepts(_ card: Card, pileIndex: Int) -> Bool

    /// Ask the table to freeze (or thaw). Solo answers itself; online
    /// this asks the host, who declares it to everyone via
    /// `tablePauseChanged` — nobody freezes unilaterally.
    func requestPause(_ on: Bool, by seat: Int)

    // Private-board reporting — badges for boards nobody else can see.
    /// The engine reports simulated seats' nerts counts when they
    /// change; a networked table broadcasts them.
    func reportNerts(seat: Int, count: Int)
    /// Last reported count for a seat this device doesn't simulate,
    /// or nil to read the local board (solo: always nil).
    func reportedNertsCount(seat: Int) -> Int?

    // Pacing — driven from the engine's tick and pause handling, so
    // every table deadline freezes and shifts exactly like the rest
    // of the game.
    func settleDueClaims(now: Date)
    func checkStuck(now: Date)
    func noteActivity()
    func shiftDeadlines(by delta: TimeInterval)
}

// MARK: - Solo: the local table

/// The solo table: arbitration in-process, no latency, no peers. All
/// the rules live here so that swapping the authority never means
/// re-implementing Nertz.
@MainActor
@Observable
final class LocalTableAuthority: TableAuthority {

    @ObservationIgnored weak var delegate: TableAuthorityDelegate?

    private(set) var foundations: [FoundationPile] = []
    private(set) var flying: [FlyingCard] = []
    private(set) var scores: [Int] = []
    private(set) var roundNumber = 1
    private(set) var summary: RoundSummary?

    // Internals — never read by views.
    @ObservationIgnored private var settings = GameSettings()
    @ObservationIgnored private var playerCount = 1
    /// Cards from completed piles cleared off the table — still worth points.
    @ObservationIgnored private var retired: [Card] = []
    @ObservationIgnored private var nextPileID = 0
    @ObservationIgnored private var roundActive = false
    @ObservationIgnored private var lastFoundationPlay = Date()
    @ObservationIgnored private var rng = SystemRandomNumberGenerator()
    /// Identity of the current match; minted in beginMatch and sent to
    /// the record book with every round, so match boundaries travel
    /// in-band with results instead of via separate lifecycle calls.
    @ObservationIgnored private var matchToken = UUID()

    var maxFoundations: Int { 4 * playerCount }

    // MARK: Lifecycle

    func beginMatch(settings: GameSettings) {
        self.settings = settings
        playerCount = settings.opponents + 1
        matchToken = UUID()
        scores = Array(repeating: 0, count: playerCount)
        roundNumber = 1
    }

    func advanceRound() {
        roundNumber += 1
    }

    func beginRound() {
        foundations = []
        flying = []
        retired = []
        summary = nil
        nextPileID = 0
        lastFoundationPlay = Date()
        roundActive = true
    }

    func abandonRound() {
        roundActive = false
    }

    func convertSeatToBot(seat: Int) {}     // solo seats never leave

    /// `calledAt` is unused here: a solo table has no wire to correct
    /// for, so the call settles the instant it's made — including the
    /// tick's deliberate head start for you over the bots.
    func endRound(caller: Int, calledAt: TimeInterval?, recordStats: Bool, note: String?) {
        guard roundActive else { return }
        roundActive = false
        // Cards still in the air when NERTS is called land if they legally
        // can; the rest go back to their owner's board (and count against it).
        // Oldest tap first here too, so the last scramble settles by the
        // same rule as every other moment of the round.
        for claim in flying.filter({ !$0.bouncing }).sorted(by: { $0.tapAt < $1.tapAt }) {
            if !commitClaim(claim) {
                delegate?.claimBounced(claim)
            }
        }
        var counts = Array(repeating: 0, count: playerCount)
        for pile in foundations {
            for card in pile.cards { counts[card.owner] += 1 }
        }
        for card in retired { counts[card.owner] += 1 }
        let left = delegate?.nertsLeftCounts() ?? Array(repeating: 0, count: playerCount)
        let deltas = (0..<playerCount).map { counts[$0] - 2 * left[$0] }
        var totals = scores
        for i in totals.indices { totals[i] += deltas[i] }
        scores = totals
        var winner: Int?
        if let best = totals.max(), best >= settings.targetScore {
            winner = totals.firstIndex(of: best)
        }
        flying = []
        let result = RoundSummary(
            caller: caller,
            foundationCounts: counts,
            nertsLeft: left,
            deltas: deltas,
            totals: totals,
            winner: winner,
            note: note
        )
        summary = result
        if recordStats {
            StatsStore.shared.record(result, settings: settings, match: matchToken)
        }
        delegate?.roundEnded(result)
    }

    // MARK: Saving & resuming (solo only)

    /// Everything the table needs to come back after the app dies.
    /// Piles mid-retirement (completed, flipping, vanishing) fold into
    /// `retired` — their animation tasks won't survive a relaunch, and
    /// their cards still count.
    func snapshot() -> TableSnapshot {
        var keep: [FoundationPile] = []
        var gone = retired
        for pile in foundations {
            if pile.isComplete || pile.faceDown || pile.vanishing {
                gone.append(contentsOf: pile.cards)
            } else {
                keep.append(pile)
            }
        }
        return TableSnapshot(
            scores: scores, roundNumber: roundNumber, foundations: keep,
            retired: gone, nextPileID: nextPileID, matchToken: matchToken,
            summary: summary
        )
    }

    /// Rebuild the table from a saved match. `live` = the round was in
    /// progress (false when the save was made at the scoreboard).
    func restore(_ s: TableSnapshot, settings: GameSettings, live: Bool) {
        self.settings = settings
        playerCount = settings.opponents + 1
        matchToken = s.matchToken
        scores = s.scores
        roundNumber = s.roundNumber
        foundations = s.foundations
        retired = s.retired
        nextPileID = s.nextPileID
        summary = s.summary
        flying = []
        roundActive = live
        lastFoundationPlay = Date()
    }

    // MARK: Foundation plays

    var tableNow: TimeInterval { Date().timeIntervalSince1970 }

    func playNow(_ card: Card, from source: MoveSource, at index: Int?, spot: CGPoint?) -> Bool {
        guard roundActive else { return false }
        return landOnFoundation(card, at: index, spot: spot) != nil
    }

    func submitClaim(_ card: Card, fromSeat: Int, source: MoveSource, pileIndex: Int?, spot: CGPoint?, tapAt: TimeInterval, flight: TimeInterval) -> Bool {
        guard roundActive else { return false }
        if let pileIndex {
            guard pileAccepts(card, pileIndex: pileIndex, seat: fromSeat) else { return false }
        } else {
            guard card.rank == 1, foundations.count < maxFoundations else { return false }
        }
        // The flight runs from the TAP, not from now — a card that
        // spent 200ms on the wire has already served most of it, so
        // latency buys nobody an advantage and costs nobody one.
        flying.append(FlyingCard(
            card: card, fromSeat: fromSeat, source: source,
            pileID: pileIndex.map { foundations[$0].id },
            spot: pileIndex == nil ? (spot ?? openSpot()) : nil,
            tapAt: tapAt,
            resolveAt: Date(timeIntervalSince1970: tapAt + flight)
        ))
        // `landed` only decides whether a card is drawn at its owner's
        // table edge, and seat 0 has no edge — your own cards slide
        // from your hand. Nothing to animate into, so nothing to set.
        guard fromSeat != 0 else { return true }
        Task {
            try? await Task.sleep(for: .milliseconds(30))
            if let i = self.flying.firstIndex(where: { $0.id == card.id }) {
                self.flying[i].landed = true
            }
        }
        return true
    }

    func pileAccepts(_ card: Card, pileIndex: Int) -> Bool {
        pileAccepts(card, pileIndex: pileIndex, seat: 0)
    }

    /// Pending-aware pile check, from one seat's point of view. Solo has
    /// no seat-0 flights at all, so this reads as the plain `accepts` it
    /// always was; if a chain's base loses its race, `landOnFoundation`
    /// bounces the rest of it.
    private func pileAccepts(_ card: Card, pileIndex: Int, seat: Int) -> Bool {
        guard pileIndex < foundations.count else { return false }
        return foundations[pileIndex].accepts(card, projecting: flying, seat: seat)
    }

    // MARK: Pause (solo answers itself; the networked tables override)

    func requestPause(_ on: Bool, by seat: Int) {
        delegate?.tablePauseChanged(by: on ? seat : nil)
    }

    func undoFoundationPlay(pileID: Int, cardID: String, wasNewPile: Bool) -> Bool {
        guard let index = foundations.firstIndex(where: { $0.id == pileID }),
              !foundations[index].faceDown,
              foundations[index].cards.last?.id == cardID,
              !wasNewPile
                || (index == foundations.count - 1
                    && foundations[index].cards.count == 1)
        else { return false }
        if wasNewPile {
            foundations.remove(at: index)
        } else {
            foundations[index].cards.removeLast()
        }
        return true
    }

    // MARK: Private-board reporting (solo: nothing to report to)

    func reportNerts(seat: Int, count: Int) {}
    func reportedNertsCount(seat: Int) -> Int? { nil }

    // MARK: Pacing

    /// Settle any claims whose flight time is up — earliest tap first,
    /// and never ahead of an earlier tap still racing for the same
    /// spot. That second rule is what makes a slow connection safe: a
    /// card thrown first but delivered late still gets the pile, and
    /// the fast player's card waits its turn and then bounces.
    /// (One loop rather than one pass: landing a card can free the
    /// next one in a chain to settle in the same tick.)
    func settleDueClaims(now: Date) {
        // The overwhelmingly common case is an empty sky; don't build
        // a single array to discover that.
        guard flying.contains(where: { !$0.bouncing && now >= $0.resolveAt }) else { return }
        while let next = nextToSettle(now: now) {
            resolveClaim(cardID: next)
        }
    }

    /// The oldest tap that is both due and unblocked, or nil when the
    /// table has to keep waiting. Blocked means an earlier tap is still
    /// racing for the same pile — that card may be a slower player's,
    /// and first tap wins. Terminates: every claim has a finite
    /// `resolveAt`, so a blocker always becomes due itself. (Two claims
    /// contend only over an existing pile; fresh aces each get their
    /// own patch of felt, so they never race.)
    private func nextToSettle(now: Date) -> String? {
        var best: FlyingCard?
        for claim in flying where !claim.bouncing && now >= claim.resolveAt {
            guard claim.tapAt < (best?.tapAt ?? .infinity) else { continue }
            let blocked = flying.contains {
                !$0.bouncing && now < $0.resolveAt
                    && $0.tapAt < claim.tapAt
                    && $0.pileID != nil && $0.pileID == claim.pileID
            }
            if !blocked { best = claim }
        }
        return best?.id
    }

    /// Whole table stuck for a long while — everyone shuffles (house rule).
    func checkStuck(now: Date) {
        guard roundActive else { return }
        if now.timeIntervalSince(lastFoundationPlay) > 40 {
            delegate?.tableShuffleCalled()
        }
    }

    func noteActivity() {
        lastFoundationPlay = Date()
    }

    func shiftDeadlines(by delta: TimeInterval) {
        for i in flying.indices {
            flying[i].resolveAt = flying[i].resolveAt.addingTimeInterval(delta)
        }
        lastFoundationPlay = lastFoundationPlay.addingTimeInterval(delta)
    }

    // MARK: The race, decided

    private func resolveClaim(cardID: String) {
        guard let idx = flying.firstIndex(where: { $0.id == cardID }) else { return }
        let claim = flying[idx]
        if commitClaim(claim) {
            flying.remove(at: idx)
        } else if claim.fromSeat == 0 {
            // Your own card lost — straight home. It has to leave the
            // sky in the same breath, because `claimBounced` puts it
            // back on your board and yours is the one board on screen:
            // a lingering ghost would draw the same card twice.
            flying.remove(at: idx)
            delegate?.claimBounced(claim)
        } else {
            // Beaten to the spot — the card flies home and rejoins the board.
            delegate?.claimBounced(claim)
            flying[idx].bouncing = true
            Task {
                try? await Task.sleep(for: .milliseconds(500))
                self.flying.removeAll { $0.id == cardID }
            }
        }
    }

    /// Lands a claim if the spot is still legal. The moment of truth.
    private func commitClaim(_ claim: FlyingCard) -> Bool {
        var index: Int?
        if let pileID = claim.pileID {
            // The pile it was thrown at may have completed and left the table.
            guard let i = foundations.firstIndex(where: { $0.id == pileID }) else { return false }
            index = i
        }
        guard let landedID = landOnFoundation(claim.card, at: index, spot: claim.spot) else { return false }
        delegate?.claimLanded(claim, on: landedID)
        return true
    }

    /// The one place a card lands on a foundation — validates and mutates.
    /// Returns the pile's id, or nil if the spot isn't legal. A nil index
    /// starts a new pile (aces) wherever `spot` says it was tossed — or
    /// somewhere open on the felt when nobody aimed.
    private func landOnFoundation(_ card: Card, at index: Int?, spot: CGPoint? = nil) -> Int? {
        let id: Int
        if let index {
            guard index < foundations.count, foundations[index].accepts(card) else { return nil }
            foundations[index].cards.append(card)
            foundations[index].lastLandAt = Date()
            id = foundations[index].id
            if foundations[index].isComplete {
                // The king caps the pile: flip it over, then clear it away.
                retirePile(id)
            }
        } else {
            guard card.rank == 1, foundations.count < maxFoundations else { return nil }
            id = nextPileID
            nextPileID += 1
            foundations.append(FoundationPile(
                id: id, cards: [card],
                spot: separatedSpot(spot ?? openSpot()),
                tilt: Double.random(in: -9...9, using: &rng)
            ))
        }
        lastFoundationPlay = Date()
        return id
    }

    /// Somewhere on the open felt for a fresh pile — a handful of random
    /// candidates, keeping the one farthest from the piles already down,
    /// so the scatter stays readable without ever looking arranged.
    private func openSpot() -> CGPoint {
        let taken = foundations.filter { !$0.vanishing }.map(\.spot)
        var best = CGPoint(x: 0.5, y: 0.4)
        var bestClearance = -1.0
        for _ in 0..<12 {
            let c = CGPoint(
                x: Double.random(in: 0.04...0.96, using: &rng),
                y: Double.random(in: 0.04...0.96, using: &rng)
            )
            guard !taken.isEmpty else { return c }
            let clearance = taken.map { Double($0.distance(to: c)) }.min() ?? .infinity
            if clearance > bestClearance {
                bestClearance = clearance
                best = c
            }
        }
        return best
    }

    /// Two piles tossed near the same spot bury each other. If the desired
    /// spot would overlap a pile already on the felt, walk outward in rings
    /// and take the nearest clear patch, so every pile stays readable.
    /// Deterministic on purpose: the host broadcasts the resolved spot.
    private func separatedSpot(_ requested: CGPoint) -> CGPoint {
        let taken = foundations.filter { !$0.vanishing }.map(\.spot)
        // A card covers roughly this much of the scatter zone on the
        // smallest screens; closer than this in both axes = overlap.
        let minDX = 0.21
        let minDY = 0.18
        func isClear(_ p: CGPoint) -> Bool {
            taken.allSatisfy { abs($0.x - p.x) >= minDX || abs($0.y - p.y) >= minDY }
        }
        func clamped(_ p: CGPoint) -> CGPoint {
            CGPoint(x: min(max(p.x, 0.03), 0.97), y: min(max(p.y, 0.03), 0.97))
        }
        let want = clamped(requested)
        if isClear(want) { return want }
        for ring in 1...9 {
            let r = Double(ring) * 0.11
            for k in 0..<16 {
                let a = (Double(k) + Double(ring) * 0.5) / 16 * 2 * .pi
                let c = clamped(CGPoint(x: want.x + cos(a) * r, y: want.y + sin(a) * r * 0.82))
                if isClear(c) { return c }
            }
        }
        return want
    }

    /// A completed pile: flip the king face down, pause, shrink it away,
    /// then remove it so the table stays uncluttered.
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
            self.retired.append(contentsOf: self.foundations[k].cards)
            self.foundations.remove(at: k)
        }
    }
}
