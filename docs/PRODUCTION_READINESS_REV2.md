# SwordFM Android — Production-Readiness Report (Rev 2.0)

**Date:** 2026-09-12 · **HEAD:** f27b23d · **Method:** Option C — six-domain re-verification of every stale claim + fresh blocker hunt, all anchored to file:line.

> **Note on team spawning:** The 6-agent team could not be spawned — the sub-agent backend returned `Incorrect API key provided: workos:...` for all six calls (a provider/infrastructure error, not a repo issue). Rather than stall, all six domains were executed directly with tooling, which means every finding below is directly verified rather than delegated. If you want the team-based runs later, the API key needs fixing first.

---

## 0. Verification run (today, direct CLI)

| Check | Result |
|---|---|
| `flutter analyze` | 107 issues — 0 errors, 0 warnings (all info) |
| `flutter test` | 282 / 282 PASS (Rev1.3 said 199 — suite grew) |
| git | clean tree, master |
| Release APK | 177,988,137 bytes ≈ 178 MB |
| Coverage (`coverage/lcov.info`) | 36.7 % (LH 369 / LF 1005) across only 12 files of ~30,750 LOC |
| `flutter pub outdated` | 57 deps locked older; 14 below resolvable major |
| `print(` in `lib/` | 0 |

---

## 1. THE TWO VERDICTS (kept separate on purpose)

### (a) Production-ready to SHIP? → 🔴 NO — blocked

High-quality code (0 analyze errors, 282 green tests, no hardcoded secrets in `lib/`), but not shippable due to release-engineering gaps unrelated to features:

1. Release APK signed with the **DEBUG keystore** — `android/app/build.gradle.kts:33-38` (`signingConfig = signingConfigs.getByName("debug")`, literal TODO). Can't publish; broken upgrades; APK is repackagable with a public key.
2. **APK = 178 MB**, driven by 27 MB tessdata (`assets/tessdata`, 14 languages) + unchecked native libs, with R8/minify OFF (no `minifyEnabled`/`shrinkResources` in the gradle file).
3. **Coverage 36.7 %** of a 12-file sample vs the project's own 80 % target. Worst: `web_share_server.dart` 3.4 %, `preview_panel.dart` 7.4 %, `bluetooth_share_service.dart` 10.5 %, `file_browser.dart` 20.4 %.
4. **Unused Play-restricted permissions:** NFC (`AndroidManifest.xml:64`), RECORD_AUDIO (`:61`), QUERY_ALL_PACKAGES (`:48`) — grep across `lib/` and `MainActivity.kt` returns zero usage.

### (b) Can it REPLACE the dedicated apps? → 🟡 PARTIAL — better than every prior report claims

| Domain | Replaces | Verdict | Decisive remaining blocker |
|---|---|---|---|
| File manager | Solid Explorer / MiXplorer | 🟡 Partial-near | MANAGE_EXTERNAL_STORAGE-only (no SAF); no dual-pane/tabs; SMB stub |
| Music player | Poweramp / Musicolet | 🟡 Partial | No EQ; no tag/album-art library scan; no gapless |
| Video player | VLC / MX Player | 🟡 Partial-near ↑ | Hw-decode hardcoded OFF (`video_player_screen.dart:80`); no external-subtitle picker; no PiP/aspect |
| Doc / PDF viewer | WPS / Adobe / Moon+ | 🟡 Partial | XLSX/ODS need the SheetJS CDN → fail offline (`spreadsheet_viewer_screen.dart:179`) |
| Conversion | WPS / online converters | 🟡 Partial | No batch; non-ASCII (Bengali/Arabic/CJK) PDF fonts unproven; output-path discoverability |
| Archiving (excl. 7z/RAR) | ZArchiver / 7-Zip | 🟢 Near-replacement | Whole-archive `readAsBytes` memory ceiling; no encrypted/split archives |
| File sharing | LocalSend / SHAREit | 🟡 Partial (near) ↑ | Stored XSS in the LAN share page (P1); no Range/REST resume |

> **Biggest correction:** Rev 1.0 rated video 🔴 and audio 🔴. That is now wrong — media_kit/libmpv shipped, subtitles work, speed control works, video resume is implemented, and auto-next playlist is genuinely wired.

---

## 2. STALE-CLAIM RE-VERIFICATION (the Option-C core)

