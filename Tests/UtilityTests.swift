import Testing
import AppKit
@testable import Mosaic

struct UtilityTests {

    // MARK: - Comparable.clamped

    @Test func clampedMidValue()      { #expect(5.clampedTo(1...10)     == 5)   }
    @Test func clampedLow()           { #expect((-5).clampedTo(0...100) == 0)   }
    @Test func clampedHigh()          { #expect(200.clampedTo(0...100)  == 100) }
    @Test func clampedAtLowerBound()  { #expect(0.clampedTo(0...10)     == 0)   }
    @Test func clampedAtUpperBound()  { #expect(10.clampedTo(0...10)    == 10)  }

    @Test func clampedFloat() {
        #expect(CGFloat(0.05).clamped(to: 0.1...3.0) == 0.1)
        #expect(CGFloat(1.5).clamped(to:  0.1...3.0) == 1.5)
        #expect(CGFloat(5.0).clamped(to:  0.1...3.0) == 3.0)
    }

    @Test func clampedDouble() {
        #expect(Double(-1.0).clamped(to: 0.0...1.0) == 0.0)
        #expect(Double(0.5).clamped(to:  0.0...1.0) == 0.5)
        #expect(Double(2.0).clamped(to:  0.0...1.0) == 1.0)
    }

    // MARK: - CGRect.center

    @Test func cgRectCenter() {
        let r = CGRect(x: 10, y: 20, width: 80, height: 60)
        #expect(r.center == CGPoint(x: 50, y: 50))
    }

    @Test func cgRectCenterSquare() {
        let r = CGRect(x: 0, y: 0, width: 100, height: 100)
        #expect(r.center == CGPoint(x: 50, y: 50))
    }

    // MARK: - CGPoint.distance

    @Test func distanceZero() {
        let p = CGPoint(x: 3, y: 4)
        #expect(p.distance(to: p) == 0)
    }

    @Test func distance3_4_5() {
        #expect(CGPoint(x: 0, y: 0).distance(to: CGPoint(x: 3, y: 4)) == 5)
    }

    @Test func distanceIsSymmetric() {
        let a = CGPoint(x: 1, y: 2)
        let b = CGPoint(x: 4, y: 6)
        #expect(a.distance(to: b) == b.distance(to: a))
    }

    // MARK: - CGRect center init

    @Test func cgRectCenterInit() {
        let center = CGPoint(x: 100, y: 200)
        let size   = CGSize(width: 60, height: 40)
        let rect   = CGRect(center: center, size: size)
        #expect(rect.midX == 100)
        #expect(rect.midY == 200)
        #expect(rect.width  == 60)
        #expect(rect.height == 40)
        #expect(rect.minX == 70)
        #expect(rect.minY == 180)
    }
}

private extension Int {
    func clampedTo(_ range: ClosedRange<Int>) -> Int { clamped(to: range) }
}
