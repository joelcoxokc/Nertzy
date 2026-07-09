import SwiftUI
import Observation

@MainActor
@Observable
final class GameEngine {

    // MARK: - Observable state

    var settings = GameSettings()
    private(set) var phase: Phase = .menu
    private(set) var boards: [PlayerBoard] = []
    private(set) var pulses: [LandingPulse] = []
    private(set) var dealing = false
    private(set) var banner: BannerMessage?
    private(set) var seatPulse: [Int] = []
    var shakeTokens: [String: Int] = [:]
    /// Cards that just flipped off the stock — they appear on the waste in
    /// place, with no travel or flip animation. Cleared on the next pickup.
    var freshWasteIDs: Set<String> = []
    private(set) var paused = false
    /// Debug: deal opponents a 2-card nerts pile so rounds end fast (-quickround).
    var debugTinyNerts = false
    /// Debug: the AI also plays your seat — living screenshots/demos (-demo).
    var debugDemo = false

    // MARK: - The shared table (authority seam)

    /// Everything contested lives behind this seam: the foundations,
    /// in-flight claims, round settlement, scores. Solo play wires up
    /// the local authority; an online table installs a networked one
    /// without touching the board sim, input, or presentation.
    private var table: any TableAuthority = LocalTableAuthority()

    enum TableKind: Equatable { case solo, online(host: Bool) }
    private(set) var tableKind: TableKind = .solo

    var isOnline: Bool { tableKind != .solo }
    var isOnlineHost: Bool { tableKind == .online(host: true) }
    /// Only the host moves the table past the scoreboard online.
    var canAdvanceScoreboard: Bool { !isOnline || isOnlineHost }

    var foundations: [FoundationPile] { table.foundations }
    var flying: [FlyingCard] { table.flying }
    var scores: [Int] { table.scores }
    var roundNumber: Int { table.roundNumber }
    var summary: RoundSummary? { table.summary }
    var maxFoundations: Int { table.maxFoundations }

    init() {
        table.delegate = self
    }

    /// Take a seat at an online table. `aiSeats` are the bot seats this
    /// device simulates (host only), in local seat space (0 = me).
    func installOnlineTable(
        _ authority: any TableAuthority,
        host: Bool,
        aiSeats: [Int],
        seatNames: [String],
        seatEmojis: [String],
        settings: GameSettings,
        onLeave: @escaping () -> Void
    ) {
        loopTask?.cancel()
        dealTask?.cancel()
        self.table = authority
        authority.delegate = self
        tableKind = .online(host: host)
        aiSeatsOverride = aiSeats
        self.seatNames = seatNames
        self.seatEmojis = seatEmojis
        self.settings = settings
        onLeaveOnline = onLeave
    }

    /// Back to a local solo table (quit, disconnect, match dissolved).
    /// `note` explains why on the menu ("Bo closed the table").
    func leaveOnlineMatch(note: String? = nil) {
        guard isOnline else { return }
        loopTask?.cancel()
        dealTask?.cancel()
        table.abandonRound()
        table = LocalTableAuthority()
        table.delegate = self
        tableKind = .solo
        aiSeatsOverride = nil
        pendingBotSeats = []
        seatNames = []
        seatEmojis = []
        onlineFarewell = note
        phase = .menu
        let handler = onLeaveOnline
        onLeaveOnline = nil
        handler?()
    }

    /// Why the last online table ended — the menu shows it once.
    var onlineFarewell: String?

    /// Host only: a guest's human vanished. Settle the round now (the
    /// scoreboard explains), and from the next deal this engine plays
    /// their seat — a bot slides into the empty chair.
    func onlineHumanLeft(seat: Int, name: String) {
        guard isOnlineHost, seat > 0, seat < playerCount else { return }
        if phase == .playing {
            endRound(caller: -1, note: "\(name) left the table")
        }
        table.convertSeatToBot(seat: seat)
        if !pendingBotSeats.contains(seat) {
            pendingBotSeats.append(seat)
        }
        seatBecameBot(seat: seat)
    }

    /// One-level undo of your last move.
    struct UndoSnapshot {
        let board: PlayerBoard
        let foundationEffect: (pileID: Int, cardID: String, wasNewPile: Bool)?
    }
    private(set) var undo: UndoSnapshot?
    var canUndo: Bool { undo != nil && phase == .playing && !dealing }

