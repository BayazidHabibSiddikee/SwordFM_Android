# SwordFM — Rev 3: Production Readiness & Replacement Parity Assessment

**Date:** 2026-09-12 · **Commit:** `d7c8b1d` · **Method:** 6-agent parallel audit with adversarial verification

> **This report supersedes `REPLACEMENT_GAP_REPORT.md` and `PRODUCTION_READINESS_REV2.md`.**
> Both prior documents contain claims that are refuted by current source (see §7). Neither should be
> used as a baseline. Every conclusion below was re-derived from source; nothing was inherited.

**Scope note:** per instruction, **7z and RAR are excluded** from the archive verdict. They are
mentioned only where their *failure mode* matters (capability signalling).

---

## 1. Answer in one line

**Not ready to publish, and not yet a replacement for any of the seven categories — but it is much
closer than the prior audits claim.** Two categories are near-parity (file manager, file sharing),
two are close (music, video), and three have decisive gaps (doc viewing, conversion, archives).
Publication is gated by **one policy item** plus four real fixes, not by a rewrite.

### Replacement matrix

| # | Category | Verdict | Decisive blocker |
|---|----------|---------|------------------|
| 1 | **File manager** | 🟡 PARTIAL (near) | No SAF/scoped-storage path at all — all-files permission is mandatory |
| 2 | **Music player** | 🟡 PARTIAL | No equalizer, no gapless, no library/album/artist scan — it is a folder player |
| 3 | **Video player** | 🟡 PARTIAL (near) | Codec ceiling now competitive; missing aspect-ratio control + PiP |
| 4 | **Doc/PDF viewer** | 🔴 CANNOT REPLACE | PPTX has no in-app rendering and no external handoff — dead-drops into directory nav |
| 5 | **Conversions** | 🔴 CANNOT REPLACE | Text/Markdown-centric only; no XLSX/PPTX output, no batch, no searchable-PDF |
| 6 | **Archives** (excl. 7z/RAR) | 🔴 CANNOT REPLACE | No password/encrypted-archive support (create or extract); no split volumes |
| 7 | **File sharing** | 🟡 PARTIAL (near) | LAN works, but no receiver UI for discovery and no Wi-Fi Direct |

**Legend:** 🟢 replaces today · 🟡 partial — usable, but common cases push users back · 🔴 decisive gap.

### Production readiness

| Metric | Measured |
|---|---|
| Verdict | **NOT READY TO PUBLISH / READY WITH FIXES** |
| `flutter test --coverage` | **344 passed / 0 failed** |
| `flutter analyze` | **107 issues — 0 errors, 0 warnings** |
| Raw line coverage | **25.80%** (LH 3720 / LF 14418, 66 files) |
| CI coverage floor | `MIN_COVERAGE: "24"` → gate passes (near-rubber-stamp) |
| Top blocker | `MANAGE_EXTERNAL_STORAGE` with zero SAF fallback |


---

## 2. Ship blockers, ranked

