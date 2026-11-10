import Foundation

// MARK: - COCO 音乐下载站数据

struct CocoItem: Identifiable, Codable, Hashable {
    let id: String
    let title: String
    let artist: String
    let album: String
    let cover: String?
    let duration: String?
    let provider: String?
}

struct CocoSearchResp: Decodable {
    let ok: Bool
    let items: [CocoItem]?
    let error: String?
    let offset: Int?
    let count: Int?
    let hasMore: Bool?

    enum CodingKeys: String, CodingKey {
        case ok, items, error, offset, count
        case hasMore = "has_more"
    }
}

struct CocoDlResp: Decodable {
    let ok: Bool
    let path: String?
    let format: String?
    let title: String?
    let artist: String?
    let duplicate: Bool?
    let lyric: Bool?
    let resumed: Bool?
    let error: String?
}

struct CocoAlbumResp: Decodable {
    let ok: Bool
    let items: [CocoItem]?
    let error: String?
}

// MARK: - 下载队列（可持久化、可断点续传）

struct QueueItem: Identifiable, Codable, Hashable {
    var id: String
    var provider: String
    var quality: String
    var title: String
    var artist: String
    var album: String
    var cover: String
    var error: String? = nil
    var added: String = ""

    var key: String { "\(id)|\(quality)" }
}

// MARK: - 已完成下载

struct CompletedItem: Identifiable, Codable, Hashable {
    var id: String
    var title: String
    var artist: String
    var album: String
    var cover: String
    var path: String
    var provider: String
    var quality: String
    var finishedAt: String
}

// MARK: - 待同步曲目（收件箱）

struct PendingTrack: Identifiable, Decodable, Hashable {
    let path: String
    let name: String
    let title: String
    let artist: String
    let album: String
    let duration: Double
    let status: String          // new / duplicate / synced
    let cover: String?          // 本地缓存 jpg 路径（可能为空）

    var id: String { path.isEmpty ? "lib|\(title)|\(artist)" : path }
}

struct StatusResp: Decodable {
    let ok: Bool
    let mounted: Bool?
    let mount: String?
    let model: String?
    let modelNum: String?
    let attached: Bool?
    let device: String?
    let media: String?
    let color: String?
    let rockbox: String?
    let total: UInt64?
    let free: UInt64?
    let inbox: String?
    let inboxFiles: Int?
    let synced: Int?
    let rockboxTracks: Int?
    let appleTracks: Int?

    enum CodingKeys: String, CodingKey {
        case ok, mounted, mount, model, color, rockbox, total, free, inbox, synced, attached, device, media
        case modelNum = "model_num"
        case inboxFiles = "inbox_files"
        case rockboxTracks = "rockbox_tracks"
        case appleTracks = "apple_tracks"
    }
}

func imageURL(_ s: String?) -> URL? {
    guard let s, !s.isEmpty else { return nil }
    if s.hasPrefix("http") { return URL(string: s) }
    return URL(fileURLWithPath: s)
}

struct PendingResp: Decodable {
    let ok: Bool
    let mounted: Bool?
    let items: [PendingTrack]?
}

// MARK: - 同步相关

struct DuplicateItem: Identifiable, Hashable {
    let id = UUID()
    let file: String
    let artist: String
    let title: String
}

enum DetailPane: Int, CaseIterable, Identifiable {
    case download = 0
    case queue = 1
    case sync = 2

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .download: return t("下载音乐")
        case .queue: return t("下载队列")
        case .sync: return t("同步到 iPod")
        }
    }

    var symbol: String {
        switch self {
        case .download: return "magnifyingglass"
        case .queue: return "arrow.down.circle"
        case .sync: return "ipod"
        }
    }
}

// MARK: - 收藏（我喜欢的音乐）

extension CocoItem {
    /// 收藏去重键：渠道 + 歌曲 id（同一首歌在不同渠道 id 不同）
    var favKey: String { (provider ?? "") + "|" + id }
}
