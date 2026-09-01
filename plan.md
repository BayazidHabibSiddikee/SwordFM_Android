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

## 🧩 Phase 10: Real Terminal + Proper File Manager (In Progress)

### Current terminal problem
The built-in terminal (`lib/screens/terminal_screen.dart`) uses `flutter_pty` to spawn
Android's **toybox shell** (`mksh`/`sh`). It's not Termux-like: no package manager
(`apt`/`pkg` are absent), the shell dies constantly, and there's no real POSIX
environment. It only "works like Termux" if Termux is separately installed and even then
it shells out funnily.

### Direction — integrate Termux instead of fighting it
Rather than reimplement a POSIX environment in pure Dart (enormous, fragile), the robust
path is:
1. **Bundle/install Termux** as the terminal backend (it ships `bash`, `coreutils`,
   `util-linux`, and the `pkg`/`apt` package manager — everything the current terminal
   lacks).
2. Drive it from SwordFM through the Termux **`RUN_COMMAND`** intent and, for an
   in-app experience, launch **Termux's own Activity** into the current directory
   (`TermuxService.openTerminalAt` + the `com.swordfm/terminal` MethodChannel + `termux://`
   URL scheme that already exist but need improvement). Optional local‑PTY fallback stays
   for non-Termux devices.

### File manager tasks (proposed)
- [ ] Upgrade `TerminalService` to robustly detect, launch, and (optionally) embed Termux.
- [ ] `Open Terminal Here` in the file browser always hands off to Termux in the current dir.
- [ ] Keep the pure-Dart `flutter_pty` shell as a graceful fallback when Termux is absent.
- [ ] Verify Termux toolchain `pkg`/`apt` inside the embedded/launched shell.

### Conversion — port `swordconv` (Python) to Termux, drop LibreOffice/pdf2docx
```diff
- OLD PLAN: use LibreOffice + pandoc in Termux (huge, rejected by original project)
+ NEW(REVISED): port the original `swordconv` Python tool (tools/swordconv) to run under
+ Termux, and drop both LibreOffice/pandoc AND pdf2docx from the Android path.
+ The original swordconv docstring explicitly rejects LibreOffice/pandoc (~500 MB).
```
The original project already ships `tools/swordconv` — a single Python script that does
all conversions with **PyMuPDF + python-docx + mammoth + bs4 + markdown** (no LibreOffice).
This is the exact engine to port onto Termux.

**Verified on host (Sep 2026):**
- ✅ `md/txt/html/docx → docx` is a **true editable re-layout** (python-docx): real
  `word/document.xml`, numbering, fonts, text runs. Light deps only.
- ✅ `text → PDF` via PyMuPDF `Story` re-lays HTML across pages.
- ✅ `pdf/docx/html → txt/md` clean text extraction.
- ⚠️ GNU **PDF→DOCX via `pdf2docx` is NOT viable on Android**: it wraps each PDF page as
  an *embedded image* (1.4 KB PDF → 122 KB "docx"), needs `opencv`+`numpy` (fragile/broken
  on Termux), and hit an import-order bug on host that wrote a `%PDF` mislabeled as DOCX.
  **Decision: do PDF→DOCX as text re-layout** via the existing `read_pdf` (PyMuPDF →
  structured HTML incl. heading-size detection) → `write_docx` (python-docx) path. Gives a
  genuinely editable DOCX with heading/paragraph structure; honest tradeoff = no embedded
  images/layout fidelity (not achievable in pure-Dart or light-Termux tools).

### Conversion tasks (proposed)
- [ ] Port `tools/swordconv`'s readers/writers into `ConversionToolService` (Dart
      Process calling `/data/data/com.termux/files/usr/bin/python` + a bundled script, or
      a trimmed Dart port of the ~390-line script).
- [ ] First-run bootstrap: `pkg install python` + `pip install pymupdf python-docx mammoth
      beautifulsoup4 markdown` (~small wheels vs LibreOffice). Show install progress.
- [ ] `ConvertDialog` calls the toolchain when present; else falls back to the existing
      pure-Dart `DocConverter` (never regresses offline / no-Termux).
