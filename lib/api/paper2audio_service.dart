import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Voice option exposed in the picker. IDs match paper2audio.com (kokoro voices).
class Paper2AudioVoice {
  final String id;
  final String label;
  final String group;
  const Paper2AudioVoice(this.id, this.label, this.group);
}

const List<Paper2AudioVoice> kPaper2AudioVoices = [
  // US Female
  Paper2AudioVoice('af_heart',    'Narrator — Bright, engaging (default)', 'US Female'),
  Paper2AudioVoice('af_bella',    'Librarian — Calm, warm',                'US Female'),
  Paper2AudioVoice('af_sarah',    'Reporter — Crisp, articulate',          'US Female'),
  Paper2AudioVoice('af_alloy',    'Professor — Polished, controlled',      'US Female'),
  // US Male
  Paper2AudioVoice('am_echo',     'Orator',                                'US Male'),
  Paper2AudioVoice('am_liam',     'Interviewer — Engaging, clear',         'US Male'),
  Paper2AudioVoice('am_puck',     'Teacher — Natural, lively',             'US Male'),
  Paper2AudioVoice('am_michael',  'News Anchor — Polished, deliberate',    'US Male'),
  // UK
  Paper2AudioVoice('bf_isabella', 'Adviser (F) — Centred, harmonised',     'UK'),
  Paper2AudioVoice('bm_daniel',   'Counsellor (M)',                        'UK'),
  // Legacy
  Paper2AudioVoice('am_fenrir',   'Fenrir (US M, legacy)',                 'Legacy'),
  Paper2AudioVoice('bf_emma',     'Emma (UK F, legacy)',                   'Legacy'),
  Paper2AudioVoice('bm_george',   'George (UK M, legacy)',                 'Legacy'),
];

/// Persistent record of a generation job.
class GeneratedAudiobookJob {
  final String runId;
  final String fileName;
  final String voiceId;
  final int createdAt;
  String status;          // e.g. "pending" / "processing" / "completed" / "failed"
  double progress;        // 0..1 (or 0..100 server-side; we normalize to 0..1)
  String? downloadUrl;
  String? error;
  String? coverPath;      // local path to extracted EPUB cover image

  GeneratedAudiobookJob({
    required this.runId,
    required this.fileName,
    required this.voiceId,
    required this.createdAt,
    this.status = 'pending',
    this.progress = 0,
    this.downloadUrl,
    this.error,
    this.coverPath,
  });

  Map<String, dynamic> toJson() => {
        'runId': runId,
        'fileName': fileName,
        'voiceId': voiceId,
        'createdAt': createdAt,
        'status': status,
        'progress': progress,
        'downloadUrl': downloadUrl,
        'error': error,
        'coverPath': coverPath,
      };

  factory GeneratedAudiobookJob.fromJson(Map<String, dynamic> j) =>
      GeneratedAudiobookJob(
        runId: j['runId'] as String,
        fileName: j['fileName'] as String? ?? 'Untitled.epub',
        voiceId: j['voiceId'] as String? ?? 'af_heart',
        createdAt: j['createdAt'] as int? ?? 0,
        status: j['status'] as String? ?? 'pending',
        progress: (j['progress'] as num?)?.toDouble() ?? 0,
        downloadUrl: j['downloadUrl'] as String?,
        error: j['error'] as String?,
        coverPath: j['coverPath'] as String?,
      );

  bool get isDone => downloadUrl != null && downloadUrl!.isNotEmpty;
  bool get isFailed => status.toLowerCase() == 'failed' || (error != null && error!.isNotEmpty);
}

/// Talks directly to paper2audio.com (no self-hosted Node server needed).
/// All heavy work happens on their server, so jobs survive app restarts —
/// we just need the runId to keep polling.
class Paper2AudioService {
  Paper2AudioService._();
  static final Paper2AudioService instance = Paper2AudioService._();

  static const String _firebaseKey = 'AIzaSyAq9_a8hU7sNkwUBJFmSlbmhepbu8bRgqw';
  static const String _baseUrl = 'https://www.paper2audio.com';
  static const String _prefsKey = 'p2a_jobs_v1';

