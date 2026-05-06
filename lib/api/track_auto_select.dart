import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

/// Common ISO-639-1 / ISO-639-2 codes mapped to display names.
/// Order matters in the picker UI — most common first. Aliases include
/// codes, English names, native names, and a few common foreign-language
/// renderings so that fuzzy detection on a track's `language` or `title`
/// field works no matter how the source labels it.
const List<MapEntry<String, List<String>>> kTrackLanguageOptions = [
  MapEntry('English',     ['en', 'eng', 'english', 'ingles', 'inglés', 'anglais', 'inglese', 'angielski']),
  MapEntry('Arabic',      ['ar', 'ara', 'arabic', 'عربي', 'العربية', 'arabe', 'árabe']),
  MapEntry('Spanish',     ['es', 'spa', 'esp', 'spanish', 'castellano', 'español', 'espanol', 'castilian', 'latino', 'latin american', 'es-la', 'es-419']),
  MapEntry('French',      ['fr', 'fra', 'fre', 'french', 'francais', 'français', 'francés', 'francese']),
  MapEntry('German',      ['de', 'deu', 'ger', 'german', 'deutsch', 'aleman', 'alemán', 'tedesco']),
  MapEntry('Italian',     ['it', 'ita', 'italian', 'italiano']),
  MapEntry('Portuguese',  ['pt', 'por', 'portuguese', 'português', 'portugues', 'brasileiro', 'brazilian', 'pt-br', 'pt-pt']),
  MapEntry('Russian',     ['ru', 'rus', 'russian', 'русский', 'рус']),
  MapEntry('Japanese',    ['ja', 'jpn', 'jap', 'japanese', '日本語', 'nihongo']),
  MapEntry('Chinese',     ['zh', 'zho', 'chi', 'chs', 'cht', 'chinese', 'mandarin', 'cantonese', '中文', '普通话', '粉语', 'zh-cn', 'zh-tw', 'zh-hk']),
  MapEntry('Korean',      ['ko', 'kor', 'korean', '한국어']),
  MapEntry('Hindi',       ['hi', 'hin', 'hindi', 'हिन्दी']),
  MapEntry('Turkish',     ['tr', 'tur', 'turkish', 'türkçe', 'turkce']),
  MapEntry('Polish',      ['pl', 'pol', 'polish', 'polski']),
  MapEntry('Dutch',       ['nl', 'nld', 'dut', 'dutch', 'nederlands', 'flemish', 'vlaams']),
  MapEntry('Swedish',     ['sv', 'swe', 'swedish', 'svenska']),
  MapEntry('Norwegian',   ['no', 'nor', 'nob', 'nno', 'norwegian', 'norsk']),
  MapEntry('Danish',      ['da', 'dan', 'danish', 'dansk']),
  MapEntry('Finnish',     ['fi', 'fin', 'finnish', 'suomi']),
  MapEntry('Czech',       ['cs', 'ces', 'cze', 'czech', 'čeština', 'cestina']),
  MapEntry('Greek',       ['el', 'ell', 'gre', 'greek', 'Ελληνικά', 'ellinika']),
  MapEntry('Hebrew',      ['he', 'heb', 'iw', 'hebrew', 'עברית']),
  MapEntry('Indonesian',  ['id', 'ind', 'indonesian', 'bahasa indonesia']),
  MapEntry('Thai',        ['th', 'tha', 'thai', 'ไทย']),
  MapEntry('Vietnamese',  ['vi', 'vie', 'vietnamese', 'tiếng việt']),
  MapEntry('Ukrainian',   ['uk', 'ukr', 'ukrainian', 'українська']),
  MapEntry('Romanian',    ['ro', 'ron', 'rum', 'romanian', 'română']),
  MapEntry('Hungarian',   ['hu', 'hun', 'hungarian', 'magyar']),
  MapEntry('Bulgarian',   ['bg', 'bul', 'bulgarian', 'български']),
  MapEntry('Persian',     ['fa', 'fas', 'per', 'persian', 'farsi', 'فارسی']),
];

const List<String> kTrackLanguageDisplayNames = [
  'None',
  'English', 'Arabic', 'Spanish', 'French', 'German', 'Italian',
  'Portuguese', 'Russian', 'Japanese', 'Chinese', 'Korean', 'Hindi',
  'Turkish', 'Polish', 'Dutch', 'Swedish', 'Norwegian', 'Danish',
  'Finnish', 'Czech', 'Greek', 'Hebrew', 'Indonesian', 'Thai',
  'Vietnamese', 'Ukrainian', 'Romanian', 'Hungarian', 'Bulgarian',
  'Persian',
];

/// True if [track]'s language/title matches the human-readable [displayName]
/// (e.g. "English"). Falls back to substring matching on the title.
bool _matchesLanguage(String displayName, String? language, String? title) {
  return matchesPreferredLanguage(displayName,
      language: language, title: title);
}

