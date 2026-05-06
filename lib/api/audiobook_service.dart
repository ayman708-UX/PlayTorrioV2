import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import 'package:html/parser.dart' as hp;
import 'local_server_service.dart';

class Audiobook {
  final String uuid;
  final String audioBookId;
  final String dynamicSlugId;
  final String title;
  final String coverImage;
  final String? source;
  final String? pageUrl;

  Audiobook({
    required this.uuid,
    required this.audioBookId,
    required this.dynamicSlugId,
    required this.title,
    required this.coverImage,
    this.source = 'tokybook',
    this.pageUrl,
  });

  String get thumbUrl {
    if (source == 'audiozaic' || source == 'goldenaudiobook' || source == 'appaudiobooks' || source == 'audionest' || source == 'paper2audio') return coverImage;
    return 'https://tokybook.com/images/$audioBookId';
  }

  factory Audiobook.fromJson(Map<String, dynamic> json) {
    final source = json['source'] ?? 'tokybook';
    final uuid = json['uuid'] ?? '';
    return Audiobook(
      uuid: uuid,
      audioBookId: json['audioBookId'] ?? '',
      dynamicSlugId: json['dynamicSlugId'] ?? '',
      title: json['title'] ?? '',
      coverImage: json['coverImage'] ?? '',
      source: source,
      pageUrl: json['pageUrl'] ?? ((source == 'audiozaic' || source == 'goldenaudiobook') ? uuid : null),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'uuid': uuid,
      'audioBookId': audioBookId,
      'dynamicSlugId': dynamicSlugId,
      'title': title,
      'coverImage': coverImage,
      'source': source,
      'pageUrl': pageUrl,
    };
  }
}

class AudiobookChapter {
  final String title;
  final String url;
  final Map<String, String>? headers;

  AudiobookChapter({required this.title, required this.url, this.headers});
}

class AudiobookService {
  static const String _baseUrl = 'https://tokybook.com/api/v1';
  
  // Standard user identity for API calls
  Map<String, dynamic> _getUserIdentity() {
    return {
      "ipAddress": "", // Let the server determine the IP from the request
      "userAgent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/145.0.0.0 Safari/537.36",
      "timestamp": DateTime.now().toUtc().toIso8601String(),
    };
  }

  Map<String, String> _getHeaders() {
    return {
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      'Origin': 'https://tokybook.com',
      'Referer': 'https://tokybook.com/',
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/145.0.0.0 Safari/537.36',
    };
  }

  Future<List<Audiobook>> getAudiobooks({int offset = 0, int limit = 12}) async {
    try {
      final payload = {
        "offset": offset,
        "limit": limit,
        "typeFilter": "audiobook",
        "slugIdFilter": null,
        "userIdentity": _getUserIdentity()
      };

      final response = await http.post(
        Uri.parse('$_baseUrl/search/audiobooks'),
        headers: _getHeaders(),
        body: json.encode(payload),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final List items = data['content'] ?? [];
        return items.map((json) => Audiobook.fromJson(json)).toList();
      }
    } catch (e) {
      debugPrint('AudiobookService Error (getAudiobooks): $e');
    }
    return [];
  }

  String _cleanTitle(String title) {
    return title
        .replaceAll(RegExp(r'\[Listen\]', caseSensitive: false), '')
        .replaceAll(RegExp(r'\[Download\]', caseSensitive: false), '')
        .replaceAll(RegExp(r'Audiobook', caseSensitive: false), '')
        .replaceAll(RegExp(r'Online', caseSensitive: false), '')
        .split('–').last // Handles "Author – Title"
        .split('-').last // Handles "Author - Title"
        .trim();
  }

  String _normalizeTitle(String title) {
    return _cleanTitle(title).toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  }

