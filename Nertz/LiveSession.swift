import Foundation
import MultipeerConnectivity
import Observation
import UIKit

// MARK: - The room, on the air
//
// Host-authoritative with full-snapshot sync: guests send tiny commands,
// the host applies them to the one true LiveMatch and rebroadcasts the
// whole thing (a few KB). Snapshots are idempotent, so ordering races,
// reconnects, and late joiners all heal by themselves — which matters,
// because iOS drops MultipeerConnectivity sessions every time a phone
// naps, and at a card table phones nap constantly. Guests queue unsent
// commands and re-apply them on top of adopted snapshots until the host
// echoes them back.

/// Everything that crosses the wire.
enum LiveMessage: Codable {
    /// guest → host, on every (re)connect: who I am, what I've seen.
    case hello(player: LivePlayer, revision: Int)
    /// guest → host: one cell of the card (nil entry = clear it).
    /// callerClaim: true = I went out, false = I un-claimed it.
    case submit(round: Int, playerID: String, entry: LiveEntry?, callerClaim: Bool?)
    /// host → all: the whole truth.
    case snapshot(LiveMatch)
}

@MainActor
@Observable
final class LiveSession: NSObject {
    enum Role { case none, host, guest }

    private(set) var role: Role = .none
    var match: LiveMatch?
    private(set) var myPlayerID = ""

    /// Tables in the room, for the hub's join list.
    struct NearbyTable: Identifiable, Equatable {
        let peer: MCPeerID
        let roomID: String
        let hostName: String
        var id: String { roomID }
        static func == (a: Self, b: Self) -> Bool { a.roomID == b.roomID && a.peer == b.peer }
    }
    private(set) var nearby: [NearbyTable] = []
    private(set) var browsing = false

    /// Someone tapped the host's table — the host okays them in.
    struct JoinRequest: Identifiable {
        let player: LivePlayer
        let decide: (Bool) -> Void
        var id: String { player.id }
    }
    private(set) var joinRequests: [JoinRequest] = []

    /// Guest-side: is the host's device currently on the line?
    private(set) var hostConnected = false
    /// Host-side: how many guest devices are on the line.
    private(set) var connectedPeers = 0

    // MARK: Radios

    @ObservationIgnored private var myPeer = MCPeerID(displayName: UIDevice.current.name)
    @ObservationIgnored private var mcSession: MCSession?
    @ObservationIgnored private var advertiser: MCNearbyServiceAdvertiser?
    @ObservationIgnored private var browser: MCNearbyServiceBrowser?
    @ObservationIgnored private var hostPeer: MCPeerID?
    /// The advertised room. Stable across PLAY AGAIN rematches, so
    /// guests keep following the same table into fresh matches.
    @ObservationIgnored private var roomID: String?
    /// The table a rejoining guest auto-joins when it reappears.
    @ObservationIgnored private var wantedRoomID: String?
    /// Guest: I've seen myself on this table's card — so a later
    /// snapshot without me means the host took me off, not that my
    /// hello hasn't landed yet.
    @ObservationIgnored private var wasSeated = false
    /// Guest commands the host hasn't echoed back yet.
    @ObservationIgnored private var pending: [LiveMessage] = []
    /// One quiet knock after a lapsed invite; a denial isn't nagged.
    @ObservationIgnored private var inviteRetries = 0
    /// peer → the player it claimed in its hello (host bookkeeping).
    @ObservationIgnored private var peerPlayers: [MCPeerID: String] = [:]

    private static let serviceType = "nertzy-score"
    private static let maxGuests = 7    // MCSession's 8-peer ceiling, minus the host

    // MARK: - Opening a table (host)

    func host(targetScore: Int) {
        let me = LiveIdentity.me
        var fresh = LiveMatch.fresh(host: me, targetScore: targetScore)
        fresh.revision = 1
        roomID = UUID().uuidString
        adopt(role: .host, match: fresh, myID: me.id)
        goOnAir()
    }

