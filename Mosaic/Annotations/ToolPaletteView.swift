import AppKit
import SwiftUI

// MARK: - Model

private final class ToolPaletteModel: ObservableObject {
    @Published var activeTool: CanvasTool = .pointer
    @Published var snappingEnabled: Bool = true
    var onToolSelected: ((CanvasTool) -> Void)?
    var onSnappingToggled: ((Bool) -> Void)?
}

// MARK: - SwiftUI palette

private struct ToolPaletteSwiftUIView: View {
    @ObservedObject var model: ToolPaletteModel

    private let tools: [(tool: CanvasTool, symbol: String, tooltip: String)] = [
        (.pointer,    "cursorarrow",    "Pointer (V)"),
        (.terminal,   "note.text",      "New Terminal (T)"),
        (.text,       "textformat",     "Text Label (L)"),
        (.stickyNote, "text.document",  "Sticky Note (N)"),
        (.arrow,      "arrow.up.right", "Arrow (A)"),
        (.pen,        "pencil.tip",     "Pen (P)"),
        (.image,      "photo",          "Image (I)"),
        (.delete,     "trash",          "Delete (X)"),
    ]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tools, id: \.tool) { def in
                toolButton(def)
            }
            Divider()
                .frame(height: 22)
                .padding(.horizontal, 4)
            toggleButton(
                symbol: "ruler",
                tooltip: "Snap to Alignment",
                active: model.snappingEnabled
            ) {
                model.snappingEnabled.toggle()
                model.onSnappingToggled?(model.snappingEnabled)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private func toolButton(_ def: (tool: CanvasTool, symbol: String, tooltip: String)) -> some View {
        let active = model.activeTool == def.tool
        Button {
            model.activeTool = def.tool
            model.onToolSelected?(def.tool)
        } label: {
            Image(systemName: def.symbol)
                .font(.system(size: 14, weight: .regular))
                .frame(width: 34, height: 34)
                .foregroundStyle(active ? .white : Color(white: 0.65))
                .background(active ? Color(white: 1, opacity: 0.15) : .clear,
                            in: RoundedRectangle(cornerRadius: 7))
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .help(def.tooltip)
    }

    @ViewBuilder
    private func toggleButton(symbol: String, tooltip: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .symbolVariant(active ? .fill : .none)
                .font(.system(size: 14, weight: .regular))
                .frame(width: 34, height: 34)
                .foregroundStyle(active ? .white : Color(white: 0.45))
                .background(active ? Color(white: 1, opacity: 0.15) : .clear,
                            in: RoundedRectangle(cornerRadius: 7))
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .help(tooltip)
    }
}

// MARK: - NSView wrapper

/// Floating tool palette HUD. Positioned in screen space (not world space).
final class ToolPaletteView: NSView {

    var onToolSelected: ((CanvasTool) -> Void)? {
        get { model.onToolSelected }
        set { model.onToolSelected = newValue }
    }

    var onSnappingToggled: ((Bool) -> Void)? {
        get { model.onSnappingToggled }
        set { model.onSnappingToggled = newValue }
    }

    var snappingEnabled: Bool {
        get { model.snappingEnabled }
        set { model.snappingEnabled = newValue }
    }

    private(set) var activeTool: CanvasTool {
        get { model.activeTool }
        set { model.activeTool = newValue }
    }

    private let model = ToolPaletteModel()
    private let hostingView: NSHostingView<ToolPaletteSwiftUIView>

    override init(frame: NSRect) {
        hostingView = NSHostingView(rootView: ToolPaletteSwiftUIView(model: model))
        super.init(frame: frame)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func selectTool(_ tool: CanvasTool) {
        model.activeTool = tool
    }
}