| # | Blocker | Sev | Consequence | Evidence |
|---|---------|-----|-------------|----------|
| 1 | `MANAGE_EXTERNAL_STORAGE` with **zero SAF fallback** | HIGH | Play declaration + human review required; if refused or user-denied, core file management becomes **unusable** (falls back to media-only grants). Top policy *and* top functional risk. | `AndroidManifest.xml:19`; `app_paths.dart:31-58`; zero SAF hits in `lib/` |
| 2 | `REQUEST_INSTALL_PACKAGES` + PackageInstaller flow | MED | Heavy Play scrutiny; not part of the file-manager core function; easiest permission to cut | `AndroidManifest.xml:23`; `installer_service.dart:15-53` |
| 3 | Firebase API key in git history | MED | Quota abuse / billing exposure if unrestricted. Fix is **key restriction**, not just history rewrite | key in `18fd58b`, `4338588`, `c8bf336` |
| 4 | FTP cross-session auth bleed + no FTP rate limit + non-constant-time compare | MED | Unauthenticated LAN client can reach filesystem commands under the right concurrency; brute-force is unthrottled | `ftp_server_service.dart:27,61,150,153` |
| 5 | Dead `ftp_server_screen.dart` with empty-PIN default | MED (latent) | Currently unreferenced (not live) — but an open-FTP footgun that contradicts its own service contract | `:22,37,38,149`; zero refs in `lib/` |
| 6 | Per-tile unisolated recursive folder size | MED | Jank/ANR on directories with many subfolders | `file_browser.dart:1936,3187,3368` → `file_utils.dart:187-198` |
| 7 | 25.80% coverage vs an 80% standard, with a verified no-op CI filter | MED | Regressions ship silently; the gate provides false assurance | `coverage/lcov.info`; `ci.yml:17,76` |
| 8 | Cleartext LAN/FTP transport | MED | PIN + file bytes sniffable on shared Wi-Fi | `web_share_server.dart:336`; `ftp_server_service.dart:42` |
| 9 | `targetSdk` not pinned | LOW | Play target-API compliance cannot be confirmed from the repo | `build.gradle.kts:29` |
| 10 | Accessibility: 2 `Semantics(` vs 117 `IconButton(` | LOW | Poor screen-reader support | screen-wide count |
| 11 | SMB offered in UI but inert | LOW | Capability mis-signalling | `network_service.dart:390-419` |

**Deliberately closed — NOT blockers (prior concerns refuted):**
- **Debug-key release signing:** `build.gradle.kts:82-91` throws `GradleException`; both CI workflows verify
  with `apksigner`. No keystore / `key.properties` tracked.
- **Termux runtime dependency:** does not exist — "Termux" appears only in user-facing hint strings.
- **RCE / command injection:** none found. The three `Process.run` sites in `lib/` are `pdfinfo`, `df`,
  `chmod` — and `pdfinfo` (`pdf_engine.dart:59,109`) is **dead code** that never ships.

---

## 3. Replacement detail

### 3.1 File manager — 🟡 PARTIAL (near)
Genuinely strong, the closest to parity. Collision-safe unique destinations (`file_utils.dart:739-753`),
recursive tolerant copy (`:770-795`), persistent clipboard, batch rename, multi-select, real decoded
thumbnails and real cached video thumbnails (`file_browser.dart:3961-3996`). Search runs in a spawned
isolate (`search_service.dart:46-62`); duplicate scan is a 3-pass `Isolate.run` with **chunked 1 MB
streaming SHA-256, not whole-file-into-RAM** (`archive_service.dart:22-40,58-108,152-156`).

**The trash is real, not a stub:** `moveToTrash`/`listTrash`/`restoreFromTrash`/`emptyTrash`
(`file_utils.dart:948-980`) with TTL auto-empty (`:1018-1048`), wired from four call sites.

Decisive gap is the permission model, not features. Also absent: SMB/NAS (offered in the picker but
inert), dual-pane/tabs, checksum display (`sha256OfFile` at `archive_service.dart:142` has **zero
callers** — dead code). "Root Mode" does **not** exec `su`; it only probes for the binary and lifts path
guards (`file_utils.dart:863-881`, `file_browser.dart:447,508`).

### 3.2 Music player — 🟡 PARTIAL
Right engine (`just_audio` + `audio_service`, `audio_handler.dart:6,30`) with solid transport:
shuffle/repeat, speed, sleep timer, queue next/prev, background notification, headset controls, resume.
What keeps it a *folder* player: `MediaItem` hardcodes `artist: 'SwordFM'` (`audio_handler.dart:96`) and
there is no tag/library scan. No equalizer (`grep -rni equalizer lib/` → 0 hits), no gapless, no
crossfade, no playlist persistence.

### 3.3 Video player — 🟡 PARTIAL (near)
**Engine is `media_kit`/libmpv, not ExoPlayer** (`pubspec.yaml:45-47`, `video_player_screen.dart:5,107,415`).
The bundled FFmpeg set includes AC3/DTS/EAC3/TrueHD, so the old patent-codec blocker is gone. Present and
working: embedded subtitles, playback speed, HW/SW decode toggle, audio-track selection, resume, auto-next
playlist. Missing: aspect-ratio control and PiP (acknowledged as unshipped in `video_player_screen.dart:20`).

