import Foundation

struct PoseBridgeSnapshot: Sendable {
    var listening = false
    var error: String?
    var source = ""
    var fresh = false
    var heartbeatAlive = false
    var sourceState = ""
    var ageMilliseconds: Double?
    var accepted: UInt64 = 0
    var invalid: UInt64 = 0
    var ignored: UInt64 = 0
    var missingTransmissions: UInt64 = 0
    var referenceChanges: UInt64 = 0
    var recenters: UInt64 = 0
    var head = PoseQuaternion.identity
}

// Used exclusively on the receiver queue. The source's received_ns clock is
// deliberately not compared with host uptime; freshness uses age_at_send plus
// the elapsed host time since receipt of that specific, nonduplicate packet.
struct PoseBridgeConsumer {
    let sourceFilter: String
    private(set) var source = ""
    private(set) var accepted: UInt64 = 0
    private(set) var invalid: UInt64 = 0
    private(set) var ignored: UInt64 = 0
    private(set) var missingTransmissions: UInt64 = 0
    private(set) var referenceChanges: UInt64 = 0
    private(set) var recenters: UInt64 = 0
    private(set) var head = PoseQuaternion.identity
    private var latest: PoseBridgePose?
    private var receivedAt: UInt64 = 0
    private var deadline: UInt64 = 0
    private var alignment = PoseQuaternion.identity
    private var frozen = true
    private var terminal = false
    private var retiredInstances: [Int64] = []
    private var retiredSessions: [Int64] = []
    private var statusSequence: Int64 = 0
    private var infoSequence: Int64 = 0
    private var minimumReference: Int64 = 0
    private var minimumRevision: Int64 = 0
    private var lastStatusAt: UInt64?
    private var sourceState = ""

    init(sourceFilter: String = "") { self.sourceFilter = sourceFilter }
    func isFresh(at now: UInt64) -> Bool { latest != nil && !frozen && !terminal && now < deadline }
    mutating func invalidPacket() { invalid &+= 1 }
    mutating func consume(_ message: PoseBridgeMessage, at now: UInt64) -> PoseQuaternion? {
        switch message {
        case .pose(let pose): return consume(pose, at: now)
        case .telemetry(let value): consume(value, at: now); return nil
        }
    }
    private mutating func consume(_ pose: PoseBridgePose, at now: UInt64) -> PoseQuaternion? {
        guard (sourceFilter.isEmpty || pose.source == sourceFilter), (source.isEmpty || source == pose.source),
              pose.ageAtSend < PoseBridgeProtocol.poseLifetime,
              !retiredInstances.contains(pose.instance) else { ignored &+= 1; return nil }
        var changedReference = latest == nil
        if let old = latest {
            if pose.instance != old.instance {
                // Avoid alternating between two live senders using one logical source.
                guard !isFresh(at: now) else { ignored &+= 1; return nil }
                retire(old.instance, in: &retiredInstances)
                retiredSessions.removeAll(); resetTelemetry()
                changedReference = true
            } else {
                guard !terminal, pose.transmission > old.transmission,
                      pose.reference >= max(old.reference, minimumReference),
                      pose.revision >= max(old.revision, minimumRevision),
                      !retiredSessions.contains(pose.session) else { ignored &+= 1; return nil }
                if pose.session != old.session {
                    guard !isFresh(at: now) else { ignored &+= 1; return nil }
                    retire(old.session, in: &retiredSessions)
                    resetTelemetry()
                    changedReference = true
                } else {
                    guard pose.sequence > old.sequence else { ignored &+= 1; return nil }
                    changedReference = pose.reference != old.reference
                }
                missingTransmissions &+= UInt64(max(0, pose.transmission - old.transmission - 1))
            }
        }
        if changedReference {
            // First pose defines forward. After reconnect/reference changes keep
            // the presented orientation continuous until the user recenters.
            alignment = (head * pose.physical.inverse).normalized ?? .identity
            referenceChanges &+= 1
        }
        if let next = (alignment * pose.physical).normalized {
            head = next.matchingHemisphere(of: head)
        }
        source = pose.source; latest = pose; receivedAt = now
        minimumReference = pose.reference; minimumRevision = pose.revision
        let expiry = now.addingReportingOverflow(PoseBridgeProtocol.poseLifetime - pose.ageAtSend)
        deadline = expiry.overflow ? .max : expiry.partialValue
        frozen = false; terminal = false; accepted &+= 1
        // Apple property 3102 rotates the scene into head coordinates.
        return head.inverse
    }
    private mutating func consume(_ value: PoseBridgeTelemetry, at now: UInt64) {
        guard let pose = latest, value.source == source, value.instance == pose.instance,
              value.session == pose.session, value.reference >= max(pose.reference, minimumReference),
              value.revision >= max(pose.revision, minimumRevision)
        else { ignored &+= 1; return }
        if value.kind == "info" {
            guard value.sequence > infoSequence else { ignored &+= 1; return }
            infoSequence = value.sequence
        } else {
            guard value.sequence > statusSequence else { ignored &+= 1; return }
            statusSequence = value.sequence; lastStatusAt = now; sourceState = value.state ?? ""
            if sourceState != "active" { frozen = true }
            if sourceState == "stopped" || sourceState == "failed" { terminal = true }
        }
        // A descriptor/heartbeat can announce a new reference before its first
        // pose arrives. Older queued poses must not cross that boundary.
        minimumReference = value.reference; minimumRevision = value.revision
        if value.reference > pose.reference { frozen = true }
    }
    private mutating func resetTelemetry() {
        statusSequence = 0; infoSequence = 0; lastStatusAt = nil; sourceState = ""; terminal = false
        minimumReference = 0; minimumRevision = 0
    }
    private func retire(_ value: Int64, in values: inout [Int64]) {
        values.append(value)
        if values.count > 128 { values.removeFirst(values.count - 128) }
    }
    mutating func recenter(at now: UInt64) -> PoseQuaternion? {
        guard isFresh(at: now), let latest else { return nil }
        alignment = latest.physical.inverse; head = .identity; recenters &+= 1
        return .identity
    }
    func snapshot(at now: UInt64) -> PoseBridgeSnapshot {
        var result = PoseBridgeSnapshot()
        result.source = source; result.fresh = isFresh(at: now); result.sourceState = sourceState
        if let lastStatusAt, now >= lastStatusAt { result.heartbeatAlive = now - lastStatusAt < PoseBridgeProtocol.heartbeatLifetime }
        if let latest { result.ageMilliseconds = Double(latest.ageAtSend) / 1e6 + Double(now >= receivedAt ? now - receivedAt : 0) / 1e6 }
        result.accepted = accepted; result.invalid = invalid; result.ignored = ignored
        result.missingTransmissions = missingTransmissions; result.referenceChanges = referenceChanges
        result.recenters = recenters; result.head = head
        return result
    }
}
