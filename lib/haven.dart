import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:video_player/video_player.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:share_plus/share_plus.dart';
import 'download_stub.dart' if (dart.library.io) 'download_native.dart';
import 'playlist_views.dart';
import 'youtube_url.dart';
import 'youtube_video_page.dart';

const green = Color(0xff7eb441), navy = Color(0xff13223c);

/// The counselling packages the ministry has published, in display order.
/// Hidden packages never reach members, and a missing/blank price means
/// "price on request" rather than free.
List<Map<String, dynamic>> counsellingPackages(HavenStore store) {
  final value = store.settings['counselling_packages'];
  final list = value is List ? value : const [];
  return list
      .whereType<Map>()
      .map((e) => Map<String, dynamic>.from(e))
      .where(
        (p) =>
            (p['name'] ?? '').toString().isNotEmpty && p['active'] != false,
      )
      .toList();
}

int? packageAmount(Map<String, dynamic> item) {
  final value = item['price_ugx'];
  if (value == null || '$value'.isEmpty) return null;
  return value is num ? value.toInt() : int.tryParse('$value');
}

bool packageNeedsPayment(Map<String, dynamic> item) =>
    (packageAmount(item) ?? 0) > 0;

double? moneyValue(dynamic value) =>
    value == null || '$value'.isEmpty ? null : double.tryParse('$value');

String ugx(num amount) {
  final digits = amount.toInt().abs().toString();
  final buffer = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(',');
    buffer.write(digits[i]);
  }
  return 'UGX $buffer';
}

String packagePriceLabel(Map<String, dynamic> item) {
  final amount = packageAmount(item);
  if (amount == null) return 'Price on request';
  return amount > 0 ? ugx(amount) : 'Free';
}

String packageMeta(Map<String, dynamic> item) {
  final sessions = (item['sessions'] as num?)?.toInt() ?? 1;
  final minutes = (item['minutes'] as num?)?.toInt() ?? 0;
  final parts = [sessions == 1 ? '1 session' : '$sessions sessions'];
  if (minutes > 0) parts.add('$minutes min');
  return parts.join(' · ');
}

String paymentLabel(String? status) => switch (status) {
  'not_required' => 'No payment needed',
  'unpaid' => 'Awaiting payment',
  'pending' => 'Payment pending',
  'paid' => 'Paid',
  'failed' => 'Payment failed',
  _ => status ?? '',
};

Future<void> startHaven() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!kIsWeb) {
    await JustAudioBackground.init(
      androidNotificationChannelId: 'org.caringhavenuganda.audio',
      androidNotificationChannelName: 'Caring Haven audio',
      androidNotificationOngoing: true,
    );
  }
  final store = HavenStore(await SharedPreferences.getInstance());
  await store.initialize();
  runApp(HavenApp(store: store));
}

class HavenStore extends ChangeNotifier {
  HavenStore(this.preferences);
  final SharedPreferences preferences;
  final secure = const FlutterSecureStorage();
  late final audio = AudioPlayer();
  static const base = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://www.api.calizaproperties.com/api',
  );
  String? token;
  Map<String, dynamic>? user, playing;
  List<Map<String, dynamic>> contents = [], favorites = [];
  List<Map<String, dynamic>> playlists = [];
  bool playlistsLoading = false;
  String? playlistsError;
  Map<String, dynamic> settings = {}, downloads = {};
  bool dark = false, offline = false, loading = false;
  void changed() => notifyListeners();
  String? error;
  Future<dynamic> api(
    String path, {
    String method = 'GET',
    Map<String, dynamic>? data,
  }) async {
    final request = http.Request(method, Uri.parse('$base$path'));
    request.headers.addAll({
      'Accept': 'application/json',
      'Content-Type': 'application/json',
      if (token != null) 'Authorization': 'Bearer $token',
    });
    if (data != null) request.body = jsonEncode(data);
    final response = await http.Response.fromStream(
      await request.send().timeout(const Duration(seconds: 30)),
    ).timeout(const Duration(seconds: 30));
    if (response.statusCode == 204) return null;
    final decoded = jsonDecode(response.body);
    if (response.statusCode >= 400) {
      throw Exception(
        decoded['message'] ?? 'Request failed. Please try again.',
      );
    }
    return decoded;
  }

  Future<void> initialize() async {
    dark = preferences.getBool('dark') ?? false;
    token = await secure.read(key: 'haven-token');
    contents = List<Map<String, dynamic>>.from(
      jsonDecode(preferences.getString('contents') ?? '[]'),
    );
    settings = Map<String, dynamic>.from(
      jsonDecode(preferences.getString('settings') ?? '{}'),
    );
    downloads = Map<String, dynamic>.from(
      jsonDecode(preferences.getString('downloads') ?? '{}'),
    );
    playlists = List<Map<String, dynamic>>.from(
      jsonDecode(preferences.getString('playlists') ?? '[]'),
    );
    // Render cached content immediately; network refresh is started by the shell.
  }

  Future<void> refresh() async {
    loading = true;
    error = null;
    notifyListeners();
    final playlistsRefresh = refreshPlaylists();
    try {
      final result = await api('/contents');
      contents = List<Map<String, dynamic>>.from(result['data']);
      for (var page = 2; page <= (result['last_page'] as int); page++) {
        final archive = await api('/contents?page=$page');
        contents.addAll(List<Map<String, dynamic>>.from(archive['data']));
      }
      settings = Map<String, dynamic>.from(await api('/settings'));
      await preferences.setString('contents', jsonEncode(contents));
      await preferences.setString('settings', jsonEncode(settings));
      offline = false;
      if (token != null) {
        try {
          user = Map<String, dynamic>.from(await api('/profile'));
          favorites = List<Map<String, dynamic>>.from(await api('/favorites'));
        } catch (e) {
          error = 'Sign in again to access your account.';
        }
      }
    } catch (e) {
      offline = true;
      error = contents.isEmpty
          ? 'Unable to connect. Pull down to try again.'
          : 'You’re offline. Showing saved messages.';
    } finally {
      await playlistsRefresh;
      loading = false;
      notifyListeners();
    }
  }

  Future<void> refreshPlaylists() async {
    if (playlistsLoading) return;
    playlistsLoading = true;
    playlistsError = null;
    notifyListeners();
    try {
      final result = List<Map<String, dynamic>>.from(await api('/playlists'));
      await preferences.setString('playlists', jsonEncode(result));
      playlists = result;
    } catch (_) {
      playlistsError = playlists.isEmpty
          ? 'Unable to load playlists. Please try again.'
          : 'Unable to refresh playlists. Showing saved playlists.';
    } finally {
      playlistsLoading = false;
      notifyListeners();
    }
  }

  Future<void> authenticate(Map<String, dynamic> data, bool register) async {
    final result = await api(
      register ? '/register' : '/login',
      method: 'POST',
      data: data,
    );
    token = result['token'];
    user = Map<String, dynamic>.from(result['user']);
    await secure.write(key: 'haven-token', value: token);
    favorites = List<Map<String, dynamic>>.from(await api('/favorites'));
    notifyListeners();
  }

  Future<void> logout() async {
    await api('/logout', method: 'POST');
    await secure.delete(key: 'haven-token');
    token = null;
    user = null;
    favorites = [];
    notifyListeners();
  }

  Future<void> toggleFavorite(Map<String, dynamic> item) async {
    if (user == null) throw Exception('Please sign in to save messages.');
    final exists = favorites.any((e) => e['id'] == item['id']);
    await api('/favorites/${item['id']}', method: exists ? 'DELETE' : 'PUT');
    if (exists) {
      favorites.removeWhere((e) => e['id'] == item['id']);
    } else {
      favorites.add(item);
    }
    notifyListeners();
  }

  Future<void> play(Map<String, dynamic> item) async {
    final url = item['audio_url'] as String?;
    if (url == null || url.isEmpty) {
      throw Exception('Audio has not been added to this message yet.');
    }
    if (directMediaUri(url) == null) {
      throw Exception(
        'This link is not a direct audio file. Use Watch for YouTube videos.',
      );
    }
    final saved = downloads['${item['id']}'] as String?;
    final uri = saved != null && await audioExists(saved)
        ? Uri.file(saved)
        : Uri.parse(url);
    await audio.setAudioSource(
      AudioSource.uri(
        uri,
        tag: MediaItem(
          id: '${item['id']}',
          title: item['title'],
          artist: item['speaker'] ?? 'Caring Haven',
        ),
      ),
    );
    final position = preferences.getInt('position-${item['id']}') ?? 0;
    if (position > 0 &&
        position < (audio.duration?.inMilliseconds ?? 0) - 5000) {
      await audio.seek(Duration(milliseconds: position));
    }
    playing = item;
    notifyListeners();
    audio.play().catchError((Object e) {
      error = e.toString();
      notifyListeners();
    });
  }

  Future<void> download(Map<String, dynamic> item) async {
    final url = item['audio_url'] as String?;
    if (url == null || url.isEmpty) {
      throw Exception('Audio is not available yet.');
    }
    if (directMediaUri(url) == null) {
      throw Exception(
        'Only direct audio files can be downloaded. YouTube videos require internet.',
      );
    }
    downloads['${item['id']}'] = await saveAudio(url, '${item['id']}');
    await preferences.setString('downloads', jsonEncode(downloads));
    notifyListeners();
  }

  void toggleTheme() {
    dark = !dark;
    preferences.setBool('dark', dark);
    notifyListeners();
  }
}

