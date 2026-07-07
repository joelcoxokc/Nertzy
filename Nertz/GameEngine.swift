import SwiftUI
import Observation

@MainActor
@Observable
final class GameEngine {

    // MARK: - Observable state

    var settings = GameSettings()
    private(set) var phase: Phase = .menu
    private(set) var boards: [PlayerBoard] = []
    private(set) var foundations: [FoundationPile] = []
    private(set) var flying: [FlyingCard] = []
    private(set) var pulses: [LandingPulse] = []
    private(set) var scores: [Int] = []
    private(set) var roundNumber = 1
    private(set) var summary: RoundSummary?
    private(set) var dealing = false
    private(set) var banner: BannerMessage?
    private(set) var seatPulse: [Int] = []
    var shakeTokens: [String: Int] = [:]
    private(set) var paused = false
    /// Debug: deal opponents a 2-card nerts pile so rounds end fast (-quickround).
    var debugTinyNerts = false
    /// Debug: the AI also plays your seat — living screenshots/demos (-demo).
    var debugDemo = false

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
    private var lastFoundationPlay = Date()
    private var rng = SystemRandomNumberGenerator()
    private var bannerCounter = 0
    private var pulseCounter = 0
    private var nextPileID = 0
    private var pausedAt: Date?
    /// Cards from completed piles cleared off the table — still worth points.
    private var retired: [Card] = []
    private var loopTask: Task<Void, Never>?
    private var dealTask: Task<Void, Never>?

    var playerCount: Int { settings.opponents + 1 }
    var maxFoundations: Int { 4 * playerCount }

    var nertsReady: Bool {
        phase == .playing && !dealing && !boards.isEmpty && boards[0].nerts.isEmpty
    }

    func aiIsCalling(_ p: Int) -> Bool {
        p < aiCallAt.count && aiCallAt[p] != nil
    }

    // MARK: - Match / round lifecycle

    func newMatch() {
        scores = Array(repeating: 0, count: playerCount)
        roundNumber = 1
        startRound()
    }

    func startRound() {
        loopTask?.cancel()
        dealTask?.cancel()
        summary = nil
        foundations = []
        flying = []
        pulses = []
        retired = []
        nextPileID = 0
        shakeTokens = [:]
        paused = false
        pausedAt = nil
        undo = nil
        seatPulse = Array(repeating: 0, count: playerCount)
        aiCallAt = Array(repeating: nil, count: playerCount)
        aiNextMove = Array(repeating: .distantFuture, count: playerCount)
        boards = (0..<playerCount).map { p in
            var b = PlayerBoard()
            b.stock = newDeck(owner: p).shuffled(using: &rng)
            return b
        }
        phase = .playing
        dealing = true
        dealTask = Task { await self.runDeal() }
    }

    private func runDeal() async {
        // Opponents set up instantly (their tables aren't visible).
        let aiNertsCount = debugTinyNerts ? (debugDemo ? 4 : 2) : 13
        for p in 1..<playerCount {
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
        for p in (debugDemo ? 0 : 1)..<playerCount {
            aiNextMove[p] = now.addingTimeInterval(sampleInterval() * 1.3)
        }
        lastFoundationPlay = now
        startLoop()
    }

    func advanceFromScoreboard() {
        guard phase == .roundEnd else { return }
        if summary?.winner != nil {
            newMatch()
        } else {
            roundNumber += 1
            startRound()
        }
    }

    func quitToMenu() {
        loopTask?.cancel()
        dealTask?.cancel()
        phase = .menu
    }

    /// Pause freezes the AI loop; resuming shifts every AI's schedule
    /// forward by the pause duration so nobody unleashes a burst of
    /// queued-up moves the moment play continues.
    func setPaused(_ on: Bool) {
        guard phase == .playing else { return }
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
            lastFoundationPlay = lastFoundationPlay.addingTimeInterval(delta)
            pausedAt = nil
            paused = false
        }
    }

    func callNerts() {
        guard nertsReady, !paused else { return }
        Haptics.fanfare()
        endRound(caller: 0)
    }

