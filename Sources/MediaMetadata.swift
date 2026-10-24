import AppKit
@preconcurrency import AVFoundation
import CoreMedia

struct PlaylistEntry: Identifiable, Equatable, Codable {
    let id: UUID
    let url: URL
    var title: String
    var failure: String? = nil
    private enum CodingKeys: String, CodingKey { case id, url, title }
    init(url: URL) { self.id = UUID(); self.url = url; self.title = url.deletingPathExtension().lastPathComponent }
}

struct MediaMetadata {
    var title = ""
    var artist = ""
    var duration: Double = 0
    var hasVideo = false
    var audioDescription = ""
    var artwork: NSImage?

    @MainActor static func load(asset: AVURLAsset) async throws -> Self {
        guard try await asset.load(.isPlayable) else {
            throw NSError(domain: "SpatialPlayer", code: 1, userInfo: [NSLocalizedDescriptionKey: "系统无法播放这个文件。请使用 AVFoundation 支持的音视频格式。"])
        }
        var value = Self()
        let duration = try await asset.load(.duration)
        value.duration = duration.seconds.isFinite ? max(0, duration.seconds) : 0
        value.hasVideo = !(try await asset.loadTracks(withMediaType: .video)).isEmpty
        if let track = try await asset.loadTracks(withMediaType: .audio).first,
           let description = try await track.load(.formatDescriptions).first,
           let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description) {
            let format = basic.pointee
            let names: [UInt32: String] = [fourCC("apac"): "APAC", fourCC("ec-3"): "Dolby Digital Plus", fourCC("ec+3"): "Dolby Atmos", fourCC("ac-3"): "Dolby Digital", fourCC("aac "): "AAC", fourCC("alac"): "Apple Lossless", fourCC("lpcm"): "PCM", fourCC(".mp3"): "MP3", fourCC("flac"): "FLAC"]
            let codec = names[format.mFormatID] ?? String(bytes: [UInt8((format.mFormatID >> 24) & 255), UInt8((format.mFormatID >> 16) & 255), UInt8((format.mFormatID >> 8) & 255), UInt8(format.mFormatID & 255)], encoding: .ascii) ?? "音频"
            let rate = String(format: "%g", format.mSampleRate / 1000)
            var elements = [codec, "\(format.mChannelsPerFrame) 声道", "\(rate) kHz"]
            var layoutSize = 0
            if let layout = CMAudioFormatDescriptionGetChannelLayout(description, sizeOut: &layoutSize) {
                let tag = layout.pointee.mChannelLayoutTag
                let names: [UInt32: String] = [kAudioChannelLayoutTag_Atmos_9_1_6: "9.1.6", kAudioChannelLayoutTag_Atmos_7_1_4: "7.1.4", kAudioChannelLayoutTag_CICP_13: "22.2"]
                if let name = names[tag] { elements.append(name) }
            }
            value.audioDescription = elements.joined(separator: " · ")
        }
        let common = (try? await asset.load(.commonMetadata)) ?? []
        for metadata in common {
            switch metadata.commonKey {
            case .commonKeyTitle: value.title = (try? await metadata.load(.stringValue)) ?? ""
            case .commonKeyArtist: value.artist = (try? await metadata.load(.stringValue)) ?? ""
            case .commonKeyArtwork:
                if let data = try? await metadata.load(.dataValue), data.count <= 20 * 1024 * 1024 { value.artwork = NSImage(data: data) }
            default: break
            }
        }
        return value
    }
}

func timeLabel(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "--:--" }
    let total = Int(seconds)
    return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60) : String(format: "%d:%02d", total / 60, total % 60)
}
