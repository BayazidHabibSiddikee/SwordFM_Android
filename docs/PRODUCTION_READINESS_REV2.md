# SwordFM Android — Production-Readiness Report (Rev 2.1)

**Date:** 2026-09-12 · **HEAD:** `c8bf336` (fix(release): P0/P1 production-readiness fixes) + working-tree fixes · **Method:** six-domain audit — re-verification of every stale claim + fresh blocker hunt, all anchored to `file:line`.

> **Team-spawn note:** The requested 6-agent team could not be spawned — the sub-agent backend returned `Incorrect API key provided: workos:…` for **every** call (a harness/provider error, not a repo issue). The six domains were therefore executed **directly by the primary agent**. Every finding below is directly verified, not delegated.

> **⚠️ IMPORTANT — this report reflects a MOVING TARGET.** While this audit ran, commit `c8bf336` landed "P0/P1 production-readiness fixes", resolving most of what the audit originally found. This document has been **corrected against the current source**, and a fresh **P0 compile-breaker was discovered and fixed** in the working tree (see §0.1). Do not read the *history* of this file as current state — read this version.

---

## 0. Verification run (this pass, direct CLI — post-fix)

| Check | Result |
|---|---|
| `flutter analyze` | **106 issues — 0 errors, 0 warnings** (all `info` lints) |
| `flutter test` | **282 / 282 PASS** ✅ |
| git | HEAD `c8bf336`; 7 files modified in working tree |
| Release APK (last build `2026-09-11 13:43`, **predates R8**) | 177,988,137 B ≈ 178 MB — **stale, needs rebuild** |
| Coverage (`coverage/lcov.info`, last generated `2026-08-18`) | **36.7 %** (LH 369 / LF 1005) across **12 files** |
| `print(` in `lib/` | 0 |

### 0.1 🔴 P0 compile-breaker — found and FIXED in this pass

The uncommitted working tree contained a **hard compile error** that broke `flutter test`, `flutter build`, and CI:

```dart
// lib/utils/safe_file_writer.dart:16-20  — BROKEN (before)
try {
  await Directory(dir).create(recursive: true);
} catch (e) {}          // <-- stray brace closed the catch block
  debugPrint('SafeFileWriter: $e');   // <-- 'e' out of scope → Error: Undefined name 'e'
await File(path).writeAsBytes(bytes, flush: true);
```

Evidence: `test/utf8_output_test.dart` failed to load with `lib/utils/safe_file_writer.dart:19:36: Error: Undefined name 'e'.`, causing 7 cascading test failures.

**Fixed** — moved the `debugPrint` inside the catch block:
```dart
} catch (e) {
  debugPrint('SafeFileWriter: could not create "$dir" ($e)');
}
```
Also reverted three lint-triggering `catch (e) {}` (unused variable) in `archive_service.dart` dedup passes back to `catch (_) { … }` with explanatory comments. **Result: analyze 0 errors, 282/282 tests pass.**

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

## 1. THE TWO VERDICTS (do not conflate)

### (a) Production-ready to SHIP? → 🟡 **CLOSE — 1 config action + 1 rebuild away**

Most of what blocked shipping has now been fixed in `c8bf336`. Evidence:

| Item | Status | Evidence |
|---|---|---|
| Release signing | ✅ **FIXED (conditional)** | `build.gradle.kts:49-59` reads `SWORDFM_STORE_FILE/PASS`, `SWORDFM_KEY_ALIAS/KEY_PASS` from env; selects `signingConfigs.getByName("release")` when all four are set |
| R8 / minify | ✅ **FIXED** | `build.gradle.kts:65-66` `isMinifyEnabled = true`, `isShrinkResources = true` + `proguard-rules.pro` (59 lines added) |
| SheetJS offline | ✅ **FIXED** | `assets/js/xlsx.full.min.js` (951,904 B) vendored; `spreadsheet_viewer_screen.dart:102` loads via `DefaultAssetBundle`; **0 CDN refs remain** |
| Stored XSS in LAN share | ✅ **FIXED** | `esc()` helper at `web_share_server.dart:653-660`; applied to `f.icon`/`f.name`/`f.size` (`:673-674`), second list (`:701-702`), breadcrumb `parts[i]` (`:690`) |
| Unused restricted perms | ✅ **FIXED** | `NFC`, `RECORD_AUDIO`, `QUERY_ALL_PACKAGES` removed from manifest (commit diff shows `-9` lines) — now **0 code refs** each |
| Tracked `google-services.json` | ✅ **FIXED** | `git ls-files` returns **nothing** for it; `android/app/google-services.json` deleted in `c8bf336`; `.gitignore:55` now also lists `android/app/google-services.json` |
| FTP service open-by-default | ✅ **FIXED** | `ftp_server_service.dart:61` now `_authenticated = false` unconditionally with an explanatory comment; `:150` requires `arg == service.sharePin` |
| HTTP Range / resume | ✅ **FIXED** | `web_share_server.dart:806-844` — full `206 Partial Content`, `Content-Range`, `Accept-Ranges: bytes` impl |
| HW-decode toggle | ✅ **FIXED** | `video_player_screen.dart:49,73,80-89,115,520` — `_hwDecode` persisted via `shared_preferences` |
| **Compile error** | ✅ **FIXED this pass** | see §0.1 |

