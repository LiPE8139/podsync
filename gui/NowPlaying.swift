import Foundation
import AppKit
import MediaPlayer

/// 把 App 自研播放器（ffmpeg 解码 + AVAudioPlayer）接入 macOS 系统「正在播放」：
/// 控制中心 / 菜单栏多媒体、键盘媒体键、耳机线控、AirPods 双击、锁屏/小组件。
///
/// 系统（MediaRemote）只认两条信息：
///   1. MPNowPlayingInfoCenter：曲名/歌手/专辑/封面/时长/播放进度/播放速率；
///   2. MPRemoteCommandCenter：play/pause/toggle/next/prev/拖动进度 的回调。
/// 两者都必须在主线程操作。
@MainActor
final class NowPlayingManager {
    static let shared = NowPlayingManager()

    // 由 AppModel 注入的回调（全部在主线程执行）
    var onPlay: (@MainActor () -> Void)?
    var onPause: (@MainActor () -> Void)?
    var onToggle: (@MainActor () -> Void)?
    var onNext: (@MainActor () -> Void)?
    var onPrevious: (@MainActor () -> Void)?
    /// 拖动进度条（秒，绝对位置）
    var onSeek: (@MainActor (Double) -> Void)?
    /// 快进/快退（秒，相对量）
    var onSkip: (@MainActor (Double) -> Void)?

    private let center = MPNowPlayingInfoCenter.default()
    private let commands = MPRemoteCommandCenter.shared()
    private let artworkDir = appSupportDir + "/np-artwork"
    private var configured = false
    private var artworkCache: [String: MPMediaItemArtwork] = [:]
    private var artworkTask: URLSessionDataTask?
    private var artworkToken = ""
    private var lastProgressWrite = Date.distantPast
    private var lastWasPlaying = false
    private var lastElapsed: Double = -1

    // MARK: - 初始化

    func configure() {
        guard !configured else { return }
        configured = true
        ensureDir(artworkDir)

        // 播放 / 暂停 / 切换
        commands.playCommand.isEnabled = true
        commands.playCommand.removeTarget(nil)
        commands.playCommand.addTarget { [weak self] _ in
            guard self != nil else { return .noSuchContent }
            Task { @MainActor in self?.onPlay?() }
            return .success
        }

        commands.pauseCommand.isEnabled = true
        commands.pauseCommand.removeTarget(nil)
        commands.pauseCommand.addTarget { [weak self] _ in
            guard self != nil else { return .noSuchContent }
            Task { @MainActor in self?.onPause?() }
            return .success
        }

        commands.togglePlayPauseCommand.isEnabled = true
        commands.togglePlayPauseCommand.removeTarget(nil)
        commands.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard self != nil else { return .noSuchContent }
            Task { @MainActor in self?.onToggle?() }
            return .success
        }

        // 上一首 / 下一首
        commands.nextTrackCommand.isEnabled = true
        commands.nextTrackCommand.removeTarget(nil)
        commands.nextTrackCommand.addTarget { [weak self] _ in
            guard self != nil else { return .noSuchContent }
            Task { @MainActor in self?.onNext?() }
            return .success
        }

        commands.previousTrackCommand.isEnabled = true
        commands.previousTrackCommand.removeTarget(nil)
        commands.previousTrackCommand.addTarget { [weak self] _ in
            guard self != nil else { return .noSuchContent }
            Task { @MainActor in self?.onPrevious?() }
            return .success
        }