  int _relevanceScore(String title, String query) {
    final titleLower = title.toLowerCase();
    if (titleLower == query) return 0; // Exact match
    if (titleLower.startsWith(query)) return 1; // Starts with query
    if (titleLower.contains(query)) return 2; // Contains query
    // Partial word matching — count how many query words appear in the title
    final queryWords = query.split(RegExp(r'\s+'));
    int matches = queryWords.where((w) => titleLower.contains(w)).length;
    if (matches == queryWords.length) return 3; // All words present
    return 4 + (queryWords.length - matches); // Fewer matches = higher score
  }

  Future<List<Audiobook>> searchAudiobooks(String query) async {
    try {
      // Run all scrapers in parallel for speed
      final results = await Future.wait([
        _searchGoldenAudiobook(query),
        _searchAppAudiobooks(query),
        _searchTokybook(query),
        _searchAudiozaic(query),
        _searchAudionest(query),
      ]);

      final goldenResults = results[0];
      final appAudioResults = results[1];
      final tokyResults = results[2];
      final audiozaicResults = results[3];
      final audionestResults = results[4];
      
      final Map<String, Audiobook> uniqueBooks = {};
      
      // 1. Add Golden results first (Primary)
      for (var book in goldenResults) {
        final key = _normalizeTitle(book.title);
        if (key.isNotEmpty) uniqueBooks[key] = book;
      }
      
      // 2. Add AppAudiobooks results
      for (var book in appAudioResults) {
        final key = _normalizeTitle(book.title);
        if (key.isNotEmpty && !uniqueBooks.containsKey(key)) {
          uniqueBooks[key] = book;
        }
      }
      
      // 3. Add Tokybook results
      for (var book in tokyResults) {
        final key = _normalizeTitle(book.title);
        if (key.isNotEmpty && !uniqueBooks.containsKey(key)) {
          uniqueBooks[key] = book;
        }
      }
      
      // 4. Add Audiozaic results
      for (var book in audiozaicResults) {
        final key = _normalizeTitle(book.title);
        if (key.isNotEmpty && !uniqueBooks.containsKey(key)) {
          uniqueBooks[key] = book;
        }
      }

      // 5. Add Audionest results
      for (var book in audionestResults) {
        final key = _normalizeTitle(book.title);
        if (key.isNotEmpty && !uniqueBooks.containsKey(key)) {
          uniqueBooks[key] = book;
        }
      }

      // Sort by relevance to search query
      final queryNorm = query.toLowerCase().trim();
      final bookList = uniqueBooks.values.toList();
      bookList.sort((a, b) => _relevanceScore(a.title, queryNorm).compareTo(_relevanceScore(b.title, queryNorm)));
      return bookList;
    } catch (e) {
      debugPrint('AudiobookService Error (searchAudiobooks): $e');
    }
    return [];
  }

  Future<List<Audiobook>> _searchTokybook(String query) async {
    try {
      final payload = {
        "query": query,
        "offset": 0,
        "limit": 20,
        "userIdentity": _getUserIdentity()
      };

      final response = await http.post(
        Uri.parse('$_baseUrl/search/instant'),
        headers: _getHeaders(),
        body: json.encode(payload),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final List items = data['content'] ?? [];
        return items.map((json) => Audiobook.fromJson(json)).toList();
      }
    } catch (e) {
      debugPrint('AudiobookService Error (_searchTokybook): $e');
    }
    return [];
  }

