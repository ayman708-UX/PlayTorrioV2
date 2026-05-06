import 'dart:ui';
import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../api/audiobook_service.dart';
import '../api/audiobook_player_service.dart';
import '../api/audiobook_download_service.dart';
import '../utils/app_theme.dart';

class AudiobookPlayerScreen extends StatefulWidget {
  final Audiobook audiobook;
  final List<AudiobookChapter> chapters;
  final int initialChapterIndex;
  final Duration? initialPosition;

  const AudiobookPlayerScreen({
    super.key,
    required this.audiobook,
    required this.chapters,
    this.initialChapterIndex = 0,
    this.initialPosition,
  });

  @override
  State<AudiobookPlayerScreen> createState() => _AudiobookPlayerScreenState();
}

class _AudiobookPlayerScreenState extends State<AudiobookPlayerScreen> {
  final _service = AudiobookPlayerService();
  final _downloadService = AudiobookDownloadService();
  double _playbackSpeed = 1.0;
  bool _isDownloaded = false;

  @override
  void initState() {
    super.initState();
    _checkDownloadStatus();
    _service.loadBook(
      widget.audiobook, 
      widget.chapters, 
      initialChapter: widget.initialChapterIndex,
      resumePosition: widget.initialPosition,
    );
  }

  void _changeChapter(int index) async {
    await _service.changeChapter(index);
  }

  void _checkDownloadStatus() async {
    final downloaded = await _downloadService.isBookDownloaded(widget.audiobook.audioBookId);
    if (mounted) setState(() => _isDownloaded = downloaded);
    // Load per-chapter download state
    _downloadService.checkDownloadedChapters(widget.audiobook.audioBookId, widget.chapters.length);
  }

