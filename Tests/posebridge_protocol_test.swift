import Foundation

private func check(_ value: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
    if !value() { fatalError("line \(line): \(message)") }
}
private func near(_ a: Double, _ b: Double, tolerance: Double = 1e-5) -> Bool { abs(a-b) < tolerance }
private func sameRotation(_ a: PoseQuaternion, _ b: PoseQuaternion) -> Bool {
    abs(abs(a.x*b.x+a.y*b.y+a.z*b.z+a.w*b.w)-1) < 1e-5
}
private struct Encoder {
    var data = Data()
    mutating func string(_ text: String) {
        data.append(contentsOf: text.utf8); data.append(0)
        while data.count % 4 != 0 { data.append(0) }
    }
    mutating func number(_ value: UInt64, _ count: Int) {
        for shift in stride(from: (count-1)*8, through: 0, by: -8) { data.append(UInt8(truncatingIfNeeded: value >> shift)) }
    }
    mutating func float(_ value: Float) { number(UInt64(value.bitPattern), 4) }
}
private func packet(quaternion: Bool = false, angles: [Float] = [0,0,0], sequence: Int64 = 1,
                    transmission: Int64? = nil, source: String = "headset", instance: Int64 = 1,
                    session: Int64 = 10, reference: Int64 = 1, revision: Int64 = 1,
                    age: Int64 = 0, received: Int64 = 0, kind: Int32 = 0,
                    time: Int64 = 0, epoch: Int64 = 0, version: Int32 = 3) -> Data {
    var e = Encoder()
    e.string(quaternion ? "/posebridge/quaternion" : "/posebridge/euler")
    e.string(quaternion ? ",ishhhhhhhhihhffff" : ",ishhhhhhhhihhfff")
    e.number(UInt64(UInt32(bitPattern: version)),4); e.string(source)
    for value in [instance,session,sequence,transmission ?? sequence,reference,revision,received,age] { e.number(UInt64(bitPattern:value),8) }
    e.number(UInt64(UInt32(bitPattern:kind)),4)
    e.number(UInt64(bitPattern:time),8); e.number(UInt64(bitPattern:epoch),8)
    angles.forEach { e.float($0) }
    return e.data
}
private func message(_ data: Data) -> PoseBridgeMessage { try! PoseBridgeProtocol.decode(data) }
private func rejected(_ data: Data) -> Bool {
    do { _ = try PoseBridgeProtocol.decode(data); return false } catch { return true }
}
private func status(sequence: Int64 = 1, state: String = "active", instance: Int64 = 1, session: Int64 = 10,
                    reference: Int64 = 1, revision: Int64 = 1) -> PoseBridgeMessage {
    .telemetry(.init(kind:"status",source:"headset",instance:instance,session:session,reference:reference,
                    revision:revision,sequence:sequence,state:state))
}
private func rotate(_ q: PoseQuaternion, _ v: (Double,Double,Double)) -> (Double,Double,Double) {
    let r = q * PoseQuaternion(x:v.0,y:v.1,z:v.2,w:0) * q.inverse
    return (r.x,r.y,r.z)
}

