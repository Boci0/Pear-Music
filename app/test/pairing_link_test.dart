import 'package:flutter_test/flutter_test.dart';

import 'package:peerm_app/services/pairing_link.dart';

void main() {
  group('PairingLink', () {
    test('encode without server -> bare deep link', () {
      expect(PairingLink.encode('ab12cd'), 'pearmusic://pair/AB12CD');
    });

    test('encode with server URL-encodes the address', () {
      final out = PairingLink.encode('ab12cd', server: 'ws://10.84.188.119:8080');
      expect(
        out,
        'pearmusic://pair/AB12CD?server=ws%3A%2F%2F10.84.188.119%3A8080',
      );
    });

    test('parse bare 6-char code', () {
      final link = PairingLink.parse('ab12cd');
      expect(link, isNotNull);
      expect(link!.code, 'AB12CD');
      expect(link.server, isNull);
    });

    test('parse deep link without server', () {
      final link = PairingLink.parse('pearmusic://pair/AB12CD');
      expect(link, isNotNull);
      expect(link!.code, 'AB12CD');
      expect(link.server, isNull);
    });

    test('parse deep link with server', () {
      final link = PairingLink.parse(
        'pearmusic://pair/AB12CD?server=ws%3A%2F%2F10.84.188.119%3A8080',
      );
      expect(link, isNotNull);
      expect(link!.code, 'AB12CD');
      expect(link.server, 'ws://10.84.188.119:8080');
    });

    test('round-trips through encode/parse', () {
      final encoded = PairingLink.encode('Z9K2Q4', server: 'ws://192.168.1.5:8080');
      final link = PairingLink.parse(encoded);
      expect(link!.code, 'Z9K2Q4');
      expect(link.server, 'ws://192.168.1.5:8080');
    });

    test('rejects invalid payloads', () {
      expect(PairingLink.parse('hello'), isNull);
      expect(PairingLink.parse('pearmusic://pair/SHORT'), isNull);
      expect(PairingLink.parse('pearmusic://pair/AB12CD?server=ws%3A%2F%2Fbad'), isNotNull);
      expect(PairingLink.parse(''), isNull);
      expect(PairingLink.parse('ABCDEFGH'), isNull);
    });
  });
}
