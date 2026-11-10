import SwiftUI
import AppKit
import AVFoundation

let kInboxKey = "inboxPath"
let kToolKey = "toolDir"
let kProviderKey = "defaultProvider"
let kQualityKey = "defaultQuality"
let kEjectKey = "ejectAfterSync"

let appSupportDir = NSHomeDirectory() + "/Library/Application Support/iPodSync"

func resourceToolDir() -> String {
    if let res = Bundle.main.resourceURL {
        let t = res.appendingPathComponent("tool")
        if FileManager.default.fileExists(atPath: t.appendingPathComponent("ipodsync.py").path) {
            return t.path
        }
    }
    return ""
}

func detectToolDir() -> String {
    let bundled = resourceToolDir()
    if !bundled.isEmpty { return bundled }
    if let exe = Bundle.main.executableURL {
        let appBundle = exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let parent = appBundle.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: parent.appendingPathComponent("ipodsync.py").path) {
            return parent.path
        }
    }
    if let s = UserDefaults.standard.string(forKey: kToolKey), !s.isEmpty { return s }
#if DEVTOOLS
    // 仅开发构建：可用环境变量指定工具目录（发布版不含这段）
    return ProcessInfo.processInfo.environment["PODSYNC_DEV_TOOL_DIR"] ?? ""
#else
    return ""
#endif
}

func pythonExecutable(_ toolDir: String) -> String {
    let p = toolDir + "/runtime/python/bin/python3"
    if FileManager.default.fileExists(atPath: p) { return p }
    return "python3"
}

func toolSearchPath(_ toolDir: String) -> String {
    var parts: [String] = []
    let ff = toolDir + "/runtime/ffmpeg/bin"
    let py = toolDir + "/runtime/python/bin"
    if FileManager.default.fileExists(atPath: ff) { parts.append(ff) }
    if FileManager.default.fileExists(atPath: py) { parts.append(py) }
    parts.append(contentsOf: ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"])
    return parts.joined(separator: ":")
}

/// App 内所有 Python 子进程统一用它：保证用内嵌运行时、并且不往 App 包里写 __pycache__
func pythonEnv(_ toolDir: String) -> [String: String] {
    var e = ProcessInfo.processInfo.environment
    e["PATH"] = toolSearchPath(toolDir)
    e["PYTHONDONTWRITEBYTECODE"] = "1"
    e["PYTHONPYCACHEPREFIX"] = appSupportDir + "/pycache"
    return e
}

func ensureDir(_ p: String) {
    try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
}

/// 在后台跑 Python 引擎，主线程回调完整输出。
func runPython(_ scriptDir: String, _ script: String, _ args: [String],
               env extra: [String: String] = [:], completion: @escaping (String) -> Void) {
    DispatchQueue.global().async {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: pythonExecutable(scriptDir))
        p.arguments = [scriptDir + "/" + script] + args
        var e = pythonEnv(scriptDir)
        for (k, v) in extra { e[k] = v }
        p.environment = e
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        var out = ""
        do {
            try p.run()
            let d = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            out = String(data: d, encoding: .utf8) ?? ""
        } catch {
            out = "{\"ok\":false,\"error\":\"启动失败：\(error.localizedDescription)\"}"
        }
        DispatchQueue.main.async { completion(out) }
    }
}

final class PreviewDelegate: NSObject, AVAudioPlayerDelegate {
    var onFinish: (() -> Void)?
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        onFinish?()
    }
}

@MainActor
final class AppModel: ObservableObject {
    // 同步
    @Published var log = ""
    @Published var running = false
    @Published var summary = ""
    @Published var ipodLine = "检测中…"
    @Published var inboxLine = "—"
    @Published var deviceModel = "iPod"
    @Published var deviceColor = "black"
    @Published var deviceColorOverride: String = UserDefaults.standard.string(forKey: "deviceColorOverride") ?? ""
    @Published var appearanceMode: String = UserDefaults.standard.string(forKey: "appearanceMode") ?? "system"
    @Published var appLanguage: String = UserDefaults.standard.string(forKey: "appLanguage") ?? "zh"
    @Published var playerCoverSize: String = UserDefaults.standard.string(forKey: "playerCoverSize") ?? "medium"
    @Published var deviceRockbox = ""
    @Published var deviceTotal: UInt64 = 0
    @Published var deviceFree: UInt64 = 0
    @Published var syncedCount = 0
    @Published var inboxFileCount = 0
    @Published var deviceMounted = false
    @Published var ejecting = false
    @Published var ejectMessage = ""
    @Published var deviceAttached = false
    @Published var deviceID = ""
    private var statusRefreshing = false
    private var lastMounted = false
    @Published var duplicates: [DuplicateItem] = []
    @Published var showDuplicates = false
    @Published var confirmPrune = false
    @Published var pruneMessage = ""
    @Published var showLog = false
    @Published var cacheMessage = ""
    @Published var inbox: String = UserDefaults.standard.string(forKey: kInboxKey)
        ?? (NSHomeDirectory() + "/Music/iPod-Inbox")
    @Published var toolDir: String = detectToolDir()
    @Published var ejectAfterSync: Bool = UserDefaults.standard.bool(forKey: kEjectKey)
    @Published var cleanInbox: Bool = (UserDefaults.standard.object(forKey: "cleanInbox") as? Bool) ?? true
    @Published var singleAlac: Bool = (UserDefaults.standard.object(forKey: "singleAlac") as? Bool) ?? true

    // 下载
    @Published var query = ""
    @Published var provider: String = UserDefaults.standard.string(forKey: kProviderKey) ?? "netease"
    @Published var quality: String = UserDefaults.standard.string(forKey: kQualityKey) ?? "lossless"
    @Published var items: [CocoItem] = []
    @Published var busy = false
    @Published var page = 1
    @Published var hasMore = false
    @Published var loadingPage = false
    static let pageSize = 50
    @Published var status = "搜索歌曲 / 歌手 / 专辑，然后下载到收件箱。"
    @Published var selection = Set<String>()
    @Published var doneIDs = Set<String>()
    @Published var batchTotal = 0
    @Published var batchDone = 0
    @Published var previewID: String?
    @Published var previewItem: CocoItem?
    @Published var previewPlaying = false
    @Published var previewProgress: Double = 0
    @Published var previewCurrent: Double = 0
    @Published var previewDuration: Double = 0
    @Published var systemVolume: Double = 1.0
    private var lastVolumeBeforeMute: Double = 0.5
    private var volumePollTimer: Timer?
    @Published var previewQueue: [CocoItem] = []
    @Published var previewIndex: Int = 0
    @Published var albumViewItems: [CocoItem] = []
    @Published var albumViewTitle = ""
    @Published var showAlbumView = false
    // 歌手模式：不弹窗，直接在下载页展示某歌手的全部歌曲
    @Published var artistName: String? = nil
    @Published var artistLoading = false
    @Published var showLibraryPanel = false
    @Published var drawerTab = 0
    @Published private(set) var history: [CocoItem] = []
    // 我喜欢的音乐
    @Published private(set) var favorites: [CocoItem] = []
    @Published var favFilter = ""
#if DEVTOOLS
    /// 仅开发截图用：强制某一行显示 hover 强调
    @Published var debugHoverID: String? = nil
#endif
    private var favKeys: Set<String> = []

