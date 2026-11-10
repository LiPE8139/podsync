import SwiftUI
import AppKit

@main
struct iPodSyncApp: App {
    @StateObject private var model = AppModel()

    init() {
        if CommandLine.arguments.contains("--selftest") {
            runSelftest()
            exit(0)
        }
    }

    var body: some Scene {
        WindowGroup("PodSync") {
            ContentView()
                .environmentObject(model)
                .id(model.appLanguage)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1040, height: 720)
        .commands {
            CommandMenu("iPod") {
                Button(t("立即同步")) { model.startSync() }
                    .keyboardShortcut("r")
                    .disabled(model.running)
                Button(t("清理已删除歌曲…")) { model.confirmPrune = true }
                    .keyboardShortcut(.delete, modifiers: [.command, .shift])
                    .disabled(model.running)
                Divider()
                Button(t("刷新状态")) { model.refreshStatus() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button(t("打开收件箱")) { model.openInbox() }
                Divider()
                Button(t("显示 / 隐藏音乐库")) { model.showLibraryPanel.toggle() }
                    .keyboardShortcut("l", modifiers: [.command])
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
                .id(model.appLanguage)
        }
    }
}

// MARK: - 命令行自检

func runSelftest() {
    let tool = detectToolDir()
    let home = ProcessInfo.processInfo.environment["IPODSYNC_HOME"] ?? appSupportDir
    try? FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)

    func capture(_ script: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: pythonExecutable(tool))
        p.arguments = [tool + "/" + script] + args
        var e = ProcessInfo.processInfo.environment
        e["PATH"] = toolSearchPath(tool)
        e["IPODSYNC_HOME"] = home
        e["PYTHONDONTWRITEBYTECODE"] = "1"
        e["PYTHONPYCACHEPREFIX"] = home + "/pycache"
        p.environment = e
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do {
            try p.run()
            let d = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return String(data: d, encoding: .utf8) ?? ""
        } catch { return "" }
    }

    print(capture("ipodsync.py", ["status"]))
    print("SELFTEST_OK")
    if let d = capture("coco.py", ["search", "--q", "kashmir", "--provider", "netease"]).data(using: .utf8),
       let r = try? JSONDecoder().decode(CocoSearchResp.self, from: d) {
        print("COCO_OK ok=\(r.ok) items=\(r.items?.count ?? 0) first=\(r.items?.first?.title ?? "-")")
    } else {
        print("COCO_PARSE_FAIL")
    }
    if let d = capture("coco.py", ["artist", "--artist", "周杰伦", "--provider", "netease"]).data(using: .utf8),
       let r = try? JSONDecoder().decode(CocoAlbumResp.self, from: d) {
        print("COCO_ARTIST_OK ok=\(r.ok) items=\(r.items?.count ?? 0)")
    } else {
        print("COCO_ARTIST_FAIL")
    }

    let pendingOut = capture("ipodsync.py", ["pending", "--json"])
    if let range = pendingOut.range(of: "PENDING_JSON:"),
       let d = String(pendingOut[range.upperBound...]).split(separator: "\n").first
        .flatMap({ String($0).data(using: .utf8) }),
       let r = try? JSONDecoder().decode(PendingResp.self, from: d) {
        print("PENDING_OK items=\(r.items?.count ?? 0)")
    } else {
        print("PENDING_PARSE_FAIL")
    }
}