### 3.4 Doc/PDF viewer — 🔴 CANNOT REPLACE
PDF is the only faithful viewer and even it is image-only: no text selection on rendered pages, no forms,
no annotations-to-file, no password prompt; search matches extracted text rather than highlighting pages
(`pdf_reader_screen.dart:394-463`). DOCX renders approximately. EPUB is stripped to text.

**PPTX is the decisive failure:** it renders only as a regex-scraped `<a:t>` text outline in the side
panel (`preview_panel.dart:927-973`), and the full-screen branch is a no-op that `break`s into directory
navigation (`main.dart:318-330`) — **worse than the prior audit claimed, because there is not even an
external-app handoff.**

Credit where due: **XLSX/XLS/ODS do work offline** via a bundled SheetJS asset
(`spreadsheet_viewer_screen.dart:94-185`, `assets/js/xlsx.full.min.js`), refuting both the "no XLSX" and
"SheetJS CDN fails offline" claims.

### 3.5 Conversions — 🔴 CANNOT REPLACE
Everything offered is offline and pure-Dart, a genuine strength: MD/TXT/code→PDF/DOCX/HTML/TXT,
DOCX→PDF/HTML/TXT/MD, PDF→TXT/MD (low fidelity), image→PDF, and **fully offline Tesseract OCR with 14
bundled language models and no cloud dependency** (`ocr_service.dart:113-159`).

Absent: any spreadsheet or presentation output, XLSX/PPTX→anything, batch conversion, searchable-PDF.
`ConvertDialog` is wired (`file_browser.dart:2201`) but only offered for text/PDF/DOCX — not xlsx/csv/pptx.

### 3.6 Archives (excl. 7z/RAR) — 🔴 CANNOT REPLACE
The pure-Dart core is honest: ZIP/TAR/GZ/XZ/BZ2 create+extract via the `archive` package, shipping in the
APK, working on a stock device. **ZIP-SLIP is properly defended in `extract()`** — symlink skip, NUL
rejection, absolute-path strip, `..` component rejection, canonical-prefix guard
(`archive_service.dart:372-399`).

Two decisive gaps: **no password/encryption support whatsoever** (cannot extract a password-protected ZIP,
the most common encrypted container on Android) and **no split/multi-volume**. Secondary: whole-archive
`readAsBytes` into RAM (`:273`, `:554`) → multi-GB archives OOM; no compression level; no cancellation.

**Caveat:** the sibling `extractEntry()` (`:516-545`) filters names by substring only and lacks the
`canonicalize` check — suspected weaker, **not proven exploitable** (no bypass archive was constructed).

### 3.7 File sharing — 🟡 PARTIAL (near)
The auth core is unusually good: 6-digit PIN from `Random.secure()`, constant-time comparison, per-IP rate
limiting (5 failures → 30s lockout), HttpOnly session cookies, and **fully implemented HTTP Range support**
(206/Content-Range/416) — which refutes the prior "sends from 0 only" claim.

**FTP auth is enforced** on the reachable path (`ftp_server_service.dart:149-154` plus a global 530 gate),
and the **PIN-leak endpoint is gone** — the route table is exactly `/`, `/index.html`, `/download/*`,
`/api/list`, `/api/auth`, `/upload` (the mDNS broadcast advertises only a boolean `pin_required`).

Gaps: no TLS (everything is cleartext on a shared Wi-Fi network), no receiver UI so discovered peers are
invisible (`_nearbyDevices` is written but never rendered), no Wi-Fi Direct, no upload resume (partial
uploads are deleted on failure, `:932-933`), Bluetooth unauthenticated at app level (OS pairing only).


---

## 4. Security findings, with honest exploitability

### 1. Cleartext transport on LAN HTTP and FTP — HIGH
`web_share_server.dart:336` plain `HttpServer.bind`; `ftp_server_service.dart:42` plain `ServerSocket.bind`;
no `SecurityContext` anywhere in `lib/`.

