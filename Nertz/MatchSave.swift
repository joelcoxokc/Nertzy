import SwiftUI
import Observation

// MARK: - Resuming a solo match

/// The shared table, frozen. Built by `LocalTableAuthority.snapshot()`.
struct TableSnapshot: Codable {
    var scores: [Int]
    var roundNumber: Int
    var foundations: [FoundationPile]
    var retired: [Card]
    var nextPileID: Int
    var matchToken: UUID
    var summary: RoundSummary?
}

/// A solo match frozen mid-flight: enough to reopen the app and pick up
/// exactly where the table stood. Online play never saves — a dead
/// connection can't be resumed, and the host owns the truth anyway.
struct MatchSnapshot: Codable {
    var settings: GameSettings
    var boards: [PlayerBoard]
    var table: TableSnapshot
    /// The scoreboard was up when the app went away.
    var atScoreboard: Bool
    /// The app died mid-deal — the half-dealt boards aren't worth
    /// keeping; resume re-deals the round (scores still restore).
    var midDeal: Bool
}

/// The one saved match on disk, observable so the menu's CONTINUE
/// button appears and disappears on its own.
@MainActor
@Observable
final class MatchSaver {
    static let shared = MatchSaver()

    private(set) var saved: MatchSnapshot?
    @ObservationIgnored private let fileURL: URL

    private init() {
        let dir = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        fileURL = dir.appendingPathComponent("resume.json")
        if let data = try? Data(contentsOf: fileURL) {
            saved = try? JSONDecoder().decode(MatchSnapshot.self, from: data)
        }
    }

    func save(_ snapshot: MatchSnapshot) {
        saved = snapshot
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    func clear() {
        saved = nil
        try? FileManager.default.removeItem(at: fileURL)
    }
}
