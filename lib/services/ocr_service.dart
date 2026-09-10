import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tesseract_ocr/flutter_tesseract_ocr.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdfx/pdfx.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Text recognition (OCR) built on Tesseract 4.
///
/// The English `eng.traineddata` model ships inside the app bundle
/// (`assets/tessdata/`, ~4 MB) and is copied to app storage on first use, so
/// OCR works fully offline with no setup. Per the project privacy policy the
/// image and the recognised text never leave the device — everything runs in
/// the bundled native library.
///
/// The active language and page-segmentation mode are persisted with
/// [SharedPreferences] so the picker UI and this service stay in sync.
class OcrService {
  static const _kLanguageKey = 'ocr_language';
  static const _kPsmKey = 'ocr_psm';

  static String _language = 'eng';
  static String _psm = '3';

  /// Page segmentation modes exposed in the UI, mapped to their Tesseract
  /// `tessedit_pageseg_mode` value.
  static const Map<String, String> psmModes = {
    'Auto (default)': '3',
    'Single column of text': '4',
    'Single block of text': '6',
    'Single line': '7',
    'Single word': '8',
    'Sparse text': '11',
  };

  /// Human-readable labels for each supported OCR language.
  /// Keys match the `.traineddata` basename (without extension).
  static const Map<String, String> languageLabels = {
    'ara': 'العربية (Arabic)',
    'chi_sim': '简体中文 (Simplified Chinese)',
    'chi_tra': '繁體中文 (Traditional Chinese)',
    'deu': 'Deutsch (German)',
    'eng': 'English',
    'fra': 'Français (French)',
    'hin': 'हिन्दी (Hindi)',
    'jpn': '日本語 (Japanese)',
    'kor': '한국어 (Korean)',
    'por': 'Português (Portuguese)',
    'rus': 'Русский (Russian)',
    'spa': 'Español (Spanish)',
    'vie': 'Tiếng Việt (Vietnamese)',
    'ben': 'বাংলা (Bengali)',
  };

  /// Directory holding the extracted `.traineddata` files. Populated after
  /// the first [ensureReady] call.
  static String tessDataPath = '';

  /// Languages currently available on the device (bundled English plus any
  /// extra trained data copied into the tessdata directory).
  /// Returns pairs of (code, label) for use in UI dropdowns.
  static List<MapEntry<String, String>> get availableLanguagesWithLabels {
    final langs = <String>{};
    final dir = Directory(tessDataPath);
    if (dir.existsSync()) {
      for (final f in dir.listSync()) {
        if (f is File && f.path.endsWith('.traineddata')) {
          langs.add(p.basenameWithoutExtension(f.path));
        }
      }
    }
    // Always include eng even if not on disk (bundled by default).
    langs.add('eng');
    return langs
        .map((code) => MapEntry(code, languageLabels[code] ?? code))
        .toList()
      ..sort((a, b) => a.value.compareTo(b.value));
  }

  /// Returns just the language codes (no labels). Kept for backwards
  /// compatibility with any callers that expect a List<String>.
  static List<String> get availableLanguages {
    return availableLanguagesWithLabels.map((e) => e.key).toList();
  }

  /// Returns the persisted [language, psm] pair.
  static Future<List<String>> loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    return [
      prefs.getString(_kLanguageKey) ?? 'eng',
      prefs.getString(_kPsmKey) ?? '3',
    ];
  }

  /// Persists [language] / [psm] for the next OCR run.
  static Future<void> savePrefs({String? language, String? psm}) async {
    final prefs = await SharedPreferences.getInstance();
    if (language != null) {
      _language = language;
      await prefs.setString(_kLanguageKey, language);
    }
    if (psm != null) {
      _psm = psm;
      await prefs.setString(_kPsmKey, psm);
    }
  }

  /// Restores persisted settings and copies bundled trained data to app
  /// storage on first run. Safe to call multiple times.
  static Future<void> ensureReady() async {
    final saved = await loadPrefs();
    _language = saved[0];
    _psm = saved[1];
    if (tessDataPath.isNotEmpty) return;
    try {
      // If the plugin already provisioned a data dir, adopt it.
      final pluginDir = await FlutterTesseractOcr.getTessdataPath();
      if (pluginDir.isNotEmpty && Directory(pluginDir).existsSync()) {
        tessDataPath = pluginDir;
        return;
      }
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory(p.join(docs.path, 'tessdata'));
      if (!dir.existsSync()) dir.createSync(recursive: true);
      // Copy any bundled trained data out of assets on first run.
      final manifest = await rootBundle.loadString(
        'assets/tessdata_config.json',
      );
      final names = RegExp(
        r'"([^"]+\.traineddata)"',
      ).allMatches(manifest).map((m) => m.group(1)!).toSet();
      for (final name in names) {
        final target = File(p.join(dir.path, name));
        if (!target.existsSync()) {
          final bytes = await rootBundle.load('assets/tessdata/$name');
          await target.writeAsBytes(bytes.buffer.asUint8List(), flush: true);
        }
      }
      tessDataPath = dir.path;
    } catch (e) {
      debugPrint('OcrService: init failed: $e');
    }
  }

  /// Runs OCR on [imagePath], returning the recognised text.
  ///
  /// Throws when OCR has not been initialised or the engine fails; callers
  /// surface the error to the user.
  static Future<String> extractText(String imagePath) async {
    if (tessDataPath.isEmpty) await ensureReady();
    return FlutterTesseractOcr.extractText(
      imagePath,
      language: _language,
      args: {'preserve_interword_spaces': '1', if (_psm != '3') 'psm': _psm},
    );
  }

  /// OCR for any document the user picks. Images go straight to the engine;
  /// multi-page PDFs are rasterised page-by-page with pdfx first.
  static Future<String> extractFromDocument(
    String path, {
    void Function(int page, int total)? onProgress,
  }) async {
    if (path.toLowerCase().endsWith('.pdf')) {
      return _extractFromPdf(path, onProgress);
    }
    return extractText(path);
  }

  static Future<String> _extractFromPdf(
    String path,
    void Function(int page, int total)? onProgress,
  ) async {
    final doc = await PdfDocument.openFile(path);
    try {
      final buffer = StringBuffer();
      final tmp = await Directory.systemTemp.createTemp('swordfm_ocr_pdf_');
      for (var i = 1; i <= doc.pagesCount; i++) {
        onProgress?.call(i, doc.pagesCount);
        final page = await doc.getPage(i);
        final png = await page.render(
          width: page.width * 2, // 2× scale for OCR accuracy
          height: page.height * 2,
          format: PdfPageImageFormat.png,
          backgroundColor: '#FFFFFF',
        );
        await page.close();
        if (png == null || png.bytes.isEmpty) continue;
        final img = File('${tmp.path}/page$i.png');
        await img.writeAsBytes(png.bytes);
        final text = await extractText(img.path);
        if (buffer.isNotEmpty) buffer.write('\n\n');
        buffer.write('--- Page $i ---\n$text');
        await img.delete();
      }
      return buffer.toString();
    } finally {
      await doc.close();
    }
  }
}
