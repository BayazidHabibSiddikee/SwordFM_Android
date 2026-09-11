import 'package:flutter_test/flutter_test.dart';
import 'package:swordfm/services/file_open_router.dart';

void main() {
  group('FileOpenRouter', () {
    test('resolves media extensions case-insensitively', () {
      final video = FileOpenRouter.resolve(
        '/media/Movie.MKV',
        source: FileOpenSource.search,
      );
      final audio = FileOpenRouter.resolve('/music/Track.FLAC');

      expect(video.type, FileOpenTargetType.video);
      expect(video.supportsPlaylist, isTrue);
      expect(video.source, FileOpenSource.search);
      expect(audio.type, FileOpenTargetType.audio);
      expect(audio.supportsPlaylist, isTrue);
    });

    test('resolves supported document and reader targets', () {
      expect(FileOpenRouter.resolve('file.pdf').type, FileOpenTargetType.pdf);
      expect(FileOpenRouter.resolve('file.docx').type, FileOpenTargetType.docx);
      expect(FileOpenRouter.resolve('cover.PNG').type, FileOpenTargetType.image);
      expect(FileOpenRouter.resolve('book.epub').type, FileOpenTargetType.epub);
      expect(FileOpenRouter.resolve('comic.cbz').type, FileOpenTargetType.comicBook);
      expect(FileOpenRouter.resolve('table.xlsx').type, FileOpenTargetType.spreadsheet);
      expect(FileOpenRouter.resolve('notes.md').type, FileOpenTargetType.text);
      expect(FileOpenRouter.resolve('main.dart').type, FileOpenTargetType.text);
    });

    test('keeps PPTX explicitly outline-only', () {
      final target = FileOpenRouter.resolve('slides.pptx');

      expect(target.type, FileOpenTargetType.pptxOutline);
      expect(target.inApp, isTrue);
      expect(target.reason, contains('outline'));
    });

    test('resolves supported archive formats', () {
      expect(FileOpenRouter.resolve('photos.zip').type, FileOpenTargetType.archive);
      expect(FileOpenRouter.resolve('backup.tar.gz').type, FileOpenTargetType.archive);
      expect(FileOpenRouter.resolve('backup.TAR.XZ').type, FileOpenTargetType.archive);
      expect(FileOpenRouter.resolve('backup.tar.bz2').type, FileOpenTargetType.archive);
    });

    test('does not advertise 7z or RAR support', () {
      for (final path in ['archive.7z', 'archive.rar', 'comic.cbr']) {
        final target = FileOpenRouter.resolve(path);
        expect(target.type, FileOpenTargetType.unsupported);
        expect(target.inApp, isFalse);
        expect(target.reason, isNotNull);
      }
    });

    test('returns external target for unknown formats', () {
      final target = FileOpenRouter.resolve(
        'binary.custom',
        source: FileOpenSource.externalIntent,
      );

      expect(target.type, FileOpenTargetType.external);
      expect(target.inApp, isFalse);
      expect(target.isFullScreen, isFalse);
      expect(target.source, FileOpenSource.externalIntent);
    });
  });
}
