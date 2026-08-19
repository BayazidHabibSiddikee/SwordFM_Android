# Project Plan: SwordFM Cross-Platform Rebuild

Recreating the Linux-only C++/Qt6 file manager **SwordFM** as a modern, high-performance, cross-platform Flutter application for **Windows**, **Android**, and **Linux**.

---

## 🛠️ Technology Stack
*   **Frontend**: Flutter (Dart)
*   **UI Design**: One Dark Theme (harmonious slate/dark background, high-contrast cyan/green accents)
*   **Local Sharing**: Pure Dart `HttpServer` (LAN web server) with QR code & PIN auth
*   **Bluetooth Sharing**: Classic Bluetooth RFCOMM / socket connection (Android + Windows)
*   **Network Sharing**: WebDAV (webdav_client) + SFTP (dartssh2)
*   **File APIs**: `dart:io` native file APIs

---

## 📅 Roadmap & Milestones

### Phase 1: Foundation & UI Layout
- [x] Initialize cross-platform Flutter project targeting `android`, `windows`, and `linux`.
- [x] Implement One Dark theme color scheme.
- [x] Build responsive dual-pane layout (sidebar + main + preview panel).
- [x] Bottom nav tabs: Files | Bluetooth | LAN | Settings | Storage | Network.
- [x] Archive support: ZIP/TAR/GZIP extract + create via ArchiveService.
- [x] Batch rename dialog (prefix/suffix/regex modes).
- [x] Duplicate file finder (SHA-256 based).
- [x] Storage analysis screen (folder size breakdown by depth).

### Phase 2: Native File System Integration
- [x] List directory contents, display metadata, filter by extension or date.
- [x] CRUD operations: Copy, Cut, Paste, Rename, Delete (send to trash).
- [x] Background search via Dart Isolate (non-blocking).

### Phase 3: LAN Web Sharing
- [x] Build pure Dart local HTTP server.
- [x] Create web UI for download and file upload.
- [x] PIN-gated session auth (cookie-based, constant-time comparison).
- [x] Path-traversal-safe uploads/downloads (`sanitizeName` + realpath check).
- [x] Streaming I/O: uploads write chunk-by-chunk; downloads pipe `file.openRead()`.
- [x] Configurable share root + subdirectory browsing via `?subdir=`.
- [x] Client IP access log + PIN rotation button in LAN screen.
- [x] Unit tests (22 total).

### Phase 4: Bluetooth File Sharing
- [x] RFCOMM scanning and service advertisement.
- [x] Peer-to-peer file sender/receiver protocol.
- [x] Sync progress bar in UI.
- [x] Send UI: native file picker, multi-file queue, progress bar + cancel.
- [x] SerialPort UUID interop with swordblue Linux side.
- [x] Connect timeout (30s) with auto-retry; collision suffix on receive.
- - [x] Foreground service for background BT transfers (BluetoothShareService.kt + manifest registration)
- [ ] Discoverability toggle (deferred — relies on OS pairing for v1).

### Phase 5: Network & Cloud
- [x] WebDAV client (webdav_client + dio) — list/upload/download.
- [x] SFTP client (dartssh2) — SSHClient + SFTP list/upload/download.
- [x] NetworkProfile model with JSON serialization.
- [x] NetworkScreen UI — profile management + remote file browser.
- [x] Connection log (ring buffer, broadcast stream).
- [x] Transfer queue (enqueue/cancel/processNext).
- [x] Connection profiles persistence (SharedPreferences + encrypted storage via flutter_secure_storage).
- [ ] Chunked/pause/resume transfers (deferred).
- [ ] Cloud SDK adapters (Drive/Dropbox/OneDrive) — deferred; WebDAV covers Nextcloud/Synology.

### Phase 6: Folder Graph & Tools
- [x] Interactive folder graph visualizer built natively in Flutter.
- [x] Document conversion integration (Markdown <-> HTML <-> Text + PDF/DOCX export via pure-Dart).

### Phase 7: Polish & Distribution
- [x] GitHub Actions CI (analyze + test on push/PR).
- [x] i18n scaffolding (easy_localization with en.arb base).
- [x] Material You dynamic color support (dynamic_color package with fallback to One Dark)

- [x] Play Store readiness: SAF dual-mode (saf package), release signing config template (key.properties + build.gradle), privacy policy screen, .gitignore keystore exclusion

---

## 📊 Current Status

| Metric | Value |
|--------|-------|
| Tests passing | 123 |
| Analysis errors | 0 |
| Last push | master |

---

### ✅ Phase 7 Complete — v1 Ready

All 7 phases are now complete. The remaining items are intentionally deferred to post-v1.

---

### ✅ Phase 8: Monetization & Premium (Complete)

- [x] bKash donation channel (+8801723977791) with deep-link open
- [x] BNB (BEP-20) crypto donation address copy
- [x] Manual premium activation flow (donor emails UID → admin flips Firestore)
- [x] EntitlementService — free/premium state via Firestore `users/{uid}` documents
- [x] SettingsScreen — account card (email, verified badge, sign out, resend verification), premium toggle linking to donation dialog
- [x] ConvertDialog — PDF & DOCX export from context menu on markdown files, Open result button
- [x] PremiumGate skeleton wired into architecture (entitlement-aware on next auth cycle)
- [ ] PremiumGate full enforcement — gated behind entitlement service (deferred to post-launch; conversion is currently available to all users)
- [ ] AdMob banner ads — test IDs in place, live IDs pending AdMob account + Real Config setup

---

## 🔗 Repository Tracking files
*   [plan.md](file:///home/sword/Documents/android/SwordFM_Android_V1/plan.md) — This document.
*   [path.md](file:///home/sword/Documents/android/SwordFM_Android_V1/path.md) — Codebase file structure map.
*   [readme.md](file:///home/sword/Documents/android/SwordFM_Android_V1/readme.md) — User documentation.