- [ ] PDF→DOCX and PDF→HTML/DOCX reuse the `swordconv` PyMuPDF text+heading pipeline
      (editable re-layout, no images) instead of the current string-slicing `_extractPdfTextSync`.
- [ ] (port-only, optionally later) `markdownFileToHtml` / md→pdf keeps the existing Dart
      builder — the Python path only wins when it means less work or better output.
- [ ] `Open Terminal Here` hands off to Termux in the current dir; pure-Pty stays as fallback.

---

## 🧩 Phase 9: UX Parity Features (In Progress)

### ✅ Batch 1 — Navigation, Selection, Bookmarks, Clipboard (Complete)

- [x] Back/Forward toolbar buttons wired to navigation history (`_goBack`/`_goForward`), disabled at history boundaries; Up button corrected to `_goUp` with tooltip. Layout: [◀ Back] [▲ Up] [▶ Forward]
- [x] `SelectionInfo` + `FileBrowser.onSelectionChanged` — status bar shows "N selected (X.X MB)" for multi-select (file sizes summed, directories count 0)
- [x] `ClipboardInfo` + `FileBrowser.onClipboardChanged` — persistent status bar chip: "Copied: N" (cyan) / "Cut: N" (amber); paste button reports too; `FileUtils.clipboardOperation` getter added
- [x] `BookmarksService` — persists `{"bookmarks": [...]}` JSON to `<app-support>/bookmarks.json` (format-compatible with Linux `~/.config/swordfm/bookmarks.json`); loaded at startup, saved on add/remove; sidebar bookmark tiles with long-press-to-remove (confirmation dialog)

**Deferred / known limitations:**
- `FileUtils` clipboard still holds a single path (last-selected wins on multi-copy) — multi-path clipboard is a post-v1 item
- FileBrowser history resets when the parent swaps the `ValueKey(_currentPath)` (sidebar/breadcrumb navigation) — in-browser Back/Forward history only accumulates for in-browser navigation

**Verification:** `flutter analyze` — 0 errors / 0 warnings; `flutter test` — 123 passing.

---

## ✅ Phase 3 — Archive Compression UI + Open With submenu (Complete)

- [x] Multi-format **Compress…** dialog (`_compressSelection`): name field + format picker (ZIP / TAR / TAR.GZ), auto-appends the matching extension when the user didn't type one; wired into both the context menu and the multi-select toolbar button
- [x] `ArchiveService.createTar()` and `createTarGz()` (GZip-wrapped TAR) — roundtrip-verified by extraction; added 3 unit tests (tar + tar.gz single/multi)
- [x] **Extract Here** now uses correct Linux semantics (extracts into the current directory) and a new **Extract to Subfolder…** option (into `<archive-name>/`)
- [x] **Open With submenu** enriched and context-aware — `Open With default app` (new `OpenWithService.openDefault`), `Choose another app…` (system chooser), `Open in Termux` (text/code files only), and `Copy file path`

