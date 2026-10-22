import Foundation
import Testing
@testable import PrimuseKit

/// 扫一遍色相环 × 饱和度 × 明度，用来验证"任何封面都得出能用的底色"这类不变量。
private func sweepTints(
    appearance: LibraryDetailTintPolicy.Appearance
) -> [(input: (hue: Double, saturation: Double, brightness: Double), tint: LibraryDetailTint)] {
    var results:
        [(input: (hue: Double, saturation: Double, brightness: Double), tint: LibraryDetailTint)] = []
    for hueStep in 0..<12 {
        let hue = Double(hueStep) / 12
        for saturation in [0.12, 0.35, 0.68, 1.0] {
            for brightness in [0.05, 0.4, 0.75, 1.0] {
                let tint = LibraryDetailTintPolicy.tint(
                    hue: hue,
                    saturation: saturation,
                    brightness: brightness,
                    appearance: appearance
                )
                results.append(((hue, saturation, brightness), tint))
            }
        }
    }
    return results
}

@Suite("详情页底色")
struct LibraryDetailTintPolicyTests {
    @Test("任何封面色算出的底色都够白字读", arguments: [
        LibraryDetailTintPolicy.Appearance.light,
        LibraryDetailTintPolicy.Appearance.dark,
    ])
    func contrastHoldsForEveryArtworkColor(appearance: LibraryDetailTintPolicy.Appearance) {
        for entry in sweepTints(appearance: appearance) {
            let top = LibraryDetailTintPolicy.contrastRatioAgainstWhite(entry.tint.top)
            let bottom = LibraryDetailTintPolicy.contrastRatioAgainstWhite(entry.tint.bottom)
            #expect(
                top >= LibraryDetailTintPolicy.minimumContrastRatio,
                "顶部底色对比度不足: \(entry.input) → \(top)"
            )
            #expect(
                bottom >= LibraryDetailTintPolicy.minimumContrastRatio,
                "底部底色对比度不足: \(entry.input) → \(bottom)"
            )
        }
    }

    @Test("中性底同样满足对比度，且看不出偏色")
    func neutralTintIsReadableAndAchromatic() {
        for appearance in [LibraryDetailTintPolicy.Appearance.light, .dark] {
            let tint = LibraryDetailTintPolicy.neutralTint(appearance: appearance)
            let contrast = LibraryDetailTintPolicy.contrastRatioAgainstWhite(tint.top)
            #expect(contrast >= LibraryDetailTintPolicy.minimumContrastRatio)
            #expect(tint.top.saturation <= 0.1)
        }
    }

    @Test("灰度封面走中性底，不硬凑颜色")
    func achromaticArtworkFallsBackToNeutral() {
        let tint = LibraryDetailTintPolicy.tint(
            hue: 0.08,
            saturation: 0.03,
            brightness: 0.62,
            appearance: .dark
        )
        let neutral = LibraryDetailTintPolicy.neutralTint(appearance: .dark)
        #expect(tint == neutral)
    }

    @Test("页尾比页首深，但不会塌成纯黑")
    func bottomIsDeeperThanTop() {
        for entry in sweepTints(appearance: .dark) {
            #expect(entry.tint.bottom.brightness < entry.tint.top.brightness)
            #expect(entry.tint.bottom.brightness > 0)
        }
    }

    @Test("封面的色相是页面身份，原样保留")
    func hueSurvives() {
        for entry in sweepTints(appearance: .light) {
            guard entry.input.saturation >= 0.12 else { continue }
            #expect(abs(entry.tint.top.hue - entry.input.hue) < 0.0001)
            #expect(abs(entry.tint.bottom.hue - entry.input.hue) < 0.0001)
        }
    }

    @Test("饱和度收进区间：霓虹封面压下来，寡淡封面抬上去")
    func saturationIsClamped() {
        let neon = LibraryDetailTintPolicy.tint(
            hue: 0.33,
            saturation: 1.0,
            brightness: 0.9,
            appearance: .dark
        )
        #expect(neon.top.saturation <= 0.58)

        let faint = LibraryDetailTintPolicy.tint(
            hue: 0.33,
            saturation: 0.14,
            brightness: 0.5,
            appearance: .dark
        )
        #expect(faint.top.saturation >= 0.24)
    }

    @Test("深色外观比浅色外观更深")
    func darkAppearanceIsDeeper() {
        let light = LibraryDetailTintPolicy.tint(
            hue: 0.52,
            saturation: 0.45,
            brightness: 0.6,
            appearance: .light
        )
        let dark = LibraryDetailTintPolicy.tint(
            hue: 0.52,
            saturation: 0.45,
            brightness: 0.6,
            appearance: .dark
        )
        #expect(dark.top.brightness < light.top.brightness)
    }

    @Test("越亮的封面给越亮的页面，但幅度有限")
    func brighterArtworkGivesBrighterPageWithinBounds() {
        let dim = LibraryDetailTintPolicy.tint(
            hue: 0.75,
            saturation: 0.4,
            brightness: 0.1,
            appearance: .dark
        )
        let bright = LibraryDetailTintPolicy.tint(
            hue: 0.75,
            saturation: 0.4,
            brightness: 1.0,
            appearance: .dark
        )
        #expect(bright.top.brightness > dim.top.brightness)
        #expect(bright.top.brightness / dim.top.brightness < 1.3)
    }

    @Test("底色深浅落在同一条带里，不会一页发白一页全黑")
    func luminanceStaysInBand() {
        // 白字要读得清的相对亮度上限，和 minimumContrastRatio 是同一件事的两种说法。
        let ceiling = 1.05 / LibraryDetailTintPolicy.minimumContrastRatio - 0.05
        for appearance in [LibraryDetailTintPolicy.Appearance.light, .dark] {
            for entry in sweepTints(appearance: appearance) {
                let luminance = LibraryDetailTintPolicy.relativeLuminance(of: entry.tint.top)
                #expect(luminance <= ceiling, "底色过亮: \(entry.input)")
                #expect(luminance >= 0.005, "底色塌成纯黑: \(entry.input)")
            }
        }
    }

    @Test("色相越界与非法输入都不会算出坏颜色")
    func outOfRangeInputsAreNormalized() {
        let wrapped = LibraryDetailTintPolicy.tint(
            hue: 1.4,
            saturation: 0.5,
            brightness: 0.5,
            appearance: .dark
        )
        #expect(abs(wrapped.top.hue - 0.4) < 0.0001)

        let negative = LibraryDetailTintPolicy.tint(
            hue: -0.25,
            saturation: 0.5,
            brightness: 0.5,
            appearance: .dark
        )
        #expect(abs(negative.top.hue - 0.75) < 0.0001)

        let broken = LibraryDetailTintPolicy.tint(
            hue: .nan,
            saturation: .infinity,
            brightness: .nan,
            appearance: .dark
        )
        #expect(broken.top.hue.isFinite)
        #expect(broken.top.brightness > 0)
        let brokenContrast = LibraryDetailTintPolicy.contrastRatioAgainstWhite(broken.top)
        #expect(brokenContrast >= LibraryDetailTintPolicy.minimumContrastRatio)
    }

    @Test("HSB 转 RGB 与标准换算一致")
    func hsbToRGBMatchesReference() {
        let red = LibraryDetailTintPolicy.rgbComponents(
            of: LibraryDetailTintStop(hue: 0, saturation: 1, brightness: 1)
        )
        #expect(abs(red.red - 1) < 0.0001)
        #expect(abs(red.green) < 0.0001)
        #expect(abs(red.blue) < 0.0001)

        let cyan = LibraryDetailTintPolicy.rgbComponents(
            of: LibraryDetailTintStop(hue: 0.5, saturation: 1, brightness: 1)
        )
        #expect(abs(cyan.red) < 0.0001)
        #expect(abs(cyan.green - 1) < 0.0001)
        #expect(abs(cyan.blue - 1) < 0.0001)

        let gray = LibraryDetailTintPolicy.rgbComponents(
            of: LibraryDetailTintStop(hue: 0.3, saturation: 0, brightness: 0.42)
        )
        #expect(abs(gray.red - 0.42) < 0.0001)
        #expect(abs(gray.green - 0.42) < 0.0001)
        #expect(abs(gray.blue - 0.42) < 0.0001)
    }
}