| # | Prior claim | Verdict | Evidence |
|---|---|---|---|
| 1 | FTP auth "parsed-but-unenforced" | ✅ FIXED | `ftp_server_service.dart:141-142, :148-152` |
| 2 | `Random()` not `Random.secure()` | ✅ FIXED | `web_share_server.dart:301, :408` |
| 3 | No auth rate-limit | ✅ FIXED | `web_share_server.dart:453` |
| 4 | Upload-500 leaks `$e` | ✅ FIXED | `web_share_server.dart:371` |
| 5 | Dedup Pass-3 OOM | ✅ FIXED | `archive_service.dart:19-55` chunked SHA-256 |
| 6 | `extractEntry` no ZipSlip guard | ✅ FIXED | `archive_service.dart:509-520` |
| 7 | "Playlist / auto-next is DEAD" | ✅ FIXED | `file_browser.dart:772,809`; `search_screen.dart:165,187`; `recent_files_screen.dart:294,315` |
| 8 | "No video resume" | ✅ FIXED | `video_player_screen.dart:94,104,109,132,154,177,202,212` |
| 9 | `codeUnits` corrupts non-ASCII | ✅ FIXED | no `codeUnits` left; all `utf8.encode` (`:81,143,156,323,405,776`) |
| 10 | "MD vs Markdown" contract break | ✅ FIXED | `doc_converter.dart:1044` |
| 11 | 5 dead-code warnings in video player | ✅ FIXED | 0 warnings now |
| 12 | No speed/sleep/shuffle/repeat (audio) | ✅ FIXED | `music_player_screen.dart:36-40,140-142,153-220` |
| 13 | ExoPlayer codec ceiling | ✅ OBSOLETE | now media_kit/libmpv (`pubspec.yaml:45-47`) |
| 14 | No subtitle support | ✅ FIXED | `video_player_screen.dart:318-358,469-479` |
| 15 | Spreadsheets → external app | ✅ FIXED | `file_utils.dart:513-515` |
| 16 | PPTX falls through | ✅ FIXED | `file_utils.dart:336,494,508` + router |
| 17 | "no real root" | ✅ OK | gated by `FileUtils.isRooted` (`settings_screen.dart:371-383`) |
| 18 | secure delete | ✅ CONFIRMED | `file_utils.dart:1098`, `file_browser.dart:2503` |
| 19 | XLSX/ODS fail offline (CDN) | ❌ STILL OPEN | `spreadsheet_viewer_screen.dart:179,183` |
| 20 | No Range/REST resume | ❌ STILL OPEN | grep → 0 hits in both servers |
| 21 | mDNS announce-only | ❌ STILL OPEN | `web_share_server.dart:39-42` |
| 22 | SMB stub | ❌ STILL OPEN | `network_service.dart` |
| 23 | No archive encryption/split | ❌ STILL OPEN | `archive_service.dart` |
| 24 | FTP empty-PIN default | ⚠️ SPLIT | Rev1.4 right for UI (`lan_screen.dart:190-197`); but service still `_authenticated = sharePin.isEmpty` (`ftp_server_service.dart:59`) |
| 25 | Hw-decode hardcoded OFF | ❌ STILL OPEN | `video_player_screen.dart:80` |
| 26 | No aspect/PiP/multi-audio | ⚠️ PARTIAL | subs+speed+audio-track shipped; aspect/PiP absent (`:18`) |
| 27 | SAF removed, strategy undecided | ❌ STILL OPEN | saf absent from `pubspec.yaml` |
| 28 | 27 MB tessdata | ✅ CONFIRMED | `du -sh assets/tessdata = 27 M` |

**18 of 28 prior findings are FIXED/OBSOLETE; 9 open; 1 partial.**

---

## 3. NEW FINDINGS — never in any prior doc

### P0 — ship blockers

| # | Finding | Evidence | Impact |
|---|---|---|---|
| N1 | Release signed with debug keystore | `build.gradle.kts:33-38` | Can't publish; broken upgrades; repackagable |
| N2 | APK 178 MB | apk 177,988,137 B; tessdata 27 M | Play limits, retention |
| N3 | Coverage 36.7 % of a 12-file sample (target 80 %) | `coverage/lcov.info` | Regressions reach users |
| N4 | Unused restricted perms | NFC `:64`, RECORD_AUDIO `:61`, QUERY_ALL_PACKAGES `:48` — grep → 0 hits | Play rejection; privacy |