  Future<List<Audiobook>> _searchAudiozaic(String query) async {
    try {
      final searchUrl = 'https://audiozaic.com/?s=${Uri.encodeComponent(query)}';
      final response = await http.get(Uri.parse(searchUrl), headers: {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
      });

      if (response.statusCode != 200) return [];

      final document = hp.parse(response.body);
      final articles = document.querySelectorAll('article.vce-post');
      
      List<Audiobook> results = [];
      for (var article in articles) {
        final titleElement = article.querySelector('h2.entry-title a');
        final pageUrl = titleElement?.attributes['href'] ?? '';
        var title = _cleanTitle(titleElement?.text ?? '');
        
        final imgElement = article.querySelector('div.meta-image img');
        var coverUrl = imgElement?.attributes['data-src'] ?? imgElement?.attributes['src'] ?? '';
        
        // Try to get high quality image by removing dimension suffix (e.g., -145x100.jpg)
        if (coverUrl.contains('-') && coverUrl.contains('x')) {
          coverUrl = coverUrl.replaceFirstMapped(RegExp(r'-\d+x\d+\.(jpg|jpeg|png|webp)'), (match) => '.${match.group(1)}');
        }

        if (pageUrl.isNotEmpty) {
          // Extract slug from URL: https://audiozaic.com/slug/ -> slug
          final uri = Uri.parse(pageUrl);
          final pathSegments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
          final slug = pathSegments.isNotEmpty ? pathSegments.last : pageUrl.hashCode.toString();

          results.add(Audiobook(
            uuid: pageUrl, 
            audioBookId: 'az_$slug', // Prefix to avoid collisions
            dynamicSlugId: pageUrl,
            title: title,
            coverImage: coverUrl,
            source: 'audiozaic',
            pageUrl: pageUrl,
          ));
        }
      }
      return results;
    } catch (e) {
      debugPrint('AudiobookService Error (_searchAudiozaic): $e');
    }
    return [];
  }

  Future<List<Audiobook>> _searchGoldenAudiobook(String query) async {
    try {
      final searchUrl = 'https://goldenaudiobook.net/?s=${Uri.encodeComponent(query)}';
      final response = await http.get(Uri.parse(searchUrl), headers: {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
      });

      if (response.statusCode != 200) return [];

      final document = hp.parse(response.body);
      final articles = document.querySelectorAll('li.ilovewp-post');
      
      List<Audiobook> results = [];
      for (var article in articles) {
        final titleElement = article.querySelector('h2.title-post a');
        final pageUrl = titleElement?.attributes['href'] ?? '';
        var title = _cleanTitle(titleElement?.text ?? '');
        
        final imgElement = article.querySelector('div.post-cover img');
        var coverUrl = imgElement?.attributes['data-src'] ?? imgElement?.attributes['src'] ?? '';
        
        // Better quality image
        if (coverUrl.contains('-') && coverUrl.contains('x')) {
          coverUrl = coverUrl.replaceFirstMapped(RegExp(r'-\d+x\d+\.(jpg|jpeg|png|webp)'), (match) => '.${match.group(1)}');
        }

        if (pageUrl.isNotEmpty) {
          final uri = Uri.parse(pageUrl);
          final pathSegments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
          final slug = pathSegments.isNotEmpty ? pathSegments.last : pageUrl.hashCode.toString();

          results.add(Audiobook(
            uuid: pageUrl, 
            audioBookId: 'ga_$slug',
            dynamicSlugId: pageUrl,
            title: title,
            coverImage: coverUrl,
            source: 'goldenaudiobook',
            pageUrl: pageUrl,
          ));
        }
      }
      return results;
    } catch (e) {
      debugPrint('AudiobookService Error (_searchGoldenAudiobook): $e');
    }
    return [];
  }

  Future<List<AudiobookChapter>> getChapters(Audiobook book) async {
    if (book.source == 'paper2audio') {
      final url = book.pageUrl;
      if (url == null || url.isEmpty) return [];
      return [AudiobookChapter(title: book.title, url: url)];
    }
    if (book.source == 'goldenaudiobook') {
      return _getGoldenChapters(book);
    }
    if (book.source == 'audiozaic') {
      return _getAudiozaicChapters(book);
    }
    if (book.source == 'appaudiobooks') {
      return _getAppAudiobooksChapters(book);
    }
    if (book.source == 'audionest') {
      return _getAudionestChapters(book);
    }
    return _getTokyChapters(book);
  }