/// 一张 `ArtworkMeshSampler.sampleWidth × sampleHeight` 的测试图：每个像素的颜色由坐标决定。
private func samplePixels(
    _ color: (_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8)
) -> [UInt8] {
    let width = ArtworkMeshSampler.sampleWidth
    let height = ArtworkMeshSampler.sampleHeight
    var pixels = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let (red, green, blue) = color(x, y)
            let offset = (y * width + x) * 4
            pixels[offset] = red
            pixels[offset + 1] = green
            pixels[offset + 2] = blue
        }
    }
    return pixels
}

private func sampledRegions(_ pixels: [UInt8]) -> [LibraryDetailTintStop?] {
    ArtworkMeshSampler.regions(
        pixels: pixels,
        width: ArtworkMeshSampler.sampleWidth,
        height: ArtworkMeshSampler.sampleHeight,
        bytesPerRow: ArtworkMeshSampler.sampleWidth * 4
    )
}

@Suite("详情页网格底色")
struct LibraryDetailMeshTintTests {
    /// 色相环上挑几种颜色，按格点轮流摆，模拟一张颜色很杂的封面。
    private func mixedRegions(offset: Int) -> [LibraryDetailTintStop?] {
        let palette: [LibraryDetailTintStop?] = [
            LibraryDetailTintStop(hue: 0.02, saturation: 0.9, brightness: 0.95),
            LibraryDetailTintStop(hue: 0.16, saturation: 1.0, brightness: 1.0),
            LibraryDetailTintStop(hue: 0.33, saturation: 0.7, brightness: 0.6),
            nil,
            LibraryDetailTintStop(hue: 0.58, saturation: 0.5, brightness: 0.2),
            LibraryDetailTintStop(hue: 0.75, saturation: 0.04, brightness: 0.98),
            LibraryDetailTintStop(hue: 0.9, saturation: 0.35, brightness: 0.05),
        ]
        return (0..<LibraryDetailMeshTint.stopCount).map { palette[($0 + offset) % palette.count] }
    }

