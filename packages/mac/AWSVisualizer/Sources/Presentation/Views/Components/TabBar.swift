import SwiftUI

/// Page-level tab strip for detail screens (General / Policy / Tags, ...):
/// real tabs - label row with an accent underline that slides to the
/// selected tab, hover highlight, a hairline under the whole strip - instead
/// of the system segmented control, which reads as an option toggle and is
/// cramped once a screen has 6-7 tabs. Scrolls horizontally if the tabs
/// don't fit.
///
/// Two styles, for the two levels of navigation a screen can have:
/// - `.underline` - page sections (General / Policy / Tags): full-width
///   strip with a sliding underline and a hairline under it.
/// - `.pills` - modes *inside* a section (Scan / Query, Running / Stopped,
///   JSON / Form, Formatted / Tree): a compact capsule with a sliding
///   filled pill, no underline or divider, sized to its content so it sits
///   in the section's toolbar row next to the actions. Using the underline
///   style twice would stack bar on bar and blur which level is which.
///
/// Form fields that merely pick a value (Ascending / Descending, Standard /
/// FIFO, search scope) stay a segmented `Picker`.
enum TabBarStyle {
    case underline
    case pills
}

struct TabBar<Tab: Hashable>: View {
    let tabs: [Tab]
    @Binding var selection: Tab
    let title: (Tab) -> String
    /// Optional SF Symbol per tab.
    var icon: ((Tab) -> String?)?
    var style: TabBarStyle = .underline
    var height: CGFloat = 38

    @Namespace private var indicatorNamespace
    @State private var hovered: Tab?

    init(tabs: [Tab], selection: Binding<Tab>, style: TabBarStyle = .underline, height: CGFloat? = nil, title: @escaping (Tab) -> String, icon: ((Tab) -> String?)? = nil) {
        self.tabs = tabs
        self._selection = selection
        self.style = style
        self.height = height ?? (style == .pills ? 26 : 38)
        self.title = title
        self.icon = icon
    }

    var body: some View {
        switch style {
        case .underline: underlineBar
        case .pills: pillBar
        }
    }

    // MARK: Pills

    private var pillBar: some View {
        HStack(spacing: 2) {
            ForEach(tabs, id: \.self) { tab in
                pillButton(tab)
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.secondary.opacity(0.14)))
        .fixedSize()
    }

    private func pillButton(_ tab: Tab) -> some View {
        let isSelected = tab == selection
        return Button {
            withAnimation(.easeInOut(duration: 0.16)) { selection = tab }
        } label: {
            HStack(spacing: 5) {
                if let symbol = icon?(tab) {
                    Image(systemName: symbol)
                        .font(.system(size: 11))
                }
                Text(title(tab))
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 12)
            .frame(height: height - 4)
            .foregroundStyle(isSelected ? Color.white : (hovered == tab ? Color.primary : Color.secondary))
            .background {
                if isSelected {
                    Capsule()
                        .fill(Color.accentColor)
                        .shadow(color: .black.opacity(0.15), radius: 1, y: 0.5)
                        .matchedGeometryEffect(id: "pill", in: indicatorNamespace)
                } else if hovered == tab {
                    Capsule().fill(Color.secondary.opacity(0.12))
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            hovered = inside ? tab : (hovered == tab ? nil : hovered)
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: Underline

    private var underlineBar: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(tabs, id: \.self) { tab in
                        tabButton(tab)
                    }
                }
                .padding(.horizontal, 10)
            }
            .frame(height: height)
            Divider()
        }
    }

    /// A low strip (height ≤ 30, e.g. DynamoDB's table tabs above its grid) gets smaller type.
    private var isCompact: Bool { height <= 30 }

    private func tabButton(_ tab: Tab) -> some View {
        let isSelected = tab == selection
        return Button {
            withAnimation(.easeInOut(duration: 0.18)) { selection = tab }
        } label: {
            HStack(spacing: isCompact ? 5 : 6) {
                if let symbol = icon?(tab) {
                    Image(systemName: symbol)
                        .font(.system(size: isCompact ? 10.5 : 12))
                }
                Text(title(tab))
                    .font(.system(size: isCompact ? 11.5 : 13, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, isCompact ? 10 : 14)
            .frame(height: height)
            .foregroundStyle(isSelected ? Color.accentColor : (hovered == tab ? Color.primary : Color.secondary))
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(hovered == tab && !isSelected ? 0.08 : 0))
                    .padding(.vertical, 4)
            )
            .overlay(alignment: .bottom) {
                if isSelected {
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(height: 3)
                        .padding(.horizontal, 6)
                        .matchedGeometryEffect(id: "indicator", in: indicatorNamespace)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            hovered = inside ? tab : (hovered == tab ? nil : hovered)
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

extension TabBar where Tab: CaseIterable & RawRepresentable, Tab.RawValue == String {
    /// Every case of a String-backed tab enum, titled by its raw value.
    init(selection: Binding<Tab>, style: TabBarStyle = .underline, height: CGFloat? = nil, icon: ((Tab) -> String?)? = nil) {
        self.init(tabs: Array(Tab.allCases), selection: selection, style: style, height: height, title: { $0.rawValue }, icon: icon)
    }
}
