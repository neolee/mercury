import Foundation
import GRDB
import Testing
@testable import Mercury

@Suite("Tag Alias Bypass")
@MainActor
struct TagAliasBypassTests {

    @Test("Simulated LLM outputs collapse to canonical names via alias resolver")
    @MainActor
    func resolvesAliasOutputsToCanonicalNames() async throws {
        try await InMemoryDatabaseFixture.withFixture { fixture in
            let db = fixture.database

            let llmTagId: Int64 = try await db.write { d in
                var tag = Tag(id: nil, name: "Large Language Models", normalizedName: "large language models", isProvisional: false, usageCount: 12)
                try tag.insert(d)
                return tag.id!
            }

            let deepLearningTagId: Int64 = try await db.write { d in
                var tag = Tag(id: nil, name: "Machine Learning", normalizedName: "machine learning", isProvisional: false, usageCount: 18)
                try tag.insert(d)
                return tag.id!
            }

            let chatgptTagId: Int64 = try await db.write { d in
                var tag = Tag(id: nil, name: "Generative AI", normalizedName: "generative ai", isProvisional: false, usageCount: 9)
                try tag.insert(d)
                return tag.id!
            }

            try await db.write { d in
                var aliasLLM = TagAlias(id: nil, tagId: llmTagId, alias: "LLM", normalizedAlias: "llm")
                try aliasLLM.insert(d)

                var aliasDeepLearning = TagAlias(id: nil, tagId: deepLearningTagId, alias: "Deep Learning", normalizedAlias: "deep learning")
                try aliasDeepLearning.insert(d)

                var aliasChatGPT = TagAlias(id: nil, tagId: chatgptTagId, alias: "ChatGPT", normalizedAlias: "chatgpt")
                try aliasChatGPT.insert(d)
            }

            let result = try await resolveTagNamesFromDB(["LLM", "Deep Learning", "ChatGPT"], database: db)
            #expect(result == ["Large Language Models", "Machine Learning", "Generative AI"])
        }
    }

    @Test("Unrecognized LLM output names remain as new proposals with original display casing")
    @MainActor
    func keepsUnrecognizedOutputsAsProposals() async throws {
        try await InMemoryDatabaseFixture.withFixture { fixture in
            let db = fixture.database

            let result = try await resolveTagNamesFromDB(["Edge AI", "RAG Ops"], database: db)
            #expect(result == ["Edge AI", "RAG Ops"])
        }
    }
}
