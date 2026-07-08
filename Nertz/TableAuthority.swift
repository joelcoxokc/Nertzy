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
    /// A remote player called nerts — end the round with them as caller.
    func remoteNertsCall(seat: Int)
    /// The online table died (host left, connection lost) — bail out.
    func tableClosed(reason: String)
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
    /// it via `roundEnded`.
    func endRound(caller: Int, recordStats: Bool)
    /// The round stops mattering (quit to menu) — no settlement.
    func abandonRound()

    // Foundation plays — the only ways a card reaches the middle.
    /// Your own play. Solo/host: commits instantly. Networked guest:
    /// becomes a short claim tossed at the host (the return value is
    /// provisional). Returns the pile's id, or nil if the spot is
    /// visibly illegal right now.
    func playNow(_ card: Card, from source: MoveSource, at index: Int?, spot: CGPoint?) -> Int?
    /// An in-flight claim: the card is in the air now, but the pile
    /// only mutates when it lands — first card DOWN wins, and losers
    /// bounce home via `claimBounced`. `spot` is where a new pile was
    /// aimed (nil = pick an open spot). False = illegal at throw time.
    func submitClaim(_ card: Card, fromSeat: Int, source: MoveSource, pileIndex: Int?, spot: CGPoint?, flight: TimeInterval) -> Bool
    /// One-level rollback of an instant commit, if the table hasn't
    /// moved on. Solo undo today; always false at a networked table.
    func undoFoundationPlay(pileID: Int, cardID: String, wasNewPile: Bool) -> Bool

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

    func endRound(caller: Int, recordStats: Bool) {
        guard roundActive else { return }
        roundActive = false
        // Cards still in the air when NERTS is called land if they legally
        // can; the rest go back to their owner's board (and count against it).
        for claim in flying where !claim.bouncing {
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
        if let best = totals.max(), best >= 100 {
            winner = totals.firstIndex(of: best)
        }
        flying = []
        let result = RoundSummary(
            caller: caller,
            foundationCounts: counts,
            nertsLeft: left,
            deltas: deltas,
            totals: totals,
            winner: winner
        )
        summary = result
        if recordStats {
            StatsStore.shared.record(result, settings: settings, match: matchToken)
        }
        delegate?.roundEnded(result)
    }

    // MARK: Foundation plays

    func playNow(_ card: Card, from source: MoveSource, at index: Int?, spot: CGPoint?) -> Int? {
        guard roundActive else { return nil }
        return landOnFoundation(card, at: index, spot: spot)
    }

    func submitClaim(_ card: Card, fromSeat: Int, source: MoveSource, pileIndex: Int?, spot: CGPoint?, flight: TimeInterval) -> Bool {
        guard roundActive else { return false }
        if let pileIndex {
            guard pileIndex < foundations.count, foundations[pileIndex].accepts(card) else { return false }
        } else {
            guard card.rank == 1, foundations.count < maxFoundations else { return false }
        }
        flying.append(FlyingCard(
            card: card, fromSeat: fromSeat, source: source,
            pileID: pileIndex.map { foundations[$0].id },
            spot: pileIndex == nil ? (spot ?? openSpot()) : nil,
            resolveAt: Date().addingTimeInterval(flight)
        ))
        Task {
            try? await Task.sleep(for: .milliseconds(30))
            if let i = self.flying.firstIndex(where: { $0.id == card.id }) {
                self.flying[i].landed = true
            }
        }
        return true
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

    /// Settle any claims whose flight time is up.
    func settleDueClaims(now: Date) {
        let due = flying.filter { !$0.bouncing && now >= $0.resolveAt }.map(\.id)
        for id in due {
            resolveClaim(cardID: id)
        }
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
                spot: spot ?? openSpot(),
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
