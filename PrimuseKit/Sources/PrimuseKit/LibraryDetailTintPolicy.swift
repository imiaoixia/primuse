import Foundation

/// 详情页底色的一段颜色，HSB 三个分量都在 0...1。
///
/// 刻意不用平台颜色类型：压深与对比度这套规则要能在没有图形栈的地方直接跑测试。
public struct LibraryDetailTintStop: Equatable, Sendable {
    public let hue: Double
    public let saturation: Double
    public let brightness: Double

    public init(hue: Double, saturation: Double, brightness: Double) {
        self.hue = hue
        self.saturation = saturation
        self.brightness = brightness
    }
}

/// 一整页详情页的底色：顶部一段、底部一段，中间线性过渡。
public struct LibraryDetailTint: Equatable, Sendable {
    public let top: LibraryDetailTintStop
    public let bottom: LibraryDetailTintStop

    public init(top: LibraryDetailTintStop, bottom: LibraryDetailTintStop) {
        self.top = top
        self.bottom = bottom
    }
}

/// 详情页的网格底色：封面切成 `columns × rows` 块，每块取一个颜色放在对应的格点上，
/// 交给 MeshGradient 在格点之间插值 —— 页面上看得出封面左上偏红、右下偏蓝这样的走向，
/// 而不是一种颜色从上到下由浅到深。
///
/// 每个格点都单独压到白字读得清，插值出来的颜色不会比两端更亮，所以整页仍然只用白字。
public struct LibraryDetailMeshTint: Equatable, Sendable {
    public static let columns = 3
    public static let rows = 3
    public static let stopCount = columns * rows

    /// 行优先，长度恒为 `stopCount`。第 0 行在页面顶部。
    public let stops: [LibraryDetailTintStop]

    public init(stops: [LibraryDetailTintStop]) {
        precondition(stops.count == Self.stopCount, "网格底色要有 \(Self.stopCount) 个格点")
        self.stops = stops
    }

    public func stop(column: Int, row: Int) -> LibraryDetailTintStop {
        stops[row * Self.columns + column]
    }
}

/// 专辑 / 艺术家 / 风格详情页那块随封面变化的底色怎么定。
///
/// 封面主色直接铺满一页是不能用的：饱和度高的封面会刺眼，亮色封面上白字会糊掉。
/// 这里把封面色的**色相**留下来当身份，饱和度收进一个区间，亮度压到白字读得清
/// 为止 —— 所以整页(头图、歌曲列表、页尾)可以共用一个前景色，看上去才是一体的。
public enum LibraryDetailTintPolicy {
    public enum Appearance: Sendable, Equatable {
        case light
        case dark
    }

    /// 正文一律白字，底色必须先满足这个对比度才允许上屏。WCAG AA 的正文门槛。
    public static let minimumContrastRatio = 4.5

    /// 饱和度区间。下限保证还看得出是"这张封面的颜色"，上限挡住霓虹色封面。
    private static let minimumSaturation = 0.24
    private static let maximumSaturation = 0.58
    /// 低于这个饱和度的封面(黑白照、灰调专辑)不硬凑颜色，当作中性底处理。
    private static let achromaticSaturation = 0.08
    private static let achromaticTintSaturation = 0.10

    /// 底部相对顶部的亮度系数。差太小看不出层次，差太大又会像两块色。
    private static let bottomBrightnessFactor = 0.58

    /// 取不到封面色时的中性底：偏蓝的深灰，不会被误认成某张封面的颜色。
    private static let neutralHue = 0.62
    private static let neutralSaturation = 0.06

    /// - Parameters:
    ///   - hue: 封面主色的色相，允许超出 0...1(会归一化)。
    ///   - saturation: 封面主色的饱和度。
    ///   - brightness: 封面主色的明度，只用来在区间内微调，不直接采用。
    public static func tint(
        hue: Double,
        saturation: Double,
        brightness: Double,
        appearance: Appearance
    ) -> LibraryDetailTint {
        let sourceSaturation = clamp01(saturation)
        guard sourceSaturation >= achromaticSaturation else {
            return neutralTint(appearance: appearance)
        }

        let normalizedHue = normalizedHue(hue)
        let tintSaturation = min(max(sourceSaturation, minimumSaturation), maximumSaturation)
        return tint(
            hue: normalizedHue,
            tintSaturation: tintSaturation,
            sourceBrightness: clamp01(brightness),
            appearance: appearance
        )
    }

