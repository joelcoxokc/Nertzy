import Foundation
import GameKit
import Observation

// MARK: - Wire protocol

/// Tiny Codable messages over GKMatch `.reliable` — MULTIPLAYER.md's
/// protocol sketch. JSON on the wire: tens of bytes, readable in logs.
/// Phase 1 carries the handshake and echo test; Phase 2 adds claims,
/// nerts counts, and round lifecycle.
enum NetMessage: Codable {
    case hello(name: String)
    case ping(id: UUID)
    case pong(id: UUID)

    func encoded() -> Data? { try? JSONEncoder().encode(self) }
    static func decode(_ data: Data) -> NetMessage? {
        try? JSONDecoder().decode(NetMessage.self, from: data)
    }
}

// MARK: - Seats

/// One chair at an online table.
struct OnlineSeat: Identifiable {
    let id: String          // gamePlayerID — identical on every device
    let name: String
    let isLocal: Bool
    var connected = true
}

// MARK: - A live match

/// A found GKMatch: the seat map, connection state, and (for Phase 1)
/// the echo test that proves the pipe. Phase 2 plugs this into the
/// TableAuthority seam.
@MainActor
@Observable
final class MatchSession {

    private(set) var seats: [OnlineSeat] = []
    private(set) var log: [LogLine] = []
    private(set) var lastRTT: Double?          // seconds, from the last pong
    private(set) var waitingFor = 0            // players still connecting
    private(set) var ended = false

    struct LogLine: Identifiable {
        let id: Int
        let text: String
    }

    @ObservationIgnored private let match: GKMatch
    @ObservationIgnored private var bridge: MatchBridge?
    @ObservationIgnored private var logCounter = 0
    @ObservationIgnored private var pendingPings: [UUID: Date] = [:]

    /// Deterministic seating: every device sorts the same gamePlayerIDs
    /// the same way, so the whole table agrees on seat order — and on
    /// the host (seat 0, lowest id) — without a negotiation message.
    var mySeat: Int { seats.firstIndex(where: \.isLocal) ?? 0 }
    var hostSeat: Int { 0 }
    var iAmHost: Bool { mySeat == hostSeat }

    init(match: GKMatch) {
        self.match = match
        var all = match.players.map {
            OnlineSeat(id: $0.gamePlayerID, name: $0.displayName, isLocal: false)
        }
        all.append(OnlineSeat(
            id: GKLocalPlayer.local.gamePlayerID,
            name: GKLocalPlayer.local.displayName,
            isLocal: true
        ))
        seats = all.sorted { $0.id < $1.id }
        waitingFor = match.expectedPlayerCount
        let bridge = MatchBridge(session: self)
        self.bridge = bridge
        match.delegate = bridge
        addLog(waitingFor > 0
            ? "Table found — waiting for \(waitingFor) more"
            : "Table ready — \(seats.count) seated")
        send(.hello(name: GKLocalPlayer.local.displayName))
    }

    // MARK: Actions

    func ping() {
        let id = UUID()
        pendingPings[id] = Date()
        send(.ping(id: id))
        addLog("🏓 ping sent")
    }

    func leave() {
        guard !ended else { return }
        match.delegate = nil
        match.disconnect()
        ended = true
    }

    private func send(_ message: NetMessage) {
        guard let data = message.encoded() else { return }
        do {
            try match.sendData(toAllPlayers: data, with: .reliable)
        } catch {
            addLog("⚠️ send failed: \(error.localizedDescription)")
        }
    }

    // MARK: Events (from the bridge, on the main actor)

    func received(_ data: Data, fromName name: String) {
        guard let message = NetMessage.decode(data) else {
            addLog("⚠️ \(data.count) undecodable bytes from \(name)")
            return
        }
        switch message {
        case .hello(let n):
            addLog("👋 \(n) is at the table")
        case .ping(let id):
            send(.pong(id: id))
            addLog("📨 ping from \(name) — answered")
        case .pong(let id):
            if let sentAt = pendingPings.removeValue(forKey: id) {
                let rtt = Date().timeIntervalSince(sentAt)
                lastRTT = rtt
                addLog(String(format: "🏓 pong from %@ — %.0f ms round trip", name, rtt * 1000))
            }
        }
    }

    func playerChanged(id: String, name: String, connected: Bool) {
        if let i = seats.firstIndex(where: { $0.id == id }) {
            seats[i].connected = connected
            addLog(connected ? "🟢 \(name) connected" : "🔴 \(name) left the table")
        } else if connected {
            // A player whose connection completed after the match formed.
            seats.append(OnlineSeat(id: id, name: name, isLocal: false))
            seats.sort { $0.id < $1.id }
            addLog("🟢 \(name) joined")
        }
        waitingFor = match.expectedPlayerCount
    }

    func failed(_ message: String) {
        addLog("⚠️ \(message)")
        ended = true
    }

    private func addLog(_ text: String) {
        logCounter += 1
        log.append(LogLine(id: logCounter, text: text))
        if log.count > 24 { log.removeFirst(log.count - 24) }
    }
}

/// GKMatchDelegate needs an NSObject; this bridge keeps MatchSession a
/// plain @Observable class and hops every callback onto the main actor.
private final class MatchBridge: NSObject, GKMatchDelegate {
    weak var session: MatchSession?

    init(session: MatchSession) {
        self.session = session
    }

    func match(_ match: GKMatch, didReceive data: Data, fromRemotePlayer player: GKPlayer) {
        let name = player.displayName
        Task { @MainActor [weak session] in
            session?.received(data, fromName: name)
        }
    }

    func match(_ match: GKMatch, player: GKPlayer, didChange state: GKPlayerConnectionState) {
        let id = player.gamePlayerID
        let name = player.displayName
        let connected = state == .connected
        Task { @MainActor [weak session] in
            session?.playerChanged(id: id, name: name, connected: connected)
        }
    }

    func match(_ match: GKMatch, didFailWithError error: Error?) {
        let message = error?.localizedDescription ?? "Connection failed"
        Task { @MainActor [weak session] in
            session?.failed(message)
        }
    }
}