    @Test("每个格点都够白字读", arguments: [
        LibraryDetailTintPolicy.Appearance.light,
        LibraryDetailTintPolicy.Appearance.dark,
    ])
    func everyStopIsReadable(appearance: LibraryDetailTintPolicy.Appearance) {
        for offset in 0..<7 {
            let mesh = LibraryDetailTintPolicy.meshTint(
                regions: mixedRegions(offset: offset),
                hue: 0.6,
                saturation: 0.5,
                brightness: 0.7,
                appearance: appearance
            )
            #expect(mesh.stops.count == LibraryDetailMeshTint.stopCount)
            for stop in mesh.stops {
                let contrast = LibraryDetailTintPolicy.contrastRatioAgainstWhite(stop)
                #expect(contrast >= LibraryDetailTintPolicy.minimumContrastRatio, "格点对比度不足: \(stop)")
                #expect(stop.brightness > 0, "格点塌成纯黑: \(stop)")
                #expect(stop.saturation <= 0.58)
            }
        }
    }

    @Test("有颜色的那一块保留自己的色相")
    func chromaticRegionsKeepTheirHue() {
        let regions = mixedRegions(offset: 0)
        let mesh = LibraryDetailTintPolicy.meshTint(
            regions: regions,
            hue: 0.6,
            saturation: 0.5,
            brightness: 0.7,
            appearance: .dark
        )
        for (region, stop) in zip(regions, mesh.stops) {
            guard let region, region.saturation >= 0.08 else { continue }
            #expect(abs(stop.hue - region.hue) < 0.0001)
        }
    }

    @Test("读不出颜色的那一块沿用主色的色相，不冒出一块灰")
    func achromaticRegionsFollowDominantHue() {
        var regions = [LibraryDetailTintStop?](repeating: nil, count: LibraryDetailMeshTint.stopCount)
        regions[0] = LibraryDetailTintStop(hue: 0.1, saturation: 0.02, brightness: 0.9)
        let mesh = LibraryDetailTintPolicy.meshTint(
            regions: regions,
            hue: 0.62,
            saturation: 0.6,
            brightness: 0.5,
            appearance: .dark
        )
        for stop in mesh.stops {
            #expect(abs(stop.hue - 0.62) < 0.0001)
            #expect(stop.saturation > 0.1)
        }
    }