    /// 封面读不出代表色时用的底色。加载途中也先用它，颜色到位后再过渡。
    public static func neutralTint(appearance: Appearance) -> LibraryDetailTint {
        tint(
            hue: neutralHue,
            tintSaturation: neutralSaturation,
            sourceBrightness: 0.5,
            appearance: appearance
        )
    }

    // MARK: - 网格底色

    /// 网格里分块明暗带动页面的幅度：比单色底色的 ±12% 放宽到 ±18%，封面的明暗结构才透得出来。
    private static let meshBrightnessSpread = 0.36
    /// 网格里饱和度的上限比单色底色再低一档：几种色相挤在一页上，个个都饱和就花了。
    private static let meshMaximumSaturation = 0.52
    /// 读不出颜色的那几块(黑白、灰调)沿用主色的色相、饱和度减半，页面上不会凭空冒出一块灰。
    private static let meshAchromaticSaturationFactor = 0.5

    /// 按封面分块取到的颜色排出整页的网格底色。
    ///
    /// - Parameters:
    ///   - regions: 封面分块的颜色，行优先排成 `LibraryDetailMeshTint.columns × rows`，第 0 行是封面顶部；
    ///     读不出颜色的那一块给 nil。个数不够时缺的按 nil 处理，多出来的忽略。
    ///   - hue: 整张封面的主色色相，给读不出颜色的那几块定色相。
    ///   - saturation: 整张封面的主色饱和度。
    ///   - brightness: 整张封面的主色明度。
    public static func meshTint(
        regions: [LibraryDetailTintStop?],
        hue: Double,
        saturation: Double,
        brightness: Double,
        appearance: Appearance
    ) -> LibraryDetailMeshTint {
        let base = tint(hue: hue, saturation: saturation, brightness: brightness, appearance: appearance)
        return meshTint(regions: regions, base: base.top, appearance: appearance)
    }

    /// 读不出封面色时的网格底色：每一格都是中性底，只保留上浅下深。加载途中也先用它。
    public static func neutralMeshTint(appearance: Appearance) -> LibraryDetailMeshTint {
        meshTint(regions: [], base: neutralTint(appearance: appearance).top, appearance: appearance)
    }

    /// 第 `row` 行相对顶部的亮度系数：顶行和头图收尾的颜色一样亮，往下越来越沉，
    /// 末行和单色底色的页尾一样深 —— 长列表压在页面下半截也读得清白字。
    static func meshRowBrightnessFactor(row: Int) -> Double {
        let lastRow = max(1, LibraryDetailMeshTint.rows - 1)
        let progress = Double(min(max(0, row), lastRow)) / Double(lastRow)
        return 1 - (1 - bottomBrightnessFactor) * pow(progress, 1.4)
    }

    private static func meshTint(
        regions: [LibraryDetailTintStop?],
        base: LibraryDetailTintStop,
        appearance: Appearance
    ) -> LibraryDetailMeshTint {
        let target = targetBrightness(for: appearance)
        var stops: [LibraryDetailTintStop] = []
        stops.reserveCapacity(LibraryDetailMeshTint.stopCount)
        for row in 0..<LibraryDetailMeshTint.rows {
            let rowFactor = meshRowBrightnessFactor(row: row)
            for column in 0..<LibraryDetailMeshTint.columns {
                let index = row * LibraryDetailMeshTint.columns + column
                let region = index < regions.count ? regions[index] : nil
                let hue: Double
                let saturation: Double
                let sourceBrightness: Double
                if let region, clamp01(region.saturation) >= achromaticSaturation {
                    hue = normalizedHue(region.hue)
                    saturation = min(max(clamp01(region.saturation), minimumSaturation), meshMaximumSaturation)
                    sourceBrightness = clamp01(region.brightness)
                } else {
                    hue = base.hue
                    saturation = base.saturation * meshAchromaticSaturationFactor
                    sourceBrightness = region.map { clamp01($0.brightness) } ?? 0.5
                }
                let nudge = 1 - meshBrightnessSpread / 2 + meshBrightnessSpread * sourceBrightness
                let brightness = readableBrightness(
                    hue: hue,
                    saturation: saturation,
                    preferred: target * nudge * rowFactor
                )
                stops.append(LibraryDetailTintStop(hue: hue, saturation: saturation, brightness: brightness))
            }
        }
        return LibraryDetailMeshTint(stops: stops)
    }

