import Foundation
import Testing
@testable import Mercury

@Suite("Digest Template Store")
struct DigestTemplateStoreTests {
    @Test("Load built-in digest template from app bundle")
    func loadBuiltInTemplateFromBundle() throws {
        let store = DigestTemplateStore()
        let bundle = try mercuryAppBundle()
        try store.loadBuiltInTemplates(bundle: bundle, subdirectory: DigestTemplateStore.builtInSubdirectory)

        #expect(store.loadedTemplateIDs.contains("single-text"))
    }

    @Test("Load single-text template and render conditional note")
    func loadAndRenderSingleTextTemplate() throws {
        let store = DigestTemplateStore()
        try store.loadTemplates(from: templateDirectoryInRepository())

        let template = try store.template(id: "single-text")
        #expect(template.version == "v1")

        let renderedWithoutNote = template.render(
            context: DigestTemplateRenderContext(
                scalars: [
                    "articleTitle": "Mercury",
                    "articleAuthor": "Neo",
                    "articleURL": "https://example.com/article",
                    "includeNote": "",
                    "noteText": ""
                ]
            )
        )
        #expect(renderedWithoutNote == "Mercury by Neo https://example.com/article")

        let renderedWithNote = template.render(
            context: DigestTemplateRenderContext(
                scalars: [
                    "articleTitle": "Mercury",
                    "articleAuthor": "",
                    "articleURL": "https://example.com/article",
                    "includeNote": "true",
                    "noteText": "Worth reading."
                ]
            )
        )
        #expect(renderedWithNote == "Mercury https://example.com/article Worth reading.")
    }

    private func templateDirectoryInRepository() throws -> URL {
        let testsDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
        let templateDirectory = testsDirectory
            .appendingPathComponent("../Mercury/Resources/Digest/Templates")
            .standardizedFileURL

        guard FileManager.default.fileExists(atPath: templateDirectory.path) else {
            throw TestError.templateDirectoryNotFound(templateDirectory.path)
        }
        return templateDirectory
    }

    private func mercuryAppBundle() throws -> Bundle {
        if let bundle = Bundle.allBundles.first(where: { $0.bundleIdentifier == "net.paradigmx.Mercury" }) {
            return bundle
        }
        if let bundle = Bundle.allBundles.first(where: { $0.bundleURL.lastPathComponent == "Mercury.app" }) {
            return bundle
        }
        throw TestError.appBundleNotFound
    }
}

private enum TestError: Error {
    case templateDirectoryNotFound(String)
    case appBundleNotFound
}
