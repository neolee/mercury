# Mercury AI Agent Notes

This file is for AI coding agents. It captures the current feature plan, baseline technical stack, and initial selection considerations. Update as the project evolves.

## Product Direction
Mercury is a modern, macOS-first RSS reader that prioritizes:
- Beautiful, fast reading experience
- High performance with offline capabilities
- AI assistance to auto tagging, summarization, and translation
- Local-first privacy and security

### Planned Features (MVP)
- Feed management: `RSS`/`Atom`/`JSON Feed` subscriptions
- Reading experience: three-pane layout, typography-focused article view
- AI assistance (opt-in): `auto-tag`, `translation`, single-article summary

### Planned Features (Post-MVP)
- More reading enhancements e.g. offline cache, local full-text search
- More AI assistance: multi-article summaries and topic digests

## Technical Stack (Baseline)
- Platform: `macOS`
- Language: `Swift`
- UI: `SwiftUI` (follow Apple best practices for architecture and UI)
- Networking: `URLSession`
- Storage: `SQLite` with `GRDB` (preferred) or `Core Data` (fallback)
- Rendering: `SwiftUI` text rendering with `WKWebView` fallback for complex HTML

## Initial Library Selections (Subject to Change)
- Feed parsing: `FeedKit` (RSS/Atom/JSON Feed) [https://github.com/nmdias/FeedKit](https://github.com/nmdias/FeedKit)
- HTML parsing/cleaning: `SwiftSoup` [https://github.com/scinfu/SwiftSoup](https://github.com/scinfu/SwiftSoup)
- Readability/article extraction: `swift-readability` [https://github.com/Ryu0118/swift-readability](https://github.com/Ryu0118/swift-readability)
- LLM client (OpenAI-compatible): `SwiftOpenAI` [https://github.com/jamesrochabrun/SwiftOpenAI](https://github.com/jamesrochabrun/SwiftOpenAI)

## AI Integration Guidelines
- Build an `LLMProvider` abstraction with support for OpenAI-compatible APIs.
- `Base URL` must be configurable to allow local model gateways in development.
- Support streaming (`SSE`) responses for progressive UI updates.
- Do not embed API keys in client builds; use local proxy/gateway for production.

## Privacy and Security Notes
- Local-first data storage.
- AI features opt-in and transparent about data use.
- Provide user controls to delete AI outputs and local data.

## Project Structure Guidance
- Keep the source layout flat by default; avoid deep folders unless a module is clearly reusable.
- Distinguish `View` and `ViewModel` by file naming (e.g., `ReaderView.swift`, `ReaderViewModel.swift`).
- Revisit folder structure only when file volume becomes a real maintainability issue.

## Development Principles
- Performance matters: avoid heavy `WKWebView` usage for normal reading flow.
- Keep UI crisp and keyboard-friendly.
- Follow Apple `SwiftUI` best practices for layout, state management, and architecture.
- Favor native `macOS` patterns unless a clear UX win exists.
- Update this file whenever key technical choices change.

## Build and Verification
- Build via `build`.
- Every change must keep the build free of compiler errors and warnings.

## Milestone Plan
1. RSS subscription and basic reading
2. Subscription sync and reading improvements
3. AI foundation (provider abstraction, task queue)
4. Initial AI features (auto-tag, single-article summary, translation)
5. Full strengthening and integration (multi-article summaries, polish, performance)
