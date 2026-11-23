// Parser for the HC-05 gas meter serial protocol.
//
// The meter firmware streams one ASCII line per reading over classic
// Bluetooth SPP, e.g.
//
//   GAS:72.5,W:5.8,BAT:88,LEAK:0\r\n
//
//   GAS  = gas left in percent (0-100)
//   W    = gas weight in kg
//   BAT  = meter battery state of charge in percent (0-100)
//   LEAK = 0 ok, 1 warning, 2 critical
//
// Radio links drop and corrupt bytes, so everything here is defensive:
// bytes are framed into lines, a bad line is dropped (never thrown), and an
// over-long line without a newline is discarded so memory stays bounded.

/// One decoded meter line. Fields the meter didn't send are null.
class MeterPacket {
  final double? percent;
  final double? weightKg;
  final double? battery;

  /// 0 = ok, 1 = warning, 2 = critical, null = not reported.
  final int? leakLevel;

  const MeterPacket({this.percent, this.weightKg, this.battery, this.leakLevel});

  @override
  bool operator ==(Object other) =>
      other is MeterPacket &&
      other.percent == percent &&
      other.weightKg == weightKg &&
      other.battery == battery &&
      other.leakLevel == leakLevel;

  @override
  int get hashCode => Object.hash(percent, weightKg, battery, leakLevel);

  @override
  String toString() =>
      'MeterPacket(percent: $percent, weightKg: $weightKg, battery: $battery, leak: $leakLevel)';
}

class MeterReadingParser {
  MeterReadingParser._();

  /// Longest line we accept. Real packets are ~30 chars.
  static const int maxLineLength = 160;

  /// Heaviest plausible reading (kg): a 50 kg cylinder plus margin.
  static const double maxWeightKg = 200;

  /// Parses one line. Returns null for anything that isn't a usable packet:
  /// empty, too long, no GAS/W value, a known key with a non-numeric or
  /// absurd value, or a repeated key (usually two lines glued together).
  /// Unknown keys are ignored so newer firmware fields don't break parsing.
  static MeterPacket? parseLine(String raw) {
    final line = raw.trim();
    if (line.isEmpty || line.length > maxLineLength) return null;

    double? percent, weight, battery;
    int? leak;
    final seen = <String>{};

    for (final token in line.split(',')) {
      final t = token.trim();
      if (t.isEmpty) continue;
      final sep = t.indexOf(':');
      if (sep <= 0) return null; // "garbage" with no key:value shape
      final key = t.substring(0, sep).trim().toUpperCase();
      final value = t.substring(sep + 1).trim();
      if (!seen.add(key)) return null;

      switch (key) {
        case 'GAS':
          final v = _number(value);
          if (v == null || v < -50 || v > 1000) return null;
          percent = v.clamp(0, 100).toDouble();
        case 'W':
          final v = _number(value);
          if (v == null || v < -50 || v > maxWeightKg) return null;
          weight = v < 0 ? 0 : v;
        case 'BAT':
          final v = _number(value);
          if (v == null || v < -50 || v > 1000) return null;
          battery = v.clamp(0, 100).toDouble();
        case 'LEAK':
          final v = int.tryParse(value);
          if (v == null || v < 0 || v > 2) return null;
          leak = v;
        default:
          // Unknown field from newer firmware: ignore.
          break;
      }
    }

    if (percent == null && weight == null) return null;
    return MeterPacket(percent: percent, weightKg: weight, battery: battery, leakLevel: leak);
  }

  static double? _number(String s) {
    final v = double.tryParse(s);
    if (v == null || v.isNaN || v.isInfinite) return null;
    return v;
  }
}

/// Turns a raw byte stream into complete lines.
///
/// Handles packets split across reads, several packets in one read, CR, LF or
/// CRLF endings, non-ASCII noise (dropped instead of throwing like
/// `ascii.decode`), and runaway data without newlines (buffer is reset).
class MeterLineFramer {
  MeterLineFramer({this.maxLineLength = MeterReadingParser.maxLineLength});

  final int maxLineLength;
  final StringBuffer _buf = StringBuffer();
  bool _discarding = false;

  /// Feeds bytes and returns any lines completed by them (without endings).
  List<String> addBytes(List<int> bytes) {
    final lines = <String>[];
    for (final b in bytes) {
      if (b == 0x0A || b == 0x0D) {
        if (!_discarding && _buf.isNotEmpty) lines.add(_buf.toString());
        _buf.clear();
        _discarding = false;
        continue;
      }
      if (_discarding) continue;
      // Keep printable ASCII only; radio noise is dropped.
      if (b < 0x20 || b > 0x7E) continue;
      if (_buf.length >= maxLineLength) {
        // No newline for too long: throw away until the next line ending.
        _buf.clear();
        _discarding = true;
        continue;
      }
      _buf.writeCharCode(b);
    }
    return lines;
  }

  /// Bytes waiting for a line ending (for tests/diagnostics).
  int get pendingLength => _buf.length;

  void reset() {
    _buf.clear();
    _discarding = false;
  }
}