    enum Phase: Equatable { case menu, playing, roundEnd }
    struct BannerMessage: Equatable {
        let text: String
        let id: Int
    }

    // MARK: - Private state

    private var aiNextMove: [Date] = []
    private var aiCallAt: [Date?] = []
    /// When the local player's auto-Nerts fires. Armed once your pile is
    /// empty (and nothing you tossed is still in the air); cleared if a
    /// bounced card refills it. Mirrors `aiCallAt` for seat 0.
    private var humanCallAt: Date?
    private var rng = SystemRandomNumberGenerator()
    private var bannerCounter = 0
    private var pulseCounter = 0
    private var pausedAt: Date?
    private var loopTask: Task<Void, Never>?
    private var dealTask: Task<Void, Never>?
    private var onLeaveOnline: (() -> Void)?
    /// Online: which local seats this device simulates as bots.
    private var aiSeatsOverride: [Int]?
    /// Seats whose humans left mid-round; they join aiSeats at the
    /// next deal (a fresh board can't appear mid-round).
    private var pendingBotSeats: [Int] = []
    /// Last badge counts pushed to the table, per seat (online only).
    private var lastReportedNerts: [Int] = []

    var playerCount: Int { settings.opponents + 1 }

    /// Seats whose boards this device actually plays. Solo: every bot
    /// (plus you, in demo mode). Online host: its bots. Guests: none.
    private var aiSeats: [Int] {
        if let aiSeatsOverride { return aiSeatsOverride }
        return (debugDemo ? [0] : []) + Array(1..<playerCount)
    }

    /// Whose cards physically exist on this device.
    private func isSeatSimulated(_ p: Int) -> Bool {
        p == 0 || aiSeats.contains(p)
    }

    var nertsReady: Bool {
        phase == .playing && !dealing && !boards.isEmpty && boards[0].nerts.isEmpty
    }

    func aiIsCalling(_ p: Int) -> Bool {
        p < aiCallAt.count && aiCallAt[p] != nil
    }

    // MARK: - Seat identity & badges

    /// Names/emojis for the current table; empty in solo (falls back to
    /// the bot roster mapping).
    private(set) var seatNames: [String] = []
    private(set) var seatEmojis: [String] = []

    func seatName(_ p: Int) -> String {
        p < seatNames.count ? seatNames[p] : AIProfile.seatName(p)
    }

    func seatEmoji(_ p: Int) -> String {
        p < seatEmojis.count ? seatEmojis[p] : AIProfile.seatEmoji(p)
    }

    /// Edge-badge count for a seat: the real board when it lives here,
    /// the reported count when it lives on someone else's device.
    func nertsBadge(_ p: Int) -> Int {
        if let reported = table.reportedNertsCount(seat: p) { return reported }
        if isSeatSimulated(p), p < boards.count { return boards[p].nerts.count }
        return 13
    }

    // MARK: - Match / round lifecycle

    func newMatch() {
        table.beginMatch(settings: settings)
        startRound()
    }

    func startRound() {
        loopTask?.cancel()
        dealTask?.cancel()
        // Empty chairs get their bots before the deal.
        if !pendingBotSeats.isEmpty, aiSeatsOverride != nil {
            aiSeatsOverride = (aiSeatsOverride ?? []) + pendingBotSeats
            pendingBotSeats = []
        }
        table.beginRound()
        pulses = []
        shakeTokens = [:]
        paused = false
        pausedAt = nil
        undo = nil
        seatPulse = Array(repeating: 0, count: playerCount)
        aiCallAt = Array(repeating: nil, count: playerCount)
        humanCallAt = nil
        aiNextMove = Array(repeating: .distantFuture, count: playerCount)
        lastReportedNerts = Array(repeating: -1, count: playerCount)
        boards = (0..<playerCount).map { p in
            var b = PlayerBoard()
            // Remote players deal their own decks on their own devices;
            // their boards here stay empty (badges use reported counts).
            if isSeatSimulated(p) {
                b.stock = newDeck(owner: p).shuffled(using: &rng)
            }
            return b
        }
        phase = .playing
        dealing = true
        freshWasteIDs = []      // card ids repeat across rounds
        dealTask = Task { await self.runDeal() }
    }

