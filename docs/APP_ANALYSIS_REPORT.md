# SwordFM Android — Full App Analysis Report

**Generated**: 2026-08-30  
**Project**: SwordFM (Flutter cross-platform file manager)  
**Repository**: `/home/sword/Documents/android/SwordFM_Android_V1`  
**Version**: 1.0.0+1

---

## 1. Project Overview

| Metric | Value |
|--------|-------|
| Total Dart files | 56 |
| Total lines of code | ~22,134 |
| Test files | 16 |
| Test lines | ~1,789 |
| Test coverage (estimated) | ~8% |
| Production dependencies | 46 packages |
| State management | Minimal (Provider + ValueNotifier) |
| Target platforms | Android, Windows, Linux |

### Tech Stack
- **Framework**: Flutter 3.x (SDK ^3.12.2)
- **Language**: Dart
- **Backend**: Firebase (Auth, Firestore, Remote Config)
- **Native**: Kotlin (MainActivity + Bluetooth/Install services)
- **Theme**: One Dark / Cream dual theme with Material You dynamic colors
- **State**: Mix of `setState`, `ValueNotifier`, and single `ChangeNotifierProvider`

---

## 2. Architecture

```
lib/
├── main.dart              # App entry + MainScreen shell (1086 lines)
├── screens/               # 27 screen widgets
├── services/              # 21 business logic services
├── widgets/               # 4 shared widgets
├── utils/                 # 3 utility modules
├── theme/                 # Theme configuration
└── l10n/                  # Internationalization (ARB files)
```

### Navigation Structure (Bottom Nav — 7 Tabs)

| Index | Tab | Widget | Lines |
|-------|-----|--------|-------|
| 0 | Files | FileBrowser (main) | 3588 |
| 1 | BT | BluetoothScreen | 505 |
| 2 | LAN | LANSharingScreen | 669 |
| 3 | Settings | SettingsScreen | 887 |
| 4 | Storage | StorageAnalysisScreen | 480 |
| 5 | Network | NetworkScreen | 481 |
| 6 | Cloud | CloudBrowserScreen | 1192 |
| 7 | Terminal | TerminalScreen (lazy) | 334 |

> **Note**: Cloud tab was added in recent update. Network tab (WebDAV/SFTP) remains separate.

### Service Dependencies

```
Network/Storage Services:
├── network_service.dart      (535L) — WebDAV + SFTP profiles + AES-encrypted credentials
├── web_share_server.dart     (697L) — HTTP file sharing server with PIN auth
├── ftp_server_service.dart   (349L) — FTP server for LAN transfers
├── bluetooth_share_service.dart (332L) — RFCOMM file transfer
├── google_drive_service.dart  (252L) — Google Drive OAuth2 + REST API
├── dropbox_service.dart       (430L) — Dropbox OAuth2 + REST API (Dio)
├── opendrive_service.dart     (320L) — OpenDrive OAuth2 + REST API
├── search_service.dart        (377L) — Isolate-based background search
└── archive_service.dart       (488L) — ZIP/TAR/GZIP create & extract

Utility Services:
├── doc_converter.dart         (743L) — Markdown ↔ HTML/PDF/DOCX/TXT
├── auth_service.dart          (141L) — Firebase Auth wrapper
├── entitlement_service.dart   (87L)  — Premium state via Firestore
├── donation_service.dart      (175L) — bKash + BNB donation handling
├── installer_service.dart     (88L)  — APK/XAPK PackageInstaller
├── terminal_service.dart      (45L)  — Termux launch via MethodChannel
├── device_service.dart        (63L)  — Android storage volumes
└── bookmark_service.dart      (54L)  — File bookmark persistence
```

---

## 3. Feature Inventory

### ✅ Implemented Features