class HavenApp extends StatelessWidget {
  const HavenApp({super.key, required this.store});
  final HavenStore store;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: store,
    builder: (context, _) => MaterialApp(
      title: 'Caring Haven',
      debugShowCheckedModeBanner: false,
      themeMode: store.dark ? ThemeMode.dark : ThemeMode.light,
      theme: theme(Brightness.light),
      darkTheme: theme(Brightness.dark),
      home: HavenShell(store: store),
    ),
  );
  ThemeData theme(Brightness brightness) => ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: ColorScheme.fromSeed(
      seedColor: green,
      brightness: brightness,
      primary: brightness == Brightness.light ? const Color(0xff507a2b) : green,
    ),
    scaffoldBackgroundColor: brightness == Brightness.light
        ? const Color(0xfff8faf7)
        : const Color(0xff111c19),
    appBarTheme: const AppBarTheme(centerTitle: false),
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 15),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
  );
}

void message(BuildContext context, Object text) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(text.toString().replaceFirst('Exception: ', ''))),
  );
}

class HavenShell extends StatefulWidget {
  const HavenShell({super.key, required this.store});
  final HavenStore store;
  @override
  State<HavenShell> createState() => _HavenShellState();
}

class _HavenShellState extends State<HavenShell> {
  int page = 0;
  String search = '', audience = 'all';
  HavenStore get s => widget.store;
  final titles = [
    'Discover',
    'Daily devotionals',
    'Sermons',
    'Podcasts',
    'More',
  ];
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      s.refresh();
    });
  }

  void go(Widget screen) {
    Navigator.push(context, MaterialPageRoute(builder: (_) => screen));
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: s,
    builder: (context, _) => Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Image.asset('assets/images/caringhaven.png', width: 36, height: 34),
            const SizedBox(width: 8),
            const Text(
              'caringhaven',
              style: TextStyle(fontSize: 21, fontWeight: FontWeight.w700),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Toggle theme',
            onPressed: s.toggleTheme,
            icon: Icon(
              s.dark ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
            ),
          ),
          IconButton(
            tooltip: 'Your profile',
            onPressed: () => go(AccountPage(store: s)),
            icon: const Icon(Icons.account_circle_outlined),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: RefreshIndicator(
              onRefresh: s.refresh,
              child: ListView(
                padding: const EdgeInsets.all(22),
                children: [
                  if (s.error != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 15),
                      child: Text(
                        s.error!,
                        style: const TextStyle(color: green),
                      ),
                    ),
                  if (s.loading) const LinearProgressIndicator(),
                  if (page == 0)
                    ...home()
                  else if (page < 4)
                    ...library()
                  else
                    ...more(),
                ],
              ),
            ),
          ),
          if (s.playing != null) MiniPlayer(store: s),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: page,
        onDestinationSelected: (i) => setState(() {
          page = i;
          search = '';
          audience = 'all';
        }),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: 'Discover',
          ),
          NavigationDestination(
            icon: Icon(Icons.menu_book_outlined),
            label: 'Devotionals',
          ),
          NavigationDestination(
            icon: Icon(Icons.play_circle_outline),
            label: 'Sermons',
          ),
          NavigationDestination(
            icon: Icon(Icons.headphones_outlined),
            label: 'Podcasts',
          ),
          NavigationDestination(
            icon: Icon(Icons.grid_view_outlined),
            label: 'More',
          ),
        ],
      ),
    ),
  );
  List<Widget> home() => [
    const Text(
      'WELCOME TO YOUR HAVEN',
      style: TextStyle(color: green, fontSize: 10, letterSpacing: 2),
    ),
    const SizedBox(height: 10),
    const Text(
      'A little closer to God.',
      style: TextStyle(fontSize: 27, fontWeight: FontWeight.bold),
    ),
    const SizedBox(height: 8),
    const Text('Encouragement for today. Hope for the journey.'),
    const SizedBox(height: 24),
    Container(
      padding: const EdgeInsets.all(25),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: const LinearGradient(
          colors: [Color(0xff234d35), Color(0xff4c703c)],
          begin: Alignment.bottomLeft,
          end: Alignment.topRight,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.spa_outlined, color: Color(0xffd4e6a6), size: 35),
          const SizedBox(height: 15),
          const Text(
            'Rooted in faith.\nGrowing in hope.',
            style: TextStyle(
              fontSize: 33,
              height: 1.15,
              color: Colors.white,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 13),
          const Text(
            'A quiet moment. A life-giving word.\nLet’s walk this journey together.',
            style: TextStyle(color: Color(0xffd4dfcd), height: 1.6),
          ),
          const SizedBox(height: 20),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xffedf2dd),
              foregroundColor: const Color(0xff254b35),
            ),
            onPressed: () => setState(() => page = 1),
            child: const Text('Explore devotionals  →'),
          ),
        ],
      ),
    ),
    const SizedBox(height: 25),
    Row(
      children: [
        Expanded(
          child: quick(
            Icons.live_tv,
            'Watch live',
            () => go(LivePage(store: s)),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: quick(
            Icons.favorite_border,
            'Give hope',
            () => go(GivingPage(store: s)),
          ),
        ),
      ],
    ),
    const SizedBox(height: 27),
    const Text(
      'Your daily dose of hope',
      style: TextStyle(fontSize: 21, fontWeight: FontWeight.bold),
    ),
    const SizedBox(height: 15),
    ...s.contents.where((e) => e['type'] == 'devotional').take(1).map(card),
    const SizedBox(height: 20),
    const Text(
      'Listen. Learn. Be inspired.',
      style: TextStyle(fontSize: 21, fontWeight: FontWeight.bold),
    ),
    const SizedBox(height: 15),
    ...s.contents
        .where((e) => e['type'] == 'sermon' || e['type'] == 'podcast')
        .take(3)
        .map(card),
    if (s.contents.isEmpty && !s.loading)
      const Text('New messages will appear here when published.'),
  ];
  Widget quick(IconData icon, String label, VoidCallback action) => Card(
    child: InkWell(
      onTap: action,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          children: [
            Icon(icon, color: green),
            const SizedBox(height: 9),
            Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    ),
  );
  List<Widget> library() {
    final type = ['', 'devotional', 'sermon', 'podcast'][page];
    final items = s.contents
        .where(
          (e) =>
              e['type'] == type &&
              (audience == 'all' || e['audience'] == audience) &&
              ('${e['title']} ${e['speaker']} ${e['category']}')
                  .toLowerCase()
                  .contains(search.toLowerCase()),
        )
        .toList();
    return [
      Text(
        titles[page],
        style: const TextStyle(fontSize: 29, fontWeight: FontWeight.bold),
      ),
      const SizedBox(height: 18),
      TextField(
        decoration: const InputDecoration(
          hintText: 'Search messages, speakers, topics',
          prefixIcon: Icon(Icons.search),
        ),
        onChanged: (v) => setState(() => search = v),
      ),
      const SizedBox(height: 15),
      if (page == 1)
        Wrap(
          spacing: 8,
          children: ['all', 'adult', 'children', 'nextgen']
              .map(
                (a) => ChoiceChip(
                  label: Text(a),
                  selected: audience == a,
                  onSelected: (_) => setState(() => audience = a),
                ),
              )
              .toList(),
        ),
      const SizedBox(height: 15),
      if (page == 3) PlaylistSection(store: s, search: search),
      ...items.map(card),
      if (items.isEmpty)
        const Padding(
          padding: EdgeInsets.all(30),
          child: Text('No messages found. Try another search.'),
        ),
    ];
  }

  Widget card(Map<String, dynamic> item) => ContentTile(
    item: item,
    store: s,
    onTap: () => go(ReaderPage(store: s, item: item)),
  );
  List<Widget> more() => [
    const Text(
      'A place to belong.',
      style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
    ),
    const SizedBox(height: 20),
    ...[
      (Icons.live_tv, 'Live TV', () => go(LivePage(store: s))),
      (Icons.bookmark_outline, 'My library', () => go(SavedPage(store: s))),
      (
        Icons.download_outlined,
        'Downloads',
        () => go(SavedPage(store: s, downloads: true)),
      ),
      (Icons.favorite_border, 'Giving', () => go(GivingPage(store: s))),
      (
        Icons.chat_bubble_outline,
        'Counselling',
        () => go(BookingPage(store: s)),
      ),
      (
        Icons.event_outlined,
        'Events & updates',
        () => go(EventsPage(store: s)),
      ),
      (Icons.info_outline, 'About us', () => go(AboutPage(store: s))),
      (Icons.person_outline, 'Profile', () => go(AccountPage(store: s))),
    ].map(
      (row) => Card(
        child: ListTile(
          leading: Icon(row.$1, color: green),
          title: Text(row.$2),
          trailing: const Icon(Icons.chevron_right),
          onTap: row.$3,
        ),
      ),
    ),
  ];
}

