import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:xml/xml.dart';

/// A DLNA/UPnP media renderer discovered on the LAN.
class DlnaDevice {
  /// Stable id — the control URL (unique per renderer service).
  final String id;
  final String name;
  final String location;
  final String controlUrl;
  final InternetAddress address;

  const DlnaDevice({
    required this.id,
    required this.name,
    required this.location,
    required this.controlUrl,
    required this.address,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'location': location,
      };
}

/// Pure-Dart DLNA renderer control (no native Cast SDK needed).
///
/// Discovery: SSDP `M-SEARCH` to `239.255.255.250:1900`, then each responder's
/// device XML is fetched and scanned for an `AVTransport` service — only
/// devices that can actually play media are returned (printers and NAS boxes
/// answer SSDP too).
///
/// Playback: `SetAVTransportURI` + `Play` SOAP calls against the renderer.
/// This drives smart TVs, Kodi, VLC-with-UPnP, and most DLNA speakers —
/// Chromecast (proprietary protocol) stays explicitly out of scope.
class DlnaCastService {
  static const _ssdpAddress = '239.255.255.250';
  static const _ssdpPort = 1900;

  /// Sends one M-SEARCH round and collects AVTransport renderers heard
  /// within [timeout]. Dedupes by control URL.
  static Future<List<DlnaDevice>> discover({
    Duration timeout = const Duration(seconds: 4),
  }) async {
    final found = <String, DlnaDevice>{};
    RawDatagramSocket? socket;
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      socket.broadcastEnabled = true;
      final search = utf8.encode(
        'M-SEARCH * HTTP/1.1\r\n'
        'HOST: $_ssdpAddress:$_ssdpPort\r\n'
        'MAN: "ns=01; ns=01"\r\n'
        'MX: 3\r\n'
        'ST: urn:schemas-upnp-org:service:AVTransport:1\r\n'
        '\r\n',
      );
      // Two shots 500 ms apart — UDP is lossy, one packet often vanishes.
      for (var i = 0; i < 2; i++) {
        socket.send(search, InternetAddress(_ssdpAddress), _ssdpPort);
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      final deadline = DateTime.now().add(timeout);
      await for (final event in socket.timeout(
        timeout,
        onTimeout: (sink) => sink.close(),
      )) {
        if (DateTime.now().isAfter(deadline)) break;
        if (event != RawSocketEvent.read) continue;
        final dg = socket.receive();
        if (dg == null) continue;
        final device = await _deviceFromResponse(dg);
        if (device != null) found[device.id] = device;
      }
    } catch (_) {
      // No multicast route (emulator, VPN) — return whatever was found.
    } finally {
      socket?.close();
    }
    return found.values.toList();
  }

  /// Plays [mediaUrl] on [device]. [title] shows in the renderer's UI when
  /// it displays metadata. Throws a descriptive [Exception] on SOAP faults
  /// or transport errors instead of returning a bool nobody checks.
  static Future<void> castUrl(DlnaDevice device, String mediaUrl,
      {String title = 'SwordFM'}) async {
    await _soap(
      device,
      'SetAVTransportURI',
      '<InstanceID>0</InstanceID>'
          '<CurrentURI>${_esc(mediaUrl)}</CurrentURI>'
          '<CurrentURIMetaData>${_esc(_didLite(title, mediaUrl))}</CurrentURIMetaData>',
    );
    await _soap(device, 'Play', '<InstanceID>0</InstanceID><Speed>1</Speed>');
  }

  /// Stops playback on [device].
  static Future<void> stop(DlnaDevice device) async {
    await _soap(device, 'Stop', '<InstanceID>0</InstanceID>');
  }

  // --- Internals ------------------------------------------------------------

  /// Parses one SSDP response datagram into a renderer. Visible for testing
  /// so the LOCATION→device-XML→control-URL chain can be exercised against
  /// a loopback HttpServer without multicast.
  @visibleForTesting
  static Future<DlnaDevice?> deviceFromSsdpResponse(Datagram dg) =>
      _deviceFromResponse(dg);

