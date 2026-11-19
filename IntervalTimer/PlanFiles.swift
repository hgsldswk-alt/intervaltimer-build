import Foundation
import UniformTypeIdentifiers

extension UTType {
    static let intervalPlan = UTType(exportedAs: "com.hgsldswk.intervaltimer.plan", conformingTo: .json)
}

enum PlanFiles {
    static func read(_ url: URL) throws -> PlanParameters {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var value: Result<PlanParameters, Error>?
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { file in
            value = Result {
                let handle = try FileHandle(forReadingFrom: file)
                defer { try? handle.close() }
                let bytes = try handle.read(upToCount: PlanTransfer.maxBytes + 1) ?? Data()
                return try PlanTransfer.decode(bytes)
            }
        }
        if let coordinationError { throw coordinationError }
        guard let value else { throw PlanTransfer.Invalid.input }
        return try value.get()
    }

    static func export(_ plans: [Plan]) throws -> [URL] {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("IntervalTimer-Share-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try plans.enumerated().map { index, plan in
            let suffix = CharacterSet.alphanumerics.union(.init(charactersIn: " -_"))
            let name = plan.name.components(separatedBy: suffix.inverted).joined(separator: "-")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let stem = name.isEmpty ? L.t("file.name") : name.unicodeScalars.prefix(55).map { String($0) }.joined()
            let filename = plans.count > 1 ? "\(index + 1)-\(stem)" : stem
            let url = folder.appendingPathComponent(filename).appendingPathExtension("intervalplan")
            try PlanTransfer.encode(plan.portableParameters).write(to: url, options: .atomic)
            return url
        }
    }
}
