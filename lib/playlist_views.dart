import 'dart:convert';

import 'package:flutter/material.dart';

import 'haven.dart';
import 'youtube_url.dart';

class PlaylistSection extends StatelessWidget {
  const PlaylistSection({super.key, required this.store, this.search = ''});
  final HavenStore store;
  final String search;

  @override
  Widget build(BuildContext context) {
    final rows = store.playlists.where(
      (playlist) => '${playlist['title']} ${playlist['description'] ?? ''}'
          .toLowerCase()
          .contains(search.toLowerCase()),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Playlists',
          style: TextStyle(fontSize: 21, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        if (store.playlistsLoading) const LinearProgressIndicator(),
        if (store.playlistsError != null) ...[
          Text(store.playlistsError!),
          TextButton.icon(
            onPressed: store.playlistsLoading ? null : store.refreshPlaylists,
            icon: const Icon(Icons.refresh),
            label: const Text('Retry playlists'),
          ),
        ],
        if (rows.isEmpty &&
            !store.playlistsLoading &&
            store.playlistsError == null)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Text(
              search.isEmpty
                  ? 'New playlists will appear here when published.'
                  : 'No playlists match your search.',
            ),
          ),
        ...rows.map((playlist) {
          final count = playlist['contents_count'] ?? 0;
          final image = playlist['image_url'] as String?;
          return Card(
            margin: const EdgeInsets.only(bottom: 12),
            child: ListTile(
              contentPadding: const EdgeInsets.all(12),
              leading: SizedBox(
                width: 56,
                height: 56,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: image != null && image.isNotEmpty
                      ? Image.network(
                          image,
                          fit: BoxFit.cover,
                          errorBuilder: (_, error, stack) =>
                              const Icon(Icons.queue_music, color: green),
                        )
                      : const Icon(Icons.queue_music, color: green, size: 32),
                ),
              ),
              title: Text(
                playlist['title'],
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: Text('$count ${count == 1 ? 'episode' : 'episodes'}'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) =>
                      PlaylistPage(store: store, playlist: playlist),
                ),
              ),
            ),
          );
        }),
        const SizedBox(height: 20),
        const Text(
          'All episodes',
          style: TextStyle(fontSize: 21, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 15),
      ],
    );
  }
}

class PlaylistPage extends StatefulWidget {
  const PlaylistPage({super.key, required this.store, required this.playlist});
  final HavenStore store;
  final Map<String, dynamic> playlist;

  @override
  State<PlaylistPage> createState() => _PlaylistPageState();
}

class _PlaylistPageState extends State<PlaylistPage> {
  Map<String, dynamic>? _detail;
  bool _loading = true;
  String? _error;
  String get _cacheKey => 'playlist-${widget.playlist['id']}';

  @override
  void initState() {
    super.initState();
    final cached = widget.store.preferences.getString(_cacheKey);
    if (cached != null) {
      try {
        final cachedDetail = Map<String, dynamic>.from(jsonDecode(cached));
        List<Map<String, dynamic>>.from(cachedDetail['contents']);
        _detail = cachedDetail;
      } catch (_) {
        // A damaged cache must not prevent a fresh playlist from loading.
      }
    }
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = Map<String, dynamic>.from(
        await widget.store.api('/playlists/${widget.playlist['id']}'),
      );
      // Validate the ordered items before replacing a usable cached playlist.
      List<Map<String, dynamic>>.from(result['contents']);
      await widget.store.preferences.setString(_cacheKey, jsonEncode(result));
      if (mounted) setState(() => _detail = result);
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = _detail == null
              ? 'Unable to load this playlist. Check your connection and try again.'
              : 'Unable to refresh. Showing saved episodes; videos need internet.',
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _play(Map<String, dynamic> item) async {
    try {
      final video = item['video_url'] as String?;
      if (video != null && video.isNotEmpty) {
        if (widget.store.playing != null) await widget.store.audio.pause();
        if (!mounted) return;
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => VideoPage(url: video, title: item['title']),
          ),
        );
        return;
      }
      await widget.store.play(item);
    } catch (error) {
      if (mounted) message(context, error);
    }
  }

  void _open(Map<String, dynamic> item) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ReaderPage(store: widget.store, item: item),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final playlist = _detail ?? widget.playlist;
    final items = List<Map<String, dynamic>>.from(_detail?['contents'] ?? []);
    final description = playlist['description'] as String?;
    final image = playlist['image_url'] as String?;
    return Scaffold(
      appBar: AppBar(title: Text(playlist['title'])),
      body: Column(
        children: [
          Expanded(
            child: RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(22),
                children: [
                  if (image != null && image.isNotEmpty) ...[
                    ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: Image.network(
                        image,
                        height: 180,
                        fit: BoxFit.cover,
                        errorBuilder: (_, error, stack) =>
                            const SizedBox.shrink(),
                      ),
                    ),
                    const SizedBox(height: 18),
                  ],
                  if (description != null && description.isNotEmpty) ...[
                    Text(description),
                    const SizedBox(height: 20),
                  ],
                  if (_loading) ...[
                    const LinearProgressIndicator(),
                    const SizedBox(height: 16),
                  ],
                  if (_error != null) ...[
                    Text(_error!),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: _loading ? null : _load,
                        icon: const Icon(Icons.refresh),
                        label: const Text('Retry'),
                      ),
                    ),
                  ],
                  if (_detail != null && items.isEmpty && !_loading)
                    const Text(
                      'No episodes have been added to this playlist yet.',
                    ),
                  for (var index = 0; index < items.length; index++)
                    _episode(items[index], index + 1),
                ],
              ),
            ),
          ),
          ListenableBuilder(
            listenable: widget.store,
            builder: (_, child) => widget.store.playing == null
                ? const SizedBox.shrink()
                : MiniPlayer(store: widget.store),
          ),
        ],
      ),
    );
  }

  Widget _episode(Map<String, dynamic> item, int number) {
    final hasVideo = (item['video_url'] as String?)?.isNotEmpty == true;
    final hasAudio = directMediaUri(item['audio_url'] as String?) != null;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        leading: CircleAvatar(
          backgroundColor: Theme.of(context).colorScheme.primaryContainer,
          child: Text('$number'),
        ),
        title: Text(item['title']),
        subtitle: Text(item['speaker'] ?? 'Caring Haven'),
        trailing: IconButton(
          tooltip: hasVideo
              ? 'Watch episode $number'
              : hasAudio
              ? 'Listen to episode $number'
              : 'Read episode $number',
          icon: Icon(
            hasVideo
                ? Icons.ondemand_video
                : hasAudio
                ? Icons.play_circle_outline
                : Icons.menu_book_outlined,
          ),
          onPressed: () => hasVideo || hasAudio ? _play(item) : _open(item),
        ),
        onTap: () => _open(item),
      ),
    );
  }
}
