import SwiftUI

struct TableView: View {
    let engine: GameEngine

    @State private var drag: DragInfo?
    @State private var hover: DropTarget?

    struct DragInfo {
        let unit: [Card]
        let source: MoveSource
        let bases: [String: CGPoint]
        let unitIDs: Set<String>
        let leadID: String
        var translation: CGSize = .zero
    }

    var body: some View {
        GeometryReader { geo in
            let layout = TableLayout(size: geo.size, playerCount: engine.playerCount)
            ZStack {
                tableChrome(layout)
                seats(layout)
                cardLayer(layout)
                pulseLayer(layout)
                highlightLayer(layout)
                hudLayer(layout)
            }
            .coordinateSpace(name: "table")
        }
        .background(FeltBackground())
        .overlay { roundEndOverlay }
        .onAppear {
            Haptics.prepare()
            Sound.start()
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .onChange(of: engine.paused) { _, isPaused in
            if isPaused {
                drag = nil
                hover = nil
            }
        }
    }

    // MARK: - Static table chrome (zone, slots, markers)

    @ViewBuilder
    private func tableChrome(_ layout: TableLayout) -> some View {
        // Foundation zone inset
        let zoneW = CGFloat(layout.fCols) * (layout.fCardW + layout.fGap) - layout.fGap + 8
        let zoneH = layout.foundationBottom - layout.foundationTop + 20
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color.black.opacity(0.13))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(.white.opacity(0.07), lineWidth: 1)
            )
            .frame(width: zoneW, height: zoneH)
            .position(x: layout.size.width / 2, y: (layout.foundationTop + layout.foundationBottom) / 2)

        // Ghost slot for the next ace
        if engine.phase != .menu, engine.foundations.count < layout.capacity {
            SlotMarker(width: layout.fCardW, label: "A")
                .position(layout.foundationSlot(engine.foundations.count))
        }