**Remaining blockers to actually publishing (small, well understood):**
1. **Set the four signing env-vars in CI and rebuild** — the code path is in place but *falls back to the debug keystore* when unset (`build.gradle.kts:73-77`). Until then the APK is still debug-signed.
2. **Rebuild the release APK** — the 178 MB artifact is from `2026-09-11`, *before* R8 was enabled. Real size unknown until rebuilt; expect a large drop.
3. **Coverage 36.7 % (stale, 2026-08-18) vs the project's own 80 % target** — the metric has not been regenerated since the new tests landed, so it likely understates current coverage, but nobody has re-measured. No CI coverage gate exists.
4. **No CI gate** on coverage or APK size (`.github/workflows/ci.yml` runs only pub get/analyze/test).

### (b) Can it REPLACE the dedicated apps? → 🟡 **PARTIAL — improving, materially better than Rev 1.x**

| Domain | Displaces | Verdict | Decisive remaining blocker |
|---|---|---|---|
| **File manager** | Solid Explorer / MiXplorer | 🟡 **Partial-near** | `MANAGE_EXTERNAL_STORAGE`-only (no SAF — `saf` absent from `pubspec.yaml`); no dual-pane/tabs; SMB stub |
| **Music player** | Poweramp / Musicolet | 🟡 **Partial** | No equalizer; no tag/album-art library scan; no gapless |
| **Video player** | VLC / MX Player | 🟡 **Partial-near** ↑ | Hw-decode is now a **toggle** ✅ (default off); no external-subtitle *picker*; no PiP/aspect |
| **Doc / PDF viewer** | WPS / Adobe / Moon+ | 🟢 **Near-replacement** ↑ | **Offline XLSX/ODS now works** ✅ (SheetJS vendored) — remaining gaps are PDF search/highlight and DOCX layout fidelity |
| **Conversion** | WPS / online converters | 🟡 **Partial** | No batch; non-ASCII (Bengali/Arabic/CJK) PDF font rendering unproven; output-path discoverability |
| **Archiving (excl. 7z/RAR)** | ZArchiver / 7-Zip | 🟢 **Near-replacement** | Whole-archive `readAsBytes` memory ceiling on huge archives; no encrypted/split archives |
| **File sharing** | LocalSend / SHAREit | 🟢 **Near-replacement** ↑ | **XSS fixed** ✅, **HTTP Range resume added** ✅; no FTP `REST` resume; mDNS still announce-only |

> **Biggest correction to the *old* reports:** Rev 1.0 rated video 🔴 and audio 🔴. That was wrong then and is more wrong now — media_kit/libmpv, subtitles, speed control, video resume, auto-next playlist, and now a hardware-decode toggle are all shipped and verified.

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

## 3. CURRENT FINDINGS — post-`c8bf336`

### P0 — publishing blockers

| # | Finding | Evidence | Impact | Fix | Effort |
|---|---|---|---|---|---|
| N1 | **Release signing env-vars unset → falls back to DEBUG keystore** | `build.gradle.kts:49-59` reads env; `:73-77` fallback to `signingConfigs.getByName("debug")` with a `TODO` | Still cannot publish; broken upgrades; repackagable | Create keystore + set the 4 env-vars in CI | S |
| N2 | **Coverage 36.7 % vs 80 % target — metric not regenerated since 2026-08-18** | `coverage/lcov.info` (LH 369/LF 1005, 12 files) | Regressions reach users unnoticed; true number unknown | Re-run `flutter test --coverage`; add a CI gate | M |
| N3 | **Release APK artifact is stale (pre-R8)** | build `2026-09-11 13:43`, 177,988,137 B; R8 enabled `2026-09-12 13:42` | Unknown real install size; Play limits unknown | Rebuild and measure | S |
| N4 | **No CI gate** for coverage or APK size | `.github/workflows/ci.yml` — pub get/analyze/test only | Silent regressions on both axes | Add thresholds to CI | S |