  void _startDownload() {
    _downloadService.downloadBook(widget.audiobook, widget.chapters);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Download started...'), duration: Duration(seconds: 2)),
    );
  }

  void _handleExit() async {
    await _service.saveManualProgress();
    await _service.stop();
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _handleExit();
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF0F0418),
        body: Stack(
          children: [
            // Subtle background blur
            Positioned.fill(
              child: _buildCoverImage(
                widget.audiobook.thumbUrl,
                fallbackUrl: widget.audiobook.coverImage,
                fit: BoxFit.cover,
                color: Colors.black.withValues(alpha: 0.6),
                colorBlendMode: BlendMode.darken,
              ),
            ),
            Positioned.fill(
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 40, sigmaY: 40),
                child: Container(color: Colors.black.withValues(alpha: 0.4)),
              ),
            ),
            const Positioned.fill(child: _NightSkyPainter()),
            
            SafeArea(
              child: Column(
                children: [
                  _buildAppBar(),
                  Expanded(
                    child: SingleChildScrollView(
                      child: Column(
                        children: [
                          const SizedBox(height: 40),
                          _buildCoverArt(),
                          const SizedBox(height: 40),
                          _buildTitleInfo(),
                          const SizedBox(height: 48),
                          _buildPlayerControls(),
                          const SizedBox(height: 32),
                          _buildChapterList(),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAppBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          IconButton(
            icon: const Icon(Icons.keyboard_arrow_down, color: Colors.white, size: 32),
            onPressed: _handleExit,
          ),
          const Text(
            'AUDIOBOOK PLAYER',
            style: TextStyle(color: Colors.white54, letterSpacing: 2, fontSize: 13, fontWeight: FontWeight.bold),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildDownloadButton(),
              const SizedBox(width: 4),
              _buildSpeedMenu(),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildDownloadButton() {
    return ValueListenableBuilder<Map<String, AudiobookDownloadProgress>>(
      valueListenable: _downloadService.activeDownloads,
      builder: (context, downloads, _) {
        final progress = downloads[widget.audiobook.audioBookId];

        if (progress != null && progress.status == 'downloading') {
          return GestureDetector(
            onTap: () {
              _downloadService.cancelDownload(widget.audiobook.audioBookId);
            },
            child: Container(
              padding: const EdgeInsets.all(8),
              child: SizedBox(
                width: 24,
                height: 24,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    CircularProgressIndicator(
                      value: progress.progress,
                      strokeWidth: 2.5,
                      color: AppTheme.primaryColor,
                      backgroundColor: Colors.white12,
                    ),
                    Icon(Icons.close, color: Colors.white, size: 12),
                  ],
                ),
              ),
            ),
          );
        }

        if (_isDownloaded || (progress != null && progress.status == 'completed')) {
          return IconButton(
            icon: const Icon(Icons.download_done, color: Colors.greenAccent, size: 24),
            onPressed: () {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Already downloaded'), duration: Duration(seconds: 1)),
              );
            },
            tooltip: 'Downloaded',
          );
        }

        return IconButton(
          icon: const Icon(Icons.download_rounded, color: Colors.white, size: 24),
          onPressed: _startDownload,
          tooltip: 'Download all chapters',
        );
      },
    );
  }

  Widget _buildSpeedMenu() {
    return PopupMenuButton<double>(
      initialValue: _playbackSpeed,
      onSelected: (double speed) {
        setState(() => _playbackSpeed = speed);
        _service.setRate(speed);
      },
      itemBuilder: (context) => [0.5, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0].map((s) => PopupMenuItem(value: s, child: Text('${s}x Speed'))).toList(),
      color: const Color(0xFF1A0B2E),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(20)),
        child: Text('${_playbackSpeed}x', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
      ),
    );
  }

  Widget _buildCoverArt() {
    return Center(
      child: Container(
        width: 280,
        height: 280,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.5), blurRadius: 30, spreadRadius: 5)],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: _buildCoverImage(
            widget.audiobook.thumbUrl,
            fallbackUrl: widget.audiobook.coverImage,
            fit: BoxFit.cover,
          ),
        ),
      ),
    );
  }

  Widget _buildCoverImage(String url,
      {String? fallbackUrl, BoxFit fit = BoxFit.cover, Color? color, BlendMode? colorBlendMode}) {
    bool isLocal(String s) => s.isNotEmpty && !s.startsWith('http://') && !s.startsWith('https://');
    if (isLocal(url)) {
      final f = File(url);
      if (f.existsSync()) {
        return Image.file(f, fit: fit, color: color, colorBlendMode: colorBlendMode);
      }
    }
    return CachedNetworkImage(
      imageUrl: url,
      fit: fit,
      color: color,
      colorBlendMode: colorBlendMode,
      errorWidget: (context, _, _) {
        if (fallbackUrl == null || fallbackUrl.isEmpty) {
          return Container(color: Colors.white10);
        }
        if (isLocal(fallbackUrl)) {
          final f = File(fallbackUrl);
          if (f.existsSync()) {
            return Image.file(f, fit: fit, color: color, colorBlendMode: colorBlendMode);
          }
          return Container(color: Colors.white10);
        }
        return CachedNetworkImage(
          imageUrl: fallbackUrl,
          fit: fit,
          color: color,
          colorBlendMode: colorBlendMode,
          errorWidget: (_, _, _) => Container(color: Colors.white10),
        );
      },
    );
  }

  Widget _buildTitleInfo() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: ValueListenableBuilder<int>(
        valueListenable: _service.currentChapterIndex,
        builder: (context, chapterIndex, _) {
          return Column(
            children: [
              Text(
                widget.audiobook.title,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 12),
              SizedBox(
                height: 24,
                child: MarqueeText(
                  text: 'Chapter ${chapterIndex + 1}: ${widget.chapters[chapterIndex].title}',
                  style: const TextStyle(color: AppTheme.primaryColor, fontSize: 16, fontWeight: FontWeight.w500),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildPlayerControls() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: ValueListenableBuilder<Duration>(
            valueListenable: _service.position,
            builder: (context, pos, _) {
              return ValueListenableBuilder<Duration>(
                valueListenable: _service.duration,
                builder: (context, dur, _) {
                  final dValue = dur.inMilliseconds.toDouble();
                  final pValue = pos.inMilliseconds.toDouble();
                  final safePValue = pValue.clamp(0.0, dValue > 0 ? dValue : 1.0);

                  return Column(
                    children: [
                      SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          activeTrackColor: Colors.white,
                          inactiveTrackColor: Colors.white10,
                          thumbColor: Colors.white,
                          trackHeight: 4,
                          overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                        ),
                        child: Slider(
                          value: safePValue,
                          max: dValue > 0 ? dValue : 1.0,
                          onChanged: (v) => _service.seek(Duration(milliseconds: v.toInt())),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(_formatDuration(pos), style: const TextStyle(color: Colors.white38, fontSize: 12)),
                            Text(_formatDuration(dur), style: const TextStyle(color: Colors.white38, fontSize: 12)),
                          ],
                        ),
                      ),
                    ],
                  );
                },
              );
            },
          ),
        ),
        const SizedBox(height: 32),
        ValueListenableBuilder<bool>(
          valueListenable: _service.autoplay,
          builder: (context, auto, _) {
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  const Text('AUTOPLAY', style: TextStyle(color: Colors.white38, fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 1)),
                  const SizedBox(width: 8),
                  SizedBox(
                    height: 24,
                    child: Switch(
                      value: auto, 
                      onChanged: (v) => _service.autoplay.value = v,
                      activeTrackColor: AppTheme.primaryColor,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                ],
              ),
            );
          },
        ),
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ValueListenableBuilder<int>(
              valueListenable: _service.currentChapterIndex,
              builder: (context, index, _) => IconButton(
                icon: const Icon(Icons.skip_previous_rounded, color: Colors.white, size: 48),
                onPressed: index > 0 ? () => _changeChapter(index - 1) : null,
              ),
            ),
            const SizedBox(width: 32),
            ValueListenableBuilder<bool>(
              valueListenable: _service.isBuffering,
              builder: (context, buffering, _) {
                return ValueListenableBuilder<bool>(
                  valueListenable: _service.isPlaying,
                  builder: (context, playing, _) {
                    if (buffering && !playing) {
                      return const SizedBox(width: 80, height: 80, child: Padding(padding: EdgeInsets.all(20), child: CircularProgressIndicator(color: Colors.white)));
                    }
                    return GestureDetector(
                      onTap: () => _service.playOrPause(),
                      child: Container(
                        width: 84, height: 84,
                        decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                        child: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded, color: Colors.black, size: 54),
                      ),
                    );
                  },
                );
              },
            ),
            const SizedBox(width: 32),
            ValueListenableBuilder<int>(
              valueListenable: _service.currentChapterIndex,
              builder: (context, index, _) => IconButton(
                icon: const Icon(Icons.skip_next_rounded, color: Colors.white, size: 48),
                onPressed: index < widget.chapters.length - 1 ? () => _changeChapter(index + 1) : null,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildChapterList() {
    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('CHAPTERS', style: TextStyle(color: Colors.white54, fontWeight: FontWeight.bold, letterSpacing: 2, fontSize: 12)),
          const SizedBox(height: 16),
          ValueListenableBuilder<int>(
            valueListenable: _service.currentChapterIndex,
            builder: (context, currentIdx, _) {
              return ListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: widget.chapters.length,
                itemBuilder: (context, index) {
                  final isCurrent = currentIdx == index;
                  return Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    decoration: BoxDecoration(
                      color: isCurrent ? Colors.white.withValues(alpha: 0.1) : Colors.transparent,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: ListTile(
                      onTap: () => _changeChapter(index),
                      leading: Text('${index + 1}', style: TextStyle(color: isCurrent ? AppTheme.primaryColor : Colors.white24, fontWeight: FontWeight.bold)),
                      title: Text(
                        widget.chapters[index].title,
                        style: TextStyle(color: isCurrent ? Colors.white : Colors.white70, fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal, fontSize: 14),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (isCurrent)
                            const Padding(
                              padding: EdgeInsets.only(right: 8),
                              child: Icon(Icons.graphic_eq, color: AppTheme.primaryColor, size: 20),
                            ),
                          _buildChapterDownloadIcon(index),
                        ],
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildChapterDownloadIcon(int index) {
    final key = '${widget.audiobook.audioBookId}_$index';
    return ValueListenableBuilder<Set<String>>(
      valueListenable: _downloadService.downloadingChapters,
      builder: (context, downloading, _) {
        if (downloading.contains(key)) {
          return const SizedBox(
            width: 20, height: 20,
            child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.primaryColor),
          );
        }
        return ValueListenableBuilder<Set<String>>(
          valueListenable: _downloadService.downloadedChapterKeys,
          builder: (context, downloaded, _) {
            if (downloaded.contains(key)) {
              return const Icon(Icons.download_done, color: Colors.greenAccent, size: 20);
            }
            return GestureDetector(
              onTap: () {
                _downloadService.downloadSingleChapter(
                  widget.audiobook,
                  widget.chapters[index],
                  index,
                );
              },
              child: const Icon(Icons.download_outlined, color: Colors.white38, size: 20),
            );
          },
        );
      },
    );
  }

  String _formatDuration(Duration d) {
    if (d.isNegative) d = Duration.zero;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '${d.inHours > 0 ? '${d.inHours}:' : ''}$m:$s';
  }
}

class MarqueeText extends StatefulWidget {
  final String text;
  final TextStyle style;
  const MarqueeText({super.key, required this.text, required this.style});
  @override
  State<MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<MarqueeText> with SingleTickerProviderStateMixin {
  late ScrollController _scrollController;
  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    WidgetsBinding.instance.addPostFrameCallback((_) => _startScrolling());
  }
  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }
  void _startScrolling() async {
    if (!_scrollController.hasClients) return;
    await Future.delayed(const Duration(seconds: 2));
    while (_scrollController.hasClients) {
      final maxScroll = _scrollController.position.maxScrollExtent;
      if (maxScroll <= 0) break;
      await _scrollController.animateTo(maxScroll, duration: Duration(milliseconds: (maxScroll * 30).toInt()), curve: Curves.linear);
      await Future.delayed(const Duration(seconds: 1));
      if (_scrollController.hasClients) {
        await _scrollController.animateTo(0, duration: const Duration(milliseconds: 500), curve: Curves.easeOut);
        await Future.delayed(const Duration(seconds: 2));
      }
    }
  }
  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      controller: _scrollController,
      scrollDirection: Axis.horizontal,
      child: Text(widget.text, style: widget.style, maxLines: 1),
    );
  }
}

class _NightSkyPainter extends StatelessWidget {
  const _NightSkyPainter();
  @override
  Widget build(BuildContext context) {
    return CustomPaint(painter: SkyPainter());
  }
}

class SkyPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint();
    final rand = _DeterministicRandom(42);
    paint.color = Colors.white.withValues(alpha: 0.3);
    for (int i = 0; i < 80; i++) {
      final x = rand.nextDouble() * size.width;
      final y = rand.nextDouble() * size.height;
      final s = rand.nextDouble() * 1.5;
      canvas.drawCircle(Offset(x, y), s, paint);
    }
  }
  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _DeterministicRandom {
  int seed;
  _DeterministicRandom(this.seed);
  double nextDouble() {
    seed = (seed * 1103515245 + 12345) & 0x7fffffff;
    return seed / 0x7fffffff;
  }
}