  /// Parses one SSDP response datagram into a renderer, or null when it is
  /// not an AVTransport device (or its device XML can't be read).
  static Future<DlnaDevice?> _deviceFromResponse(Datagram dg) async {
    try {
      final text = utf8.decode(dg.data, allowMalformed: true);
      final location = RegExp(r'LOCATION:\s*(\S+)', caseSensitive: false)
          .firstMatch(text)
          ?.group(1);
      if (location == null || location.isEmpty) return null;
      return await _describe(location, dg.address);
    } catch (_) {
      return null;
    }
  }

  /// Fetches the device description XML at [location] and extracts the
  /// AVTransport control URL + friendly name. Relative control URLs resolve
  /// against the device location (UPnP §2 — most renderers send relative).
  static Future<DlnaDevice?> _describe(
    String location,
    InternetAddress address,
  ) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final req = await client.getUrl(Uri.parse(location));
      final resp = await req.close().timeout(const Duration(seconds: 5));
      if (resp.statusCode != 200) return null;
      final body = await resp.transform(utf8.decoder).join();
      final doc = XmlDocument.parse(body);
      final base = Uri.parse(location);
      for (final service in doc.findAllElements('service')) {
        final type = service.getElement('serviceType')?.innerText ?? '';
        if (!type.contains('AVTransport')) continue;
        final rawControl =
            service.getElement('controlURL')?.innerText.trim() ?? '';
        if (rawControl.isEmpty) continue;
        final controlUrl = base.resolve(rawControl).toString();
        final name = _friendlyName(doc) ?? address.address;
        return DlnaDevice(
          id: controlUrl,
          name: name,
          location: location,
          controlUrl: controlUrl,
          address: address,
        );
      }
      return null; // No AVTransport — not a renderer.
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  static String? _friendlyName(XmlDocument doc) {
    final name = doc
        .findAllElements('device')
        .firstOrNull
        ?.getElement('friendlyName')
        ?.innerText
        .trim();
    return (name == null || name.isEmpty) ? null : name;
  }

  static Future<void> _soap(
    DlnaDevice device,
    String action,
    String body,
  ) async {
    final envelope = '<?xml version="1.0"?>'
        '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
        's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
        '<s:Body>'
        '<u:$action xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">'
        '$body'
        '</u:$action>'
        '</s:Body></s:Envelope>';
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final req = await client.postUrl(Uri.parse(device.controlUrl));
      req.headers.set('Content-Type', 'text/xml; charset="utf-8"');
      req.headers.set(
        'SOAPACTION',
        '"urn:schemas-upnp-org:service:AVTransport:1#$action"',
      );
      req.write(envelope);
      final resp = await req.close().timeout(const Duration(seconds: 8));
      final respBody = await resp.transform(utf8.decoder).join();
      if (resp.statusCode >= 300 || respBody.contains('<s:Fault>')) {
        final fault = RegExp(r'<faultstring>([^<]*)</faultstring>')
                .firstMatch(respBody)
                ?.group(1) ??
            'HTTP ${resp.statusCode}';
        throw Exception('DLNA $action failed: $fault');
      }
    } finally {
      client.close(force: true);
    }
  }

  static String _esc(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');

  /// Minimal DIDL-Lite item so renderers show a title instead of a raw URL.
  static String _didLite(String title, String url) {
    final mime = url.toLowerCase().endsWith('.mp3') ||
            url.toLowerCase().endsWith('.m4a')
        ? 'audio/mpeg'
        : url.toLowerCase().endsWith('.mp4')
            ? 'video/mp4'
            : '*/*';
    final cls = mime.startsWith('audio')
        ? 'object.item.audioItem.musicTrack'
        : mime.startsWith('video')
            ? 'object.item.videoItem'
            : 'object.item';
    return '<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" '
        'xmlns:dc="http://purl.org/dc/elements/1.1/" '
        'xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">'
        '<item id="0" parentID="0" restricted="1">'
        '<dc:title>${_esc(title)}</dc:title>'
        '<upnp:class>$cls</upnp:class>'
        '<res protocolInfo="http-get:*:$mime:*">${_esc(url)}</res>'
        '</item></DIDL-Lite>';
  }
}