    private func runDeal() async {
        // Locally simulated opponents set up instantly (not visible).
        let aiNertsCount = debugTinyNerts ? (debugDemo ? 4 : 2) : 13
        for p in aiSeats where p != 0 {
            var b = boards[p]
            for _ in 0..<aiNertsCount { b.nerts.append(b.stock.removeLast()) }
            for i in 0..<4 { b.work[i].append(b.stock.removeLast()) }
            boards[p] = b
        }
        // Your cards are dealt one at a time off the stock.
        let myNertsCount = (debugTinyNerts && debugDemo) ? 4 : 13
        try? await Task.sleep(for: .milliseconds(400))
        for _ in 0..<myNertsCount {
            guard !Task.isCancelled else { return }
            var b = boards[0]
            b.nerts.append(b.stock.removeLast())
            boards[0] = b
            Sound.play(.deal)
            try? await Task.sleep(for: .milliseconds(45))
        }
        for i in 0..<4 {
            guard !Task.isCancelled else { return }
            var b = boards[0]
            b.work[i].append(b.stock.removeLast())
            boards[0] = b
            Sound.play(.deal)
            try? await Task.sleep(for: .milliseconds(80))
        }
        guard !Task.isCancelled else { return }
        dealing = false
        let now = Date()
        for p in aiSeats {
            aiNextMove[p] = now.addingTimeInterval(sampleInterval() * 1.3)
        }
        table.noteActivity()
        startLoop()
    }

    func advanceFromScoreboard() {
        guard phase == .roundEnd, canAdvanceScoreboard else { return }
        if summary?.winner != nil {
            newMatch()
        } else {
            table.advanceRound()
            startRound()
        }
    }

    func quitToMenu() {
        if isOnline {
            leaveOnlineMatch()
            return
        }
        loopTask?.cancel()
        dealTask?.cancel()
        table.abandonRound()
        phase = .menu
    }

    /// Pause freezes the AI loop; resuming shifts every AI's schedule
    /// (and the table's deadlines) forward by the pause duration so
    /// nobody unleashes a burst of queued-up moves the moment play
    /// continues.
    func setPaused(_ on: Bool) {
        // An online table can't be frozen by one player.
        guard phase == .playing, !isOnline else { return }
        if on {
            guard !paused else { return }
            pausedAt = Date()
            paused = true
        } else {
            guard paused else { return }
            let delta = Date().timeIntervalSince(pausedAt ?? Date())
            for i in aiNextMove.indices {
                aiNextMove[i] = aiNextMove[i].addingTimeInterval(delta)
            }
            for i in aiCallAt.indices {
                aiCallAt[i] = aiCallAt[i]?.addingTimeInterval(delta)
            }
            humanCallAt = humanCallAt?.addingTimeInterval(delta)
            table.shiftDeadlines(by: delta)
            pausedAt = nil
            paused = false
        }
    }

    func callNerts() {
        guard nertsReady, !paused else { return }
        Haptics.fanfare()
        endRound(caller: 0)
    }

    private func endRound(caller: Int, note: String? = nil) {
        guard phase == .playing else { return }
        loopTask?.cancel()
        dealTask?.cancel()
        dealing = false
        // The authority settles the race, tallies, and reports back via
        // roundEnded. Demo/quickround rounds aren't genuine play — keep
        // them out of stats.
        table.endRound(caller: caller, recordStats: !debugDemo && !debugTinyNerts, note: note)
    }

    // MARK: - The AI loop

    private func startLoop() {
        loopTask?.cancel()
        loopTask = Task {
            while !Task.isCancelled {
                self.tick()
                try? await Task.sleep(for: .milliseconds(110))
            }
        }
    }

    private func sampleInterval() -> Double {
        Double.random(in: settings.difficulty.params.interval, using: &rng)
    }