**Exploitable on a shared Wi-Fi network: yes, trivially.** The 6-digit PIN travels in the `/api/auth` POST
body and the session cookie is `HttpOnly` but not `Secure`; with no TLS layer, any peer on the same AP can
capture the PIN and then the session cookie, and read or upload files. This is the concrete capability
separating SwordFM sharing from LocalSend (TLS + fingerprint verification).
**Fix (M):** self-signed TLS with the fingerprint shown in the QR/UI, and add `Secure` to the cookie.

### 2. FTP authentication weaknesses — MEDIUM
- **Non-constant-time compare** at `ftp_server_service.dart:150` (`arg != service.sharePin`) while the HTTP
  path correctly uses `constantTimeCompare`.
- **No rate limiting on FTP.** The HTTP lockout (`web_share_server.dart:472-501`) protects `/api/auth`
  **only**, so an FTP brute-forcer bypasses the lockout entirely — this makes the weaker comparison
  materially worse, and is the biggest *fixable* hole.
- **Cross-session auth bleed (newly found).** `_authenticated` is a service-level field (`:27`), not
  per-`_FtpSession`. A second concurrent client's `PASS` sets it true globally, unlocking **another**
  connection's LIST/RETR/STOR/DELE without that connection authenticating.

**Fix (S — highest leverage per line changed):** move `_authenticated` into `_FtpSession`, use
`constantTimeCompare`, add per-IP failure lockout.

### 3. Bluetooth receiver has no app-level authentication — MEDIUM/LOW
`BluetoothShareService.kt:103-109` uses `listenUsingRfcommWithServiceRecord` (secure RFCOMM → OS pairing
forced, which is good) but there is no in-app accept prompt, and it stops accepting after the first
connection (`:109`). Exploitability: **low** — needs physical proximity and OS-level pairing. Integrity is
provided (SHA-256, `:170,217`), confidentiality is not.

### 4. Firebase key in git history — MEDIUM
Client API key `AIzaSyChW2PHVikd9u0qAcBkj5WFtBmeEZBQ7Ms` (project `swordfm-412e3`) is present in historical
commits. **Honest framing:** Firebase client API keys are *designed to be public* and ship inside every
APK; the genuine risk is **unrestricted use** (quota abuse / billing), not key secrecy. Correct remediation
is **API-key restriction in Google Cloud Console** (package name + SHA-1), with history purge as hygiene.

### 5. Archive path traversal — DEFENDED, with one weak sibling
`extract()` is properly layered (`archive_service.dart:377,379,382-384,387,394-398`). `extractEntry()`
(`:516-545`) filters names by substring only and builds `p.join(destDir, name)` at `:539` **without** the
canonicalize re-check. **Status: suspected weaker, NOT proven exploitable** — no bypass archive was built.

### 6. Web-share hardening — genuinely good
Worth stating plainly, because this is the app's most security-sensitive component and the prior docs got
it backwards: PIN from `Random.secure()`; constant-time comparison; per-IP rate limiting with lockout; no
PIN-echoing endpoint; mDNS advertises only a boolean; access log strips query strings; full HTTP Range
support. Its test suite boots a **real `HttpServer`** on loopback and asserts 401/400/429 gating,
HttpOnly/SameSite, cookie forgery rejection, subdirectory traversal, NUL filenames, byte-exact download and
real 206/tail/416 — **98/98 tests pass**.


---

## 5. Evidence integrity

### Method: verify, don't summarize
6 agents ran in parallel: 5 domain analysts (media, docs, archive, sharing, filesystem) plus **1
adversarial verifier whose explicit job was to falsify the other five**. Every verdict was re-derived from
source at HEAD `d7c8b1d`. The lead independently reproduced the highest-stakes claims before accepting them.

**Rules enforced on every agent:** (1) every claim cites `file:line` or a command output; (2) never
conflate IMPLEMENTED vs WIRED IN UI vs WORKING ON A STOCK DEVICE — dead code earns no credit; (3) prior
audit docs are untrusted hints, never evidence; (4) prefer reproducing behavior over reading it.

