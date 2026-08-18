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
- [x] Build pure Dart local server.
- [x] Create web UI for download and file upload.
- [x] Add PIN-gated session auth (cookie-based, constant-time comparison).
- [x] Path-traversal-safe uploads/downloads (`sanitizeName` + realpath check).
- [x] Streaming I/O: uploads write chunk-by-chunk to disk; downloads pipe `file.openRead()` to response.
- [x] Configurable share root + subdirectory browsing via `?subdir=` query param.
- [x] Client IP access log + PIN rotation button in LAN screen.
- [x] Dart unit tests (22 total): sanitizeName, constantTimeCompare, extractCookie, randomHex, rotatePin.

### Phase 4: Bluetooth File Sharing
- [ ] Implement Bluetooth scanning and service advertisement (RFCOMM).
- [ ] Create simple peer-to-peer file sender and receiver protocol.
- [ ] Sync Bluetooth data transfer progress bar in UI.
      - v1 approach: rely on OS-level pairing. Implement "connect to already-paired
        device" from a simple picker (see `BluetoothScreen`). Do NOT build a "make
        Android discoverable" toggle yet — that defers BLUETOOTH_ADVERTISE edge cases.
        The RFCOMM frame format matches swordblue (see frame-format comments in
        `MainActivity.kt` and `bluetooth_share_service.dart`).

### Phase 2 (Deferred — post v1): Document Conversion & Background Search
- ~~Document conversion~~ → Deferred: PDF/DOCX/TXT/HTML exports require native helpers (pandoc/LibreOffice) or cloud API. v1 ships markdown-only preview. Revisit after Bluetooth + LAN sharing are production-stable.
- Background search via Dart isolates — deferred until Phase 5 tooling is established.

### Phase 5: Folder Graph & Tools
- [ ] Interactive folder graph visualizer built natively in Flutter.
- [x] Document conversion integration (Markdown <-> HTML <-> Text, and optional PDF/Word handlers).
      - Status: Basic Markdown → HTML/Text conversion implemented in `lib/services/doc_converter.dart`.
      - DEFERRED → **Phase 2**: native/offloaded PDF & DOCX export (`lib/services/convert_offload.dart`
        plus a receiving endpoint in swordconv/C++). Heavy native dependencies (pandoc / LibreOffice /
        cloud API) are not feasible for an on-device v1 Android build. Get Bluetooth fallback and
        QR/HTTP sharing solid first — that is the actual pain point. Revisit once those are stable.

---

## 🔗 Repository Tracking files
*   [plan.md](file:///home/sword/Documents/android/SwordFM_Android_V1/plan.md) — This document.
*   [path.md](file:///home/sword/Documents/android/SwordFM_Android_V1/path.md) — Codebase file structure map.
*   [readme.md](file:///home/sword/Documents/android/SwordFM_Android_V1/readme.md) — User documentation.
