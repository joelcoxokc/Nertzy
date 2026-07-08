import SwiftUI

/// The online table before cards fly (multiplayer Phase 1): who's
/// seated, who hosts, and a ping button to prove the pipe between
/// devices. Phase 2 replaces the log with an actual deal.
struct LobbyView: View {
    let session: MatchSession
    /// Host only: start the game with this many bot seats.
    var onStart: ((Int) -> Void)? = nil
    let onLeave: () -> Void

    @State private var botCount = 0

    private let seatEmojis = ["🙂", "😎", "🤠", "🥸"]

    private var maxBots: Int { max(0, 4 - session.seats.count) }

    var body: some View {
        ZStack {
            FeltBackground()
            VStack(spacing: 0) {
                Spacer(minLength: 24)
                header
                Spacer(minLength: 20)
                seatList
                if session.waitingFor > 0 {
                    Text("Waiting for \(session.waitingFor) more…")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(.top, 10)
                }
                Spacer(minLength: 16)
                if session.iAmHost, maxBots > 0 {
                    botPicker
                    Spacer(minLength: 14)
                }
                eventLog
                Spacer(minLength: 16)
                if session.iAmHost {
                    dealButton
                    pingButton
                        .padding(.top, 10)
                } else {
                    Text("The host deals the table…")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.65))
                        .padding(.bottom, 10)
                    pingButton
                }
                leaveButton
                    .padding(.top, 14)
                Spacer(minLength: 28)
            }
            .padding(.horizontal, 26)
            .frame(maxWidth: 480)
        }
    }

    // MARK: Host controls

    private var botPicker: some View {
        VStack(spacing: 8) {
            Text("BOTS AT THE TABLE")
                .font(.system(size: 12, weight: .heavy, design: .rounded))
                .tracking(2)
                .foregroundStyle(.white.opacity(0.55))
            HStack(spacing: 10) {
                ForEach(0...maxBots, id: \.self) { n in
                    let selected = botCount == n
                    Button {
                        botCount = n
                        Haptics.flip()
                    } label: {
                        VStack(spacing: 3) {
                            Text(n == 0 ? "—" : AIProfile.roster.prefix(n).map(\.emoji).joined())
                                .font(.system(size: 17))
                            Text("\(n)")
                                .font(.system(size: 17, weight: .heavy, design: .rounded))
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
    }

    private var dealButton: some View {
        Button {
            Haptics.fanfare()
            onStart?(botCount)
        } label: {
            Text("DEAL EVERYONE IN")
                .font(.system(size: 18, weight: .black, design: .rounded))
                .tracking(2)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
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
        .disabled(session.waitingFor > 0 || session.ended)
        .opacity(session.waitingFor > 0 || session.ended ? 0.4 : 1)
    }

    private var header: some View {
        VStack(spacing: 6) {
            Text("ONLINE TABLE")
                .font(.system(size: 34, weight: .black, design: .rounded))
                .tracking(3)
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.4), radius: 8, y: 4)
            Text(session.iAmHost ? "You host this table" : "\(session.seats[session.hostSeat].name) hosts")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.65))
        }
    }

    private var seatList: some View {
        VStack(spacing: 8) {
            ForEach(Array(session.seats.enumerated()), id: \.element.id) { index, seat in
                HStack(spacing: 12) {
                    Text(seatEmojis[index % seatEmojis.count])
                        .font(.system(size: 22))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(seat.isLocal ? "\(seat.name) (you)" : seat.name)
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                        Text(index == session.hostSeat ? "Host · seat \(index + 1)" : "Seat \(index + 1)")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    Spacer()
                    if index == session.hostSeat {
                        Text("👑").font(.system(size: 16))
                    }
                    Circle()
                        .fill(seat.connected ? Color(hex: 0x7CFFB0) : Color(hex: 0xE0443A))
                        .frame(width: 10, height: 10)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(.white.opacity(seat.isLocal ? 0.16 : 0.07))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(.white.opacity(seat.isLocal ? 0.55 : 0.12), lineWidth: 1)
                )
            }
        }
    }

    private var eventLog: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(session.log.suffix(8)) { line in
                Text(line.text)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.black.opacity(0.25))
        )
    }

    private var pingButton: some View {
        Button {
            Haptics.flip()
            session.ping()
        } label: {
            HStack(spacing: 8) {
                Text("🏓 PING")
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .tracking(1.5)
                if let rtt = session.lastRTT {
                    Text(String(format: "%.0f ms", rtt * 1000))
                        .font(.system(size: 13, weight: .heavy, design: .rounded))
                        .foregroundStyle(Color(hex: 0x7CFFB0))
                        .contentTransition(.numericText())
                }
            }
            .foregroundStyle(.white.opacity(0.8))
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(Capsule().fill(.white.opacity(0.08)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.15), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(session.ended)
        .opacity(session.ended ? 0.4 : 1)
    }

    private var leaveButton: some View {
        Button {
            Haptics.nope()
            onLeave()
        } label: {
            Text(session.ended ? "BACK TO MENU" : "LEAVE TABLE")
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
