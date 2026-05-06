// ignore_for_file: avoid_print
// Standalone test - no flutter deps.
import 'dart:convert';
import 'dart:typed_data';
import 'package:pointycastle/export.dart';

String decryptCue(String b64, Uint8List key, Uint8List iv) {
  try {
    final ct = base64.decode(b64.trim());
    if (ct.isEmpty || ct.length % 16 != 0) return 'BAD_LEN(${ct.length})';
    final cipher = CBCBlockCipher(AESEngine())
      ..init(false, ParametersWithIV(KeyParameter(key), iv));
    final out = Uint8List(ct.length);
    for (var off = 0; off < ct.length; off += 16) {
      cipher.processBlock(ct, off, out, off);
    }
    final pad = out.last;
    final stripped = (pad >= 1 && pad <= 16)
        ? out.sublist(0, out.length - pad)
        : out;
    return utf8.decode(stripped, allowMalformed: true);
  } catch (e) {
    return 'ERR: $e';
  }
}

void main() async {
  const ct = 'O7/IcKbSiPWvjf9ZDApGz5k1HcFRViOkWZh7ycxseodPloMXNEAvgMCheiFhfXJD';
  const expected = '(Lee Jae In / Kim Woo Seok / Choi Ye Bin)';
  print('expected: $expected\n');

  final variants = <String, List<Uint8List>>{
    'utf8 key/iv (published)': [
      Uint8List.fromList(utf8.encode('8056483646328763')),
      Uint8List.fromList(utf8.encode('6852612370185273')),
    ],
    'swapped': [
      Uint8List.fromList(utf8.encode('6852612370185273')),
      Uint8List.fromList(utf8.encode('8056483646328763')),
    ],
    'old kissasian key (kissAsianisAwesome trimmed)': [
      Uint8List.fromList(utf8.encode('kissAsianisAwesome').sublist(0, 16)),
      Uint8List.fromList(utf8.encode('6852612370185273')),
    ],
  };

  for (final e in variants.entries) {
    final k = e.value[0];
    final iv = e.value[1];
    print('=== ${e.key}  key.len=${k.length} iv.len=${iv.length} ===');
    final got = decryptCue(ct, k, iv);
    print('  got: $got');
    print('  hex: ${got.codeUnits.take(40).map((c) => c.toRadixString(16).padLeft(2, '0')).join(' ')}');
    print('  match: ${got == expected}\n');
  }
}
