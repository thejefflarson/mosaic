import XCTest
@testable import Mosaic

final class AnnotationSnapshotTests: XCTestCase {

    private func encode(_ snap: AnnotationSnapshot) throws -> Data {
        try JSONEncoder().encode(snap)
    }

    private func decode(_ data: Data) throws -> AnnotationSnapshot {
        try JSONDecoder().decode(AnnotationSnapshot.self, from: data)
    }

    // MARK: - Text

    func testTextRoundTrip() throws {
        let id = UUID()
        let snap = AnnotationSnapshot(
            id: id, kind: .text, x: 10, y: 20, width: 800, height: 175,
            content: "Hello canvas"
        )
        let decoded = try decode(encode(snap))
        XCTAssertEqual(decoded.id,      id)
        XCTAssertEqual(decoded.kind,    .text)
        XCTAssertEqual(decoded.content, "Hello canvas")
        XCTAssertEqual(decoded.x,  10)
        XCTAssertEqual(decoded.y,  20)
        XCTAssertNil(decoded.points)
        XCTAssertNil(decoded.colorName)
    }

    // MARK: - Arrow

    func testArrowRoundTrip() throws {
        let snap = AnnotationSnapshot(
            id: UUID(), kind: .arrow, x: 0, y: 0, width: 200, height: 150,
            points: [
                PointSnapshot(x: 10, y: 20),
                PointSnapshot(x: 180, y: 130),
            ]
        )
        let decoded = try decode(encode(snap))
        XCTAssertEqual(decoded.kind, .arrow)
        XCTAssertEqual(decoded.points?.count, 2)
        XCTAssertEqual(decoded.points?[0].x, 10)
        XCTAssertEqual(decoded.points?[1].y, 130)
    }

    // MARK: - Freehand

    func testFreehandRoundTrip() throws {
        let pts = (0..<5).map { PointSnapshot(x: CGFloat($0) * 10, y: CGFloat($0) * 5) }
        let snap = AnnotationSnapshot(
            id: UUID(), kind: .freehand, x: 0, y: 0, width: 60, height: 30,
            points: pts, lineWidth: 3
        )
        let decoded = try decode(encode(snap))
        XCTAssertEqual(decoded.kind,      .freehand)
        XCTAssertEqual(decoded.lineWidth, 3)
        XCTAssertEqual(decoded.points?.count, 5)
        XCTAssertEqual(decoded.points?.last?.x, 40)
    }

    // MARK: - Sticky note

    func testStickyNoteRoundTrip() throws {
        let snap = AnnotationSnapshot(
            id: UUID(), kind: .stickyNote, x: 50, y: 60, width: 200, height: 160,
            content: "Remember this!", colorName: "pink"
        )
        let decoded = try decode(encode(snap))
        XCTAssertEqual(decoded.kind,      .stickyNote)
        XCTAssertEqual(decoded.colorName, "pink")
        XCTAssertEqual(decoded.content,   "Remember this!")
    }

    // MARK: - Image

    func testImageRoundTrip() throws {
        let snap = AnnotationSnapshot(
            id: UUID(), kind: .image, x: 100, y: 100, width: 400, height: 300,
            imagePath: "/tmp/test.png"
        )
        let decoded = try decode(encode(snap))
        XCTAssertEqual(decoded.kind,      .image)
        XCTAssertEqual(decoded.imagePath, "/tmp/test.png")
    }

    // MARK: - Missing optionals

    func testMissingOptionalsDecodeAsNil() throws {
        // A minimal snapshot with only required fields
        let json = """
        {
          "id": "00000000-0000-0000-0000-000000000001",
          "kind": "text",
          "x": 0, "y": 0, "width": 100, "height": 50
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AnnotationSnapshot.self, from: json)
        XCTAssertNil(decoded.content)
        XCTAssertNil(decoded.colorName)
        XCTAssertNil(decoded.points)
        XCTAssertNil(decoded.lineWidth)
        XCTAssertNil(decoded.imagePath)
    }

    func testUnknownKindThrows() {
        let json = """
        {
          "id": "00000000-0000-0000-0000-000000000002",
          "kind": "unknown_future_kind",
          "x": 0, "y": 0, "width": 10, "height": 10
        }
        """.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(AnnotationSnapshot.self, from: json))
    }

    // MARK: - PointSnapshot

    func testPointSnapshotRoundTrip() throws {
        let pt = PointSnapshot(x: 3.14, y: -2.71)
        let decoded = try JSONDecoder().decode(
            PointSnapshot.self,
            from: try JSONEncoder().encode(pt)
        )
        XCTAssertEqual(decoded.x, 3.14, accuracy: 1e-10)
        XCTAssertEqual(decoded.y, -2.71, accuracy: 1e-10)
    }
}