    // 待同步曲目
    @Published var pending: [PendingTrack] = []
    @Published var pendingBusy = false
    @Published var filterQuery = ""
    @Published var filterArtist = ""
    @Published var filterAlbum = ""
    @Published var selectedPending = Set<String>()

    // 队列
    @Published private(set) var queue: [QueueItem] = []
    @Published private(set) var completed: [CompletedItem] = []
    @Published private(set) var queueRunning = false
    @Published private(set) var downloadingID: String?
    @Published private(set) var downloadPercent: Double = 0
    @Published private(set) var downloadDetail = ""

    private final class LineBuffer {
        var out = ""
        var partial = ""
    }

    private var proc: Process?
    private var previewPlayer: AVAudioPlayer?
    private var previewDelegate: PreviewDelegate?
    private var previewFile: String?
    private var previewProcess: Process?
    private var previewTimer: Timer?
    var preferredScheme: ColorScheme? {
        switch appearanceMode {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    var artworkSize: CGFloat {
        switch playerCoverSize {
        case "small": return 28
        case "large": return 48
        default: return 36
        }
    }

    var canPlayPrev: Bool { previewIndex > 0 && previewIndex < previewQueue.count }
    var canPlayNext: Bool { !previewQueue.isEmpty && previewIndex < previewQueue.count - 1 }
    private var buffer = ""
    private var currentTag = ""
    private let queuePath = appSupportDir + "/queue.json"
    private let completedPath = appSupportDir + "/completed.json"
    private let historyPath = appSupportDir + "/history.json"
    private let favoritesPath = appSupportDir + "/favorites.json"

    init() {
        migrateLegacyDefaultsIfNeeded()
        ensureDir(appSupportDir)
        ensureDir(inbox)
        loadQueue()
        loadCompleted()
        loadHistory()
        loadFavorites()
        setupNowPlaying()
        if let v = SystemVolume.get() { systemVolume = v }
        startVolumePolling()
        refreshStatus()
        loadPending()
        if queue.contains(where: { $0.error == nil }) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.processQueue()
            }
        }
        Timer.scheduledTimer(withTimeInterval: 4.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.running, !self.ejecting else { return }
                self.refreshStatus()
            }
        }
#if DEVTOOLS
        let devDir = ProcessInfo.processInfo.environment["PODSYNC_DEV_TOOL_DIR"] ?? ""
        let snapMarker = devDir + "/snapshot.txt"
        if let dir = try? String(contentsOfFile: snapMarker, encoding: .utf8) {
            try? FileManager.default.removeItem(atPath: snapMarker)
            let out = dir.trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
                self?.devSnapshot(out)
            }
        }

        let marker = devDir + "/devplay.txt"
        if let text = try? String(contentsOfFile: marker, encoding: .utf8) {
            let lines = text.split(separator: "\n").map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty }
            try? FileManager.default.removeItem(atPath: marker)
            if let path = lines.first {
                let cover = lines.count > 1 ? lines[1] : nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                    self?.devPlayFile(path, cover: cover)
                }
            }
        }
        if let i = CommandLine.arguments.firstIndex(of: "--dev-play"),
           i + 1 < CommandLine.arguments.count {
            let path = CommandLine.arguments[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.devPlayFile(path)
            }
        }
