import Foundation
import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif
import PrimuseKit

/// 一张封面取出来的全部颜色：主色双色给卡片光晕和沉浸播放器，
/// 分块色给详情页和首页卡片的网格底色(MeshGradient)。后台取色、主线程读，所以不挂在
/// 主线程隔离的 `CoverTintProvider` 里。
struct CoverTint: Sendable {
    var palette: ImmersiveArtworkPalette
    /// 行优先排成 `LibraryDetailMeshTint.columns × rows`，读不出颜色的那一块为 nil。
    var meshRegions: [LibraryDetailTintStop?]
}

/// Per-song dominant-color cache. Used by HomeView's recommendation /
/// continue-listening cards to tint their backgrounds with a soft
/// mesh pulled from the song's cover art — the "your music drives
/// the visuals" idea, no static decoration art needed.
///
/// Distinct from `ThemeService` (global accent for the currently
/// playing song): this never mutates app-wide state. Each card asks
/// for its own song's tint, gets a `Color?` back; the provider
/// schedules background extraction on first request and caches the
/// result for the rest of the app session.
@MainActor
@Observable
final class CoverTintProvider {
    /// In-memory cache: songID → derived tint. Reset on memory
    /// pressure via `clearCache()`. Covers don't change often, so a
    /// cold launch + extract pass for ~12 visible cards is cheap and
    /// the cache stays warm afterwards.
    private var cache: [String: CoverTint] = [:]
    /// A valid cover was decoded but contained no representative chromatic
    /// region. Remembering that negative result avoids re-decoding grayscale
    /// artwork every time HomeView refreshes.
    private var noColorCache: Set<String> = []
    private var inFlight: Set<String> = []
    private var invalidatedWhileInFlight: Set<String> = []
    /// Latest Home inputs let an artwork cache notification retry immediately
    /// even when the visible song identity itself did not change.
    private var knownSongs: [String: Song] = [:]

    /// Synchronous read. Returns the cached tint if extraction has
    /// finished. Returns nil while computation is pending — callers
    /// fall back to plain Material until the cache fills in, at which
    /// point @Observable triggers a re-render.
    func tint(forSongID songID: String) -> Color? {
        cache[songID]?.palette.primary
    }

    /// 沉浸播放器使用完整的明暗双色，而不是把一个固定色套到所有场景。
    func palette(forSongID songID: String) -> ImmersiveArtworkPalette? {
        cache[songID]?.palette
    }

    /// 封面按网格分块取到的颜色，跟 `tint(forSongID:)` 同一次取色得到。
    func meshRegions(forSongID songID: String) -> [LibraryDetailTintStop?]? {
        cache[songID]?.meshRegions
    }

    /// 首页卡片的网格衬底：主色和分块色都到了才有，取色还没完成时为 nil。
    func cardMesh(forSongID songID: String) -> CoverTintCardMesh? {
        guard let entry = cache[songID] else { return nil }
        return CoverTintCardMesh(primary: entry.palette.primary, regions: entry.meshRegions)
    }

    /// Schedule background extraction for any songs not already
    /// cached. Idempotent — safe to call on every body re-eval.
    func prepare(_ songs: [Song]) {
        for song in songs {
            knownSongs[song.id] = song
        }
        let pending = songs.filter {
            cache[$0.id] == nil
                && !noColorCache.contains($0.id)
                && !inFlight.contains($0.id)
        }
        guard !pending.isEmpty else { return }

        let pendingIDs = Set(pending.map(\.id))
        inFlight.formUnion(pendingIDs)
        Task.detached(priority: .utility) {
            // Read/decode the small visible set serially on one utility task.
            // Publishing one completed dictionary avoids re-evaluating the
            // entire HomeView once for every individual cover tint.
            var extracted: [String: CoverTint] = [:]
            var noColorIDs: Set<String> = []
            extracted.reserveCapacity(pending.count)
            for song in pending {
                guard !Task.isCancelled else { break }
                let result = Self.computeTint(
                    songID: song.id,
                    coverFileName: song.coverArtFileName
                )
                if let tint = result.tint {
                    extracted[song.id] = tint
                } else if result.analyzedImage {
                    noColorIDs.insert(song.id)
                }
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                let invalidated = self.invalidatedWhileInFlight.intersection(pendingIDs)
                let validIDs = pendingIDs.subtracting(invalidated)
                let validExtracted = extracted.filter { validIDs.contains($0.key) }
                if !validExtracted.isEmpty {
                    var nextCache = self.cache
                    nextCache.merge(validExtracted) { _, new in new }
                    self.cache = nextCache
                }
                self.noColorCache.formUnion(noColorIDs.intersection(validIDs))
                self.inFlight.subtract(pendingIDs)
                self.invalidatedWhileInFlight.subtract(pendingIDs)
                if !invalidated.isEmpty {
                    self.prepare(invalidated.compactMap { self.knownSongs[$0] })
                }
            }
        }
    }

    func clearCache() {
        cache.removeAll(keepingCapacity: false)
        noColorCache.removeAll(keepingCapacity: false)
        invalidatedWhileInFlight.formUnion(inFlight)
    }

