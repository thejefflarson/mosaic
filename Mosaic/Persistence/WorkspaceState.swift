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
        var title: String
        var scrollback: String?
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
