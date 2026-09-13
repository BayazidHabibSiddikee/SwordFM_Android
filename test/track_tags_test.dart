import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:swordfm/services/audio_handler.dart';

/// Builds a minimal MP3 file with an ID3v2.3 tag (TIT2 title, TPE1 artist,
/// TALB album) followed by a single fake MPEG frame header so parsers accept
/// the container.
Uint8List buildTaggedMp3({
  String title = 'Test Title',
  String artist = 'Test Artist',
  String album = 'Test Album',
}) {
  final out = BytesBuilder();

  BytesBuilder frame(String id, String text) {
    final payload = Uint8List.fromList(
      [0x00, ...utf8.encode(text)], // 0x00 = ISO-8859-1 encoding byte
    );
    final b = BytesBuilder()
      ..add(utf8.encode(id))
      ..add([(payload.length >> 24) & 0xFF, (payload.length >> 16) & 0xFF,
        (payload.length >> 8) & 0xFF, payload.length & 0xFF])
      ..add([0x00, 0x00]) // flags
      ..add(payload);
    return b;
  }

  final frames = BytesBuilder()
    ..add(frame('TIT2', title).toBytes())
    ..add(frame('TPE1', artist).toBytes())
    ..add(frame('TALB', album).toBytes());
  final tagBytes = frames.toBytes();

  // ID3v2 header: "ID3" + ver 3.0 + flags 0 + syncsafe size.
  final size = tagBytes.length;
  final syncsafe = [
    (size >> 21) & 0x7F,
    (size >> 14) & 0x7F,
    (size >> 7) & 0x7F,
    size & 0x7F,
  ];
  out.add(utf8.encode('ID3'));
  out.add([0x03, 0x00, 0x00, ...syncsafe]);
  out.add(tagBytes);
  // One fake MPEG-1 Layer III frame header (0xFF 0xFB …) + padding.
  out.add([0xFF, 0xFB, 0x90, 0x00, ...List.filled(100, 0)]);
  return out.toBytes();
}

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('track_tags_');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('reads embedded title/artist/album', () async {
    final path = p.join(tmp.path, 'song.mp3');
    File(path).writeAsBytesSync(buildTaggedMp3());
    final tags = await TrackTags.read(path);
    expect(tags.title, 'Test Title');
    expect(tags.artist, 'Test Artist');
    expect(tags.album, 'Test Album');
  });

  test('missing file yields empty tags, never throws', () async {
    final tags = await TrackTags.read(p.join(tmp.path, 'nope.mp3'));
    expect(tags.title, isNull);
    expect(tags.artist, isNull);
    expect(tags.album, isNull);
  });

  test('untagged file yields empty tags, never throws', () async {
    final path = p.join(tmp.path, 'plain.wav');
    File(path).writeAsBytesSync(List.filled(256, 0));
    final tags = await TrackTags.read(path);
    expect(tags.title, isNull);
    expect(tags.artist, isNull);
  });

  test('blank tag values normalize to null', () async {
    final path = p.join(tmp.path, 'blank.mp3');
    File(path).writeAsBytesSync(
      buildTaggedMp3(title: '   ', artist: '', album: 'Real Album'),
    );
    final tags = await TrackTags.read(path);
    expect(tags.title, isNull);
    expect(tags.artist, isNull);
    expect(tags.album, 'Real Album');
  });
}
