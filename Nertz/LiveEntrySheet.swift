import SwiftUI

/// One cell of the scorecard: type the round total straight in, or count
/// the cards out and let the app do the math. The keypad is ours (no
/// system keyboard jumping around a card table).
struct LiveEntrySheet: View {
    let player: LivePlayer
    let roundNumber: Int            // 1-based, for the header
    let existing: LiveEntry?
    let existingCaller: Bool
    let isMe: Bool
    /// entry nil = clear the cell; callerClaim nil = no change.
    let onSave: (LiveEntry?, Bool?) -> Void

    @Environment(\.dismiss) private var dismiss

    private enum Mode: String {
        case total, counted
    }
    private enum CountField {
        case table, nertz
    }

    /// The mode you used last time is the mode you get next time.
    @AppStorage("liveEntryMode") private var preferredMode = Mode.total.rawValue

    @State private var mode: Mode = .total
    @State private var magnitude = 0
    @State private var negative = false
    @State private var table = 0
    @State private var nertz = 0
    @State private var focused: CountField = .table
    /// Typing replaces the shown value first, then appends.
    @State private var virgin = true
    @State private var wentOut = false

    var body: some View {
        VStack(spacing: 14) {
            header
            modeToggle
            Group {
                if mode == .total {
                    totalDisplay
                } else {
                    countedDisplay
                }
            }
            .frame(maxHeight: .infinity)
            wentOutChip
            keypad
            saveRow
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 14)
        .presentationDetents([.height(680)])
        .presentationBackground(Color(hex: 0x0E2417))
        .presentationDragIndicator(.visible)
        .onAppear(perform: prefill)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Text(player.emoji).font(.system(size: 24))
            Text(player.name.uppercased())
                .font(.system(size: 18, weight: .black, design: .rounded))
                .tracking(1.5)
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Spacer()
            Text("ROUND \(roundNumber)")
                .font(.system(size: 12, weight: .heavy, design: .rounded))
                .tracking(1.5)
                .foregroundStyle(.white.opacity(0.5))
        }
    }

    // MARK: Mode toggle

    private var modeToggle: some View {
        HStack(spacing: 8) {
            modeChip("TOTAL", hint: "I did the math", .total)
            modeChip("COUNT IT", hint: "the app does it", .counted)
        }
    }

    private func modeChip(_ label: String, hint: String, _ m: Mode) -> some View {
        let selected = mode == m
        return Button {
            mode = m
            preferredMode = m.rawValue
            virgin = true
            Haptics.flip()
        } label: {
            VStack(spacing: 2) {
                Text(label)
                    .font(.system(size: 14, weight: .black, design: .rounded))
                    .tracking(1.5)
                    .foregroundStyle(.white)
                Text(hint)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))
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

    // MARK: Total — one big signed number

    private var currentTotal: Int { negative ? -magnitude : magnitude }

    private var totalDisplay: some View {
        Text(signedText(currentTotal))
            .font(.system(size: 64, weight: .black, design: .rounded))
            .foregroundStyle(currentTotal < 0 ? Color(hex: 0xFF9C93) : .white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.black.opacity(0.25))
            )
    }

    // MARK: Count it — two piles and the math done for you

    private var countedDelta: Int { table - 2 * (wentOut ? 0 : nertz) }

    private var countedDisplay: some View {
        VStack(spacing: 10) {
            countRow(
                label: "CARDS ON THE TABLE",
                sub: "played to the middle",
                value: table,
                field: .table,
                disabled: false
            )
            countRow(
                label: "LEFT IN NERTZ",
                sub: wentOut ? "you went out — zero!" : "each one costs 2",
                value: wentOut ? 0 : nertz,
                field: .nertz,
                disabled: wentOut
            )
            Text("\(table)  −  2 × \(wentOut ? 0 : nertz)  =  \(signedText(countedDelta))")
                .font(.system(size: 17, weight: .heavy, design: .rounded))
                .foregroundStyle(countedDelta < 0 ? Color(hex: 0xFF9C93) : Color(hex: 0x7CFFB0))
                .padding(.top, 2)
        }
    }

    private func countRow(label: String, sub: String, value: Int, field: CountField, disabled: Bool) -> some View {
        let isFocused = focused == field && !disabled
        return Button {
            guard !disabled else { return }
            focused = field
            virgin = true
            Haptics.flip()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(label)
                        .font(.system(size: 13, weight: .heavy, design: .rounded))
                        .tracking(1)
                        .foregroundStyle(.white.opacity(disabled ? 0.35 : 0.9))
                    Text(sub)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.45))
                }
                Spacer()
                Text("\(value)")
                    .font(.system(size: 34, weight: .black, design: .rounded))
                    .foregroundStyle(.white.opacity(disabled ? 0.35 : 1))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.white.opacity(isFocused ? 0.16 : 0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.white.opacity(isFocused ? 0.85 : 0.12), lineWidth: isFocused ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: Went out

    private var wentOutChip: some View {
        Button {
            wentOut.toggle()
            if wentOut { focused = .table }
            virgin = true
            Haptics.flip()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: wentOut ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(wentOut ? Color(hex: 0x7CFFB0) : .white.opacity(0.35))
                Text(isMe ? "I WENT OUT — NERTZ!" : "WENT OUT — NERTZ!")
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .tracking(1.5)
                    .foregroundStyle(.white.opacity(0.85))
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Capsule().fill(.white.opacity(wentOut ? 0.14 : 0.06)))
            .overlay(Capsule().strokeBorder(.white.opacity(wentOut ? 0.4 : 0.12), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: Keypad

    private var keypad: some View {
        VStack(spacing: 8) {
            ForEach([["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], ["±", "0", "⌫"]], id: \.self) { row in
                HStack(spacing: 8) {
                    ForEach(row, id: \.self) { key in
                        keypadButton(key)
                    }
                }
            }
        }
    }

    private func keypadButton(_ key: String) -> some View {
        let signDisabled = key == "±" && mode == .counted
        return Button {
            press(key)
        } label: {
            Text(key)
                .font(.system(size: 24, weight: .heavy, design: .rounded))
                .foregroundStyle(.white.opacity(signDisabled ? 0.15 : 0.95))
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.white.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(.white.opacity(0.10), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(signDisabled)
    }

    private func press(_ key: String) {
        Haptics.flip()
        switch key {
        case "±":
            negative.toggle()
        case "⌫":
            virgin = false
            setFocusedValue(focusedValue / 10)
        default:
            guard let digit = Int(key) else { return }
            let appended = virgin ? digit : focusedValue * 10 + digit
            virgin = false
            // Overflowing the pile's ceiling starts a fresh number —
            // calculator manners, quickest way to correct a typo.
            setFocusedValue(appended > focusedMax ? digit : appended)
        }
    }

    private var focusedValue: Int {
        if mode == .total { return magnitude }
        return focused == .table ? table : nertz
    }

    private var focusedMax: Int {
        if mode == .total { return 99 }
        return focused == .table ? 52 : 13
    }

    private func setFocusedValue(_ v: Int) {
        let clamped = min(max(0, v), focusedMax)
        if mode == .total {
            magnitude = clamped
        } else if focused == .table {
            table = clamped
        } else {
            nertz = clamped
        }
    }

    // MARK: Save

    private var saveRow: some View {
        VStack(spacing: 8) {
            Button {
                Haptics.score()
                Sound.play(.score)
                let entry: LiveEntry = mode == .total
                    ? .direct(total: currentTotal)
                    : .counted(table: table, nertzLeft: wentOut ? 0 : nertz)
                onSave(entry, wentOut == existingCaller ? nil : wentOut)
                dismiss()
            } label: {
                Text("SAVE SCORE")
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
            if existing != nil {
                Button {
                    Haptics.nope()
                    onSave(nil, existingCaller ? false : nil)
                    dismiss()
                } label: {
                    Text("CLEAR THIS SCORE")
                        .font(.system(size: 11, weight: .heavy, design: .rounded))
                        .tracking(1.5)
                        .foregroundStyle(.white.opacity(0.45))
                        .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Prefill

    private func prefill() {
        wentOut = existingCaller
        switch existing {
        case .direct(let total):
            mode = .total
            magnitude = abs(total)
            negative = total < 0
        case .counted(let t, let n):
            mode = .counted
            table = t
            nertz = n
            focused = .table
        case nil:
            mode = Mode(rawValue: preferredMode) ?? .total
        }
        virgin = true
    }
}

func signedText(_ n: Int) -> String {
    n > 0 ? "+\(n)" : "\(n)"
}