| Feature | Status | Key Files |
|---------|--------|-----------|
| **File Browser** | Production | `file_browser.dart`, `file_utils.dart` |
| **Archive Support** | Production | `archive_service.dart`, `archive_browser_screen.dart` |
| **Duplicate Finder** | Production | `duplicates_screen.dart`, SHA-256 based |
| **Storage Analysis** | Production | `storage_analysis_screen.dart` |
| **Bluetooth Sharing** | Production | `bluetooth_screen.dart`, `bluetooth_share_service.dart` |
| **LAN Web Share** | Production | `lan_screen.dart`, `web_share_server.dart` |
| **WebDAV Connections** | Production | `network_screen.dart`, `network_service.dart` |
| **SFTP Connections** | Production | `network_screen.dart`, `network_service.dart` |
| **FTP Server** | Production | `ftp_server_screen.dart`, `ftp_server_service.dart` |
| **Google Drive** | Production | `google_drive_service.dart`, cloud browser |
| **Dropbox** | Production | `dropbox_service.dart`, cloud browser |
| **OpenDrive** | New | `opendrive_service.dart`, cloud browser |
| **Document Scanner** | Production | `document_scanner_screen.dart` → PDF |
| **Photo Editor** | Production | `photo_editor_screen.dart` (rotate/flip/brightness/contrast) |
| **PDF Reader** | Production | `pdf_reader_screen.dart` |
| **Music Player** | Production | `music_player_screen.dart` |
| **Video Player** | Production | `video_player_screen.dart` |
| **Terminal** | Production (fallback) | `terminal_screen.dart`, `terminal_service.dart` |
| **QR Scanner** | Production | `qr_scanner_screen.dart` |
| **Folder Graph** | Production | `folder_graph_screen.dart` |
| **Search** | Production (Isolate) | `search_screen.dart`, `search_service.dart` |
| **Notepad** | Production | `notepad_screen.dart` |
| **File Conversion** | Production | `doc_converter.dart`, `convert_dialog.dart` |
| **Home Widget** | Production | `widget_service.dart`, `SwordFmWidgetProvider` |
| **Premium/Donation** | Production | `entitlement_service.dart`, `donation_service.dart` |
| **Auto Theme Schedule** | Production | Settings toggle + schedule check |
| **Material You** | Production | `dynamic_color` package integration |

### ⚠️ Partially Working / Needs Attention

| Feature | Issue | Status |
|---------|-------|--------|
| **Cast/Chromecast** | Native stub returns empty list; no real MediaRouter implementation | Stub only |
| **Terminal (native PTY)** | `flutter_pty` needs `.so` libraries per CPU arch | Requires native libs |
| **Cloud Auto-Reconnect** | Google Drive doesn't persist refresh token (simplified by user) | Sign-in required each launch |
| **App Analyzer** | No app size data (requires system access); uses install timestamp as proxy | Works but limited |
| **OpenDrive OAuth** | Redirect URI `storagesfm://opendrive-callback` needs manifest intent-filter | Not registered |

---

## 4. Security Analysis

### 🔴 Critical Issues

| Issue | Location | Risk |
|-------|----------|------|
| **XOR Obfuscation** | `network_service.dart:40-80` | Passwords XOR'd with AES key — trivially reversible |
| **OAuth Tokens in SharedPreferences** | `dropbox_service.dart`, `opendrive_service.dart` | Access/refresh tokens stored in plain prefs (not secure storage) |
| **No Certificate Pinning** | All HTTP clients | MITM possible on untrusted networks |

### 🟡 Medium Issues

| Issue | Location | Recommendation |
|-------|----------|----------------|
| QR codes expose full URLs | `qr_file_screen.dart` | Consider encoding PIN separately or using short-lived tokens |
| LAN server has weak PIN auth | `web_share_server.dart` | Consider HMAC-based auth instead of cookie-only |
| Firebase config exposed | `google-services.json` committed | Remove from repo; use remote config for non-secret values |

### 🟢 Good Practices

- File uploads/downloads sanitize paths (traversal protection)
- Sensitive ops use `flutter_secure_storage` where appropriate
- LAN share root is configurable (can be set to restricted directory)
- Backup encryption key stored in secure storage

---

## 5. Code Quality Metrics

### Largest Files (Attention Required)

| File | Lines | Complexity | Notes |
|------|-------|------------|-------|
| `widgets/file_browser.dart` | 3588 | Very High | Monolithic — handles browsing, context menus, preview, batch ops, grid/list views |
| `screens/cloud_browser_screen.dart` | 1192 | High | 3 providers × CRUD operations = duplicated logic |
| `main.dart` | 1086 | High | App shell + sidebar + navigation + deep link routing |
| `services/doc_converter.dart` | 743 | Medium | Well-structured, pure-Dart conversions |
| `screens/settings_screen.dart` | 887 | Medium | Long but manageable; consider splitting sections |

### Code Smells

```dart
// 32 debugPrint statements across services — should be routed through a logger
// Mixed state management: setState, ValueNotifier, ChangeNotifier, global vars
// No dependency injection — services instantiated inline in screens
// Google Drive service simplified (removed refresh token persistence)
```

### Test Coverage

| Module | Tests | Status |
|--------|-------|--------|
| Archive service | 319 lines | ✅ Well tested |
| Doc converter | 180 lines | ✅ Well tested |
| UI overflow | 166 lines | ✅ Good |
| Network service | 134 lines | ✅ Covered |
| Search service | 123 lines | ✅ Covered |
| Cloud services | 0 lines | ❌ No tests |
| Terminal | 0 lines | ❌ No tests |
| Photo editor | 0 lines | ❌ No tests |