### Independently reproduced measurements
| Measurement | Command | Result |
|---|---|---|
| Test suite | `flutter test --coverage` | **344 passed / 0 failed**, exit 0 |
| Static analysis | `flutter analyze` | **107 issues, 0 errors, 0 warnings** |
| Raw line coverage | `coverage/lcov.info` | **25.80%** (LH 3720 / LF 14418, 66 files) |
| CI coverage floor | `ci.yml:17` | `MIN_COVERAGE: "24"` → gate **passes** |
| lcov filter effectiveness | `grep '^SF:' lcov.info` filtered by CI's globs | **0 files matched** — `--remove` at `ci.yml:76` is a **no-op** |
| Sharing tests | `flutter test web_share_server ftp_auth_gate bluetooth_service ftp_probe` | **98/98 pass** |
| Doc tests | `flutter test doc_converter pdf_engine_render docx_reader real_pdf` | **45/45 pass** |
| SAF presence | `grep -i saf pubspec.yaml`; `grep -rn 'OpenDocumentTree\|takePersistableUriPermission' lib/` | **zero hits** |
| Termux shell-out | all `Process.run` in `lib/` | pdfinfo / `df` / `chmod` only — **none archive-related** |
| Committed secrets | `git ls-files` filtered for keystore/jks/p12/key.properties/google-services | **none tracked** |

### What the adversarial verifier corrected
It **confirmed** the lead's findings on dead `saf`, correct release signing, manifest permissions and the
no-op lcov filter — each re-derived, not taken on trust. It **refuted both sides** of the FTP contradiction
(`REV2.md:78` "FTP ✅ FIXED" is overstated; `GAP_REPORT.md:17` "FTP open" is a false blanket claim),
established the accurate middle position explained by *reachability*, and found a defect neither doc
reports (cross-session auth bleed). It also identified that `pdf_engine.dart::PdfEngine` is **dead in
`lib/`**, meaning some PDF tests exercise a poppler path that never ships, and that
`test/round_trip_pure/` is an **empty directory** despite code comments citing that suite.

---

## 6. Confidence and gaps

### Confidence by conclusion
| Conclusion | Confidence | Why |
|---|---|---|
| Prior docs contain multiple refuted claims | **HIGH** | Each correction re-derived by 2 agents from source |
| Video engine is media_kit/libmpv, not ExoPlayer | **HIGH** | Direct read of `pubspec.yaml` + screen imports; no `video_player` |
| `saf` entirely removed; no SAF path exists | **HIGH** | Two independent greps, both empty |
| Release signing never falls back to debug | **HIGH** | Literal `throw GradleException` in Gradle config |
| FTP auth enforced on the reachable path | **HIGH** | Quoted handler + UI guard + passing test |
| FTP cross-session auth bleed | **MED-HIGH** | Code structure unambiguous; exploitability not demonstrated on a network |
| Test count 344, coverage 25.80% | **HIGH** | Reproduced independently by 2 agents |
| CI lcov filter is a no-op | **HIGH** | Verified by enumerating `SF:` paths |
| Documentation fidelity ratings | **MEDIUM** | Source-level parser inspection; no device rendering pass |
| Real libmpv v1.1.7 codec ceiling | **MEDIUM** | Package build config + upstream codec list; `.so` not extracted |
| ZIP-SLIP in `extractEntry()` | **LOW / UNPROVEN** | Weaker guard identified; no bypass archive constructed |

### Explicitly NOT verified (and why)
1. **No Android device or emulator.** Everything behavioral is code-level. Specifically unverified: libmpv
   playback and hardware decoding, subtitle rendering, Bluetooth RFCOMM transfer, background-audio
   notification, real ANR severity from the unisolated folder-size walk, and SheetJS in a WebView.
2. **`targetSdk` numeric value.** `build.gradle.kts:29` sets `flutter.targetSdkVersion`; the resolved
   integer needs a merged-manifest build. **Play target-API compliance is therefore unknown** — a real gap
   in the readiness verdict, not a formality.
