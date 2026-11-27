import Foundation

struct Plan: Codable, Equatable, Identifiable {
    let id: UUID
    var parameters: PlanParameters

    var name: String {
        guard let index = Self.presets.firstIndex(where: { $0.id == id }) else { return parameters.name }
        return L.t(["preset.standard", "preset.short", "preset.long"][index])
    }
    var portableParameters: PlanParameters {
        var value = parameters
        value.name = name
        return value
    }

    static let presets: [Plan] = [(40, 20, 8), (20, 10, 8), (60, 30, 6)].enumerated().map { index, item in
        let id = UUID(uuid: (0, 0, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, UInt8(index + 1)))
        return Plan(id: id, parameters: PlanParameters(name: "\(item.0) / \(item.1)", work: item.0,
                                                       rest: item.1, rounds: item.2))
    }
}

struct PlanParameters: Codable, Equatable {
    var version = 1
    var name: String
    var work: Int = 40
    var rest: Int = 20
    var rounds: Int = 8
    var prepare: Int = 10
    var cooldown: Int = 0

    var numbersValid: Bool {
        (5...600).contains(work) && (0...600).contains(rest) && (1...24).contains(rounds)
            && (0...120).contains(prepare) && (0...120).contains(cooldown)
    }
    var total: Int {
        guard numbersValid else { return 0 }
        return prepare + rounds * work + (rounds - 1) * rest + cooldown
    }
    var isValid: Bool {
        let invisible = CharacterSet.controlCharacters.union(.whitespacesAndNewlines)
        return version == 1 && numbersValid && total <= 7_200 && name.count <= 40
            && name.unicodeScalars.contains { !invisible.contains($0) }
            && !name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) && $0.value != 0x200D }
    }
}

enum PlanTransfer {
    static let prefix = "INTERVAL1:"
    static let maxBytes = 4_096
    static let maxCodeBytes = 6_144
    enum Invalid: Error { case input }

    static func encode(_ plan: PlanParameters) throws -> Data {
        guard plan.isValid else { throw Invalid.input }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(plan)
        guard bytes.count <= maxBytes else { throw Invalid.input }
        return bytes
    }

    static func decode(_ bytes: Data) throws -> PlanParameters {
        guard bytes.count <= maxBytes, let value = try? JSONDecoder().decode(PlanParameters.self, from: bytes),
              value.isValid else { throw Invalid.input }
        return value
    }

    static func code(_ plan: PlanParameters) throws -> String {
        prefix + (try encode(plan)).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decodeCode(_ text: String) throws -> PlanParameters {
        guard text.utf8.prefix(maxCodeBytes + 1).count <= maxCodeBytes else { throw Invalid.input }
        let lines = text.split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix(prefix) }
        guard lines.count == 1 else { throw Invalid.input }
        let encoded = lines[0].dropFirst(prefix.count)
        guard !encoded.isEmpty, encoded.utf8.allSatisfy({
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }) else { throw Invalid.input }
        let base64 = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let pad = (4 - base64.utf8.count % 4) % 4
        guard let bytes = Data(base64Encoded: base64 + String(repeating: "=", count: pad)) else { throw Invalid.input }
        return try decode(bytes)
    }
}

func timerText(_ seconds: Int) -> String {
    String(format: "%d:%02d", seconds / 60, seconds % 60)
}
