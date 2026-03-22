import XCTest
@testable import Mosaic

final class WorkspaceSnapshotTests: XCTestCase {

    private func makeWindowSnapshot(scrollback: String? = nil) -> WorkspaceSnapshot.WindowSnapshot {
        WorkspaceSnapshot.WindowSnapshot(
            id: UUID(), x: 100, y: 200, width: 600, height: 400,
            shell: "/bin/zsh", cwd: "/Users/test", title: "bash",
            scrollback: scrollback
        )
    }

    private func makeViewportState() -> WorkspaceSnapshot.ViewportState {
        WorkspaceSnapshot.ViewportState(panX: 123.5, panY: -45.0, zoom: 1.25)
    }

    // MARK: - Round-trip

    func testEncodeDecodeEmpty() throws {
        let snapshot = WorkspaceSnapshot(viewport: makeViewportState(), windows: [], annotations: [])
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(WorkspaceSnapshot.self, from: data)
        XCTAssertEqual(decoded.windows.count, 0)
        XCTAssertEqual(decoded.annotations.count, 0)
        XCTAssertEqual(decoded.viewport.panX,  123.5)
        XCTAssertEqual(decoded.viewport.panY,  -45.0)
        XCTAssertEqual(decoded.viewport.zoom,  1.25)
    }

    func testEncodeDecodeWithWindows() throws {
        let w1 = makeWindowSnapshot()
        let w2 = makeWindowSnapshot(scrollback: "some history")
        let snapshot = WorkspaceSnapshot(viewport: makeViewportState(), windows: [w1, w2])
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(WorkspaceSnapshot.self, from: data)
        XCTAssertEqual(decoded.windows.count, 2)
        XCTAssertNil(decoded.windows[0].scrollback)
        XCTAssertEqual(decoded.windows[1].scrollback, "some history")
    }

    func testScrollbackPreserved() throws {
        let multiline = "line1\r\nline2\r\nline3"
        let w = makeWindowSnapshot(scrollback: multiline)
        let snapshot = WorkspaceSnapshot(viewport: makeViewportState(), windows: [w])
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(WorkspaceSnapshot.self, from: data)
        XCTAssertEqual(decoded.windows[0].scrollback, multiline)
    }

    func testWindowFieldsPreserved() throws {
        let id = UUID()
        let w = WorkspaceSnapshot.WindowSnapshot(
            id: id, x: 10, y: 20, width: 300, height: 200,
            shell: "/bin/bash", cwd: "/tmp", title: "test", scrollback: nil
        )
        let snapshot = WorkspaceSnapshot(viewport: makeViewportState(), windows: [w])
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(WorkspaceSnapshot.self, from: data)
        let dw = decoded.windows[0]
        XCTAssertEqual(dw.id,     id)
        XCTAssertEqual(dw.x,      10)
        XCTAssertEqual(dw.y,      20)
        XCTAssertEqual(dw.width,  300)
        XCTAssertEqual(dw.height, 200)
        XCTAssertEqual(dw.shell,  "/bin/bash")
        XCTAssertEqual(dw.cwd,    "/tmp")
        XCTAssertEqual(dw.title,  "test")
    }

    // MARK: - Backward compatibility

    func testMissingAnnotationsFieldDecodesAsEmpty() throws {
        // JSON without the "annotations" key — simulates a snapshot saved by an older version
        let json = """
        {
          "viewport": {"panX": 0, "panY": 0, "zoom": 1},
          "windows": []
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(WorkspaceSnapshot.self, from: json)
        XCTAssertEqual(decoded.annotations.count, 0)
    }

    // MARK: - ViewportState

    func testViewportStateRoundTrip() throws {
        let vp = WorkspaceSnapshot.ViewportState(panX: -100, panY: 50, zoom: 0.5)
        let data = try JSONEncoder().encode(vp)
        let decoded = try JSONDecoder().decode(WorkspaceSnapshot.ViewportState.self, from: data)
        XCTAssertEqual(decoded.panX, -100)
        XCTAssertEqual(decoded.panY,   50)
        XCTAssertEqual(decoded.zoom,  0.5)
    }
}
