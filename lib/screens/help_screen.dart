import 'package:flutter/material.dart';
import '../theme/theme.dart';

/// In-app user guide. Explains how the main features work — with extra depth
/// on Cloud Storage, where the provider setup (Google Cloud Console client
/// IDs, Dropbox app keys, …) is not obvious without documentation.
class HelpScreen extends StatelessWidget {
  const HelpScreen({super.key});

  static const List<_HelpSection> _sections = [
    _HelpSection(
      title: 'Files & Preview',
      icon: Icons.folder_open,
      entries: [
        _HelpEntry(
          q: 'Browsing and opening files',
          a: 'Tap a file to select it — its details and a preview appear in '
              'the side panel. PDF, DOCX, images, video, audio, text, code '
              'and Markdown files preview right in the app. Double-tap (or '
              'use the expand icon in the panel header) to open the '
              'full-screen reader with pinch-to-zoom.\n\n'
              'Large PDFs render page-by-page on demand, so the first page '
              'appears immediately even for big documents.',
        ),
        _HelpEntry(
          q: '"Open with…" vs the built-in readers',
          a: 'The panel header has both a full-screen button and an '
              '"Open with…" action. Built-in readers are used for PDF, '
              'DOCX, video and archives; "Open with…" always hands the file '
              'to another Android app you have installed.',
        ),
      ],
    ),
    _HelpSection(
      title: 'Archives (ZIP, TAR, 7z, RAR…)',
      icon: Icons.archive,
      entries: [
        _HelpEntry(
          q: 'Extracting an archive',
          a: 'Select an archive and press Extract in the preview panel. '
              'Contents are unpacked into a folder named after the archive, '
              'right next to it. Press "Browse contents" to look inside '
              'without extracting everything.\n\n'
              'ZIP and TAR family archives (including .tar.gz / .tar.xz / '
              '.tar.bz2) extract fully in-app. 7z, RAR and Zstandard are '
              'detected and browsable, but extracting them needs an external '
              'tool because their formats are proprietary.',
        ),
        _HelpEntry(
          q: 'Browsing inside an archive',
          a: 'The archive browser lists the archive like a normal folder. '
              'Tap a file to extract just that entry to a temp folder and '
              'open it; long-press for options, including extracting next to '
              'the archive. "Extract All" unpacks everything at once.',
        ),
      ],
    ),
    _HelpSection(
      title: 'Notepad',
      icon: Icons.sticky_note_2,
      entries: [
        _HelpEntry(
          q: 'Saving as any file type',
          a: 'Notepad saves plain text, so it can write any text-based '
              'format — .txt, .md, .json, .yaml, .csv, .ini, config files, '
              'source code (.py, .dart, .java, .c, …), even files with no '
              'extension at all (like a shell script named "install").\n\n'
              'In Save As, type the name, then pick an extension chip or '
              'type any extension you want. If the file was opened from an '
              'existing file, Save keeps its original name and type.',
        ),
        _HelpEntry(
          q: 'Where files are saved',
          a: 'New documents go to the last folder you used (or Documents on '
              'first run). Use Save As to choose a different folder, '
              'including any custom directory via the folder picker. If a '
              'location is not writable (Android scoped storage), SwiftFM '
              'falls back to its own Downloads folder so your text is never '
              'lost.',
        ),
      ],
    ),
    _HelpSection(
      title: 'Scanner & OCR (text recognition)',
      icon: Icons.document_scanner,
      entries: [
        _HelpEntry(
          q: 'Scanning pages into a PDF',
          a: 'Open Scanner from the sidebar Tools section or Settings. '
              'Capture pages with the camera or pick images from the '
              'gallery, reorder or remove pages, then press the PDF button '
              'to build a single PDF. Pages are stored at high quality.',
        ),
        _HelpEntry(
          q: 'Recognising text in images (OCR)',
          a: 'OCR runs entirely on your device with the bundled Tesseract '
              'engine — no internet needed and images never leave the '
              'phone. Open an image and press "Extract text" (or use OCR '
              'inside the Scanner on any page). Recognised text can be '
              'copied to the clipboard, opened in Notepad, or saved as a '
              '.txt file.\n\n'
              'English is bundled. More languages (e.g. hin, ara, spa) can '
              'be added by placing their .traineddata file in the app\'s '
              'documents/tessdata folder — download them from the Tesseract '
              'tessdata_fast repository on GitHub.',
        ),
      ],
    ),
  ];