        if let board = engine.boards.first {
            // Nerts pile slot
            SlotMarker(width: layout.cardW, label: "N")
                .position(layout.nertsPos)
            // Work pile slots
            ForEach(0..<4, id: \.self) { i in
                SlotMarker(width: layout.cardW)
                    .position(layout.workBase(i))
            }
            // Stock slot — tappable to recycle the waste
            SlotMarker(
                width: layout.cardW,
                icon: board.stock.isEmpty && !board.waste.isEmpty
                    ? "arrow.triangle.2.circlepath"
                    : nil
            )
            .position(layout.stockPos)
            .onTapGesture { engine.humanTapStock() }
        }
    }

    // MARK: - Opponent seats

    private func seats(_ layout: TableLayout) -> some View {
        ForEach(1..<engine.playerCount, id: \.self) { p in
            SeatChip(
                profile: AIProfile.roster[p - 1],
                nertsLeft: p < engine.boards.count ? engine.boards[p].nerts.count : 13,
                score: p < engine.scores.count ? engine.scores[p] : 0,
                backTint: CardPalette.back(for: p),
                calling: engine.aiIsCalling(p),
                pulse: p < engine.seatPulse.count ? engine.seatPulse[p] : 0
            )
            .position(layout.seatPos(p))
            .zIndex(9200)
        }
    }

    // MARK: - Cards

    private struct RC: Identifiable {
        let id: String
        let card: Card
        var pos: CGPoint
        var z: Double
        var faceUp: Bool
        var w: CGFloat
        var rot: Double
        var opacity: Double = 1
        var dragging = false
        var flight = false
        var shadowed = false
    }

    private func renderCards(_ layout: TableLayout) -> [RC] {
        var out: [RC] = []
        guard let board = engine.boards.first else { return out }

        // Stock — the whole face-down pile, with a hint of thickness
        let stockCount = board.stock.count
        for (i, c) in board.stock.enumerated() {
            let lift = min(CGFloat(i), 20) * 0.16
            out.append(RC(
                id: c.id, card: c, pos: layout.stockPos.offsetBy(0, -lift),
                z: 100 + Double(i), faceUp: false, w: layout.cardW, rot: 0,
                shadowed: i == stockCount - 1
            ))
        }
        // Waste — top three fanned
        let wasteCount = board.waste.count
        for (i, c) in board.waste.enumerated() {
            let depth = wasteCount - 1 - i
            out.append(RC(
                id: c.id, card: c, pos: layout.wastePos(depth: depth),
                z: 300 + Double(i), faceUp: true, w: layout.cardW, rot: 0,
                shadowed: depth < 3
            ))
        }
        // Nerts pile
        let nertsCount = board.nerts.count
        for (i, c) in board.nerts.enumerated() {
            let lift = min(CGFloat(i), 16) * 0.3
            out.append(RC(
                id: c.id, card: c, pos: layout.nertsPos.offsetBy(0, -lift),
                z: 500 + Double(i), faceUp: i == nertsCount - 1, w: layout.cardW, rot: 0,
                shadowed: i >= nertsCount - 2
            ))
        }
        // Work piles
        for p in 0..<4 {
            let count = board.work[p].count
            for (i, c) in board.work[p].enumerated() {
                out.append(RC(
                    id: c.id, card: c,
                    pos: layout.workCardPos(pile: p, index: i, count: count),
                    z: 700 + Double(p) * 30 + Double(i), faceUp: true,
                    w: layout.cardW, rot: 0, shadowed: true
                ))
            }
        }
        // Foundations — top two cards per pile.
        // Completed piles flip face down, shrink, and leave the table.
        for (idx, pile) in engine.foundations.enumerated() {
            let visible = Array(pile.cards.suffix(pile.faceDown ? 1 : 2))
            for (k, c) in visible.enumerated() {
                out.append(RC(
                    id: c.id, card: c, pos: layout.foundationSlot(idx),
                    z: 40 + Double(idx) * 2 + Double(k), faceUp: !pile.faceDown,
                    w: pile.vanishing ? layout.fCardW * 0.1 : layout.fCardW,
                    rot: tossAngle(for: c),
                    opacity: pile.vanishing ? 0 : 1,
                    shadowed: k == visible.count - 1
                ))
            }
        }
        // Opponent cards racing in from their seats. A claim aims at its
        // pile (or the ghost slot for a fresh ace) and flies home if beaten.
        for f in engine.flying {
            let slotIdx = f.pileID.flatMap { pid in
                engine.foundations.firstIndex(where: { $0.id == pid })
            } ?? engine.foundations.count
            let atSeat = !f.landed || f.bouncing
            out.append(RC(
                id: f.id, card: f.card,
                pos: atSeat
                    ? layout.seatPos(f.fromSeat).offsetBy(0, 18)
                    : layout.foundationSlot(slotIdx),
                z: 6000, faceUp: true,
                w: atSeat ? layout.fCardW * 0.8 : layout.fCardW,
                rot: atSeat ? 0 : tossAngle(for: f.card),
                flight: true,
                shadowed: true
            ))
        }
        // Cards being dragged track the finger 1:1
        if let d = drag {
            for idx in out.indices where d.unitIDs.contains(out[idx].id) {
                let orderInUnit = d.unit.firstIndex(of: out[idx].card) ?? 0
                if let base = d.bases[out[idx].id] {
                    out[idx].pos = base.adding(d.translation)
                }
                out[idx].z = 8000 + Double(orderInUnit)
                out[idx].dragging = true
                out[idx].w = layout.cardW * 1.06
                out[idx].rot = 1.6
                out[idx].shadowed = true
            }
        }
        return out
    }

    private func cardLayer(_ layout: TableLayout) -> some View {
        ForEach(renderCards(layout)) { rc in
            CardView(card: rc.card, faceUp: rc.faceUp, width: rc.w)
                .rotationEffect(.degrees(rc.rot))
                .shadow(
                    color: .black.opacity(rc.dragging ? 0.38 : (rc.shadowed ? 0.22 : 0)),
                    radius: rc.dragging ? 16 : 4,
                    x: 0,
                    y: rc.dragging ? 12 : 2.5
                )
                .modifier(ShakeEffect(animatableData: CGFloat(engine.shakeTokens[rc.id] ?? 0)))
                .opacity(rc.opacity)
                .position(rc.pos)
                .zIndex(rc.z)
                .onTapGesture { engine.handleTap(on: rc.card) }
                .gesture(dragGesture(for: rc.card, layout: layout))
                .animation(
                    rc.dragging
                        ? nil
                        : (rc.flight
                            ? .spring(response: 0.6, dampingFraction: 0.8)
                            : .spring(response: 0.32, dampingFraction: 0.82)),
                    value: rc.pos
                )
                .animation(.spring(response: 0.34, dampingFraction: 0.82), value: rc.faceUp)
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: rc.w)
                .animation(.easeOut(duration: 0.32), value: rc.opacity)
                .animation(.linear(duration: 0.3), value: engine.shakeTokens[rc.id] ?? 0)
        }
    }

    // MARK: - Dragging

    private func dragGesture(for card: Card, layout: TableLayout) -> some Gesture {
        DragGesture(minimumDistance: 5, coordinateSpace: .named("table"))
            .onChanged { value in
                if drag == nil {
                    guard let (unit, source) = engine.dragUnit(for: card) else { return }
                    var bases: [String: CGPoint] = [:]
                    for rc in renderCards(layout) where unit.contains(rc.card) {
                        bases[rc.id] = rc.pos
                    }
                    drag = DragInfo(
                        unit: unit,
                        source: source,
                        bases: bases,
                        unitIDs: Set(unit.map(\.id)),
                        leadID: card.id
                    )
                    Haptics.lift()
                }
                guard drag?.leadID == card.id else { return }
                drag?.translation = value.translation
                hover = currentTarget(layout)
            }
            .onEnded { _ in
                guard let d = drag, d.leadID == card.id else { return }
                engine.humanDrop(source: d.source, target: currentTarget(layout))
                drag = nil
                hover = nil
            }
    }

    private func currentTarget(_ layout: TableLayout) -> DropTarget? {
        guard let d = drag, let lead = d.unit.first, let base = d.bases[lead.id] else { return nil }
        let point = base.adding(d.translation)

        // Released next to where it was picked up = putting it back.
        guard point.distance(to: base) > layout.cardW * 0.75 else { return nil }

        // The table zone, grown by a full card in every direction (but kept
        // clear of the work row) — the card finds its own pile.
        if d.unit.count == 1 {
            var zone = layout.foundationZone.insetBy(dx: -layout.cardW, dy: 0)
            zone.origin.y -= layout.cardW * 0.9
            zone.size.height += layout.cardW * 0.9
            let maxY = layout.workTopY - layout.cardH / 2 - 8
            zone.size.height = min(zone.size.height + layout.cardW * 0.9, maxY - zone.origin.y)
            if zone.contains(point) {
                return engine.foundationTarget(for: lead)
            }
        }
        // Work pile by geometry, with a wide catch.
        if let wi = layout.workIndex(at: point) {
            return .work(wi)
        }
        // Snap-assist: you clearly moved it — send it to the nearest legal
        // home within about two cards of the release point.
        var best: (target: DropTarget, dist: CGFloat)?
        if d.unit.count == 1, let ft = engine.foundationTarget(for: lead),
           case .foundation(let idx) = ft {
            let slot = idx ?? engine.foundations.count
            let dist = layout.foundationSlot(slot).distance(to: point)
            if dist < (best?.dist ?? .infinity) { best = (ft, dist) }
        }
        for w in 0..<4 where engine.canDrop(d.unit, on: .work(w)) {
            let count = engine.boards.first?.work[w].count ?? 0
            let landing = layout.workCardPos(pile: w, index: count, count: count + 1)
            let dist = landing.distance(to: point)
            if dist < (best?.dist ?? .infinity) { best = (.work(w), dist) }
        }
        // Must be closer to the new home than to where it came from, so a
        // small fumble near the origin still cancels.
        if let best, best.dist < min(layout.cardW * 2.2, point.distance(to: base)) {
            return best.target
        }
        return nil
    }

    // MARK: - Landing pulses

    private func pulseLayer(_ layout: TableLayout) -> some View {
        ForEach(engine.pulses) { pulse in
            if let idx = engine.foundations.firstIndex(where: { $0.id == pulse.pileID }) {
                LandingRing(
                    color: CardPalette.back(for: pulse.owner),
                    cardW: layout.fCardW
                )
                .position(layout.foundationSlot(idx))
                .zIndex(8500)
            }
        }
    }

    // MARK: - Drop-target highlight

    @ViewBuilder
    private func highlightLayer(_ layout: TableLayout) -> some View {
        if let hover, let d = drag {
            let valid = engine.canDrop(d.unit, on: hover)
            let (pos, w): (CGPoint, CGFloat) = {
                switch hover {
                case .foundation(let fi):
                    let slot = fi ?? engine.foundations.count
                    return (layout.foundationSlot(slot), layout.fCardW)
                case .work(let wi):
                    let count = engine.boards.first?.work[wi].count ?? 0
                    let pos = layout.workCardPos(pile: wi, index: max(0, count), count: count + 1)
                    return (pos, layout.cardW)
                }
            }()
            RoundedRectangle(cornerRadius: w * 0.12, style: .continuous)
                .strokeBorder(
                    valid ? Color(hex: 0x7CFFB0) : Color(hex: 0xFF5A4E).opacity(0.7),
                    lineWidth: 2.5
                )
                .frame(width: w + 8, height: w * 1.42 + 8)
                .position(pos)
                .zIndex(9000)
                .allowsHitTesting(false)
        }
    }

    // MARK: - HUD

    @ViewBuilder
    private func hudLayer(_ layout: TableLayout) -> some View {
        // Round + your score, top left
        Text("R\(engine.roundNumber) · You \(engine.scores.first ?? 0)")
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.black.opacity(0.28)))
            .position(x: 58, y: layout.statusY)
            .zIndex(9300)

        // Pause, top right
        Button {
            engine.setPaused(true)
        } label: {
            Image(systemName: "pause.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.black.opacity(0.28)))
        }
        .buttonStyle(.plain)
        .position(x: layout.size.width - 32, y: layout.statusY)
        .zIndex(9300)

        // Stock count
        if let board = engine.boards.first, board.stock.count > 0 {
            Text("\(board.stock.count)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.6))
                .position(layout.stockPos.offsetBy(0, layout.cardH / 2 + 12))
                .zIndex(9100)
        }

        // Nerts pile count badge
        if let board = engine.boards.first, board.nerts.count > 0 {
            Text("\(board.nerts.count)")
                .font(.system(size: 13, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color(hex: 0xD22B20)))
                .overlay(Circle().strokeBorder(.white.opacity(0.7), lineWidth: 1.5))
                .position(layout.nertsPos.offsetBy(-layout.cardW / 2 - 2, -layout.cardH / 2 - 2))
                .zIndex(9100)
        }

        // Undo — one move, bottom left
        Button {
            engine.undoLast()
        } label: {
            Image(systemName: "arrow.uturn.backward")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 44, height: 44)
                .background(Circle().fill(Color.black.opacity(0.30)))
                .overlay(Circle().strokeBorder(.white.opacity(0.15), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!engine.canUndo)
        .opacity(engine.canUndo ? 1 : 0.35)
        .animation(.easeInOut(duration: 0.2), value: engine.canUndo)
        .position(x: layout.wastePos(depth: 1).x, y: layout.bottomRowY - layout.cardH / 2 - 32)
        .zIndex(9350)

        // The big red button
        if engine.nertsReady {
            let leftEdge = layout.wastePos(depth: 2).x - layout.cardW / 2
            NertsButton { engine.callNerts() }
                .position(x: (12 + leftEdge) / 2, y: layout.bottomRowY)
                .zIndex(9400)
                .transition(.scale(scale: 0.6).combined(with: .opacity))
        }

        // Banner toasts
        if let banner = engine.banner {
            Text(banner.text)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(Capsule().fill(Color.black.opacity(0.55)))
                .position(x: layout.size.width / 2, y: layout.foundationTop - 22)
                .zIndex(9500)
                .transition(.move(edge: .top).combined(with: .opacity))
                .id(banner.id)
        }
    }

    // MARK: - Round end

    @ViewBuilder
    private var roundEndOverlay: some View {
        ZStack {
            if engine.phase == .roundEnd, let summary = engine.summary {
                ScoreboardOverlay(engine: engine, summary: summary)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            if engine.paused, engine.phase == .playing {
                PauseOverlay(engine: engine)
                    .transition(.opacity)
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: engine.phase)
        .animation(.easeInOut(duration: 0.22), value: engine.paused)
    }
}
