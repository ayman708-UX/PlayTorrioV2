import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import '../api/paper2audio_service.dart';
import '../api/audiobook_service.dart';
import '../api/music_player_service.dart';
import '../api/epub_splitter.dart';
import '../api/epub_cover.dart';
import '../utils/app_theme.dart';
import 'audiobook_player_screen.dart';

/// Top-level worker for `compute` so the EPUB parsing/splitting runs off the UI thread.
Future<List<EpubPart>> _splitWorker(String path) {
  return EpubSplitter.splitIfNeeded(File(path));
}

class GenerateAudiobookScreen extends StatefulWidget {
  const GenerateAudiobookScreen({super.key});

  @override
  State<GenerateAudiobookScreen> createState() =>
      _GenerateAudiobookScreenState();
}

class _GenerateAudiobookScreenState extends State<GenerateAudiobookScreen> {
  final Paper2AudioService _svc = Paper2AudioService.instance;
  String _voiceId = 'af_heart';
  bool _uploading = false;
  Timer? _poller;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    await _svc.getJobs();
    if (!mounted) return;
    setState(() {});
    _refreshAndScheduleNext();
  }

  void _refreshAndScheduleNext() {
    _poller?.cancel();
    () async {
      await _svc.refreshAll();
      if (!mounted) return;
      final hasPending = _svc.jobs.value.any((j) => !j.isDone && !j.isFailed);
      if (hasPending) {
        _poller = Timer(const Duration(seconds: 8), _refreshAndScheduleNext);
      }
    }();
  }

  @override
  void dispose() {
    _poller?.cancel();
    super.dispose();
  }

  Future<void> _pickAndUpload() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['epub'],
      withData: false,
    );
    if (result == null || result.files.single.path == null) return;
    final file = File(result.files.single.path!);

    setState(() => _uploading = true);
    try {
      // Analyze + split off the UI thread.
      final parts = await compute(_splitWorker, file.path);

      // Extract cover from the original EPUB once; share across parts.
      final originalBytes = await file.readAsBytes();
      final safeName = file.path
          .split(Platform.pathSeparator)
          .last
          .replaceAll(RegExp(r'\.epub$', caseSensitive: false), '')
          .replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
      final coverPath = await EpubCover.extractAndSave(
        epubBytes: originalBytes,
        saveAsName: '${safeName}_${DateTime.now().millisecondsSinceEpoch}',
      );

      if (parts.length > 1) {
        if (!mounted) return;
        final totalWords =
            parts.fold<int>(0, (a, p) => a + p.wordCount);
        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('EPUB exceeds 250,000 words'),
            content: Text(
              'This book has ~${_formatWords(totalWords)} words, which is over the 250k limit per generation.\n\n'
              'It will be split into ${parts.length} parts at a chapter boundary and queued as separate jobs:\n\n'
              '${parts.map((p) => '• ${p.suggestedName} (~${_formatWords(p.wordCount)} words)').join('\n')}',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Split & Upload'),
              ),
            ],
          ),
        );
        if (ok != true) {
          if (mounted) setState(() => _uploading = false);
          return;
        }
      }

      for (final part in parts) {
        await _svc.uploadBytes(
          bytes: part.bytes,
          fileName: part.suggestedName,
          voiceId: _voiceId,
          coverPath: coverPath,
        );
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(parts.length == 1
              ? 'Uploaded — generation started on the server.'
              : 'Uploaded ${parts.length} parts — generation started.'),
        ),
      );
      _refreshAndScheduleNext();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Upload failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  String _formatWords(int n) {
    if (n >= 1000) {
      return '${(n / 1000).toStringAsFixed(n >= 100000 ? 0 : 1)}k';
    }
    return n.toString();
  }

  Future<void> _copyUrl(String url) async {
    await Clipboard.setData(ClipboardData(text: url));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Stream link copied')),
    );
  }

  void _playInApp(GeneratedAudiobookJob job) {
    if (!job.isDone) return;
    final title = job.fileName.replaceAll(RegExp(r'\.epub$', caseSensitive: false), '');
    final book = Audiobook(
      uuid: 'p2a_${job.runId}',
      audioBookId: 'p2a_${job.runId}',
      dynamicSlugId: job.runId,
      title: title,
      coverImage: job.coverPath ?? '',
      source: 'paper2audio',
      pageUrl: job.downloadUrl,
    );
    final chapters = [
      AudiobookChapter(title: title, url: job.downloadUrl!),
    ];
    final musicService = MusicPlayerService();
    musicService.isFullScreenVisible.value = true;
    final isWide = Platform.isWindows || MediaQuery.of(context).size.width > 900;
    if (isWide) {
      showDialog(
        context: context,
        builder: (ctx) => Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 500, maxHeight: 850),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(24),
              child: AudiobookPlayerScreen(
                audiobook: book,
                chapters: chapters,
              ),
            ),
          ),
        ),
      ).then((_) => musicService.isFullScreenVisible.value = false);
    } else {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => AudiobookPlayerScreen(
            audiobook: book,
            chapters: chapters,
          ),
        ),
      ).then((_) => musicService.isFullScreenVisible.value = false);
    }
  }

  Future<void> _confirmDelete(GeneratedAudiobookJob job) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove job?'),
        content: Text('"${job.fileName}" will be removed from this list.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Remove')),
        ],
      ),
    );
    if (ok == true) {
      await _svc.removeJob(job.runId);
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0F),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text('Generate Audiobook',
            style: TextStyle(fontWeight: FontWeight.w600)),
      ),
      body: SafeArea(
        child: ValueListenableBuilder<List<GeneratedAudiobookJob>>(
          valueListenable: _svc.jobs,
          builder: (context, jobs, _) {
            return Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                  children: [
                    _buildUploadCard(),
                    const SizedBox(height: 28),
                    if (jobs.isEmpty)
                      _buildEmptyState()
                    else ...[
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: Row(
                          children: [
                            const Text(
                              'Your jobs',
                              style: TextStyle(
                                  fontSize: 16, fontWeight: FontWeight.w600),
                            ),
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.08),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Text('${jobs.length}',
                                  style: const TextStyle(
                                      fontSize: 11,
                                      color: Colors.white70,
                                      fontWeight: FontWeight.w600)),
                            ),
                            const Spacer(),
                            IconButton(
                              icon: const Icon(Icons.refresh, size: 20),
                              tooltip: 'Refresh',
                              onPressed: _refreshAndScheduleNext,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 8),
                      ...jobs.map(_buildJobTile),
                    ],
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 32),
      child: Column(
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: AppTheme.primaryColor.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.menu_book_rounded,
                color: AppTheme.primaryColor, size: 28),
          ),
          const SizedBox(height: 12),
          const Text('No jobs yet',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          const Text('Upload an EPUB to get started.',
              style: TextStyle(color: Colors.white54, fontSize: 12)),
        ],
      ),
    );
  }

  Widget _buildUploadCard() {
    final selectedVoice = kPaper2AudioVoices.firstWhere(
      (v) => v.id == _voiceId,
      orElse: () => kPaper2AudioVoices.first,
    );

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            AppTheme.primaryColor.withValues(alpha: 0.10),
            Colors.white.withValues(alpha: 0.03),
          ],
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: 0.07)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppTheme.primaryColor.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(Icons.auto_awesome_rounded,
                    color: AppTheme.primaryColor, size: 20),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Upload an EPUB',
                        style: TextStyle(
                            fontSize: 17, fontWeight: FontWeight.w600)),
                    SizedBox(height: 2),
                    Text(
                      'Server-side TTS — closing the app is fine.',
                      style: TextStyle(color: Colors.white54, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          _buildVoicePill(selectedVoice),
          const SizedBox(height: 14),
          Align(
            alignment: Alignment.centerLeft,
            child: _buildPickButton(),
          ),
        ],
      ),
    );
  }

  Widget _buildVoicePill(Paper2AudioVoice selected) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: _uploading ? null : _openVoicePicker,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
          ),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    colors: [
                      AppTheme.primaryColor,
                      AppTheme.primaryColor.withValues(alpha: 0.6),
                    ],
                  ),
                ),
                child: const Icon(Icons.graphic_eq_rounded,
                    color: Colors.white, size: 18),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Narrator voice',
                        style: TextStyle(
                            color: Colors.white54,
                            fontSize: 11,
                            letterSpacing: 0.4,
                            fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(
                      selected.label,
                      style: const TextStyle(
                          fontSize: 13.5, fontWeight: FontWeight.w500),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const Icon(Icons.expand_more_rounded,
                  color: Colors.white54, size: 22),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPickButton() {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: _uploading ? null : _pickAndUpload,
        borderRadius: BorderRadius.circular(999),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding:
              const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: _uploading
                  ? [Colors.white12, Colors.white10]
                  : [AppTheme.primaryColor, const Color(0xFF5D3EFF)],
            ),
            borderRadius: BorderRadius.circular(999),
            boxShadow: _uploading
                ? null
                : [
                    BoxShadow(
                      color: AppTheme.primaryColor.withValues(alpha: 0.35),
                      blurRadius: 18,
                      offset: const Offset(0, 6),
                    ),
                  ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_uploading)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white),
                )
              else
                const Icon(Icons.upload_rounded, color: Colors.white, size: 18),
              const SizedBox(width: 10),
              Text(
                _uploading ? 'Uploading…' : 'Pick EPUB',
                style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                    fontSize: 14),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openVoicePicker() async {
    final groups = <String, List<Paper2AudioVoice>>{};
    for (final v in kPaper2AudioVoices) {
      groups.putIfAbsent(v.group, () => []).add(v);
    }

    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) {
        final maxH = MediaQuery.of(ctx).size.height * 0.75;
        return SafeArea(
          child: Container(
            constraints: BoxConstraints(maxHeight: maxH),
            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            decoration: BoxDecoration(
              color: const Color(0xFF14141D),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(top: 10, bottom: 6),
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const Padding(
                  padding:
                      EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                  child: Row(
                    children: [
                      Icon(Icons.graphic_eq_rounded,
                          size: 18, color: Colors.white70),
                      SizedBox(width: 8),
                      Text('Choose narrator',
                          style: TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
                const Divider(height: 1, color: Colors.white12),
                Flexible(
                  child: ListView(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    children: [
                      for (final entry in groups.entries) ...[
                        Padding(
                          padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
                          child: Text(
                            entry.key.toUpperCase(),
                            style: const TextStyle(
                              fontSize: 10.5,
                              letterSpacing: 1.2,
                              color: Colors.white38,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        for (final v in entry.value)
                          _VoiceTile(
                            voice: v,
                            selected: v.id == _voiceId,
                            onTap: () => Navigator.pop(ctx, v.id),
                          ),
                      ],
                      const SizedBox(height: 8),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );

    if (picked != null && picked != _voiceId) {
      setState(() => _voiceId = picked);
    }
  }

  Widget _buildCoverThumb(GeneratedAudiobookJob job) {
    final cover = job.coverPath;
    final hasCover = cover != null && cover.isNotEmpty && File(cover).existsSync();
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: 44,
        height: 60,
        color: Colors.white.withValues(alpha: 0.06),
        child: hasCover
            ? Image.file(File(cover), fit: BoxFit.cover)
            : Center(
                child: Icon(Icons.menu_book_rounded,
                    size: 22,
                    color: AppTheme.primaryColor.withValues(alpha: 0.7)),
              ),
      ),
    );
  }

  Widget _buildJobTile(GeneratedAudiobookJob job) {
    final voiceLabel = kPaper2AudioVoices
        .firstWhere((v) => v.id == job.voiceId,
            orElse: () => Paper2AudioVoice(job.voiceId, job.voiceId, ''))
        .label;

    Color statusColor = Colors.amber;
    IconData statusIcon = Icons.hourglass_top_rounded;
    if (job.isDone) {
      statusColor = Colors.greenAccent;
      statusIcon = Icons.check_circle_rounded;
    } else if (job.isFailed) {
      statusColor = Colors.redAccent;
      statusIcon = Icons.error_rounded;
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _buildCoverThumb(job),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(statusIcon, color: statusColor, size: 18),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            job.fileName,
                            style: const TextStyle(
                                fontWeight: FontWeight.w600),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Voice: $voiceLabel',
                      style: const TextStyle(
                          color: Colors.white54, fontSize: 12),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.delete_outline, size: 20),
                onPressed: () => _confirmDelete(job),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (!job.isDone && !job.isFailed) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: job.progress > 0 ? job.progress.clamp(0.0, 1.0) : null,
                minHeight: 6,
                backgroundColor: Colors.white12,
                valueColor: AlwaysStoppedAnimation<Color>(AppTheme.primaryColor),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '${job.status} · ${(job.progress.clamp(0.0, 1.0) * 100).toStringAsFixed(0)}%',
              style: const TextStyle(color: Colors.white54, fontSize: 11),
            ),
          ],
          if (job.isFailed)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(job.error ?? 'Generation failed',
                  style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
            ),
          if (job.isDone) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _copyUrl(job.downloadUrl!),
                    icon: const Icon(Icons.copy, size: 16),
                    label: const Text('Copy link'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () => _playInApp(job),
                    icon: const Icon(Icons.play_arrow, size: 18),
                    label: const Text('Play'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.primaryColor,
                      foregroundColor: Colors.white,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _VoiceTile extends StatelessWidget {
  final Paper2AudioVoice voice;
  final bool selected;
  final VoidCallback onTap;
  const _VoiceTile({
    required this.voice,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          color: selected
              ? AppTheme.primaryColor.withValues(alpha: 0.12)
              : Colors.transparent,
          child: Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: selected
                      ? AppTheme.primaryColor
                      : Colors.white.withValues(alpha: 0.06),
                ),
                child: Icon(
                  selected
                      ? Icons.check_rounded
                      : Icons.person_outline_rounded,
                  size: 18,
                  color: selected ? Colors.white : Colors.white60,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  voice.label,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight:
                        selected ? FontWeight.w600 : FontWeight.w400,
                    color: selected ? Colors.white : Colors.white70,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