@main struct ProtocolTests {
    static func main() {
        let valid = packet(source:"耳机👨‍👩‍👧")
        check(!rejected(valid), "UTF-8 source including format characters")
        for length in 0..<valid.count { check(rejected(valid.prefix(length)), "truncated packet \(length)") }
        check(rejected(valid + Data([0,0,0,0])), "trailing bytes")
        check(rejected(Data(repeating: 0, count: 8193)), "packet size limit")
        for p in [packet(version:2),packet(sequence:0),packet(instance:-1),packet(session:0),
                  packet(reference:0),packet(revision:0),packet(age:500_000_000),packet(age:-1),
                  packet(source:"\n"),packet(source:String(repeating:"x",count:257)),packet(angles:[.nan,0,0]),
                  packet(kind:0,time:1),packet(kind:2,time:1,epoch:0),packet(kind:3),
                  packet(quaternion:true,angles:[0,0,0,0]),packet(quaternion:true,angles:[0,0,0,2])] {
            check(rejected(p), "invalid metadata or orientation")
        }
        check(!rejected(packet(received:Int64.max,kind:2,time:42,epoch:1)), "independent sample clock")
        if case .pose(let p) = message(packet(quaternion:true,angles:[0,0.70710678,0,0.70710678])) {
            check(near(p.physical.z,sqrt(0.5)) && near(p.physical.y,0), "wire Y yaw becomes physical Z")
        } else { fatalError() }
        if case .pose(let p) = message(packet(quaternion:true,angles:[0.189307857,0.239298338,0.038134576,0.951548525])) {
            // Independently apply Ry(roll), Rx(pitch), Rz(yaw) to a forward vector.
            let v = rotate(p.physical,(0,1,0))
            check(near(v.0,-sin(.pi/6)*cos(.pi/9)) && near(v.1,cos(.pi/6)*cos(.pi/9)) &&
                  near(v.2,sin(.pi/9)), "compound profile conversion preserves physical rotation order")
            let right = rotate(p.physical,(1,0,0)), y = Double.pi/6, p = Double.pi/9, r = Double.pi/18
            check(near(right.0,cos(y)*cos(r)-sin(y)*sin(p)*sin(r)) &&
                  near(right.1,sin(y)*cos(r)+cos(y)*sin(p)*sin(r)) &&
                  near(right.2,-cos(p)*sin(r)), "compound roll sign and order")
        }
        var consumer = PoseBridgeConsumer()
        let identity = consumer.consume(message(packet()),at:1_000)!
        check(sameRotation(identity,.identity), "first packet establishes forward")
        let left = consumer.consume(message(packet(angles:[45,0,0],sequence:2)),at:10_000)!
        let forward = rotate(left,(0,1,0))
        check(forward.0 > 0.7 && forward.1 > 0.7, "left head turn moves front source to the right")
        check(consumer.consume(message(packet(angles:[90,0,0],sequence:2,transmission:3)),at:20_000) == nil, "sample dedup")
        check(consumer.consume(message(packet(sequence:3,transmission:2)),at:20_000) == nil, "transmission dedup")
        check(consumer.consume(message(packet(sequence:3,source:"other")),at:20_000) == nil, "lock logical source")
        check(consumer.consume(message(packet(instance:2)),at:20_000) == nil, "do not mix concurrent instances")
        _ = consumer.consume(status(),at:30_000)
        _ = consumer.consume(status(sequence:2),at:500_010_000)
        check(!consumer.isFresh(at:500_010_000), "heartbeats do not prolong pose")
        check(consumer.consume(message(packet(sequence:2,transmission:3)),at:500_020_000) == nil, "duplicate cannot unfreeze")
        let resumed = consumer.consume(message(packet(angles:[50,0,0],sequence:3,transmission:5)),at:510_000_000)
        check(resumed != nil && consumer.missingTransmissions == 2, "resume on new sample and count tx gaps")
        check(consumer.recenter(at:510_000_001) == .identity, "local recenter")
        check(consumer.snapshot(at:510_000_001).recenters == 1, "recenter counter")
        let before = consumer.head
        _ = consumer.consume(message(packet(angles:[-60,20,10],sequence:4,transmission:6,reference:2,revision:2)),at:520_000_000)
        check(sameRotation(consumer.head,before), "reference change is continuous")
        check(consumer.consume(message(packet(sequence:5,transmission:7,reference:1,revision:2)),at:530_000_000) == nil, "old reference cannot return")
        check(consumer.consume(message(packet(sequence:5,transmission:7,reference:2,revision:1)),at:530_000_000) == nil, "old descriptor revision")
        _ = consumer.consume(status(sequence:3,state:"stopped",reference:2,revision:2),at:540_000_000)
        check(!consumer.isFresh(at:540_000_000), "terminal heartbeat freezes immediately")
        check(consumer.consume(message(packet(sequence:5,transmission:7,reference:2,revision:2)),at:550_000_000) == nil, "late pose cannot undo stop")
        _ = consumer.consume(message(packet(angles:[90,0,0],instance:2)),at:550_000_000)
        check(sameRotation(consumer.head,before), "new instance preserves presentation")
        check(consumer.consume(message(packet(sequence:99)),at:2_000_000_000) == nil, "retired instance cannot return")
        _ = consumer.consume(message(packet(angles:[100,0,0],sequence:2,instance:2)),at:2_000_000_000)
        _ = consumer.consume(status(state:"reconnecting",instance:2),at:2_010_000_000)
        let held = consumer.head
        _ = consumer.consume(message(packet(angles:[0,0,0],sequence:1,transmission:3,instance:2,session:20,reference:2,revision:2)),at:2_020_000_000)
        check(sameRotation(held,consumer.head), "new device session preserves presentation")
        check(consumer.consume(message(packet(sequence:50,transmission:50,instance:2,session:10,reference:2,revision:2)),at:3_000_000_000) == nil, "retired device session")

        var age = PoseBridgeConsumer(sourceFilter:"headset")
        _ = age.consume(message(packet(age:499_000_000)),at:10_000_000)
        check(age.isFresh(at:10_999_999) && !age.isFresh(at:11_000_000), "source age plus local elapsed boundary")
        check(age.recenter(at:11_000_000) == nil, "cannot recenter expired pose")
        var ahead = PoseBridgeConsumer()
        _ = ahead.consume(message(packet()),at:0)
        _ = ahead.consume(status(reference:2,revision:2),at:1)
        check(!ahead.isFresh(at:1), "metadata announces new reference before pose")
        check(ahead.consume(message(packet(sequence:2)),at:2) == nil, "old queued pose cannot cross metadata boundary")
        _ = ahead.consume(message(packet(sequence:3,reference:2,revision:2)),at:3)
        _ = ahead.consume(status(sequence:2,state:"stopped"),at:4)
        check(ahead.isFresh(at:4), "old metadata cannot overwrite new pose reference")
        var wrap = PoseBridgeConsumer()
        _ = wrap.consume(message(packet(angles:[179,0,0])),at:0)
        _ = wrap.consume(message(packet(angles:[-179,0,0],sequence:2)),at:1)
        check(near(wrap.head.physicalEuler.yaw,2), "wrap crosses two degrees rather than 358")
        check(wrap.head.w > 0, "quaternion sign stays continuous across angle wrap")

        var e = Encoder(); e.string("/posebridge/status"); e.string(",s")
        let telemetry: [String:Any] = ["schema":3,"kind":"status","source_id":"headset","instance_id":"1",
            "session_id":"10","reference_epoch":"1","metadata_revision":"1","message_seq":"1",
            "status":["session_id":"10","state":"active"]]
        e.string(String(data:try! JSONSerialization.data(withJSONObject:telemetry),encoding:.utf8)!)
        check(!rejected(e.data), "canonical status JSON")
        var bad = telemetry; bad["instance_id"] = 1
        var badEncoder = Encoder(); badEncoder.string("/posebridge/status"); badEncoder.string(",s")
        badEncoder.string(String(data:try! JSONSerialization.data(withJSONObject:bad),encoding:.utf8)!)
        check(rejected(badEncoder.data), "64-bit metadata must be decimal strings")
        var heartbeat = PoseBridgeConsumer()
        _ = heartbeat.consume(message(packet()),at:0)
        _ = heartbeat.consume(message(e.data),at:1_000)
        check(heartbeat.snapshot(at:2_999_999_999).heartbeatAlive, "heartbeat independent timeout")
        _ = heartbeat.consume(message(e.data),at:3_000_000_000)
        check(!heartbeat.snapshot(at:3_000_001_000).heartbeatAlive, "duplicate heartbeat does not refresh")
        print("PASS: OSC 3 wire validation, coordinate mapping, recenter, age, heartbeat, sequence/reference/session/instance changes")
    }
}