### P1

| # | Finding | Evidence | Impact |
|---|---|---|---|
| N5 | Stored XSS in LAN share page — raw `f.name`/`f.icon`/`f.size` and `parts[i]` concatenated into `innerHTML`; only the `href` is `encodeURIComponent`'d | `web_share_server.dart:661-666, :690-695`, breadcrumb `:678` | A file named `<img src=x onerror=...>` runs script in the browser of anyone who opens the share, same origin as the session cookie |
| N6 | `google-services.json` gitignored yet **tracked**, plus a root duplicate | `.gitignore` lists it; `git ls-files` → `android/app/google-services.json`; both files present, contain `"api_key"` | Policy violation; key in history |
| N7 | FTP service open-by-default if driven directly | `ftp_server_service.dart:59` | UI guards it, service doesn't |
| N8 | 70 silent `catch (_) {}` blocks | grep count 70 (incl. `file_utils.dart`, `archive_service.dart`, `safe_file_writer.dart`) | Silent data-loss paths |
| N9 | `minifyEnabled`/`shrinkResources` absent | `build.gradle.kts:32-38` | Inflated APK, easy RE |
| N10 | i18n is scaffolding only — `en.arb` is 39 bytes, 0 `.tr()` calls, 533 hardcoded `Text(` | `lib/l10n/arb/en.arb` | 13-language promise not in UI |

### P2

- **N11** Whole-archive `readAsBytes` in `extract` `:264`, `_decodeArchive` `:542`, sync `:701` — the dedup fix didn't cover decode (memory ceiling on multi-GB archives).
- **N12** `video_thumbnail` is used (`file_browser.dart:15,3024,3947-3963`) — old "never used" note is wrong.
- **N13** SFTP creds in `flutter_secure_storage` (`network_service.dart:9,83`) but no host-key verification → MITM.
- **N14** Firebase init is `try/catch`-guarded (`main.dart:56-58`, good) but `firebase_remote_config` is a hard dep for an offline-first app.
- **N15** 57 deps locked older; 14 below resolvable major.
- **N16** CI (`ci.yml`) runs only pub get/analyze/test — no coverage or APK-size gate.

---

## 4. 7z / RAR graceful-failure check (explicitly in scope)

✅ **PASS.** All unsupported formats throw a clear `UnsupportedArchiveFormat` and never crash or silently no-op:

- `.7z` → `archive_service.dart:234-240` · `.rar` → `:241-247` · `.zst`/`.tar.zst` → `:248-252`, read path `:557,576-592`

Given the "without 7z/RAR" scope, this domain is acceptable.

---

## 5. Highest-leverage fixes, ranked

### Before any public release (P0, ~1–2 days total):

1. Real release keystore (`build.gradle.kts:36`) — **S**
2. Remove NFC / RECORD_AUDIO / QUERY_ALL_PACKAGES — **S**
3. HTML-escape the LAN share page (`web_share_server.dart:663,678,692`) — **S**
4. `git rm --cached android/app/google-services.json` + rotate key + drop root duplicate — **S**
5. Enable R8/minify + `shrinkResources` — **S**

### Then to close the "replacement" gap (P1):

6. Vendor SheetJS locally — the single biggest doc-viewer blocker — **M**
7. On-demand OCR models — cuts ~27 MB — **M**
8. Service-level FTP PIN requirement (`:59`) — **S**
9. Hardware-decode toggle (`video_player_screen.dart:80`) — **S**
10. Coverage on `web_share_server.dart` (3.4 %) + mutation paths — **L**

---

## 6. Bottom line

- **Ship-ready? NO** — but only ~5 small, well-understood release-engineering items (debug signing, 178 MB, unused restricted perms, tracked key file, R8 off). No architectural work needed; a focused day or two clears P0.
- **Replacement-ready? PARTIAL**, and materially better than documented. Archiving (excl. 7z/RAR) is near-replacement quality. Video/audio are far closer than the old 🔴 verdicts — media_kit migration, subtitles, resume, and playlist wiring all landed and are verified. Blockers concentrate in exactly two places: offline XLSX/ODS and test coverage, with secondary gaps in scoped storage (no SAF) and sharing resume (no Range/REST).
- **Most urgent unreported issues:** the stored XSS in the LAN share page and the debug-signed release.
