# Project Plan: SwordFM Cross-Platform Rebuild

Recreating the Linux-only C++/Qt6 file manager **SwordFM** as a modern, high-performance, cross-platform Flutter application for **Windows**, **Android**, and **Linux**.

---

## 🛠️ Technology Stack
*   **Frontend**: Flutter (Dart)
*   **UI Design**: One Dark Theme (harmonious slate/dark background, high-contrast cyan/green accents, custom animations)
*   **Local Sharing**: Pure Dart `HttpServer` (LAN web server) with QR code & pairing dialog
*   **Bluetooth Sharing**: Classic Bluetooth RFCOMM / socket connection (Android + Windows)
*   **File APIs**: `dart:io` native file APIs

---

## 📅 Roadmap & Milestones

### Phase 1: Foundation & UI Layout (Linux / Windows / Android)
- [ ] Initialize cross-platform Flutter project targeting `android`, `windows`, and `linux`.
- [ ] Implement One Dark theme color scheme.
- [ ] Build responsive dual-pane layout:
    - Sidebar (bookmarks, shortcuts, drives).
    - Main view (Grid & Details lists).
    - Status bar & Toolbar.
    - Collapsible Live Preview Panel (supports code syntax highlighting, image scaling, markdown rendering).

### Phase 2: Native File System Integration
- [ ] List directory contents, display metadata, filter by extension or date.
- [ ] Implement CRUD operations: Copy, Cut, Paste, Rename, Delete (send to trash).
- [ ] Implement background search (recursive and local) using Dart isolates.

### Phase 3: LAN Web Sharing (Re-implementing swordshare)
- [ ] Build pure Dart local server.
- [ ] Create web UI for download and file upload.
- [ ] Add PIN verification and app-side client authorization dialog ("Allow connection from IP?").

### Phase 4: Bluetooth File Sharing
- [ ] Implement Bluetooth scanning and service advertisement (RFCOMM).
- [ ] Create simple peer-to-peer file sender and receiver protocol.
- [ ] Sync Bluetooth data transfer progress bar in UI.

### Phase 5: Folder Graph & Tools
- [ ] Interactive folder graph visualizer built natively in Flutter.
- [ ] Document conversion integration (Markdown <-> HTML <-> Text, and optional PDF/Word handlers).

---

## 🔗 Repository Tracking files
*   [plan.md](file:///home/sword/Documents/android/SwordFM_Android_V1/plan.md) — This document.
*   [path.md](file:///home/sword/Documents/android/SwordFM_Android_V1/path.md) — Codebase file structure map.
*   [readme.md](file:///home/sword/Documents/android/SwordFM_Android_V1/readme.md) — User documentation.