---

## 6. Known Issues (Post-Fix Status)

| # | Issue | Fixed? | Notes |
|---|-------|--------|-------|
| 1 | Doc scanner save location unclear | ✅ Fixed | Now saves to Downloads/, shows rename dialog |
| 2 | Cast non-functional | ⚠️ Partial | Stub registered; real Chromecast SDK not integrated |
| 3 | App analyzer empty list | ✅ Fixed | Uses `installed_apps` plugin |
| 4 | FTP in wrong place | ✅ Fixed | Moved to LAN tab |
| 5 | Theme override bug | ✅ Fixed | Manual toggle now respected |
| 6 | Grid image overflow | ✅ Fixed | Responsive ConstrainedBox |
| 7 | Terminal crash | ✅ Fixed | Better error handling + Termux fallback |
| 8 | OpenDrive missing | ✅ Fixed | Added with OAuth flow |
| 9 | Photo editor missing | ✅ Was present | Accessible via long-press image |
| 10 | QR codes don't open | ✅ Fixed | URL launching added |
| 11 | PDF conversion hidden | ✅ Verified | Available via file browser context menu |

---

## 7. External Dependencies

### Required Accounts/Credentials

| Service | What's Needed | Where to Get |
|---------|---------------|--------------|
| **Google Drive** | OAuth 2.0 Client ID | [console.cloud.google.com](https://console.cloud.google.com/apis/credentials) |
| **Dropbox** | App Key + Secret | [dropbox.com/developers](https://www.dropbox.com/developers) |
| **OpenDrive** | API Key | [dev.openrazer.com](https://dev.openrazer.com) *(verify endpoint)* |
| **Firebase** | Project config | [firebase.google.com](https://firebase.google.com) |
| **Termux** | App installed | Play Store / F-Droid |

### Android Permissions Declared

```xml
BLUETOOTH, BLUETOOTH_ADMIN, ACCESS_FINE_LOCATION
BLUETOOTH_SCAN, BLUETOOTH_CONNECT
READ_EXTERNAL_STORAGE (maxSdk 32)
READ_MEDIA_IMAGES/VIDEO/AUDIO/FILES
MANAGE_EXTERNAL_STORAGE  ← "All files access"
INTERNET, REQUEST_INSTALL_PACKAGES
ACCESS_NETWORK_STATE
FOREGROUND_SERVICE (×3 types)
POST_NOTIFICATIONS
```

---

## 8. Recommendations

### Immediate (P0)

1. **Move OAuth tokens to `flutter_secure_storage`** — currently in plain SharedPreferences for Dropbox/OpenDrive
2. **Replace XOR obfuscation** in `network_service.dart` with proper AES-GCM encryption
3. **Add OpenDrive manifest intent-filter** for `storagesfm://opendrive-callback`
4. **Add unit tests for cloud services** — zero test coverage on critical path

### Short-term (P1)

5. **Refactor `file_browser.dart`** (3588 lines) — split into smaller widgets
6. **Implement proper cast discovery** — add Google Cast SDK or DIAL library
7. **Bundle `flutter_pty` native libs** — ensure `.so` files included for arm64-v8a
8. **Add error boundaries** — screens crash without graceful fallback

### Long-term (P2)

9. **Introduce BLoC/Cubit** — replace mixed state management pattern
10. **Add integration tests** — E2E flows for file transfer, cloud sync
11. **Implement cloud-to-cloud transfer** — move files between Drive/Dropbox directly
12. **Add biometric lock** — gate sensitive features behind fingerprint/FaceID

---

## 9. Build Configuration

```kotlin
// android/app/build.gradle.kts
namespace = "com.swordfm.swordfm"
compileSdk = 37
minSdk = flutter.minSdkVersion  // ~21
targetSdk = flutter.targetSdkVersion  // ~34
Java 17
```

### Gradle Plugins
- `com.android.application` 9.0.1
- `com.google.gms.google-services` 4.4.2
- Flutter Gradle plugin 1.0.0

---

## 10. File Map Summary

| Category | Count | Total Lines |
|----------|-------|-------------|
| Screens | 27 | ~8,500 |
| Services | 21 | ~5,200 |
| Widgets | 4 | ~1,800 |
| Utils | 3 | ~1,100 |
| Theme | 1 | ~300 |
| Tests | 16 | ~1,800 |
| **Total** | **56** | **~22,134** |

---

*Report generated automatically from codebase analysis.*
