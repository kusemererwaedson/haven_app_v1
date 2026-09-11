const _youtubeHosts = {
  'youtube.com',
  'www.youtube.com',
  'm.youtube.com',
  'music.youtube.com',
  'youtu.be',
  'www.youtu.be',
  'youtube-nocookie.com',
  'www.youtube-nocookie.com',
};

/// Identifies YouTube links even when they do not contain a playable video ID.
/// Such links must never be sent to a native media player or downloaded.
bool isYouTubeUrl(String? value) {
  final uri = Uri.tryParse(value?.trim() ?? '');
  return uri != null && _youtubeHosts.contains(uri.host.toLowerCase());
}

/// Accepts only supported YouTube URL shapes with an exact 11-character ID.
String? youtubeVideoId(String? value) {
  try {
    return _youtubeVideoId(value);
  } on FormatException {
    // Invalid percent-encoded query/path text is not a playable video ID.
    return null;
  }
}

String? _youtubeVideoId(String? value) {
  final uri = Uri.tryParse(value?.trim() ?? '');
  if (uri == null ||
      !{'http', 'https'}.contains(uri.scheme) ||
      !_youtubeHosts.contains(uri.host.toLowerCase()) ||
      uri.userInfo.isNotEmpty ||
      uri.hasPort) {
    return null;
  }
  final segments = uri.pathSegments;
  final host = uri.host.toLowerCase();
  String? id;
  if (host == 'youtu.be' || host == 'www.youtu.be') {
    if (segments.length == 1) id = segments.single;
  } else if (uri.path == '/watch' && !host.endsWith('youtube-nocookie.com')) {
    final values = uri.queryParametersAll['v'];
    if (values?.length == 1) id = values!.single;
  } else if (segments.length == 2 &&
      {'embed', 'shorts', 'live'}.contains(segments.first)) {
    id = segments.last;
  }
  return id != null &&
          id.length == 11 &&
          RegExp(r'^[a-zA-Z0-9_-]{11}$').hasMatch(id)
      ? id
      : null;
}

/// Direct media must use HTTP(S); YouTube page URLs require its iframe player.
Uri? directMediaUri(String? value) {
  final uri = Uri.tryParse(value?.trim() ?? '');
  if (uri == null ||
      !{'http', 'https'}.contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      isYouTubeUrl(value)) {
    return null;
  }
  return uri;
}
