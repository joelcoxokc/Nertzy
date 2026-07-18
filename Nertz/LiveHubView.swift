import SwiftUI

/// The way into an in-person night: open a table (real cards, the app
/// keeps score) or tap a friend's table from the nearby list. Once a
/// room exists, this cover IS the scoreboard.
struct LiveHubView: View {
    let session: LiveSession
    let onClose: () -> Void

    @AppStorage("liveTargetScore") private var targetScore = 100
    @State private var myName = LiveIdentity.myName
    @State private var myEmoji = LiveIdentity.myEmoji
    @FocusState private var nameFocused: Bool

    var body: some View {
        ZStack {
            FeltBackground()
            if session.role != .none {
                LiveScoreboardView(session: session, onExit: onClose)
            } else {
                hubBody
            }
        }
        .onAppear {
            // Browsing doubles as the local-network permission moment —
            // better here than mid-join.
            if session.role == .none { session.startBrowsing() }
        }
        .onDisappear {
            if session.role == .none { session.stopBrowsing() }
        }
    }

    private var hubBody: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                Spacer(minLength: 22)
                Text("IN PERSON")
                    .font(.system(size: 34, weight: .black, design: .rounded))
                    .tracking(3)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.4), radius: 8, y: 4)
                Text("Real cards on a real table — the app keeps score")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.top, 5)
                Spacer(minLength: 24)
                VStack(spacing: 20) {
                    titledSection("YOU") { youRow }
                    if let save = LiveSaver.shared.saved {
                        titledSection("PICK BACK UP") { continueRow(save) }
                    }
                    titledSection("HOST A TABLE") { hostSection }
                    titledSection("JOIN A TABLE") { joinSection }
                }
                Spacer(minLength: 20)
                bottomButtons
                Spacer(minLength: 28)
            }
            .padding(.horizontal, 26)
        }
        .frame(maxWidth: 480)
    }

    // MARK: You

    private var youRow: some View {
        HStack(spacing: 10) {
            Button {
                let pool = LiveIdentity.emojiPool
                let next = ((pool.firstIndex(of: myEmoji) ?? 0) + 1) % pool.count
                myEmoji = pool[next]
                LiveIdentity.myEmoji = myEmoji
                Haptics.flip()
            } label: {
                Text(myEmoji)
                    .font(.system(size: 24))
                    .frame(width: 48, height: 48)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(.white.opacity(0.08))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(.white.opacity(0.15), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            TextField("Your name", text: $myName)
                .focused($nameFocused)
                .autocorrectionDisabled()
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .frame(height: 48)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.black.opacity(0.25))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(.white.opacity(nameFocused ? 0.5 : 0.12), lineWidth: 1)
                )
                .onChange(of: myName) { _, name in
                    LiveIdentity.myName = name
                }
        }
    }

    // MARK: Continue

    private func continueRow(_ save: LiveSave) -> some View {
        HStack(spacing: 8) {
            Button {
                Haptics.fanfare()
                session.resume(save)
            } label: {
                VStack(spacing: 2) {
                    Text(save.isHost ? "REOPEN YOUR TABLE" : "REJOIN THE TABLE")
                        .font(.system(size: 15, weight: .black, design: .rounded))
                        .tracking(1.5)
                    Text(save.match.summaryLine)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .opacity(0.8)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    Capsule().fill(LinearGradient(
                        colors: [Color(hex: 0x35C963), Color(hex: 0x1E9B47)],
                        startPoint: .top, endPoint: .bottom
                    ))
                )
                .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 1.5))
            }
            .buttonStyle(.plain)
            Button {
                Haptics.nope()
                LiveSaver.shared.clear()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(.white.opacity(0.08)))
                    .overlay(Circle().strokeBorder(.white.opacity(0.15), lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Host

    private var hostSection: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                ForEach(GameSettings.targetChoices, id: \.self) { n in
                    let selected = targetScore == n
                    Button {
                        targetScore = n
                        Haptics.flip()
                    } label: {
                        VStack(spacing: 3) {
                            Text("PLAY TO")
                                .font(.system(size: 8, weight: .heavy, design: .rounded))
                                .tracking(1)
                                .foregroundStyle(.white.opacity(0.5))
                            Text("\(n)")
                                .font(.system(size: 20, weight: .heavy, design: .rounded))
                                .foregroundStyle(.white)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(.white.opacity(selected ? 0.20 : 0.07))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(.white.opacity(selected ? 0.85 : 0.12), lineWidth: selected ? 2 : 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            Button {
                Haptics.fanfare()
                nameFocused = false
                session.host(targetScore: targetScore)
            } label: {
                Text("OPEN THE TABLE")
                    .font(.system(size: 17, weight: .black, design: .rounded))
                    .tracking(2)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        Capsule().fill(LinearGradient(
                            colors: [Color(hex: 0xE0862A), Color(hex: 0xB4611B)],
                            startPoint: .top, endPoint: .bottom
                        ))
                    )
                    .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 1.5))
            }
            .buttonStyle(.plain)
            Text("Friends join from this screen — paper players\n(no phone) get added at the table.")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.5))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
    }

    // MARK: Join

    private var joinSection: some View {
        VStack(spacing: 8) {
            if session.nearby.isEmpty {
                HStack(spacing: 10) {
                    ProgressView().tint(.white)
                    Text("Looking around the room…")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(.white.opacity(0.05))
                )
            } else {
                ForEach(session.nearby) { table in
                    Button {
                        Haptics.fanfare()
                        session.join(table)
                    } label: {
                        HStack(spacing: 12) {
                            Text("🎴").font(.system(size: 22))
                            Text("\(table.hostName)'s table")
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            Spacer()
                            Text("JOIN")
                                .font(.system(size: 12, weight: .black, design: .rounded))
                                .tracking(1)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .background(Capsule().fill(Color(hex: 0x1E9B47)))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(.white.opacity(0.08))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(.white.opacity(0.15), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Bottom

    private var bottomButtons: some View {
        VStack(spacing: 10) {
            ShareLink(item: "Nertz night! Get Nertzy, then tap IN PERSON → your name shows up at my table.") {
                HStack(spacing: 7) {
                    Image(systemName: "message.fill")
                        .font(.system(size: 12, weight: .bold))
                    Text("INVITE FRIENDS TO GET THE APP")
                        .font(.system(size: 12, weight: .heavy, design: .rounded))
                        .tracking(1.5)
                }
                .foregroundStyle(.white.opacity(0.6))
                .padding(.horizontal, 18)
                .padding(.vertical, 9)
                .background(Capsule().fill(.white.opacity(0.06)))
                .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
            }
            .buttonStyle(.plain)
            Button {
                Haptics.nope()
                onClose()
            } label: {
                Text("BACK")
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .tracking(1.5)
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(.horizontal, 22)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(.white.opacity(0.08)))
                    .overlay(Capsule().strokeBorder(.white.opacity(0.15), lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
    }
}
