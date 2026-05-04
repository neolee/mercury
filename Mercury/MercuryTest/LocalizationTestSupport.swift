import Foundation

func localizedTestString(_ key: String, bundle: Bundle) -> String {
    bundle.localizedString(forKey: key, value: key, table: nil)
}

func localizedTestString(_ key: String, _ arguments: CVarArg..., bundle: Bundle) -> String {
    String(format: localizedTestString(key, bundle: bundle), arguments: arguments)
}