  Future<List<AudiobookChapter>> _getTokyChapters(Audiobook book) async {
    try {
      // 1. Get post details
      final detailsPayload = {
        "dynamicSlugId": book.dynamicSlugId,
        "userIdentity": _getUserIdentity()
      };

      final detailsRes = await http.post(Uri.parse('$_baseUrl/search/post-details'), headers: _getHeaders(), body: json.encode(detailsPayload));
      if (detailsRes.statusCode != 200) return [];

      final detailsData = json.decode(detailsRes.body);
      final String? token = detailsData['postDetailToken'];
      if (token == null) return [];

      // 2. Fetch the playlist
      final playlistPayload = {
        "audioBookId": book.audioBookId,
        "postDetailToken": token,
        "userIdentity": _getUserIdentity()
      };

      final playlistRes = await http.post(Uri.parse('$_baseUrl/playlist'), headers: _getHeaders(), body: json.encode(playlistPayload));
      if (playlistRes.statusCode != 200) return [];

      final data = json.decode(playlistRes.body);
      final String streamToken = data['streamToken'] ?? '';
      final List tracks = data['tracks'] ?? [];
      
      final baseAudioUrl = 'https://tokybook.com/api/v1/public/audio/';
      final proxy = LocalServerService();

      return tracks.map((t) {
        final src = t['src'] ?? '';
        final title = t['trackTitle'] ?? 'Track';
        
        // Encode each segment of the path to match browser behavior exactly
        final encodedSrc = src.split('/').map((p) => Uri.encodeComponent(p)).join('/');
        final fullTrackSrc = '/api/v1/public/audio/$encodedSrc';
        final finalUrl = '$baseAudioUrl$src';
        
        // Route through our local specialized proxy
        final proxiedUrl = proxy.getTokyProxyUrl(
          finalUrl, 
          book.audioBookId, 
          streamToken, 
          fullTrackSrc
        );

        return AudiobookChapter(title: title, url: proxiedUrl);
      }).toList();
    } catch (e) {
      debugPrint('AudiobookService Error (_getTokyChapters): $e');
    }
    return [];
  }

  Future<List<AudiobookChapter>> _getGoldenChapters(Audiobook book) async {
    try {
      if (book.pageUrl == null) return [];

      final pageRes = await http.get(Uri.parse(book.pageUrl!), headers: {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
      });
      if (pageRes.statusCode != 200) return [];

      final document = hp.parse(pageRes.body);
      final audios = document.querySelectorAll('audio.wp-audio-shortcode');
      
      List<AudiobookChapter> chapters = [];
      for (int i = 0; i < audios.length; i++) {
        final sourceTag = audios[i].querySelector('source');
        final streamUrl = sourceTag?.attributes['src'] ?? '';
        
        if (streamUrl.isNotEmpty) {
          chapters.add(AudiobookChapter(
            title: 'Part ${i + 1}', 
            url: streamUrl,
          ));
        }
      }
      return chapters;
    } catch (e) {
      debugPrint('AudiobookService Error (_getGoldenChapters): $e');
    }
    return [];
  }