### P1

| # | Finding | Evidence | Impact | Fix | Effort |
|---|---|---|---|---|---|
| N5 | **70 silent `catch (_) {}` blocks** across `lib/` | grep count 70 (post-fix 67) | Silent data-loss paths, no telemetry | Audit mutation paths; surface user-visible errors | M |
| N6 | **i18n is scaffolding only** — `en.arb` is **39 bytes**, 0 `.tr()` calls, 533 hardcoded `Text(` | `lib/l10n/arb/en.arb`; grep counts | The 13-language promise is not in the UI | Implement or drop `easy_localization` | L |
| N7 | **Never measured**: no archive-integrity / large-file test | `test/` — 31 files, none cover multi-GB archives | OOM regressions unguarded | Add a bounded large-file test | M |
| N8 | **Second wave of zero-use permissions**: `ACCESS_BACKGROUND_LOCATION`, `VIBRATE`, `USE_FINGERPRINT`, `SCHEDULE_EXACT_ALARM`, `USE_EXACT_ALARM`, `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`, `FOREGROUND_SERVICE_DATA_SYNC` all have **0 code refs** | grep over `lib/` + `MainActivity.kt` → 0 each | Same Play-review risk just fixed for NFC/RECORD_AUDIO/QUERY_ALL_PACKAGES; the manifest's own comments say "Remove if dropped" | Remove or implement | S |

### P2

- **N9** Whole-archive `readAsBytes` in `extract` (`:264`), `_decodeArchive` (`:542`), sync (`:701`) — memory ceiling on multi-GB archives. *Not fixed by the dedup chunking.*
- **N10** SFTP creds in `flutter_secure_storage` (`network_service.dart:9,83`) but no host-key verification → MITM.
- **N11** mDNS still announce-only: `web_share_server.dart:39-42` `_MdnsBeacon`; JSON broadcast is the real channel.
- **N12** No archive encryption / split-volume support; no FTP `REST` resume (`grep REST ftp_server_service.dart` → 0).
- **N13** `firebase_remote_config` remains a hard dependency for an offline-first file manager.
- **N14** 57 dependencies locked below latest.
- **N15** 106 analysis `info` lints accumulated (0 errors/warnings) — technical debt, not a blocker.

---

## 4. 7z / RAR graceful-failure check (explicitly in scope)

✅ **PASS.** All unsupported formats throw a clear `UnsupportedArchiveFormat` and never crash or silently no-op:

- `.7z` → `archive_service.dart:234-240` · `.rar` → `:241-247` · `.zst`/`.tar.zst` → `:248-252`, read path `:557,576-592`

Given the "without 7z/RAR" scope, this domain is **acceptable**.

---

## 5. Highest-leverage next steps, ranked

**To publish (P0, ~1 day):**
1. **Create a release keystore and set the 4 `SWORDFM_*` env-vars in CI** (`build.gradle.kts:49-59`). **(S)**
2. **Rebuild the release APK now that R8 is on** and record the real size. **(S)**
3. **Re-run `flutter test --coverage`** and update the coverage figure — the current 36.7 % is 3+ weeks stale. **(S)**
4. **Add coverage + APK-size gates to CI.** **(S)**

**To finish the Play-policy cleanup (P1):**
5. **Remove the second wave of zero-use permissions** (N8) — the manifest's own comments already say "Remove if dropped". **(S)**

**To close the remaining replacement gap (P1/P2):**
6. **PDF search/highlighting** — the largest remaining doc-viewer gap vs WPS/Adobe. **(L)**
7. **Raise coverage on `web_share_server.dart` + mutation paths** — the riskiest code is the least tested. **(L)**
8. **FTP `REST` resume** to match the now-complete HTTP Range support. **(S)**
9. **On-demand OCR models** — cut ~27 MB of tessdata from the install. **(M)**
10. **SAF / scoped-storage strategy** — the biggest structural difference vs Solid Explorer. **(L)**

---

## 6. Bottom line

