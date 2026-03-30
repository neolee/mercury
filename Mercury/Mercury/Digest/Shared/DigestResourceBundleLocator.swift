import Foundation

private nonisolated final class DigestResourceBundleSentinel {}

nonisolated enum DigestResourceBundleLocator {
    nonisolated static func bundle() -> Bundle {
        let moduleBundle = Bundle(for: DigestResourceBundleSentinel.self)
        if hasDigestTemplates(in: moduleBundle) {
            return moduleBundle
        }

        if hasDigestTemplates(in: .main) {
            return .main
        }

        if let candidate = Bundle.allBundles.first(where: hasDigestTemplates(in:)) {
            return candidate
        }

        return moduleBundle
    }

    nonisolated private static func hasDigestTemplates(in bundle: Bundle) -> Bool {
        bundle.url(forResource: "single-text", withExtension: "yaml", subdirectory: DigestTemplateStore.builtInSubdirectory) != nil ||
        bundle.url(forResource: "single-markdown", withExtension: "yaml", subdirectory: DigestTemplateStore.builtInSubdirectory) != nil ||
        bundle.url(forResource: "multiple-markdown", withExtension: "yaml", subdirectory: DigestTemplateStore.builtInSubdirectory) != nil
    }
}
