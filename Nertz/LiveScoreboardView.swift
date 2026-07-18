import SwiftUI

/// The table's scorecard, live on every device: standings up top, the
/// classic paper grid below (rows = rounds, newest first). Tap your own
/// cell — or any paper player's — to score a round; the host can tap
/// anything, any round, all night.
struct LiveScoreboardView: View {
    let session: LiveSession
    /// Leave the cover entirely (back to the menu).
    let onExit: () -> Void

    private struct EditTarget: Identifiable {
        let playerID: String
        let round: Int
        var id: String { "\(playerID)-\(round)" }
    }

    @State private var editing: EditTarget?
    @State private var showAddPlayer = false
    @State private var confirmEnd = false
    @State private var removing: LivePlayer?

    private let labelW: CGFloat = 36
    private let colW: CGFloat = 76
    private let rowH: CGFloat = 46

    var body: some View {
        ZStack {
            FeltBackground()
            if let match = session.match {
                board(match)
                if match.finished != nil {
                    finishedOverlay(match)
                }
            } else {
                joiningBody
            }
        }
        .sheet(item: $editing) { target in
            if let match = session.match,
               let player = match.player(target.playerID),
               match.rounds.indices.contains(target.round) {
                LiveEntrySheet(
                    player: player,
                    roundNumber: target.round + 1,
                    existing: match.rounds[target.round].entries[target.playerID],
                    existingCaller: match.rounds[target.round].caller == target.playerID,
                    isMe: target.playerID == session.myPlayerID,
                    onSave: { entry, callerClaim in
                        session.submit(
                            entry: entry,
                            player: target.playerID,
                            round: target.round,
                            callerClaim: callerClaim
                        )
                    }
                )
            }
        }
        .sheet(isPresented: $showAddPlayer) {
            AddPaperPlayerSheet { name, emoji in
                session.addPaperPlayer(named: name, emoji: emoji)
            }
        }
        .onAppear {
            // Dev: pop the entry sheet for screenshots (simctl can't tap).
            let args = ProcessInfo.processInfo.arguments
            if let match = session.match, let open = match.openRoundIndex {
                if args.contains("-liveentry") {
                    editing = EditTarget(playerID: session.myPlayerID, round: open)
                } else if args.contains("-liveentrytotal") {
                    editing = EditTarget(playerID: "demo:sarah", round: open)
                }
            }
        }
        .confirmationDialog(
            "End the night?",
            isPresented: $confirmEnd,
            titleVisibility: .visible
        ) {
            Button("END & SAVE TO RECORDS", role: .destructive) {
                Haptics.fanfare()
                session.finish()
            }
            Button("Keep playing", role: .cancel) {}
        } message: {
            Text("Scores lock in and everyone's record book gets the night.")
        }
        .confirmationDialog(
            removing.map { "Take \($0.name) off the card?" } ?? "",
            isPresented: Binding(
                get: { removing != nil },
                set: { if !$0 { removing = nil } }
            ),
            titleVisibility: .visible,
            presenting: removing
        ) { player in
            Button("REMOVE \(player.name.uppercased())", role: .destructive) {
                Haptics.nope()
                session.removePlayer(player.id)
            }
            Button("Keep them", role: .cancel) {}
        } message: { _ in
            Text("They come off the card now — if they rejoin later, their column comes back, scores and all.")
        }
    }

    // MARK: The board

    private func board(_ match: LiveMatch) -> some View {
        VStack(spacing: 0) {
            topBar(match)
            standingsStrip(match)
                .padding(.top, 4)
            scorecard(match)
                .padding(.top, 10)
            if let request = session.joinRequests.first {
                joinRequestCard(request)
                    .padding(.horizontal, 22)
                    .padding(.bottom, 8)
            }
            if match.finished == nil {
                if let championID = match.champion, let champ = match.player(championID) {
                    championCard(champ, match: match)
                        .padding(.horizontal, 22)
                        .padding(.bottom, 8)
                }
                bottomBar(match)
            }
        }
    }