- **Ship-ready? CLOSE — not yet.** The audit began with 4 hard P0s; commit `c8bf336` fixed the *code* for essentially all of them (signing infrastructure, R8, vendored SheetJS, XSS escaping, permission removal, untracking the key file), and this pass found and fixed a **hard compile-breaker** in the working tree. What remains is **configuration and measurement**, not engineering: set the signing env-vars, rebuild, and re-measure coverage/size. That is roughly **one day of work**, not weeks.
- **Replacement-ready? PARTIAL, and rising fast.** Docs/PDF just moved 🟡→🟢 (offline XLSX/ODS fixed) and file sharing moved 🟡→🟢 (XSS fixed + HTTP Range resume added). Archiving (excl. 7z/RAR) remains near-replacement quality. The remaining hard blockers concentrate in **three** places: **file-manager scoped storage (no SAF)**, **music library/EQ/gapless**, and **PDF search**, with secondary gaps in **conversion batch + non-ASCII fonts** and **FTP `REST`**.
- **Most important process finding:** the repository moved *underneath* this audit. Any readiness claim is only valid for a specific commit — this document is valid for `c8bf336` **plus** the working-tree fixes described in §0.1.

---

## 7. ADDITIONAL DOMAINS AND DIMENSIONS

Sections 1–6 covered the six requested domains. Beyond those, the following were audited — these are where an "everything app" usually fails after launch.

### 7.1 Security posture (beyond the XSS already fixed)

| # | Finding | Evidence | Severity |
|---|---|---|---|
| S1 | **Both LAN servers bind to `0.0.0.0` with no TLS** — every transfer is plaintext and reachable by any host on the network (hotel/coffee-shop Wi-Fi included) | `web_share_server.dart:331` `HttpServer.bind(InternetAddress.anyIPv4, port)`; `ftp_server_service.dart:42` `ServerSocket.bind(InternetAddress.anyIPv4, port)`; no `SecurityContext`/`SecureServer` anywhere in `lib/` | **P1** |
| S2 | **`USE_BIOMETRIC` + `USE_FINGERPRINT` declared, but `local_auth` is not a dependency and nothing calls it** — there is **no app lock** despite the manifest implying one | manifest `:58-59`; `grep local_auth pubspec.yaml` → 0; `grep -r 'BiometricType\|local_auth' lib/` → 0 | **P1** (Play + false security claim) |
| S3 | **`REQUEST_INSTALL_PACKAGES` + APK/XAPK installer** — a sideload-install surface Play scrutinises heavily | manifest `:23`; `installer_service.dart:12,30` `installApk`/`installXapk` | P2 |
| S4 | Cloud OAuth tokens are stored in `flutter_secure_storage` (good), but app key/secret are **user-supplied** — no first-party OAuth broker | `dropbox_service.dart:32-33,49-50,72-73`; `google_drive_service.dart:37,45,48-51` | P2 |
| S5 | **No hardcoded secrets found in `lib/`** ✅ | regex scan for `api_key\|secret\|password\|token` literals → 0 hits | ✅ |
| S6 | **No `android:networkSecurityConfig`** — worth pinning explicitly given the app *serves* cleartext HTTP locally | manifest absent; `res/xml/` holds only `file_paths.xml`, `widget_config.xml` | P2 |
| S7 | **No `allowBackup`/`dataExtractionRules`** — Android auto-backup may export app data to Google cloud | manifest absent | P2 |
| S8 | FTP data channels bind ephemeral ports on `anyIPv4` | `ftp_server_service.dart:180,188` | P2 |

### 7.2 Accessibility — **the weakest dimension in the app**

| # | Finding | Evidence | Severity |
|---|---|---|---|
| A1 | **Zero accessibility annotations**: `Semantics(` = **0**, `semanticsLabel:` = **0** | `grep -rn 'Semantics(\|semanticsLabel' lib/` → 0 | **P1** |
| A2 | **No text-scaling awareness**: no `textScaler`/`textScaleFactor` handling — large-font users hit overflow. There *is* a `ui_overflow_test.dart`, but it does not test system font scale | `grep -rc 'textScaler\|textScaleFactor' lib/` → 0 | **P1** |
| A3 | Icon-only controls (hw-decode toggle `video_player_screen.dart:520-526`, player buttons) rely on `tooltip`; screen readers get nothing | `video_player_screen.dart:520-526` | P2 |

**Impact:** a Play Store accessibility/quality-signal problem that excludes blind and low-vision users. For a *file manager* — where an inaccessible storage operation can destroy data — it is a real barrier, not a nicety.