class ContentTile extends StatelessWidget {
  const ContentTile({
    super.key,
    required this.item,
    required this.store,
    required this.onTap,
  });
  final Map<String, dynamic> item;
  final HavenStore store;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.only(bottom: 16),
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            height: 150,
            width: double.infinity,
            decoration: BoxDecoration(
              color: item['type'] == 'devotional'
                  ? const Color(0xffe8ebdd)
                  : const Color(0xffdfe7e2),
            ),
            child: item['image_url'] != null && item['image_url'] != ''
                ? Image.network(
                    item['image_url'],
                    fit: BoxFit.cover,
                    errorBuilder: (_, e, st) =>
                        const Icon(Icons.spa, size: 50, color: green),
                  )
                : Padding(
                    padding: const EdgeInsets.all(23),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'CARING HAVEN • ${item['type'].toString().toUpperCase()}',
                          style: const TextStyle(
                            color: Color(0xff5d7252),
                            fontSize: 9,
                            letterSpacing: 1.6,
                          ),
                        ),
                        const Spacer(),
                        Text(
                          item['title'],
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontFamily: 'serif',
                            fontSize: 27,
                            color: Color(0xff3c563e),
                          ),
                        ),
                      ],
                    ),
                  ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item['category'] ?? 'Faith',
                  style: const TextStyle(color: green, fontSize: 11),
                ),
                const SizedBox(height: 7),
                Text(
                  item['title'],
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  item['speaker'] ?? 'Caring Haven',
                  style: TextStyle(
                    fontSize: 11,
                    color: Theme.of(context).hintColor,
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

class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key, required this.store});
  final HavenStore store;
  @override
  Widget build(BuildContext context) => Material(
    elevation: 8,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ListTile(
          dense: true,
          leading: const Icon(Icons.headphones, color: green),
          title: Text(
            store.playing?['title'] ?? '',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            store.playing?['speaker'] ?? 'Caring Haven',
            maxLines: 1,
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              StreamBuilder<PlayerState>(
                stream: store.audio.playerStateStream,
                builder: (context, snapshot) => IconButton(
                  tooltip: 'Play or pause',
                  icon: Icon(
                    snapshot.data?.playing == true
                        ? Icons.pause
                        : Icons.play_arrow,
                  ),
                  onPressed: () async {
                    try {
                      if (store.audio.playing) {
                        await store.audio.pause();
                      } else {
                        if (store.audio.processingState ==
                            ProcessingState.completed) {
                          await store.audio.seek(Duration.zero);
                        }
                        await store.audio.play();
                      }
                    } catch (e) {
                      if (context.mounted) message(context, e);
                    }
                  },
                ),
              ),
              IconButton(
                tooltip: 'Close player',
                icon: const Icon(Icons.close, size: 20),
                onPressed: () async {
                  await store.audio.stop();
                  store.playing = null;
                  store.changed();
                },
              ),
            ],
          ),
        ),
        StreamBuilder<Duration>(
          stream: store.audio.positionStream,
          builder: (context, snapshot) {
            final value = snapshot.data ?? Duration.zero;
            final total = store.audio.duration ?? Duration.zero;
            if (store.playing != null && value.inSeconds % 5 == 0) {
              store.preferences.setInt(
                'position-${store.playing!['id']}',
                value.inMilliseconds,
              );
            }
            return Slider(
              value: value.inMilliseconds.toDouble().clamp(
                0,
                total.inMilliseconds.toDouble().clamp(1, double.infinity),
              ),
              max: total.inMilliseconds.toDouble().clamp(1, double.infinity),
              onChanged: (v) =>
                  store.audio.seek(Duration(milliseconds: v.toInt())),
            );
          },
        ),
      ],
    ),
  );
}