    @Test("同一列越往下越深")
    func rowsGetDeeperTowardTheBottom() {
        for hueStep in 0..<12 {
            let region = LibraryDetailTintStop(hue: Double(hueStep) / 12, saturation: 0.6, brightness: 0.7)
            let mesh = LibraryDetailTintPolicy.meshTint(
                regions: Array(repeating: region, count: LibraryDetailMeshTint.stopCount),
                hue: region.hue,
                saturation: region.saturation,
                brightness: region.brightness,
                appearance: .light
            )
            for column in 0..<LibraryDetailMeshTint.columns {
                for row in 1..<LibraryDetailMeshTint.rows {
                    let upper = mesh.stop(column: column, row: row - 1)
                    let lower = mesh.stop(column: column, row: row)
                    #expect(lower.brightness < upper.brightness)
                }
            }
        }
    }

    @Test("中性网格底色看不出偏色，个数不够的分块按读不出处理")
    func neutralMeshIsAchromatic() {
        for appearance in [LibraryDetailTintPolicy.Appearance.light, .dark] {
            let neutral = LibraryDetailTintPolicy.neutralMeshTint(appearance: appearance)
            #expect(neutral.stops.count == LibraryDetailMeshTint.stopCount)
            for stop in neutral.stops {
                #expect(stop.saturation <= 0.1)
                let contrast = LibraryDetailTintPolicy.contrastRatioAgainstWhite(stop)
                #expect(contrast >= LibraryDetailTintPolicy.minimumContrastRatio)
            }
        }
        let short = LibraryDetailTintPolicy.meshTint(
            regions: [LibraryDetailTintStop(hue: 0.3, saturation: 0.8, brightness: 0.8)],
            hue: 0.3,
            saturation: 0.8,
            brightness: 0.8,
            appearance: .dark
        )
        #expect(short.stops.count == LibraryDetailMeshTint.stopCount)
    }

    @Test("RGB 转 HSB 与 HSB 转 RGB 互逆")
    func hsbRoundTrips() {
        for hueStep in 0..<12 {
            let stop = LibraryDetailTintStop(hue: Double(hueStep) / 12, saturation: 0.65, brightness: 0.8)
            let rgb = LibraryDetailTintPolicy.rgbComponents(of: stop)
            let back = LibraryDetailTintPolicy.hsbStop(red: rgb.red, green: rgb.green, blue: rgb.blue)
            #expect(abs(back.hue - stop.hue) < 0.0001)
            #expect(abs(back.saturation - stop.saturation) < 0.0001)
            #expect(abs(back.brightness - stop.brightness) < 0.0001)
        }
        let gray = LibraryDetailTintPolicy.hsbStop(red: 0.4, green: 0.4, blue: 0.4)
        #expect(gray.saturation == 0)
        #expect(abs(gray.brightness - 0.4) < 0.0001)
    }

    @Test("分块取色按封面的位置排：左边红、右边蓝")
    func samplerFollowsArtworkLayout() {
        let pixels = samplePixels { x, _ in
            x < ArtworkMeshSampler.sampleWidth / 2 ? (220, 30, 30) : (30, 40, 220)
        }
        let regions = sampledRegions(pixels)
        #expect(regions.count == LibraryDetailMeshTint.stopCount)
        for row in 0..<LibraryDetailMeshTint.rows {
            let leading = regions[row * LibraryDetailMeshTint.columns]
            let trailing = regions[row * LibraryDetailMeshTint.columns + LibraryDetailMeshTint.columns - 1]
            #expect(leading.map { $0.hue < 0.05 || $0.hue > 0.95 } == true)
            #expect(leading.map { $0.saturation > 0.7 } == true)
            #expect(trailing.map { abs($0.hue - 0.66) < 0.05 } == true)
        }
    }

    @Test("一块里大半是灰底时取出来的是那片鲜艳的颜色")
    func samplerFavorsVividPixels() {
        // 每一块左上角 3×3 是纯绿，其余是中灰。
        let pixels = samplePixels { x, y in
            x % ArtworkMeshSampler.cellSide < 3 && y % ArtworkMeshSampler.cellSide < 3
                ? (20, 200, 40)
                : (128, 128, 128)
        }
        for region in sampledRegions(pixels) {
            #expect(region.map { abs($0.hue - 0.35) < 0.06 } == true)
            #expect(region.map { $0.saturation > 0.24 } == true)
        }
    }

    @Test("像素不够时每一块都读不出")
    func samplerRejectsShortInput() {
        let regions = ArtworkMeshSampler.regions(pixels: [0, 0, 0, 0], width: 24, height: 24, bytesPerRow: 96)
        #expect(regions.count == LibraryDetailMeshTint.stopCount)
        #expect(regions.allSatisfy { $0 == nil })
    }
}