    /// Artwork writes and replacements invalidate both positive and negative
    /// results. Notifications without song identities conservatively clear the
    /// small session cache because their object may be a legacy filename.
    func invalidateArtwork(from notification: Notification) {
        var songIDs = Set(notification.userInfo?["songIDs"] as? [String] ?? [])
        if let songID = notification.userInfo?["songID"] as? String {
            songIDs.insert(songID)
        }
        if notification.name == .primuseArtworkDidCache,
           let songID = notification.object as? String {
            songIDs.insert(songID)
        }
        guard !songIDs.isEmpty else {
            clearCache()
            prepare(Array(knownSongs.values))
            return
        }
        // 只在确有这一项时才删：对观察属性做一次删除，哪怕键不存在也会通知所有读过
        // 取色的卡片重画。冷启动时封面一张张缓存好，每张都会发这个通知。
        var affected: [Song] = []
        for songID in songIDs {
            if cache[songID] != nil { cache.removeValue(forKey: songID) }
            if noColorCache.contains(songID) { noColorCache.remove(songID) }
            if inFlight.contains(songID) {
                invalidatedWhileInFlight.insert(songID)
            }
            if let song = knownSongs[songID] { affected.append(song) }
        }
        prepare(affected)
    }

    /// Off-main extraction. Mirrors ThemeService's load-then-extract
    /// flow: try songID-derived hashed filename first, fall back to
    /// the legacy filename column. `MetadataAssetStore.readCoverData`
    /// is `nonisolated`, so no actor hop needed.
    nonisolated private static func computeTint(
        songID: String,
        coverFileName: String?
    ) -> (tint: CoverTint?, analyzedImage: Bool) {
        let hashedName = MetadataAssetStore.shared.expectedCoverFileName(for: songID)
        var data = MetadataAssetStore.shared.readCoverData(named: hashedName)
        if data == nil,
           let coverFileName,
           !coverFileName.isEmpty,
           !coverFileName.contains("/"),
           !coverFileName.contains("://") {
            data = MetadataAssetStore.shared.readCoverData(named: coverFileName)
        }
        guard let data, let image = PlatformImage(data: data) else { return (nil, false) }
        guard let result = ThemeService.extractDominantColor(from: image) else { return (nil, true) }
        return (CoverTint(
            palette: ImmersiveArtworkPalette(primary: result.accent, secondary: result.secondaryDark),
            meshRegions: meshRegions(from: image)
        ), true)
    }

    /// 把封面缩成 `ArtworkMeshSampler.sampleWidth × sampleHeight` 再分块取色。
    /// 像素按行从图像顶部往下排(位图上下文的内存布局就是这样)，第 0 行对应封面顶部。
    nonisolated static func meshRegions(from image: PlatformImage) -> [LibraryDetailTintStop?] {
        let width = ArtworkMeshSampler.sampleWidth
        let height = ArtworkMeshSampler.sampleHeight
        let bytesPerRow = width * 4
        let unreadable = [LibraryDetailTintStop?](repeating: nil, count: LibraryDetailMeshTint.stopCount)
        guard let cgImage = image.platformCGImage else { return unreadable }
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return unreadable }
        return ArtworkMeshSampler.regions(
            pixels: pixels,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow
        )
    }
}

/// 首页卡片的网格衬底：封面分块色铺成一张 MeshGradient 垫在卡片下面，颜色跟着封面的
/// 布局走(封面左上偏红，卡片左上也偏红)，深浅按原来那条渐变的分量，从浓到淡。
///
/// 卡片压在系统底色上、文字是系统主色，所以这里不压深，只用透明度控制分量。
struct CoverTintCardMesh: Equatable {
    /// 浓淡往哪个方向退。
    enum Falloff {
        /// 左上最浓，右下最淡。
        case diagonal
        /// 顶部最浓，底部最淡。
        case vertical
        /// 一样浓，交给外面的遮罩决定形状。
        case uniform
    }

    let primary: Color
    let regions: [LibraryDetailTintStop?]

    /// 规整的 3×3 格点，中心点稍稍偏开，过渡不会正好是一个十字。
    private static let points: [SIMD2<Float>] = [
        [0, 0], [0.5, 0], [1, 0],
        [0, 0.5], [0.56, 0.44], [1, 0.5],
        [0, 1], [0.5, 1], [1, 1],
    ]

    @MainActor
    func gradient(strongest: Double, weakest: Double, falloff: Falloff = .diagonal) -> MeshGradient {
        let columns = LibraryDetailMeshTint.columns
        let rows = LibraryDetailMeshTint.rows
        var colors: [Color] = []
        colors.reserveCapacity(LibraryDetailMeshTint.stopCount)
        for row in 0..<rows {
            for column in 0..<columns {
                let index = row * columns + column
                let progress: Double
                switch falloff {
                case .diagonal:
                    progress = (Double(column) / Double(columns - 1) + Double(row) / Double(rows - 1)) / 2
                case .vertical:
                    progress = Double(row) / Double(rows - 1)
                case .uniform:
                    progress = 0
                }
                let opacity = strongest + (weakest - strongest) * progress
                colors.append(color(at: index).opacity(opacity))
            }
        }
        return MeshGradient(
            width: columns,
            height: rows,
            points: Self.points,
            colors: colors
        )
    }

    /// 读不出颜色的那一块(黑白、灰调)用主色顶上；太暗、太淡的块提一点，衬底才看得出颜色。
    private func color(at index: Int) -> Color {
        guard index < regions.count, let region = regions[index], region.saturation >= 0.12 else {
            return primary
        }
        return Color(
            hue: region.hue,
            saturation: min(max(region.saturation, 0.35), 0.9),
            brightness: min(max(region.brightness, 0.45), 0.95)
        )
    }
}
