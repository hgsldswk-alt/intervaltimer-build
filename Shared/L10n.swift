import Foundation

enum L {
    static func t(_ key: String) -> String { Bundle.main.localizedString(forKey: key, value: nil, table: nil) }
    static func f(_ key: String, _ values: CVarArg...) -> String {
        String(format: t(key), locale: Locale.current, arguments: values)
    }
}
