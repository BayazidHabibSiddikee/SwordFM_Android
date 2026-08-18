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
- [x] Initialize cross-platform Flutter project targeting `android`, `windows`, and `linux`.
- [x] Implement One Dark theme color scheme.
- [x] Build responsive dual-pane layout (sidebar + main + preview panel).
- [x] Bottom nav tabs: Files | Bluetooth | LAN | Settings | Storage
- [x] Archive support: ZIP/TAR/GZIP extract + create via ArchiveService
- [x] Batch rename dialog (prefix/suffix/regex modes)
- [x] Duplicate file finder (SHA-256 based)
- [x] Storage analysis screen (folder size breakdown by depth)

### Phase 2: Network & Cloud
- [x] WebDAV client (webdav_client + dio) — list/upload/download
- [x] NetworkProfile model with JSON serialization
- [x] NetworkScreen UI — profile management + remote file browser
- [x] Connection log (ring buffer, broadcast stream)
- [ ] SFTP via dartssh2 (stubbed, not yet integrated)
- [ ] Connection profiles persistence (SharedPreferences)
- [ ] Background transfer engine (queue, chunked, pause/resume)
- [ ] Cloud SDK adapters (Drive/Dropbox/OneDrive)

### Phase 2b: Native File System Integration (renamed from original Phase 2)
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
- [x] Implement Bluetooth scanning and service advertisement (RFCOMM).
- [x] Create simple peer-to-peer file sender and receiver protocol.
- [x] Sync Bluetooth data transfer progress bar in UI.
      - v1 approach: rely on OS-level pairing. Implement "connect to already-paired
        device" from a simple picker (see `BluetoothScreen`). Do NOT build a "make
        Android discoverable" toggle yet — that defers BLUETOOTH_ADVERTISE edge cases.
        The RFCOMM frame format matches swordblue (see frame-format comments in
        `MainActivity.kt` and `bluetooth_share_service.dart`).

### Phase 2 (Deferred — post v1): Document Conversion & Background Search
- ~~Document conversion~~ → Deferred: PDF/DOCX/TXT/HTML exports require native helpers (pandoc/LibreOffice) or cloud API. v1 ships markdown-only preview. Revisit after Bluetooth + LAN sharing are production-stable.
- Background search via Dart isolates — deferred until Phase 5 tooling is established.

### Phase 5: Folder Graph & Tools
- [x] Interactive folder graph visualizer built natively in Flutter.
- [x] Document conversion integration (Markdown <-> HTML <-> Text, and optional PDF/Word handlers).
      - Status: Real PDF/DOCX conversion possible entirely in Dart, no external binaries needed.
      - DEFERRED → **Phase 2**: native/offloaded PDF & DOCX export (`lib/services/convert_offload.dart`
        plus a receiving endpoint in swordconv/C++). Heavy native dependencies (pandoc / LibreOffice /
        cloud API) are not feasible for an on-device v1 Android build. Get Bluetooth fallback and
        QR/HTTP sharing solid first — that is the actual pain point. Revisit once those are stable.

---

## 🔗 Repository Tracking files
*   [plan.md](file:///home/sword/Documents/android/SwordFM_Android_V1/plan.md) — This document.
*   [path.md](file:///home/sword/Documents/android/SwordFM_Android_V1/path.md) — Codebase file structure map.
*   [readme.md](file:///home/sword/Documents/android/SwordFM_Android_V1/readme.md) — User documentation.
