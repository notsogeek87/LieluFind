

import 'dart:math';

import 'package:dawarich/core/data/backup/backup_secrets_store.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

final class DbKeyProvider {

  final FlutterSecureStorage _ss = const FlutterSecureStorage();
  final BackupSecretsStore _backup = const BackupSecretsStore();
  static const _k = 'db_key_v1';

  Future<String> getOrCreateHexKey() async {

    final String? e = await _ss.read(key: _k);

    if (e != null && e.isNotEmpty) {
      await _backup.write(_k, e);
      return e;
    }

    // Nouveau téléphone : le Keystore n'a pas suivi, mais le miroir restauré
    // par Android Auto Backup permet de rouvrir la base sauvegardée.
    final String? restored = await _backup.read(_k);
    if (restored != null) {
      await _ss.write(key: _k, value: restored);
      return restored;
    }

    final Random rnd = Random.secure();
    final List<int> bytes = List<int>.generate(32, (_) => rnd.nextInt(256));
    final String hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();

    await _ss.write(
      key: _k,
      value: hex,
    );
    await _backup.write(_k, hex);
    return hex;
  }

}