    /// Reopen the saved room (host) or the saved view of one (guest —
    /// starts hunting for the host's table again).
    func resume(_ save: LiveSave) {
        roomID = save.roomID ?? save.match.id.uuidString
        adopt(role: save.isHost ? .host : .guest, match: save.match, myID: save.myPlayerID)
        if save.isHost {
            goOnAir()
        } else {
            wasSeated = save.match.player(save.myPlayerID) != nil
            wantedRoomID = roomID
            startBrowsing()
        }
    }

    private func adopt(role: Role, match: LiveMatch, myID: String) {
        self.role = role
        self.match = match
        myPlayerID = myID
        persist()
    }

    // MARK: - Finding a table (guest)

    func startBrowsing() {
        guard browser == nil else { return }
        browsing = true
        let b = MCNearbyServiceBrowser(peer: myPeer, serviceType: Self.serviceType)
        b.delegate = self
        b.startBrowsingForPeers()
        browser = b
    }

    func stopBrowsing() {
        browser?.stopBrowsingForPeers()
        browser = nil
        browsing = false
        nearby = []
    }

    func join(_ table: NearbyTable) {
        let me = LiveIdentity.me
        role = .guest
        myPlayerID = me.id
        roomID = table.roomID
        wantedRoomID = table.roomID
        wasSeated = false
        inviteRetries = 0
        invite(table.peer, as: me)
    }

    private func invite(_ peer: MCPeerID, as player: LivePlayer) {
        let session = ensureSession()
        let context = try? JSONEncoder().encode(player)
        browser?.invitePeer(peer, to: session, withContext: context, timeout: 20)
    }

    // MARK: - The host's side of the handshake

    private func goOnAir() {
        guard role == .host, let match else { return }
        _ = ensureSession()
        advertiser?.stopAdvertisingPeer()
        let ad = MCNearbyServiceAdvertiser(
            peer: myPeer,
            discoveryInfo: ["room": roomID ?? match.id.uuidString, "host": match.hostName],
            serviceType: Self.serviceType
        )
        ad.delegate = self
        ad.startAdvertisingPeer()
        advertiser = ad
    }

    func approve(_ request: JoinRequest, allow: Bool) {
        joinRequests.removeAll { $0.id == request.id }
        request.decide(allow)
        if allow, var m = match {
            m.add(player: request.player)
            m.update(player: request.player)    // rejoiner with a fresh emoji/name
            commit(m)
        }
    }

    // MARK: - Scoring (both roles call these; guests relay to the host)

    func submit(entry: LiveEntry?, player playerID: String, round: Int, callerClaim: Bool? = nil) {
        apply(.submit(round: round, playerID: playerID, entry: entry, callerClaim: callerClaim))
    }

    func addPaperPlayer(named name: String, emoji: String) {
        guard role == .host, var m = match else { return }
        m.add(player: LivePlayer(id: m.paperID(for: name), name: name, emoji: emoji, isPaper: true))
        commit(m)
    }

    func closeRound() {
        guard role == .host, var m = match else { return }
        m.closeOpenRound()
        commit(m)
    }

    func finish() {
        guard role == .host, var m = match else { return }
        m.finish()
        commit(m)
        LiveRecorder.recordIfNeeded(m, myPlayerID: myPlayerID)
    }

    /// Same table, same people, fresh card. The advertised room doesn't
    /// change, so guests ride the next snapshot straight into the new
    /// match (and nappers rejoin by the same room id).
    func playAgain() {
        guard role == .host, let old = match, old.finished != nil else { return }
        match = old.rematch()
        persist()
        broadcastSnapshot()
    }

    /// Host takes someone off the card — device or paper. A round that
    /// was only waiting on them can close now.
    func removePlayer(_ playerID: String) {
        guard role == .host, var m = match else { return }
        m.remove(playerID: playerID)
        autoCloseIfFull(&m)
        commit(m)
    }

    /// One door for cell changes. The host applies straight to the
    /// truth; a guest applies optimistically, queues, and sends.
    private func apply(_ message: LiveMessage) {
        guard case .submit = message, var m = match else { return }
        Self.land(message, on: &m)
        if role == .host {
            autoCloseIfFull(&m)
            commit(m)
        } else {
            match = m           // optimistic — the echo confirms it
            pending.append(message)
            persist()
            flushPending()
        }
    }

