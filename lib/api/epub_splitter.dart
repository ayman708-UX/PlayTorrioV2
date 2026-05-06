import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:xml/xml.dart';

class EpubPart {
  final String suggestedName;
  final Uint8List bytes;
  final int wordCount;
  EpubPart({
    required this.suggestedName,
    required this.bytes,
    required this.wordCount,
  });
}

/// Counts words in an EPUB and splits it into <= [maxWordsPerPart] chunks
/// at chapter (spine) boundaries. The split EPUBs reuse the original
/// resources and only rewrite the OPF spine to reference half the documents.
class EpubSplitter {
  static const int maxWordsPerPart = 250000;

  /// Returns total word count across all spine documents.
  static Future<int> countWords(File epub) async {
    final bytes = await epub.readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);
    final spine = _readSpine(archive);
    int total = 0;
    for (final entry in spine.spineFiles) {
      final file = archive.findFile(entry);
      if (file == null) continue;
      total += _countWordsHtml(_decode(file));
    }
    return total;
  }

  /// If the EPUB is under the limit, returns one part containing the
  /// original bytes. Otherwise splits at the spine boundary nearest to
  /// the cumulative midpoint and returns two parts.
  static Future<List<EpubPart>> splitIfNeeded(File epub) async {
    final originalBytes = await epub.readAsBytes();
    final archive = ZipDecoder().decodeBytes(originalBytes);
    final spineInfo = _readSpine(archive);

    final perFileCounts = <int>[];
    int total = 0;
    for (final entry in spineInfo.spineFiles) {
      final file = archive.findFile(entry);
      final c = file == null ? 0 : _countWordsHtml(_decode(file));
      perFileCounts.add(c);
      total += c;
    }

    final originalName = _basename(epub.path)
        .replaceAll(RegExp(r'\.epub$', caseSensitive: false), '');

    if (total <= maxWordsPerPart || perFileCounts.length < 2) {
      return [
        EpubPart(
          suggestedName: '$originalName.epub',
          bytes: originalBytes,
          wordCount: total,
        ),
      ];
    }

    // Find split index closest to cumulative half (chapter boundary).
    final half = total ~/ 2;
    int cum = 0;
    int splitIdx = perFileCounts.length;
    for (int i = 0; i < perFileCounts.length; i++) {
      cum += perFileCounts[i];
      if (cum >= half) {
        splitIdx = i + 1;
        break;
      }
    }
    if (splitIdx >= perFileCounts.length) splitIdx = perFileCounts.length - 1;
    if (splitIdx < 1) splitIdx = 1;

    final part1Idrefs = spineInfo.spineIdrefs.sublist(0, splitIdx);
    final part2Idrefs = spineInfo.spineIdrefs.sublist(splitIdx);
    final part1Words =
        perFileCounts.sublist(0, splitIdx).fold<int>(0, (a, b) => a + b);
    final part2Words =
        perFileCounts.sublist(splitIdx).fold<int>(0, (a, b) => a + b);

    final part1Bytes = _rebuildEpub(originalBytes, spineInfo, part1Idrefs);
    final part2Bytes = _rebuildEpub(originalBytes, spineInfo, part2Idrefs);

    return [
      EpubPart(
        suggestedName: '$originalName - Part 1.epub',
        bytes: part1Bytes,
        wordCount: part1Words,
      ),
      EpubPart(
        suggestedName: '$originalName - Part 2.epub',
        bytes: part2Bytes,
        wordCount: part2Words,
      ),
    ];
  }

  static Uint8List _rebuildEpub(
    Uint8List originalBytes,
    _SpineInfo info,
    List<String> keepIdrefs,
  ) {
    final archive = ZipDecoder().decodeBytes(originalBytes);
    final keepSet = keepIdrefs.toSet();

    // Rewrite OPF: keep manifest as-is (so resources/styles/images still resolve)
    // but only include itemrefs for the chosen spine slice.
    final opfFile = archive.findFile(info.opfPath)!;
    final doc = XmlDocument.parse(_decode(opfFile));
    final spineEl = doc.findAllElements('spine', namespace: '*').first;
    final kept = <XmlElement>[];
    for (final ir in spineEl.findElements('itemref', namespace: '*').toList()) {
      final idref = ir.getAttribute('idref');
      if (idref != null && keepSet.contains(idref)) {
        kept.add(ir.copy());
      }
    }
    spineEl.children.clear();
    for (final ir in kept) {
      spineEl.children.add(ir);
    }
    final newOpfBytes = Uint8List.fromList(utf8.encode(doc.toXmlString()));

    // Build a new archive. The EPUB spec requires `mimetype` to be the first
    // entry and stored uncompressed; everything else can be deflated.
    final out = Archive();
    for (final f in archive.files) {
      if (!f.isFile) continue;
      Uint8List bytes;
      if (f.name == info.opfPath) {
        bytes = newOpfBytes;
      } else {
        final content = f.content as List<int>;
        bytes = content is Uint8List ? content : Uint8List.fromList(content);
      }
      final newFile = ArchiveFile.bytes(f.name, bytes);
      if (f.name == 'mimetype') {
        newFile.compression = CompressionType.none;
      }
      out.add(newFile);
    }
    final encoded = ZipEncoder().encode(out);
    return encoded is Uint8List ? encoded : Uint8List.fromList(encoded);
  }

  static _SpineInfo _readSpine(Archive archive) {
    final container = archive.findFile('META-INF/container.xml');
    if (container == null) {
      throw Exception('Not a valid EPUB (missing META-INF/container.xml)');
    }
    final containerDoc = XmlDocument.parse(_decode(container));
    final rootfile =
        containerDoc.findAllElements('rootfile', namespace: '*').first;
    final opfPath = rootfile.getAttribute('full-path');
    if (opfPath == null) throw Exception('container.xml missing full-path');

    final opfFile = archive.findFile(opfPath);
    if (opfFile == null) throw Exception('OPF not found at $opfPath');
    final opfDoc = XmlDocument.parse(_decode(opfFile));

    final manifest = <String, String>{};
    for (final item in opfDoc.findAllElements('item', namespace: '*')) {
      final id = item.getAttribute('id');
      final href = item.getAttribute('href');
      if (id != null && href != null) manifest[id] = href;
    }

    final basePath = _dirname(opfPath);

    final spineIdrefs = <String>[];
    final spineFiles = <String>[];
    for (final ir in opfDoc.findAllElements('itemref', namespace: '*')) {
      final idref = ir.getAttribute('idref');
      if (idref == null) continue;
      final href = manifest[idref];
      if (href == null) continue;
      spineIdrefs.add(idref);
      spineFiles.add(_joinPath(basePath, href));
    }

    return _SpineInfo(
      opfPath: opfPath,
      spineIdrefs: spineIdrefs,
      spineFiles: spineFiles,
    );
  }

  static String _decode(ArchiveFile f) {
    final content = f.content as List<int>;
    try {
      return utf8.decode(content, allowMalformed: true);
    } catch (_) {
      return String.fromCharCodes(content);
    }
  }

  static int _countWordsHtml(String content) {
    try {
      final doc = html_parser.parse(content);
      final text = doc.body?.text ?? doc.documentElement?.text ?? '';
      return _countWords(text);
    } catch (_) {
      final stripped = content.replaceAll(RegExp(r'<[^>]+>'), ' ');
      return _countWords(stripped);
    }
  }

  static int _countWords(String text) {
    return RegExp(r'\S+').allMatches(text).length;
  }

  static String _dirname(String path) {
    final i = path.lastIndexOf('/');
    return i < 0 ? '' : path.substring(0, i);
  }

  static String _basename(String path) {
    final i = path.lastIndexOf(Platform.pathSeparator);
    final base = i < 0 ? path : path.substring(i + 1);
    final j = base.lastIndexOf('/');
    return j < 0 ? base : base.substring(j + 1);
  }

  static String _joinPath(String dir, String href) {
    if (dir.isEmpty) return href;
    return '$dir/$href';
  }
}

class _SpineInfo {
  final String opfPath;
  final List<String> spineIdrefs;
  final List<String> spineFiles;
  _SpineInfo({
    required this.opfPath,
    required this.spineIdrefs,
    required this.spineFiles,
  });
}
