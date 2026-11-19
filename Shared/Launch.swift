import Foundation

enum Launch {
    static let freePeriod = false
    static let arguments = ProcessInfo.processInfo.arguments
    #if DEBUG
    static let testing = arguments.contains("-ui-testing")
    #else
    static let testing = false
    #endif
    static var isFree: Bool {
        freePeriod && !(testing && ["-paid-mode", "-paywall", "-expired"].contains(where: arguments.contains))
    }
    static func flag(_ flag: String) -> Bool { testing && arguments.contains(flag) }
    static var appStoreURL: URL? {
        guard let id = Bundle.main.object(forInfoDictionaryKey: "APP_STORE_ID") as? String,
              !id.isEmpty, id.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return URL(string: "https://apps.apple.com/app/id\(id)")
    }
}