  static final _HelpSection _cloudSection = const _HelpSection(
    title: 'Cloud Storage',
    icon: Icons.cloud,
    initiallyExpanded: true,
    entries: [
      _HelpEntry(
        q: 'How cloud works in SwiftFM',
        a: 'Settings ▸ Cloud Storage opens the cloud browser. Pick a provider '
            'tab, connect once, and the provider\'s files appear side by side '
            'with your local storage: browse folders, upload, download, '
            'rename and delete. SwiftFM talks to the provider directly from '
            'your device — there is no SwiftFM server in between.',
      ),
      _HelpEntry(
        q: 'Google Drive — getting a Client ID',
        a: 'SwiftFM uses Google\'s installed-app OAuth flow, so you bring '
            'your own credentials:\n'
            '1. Go to console.cloud.google.com and create (or pick) a '
            'project.\n'
            '2. APIs & Services ▸ Library → enable "Google Drive API".\n'
            '3. APIs & Services ▸ OAuth consent screen → External, fill the '
            'app name and your e-mail, add the scope '
            'https://www.googleapis.com/auth/drive, and add yourself as a '
            'test user while the app is in Testing.\n'
            '4. APIs & Services ▸ Credentials ▸ Create credentials ▸ OAuth '
            'client ID ▸ Application type: Android. Package name: '
            'com.swordfm.swordfm. Add the SHA-1 fingerprint of your signing '
            'key (debug or release).\n'
            '5. Copy the Client ID (it ends with .apps.googleusercontent.com) '
            'into SwiftFM\'s Google Drive tab and connect.',
      ),
      _HelpEntry(
        q: 'Dropbox — getting an App Key',
        a: '1. Create an app at www.dropbox.com/developers/apps with the '
            '"Scoped access" / "App folder" or "Full Dropbox" permission.\n'
            '2. On the app\'s Settings page, under "Redirect URIs", add: '
            'storagesfm://dropbox-callback\n'
            '3. Enable the files.content.read / files.content.write scopes '
            'on the Permissions tab, then Submit.\n'
            '4. Copy the App key (and App secret) from Settings into '
            'SwiftFM\'s Dropbox tab and connect. Sign-in happens in a browser '
            'window and returns to the app automatically.',
      ),
      _HelpEntry(
        q: 'OpenDrive / WebDAV / FTP',
        a: 'OpenDrive connects with the API key from your account settings. '
            'Plain servers (FTP, FTPS, SFTP, WebDAV, SMB) are configured in '
            'the Network tab instead — see the Network section of the app. '
            'rclone users can mount nearly any cloud provider via '
            'Settings ▸ rclone Cloud Mounts (requires Termux).',
      ),
      _HelpEntry(
        q: 'Tokens, security and signing out',
        a: 'Access tokens are stored only in the app\'s private storage on '
            'your device and are refreshed automatically when they expire. '
            'Disconnect (Sign out) inside the cloud browser deletes them. '
            'If a connect attempt fails, double-check the client ID / app '
            'key, the redirect URI spelling, and that your account was added '
            'as a test user while the OAuth app is unpublished.',
      ),
    ],
  );