  Future<List<AudiobookChapter>> _getAudiozaicChapters(Audiobook book) async {
    try {
      if (book.pageUrl == null) return [];

      // 1. Fetch book page to get actual cover and listen link
      final pageRes = await http.get(Uri.parse(book.pageUrl!), headers: {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
      });
      if (pageRes.statusCode != 200) return [];

      final document = hp.parse(pageRes.body);
      
      // Update cover image if found (better quality usually)
      final mainImg = document.querySelector('div.entry-content img');
      if (mainImg != null) {
        final newCover = mainImg.attributes['data-src'] ?? mainImg.attributes['src'] ?? '';
        if (newCover.isNotEmpty) {
          // Note: we can't easily update the 'book' object here but it will use the better cover if it was already saved
        }
      }

      // Find the listen button which has the slug32
      final listenBtn = document.querySelector('button#listen-button');
      final onclick = listenBtn?.attributes['onclick'] ?? '';
      final urlMatch = RegExp(r"window\.open\('([^']+)'").firstMatch(onclick);
      var listenUrl = urlMatch?.group(1);

      if (listenUrl == null) return [];

      if (listenUrl.startsWith('/')) {
        listenUrl = 'https://audiozaic.com$listenUrl';
      } else if (!listenUrl.startsWith('http')) {
        listenUrl = 'https://audiozaic.com/$listenUrl';
      }

      // 2. Fetch the file-audio page
      final audioPageRes = await http.get(Uri.parse(listenUrl), headers: {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
        'Referer': book.pageUrl!,
      });
      if (audioPageRes.statusCode != 200) return [];

      final audioDoc = hp.parse(audioPageRes.body);
      final tracks = audioDoc.querySelectorAll('div.track');
      
      List<AudiobookChapter> chapters = [];
      for (var track in tracks) {
        final title = track.querySelector('span.songtitle')?.text ?? 'Part';
        final audioSource = track.querySelector('audio source');
        var streamUrl = audioSource?.attributes['src'] ?? '';
        
        if (streamUrl.isEmpty) {
          final link = track.querySelector('div.albumtrack a');
          streamUrl = link?.attributes['href'] ?? '';
        }

        if (streamUrl.isNotEmpty) {
          chapters.add(AudiobookChapter(
            title: title, 
            url: streamUrl,
            headers: {
              'Referer': 'https://audiozaic.com/',
              'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
            }
          ));
        }
      }
      return chapters;
    } catch (e) {
      debugPrint('AudiobookService Error (_getAudiozaicChapters): $e');
    }
    return [];
  }

  // --- AppAudiobooks.net ---

  Future<List<Audiobook>> _searchAppAudiobooks(String query) async {
    try {
      final searchUrl =
          'https://appaudiobooks.com/?s=${Uri.encodeComponent(query)}';

      final response = await http.get(Uri.parse(searchUrl), headers: {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
        'Referer': 'https://appaudiobooks.com/',
      });

      if (response.statusCode != 200) return [];

      final document = hp.parse(response.body);
      // Standard WordPress search results: each post has <h2 class="entry-title"><a href="...">Title</a></h2>
      final links = document.querySelectorAll('h2.entry-title a, h2.post-title a, article h2 a');

      List<Audiobook> results = [];
      final seen = <String>{};

      for (var link in links) {
        final pageUrl = link.attributes['href'] ?? '';
        if (pageUrl.isEmpty || !pageUrl.contains('appaudiobooks.')) continue;
        if (seen.contains(pageUrl)) continue;
        seen.add(pageUrl);

        var title = _cleanTitle(link.text.trim());
        if (title.isEmpty) continue;

        final uri = Uri.parse(pageUrl);
        final pathSegments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
        final slug = pathSegments.isNotEmpty ? pathSegments.last : pageUrl.hashCode.toString();

        results.add(Audiobook(
          uuid: pageUrl,
          audioBookId: 'aab_$slug',
          dynamicSlugId: pageUrl,
          title: title,
          coverImage: '',
          source: 'appaudiobooks',
          pageUrl: pageUrl,
        ));
      }

      // Fetch covers from each result page in parallel
      final futures = results.map((book) async {
        try {
          final cover = await _fetchAppAudiobookCover(book.pageUrl!);
          if (cover.isNotEmpty) {
            return Audiobook(
              uuid: book.uuid,
              audioBookId: book.audioBookId,
              dynamicSlugId: book.dynamicSlugId,
              title: book.title,
              coverImage: cover,
              source: book.source,
              pageUrl: book.pageUrl,
            );
          }
        } catch (_) {}
        return book;
      }).toList();

      return await Future.wait(futures);
    } catch (e) {
      debugPrint('AudiobookService Error (_searchAppAudiobooks): $e');
    }
    return [];
  }