class ReaderPage extends StatefulWidget {
  const ReaderPage({super.key, required this.store, required this.item});
  final HavenStore store;
  final Map<String, dynamic> item;
  @override
  State<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends State<ReaderPage> {
  double size = 18;
  bool downloading = false;
  Future<void> action(Future<void> Function() fn) async {
    try {
      await fn();
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) message(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final i = widget.item, s = widget.store;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          i['type'].toString().toUpperCase(),
          style: const TextStyle(fontSize: 13, letterSpacing: 1),
        ),
        actions: [
          IconButton(
            tooltip: 'Save',
            onPressed: () => action(() => s.toggleFavorite(i)),
            icon: Icon(
              s.favorites.any((e) => e['id'] == i['id'])
                  ? Icons.bookmark
                  : Icons.bookmark_outline,
            ),
          ),
          IconButton(
            tooltip: 'Share',
            onPressed: () => SharePlus.instance.share(
              ShareParams(
                text: '${i['title']}\n\n${i['body'] ?? i['excerpt'] ?? ''}',
                sharePositionOrigin: const Rect.fromLTWH(0, 0, 100, 100),
              ),
            ),
            icon: const Icon(Icons.share_outlined),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                Text(i['category'] ?? '', style: const TextStyle(color: green)),
                const SizedBox(height: 12),
                Text(
                  i['title'],
                  style: const TextStyle(
                    fontSize: 31,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  i['scripture'] ?? '',
                  style: const TextStyle(
                    color: green,
                    fontStyle: FontStyle.italic,
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 10,
                  children: [
                    TextButton(
                      onPressed: () =>
                          setState(() => size = (size - 2).clamp(14, 30)),
                      child: const Text('A−'),
                    ),
                    TextButton(
                      onPressed: () =>
                          setState(() => size = (size + 2).clamp(14, 30)),
                      child: const Text('A+'),
                    ),
                    if (directMediaUri(i['audio_url'] as String?) != null) ...[
                      FilledButton.icon(
                        onPressed: () => action(() => s.play(i)),
                        icon: const Icon(Icons.play_arrow),
                        label: const Text('Listen'),
                      ),
                      IconButton(
                        tooltip: 'Download audio',
                        onPressed: downloading
                            ? null
                            : () async {
                                setState(() => downloading = true);
                                await action(() => s.download(i));
                                if (context.mounted) {
                                  setState(() => downloading = false);
                                  if (s.downloads.containsKey('${i['id']}')) {
                                    message(
                                      context,
                                      'Audio saved for offline listening.',
                                    );
                                  }
                                }
                              },
                        icon: Icon(
                          downloading
                              ? Icons.hourglass_top
                              : Icons.download_outlined,
                        ),
                      ),
                      IconButton(
                        tooltip: 'Repeat audio',
                        onPressed: () => action(
                          () => s.audio.setLoopMode(
                            s.audio.loopMode == LoopMode.one
                                ? LoopMode.off
                                : LoopMode.one,
                          ),
                        ),
                        icon: Icon(
                          Icons.repeat,
                          color: s.audio.loopMode == LoopMode.one
                              ? green
                              : null,
                        ),
                      ),
                    ],
                    if (i['video_url'] != null && i['video_url'] != '')
                      OutlinedButton.icon(
                        onPressed: () {
                          s.audio.pause();
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => VideoPage(
                                url: i['video_url'],
                                title: i['title'],
                              ),
                            ),
                          );
                        },
                        icon: const Icon(Icons.ondemand_video),
                        label: const Text('Watch'),
                      ),
                  ],
                ),
                const SizedBox(height: 22),
                SelectableText(
                  i['body'] ?? i['excerpt'] ?? '',
                  style: TextStyle(fontSize: size, height: 1.85),
                ),
                const SizedBox(height: 30),
                const Text(
                  'Devotionals you have loaded are available offline.',
                  style: TextStyle(fontSize: 11, color: green),
                ),
              ],
            ),
          ),
          ListenableBuilder(
            listenable: s,
            builder: (_, child) => s.playing == null
                ? const SizedBox.shrink()
                : MiniPlayer(store: s),
          ),
        ],
      ),
    );
  }
}

