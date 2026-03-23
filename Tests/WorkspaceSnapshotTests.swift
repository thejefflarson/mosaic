import Testing
import Foundation
@testable import Mosaic

struct WorkspaceSnapshotTests {

    private func makeWindow(scrollback: String? = nil) -> WorkspaceSnapshot.WindowSnapshot {
        WorkspaceSnapshot.WindowSnapshot(
            id: UUID(), x: 100, y: 200, width: 600, height: 400,
            shell: "/bin/zsh", cwd: "/Users/test", title: "bash",
            scrollback: scrollback
        )
    }

    private let viewport = WorkspaceSnapshot.ViewportState(panX: 123.5, panY: -45.0, zoom: 1.25)

    private func roundTrip(_ snapshot: WorkspaceSnapshot) throws -> WorkspaceSnapshot {
        try JSONDecoder().decode(WorkspaceSnapshot.self, from: JSONEncoder().encode(snapshot))
    }

    // MARK: - Round-trip

    @Test func encodeDecodeEmpty() throws {
        let decoded = try roundTrip(WorkspaceSnapshot(viewport: viewport, windows: [], annotations: []))
        #expect(decoded.windows.count     == 0)
        #expect(decoded.annotations.count == 0)
        #expect(decoded.viewport.panX     == 123.5)
        #expect(decoded.viewport.panY     == -45.0)
        #expect(decoded.viewport.zoom     == 1.25)
    }

    @Test func encodeDecodeWithWindows() throws {
        let decoded = try roundTrip(
            WorkspaceSnapshot(viewport: viewport,
                              windows: [makeWindow(), makeWindow(scrollback: "some history")]))
        #expect(decoded.windows.count       == 2)
        #expect(decoded.windows[0].scrollback == nil)
        #expect(decoded.windows[1].scrollback == "some history")
    }

    @Test func scrollbackPreserved() throws {
        let text    = "line1\r\nline2\r\nline3"
        let decoded = try roundTrip(WorkspaceSnapshot(viewport: viewport,
                                                      windows: [makeWindow(scrollback: text)]))
        #expect(decoded.windows[0].scrollback == text)
    }

    @Test func windowFieldsPreserved() throws {
        let id = UUID()
        let w  = WorkspaceSnapshot.WindowSnapshot(
            id: id, x: 10, y: 20, width: 300, height: 200,
            shell: "/bin/bash", cwd: "/tmp", title: "test", scrollback: nil
        )
        let dw = try roundTrip(WorkspaceSnapshot(viewport: viewport, windows: [w])).windows[0]
        #expect(dw.id     == id)
        #expect(dw.x      == 10)
        #expect(dw.y      == 20)
        #expect(dw.width  == 300)
        #expect(dw.height == 200)
        #expect(dw.shell  == "/bin/bash")
        #expect(dw.cwd    == "/tmp")
        #expect(dw.title  == "test")
    }

    // MARK: - Backward compatibility

    @Test func missingAnnotationsFieldDecodesAsEmpty() throws {
        let json = """
        {"viewport":{"panX":0,"panY":0,"zoom":1},"windows":[]}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(WorkspaceSnapshot.self, from: json)
        #expect(decoded.annotations.count == 0)
    }

    // MARK: - ViewportState

    @Test func viewportStateRoundTrip() throws {
        let vp      = WorkspaceSnapshot.ViewportState(panX: -100, panY: 50, zoom: 0.5)
        let decoded = try JSONDecoder().decode(
            WorkspaceSnapshot.ViewportState.self, from: JSONEncoder().encode(vp))
        #expect(decoded.panX == -100)
        #expect(decoded.panY == 50)
        #expect(decoded.zoom == 0.5)
    }
}
