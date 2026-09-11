import 'package:caring_haven/haven.dart';
import 'package:caring_haven/youtube_url.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const id = 'AbCdEf12_-3';
  group('YouTube URL parsing', () {
    for (final url in [
      'https://www.youtube.com/watch?v=$id',
      'https://youtube.com/watch?feature=share&v=$id&t=20',
      'http://m.youtube.com/watch?v=$id',
      'https://music.youtube.com/watch?v=$id&list=PL123',
      'https://youtu.be/$id?si=share',
      'https://www.youtu.be/$id',
      'https://www.youtube.com/embed/$id',
      'https://www.youtube-nocookie.com/embed/$id',
      'https://youtube.com/shorts/$id',
      'https://youtube.com/live/$id',
      '  https://WWW.YOUTUBE.COM/watch?v=$id  ',
    ]) {
      test('parses $url', () => expect(youtubeVideoId(url), id));
    }

    for (final url in [
      null,
      '',
      id,
      'https://youtube.com.evil.test/watch?v=$id',
      'https://notyoutube.com/watch?v=$id',
      'https://evil.test/youtube.com/watch?v=$id',
      'https://youtube.com@evil.test/watch?v=$id',
      'https://evil.test@youtube.com/watch?v=$id',
      'https://youtube.com:8443/watch?v=$id',
      'javascript:https://youtube.com/watch?v=$id',
      'ftp://youtube.com/watch?v=$id',
      'https://youtu.be/${id}extra',
      'https://youtu.be/$id/extra',
      'https://youtu.be/AbCdEf12_-',
      'https://youtube.com/watch?v=$id&v=12345678901',
      'https://youtube.com/watch?v=AbCdEf12_!3',
      'https://youtube.com/watch?v=AbCdEf12_%2F',
      'https://youtube.com/watch?v=$id%0A',
      'https://youtube.com/watch?v=%FF',
      'https://youtube.com/embed/%FF',
      'https://youtube.com/playlist?list=PL123',
      'https://youtube.com/channel/$id',
      'https://youtube-nocookie.com/watch?v=$id',
    ]) {
      test('rejects $url', () => expect(youtubeVideoId(url), isNull));
    }
  });

  test('YouTube pages never become native media sources', () {
    for (final url in [
      'https://youtube.com/watch?v=$id',
      'https://youtu.be/$id',
      'https://youtube.com/playlist?list=PL123',
      'https://youtube.com/watch?v=invalid',
      'ftp://youtube.com/watch?v=$id',
    ]) {
      expect(isYouTubeUrl(url), isTrue);
      expect(directMediaUri(url), isNull);
    }
    expect(isYouTubeUrl('https://notyoutube.com/watch?v=$id'), isFalse);
    expect(directMediaUri('https://media.example.org/episode.mp3'), isNotNull);
    expect(directMediaUri('https://media.example.org/episode.mp4'), isNotNull);
    expect(directMediaUri('http://media.example.org/live.m3u8'), isNotNull);
    expect(directMediaUri('javascript:alert(1)'), isNull);
    expect(directMediaUri('file:///etc/passwd'), isNull);
    expect(directMediaUri('/relative.mp3'), isNull);
  });

  test(
    'Store rejects YouTube audio before opening or downloading a file',
    () async {
      SharedPreferences.setMockInitialValues({});
      final store = HavenStore(await SharedPreferences.getInstance());
      final item = {
        'id': 1,
        'title': 'Episode',
        'audio_url': 'https://youtu.be/$id',
      };
      await expectLater(store.play(item), throwsA(isA<Exception>()));
      await expectLater(store.download(item), throwsA(isA<Exception>()));
      expect(store.playing, isNull);
      expect(store.downloads, isEmpty);
      store.dispose();
    },
  );
}