class SavedPage extends StatelessWidget {
  const SavedPage({super.key, required this.store, this.downloads = false});
  final HavenStore store;
  final bool downloads;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: store,
    builder: (context, _) {
      final items = downloads
          ? store.contents
                .where((i) => store.downloads.containsKey('${i['id']}'))
                .toList()
          : store.favorites;
      return Scaffold(
        appBar: AppBar(title: Text(downloads ? 'Downloads' : 'My library')),
        body: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            if (items.isEmpty)
              const Padding(
                padding: EdgeInsets.all(35),
                child: Text('Save a message to find it here.'),
              ),
            ...items.map(
              (i) => ContentTile(
                item: i,
                store: store,
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => ReaderPage(store: store, item: i),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
}

class VideoPage extends StatelessWidget {
  const VideoPage({super.key, required this.url, required this.title});
  final String url, title;
  @override
  Widget build(BuildContext context) {
    if (isYouTubeUrl(url)) return YouTubeVideoPage(url: url, title: title);
    if (directMediaUri(url) == null) {
      return Scaffold(
        appBar: AppBar(title: Text(title)),
        body: const Center(child: Text('This video link is not available.')),
      );
    }
    return _DirectVideoPage(url: url, title: title);
  }
}

class _DirectVideoPage extends StatefulWidget {
  const _DirectVideoPage({required this.url, required this.title});
  final String url, title;
  @override
  State<_DirectVideoPage> createState() => _VideoPageState();
}

class _VideoPageState extends State<_DirectVideoPage> {
  late VideoPlayerController controller;
  String? error;
  @override
  void initState() {
    super.initState();
    controller = VideoPlayerController.networkUrl(Uri.parse(widget.url));
    controller
        .initialize()
        .then((_) {
          if (mounted) setState(() {});
        })
        .catchError((Object e) {
          if (mounted) {
            setState(
              () =>
                  error = 'Unable to load this video. Please try again later.',
            );
          }
        });
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.title)),
    body: Center(
      child: error != null
          ? Text(error!)
          : !controller.value.isInitialized
          ? const CircularProgressIndicator()
          : Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AspectRatio(
                  aspectRatio: controller.value.aspectRatio,
                  child: VideoPlayer(controller),
                ),
                VideoProgressIndicator(controller, allowScrubbing: true),
                IconButton(
                  icon: Icon(
                    controller.value.isPlaying
                        ? Icons.pause_circle
                        : Icons.play_circle,
                    size: 50,
                  ),
                  onPressed: () => setState(() {
                    controller.value.isPlaying
                        ? controller.pause()
                        : controller.play();
                  }),
                ),
              ],
            ),
    ),
  );
}

class LivePage extends StatelessWidget {
  const LivePage({super.key, required this.store});
  final HavenStore store;
  @override
  Widget build(BuildContext context) {
    final url = store.settings['live_hls_url'];
    return Scaffold(
      appBar: AppBar(title: const Text('Caring Haven Live')),
      body: ListView(
        padding: const EdgeInsets.all(25),
        children: [
          const Icon(Icons.live_tv, size: 70, color: green),
          const SizedBox(height: 25),
          Text(
            store.settings['live_title'] ?? 'Caring Haven TV',
            style: const TextStyle(fontSize: 29, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 15),
          Text(
            store.settings['live_schedule']?.toString().isNotEmpty == true
                ? store.settings['live_schedule']
                : 'Our broadcast schedule will appear here.',
          ),
          const SizedBox(height: 25),
          if (url != null && url != '')
            FilledButton.icon(
              onPressed: () {
                store.audio.pause();
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) =>
                        VideoPage(url: url, title: 'Caring Haven Live'),
                  ),
                );
              },
              icon: const Icon(Icons.play_arrow),
              label: const Text('Watch live'),
            )
          else
            const Text(
              'The live stream is currently unavailable. Please check back soon.',
            ),
        ],
      ),
    );
  }
}

class AccountPage extends StatefulWidget {
  const AccountPage({super.key, required this.store});
  final HavenStore store;
  @override
  State<AccountPage> createState() => _AccountPageState();
}

class _AccountPageState extends State<AccountPage> {
  final form = GlobalKey<FormState>();
  final name = TextEditingController(),
      email = TextEditingController(),
      password = TextEditingController(),
      phone = TextEditingController();
  bool register = false, busy = false;
  @override
  void initState() {
    super.initState();
    name.text = widget.store.user?['name'] ?? '';
    phone.text = widget.store.user?['phone'] ?? '';
  }