#endif
    }

    /// 改 Bundle ID 后，把旧版本（local.ipodsync.gui）的偏好搬过来一次
    private func migrateLegacyDefaultsIfNeeded() {
        let d = UserDefaults.standard
        let flag = "podsyncPrefsMigrated"
        guard !d.bool(forKey: flag) else { return }
        d.set(true, forKey: flag)
        guard let old = UserDefaults(suiteName: "local.ipodsync.gui") else { return }
        if let v = old.string(forKey: "appLanguage"), !v.isEmpty {
            appLanguage = v; d.set(v, forKey: "appLanguage")
        }
        if let v = old.string(forKey: "appearanceMode"), !v.isEmpty {
            appearanceMode = v; d.set(v, forKey: "appearanceMode")
        }
        if let v = old.string(forKey: "playerCoverSize"), !v.isEmpty {
            playerCoverSize = v; d.set(v, forKey: "playerCoverSize")
        }
        if let v = old.string(forKey: "deviceColorOverride"), !v.isEmpty {
            deviceColorOverride = v; d.set(v, forKey: "deviceColorOverride")
        }
        if let v = old.string(forKey: kInboxKey), !v.isEmpty {
            inbox = v; d.set(v, forKey: kInboxKey)
        }
        if let v = old.string(forKey: kProviderKey), !v.isEmpty {
            provider = v; d.set(v, forKey: kProviderKey)
        }
        if let v = old.string(forKey: kQualityKey), !v.isEmpty {
            quality = v; d.set(v, forKey: kQualityKey)
        }
        if old.object(forKey: kEjectKey) != nil {
            ejectAfterSync = old.bool(forKey: kEjectKey); d.set(ejectAfterSync, forKey: kEjectKey)
        }
        for k in ["cleanInbox", "singleAlac"] {
            if let v = old.object(forKey: k) as? Bool {
                if k == "cleanInbox" { cleanInbox = v } else { singleAlac = v }
                d.set(v, forKey: k)
            }
        }
    }

    // MARK: 偏好
    func savePrefs() {
        let d = UserDefaults.standard
        d.set(inbox, forKey: kInboxKey)
        d.set(toolDir, forKey: kToolKey)
        d.set(provider, forKey: kProviderKey)
        d.set(quality, forKey: kQualityKey)
        d.set(ejectAfterSync, forKey: kEjectKey)
        d.set(cleanInbox, forKey: "cleanInbox")
        d.set(singleAlac, forKey: "singleAlac")
        d.set(deviceColorOverride, forKey: "deviceColorOverride")
        d.set(appearanceMode, forKey: "appearanceMode")
        d.set(appLanguage, forKey: "appLanguage")
        d.set(playerCoverSize, forKey: "playerCoverSize")
    }

    func chooseInbox() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "选择收件箱"
        if panel.runModal() == .OK, let u = panel.url {
            inbox = u.path
            ensureDir(inbox)
            savePrefs()
            refreshStatus()
        }
    }

    func chooseToolDir() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "选择工具目录（含 ipodsync.py）"
        if panel.runModal() == .OK, let u = panel.url {
            toolDir = u.path
            savePrefs()
            refreshStatus()
        }
    }

    func openInbox() {
        ensureDir(inbox)
        NSWorkspace.shared.open(URL(fileURLWithPath: inbox))
    }

    func openToolDir() { NSWorkspace.shared.open(URL(fileURLWithPath: toolDir)) }

    // MARK: 状态
    var deviceUsedFraction: Double {
        deviceTotal > 0 ? 1.0 - Double(deviceFree) / Double(deviceTotal) : 0
    }

    var capacityText: String {
        guard deviceTotal > 0 else { return "—" }
        return "剩余 \(Self.fmtBytes(Int(deviceFree))) / 共 \(Self.fmtBytes(Int(deviceTotal)))"
    }

    private static func fmtBytes(_ n: Int) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useMB, .useGB]
        return f.string(fromByteCount: Int64(n))
    }

    func refreshStatus() {
        guard !statusRefreshing else { return }
        statusRefreshing = true
        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: pythonExecutable(self.toolDir))
            p.arguments = [self.toolDir + "/ipodsync.py", "status", "--json"]
            var e = pythonEnv(self.toolDir)
            e["IPODSYNC_INBOX"] = self.inbox
            e["IPODSYNC_HOME"] = appSupportDir
            e["IPODSYNC_LIBRARY_MODE"] = self.singleAlac ? "alac" : "dual"
            p.environment = e
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            var out = ""
            do {
                try p.run()
                let d = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                out = String(data: d, encoding: .utf8) ?? ""
            } catch {}
            let resp = out.data(using: .utf8).flatMap {
                try? JSONDecoder().decode(StatusResp.self, from: $0)
            }
            DispatchQueue.main.async {
                self.statusRefreshing = false
                guard let r = resp else {
                    self.ipodLine = "iPod：未知"
                    return
                }
                self.deviceMounted = r.mounted ?? false
                self.deviceAttached = r.attached ?? false
                self.deviceID = r.device ?? ""
                if self.deviceMounted {
                    self.deviceModel = r.model ?? "iPod"
                    self.deviceColor = r.color ?? "black"
                    self.deviceRockbox = r.rockbox ?? ""
                    self.deviceTotal = r.total ?? 0
                    self.deviceFree = r.free ?? 0
                    self.syncedCount = r.synced ?? 0
                    self.ipodLine = self.deviceModel
                } else {
                    self.deviceModel = "未连接"
                    self.ipodLine = "未连接"
                }
                self.inboxFileCount = r.inboxFiles ?? 0
                self.inboxLine = "收件箱 \(self.inboxFileCount) 首待处理 · 已同步 \(self.syncedCount) 首"
                if self.deviceMounted != self.lastMounted {
                    self.lastMounted = self.deviceMounted
                    self.loadPending()
                }
            }
        }
    }

    // MARK: 推出设备
    func ejectDevice() {
        guard !ejecting, !running else { return }
        ejecting = true
        ejectMessage = "正在推出…"
        runPython(toolDir, "ipodsync.py", ["eject"], env: ["IPODSYNC_HOME": appSupportDir]) { [weak self] out in
            guard let self else { return }
            self.ejecting = false
            let jsonLine = out.split(separator: "\n").first { $0.hasPrefix("{") }.map(String.init)
                ?? out.trimmingCharacters(in: .whitespacesAndNewlines)
            if let d = jsonLine.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                if obj["ok"] as? Bool == true {
                    let ejected = obj["ejected"] as? Bool ?? false
                    let still = obj["attached"] as? Bool ?? false
                    if ejected {
                        self.ejectMessage = "已弹出，可以拔线了"
                    } else if still {
                        self.ejectMessage = "已卸载，设备仍连接（可拔线）"
                    } else {
                        self.ejectMessage = "已安全退出"
                    }
                    self.refreshStatus()
                } else {
                    self.ejectMessage = "推出失败：" + ((obj["error"] as? String) ?? "未知错误")
                }
            } else {
                self.ejectMessage = "推出失败：无法解析结果"
            }
        }
    }

    func refreshCrazypodCache() {
        guard !running else { return }
        cacheMessage = "正在刷新 Rockbox 曲库缓存…"
        runPython(toolDir, "ipodsync.py", ["refresh-crazypod"], env: ["IPODSYNC_HOME": appSupportDir]) { [weak self] out in
            guard let self else { return }
            let line = out.split(separator: "\n").first { $0.hasPrefix("{") }.map(String.init) ?? ""
            if let d = line.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
               obj["ok"] as? Bool == true {
                let refreshed = obj["refreshed"] as? Bool ?? false
                self.cacheMessage = refreshed
                    ? "已重置 Rockbox 曲库缓存，重启 Rockbox 后曲库会重建（含新歌）"
                    : "没有找到 CrazyPod 缓存（无需处理）"
            } else {
                self.cacheMessage = "刷新缓存失败，请重试"
            }
        }
    }

    func mountDevice() {
        guard !ejecting, !running else { return }
        ejecting = true
        ejectMessage = "正在挂载…"
        runPython(toolDir, "ipodsync.py", ["mount"], env: ["IPODSYNC_HOME": appSupportDir]) { [weak self] out in
            guard let self else { return }
            self.ejecting = false
            let jsonLine = out.split(separator: "\n").first { $0.hasPrefix("{") }.map(String.init) ?? ""
            if let d = jsonLine.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
               obj["ok"] as? Bool == true {
                self.ejectMessage = "已重新挂载"
            } else {
                self.ejectMessage = "挂载失败：请拔插一次 iPod"
            }
            self.refreshStatus()
        }
    }

    // MARK: 同步
    func startSync() { runSync(["sync"], tag: "sync") }
    func runPrune() { runSync(["prune", "--yes"], tag: "prune") }

    private func runSync(_ args: [String], tag: String) {
        guard !running else { return }
        running = true
        currentTag = tag
        summary = ""
        pruneMessage = ""
        log = ""
        buffer = ""
        ensureDir(inbox)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: pythonExecutable(toolDir))
        var runArgs = args
        if tag == "sync" && ejectAfterSync { runArgs.append("--eject") }
        if tag == "sync" && !cleanInbox { runArgs.append("--keep-inbox") }
        p.arguments = [toolDir + "/ipodsync.py"] + runArgs
        var e = pythonEnv(toolDir)
        e["IPODSYNC_INBOX"] = inbox
        e["IPODSYNC_HOME"] = appSupportDir
        e["IPODSYNC_LIBRARY_MODE"] = singleAlac ? "alac" : "dual"
        p.environment = e
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty else { h.readabilityHandler = nil; return }
            guard let s = String(data: d, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                self.log += s
                self.buffer += s
            }
        }
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self else { return }
                self.running = false
                self.proc = nil
                let text = self.buffer
                self.duplicates = text.split(separator: "\n").compactMap { line -> DuplicateItem? in
                    guard line.hasPrefix("DUP:") else { return nil }
                    let parts = String(line.dropFirst(4)).split(separator: "\t", omittingEmptySubsequences: false)
                    guard parts.count >= 3 else { return nil }
                    return DuplicateItem(file: String(parts[0]), artist: String(parts[1]), title: String(parts[2]))
                }
                if let r = text.range(of: "PRUNE_JSON:") {
                    let jsonStr = String(text[r.upperBound...]).split(separator: "\n").first.map(String.init) ?? "{}"
                    if let d = jsonStr.data(using: .utf8),
                       let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                        self.pruneMessage = "清理完成：移除 \(obj["dead"] as? Int ?? 0) 首失效记录，"
                            + "删除 \(obj["removed_files"] as? Int ?? 0)/\(obj["orphans"] as? Int ?? 0) 个孤儿文件，"
                            + "剩余 \(obj["remaining"] as? Int ?? 0) 首"
                    }
                }
                if let r = text.range(of: "===== 结果 =====") {
                    self.summary = String(text[r.lowerBound...]).split(separator: "\n").prefix(4).joined(separator: " ")
                } else if self.currentTag != "prune" {
                    self.summary = proc.terminationStatus == 0 ? "完成。" : "同步失败（退出码 \(proc.terminationStatus)），请看日志。"
                }
                self.buffer = ""
                self.showDuplicates = !self.duplicates.isEmpty
                self.refreshStatus()
                self.loadPending()
            }
        }
        do { try p.run(); proc = p } catch {
            running = false
            summary = "启动引擎失败：\(error.localizedDescription)"
        }
    }

    // MARK: 待同步曲目
    var pendingArtists: [String] {
        ["全部歌手"] + Array(Set(pending.map(\.artist))).sorted()
    }

    var pendingAlbums: [String] {
        ["全部专辑"] + Array(Set(pending.map(\.album))).sorted()
    }

    var filteredPending: [PendingTrack] {
        let q = filterQuery.trimmingCharacters(in: .whitespaces).lowercased()
        return pending.filter { t in
            if !filterArtist.isEmpty, filterArtist != "全部歌手", t.artist != filterArtist { return false }
            if !filterAlbum.isEmpty, filterAlbum != "全部专辑", t.album != filterAlbum { return false }
            if q.isEmpty { return true }
            return t.title.lowercased().contains(q)
                || t.artist.lowercased().contains(q)
                || t.album.lowercased().contains(q)
        }
    }

    var pendingNewCount: Int {
        filteredPending.filter { $0.status == "new" }.count
    }

    func loadPending() {
        guard !pendingBusy else { return }
        pendingBusy = true
        runPython(toolDir, "ipodsync.py", ["pending", "--json"],
                  env: ["IPODSYNC_INBOX": inbox, "IPODSYNC_HOME": appSupportDir,
                        "IPODSYNC_LIBRARY_MODE": singleAlac ? "alac" : "dual"]) { [weak self] out in
            guard let self else { return }
            self.pendingBusy = false
            guard let r = out.range(of: "PENDING_JSON:") else { return }
            let jsonStr = String(out[r.upperBound...]).split(separator: "\n").first.map(String.init) ?? "{}"
            guard let d = jsonStr.data(using: .utf8),
                  let resp = try? JSONDecoder().decode(PendingResp.self, from: d) else { return }
            self.pending = resp.items ?? []
            let valid = Set(self.pending.map(\.id))
            self.selectedPending = self.selectedPending.intersection(valid)
        }
    }

    func isSelected(_ id: String) -> Bool { selectedPending.contains(id) }

    func setSelected(_ id: String, _ on: Bool) {
        if on { selectedPending.insert(id) } else { selectedPending.remove(id) }
    }

    func selectAllPending() {
        selectedPending.formUnion(filteredPending.map(\.path))
    }

    func invertPendingSelection() {
        let all = Set(filteredPending.map(\.path))
        selectedPending = all.subtracting(selectedPending)
    }

    func clearPendingSelection() {
        selectedPending.removeAll()
    }

    func syncSelected() {
        let chosen = pending.filter { selectedPending.contains($0.id) && $0.status == "new" }
        guard !chosen.isEmpty, !running else { return }
        ensureDir(appSupportDir)
        let listPath = appSupportDir + "/pending-sync.json"
        if let data = try? JSONEncoder().encode(chosen.map(\.path)) {
            try? data.write(to: URL(fileURLWithPath: listPath))
        }
        runSync(["sync", "--only", listPath], tag: "sync")
    }

    // MARK: 搜索
    func search() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, !busy else { return }
        artistName = nil
        artistLoading = false
        busy = true
        items = []
        selection = []
        status = "搜索中…"
        let prov = provider
        hasMore = false
        page = 1
        runPython(toolDir, "coco.py", ["search", "--q", q, "--provider", prov,
                                       "--limit", "\(Self.pageSize)", "--offset", "0"],
                  env: ["IPODSYNC_HOME": appSupportDir]) { [weak self] out in
            guard let self else { return }
            self.busy = false
            guard let d = out.data(using: .utf8),
                  let r = try? JSONDecoder().decode(CocoSearchResp.self, from: d) else {
                self.status = "搜索失败：返回无法解析"
                return
            }
            if r.ok {
                self.items = r.items ?? []
                self.hasMore = r.hasMore ?? false
                self.page = 1
                self.selection = []
                self.status = "第 1 页 · 共 \(self.items.count) 条"
                    + (self.hasMore ? "（还有更多页）" : "")
            } else {
                self.status = r.error ?? "搜索失败"
            }
        }
    }

    func loadPage(_ n: Int) {
        guard artistName == nil else { return }
        guard n >= 1, !loadingPage, !busy else { return }
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        loadingPage = true
        let prov = provider
        let offset = (n - 1) * Self.pageSize
        runPython(toolDir, "coco.py", ["search", "--q", q, "--provider", prov,
                                       "--limit", "\(Self.pageSize)", "--offset", "\(offset)"],
                  env: ["IPODSYNC_HOME": appSupportDir]) { [weak self] out in
            guard let self else { return }
            self.loadingPage = false
            guard let d = out.data(using: .utf8),
                  let r = try? JSONDecoder().decode(CocoSearchResp.self, from: d), r.ok else {
                self.hasMore = false
                return
            }
            self.items = r.items ?? []
            self.page = n
            self.hasMore = r.hasMore ?? false
            self.selection = []
            self.status = "第 \(n) 页 · 共 \(self.items.count) 条"
                + (self.hasMore ? "（还有更多页）" : "（最后一页）")
        }
    }

    // MARK: 在线试听（完整播放 + 上/下一首）
    func togglePreview(_ item: CocoItem) {
        if previewID == item.id {
            togglePreviewPlay()
            return
        }
        playPreview(item, queue: items)
    }

    func playPreview(_ item: CocoItem, queue: [CocoItem]) {
        previewQueue = queue.isEmpty ? [item] : queue
        if let idx = previewQueue.firstIndex(where: { $0.id == item.id }) {
            previewIndex = idx
        } else {
            previewQueue.insert(item, at: 0)
            previewIndex = 0
        }
        startPreview()
    }

    /// 在下载页直接展示这位歌手的全部歌曲（不弹新窗口）
    func viewArtist(_ item: CocoItem) {
        let artist = item.artist.trimmingCharacters(in: .whitespaces)
        guard !artist.isEmpty, !busy else { return }
        artistName = artist
        artistLoading = true
        items = []
        selection = []
        page = 1
        hasMore = false
        status = "正在获取 \(artist) 的全部歌曲…"
        let prov = item.provider ?? provider
        runPython(toolDir, "coco.py",
                  ["artist", "--artist", artist, "--provider", prov, "--limit", "500"],
                  env: ["IPODSYNC_HOME": appSupportDir]) { [weak self] out in
            guard let self else { return }
            self.artistLoading = false
            guard let data = out.data(using: .utf8),
                  let resp = try? JSONDecoder().decode(CocoAlbumResp.self, from: data),
                  resp.ok, let list = resp.items, !list.isEmpty else {
                self.status = "没有找到「\(artist)」的曲目"
                return
            }
            self.items = list
            self.status = "\(artist) · \(list.count) \(t("首"))"
        }
    }

    /// 退出歌手模式（回到普通搜索结果）
    func exitArtistMode() {
        artistName = nil
        artistLoading = false
        items = []
        selection = []
        page = 1
        hasMore = false
        status = "搜索歌曲 / 歌手 / 专辑，然后下载到收件箱。"
    }

    func openAlbum(_ item: CocoItem) {
        albumViewTitle = "\(item.artist) · \(item.album)"
        albumViewItems = []
        showAlbumView = true
        status = "正在获取整张专辑：\(item.album)…"
        let prov = item.provider ?? provider
        runPython(toolDir, "coco.py",
                  ["album", "--artist", item.artist, "--album", item.album, "--provider", prov],
                  env: ["IPODSYNC_HOME": appSupportDir]) { [weak self] out in
            guard let self else { return }
            guard let data = out.data(using: .utf8),
                  let resp = try? JSONDecoder().decode(CocoAlbumResp.self, from: data),
                  resp.ok, let list = resp.items, !list.isEmpty else {
                self.status = "没有找到这张专辑的曲目"
                return
            }
            self.albumViewItems = list
            self.status = "专辑《\(item.album)》共 \(list.count) 首"
        }
    }

    func playAlbum(_ item: CocoItem) {
        status = "正在获取整张专辑：\(item.album)…"
        let prov = item.provider ?? provider
        runPython(toolDir, "coco.py",
                  ["album", "--artist", item.artist, "--album", item.album, "--provider", prov],
                  env: ["IPODSYNC_HOME": appSupportDir]) { [weak self] out in
            guard let self else { return }
            guard let data = out.data(using: .utf8),
                  let resp = try? JSONDecoder().decode(CocoAlbumResp.self, from: data),
                  resp.ok, let list = resp.items, !list.isEmpty else {
                self.status = "没有找到这张专辑的曲目"
                return
            }
            self.playPreview(item, queue: list)
        }
    }

    func playPrev() {
        guard canPlayPrev else { return }
        previewIndex -= 1
        startPreview()
    }

    func playNext() {
        guard canPlayNext else { return }
        previewIndex += 1
        startPreview()
    }

    private func startPreview() {
        guard previewIndex >= 0, previewIndex < previewQueue.count else { return }
        stopPreview(keepQueue: true)
        let item = previewQueue[previewIndex]
        previewItem = item
        NowPlayingManager.shared.startTrack(title: item.title, artist: item.artist,
                                           album: item.album, duration: 0,
                                           cover: item.cover, isPlaying: false)
        status = "正在获取试听链接：\(item.artist) - \(item.title)…"
        let prov = item.provider ?? provider
        runPython(toolDir, "coco.py",
                  ["url", "--id", item.id, "--provider", prov, "--quality", quality],
                  env: ["IPODSYNC_HOME": appSupportDir]) { [weak self] out in
            guard let self else { return }
            guard let data = out.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (obj["ok"] as? Bool) == true,
                  let u = obj["url"] as? String, let url = URL(string: u) else {
                self.status = "试听失败：没有取到可播放的直链"
                self.previewItem = nil
                NowPlayingManager.shared.clear()
                return
            }
            self.decodeThenPlay(url, item: item)
        }
    }

    private func decodeThenPlay(_ url: URL, item: CocoItem) {
        let outPath = appSupportDir + "/preview.wav"
        try? FileManager.default.removeItem(atPath: outPath)
        status = "正在加载：\(item.title)（完整曲目）…"
        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = ["ffmpeg", "-nostdin", "-v", "error", "-y",
                           "-i", url.absoluteString,
                           "-vn", "-c:a", "pcm_s16le", "-ar", "44100", "-ac", "2", outPath]
            var e = ProcessInfo.processInfo.environment
            e["PATH"] = toolSearchPath(self.toolDir)
            p.environment = e
            p.standardOutput = Pipe()
            p.standardError = Pipe()
            self.previewProcess = p
            var ok = false
            do {
                try p.run()
                p.waitUntilExit()
                let attrs = try? FileManager.default.attributesOfItem(atPath: outPath)
                let size = (attrs?[.size] as? Int) ?? 0
                ok = p.terminationStatus == 0 && size > 4096
            } catch {
                ok = false
            }
            self.previewProcess = nil
            DispatchQueue.main.async {
                guard ok else {
                    self.status = "试听失败：直链不可用或格式不支持"
                    self.previewItem = nil
                    NowPlayingManager.shared.clear()
                    return
                }
                do {
                    let player = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: outPath))
                    player.prepareToPlay()
                    player.volume = 1.0   // 音量交给系统输出控制
                    let delegate = PreviewDelegate()
                    delegate.onFinish = { [weak self] in
                        if let self, self.canPlayNext { self.playNext() } else { self?.stopPreview() }
                    }
                    player.delegate = delegate
                    self.previewDelegate = delegate
                    self.previewPlayer = player
                    self.previewFile = outPath
                    self.previewID = item.id
                    self.recordHistory(item)
                    self.previewDuration = player.duration
                    self.previewCurrent = 0
                    self.previewProgress = 0
                    self.previewPlaying = true
                    NowPlayingManager.shared.startTrack(title: item.title, artist: item.artist,
                                                        album: item.album,
                                                        duration: player.duration,
                                                        cover: item.cover, isPlaying: true)
                    self.status = "试听中：\(item.artist) - \(item.title)"
                    player.play()
                    self.startPreviewTimer()
                } catch {
                    self.status = "试听失败：\(error.localizedDescription)"
                    self.previewItem = nil
                    NowPlayingManager.shared.clear()
                }
            }
        }
    }

    private func startPreviewTimer() {
        previewTimer?.invalidate()
        previewTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let p = self.previewPlayer else { return }
                self.previewCurrent = p.currentTime
                self.previewDuration = max(p.duration, 1)
                self.previewProgress = min(max(p.currentTime / self.previewDuration, 0), 1)
                self.syncNowPlaying()
            }
        }
    }

    func togglePreviewPlay() {
        guard let p = previewPlayer else { return }
        if p.isPlaying { pausePreview() } else { resumePreview() }
    }

    func resumePreview() {
        guard let p = previewPlayer else { return }
        if !p.isPlaying { p.play() }
        previewPlaying = true
        syncNowPlaying(force: true)
    }

    func pausePreview() {
        guard let p = previewPlayer else { return }
        if p.isPlaying { p.pause() }
        previewPlaying = false
        syncNowPlaying(force: true)
    }

    /// 进度条（0…1），来自界面
    func seekPreview(_ fraction: Double) {
        guard let p = previewPlayer else { return }
        seekPreview(seconds: max(0, min(fraction, 1)) * p.duration)
    }

    /// 绝对时间定位（秒）：界面 / 系统「正在播放」拖动
    func seekPreview(seconds: Double) {
        guard let p = previewPlayer else { return }
        let t = max(0, min(seconds, p.duration))
        p.currentTime = t
        previewCurrent = t
        previewProgress = p.duration > 0 ? max(0, min(t / p.duration, 1)) : 0
        syncNowPlaying(force: true)
    }

    /// 相对快进/快退（秒，可为负）
    func seekPreview(bySeconds delta: Double) {
        guard let p = previewPlayer else { return }
        seekPreview(seconds: p.currentTime + delta)
    }

    // MARK: 系统「正在播放」（控制中心 / 菜单栏多媒体 / 键盘媒体键）
    private func setupNowPlaying() {
        let np = NowPlayingManager.shared
        np.onPlay = { [weak self] in self?.resumePreview() }
        np.onPause = { [weak self] in self?.pausePreview() }
        np.onToggle = { [weak self] in self?.togglePreviewPlay() }
        np.onNext = { [weak self] in
            guard let self, self.canPlayNext else { return }
            self.playNext()
        }
        np.onPrevious = { [weak self] in
            guard let self, self.canPlayPrev else { return }
            self.playPrev()
        }
        np.onSeek = { [weak self] t in self?.seekPreview(seconds: t) }
        np.onSkip = { [weak self] d in self?.seekPreview(bySeconds: d) }
        np.configure()
    }

    /// 把当前播放器状态推给系统「正在播放」
    private func syncNowPlaying(force: Bool = false) {
        guard let p = previewPlayer else { return }
        NowPlayingManager.shared.updateTime(isPlaying: p.isPlaying,
                                            elapsed: p.currentTime,
                                            duration: p.duration,
                                            canNext: canPlayNext,
                                            canPrev: canPlayPrev,
                                            force: force)
    }