3. **Play Console review outcome.** Cannot be predicted; the declaration form and reviewer judgment decide it.
4. **Network exploitability of the cleartext finding.** Reasoned from the absence of TLS, not demonstrated
   by sniffing on a live AP.
5. **mDNS interop.** Packet is byte-constructed per spec, but no two-device test was run. Notably, **no
   `WifiManager.MulticastLock` is acquired anywhere** despite `CHANGE_WIFI_MULTICAST_STATE` being declared
   — multicast may be silently dropped on many OEM ROMs. Unverified risk.
6. **Whether the Firebase key is currently restricted** — not determinable from the repository.
7. **The empty `test/round_trip_pure/`** means the RUET suite code comments cite does not execute.
8. **PDF password behavior** inferred (open throws → caught → text fallback), not observed.

### What a single device pass would resolve
One session on a real phone would raise the MEDIUM-confidence items to HIGH by testing MKV/AC3 playback,
subtitle auto-load, a large directory for jank, a real LAN transfer for sniffing feasibility, and a complex
PPTX/XLSX for fidelity. It would **not** change any replacement verdict, because those rest on absent code
(no PPTX renderer, no encrypted-archive support, no SAF path, no equalizer), not on quality judgments.


---

## 7. Corrections to the prior audit documents

**Both prior docs contradict each other, and neither is a trustworthy baseline.** Every correction below
was independently re-derived from source at HEAD `d7c8b1d` by a domain analyst *and* the adversarial verifier.

### Refuted (prior doc said X, source says not-X)
| Prior claim | Location | Reality | Evidence |
|---|---|---|---|
| Video uses ExoPlayer/Media3, no DTS/AC3 | `GAP_REPORT.md:93-94,100-101` | **Engine is media_kit/libmpv**; DTS/AC3/EAC3/TrueHD decode | `pubspec.yaml:45-47`; `video_player_screen.dart:5,107,415` |
| `saf` package declared but unused | `GAP_REPORT.md:71` | **`saf` entirely gone** from pubspec; zero SAF code | `grep -i saf pubspec.yaml` = none |
| FTP auth "parsed-but-unenforced (open)" | `GAP_REPORT.md:17,242,263` | **Enforced** on the reachable path (530 + global gate; UI refuses empty PIN) | `ftp_server_service.dart:143-145,149-154`; `lan_screen.dart:188-202` |
| 7z/RAR/zst via Termux shell-out to hardcoded path | `GAP_REPORT.md:161` | **No shell-out exists.** "Termux" is a *hint string* in an exception message | `archive_service.dart:246-261`; all `Process.run` = pdfinfo/`df`/`chmod` |
| No XLSX support | `GAP_REPORT.md:49` | **XLSX/XLS/ODS work offline** via bundled SheetJS asset | `file_open_router.dart:104-110`; `spreadsheet_viewer_screen.dart:94-185` |
| SheetJS loaded from CDN, fails offline | `GAP_REPORT.md:260` | **Loads local asset** `assets/js/xlsx.full.min.js`; zero CDN hits | `spreadsheet_viewer_screen.dart:101-102` |
| No PDF text search | `GAP_REPORT.md:126` | **In-document search exists** | `pdf_reader_screen.dart:394-463,815-838` |
| HTTP downloads send from byte 0 only | `GAP_REPORT.md:176` | **Full Range support** (206/416). Claim holds for *uploads* only | `web_share_server.dart:817-853` |
| ~8% coverage; 182 pass/8 fail; 2 warnings | `GAP_REPORT.md:21,196` | **25.80% coverage; 344/344 pass; 0 warnings** | local `flutter test --coverage` |
| FTP "✅ FIXED" (unconditional) | `REV2.md:78` | **Overstated** — `sharePin.isNotEmpty && ...`, so an empty PIN still opens the service | `ftp_server_service.dart:150` |
| Service sets `_authenticated = sharePin.isEmpty` | `REV2.md:135` | **Misquote** — actual line is `_authenticated = false` | `ftp_server_service.dart:61` |
| 282/282 tests | `REV2.md:18,45,396` | **Contradicts its own line 334 (344)**; truth is 344 | local re-run |
| 3 doc_converter tests failing | `GAP_REPORT.md:260` | **All pass** (45/45 across the doc suite) | local re-run |

