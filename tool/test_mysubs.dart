// ignore_for_file: avoid_print
import 'package:http/http.dart' as http;

const base = 'https://my-subs.co';
const ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36';
final headers = {'User-Agent': ua, 'Accept': 'text/html,*/*', 'Referer': '$base/'};

String slugify(String s) => s.toLowerCase()
    .replaceAll(RegExp("[`'\u2019\"]"), '')
    .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
    .replaceAll(RegExp(r'^-+|-+$'), '');

int score(String c, String w) {
  if (c == w) return 1000;
  final ct = c.split('-').toSet();
  final wt = w.split('-').toSet();
  final ov = ct.intersection(wt).length;
  return ov * 10 - (ct.length - ov);
}

Future<void> main() async {
  const title = 'The Walking Dead';
  const season = 2, episode = 12;
  final searchUrl = '$base/search.php?key=${Uri.encodeQueryComponent(title)}';
  print('GET $searchUrl');
  final res = await http.get(Uri.parse(searchUrl), headers: headers);
  print('status=${res.statusCode} len=${res.body.length}');

  final re = RegExp("href=['\"]/showlistsubtitles-(\\d+)-([a-z0-9-]+)['\"]", caseSensitive: false);
  final matches = re.allMatches(res.body).toList();
  print('show matches: ${matches.length}');
  final want = slugify(title);
  String? bestId, bestSlug;
  int bestScore = -1 << 30;
  print('want slug: $want');
  for (final m in matches) {
    final id = m.group(1)!;
    final slug = m.group(2)!;
    final s = score(slug, want);
    print('  candidate: id=$id slug=$slug score=$s');
    if (s > bestScore) { bestScore = s; bestId = id; bestSlug = slug; }
  }
  print('best: id=$bestId slug=$bestSlug score=$bestScore');
  if (bestId == null) return;
  final path = '/versions-$bestId-$episode-$season-$bestSlug-subtitles';
  print('Picked: $path');

  final r2 = await http.get(Uri.parse('$base$path'), headers: headers);
  print('versions status=${r2.statusCode} len=${r2.body.length}');

  final rowRe = RegExp(
    r'<b>\s*Language\s*:\s*</b>\s*'
    r'<span class="flag-icon flag-icon-([a-z]{2,3})"\s+title="([^"]+)"[^>]*></span>\s*'
    r'<i>\s*([^<]+?)\s*</i>'
    r"[\s\S]{0,2000}?href='(/downloads/[^']+)'",
    caseSensitive: false,
  );
  final rows = rowRe.allMatches(r2.body).toList();
  print('rows matched: ${rows.length}');
  for (var i = 0; i < rows.length && i < 3; i++) {
    final m = rows[i];
    print('  cc=${m.group(1)} title=${m.group(2)} lang=${m.group(3)}');
  }
}