#if DEVTOOLS
    /// 开发自检：把当前窗口渲染成 PNG（不用屏幕录制权限）
    func devSnapshot(_ outDir: String) {
        ensureDir(outDir)
        let samples = [
            CocoItem(id: "s1", title: "Love", artist: "Keyshia Cole",
                     album: "The Way It Is", cover: nil, duration: "04:15", provider: "netease"),
            CocoItem(id: "s2", title: "Love Me", artist: "JMSN",
                     album: "Soft Spot", cover: nil, duration: "04:33", provider: "netease"),
            CocoItem(id: "s3", title: "晴天", artist: "周杰伦",
                     album: "叶惠美", cover: nil, duration: "04:29", provider: "netease"),
            CocoItem(id: "s4", title: "夜曲", artist: "周杰伦",
                     album: "十一月的萧邦", cover: nil, duration: "03:47", provider: "netease"),
        ]
        items = samples
        favorites = [samples[0], samples[2], samples[3]]
        favKeys = Set(favorites.map { $0.favKey })
        selection = [samples[0].id, samples[1].id]
        status = "第 1 页 · 共 4 条"
        debugHoverID = samples[2].id

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            self?.snapWindow(outDir + "/01-download.png")
            self?.showLibraryPanel = true
            self?.drawerTab = 0
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.snapWindow(outDir + "/02-favorites.png")
                self?.drawerTab = 1
                self?.history = Array(samples.reversed())
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                    self?.snapWindow(outDir + "/03-history.png")
                    self?.showLibraryPanel = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                        guard let self else { return }
                        self.artistName = "周杰伦"
                        self.items = samples
                        self.status = "周杰伦 · \(samples.count) 首"
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
                            self?.snapWindow(outDir + "/04-artist.png")
                            guard let self else { return }
                            self.artistName = nil
                            self.items = samples
                            self.showLibraryPanel = true
                            self.drawerTab = 1
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                                guard let self else { return }
                                if let win = NSApp.windows.first(where: {
                                    $0.contentView != nil && $0.frame.width > 800
                                }) {
                                    // 把指针移到抽屉中间偏上（不点任何控件）
                                    let p = NSPoint(x: win.frame.maxX - 170,
                                                    y: win.frame.midY + 80)
                                    CGWarpMouseCursorPosition(p)
                                    CGAssociateMouseAndMouseCursorPosition(1)
                                }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                                    self?.snapWindow(outDir + "/05-hover-drawer.png")
                                    self?.simulateClickToDismiss(outDir: outDir)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// 开发自检：模拟点击搜索页内容，验证抽屉会不会自动收起
    private func simulateClickToDismiss(outDir: String) {
        guard let win = NSApp.windows.first(where: { $0.contentView != nil && $0.frame.width > 800 }) else {
            exit(0)
        }
        NSApp.activate(ignoringOtherApps: true)
        // 直接在窗口里派发一次单击（不依赖辅助功能权限）
        if let content = win.contentView {
            let h = content.bounds.height
            let pt = NSPoint(x: 320, y: h - 250)   // 列表中某一行的位置（窗口坐标系，左下原点）
            CGWarpMouseCursorPosition(win.convertPoint(toScreen: pt))
            CGAssociateMouseAndMouseCursorPosition(1)
            for type in [NSEvent.EventType.leftMouseDown, NSEvent.EventType.leftMouseUp] {
                if let e = NSEvent.mouseEvent(with: type, location: pt, modifierFlags: [],
                                              timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: win.windowNumber, context: nil,
                                              eventNumber: 0, clickCount: 1, pressure: 1) {
                    NSApp.sendEvent(e)
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { exit(0) }
            self.snapWindow(outDir + "/06-after-click.png")
            let state = "drawer_open_after_click=\(self.showLibraryPanel)\n"
            try? state.write(toFile: outDir + "/06-state.txt", atomically: true, encoding: .utf8)
            exit(0)
        }
    }

    /// 把当前 App 的所有可见窗口都截下来（用于验证 sheet 等独立窗口）
    private func snapWindows(_ prefix: String) {
        let wins = NSApp.windows.filter { $0.isVisible && $0.frame.width > 200 }
        var idx = 0
        for win in wins {
            guard win.windowNumber > 0,
                  let cg = CGWindowListCreateImage(.null, .optionIncludingWindow,
                                                   CGWindowID(win.windowNumber),
                                                   [.boundsIgnoreFraming]) else { continue }
            let rep = NSBitmapImageRep(cgImage: cg)
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: "\(prefix)-\(idx).png"))
            }
            idx += 1
        }
        print("snapWindows: \(idx)")
    }

    private func snapWindow(_ path: String) {
        guard let win = NSApp.windows.first(where: { $0.contentView != nil && $0.frame.width > 800 }) else {
            print("snapshot failed: no window")
            return
        }
        // 先试窗口服务器合成图（能拍到 Liquid Glass 等材质图层），失败再退回视图缓存
        if win.windowNumber > 0,
           let cg = CGWindowListCreateImage(.null, .optionIncludingWindow,
                                            CGWindowID(win.windowNumber),
                                            [.boundsIgnoreFraming]) {
            let rep = NSBitmapImageRep(cgImage: cg)
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: path))
                print("snapshot(cg): \(path)")
                return
            }
        }
        guard let view = win.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            print("snapshot failed")
            return
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
            print("snapshot(view): \(path)")
        }
    }

    /// 开发自检：把本地 WAV 走一遍正式试听链路（验证系统「正在播放」）
    func devPlayFile(_ path: String, cover: String? = nil) {
        let wav = appSupportDir + "/preview.wav"
        try? FileManager.default.removeItem(atPath: wav)
        try? FileManager.default.copyItem(atPath: path, toPath: wav)
        do {
            let player = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: wav))
            player.prepareToPlay()
            player.volume = 1.0
            let delegate = PreviewDelegate()
            delegate.onFinish = { [weak self] in
                if let self, self.canPlayNext { self.playNext() } else { self?.stopPreview() }
            }
            player.delegate = delegate
            previewDelegate = delegate
            previewPlayer = player
            previewFile = wav
            previewID = "dev"
            previewItem = CocoItem(id: "dev", title: "试听测试", artist: "iPodSync",
                                   album: "Now Playing Test", cover: cover,
                                   duration: nil, provider: nil)
            previewDuration = player.duration
            previewCurrent = 0
            previewProgress = 0
            previewPlaying = true
            NowPlayingManager.shared.startTrack(title: "试听测试", artist: "iPodSync",
                                                album: "Now Playing Test",
                                                duration: player.duration,
                                                cover: cover, isPlaying: true)
            startPreviewTimer()
            player.play()
            status = "开发自检：正在播放本地文件"
        } catch {
            status = "开发自检失败：\(error.localizedDescription)"
        }
    }
