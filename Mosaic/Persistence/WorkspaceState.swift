import Foundation

struct PointSnapshot: Codable {
    var x: CGFloat
    var y: CGFloat
}

struct AnnotationSnapshot: Codable {
    enum Kind: String, Codable {
        case text, stickyNote, arrow, freehand, image
    }
    var id: UUID
    var kind: Kind
    var x, y, width, height: CGFloat
    var content: String?
    var colorName: String?
    var points: [PointSnapshot]?
    var lineWidth: CGFloat?
    /// Path to an image file in Application Support (used by ImageAnnotationView).
    var imagePath: String?

    init(id: UUID, kind: Kind, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat,
         content: String? = nil, colorName: String? = nil,
         points: [PointSnapshot]? = nil, lineWidth: CGFloat? = nil, imagePath: String? = nil) {
        self.id = id; self.kind = kind
        self.x = x; self.y = y; self.width = width; self.height = height
        self.content = content; self.colorName = colorName
        self.points = points; self.lineWidth = lineWidth; self.imagePath = imagePath
    }
}

struct WorkspaceSnapshot: Codable, Sendable {

    struct ViewportState: Codable {
        var panX: CGFloat
        var panY: CGFloat
        var zoom: CGFloat
    }

    struct WindowSnapshot: Codable {
        var id: UUID
        var x: CGFloat
        var y: CGFloat
        var width: CGFloat
        var height: CGFloat
        var shell: String
        var cwd: String
        /// Title is intentionally NOT persisted: OSC 2 titles may contain sensitive
        /// data (e.g. vim shows the open file path; AWS CLI shows prompts). The field
        /// is decoded from legacy snapshots (with a length cap) but always encoded as
        /// an empty string so new snapshots don't record it.
        var title: String
        var scrollback: String?

        // Maximum lengths for fields decoded from disk. Guards against a tampered or
        // corrupt workspace.json supplying multi-megabyte strings that are decoded on
        // the main thread at launch and stall or exhaust heap before validation fires.
        private static let maxShellLen    = 4_096   // generous PATH_MAX
        private static let maxCwdLen      = 4_096
        private static let maxTitleLen    = 1_024
        private static let maxScrollbackLen = 256 * 1_024  // matches maxScrollbackTotalChars

        private enum CodingKeys: String, CodingKey {
            case id, x, y, width, height, shell, cwd, title, scrollback
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id    = try c.decode(UUID.self,    forKey: .id)
            x     = try c.decode(CGFloat.self, forKey: .x)
            y     = try c.decode(CGFloat.self, forKey: .y)
            width = try c.decode(CGFloat.self, forKey: .width)
            height = try c.decode(CGFloat.self, forKey: .height)
            let rawShell = try c.decode(String.self, forKey: .shell)
            shell = String(rawShell.prefix(Self.maxShellLen))
            let rawCwd = try c.decode(String.self, forKey: .cwd)
            cwd   = String(rawCwd.prefix(Self.maxCwdLen))
            let rawTitle = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
            title = String(rawTitle.prefix(Self.maxTitleLen))
            let rawScrollback = try c.decodeIfPresent(String.self, forKey: .scrollback)
            scrollback = rawScrollback.map { String($0.prefix(Self.maxScrollbackLen)) }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id,     forKey: .id)
            try c.encode(x,      forKey: .x)
            try c.encode(y,      forKey: .y)
            try c.encode(width,  forKey: .width)
            try c.encode(height, forKey: .height)
            try c.encode(shell,  forKey: .shell)
            try c.encode(cwd,    forKey: .cwd)
            // Encode title as empty string — OSC 2 titles may contain sensitive data
            // (file paths, AWS prompts). The terminal re-sets its own title via OSC 2
            // after the first command, so there is no visible regression.
            try c.encode("",     forKey: .title)
            try c.encodeIfPresent(scrollback, forKey: .scrollback)
        }
    }

    var viewport: ViewportState
    var windows: [WindowSnapshot]
    var annotations: [AnnotationSnapshot]
    var minimapWidth: CGFloat?
    var minimapHeight: CGFloat?

    init(viewport: ViewportState, windows: [WindowSnapshot], annotations: [AnnotationSnapshot] = [],
         minimapWidth: CGFloat? = nil, minimapHeight: CGFloat? = nil) {
        self.viewport = viewport
        self.windows = windows
        self.annotations = annotations
        self.minimapWidth = minimapWidth
        self.minimapHeight = minimapHeight
    }

    // Custom decoder so that snapshots saved before annotations or minimap size were added still load correctly.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        viewport      = try c.decode(ViewportState.self,        forKey: .viewport)
        windows       = try c.decode([WindowSnapshot].self,     forKey: .windows)
        annotations   = try c.decodeIfPresent([AnnotationSnapshot].self, forKey: .annotations) ?? []
        minimapWidth  = try c.decodeIfPresent(CGFloat.self, forKey: .minimapWidth)
        minimapHeight = try c.decodeIfPresent(CGFloat.self, forKey: .minimapHeight)
    }
}
