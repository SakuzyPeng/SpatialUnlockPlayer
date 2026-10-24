import Foundation

struct PoseQuaternion: Equatable, Sendable {
    var x: Double
    var y: Double
    var z: Double
    var w: Double

    static let identity = Self(x: 0, y: 0, z: 0, w: 1)
    var inverse: Self { Self(x: -x, y: -y, z: -z, w: w) }
    func matchingHemisphere(of previous: Self) -> Self {
        if x*previous.x + y*previous.y + z*previous.z + w*previous.w < 0 {
            return Self(x: -x, y: -y, z: -z, w: -w)
        }
        return self
    }
    var normalized: Self? {
        let n = x*x + y*y + z*z + w*w
        guard n.isFinite, n > 1e-12 else { return nil }
        let scale = 1 / sqrt(n)
        return Self(x: x*scale, y: y*scale, z: z*scale, w: w*scale)
    }
    static func * (a: Self, b: Self) -> Self {
        Self(x: a.w*b.x + a.x*b.w + a.y*b.z - a.z*b.y,
             y: a.w*b.y - a.x*b.z + a.y*b.w + a.z*b.x,
             z: a.w*b.z + a.x*b.y - a.y*b.x + a.z*b.w,
             w: a.w*b.w - a.x*b.x - a.y*b.y - a.z*b.z)
    }
    private static func axis(_ axis: Int, radians: Double) -> Self {
        let s = sin(radians / 2), c = cos(radians / 2)
        return Self(x: axis == 0 ? s : 0, y: axis == 1 ? s : 0, z: axis == 2 ? s : 0, w: c)
    }
    // PoseBridge's wire YXZ profile is not a scene coordinate basis. Decode its
    // named angles, then rebuild physical X-right/Y-forward/Z-up as ZXY.
    static func physical(yaw: Double, pitch: Double, roll: Double) -> Self? {
        guard [yaw, pitch, roll].allSatisfy({ $0.isFinite && abs($0) <= 1e6 }) else { return nil }
        let scale = Double.pi / 180
        return (axis(2, radians: yaw*scale) * axis(0, radians: pitch*scale) * axis(1, radians: roll*scale)).normalized
    }
    static func fromPoseBridge(x: Double, y: Double, z: Double, w: Double) -> Self? {
        let n = x*x + y*y + z*z + w*w
        guard n.isFinite, (0.81...1.21).contains(n),
              let q = Self(x: x, y: y, z: z, w: w).normalized else { return nil }
        let scale = 180 / Double.pi
        let yaw = atan2(2*(q.x*q.z + q.w*q.y), 1 - 2*(q.x*q.x + q.y*q.y)) * scale
        let pitch = asin(min(1, max(-1, 2*(q.w*q.x - q.y*q.z)))) * scale
        let roll = atan2(2*(q.x*q.y + q.w*q.z), 1 - 2*(q.x*q.x + q.z*q.z)) * scale
        return physical(yaw: yaw, pitch: pitch, roll: roll)
    }
    var physicalEuler: (yaw: Double, pitch: Double, roll: Double) {
        let scale = 180 / Double.pi
        let pitch = asin(min(1, max(-1, 2*(y*z + w*x))))
        if abs(cos(pitch)) < 1e-7 {
            return (atan2(2*(x*y + w*z), 1 - 2*(y*y + z*z))*scale, pitch*scale, 0)
        }
        return (atan2(2*(w*z - x*y), 1 - 2*(x*x + z*z))*scale, pitch*scale,
                atan2(2*(w*y - x*z), 1 - 2*(x*x + y*y))*scale)
    }
}
