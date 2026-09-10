# SwordFM Android — Rev 1.3 Working-Tree Status Report

**Date:** 2026-09-11
**Scope:** Independent re-verification of the uncommitted working tree (the "I made changes" pass), 5-agent team + direct CLI verification.
**Bottom line:** **Substantially improved — the previous blockers are fixed.** `flutter analyze`: **0 errors / 5 warnings**. `flutter test`: **all 199 tests PASS** (was 182 pass / 8 fail). Several security P0s called out in `docs/REPLACEMENT_GAP_REPORT.md` Rev 1.2 are now **FIXED**; the older report's "parsed-but-unenforced" and "Random() not Random.secure()" claims are **archived/stale** against the current source.

---

## 1. Verified by direct CLI runs

| Check | Before (Rev 1.2 gap report) | Now (current working tree) |
|-------|------------------------------|----------------------------|
| `flutter analyze` | 116 issues (0 err / 2 warn) | **114 issues (0 err / 5 warn)** — old 2 warnings gone |
| `flutter test` | 182 pass / 8 fail | **199 / 199 PASS** — the 8 failing tests are FIXED |
| Dangling refs to deleted `terminal_*` / `interface_health_*` | — | **None** (grep clean across `lib/` + `test/`) |

`flutter analyze` summary: **0 errors**, **5 warnings**, **109 info**. All 5 warnings are new, all in `lib/screens/video_player_screen.dart`:
- `:36` `_initialized` field set but never read
- `:37` `_initFailed` set but never read
- `:38` `_initError` set but never read
- `:211` dead code (right operand of `??` unreachable)
- `:211` `dead_null_aware_expression` (same line)

`flutter test`: **199/199 passed**. This closes the Rev 1.2 "must-fix" list items for the 3× `doc_converter_test.dart` failures, `network_screen_test.dart` (Interface Health), and the +4 others. The markdown fenced-code / doc-converter regressions are resolved in the current tree.
---

## 2. Security findings: previously-called P0s — NOW VERIFIED FIXED

These contradict (and supersede) claims in `docs/REPLACEMENT_GAP_REPORT.md:17,263,266`:

| Item | Where to verify | Status |
|------|-----------------|--------|
| **FTP auth gate** | `lib/services/ftp_server_service.dart:141-142` | ✅ **Enforced** — returns `530 Not logged in.\r\n` for any command not in the open pre-auth set (`USER/PASS/SYST/FEAT/OPTS/TYPE/NOOP/QUIT/ABOR`); `PASS` mismatch → `530 Login incorrect.` (`:147-152`). The Rev 1.2 "parsed-but-unenforced" claim is **archived**. |
| **PIN/session RNG** | `lib/services/web_share_server.dart:301,408` | ✅ **`Random.secure()`** used for both PIN and session token. Rev 1.2 "Random() not Random.secure()" claim is **stale**. |
| **Auth rate limiting** | `lib/services/web_share_server.dart:453` ("5 failures → 30s lockout") | ✅ Implemented per client IP. |
| **Upload-500 info leak** | `lib/services/web_share_server.dart:371` | ✅ Sends generic `Internal Server Error` — raw `$e` no longer returned to the client. |
| **Constant-time PIN compare** | `web_share_server.dart:410-417` | ✅ Still present and correct. |
| **`extractPdfText` API** | `lib/services/doc_converter.dart:224` | ✅ **Exists.** The claim by one draft that it "does not exist" is false; the PDF reader's text-fallback call (`pdf_reader_screen.dart:315`) is valid. |

**Remaining security note:** FTP default `sharePin = ''` means `_authenticated = sharePin.isEmpty` (`ftp_server_service.dart:59`) → **open by default until the user sets a PIN**. Worth a decision (auto-generate at start, or require explicit open-mode).

---

## 3. Feature-readiness vs "replace a dedicated app" (still open)

These are the honest gaps that keep SwordFM from replacing the dedicated apps. Most were already called in Rev 1.0/1.2 and are **unchanged** by this pass.

### 3.1 File manager — Partial-near (all-files only)
- No dual-pane/tabs; trash loses paths; no SAF tree/root exec (SAF removed from `pubspec.yaml`); core still `dart:io`.
- ✅ In-app viewers now open PDF/images/DOCX from Browse/Search/Recent instead of falling through to external apps.

### 3.2 Video / audio — engine real, chrome missing
- **Playlist / auto-next is DEAD in practice**: every call site builds `VideoPlayerScreen(filePath: path)` with no `playlist` — `lib/widgets/file_browser.dart:794`, `lib/screens/recent_files_screen.dart:276`, `lib/screens/search_screen.dart:147`. The auto-next feature can never trigger.
- Hardware decode hardcoded **OFF** (`video_player_screen.dart:70`) with no runtime toggle (roadmap comment `:14` over-promises).
- No video resume, no external-subtitle file picker (sidecar/embedded only).
- Audio: no album art/metadata extraction, no library/folder-scan, no EQ.

