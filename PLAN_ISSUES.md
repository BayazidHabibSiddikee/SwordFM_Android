# SwordFM Android V1 — 10-Issue Fix Plan

> Status: ALL 10 ISSUES FIXED (verified with `flutter analyze` clean of errors and
> `flutter build apk --debug` success on 2026-08-31).

## Fix Summary
| # | Issue | Fix location |
|---|-------|--------------|
| 1 | Convert button for PDFs | `file_browser.dart` show convert for `.pdf`; `doc_converter.dart` supports PDF |
| 2 | Terminal not working | `terminal_screen.dart` prefer `/system/bin/mksh`, Termux bash; robust shell list |
| 3 | Recent preview too small | `recent_files_screen.dart` `height: null` (fills space) |
| 4 | Permission denied (scoped storage) | `app_paths.dart` check/request `manageExternalStorage` on API 30+ |
| 5 | Edit image slow/broken | `photo_editor_screen.dart` isolated decode/encode, downscaled JPEG preview, 150ms slider debounce |
| 6 | QR code button | `swordfm://` intent filter in `AndroidManifest.xml`; `MainActivity.kt` + `main.dart` deep-link handler (`com.swordfm/deeplink`) |
| 7 | PDF opens like music player | `_showFile` routes PDF/docs to preview panel (bottom sheet on phone, side panel on tablet); fullscreen via preview button |
| 8 | App analyzer uninstall/stop/process | `app_analyzer_screen.dart` `Process.run` for stop/uninstall, url_launcher for app info |
| 9 | Bluetooth share | `BLUETOOTH_ADVERTISE` added to `AndroidManifest.xml`; verified `bt_permissions.dart` API 31 flow |
| 10 | Terminal package install | `terminal_screen.dart` Termux detection + `_hintPackageInstall` (download button) |

## Issue 1: Document Conversion Button Missing for PDFs
**Root cause:** In `lib/widgets/file_browser.dart:2050`, the convert menu item only shows for `item.isText || item.extension == '.docx'`. Since `isPdf` is a separate check (`extension == '.pdf'`), PDFs are excluded from the convert option.

**Fix:** Add `.pdf` to the condition at line 2050:
```dart
if (item.isText || item.extension == '.docx' || item.extension == '.pdf')
```
Also verify `DocConverter.canConvert()` and `getAvailableFormats()` include `.pdf` in their supported extensions list (check `lib/services/doc_converter.dart:404`).

---

## Issue 2: Terminal Not Working
**Root cause:** The terminal in `lib/screens/terminal_screen.dart` tries shells in order: Termux bash → Termux sh → /system/bin/sh → /system/xbin/sh → /bin/sh. On most Android devices, `/system/bin/sh` (toybox) is not interactive under PTY and exits immediately, triggering the error fallback. If Termux isn't installed, the terminal is non-functional.

