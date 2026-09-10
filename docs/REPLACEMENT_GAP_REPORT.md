# SwordFM Android — Replacement-Readiness Gap Report

**Date:** 2026-09-09
**Scope:** Can SwordFM Android actually *replace* dedicated apps for file management, document viewing, audio/video playback, document conversion, archiving, and file sharing?
**Benchmarks used:** Solid Explorer / MiXplorer / X-plore · VLC / MX Player / Poweramp / Musicolet · WPS Office / Adobe / LibreOffice · ZArchiver / 7-Zip / RAR · LocalSend / SHAREit / Nearby Share.
**Method:** Read-only domain analysis by five specialist agents, every finding anchored to `file:line` in the actual source. No files were modified.

---

## 0. Revision Log

| Rev | Date | Change |
|-----|------|--------|
| 1.0 | 2026-09-09 | Initial gap analysis (five-domain). |
| 1.2 | 2026-09-09 | **Team re-audit of uncommitted working tree (5 agents). `flutter analyze`: 116 issues (0 errors, 2 warnings); `flutter test`: 182 pass / 8 fail.** Verdicts: FM 🟡 partial-near (all-files only); video/audio ❌ no (engine real, chrome missing); docs ❌ no (EPUB/CBZ/CSV/OCR real, XLSX-offline/PPTX/CBR fail); archive/share ❌ no (ZIP/TAR+PIN real, 7z/RAR/resume/SMB fail); merge ❌ DO NOT MERGE (1 build error + P0s below). |

> **Rev 1.2 corrections to Rev 1.1 claims:** Q2 FTP auth is **NOT enforced** — `ftp_server_service.dart:125-131` parses `PASS` but no gate before LIST/RETR/STOR (`:169-220,235-354`); default `sharePin=''` (`:21`). Q1 PIN leak fix is real (no `/api/pin`, constant-time compare `:410-417`, sanitized 500s) but PIN/session RNG is `Random()` not `Random.secure()` (`web_share_server.dart:298,404`); no auth rate-limit (`:447-463`); upload-500 leaks raw `$e` (`:844-846`). |

## 0A. Is it fine? — NO, do not merge (team consensus + local verification)

**Local verification 2026-09-09:** `flutter analyze` → **116 issues (0 errors, 2 warnings)** — warnings: unused `dart:io` import `video_player_screen.dart:2`, dead `_readHead` `archive_service.dart:90`. `flutter test` → **182 pass / 8 fail**, failing: 3× `doc_converter_test.dart` (stray inline markers, unclosed trailing fence, fenced-code content kept), `network_screen_test.dart` (Interface Health panel — deleted feature), +4 more. `flutter` was missing from default `PATH` (found at `~/flutter/bin`).

