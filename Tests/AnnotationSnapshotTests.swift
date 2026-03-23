import Testing
import AppKit
@testable import Mosaic

struct AnnotationSnapshotTests {

    private func roundTrip(_ snap: AnnotationSnapshot) throws -> AnnotationSnapshot {
        try JSONDecoder().decode(AnnotationSnapshot.self,
                                 from: JSONEncoder().encode(snap))
    }

    // MARK: - Text

    @Test func textRoundTrip() throws {
        let id   = UUID()
        let snap = AnnotationSnapshot(id: id, kind: .text, x: 10, y: 20,
                                      width: 800, height: 175, content: "Hello canvas")
        let decoded = try roundTrip(snap)
        #expect(decoded.id      == id)
        #expect(decoded.kind    == .text)
        #expect(decoded.content == "Hello canvas")
        #expect(decoded.x       == 10)
        #expect(decoded.y       == 20)
        #expect(decoded.points  == nil)
        #expect(decoded.colorName == nil)
    }

    // MARK: - Arrow

    @Test func arrowRoundTrip() throws {
        let snap = AnnotationSnapshot(
            id: UUID(), kind: .arrow, x: 0, y: 0, width: 200, height: 150,
            points: [PointSnapshot(x: 10, y: 20), PointSnapshot(x: 180, y: 130)]
        )
        let decoded = try roundTrip(snap)
        #expect(decoded.kind           == .arrow)
        #expect(decoded.points?.count  == 2)
        #expect(decoded.points?[0].x   == 10)
        #expect(decoded.points?[1].y   == 130)
    }

    // MARK: - Freehand

    @Test func freehandRoundTrip() throws {
        let pts  = (0..<5).map { PointSnapshot(x: CGFloat($0) * 10, y: CGFloat($0) * 5) }
        let snap = AnnotationSnapshot(id: UUID(), kind: .freehand, x: 0, y: 0,
                                      width: 60, height: 30, points: pts, lineWidth: 3)
        let decoded = try roundTrip(snap)
        #expect(decoded.kind         == .freehand)
        #expect(decoded.lineWidth    == 3)
        #expect(decoded.points?.count == 5)
        #expect(decoded.points?.last?.x == 40)
    }

    // MARK: - Sticky note

    @Test func stickyNoteRoundTrip() throws {
        let snap = AnnotationSnapshot(id: UUID(), kind: .stickyNote, x: 50, y: 60,
                                      width: 200, height: 160,
                                      content: "Remember this!", colorName: "pink")
        let decoded = try roundTrip(snap)
        #expect(decoded.kind      == .stickyNote)
        #expect(decoded.colorName == "pink")
        #expect(decoded.content   == "Remember this!")
    }

    // MARK: - Image

    @Test func imageRoundTrip() throws {
        let snap = AnnotationSnapshot(id: UUID(), kind: .image, x: 100, y: 100,
                                      width: 400, height: 300, imagePath: "/tmp/test.png")
        let decoded = try roundTrip(snap)
        #expect(decoded.kind      == .image)
        #expect(decoded.imagePath == "/tmp/test.png")
    }

    // MARK: - Missing optionals

    @Test func missingOptionalsDecodeAsNil() throws {
        let json = """
        {"id":"00000000-0000-0000-0000-000000000001","kind":"text",
         "x":0,"y":0,"width":100,"height":50}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AnnotationSnapshot.self, from: json)
        #expect(decoded.content   == nil)
        #expect(decoded.colorName == nil)
        #expect(decoded.points    == nil)
        #expect(decoded.lineWidth == nil)
        #expect(decoded.imagePath == nil)
    }

    @Test func unknownKindThrows() {
        let json = """
        {"id":"00000000-0000-0000-0000-000000000002","kind":"unknown_future_kind",
         "x":0,"y":0,"width":10,"height":10}
        """.data(using: .utf8)!
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(AnnotationSnapshot.self, from: json)
        }
    }

    // MARK: - PointSnapshot

    @Test func pointSnapshotRoundTrip() throws {
        let decoded = try JSONDecoder().decode(
            PointSnapshot.self, from: JSONEncoder().encode(PointSnapshot(x: 3.14, y: -2.71)))
        #expect(abs(decoded.x - 3.14)  < 1e-10)
        #expect(abs(decoded.y - -2.71) < 1e-10)
    }
}