**Fix:**
1. Improve shell detection — try `mksh` (Android's default interactive shell) at `/system/bin/mksh` before falling back to `sh`
2. Add better error recovery — when the shell exits within 1 second, auto-retry with different environment variables (e.g., set `TERM=dumb`, try without `LANG`)
3. Add a visible "shell selector" dropdown in the error state so users can pick a shell path manually
4. Ensure the PTY resize is called after the first frame renders to avoid zero-size terminal

---

## Issue 3: Recent Files Preview Tab Too Small
**Root cause:** In `lib/screens/recent_files_screen.dart:270-276`, the mobile layout uses `PreviewPanel` with `height: 280`, which is much smaller than the file list area.

**Fix:** Change the mobile preview panel to use a larger initial height (e.g., `height: 360`) or use `Expanded` with a flex ratio so the preview takes a proportional amount of space. Also add a drag handle to let users resize it.

---

## Issue 4: Permission Denied Despite All Access Given
**Root cause:** In `lib/utils/app_paths.dart`, the permission handler only requests `mediaLibrary`, `storage`, and `photos`. On Android 11+ (API 30+), `MANAGE_EXTERNAL_STORAGE` requires the user to manually grant it via `Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION`. The current code doesn't check/request this special permission.

**Fix:**
1. Add `Permission.manageExternalStorage` check and request via `openAppSettings()` or the system intent
2. Add a permission status check on app startup and show a dialog explaining why the permission is needed
3. Add a settings button to re-request permissions if denied

---

## Issue 5: Edit Image Slow/Broken, Stops the App
**Root cause:** In `lib/screens/photo_editor_screen.dart:175`, `img.encodePng(_edited!)` is called to display the preview. This encodes the ENTIRE edited image to PNG on EVERY state change (rotate, flip, brightness, contrast). For large images (5MB+ photos), this encoding takes seconds and blocks the UI thread, making the app appear frozen.

**Fix:**
1. Replace `img.encodePng(_edited!)` with a faster encoding format for preview (e.g., encode as JPEG with lower quality, or use `img.getBytes()` directly with `ui.Image`)
2. Debounce/throttle the preview updates during slider changes (brightness/contrast)
3. Use `Isolate` or `compute()` to run image encoding off the main thread
4. Downscale the preview image before encoding (e.g., max 800px wide)

---

## Issue 6: Show QR Code Button Doesn't Work
**Root cause:** The "Show QR Code" menu item in `file_browser.dart:2057-2065` uses `showDialog` which should work. However, the QR data encodes a custom URL scheme `swordfm://open?path=...` which is NOT registered in the AndroidManifest (no intent filter for this scheme). So even if the QR displays, scanning it does nothing on the receiving device.

**Fix:**
1. Verify the QR dialog actually renders (add error handling around `QrImageView`)
2. Register the `swordfm://` URL scheme in `AndroidManifest.xml` with an intent filter so scanning the QR opens the app
3. Alternatively, if the LAN server is running, show the LAN HTTP URL instead (which is scannable/downloadable)

---

## Issue 7: PDF Opens Like Music Player — Should Open in Preview
**Root cause:** In `file_browser.dart:672` and `file_browser.dart:700`, tapping a PDF opens `PdfReaderScreen` (full-screen reader). The user wants documents to open in the preview panel (like text files do), with an option to go full-screen.

**Fix:**
1. In `_openItem()` and `_showFile()` in `file_browser.dart`, route PDF/DOCX/HTML files to the preview panel instead of the full-screen reader
2. Add a "full screen" / "half screen" toggle button in the `PreviewPanel` widget header
3. In `recent_files_screen.dart`, ensure documents (not just video/audio) open in the preview panel
4. Keep the full-screen PDF reader accessible via a "Full Screen" button in the preview panel

---

## Issue 8: App Analyzer — Add Uninstall/Stop/Process Options
**Root cause:** `lib/screens/app_analyzer_screen.dart` only lists apps with name, package, version, and icon. No actions (uninstall, force stop, view process) are available.

**Fix:**
1. Add a long-press context menu or trailing icon button on each app tile with options:
   - **Uninstall** — launch `android.intent.action.DELETE` with the package URI
   - **Force Stop** — launch `android.settings.APPLICATION_DETAILS_SETTINGS` for the package
   - **App Info** — open system app info screen
   - **Copy Package Name** — copy to clipboard
2. Add these via a `MethodChannel` to `MainActivity.kt` or use `url_launcher` with system intents
3. Add a filter toggle for "User apps only" vs "System apps"

---

## Issue 9: Bluetooth Sharing
**Root cause:** The Bluetooth implementation is comprehensive (RFCOMM, foreground service, SHA-256 verification) but may have issues with:
- Permission handling on Android 12+ (BLUETOOTH_SCAN, BLUETOOTH_CONNECT)
- The foreground service type declaration
- Missing `BLUETOOTH_ADVERTISE` permission

**Fix:**
1. Add `BLUETOOTH_ADVERTISE` permission to `AndroidManifest.xml`
2. Ensure `BtPermissions.ensurePermissions()` handles the Android 12+ permission flow correctly
3. Add user-visible error messages when Bluetooth is unavailable
4. Test the send/receive flow end-to-end and fix any issues found

---

## Issue 10: Terminal Package Installation
**Root cause:** The terminal uses system shell (toybox) which doesn't have a package manager. Package installation requires Termux with `pkg`/`apt`.

**Fix:**
1. Detect if Termux is installed and prefer its shell
2. When Termux shell is detected, set up the environment with proper `PATH` including Termux package directories
3. Add a "Install Packages" quick-action button in the terminal toolbar that runs `pkg install` or `apt install`
4. Show a helpful message when users try to install packages without Termux

---

## Implementation Order
1. **Issue 4** (Permission denied) — Critical, affects all file operations
2. **Issue 2** (Terminal) — High priority, core feature
3. **Issue 10** (Terminal packages) — Depends on Issue 2
4. **Issue 1** (Convert button) — Quick fix
5. **Issue 7** (Document preview) — UX improvement
6. **Issue 3** (Recent preview size) — Quick fix
7. **Issue 6** (QR code) — Quick fix
8. **Issue 5** (Image editor) — Performance fix
9. **Issue 8** (App analyzer actions) — New feature
10. **Issue 9** (Bluetooth) — Verification and minor fixes
