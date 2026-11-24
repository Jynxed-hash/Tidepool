#if os(macOS)
import CoreGraphics
import Testing
@testable import Tidepool

private func expectClose(_ actual: CGFloat, _ expected: CGFloat) {
    #expect(abs(actual - expected) < 0.001)
}

@Test func allowanceMarkMatchesTheStaticSvgWithoutUsage() {
    let widths = AllowanceMark.widths(usedPercent: nil, needsYou: false)
    #expect(widths == [10.5, 8, 5])
    let bars = AllowanceMark.bars(usedPercent: nil, needsYou: false)
    #expect(bars.map(\.minX) == [2, 2, 2])
    #expect(bars.map(\.minY) == [12, 7.5, 3])
    #expect(bars.map(\.width) == widths)
    #expect(bars.map(\.height) == [3, 3, 3])
    #expect(AllowanceMark.canvas == 18)
    #expect(AllowanceMark.cornerRadius == 1.5)
}

@Test func allowanceNeedsYouExtendsOnlyTheTopBar() {
    let widths = AllowanceMark.widths(usedPercent: nil, needsYou: true)
    #expect(widths == [14, 8, 5])
    let bars = AllowanceMark.bars(usedPercent: nil, needsYou: true)
    #expect(bars[0].width == AllowanceMark.track)
    #expect(bars[0].maxX == 16)
    #expect(bars[1].width == 8)
    #expect(bars[2].width == 5)
    #expect(bars.map(\.minY) == [12, 7.5, 3])
}

@Test func allowanceBarsScaleWithFiveHourRemaining() {
    // 25% used leaves 75%, and 75% of the 14pt track is the static top bar.
    #expect(AllowanceMark.widths(usedPercent: 25, needsYou: false) == [10.5, 8, 5])

    let full = AllowanceMark.widths(usedPercent: 0, needsYou: false)
    #expect(full[0] == 14)
    expectClose(full[1], 14 * (8 / 10.5))
    expectClose(full[2], 14 * (5 / 10.5))

    let half = AllowanceMark.widths(usedPercent: 50, needsYou: false)
    #expect(half[0] == 7)
    expectClose(half[1], 7 * (8 / 10.5))
    expectClose(half[2], 7 * (5 / 10.5))

    #expect(AllowanceMark.widths(usedPercent: 100, needsYou: false) == [3, 3, 3])
    #expect(AllowanceMark.widths(usedPercent: 140, needsYou: false) == [3, 3, 3])
    #expect(AllowanceMark.widths(usedPercent: -20, needsYou: false) == full)
    #expect(AllowanceMark.widths(usedPercent: .nan, needsYou: false) == [10.5, 8, 5])
}

@Test func allowanceNeedsYouKeepsLiveLowerBarsAndFillsTheTop() {
    let widths = AllowanceMark.widths(usedPercent: 100, needsYou: true)
    #expect(widths == [14, 3, 3])
    let quiet = AllowanceMark.widths(usedPercent: 25, needsYou: true)
    #expect(quiet == [14, 8, 5])
}

@Test func allowanceBarsStayInsideTheCanvasAndDecrease() {
    let samples: [Double?] = [nil, 0, 25, 50, 75, 100]
    for sample in samples {
        for needsYou in [false, true] {
            let bars = AllowanceMark.bars(usedPercent: sample, needsYou: needsYou)
            #expect(bars.count == 3)
            #expect(bars[0].width >= bars[1].width)
            #expect(bars[1].width >= bars[2].width)
            for bar in bars {
                #expect(bar.minX == 2)
                #expect(bar.width >= AllowanceMark.minimumWidth)
                #expect(bar.maxX <= AllowanceMark.originX + AllowanceMark.track)
                #expect(bar.minY >= 0)
                #expect(bar.maxY <= AllowanceMark.canvas)
            }
        }
    }
}
#endif
