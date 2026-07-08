import SwiftUI

struct MenuView: View {
    let engine: GameEngine
    let gameCenter: GameCenterManager

    @AppStorage("opponents") private var opponents = 2
    @AppStorage("difficulty") private var difficultyRaw = Difficulty.classic.rawValue
    @AppStorage(GameCenterManager.settingKey) private var gameCenterOn = false
    @State private var showStats = false
    @State private var onlineRoute: OnlineRoute?
    @State private var matchmakingError: String?

    enum OnlineRoute: Identifiable {
        /// The key varies per invite, so a fresh invite re-presents the
        /// sheet even if matchmaking was already up.
        case matchmaking(String)
        case lobby
        var id: String {
            switch self {
            case .matchmaking(let key): return "matchmaking-\(key)"
            case .lobby: return "lobby"
            }
        }
    }

    var body: some View {
        ZStack {
            FeltBackground()
            VStack(spacing: 0) {
                Spacer(minLength: 20)
                titleBlock
                Spacer(minLength: 26)
                VStack(spacing: 24) {
                    titledSection("OPPONENTS") { opponentPicker }
                    titledSection("TABLE SPEED") { difficultyPicker }
                }
                Spacer(minLength: 26)
                dealButton
                playOnlineButton
                    .padding(.top, 12)
                onlineStatusLine
                HStack(spacing: 10) {
                    statsButton
                    gameCenterToggle
                }
                .padding(.top, 14)
                Spacer(minLength: 30)
            }
            .padding(.horizontal, 26)
            .frame(maxWidth: 480)
        }
        .fullScreenCover(isPresented: $showStats) {
            StatsView()
        }
        .fullScreenCover(item: $onlineRoute) { route in
            switch route {
            case .matchmaking:
                MatchmakerView(invite: gameCenter.pendingInvite) { match in
                    let session = MatchSession(match: match)
                    // A guest enters the game the moment the host
                    // announces the seating.
                    session.onTableConfig = { [weak session] config in
                        session?.startAsGuest(engine: engine, config: config)
                    }
                    gameCenter.session = session
                    gameCenter.pendingInvite = nil
                    onlineRoute = .lobby
                } onEnd: { error in
                    gameCenter.pendingInvite = nil
                    matchmakingError = error
                    onlineRoute = nil
                }
                .ignoresSafeArea()
            case .lobby:
                if let session = gameCenter.session {
                    LobbyView(
                        session: session,
                        onStart: { bots in
                            session.startAsHost(
                                engine: engine,
                                botCount: bots,
                                difficulty: Difficulty(rawValue: difficultyRaw) ?? .classic
                            )
                        },
                        onLeave: {
                            session.leave()
                            gameCenter.session = nil
                            onlineRoute = nil
                        }
                    )
                }
            }
        }
        .onChange(of: gameCenter.pendingInvite) { _, invite in
            // A friend's invite pulls the menu straight into matchmaking.
            if let invite, gameCenter.session == nil {
                onlineRoute = .matchmaking(invite.sender.gamePlayerID)
            }
        }
        .onChange(of: engine.phase) { _, phase in
            // The game took over — the lobby's job is done.
            if phase != .menu {
                onlineRoute = nil
                showStats = false
            }
        }
        .onAppear {
            // Back at the menu: a dead session has nothing left to offer.
            if let session = gameCenter.session, session.ended {
                gameCenter.session = nil
            }
        }
    }

    // MARK: Title