    /// Land one submit on a match — entry plus caller claim, the same
    /// way everywhere (host truth, guest optimism, pending re-apply).
    private static func land(_ message: LiveMessage, on m: inout LiveMatch) {
        guard case .submit(let round, let playerID, let entry, let callerClaim) = message else { return }
        m.apply(entry: entry, player: playerID, round: round)
        guard let callerClaim else { return }
        if callerClaim {
            m.setCaller(playerID, round: round)
        } else if m.rounds.indices.contains(round), m.rounds[round].caller == playerID {
            m.setCaller(nil, round: round)
        }
    }

    /// Every seat filled = the line gets drawn (host rule).
    private func autoCloseIfFull(_ m: inout LiveMatch) {
        if let open = m.openRoundIndex,
           m.players.allSatisfy({ m.rounds[open].entries[$0.id] != nil }) {
            m.closeOpenRound()
        }
    }

    /// Host: bump, save, broadcast. The one exit for every mutation.
    private func commit(_ m: LiveMatch) {
        guard role == .host else { return }
        var next = m
        next.revision += 1
        match = next
        persist()
        broadcastSnapshot()
    }

    // MARK: - Ending / leaving

    /// Walk away from the room screen. The host's room is revivable from
    /// disk (or already recorded, if finished); a guest keeps its last
    /// look at the board unless the night ended properly.
    func leaveRoom() {
        if match?.finished != nil { LiveSaver.shared.clear() }
        wantedRoomID = nil      // a deliberate leave stops auto-rejoin
        tearDownRadios()
        role = .none
        match = nil
        myPlayerID = ""
        roomID = nil
        wasSeated = false
        pending = []
    }

    private func tearDownRadios() {
        advertiser?.stopAdvertisingPeer()
        advertiser = nil
        stopBrowsing()
        mcSession?.disconnect()
        mcSession = nil
        hostPeer = nil
        peerPlayers = [:]
        joinRequests = []
        hostConnected = false
        connectedPeers = 0
    }

    /// Foreground re-entry: iOS killed the radios while the app napped —
    /// quietly put the room back on the air / go find it again.
    func rearmIfNeeded() {
        guard match != nil, match?.finished == nil else { return }
        switch role {
        case .host:
            goOnAir()
        case .guest:
            if !hostConnected { startBrowsing() }
        case .none:
            break
        }
    }

    /// Dev demo rooms stay off the disk.
    @ObservationIgnored private var saveEnabled = true

    private func persist() {
        guard saveEnabled, let match else { return }
        LiveSaver.shared.save(LiveSave(
            match: match, myPlayerID: myPlayerID, isHost: role == .host, roomID: roomID
        ))
    }

    // MARK: - Dev

