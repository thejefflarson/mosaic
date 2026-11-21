import AppKit
import SwiftUI

// MARK: - Model

/// Holds only value snapshots (ADR 010): no terminal view is captured, so a closed
/// terminal can't be kept alive by the panel.
@MainActor
private final class AgentsPanelModel: ObservableObject {
    @Published var snapshots: [AgentSnapshot] = []
    var onSelect: ((UUID) -> Void)?
}

// MARK: - SwiftUI panel

private struct AgentsPanelSwiftUIView: View {
    @ObservedObject var model: AgentsPanelModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(AgentGroup.allCases, id: \.self) { group in
                    let rows = model.snapshots.filter { AgentRoster.group(for: $0) == group }
                    if !rows.isEmpty {
                        header(group, count: rows.count)
                        ForEach(rows, id: \.id) { row in
                            AgentRowView(snapshot: row, group: group) { model.onSelect?(row.id) }
                        }
                    }
                }
            }
            .padding(.horizontal, AgentRowFormat.panelPadding)
            .padding(.bottom, AgentRowFormat.panelPadding)
            .padding(.top, AgentRowFormat.panelTopPadding)
        }
        .frame(width: AgentsPanelView.width)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            // Same hairline as the minimap and pill (NSColor white 0.3, 1pt).
            RoundedRectangle(cornerRadius: 10).stroke(Color(white: 0.3), lineWidth: 1)
        )
        .environment(\.colorScheme, .dark)
    }

    private func header(_ group: AgentGroup, count: Int) -> some View {
        Text("\(AgentRowFormat.groupTitle(group)) · \(count)")
            .font(.system(size: 10, weight: .semibold))
            .textCase(.uppercase)
            .foregroundStyle(.primary)
            .padding(.horizontal, 6)
            .frame(height: AgentRowFormat.headerHeight, alignment: .bottom)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct AgentRowView: View {
    let snapshot: AgentSnapshot
    let group: AgentGroup
    let action: () -> Void
    @State private var hovering = false

    private var identity: String { AgentRowFormat.displayName(agentID: snapshot.agentID) }
    private var location: String { AgentRowFormat.location(cwd: snapshot.cwd, title: snapshot.title) }
    private var duration: String { AgentRowFormat.duration(since: snapshot.stateSince) }
    private var subtitle: String? { AgentRowFormat.subtitle(for: snapshot) }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    GlyphView(glyph: AgentRowFormat.glyph(for: snapshot), group: group)
                    Text(identity).font(.system(size: 12, weight: .semibold))
                    Text("· \(location)")
                        .font(.system(size: 11))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    Text(duration)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.primary)
                }
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.leading, 18)
                }
            }
            .padding(.horizontal, 6)
            .frame(height: AgentRowFormat.rowHeight(for: group), alignment: .center)
            .background(hovering ? Color(white: 1, opacity: 0.12) : .clear,
                        in: RoundedRectangle(cornerRadius: 7))
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isButton)
    }

    private var accessibilityLabel: String {
        var parts = [identity, AgentRowFormat.groupTitle(group)]
        if let subtitle { parts.append(subtitle) }
        parts.append(duration == "just now" ? duration : "for \(duration)")
        parts.append(location)
        return parts.joined(separator: ", ")
    }
}

/// A status dot whose color encodes state, on a colorblind-safe palette (Okabe-Ito
/// blue + amber, which stay distinct under the common red-green and blue-yellow
/// deficiencies, plus a neutral gray for the calm idle state). The dot is static,
/// never a spinner: the pulse channel belongs to the pill and title-bar indicator.
/// Shape carries a second, color-independent signal — a nonzero exit renders as a
/// triangle rather than a circle — so the one state the user must not miss survives
/// any color vision.
private struct GlyphView: View {
    let glyph: AgentRowFormat.Glyph
    let group: AgentGroup

    private var color: Color {
        switch group {
        case .working: return Color(red: 0, green: 114 / 255, blue: 178 / 255)       // Okabe-Ito blue  #0072B2
        case .needsYou: return Color(red: 230 / 255, green: 159 / 255, blue: 0)       // Okabe-Ito amber #E69F00
        case .idle: return Color(white: 0.55)
        }
    }

    var body: some View {
        Group {
            switch glyph {
            case .triangle:
                Triangle().fill(color)
            case .filledCircle, .hollowCircle:
                Circle().fill(color)
            }
        }
        .frame(width: 9, height: 9)
        .frame(width: 12)
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

// MARK: - NSView wrapper

/// Grouped roster of running agents, docked above the minimap (ADR 010). Screen-space
/// overlay; shown only while at least one agent is running.
final class AgentsPanelView: NSView, HoverCursorProviding {
    static let width: CGFloat = 260

    var onSelect: ((UUID) -> Void)? {
        get { model.onSelect }
        set { model.onSelect = newValue }
    }

    private let model = AgentsPanelModel()
    private let hostingView: NSHostingView<AgentsPanelSwiftUIView>
    private var heightConstraint: NSLayoutConstraint!

    override init(frame: NSRect) {
        hostingView = NSHostingView(rootView: AgentsPanelSwiftUIView(model: model))
        super.init(frame: frame)
        heightConstraint = heightAnchor.constraint(equalToConstant: 0)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(equalToConstant: Self.width),
            heightConstraint,
        ])
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Refreshes the roster; the panel is visible exactly when `snapshots` is non-empty.
    /// `maxHeight` caps the panel so it never covers the canvas; taller content scrolls.
    func update(snapshots: [AgentSnapshot], maxHeight: CGFloat) {
        if model.snapshots != snapshots { model.snapshots = snapshots }
        heightConstraint.constant = min(AgentRowFormat.contentHeight(for: snapshots), min(320, maxHeight))
        isHidden = snapshots.isEmpty
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    func hoverCursor(at localPoint: NSPoint) -> NSCursor? { .pointingHand }
}