    private func tick() {
        guard phase == .playing, !dealing, !paused else { return }
        let now = Date()
        let params = settings.difficulty.params

        // Auto-Nerts: no button to hit. The instant your pile is empty and
        // nothing you tossed is still racing for a foundation (an online toss
        // can lose the race and bounce home, refilling the pile), the table
        // calls it for you after a short beat. Skipped in demo mode, where the
        // bot loop below drives seat 0.
        if !aiSeats.contains(0) {
            if nertsReady && !table.flying.contains(where: { $0.fromSeat == 0 }) {
                if humanCallAt == nil {
                    humanCallAt = now.addingTimeInterval(0.4)
                } else if now >= humanCallAt! {
                    callNerts()
                    return
                }
            } else {
                humanCallAt = nil
            }
        }

        for p in aiSeats {
            if boards[p].nerts.isEmpty {
                if aiCallAt[p] == nil {
                    aiCallAt[p] = now.addingTimeInterval(Double.random(in: params.callDelay, using: &rng))
                } else if now >= aiCallAt[p]! {
                    endRound(caller: p)
                    return
                }
            } else if aiCallAt[p] != nil {
                // A bounced card refilled the pile — cancel the call.
                aiCallAt[p] = nil
            }
            if now >= aiNextMove[p] {
                let action = performAIMove(p)
                let base = sampleInterval()
                aiNextMove[p] = now.addingTimeInterval(action == .flip ? base * 0.55 : base)
            }
        }

        // Online: push badge counts for the boards that live here when
        // they change. (Writes nothing unless a count actually moved.)
        if isOnline {
            for p in 0..<playerCount where isSeatSimulated(p) {
                let count = boards[p].nerts.count
                if p < lastReportedNerts.count, lastReportedNerts[p] != count {
                    lastReportedNerts[p] = count
                    table.reportNerts(seat: p, count: count)
                }
            }
        }

        // Settle any claims whose flight time is up. Runs on the tick so it
        // freezes with pause, like every other gameplay deadline.
        table.settleDueClaims(now: now)

        // Whole table stuck for a long while — everyone shuffles (house rule).
        table.checkStuck(now: now)
    }

    private enum AIAction { case flip, play }

    private func performAIMove(_ p: Int) -> AIAction {
        let params = settings.difficulty.params
        if Double.random(in: 0...1, using: &rng) < params.skipChance {
            flipStock(p)
            return .flip
        }
        guard let (source, target) = AIBrain.decide(
            board: boards[p],
            foundations: foundations,
            maxFoundations: maxFoundations,
            params: params,
            rng: &rng
        ) else {
            flipStock(p)
            return .flip
        }
        switch target {
        case .foundation(let idx):
            // The demo player stands in for a human, so it commits instantly.
            if p == 0 {
                if applyMove(p, source: source, target: target) { return .play }
            } else if launchClaim(p, source: source, pileIndex: idx) {
                return .play
            }
        case .work:
            if applyMove(p, source: source, target: target) { return .play }
        }
        flipStock(p)
        return .flip
    }

    /// The official unsticking rule: everyone re-forms their stock from the
    /// waste, then moves the top card of the stock to the bottom — so the
    /// same threes never come up again. Applies to every player, so using
    /// it manually is never an unfair advantage.
    func tableShuffle() {
        guard phase == .playing, !dealing else { return }
        for p in 0..<playerCount {
            var b = boards[p]
            b.stock = b.stock + b.waste.reversed()
            b.waste = []
            if b.stock.count > 1 {
                let top = b.stock.removeLast()
                b.stock.insert(top, at: 0)
            }
            boards[p] = b
        }
        table.noteActivity()
        showBanner("Table shuffle — top card to the bottom 🔀")
    }

    private func showBanner(_ text: String) {
        bannerCounter += 1
        banner = BannerMessage(text: text, id: bannerCounter)
        let id = bannerCounter
        Task {
            try? await Task.sleep(for: .seconds(2.4))
            if self.banner?.id == id { self.banner = nil }
        }
    }

    // MARK: - Core rules: reading & mutating piles

    private func cards(at source: MoveSource, player p: Int) -> [Card]? {
        let b = boards[p]
        switch source {
        case .nertsTop:
            guard let c = b.nerts.last else { return nil }
            return [c]
        case .wasteTop:
            guard let c = b.waste.last else { return nil }
            return [c]
        case .work(let pile, let index):
            guard (0..<4).contains(pile), index >= 0, index < b.work[pile].count else { return nil }
            return Array(b.work[pile][index...])
        }
    }

    private func removeCards(at source: MoveSource, player p: Int) {
        var b = boards[p]
        switch source {
        case .nertsTop: b.nerts.removeLast()
        case .wasteTop: b.waste.removeLast()
        case .work(let pile, let index): b.work[pile].removeSubrange(index...)
        }
        boards[p] = b
    }

