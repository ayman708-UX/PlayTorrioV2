import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:path_provider/path_provider.dart';
import 'package:xml/xml.dart';

/// Extracts a cover image from EPUB bytes and writes it to the app's
/// documents directory under `audiobook_covers/<runId-or-name>.<ext>`.
/// Returns the local file path, or null if no cover could be found.
class EpubCover {
  static Future<String?> extractAndSave({
    required Uint8List epubBytes,
    required String saveAsName, // e.g. runId or sanitized filename (no ext)
  }) async {
    try {
      final archive = ZipDecoder().decodeBytes(epubBytes);
      final coverFile = _findCover(archive);
      if (coverFile == null) return null;

      final ext = _extFromName(coverFile.name);
      final dir = await getApplicationDocumentsDirectory();
      final coversDir = Directory('${dir.path}/audiobook_covers');
      if (!await coversDir.exists()) {
        await coversDir.create(recursive: true);
      }
      final outPath = '${coversDir.path}/$saveAsName$ext';
      final outFile = File(outPath);
      await outFile.writeAsBytes(coverFile.content as List<int>);
      return outPath;
    } catch (_) {
      return null;
    }
  }

  static ArchiveFile? _findCover(Archive archive) {
    // 1) Read META-INF/container.xml -> OPF path
    final container = _fileByName(archive, 'META-INF/container.xml');
    String? opfPath;
    if (container != null) {
      try {
        final doc = XmlDocument.parse(_decode(container));
        final rootfile = doc.findAllElements('rootfile').firstOrNull;
        opfPath = rootfile?.getAttribute('full-path');
      } catch (_) {}
    }

    if (opfPath != null) {
      final opfFile = _fileByName(archive, opfPath);
      if (opfFile != null) {
        try {
          final doc = XmlDocument.parse(_decode(opfFile));
          final basePath = _dirOf(opfPath);

          // Build manifest map: id -> {href, mediaType, properties}
          final manifest = <String, _ManifestItem>{};
          for (final item in doc.findAllElements('item')) {
            final id = item.getAttribute('id');
            final href = item.getAttribute('href');
            if (id == null || href == null) continue;
            manifest[id] = _ManifestItem(
              href: href,
              mediaType: item.getAttribute('media-type') ?? '',
              properties: item.getAttribute('properties') ?? '',
            );
          }

          // EPUB 3: properties="cover-image"
          for (final entry in manifest.entries) {
            if (entry.value.properties.contains('cover-image')) {
              final f = _fileByName(archive, _join(basePath, entry.value.href));
              if (f != null) return f;
            }
          }

          // EPUB 2: <meta name="cover" content="X"/>
          String? coverId;
          for (final m in doc.findAllElements('meta')) {
            if (m.getAttribute('name')?.toLowerCase() == 'cover') {
              coverId = m.getAttribute('content');
              break;
            }
          }
          if (coverId != null && manifest[coverId] != null) {
            final href = manifest[coverId]!.href;
            final f = _fileByName(archive, _join(basePath, href));
            if (f != null) return f;
          }

          // Fallback: any image whose id contains "cover"
          for (final entry in manifest.entries) {
            final id = entry.key.toLowerCase();
            final mt = entry.value.mediaType.toLowerCase();
            if (id.contains('cover') && mt.startsWith('image/')) {
              final f = _fileByName(archive, _join(basePath, entry.value.href));
              if (f != null) return f;
            }
          }

          // Last resort: first image in manifest
          for (final entry in manifest.entries) {
            if (entry.value.mediaType.toLowerCase().startsWith('image/')) {
              final f = _fileByName(archive, _join(basePath, entry.value.href));
              if (f != null) return f;
            }
          }
        } catch (_) {}
      }
    }

    // Absolute fallback: any file in archive named cover.*
    for (final f in archive.files) {
      final n = f.name.toLowerCase();
      if (!f.isFile) continue;
      if ((n.endsWith('.jpg') || n.endsWith('.jpeg') ||
              n.endsWith('.png') || n.endsWith('.webp')) &&
          n.contains('cover')) {
        return f;
      }
    }
    return null;
  }

  static ArchiveFile? _fileByName(Archive archive, String name) {
    final norm = name.replaceAll('\\', '/');
    for (final f in archive.files) {
      if (f.name.replaceAll('\\', '/') == norm) return f;
    }
    return null;
  }

  static String _decode(ArchiveFile f) {
    final bytes = f.content as List<int>;
    return String.fromCharCodes(bytes);
  }

  static String _dirOf(String p) {
    final i = p.lastIndexOf('/');
    return i < 0 ? '' : p.substring(0, i);
  }

  static String _join(String dir, String href) {
    if (dir.isEmpty) return href;
    return '$dir/$href';
  }

  static String _extFromName(String name) {
    final n = name.toLowerCase();
    if (n.endsWith('.jpeg')) return '.jpg';
    if (n.endsWith('.jpg')) return '.jpg';
    if (n.endsWith('.png')) return '.png';
    if (n.endsWith('.webp')) return '.webp';
    if (n.endsWith('.gif')) return '.gif';
    return '.img';
  }
}

class _ManifestItem {
  final String href;
  final String mediaType;
  final String properties;
  _ManifestItem({required this.href, required this.mediaType, required this.properties});
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
