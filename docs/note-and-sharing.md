# Note and Sharing Feature Plan

## Overview

This document outlines the design and implementation plan for a new set of features aimed at allowing users to annotate, share, and summarize articles. The requirements are decoupled into three independent, modular components:
1. **Entry Note**: Persistent user annotations for individual articles.
2. **Entry Sharing**: Configurable single-article sharing via macOS native sharing services.
3. **Reader's Digest**: Multi-article synthesis and Markdown export for external publishing (e.g., blogs).

By decoupling these features, we can deliver them incrementally while maintaining a seamless and native macOS reading experience.

---

## 1. Entry Note

### Design
- Allows users to write and permanently save short comments, thoughts, or annotations for a specific article.
- **UI Integration**: A new "Note" button in the Reader toolbar.
- **Interaction**: Clicking the button opens a lightweight, non-blocking dropdown panel (as implemented in `tagging` and `style` panel features). The user can type their thoughts without interrupting their reading flow. Dismissing the popover automatically saves the note.

### Implementation Details
- **Data Model**: Introduce a new `EntryNote` table in the SQLite database (or extend the existing `Entry` schema) via a GRDB migration to store the annotation (`entryId`, `text`, `updatedAt`).
- **Persistence**: Notes must persist across app launches and sync accurately with the UI.

---

## 2. Entry Sharing

### Design
- Enhances the existing "Share" functionality (which currently only supports "Copy URL" and "Open in Default Browser").
- **UI Integration**: Add a "Share..." or "Share Article..." option to the existing Share menu in the Reader toolbar.
- **Configuration Sheet**: Opens a small sheet allowing the user to construct their shared message. Checkboxes will let them selectively include:
  - Article Title & Link
  - AI Summary / Excerpt
  - User's Note
- **System Dispatch**: After configuration, the generated Markdown/Text payload is dispatched to the native macOS share menu (`NSSharingServicePicker` or `ShareLink`) for easy routing to Messages, Notes, social media, etc.

### Implementation Details
- **String Interpolation**: Build a robust text formatter that conditionally appends the selected metadata.
- **Native Integration**: Use SwiftUI's `ShareLink` or wrap `NSSharingServicePicker` to handle the actual sharing action.

---

## 3. Reader's Digest

### Design
- An independent feature enabling the aggregation of multiple selected articles into a single digest or newsletter format. This replaces the need for a complex "queue" state.
- **UI Integration**: Users select multiple articles in the Entry List view (Sidebar/Feed). A right-click context menu or toolbar button offers a "Generate Digest..." action.
- **Generation Modes**:
  - *Standard Template (Markdown)*: Directly concatenates the titles, links, summaries, and user notes of the selected articles into a clean list.
  - *AI Synthesized Post*: Routes the selected articles and user notes through the `AgentRunCoordinator` to generate an editorial introduction, group common themes, and format the output.
- **Export Mechanism**: Presents a preview sheet of the generated Markdown along with a "Save As..." button (`fileExporter` or `NSSavePanel`) to save the `.md` file to a local directory (extremely useful for GitHub Pages, Hexo, Obsidian, etc.).

### Implementation Details
- **Selection Handling**: Enable multi-selection in `EntryListView` and pass the selected `entryId` array to the digest generator; or provider a `Select` mode to entry list (add checkboxes) to select entries for digest generation.
- **Agent Integration**: Utilize the existing `AgentRunStateMachine` and `AgentRunCoordinator` for the AI synthesis mode. Define a new `AgentDigest` task kind.
- **File System**: Implement safe file export without triggering macOS sandbox permission errors for user-selected directories.

---

## Implementation Phases

- **Phase 1**: Database schema updates and Reader UI for **Entry Notes**.
- **Phase 2**: Toolbar integration and configuration sheet for **Entry Sharing**.
- **Phase 3**: Multi-selection support, standard/AI generation modes, and Markdown export for **Reader's Digest**.