#endif

    func setVolume(_ v: Double) {
        let clamped = min(max(v, 0), 1)
        systemVolume = clamped
        if clamped > 0 { lastVolumeBeforeMute = clamped }
        SystemVolume.set(clamped)
    }

    func toggleMute() {
        if systemVolume > 0.001 {
            lastVolumeBeforeMute = systemVolume
            setVolume(0)
        } else {
            setVolume(lastVolumeBeforeMute > 0 ? lastVolumeBeforeMute : 0.5)
        }
    }

    /// 轮询系统音量，保证用键盘/系统条改音量时控件也跟着变
    private func startVolumePolling() {
        volumePollTimer?.invalidate()
        volumePollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let v = SystemVolume.get() else { return }
                if abs(v - self.systemVolume) > 0.005 {
                    self.systemVolume = v
                }
            }
        }
    }

    func stopPreview(keepQueue: Bool = false) {
        NowPlayingManager.shared.clear()
        previewProcess?.terminate()
        previewProcess = nil
        previewTimer?.invalidate()
        previewTimer = nil
        previewPlayer?.stop()
        previewPlayer = nil
        previewDelegate = nil
        previewID = nil
        previewItem = nil
        previewPlaying = false
        previewProgress = 0
        previewCurrent = 0
        previewDuration = 0
        if let f = previewFile {
            try? FileManager.default.removeItem(atPath: f)
            previewFile = nil
        }
        if !keepQueue {
            previewQueue = []
            previewIndex = 0
        }
    }

    // MARK: 下载队列
    func loadQueue() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: queuePath)),
              let arr = try? JSONDecoder().decode([QueueItem].self, from: data) else { return }
        queue = arr
    }

    private func loadCompleted() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: completedPath)),
              let arr = try? JSONDecoder().decode([CompletedItem].self, from: data) else { return }
        completed = arr
    }

    private func saveCompleted() {
        ensureDir(appSupportDir)
        if let data = try? JSONEncoder().encode(Array(completed.prefix(300))) {
            try? data.write(to: URL(fileURLWithPath: completedPath))
        }
    }

    // MARK: 播放历史
    private func loadHistory() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: historyPath)),
              let arr = try? JSONDecoder().decode([CocoItem].self, from: data) else { return }
        history = arr
    }

    private func saveHistory() {
        ensureDir(appSupportDir)
        if let data = try? JSONEncoder().encode(Array(history.prefix(200))) {
            try? data.write(to: URL(fileURLWithPath: historyPath))
        }
    }

    func recordHistory(_ item: CocoItem) {
        history.removeAll { $0.id == item.id }
        history.insert(item, at: 0)
        if history.count > 200 { history = Array(history.prefix(200)) }
        saveHistory()
    }

    func playHistoryItem(at index: Int) {
        guard index >= 0, index < history.count else { return }
        previewQueue = history
        previewIndex = index
        startPreview()
    }

    func removeFromHistory(_ item: CocoItem) {
        history.removeAll { $0.id == item.id }
        saveHistory()
    }

    func clearHistory() {
        history = []
        saveHistory()
    }

    // MARK: 我喜欢的音乐（收藏）

    var filteredFavorites: [CocoItem] {
        let q = favFilter.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return favorites }
        return favorites.filter {
            $0.title.localizedCaseInsensitiveContains(q)
                || $0.artist.localizedCaseInsensitiveContains(q)
                || $0.album.localizedCaseInsensitiveContains(q)
        }
    }

    func isFavorite(_ item: CocoItem) -> Bool { favKeys.contains(item.favKey) }

    func toggleFavorite(_ item: CocoItem) {
        if favKeys.contains(item.favKey) {
            favorites.removeAll { $0.favKey == item.favKey }
            favKeys.remove(item.favKey)
            status = "已取消喜欢：\(item.title)"
        } else {
            favorites.insert(item, at: 0)
            favKeys.insert(item.favKey)
            status = "已加入我喜欢的音乐：\(item.title)"
        }
        saveFavorites()
    }

    func clearFavorites() {
        favorites = []
        favKeys = []
        saveFavorites()
    }

    private func loadFavorites() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: favoritesPath)),
              let arr = try? JSONDecoder().decode([CocoItem].self, from: data) else { return }
        favorites = arr
        favKeys = Set(arr.map { $0.favKey })
    }

    private func saveFavorites() {
        ensureDir(appSupportDir)
        if let data = try? JSONEncoder().encode(favorites) {
            try? data.write(to: URL(fileURLWithPath: favoritesPath))
        }
    }

    /// 播放一整组曲目（收藏 / 搜索结果 / 任意列表）
    func playList(_ list: [CocoItem]) {
        guard let first = list.first else { return }
        playPreview(first, queue: list)
    }

    /// 整组加入下载队列
    func downloadList(_ list: [CocoItem]) {
        guard !list.isEmpty else { return }
        enqueue(list)
    }


    // MARK: 下载列表勾选

    var allSelectedOnPage: Bool {
        !items.isEmpty && items.allSatisfy { selection.contains($0.id) }
    }

    func setPageSelected(_ id: String, _ on: Bool) {
        if on { selection.insert(id) } else { selection.remove(id) }
    }

    func toggleSelectAllOnPage() {
        if allSelectedOnPage {
            selection.removeAll()
        } else {
            selection = Set(items.map(\.id))
        }
    }

    func clearCompleted() {
        completed = []
        saveCompleted()
    }

    func openInFinder(_ path: String) {
        guard FileManager.default.fileExists(atPath: path) else {
            openInbox()
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func reEnqueue(_ c: CompletedItem) {
        enqueue([CocoItem(id: c.id, title: c.title, artist: c.artist, album: c.album,
                          cover: c.cover.isEmpty ? nil : c.cover,
                          duration: nil, provider: c.provider)])
    }

    private func saveQueue() {
        ensureDir(appSupportDir)
        if let data = try? JSONEncoder().encode(queue) {
            try? data.write(to: URL(fileURLWithPath: queuePath))
        }
    }

    func enqueue(_ list: [CocoItem]) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        for it in list where !queue.contains(where: { $0.key == "\(it.id)|\(quality)" }) {
            queue.append(QueueItem(id: it.id, provider: it.provider ?? provider, quality: quality,
                                   title: it.title, artist: it.artist, album: it.album,
                                   cover: it.cover ?? "", added: stamp))
        }
        saveQueue()
        processQueue()
    }

    func download(_ item: CocoItem) { enqueue([item]) }

    func downloadSelected() {
        enqueue(items.filter { selection.contains($0.id) })
    }

    func downloadAll() {
        enqueue(items.filter { !doneIDs.contains($0.id) })
    }

    func downloadAlbum(_ item: CocoItem) {
        status = "正在获取整张专辑：\(item.album)…"
        runPython(toolDir, "coco.py",
                  ["album", "--artist", item.artist, "--album", item.album,
                   "--provider", item.provider ?? provider],
                  env: ["IPODSYNC_HOME": appSupportDir]) { [weak self] out in
            guard let self else { return }
            guard let d = out.data(using: .utf8),
                  let r = try? JSONDecoder().decode(CocoAlbumResp.self, from: d), r.ok,
                  let list = r.items, !list.isEmpty else {
                self.status = "没有找到这张专辑的其他曲目"
                return
            }
            self.enqueue(list)
            self.status = "已将 \(list.count) 首加入队列"
        }
    }

    private func runDownload(_ args: [String], completion: @escaping (String) -> Void) {
        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: pythonExecutable(self.toolDir))
            p.arguments = [self.toolDir + "/coco.py"] + args
            var e = pythonEnv(self.toolDir)
            e["IPODSYNC_HOME"] = appSupportDir
            p.environment = e
            let outPipe = Pipe()
            let errPipe = Pipe()
            p.standardOutput = outPipe
            p.standardError = errPipe
            let outBuf = LineBuffer()
            let errBuf = LineBuffer()

            outPipe.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                guard !d.isEmpty else { h.readabilityHandler = nil; return }
                guard let text = String(data: d, encoding: .utf8) else { return }
                DispatchQueue.main.async {
                    outBuf.partial += text
                    while let idx = outBuf.partial.firstIndex(of: "\n") {
                        let line = String(outBuf.partial[..<idx])
                        outBuf.partial = String(outBuf.partial[outBuf.partial.index(after: idx)...])
                        outBuf.out += line + "\n"
                    }
                }
            }
            errPipe.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                guard !d.isEmpty else { h.readabilityHandler = nil; return }
                guard let text = String(data: d, encoding: .utf8) else { return }
                DispatchQueue.main.async {
                    errBuf.partial += text
                    while let idx = errBuf.partial.firstIndex(of: "\n") {
                        let line = String(errBuf.partial[..<idx])
                        errBuf.partial = String(errBuf.partial[errBuf.partial.index(after: idx)...])
                        self.handleDownloadLine(line, errBuf)
                    }
                }
            }
            p.terminationHandler = { _ in
                DispatchQueue.main.async {
                    if !outBuf.partial.isEmpty {
                        outBuf.out += outBuf.partial + "\n"
                        outBuf.partial = ""
                    }
                    if !errBuf.partial.isEmpty {
                        self.handleDownloadLine(errBuf.partial, errBuf)
                        errBuf.partial = ""
                    }
                    completion(outBuf.out)
                }
            }
            do { try p.run() } catch {
                completion("{\"ok\":false,\"error\":\"启动失败\"}")
            }
        }
    }

    private func handleDownloadLine(_ line: String, _ buf: LineBuffer) {
        if line.hasPrefix("PROGRESS\t") {
            let parts = line.split(separator: "\t")
            if parts.count >= 4 {
                let pct = Int(parts[1]) ?? -1
                let got = Int(parts[2]) ?? 0
                let total = Int(parts[3]) ?? 0
                downloadPercent = pct >= 0 ? min(max(Double(pct) / 100.0, 0), 1) : 0
                if total > 0 {
                    downloadDetail = "\(Self.fmtBytes(got)) / \(Self.fmtBytes(total))"
                } else if got > 0 {
                    downloadDetail = Self.fmtBytes(got)
                }
            }
            return
        }
        if !line.isEmpty {
            buf.out += line + "\n"
        }
    }

    func processQueue() {
        guard !queueRunning else { return }
        guard !queue.isEmpty else {
            status = "队列为空"
            return
        }
        queueRunning = true
        batchTotal = queue.count
        batchDone = 0
        stepQueue()
    }

    private func stepQueue() {
        guard let first = queue.first else {
            queueRunning = false
            downloadingID = nil
            status = "队列已完成"
            refreshStatus()
            loadPending()
            return
        }
        downloadingID = first.id
        downloadPercent = 0
        downloadDetail = ""
        status = "下载中 [\(batchDone + 1)/\(batchTotal)]：\(first.artist) - \(first.title)"
        var args = ["download", "--id", first.id, "--provider", first.provider,
                    "--quality", first.quality, "--inbox", inbox,
                    "--title", first.title, "--artist", first.artist, "--album", first.album]
        if !first.cover.isEmpty { args += ["--cover", first.cover] }
        runDownload(args) { [weak self] out in
            guard let self else { return }
            self.downloadingID = nil
            self.downloadPercent = 0
            self.downloadDetail = ""
            let jsonLine = out.split(separator: "\n").last { $0.hasPrefix("{") }.map(String.init) ?? out
            if let d = jsonLine.data(using: .utf8),
               let r = try? JSONDecoder().decode(CocoDlResp.self, from: d), r.ok {
                self.doneIDs.insert(first.id)
                let fmt = DateFormatter()
                fmt.dateFormat = "MM-dd HH:mm"
                self.completed.insert(CompletedItem(
                    id: first.key + "|" + UUID().uuidString.prefix(6).description,
                    title: first.title, artist: first.artist, album: first.album,
                    cover: first.cover, path: r.path ?? "",
                    provider: first.provider, quality: first.quality,
                    finishedAt: fmt.string(from: Date())), at: 0)
                if self.completed.count > 300 {
                    self.completed = Array(self.completed.prefix(300))
                }
                self.saveCompleted()
                self.queue.removeAll { $0.key == first.key }
                self.saveQueue()
                self.batchDone += 1
                let note = r.resumed == true ? "（断点续传）" : ""
                self.status = "已下载：\((r.path as NSString?)?.lastPathComponent ?? first.title)\(note)"
                self.stepQueue()
            } else {
                if let idx = self.queue.firstIndex(where: { $0.key == first.key }) {
                    self.queue[idx].error = String(out.prefix(120))
                }
                self.saveQueue()
                self.queueRunning = false
                self.status = "下载失败：\(first.artist) - \(first.title)（已保留在队列，可重试）"
            }
        }
    }

    func retryQueue() {
        queue = queue.map { var q = $0; q.error = nil; return q }
        saveQueue()
        processQueue()
    }

    func clearQueue() {
        queue = []
        saveQueue()
        queueRunning = false
        downloadingID = nil
    }

    func removeQueueItem(_ item: QueueItem) {
        queue.removeAll { $0.key == item.key }
        saveQueue()
    }
}
