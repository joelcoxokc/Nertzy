import SwiftUI

/// UserDefaults keys for the table-feel preferences, shared by every
/// @AppStorage that binds them.
enum TablePrefs {
    static let leftHandKey = "leftHandMode"
    static let tapToPlayKey = "tapToPlay"
}

/// The two table-feel preferences. Device-level (@AppStorage), not match
/// settings: they apply live, even mid-round, and never touch saves.
struct TableSettingsSheet: View {
    @AppStorage(TablePrefs.leftHandKey) private var leftHandMode = false
    @AppStorage(TablePrefs.tapToPlayKey) private var tapToPlay = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 12) {
            Text("TABLE SETTINGS")
                .font(.system(size: 20, weight: .black, design: .rounded))
                .tracking(2)
                .foregroundStyle(.white)
                .padding(.top, 6)
                .padding(.bottom, 6)

            SettingToggleRow(
                title: "LEFT-HAND MODE",
                blurb: "Nerts pile and stock at your left thumb, work piles on the right.",
                isOn: $leftHandMode
            )
            SettingToggleRow(
                title: "TAP TO PLAY",
                blurb: "Tap a card to send it to the table. Off, cards move only when you drag them.",
                isOn: $tapToPlay
            )

            Button {
                dismiss()
            } label: {
                Text("DONE")
                    .font(.system(size: 15, weight: .black, design: .rounded))
                    .tracking(1.5)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        Capsule().fill(LinearGradient(
                            colors: [Color(hex: 0x35C963), Color(hex: 0x1E9B47)],
                            startPoint: .top, endPoint: .bottom
                        ))
                    )
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
        }
        .padding(24)
        .frame(maxWidth: 480)
        .presentationDetents([.height(330)])
        .presentationBackground(Color(hex: 0x0E2417))
        .presentationDragIndicator(.visible)
    }
}

/// A settings row in the house style: title, one-line why, green check.
struct SettingToggleRow: View {
    let title: String
    let blurb: String
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
            Haptics.flip()
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text(blurb)
                        .font(.system(size: 11.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.55))
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(isOn ? Color(hex: 0x7CFFB0) : .white.opacity(0.25))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.white.opacity(isOn ? 0.16 : 0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        .white.opacity(isOn ? 0.7 : 0.12),
                        lineWidth: isOn ? 1.5 : 1
                    )
            )
        }
        .buttonStyle(.plain)
    }
}
