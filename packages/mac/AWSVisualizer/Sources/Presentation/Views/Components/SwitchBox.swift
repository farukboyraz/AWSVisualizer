import SwiftUI

/// A compact capsule toggle, like the native `Toggle` but with the track's
/// on/off colors exposed as parameters - Settings has several boolean
/// switches that read better with distinct on/off colors (e.g. a feature
/// that's normally red-when-off/green-when-on) than the system's single
/// accent-color track.
struct SwitchBox: View {
    @Binding var isOn: Bool
    var onColor: Color = .accentColor
    var offColor: Color = Color.secondary.opacity(0.35)
    var width: CGFloat = 40
    var height: CGFloat = 24

    private var knobDiameter: CGFloat { height - 4 }
    private var knobTravel: CGFloat { (width - knobDiameter) / 2 - 2 }

    var body: some View {
        Capsule()
            .fill(isOn ? onColor : offColor)
            .frame(width: width, height: height)
            .overlay(
                Circle()
                    .fill(.white)
                    .frame(width: knobDiameter, height: knobDiameter)
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                    .offset(x: isOn ? knobTravel : -knobTravel)
            )
            .contentShape(Capsule())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.15)) { isOn.toggle() }
            }
            .animation(.easeInOut(duration: 0.15), value: isOn)
            .accessibilityAddTraits(.isButton)
    }
}

/// `SwitchBox` plus a leading label - the common case in Settings-style
/// rows (label on the left, switch on the right).
struct LabeledSwitchBox: View {
    let title: String
    @Binding var isOn: Bool
    var onColor: Color = .accentColor
    var offColor: Color = Color.secondary.opacity(0.35)

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            SwitchBox(isOn: $isOn, onColor: onColor, offColor: offColor)
        }
    }
}

/// Multi-position version of `SwitchBox` - a capsule track with a sliding
/// knob behind the selected option's label, for settings with more than
/// two states (e.g. DynamoDB's three item views). Clicking a label moves
/// the knob there.
struct MultiSwitchBox<Option: Hashable>: View {
    @Binding var selection: Option
    let options: [(value: Option, label: String)]
    var segmentWidth: CGFloat = 116
    var height: CGFloat = 26
    var knobColor: Color = .accentColor
    var trackColor: Color = Color.secondary.opacity(0.18)

    private var selectedIndex: Int {
        options.firstIndex { $0.value == selection } ?? 0
    }

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(trackColor)
            Capsule()
                .fill(knobColor)
                .frame(width: segmentWidth - 4, height: height - 4)
                .shadow(color: .black.opacity(0.2), radius: 1, y: 0.5)
                .offset(x: CGFloat(selectedIndex) * segmentWidth + 2)
            HStack(spacing: 0) {
                ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                    Text(option.label)
                        .font(.caption.weight(index == selectedIndex ? .semibold : .regular))
                        .foregroundStyle(index == selectedIndex ? Color.white : Color.primary)
                        .frame(width: segmentWidth, height: height)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.15)) { selection = option.value }
                        }
                        .accessibilityAddTraits(.isButton)
                }
            }
        }
        .frame(width: segmentWidth * CGFloat(options.count), height: height)
        .animation(.easeInOut(duration: 0.15), value: selectedIndex)
    }
}