  final ValueNotifier<List<GeneratedAudiobookJob>> jobs = ValueNotifier([]);
  bool _loaded = false;

  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final list = (jsonDecode(raw) as List)
            .map((e) => GeneratedAudiobookJob.fromJson(e as Map<String, dynamic>))
            .toList();
        jobs.value = list;
      } catch (_) {}
    }
    _loaded = true;
  }

  Future<List<GeneratedAudiobookJob>> getJobs() async {
    await _ensureLoaded();
    return List.unmodifiable(jobs.value);
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = jsonEncode(jobs.value.map((j) => j.toJson()).toList());
    await prefs.setString(_prefsKey, encoded);
  }

  Future<void> removeJob(String runId) async {
    await _ensureLoaded();
    jobs.value = jobs.value.where((j) => j.runId != runId).toList();
    await _persist();
  }

  Future<String> _getAuthToken() async {
    final email = '${_uuid()}@mailinator.com';
    final resp = await http.post(
      Uri.parse(
          'https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=$_firebaseKey'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'email': email,
        'password': 'TestPassword123!',
        'returnSecureToken': true,
      }),
    );
    if (resp.statusCode >= 400) {
      throw Exception('Auth failed: ${resp.statusCode} ${resp.body}');
    }
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    final token = data['idToken'] as String?;
    if (token == null) throw Exception('Auth: missing idToken');
    return token;
  }

  /// Uploads the given EPUB bytes and queues a job. Returns the new job.
  Future<GeneratedAudiobookJob> upload({
    required File epub,
    required String voiceId,
    String? fileNameOverride,
  }) async {
    final fileName = fileNameOverride ??
        epub.path.split(Platform.pathSeparator).last;
    final bytes = await epub.readAsBytes();
    return uploadBytes(bytes: bytes, fileName: fileName, voiceId: voiceId);
  }

  /// Uploads raw EPUB bytes (use this after splitting an oversized EPUB).
  Future<GeneratedAudiobookJob> uploadBytes({
    required Uint8List bytes,
    required String fileName,
    required String voiceId,
    String? coverPath,
  }) async {
    await _ensureLoaded();
    final token = await _getAuthToken();
    final uri = Uri.parse('$_baseUrl/v2/summarize').replace(queryParameters: {
      'fileName': fileName,
      'summarizationMethod': 'ultimate',
      'primaryVoice': voiceId,
    });

    final resp = await http.post(
      uri,
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/epub+zip',
      },
      body: bytes,
    );

    if (resp.statusCode >= 400) {
      throw Exception('Upload failed: ${resp.statusCode} ${resp.body}');
    }
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    final runId = data['runId'] as String?;
    if (runId == null) throw Exception('Upload: missing runId');

    final job = GeneratedAudiobookJob(
      runId: runId,
      fileName: fileName,
      voiceId: voiceId,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      status: 'pending',
      coverPath: coverPath,
    );
    jobs.value = [job, ...jobs.value];
    await _persist();
    return job;
  }

  /// Polls status for a single runId. Updates the persisted job in place.
  Future<GeneratedAudiobookJob?> refreshStatus(String runId) async {
    await _ensureLoaded();
    final idx = jobs.value.indexWhere((j) => j.runId == runId);
    if (idx == -1) return null;
    final job = jobs.value[idx];

    try {
      final resp = await http.post(
        Uri.parse('$_baseUrl/batchCheckStatus'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'runIds': [runId]}),
      );
      if (resp.statusCode >= 400) {
        return job;
      }
      final body = jsonDecode(resp.body);
      final entry = (body is Map && body[runId] is Map)
          ? body[runId] as Map<String, dynamic>
          : null;
      if (entry == null) return job;

      job.status = (entry['status'] as String?) ?? job.status;
      final p = entry['progress'];
      double? pv;
      if (p is num) {
        pv = p.toDouble();
      } else if (p is String) {
        pv = double.tryParse(p);
      }
      if (pv != null) {
        job.progress = pv > 1 ? pv / 100.0 : pv;
      }
      final url = entry['fullAudioFileUrl'] as String?;
      if (url != null && url.isNotEmpty) job.downloadUrl = url;

      // Replace to trigger ValueNotifier listeners.
      final next = List<GeneratedAudiobookJob>.from(jobs.value);
      next[idx] = job;
      jobs.value = next;
      await _persist();
      return job;
    } catch (_) {
      return job;
    }
  }

  /// Refreshes status for all unfinished jobs.
  Future<void> refreshAll() async {
    await _ensureLoaded();
    final pending = jobs.value.where((j) => !j.isDone && !j.isFailed).toList();
    for (final j in pending) {
      await refreshStatus(j.runId);
    }
  }

  // Tiny UUID v4 (no extra dep).
  String _uuid() {
    final r = DateTime.now().microsecondsSinceEpoch;
    final rnd = (r ^ (r >> 16)).toRadixString(16).padLeft(8, '0');
    final tail = (r * 1664525 + 1013904223).toUnsigned(32).toRadixString(16).padLeft(8, '0');
    return '$rnd-${tail.substring(0, 4)}-4${tail.substring(4, 7)}-a${rnd.substring(0, 3)}-$tail$rnd'
        .substring(0, 36);
  }
}