    /// A staged game night for `-livedemo` screenshots: six players (two
    /// paper), seven rounds on the card, grandma one hot round from 100.
    func debugSeedDemo() {
        saveEnabled = false
        let me = LiveIdentity.me
        var m = LiveMatch.fresh(
            host: LivePlayer(id: me.id, name: "Joel", emoji: "🙂", isPaper: false),
            targetScore: 100
        )
        m.add(player: LivePlayer(id: "demo:sarah", name: "Sarah", emoji: "🦊", isPaper: false))
        m.add(player: LivePlayer(id: "demo:mike", name: "Mike", emoji: "🐻", isPaper: false))
        m.add(player: LivePlayer(id: "demo:lily", name: "Lily", emoji: "🐸", isPaper: false))
        m.add(player: LivePlayer(id: "paper:grandma", name: "Grandma", emoji: "🦉", isPaper: true))
        m.add(player: LivePlayer(id: "paper:dre", name: "Dre", emoji: "🐯", isPaper: true))
        let ids = m.players.map(\.id)
        let deltas: [[Int]] = [
            [12, 15, -4, 7, 10, -2],
            [8, 12, 6, 9, 14, 5],
            [15, 10, 8, -6, 12, 7],
            [-4, 13, 5, 11, 9, 3],
            [11, 9, -2, 8, 15, 6],
            [9, 16, 7, 5, 13, -8],
            [14, 12, 10, 6, 18, 9],
        ]
        let callers = ["demo:sarah", "paper:grandma", me.id, "demo:sarah", "paper:grandma", "demo:sarah", "paper:grandma"]
        for (r, row) in deltas.enumerated() {
            if r > 0 { m.rounds.append(LiveRound()) }
            for (i, d) in row.enumerated() {
                // A few counted entries so the demo shows both doors.
                m.rounds[r].entries[ids[i]] = (i + r) % 3 == 0 && d > 4
                    ? .counted(table: d + 4, nertzLeft: 2)
                    : .direct(total: d)
            }
            m.rounds[r].caller = callers[r]
            m.rounds[r].closed = true
        }
        m.rounds.append(LiveRound())
        m.rounds[7].entries[me.id] = .counted(table: 16, nertzLeft: 3)
        m.rounds[7].entries["demo:sarah"] = .direct(total: 12)
        m.rounds[7].entries["paper:dre"] = .direct(total: -4)
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-livefinished") || args.contains("-liverecordtest") {
            // Grandma's hot round carries her over 100 — night over.
            m.rounds[7].entries["demo:mike"] = .direct(total: 8)
            m.rounds[7].entries["demo:lily"] = .direct(total: 6)
            m.rounds[7].entries["paper:grandma"] = .counted(table: 16, nertzLeft: 2)
            m.rounds[7].caller = "paper:grandma"
            m.closeOpenRound()
            m.finish()
        }
        m.revision = 40
        role = .host
        match = m
        myPlayerID = me.id
        if args.contains("-liverecordtest") {
            LiveRecorder.recordIfNeeded(m, myPlayerID: me.id)
        }
        // Exercise the host-only doors screenshots can't tap into.
        if args.contains("-liveplayagain") { playAgain() }
        if args.contains("-liveremove") { removePlayer("demo:mike") }
    }

    // MARK: - Wire plumbing

    private func ensureSession() -> MCSession {
        if let mcSession { return mcSession }
        let s = MCSession(peer: myPeer, securityIdentity: nil, encryptionPreference: .required)
        s.delegate = self
        mcSession = s
        return s
    }

    private func send(_ message: LiveMessage, to peers: [MCPeerID]) {
        guard let mcSession, !peers.isEmpty,
              let data = try? JSONEncoder().encode(message) else { return }
        try? mcSession.send(data, toPeers: peers, with: .reliable)
    }

    private func broadcastSnapshot() {
        guard role == .host, let match, let mcSession else { return }
        send(.snapshot(match), to: mcSession.connectedPeers)
    }

    private func flushPending() {
        guard role == .guest, hostConnected, let hostPeer else { return }
        for message in pending { send(message, to: [hostPeer]) }
    }

    /// Guest: take the host's word for it, then re-apply anything of
    /// mine the host hasn't echoed yet.
    private func adoptSnapshot(_ snapshot: LiveMatch) {
        guard role == .guest || role == .none else { return }
        if let current = match, snapshot.id == current.id {
            guard snapshot.revision >= current.revision else { return }
        } else {
            // A different match under the same room — PLAY AGAIN.
            // Cells queued for the old card don't carry over.
            pending = []
        }
        var m = snapshot
        pending.removeAll { message in
            guard case .submit(let round, let playerID, let entry, _) = message else { return true }
            return m.rounds.indices.contains(round) && m.rounds[round].entries[playerID] == entry
        }
        for message in pending {
            Self.land(message, on: &m)
        }
        if m.player(myPlayerID) != nil {
            wasSeated = true
        } else if wasSeated {
            // The host took me off the card — bow out to the hub.
            // (Never fires on the first snapshot racing my hello.)
            LiveSaver.shared.clear()
            leaveRoom()
            return
        }
        match = m
        persist()
        if m.finished != nil {
            LiveRecorder.recordIfNeeded(m, myPlayerID: myPlayerID)
        }
    }

    // MARK: Host-side message handling

    private func received(_ message: LiveMessage, from peer: MCPeerID) {
        switch message {
        case .hello(let player, _):
            guard role == .host, var m = match else { return }
            peerPlayers[peer] = player.id
            m.add(player: player)
            m.update(player: player)
            commit(m)   // also snapshots the newcomer up to date
        case .submit(let round, let playerID, let entry, let callerClaim):
            guard role == .host else { return }
            // Friendly-table trust, but stay in your lane: your own
            // column or a paper player's. The host edits from its own UI.
            let sender = peerPlayers[peer]
            let target = match?.player(playerID)
            guard sender == playerID || target?.isPaper == true else { return }
            apply(.submit(round: round, playerID: playerID, entry: entry, callerClaim: callerClaim))
        case .snapshot(let snapshot):
            guard peer == hostPeer || role == .guest else { return }
            adoptSnapshot(snapshot)
        }
    }
}

