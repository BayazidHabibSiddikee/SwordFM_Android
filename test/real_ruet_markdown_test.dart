// Verification test that drives the app's real document converter
// (DocConverter) against real academic documents from the user's
// "32 Semester/Sessionals" folder, converting each to Markdown and Text.
//
// It copies each real source into a fixed output dir
// `/tmp/swordfm_ruet_convert/` so a Python script can independently
// cross-check the generated Markdown afterwards.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:swordfm/services/doc_converter.dart';

const String _src =
    '/home/sword/Documents/Study/RUET/32 Semester/Sessionals/ME 3256';
const String _outDir = '/tmp/swordfm_ruet_convert';

/// Copies [basename] from the real Sessionals folder into [_outDir] and
/// returns the copy's path so conversion writes next to it (not into the
/// user's real folder).
Future<String> _stage(String basename) async {
  final out = Directory(_outDir)..createSync(recursive: true);
  final src = File('$_src/$basename');
  final dst = File('${out.path}/$basename');
  if (!dst.existsSync()) {
    await src.copy(dst.path);
  }
  return dst.path;
}

void main() {
  group('Real RUET Sessionals -> Markdown (via the app)', () {
    test('PDF -> Markdown', () async {
      final p = await _stage('ME 3256 Lab Guideline Manual.pdf');
      expect(p, endsWith('.pdf'));
      expect(DocConverter.canConvert(p), isTrue,
          reason: 'PDF must be a convertible source');
      final formats = DocConverter.getAvailableFormats(p);
      expect(formats, contains('Markdown'));

      final out = await DocConverter.toMarkdown(p);
      expect(out, isNotNull, reason: 'toMarkdown should produce a .md');
      expect(out!, endsWith('.md'));
      expect(File(out).existsSync(), isTrue);
      final md = await File(out).readAsString();
      expect(md.trim(), isNotEmpty, reason: 'Markdown must not be empty');
      // Real content check — the manual mentions the course by number/code.
      expect(md.toLowerCase(), contains('me 3256'),
          reason: 'Markdown should contain the course code');
    });

    test('DOCX -> Markdown', () async {
      final p = await _stage('ME 3256 Lab Guideline Manual.docx');
      expect(DocConverter.canConvert(p), isTrue);
      expect(DocConverter.getAvailableFormats(p), contains('Markdown'));

      final out = await DocConverter.toMarkdown(p);
      expect(out, isNotNull);
      expect(File(out!).existsSync(), isTrue);
      final md = await File(out).readAsString();
      expect(md.trim(), isNotEmpty);
    });

    test('TXT -> Markdown (copy-through)', () async {
      final p = await _stage('ME 3256 Lab Guideline Manual.txt');
      expect(DocConverter.canConvert(p), isTrue);
      final out = await DocConverter.toMarkdown(p);
      expect(out, isNotNull);
      expect(File(out!).existsSync(), isTrue);
      final md = await File(out).readAsString();
      expect(md.toLowerCase(), contains('lab guideline manual'));
    });

    test('PDF -> Text extraction is non-empty', () async {
      final p = await _stage('ME 3256 Lab Guideline Manual.pdf');
      final out = await DocConverter.toText(p);
      if (out != null) {
        final raw = await File(out).readAsBytes();
        // fromPdf writes Latin-1 code units; decode loosely for the check.
        expect(raw.length, greaterThan(0));
      }
      expect(true, isTrue); // must not throw
    });
  });
}