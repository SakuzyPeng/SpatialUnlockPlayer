import Foundation

enum EQFilterType: String, Codable, Sendable, CaseIterable {
    case peak = "PK", lowShelf = "LSC", highShelf = "HSC"
    var nativeValue: UInt32 {
        switch self {
        case .peak: UInt32(SpatialEQPeak)
        case .lowShelf: UInt32(SpatialEQLowShelf)
        case .highShelf: UInt32(SpatialEQHighShelf)
        }
    }
}

struct EQFilter: Codable, Equatable, Sendable, Identifiable {
    let id: Int
    let enabled: Bool
    let type: EQFilterType
    let frequency: Double
    let gain: Double
    let q: Double
    var native: SpatialEQFilter {
        SpatialEQFilter(type: type.nativeValue, enabled: enabled ? 1 : 0, frequency: frequency, gain: gain, q: q)
    }
}

struct EQImportError: LocalizedError {
    let line: Int?
    let reason: String
    var errorDescription: String? { line.map { "第 \($0) 行：\(reason)" } ?? reason }
}

struct EqualizerPreset: Codable, Equatable, Sendable {
    let name: String
    let preamp: Double
    let filters: [EQFilter]

    func validate() throws {
        guard !name.isEmpty, name.count <= 512, filters.count <= Int(SpatialEQMaxFilters),
              Set(filters.map(\.id)).count == filters.count,
              preamp.isFinite, pow(10, preamp / 20).isFinite, pow(10, preamp / 20) > 0 else {
            throw EQImportError(line: nil, reason: "EQ 配置或前级增益无效。")
        }
        for filter in filters {
            guard filter.id > 0, filter.frequency.isFinite, filter.frequency > 0,
                  filter.gain.isFinite, filter.q.isFinite, filter.q > 0,
                  pow(10, filter.gain / 40).isFinite, pow(10, filter.gain / 40) > 0 else {
                throw EQImportError(line: nil, reason: "滤波器 \(filter.id) 的参数无效。")
            }
        }
    }

    static func parse(_ text: String, name: String) throws -> Self {
        let number = #"([+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?)"#
        let preampPattern = try NSRegularExpression(pattern: "^Preamp\\s*:\\s*\(number)\\s+dB$", options: .caseInsensitive)
        let filterPattern = try NSRegularExpression(pattern:
            "^Filter\\s+(\\d+)\\s*:\\s*(ON|OFF)\\s+(\\w+)\\s+Fc\\s+\(number)\\s+Hz\\s+Gain\\s+\(number)\\s+dB\\s+Q\\s+\(number)$",
            options: .caseInsensitive)
        var preamp: Double?
        var filters: [EQFilter] = []
        let source = text.hasPrefix("\u{feff}") ? String(text.dropFirst()) : text
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        for (index, raw) in lines.enumerated() {
            let line = raw.prefix { $0 != "#" && $0 != ";" }.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            let range = NSRange(line.startIndex..., in: line)
            func capture(_ match: NSTextCheckingResult, _ group: Int) -> String {
                Range(match.range(at: group), in: line).map { String(line[$0]) } ?? ""
            }
            func invalid(_ reason: String) -> EQImportError { .init(line: index + 1, reason: reason) }
            if let match = preampPattern.firstMatch(in: line, range: range) {
                guard preamp == nil else { throw invalid("前级增益只能声明一次。") }
                guard let value = Double(capture(match, 1)), value.isFinite,
                      pow(10, value / 20).isFinite, pow(10, value / 20) > 0 else { throw invalid("前级增益无效。") }
                preamp = value
            } else if let match = filterPattern.firstMatch(in: line, range: range) {
                guard filters.count < Int(SpatialEQMaxFilters) else { throw invalid("最多支持 32 个滤波器。") }
                guard let id = Int(capture(match, 1)), id > 0, !filters.contains(where: { $0.id == id }) else {
                    throw invalid("滤波器编号必须为不重复的正整数。")
                }
                guard let type = EQFilterType(rawValue: capture(match, 3).uppercased()) else {
                    throw invalid("仅支持 PK、LSC 和 HSC 滤波器。")
                }
                guard let frequency = Double(capture(match, 4)), frequency.isFinite, frequency > 0,
                      let gain = Double(capture(match, 5)), gain.isFinite,
                      let q = Double(capture(match, 6)), q.isFinite, q > 0,
                      pow(10, gain / 40).isFinite, pow(10, gain / 40) > 0 else {
                    throw invalid("频率和 Q 必须为有限正数，增益必须为有效数值。")
                }
                filters.append(.init(id: id, enabled: capture(match, 2).uppercased() == "ON",
                                     type: type, frequency: frequency, gain: gain, q: q))
            } else {
                throw invalid("无法识别。请使用 Preamp 或带 Fc、Gain、Q 的参数滤波器行。")
            }
        }
        guard preamp != nil || !filters.isEmpty else { throw EQImportError(line: nil, reason: "文件中没有参数 EQ 配置。") }
        let result = Self(name: name, preamp: preamp ?? 0, filters: filters)
        try result.validate()
        return result
    }

    func coefficients(sampleRate: Double) -> [SpatialEQCoefficients]? {
        var result: [SpatialEQCoefficients] = []
        for filter in filters where filter.enabled {
            var c = SpatialEQCoefficients()
            guard SpatialEQMakeCoefficients(filter.native, sampleRate, &c) else { return nil }
            result.append(c)
        }
        return result
    }

    func response(frequencies: [Double], sampleRate: Double) -> [Double]? {
        guard let coefficients = coefficients(sampleRate: sampleRate) else { return nil }
        return frequencies.map { frequency in
            coefficients.reduce(preamp) { $0 + SpatialEQCoefficientResponse($1, sampleRate, frequency) }
        }
    }
}
