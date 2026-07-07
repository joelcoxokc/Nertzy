import SwiftUI

/// Pure geometry for the table. Every pile, slot, and seat maps to a point in
/// the "table" coordinate space so all cards can live on one canvas and every
/// movement is a real animated position change.
struct TableLayout {
    let size: CGSize
    let playerCount: Int    // includes you

    // MARK: Card size — one size for every card on the table

    var fGap: CGFloat { 8 }
    var cardW: CGFloat { min((size.width - 12 - 5 * fGap) / 6, 64) }
    var cardH: CGFloat { cardW * 1.42 }
    var fCardW: CGFloat { cardW }
    var fCardH: CGFloat { cardH }

    // MARK: Foundation grid

    var capacity: Int { 4 * playerCount }
    var fCols: Int { 6 }
    var fRows: Int { Int(ceil(Double(capacity) / Double(fCols))) }

    // MARK: Vertical anchors

    var statusY: CGFloat { 18 }
    var seatY: CGFloat { 62 }
    var foundationTop: CGFloat { 104 }
    var foundationBottom: CGFloat { foundationTop + CGFloat(fRows) * (fCardH + fGap) - fGap }
    var workTopY: CGFloat { foundationBottom + 40 + cardH / 2 }
    var bottomRowY: CGFloat { size.height - cardH / 2 - 12 }
    var fanBottomLimit: CGFloat { bottomRowY - cardH - 8 }

    /// Generous hit region for "just drop it on the table" foundation plays.
    var foundationZone: CGRect {
        let gridW = CGFloat(fCols) * (fCardW + fGap) - fGap
        return CGRect(
            x: (size.width - gridW) / 2 - 20,
            y: foundationTop - 34,
            width: gridW + 40,
            height: foundationBottom - foundationTop + 68
        )
    }

    // MARK: Player columns — work piles left, nerts pile at the right thumb

    var colGap: CGFloat { (size.width - 24 - 5 * cardW) / 4 }
    func colX(_ i: Int) -> CGFloat { 12 + cardW / 2 + CGFloat(i) * (cardW + colGap) }

    var nertsPos: CGPoint { CGPoint(x: colX(4), y: workTopY) }
    func workBase(_ i: Int) -> CGPoint { CGPoint(x: colX(i), y: workTopY) }

    func workCardPos(pile: Int, index: Int, count: Int) -> CGPoint {
        let base = workBase(pile)
        guard count > 1 else { return base }
        let span = min(CGFloat(count - 1) * 24, max(0, fanBottomLimit - workTopY))
        let step = span / CGFloat(count - 1)
        return base.offsetBy(0, CGFloat(index) * step)
    }

    var stockPos: CGPoint { CGPoint(x: colX(4), y: bottomRowY) }

    /// depth 0 = top card (closest to the stock), deeper cards fan left.
    func wastePos(depth: Int) -> CGPoint {
        let d = CGFloat(min(depth, 2))
        return CGPoint(x: stockPos.x - cardW - 14 - d * 19, y: bottomRowY)
    }

    // MARK: Foundations

    func rowWidth(_ row: Int) -> CGFloat {
        let inRow = min(fCols, capacity - row * fCols)
        return CGFloat(inRow) * (fCardW + fGap) - fGap
    }

    func foundationSlot(_ i: Int) -> CGPoint {
        let row = i / fCols
        let col = i % fCols
        let x = (size.width - rowWidth(row)) / 2 + fCardW / 2 + CGFloat(col) * (fCardW + fGap)
        let y = foundationTop + fCardH / 2 + CGFloat(row) * (fCardH + fGap)
        return CGPoint(x: x, y: y)
    }

    // MARK: Seats

    func seatPos(_ seat: Int) -> CGPoint {
        let n = playerCount - 1
        return CGPoint(x: size.width * CGFloat(seat) / CGFloat(n + 1), y: seatY)
    }

    // MARK: Hit testing

    func workIndex(at p: CGPoint) -> Int? {
        guard p.y > foundationBottom + fCardH * 0.7 else { return nil }
        var best: (index: Int, dist: CGFloat)?
        for i in 0..<4 {
            let d = abs(workBase(i).x - p.x)
            if d < (best?.dist ?? .infinity) { best = (i, d) }
        }
        guard let best, best.dist < (cardW + colGap) * 0.75 else { return nil }
        return best.index
    }
}
