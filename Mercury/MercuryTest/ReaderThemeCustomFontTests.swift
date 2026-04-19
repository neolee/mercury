import Testing
@testable import Mercury

@MainActor
struct ReaderThemeCustomFontTests {
    @Test("Custom serif family builds serif fallback stack")
    func customSerifFamilyBuildsSerifFallbackStack() {
        let override = ReaderThemeRules.makeOverride(
            variant: .normal,
            quickStylePresetRaw: ReaderThemeQuickStylePresetID.none.rawValue,
            fontSizeOverride: 0,
            lineHeightOverride: 0,
            contentWidthOverride: 0,
            fontFamilyOptionRaw: ReaderThemeFontFamilyOptionID.custom.rawValue,
            customFontFamilyName: "Times New Roman"
        )

        #expect(
            override?.fontFamilyBody
                == "\"Times New Roman\", \"Iowan Old Style\", \"New York\", Charter, Georgia, \"Times New Roman\", serif"
        )
    }

    @Test("Custom sans family builds sans fallback stack")
    func customSansFamilyBuildsSansFallbackStack() {
        let override = ReaderThemeRules.makeOverride(
            variant: .normal,
            quickStylePresetRaw: ReaderThemeQuickStylePresetID.none.rawValue,
            fontSizeOverride: 0,
            lineHeightOverride: 0,
            contentWidthOverride: 0,
            fontFamilyOptionRaw: ReaderThemeFontFamilyOptionID.custom.rawValue,
            customFontFamilyName: "Helvetica"
        )

        #expect(
            override?.fontFamilyBody
                == "\"Helvetica\", -apple-system, system-ui, \"SF Pro Text\", \"Helvetica Neue\", Helvetica, Arial, sans-serif"
        )
    }

    @Test("Custom monospace family builds mono fallback stack")
    func customMonospaceFamilyBuildsMonoFallbackStack() {
        let override = ReaderThemeRules.makeOverride(
            variant: .normal,
            quickStylePresetRaw: ReaderThemeQuickStylePresetID.none.rawValue,
            fontSizeOverride: 0,
            lineHeightOverride: 0,
            contentWidthOverride: 0,
            fontFamilyOptionRaw: ReaderThemeFontFamilyOptionID.custom.rawValue,
            customFontFamilyName: "Menlo"
        )

        #expect(
            override?.fontFamilyBody
                == "\"Menlo\", \"SF Mono\", Menlo, Monaco, Consolas, \"Liberation Mono\", \"Courier New\", monospace"
        )
    }

    @Test("Empty custom family name produces no font override")
    func emptyCustomFamilyNameProducesNoFontOverride() {
        let override = ReaderThemeRules.makeOverride(
            variant: .normal,
            quickStylePresetRaw: ReaderThemeQuickStylePresetID.none.rawValue,
            fontSizeOverride: 0,
            lineHeightOverride: 0,
            contentWidthOverride: 0,
            fontFamilyOptionRaw: ReaderThemeFontFamilyOptionID.custom.rawValue,
            customFontFamilyName: "   "
        )

        #expect(override == nil)
    }

    @Test("Custom font changes reader cache theme identity")
    func customFontChangesReaderCacheThemeIdentity() {
        let baseTheme = ReaderThemeResolver.resolve(
            presetID: .classic,
            mode: .forceLight,
            isSystemDark: false,
            override: nil
        )

        let customTheme = ReaderThemeResolver.resolve(
            presetID: .classic,
            mode: .forceLight,
            isSystemDark: false,
            override: ReaderThemeRules.makeOverride(
                variant: .normal,
                quickStylePresetRaw: ReaderThemeQuickStylePresetID.none.rawValue,
                fontSizeOverride: 0,
                lineHeightOverride: 0,
                contentWidthOverride: 0,
                fontFamilyOptionRaw: ReaderThemeFontFamilyOptionID.custom.rawValue,
                customFontFamilyName: "Helvetica"
            )
        )

        #expect(baseTheme.cacheThemeID != customTheme.cacheThemeID)
    }
}