  @override
  void dispose() {
    for (final c in [name, email, password, phone]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> submit() async {
    if (!form.currentState!.validate()) return;
    setState(() => busy = true);
    try {
      if (widget.store.user != null) {
        widget.store.user = Map<String, dynamic>.from(
          await widget.store.api(
            '/profile',
            method: 'PUT',
            data: {'name': name.text, 'phone': phone.text},
          ),
        );
        widget.store.changed();
        if (mounted) message(context, 'Profile saved.');
      } else {
        await widget.store.authenticate({
          'name': name.text,
          'email': email.text,
          'password': password.text,
        }, register);
        name.text = widget.store.user?['name'] ?? '';
        password.clear();
        if (!mounted) return;
        final chosen = await showPackagesSheet(context, widget.store);
        if (chosen != null && mounted) {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => BookingPage(
                store: widget.store,
                initialPackage: chosen['name'] as String?,
              ),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) message(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = widget.store.user;
    return Scaffold(
      appBar: AppBar(
        title: Text(user == null ? 'Welcome to the Haven' : 'Your profile'),
      ),
      body: Form(
        key: form,
        child: ListView(
          padding: const EdgeInsets.all(25),
          children: [
            const Icon(Icons.person_outline, size: 65, color: green),
            const SizedBox(height: 25),
            if (register || user != null) field(name, 'Full name'),
            if (user == null) ...[
              field(
                email,
                'Email address',
                keyboard: TextInputType.emailAddress,
              ),
              field(password, 'Password', secret: true, min: register ? 10 : 1),
            ] else ...[
              Text(user['email']),
              const SizedBox(height: 20),
              field(phone, 'Phone number', required: false),
            ],
            const SizedBox(height: 15),
            FilledButton(
              onPressed: busy ? null : submit,
              child: Text(
                busy
                    ? 'Please wait…'
                    : user != null
                    ? 'Save profile'
                    : register
                    ? 'Create account'
                    : 'Sign in',
              ),
            ),
            if (user == null)
              TextButton(
                onPressed: () => setState(() => register = !register),
                child: Text(
                  register
                      ? 'Already have an account? Sign in'
                      : 'New here? Create an account',
                ),
              )
            else
              TextButton(
                onPressed: () async {
                  try {
                    await widget.store.logout();
                    if (mounted) setState(() {});
                  } catch (e) {
                    if (context.mounted) message(context, e);
                  }
                },
                child: const Text('Sign out'),
              ),
          ],
        ),
      ),
    );
  }

  Widget field(
    TextEditingController controller,
    String label, {
    bool secret = false,
    bool required = true,
    int min = 1,
    TextInputType? keyboard,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 18),
    child: TextFormField(
      controller: controller,
      obscureText: secret,
      keyboardType: keyboard,
      decoration: InputDecoration(labelText: label),
      validator: (v) => required && (v ?? '').trim().length < min
          ? 'Enter $label${min > 1 ? ' (at least $min characters)' : ''}'
          : null,
    ),
  );
}

class GivingPage extends StatefulWidget {
  const GivingPage({super.key, required this.store});
  final HavenStore store;
  @override
  State<GivingPage> createState() => _GivingPageState();
}

class _GivingPageState extends State<GivingPage> with WidgetsBindingObserver {
  final amount = TextEditingController(text: '20000');
  String purpose = 'General ministry';
  bool busy = false;
  List<dynamic> history = [];
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    amount.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) load();
  }

  Future<void> load() async {
    if (widget.store.user == null) return;
    try {
      final rows = await widget.store.api('/giving');
      if (mounted) setState(() => history = rows);
    } catch (e) {
      if (mounted) message(context, e);
    }
  }

  Future<void> give() async {
    final value = double.tryParse(amount.text);
    if (value == null || value < 1000) {
      message(context, 'Enter at least UGX 1,000.');
      return;
    }
    setState(() => busy = true);
    try {
      final result = await widget.store.api(
        '/giving',
        method: 'POST',
        data: {'amount': value, 'purpose': purpose},
      );
      if (!await launchUrl(
        Uri.parse(result['redirect_url']),
        mode: LaunchMode.externalApplication,
      )) {
        throw Exception('Unable to open checkout.');
      }
    } catch (e) {
      if (mounted) message(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Giving')),
    body: widget.store.user == null
        ? LoginRequired(
            store: widget.store,
            onReturn: () {
              setState(() {});
              load();
            },
          )
        : RefreshIndicator(
            onRefresh: load,
            child: ListView(
              padding: const EdgeInsets.all(25),
              children: [
                const Icon(Icons.favorite_border, size: 55, color: green),
                const SizedBox(height: 20),
                const Text(
                  'Give hope. Share love.',
                  style: TextStyle(fontSize: 29, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 15),
                const Text(
                  'Your generosity helps Caring Haven reach more lives.',
                ),
                const SizedBox(height: 25),
                Wrap(
                  spacing: 10,
                  children: [10000, 20000, 50000, 100000]
                      .map(
                        (n) => ActionChip(
                          label: Text('$n'),
                          onPressed: () => setState(() => amount.text = '$n'),
                        ),
                      )
                      .toList(),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: amount,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Amount (UGX)'),
                ),
                const SizedBox(height: 18),
                DropdownButtonFormField<String>(
                  initialValue: purpose,
                  decoration: const InputDecoration(labelText: 'Give towards'),
                  items:
                      [
                            'General ministry',
                            'Community outreach',
                            'Media ministry',
                          ]
                          .map(
                            (p) => DropdownMenuItem(value: p, child: Text(p)),
                          )
                          .toList(),
                  onChanged: (v) => purpose = v!,
                ),
                const SizedBox(height: 22),
                FilledButton(
                  onPressed: busy ? null : give,
                  child: Text(
                    busy ? 'Opening checkout…' : 'Continue to Pesapal',
                  ),
                ),
                const SizedBox(height: 30),
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Your giving history',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 19,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Refresh payments',
                      onPressed: load,
                      icon: const Icon(Icons.refresh),
                    ),
                  ],
                ),
                ...history.map(
                  (d) => ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text('UGX ${d['amount']}'),
                    subtitle: Text(d['purpose']),
                    trailing: Text(d['status']),
                  ),
                ),
              ],
            ),
          ),
  );
}

class PackageCard extends StatelessWidget {
  const PackageCard({
    super.key,
    required this.item,
    this.selected = false,
    this.onSelect,
    this.actionLabel,
  });
  final Map<String, dynamic> item;
  final bool selected;
  final VoidCallback? onSelect;
  final String? actionLabel;
  @override
  Widget build(BuildContext context) {
    final amount = packageAmount(item);
    final compare = (item['compare_at_ugx'] as num?)?.toInt();
    final description = (item['description'] ?? '').toString();
    return Card(
      margin: const EdgeInsets.only(bottom: 14),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: selected ? green : Theme.of(context).dividerColor,
          width: selected ? 1.6 : 1,
        ),
      ),
      child: InkWell(
        onTap: onSelect,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                packageMeta(item),
                style: const TextStyle(fontSize: 11, letterSpacing: 0.7),
              ),
              const SizedBox(height: 8),
              Text(
                '${item['name']}',
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.bold,
                ),
              ),
              if (description.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(description),
              ],
              const SizedBox(height: 12),
              Row(
                children: [
                  Text(
                    packagePriceLabel(item),
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: green,
                    ),
                  ),
                  if (amount != null &&
                      compare != null &&
                      compare > amount) ...[
                    const SizedBox(width: 10),
                    Text(
                      ugx(compare),
                      style: const TextStyle(
                        decoration: TextDecoration.lineThrough,
                      ),
                    ),
                  ],
                ],
              ),
              if (actionLabel != null && onSelect != null) ...[
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: onSelect,
                    child: Text(actionLabel!),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Shown straight after a member signs in or creates an account so they see
/// what the counselling team offers before anything else.
Future<Map<String, dynamic>?> showPackagesSheet(
  BuildContext context,
  HavenStore store,
) {
  final packages = counsellingPackages(store);
  if (packages.isEmpty) return Future.value();
  return showModalBottomSheet<Map<String, dynamic>>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
      maxChildSize: 0.95,
      builder: (context, controller) => ListView(
        controller: controller,
        padding: const EdgeInsets.fromLTRB(22, 0, 22, 30),
        children: [
          const Text(
            'Welcome home.',
            style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 6),
          const Text('How can we walk with you?'),
          const SizedBox(height: 12),
          const Text(
            'These are the counselling packages our team offers. Choose the one that fits your season — you can change it at any time.',
            style: TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 18),
          ...packages.map(
            (p) => PackageCard(
              item: p,
              actionLabel: 'Choose this package',
              onSelect: () => Navigator.pop(context, p),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('I’ll decide later'),
          ),
        ],
      ),
    ),
  );
}

class LoginRequired extends StatelessWidget {
  const LoginRequired({super.key, required this.store, required this.onReturn});
  final HavenStore store;
  final VoidCallback onReturn;
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(30),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.person_outline, size: 55, color: green),
          const SizedBox(height: 20),
          const Text('Sign in to continue with your account.'),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => AccountPage(store: store)),
              );
              onReturn();
            },
            child: const Text('Sign in / Create account'),
          ),
        ],
      ),
    ),
  );
}

