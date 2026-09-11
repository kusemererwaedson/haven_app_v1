import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

Future<String> saveAudio(String url, String id) async {
  final directory = await getApplicationDocumentsDirectory();
  final target = File('${directory.path}/haven-$id.audio');
  final temporary = File('${target.path}.part');
  final client = http.Client();
  try {
    final response = await client
        .send(http.Request('GET', Uri.parse(url)))
        .timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) {
      throw Exception('Download failed. Please try again.');
    }
    final sink = temporary.openWrite();
    try {
      await response.stream.timeout(const Duration(seconds: 45)).pipe(sink);
    } catch (_) {
      await sink.close();
      rethrow;
    }
    await temporary.rename(target.path);
    return target.path;
  } catch (_) {
    if (await temporary.exists()) await temporary.delete();
    rethrow;
  } finally {
    client.close();
  }
}

Future<bool> audioExists(String path) => File(path).exists();