/// Public version of [_matchesLanguage] — useful for matching external
/// subtitle map entries (which carry `language`/`display` keys, not real
/// SubtitleTrack objects yet).
bool matchesPreferredLanguage(String displayName,
    {String? language, String? title}) {
  if (displayName == 'None' || displayName.isEmpty) return false;
  final aliases = <String>{
    displayName.toLowerCase(),
    ...kTrackLanguageOptions
        .firstWhere((e) => e.key == displayName,
            orElse: () => const MapEntry('', <String>[]))
        .value
        .map((s) => s.toLowerCase()),
  }..removeWhere((s) => s.isEmpty);
  if (aliases.isEmpty) return false;

  final lang = _normalize(language);
  final ttl = _normalize(title);

  // Quick reject for the common "unknown" sentinels.
  const unknown = {'und', 'undefined', 'unknown', 'mul', 'zxx', '', 'qaa'};

  for (final raw in aliases) {
    final a = _normalize(raw);
    if (a.isEmpty) continue;
    // Exact / locale-prefixed code match against language field.
    if (lang.isNotEmpty && !unknown.contains(lang)) {
      if (lang == a) return true;
      if (lang.startsWith('$a-') || lang.startsWith('${a}_')) return true;
      if (a.startsWith('$lang-') || a.startsWith('${lang}_')) return true;
    }
    // Substring match against the human title (e.g. "English 5.1").
    if (ttl.isNotEmpty && a.length >= 2) {
      // For 2-letter codes, require word-boundary so "de" doesn't match
      // "adventure". For ≥3-char tokens, plain substring is fine.
      if (a.length == 2) {
        if (RegExp('(?:^|[^a-z])$a(?:[^a-z]|\$)').hasMatch(ttl)) return true;
      } else {
        if (ttl.contains(a)) return true;
      }
    }
  }
  return false;
}

/// Lower-cases, trims, strips diacritics, collapses whitespace, and removes
/// surrounding punctuation/brackets so different sources' label conventions
/// compare cleanly ("English [Forced]" → "english forced").
String _normalize(String? s) {
  if (s == null) return '';
  var x = s.toLowerCase().trim();
  if (x.isEmpty) return '';
  // Strip combining diacritics (NFD-style mapping for the common Latin set).
  const accentMap = {
    'à': 'a', 'á': 'a', 'â': 'a', 'ã': 'a', 'ä': 'a', 'å': 'a',
    'è': 'e', 'é': 'e', 'ê': 'e', 'ë': 'e',
    'ì': 'i', 'í': 'i', 'î': 'i', 'ï': 'i',
    'ò': 'o', 'ó': 'o', 'ô': 'o', 'õ': 'o', 'ö': 'o',
    'ù': 'u', 'ú': 'u', 'û': 'u', 'ü': 'u',
    'ý': 'y', 'ÿ': 'y',
    'ñ': 'n', 'ç': 'c',
  };
  final buf = StringBuffer();
  for (final r in x.runes) {
    final ch = String.fromCharCode(r);
    buf.write(accentMap[ch] ?? ch);
  }
  x = buf.toString();
  // Collapse separators, drop surrounding brackets / punctuation.
  x = x.replaceAll(RegExp(r'[\[\](){}【】]'), ' ');
  x = x.replaceAll(RegExp(r'\s+'), ' ').trim();
  return x;
}

/// Picks the "best" external subtitle entry for [preferredLang] from a list
/// of subtitle maps (each must contain at least `url`, `language`,
/// `display`). Returns null if no match. Prefers entries whose language
/// matches exactly; ranks human-translated above auto-translated.
Map<String, dynamic>? pickExternalSubtitleForLanguage(
  String preferredLang,
  List<Map<String, dynamic>> subs,
) {
  if (preferredLang == 'None' || subs.isEmpty) return null;
  Map<String, dynamic>? best;
  int bestScore = -1;
  for (final s in subs) {
    final url = (s['url'] ?? '').toString();
    if (url.isEmpty) continue;
    final lang = s['language']?.toString();
    final disp = s['display']?.toString();
    if (!matchesPreferredLanguage(preferredLang,
        language: lang, title: disp)) {
      continue;
    }
    var score = 100;
    if (s['translated'] == true) score -= 50; // prefer non-translated
    if ((disp ?? '').toLowerCase().contains('hearing')) score -= 5; // SDH ↓
    if (score > bestScore) {
      bestScore = score;
      best = s;
    }
  }
  return best;
}

/// Codec/title hints we want to *avoid* because the bundled mpv build on
/// many platforms can't render them (Atmos / TrueHD / DTS:X).
const List<String> _kUnsupportedAudioHints = [
  'atmos', 'truehd', 'true-hd', 'true hd', 'mlp', 'dts:x', 'dts-x', 'dtsx',
  'dts-hd ma', 'dts hd ma', 'dts-hd', 'dtshd',
];