class BookingPage extends StatefulWidget {
  const BookingPage({super.key, required this.store, this.initialPackage});
  final HavenStore store;
  final String? initialPackage;
  @override
  State<BookingPage> createState() => _BookingPageState();
}

class _BookingPageState extends State<BookingPage> with WidgetsBindingObserver {
  String topic = 'Faith and spiritual growth', mode = 'online';
  String? selectedPackage;
  DateTime? date;
  final note = TextEditingController();
  bool busy = false;
  int? paying;
  List<dynamic> bookings = [];
  HavenStore get store => widget.store;

  @override
  void initState() {
    super.initState();
    selectedPackage = widget.initialPackage;
    WidgetsBinding.instance.addObserver(this);
    load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    note.dispose();
    super.dispose();
  }

  /// Coming back from the browser checkout proves nothing on its own, so any
  /// payment still pending with the provider is re-checked through the API.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) load();
  }

  Future<void> load() async {
    if (store.user == null) return;
    try {
      var rows = List<dynamic>.from(await store.api('/bookings'));
      final pending = rows
          .where(
            (r) =>
                r['payment_status'] == 'pending' && r['tracking_id'] != null,
          )
          .toList();
      if (pending.isNotEmpty) {
        for (final row in pending) {
          try {
            await store.api(
              '/bookings/payment/status/${row['tracking_id']}',
            );
          } catch (_) {
            // A payment that cannot be confirmed stays pending.
          }
        }
        rows = List<dynamic>.from(await store.api('/bookings'));
      }
      if (mounted) setState(() => bookings = rows);
    } catch (e) {
      if (mounted) message(context, e);
    }
  }

  Future<void> pick() async {
    final day = await showDatePicker(
      context: context,
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (day == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: const TimeOfDay(hour: 10, minute: 0),
    );
    if (time != null && mounted) {
      setState(
        () => date = DateTime(
          day.year,
          day.month,
          day.day,
          time.hour,
          time.minute,
        ),
      );
    }
  }

  Future<void> pay(int id) async {
    setState(() => paying = id);
    try {
      final result = await store.api('/bookings/$id/pay', method: 'POST');
      if (!await launchUrl(
        Uri.parse('${result['redirect_url']}'),
        mode: LaunchMode.externalApplication,
      )) {
        throw Exception('Unable to open checkout.');
      }
    } catch (e) {
      if (mounted) message(context, e);
    } finally {
      if (mounted) setState(() => paying = null);
    }
  }

  Future<void> submit() async {
    if (date == null || date!.isBefore(DateTime.now())) {
      message(context, 'Choose a future date and time.');
      return;
    }
    setState(() => busy = true);
    try {
      final result = await store.api(
        '/bookings',
        method: 'POST',
        data: {
          'topic': topic,
          'mode': mode,
          'package': selectedPackage,
          'requested_at': date!.toUtc().toIso8601String(),
          'message': note.text,
        },
      );
      note.clear();
      date = null;
      final needsPayment = '${result['payment_status']}' == 'unpaid';
      await load();
      if (!mounted) return;
      if (needsPayment) {
        await pay(result['id'] as int);
      } else {
        setState(() => selectedPackage = null);
        message(
          context,
          'Request received. Our team will contact you to confirm.',
        );
      }
    } catch (e) {
      if (mounted) message(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final packages = counsellingPackages(store);
    Map<String, dynamic>? chosen;
    for (final p in packages) {
      if (p['name'] == selectedPackage) chosen = p;
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Counselling')),
      body: store.user == null
          ? LoginRequired(
              store: store,
              onReturn: () {
                setState(() {});
                load();
              },
            )
          : RefreshIndicator(
              onRefresh: load,
              child: ListView(
                padding: const EdgeInsets.all(25),
                children: [
                  const Text(
                    'You’re not alone.',
                    style: TextStyle(fontSize: 30, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 10),
                  const Text('Request a conversation with someone who cares.'),
                  if (packages.isNotEmpty) ...[
                    const SizedBox(height: 28),
                    const Text(
                      'Our counselling packages',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'Choose the level of support that fits your season. You can change it any time.',
                      style: TextStyle(fontSize: 12),
                    ),
                    const SizedBox(height: 14),
                    ...packages.map(
                      (p) => PackageCard(
                        item: p,
                        selected: selectedPackage == p['name'],
                        onSelect: () =>
                            setState(() => selectedPackage = '${p['name']}'),
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    key: ValueKey('package-$selectedPackage'),
                    initialValue: selectedPackage,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Counselling package',
                    ),
                    hint: const Text('Not sure yet — help me choose'),
                    items: packages
                        .map(
                          (p) => DropdownMenuItem(
                            value: '${p['name']}',
                            child: Text(
                              '${p['name']} · ${packageMeta(p)} · ${packagePriceLabel(p)}',
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: (v) => setState(() => selectedPackage = v),
                  ),
                  const SizedBox(height: 18),
                  DropdownButtonFormField<String>(
                    initialValue: topic,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Topic'),
                    items:
                        [
                              'Faith and spiritual growth',
                              'Relationships and family',
                              'Grief and loss',
                              'Personal wellbeing',
                              'Something else',
                            ]
                            .map(
                              (v) => DropdownMenuItem(value: v, child: Text(v)),
                            )
                            .toList(),
                    onChanged: (v) => topic = v!,
                  ),
                  const SizedBox(height: 18),
                  DropdownButtonFormField<String>(
                    initialValue: mode,
                    decoration: const InputDecoration(labelText: 'Session format'),
                    items: ['online', 'in-person', 'phone']
                        .map((v) => DropdownMenuItem(value: v, child: Text(v)))
                        .toList(),
                    onChanged: (v) => mode = v!,
                  ),
                  const SizedBox(height: 18),
                  OutlinedButton.icon(
                    onPressed: pick,
                    icon: const Icon(Icons.calendar_month),
                    label: Text(
                      date == null
                          ? 'Choose date & time'
                          : date.toString().substring(0, 16),
                    ),
                  ),
                  const SizedBox(height: 18),
                  TextField(
                    controller: note,
                    maxLines: 4,
                    maxLength: 3000,
                    decoration: const InputDecoration(
                      labelText: 'Anything to share? (optional)',
                    ),
                  ),
                  Text(
                    'Only authorized Caring Haven administrators can view your request. Your preferred time is subject to confirmation.'
                    '${chosen != null && packageNeedsPayment(chosen) ? ' You will be taken to a secure checkout to pay for your package.' : ''}',
                    style: const TextStyle(fontSize: 11),
                  ),
                  const SizedBox(height: 22),
                  FilledButton(
                    onPressed: busy ? null : submit,
                    child: Text(busy ? 'Sending…' : 'Request a session'),
                  ),
                  const SizedBox(height: 30),
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Your sessions',
                          style: TextStyle(
                            fontSize: 21,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Refresh sessions',
                        onPressed: load,
                        icon: const Icon(Icons.refresh),
                      ),
                    ],
                  ),
                  if (bookings.isEmpty) const Text('Your requests will appear here.'),
                  ...bookings.map((b) {
                    final amount = moneyValue(b['amount']);
                    final unpaid = b['payment_status'] == 'unpaid' ||
                        b['payment_status'] == 'failed';
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      isThreeLine: amount != null && amount > 0,
                      title: Text('${b['package'] ?? b['topic']}'),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${DateTime.parse('${b['requested_at']}Z').toLocal().toString().substring(0, 16)} · ${b['mode']}'
                            '${b['package'] != null ? ' · ${b['topic']}' : ''}',
                          ),
                          if (amount != null && amount > 0)
                            Text(
                              '${ugx(amount)} · ${paymentLabel(b['payment_status'] as String?)}',
                              style: const TextStyle(
                                color: green,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                        ],
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('${b['status']}'),
                          if (unpaid) ...[
                            const SizedBox(width: 8),
                            TextButton(
                              onPressed: paying == b['id']
                                  ? null
                                  : () => pay(b['id'] as int),
                              child: Text(
                                paying == b['id'] ? 'Opening…' : 'Pay now',
                              ),
                            ),
                          ],
                        ],
                      ),
                    );
                  }),
                ],
              ),
            ),
    );
  }
}

class AboutPage extends StatelessWidget {
  const AboutPage({super.key, required this.store});
  final HavenStore store;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('About us')),
    body: ListView(
      padding: const EdgeInsets.all(25),
      children: [
        Image.asset('assets/images/caringhaven.png', height: 170),
        const SizedBox(height: 25),
        const Text(
          'It’s about you.',
          style: TextStyle(fontSize: 31, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 20),
        Text(
          store.settings['about'] ?? 'Welcome to Caring Haven Uganda.',
          style: const TextStyle(fontSize: 17, height: 1.8),
        ),
        const SizedBox(height: 25),
        Text(store.settings['contact_email'] ?? ''),
        Text(store.settings['contact_phone'] ?? ''),
        TextButton(
          onPressed: () => launchUrl(
            Uri.parse('https://www.caringhavenuganda.org/'),  // website stays the same
            mode: LaunchMode.externalApplication,
          ),
          child: const Text('Visit our website ↗'),
        ),
      ],
    ),
  );
}

class EventsPage extends StatelessWidget {
  const EventsPage({super.key, required this.store});
  final HavenStore store;
  @override
  Widget build(BuildContext context) {
    final events = store.contents.where((e) => e['type'] == 'event');
    return Scaffold(
      appBar: AppBar(title: const Text('Events & updates')),
      body: ListView(
        padding: const EdgeInsets.all(22),
        children: [
          if (events.isEmpty)
            const Text(
              'Upcoming events and ministry updates will appear here.',
            ),
          ...events.map(
            (i) => ContentTile(
              item: i,
              store: store,
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => ReaderPage(store: store, item: i),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
