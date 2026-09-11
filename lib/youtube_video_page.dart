import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:youtube_player_iframe/youtube_player_iframe.dart';

import 'youtube_url.dart';

class YouTubeVideoPage extends StatefulWidget {
  const YouTubeVideoPage({super.key, required this.url, required this.title});
  final String url, title;

  @override
  State<YouTubeVideoPage> createState() => _YouTubeVideoPageState();
}

class _YouTubeVideoPageState extends State<YouTubeVideoPage>
    with WidgetsBindingObserver {
  YoutubePlayerController? _controller;
  StreamSubscription<YoutubePlayerValue>? _subscription;
  Timer? _loadingTimer;
  late final String? _videoId;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _videoId = youtubeVideoId(widget.url);
    if (_videoId == null) {
      _error = 'This YouTube link does not contain a valid video.';
      _loading = false;
      return;
    }
    final supported =
        kIsWeb ||
        {
          TargetPlatform.android,
          TargetPlatform.iOS,
          TargetPlatform.macOS,
        }.contains(defaultTargetPlatform);
    if (!supported) {
      _error = 'Open YouTube to watch this video on your device.';
      _loading = false;
      return;
    }
    try {
      final controller = YoutubePlayerController(
        params: YoutubePlayerParams(
          showFullscreenButton: true,
          // Native HTML WebViews use this origin as their Referer. These IDs
          // match Android applicationId and iOS PRODUCT_BUNDLE_IDENTIFIER.
          origin: kIsWeb
              ? Uri.base.origin
              : defaultTargetPlatform == TargetPlatform.android
              ? 'https://org.caringhavenuganda.caring_haven'
              : 'https://org.caringhavenuganda.caringhaven',
        ),
        onWebResourceError: (_) => _showError(),
      );
      _controller = controller;
      _subscription = controller.listen((value) {
        if (value.hasError) {
          _showError();
        } else if (value.playerState != PlayerState.unknown && mounted) {
          _loadingTimer?.cancel();
          setState(() => _loading = false);
        }
      });
      controller.cueVideoById(videoId: _videoId).catchError((Object _) {
        _showError();
      });
      _loadingTimer = Timer(const Duration(seconds: 20), _showError);
    } catch (_) {
      _error = 'The video cannot play here. Try watching it on YouTube.';
      _loading = false;
    }
  }

  void _showError() {
    if (!mounted) return;
    _loadingTimer?.cancel();
    setState(() {
      _loading = false;
      _error = 'The video cannot play here. Try watching it on YouTube.';
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _pause();
    }
  }

  void _pause() {
    _controller?.pauseVideo().catchError((Object _) {});
  }

  Future<void> _watchOnYouTube() async {
    try {
      // Start the external launch directly from the tap, including on web.
      final launched = launchUrl(
        Uri.https('www.youtube.com', '/watch', {'v': _videoId!}),
        mode: LaunchMode.externalApplication,
      );
      _pause();
      if (!await launched) throw Exception('Unable to open YouTube.');
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Unable to open YouTube. Please try again.'),
        ),
      );
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _loadingTimer?.cancel();
    _subscription?.cancel();
    _controller?.close().catchError((Object _) {});
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.title)),
    body: ListView(
      children: [
        if (_controller != null)
          LayoutBuilder(
            builder: (context, constraints) => YoutubePlayer(
              controller: _controller!,
              aspectRatio: constraints.maxWidth < 356
                  ? constraints.maxWidth / 200
                  : 16 / 9,
            ),
          ),
        Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_loading) ...[
                const LinearProgressIndicator(),
                const SizedBox(height: 12),
                const Text('Loading YouTube video...'),
              ],
              if (_error != null) Text(_error!),
              if (_videoId != null) ...[
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  onPressed: _watchOnYouTube,
                  icon: const Icon(Icons.open_in_new),
                  label: const Text('Watch on YouTube'),
                ),
                const SizedBox(height: 12),
                const Text('YouTube videos require an internet connection.'),
              ],
            ],
          ),
        ),
      ],
    ),
  );
}