  static const _HelpSection _privacySection = _HelpSection(
    title: 'Privacy — how your data is handled',
    icon: Icons.privacy_tip,
    entries: [
      _HelpEntry(
        q: 'Your files stay yours',
        a: 'SwiftFM never reads, copies, uploads or analyses your files on '
            'any SwiftFM-side server — there is no such server. File '
            'operations happen locally on the device, or directly between '
            'the device and the cloud provider / network server you chose to '
            'connect to.',
      ),
      _HelpEntry(
        q: 'What does leave the device',
        a: 'Only what is strictly needed to sign you in: your e-mail '
            'address when you sign in with Firebase (used for your account '
            'and premium entitlements), the tokens issued by the cloud '
            'providers you connect to, and standard Firebase Remote Config '
            'fetches. Nothing else.',
      ),
      _HelpEntry(
        q: 'OCR and scanning',
        a: 'Text recognition runs entirely on the device using the bundled '
            'Tesseract engine. Scanned pages and recognised text are stored '
            'only where you choose to save them.',
      ),
    ],
  );

  static const _HelpSection _troubleshootingSection = _HelpSection(
    title: 'Troubleshooting',
    icon: Icons.build,
    entries: [
      _HelpEntry(
        q: 'PDF opens slowly or seems stuck',
        a: 'Pages render on demand, so the reader should open instantly. If '
            'a specific page shows "Rendering page…", wait a moment — '
            'complex pages take longer on low-end devices. If the whole file '
            'fails, the PDF may be encrypted or damaged.',
      ),
      _HelpEntry(
        q: 'App Analyzer is slow the first time',
        a: 'Loading every installed app (including system apps, with icons) '
            'takes a few seconds on the first open — icons alone mean '
            'decoding hundreds of images. Later opens are faster.',
      ),
      _HelpEntry(
        q: 'Cloud connect fails',
        a: 'Re-check the client ID / app key and redirect URI (they must '
            'match exactly), confirm you are a test user on the provider\'s '
            'OAuth console, and make sure the app is signed with the same '
            'key whose SHA-1 you registered for Google Drive.',
      ),
      _HelpEntry(
        q: 'OCR finds little text',
        a: 'Tesseract works best on sharp, evenly-lit, straight-on photos. '
            'Try the "Single line" or "Single word" mode for tricky layouts '
            '(see the OCR mode picker), and use tessdata_best models for '
            'maximum accuracy.',
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: OneDarkColors.bg,
      appBar: AppBar(
        title: Text('Help & How-To',
            style: TextStyle(color: OneDarkColors.fg, fontSize: 16)),
        backgroundColor: OneDarkColors.bgDark,
        foregroundColor: OneDarkColors.fg,
        iconTheme: IconThemeData(color: OneDarkColors.fg),
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          for (final section in _sections) _sectionCard(context, section),
          _sectionCard(context, _cloudSection),
          _sectionCard(context, _privacySection),
          _sectionCard(context, _troubleshootingSection),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _sectionCard(BuildContext context, _HelpSection section) {
    return Card(
      color: OneDarkColors.bgDark,
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: OneDarkColors.dim.withValues(alpha: 0.4)),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: section.initiallyExpanded,
          iconColor: OneDarkColors.cyan,
          collapsedIconColor: OneDarkColors.fgDim,
          leading: Icon(section.icon, color: OneDarkColors.amber, size: 20),
          title: Text(
            section.title,
            style: TextStyle(
              color: OneDarkColors.fg,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          children: [
            for (final entry in section.entries) ...[
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.only(top: 8, bottom: 4),
                  child: Text(
                    entry.q,
                    style: TextStyle(
                      color: OneDarkColors.cyan,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  entry.a,
                  style: TextStyle(
                    color: OneDarkColors.fgDim,
                    fontSize: 12.5,
                    height: 1.45,
                  ),
                ),
              ),
              const SizedBox(height: 6),
            ],
          ],
        ),
      ),
    );
  }
}

class _HelpSection {
  final String title;
  final IconData icon;
  final List<_HelpEntry> entries;
  final bool initiallyExpanded;
  const _HelpSection({
    required this.title,
    required this.icon,
    required this.entries,
    this.initiallyExpanded = false,
  });
}

class _HelpEntry {
  final String q;
  final String a;
  const _HelpEntry({required this.q, required this.a});
}
