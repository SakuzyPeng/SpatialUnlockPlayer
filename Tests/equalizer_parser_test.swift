import Foundation

@main
struct EqualizerParserTest {
    @MainActor static func main() throws {
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1])
        let text = try String(contentsOf: fixture, encoding: .utf8)
        let preset = try EqualizerPreset.parse(text, name: "Sony MDR-MV1")
        precondition(preset.preamp == -3.12 && preset.filters.count == 10)
        precondition(preset.filters.filter { $0.type == .peak }.count == 8)
        precondition(preset.filters.first?.type == .lowShelf && preset.filters.last?.type == .highShelf)
        precondition(preset.filters[1].frequency == 47.6 && preset.filters[5].q == 6)
        try FileManager.default.createDirectory(atPath: "Tests/Artifacts/equalizer", withIntermediateDirectories: true)
        try JSONEncoder().encode(preset).write(to: URL(fileURLWithPath: "Tests/Artifacts/equalizer/sony-normalized.json"))
        let variant = "\u{feff}# header\r\nPreamp: -3.12 dB ; comment\rFilter 2: OFF PK Fc 47.6 Hz Gain -1.0 dB Q 2.18\r\n"
        let parsed = try EqualizerPreset.parse(variant, name: "variant")
        precondition(parsed.filters.count == 1 && !parsed.filters[0].enabled)
        precondition(parsed.response(frequencies: [20, 1000, 20000], sampleRate: 48000) == [-3.12, -3.12, -3.12])
        for bad in ["Preamp: NaN dB", "Include: other.txt", "Filter 1: ON LS Fc 100 Hz Gain 1 dB Q 1",
                    "Filter 1: ON PK Fc 0 Hz Gain 1 dB Q 1", "Filter 1: ON PK Fc 100 Hz Gain 1 dB Q 0",
                    "Preamp: 1e999 dB", "Filter 1: ON PK Fc 100 Hz Gain inf dB Q 1"] {
            do { _ = try EqualizerPreset.parse("# comment\n" + bad, name: "bad"); preconditionFailure("Accepted invalid EQ") }
            catch let error as EQImportError { precondition(error.line == 2) }
        }
        for bad in ["Preamp: 0 dB\nPreamp: 1 dB", String(repeating: "Filter 1: ON PK Fc 100 Hz Gain 1 dB Q 1\n", count: 2),
                    (1...33).map { "Filter \($0): ON PK Fc 100 Hz Gain 1 dB Q 1" }.joined(separator: "\n")] {
            do { _ = try EqualizerPreset.parse(bad, name: "bad"); preconditionFailure("Accepted duplicate/over-limit EQ") }
            catch is EQImportError {}
        }
        let suite = "local.sakuzy.SpatialUnlockPlayer.EQTests"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let temporary = URL(fileURLWithPath: "build/tests/imported-eq.txt")
        try text.write(to: temporary, atomically: true, encoding: .utf8)
        let model = EqualizerModel(defaults: defaults)
        precondition(model.preset == nil && !model.isEnabled)
        try model.importPreset(temporary)
        precondition(model.isEnabled && model.preset?.filters == preset.filters)
        let previous = model.preset
        try "Filter 1: ON NOT_SUPPORTED Fc 100 Hz Gain 1 dB Q 1".write(to: temporary, atomically: true, encoding: .utf8)
        do { try model.importPreset(temporary); preconditionFailure("Bad import replaced preset") }
        catch is EQImportError { precondition(model.preset == previous && model.isEnabled) }
        model.shutdown()
        try FileManager.default.removeItem(at: temporary)
        let restored = EqualizerModel(defaults: defaults)
        precondition(restored.isEnabled && restored.preset == previous)
        restored.setRenderingAllowed(false)
        precondition(!restored.isApplied && restored.statusText.contains("未应用"))
        restored.setEnabled(false); restored.shutdown()
        let disabled = EqualizerModel(defaults: defaults)
        precondition(!disabled.isEnabled && disabled.preset == previous); disabled.shutdown()
        for rate in [44100.0, 48000, 96000] {
            let response = preset.response(frequencies: [20, 100, 1000, 4132.9, 10000, 20000], sampleRate: rate)!
            precondition(response.allSatisfy(\.isFinite))
        }
        print("PASS: Sony 10-band precision, PK/LSC/HSC, OFF, BOM/comments/newlines, line errors, transactional imports and independent persistence")
    }
}
