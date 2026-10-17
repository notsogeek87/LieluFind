import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Petit journal texte du service de tracking, lisible dans les réglages.
/// Fichier simple (pas de base) : utilisable depuis l'isolate de fond comme
/// depuis l'UI, sans migration. Ne lève jamais d'exception.
final class TrackingLog {
  static const _fileName = 'tracking_log.txt';
  static const _maxBytes = 64 * 1024;
  static final Map<String, DateTime> _lastByKey = {};

  static Future<File> _file() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_fileName');
  }

  static Future<void> add(String message) async {
    try {
      final f = await _file();
      final line = '${DateTime.now().toIso8601String().substring(0, 19)}  $message\n';
      await f.writeAsString(line, mode: FileMode.append, flush: true);
      if (await f.length() > _maxBytes) {
        final text = await f.readAsString();
        await f.writeAsString(text.substring(text.length ~/ 2));
      }
    } catch (_) {}
  }

  /// Une seule entrée par [key] et par [every] (évite d'inonder le journal).
  static Future<void> addThrottled(String key, String message,
      {Duration every = const Duration(minutes: 5)}) async {
    final now = DateTime.now();
    final last = _lastByKey[key];
    if (last != null && now.difference(last) < every) return;
    _lastByKey[key] = now;
    await add(message);
  }

  static Future<String> read() async {
    try {
      final f = await _file();
      if (!await f.exists()) return '';
      return await f.readAsString();
    } catch (e) {
      return 'Lecture impossible : $e';
    }
  }

  static Future<void> clear() async {
    try {
      final f = await _file();
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }
}