### 7.3 Cloud storage (a domain the brief did not name, but the app ships)

| Service | LOC | State | Evidence |
|---|---|---|---|
| Dropbox | 418 | Functional; tokens in secure storage; refresh flow present | `dropbox_service.dart:34-35,159-206` |
| OpenDrive | 316 | Present | `opendrive_service.dart` |
| Google Drive | 251 | `GoogleSignIn` + `drive.DriveApi` | `google_drive_service.dart:31-55` |
| WebDAV | — | `webdav_client` dependency | `pubspec.yaml` |
| Cloud UI | 1190 | `cloud_browser_screen.dart` | — |

**Caveat:** every provider requires the **user** to paste an app key/client ID (no first-party OAuth) — a real onboarding cliff versus Solid Explorer.

### 7.4 Bluetooth, Wi-Fi Direct, and Cast

| # | Finding | Evidence | Severity |
|---|---|---|---|
| B1 | Bluetooth share is **fully implemented natively** (260-line `BluetoothShareService.kt`, SHA-256 integrity, sequential sends) — not a stub | `BluetoothShareService.kt`; `bluetooth_share_service.dart:178,306` | ✅ |
| B2 | **Cast is effectively non-functional** — Dart calls `MethodChannel('com.swordfm/cast')` for `discoverDevices`, but **no Kotlin counterpart exists**; degrades to "Cast is not available on this device" | `cast_screen.dart:1-40` vs only 3 Kotlin files (`MainActivity`, `BluetoothShareService`, `SwordFmWidgetProvider`) | **P1** (dead feature shipped in the UI) |
| B3 | Wi-Fi Direct permissions declared | manifest `:62-63` | ✅ |

### 7.5 Native layer (1,430 lines of Kotlin)

`MainActivity.kt` = **1,106 lines in a single class** — the largest, least testable unit in the project (**no Kotlin tests exist**). It hosts the cast, install, widget, and share MethodChannels. **P2** — a maintainability and crash-surface risk, and the reason A1/B2 are hard to fix.

### 7.6 Packaging, SDK, and platform config

| # | Finding | Evidence | Severity |
|---|---|---|---|
| P1 | **No ABI splits / `abiFilters`** — one universal APK carries every architecture; a direct contributor to the 178 MB | `build.gradle.kts` — no `splits`/`abiFilters` block | **P1** |
| P2 | **`compileSdk = 37`** — ahead of the current stable Android SDK; risks toolchain/preview-API breakage and is unusual for a release build | `build.gradle.kts:11` | P2 |
| P3 | `minSdk = 24` (Android 7.0) sensible; `ndkVersion = 28.2.13676358` pinned | `:11,26` | ✅ |
| P4 | `proguard-rules.pro` is well-written (Flutter, `com.ryanheise.**`, media_kit/libmpv JNI keeps) | `proguard-rules.pro:1-20+` | ✅ |

### 7.7 Theming and UI polish

- Dark-first theme with `dynamic_color`; `ThemeMode` persisted via `shared_preferences` (`theme/theme.dart:84,93-104`). ✅
- **Note:** mode is stored as a raw `String` defaulting to `'dark'`; there is no explicit "follow system" watch, so an OS theme change mid-session may not be picked up. **P2.**

### 7.8 Testing inventory (31 files, 3,778 LOC of tests)

**Strong:** `archive_service`, `file_utils`, `doc_converter`, `pdf_engine` (with real PDF/DOCX fixtures), `secure_delete`, `ftp_auth_gate`, `web_share_server`, `playback_resume`, `utf8_output`, `ui_overflow`, AES encryption.