    private func endRound(caller: Int) {
        guard phase == .playing else { return }
        loopTask?.cancel()
        dealTask?.cancel()
        dealing = false
        var counts = Array(repeating: 0, count: playerCount)
        for pile in foundations {
            for card in pile.cards { counts[card.owner] += 1 }
        }
        for card in retired { counts[card.owner] += 1 }
        let left = boards.map { $0.nerts.count }
        let deltas = (0..<playerCount).map { counts[$0] - 2 * left[$0] }
        var totals = scores
        for i in totals.indices { totals[i] += deltas[i] }
        scores = totals
        var winner: Int?
        if let best = totals.max(), best >= 100 {
            winner = totals.firstIndex(of: best)
        }
        flying = []
        pulses = []
        summary = RoundSummary(
            caller: caller,
            foundationCounts: counts,
            nertsLeft: left,
            deltas: deltas,
            totals: totals,
            winner: winner
        )
        phase = .roundEnd
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

        for p in (debugDemo ? 0 : 1)..<playerCount {
            if boards[p].nerts.isEmpty {
                if aiCallAt[p] == nil {
                    aiCallAt[p] = now.addingTimeInterval(Double.random(in: params.callDelay, using: &rng))
                } else if now >= aiCallAt[p]! {
                    endRound(caller: p)
                    return
                }
            }
            if now >= aiNextMove[p] {
                let action = performAIMove(p)
                let base = sampleInterval()
                aiNextMove[p] = now.addingTimeInterval(action == .flip ? base * 0.55 : base)
            }
        }

        // Whole table stuck for a long while — everyone shuffles (house rule).
        if now.timeIntervalSince(lastFoundationPlay) > 40 {
            tableShuffle()
        }
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
        if applyMove(p, source: source, target: target) {
            return .play
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
            b.playsSinceRecycle = 0
            boards[p] = b
        }
        lastFoundationPlay = Date()
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
    private func applyMove(_ p: Int, source: MoveSource, target: DropTarget) -> Bool {
        guard phase == .playing else { return false }
        guard let unit = cards(at: source, player: p), let first = unit.first else { return false }

        switch target {
        case .foundation(let idx):
            guard unit.count == 1 else { return false }
            if let idx {
                guard idx < foundations.count, foundations[idx].accepts(first) else { return false }
                removeCards(at: source, player: p)
                foundations[idx].cards.append(first)
                noteFoundationPlay(p, card: first, pileID: foundations[idx].id)
                if foundations[idx].isComplete {
                    // The king caps the pile: flip it over, then clear it away.
                    retirePile(foundations[idx].id, after: p == 0 ? 0.9 : 1.7)
                }
            } else {
                guard first.rank == 1, foundations.count < maxFoundations else { return false }
                removeCards(at: source, player: p)
                foundations.append(FoundationPile(id: nextPileID, cards: [first]))
                nextPileID += 1
                noteFoundationPlay(p, card: first, pileID: foundations.last!.id)
            }
        case .work(let w):
            guard (0..<4).contains(w) else { return false }
            if case .work(let src, _) = source, src == w { return false }
            if let base = boards[p].work[w].last {
                guard stacksOnWork(first, onto: base) else { return false }
            }
            removeCards(at: source, player: p)
            boards[p].work[w].append(contentsOf: unit)
        }
        boards[p].playsSinceRecycle += 1
        return true
    }

    private func noteFoundationPlay(_ p: Int, card: Card, pileID: Int) {
        lastFoundationPlay = Date()
        if p > 0 {
            seatPulse[p] += 1
            launchFlight(card: card, from: p, to: pileID)
        }
    }

    private func launchFlight(card: Card, from seat: Int, to pileID: Int) {
        flying.append(FlyingCard(card: card, fromSeat: seat, pileID: pileID))
        pulseCounter += 1
        let pulseID = pulseCounter
        Task {
            try? await Task.sleep(for: .milliseconds(30))
            if let i = self.flying.firstIndex(where: { $0.id == card.id }) {
                self.flying[i].landed = true
            }
            // Let the slower flight spring settle, then stamp the landing.
            try? await Task.sleep(for: .milliseconds(650))
            self.flying.removeAll { $0.id == card.id }
            guard self.phase == .playing else { return }
            self.pulses.append(LandingPulse(id: pulseID, pileID: pileID, owner: seat))
            Sound.play(.opponent)
            try? await Task.sleep(for: .milliseconds(650))
            self.pulses.removeAll { $0.id == pulseID }
        }
    }

    /// A completed pile: flip the king face down, pause, shrink it away,
    /// then remove it so the table stays uncluttered.
    private func retirePile(_ pileID: Int, after delay: Double) {
        Task {
            try? await Task.sleep(for: .seconds(delay))
            guard self.phase == .playing,
                  let i = self.foundations.firstIndex(where: { $0.id == pileID }),
                  self.foundations[i].isComplete else { return }
            self.foundations[i].faceDown = true
            Sound.play(.place)
            try? await Task.sleep(for: .seconds(1.5))
            guard self.phase == .playing,
                  let j = self.foundations.firstIndex(where: { $0.id == pileID }) else { return }
            self.foundations[j].vanishing = true
            try? await Task.sleep(for: .milliseconds(400))
            guard self.phase == .playing,
                  let k = self.foundations.firstIndex(where: { $0.id == pileID }) else { return }
            self.retired.append(contentsOf: self.foundations[k].cards)
            self.foundations.remove(at: k)
        }
    }

    private func flipStock(_ p: Int) {
        var b = boards[p]
        if b.stock.isEmpty {
            guard !b.waste.isEmpty else { return }
            b.stock = b.waste.reversed()
            b.waste = []
            if b.playsSinceRecycle == 0, b.stock.count > 1 {
                // A full barren cycle: shift one card so the same threes don't repeat.
                let top = b.stock.removeLast()
                b.stock.insert(top, at: 0)
            }
            b.playsSinceRecycle = 0
        } else {
            for _ in 0..<min(3, b.stock.count) {
                b.waste.append(b.stock.removeLast())
            }
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

    func foundationTarget(for card: Card) -> DropTarget? {
        if let idx = foundations.firstIndex(where: { $0.accepts(card) }) {
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
    /// if the cards were released over nothing.
    @discardableResult
    func humanDrop(source: MoveSource, target: DropTarget?) -> DropResult {
        guard let target else { return .rejected }
        let snapshot = boards[0]
        let movedCardID = cards(at: source, player: 0)?.first?.id
        guard applyMove(0, source: source, target: target) else {
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
            let index = foundations.firstIndex(where: { $0.id == fe.pileID })
            let stillReversible = index != nil
                && !foundations[index!].faceDown
                && foundations[index!].cards.last?.id == fe.cardID
                && (!fe.wasNewPile
                    || (index == foundations.count - 1
                        && foundations[index!].cards.count == 1))
            guard stillReversible, let index else {
                undo = nil
                showBanner("Too late to undo — the table moved on")
                Haptics.nope()
                return
            }
            if fe.wasNewPile {
                foundations.remove(at: index)
            } else {
                foundations[index].cards.removeLast()
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
                return idx < foundations.count && foundations[idx].accepts(first)
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