    @discardableResult
    private func applyMove(_ p: Int, source: MoveSource, target: DropTarget, spot: CGPoint? = nil) -> Bool {
        guard phase == .playing else { return false }
        guard let unit = cards(at: source, player: p), let first = unit.first else { return false }

        switch target {
        case .foundation(let idx):
            // Your own play: instant commit at a table you're the
            // authority for; a short toss at a networked one.
            guard unit.count == 1, table.playNow(first, from: source, at: idx, spot: spot) != nil else { return false }
            removeCards(at: source, player: p)
        case .work(let w):
            guard (0..<4).contains(w) else { return false }
            if case .work(let src, _) = source, src == w { return false }
            if let base = boards[p].work[w].last {
                guard stacksOnWork(first, onto: base) else { return false }
            }
            removeCards(at: source, player: p)
            boards[p].work[w].append(contentsOf: unit)
        }
        return true
    }

    /// An opponent throws a card at a foundation. It leaves their board now,
    /// but the pile only updates when the card lands — anyone can take the
    /// spot in the meantime, and the loser's card bounces home.
    private func launchClaim(_ p: Int, source: MoveSource, pileIndex: Int?) -> Bool {
        guard let unit = cards(at: source, player: p), unit.count == 1, let card = unit.first,
              table.submitClaim(card, fromSeat: p, source: source, pileIndex: pileIndex, spot: nil, flight: 0.68)
        else { return false }
        removeCards(at: source, player: p)
        seatPulse[p] += 1
        return true
    }

    private func returnToBoard(_ claim: FlyingCard) {
        var b = boards[claim.fromSeat]
        switch claim.source {
        case .nertsTop: b.nerts.append(claim.card)
        case .wasteTop: b.waste.append(claim.card)
        case .work(let pile, _): b.work[pile].append(claim.card)
        }
        boards[claim.fromSeat] = b
    }

    private func pulse(at pileID: Int, owner: Int) {
        pulseCounter += 1
        let pulseID = pulseCounter
        pulses.append(LandingPulse(id: pulseID, pileID: pileID, owner: owner))
        Task {
            try? await Task.sleep(for: .milliseconds(650))
            self.pulses.removeAll { $0.id == pulseID }
        }
    }

    private func flipStock(_ p: Int) {
        var b = boards[p]
        if b.stock.isEmpty {
            // A pure recycle: the same threes come up again. Only playing a
            // card from the waste (or a table shuffle) changes the phase.
            guard !b.waste.isEmpty else { return }
            b.stock = b.waste.reversed()
            b.waste = []
            if p == 0 { freshWasteIDs = [] }
        } else {
            var flipped: Set<String> = []
            for _ in 0..<min(3, b.stock.count) {
                let c = b.stock.removeLast()
                flipped.insert(c.id)
                b.waste.append(c)
            }
            if p == 0 { freshWasteIDs = flipped }
        }
        boards[p] = b
    }

    // MARK: - Human interactions

    func humanTapStock() {
        guard phase == .playing, !dealing, !paused else { return }
        guard !(boards[0].stock.isEmpty && boards[0].waste.isEmpty) else { return }
        let snapshot = boards[0]
        flipStock(0)
        undo = UndoSnapshot(board: snapshot, foundationEffect: nil)
        Haptics.flip()
        Sound.play(.flip)
    }

    func handleTap(on card: Card) {
        guard phase == .playing, !dealing, !paused, card.owner == 0 else { return }
        let b = boards[0]
        if b.stock.contains(card) {
            humanTapStock()
            return
        }
        // Buried waste / nerts cards are inert.
        if b.waste.contains(card), b.waste.last != card { return }
        if b.nerts.contains(card), b.nerts.last != card { return }

        guard let source = topSource(of: card) else {
            // A buried work-pile card can never go to a foundation.
            rejectFeedback(card)
            return
        }
        if let target = foundationTarget(for: card) {
            let snapshot = boards[0]
            if applyMove(0, source: source, target: target) {
                recordUndo(snapshot: snapshot, target: target, movedCardID: card.id)
                Haptics.score()
                Sound.play(.score)
                return
            }
        }
        rejectFeedback(card)
    }