        // 拖动进度（控制中心 / 锁屏上的进度条）
        commands.changePlaybackPositionCommand.isEnabled = true
        commands.changePlaybackPositionCommand.removeTarget(nil)
        commands.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard self != nil,
                  let e = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            let t = e.positionTime
            Task { @MainActor in self?.onSeek?(t) }
            return .success
        }

        // 15 秒快进 / 快退（耳机线控、部分键盘）
        commands.skipForwardCommand.preferredIntervals = [15]
        commands.skipForwardCommand.isEnabled = true
        commands.skipForwardCommand.removeTarget(nil)
        commands.skipForwardCommand.addTarget { [weak self] event in
            let d = (event as? MPSkipIntervalCommandEvent)?.interval ?? 15
            Task { @MainActor in self?.onSkip?(d) }
            return .success
        }

        commands.skipBackwardCommand.preferredIntervals = [15]
        commands.skipBackwardCommand.isEnabled = true
        commands.skipBackwardCommand.removeTarget(nil)
        commands.skipBackwardCommand.addTarget { [weak self] event in
            let d = (event as? MPSkipIntervalCommandEvent)?.interval ?? 15
            Task { @MainActor in self?.onSkip?(-d) }
            return .success
        }
    }

    // MARK: - 系统「正在播放」信息

    /// 开始一首新曲目（duration 传 0 表示还在加载）
    func startTrack(title: String, artist: String, album: String,
                    duration: Double, cover: String?, isPlaying: Bool) {
        configure()
        artworkTask?.cancel()
        artworkToken = cover ?? ""

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title.isEmpty ? "未命名" : title,
            MPMediaItemPropertyArtist: artist,
            MPMediaItemPropertyAlbumTitle: album,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if let art = cachedArtwork(cover) { info[MPMediaItemPropertyArtwork] = art }

        center.nowPlayingInfo = info
        center.playbackState = isPlaying ? .playing : .paused
        lastProgressWrite = Date()
        updateCommandAvailability(hasTrack: true, canNext: false, canPrev: false)

        if let cover, !cover.isEmpty {
            loadArtwork(cover)
        }
    }

    /// 播放状态 / 进度同步（定时器里节流调用，状态变化时 force=true）
    func updateTime(isPlaying: Bool, elapsed: Double, duration: Double,
                    canNext: Bool, canPrev: Bool, force: Bool = false) {
        let now = Date()
        if !force && now.timeIntervalSince(lastProgressWrite) < 0.9 { return }
        // 暂停状态且进度没变时不必反复推给系统
        if !force && !isPlaying && !lastWasPlaying && abs(elapsed - lastElapsed) < 0.3 { return }
        lastProgressWrite = now
        lastWasPlaying = isPlaying
        lastElapsed = elapsed
        guard var info = center.nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = max(0, elapsed)
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        center.nowPlayingInfo = info
        center.playbackState = isPlaying ? .playing : .paused
        updateCommandAvailability(hasTrack: true, canNext: canNext, canPrev: canPrev)
    }

    /// 停止试听：从系统「正在播放」里移除
    func clear() {
        artworkToken = ""
        artworkTask?.cancel()
        artworkTask = nil
        center.nowPlayingInfo = nil
        center.playbackState = .stopped
        updateCommandAvailability(hasTrack: false, canNext: false, canPrev: false)
    }

    private func updateCommandAvailability(hasTrack: Bool, canNext: Bool, canPrev: Bool) {
        commands.playCommand.isEnabled = hasTrack
        commands.pauseCommand.isEnabled = hasTrack
        commands.togglePlayPauseCommand.isEnabled = hasTrack
        commands.nextTrackCommand.isEnabled = hasTrack && canNext
        commands.previousTrackCommand.isEnabled = hasTrack && canPrev
        commands.changePlaybackPositionCommand.isEnabled = hasTrack
        commands.skipForwardCommand.isEnabled = hasTrack
        commands.skipBackwardCommand.isEnabled = hasTrack
    }

    // MARK: - 封面

    private func cachedArtwork(_ cover: String?) -> MPMediaItemArtwork? {
        guard let cover, !cover.isEmpty, let art = artworkCache[cover] else { return nil }
        return art
    }

    private func loadArtwork(_ cover: String) {
        if let art = artworkCache[cover] {
            applyArtwork(art, key: cover)
            return
        }
        let token = cover
        let localPath: String
        if cover.hasPrefix("http") {
            localPath = artworkDir + "/" + Self.stableHash(cover) + ".img"
            if let data = try? Data(contentsOf: URL(fileURLWithPath: localPath)),
               let img = NSImage(data: data) {
                applyArtwork(makeArtwork(img), key: token)
                return
            }
            guard let url = URL(string: cover) else { return }
            artworkTask = URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
                guard let data, let image = NSImage(data: data) else { return }
                try? data.write(to: URL(fileURLWithPath: localPath))
                Task { @MainActor in self?.applyArtwork(self?.makeArtwork(image), key: token) }
            }
            artworkTask?.resume()
        } else {
            guard let image = NSImage(contentsOfFile: cover) else { return }
            applyArtwork(makeArtwork(image), key: token)
        }
    }

    private func makeArtwork(_ image: NSImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: NSSize(width: 600, height: 600)) { _ in image }
    }

    private func applyArtwork(_ art: MPMediaItemArtwork?, key: String) {
        guard let art, key == artworkToken else { return }
        artworkCache[key] = art
        guard var info = center.nowPlayingInfo else { return }
        info[MPMediaItemPropertyArtwork] = art
        center.nowPlayingInfo = info
    }

    /// 稳定的短哈希（只用于封面缓存文件名，跨启动一致）
    static func stableHash(_ s: String) -> String {
        var h: UInt64 = 5381
        for b in s.utf8 { h = h &* 33 &+ UInt64(b) }
        return String(h, radix: 16)
    }
}