### 3.3 Docs / conversion / OCR — readers real, fidelity gaps
- **XLSX/XLS/ODS still fail offline** — SheetJS loaded from CDN (`lib/screens/spreadsheet_viewer_screen.dart:179`). CSV is fine (pure Dart).
- EPUB = text extraction only (no EPUB3 nav / CSS / images). CBZ works for clean archives (image-validation + predicate edge cases remain). CBR is an honest "unsupported" message.

### 3.4 Archive / sharing — basics real, hard gaps open
- **Dedup Pass-3 `readAsBytes()` loads full file into RAM** → OOM risk on GB media (`lib/services/archive_service.dart:55`; same in `sha256OfFile` `:68-75`). Needs streaming/chunked hashing.
- `extractEntry` (single-file path `archive_service.dart:402-415`) **lacks the ZipSlip guards** that `extract` (`:253-265`) has.
- 7z/RAR need Termux binaries; no archive encryption or split/volume support.
- mDNS beacon is **announce-only** (PTR, no SRV/TXT/A resolution) — the JSON broadcast on 5350 is the real discovery channel.
- No HTTP `Range` / FTP `REST` resume.
- SMB is an informational stub (`lib/services/network_service.dart:496-507`).
---

## 4. Verdict for "is it fine?"

- **Ready-to-merge quality gate: YES** — 0 analyze errors, 199/199 tests green, no dangling references, FTP/PIN/rate-limit security P0s fixed. Only 5 new unused/dead-code warnings in `video_player_screen.dart` to tidy.
- **Ready to replace the dedicated apps: NO (unchanged)** — the feature-completeness gaps (dead playlist wiring, XLSX offline, archive dedup OOM, no resume, mDNS/SMB) remain exactly where Rev 1.0/1.2 left them.

**Highest-leverage next steps (in priority order):**
1. Pass `playlist` from Browse/Search/Recent into `VideoPlayerScreen` so auto-next actually works (couple of lines).
2. Remove the 5 dead fields/`??` in `video_player_screen.dart` (lines 36-38, 211).
3. Streaming/chunked hash for dedup + `sha256OfFile` (fixes GB OOM).
4. Port ZipSlip guard from `extract` to `extractEntry`.
5. Decide the empty-FTP-PIN default (auto-generate at start).
6. Bundle SheetJS locally for offline XLSX.

*Rev 1.3 by 5-agent team (media-player, documents-ocr, archive-sharing, file-manager, quality-security) + primary-agent CLI verification. See `docs/REPLACEMENT_GAP_REPORT.md` for the original domain audit and full roadmap.*

---

## Rev 1.4 — Fixes applied (this pass)

**Decision:** 7z/RAR deferred (per user). Items 1-5 below are coded and **verified**: `flutter analyze` = **0 errors / 0 warnings** (down from 0/5), `flutter test` = **all 199 pass**. Item 6 deferred (see note).

| # | Fix | File | Status |
|---|-----|------|--------|
| 1 | **Video playlist wired** — `_openVideo` now builds a sibling-video playlist and passes `playlist`/`initialIndex` into `VideoPlayerScreen` | `lib/widgets/file_browser.dart:792-815`, `lib/screens/search_screen.dart:143-160`, `lib/screens/recent_files_screen.dart:273-289` | ✅ Auto-next is now reachable from Browse, Search (all video hits), and Recent |
| 2 | **5 dead-code warnings cleared** — removed unused `_initialized`/`_initFailed`/`_initError`; init catch now surfaces `_error`; dropped dead `?? []` on audio tracks | `lib/screens/video_player_screen.dart` | ✅ 0 warnings |
| 3 | **Streaming dedup hash** — Pass-3 and `sha256OfFile` now stream 1 MB chunks via `sha256.startChunkedConversion` instead of `readAsBytes()` (fixes GB-OOM). Verified chunked==oneshot on 5 MB | `lib/services/archive_service.dart:19-55` | ✅ |
| 4 | **`extractEntry` ZipSlip guard** — rejects `..`, NUL, leading-slash, empty; `firstOrNull` + clear error instead of crash | `lib/services/archive_service.dart:434-473` | ✅ |
| 5 | **FTP empty-PIN default** — already mitigated: `lan_screen.dart:191` refuses to start FTP with an empty PIN (\"require explicit open-mode\" decision already implemented); web share always yields `Random.secure()` PIN which FTP copies | no change needed | ✅ already handled |
| 6 | **Bundle SheetJS locally** — **deferred.** `webview_flutter` 4.14 (resolved from `^4.8.0`) exposes **no** local-asset API (`registerAsset`/`WebViewAssetManager` were removed in 4.x); reliable offline serving needs either a device-tested file path or a package strategy. Not changed to avoid an unverifiable, potentially-breaking webview change | — | ⚠️ deferred, still CDN + honest offline message |

**Net result:** `flutter analyze` 114→110 (all info), `flutter test` 199/199 green. The remaining real gaps for \"replace the dedicated apps\" are now: XLSX offline (deferred #6), 7z/RAR (deferred), archive encryption/split, mDNS announce-only resolution, no HTTP `Range`/FTP `REST` resume, SMB stub, no video resume.