  Future<String> _fetchAppAudiobookCover(String pageUrl) async {
    try {
      final res = await http.get(Uri.parse(pageUrl), headers: {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
      });
      if (res.statusCode != 200) return '';
      final doc = hp.parse(res.body);
      final img = doc.querySelector('.wp-caption img') ?? doc.querySelector('.entry img');
      return img?.attributes['src'] ?? '';
    } catch (_) {}
    return '';
  }

  Future<List<AudiobookChapter>> _getAppAudiobooksChapters(Audiobook book) async {
    try {
      if (book.pageUrl == null) return [];

      final pageRes = await http.get(Uri.parse(book.pageUrl!), headers: {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
      });
      if (pageRes.statusCode != 200) return [];

      final document = hp.parse(pageRes.body);
      final audios = document.querySelectorAll('audio.wp-audio-shortcode');

      List<AudiobookChapter> chapters = [];
      for (int i = 0; i < audios.length; i++) {
        final sourceTag = audios[i].querySelector('source');
        var streamUrl = sourceTag?.attributes['src'] ?? '';

        // Strip query params like ?_=1
        if (streamUrl.contains('?')) {
          streamUrl = streamUrl.substring(0, streamUrl.indexOf('?'));
        }

        if (streamUrl.isNotEmpty) {
          chapters.add(AudiobookChapter(
            title: 'Chapter ${i + 1}',
            url: streamUrl,
          ));
        }
      }
      return chapters;
    } catch (e) {
      debugPrint('AudiobookService Error (_getAppAudiobooksChapters): $e');
    }
    return [];
  }

  // --- Audionest (audionestapp.com) ---
  // Reverse-engineered from the official Android APK.
  // Pipeline:
  //   1. Search via their hosted Meilisearch instance (key shipped in the APK's .env)
  //   2. Fetch chapter URLs from Cloud Firestore using the integer `book_id` field
  //   3. Anonymous Firebase auth provides a 1h idToken, refreshed lazily on 401/expiry
  // MP3s are public DigitalOcean Spaces URLs — no Referer/auth required for playback.

  static const String _audionestMeiliBase = 'https://search.audionestapp.com';
  static const String _audionestMeiliKey =
      'MWJiNWM0MjA2N2ZkM2RiMDNhNWFmNGNk';
  static const String _audionestFirebaseApiKey =
      'AIzaSyAG-z_yl0_55NEYTEKGoVJyixtHG-FhnfA';
  static const String _audionestFirestoreBase =
      'https://firestore.googleapis.com/v1/projects/learningfirebase-ae02f/databases/(default)/documents';

  String? _audionestIdToken;
  DateTime? _audionestIdTokenExpiry;

