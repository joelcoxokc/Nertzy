import SwiftUI
import GameKit

/// The way into an online table: create one and read the code out
/// loud, or type a friend's code. Apple's friend-invite sheet remains
/// as a fallback — codes need no friending and no invite plumbing.
struct OnlineHubView: View {
    let onMatch: (GKMatch) -> Void
    let onInvites: () -> Void
    let onClose: () -> Void

    private enum HubState: Equatable {
        case idle
        case hosting(code: String)
        case joining(code: String)
    }

    @State private var state: HubState = .idle
    @State private var humans = 2
    @State private var joinCode = ""
    @State private var errorText: String?
    @FocusState private var codeFieldFocused: Bool

    var body: some View {
        ZStack {
            FeltBackground()
            VStack(spacing: 0) {
                Spacer(minLength: 24)
                Text("PLAY ONLINE")
                    .font(.system(size: 34, weight: .black, design: .rounded))
                    .tracking(3)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.4), radius: 8, y: 4)
                Spacer(minLength: 24)
                switch state {
                case .idle:
                    idleBody
                case .hosting(let code):
                    searchingBody(
                        title: "YOUR TABLE CODE",
                        code: code,
                        hint: "Tell your friends — they tap JOIN WITH CODE.\nThe table opens when \(TableCode.humans(in: code) ?? 2) players are looking."
                    )
                case .joining(let code):
                    searchingBody(
                        title: "JOINING TABLE",
                        code: code,
                        hint: "Waiting for everyone to arrive…"
                    )
                }
                Spacer(minLength: 20)
                if let errorText {
                    Text(errorText)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color(hex: 0xFF9C93))
                        .padding(.bottom, 10)
                }
                bottomButtons
                Spacer(minLength: 28)
            }
            .padding(.horizontal, 26)
            .frame(maxWidth: 480)
        }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { CodeMatchmaker.cancel() }
    }

    // MARK: Idle — choose your door

    private var idleBody: some View {
        VStack(spacing: 22) {
            titledSection("CREATE A TABLE") {
                VStack(spacing: 12) {
                    HStack(spacing: 10) {
                        ForEach(2...4, id: \.self) { n in
                            let selected = humans == n
                            Button {
                                humans = n
                                Haptics.flip()
                            } label: {
                                VStack(spacing: 3) {
                                    Text("\(n)")
                                        .font(.system(size: 20, weight: .heavy, design: .rounded))
                                        .foregroundStyle(.white)
                                    Text("humans")
                                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                                        .foregroundStyle(.white.opacity(0.55))
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 9)
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
                        startHosting()
                    } label: {
                        Text("GET A CODE")
                            .font(.system(size: 17, weight: .black, design: .rounded))
                            .tracking(2)
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
                    }
                    .buttonStyle(.plain)
                    Text("Bots can still fill empty seats in the lobby.")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }

            titledSection("JOIN WITH CODE") {
                VStack(spacing: 12) {
                    TextField("KQJZ3", text: $joinCode)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .keyboardType(.asciiCapable)
                        .focused($codeFieldFocused)
                        .font(.system(size: 24, weight: .black, design: .rounded))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(.black.opacity(0.25))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(.white.opacity(codeFieldFocused ? 0.5 : 0.15), lineWidth: 1)
                        )
                    Button {
                        Haptics.fanfare()
                        startJoining()
                    } label: {
                        Text("JOIN")
                            .font(.system(size: 17, weight: .black, design: .rounded))
                            .tracking(2)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(
                                Capsule().fill(LinearGradient(
                                    colors: [Color(hex: 0x35C963), Color(hex: 0x1E9B47)],
                                    startPoint: .top, endPoint: .bottom
                                ))
                            )
                            .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                    .disabled(TableCode.humans(in: TableCode.normalize(joinCode)) == nil)
                    .opacity(TableCode.humans(in: TableCode.normalize(joinCode)) == nil ? 0.4 : 1)
                }
            }
        }
    }

    // MARK: Searching — big code, patient spinner

    private func searchingBody(title: String, code: String, hint: String) -> some View {
        VStack(spacing: 18) {
            Text(title)
                .font(.system(size: 13, weight: .heavy, design: .rounded))
                .tracking(2)
                .foregroundStyle(.white.opacity(0.55))
            Text(code)
                .font(.system(size: 58, weight: .black, design: .rounded))
                .tracking(10)
                .foregroundStyle(.white)
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(.black.opacity(0.28))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(.white.opacity(0.2), lineWidth: 1.5)
                )
            ProgressView()
                .tint(.white)
                .scaleEffect(1.3)
                .padding(.top, 6)
            Text(hint)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
        }
    }

    // MARK: Actions

    private func startHosting() {
        errorText = nil
        let code = TableCode.generate(humans: humans)
        state = .hosting(code: code)
        search(code: code)
    }

    private func startJoining() {
        errorText = nil
        let code = TableCode.normalize(joinCode)
        guard TableCode.humans(in: code) != nil else {
            errorText = "Codes look like KQJZ3 — four letters and the table size"
            return
        }
        codeFieldFocused = false
        state = .joining(code: code)
        search(code: code)
    }

    private func search(code: String) {
        CodeMatchmaker.start(code: code) { match in
            onMatch(match)
        } onError: { message in
            errorText = message
            state = .idle
        }
    }

    private var bottomButtons: some View {
        VStack(spacing: 10) {
            if state == .idle {
                Button {
                    Haptics.flip()
                    onInvites()
                } label: {
                    Text("USE GAME CENTER INVITES")
                        .font(.system(size: 12, weight: .heavy, design: .rounded))
                        .tracking(1.5)
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 9)
                        .background(Capsule().fill(.white.opacity(0.06)))
                        .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            Button {
                Haptics.nope()
                if state == .idle {
                    onClose()
                } else {
                    CodeMatchmaker.cancel()
                    state = .idle
                }
            } label: {
                Text(state == .idle ? "BACK" : "CANCEL")
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
