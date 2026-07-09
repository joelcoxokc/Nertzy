import SwiftUI

/// Pure geometry for the table. Your tableau hugs the bottom of the screen,
/// the middle is open felt where foundation piles sit wherever they were
/// tossed, and opponents are pinned to the left/top/right edges. Every pile,
/// slot, and seat maps to a point in the "table" coordinate space so all
/// cards live on one canvas and every movement is a real animated position
/// change.
struct TableLayout {
    let size: CGSize
    let playerCount: Int    // includes you

    // MARK: Card size — one size for every card on the table

    var cardW: CGFloat { min(size.width * 0.12, 56) }
    var cardH: CGFloat { cardW * 1.42 }

    // MARK: Vertical anchors

    var statusY: CGFloat { 18 }
    var bottomRowY: CGFloat { size.height - cardH / 2 - 12 }
    var workTopY: CGFloat { size.height - cardH * 3.35 }

    // MARK: The open table — piles land wherever they're tossed

    /// Pile spots are stored normalized (0...1 each way) and mapped into
    /// this rect, so a scatter survives any screen size.
    var scatterZone: CGRect {
        let sideInset = 48 + cardW / 2          // clear of the edge badges
        let top = 84 + cardH / 2                // below the HUD
        let bottom = workTopY - cardH * 1.35    // clear of your work row
        return CGRect(
            x: sideInset,
            y: top,
            width: size.width - sideInset * 2,
            height: max(cardH, bottom - top)
        )
    }

    func scatterPoint(_ spot: CGPoint) -> CGPoint {
        CGPoint(
            x: scatterZone.minX + spot.x * scatterZone.width,
            y: scatterZone.minY + spot.y * scatterZone.height
        )
    }

    func scatterSpot(at p: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max((p.x - scatterZone.minX) / max(scatterZone.width, 1), 0), 1),
            y: min(max((p.y - scatterZone.minY) / max(scatterZone.height, 1), 0), 1)
        )
    }

    // MARK: Player columns — work piles hug the left, nerts pile at the right thumb

    var colGap: CGFloat { 12 }
    func colX(_ i: Int) -> CGFloat { 12 + cardW / 2 + CGFloat(i) * (cardW + colGap) }
    var rightColX: CGFloat { size.width - 12 - cardW / 2 }

    var nertsPos: CGPoint { CGPoint(x: rightColX, y: workTopY) }
    func workBase(_ i: Int) -> CGPoint { CGPoint(x: colX(i), y: workTopY) }

    /// How deep a column's fan may run. The raised waste hangs over the
    /// right end of the fan zone, so a column beneath it stops higher.
    func fanBottomLimit(_ pile: Int) -> CGFloat {
        let wasteLeft = wastePos(depth: 2).x - cardW / 2
        return colX(pile) + cardW / 2 >= wasteLeft - 6
            ? wasteY - cardH - 8
            : bottomRowY - cardH - 8
    }

    func workCardPos(pile: Int, index: Int, count: Int) -> CGPoint {
        let base = workBase(pile)
        guard count > 1 else { return base }
        let span = min(CGFloat(count - 1) * 30, max(0, fanBottomLimit(pile) - workTopY))
        let step = span / CGFloat(count - 1)
        return base.offsetBy(0, CGFloat(index) * step)
    }

    var stockPos: CGPoint { CGPoint(x: rightColX, y: bottomRowY) }

    /// The waste rides above the undo/pause row, clear of the screen bottom.
    var wasteY: CGFloat { size.height - 60 - cardH / 2 }

    /// depth 0 = top card (closest to the stock), deeper cards fan left —
    /// spread wide enough that each buried card's left-edge rank shows.
    func wastePos(depth: Int) -> CGPoint {
        let d = CGFloat(min(depth, 2))
        return CGPoint(x: stockPos.x - cardW - 14 - d * 28, y: wasteY)
    }

    // MARK: Buttons — undo and pause tucked under the waste fan

    var buttonRowY: CGFloat { size.height - 32 }
    var undoPos: CGPoint { CGPoint(x: wastePos(depth: 1).x + 27, y: buttonRowY) }
    var pausePos: CGPoint { CGPoint(x: wastePos(depth: 1).x - 27, y: buttonRowY) }

    // MARK: Seats — bare nerts-count badges pinned to the table edges

    func seatPos(_ seat: Int) -> CGPoint {
        let top = CGPoint(x: size.width / 2, y: 46)
        let left = CGPoint(x: 26, y: scatterZone.midY)
        let right = CGPoint(x: size.width - 26, y: scatterZone.midY)
        let spots: [CGPoint]
        switch playerCount - 1 {
        case 1: spots = [top]
        case 2: spots = [left, right]
        default: spots = [left, top, right]
        }
        return spots[min(max(seat - 1, 0), spots.count - 1)]
    }

    /// Where an opponent's card enters the table — just inside their badge,
    /// so the card is never hidden behind it.
    func seatLaunchPos(_ seat: Int) -> CGPoint {
        let p = seatPos(seat)
        if p.x < size.width * 0.25 { return p.offsetBy(36, 0) }
        if p.x > size.width * 0.75 { return p.offsetBy(-36, 0) }
        return p.offsetBy(0, 38)
    }

    // MARK: Hit testing

    func workIndex(at p: CGPoint) -> Int? {
        guard p.y > workTopY - cardH * 1.1 else { return nil }
        var best: (index: Int, dist: CGFloat)?
        for i in 0..<4 {
            let d = abs(workBase(i).x - p.x)
            if d < (best?.dist ?? .infinity) { best = (i, d) }
        }
        guard let best, best.dist < (cardW + colGap) * 0.75 else { return nil }
        return best.index
    }
}
