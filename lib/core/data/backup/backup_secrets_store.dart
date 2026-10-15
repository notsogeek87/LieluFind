import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Miroir restaurable des secrets (clé SQLCipher, URL et clé API).
///
/// Le Keystore Android n'est pas restauré sur un nouveau téléphone : sans ce
/// fichier, la base chiffrée sauvegardée par Android Auto Backup serait
/// illisible. Il est inclus dans les règles de sauvegarde
/// (`backup_rules.xml` / `data_extraction_rules.xml`) et n'est donc transféré
/// que via la sauvegarde Android (chiffrée côté Google) ou le transfert direct.
final class BackupSecretsStore {

  /// Doit rester identique aux chemins déclarés dans les règles de sauvegarde.
  static const String fileName = 'lielu_backup_secrets.json';

  const BackupSecretsStore();

  Future<File> _file() async {
    final dir = await getApplicationDocumentsDirectory();
    return File(p.join(dir.path, fileName));
  }

  Future<Map<String, String>> _readAll() async {
    try {
      final file = await _file();
      if (!await file.exists()) {
        return {};
      }
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) {
        return {};
      }
      return {
        for (final e in decoded.entries)
          if (e.key is String && e.value is String) e.key as String: e.value as String,
      };
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[BackupSecretsStore] read failed: $e');
      }
      return {};
    }
  }

  Future<String?> read(String key) async {
    final value = (await _readAll())[key];
    return (value == null || value.isEmpty) ? null : value;
  }

  Future<void> write(String key, String? value) async {
    try {
      final all = await _readAll();
      if (value == null || value.isEmpty) {
        all.remove(key);
      } else {
        all[key] = value;
      }

      final file = await _file();
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(jsonEncode(all), flush: true);
      await tmp.rename(file.path);
    } catch (e) {
      // La sauvegarde est un confort : ne jamais casser l'app pour ça.
      if (kDebugMode) {
        debugPrint('[BackupSecretsStore] write failed: $e');
      }
    }
  }
}
