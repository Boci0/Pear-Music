import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;

/// Repairs song titles that arrive as mojibake.
///
/// Some titles reach the app after their UTF-8 bytes were decoded with a
/// Windows code page (cp1252) once, twice or three times. Older builds, log
/// tools and playlist files made elsewhere can all do that. [title] reverses
/// those mistakes so the real characters show again, and leaves healthy text
/// untouched.
///
/// A reversal step is only taken when every character of the string maps back
/// to a single cp1252 byte and those bytes are strict UTF-8. Real titles
/// almost never pass that test: Japanese, Arabic and emoji text fail on their
/// first character, and accented Latin text fails because its lone bytes are
/// not valid UTF-8. That is what makes it safe to run on every title.
class TextRepair {
  TextRepair._();

  /// A title may be a few encoding mistakes deep; the worst seen in the wild
  /// was three. Five keeps a loop from running on text that keeps decoding.
  static const int _maxLevels = 5;

  /// Windows-1252's printable characters for the bytes 0x80-0x9F.
  static const Map<int, int> _cp1252Bytes = {
    0x20AC: 0x80, // euro sign
    0x201A: 0x82, // single low quotation mark
    0x0192: 0x83, // f with hook
    0x201E: 0x84, // double low quotation mark
    0x2026: 0x85, // horizontal ellipsis
    0x2020: 0x86, // dagger
    0x2021: 0x87, // double dagger
    0x02C6: 0x88, // circumflex
    0x2030: 0x89, // per mille sign
    0x0160: 0x8A, // S with caron
    0x2039: 0x8B, // single left angle quotation mark
    0x0152: 0x8C, // OE ligature
    0x017D: 0x8E, // Z with caron
    0x2018: 0x91, // left single quotation mark
    0x2019: 0x92, // right single quotation mark
    0x201C: 0x93, // left double quotation mark
    0x201D: 0x94, // right double quotation mark
    0x2022: 0x95, // bullet
    0x2013: 0x96, // en dash
    0x2014: 0x97, // em dash
    0x02DC: 0x98, // small tilde
    0x2122: 0x99, // trade mark sign
    0x0161: 0x9A, // s with caron
    0x203A: 0x9B, // single right angle quotation mark
    0x0153: 0x9C, // oe ligature
    0x017E: 0x9E, // z with caron
    0x0178: 0x9F, // Y with diaeresis
  };

  /// [value] with any code-page decoding mistakes reversed.
  static String title(String value) {
    if (value.isEmpty) return value;
    var ascii = true;
    for (final unit in value.codeUnits) {
      if (unit > 0x7F) {
        ascii = false;
        break;
      }
    }
    // Plain titles are the common case and cannot be mojibake.
    if (ascii) return value;
    var text = value;
    for (var level = 0; level < _maxLevels; level++) {
      final decoded = reverseOnce(text);
      if (decoded == null || decoded == text) break;
      text = decoded;
    }
    return text;
  }

  /// One reversal step, or null when [value] is not mojibake.
  @visibleForTesting
  static String? reverseOnce(String value) {
    final bytes = <int>[];
    for (final rune in value.runes) {
      final byte = _cp1252Bytes[rune] ?? (rune <= 0xFF ? rune : null);
      if (byte == null) return null;
      bytes.add(byte);
    }
    try {
      return utf8.decode(bytes);
    } on FormatException {
      return null;
    }
  }
}
