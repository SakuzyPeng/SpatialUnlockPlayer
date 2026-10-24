import Foundation

struct PlaylistEntry: Identifiable, Equatable, Codable {
    let id: UUID
    let url: URL
    var title: String
    var failure: String? = nil
    private enum CodingKeys: String, CodingKey { case id, url, title }
    init(url: URL) { self.id = UUID(); self.url = url; self.title = url.deletingPathExtension().lastPathComponent }
}

struct Playlist: Identifiable, Equatable, Codable {
    var id = UUID()
    var name: String
    var entries: [PlaylistEntry] = []
}

enum PlaybackMode: String, CaseIterable, Identifiable, Codable {
    case sequential, repeatAll, repeatOne, shuffle
    var id: Self { self }
    var title: String {
        switch self {
        case .sequential: "顺序播放"
        case .repeatAll: "列表循环"
        case .repeatOne: "单曲循环"
        case .shuffle: "随机播放"
        }
    }
    var symbol: String {
        switch self {
        case .sequential: "arrow.right"
        case .repeatAll: "repeat"
        case .repeatOne: "repeat.1"
        case .shuffle: "shuffle"
        }
    }
}
