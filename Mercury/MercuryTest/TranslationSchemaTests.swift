import Foundation
import GRDB
import Testing
@testable import Mercury

@Suite("Translation Schema")
struct TranslationSchemaTests {
    @Test("Migration creates translation payload tables and indexes")
    @MainActor
    func migrationCreatesTranslationTablesAndIndexes() throws {
        let dbPath = temporaryDatabasePath()
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let manager = try DatabaseManager(path: dbPath)

        try manager.dbQueue.read { db in
            #expect(try db.tableExists("translation_result"))
            #expect(try db.tableExists("translation_segment"))

            let resultColumns = try Set(db.columns(in: "translation_result").map(\.name))
            #expect(resultColumns.contains("taskRunId"))
            #expect(resultColumns.contains("entryId"))
            #expect(resultColumns.contains("targetLanguage"))
            #expect(resultColumns.contains("sourceContentHash"))
            #expect(resultColumns.contains("segmenterVersion"))
            #expect(resultColumns.contains("outputLanguage"))

            let segmentColumns = try Set(db.columns(in: "translation_segment").map(\.name))
            #expect(segmentColumns.contains("taskRunId"))
            #expect(segmentColumns.contains("sourceSegmentId"))
            #expect(segmentColumns.contains("orderIndex"))
            #expect(segmentColumns.contains("sourceTextSnapshot"))
            #expect(segmentColumns.contains("translatedText"))

            let indexNames = try Set(db.indexes(on: "translation_result").map(\.name))
            #expect(indexNames.contains("idx_translation_slot"))
            #expect(indexNames.contains("idx_translation_updated"))

            let segmentIndexNames = try Set(db.indexes(on: "translation_segment").map(\.name))
            #expect(segmentIndexNames.contains("idx_translation_segment_order"))
            #expect(segmentIndexNames.contains("idx_translation_segment_unique"))
        }
    }

    private func temporaryDatabasePath() -> String {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mercury-translation-schema-tests-\(UUID().uuidString).sqlite")
            .path
    }
}
