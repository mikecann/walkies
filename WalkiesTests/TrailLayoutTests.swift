import Foundation
import Testing
@testable import Walkies

struct TrailLayoutTests {
    let bounds = CGRect(x: -100, y: -100, width: 200, height: 200)

    @Test func evenlySpacedFeetAlternateSidesAndFaceForwards() {
        let stamps = TrailLayout.stamps(along: [CGPoint.zero, CGPoint(x: 48, y: 0)], in: bounds)
        #expect(stamps.map(\.point.x) == [6, 18, 30, 42])
        #expect(stamps.map(\.isLeft) == [true, false, true, false])
        #expect(stamps.allSatisfy { $0.angle == 0 })
    }

    @Test func spacingContinuesAroundCornersAndDuplicateFixes() {
        let stamps = TrailLayout.stamps(along: [
            .zero, CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 30)
        ], in: bounds)
        #expect(stamps.map(\.point) == [CGPoint(x: 6, y: 0), CGPoint(x: 10, y: 8), CGPoint(x: 10, y: 20)])
        #expect(abs(stamps[1].angle - .pi / 2) < 0.0001)
        #expect(stamps.map(\.index) == [0, 1, 2])
    }

    @Test func sampleExactlyAtVertexIsOnlyDrawnOnce() {
        let stamps = TrailLayout.stamps(along: [.zero, CGPoint(x: 6, y: 0), CGPoint(x: 6, y: -20)], in: bounds)
        #expect(stamps.map(\.point) == [CGPoint(x: 6, y: 0), CGPoint(x: 6, y: -12)])
        #expect(abs(stamps[1].angle + .pi / 2) < 0.0001)
    }

    @Test func clippingKeepsGlobalPhaseAndSkipsLongOffscreenSections() {
        let viewport = CGRect(x: 0, y: -10, width: 48, height: 20)
        let stamps = TrailLayout.stamps(along: [CGPoint(x: -12_000_000, y: 0), CGPoint(x: 12_000_000, y: 0)], in: viewport)
        #expect(stamps.count == 4)
        #expect(stamps.map(\.point.x) == [6, 18, 30, 42])
        #expect(stamps.map(\.index) == [1_000_000, 1_000_001, 1_000_002, 1_000_003])
        #expect(TrailLayout.stamps(along: [CGPoint(x: 0, y: 100), CGPoint(x: 50, y: 100)], in: viewport).isEmpty)
    }

    @Test func reversedAndDiagonalSegmentsKeepTheirHeading() {
        let stamps = TrailLayout.stamps(along: [CGPoint(x: 24, y: 24), .zero], in: bounds)
        #expect(abs(stamps[0].angle + 3 * .pi / 4) < 0.0001)
        #expect(abs(hypot(stamps[1].point.x - stamps[0].point.x, stamps[1].point.y - stamps[0].point.y) - 12) < 0.0001)
    }

    @Test func invalidOrEmptyInputProducesNoStamps() {
        #expect(TrailLayout.stamps(along: [], in: bounds).isEmpty)
        #expect(TrailLayout.stamps(along: [.zero, .zero], in: bounds).isEmpty)
        #expect(TrailLayout.stamps(along: [.zero, CGPoint(x: 20, y: 0)], spacing: 0, in: bounds).isEmpty)
        #expect(TrailLayout.visibleRange(from: .zero, to: CGPoint(x: Double.infinity, y: 0), in: bounds) == nil)
    }
}