bool _isUnsupportedAudio(AudioTrack t) {
  final s =
      '${t.codec ?? ''} ${t.title ?? ''} ${t.channels ?? ''}'.toLowerCase();
  for (final h in _kUnsupportedAudioHints) {
    if (s.contains(h)) return true;
  }
  // 7.1 channel layouts are problematic with most audio sinks → prefer 5.1.
  if (s.contains('7.1')) return true;
  return false;
}

class AutoSelectResult {
  final AudioTrack? audio;
  final SubtitleTrack? subtitle;
  final bool clearSubtitle; // true when user wants subtitles off

  const AutoSelectResult({this.audio, this.subtitle, this.clearSubtitle = false});

  bool get hasAny => audio != null || subtitle != null || clearSubtitle;
}

/// Given the player's current track lists and user prefs, returns the
/// recommended audio + subtitle track to switch to.
AutoSelectResult computeAutoSelect({
  required List<AudioTrack> audioTracks,
  required List<SubtitleTrack> subtitleTracks,
  required AudioTrack currentAudio,
  required SubtitleTrack currentSubtitle,
  required String preferredAudioLang,    // display name, "None" disables
  required String preferredSubtitleLang, // display name
  required bool avoidUnsupportedAudio,
}) {
  AudioTrack? audioPick;
  SubtitleTrack? subtitlePick;
  bool clearSub = false;

  // ── AUDIO ───────────────────────────────────────────────────────────────
  final realAudio =
      audioTracks.where((t) => t.id != 'no' && t.id != 'auto').toList();

  if (realAudio.isNotEmpty) {
    int bestScore = -1;
    AudioTrack? best;
    for (final t in realAudio) {
      int score = 0;
      final isMatch = preferredAudioLang != 'None' &&
          _matchesLanguage(preferredAudioLang, t.language, t.title);
      if (isMatch) score += 1000;

      final unsupported = _isUnsupportedAudio(t);
      if (avoidUnsupportedAudio && unsupported) {
        score -= 500; // strong penalty but a matching unsupported track still
                       // beats a non-matching one
      }
      // Mild boost for "mainstream" stereo/5.1 codecs we know work.
      final s = '${t.codec ?? ''} ${t.title ?? ''}'.toLowerCase();
      if (s.contains('ac3') || s.contains('eac3') || s.contains('aac') ||
          s.contains('opus') || s.contains('mp3')) {
        score += 10;
      }
      if (score > bestScore) {
        bestScore = score;
        best = t;
      }
    }

    // Only switch if our pick is meaningfully better than what's already on:
    // - language preference set + currently playing the wrong language → switch
    // - avoid-unsupported on + currently on an unsupported track + we found a supported one → switch
    if (best != null && best.id != currentAudio.id) {
      final bool currentMatches = preferredAudioLang != 'None' &&
          _matchesLanguage(
              preferredAudioLang, currentAudio.language, currentAudio.title);
      final bool currentIsBad =
          avoidUnsupportedAudio && _isUnsupportedAudio(currentAudio);
      final bool bestMatches = preferredAudioLang != 'None' &&
          _matchesLanguage(preferredAudioLang, best.language, best.title);
      final bool bestIsBad =
          avoidUnsupportedAudio && _isUnsupportedAudio(best);

      final shouldSwitch =
          (preferredAudioLang != 'None' && bestMatches && !currentMatches) ||
              (currentIsBad && !bestIsBad);
      if (shouldSwitch) {
        audioPick = best;
        debugPrint(
            '[TrackAutoSelect] audio → ${best.title ?? best.language ?? best.id} '
            '(codec=${best.codec}, channels=${best.channels})');
      }
    }
  }

  // ── SUBTITLES ───────────────────────────────────────────────────────────
  if (preferredSubtitleLang == 'None') {
    // User explicitly wants subs off → only force off if one is currently on
    // and tracks list shows we even have subs.
    if (currentSubtitle.id != 'no' && currentSubtitle.id.isNotEmpty) {
      clearSub = true;
    }
  } else {
    final realSub =
        subtitleTracks.where((t) => t.id != 'no' && t.id != 'auto').toList();
    SubtitleTrack? subBest;
    for (final t in realSub) {
      if (_matchesLanguage(preferredSubtitleLang, t.language, t.title)) {
        subBest = t;
        break;
      }
    }
    if (subBest != null && subBest.id != currentSubtitle.id) {
      subtitlePick = subBest;
      debugPrint(
          '[TrackAutoSelect] subtitle → ${subBest.title ?? subBest.language ?? subBest.id}');
    }
  }

  return AutoSelectResult(
    audio: audioPick,
    subtitle: subtitlePick,
    clearSubtitle: clearSub,
  );
}