  Future<String?> _audionestEnsureToken({bool force = false}) async {
    if (!force &&
        _audionestIdToken != null &&
        _audionestIdTokenExpiry != null &&
        DateTime.now().isBefore(_audionestIdTokenExpiry!)) {
      return _audionestIdToken;
    }
    try {
      final res = await http.post(
        Uri.parse(
            'https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=$_audionestFirebaseApiKey'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'returnSecureToken': true}),
      );
      if (res.statusCode != 200) {
        debugPrint(
            'AudiobookService Error (audionest signUp): ${res.statusCode} ${res.body}');
        return null;
      }
      final data = json.decode(res.body) as Map<String, dynamic>;
      _audionestIdToken = data['idToken'] as String?;
      final expiresIn = int.tryParse('${data['expiresIn'] ?? '3600'}') ?? 3600;
      // Refresh 60s before actual expiry to be safe.
      _audionestIdTokenExpiry =
          DateTime.now().add(Duration(seconds: expiresIn - 60));
      return _audionestIdToken;
    } catch (e) {
      debugPrint('AudiobookService Error (_audionestEnsureToken): $e');
      return null;
    }
  }

  Future<List<Audiobook>> _searchAudionest(String query) async {
    try {
      final res = await http.post(
        Uri.parse('$_audionestMeiliBase/indexes/trackfiles/search'),
        headers: {
          'Authorization': 'Bearer $_audionestMeiliKey',
          'Content-Type': 'application/json',
        },
        body: json.encode({'q': query, 'limit': 30}),
      );
      if (res.statusCode != 200) return [];
      final data = json.decode(res.body) as Map<String, dynamic>;
      final hits = (data['hits'] as List?) ?? const [];

      final List<Audiobook> results = [];
      for (final raw in hits) {
        if (raw is! Map) continue;
        final hit = raw.cast<String, dynamic>();
        final id = '${hit['id'] ?? ''}'.trim();
        final title = (hit['title'] as String?)?.trim() ?? '';
        if (id.isEmpty || title.isEmpty) continue;

        final cover = (hit['thumbnailUrl'] as String?)?.trim() ??
            (hit['img_prefix'] as String?)?.trim() ??
            '';

        results.add(Audiobook(
          uuid: id,
          audioBookId: id,
          dynamicSlugId: id,
          title: title,
          coverImage: cover,
          source: 'audionest',
          pageUrl: id,
        ));
      }
      return results;
    } catch (e) {
      debugPrint('AudiobookService Error (_searchAudionest): $e');
    }
    return [];
  }

  Future<http.Response> _audionestFirestoreQuery(
      String body, String token) async {
    return http.post(
      Uri.parse('$_audionestFirestoreBase:runQuery'),
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      },
      body: body,
    );
  }

  Future<List<AudiobookChapter>> _getAudionestChapters(Audiobook book) async {
    try {
      final bookId = int.tryParse(book.audioBookId);
      if (bookId == null) return [];

      final reqBody = json.encode({
        'structuredQuery': {
          'from': [
            {'collectionId': 'TrackFiles'}
          ],
          'where': {
            'fieldFilter': {
              'field': {'fieldPath': 'book_id'},
              'op': 'EQUAL',
              'value': {'integerValue': '$bookId'},
            }
          },
          'limit': 1,
        }
      });

      var token = await _audionestEnsureToken();
      if (token == null) return [];

      var res = await _audionestFirestoreQuery(reqBody, token);
      if (res.statusCode == 401 || res.statusCode == 403) {
        // Token rejected — force a fresh anonymous sign-in and retry once.
        token = await _audionestEnsureToken(force: true);
        if (token == null) return [];
        res = await _audionestFirestoreQuery(reqBody, token);
      }
      if (res.statusCode != 200) return [];

      // runQuery returns a JSON array of {document: {...}} entries.
      final decoded = json.decode(res.body);
      if (decoded is! List) return [];

      Map<String, dynamic>? doc;
      for (final entry in decoded) {
        if (entry is Map && entry['document'] is Map) {
          doc = (entry['document'] as Map).cast<String, dynamic>();
          break;
        }
      }
      if (doc == null) return [];

      final fields = (doc['fields'] as Map?)?.cast<String, dynamic>();
      if (fields == null) return [];

      final urlLink = (fields['urlLink'] as Map?)?.cast<String, dynamic>();
      final values = (urlLink?['arrayValue'] as Map?)?['values'];
      if (values is! List) return [];

      final List<String> urls = [];
      for (final v in values) {
        if (v is Map && v['stringValue'] is String) {
          final u = (v['stringValue'] as String).trim();
          if (u.isNotEmpty) urls.add(u);
        }
      }
      if (urls.isEmpty) return [];

      final chapters = <AudiobookChapter>[];
      for (var i = 0; i < urls.length; i++) {
        final title = urls.length == 1 ? 'Full Audiobook' : 'Chapter ${i + 1}';
        chapters.add(AudiobookChapter(title: title, url: urls[i]));
      }
      return chapters;
    } catch (e) {
      debugPrint('AudiobookService Error (_getAudionestChapters): $e');
    }
    return [];
  }
}