### Confirmed-correct prior claims (credit where due)
- **`google-services.json` is untracked** (`REV2.md:77`) — CONFIRMED. *Caveat the doc missed:* it remains in
  **git history** (`18fd58b`, `4338588`, `c8bf336`).
- **No TLS on either server** (`REV2.md:223`) — CONFIRMED.
- **Accessibility is the weakest axis** — CONFIRMED (2 `Semantics(` vs 117 `IconButton(`).

### Defects found that NEITHER prior doc reports
1. **FTP cross-session auth bleed** — one shared `_authenticated` field unlocks other connections.
2. **Dead `ftp_server_screen.dart` is an open-FTP footgun** — zero refs, empty PIN default, no guard, and a
   hint saying "Leave empty for no password" (`:22,37,38,149`), contradicting the service's own comment.
3. **`pdf_engine.dart::PdfEngine` is dead in `lib/`** — some PDF tests gate on a poppler path that never ships.
4. **`test/round_trip_pure/` is an empty directory** — the suite the code comments cite does not run.


---

## 8. What to do, in order

**Phase 0 — unblock publication (days)**
1. File the `MANAGE_EXTERNAL_STORAGE` Play declaration, or build the SAF fallback and drop the permission.
   If `REQUEST_INSTALL_PACKAGES` is not core, cut it — it is the easiest scrutiny removed.
2. Restrict + (optionally) rotate the Firebase key in Google Cloud Console.
3. Delete or guard `ftp_server_screen.dart`; move `_authenticated` into `_FtpSession`, use
   `constantTimeCompare`, and add a per-IP failure lockout.

**Phase 1 — make the gate meaningful (days)**
4. Raise `MIN_COVERAGE` to the measured value and delete the no-op `lcov --remove` globs at `ci.yml:76`.
5. Test the production PDF renderer (pdfx/pdfium), not the dead poppler path; rebuild
   `test/round_trip_pure/` or delete the stale comments referencing it.

**Phase 2 — close the replacement gaps (weeks)**
6. **Archives (excl. 7z/RAR):** password-protected ZIP extract → create; streaming extraction + progress +
   cancel. This is what makes it ZArchiver-class.
7. **Docs:** PPTX full-screen reader (the no-op `break` at `main.dart:318` is the worst UX defect found);
   PDF text-layer overlay for selection + true search highlight; expose `ConvertDialog` for xlsx/csv/pptx;
   add XLSX→PDF.
8. **Music:** library/album/artist scan + artwork (replaces the hardcoded `artist: 'SwordFM'`), equalizer,
   gapless.
9. **Video:** aspect-ratio menu + PiP.
10. **File manager:** SAF tree grants + persisted URIs; delete or implement SMB; stop per-tile recursive
    folder size.
11. **Sharing:** TLS for the LAN server (the real LocalSend gap); render the discovery list; upload resume.

---

## 9. Bottom line

SwordFM is a **genuinely ambitious, better-engineered app than its own documentation claims.** It has a
modern libmpv video engine, a strong and well-tested LAN auth core with real Range support, working offline
XLSX, offline OCR, a real recycle bin, and no debug-key signing or shipping secrets. What holds it back is
**breadth without depth in three domains** (no PPTX renderer, no encrypted archives, no SAF), **one
policy-shaped permission strategy**, and **one auth defect** — none of which require a rewrite.

It can credibly claim replacement for **file manager and file sharing** after Phase 0 + Phase 1 and a small
amount of Phase 2. **Music and video** are close and would pass with a device-verification pass plus a few
UI toggles. **Document viewing, conversion and archives are the long tail** and need the real work in
Phase 2 before the word "replaces" is honest. 7z/RAR aside, the single highest-value item in this report is
**PPTX rendering**, because a dead-end tap is worse than an explicit "not supported".

