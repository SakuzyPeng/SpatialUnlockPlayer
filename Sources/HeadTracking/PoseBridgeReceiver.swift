import Foundation
import Dispatch
import Darwin

// Socket, decoder and consumer are confined to this queue. The only crossing
// into audio rendering is the C shim's atomic quaternion mailbox.
final class PoseBridgeReceiver: @unchecked Sendable {
    private struct Configuration: Sendable { let port: UInt16; let source: String }
    private let queue = DispatchQueue(label: "local.sakuzy.posebridge.receiver", qos: .userInitiated)
    private var desired: Configuration?
    private var socketSource: DispatchSourceRead?
    private var timer: DispatchSourceTimer?
    private var descriptor: Int32 = -1
    private var closing = false
    private var consumer = PoseBridgeConsumer()
    private var failure: String?
    private var onUpdate: (@Sendable (PoseBridgeSnapshot) -> Void)?
    private var buffer = [UInt8](repeating: 0, count: PoseBridgeProtocol.maxPacketBytes + 1)

    func start(port: UInt16, source: String, onUpdate: @escaping @Sendable (PoseBridgeSnapshot) -> Void) {
        queue.async { [self] in
            desired = .init(port: port, source: source)
            self.onUpdate = onUpdate; failure = nil
            if socketSource != nil { cancelSocket() }
            else if !closing { openSocket() }
        }
    }
    func stop() {
        queue.async { [self] in desired = nil; failure = nil; cancelSocket(); emitSnapshot() }
    }
    func shutdown() {
        queue.sync { desired = nil; onUpdate = nil; cancelSocket() }
    }
    func recenter() {
        queue.async { [self] in
            if let q = consumer.recenter(at: DispatchTime.now().uptimeNanoseconds) { publish(q) }
            emitSnapshot()
        }
    }
    private func openSocket() {
        guard let desired, descriptor == -1, !closing else { return }
        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { fail("无法建立 UDP 接收：\(String(cString: strerror(errno)))"); return }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = desired.port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, fcntl(fd, F_SETFL, O_NONBLOCK) == 0, fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else {
            let reason = String(cString: strerror(errno)); Darwin.close(fd)
            fail("无法监听 127.0.0.1:\(desired.port)：\(reason)")
            return
        }
        descriptor = fd
        consumer = PoseBridgeConsumer(sourceFilter: desired.source)
        publish(.identity)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        socketSource = source
        source.setEventHandler { [weak self] in self?.receive(fd) }
        source.setCancelHandler { [weak self] in
            Darwin.close(fd)
            guard let self, self.descriptor == fd else { return }
            self.descriptor = -1; self.socketSource = nil; self.closing = false
            if self.desired != nil { self.openSocket() }
        }
        source.resume()
        let tick = DispatchSource.makeTimerSource(queue: queue)
        timer = tick
        tick.schedule(deadline: .now(), repeating: .milliseconds(100), leeway: .milliseconds(10))
        tick.setEventHandler { [weak self] in self?.emitSnapshot() }
        tick.resume()
        emitSnapshot()
    }
    private func cancelSocket() {
        timer?.cancel(); timer = nil
        guard let socketSource, !closing else { return }
        closing = true
        socketSource.cancel()
        // Closing happens in the cancel handler, before a pending new bind.
    }
    private func fail(_ text: String) {
        failure = text; desired = nil
        cancelSocket(); emitSnapshot()
    }
    private func receive(_ fd: Int32) {
        guard fd == descriptor, !closing, desired != nil else { return }
        for _ in 0..<128 {
            var sender = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = buffer.withUnsafeMutableBytes { storage in
                withUnsafeMutablePointer(to: &sender) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(fd, storage.baseAddress, storage.count, 0, $0, &length)
                    }
                }
            }
            let now = DispatchTime.now().uptimeNanoseconds
            if count < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK { break }
                if errno == EINTR { continue }
                fail("UDP 接收中断：\(String(cString: strerror(errno)))")
                return
            }
            guard sender.sin_family == sa_family_t(AF_INET), sender.sin_addr.s_addr == inet_addr("127.0.0.1"),
                  count > 0, count <= PoseBridgeProtocol.maxPacketBytes else { consumer.invalidPacket(); continue }
            do {
                let message = try PoseBridgeProtocol.decode(Data(buffer.prefix(count)))
                if let q = consumer.consume(message, at: now) { publish(q) }
            } catch { consumer.invalidPacket() }
        }
    }
    private func publish(_ q: PoseQuaternion) {
        _ = SpatialHeadPosePublish(Float(q.x), Float(q.y), Float(q.z), Float(q.w))
    }
    private func emitSnapshot() {
        var result = consumer.snapshot(at: DispatchTime.now().uptimeNanoseconds)
        result.listening = descriptor >= 0 && !closing && desired != nil
        result.error = failure
        onUpdate?(result)
    }
    deinit {
        timer?.cancel()
        socketSource?.cancel()
    }
}