    private func rejectFeedback(_ card: Card) {
        shakeTokens[card.id, default: 0] += 1
        Haptics.nope()
    }

    private func topSource(of card: Card) -> MoveSource? {
        let b = boards[0]
        if b.nerts.last == card { return .nertsTop }
        if b.waste.last == card { return .wasteTop }
        for i in 0..<4 where b.work[i].last == card {
            return .work(pile: i, index: b.work[i].count - 1)
        }
        return nil
    }

    /// Pending-aware pile check: online, your own in-flight tosses
    /// count as already down, so runs chain without waiting on the wire.
    func pileAccepts(_ card: Card, at index: Int) -> Bool {
        table.pileAccepts(card, pileIndex: index)
    }

    func foundationTarget(for card: Card) -> DropTarget? {
        if let idx = foundations.indices.first(where: { pileAccepts(card, at: $0) }) {
            return .foundation(idx)
        }
        if card.rank == 1, foundations.count < maxFoundations {
            return .foundation(nil)
        }
        return nil
    }

    func dragUnit(for card: Card) -> (unit: [Card], source: MoveSource)? {
        guard phase == .playing, !dealing, !paused, card.owner == 0 else { return nil }
        let b = boards[0]
        if b.waste.last == card { return ([card], .wasteTop) }
        if b.nerts.last == card { return ([card], .nertsTop) }
        for i in 0..<4 {
            if let idx = b.work[i].firstIndex(of: card) {
                return (Array(b.work[i][idx...]), .work(pile: i, index: idx))
            }
        }
        return nil
    }

    /// `target` is the geometric target under the drop point (unvalidated), or nil
    /// if the cards were released over nothing. `spot` is where on the open
    /// felt the card was dropped, for starting a new pile right there.
    @discardableResult
    func humanDrop(source: MoveSource, target: DropTarget?, spot: CGPoint? = nil) -> DropResult {
        guard let target else { return .rejected }
        let snapshot = boards[0]
        let movedCardID = cards(at: source, player: 0)?.first?.id
        guard applyMove(0, source: source, target: target, spot: spot) else {
            Haptics.nope()
            return .rejected
        }
        recordUndo(snapshot: snapshot, target: target, movedCardID: movedCardID)
        switch target {
        case .foundation:
            Haptics.score()
            Sound.play(.score)
            return .foundation
        case .work:
            Haptics.place()
            Sound.play(.place)
            return .work
        }
    }

    // MARK: - Undo (one level)

    private func recordUndo(snapshot: PlayerBoard, target: DropTarget, movedCardID: String?) {
        var effect: (pileID: Int, cardID: String, wasNewPile: Bool)?
        if case .foundation(let idx) = target, let movedCardID {
            let pileID = idx.map { foundations[$0].id } ?? (foundations.last?.id ?? -1)
            effect = (pileID, movedCardID, idx == nil)
        }
        undo = UndoSnapshot(board: snapshot, foundationEffect: effect)
    }

    func undoLast() {
        guard phase == .playing, !dealing, !paused, let u = undo else { return }
        if let fe = u.foundationEffect {
            guard table.undoFoundationPlay(pileID: fe.pileID, cardID: fe.cardID, wasNewPile: fe.wasNewPile) else {
                undo = nil
                showBanner("Too late to undo — the table moved on")
                Haptics.nope()
                return
            }
        }
        boards[0] = u.board
        undo = nil
        Haptics.place()
        Sound.play(.place)
    }

    func canDrop(_ unit: [Card], on target: DropTarget) -> Bool {
        guard let first = unit.first else { return false }
        switch target {
        case .foundation(let idx):
            guard unit.count == 1 else { return false }
            if let idx {
                return idx < foundations.count && pileAccepts(first, at: idx)
            }
            return first.rank == 1 && foundations.count < maxFoundations
        case .work(let w):
            guard (0..<4).contains(w) else { return false }
            if case .work(let src, _) = sourceOf(unit: unit), src == w { return false }
            guard let base = boards[0].work[w].last else { return true }
            return stacksOnWork(first, onto: base)
        }
    }

    private func sourceOf(unit: [Card]) -> MoveSource {
        guard let first = unit.first else { return .wasteTop }
        for i in 0..<4 where boards[0].work[i].contains(first) {
            return .work(pile: i, index: boards[0].work[i].firstIndex(of: first) ?? 0)
        }
        if boards[0].nerts.last == first { return .nertsTop }
        return .wasteTop
    }
}