    private var titleBlock: some View {
        VStack(spacing: 16) {
            ZStack {
                CardView(card: Card(owner: 1, suit: .spades, rank: 1), faceUp: true, width: 62)
                    .rotationEffect(.degrees(-14))
                    .offset(x: -46, y: 8)
                    .shadow(color: .black.opacity(0.3), radius: 8, y: 5)
                CardView(card: Card(owner: 2, suit: .diamonds, rank: 13), faceUp: true, width: 62)
                    .rotationEffect(.degrees(13))
                    .offset(x: 46, y: 8)
                    .shadow(color: .black.opacity(0.3), radius: 8, y: 5)
                CardView(card: Card(owner: 0, suit: .hearts, rank: 1), faceUp: true, width: 62)
                    .shadow(color: .black.opacity(0.35), radius: 10, y: 6)
            }
            .frame(height: 104)
            VStack(spacing: 6) {
                Text("NERTZY")
                    .font(.system(size: 56, weight: .black, design: .rounded))
                    .tracking(5)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.4), radius: 8, y: 4)
                Text("The fastest card game in the world")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.65))
            }
        }
    }

    // MARK: Options

    private var opponentPicker: some View {
        HStack(spacing: 10) {
            ForEach(1...3, id: \.self) { n in
                let selected = opponents == n
                Button {
                    opponents = n
                    Haptics.flip()
                } label: {
                    VStack(spacing: 4) {
                        Text(AIProfile.roster.prefix(n).map(\.emoji).joined())
                            .font(.system(size: 19))
                        Text("\(n)")
                            .font(.system(size: 21, weight: .heavy, design: .rounded))
                            .foregroundStyle(.white)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(.white.opacity(selected ? 0.20 : 0.07))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(
                                .white.opacity(selected ? 0.85 : 0.12),
                                lineWidth: selected ? 2 : 1
                            )
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var difficultyPicker: some View {
        VStack(spacing: 8) {
            ForEach(Difficulty.allCases) { d in
                let selected = difficultyRaw == d.rawValue
                Button {
                    difficultyRaw = d.rawValue
                    Haptics.flip()
                } label: {
                    HStack(spacing: 12) {
                        Text(d.emoji).font(.system(size: 22))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(d.label)
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                            Text(d.blurb)
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(.white.opacity(0.55))
                        }
                        Spacer()
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 20))
                            .foregroundStyle(selected ? Color(hex: 0x7CFFB0) : .white.opacity(0.25))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(.white.opacity(selected ? 0.18 : 0.07))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(
                                .white.opacity(selected ? 0.85 : 0.12),
                                lineWidth: selected ? 2 : 1
                            )
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Deal

    private var dealButton: some View {
        Button {
            engine.settings = GameSettings(
                opponents: opponents,
                difficulty: Difficulty(rawValue: difficultyRaw) ?? .classic
            )
            Haptics.fanfare()
            engine.newMatch()
        } label: {
            Text("DEAL ME IN")
                .font(.system(size: 20, weight: .black, design: .rounded))
                .tracking(2)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 17)
                .background(
                    Capsule().fill(LinearGradient(
                        colors: [Color(hex: 0xE0443A), Color(hex: 0xB4271E)],
                        startPoint: .top, endPoint: .bottom
                    ))
                )
                .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 1.5))
                .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
        }
        .buttonStyle(.plain)
    }

    // MARK: Online (multiplayer Phase 1)

    private var canPlayOnline: Bool {
        gameCenterOn && gameCenter.auth == .authenticated
    }

    private var playOnlineButton: some View {
        Button {
            Haptics.fanfare()
            matchmakingError = nil
            onlineRoute = .matchmaking("auto")
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "wifi")
                    .font(.system(size: 15, weight: .black))
                Text(gameCenterOn && gameCenter.auth == .authenticating ? "CONNECTING…" : "PLAY ONLINE")
                    .font(.system(size: 17, weight: .black, design: .rounded))
                    .tracking(2)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                Capsule().fill(LinearGradient(
                    colors: [Color(hex: 0x2E6BE6), Color(hex: 0x1E4FB8)],
                    startPoint: .top, endPoint: .bottom
                ))
            )
            .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 1.5))
            .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
        }
        .buttonStyle(.plain)
        .disabled(!canPlayOnline)
        .opacity(canPlayOnline ? 1 : 0.4)
    }

    @ViewBuilder
    private var onlineStatusLine: some View {
        if let message = statusMessage {
            Text(message)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(statusIsError ? Color(hex: 0xFF9C93) : .white.opacity(0.55))
                .padding(.top, 8)
        }
    }

    private var statusMessage: String? {
        if let matchmakingError { return matchmakingError }
        guard gameCenterOn else { return "Turn on Game Center to play online" }
        switch gameCenter.auth {
        case .failed(let reason): return reason
        case .authenticated: return "Signed in as \(gameCenter.localName)"
        default: return nil
        }
    }

    private var statusIsError: Bool {
        if matchmakingError != nil { return true }
        if case .failed = gameCenter.auth { return true }
        return false
    }

    private var gameCenterToggle: some View {
        Button {
            Haptics.flip()
            gameCenterOn.toggle()
            matchmakingError = nil
            if gameCenterOn { gameCenter.authenticate() }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "gamecontroller.fill")
                    .font(.system(size: 12, weight: .bold))
                Text("GAME CENTER")
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .tracking(1.5)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Image(systemName: gameCenterOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(gameCenterOn ? Color(hex: 0x7CFFB0) : .white.opacity(0.35))
            }
            .foregroundStyle(.white.opacity(0.75))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Capsule().fill(.white.opacity(0.08)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.15), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var statsButton: some View {
        Button {
            Haptics.flip()
            showStats = true
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "trophy.fill")
                    .font(.system(size: 12, weight: .bold))
                Text("YOUR RECORD")
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .tracking(1.5)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .foregroundStyle(.white.opacity(0.75))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Capsule().fill(.white.opacity(0.08)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.15), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