    /// 浅色外观下整页可以稍亮一点，但仍然是"深色页配白字"，跟深色外观同一套版式。
    private static func targetBrightness(for appearance: Appearance) -> Double {
        appearance == .dark ? 0.28 : 0.34
    }

    private static func tint(
        hue: Double,
        tintSaturation: Double,
        sourceBrightness: Double,
        appearance: Appearance
    ) -> LibraryDetailTint {
        let target = targetBrightness(for: appearance)
        // 封面本身的明暗只在 ±12% 内影响页面，避免深色封面把页面压成纯黑。
        let nudged = target * (0.88 + 0.24 * sourceBrightness)

        let topBrightness = readableBrightness(
            hue: hue,
            saturation: tintSaturation,
            preferred: nudged
        )
        let top = LibraryDetailTintStop(
            hue: hue,
            saturation: tintSaturation,
            brightness: topBrightness
        )
        let bottom = LibraryDetailTintStop(
            hue: hue,
            saturation: tintSaturation,
            brightness: topBrightness * bottomBrightnessFactor
        )
        return LibraryDetailTint(top: top, bottom: bottom)
    }

    /// 在不超过 `preferred` 的前提下取最亮的那个仍满足对比度的亮度。
    ///
    /// 亮度升高则相对亮度单调升高、与白色的对比度单调下降，所以可以二分。
    private static func readableBrightness(
        hue: Double,
        saturation: Double,
        preferred: Double
    ) -> Double {
        let candidate = LibraryDetailTintStop(
            hue: hue,
            saturation: saturation,
            brightness: preferred
        )
        if contrastRatioAgainstWhite(candidate) >= minimumContrastRatio {
            return preferred
        }

        var low = 0.0
        var high = preferred
        for _ in 0..<24 {
            let mid = (low + high) / 2
            let stop = LibraryDetailTintStop(hue: hue, saturation: saturation, brightness: mid)
            if contrastRatioAgainstWhite(stop) >= minimumContrastRatio {
                low = mid
            } else {
                high = mid
            }
        }
        return low
    }

    // MARK: - 颜色计算

    /// 白色与该底色的 WCAG 对比度。
    public static func contrastRatioAgainstWhite(_ stop: LibraryDetailTintStop) -> Double {
        (1.0 + 0.05) / (relativeLuminance(of: stop) + 0.05)
    }

    /// sRGB 相对亮度。
    public static func relativeLuminance(of stop: LibraryDetailTintStop) -> Double {
        let rgb = rgbComponents(of: stop)
        return 0.2126 * linearize(rgb.red)
            + 0.7152 * linearize(rgb.green)
            + 0.0722 * linearize(rgb.blue)
    }

    /// HSB → sRGB。平台颜色类型的同名转换在这里手写一份，测试才跑得起来。
    public static func rgbComponents(
        of stop: LibraryDetailTintStop
    ) -> (red: Double, green: Double, blue: Double) {
        let hue = normalizedHue(stop.hue)
        let saturation = clamp01(stop.saturation)
        let brightness = clamp01(stop.brightness)

        guard saturation > 0 else { return (brightness, brightness, brightness) }

        let sector = hue * 6
        let index = Int(sector.rounded(.down)) % 6
        let offset = sector - sector.rounded(.down)
        let p = brightness * (1 - saturation)
        let q = brightness * (1 - saturation * offset)
        let t = brightness * (1 - saturation * (1 - offset))

        switch index {
        case 0: return (brightness, t, p)
        case 1: return (q, brightness, p)
        case 2: return (p, brightness, t)
        case 3: return (p, q, brightness)
        case 4: return (t, p, brightness)
        default: return (brightness, p, q)
        }
    }

