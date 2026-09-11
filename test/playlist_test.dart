import 'dart:async';
import 'dart:convert';

import 'package:caring_haven/haven.dart';
import 'package:caring_haven/playlist_views.dart';
import 'package:caring_haven/youtube_video_page.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class PlaylistStore extends HavenStore {
  PlaylistStore(super.preferences);
  Future<dynamic> Function(String path)? respond;
  final requests = <String>[];

  @override
  Future<dynamic> api(
    String path, {
    String method = 'GET',
    Map<String, dynamic>? data,
  }) async {
    requests.add(path);
    return respond!(path);
  }

  @override
  Future<void> refresh() async {}
}

void main() {
  const playlist = <String, dynamic>{
    'id': 7,
    'title': 'Growing in faith',
    'contents_count': 2,
    'description': 'A journey of hope.',
  };
  const second = <String, dynamic>{
    'id': 20,
    'title': 'Second recorded episode',
    'type': 'podcast',
    'body': 'Read the first playlist episode.',
    'video_url': 'https://youtu.be/AbCdEf12_-3',
  };
  const first = <String, dynamic>{
    'id': 10,
    'title': 'First recorded episode',
    'type': 'podcast',
    'audio_url': 'https://example.org/episode.mp3',
  };

  Future<PlaylistStore> makeStore([
    Map<String, Object> values = const {},
  ]) async {
    SharedPreferences.setMockInitialValues(values);
    return PlaylistStore(await SharedPreferences.getInstance());
  }

  test('Playlist list refresh caches data and retains it on failure', () async {
    final store = await makeStore();
    store.respond = (_) async => [playlist];
    await store.refreshPlaylists();
    expect(store.requests, ['/playlists']);
    expect(store.playlists.single['id'], 7);
    expect(
      store.preferences.getString('playlists'),
      contains('Growing in faith'),
    );
    store.respond = (_) async => throw Exception('offline');
    await store.refreshPlaylists();
    expect(store.playlists.single['id'], 7);
    expect(store.playlistsError, contains('Showing saved playlists'));
    expect(store.playlistsLoading, isFalse);
    store.dispose();
  });

  testWidgets(
    'Podcasts searches playlists and keeps individual episode results',
    (tester) async {
      final store = await makeStore();
      store.playlists = [playlist];
      store.contents = [first];
      await tester.pumpWidget(HavenApp(store: store));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Podcasts'));
      await tester.pumpAndSettle();
      expect(find.text('Growing in faith'), findsOneWidget);
      expect(find.text('All episodes'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'growing');
      await tester.pumpAndSettle();
      expect(find.text('Growing in faith'), findsOneWidget);
      expect(find.text('First recorded episode'), findsNothing);
      await tester.enterText(find.byType(TextField), 'recorded');
      await tester.pumpAndSettle();
      expect(find.text('Growing in faith'), findsNothing);
      expect(find.text('First recorded episode'), findsWidgets);
      await tester.pumpWidget(const SizedBox.shrink());
      store.dispose();
    },
  );

  testWidgets('Playlist loads API order and opens an existing reader', (
    tester,
  ) async {
    final store = await makeStore();
    final response = Completer<dynamic>();
    store.respond = (_) => response.future;
    await tester.pumpWidget(
      MaterialApp(
        home: PlaylistPage(store: store, playlist: playlist),
      ),
    );
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(
      find.text('No episodes have been added to this playlist yet.'),
      findsNothing,
    );
    response.complete({
      ...playlist,
      'contents': [second, first],
    });
    await tester.pumpAndSettle();
    expect(store.requests, ['/playlists/7']);
    expect(
      tester.getTopLeft(find.text(second['title'] as String)).dy,
      lessThan(tester.getTopLeft(find.text(first['title'] as String)).dy),
    );
    expect(find.byTooltip('Watch episode 1'), findsOneWidget);
    expect(find.byTooltip('Listen to episode 2'), findsOneWidget);
    await tester.tap(find.text(second['title'] as String));
    await tester.pumpAndSettle();
    expect(find.byType(ReaderPage), findsOneWidget);
    expect(find.text(second['body'] as String), findsOneWidget);
    expect(
      store.preferences.getString('playlist-7'),
      contains('Second recorded episode'),
    );
    await tester.pumpWidget(const SizedBox.shrink());
    store.dispose();
  });

  testWidgets('Playlist retry replaces an error with an empty state', (
    tester,
  ) async {
    final store = await makeStore();
    store.respond = (_) async => throw Exception('offline');
    await tester.pumpWidget(
      MaterialApp(
        home: PlaylistPage(store: store, playlist: playlist),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Unable to load this playlist. Check your connection and try again.',
      ),
      findsOneWidget,
    );
    store.respond = (_) async => {...playlist, 'contents': []};
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(
      find.text('No episodes have been added to this playlist yet.'),
      findsOneWidget,
    );
    expect(find.text('Retry'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    store.dispose();
  });

  testWidgets('Cached playlist stays readable when its refresh fails', (
    tester,
  ) async {
    final store = await makeStore({
      'playlist-7': jsonEncode({
        ...playlist,
        'contents': [second, first],
      }),
    });
    store.respond = (_) async => throw Exception('offline');
    await tester.pumpWidget(
      MaterialApp(
        home: PlaylistPage(store: store, playlist: playlist),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Second recorded episode'), findsOneWidget);
    expect(find.textContaining('Showing saved episodes'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    store.dispose();
  });

  testWidgets(
    'YouTube playlist item uses YouTube page with an external fallback',
    (tester) async {
      final store = await makeStore();
      final previousPlatform = debugDefaultTargetPlatformOverride;
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      try {
        store.respond = (_) async => {
          ...playlist,
          'contents': [second],
        };
        await tester.pumpWidget(
          MaterialApp(
            home: PlaylistPage(store: store, playlist: playlist),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Watch episode 1'));
        await tester.pumpAndSettle();
        expect(find.byType(YouTubeVideoPage), findsOneWidget);
        expect(find.text('Watch on YouTube'), findsOneWidget);
        expect(
          find.text('Open YouTube to watch this video on your device.'),
          findsOneWidget,
        );
      } finally {
        debugDefaultTargetPlatformOverride = previousPlatform;
        await tester.pumpWidget(const SizedBox.shrink());
        store.dispose();
      }
    },
  );
}