    private func topBar(_ match: LiveMatch) -> some View {
        HStack(spacing: 10) {
            Button {
                Haptics.nope()
                onExit()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .black))
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(10)
                    .background(Circle().fill(.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(match.hostName.uppercased())'S TABLE")
                    .font(.system(size: 17, weight: .black, design: .rounded))
                    .tracking(1.5)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(statusLine(match))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
            }
            Spacer()
            Text("PLAY TO \(match.targetScore)")
                .font(.system(size: 11, weight: .heavy, design: .rounded))
                .tracking(1)
                .foregroundStyle(.white.opacity(0.7))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(.white.opacity(0.08)))
        }
        .padding(.horizontal, 22)
        .padding(.top, 16)
    }

    private func statusLine(_ match: LiveMatch) -> String {
        switch session.role {
        case .host:
            let devices = session.connectedPeers + 1
            return "\(match.players.count) players · \(devices) device\(devices == 1 ? "" : "s")"
        case .guest:
            return session.hostConnected ? "at the table" : "looking for the host…"
        case .none:
            return ""
        }
    }

    // MARK: Standings

    private func standingsStrip(_ match: LiveMatch) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(match.standings) { p in
                    let total = match.total(for: p.id)
                    VStack(spacing: 2) {
                        Text("\(p.emoji) \(p.name)")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                        Text("\(total)")
                            .font(.system(size: 26, weight: .black, design: .rounded))
                            .foregroundStyle(total < 0 ? Color(hex: 0xFF9C93) : .white)
                    }
                    .frame(minWidth: 74)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(.white.opacity(p.id == session.myPlayerID ? 0.14 : 0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(.white.opacity(p.id == session.myPlayerID ? 0.4 : 0.1), lineWidth: 1)
                    )
                }
            }
            .padding(.horizontal, 22)
        }
    }

    // MARK: Scorecard grid

    private func scorecard(_ match: LiveMatch) -> some View {
        let rows = Array(match.rounds.enumerated()).reversed()
        return ScrollView(showsIndicators: false) {
            HStack(alignment: .top, spacing: 0) {
                // Round numbers stay put while players scroll sideways.
                VStack(spacing: 6) {
                    Color.clear.frame(width: labelW, height: 30)
                    ForEach(rows, id: \.offset) { index, _ in
                        Text("R\(index + 1)")
                            .font(.system(size: 11, weight: .heavy, design: .rounded))
                            .foregroundStyle(.white.opacity(index == match.openRoundIndex ? 0.9 : 0.4))
                            .frame(width: labelW, height: rowH)
                    }
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    VStack(spacing: 6) {
                        HStack(spacing: 6) {
                            ForEach(match.players) { p in
                                let removable = session.role == .host
                                    && p.id != match.hostID
                                    && match.finished == nil
                                Button {
                                    Haptics.flip()
                                    removing = p
                                } label: {
                                    VStack(spacing: 0) {
                                        Text(p.emoji).font(.system(size: 14))
                                        Text(p.name)
                                            .font(.system(size: 10, weight: .bold, design: .rounded))
                                            .foregroundStyle(.white.opacity(0.65))
                                            .lineLimit(1)
                                            .minimumScaleFactor(0.7)
                                    }
                                    .frame(width: colW, height: 30)
                                }
                                .buttonStyle(.plain)
                                .disabled(!removable)
                            }
                        }
                        ForEach(rows, id: \.offset) { index, round in
                            HStack(spacing: 6) {
                                ForEach(match.players) { p in
                                    cell(match, round: round, index: index, player: p)
                                }
                            }
                        }
                    }
                    .padding(.trailing, 22)
                }
            }
            .padding(.leading, 12)
            .padding(.bottom, 16)
        }
    }

    private func canEdit(_ match: LiveMatch, player: LivePlayer) -> Bool {
        guard match.finished == nil else { return false }
        return session.role == .host || player.isPaper || player.id == session.myPlayerID
    }

    private func cell(_ match: LiveMatch, round: LiveRound, index: Int, player: LivePlayer) -> some View {
        let entry = round.entries[player.id]
        let open = index == match.openRoundIndex
        let editable = canEdit(match, player: player)
        return Button {
            Haptics.flip()
            editing = EditTarget(playerID: player.id, round: index)
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.white.opacity(open ? 0.10 : 0.045))
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.white.opacity(open ? 0.30 : 0.07), lineWidth: 1)
                if let entry {
                    Text(signedText(entry.delta))
                        .font(.system(size: 17, weight: .heavy, design: .rounded))
                        .foregroundStyle(
                            entry.delta < 0
                                ? Color(hex: 0xFF9C93)
                                : .white.opacity(open ? 1 : 0.8)
                        )
                } else if open && editable {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .black))
                        .foregroundStyle(.white.opacity(0.55))
                } else {
                    Text(open ? "·" : "—")
                        .font(.system(size: 15, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white.opacity(0.25))
                }
            }
            .frame(width: colW, height: rowH)
        }
        .buttonStyle(.plain)
        .disabled(!editable)
    }

    // MARK: Host approvals

    private func joinRequestCard(_ request: LiveSession.JoinRequest) -> some View {
        HStack(spacing: 10) {
            Text(request.player.emoji).font(.system(size: 22))
            Text("\(request.player.name) wants in")
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer()
            Button {
                Haptics.fanfare()
                session.approve(request, allow: true)
            } label: {
                Text("LET IN")
                    .font(.system(size: 12, weight: .black, design: .rounded))
                    .tracking(1)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color(hex: 0x1E9B47)))
            }
            .buttonStyle(.plain)
            Button {
                Haptics.nope()
                session.approve(request, allow: false)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(9)
                    .background(Circle().fill(.white.opacity(0.1)))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(hex: 0x123A24))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.2), lineWidth: 1)
        )
    }

    // MARK: Champion + bottom controls

    private func championCard(_ champ: LivePlayer, match: LiveMatch) -> some View {
        HStack(spacing: 10) {
            Text("🏆").font(.system(size: 24))
            VStack(alignment: .leading, spacing: 1) {
                Text("\(champ.name.uppercased()) CROSSED \(match.targetScore)")
                    .font(.system(size: 13, weight: .black, design: .rounded))
                    .tracking(0.5)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(session.role == .host ? "Fix any scores, then finish the night." : "Waiting for the host to finish the night.")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.6))
            }
            Spacer()
            if session.role == .host {
                Button {
                    Haptics.fanfare()
                    session.finish()
                } label: {
                    Text("FINISH")
                        .font(.system(size: 13, weight: .black, design: .rounded))
                        .tracking(1)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .background(
                            Capsule().fill(LinearGradient(
                                colors: [Color(hex: 0xFFB03A), Color(hex: 0xE0862A)],
                                startPoint: .top, endPoint: .bottom
                            ))
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(hex: 0x2E5A1E).opacity(0.9))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color(hex: 0xFFD166).opacity(0.5), lineWidth: 1.5)
        )
    }

    private func bottomBar(_ match: LiveMatch) -> some View {
        HStack(spacing: 8) {
            if session.role == .host {
                bottomPill("ADD PLAYER", icon: "plus") {
                    showAddPlayer = true
                }
                bottomPill("CLOSE ROUND", icon: "checkmark") {
                    Sound.play(.deal)
                    session.closeRound()
                }
                bottomPill("END NIGHT", icon: "flag.checkered") {
                    confirmEnd = true
                }
            } else {
                Text("Scores land on everyone's card the moment they're saved.")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.45))
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 14)
    }

    private func bottomPill(_ label: String, icon: String, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.flip()
            action()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .black))
                Text(label)
                    .font(.system(size: 12, weight: .heavy, design: .rounded))
                    .tracking(0.5)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(.white.opacity(0.85))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(Capsule().fill(.white.opacity(0.09)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.15), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: Finished

    private func finishedOverlay(_ match: LiveMatch) -> some View {
        ZStack {
            Color.black.opacity(0.65).ignoresSafeArea()
            ConfettiView(particleCount: match.winnerID == nil ? 0 : 120)
            VStack(spacing: 16) {
                if let winnerID = match.winnerID, let winner = match.player(winnerID) {
                    Text("🏆").font(.system(size: 54))
                    Text("\(winner.name.uppercased()) WINS THE NIGHT")
                        .font(.system(size: 24, weight: .black, design: .rounded))
                        .tracking(1.5)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                } else {
                    Text("🌙").font(.system(size: 54))
                    Text("THAT'S THE NIGHT")
                        .font(.system(size: 24, weight: .black, design: .rounded))
                        .tracking(2)
                        .foregroundStyle(.white)
                }
                VStack(spacing: 6) {
                    ForEach(match.standings) { p in
                        HStack {
                            Text("\(p.emoji) \(p.name)")
                                .font(.system(size: 15, weight: .bold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.85))
                            Spacer()
                            Text("\(match.total(for: p.id))")
                                .font(.system(size: 17, weight: .black, design: .rounded))
                                .foregroundStyle(.white)
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(.white.opacity(p.id == match.winnerID ? 0.16 : 0.06))
                        )
                    }
                }
                .frame(maxWidth: 300)
                Text("Saved to your record")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
                if session.role == .host {
                    Button {
                        Haptics.fanfare()
                        Sound.play(.deal)
                        session.playAgain()
                    } label: {
                        Text("PLAY AGAIN")
                            .font(.system(size: 17, weight: .black, design: .rounded))
                            .tracking(2)
                            .foregroundStyle(.white)
                            .frame(maxWidth: 220)
                            .padding(.vertical, 13)
                            .background(
                                Capsule().fill(LinearGradient(
                                    colors: [Color(hex: 0x35C963), Color(hex: 0x1E9B47)],
                                    startPoint: .top, endPoint: .bottom
                                ))
                            )
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                    Text("Same table, fresh card — everyone stays seated.")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.45))
                }
                Button {
                    Haptics.fanfare()
                    session.leaveRoom()
                    onExit()
                } label: {
                    if session.role == .host {
                        // Quiet next to PLAY AGAIN, which owns the moment.
                        Text("DONE — CLOSE THE TABLE")
                            .font(.system(size: 13, weight: .black, design: .rounded))
                            .tracking(1.5)
                            .foregroundStyle(.white.opacity(0.75))
                            .frame(maxWidth: 220)
                            .padding(.vertical, 10)
                            .background(Capsule().fill(.white.opacity(0.08)))
                            .overlay(Capsule().strokeBorder(.white.opacity(0.15), lineWidth: 1))
                    } else {
                        Text("DONE")
                            .font(.system(size: 17, weight: .black, design: .rounded))
                            .tracking(2)
                            .foregroundStyle(.white)
                            .frame(maxWidth: 220)
                            .padding(.vertical, 13)
                            .background(
                                Capsule().fill(LinearGradient(
                                    colors: [Color(hex: 0x35C963), Color(hex: 0x1E9B47)],
                                    startPoint: .top, endPoint: .bottom
                                ))
                            )
                    }
                }
                .buttonStyle(.plain)
                .padding(.top, session.role == .host ? 2 : 4)
            }
            .padding(30)
        }
    }

    // MARK: Guest, pre-snapshot

    private var joiningBody: some View {
        VStack(spacing: 16) {
            ProgressView()
                .tint(.white)
                .scaleEffect(1.4)
            Text("PULLING UP A CHAIR…")
                .font(.system(size: 15, weight: .black, design: .rounded))
                .tracking(2)
                .foregroundStyle(.white.opacity(0.8))
            Text("The host okays you in and the card appears.")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.5))
            Button {
                Haptics.nope()
                session.leaveRoom()
                onExit()
            } label: {
                Text("CANCEL")
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .tracking(1.5)
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(.horizontal, 22)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .padding(.top, 10)
        }
    }
}