// MARK: - Authority events (the "host → all" stream; local and instant in solo)

extension GameEngine: TableAuthorityDelegate {
    func claimLanded(_ claim: FlyingCard, on pileID: Int) {
        pulse(at: pileID, owner: claim.fromSeat)
        // Your own online toss already clicked when you dropped it.
        if claim.fromSeat != 0 {
            Sound.play(.opponent)
        }
    }

    func claimBounced(_ claim: FlyingCard) {
        // Remote players' cards return to boards on their own devices.
        guard isSeatSimulated(claim.fromSeat) else { return }
        returnToBoard(claim)
        if claim.fromSeat == 0 {
            // Your toss lost the race — the card comes home.
            Haptics.nope()
        }
    }

    func nertsLeftCounts() -> [Int] {
        boards.map { $0.nerts.count }
    }

    func roundEnded(_ summary: RoundSummary) {
        pulses = []
        phase = .roundEnd
    }

    func tableShuffleCalled() {
        tableShuffle()
    }

    func roundStarted(round: Int) {
        // A networked host dealt — deal our own deck to match.
        guard isOnline else { return }
        startRound()
    }

    func remoteNertsCall(seat: Int) {
        guard isOnline else { return }
        endRound(caller: seat)
    }

    func seatBecameBot(seat: Int) {
        guard isOnline, seat < seatNames.count else { return }
        if !seatNames[seat].hasSuffix("🤖") {
            seatNames[seat] += " 🤖"
        }
    }

    func tableClosed(reason: String) {
        leaveOnlineMatch(note: reason)
    }
}

// MARK: - AI decision making

enum AIBrain {
    static func decide(
        board: PlayerBoard,
        foundations: [FoundationPile],
        maxFoundations: Int,
        params: DifficultyParams,
        rng: inout SystemRandomNumberGenerator
    ) -> (MoveSource, DropTarget)? {

        func foundationTarget(_ card: Card) -> DropTarget? {
            if let idx = foundations.firstIndex(where: { $0.accepts(card) }) {
                return .foundation(idx)
            }
            if card.rank == 1, foundations.count < maxFoundations {
                return .foundation(nil)
            }
            return nil
        }

        func fitsWork(_ card: Card, _ pile: Int) -> Bool {
            guard let base = board.work[pile].last else { return true }
            return stacksOnWork(card, onto: base)
        }

        // 1. Nerts pile → foundation. The whole point of the game.
        if let c = board.nerts.last, let t = foundationTarget(c) {
            return (.nertsTop, t)
        }
        // 2. Waste → foundation.
        if let c = board.waste.last, let t = foundationTarget(c) {
            return (.wasteTop, t)
        }
        // 3. Work pile tops → foundation.
        for i in 0..<4 {
            if let c = board.work[i].last, let t = foundationTarget(c) {
                return (.work(pile: i, index: board.work[i].count - 1), t)
            }
        }
        // 4. Nerts → work: dig into the pile.
        if let c = board.nerts.last {
            if let empty = (0..<4).first(where: { board.work[$0].isEmpty }) {
                return (.nertsTop, .work(empty))
            }
            if let fit = (0..<4).first(where: { fitsWork(c, $0) }) {
                return (.nertsTop, .work(fit))
            }
        }

        guard params.smart else { return nil }

        // 5. Free up a work slot by consolidating a whole pile, so the next
        //    nerts card has somewhere to go.
        if !board.nerts.isEmpty, !(0..<4).contains(where: { board.work[$0].isEmpty }) {
            for i in 0..<4 where !board.work[i].isEmpty && board.work[i].count <= 4 {
                if let first = board.work[i].first,
                   let j = (0..<4).first(where: { $0 != i && !board.work[$0].isEmpty && fitsWork(first, $0) }) {
                    return (.work(pile: i, index: 0), .work(j))
                }
            }
        }
        // 6. Waste → work to keep the engine turning.
        if let c = board.waste.last,
           let j = (0..<4).first(where: { !board.work[$0].isEmpty && fitsWork(c, $0) }),
           Double.random(in: 0...1, using: &rng) < 0.55 {
            return (.wasteTop, .work(j))
        }
        return nil
    }
}
