# Project Path: /home/sword/Documents/android/SwordFM_Android_V1

## Android App (Flutter)
- `lib/main.dart`: Main entry point, One Dark Theme, Bottom Navigation.
- `lib/services/web_share_server.dart`: LAN HTTP server for Wi-Fi sharing.
- `android/app/src/main/kotlin/com/swordfm/MainActivity.kt`: Kotlin platform channel for RFCOMM Bluetooth sockets.
- `android/app/src/main/AndroidManifest.xml`: Permissions for Bluetooth Classic (Android 12+).

## Linux Host Bridge
- `/home/sword/SwordFM/tools/swordblue`: Python helper using BlueZ/RFCOMM sockets for file transfer.
- `/home/sword/SwordFM/src/ops/shareops.cpp`: (Integration point) Spawns `swordblue` and reads status JSON from stdout.

## Protocol (RFCOMM)
- Frame Format: `[4-byte Metadata Length] [JSON Metadata] [Raw File Bytes]`
- Metadata: `{"filename": "example.pdf", "size": 12345}`