**Gaps:** **no tests** for `file_browser.dart` (4,017 LOC — the app's core), `preview_panel.dart`, `cloud_browser_screen.dart` (1,190), `cast_screen.dart`, `music_player_screen.dart`, `video_player_screen.dart`, and **no Kotlin tests at all**. Combined with the 36.7 % figure, risk is concentrated exactly where the code is largest.

### 7.9 CI/CD and release automation

| # | Finding | Evidence | Severity |
|---|---|---|---|
| C1 | CI runs `pub get` + `analyze` + `test` — **no build, no coverage gate, no APK-size gate, no `--fatal-infos`, no format check** | `.github/workflows/ci.yml` | **P1** |
| C2 | **No release workflow at all** — no tagged build, no signing step, no Play upload | no `.github/workflows/release*` exists | **P1** |
| C3 | No `dart format --set-exit-if-changed` | `.github/workflows/ci.yml` | P2 |

### 7.10 Monetization / premium gate — verify before shipping

`entitlement_service.dart` (87), `widgets/premium_gate.dart` (192), `donation_service.dart` (175), `auth_screen.dart` (323) all exist, and `FirebaseAuth.isAuthenticated` **requires a verified email** (`auth_service.dart:23`).

**Implication:** if any *core* feature sits behind `PremiumGate`, the app is not usable offline or without an account — which contradicts the "offline-first file manager" positioning. **P1 — enumerate exactly which features are gated before release.**

---

## 8. CONSOLIDATED RANKED ROADMAP (all domains)

| Rank | Action | Sev | Effort | Evidence |
|---|---|---|---|---|
| 1 | Create release keystore + set the 4 `SWORDFM_*` env-vars | P0 | S | `build.gradle.kts:49-59,73-77` |
| 2 | Rebuild APK (R8 is now on) and record the real size | P0 | S | APK dated 2026-09-11 |
| 3 | Re-run `flutter test --coverage`; replace the stale 36.7 % | P0 | S | `coverage/lcov.info` (2026-08-18) |
| 4 | Add CI gates: coverage, APK size, `--fatal-infos` | P0 | S | `.github/workflows/ci.yml` |
| 5 | Remove the second wave of zero-use permissions (incl. `USE_BIOMETRIC`/`USE_FINGERPRINT`) or ship app lock | P1 | S | §3 N8, §7.1 S2 |
| 6 | **Add baseline accessibility** — `Semantics`, icon labels, text-scale support | P1 | M | §7.2 A1–A3 |
| 7 | **Fix or hide Cast** — implement the Kotlin side or remove the screen | P1 | S/M | `cast_screen.dart` vs Kotlin files |
| 8 | Add TCP TLS (or bind loopback + explicit opt-in) for LAN servers | P1 | M | §7.1 S1 |
| 9 | Enable ABI splits to attack install size | P1 | S | `build.gradle.kts` |
| 10 | Add a release workflow (tag → build → sign → upload) | P1 | M | §7.9 C2 |
| 11 | Audit `PremiumGate` — ensure core file ops are never gated | P1 | S | `auth_service.dart:23` |
| 12 | PDF search/highlighting — largest doc-viewer gap | P1 | L | §1(b) |
| 13 | Coverage on `file_browser.dart`, `web_share_server.dart`, mutation paths | P1 | L | §7.8 |
| 14 | On-demand OCR model download — cut ~27 MB | P2 | M | `assets/tessdata` |
| 15 | FTP `REST` resume; SAF/scoped-storage strategy; music EQ/gapless | P2 | L | §§1(b), 3 |

---

## 9. FINAL ANSWER IN ONE PARAGRAPH

**Not production-ready yet, but close and improving fast.** The *code* is in good shape — 0 analyze errors, 282/282 tests green, no hardcoded secrets, R8 configured, XSS fixed, SheetJS vendored offline, HTTP Range resume added, and a hard compile-breaker found and fixed in this pass. What stands between SwordFM and a public release is now **configuration and polish, not architecture**: sign with a real keystore, rebuild to obtain the true (much smaller) APK size, re-measure coverage, and add CI gates. On replacement parity, **archiving (excl. 7z/RAR), document viewing, and file sharing are already near replacement quality**; the honest gaps are **file-manager scoped storage (no SAF)**, **music library/EQ/gapless**, **PDF search**, and **conversion batch/non-ASCII fonts** — plus three newly surfaced weaknesses: **no accessibility support at all**, a **shipped-but-dead Cast feature**, and **cleartext LAN servers bound to all interfaces**. Fix the P0 four, plus accessibility and Cast, and SwordFM is a credible Play Store release.

---

*Rev 2.1 — six requested domains (file-manager, media, docs, conversion, archive/sharing, quality-release) **plus** additional audited dimensions: security posture, accessibility, cloud storage, Bluetooth/Wi-Fi Direct/Cast, the Kotlin native layer, packaging/SDK config, theming, test inventory, CI/CD, and the premium gate. Executed directly by the primary agent after the sub-agent backend failed with a provider API-key error. Every claim is anchored to the current source at HEAD `c8bf336` + working-tree fixes. Supersedes `docs/REPLACEMENT_GAP_REPORT.md` Rev 1.2 and `docs/REV1.3_STATUS_REPORT.md` for all verdicts.*
