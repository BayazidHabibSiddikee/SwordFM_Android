# SwordFM Cross-Platform

A recreation of the C++/Qt6 file manager **SwordFM** built using Flutter. This version runs natively on **Windows**, **Android**, and **Linux** from a single codebase, bringing modern file management, premium One Dark aesthetics, and wireless sharing features to all devices.

## 🚀 Key Features

*   **Details + Icon Views**: Toggleable grid/list views for files and folders.
*   **Unified Sidebar**: Quick access to Home, Desktop, Downloads, Trash, and customizable Bookmarks.
*   **Collapsible Preview Panel**: Live preview for code (with syntax highlighting), markdown (formatted rendering), images (scalable), and text files.
*   **LAN Web Sharing**: An in-app server that generates a QR code and password. Scanners on the LAN can browse, download, and upload files via a clean web UI (no Python or external server setup required!).
*   **Bluetooth File Sharing**: Connect your Windows and Android devices directly over Bluetooth for seamless, offline peer-to-peer file transfers.
*   **Interactive Folder Graph**: A native interactive graph visualization of folder hierarchies.

---

## 🛠️ Build and Setup

### Dependencies
Ensure you have the Flutter SDK installed on your machine.
- Flutter SDK (stable channel recommended)
- Android SDK (for building APKs)
- Native build tools (MSBuild/C++ tools for Windows; gcc/cmake/pkg-config/libgtk-3-dev for Linux)

### Run the App

#### Linux (development environment)
```bash
flutter run -d linux
```

#### Android (run on connected device)
```bash
flutter run -d android
```

#### Windows
To build and run on a Windows machine:
```cmd
flutter run -d windows
```

### Build Release Artifacts

*   **Android APK**: `flutter build apk --release`
*   **Linux executable**: `flutter build linux --release`
*   **Windows executable**: `flutter build windows --release` (must be executed on Windows)
