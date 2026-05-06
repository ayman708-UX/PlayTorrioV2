import 'dart:io';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../api/audiobook_service.dart';
import '../api/audiobook_player_service.dart';
import '../api/music_player_service.dart';
import '../utils/app_theme.dart';
import 'audiobook_player_screen.dart';
import 'audiobook_downloads_screen.dart';
import 'generate_audiobook_screen.dart';

class AudiobookScreen extends StatefulWidget {
  const AudiobookScreen({super.key});

  @override
  State<AudiobookScreen> createState() => _AudiobookScreenState();
}

class _AudiobookScreenState extends State<AudiobookScreen> with WidgetsBindingObserver {
  final AudiobookService _service = AudiobookService();
  final AudiobookPlayerService _playerService = AudiobookPlayerService();
  final TextEditingController _searchController = TextEditingController();
  
  List<Audiobook> _books = [];
  List<Audiobook> _likedBooks = [];
  List<Map<String, dynamic>> _history = [];
  bool _isLoading = true;
  int _currentOffset = 0;
  final int _limit = 12;
  bool _isSearching = false;
  bool _showLiked = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadBooks();
    _loadHistory();
    _loadLikedBooks();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    if (mounted) setState(() {});
  }

  Future<void> _loadHistory() async {
    final history = await _playerService.getHistory();
    if (mounted) {
      setState(() => _history = history);
    }
  }

  Future<void> _loadLikedBooks() async {
    final liked = await _playerService.getLikedBooks();
    if (mounted) {
      setState(() => _likedBooks = liked);
    }
  }

  Future<void> _loadBooks() async {
    setState(() {
      _isLoading = true;
      _showLiked = false;
    });
    final books = await _service.getAudiobooks(offset: _currentOffset, limit: _limit);
    if (!mounted) return;
    setState(() {
      _books = books;
      _isLoading = false;
      _isSearching = false;
    });
  }

  Future<void> _onSearch(String query) async {
    if (query.isEmpty) {
      _currentOffset = 0;
      _loadBooks();
      return;
    }
    setState(() {
      _isLoading = true;
      _isSearching = true;
      _showLiked = false;
    });
    final results = await _service.searchAudiobooks(query);
    setState(() {
      _books = results;
      _isLoading = false;
    });
  }

  void _toggleLikedView() {
    setState(() {
      _showLiked = !_showLiked;
      if (_showLiked) {
        _isSearching = false;
      }
    });
    if (_showLiked) {
      _loadLikedBooks();
    }
  }

  void _nextPage() {
    setState(() {
      _currentOffset += _limit;
    });
    _loadBooks();
  }

  void _prevPage() {
    if (_currentOffset >= _limit) {
      setState(() {
        _currentOffset -= _limit;
      });
      _loadBooks();
    }
  }

  void _resumeAudiobook(Map<String, dynamic> progress) async {
    final book = Audiobook.fromJson(progress['book']);
    
    _openAudiobook(
      book, 
      initialChapter: progress['chapterIndex'], 
      initialPosition: Duration(milliseconds: progress['positionMs']),
    );
  }

  void _removeFromHistory(String audioBookId) async {
    await _playerService.removeFromHistory(audioBookId);
    _loadHistory();
  }

  void _openAudiobook(Audiobook book, {int initialChapter = 0, Duration? initialPosition}) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(child: CircularProgressIndicator(color: AppTheme.primaryColor)),
    );

    final chapters = await _service.getChapters(book);
    
    if (mounted) {
      Navigator.pop(context); 
      final musicService = MusicPlayerService();
      if (chapters.isNotEmpty) {
        if (Platform.isWindows || MediaQuery.of(context).size.width > 900) {
          musicService.isFullScreenVisible.value = true;
          showDialog(
            context: context,
            builder: (context) => Dialog(
              backgroundColor: Colors.transparent,
              insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 500, maxHeight: 850),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(24),
                  child: AudiobookPlayerScreen(
                    audiobook: book,
                    chapters: chapters,
                    initialChapterIndex: initialChapter,
                    initialPosition: initialPosition,
                  ),
                ),
              ),
            ),
          ).then((_) {
            musicService.isFullScreenVisible.value = false;
            _loadHistory();
          });
        } else {
          musicService.isFullScreenVisible.value = true;
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => AudiobookPlayerScreen(
                audiobook: book,
                chapters: chapters,
                initialChapterIndex: initialChapter,
                initialPosition: initialPosition,
              ),
            ),
          ).then((_) {
            musicService.isFullScreenVisible.value = false;
            _loadHistory();
          }); 
        }
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to load audio tracks. Book might be restricted.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 24),
            _buildHeader(),
            _buildSearchBar(),
            Expanded(
              child: RefreshIndicator(
                onRefresh: () async {
                  await _loadBooks();
                  await _loadHistory();
                },
                color: AppTheme.primaryColor,
                child: SingleChildScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  child: Column(
                    children: [
                      if (!_isSearching && _history.isNotEmpty) _buildHistoryCarousel(),
                      _buildBody(),
                    ],
                  ),
                ),
              ),
            ),
            if (!_isSearching) _buildPagination(),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          const Text(
            'Audiobooks',
            style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold, fontFamily: 'Poppins'),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: const Icon(Icons.auto_awesome, color: Colors.white, size: 24),
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (context) => const GenerateAudiobookScreen()),
                  ).then((_) => _loadHistory());
                },
                tooltip: 'Generate your own audiobook',
              ),
              IconButton(
                icon: const Icon(Icons.download_rounded, color: Colors.white, size: 26),
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (context) => const AudiobookDownloadsScreen()),
                  );
                },
                tooltip: 'Downloads',
              ),
              IconButton(
                icon: Icon(
                  _showLiked ? Icons.favorite : Icons.favorite_border,
                  color: _showLiked ? Colors.redAccent : Colors.white,
                  size: 28,
                ),
                onPressed: _toggleLikedView,
                tooltip: 'Liked Audiobooks',
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
      child: TextField(
        controller: _searchController,
        onSubmitted: _onSearch,
        decoration: InputDecoration(
          hintText: 'Search audiobooks...',
          prefixIcon: const Icon(Icons.search, color: Colors.white54),
          filled: true,
          fillColor: Colors.white.withValues(alpha: 0.05),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(30), borderSide: BorderSide.none),
          contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        ),
      ),
    );
  }

  Widget _buildHistoryThumb(Audiobook book) {
    final url = book.thumbUrl;
    final isLocal = url.isNotEmpty && !url.startsWith('http://') && !url.startsWith('https://');
    if (isLocal) {
      final f = File(url);
      if (f.existsSync()) {
        return Image.file(f, width: 60, height: 60, fit: BoxFit.cover);
      }
    }
    return CachedNetworkImage(
      imageUrl: url,
      width: 60, height: 60, fit: BoxFit.cover,
      errorWidget: (c, u, e) => Container(
        width: 60, height: 60, color: Colors.white12,
        child: const Icon(Icons.menu_book_rounded, color: Colors.white54),
      ),
    );
  }

  Widget _buildHistoryCarousel() {
    final isDesktop = MediaQuery.of(context).size.width > 600;
    final pageController = PageController(viewportFraction: isDesktop ? 0.45 : 0.9);
    
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('CONTINUE LISTENING', style: TextStyle(color: Colors.white54, fontWeight: FontWeight.bold, letterSpacing: 2, fontSize: 12)),
              if (isDesktop && _history.length > 1)
                Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back_ios, size: 16),
                      onPressed: () {
                        pageController.previousPage(
                          duration: const Duration(milliseconds: 300),
                          curve: Curves.easeInOut,
                        );
                      },
                      color: Colors.white54,
                    ),
                    IconButton(
                      icon: const Icon(Icons.arrow_forward_ios, size: 16),
                      onPressed: () {
                        pageController.nextPage(
                          duration: const Duration(milliseconds: 300),
                          curve: Curves.easeInOut,
                        );
                      },
                      color: Colors.white54,
                    ),
                  ],
                ),
            ],
          ),
        ),
        SizedBox(
          height: 120,
          child: PageView.builder(
            controller: pageController,
            itemCount: _history.length,
            itemBuilder: (context, index) {
              final progress = _history[index];
              final book = Audiobook.fromJson(progress['book']);
              final title = book.title;
              final chapterIdx = progress['chapterIndex'] + 1;

              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Stack(
                  children: [
                    FocusableControl(
                      onTap: () => _resumeAudiobook(progress),
                      borderRadius: 16,
                      child: Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: AppTheme.primaryColor.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: AppTheme.primaryColor.withValues(alpha: 0.3)),
                        ),
                        child: Row(
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: _buildHistoryThumb(book),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                                  const SizedBox(height: 4),
                                  Text('Chapter $chapterIdx', style: const TextStyle(color: AppTheme.primaryColor, fontSize: 13, fontWeight: FontWeight.w500)),
                                ],
                              ),
                            ),
                            const Icon(Icons.play_circle_fill, color: AppTheme.primaryColor, size: 40),
                          ],
                        ),
                      ),
                    ),
                    Positioned(
                      top: 4, right: 4,
                      child: GestureDetector(
                        onTap: () => _removeFromHistory(book.audioBookId),
                        child: Container(
                          padding: const EdgeInsets.all(4),
                          decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
                          child: const Icon(Icons.close, size: 16, color: Colors.white70),
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildBody() {
    final displayBooks = _showLiked ? _likedBooks : _books;
    
    if (_isLoading && !_showLiked) return const Padding(padding: EdgeInsets.only(top: 100), child: Center(child: CircularProgressIndicator(color: AppTheme.primaryColor)));
    if (displayBooks.isEmpty) return Padding(padding: const EdgeInsets.only(top: 100), child: Center(child: Text(_showLiked ? 'No liked audiobooks' : 'No audiobooks found', style: const TextStyle(color: Colors.white54))));

    final screenWidth = MediaQuery.of(context).size.width;
    int crossAxisCount = 2;
    if (screenWidth > 1200) {
      crossAxisCount = 6;
    } else if (screenWidth > 900) {
      crossAxisCount = 4;
    } else if (screenWidth > 600) {
      crossAxisCount = 3;
    }

    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 150),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: crossAxisCount,
        childAspectRatio: 0.7,
        crossAxisSpacing: 16,
        mainAxisSpacing: 16,
      ),
      itemCount: displayBooks.length,
      itemBuilder: (context, index) {
        final book = displayBooks[index];
        return _buildBookCard(book);
      },
    );
  }

  Widget _buildBookCard(Audiobook book) {
    final isLiked = _likedBooks.any((b) => b.audioBookId == book.audioBookId);

    return FocusableControl(
      onTap: () => _openAudiobook(book),
      borderRadius: 16,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(16),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: CachedNetworkImage(
                    imageUrl: book.thumbUrl,
                    fit: BoxFit.cover,
                    width: double.infinity,
                    placeholder: (context, url) => Container(color: Colors.white10),
                    errorWidget: (context, url, error) => CachedNetworkImage(
                      imageUrl: book.coverImage,
                      fit: BoxFit.cover,
                      width: double.infinity,
                      errorWidget: (c, u, e) => const Center(child: Icon(Icons.book, color: Colors.white24)),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(12.0),
                  child: Text(
                    book.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                  ),
                ),
              ],
            ),
            Positioned(
              top: 8, right: 8,
              child: GestureDetector(
                onTap: () async {
                  await _playerService.toggleLikeBook(book);
                  _loadLikedBooks();
                },
                child: Container(
                  padding: const EdgeInsets.all(6),
                  decoration: const BoxDecoration(
                    color: Colors.black45,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    isLiked ? Icons.favorite : Icons.favorite_border,
                    color: isLiked ? Colors.redAccent : Colors.white70,
                    size: 18,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPagination() {
    if (_showLiked) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 24),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          ElevatedButton(
            onPressed: _currentOffset > 0 ? _prevPage : null,
            style: ElevatedButton.styleFrom(backgroundColor: Colors.white10, foregroundColor: Colors.white),
            child: const Text('Previous'),
          ),
          Text('Page ${(_currentOffset / _limit).floor() + 1}', style: const TextStyle(fontWeight: FontWeight.bold)),
          ElevatedButton(
            onPressed: _nextPage,
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primaryColor, foregroundColor: Colors.white),
            child: const Text('Next Page'),
          ),
        ],
      ),
    );
  }

}