### Regression fixes (from uncommitted Phase 2 work, tests caught them)
- **Toolbar overflow**: the file-browser toolbar overflowed by 36px on narrow surfaces (added type/date/junk buttons). Wrapped the toolbar in a horizontal `SingleChildScrollView`; path label is now a bounded `ConstrainedBox` (160–320px) instead of `Expanded`, so all buttons stay reachable on small screens.
- **Search blocked under `/tmp`**: the search isolate skipped the explicit root and any subtree whenever it fell under a blocked dir, breaking searches into temp folders (and the app's own temp usage). Moved the boundary check to recursion only — the explicit search root is always honored, but blocked *subdirectories* are still skipped while descending.
- **`/tmp` removed from `kBlockedDirectories`**: `/tmp` is a legitimate user directory and the OS temp location (where `Directory.systemTemp` and tests live); blocking it was overly aggressive. Only virtual/system dirs (`/proc`, `/sys`, `/dev`, `/run`, `/snap`, `/boot`, `/lost+found`, `/opt`, `/usr`, `/var`) remain protected.

**Verification:** `flutter analyze` — 0 errors / 0 warnings; `flutter test` — 126 passing.

---

## ✅ Phase 6 — High-Impact Linux Parity Features

Implemented the last 4 of 8 high-impact missing features from the Linux SwordFM gap analysis (#5, #6, #7, #8). Features #1–#4 (recursive filter, cross-device move, unique dest path, Properties MIME/permissions) were already implemented in the uncommitted working tree when this session started — the external code-review commit `5900ce2` and Phase 5 commit `81d1ff2` already covered them.

### #5 — Share from context menu
- New `lib/services/share_service.dart` (MethodChannel `com.swordfm/share`)
- New `MainActivity.shareFiles()` method using `Intent.ACTION_SEND` / `ACTION_SEND_MULTIPLE` with `FileProvider`-backed URIs and a chooser
- New `Share…` context-menu item (files only) and select-mode toolbar button (`Icons.share`)
- SnackBar feedback ("Sharing N items…" or "Share not available here")

### #6 — Selection size for directories (recursive sum)
- `FileBrowser._computeSelectionInfo` is now `async` and sums directory sizes via `FileItem.getTotalSize` (which was already recursive), so multi-select now reports the true aggregate size when folders are included
- Cached via the existing `_folderSizes` map to avoid repeated full-tree walks

### #7 — Multi-item clipboard
- `FileUtils`: `_clipboardPaths` is now a `List<String>`; new `setClipboardMultiple(paths, op)`, `clipboardCount`, `clipboardPaths` accessors
- `FileUtils.paste(destDir)` iterates all paths in copy/cut mode; cut-mode still consumes the entire clipboard on successful paste
- `FileBrowser` reports the truthful `count` to the status bar via `ClipboardInfo`; copy/cut/paste UI and snackbar messages all use the actual list size
- Existing tests in `test/file_utils_test.dart` continue to pass

### #8 — Additional archive formats (tar.xz, tar.bz2)
- The bundled `archive: 3.6.1` package provides `XZDecoder/Encoder` and `BZip2Decoder/Encoder` natively — no new dependencies
- `ArchiveService` extracts `.tar.xz`, `.txz`, `.tar.bz2`, `.tbz2` and creates them with new `createTarXz()` / `createTarBz2()` methods
- Compress dialog now offers **5 formats** (ZIP, TAR, TAR.GZ, TAR.XZ, TAR.BZ2) in a 5-segment `SegmentedButton` (auto-strip + auto-append the matching extension when the user switches format)
- `isArchive()` recognition extended to the new extensions
- Formats still not supported (genuinely not in the Dart `archive` package): **7z, RAR, tar.zst** — these require FFI / native bindings and are noted in the service doc-comment as an honest limitation

**Verification:**
- `flutter analyze` — 0 errors, 0 warnings (40 pre-existing info-level style lints)
- `flutter test` — **130 passing** (was 126; +4 new: 2 roundtrips for tar.xz/tar.bz2, 2 recognition tests for `.tar.xz`/`.tar.bz2`)
- Regression: the existing "rejects unsupported format" test was using `.bz2` as the "unsupported" example; switched it to `.rar` (the only remaining genuinely-unsupported extension)

**Honest limitations** (documented in code):
- Share only works for files (Android share sheet cannot share a folder); Share menu/button is hidden for directories
- The `com.swordfm/share` channel has no Dart-side automated test (it's a thin platform-channel wrapper over the Android share intent — testing would require a Flutter integration test on a device/emulator, which isn't in this repo's `flutter test` suite)
- 7z, RAR, tar.zst require FFI and remain unsupported

---

## 🔗 Repository Tracking files
*   [plan.md](file:///home/sword/Documents/android/SwordFM_Android_V1/plan.md) — This document.
*   [path.md](file:///home/sword/Documents/android/SwordFM_Android_V1/path.md) — Codebase file structure map.
*   [readme.md](file:///home/sword/Documents/android/SwordFM_Android_V1/readme.md) — User documentation.
