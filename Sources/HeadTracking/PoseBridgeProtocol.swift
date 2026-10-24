import Foundation

struct PoseBridgePose: Sendable {
    let source: String
    let instance: Int64
    let session: Int64
    let sequence: Int64
    let transmission: Int64
    let reference: Int64
    let revision: Int64
    let ageAtSend: UInt64
    let physical: PoseQuaternion
}

struct PoseBridgeTelemetry: Sendable {
    let kind: String
    let source: String
    let instance: Int64
    let session: Int64
    let reference: Int64
    let revision: Int64
    let sequence: Int64
    let state: String?
}

enum PoseBridgeMessage: Sendable {
    case pose(PoseBridgePose)
    case telemetry(PoseBridgeTelemetry)
}

enum PoseBridgeProtocol {
    static let maxPacketBytes = 8192
    static let poseLifetime: UInt64 = 500_000_000
    static let heartbeatLifetime: UInt64 = 3_000_000_000
    enum InvalidPacket: Error { case malformed }

    private struct Reader {
        let bytes: [UInt8]
        var offset = 0
        mutating func string() throws -> String {
            guard offset < bytes.count, let end = bytes[offset...].firstIndex(of: 0) else { throw InvalidPacket.malformed }
            let next = (end + 4) & ~3
            guard next <= bytes.count, bytes[end..<next].allSatisfy({ $0 == 0 }),
                  let text = String(bytes: bytes[offset..<end], encoding: .utf8) else { throw InvalidPacket.malformed }
            offset = next
            return text
        }
        mutating func unsigned(_ count: Int) throws -> UInt64 {
            guard count <= bytes.count - offset else { throw InvalidPacket.malformed }
            var result: UInt64 = 0
            for byte in bytes[offset..<(offset + count)] { result = (result << 8) | UInt64(byte) }
            offset += count
            return result
        }
        mutating func int() throws -> Int32 { Int32(bitPattern: UInt32(try unsigned(4))) }
        mutating func long() throws -> Int64 { Int64(bitPattern: try unsigned(8)) }
        mutating func float() throws -> Double { Double(Float(bitPattern: UInt32(try unsigned(4)))) }
    }
    static func validSource(_ source: String) -> Bool {
        (1...256).contains(source.utf8.count) &&
        !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !source.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
    }
    static func decode(_ data: Data) throws -> PoseBridgeMessage {
        guard !data.isEmpty, data.count <= maxPacketBytes else { throw InvalidPacket.malformed }
        var reader = Reader(bytes: Array(data))
        let address = try reader.string(), tags = try reader.string()
        if address == "/posebridge/info" || address == "/posebridge/status" {
            guard tags == ",s" else { throw InvalidPacket.malformed }
            let json = try reader.string()
            guard reader.offset == data.count else { throw InvalidPacket.malformed }
            return .telemetry(try telemetry(json, kind: address == "/posebridge/info" ? "info" : "status"))
        }
        let quaternion = address == "/posebridge/quaternion"
        guard quaternion || address == "/posebridge/euler",
              tags == (quaternion ? ",ishhhhhhhhihhffff" : ",ishhhhhhhhihhfff"),
              try reader.int() == 3 else { throw InvalidPacket.malformed }
        let source = try reader.string()
        let instance = try reader.long(), session = try reader.long(), sequence = try reader.long()
        let transmission = try reader.long(), reference = try reader.long(), revision = try reader.long()
        let received = try reader.long(), age = try reader.long(), clockKind = try reader.int()
        let sampleTime = try reader.long(), clockEpoch = try reader.long()
        guard validSource(source), [instance, session, sequence, transmission, reference, revision].allSatisfy({ $0 > 0 }),
              received >= 0, age >= 0, UInt64(age) < poseLifetime, (0...2).contains(clockKind),
              sampleTime >= 0, (clockKind == 0 ? sampleTime == 0 && clockEpoch == 0 : clockEpoch > 0)
        else { throw InvalidPacket.malformed }
        let a = try reader.float(), b = try reader.float(), c = try reader.float()
        let physical: PoseQuaternion?
        if quaternion { physical = PoseQuaternion.fromPoseBridge(x: a, y: b, z: c, w: try reader.float()) }
        else { physical = PoseQuaternion.physical(yaw: a, pitch: b, roll: c) }
        guard reader.offset == data.count, let physical else { throw InvalidPacket.malformed }
        return .pose(.init(source: source, instance: instance, session: session, sequence: sequence,
                           transmission: transmission, reference: reference, revision: revision,
                           ageAtSend: UInt64(age), physical: physical))
    }
    private static func telemetry(_ text: String, kind: String) throws -> PoseBridgeTelemetry {
        guard let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              object["schema"] as? Int == 3, object["kind"] as? String == kind,
              let source = object["source_id"] as? String, validSource(source) else { throw InvalidPacket.malformed }
        func decimal(_ key: String) throws -> Int64 {
            guard let text = object[key] as? String, !text.isEmpty,
                  text.utf8.allSatisfy({ (48...57).contains($0) }),
                  let number = Int64(text), number >= 0 else { throw InvalidPacket.malformed }
            return number
        }
        let instance = try decimal("instance_id"), session = try decimal("session_id")
        let reference = try decimal("reference_epoch"), revision = try decimal("metadata_revision"), sequence = try decimal("message_seq")
        guard instance > 0, sequence > 0, let nested = object[kind == "info" ? "descriptor" : "status"] as? [String: Any],
              nested["session_id"] as? String == object["session_id"] as? String else { throw InvalidPacket.malformed }
        var state: String?
        if kind == "info" {
            for key in ["source_id", "instance_id", "reference_epoch", "metadata_revision"] {
                guard nested[key] as? String == object[key] as? String else { throw InvalidPacket.malformed }
            }
            guard nested["coordinate_profile"] as? String == "posebridge.yxz.v1" else { throw InvalidPacket.malformed }
        } else {
            state = nested["state"] as? String
            let states = ["idle", "scanning", "connecting", "active", "stale", "reconnecting", "stopped", "failed",
                          "configuring", "complete", "inspecting", "magnetic"]
            guard let state, states.contains(state) else { throw InvalidPacket.malformed }
        }
        return .init(kind: kind, source: source, instance: instance, session: session, reference: reference,
                     revision: revision, sequence: sequence, state: state)
    }
}