**Resolved since Rev 1.0** (verified in current source):
- **Q1 — LAN PIN leak:** `/api/pin` endpoint removed; the server no longer echoes the PIN in responses (only the client's legitimate submit body remains). `git a82df15`.
- **Q2 — FTP no-auth:** FTP `PASS` is now validated against the share PIN, returning `530 Login incorrect.` on mismatch and `230` only on match (`ftp_server_service.dart:127-131`). FTP screen gained a PIN/password field. `git a82df15`.
- **Q9 (partial) — raw exception leak in HTTP 500s:** sanitized. `git a82df15`.
- **DOCX opens in-app from Search and Recent** (`search_screen.dart:170-179`, `recent_files_screen.dart:295-301`); **PDF and images open in built-in fullscreen readers from Recent** — closes the "falls through to external app" gap for those paths.
- **PDF text fallback & conversion groundwork:** `DocConverter.extractPdfText` is now a public API wired into the PDF reader text fallback (`pdf_reader_screen.dart:308`) and preview panel — the foundation for in-document search/selection (D3).
- **Notification runtime permission on API 33+** requested up front (`app_paths.dart:20-29`) so the media/foreground-service notification isn't silently dropped.
- **Player reopen fix:** reopening `MusicPlayerScreen` from the mini "now-playing" bar no longer restarts/duplicates playback or auto-resumes.

---

## 1. Executive Summary

SwordFM is a **broad but shallow** file manager: it already has an unusually wide feature surface for a single app (~29K LOC, 26+ feature screens, 46 packages), including LAN/Bluetooth sharing, WebDAV/SFTP, PDF/DOCX rendering, ZIP/TAR/GZ archives, terminal, and media players. However, in **every single target category it is a "partial" replacement today** — each domain has decisive gaps that would drive a user back to the dedicated app.

The two categories **closest** to replacement parity are **file management core** and **LAN file sharing** (both are genuinely functional daily drivers *given the all-files permission*). The **farthest** from parity are **document viewing/conversion** (no XLSX, no full PPTX render) and **proximity file sharing** (no Wi-Fi Direct / local discovery).

The most important finding is a **single strategic fork**: the app currently leans fully on `MANAGE_EXTERNAL_STORAGE` ("All files access"), yet the `saf` package is **declared but completely unused**. This is both the biggest Play-Store policy risk and the clearing path to a compliant, scoped-storage file manager.

---

## 2. Capability Matrix — "Can it replace the dedicated app today?"

| Domain | Dedicated app it displaces | Verdict | Key blockers |
|--------|---------------------------|---------|--------------|
| **File management** | Solid Explorer / MiXplorer | 🟡 **Partial (near)** | No SAF/scoped-storage tree access; no SMB; no recycle bin; no dual-pane/tabs; no real root; no unified cloud/network roots |
| **Document viewing** | WPS / Adobe / LibreOffice | 🔴 **Partial (far)** | No XLSX, full PPTX falls through to external app, no EPUB/DJVU, no forms/text-select/search-in-PDF, flat DOCX rendering |
| **Document conversion** | WPS / online converters | 🔴 **Partial** | Only md→PDF/DOCX/HTML/TXT; no DOCX→PDF, XLSX→PDF, image→PDF, batch, or OCR |
| **Audio player** | Poweramp / Musicolet | 🟡 **Partial** | No equalizer, gapless, library/album scan, sleep timer, speed; codec gates advertise WMA/APE/ALAC that ExoPlayer can't decode |
| **Video player** | VLC / MX Player | 🔴 **Partial (far)** | ExoPlayer codec ceiling (no DTS/AC3, MKV issues), no subtitles, no speed/aspect/PiP/hw-sw toggle, single-file no resume |
| **Archives** | ZArchiver / 7-Zip | 🟡 **Partial** | Pure-Dart ZIP/TAR/GZ/XZ/BZ2 solid; 7z/RAR/zst only via Termux shell-out (non-functional on stock phone); no encryption/split/browse-in-place for those formats |
| **File sharing** | LocalSend / SHAREit | 🟡 **Partial (near)** | LAN+BT work; no mDNS/UDP discovery, no Wi-Fi Direct, no transfer resume; no SMB/NAS (FTP auth **now fixed** — Rev 1.1) |

**Legend:** 🟢 can replace today · 🟡 partial — usable but drives users back for common cases · 🔴 far from replacement.
---

## 3. File-Manager Core (`fs-analyst`)

### Current state (solid foundation)
- Full CRUD with secure 3-pass delete, unique-destination resolution, batch rename, multi-select, persistent clipboard (`file_utils.dart:701,717-794,1080`).
- Details + grid views with real image/video thumbnails (`file_browser.dart:2974-2989`), sort/filter/junk-name filters, recursive filtered scan (`file_utils.dart:633`).
- Isolate-based search with content snippet (`search_service.dart`), bookmarks JSON store (`bookmarks_service.dart:23`), depth-capped storage analysis, 3-pass SHA-256 duplicate finder (`archive_service.dart:36-80`), ZIP/TAR/GZ/XZ/BZ2 archives.
- All-files access model via `Permission.manageExternalStorage` (`app_paths.dart:34-44`) + `MANAGE_EXTERNAL_STORAGE` in the manifest; volumes enumerated natively (`MainActivity.kt:391-410`) and surfaced in the sidebar.

### Prioritized gaps

| # | Gap | Sev | Why it matters | Recommendation | Effort |
|---|-----|-----|----------------|----------------|--------|
| G1 | **`saf ^2.1.0` dependency is dead — zero usage; no SAF/Storage Access Framework browsing** | **P0** | App depends entirely on all-files permission. Where that's denied or for policy compliance, Downloads/DCIM/external-SD become unusable. | Wire the already-declared `saf` package into a directory-tree picker with persisted grant → compliant fallback path. | **M** |
| G2 | **No persistent SAF tree URIs across reboots** | **P1** | SAF `content://` grants are process-lifetime only unless `takePersistableUriPermission` is used; external SD/Downloads break after reboot. | Persist tree URIs via `obtainPermissionForDirectory` + persisted URI store. | M |
| G3 | **SMB/CIFS client absent** | **P0** | Windows/Synology/QNAP NAS shares unreachable — a core expectation of any file manager; app only does WebDAV+SFTP (`network_service.dart:18`). | Add `smb_client` (pure-Dart SMB2) list/upload/download into the existing network-screen/queue pattern. | L |
| G4 | **No dual-pane / tabbed browsing, no archive-in-place** | **P1** | Power-user FM workflows (side-by-side copy, multi-folder). | Dual-pane toggle + tab bar in browser; archive-in-place comes with the FFI archive work (§6 A6). | M |
| G5 | **No recycle bin / recovery** | **P1** | Permanent delete without undo is a top data-loss fear; rivals ship trash. | Intercept delete → move to app trash dir with restore + TTL. | M |
| G6 | **USB OTG hot-plug / removable volume handling** | **P1** | Volumes appear by raw path only when all-files granted; read/write to OTG fails without SAF tree. | Persist removable-volume SAF tree grants + storage-event broadcast receiver. | M |
| G7 | **No real root access** | **P2** | "Root Mode" only lifts `/proc,/sys,…` guards (`file_browser.dart:522`); no actual `su` exec / privileged FS ops. | `su -c` bridge via existing `flutter_pty`, gated by `FileUtils.isRooted` (`file_utils.dart:824`). | M |
| G8 | **Share/open-with limited to FileProvider file URIs** | **P2** | External apps get `file:` URIs requiring all-files; no grantable `content://` SAF URIs. | Emit SAF document URIs for share/open intents. | M |
| G9 | **No tags/colors; Properties lack checksums** | **P2** | Rivals (X-plore) raise metadata density; app hides a ready `sha256OfFile`. | Persistent tag store (reuse bookmarks JSON) + Checksum row in Properties. | S |
| G10 | **Performance: thousands of files, per-tile folder size, full-image decode** | **P1** | Grid `Image.file` + per-entry `stat` + per-tile folder-size on UI isolate freeze large dirs. | Lazy Builder tiles, in-isolate thumbnails with LRU cache, lazy folder sizes, paginated loading. | M |

### Top-3 quick wins (file manager)
1. **Wire the dead `saf` dependency** into a Downloads/DCIM/external-SD tree-grant fallback (G1/G2) — biggest user-visible + policy win, package already present.
2. **Add tags/colors + on-demand checksums** (G9) — small, self-contained, differentiating.
3. **Persist removable-volume tree grants + storage hot-plug refresh** (G6) — fixes the reboot/unmount failure class for SD/OTG.

---

## 4. Audio & Video Player (`media-analyst`)

### Current state
- **Audio:** `audio_service` + `just_audio` with a real Android **foreground service** (`foregroundServiceType="mediaPlayback"`, `AndroidManifest.xml:157-164`) and lock-screen media notification (`audio_handler.dart:34-74`); mini-bar (`now_playing_mini_bar.dart`); in-memory sibling playlist per directory (`file_browser.dart:804-824`).
- **Video:** `video_player ^2.9.3` (ExoPlayer/Media3); single-file, gestures only slider/±10s/mute; registers with the audio service for lock-screen controls.
- **Codec reality (the keep-or-switch crux):** Both engines are ExoPlayer/Media3. Video covers H.264/AAC/MP3/FLAC/OPUS/VP8/VP9/AV1 (when device-decoder exists) in MP4/WebM/TS; **no DTS/AC3/EAC3/TrueHD, MKV content is hit-or-miss, no subtitle API.** The app's own extension allow-lists advertise formats the engine *cannot decode* — `.wmv .rmvb .vob .divx .mts .m2ts` gate → open → then fail at `initialize()` with a bare error screen (`video_player_screen.dart:53-54`). Audio advertises `.wma .ape .alac .mid .aiff .amr` that just_audio cannot decode → silent failure.

### Prioritized gaps

| # | Gap | Sev | Why it matters | Recommendation | Effort |
|---|-----|-----|----------------|----------------|--------|
| V1 | **No codec/container coverage for DTS/AC3/EAC3/MKV-softsubs/TrueHD** | **P0** | The single make-or-break gap vs VLC/MX; most downloaded movies are MKV with DTS/AC3 audio. ExoPlayer won't ship patent-encumbered codecs. | **Switch video engine to `media_kit` (libmpv)** — collapses V1/V2/V5/V8 into one migration and adds local subtitle rendering. | **L** |
| V2 | **No subtitle support at all** (.srt/.ass/embedded) | **P0** | Foreign-language content is unreadable; MX/VLC handle all of this. | Ships with `media_kit`; otherwise add a subtitle-overlay + sync package. | L (media_kit carries it) |
| V3 | **No equalizer/audio effects** | **P0** | Music-O hardware EQ absent; `audio_service` handles background only. | Native Android equalizer (SystemEqualizer) or `flutter_audio_capture`-style DSP. | M-L |
| V4 | **No gapless playback / crossfade** | **P1** | Concert/live/full-album listening (gapless is a Poweramp fundamental). | just_audio gapless via tag reading; crossfade via dual-player; gapless-only cheapest. | L (gapless subset S/M) |
| V5 | **Video: no speed / rotation-lock / aspect / PiP / hw-sw decode toggle / multi-audio track** | **P1** | All MX/VLC defaults absent (`video_player_screen.dart` has slider/±10s/mute only). | Lands via `media_kit` (`setRate`, `setAudioTrack`, aspect, PiP, `hwdec`). | M-L (media_kit) |
| V6 | **No playlist persistence/queue mgmt (reorder/remove)** | **P1** | Sibling playlist is non-recursive, in-memory only (`file_browser.dart:807-813`); no save as m3u. | Recursive option + persistent queue + save/load playlists. | M |
| V7 | **No library scan: Genre/Album/Artist, cover art** | **P1** | Pure folder browser; placeholder `music_note` cover (`music_player_screen.dart:140-153`); Musicolet/Poweramp library experience missing. | Tag/metadata scan service + cover extraction (`audio_metadata_reader`). | L |
| V8 | **Video resume + auto-continue next file (binge mode)** | **P1** | Single-file open, no next/prev, no resume; can't binge a season folder. | Reuse media_kit playlist + per-file resume. | M |
| V9 | **No sleep timer / playback-speed UI** | **P2/P1** | Lecture/podcast & night-listening use-cases; `speed` field is broadcast but not user-settable (`audio_handler.dart:58`), no UI. | Speed menu (`setSpeed`) + foreground-safe Timer. | S |
| V10 | **Video hijacks shared audio service state** | **P2** | Video forces its MediaItem over the shared handler (`video_player_screen.dart:63-87`), clashing with active music. | Separate media session / state coordinator. | M |
| V11 | **`video_thumbnail` declared, never used** | **P2** | No video grid thumbnails despite dependency (`pubspec.yaml:66`). | Wire `video_thumbnail` into the grid or drop it. | S |

### Top-3 quick wins (media)
1. **Repeat/shuffle toggle** (just_audio `LoopMode` + concat shuffle already present; `audio_handler.dart:105-110`) — pure Dart, ~half day.
2. **Sleep timer + resume position** (SharedPreferences map + `stop()`) — no engine change, S.
3. **Audio playback-speed menu** (`setSpeed()` one call driving the existing `speed` broadcast) — S.

**Strategic note:** Switching video to `media_kit`/libmpv is the highest-leverage single decision in the whole report — it closes V1/V2/V5/V8 (codec breadth, subtitles, hw-decode, speed/aspect/PiP, auto-next) in one migration. Audio gaps (EQ, gapless, library) then layer onto just_audio.
---

## 5. Document Viewing & Conversion (`docs-analyst`)

### Current state — rendering matrix

| Format | In-app? | Fidelity | Evidence |
|--------|---------|----------|----------|
| PDF | ✅ pdfium (`pdfx`) on Android | Full pages, pinch/zoom; overlay marks only (persisted to prefs, not into file); **no forms, text-select, search, password prompt** | `pdf_reader_screen.dart`, `pdf_engine.dart` |
| DOCX | ✅ custom XML parser | Flat block tree — columns/text-boxes/sections dropped | `docx_reader.dart:12-13` |
| PPTX | ⚠️ outline only | Full-screen falls **through to external app** (no branch in `_openFullScreen`) | `file_utils.dart:502,521` |
| Spreadsheets | ❌ | `isSpreadsheet` but not in `hasNativeViewer` → external | `file_utils.dart:505-507,519-521` |
| ePub/MOBI/DJVU/CBZ | ❌ | None handled | — |
| md/text/image | ✅ | Formatted md / mono / native decode | `preview_panel.dart` |

**Conversion current state (all pure-Dart):** md/text → PDF/DOCX/HTML/TXT (`doc_converter.dart`); PDF→text crude regex; DOCX output text-only (`convert_dialog.dart:7-8`). No DOCX→PDF, XLSX→PDF, image→PDF, batch, OCR.

### Prioritized gaps

| # | Gap | Sev | Why it matters | Recommendation | Effort |
|---|-----|-----|----------------|----------------|--------|
| D1 | **XLSX/XLS/CSV spreadsheet viewing absent** | **P0** | The single most common office file is spreadsheet; currently external-only. | `syncfusion_flutter_xlsio` parse→grid, or webview + SheetJS. | M |
| D2 | **Full PPTX slide rendering absent (outline only)** | **P0** | Presentations are rendered as bullet outlines then dumped to an external app. | Parse PPTX (OOXML via `xml`) into slide/image pager, or webview renderer. | M-L |
| D3 | **PDF: no in-document search / text selection** | **P0** | Core PDF habit; app already extracts text (`DocConverter.extractPdfText`, `doc_converter.dart:70`) but doesn't surface it. | Align extracted text to pages as `SelectableText` overlays + find-bar (reuse existing `PdfMark` overlay). High UX lift, no new native deps. | M |
| D4 | **PDF: no annotations persisted to file / forms / password PDFs** | **P1** | Marks are overlay-only + prefs (`pdf_reader_screen.dart:18-45,483-500`); forms & password-supported PDFs unhandled. | pdfium full API (forms, save marks), `SdPdf`/poppler for password. | L |
| D5 | **DOCX complex layout fidelity (columns/text-boxes/sections)** | **P1** | Flat renderer loses layout → docs look broken vs Word. | Full OOXML block coverage or delegate complex docs to webview + Word Online renderer. | L |
| D6 | **No EPUB/MOBI/DJVU/CBZ-CBR reading** | **P1** | Whole indie/e-book/magazine category missing. | EPUB: OPF+spine via `xml`+`archive`→pager; CBZ/CBR reuse `ArchiveService` + image pager (fast win); DJVU delegate. | M (EPUB/CBZ), L (DJVU) |
| D7 | **Conversion: no DOCX→PDF / XLSX→PDF** | **P1** | Users want to ship PDFs from any office format; only md converts. | DOCX→PDF reuses the existing `pw.Document` writer (`doc_converter.dart:946`) by walking the block tree; XLSX via `xlsio.exportToPdf()`. | M |
| D8 | **No image→PDF / no batch conversion / no OCR** | **P2** | Scanning/photo→PDF, folder converts, and scanned-PDF→text are expected; OCR gap even blocks image-only docs (returns "encrypted", `convert_dialog.dart:61-63`). | `pdf` `pw.MultiImage` wrap; batch loop; `google_mlkit_text_recognition` (on-device). | S-M / M / L |
| D9 | **High-fidelity md→PDF (images, CJK, page breaks, TOC)** | **P2** | Export fidelity is flat Helvetica; code/README→PDF looks amateur. | `PdfGoogleFonts`/embedded fonts + image resolution (`_preprocessForMarkdown` exists). | M |

### Top-3 quick wins (documents)
1. **PDF in-document search + selectable text** (D3) — highest UX lift, reuses existing extraction + `PdfMark` overlay. M.
2. **CBZ/CBR + EPUB reader** (D6 subset) — `archive` and `xml` already in `pubspec.yaml:25,27`; zero new deps. M.
3. **DOCX→PDF via the existing writer** (D7) — the node→`pw.Widget` mapping into `_buildPdfBytes` (`doc_converter.dart:946`) is mechanical. M.

*Optional P0 pivot:* a `webview_flutter` + self-hosted **pdf.js / Office Online** viewer (webview already ships, `pubspec.yaml:65`) collapses D1/D2/D3/D5/D6 into one L-effort path — but trades offline purity for coverage.
---

## 6. Archives & File Sharing (`archive-share-analyst`)

### Current state
**Archives (create):** ZIP/TAR/TAR.GZ/TAR.XZ/TAR.BZ2 (`archive_service.dart:457-538`). No compression level, password, add-to-archive, or split.
**Archives (extract):** same five pure-Dart (`archive_service.dart:166-208`); **7z/RAR/zst only via Termux shell-out** to hardcoded `/data/data/com.termux/files/usr/bin` (`archive_service.dart:331-379,338`) — **effectively non-functional on a stock phone**; browse-in-place (`archive_browser`) throws for those three (`_decodeArchive`, `:445`).
**Sharing:** LAN HTTP :8080 + QR + PIN cookie (constant-time compare, `web_share_server.dart:153-188`); FTP :2121 (**now PIN-authenticated** — `PASS` validated against the share PIN, `530` on mismatch; `ftp_server_service.dart:127-131`, fixed in Rev 1.1); Bluetooth RFCOMM foreground service (`BluetoothShareService.kt:103`) with SHA-256 integrity. WebDAV + SFTP clients only; **no SMB**.

### Prioritized gaps

| # | Gap | Sev | Why it matters | Recommendation | Effort |
|---|-----|-----|----------------|----------------|--------|
| A1 | **7z create/extract absent (Termux-only)** | **P0** | 7z is the de-facto archive standard; current path is non-functional on stock devices. | Bundle libarchive via FFI (`libarchive_ffi`) or a statically-linked 7z binary. | L |
| A2 | **RAR extract absent (Termux-only)** | **P0** | RAR is the most common download format for movies; can't extract on stock devices. | libarchive/UnRAR via FFI (licensing: one boolean prompt for UnRAR). | L |
| A3 | **Broken capability signalling for 7z/rar/zst** | **P1** | UI lists them as extractable/compressible but they throw at runtime without Termux. | Gate formats behind a real capability probe; show clear install guidance only where functional. | S |
| A4 | **No encrypted/password archives (create or extract)** | **P1** | Storing/extracting protected archives fails today. | libarchive FFI (v7 encryption) + `archive` pkg AES. | M |
| A5 | **No split/multi-volume archives; no add-to-archive; no compression level** | **P1** | 7-Zip/ZArchiver staples; users distributing large zips need volumes. | Thread through ZipEncoder level (`archive_service.dart:466`) + volume chunking. | M |
| A6 | **No archive browse-in-place for 7z/rar/zst; no per-file progress / test** | **P1** | Browsing/viewing single files inside rar/7z without extracting is expected. | libarchive streaming list / extract-entry API. | M |
| S1 | **No proximity auto-discovery (mDNS/UDP)** | **P0** | LAN share requires manual IP + QR; LocalSend/Nearby auto-discover nearby devices. | Add mDNS/udp broadcast beacon (LocalSend protocol reuse) to the existing HTTP server. | M |
| S2 | **No Wi-Fi Direct / P2P transport** | **P1** | RFCOMM BT is ~200 KB/s — unusable for GB files; LocalSend/Nearby use Wi-Fi P2P. | `wifi_direct` / `flutter_p2p_connection` near-gigabit links with LAN fallback. | L |
| S3 | **No transfer resumption (Content-Range)** | **P1** | `_serveDownload` sends from 0 only; partial uploads are deleted on failure (`web_share_server.dart:546-548,615`) → full restarts on drop. | HTTP Range download + append-mode/Content-Range upload with `.part` offset files. | M |
| S4 | **No folder/multi-file whole-directory transfer** | **P1** | LAN/FTP/BT are per-file; no zip-and-send folder flow. | Server-side tar/zip of a directory or recursive `/api/list` walk; multi-entry BT frames. | M |
| S5 | **No channel encryption (LAN plaintext, FTP cleartext)** | **P1** | Sniffable on shared AP (BT has SHA-256 integrity only). | Self-signed TLS or app-layer AES-GCM over the LAN link; keep PIN for auth. | M |
| S6 | ~~FTP server has no authentication (any `PASS` → `230`)~~ **RESOLVED — Rev 1.1** | ~~P0~~ | FTP `PASS` is now validated against the share PIN; `530` on mismatch (`ftp_server_service.dart:127-131`). | N/A — fixed. No action needed. | — |
| N1 | **SMB/CIFS absent (NAS access)** | **P0** | Windows/Synology/QNAP NAS unreachable — a core FM expectation vs Solid/ZArchiver. | `smb_client` (SMB2) into existing queue pattern. | L |

### Top-3 quick wins (archives/sharing)
1. **LAN download/upload resume** (S3) — Content-Range + `.part` files; big drop-of-Wi-Fi win, pure Dart. *(The previous #1 quick win, "Real FTP auth", is done — see S6.)*
2. **Bundle libarchive (7z/RAR + encryption/split)** (A1/A2/A4/A5) — biggest feature gap vs ZArchiver; additive FFI work.
3. **Archive progress + compression level** (A5 subset) — streamed decode progress + pass level through `ZipEncoder`; turns indeterminate spinner into feedback.
---

## 7. Production Readiness (`quality-analyst`)

### Top issues

| # | Issue | Sev | Why it matters | Mitigation | Effort |
|---|-------|-----|----------------|------------|--------|
| Q1 | ~~LAN PIN leaked without auth~~ **RESOLVED — Rev 1.1** — `/api/pin` removed; server no longer echoes the PIN (`git a82df15`). | ~~P0~~ | ~~The PIN is the auth gate; any on-Wi-Fi device could fetch it anonymously~~ | N/A — fixed. No action needed. (Keep the on-device status card/QR as the only PIN surface.) | — |
| Q2 | ~~FTP accepts any credentials~~ **RESOLVED — Rev 1.1** — `PASS` now validated against the share PIN, `530` on mismatch (`ftp_server_service.dart:127-131`, `git a82df15`). | ~~P0~~ | ~~Full read of share root from the LAN~~ | N/A — fixed. (Optional hardening: add an explicit FTP "disabled when share PIN is empty" guard.) | — |
| Q3 | **~8% effective test coverage** — `coverage/lcov.info` instruments only 1,005 of ~29K LOC actually reached; `file_browser.dart` 20.4%, `web_share_server.dart` 3.4%, `preview_panel.dart` 7.4%, `bt_share` 10.5% | **P0** | Untested core + security-sensitivity of HTTP/FTP server ⇒ regressions ship silently | Line-coverage gates; priority: archive/duplicates, web-share auth/traversal, path scanning, players | L |
| Q4 | **Main-thread I/O in browser hot path** — per-entry `stat` on UI isolate (`file_utils.dart:597-604`); recursive filtered scan per-node (`:645-654`) awaited from UI (`file_browser.dart:560-570`) | **P0** | Directory loads and filter scans freeze the UI | Move to `Isolate.run`/`compute` (pattern in `archive_service.dart:461`), progressive batches like `search_service` | M |
| Q5 | **Duplicate SHA-256 hashing on UI isolate, whole-file read into memory** — `File(path).readAsBytes()` then `sha256.convert` on UI isolate (`archive_service.dart:20-27`); duplicates scan hammers `File.length()` (`duplicates_screen.dart:88`) | **P0** | Hashing a large tree == app freeze + OOM risk | Isolate + chunked streaming hashing; cancel in-flight scans | M |
| Q6 | **`MANAGE_EXTERNAL_STORAGE` (Play policy risk)** | **P0** | Play requires declared file-manager core function + justification form; combined with `REQUEST_INSTALL_PACKAGES` & `QUERY_ALL_PACKAGES` it raises takedown risk | File Play declaration + consent flow; prefer SAF grant path (G1/G2) to reduce blast radius | M |
| Q7 | **Foreground-service posture** — 5 types requested (`MEDIA_PLAYBACK`, `CONNECTED_DEVICE`, `BLUETOOTH`, `WAKE_LOCK`, generic) | **P1** | Android 14+/15 limits: must start from user-visible action, `shortService` ≤3 min, explicit notification; continuous BT listening is scrutinized | Justify each; start BT service only on explicit user action | M |
| Q8 | **Credential handling regression** — XOR "obfuscation" for passwords (`network_service.dart:40-80`), some OAuth tokens in SharedPreferences | **P0** | Trivially reversible; tokens recoverable | Real AES-GCM via `flutter_secure_storage` for all secrets | M |
| Q9 | **Swallowed errors + raw exception leakage** — many `catch(_){}` (`search_service.dart:299,320`, `file_utils.dart:646`, `pdf_engine.dart:32`); remote clients get raw exception text (`web_share_server.dart:138`) | **P2/P1** | Hides permission/IO failures; leaks internals | Structured logging + sanitized error surfaces | S |
| Q10 | **Monolith architecture** — `file_browser.dart` 3986L, `main.dart` 1270L, `doc_converter.dart` 1130L; mixed `setState`+`ValueNotifier`+single `ChangeNotifierProvider` | **P1** | Low maintainability, hard testing, slow feature work | Feature-first refactor + repository/DI; split giant widgets/screens into modules | L |
| Q11 | **Long operations not cancellable** — duplicate scan on init (`duplicates_screen.dart:145`) can't abort | **P2** | Once started, only killing the app stops it on a large tree | Cancellation token through the scan; top "Cancel" button | S |
| Q12 | **targetSdk not pinned** (`build.gradle.kts:27` = `flutter.targetSdkVersion`) | **P2** | Compliance drifts with SDK upgrades | Pin explicitly; align Data-Safety answers with actual usage | S |

> **Note:** Q1/Q2 are **resolved as of Rev 1.1** (`git a82df15`). Q6/Q8 remain *partially* documented in `docs/APP_ANALYSIS_REPORT.md` §4 (XOR obfuscation, OAuth tokens in prefs) and are still open here.
---

## 8. Cross-Cutting Themes & Roadmap

### Theme 1 — The SAF delegation fork (File Manager + Sharing + Documents)
The app's single biggest opportunity is to stop leaning on all-files access alone. Wiring the already-declared `saf` package for scoped-scope browsing, external-SD/OTG tree grants, and `content://` share/open URIs (G1, G2, G6, G8 + Q6) simultaneously fixes the top policy risk and the two most common storage use-cases.

### Theme 2 — The media-engine decision
Video: switch to `media_kit`/libmpv (closes V1/V2/V5/V8 in one go, the make-or-break vs VLC/MX). Audio: keep `just_audio`, layer EQ/gapless/library/speed/sleep-timer on top, and align the extension allow-lists with what the engine can actually decode — fix the "advertised but undecodable" format gate bug (media GAP + V1).

### Theme 3 — Archive & share hardening
Bundle libarchive via FFI for 7z/RAR/encryption/split (A1/A2/A4/A5/A6) and add real FTP auth + transfer resume + local discovery (S6/S3/S1). These bridge the two hardest replacement gaps (ZArchiver, LocalSend) with achievable, additive work.

### Theme 4 — Production hardening before everything
The two P0 auth leaks (Q1/Q2) are **now fixed (Rev 1.1)**. Remaining foundation work: move browser/duplicate heavy work off the UI isolate (Q4/Q5), seed a real test suite for the security/perf-critical paths (Q3), and file the Play permissions declaration (Q6). Security & perf are prerequisites to being a trusted daily driver.

### Phased roadmap

| Phase | Focus | Items | Outcome |
|-------|-------|-------|---------|
| **P0 — Foundation (0-2 wks)** | Security + perf | Q1/Q2 ✅ done (Rev 1.1); remaining: Q4/Q5 off the UI isolate, Q6 Play attestation, fix "advertised-but-undecodable" codec gates; cancel tokens | Trustworthy, non-freezing core; security-review-clean |
| **P1 — Storage & docs (2-6 wks)** | SAF + viewers | G1/G2/G6 SAF tree grants; G8 content:// share; D3 PDF search/select; D7 DOCX→PDF; D6 EPUB/CBZ | Replaces external viewers for the top-3 formats; compliant storage |
| **P2 — Media (4-8 wks)** | Engine migration | V1/V2 media_kit video; V4 gapless; V3 EQ; V5 speed/aspect/PiP; V9 sleep timer | Replaces VLC/MX for MKV/AC3/DTS + replaces Poweramp for gapless |
| **P3 — Archives & sharing (6-10 wks)** | Coverage + discovery | A1/A2 libarchive; A4/A5 encryption/split; S1 discovery; S3 resume; N1 SMB (S6 FTP auth ✅ done — Rev 1.1) | Replaces ZArchiver + is a credible LocalSend |
| **P4 — Depth (ongoing)** | Power features | Dual-pane/tabs (G4); recycle bin (G5); root (G7); library scan (V7); batch/OCR (D8); tags/checksums (G9) | Feature-parity with the dedicated premium apps |

---

## 9. Bottom Line

SwordFM is a genuinely ambitious **Swiss-army file manager** — far ahead of typical "file manager + PDF viewer" apps in domain breadth. But today it is a **"partial" replacement in all seven categories**, and the report card is clear:

- **Strongest:** file-manager core (with all-files permission) and LAN sharing.
- **Weakest:** document viewing/conversion (no spreadsheets, no PPTX render) and video playback (codec ceiling, no subtitles).
- **Security posture corrected (Rev 1.2):** only Q1 PIN-leak fix is real; Q2 FTP auth is parsed-but-unenforced (open). Remaining P0s: FTP gate + `Random.secure()` + rate-limit + Play attestation + credential nonce. P1 doc-converter regressions (codeUnits, fenced-code deletion `:885-886`, `MD` vs `Markdown` `:985`) fail 3 existing tests — revert before merge.
- **Highest-leverage moves:** decide SAF (removed in `pubspec.yaml:33`), vendor SheetJS for offline XLSX, FTP auth gate, HTTP/FTP resume, chunked hashing, real mDNS or documented 5350 schema.

With the phased roadmap above, SwordFM can credibly claim "replaces the dedicated apps" for **file management, LAN sharing, and the big document/archive formats** within ~6-10 weeks of focused work; full media-player and office-suite parity (EQ, gapless, XLSX, full PPTX, EPUB) remains the longer tail.

---

## 10. Rev 1.2 — What your changes actually did (team consensus)

Scope: 35 files, +3178/-2324 vs HEAD 71dd80d. Biggest: video_player (761), doc_converter (439), music_player (418), preview_panel (386). Deleted: terminal_screen (507L), terminal_service, interface_health + 2 test files. New: epub/cbz/spreadsheet/help screens + ocr_service + 4MB eng.traineddata.

### 10.1 File management — Partial-near, all-files only
Real: isolate listDirectory (file_utils 580-650), multi-clipboard, notif-permission fix (app_paths 20-29). Open: no SAF tree (app_paths 16-59, file_utils 580-712 all dart:io); no dual-pane/tabs; trash loses paths; no root exec; saf removed (pubspec 33) needs strategy decision; terminal deletion leaves docs/tests dangling.

### 10.2 Video/audio — engine real, chrome missing
Real: video_player to media_kit/libmpv (pubspec 45-47, video_player_screen 56-84) fixes codec ceiling; embedded subs, speed, audio-track, auto-next; music speed/sleep/shuffle/repeat + reopen fix + background. Missing: header over-claims aspect/PiP/HW-toggle (video_player_screen 9-14, none shipped); no external-sub picker, no playlist wiring, no resume, no EQ/library/queue; file_browser 254-291 advertises undecodable wma/ape/alac/mid/amr/aiff vs canonical file_utils 74-88.

### 10.3 Docs/conversion/OCR — readers real, fidelity fails
Real: EPUB text reader (no EPUB3 nav); CBZ ZIP reader (CBR honest msg); CSV local + XLSX via SheetJS CDN (spreadsheet_viewer 179 — offline FAIL); PDF-layout MD + DOCX-blocks MD + extractPdfText wired; offline Tesseract eng. Broken: no PPTX viewer; PDF image-only; codeUnits (doc_converter 79,139,305) corrupts non-ASCII; fenced-code deletion (885-886) fails 3 tests; MD vs Markdown label (985); CBZ predicate (cbz_reader 63) + full-RAM pages.

### 10.4 Archive/sharing — basics real, hard gaps open
Real: ZIP/TAR.XZ/BZ2 in isolates; ZipSlip-aware listing (archive_service 396-399); 3-pass isolate dedupe (18-87) but Pass-3 readAsBytes (55) OOMs on GB media; PIN sessions well-shaped (constant-time 410-417, HttpOnly cookie). Broken: 7z/RAR need Termux binaries (338-386); encryption/split zero; _MdnsBeacon announce-only (no SRV/TXT/A); FTP auth parsed-but-unenforced (ftp_server 21,125-131 vs 169-354); Random() PIN/session (web_share 298,404); no Range/REST resume; SMB informational stub (network_service 496-507).

### 10.5 Must-fix before merge (blocking)
P0: fix 8 failing tests (3 fenced-code, Interface-Health, +4); 2 analyze warnings; FTP auth gate; Random.secure + nonce + throttling; Play MANAGE/QUERY/background-location justification. P1: codeUnits revert + non-ASCII test; fenced-code restore; MD/Markdown contract; gate swordfm://open path; SAF sign-off; vendor SheetJS.

---

*Rev 1.2 by 5-agent team re-audit (file-manager-core, media-player, documents-ocr, archive-sharing, quality-security), all findings anchored to file:line. See docs/APP_ANALYSIS_REPORT.md for the original audit.*