// MARK: - Adding a paper player (host)

/// Someone at the table with no phone in the game — they still get a
/// column; anyone can key their rounds in.
struct AddPaperPlayerSheet: View {
    let onAdd: (String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var emojiIndex = 3
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(spacing: 16) {
            Text("ADD A PLAYER")
                .font(.system(size: 16, weight: .black, design: .rounded))
                .tracking(2)
                .foregroundStyle(.white)
            Text("No phone needed — anyone at the table\ncan key their scores in.")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
            HStack(spacing: 10) {
                Button {
                    emojiIndex = (emojiIndex + 1) % LiveIdentity.emojiPool.count
                    Haptics.flip()
                } label: {
                    Text(LiveIdentity.emojiPool[emojiIndex])
                        .font(.system(size: 26))
                        .frame(width: 52, height: 52)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(.white.opacity(0.08))
                        )
                }
                .buttonStyle(.plain)
                TextField("Name", text: $name)
                    .focused($nameFocused)
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .frame(height: 52)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(.black.opacity(0.25))
                    )
            }
            Button {
                Haptics.fanfare()
                onAdd(name.trimmingCharacters(in: .whitespaces), LiveIdentity.emojiPool[emojiIndex])
                dismiss()
            } label: {
                Text("DEAL THEM IN")
                    .font(.system(size: 15, weight: .black, design: .rounded))
                    .tracking(1.5)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(
                        Capsule().fill(LinearGradient(
                            colors: [Color(hex: 0x35C963), Color(hex: 0x1E9B47)],
                            startPoint: .top, endPoint: .bottom
                        ))
                    )
            }
            .buttonStyle(.plain)
            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            .opacity(name.trimmingCharacters(in: .whitespaces).isEmpty ? 0.4 : 1)
        }
        .padding(24)
        .presentationDetents([.height(260)])
        .presentationBackground(Color(hex: 0x0E2417))
        .presentationDragIndicator(.visible)
        .onAppear { nameFocused = true }
    }
}