    /// sRGB → HSB，`rgbComponents(of:)` 的反向。
    public static func hsbStop(red: Double, green: Double, blue: Double) -> LibraryDetailTintStop {
        let r = clamp01(red)
        let g = clamp01(green)
        let b = clamp01(blue)
        let maximum = max(r, g, b)
        let minimum = min(r, g, b)
        let delta = maximum - minimum
        guard maximum > 0, delta > 0 else {
            return LibraryDetailTintStop(hue: 0, saturation: 0, brightness: maximum)
        }

        let sector: Double
        if maximum == r {
            sector = (g - b) / delta
        } else if maximum == g {
            sector = (b - r) / delta + 2
        } else {
            sector = (r - g) / delta + 4
        }
        return LibraryDetailTintStop(
            hue: normalizedHue(sector / 6),
            saturation: delta / maximum,
            brightness: maximum
        )
    }

    private static func linearize(_ component: Double) -> Double {
        component <= 0.04045
            ? component / 12.92
            : pow((component + 0.055) / 1.055, 2.4)
    }

    private static func normalizedHue(_ hue: Double) -> Double {
        guard hue.isFinite else { return 0 }
        let wrapped = hue.truncatingRemainder(dividingBy: 1)
        return wrapped < 0 ? wrapped + 1 : wrapped
    }

    private static func clamp01(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}

/// 把封面按网格分块取色，给详情页的网格底色和首页卡片的网格衬底用。
///
/// 输入是已经缩小到 `sampleWidth × sampleHeight` 的像素，每像素 4 字节、前三字节是 RGB，
/// 行优先、第 0 行是图像顶部。每一块按饱和度加权平均：一块里大半是灰底、只有一小片鲜艳的颜色时，
/// 取出来的是那片颜色，而不是一团泥色。
public enum ArtworkMeshSampler {
    /// 每一块缩成 8×8 个像素来取色。
    public static let cellSide = 8
    public static let sampleWidth = LibraryDetailMeshTint.columns * cellSide
    public static let sampleHeight = LibraryDetailMeshTint.rows * cellSide

    /// - Returns: 行优先的 `LibraryDetailMeshTint.stopCount` 个颜色；像素不够的那一块给 nil。
    public static func regions(
        pixels: [UInt8],
        width: Int,
        height: Int,
        bytesPerRow: Int
    ) -> [LibraryDetailTintStop?] {
        let columns = LibraryDetailMeshTint.columns
        let rows = LibraryDetailMeshTint.rows
        guard width >= columns, height >= rows, bytesPerRow >= width * 4,
              pixels.count >= bytesPerRow * (height - 1) + width * 4 else {
            return Array(repeating: nil, count: LibraryDetailMeshTint.stopCount)
        }

        var result: [LibraryDetailTintStop?] = []
        result.reserveCapacity(LibraryDetailMeshTint.stopCount)
        for row in 0..<rows {
            let top = row * height / rows
            let bottom = (row + 1) * height / rows
            for column in 0..<columns {
                let leading = column * width / columns
                let trailing = (column + 1) * width / columns
                var red = 0.0
                var green = 0.0
                var blue = 0.0
                var totalWeight = 0.0
                for y in top..<bottom {
                    for x in leading..<trailing {
                        let offset = y * bytesPerRow + x * 4
                        let r = Double(pixels[offset]) / 255
                        let g = Double(pixels[offset + 1]) / 255
                        let b = Double(pixels[offset + 2]) / 255
                        let pixelWeight = weight(red: r, green: g, blue: b)
                        red += r * pixelWeight
                        green += g * pixelWeight
                        blue += b * pixelWeight
                        totalWeight += pixelWeight
                    }
                }
                guard totalWeight > 0 else {
                    result.append(nil)
                    continue
                }
                result.append(LibraryDetailTintPolicy.hsbStop(
                    red: red / totalWeight,
                    green: green / totalWeight,
                    blue: blue / totalWeight
                ))
            }
        }
        return result
    }

    /// 越鲜艳的像素分量越重；近黑、近白的像素只算一点，免得暗角和留白把一块的颜色冲淡。
    private static func weight(red: Double, green: Double, blue: Double) -> Double {
        let maximum = max(red, green, blue)
        let minimum = min(red, green, blue)
        let saturation = maximum > 0 ? (maximum - minimum) / maximum : 0
        var result = 0.3 + 2.5 * saturation * saturation
        if maximum < 0.08 { result *= 0.35 }
        if minimum > 0.94 { result *= 0.5 }
        return result
    }
}
