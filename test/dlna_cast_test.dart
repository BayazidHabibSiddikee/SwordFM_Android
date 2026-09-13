import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:swordfm/services/dlna_cast_service.dart';

const _deviceXml = '''<?xml version="1.0"?>
<root xmlns="urn:schemas-upnp-org:device-1-0">
<device>
<friendlyName>Kodi Living Room</friendlyName>
<serviceList>
<service>
<serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>
<controlURL>/ctl/av</controlURL>
</service>
</serviceList>
</device>
</root>''';

void main() {
  late HttpServer server;
  late List<Map<String, String>> soapCalls;

  setUp(() async {
    soapCalls = [];
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      if (req.uri.path == '/desc.xml') {
        req.response
          ..headers.contentType = ContentType('text', 'xml')
          ..write(_deviceXml)
          ..close();
        return;
      }
      final body = await req.cast<List<int>>().transform(utf8.decoder).join();
      soapCalls.add({
        'path': req.uri.path,
        'soapAction': req.headers.value('soapaction') ?? '',
        'body': body,
      });
      req.response
        ..statusCode = 200
        ..headers.contentType = ContentType('text', 'xml')
        ..write('<s:Envelope/>')
        ..close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
  });

  DlnaDevice device() => DlnaDevice(
        id: 'http://127.0.0.1:${server.port}/ctl/av',
        name: 'Kodi Living Room',
        location: 'http://127.0.0.1:${server.port}/desc.xml',
        controlUrl: 'http://127.0.0.1:${server.port}/ctl/av',
        address: InternetAddress.loopbackIPv4,
      );

  Datagram ssdpResponse(String location) {
    final text = 'HTTP/1.1 200 OK\r\n'
        'LOCATION: $location\r\n'
        'ST: urn:schemas-upnp-org:service:AVTransport:1\r\n\r\n';
    return Datagram(
      Uint8List.fromList(utf8.encode(text)),
      InternetAddress.loopbackIPv4,
      server.port,
    );
  }

  test('device XML yields renderer with resolved control URL', () async {
    final found = await DlnaCastService.deviceFromSsdpResponse(
      ssdpResponse('http://127.0.0.1:${server.port}/desc.xml'),
    );
    expect(found, isNotNull);
    expect(found!.name, 'Kodi Living Room');
    expect(found.controlUrl, 'http://127.0.0.1:${server.port}/ctl/av');
  });

  test('non-renderer device XML yields null', () async {
    // LOCATION pointing at a path that 404s → describe fails → null.
    final found = await DlnaCastService.deviceFromSsdpResponse(
      ssdpResponse('http://127.0.0.1:${server.port}/printer.xml'),
    );
    expect(found, isNull);
  });

  test('response without LOCATION yields null', () async {
    final dg = Datagram(
      Uint8List.fromList(utf8.encode('HTTP/1.1 200 OK\r\n\r\n')),
      InternetAddress.loopbackIPv4,
      server.port,
    );
    expect(await DlnaCastService.deviceFromSsdpResponse(dg), isNull);
  });

  test('castUrl sends SetAVTransportURI then Play', () async {
    await DlnaCastService.castUrl(
      device(),
      'http://example.com/song.mp3',
      title: 'Test Song',
    );
    expect(soapCalls, hasLength(2));
    expect(soapCalls[0]['path'], '/ctl/av');
    expect(soapCalls[0]['soapAction'], contains('SetAVTransportURI'));
    expect(soapCalls[0]['body'], contains('http://example.com/song.mp3'));
    expect(soapCalls[0]['body'], contains('Test Song'));
    expect(soapCalls[1]['soapAction'], contains('#Play'));
  });

  test('castUrl throws on SOAP fault', () async {
    await server.close(force: true);
    // Recreate a server that answers 500 with a fault body.
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      await req.cast<List<int>>().transform(utf8.decoder).join();
      req.response
        ..statusCode = 500
        ..headers.contentType = ContentType('text', 'xml')
        ..write('<s:Envelope><s:Body><s:Fault>'
            '<faultstring>Invalid Args</faultstring>'
            '</s:Fault></s:Body></s:Envelope>')
        ..close();
    });
    expect(
      () => DlnaCastService.castUrl(device(), 'http://example.com/x.mp4'),
      throwsA(
        isA<Exception>().having(
          (e) => '$e',
          'message',
          contains('Invalid Args'),
        ),
      ),
    );
  });

  test('stop sends Stop action', () async {
    await DlnaCastService.stop(device());
    expect(soapCalls, hasLength(1));
    expect(soapCalls[0]['soapAction'], contains('#Stop'));
  });
}
