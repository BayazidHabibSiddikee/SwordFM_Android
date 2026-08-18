# SwordFM — Android (Flutter)

A cross-platform file manager built with Flutter, recreating the C++/Qt6 **SwordFM** Linux application for Android (with Windows and Linux support planned).

---

## 🚀 Features (Completed)

### File Management
- **Details + Icon Views** — Toggle between list and grid layouts (`Ctrl+1` / `Ctrl+2` equivalent)
- **Unified Sidebar** — Quick access to Home, Desktop, Documents, Downloads, Trash, Pictures, Music, Videos
- **Bookmarks** — Add and manage custom bookmarks (persisted in-memory; SharedPreferences integration ready)
- **Collapsible Preview Panel** — Live preview for code (syntax-aware), markdown (formatted rendering), images (scalable), and text files
- **File Operations** — Copy, Cut, Paste, Rename, Delete (with confirmation dialog), Properties
- **Multi-select** — Long-press to select multiple files
- **Hidden Files Toggle** — Show/hide dotfiles
- **Sort Options** — Sort by Name, Size, Date, Type (ascending/descending)
- **Breadcrumb Navigation** — Tap any path segment to jump directly

### Wireless Sharing
- **LAN Web Sharing** — Pure Dart HTTP server with QR code generation, PIN-gated session auth (cookie-based), path-traversal-safe uploads/downloads, streaming I/O, configurable share root, and client IP access log
- **Bluetooth File Sharing** — RFCOMM socket connection to paired devices; binary protocol: `[8-byte length][4-byte filename length][filename][raw bytes]`

### UI
- **One Dark Theme** — Exact color match with the Linux version (cyan `#61AFEF`, green `#98C379`, amber `#E5C07B`, red `#E06C75`, purple `#C678DD`)
- **Bottom Navigation** — Files | Bluetooth | LAN | Settings tabs

---

## 📁 Project Structure

```
lib/
├── main.dart                          # App entry point, MainScreen layout
├── theme/
│   └── theme.dart                     # One Dark theme definition
├── utils/
│   ├── constants.dart                 # AppPaths (Home, Desktop, Downloads, etc.)
│   └── file_utils.dart                # FileItem model + FileUtils CRUD operations
├── services/
│   ├── bluetooth_share_service.dart   # Native channel bridge for BT RFCOMM
│   └── web_share_server.dart          # In-app HTTP server for LAN sharing
├── screens/
│   ├── bluetooth_screen.dart          # BT pairing & transfer UI
│   ├── lan_screen.dart               # LAN server controls + QR display
│   ├── qr_scanner_screen.dart        # Camera-based QR code scanner
│   └── settings_screen.dart          # App settings
└── widgets/
    ├── file_browser.dart              # Full file browser (grid/list/views)
    └── preview_panel.dart             # Collapsible right-side preview panel

android/app/src/main/kotlin/com/swordfm/swordfm/
└── MainActivity.kt                    # Kotlin platform channel (RFCOMM BT sockets)
```

---

## 🛠️ Build & Setup

### Prerequisites
- Flutter SDK 3.12+ (stable channel)
- Android SDK (API 21+ / minSdkVersion 21)
- Java 17+
- A physical Android device with Bluetooth (for BT testing)

### Run the App
```bash
# Install dependencies
flutter pub get

# Run on connected device
flutter run

# Build release APK
flutter build apk --release

# Build app bundle for Play Store
flutter build appbundle --release
```

### Permissions Required
The app declares the following permissions in `AndroidManifest.xml`:
- `BLUETOOTH` / `BLUETOOTH_ADMIN` — Classic BT communication
- `BLUETOOTH_SCAN` / `BLUETOOTH_CONNECT` / `BLUETOOTH_ADVERTISE` — Android 12+ BT APIs
- `ACCESS_FINE_LOCATION` — Required for BT discovery on Android
- `READ_EXTERNAL_STORAGE` (≤API 32) / `READ_MEDIA_*` (API 33+) — File access
- `MANAGE_EXTERNAL_STORAGE` — Full filesystem access for sharing
- `FOREGROUND_SERVICE` + `FOREGROUND_SERVICE_BLUETOOTH` — Continuous BT listening
- `POST_NOTIFICATIONS` — Notification for foreground service (Android 13+)

---

## 🔄 Protocol (Bluetooth)

File transfers use an RFCOMM frame format compatible with the Linux `swordblue` tool.
Both Android (`MainActivity.kt`) and Linux sides share this exact layout:

```
[4-byte uint32 metadataLength]  (big-endian)
[metadataLength bytes of JSON]  {"filename": "example.pdf", "size": 12345}
[raw file bytes — exactly "size" bytes]
```

Sender writes: 4B length → JSON → raw bytes
Receiver reads: 4B length → parse JSON → read "size" bytes
Both sides use a 64 KB buffer; progress updates are sent at ≤10 Hz via the method channel.

**Note:** The Android side uses the standard SerialPort UUID (`00001101-0000-1000-8000-00805F9B34FB`)
for Bluetooth RFCOMM interop with `swordblue` on Linux.

---

## 📊 Test Coverage

| Module | Tests | Status |
|--------|-------|--------|
| FileItem (properties) | 12 | ✅ |
| FileUtils (CRUD ops) | 11 | ✅ |
| WebShareServer (unit) | 22 | ✅ |
| DocConverter | 22 | ✅ |
| App integration | 6 | ✅ |
| **Total** | **73** | **100% pass** |

Run tests:
```bash
flutter test
```

---

## 🔗 Roadmap (From plan.md)

| Phase | Feature | Status |
|-------|---------|--------|
| Phase 1 | Foundation & UI Layout | ✅ Complete |
| Phase 2 | Native File System CRUD | ✅ Complete |
| Phase 3 | LAN Web Sharing | ✅ Complete |
| Phase 4 | Bluetooth File Sharing | ✅ Complete |
| Phase 5 | Folder Graph & Document Conversion | 🔄 Planned |

---

## 🐧 Relation to Linux Version

This Flutter project is a direct recreation of **[SwordFM](https://github.com/BayazidHabibSiddikee/SwordFM)** (C++/Qt6 for Linux). Feature parity target:

| Feature | Linux (C++/Qt6) | Android (Flutter) |
|---------|----------------|-------------------|
| File browser (grid/list) | ✅ | ✅ |
| Preview panel (code/markdown/images) | ✅ | ✅ |
| LAN sharing (swordshare) | Python server | Pure Dart HttpServer |
| Bluetooth sharing (swordblue) | BlueZ/RFCOMM Python | Kotlin RFCOMM sockets |
| One Dark theme | ✅ | ✅ |
| Folder graph (swordgraph) | ✅ (Graphviz) | 🔄 Phase 5 |
| Doc conversion (swordconv) | ✅ (pymupdf/mammoth) | 🔄 Phase 5 |
| Keyboard shortcuts | ✅ (F2/F4/Ctrl+C etc.) | 🔄 Touch-first UI |

---

## 📄 License

MIT