// MARK: - MC delegates (callbacks arrive off-main; hop before touching state)

extension LiveSession: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        let peerCount = session.connectedPeers.count
        Task { @MainActor in
            switch state {
            case .connected:
                if self.role == .guest {
                    self.hostPeer = peerID
                    self.hostConnected = true
                    self.inviteRetries = 0
                    self.stopBrowsing()
                    self.send(.hello(player: LiveIdentity.me, revision: self.match?.revision ?? 0), to: [peerID])
                    self.flushPending()
                } else if self.role == .host {
                    self.connectedPeers = peerCount
                    self.broadcastSnapshot()
                }
            case .notConnected:
                if self.role == .guest, peerID == self.hostPeer {
                    self.hostConnected = false
                    // The table's still out there — listen for its return.
                    if self.match?.finished == nil { self.startBrowsing() }
                } else if self.role == .guest, self.hostPeer == nil {
                    // The invite lapsed before the host okayed it (or
                    // failed outright) — knock again while the table's
                    // still on the air.
                    if self.inviteRetries < 1,
                       let wanted = self.wantedRoomID,
                       let table = self.nearby.first(where: { $0.roomID == wanted }) {
                        self.inviteRetries += 1
                        self.invite(table.peer, as: LiveIdentity.me)
                    }
                } else if self.role == .host {
                    self.connectedPeers = peerCount
                    self.peerPlayers[peerID] = nil
                }
            default:
                break
            }
        }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let message = try? JSONDecoder().decode(LiveMessage.self, from: data) else { return }
        Task { @MainActor in
            self.received(message, from: peerID)
        }
    }

    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

extension LiveSession: MCNearbyServiceAdvertiserDelegate {
    nonisolated func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser,
        didReceiveInvitationFromPeer peerID: MCPeerID,
        withContext context: Data?,
        invitationHandler: @escaping (Bool, MCSession?) -> Void
    ) {
        Task { @MainActor in
            guard self.role == .host, let m = self.match else {
                invitationHandler(false, nil)
                return
            }
            guard let context,
                  let player = try? JSONDecoder().decode(LivePlayer.self, from: context),
                  !player.isPaper
            else {
                invitationHandler(false, nil)
                return
            }
            let session = self.ensureSession()
            guard session.connectedPeers.count < Self.maxGuests else {
                invitationHandler(false, nil)
                return
            }
            // A familiar face reconnecting walks right back in.
            if m.player(player.id) != nil {
                self.peerPlayers[peerID] = player.id
                invitationHandler(true, session)
                return
            }
            self.joinRequests.removeAll { $0.id == player.id }
            self.joinRequests.append(JoinRequest(player: player) { [weak self] allow in
                guard let self else { return }
                if allow { self.peerPlayers[peerID] = player.id }
                invitationHandler(allow, allow ? self.mcSession : nil)
            })
        }
    }
}

extension LiveSession: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        guard let info, let roomID = info["room"], let hostName = info["host"] else { return }
        Task { @MainActor in
            let table = NearbyTable(peer: peerID, roomID: roomID, hostName: hostName)
            self.nearby.removeAll { $0.roomID == roomID }
            self.nearby.append(table)
            // The table I belong to came back — rejoin without a tap.
            if roomID == self.wantedRoomID, self.role == .guest, !self.hostConnected {
                self.invite(peerID, as: LiveIdentity.me)
            }
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        Task { @MainActor in
            self.nearby.removeAll { $0.peer == peerID }
        }
    }
}
